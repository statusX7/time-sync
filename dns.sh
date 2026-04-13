#!/usr/bin/env bash
set -euo pipefail

############################################
# DoH Manager PRO (All-in-One + allowlist.txt)
# Version: v2.4
#
# v2.4 更新：
# 1) 服务状态检查改为自动判断正常/异常，并显示异常原因摘要
# 2) 端口监听检查改为自动判断正常/异常
# 3) 健康检查改为自动判断正常/异常
# 4) 证书有效期检查改为显示是否有效、剩余天数
# 5) 菜单改为并列形式
# 6) 菜单序号重新按顺序排列
############################################

SCRIPT_VERSION="v2.4"

MOSDNS_USER="mosdns"
CONF_DIR="/etc/mosdns-x"
WORK_DIR="/var/lib/mosdns-x"
MOSDNS_HTTP_ADDR="127.0.0.1:8053"

ACME_WEBROOT="/var/www/acme"
STATIC_ROOT="/var/www/html"

UNBOUND_PORT="5335"
UNBOUND_SNIPPET="/etc/unbound/unbound.conf.d/doh-forward.conf"

NGINX_SITE_DIR="/etc/nginx/sites-available"
NGINX_LINK_DIR="/etc/nginx/sites-enabled"

STATE_FILE="/etc/mosdns-x/doh-manager-pro.state"
LOG_FILE="/var/log/doh-manager-pro.log"
DEFAULT_ALLOWLIST_FILE="/etc/mosdns-x/allowlist.txt"

DEFAULT_DOMAIN="example.com"
DEFAULT_DOH_PATH="/dns-query"

DEFAULT_UPSTREAM_DOT=(
  "1.1.1.1@853"
  "8.8.8.8@853"
)

DEFAULT_UB_MSG_CACHE="64m"
DEFAULT_UB_RRSET_CACHE="128m"
DEFAULT_UB_MIN_TTL="60"
DEFAULT_UB_MAX_TTL="86400"
DEFAULT_UB_PREFETCH="yes"
DEFAULT_UB_SERVE_EXPIRED="yes"
DEFAULT_UB_SERVE_EXPIRED_TTL="3600"
DEFAULT_UB_SERVE_EXPIRED_REPLY_TTL="30"
DEFAULT_UB_DO_IP6="no"

DEFAULT_MOS_LOG_LEVEL="info"
DEFAULT_DENY_MODE="refused"

DEFAULT_NGX_HTTP2="yes"
DEFAULT_NGX_LIMIT_REQ="no"
DEFAULT_NGX_RPS="20"
DEFAULT_NGX_BURST="40"

TEMPLATE_SIMPLE='<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>OK</title></head><body><h1>OK</h1></body></html>'
TEMPLATE_404='<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>404 Not Found</title></head><body><h1>404 Not Found</h1></body></html>'
TEMPLATE_MINIMAL='<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Welcome</title></head><body>Welcome</body></html>'

DOMAIN=""
DOH_PATH=""
ALLOWLIST_FILE=""
UPSTREAM_DOT=()

UB_MSG_CACHE=""
UB_RRSET_CACHE=""
UB_MIN_TTL=""
UB_MAX_TTL=""
UB_PREFETCH=""
UB_SERVE_EXPIRED=""
UB_SERVE_EXPIRED_TTL=""
UB_SERVE_EXPIRED_REPLY_TTL=""
UB_DO_IP6=""

MOS_LOG_LEVEL=""
DENY_MODE=""

NGX_HTTP2=""
NGX_LIMIT_REQ=""
NGX_RPS=""
NGX_BURST=""

NGINX_SSL_DIR=""
FIRST_RUN="no"

c_ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
c_warn() { echo -e "\033[1;33m[!]\033[0m  $*"; }
c_err()  { echo -e "\033[1;31m[-]\033[0m $*"; }
c_info() { echo -e "\033[1;36m[i]\033[0m  $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    c_err "请使用 root 运行"
    exit 1
  fi
}

log_action() {
  local msg="$*"
  mkdir -p "$(dirname "${LOG_FILE}")" >/dev/null 2>&1 || true
  echo "[$(date '+%F %T')] [${SCRIPT_VERSION}] ${msg}" >> "${LOG_FILE}"
}

backup_file() {
  local f="$1"
  if [[ -f "${f}" ]]; then
    cp -a "${f}" "${f}.bak.$(date +%Y%m%d_%H%M%S)"
    c_ok "已备份: ${f}"
    log_action "backup ${f}"
  fi
}

remove_if_exists() {
  local path="$1"
  if [[ -e "${path}" || -L "${path}" ]]; then
    rm -rf "${path}"
    c_ok "已删除: ${path}"
  else
    c_warn "不存在，跳过: ${path}"
  fi
}

pause_enter() {
  echo
  read -r -p "按回车继续..." _
}

ensure_state_file() {
  mkdir -p "$(dirname "${STATE_FILE}")"
  if [[ ! -f "${STATE_FILE}" ]]; then
    FIRST_RUN="yes"
    c_warn "未发现状态文件，开始初始化: ${STATE_FILE}"
    log_action "init state file ${STATE_FILE}"
    {
      echo "DOMAIN=\"${DEFAULT_DOMAIN}\""
      echo "DOH_PATH=\"${DEFAULT_DOH_PATH}\""
      echo "ALLOWLIST_FILE=\"${DEFAULT_ALLOWLIST_FILE}\""

      echo "UPSTREAM_DOT=("
      for u in "${DEFAULT_UPSTREAM_DOT[@]}"; do
        echo "  \"${u}\""
      done
      echo ")"

      echo "UB_MSG_CACHE=\"${DEFAULT_UB_MSG_CACHE}\""
      echo "UB_RRSET_CACHE=\"${DEFAULT_UB_RRSET_CACHE}\""
      echo "UB_MIN_TTL=\"${DEFAULT_UB_MIN_TTL}\""
      echo "UB_MAX_TTL=\"${DEFAULT_UB_MAX_TTL}\""
      echo "UB_PREFETCH=\"${DEFAULT_UB_PREFETCH}\""
      echo "UB_SERVE_EXPIRED=\"${DEFAULT_UB_SERVE_EXPIRED}\""
      echo "UB_SERVE_EXPIRED_TTL=\"${DEFAULT_UB_SERVE_EXPIRED_TTL}\""
      echo "UB_SERVE_EXPIRED_REPLY_TTL=\"${DEFAULT_UB_SERVE_EXPIRED_REPLY_TTL}\""
      echo "UB_DO_IP6=\"${DEFAULT_UB_DO_IP6}\""

      echo "MOS_LOG_LEVEL=\"${DEFAULT_MOS_LOG_LEVEL}\""
      echo "DENY_MODE=\"${DEFAULT_DENY_MODE}\""

      echo "NGX_HTTP2=\"${DEFAULT_NGX_HTTP2}\""
      echo "NGX_LIMIT_REQ=\"${DEFAULT_NGX_LIMIT_REQ}\""
      echo "NGX_RPS=\"${DEFAULT_NGX_RPS}\""
      echo "NGX_BURST=\"${DEFAULT_NGX_BURST}\""
    } > "${STATE_FILE}"
    c_ok "初始化完成"
  fi
}

load_state() {
  # shellcheck disable=SC1090
  source "${STATE_FILE}"

  DOMAIN="${DOMAIN:-${DEFAULT_DOMAIN}}"
  DOH_PATH="${DOH_PATH:-${DEFAULT_DOH_PATH}}"
  ALLOWLIST_FILE="${ALLOWLIST_FILE:-${DEFAULT_ALLOWLIST_FILE}}"
  NGINX_SSL_DIR="/etc/nginx/ssl/${DOMAIN}"

  if (( ${#UPSTREAM_DOT[@]} <= 0 )); then
    UPSTREAM_DOT=("${DEFAULT_UPSTREAM_DOT[@]}")
  fi

  UB_MSG_CACHE="${UB_MSG_CACHE:-${DEFAULT_UB_MSG_CACHE}}"
  UB_RRSET_CACHE="${UB_RRSET_CACHE:-${DEFAULT_UB_RRSET_CACHE}}"
  UB_MIN_TTL="${UB_MIN_TTL:-${DEFAULT_UB_MIN_TTL}}"
  UB_MAX_TTL="${UB_MAX_TTL:-${DEFAULT_UB_MAX_TTL}}"
  UB_PREFETCH="${UB_PREFETCH:-${DEFAULT_UB_PREFETCH}}"
  UB_SERVE_EXPIRED="${UB_SERVE_EXPIRED:-${DEFAULT_UB_SERVE_EXPIRED}}"
  UB_SERVE_EXPIRED_TTL="${UB_SERVE_EXPIRED_TTL:-${DEFAULT_UB_SERVE_EXPIRED_TTL}}"
  UB_SERVE_EXPIRED_REPLY_TTL="${UB_SERVE_EXPIRED_REPLY_TTL:-${DEFAULT_UB_SERVE_EXPIRED_REPLY_TTL}}"
  UB_DO_IP6="${UB_DO_IP6:-${DEFAULT_UB_DO_IP6}}"

  MOS_LOG_LEVEL="${MOS_LOG_LEVEL:-${DEFAULT_MOS_LOG_LEVEL}}"
  DENY_MODE="${DENY_MODE:-${DEFAULT_DENY_MODE}}"

  NGX_HTTP2="${NGX_HTTP2:-${DEFAULT_NGX_HTTP2}}"
  NGX_LIMIT_REQ="${NGX_LIMIT_REQ:-${DEFAULT_NGX_LIMIT_REQ}}"
  NGX_RPS="${NGX_RPS:-${DEFAULT_NGX_RPS}}"
  NGX_BURST="${NGX_BURST:-${DEFAULT_NGX_BURST}}"
}

save_state() {
  {
    echo "DOMAIN=\"${DOMAIN}\""
    echo "DOH_PATH=\"${DOH_PATH}\""
    echo "ALLOWLIST_FILE=\"${ALLOWLIST_FILE}\""

    echo "UPSTREAM_DOT=("
    for u in "${UPSTREAM_DOT[@]}"; do echo "  \"${u}\""; done
    echo ")"

    echo "UB_MSG_CACHE=\"${UB_MSG_CACHE}\""
    echo "UB_RRSET_CACHE=\"${UB_RRSET_CACHE}\""
    echo "UB_MIN_TTL=\"${UB_MIN_TTL}\""
    echo "UB_MAX_TTL=\"${UB_MAX_TTL}\""
    echo "UB_PREFETCH=\"${UB_PREFETCH}\""
    echo "UB_SERVE_EXPIRED=\"${UB_SERVE_EXPIRED}\""
    echo "UB_SERVE_EXPIRED_TTL=\"${UB_SERVE_EXPIRED_TTL}\""
    echo "UB_SERVE_EXPIRED_REPLY_TTL=\"${UB_SERVE_EXPIRED_REPLY_TTL}\""
    echo "UB_DO_IP6=\"${UB_DO_IP6}\""

    echo "MOS_LOG_LEVEL=\"${MOS_LOG_LEVEL}\""
    echo "DENY_MODE=\"${DENY_MODE}\""

    echo "NGX_HTTP2=\"${NGX_HTTP2}\""
    echo "NGX_LIMIT_REQ=\"${NGX_LIMIT_REQ}\""
    echo "NGX_RPS=\"${NGX_RPS}\""
    echo "NGX_BURST=\"${NGX_BURST}\""
  } > "${STATE_FILE}"

  c_ok "已保存状态: ${STATE_FILE}"
  log_action "save state"
}

is_installed() {
  [[ -x /usr/local/bin/mosdns && -f /etc/systemd/system/mosdns.service && -d "${CONF_DIR}" ]]
}

service_is_running() {
  systemctl is-active --quiet mosdns && systemctl is-active --quiet unbound && systemctl is-active --quiet nginx
}

ensure_allowlist_file() {
  mkdir -p "$(dirname "${ALLOWLIST_FILE}")"
  if [[ ! -f "${ALLOWLIST_FILE}" ]]; then
    c_warn "未发现 allowlist.txt，开始初始化: ${ALLOWLIST_FILE}"
    cat > "${ALLOWLIST_FILE}" <<EOF
# allowlist.txt
# 每行一个域名或后缀
EOF
    c_ok "allowlist.txt 初始化完成"
    log_action "init allowlist ${ALLOWLIST_FILE}"
  fi
}

allowlist_count() {
  ensure_allowlist_file
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    {count++}
    END {print count+0}
  ' "${ALLOWLIST_FILE}"
}

show_brief_runtime_status() {
  echo "=============================================================="
  echo " DoH Manager PRO ${SCRIPT_VERSION}"
  if is_installed; then
    if service_is_running; then
      c_ok "状态: 已安装，服务正在运行"
    else
      c_warn "状态: 已安装，但服务未全部运行"
    fi
  else
    c_warn "状态: 尚未完整安装"
  fi
  echo " 当前域名: ${DOMAIN}"
  echo " 当前路径: ${DOH_PATH}"
  echo " allowlist 条数: $(allowlist_count)"
  echo "=============================================================="
}

show_allowlist() {
  ensure_allowlist_file
  echo "==================== allowlist.txt ===================="
  echo "路径: ${ALLOWLIST_FILE}"
  echo "条数: $(allowlist_count)"
  echo "--------------------------------------------------------"
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    {print " - " $0}
  ' "${ALLOWLIST_FILE}" | head -n 200
  local total
  total="$(allowlist_count)"
  if (( total > 200 )); then
    echo "..."
    echo "(仅显示前200条，总计 ${total} 条)"
  fi
  echo "========================================================"
}

edit_allowlist_vim() {
  ensure_allowlist_file
  c_warn "使用 vim 编辑（保存 :wq，退出 :q）"
  sleep 1
  vim "${ALLOWLIST_FILE}"
  c_ok "已保存 allowlist.txt"
  log_action "edit allowlist by vim"
}

allowlist_dedupe_sort() {
  ensure_allowlist_file
  local tmp="/tmp/allowlist.$$.tmp"
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    {
      gsub(/\r/,"",$0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if (length($0)>0) print $0
    }
  ' "${ALLOWLIST_FILE}" | sort -u > "${tmp}"
  {
    echo "# allowlist.txt (managed by DoH Manager PRO)"
    echo "# each line: domain or suffix"
    cat "${tmp}"
  } > "${ALLOWLIST_FILE}"
  rm -f "${tmp}" >/dev/null 2>&1 || true
  c_ok "allowlist.txt 已去重排序"
  log_action "dedupe/sort allowlist"
}

add_allowlist_one() {
  ensure_allowlist_file
  read -r -p "请输入要新增的域名/后缀: " s
  [[ -n "${s}" ]] || { c_warn "未输入，取消"; return; }
  s="$(echo "${s}" | tr -d '\r' | sed -e 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"
  [[ -n "${s}" ]] || { c_warn "空输入，取消"; return; }

  if grep -qxF "${s}" "${ALLOWLIST_FILE}" 2>/dev/null; then
    c_warn "已存在: ${s}"
    return
  fi

  echo "${s}" >> "${ALLOWLIST_FILE}"
  allowlist_dedupe_sort
  c_ok "已新增: ${s}"
  log_action "allowlist add ${s}"
}

remove_allowlist_one() {
  ensure_allowlist_file
  show_allowlist
  read -r -p "请输入要删除的域名/后缀（完整匹配）: " s
  [[ -n "${s}" ]] || { c_warn "未输入，取消"; return; }

  if ! grep -qxF "${s}" "${ALLOWLIST_FILE}" 2>/dev/null; then
    c_warn "未找到: ${s}"
    return
  fi

  local tmp="/tmp/allowlist.rm.$$.tmp"
  grep -vxF "${s}" "${ALLOWLIST_FILE}" > "${tmp}" || true
  mv "${tmp}" "${ALLOWLIST_FILE}"
  allowlist_dedupe_sort
  c_ok "已删除: ${s}"
  log_action "allowlist remove ${s}"
}

normalize_domain_line() {
  local line="$1"
  line="$(echo "${line}" | sed -e 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"
  [[ -z "${line}" ]] && return 0
  [[ "${line}" =~ ^# ]] && return 0

  line="${line//\"/}"
  line="${line//\'/}"
  line="${line//,/}"
  line="${line//\r/}"

  if [[ "${line}" == geosite:* ]]; then
    return 0
  fi

  if [[ "${line}" == domain:* ]]; then
    line="${line#domain:}"
  fi

  if echo "${line}" | grep -qiE 'DOMAIN-SUFFIX'; then
    line="$(echo "${line}" | awk -F',' '{print $2}')"
  fi

  if echo "${line}" | grep -qiE 'DOMAIN,'; then
    line="$(echo "${line}" | awk -F',' '{print $2}')"
  fi

  line="${line#- }"
  [[ -z "${line}" ]] && return 0
  [[ "${line}" =~ [[:space:]] ]] && return 0

  line="${line//\$app_name/}"
  line="$(echo "${line}" | sed -e 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"

  line="${line#http://}"
  line="${line#https://}"
  line="$(echo "${line}" | cut -d'/' -f1)"
  line="$(echo "${line}" | cut -d':' -f1)"

  if [[ "${line}" != *.* ]]; then
    return 0
  fi

  echo "${line}"
}

batch_import_allowlist() {
  ensure_allowlist_file
  c_info "批量导入 allowlist.txt"
  echo
  echo "请粘贴域名列表，多行均可，输入 END 结束"
  echo "------------------------------------------------------------"

  local tmp="/tmp/doh_allow_import.$$.txt"
  : > "${tmp}"

  while IFS= read -r line; do
    [[ "${line}" == "END" ]] && break
    echo "${line}" >> "${tmp}"
  done

  local before
  before="$(allowlist_count)"
  local added=0

  while IFS= read -r line; do
    local d
    d="$(normalize_domain_line "${line}" || true)"
    [[ -z "${d}" ]] && continue

    if ! grep -qxF "${d}" "${ALLOWLIST_FILE}" 2>/dev/null; then
      echo "${d}" >> "${ALLOWLIST_FILE}"
      added=$((added+1))
    fi
  done < "${tmp}"

  rm -f "${tmp}" >/dev/null 2>&1 || true

  allowlist_dedupe_sort
  local after
  after="$(allowlist_count)"

  c_ok "导入完成: 新增 ${added} 条；原有 ${before} -> 现在 ${after}"
  log_action "batch import allowlist added=${added} total=${after}"
}

show_config() {
  echo "==================== 当前配置 ===================="
  echo "版本: ${SCRIPT_VERSION}"
  echo "DOMAIN: ${DOMAIN}"
  echo "DOH_PATH: ${DOH_PATH}"
  echo "ALLOWLIST_FILE: ${ALLOWLIST_FILE}"
  echo "ALLOWLIST_COUNT: $(allowlist_count)"
  echo
  echo "UPSTREAM_DOT:"
  for u in "${UPSTREAM_DOT[@]}"; do echo "  - ${u}"; done
  echo "=================================================="
}

set_domain() {
  echo "当前 DOMAIN: ${DOMAIN}"
  read -r -p "请输入新的伪装域名: " newd
  [[ -n "${newd}" ]] || { c_warn "未输入，取消"; return; }
  DOMAIN="${newd}"
  NGINX_SSL_DIR="/etc/nginx/ssl/${DOMAIN}"
  c_ok "DOMAIN 已设置为: ${DOMAIN}"
  c_warn "更换 DOMAIN 后需要重新签发证书"
  log_action "set DOMAIN=${DOMAIN}"
  save_state
}

set_doh_path() {
  echo "当前 DOH_PATH: ${DOH_PATH}"
  read -r -p "请输入新的伪装路径: " p
  [[ -n "${p}" ]] || { c_warn "未输入，取消"; return; }
  if [[ "${p:0:1}" != "/" ]]; then
    c_err "DOH_PATH 必须以 / 开头"
    return
  fi
  DOH_PATH="${p}"
  c_ok "DOH_PATH 已设置为: ${DOH_PATH}"
  log_action "set DOH_PATH=${DOH_PATH}"
  save_state
}

set_allowlist_file() {
  echo "当前 allowlist 路径: ${ALLOWLIST_FILE}"
  read -r -p "请输入新的 allowlist.txt 路径: " p
  [[ -n "${p}" ]] || { c_warn "未输入，取消"; return; }
  ALLOWLIST_FILE="${p}"
  ensure_allowlist_file
  c_ok "ALLOWLIST_FILE 已设置为: ${ALLOWLIST_FILE}"
  log_action "set ALLOWLIST_FILE=${ALLOWLIST_FILE}"
  save_state
}

list_upstreams() {
  echo "UPSTREAM_DOT 列表:"
  local i=1
  for u in "${UPSTREAM_DOT[@]}"; do
    echo "  [$i] ${u}"
    i=$((i+1))
  done
}

add_upstream() {
  read -r -p "请输入新的 DoT 上游（例如 1.1.1.1@853）: " u
  [[ -n "${u}" ]] || { c_warn "未输入，取消"; return; }
  for x in "${UPSTREAM_DOT[@]}"; do
    if [[ "${x}" == "${u}" ]]; then
      c_warn "已存在: ${u}"
      return
    fi
  done
  UPSTREAM_DOT+=("${u}")
  c_ok "已新增: ${u}"
  log_action "add UPSTREAM_DOT+=${u}"
  save_state
}

remove_upstream() {
  list_upstreams
  read -r -p "请输入要删除的序号: " idx
  [[ "${idx}" =~ ^[0-9]+$ ]] || { c_err "请输入数字"; return; }
  local n="${#UPSTREAM_DOT[@]}"
  if (( idx < 1 || idx > n )); then
    c_err "超出范围"
    return
  fi
  local target="${UPSTREAM_DOT[$((idx-1))]}"
  UPSTREAM_DOT=( "${UPSTREAM_DOT[@]:0:$((idx-1))}" "${UPSTREAM_DOT[@]:$idx}" )
  c_ok "已删除: ${target}"
  log_action "remove UPSTREAM_DOT-=${target}"
  save_state
}

quick_setup_wizard() {
  c_info "快速初始化向导"
  echo

  read -r -p "请问伪装域名是什么？ " input_domain
  [[ -n "${input_domain}" ]] || { c_warn "域名为空，取消"; return; }

  read -r -p "请问伪装路径是什么？ " input_path
  [[ -n "${input_path}" ]] || { c_warn "路径为空，取消"; return; }
  if [[ "${input_path:0:1}" != "/" ]]; then
    input_path="/${input_path}"
  fi

  read -r -p "请问您想添加进 allowlist.txt 的域名是什么？以英文逗号分割: " input_domains
  [[ -n "${input_domains}" ]] || { c_warn "allowlist 为空，取消"; return; }

  DOMAIN="${input_domain}"
  DOH_PATH="${input_path}"
  NGINX_SSL_DIR="/etc/nginx/ssl/${DOMAIN}"

  ensure_allowlist_file
  : > "${ALLOWLIST_FILE}"
  echo "# allowlist.txt (managed by DoH Manager PRO ${SCRIPT_VERSION})" >> "${ALLOWLIST_FILE}"
  echo "# each line: domain or suffix" >> "${ALLOWLIST_FILE}"

  IFS=',' read -r -a domains_arr <<< "${input_domains}"
  for item in "${domains_arr[@]}"; do
    item="$(echo "${item}" | sed -e 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"
    [[ -n "${item}" ]] && echo "${item}" >> "${ALLOWLIST_FILE}"
  done

  allowlist_dedupe_sort
  save_state

  c_ok "快速初始化完成"
  c_info "DOMAIN = ${DOMAIN}"
  c_info "DOH_PATH = ${DOH_PATH}"
  c_info "ALLOWLIST_COUNT = $(allowlist_count)"
  log_action "quick setup wizard done"

  echo
  c_info "开始安装/修复环境..."
  ensure_environment

  echo
  c_info "开始自动尝试为当前 DOMAIN 签发证书..."
  if issue_cert; then
    c_ok "自动签发证书成功"
  else
    c_warn "自动签发证书失败，请稍后在菜单中手动重试"
  fi
}

doh_path_conflict_check() {
  c_info "DoH 路径冲突检测"

  if [[ "${DOH_PATH:0:1}" != "/" ]]; then
    c_err "DOH_PATH 必须以 / 开头: ${DOH_PATH}"
    return 1
  fi

  if [[ "${DOH_PATH}" == "/" ]]; then
    c_err "DOH_PATH 不能是 /"
    return 1
  fi

  if [[ "${DOH_PATH}" == "/.well-known/acme-challenge/"* ]]; then
    c_err "DOH_PATH 与 ACME 冲突: ${DOH_PATH}"
    return 1
  fi

  local static_file="${STATIC_ROOT}${DOH_PATH}"
  if [[ -f "${static_file}" ]]; then
    c_warn "静态目录中存在同名文件: ${static_file}"
  fi

  if [[ "${DOH_PATH}" != */*.* ]]; then
    c_warn "路径看起来不像静态资源: ${DOH_PATH}"
  fi

  c_ok "路径检测通过"
  return 0
}

cert_exists_for_domain() {
  [[ -f "${NGINX_SSL_DIR}/fullchain.pem" && -f "${NGINX_SSL_DIR}/${DOMAIN}.key" ]]
}

check_domain_cert_before_apply() {
  if cert_exists_for_domain; then
    c_ok "检测到当前 DOMAIN 证书存在"
    return 0
  fi

  c_err "未检测到当前 DOMAIN 的证书文件"
  echo "缺少以下文件之一："
  echo " - ${NGINX_SSL_DIR}/fullchain.pem"
  echo " - ${NGINX_SSL_DIR}/${DOMAIN}.key"
  echo
  c_warn "请先执行证书签发，再进行应用"
  return 1
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget jq unzip tar \
    nginx openssl socat \
    unbound
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl enable unbound >/dev/null 2>&1 || true
  c_ok "依赖安装完成"
  log_action "apt install deps"
}

download_and_install_mosdnsx() {
  c_info "安装/更新 mosdns-x"

  local arch arch_key
  arch="$(dpkg --print-architecture)"
  case "${arch}" in
    amd64) arch_key="amd64" ;;
    arm64) arch_key="arm64" ;;
    *) c_err "不支持架构: ${arch}"; return 1 ;;
  esac

  local api="https://api.github.com/repos/pmkol/mosdns-x/releases/latest"
  local json asset_name asset_url
  json="$(curl -fsSL "${api}")"

  asset_name="$(echo "${json}" | jq -r --arg a "${arch_key}" '
    .assets[]
    | select((.name|ascii_downcase|test("linux")) and (.name|ascii_downcase|test($a)) and ((.name|ascii_downcase|endswith(".zip")) or (.name|ascii_downcase|endswith(".tar.gz"))))
    | .name
  ' | head -n 1)"

  asset_url="$(echo "${json}" | jq -r --arg n "${asset_name}" '
    .assets[] | select(.name==$n) | .browser_download_url
  ')"

  [[ -n "${asset_name}" && -n "${asset_url}" && "${asset_url}" != "null" ]] || {
    c_err "未找到 mosdns-x 发行包"
    return 1
  }

  c_info "-> ${asset_name}"
  local tmpdir
  tmpdir="$(mktemp -d)"
  curl -fL --retry 3 --retry-delay 1 -o "${tmpdir}/${asset_name}" "${asset_url}"
  mkdir -p "${tmpdir}/out"

  if [[ "${asset_name,,}" == *.zip ]]; then
    unzip -q "${tmpdir}/${asset_name}" -d "${tmpdir}/out"
  else
    tar -xzf "${tmpdir}/${asset_name}" -C "${tmpdir}/out"
  fi

  local bin
  bin="$(find "${tmpdir}/out" -maxdepth 3 -type f \( -name "mosdns" -o -name "mosdns-x" \) | head -n 1 || true)"
  [[ -n "${bin}" ]] || { c_err "解压后未找到 mosdns 二进制"; rm -rf "${tmpdir}"; return 1; }

  install -m 0755 "${bin}" /usr/local/bin/mosdns
  rm -rf "${tmpdir}"

  c_ok "mosdns-x 安装完成: /usr/local/bin/mosdns"
  log_action "install mosdns-x"
}

create_user_and_dirs() {
  if ! id -u "${MOSDNS_USER}" >/dev/null 2>&1; then
    useradd --system --home "${WORK_DIR}" --shell /usr/sbin/nologin "${MOSDNS_USER}"
    c_ok "已创建用户: ${MOSDNS_USER}"
    log_action "create user ${MOSDNS_USER}"
  fi

  mkdir -p "${CONF_DIR}" "${WORK_DIR}" "${NGINX_SSL_DIR}" "${ACME_WEBROOT}" "${STATIC_ROOT}"
  chown -R "${MOSDNS_USER}:${MOSDNS_USER}" "${WORK_DIR}"
}

install_mosdns_systemd() {
  c_info "安装/修复 mosdns systemd 服务"
  cat > /etc/systemd/system/mosdns.service <<EOF
[Unit]
Description=mosdns-x (DoH backend)
After=network-online.target
Wants=network-online.target

[Service]
User=${MOSDNS_USER}
Group=${MOSDNS_USER}
WorkingDirectory=${WORK_DIR}
ExecStart=/usr/local/bin/mosdns start -c ${CONF_DIR}/config.yaml -d ${WORK_DIR}
Restart=on-failure
RestartSec=1s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable mosdns >/dev/null 2>&1 || true
  c_ok "mosdns systemd 已就绪"
  log_action "install systemd mosdns"
}

ensure_environment() {
  c_info "开始安装/修复环境"
  apt_install
  create_user_and_dirs
  ensure_allowlist_file
  download_and_install_mosdnsx
  install_mosdns_systemd
  c_ok "环境准备完成"
  log_action "ensure environment done"
}

write_unbound_forward() {
  c_info "写入 Unbound 配置: ${UNBOUND_SNIPPET}"
  backup_file "${UNBOUND_SNIPPET}"
  mkdir -p "$(dirname "${UNBOUND_SNIPPET}")"

  {
    echo "server:"
    echo "  interface: 127.0.0.1"
    echo "  port: ${UNBOUND_PORT}"
    echo "  access-control: 127.0.0.0/8 allow"
    echo ""
    echo "  msg-cache-size: ${UB_MSG_CACHE}"
    echo "  rrset-cache-size: ${UB_RRSET_CACHE}"
    echo "  cache-min-ttl: ${UB_MIN_TTL}"
    echo "  cache-max-ttl: ${UB_MAX_TTL}"
    echo "  prefetch: ${UB_PREFETCH}"
    echo "  prefetch-key: ${UB_PREFETCH}"
    echo ""
    echo "  serve-expired: ${UB_SERVE_EXPIRED}"
    echo "  serve-expired-ttl: ${UB_SERVE_EXPIRED_TTL}"
    echo "  serve-expired-reply-ttl: ${UB_SERVE_EXPIRED_REPLY_TTL}"
    echo ""
    echo "  do-ip6: ${UB_DO_IP6}"
    echo ""
    echo "  hide-identity: yes"
    echo "  hide-version: yes"
    echo "  qname-minimisation: yes"
    echo ""
    echo "forward-zone:"
    echo "  name: \".\""
    echo "  forward-tls-upstream: yes"
    for u in "${UPSTREAM_DOT[@]}"; do
      echo "  forward-addr: ${u}"
    done
  } > "${UNBOUND_SNIPPET}"

  unbound-checkconf >/dev/null 2>&1 || {
    c_err "unbound-checkconf 检查失败"
    exit 1
  }
  c_ok "Unbound 配置 OK"
  log_action "write unbound config"
}

build_domain_rules_from_allowlist() {
  ensure_allowlist_file

  local cnt
  cnt="$(allowlist_count)"
  if (( cnt <= 0 )); then
    c_err "allowlist.txt 为空: ${ALLOWLIST_FILE}"
    return 1
  fi

  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    {
      gsub(/\r/,"",$0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if (length($0)>0) print "        - \"domain:" $0 "\""
    }
  ' "${ALLOWLIST_FILE}"
}

write_mosdns_config() {
  c_info "写入 mosdns 配置: ${CONF_DIR}/config.yaml"
  mkdir -p "${CONF_DIR}"
  backup_file "${CONF_DIR}/config.yaml"

  local domain_rules
  domain_rules="$(build_domain_rules_from_allowlist)" || return 1

  local deny_action="_new_refused_response"
  if [[ "${DENY_MODE}" == "nxdomain" ]]; then
    deny_action="_new_nxdomain_response"
  fi

  cat > "${CONF_DIR}/config.yaml" <<EOF
log:
  level: ${MOS_LOG_LEVEL}

plugins:
  - tag: allow_list
    type: query_matcher
    args:
      domain:
${domain_rules}

  - tag: forward_local_unbound
    type: fast_forward
    args:
      upstream:
        - addr: "udp://127.0.0.1:${UNBOUND_PORT}"
          trusted: true
        - addr: "tcp://127.0.0.1:${UNBOUND_PORT}"
          trusted: true

  - tag: main_sequence
    type: sequence
    args:
      exec:
        - if: "! allow_list"
          exec:
            - ${deny_action}
            - _return
        - _default_cache
        - forward_local_unbound

servers:
  - exec: main_sequence
    listeners:
      - protocol: http
        addr: "${MOSDNS_HTTP_ADDR}"
        url_path: "${DOH_PATH}"
EOF

  c_ok "mosdns 配置 OK"
  log_action "write mosdns config"
}

write_nginx_site() {
  local nginx_site="${NGINX_SITE_DIR}/doh_${DOMAIN}.conf"
  local nginx_link="${NGINX_LINK_DIR}/doh_${DOMAIN}.conf"

  c_info "写入 Nginx 配置: ${nginx_site}"
  mkdir -p "${NGINX_SITE_DIR}" "${NGINX_LINK_DIR}" "${NGINX_SSL_DIR}" "${ACME_WEBROOT}" "${STATIC_ROOT}"
  backup_file "${nginx_site}"

  if [[ ! -f "${STATIC_ROOT}/index.html" ]]; then
    echo "${TEMPLATE_SIMPLE}" > "${STATIC_ROOT}/index.html"
  fi

  rm -f /etc/nginx/sites-enabled/default >/dev/null 2>&1 || true

  local http2_line=""
  if [[ "${NGX_HTTP2}" == "yes" ]]; then
    http2_line="http2"
  fi

  local limit_req_block=""
  if [[ "${NGX_LIMIT_REQ}" == "yes" ]]; then
    limit_req_block=$(cat <<EOF
  limit_req_zone \$binary_remote_addr zone=doh_zone:10m rate=${NGX_RPS}r/s;
EOF
)
  fi

  local limit_req_apply=""
  if [[ "${NGX_LIMIT_REQ}" == "yes" ]]; then
    limit_req_apply=$(cat <<EOF
    limit_req zone=doh_zone burst=${NGX_BURST} nodelay;
EOF
)
  fi

  cat > "${nginx_site}" <<EOF
${limit_req_block}
server {
  listen 80;
  server_name ${DOMAIN};

  location ^~ /.well-known/acme-challenge/ {
    root ${ACME_WEBROOT};
    default_type "text/plain";
    try_files \$uri =404;
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}

server {
  listen 443 ssl ${http2_line};
  server_name ${DOMAIN};

  ssl_certificate     ${NGINX_SSL_DIR}/fullchain.pem;
  ssl_certificate_key ${NGINX_SSL_DIR}/${DOMAIN}.key;
  ssl_protocols TLSv1.2 TLSv1.3;

  location = ${DOH_PATH} {
${limit_req_apply}
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_buffering off;
    proxy_pass http://${MOSDNS_HTTP_ADDR};
  }

  location / {
    root ${STATIC_ROOT};
    try_files \$uri \$uri/ =404;
  }
}
EOF

  ln -sf "${nginx_site}" "${nginx_link}"
  nginx -t >/dev/null
  c_ok "Nginx 配置 OK"
  log_action "write nginx site"
}

reload_services() {
  c_info "重载服务: unbound / mosdns / nginx"
  systemctl restart unbound >/dev/null 2>&1 || true
  systemctl restart mosdns  >/dev/null 2>&1 || true
  systemctl reload nginx    >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
  c_ok "服务重载完成"
  log_action "reload services"
}

start_services() {
  c_info "启动服务: unbound / mosdns / nginx"
  systemctl start unbound >/dev/null 2>&1 || true
  systemctl start mosdns  >/dev/null 2>&1 || true
  systemctl start nginx   >/dev/null 2>&1 || true
  c_ok "启动完成"
  log_action "start services"
}

stop_services() {
  c_info "停止服务: mosdns / unbound / nginx"
  systemctl stop mosdns  >/dev/null 2>&1 || true
  systemctl stop unbound >/dev/null 2>&1 || true
  systemctl stop nginx   >/dev/null 2>&1 || true
  c_ok "停止完成"
  log_action "stop services"
}

restart_services() {
  c_info "重启服务: unbound / mosdns / nginx"
  systemctl restart unbound >/dev/null 2>&1 || true
  systemctl restart mosdns  >/dev/null 2>&1 || true
  systemctl restart nginx   >/dev/null 2>&1 || true
  c_ok "重启完成"
  log_action "restart services"
}

apply_all() {
  doh_path_conflict_check || {
    c_err "检测未通过，已阻止应用"
    return
  }

  ensure_allowlist_file
  local cnt
  cnt="$(allowlist_count)"
  if (( cnt <= 0 )); then
    c_err "allowlist.txt 为空，已阻止应用"
    return
  fi

  if [[ ! -x /usr/local/bin/mosdns ]]; then
    c_warn "检测到 mosdns 未安装，建议先执行安装/修复"
  fi
  if [[ ! -f /etc/systemd/system/mosdns.service ]]; then
    c_warn "检测到 mosdns.service 不存在，建议先执行安装/修复"
  fi

  c_info "生成配置并应用..."
  write_unbound_forward
  write_mosdns_config
  write_nginx_site
  reload_services
  c_ok "本机应用完成"
  log_action "apply all done"
}

service_status_summary() {
  local failed=0

  echo "==================== 服务状态检查 ===================="

  for svc in mosdns unbound nginx; do
    if systemctl is-active --quiet "${svc}"; then
      c_ok "${svc} 正在正常运行中"
    else
      c_err "${svc} 未正常运行"
      failed=1
      echo "原因摘要："
      systemctl --no-pager --full status "${svc}" 2>/dev/null | sed -n '1,12p' || true
      echo "最近日志："
      journalctl -u "${svc}" -n 8 --no-pager 2>/dev/null || true
      echo "------------------------------------------------------"
    fi
  done

  if (( failed == 0 )); then
    c_ok "结论：全部服务正在正常运行中"
  else
    c_warn "结论：存在异常服务，请根据上面的原因摘要排查"
  fi
}

show_ports_summary() {
  echo "==================== 端口监听检查 ===================="

  local failed=0
  local ports=(80 443 8053 "${UNBOUND_PORT}")

  for p in "${ports[@]}"; do
    if ss -lntp 2>/dev/null | grep -q ":${p} "; then
      c_ok "端口 ${p} 正在监听"
    else
      c_err "端口 ${p} 未监听"
      failed=1
    fi
  done

  echo
  if (( failed == 0 )); then
    c_ok "结论：端口监听一切正常"
  else
    c_warn "结论：存在未监听端口，请检查对应服务是否启动或配置是否生效"
  fi

  echo
  ss -lntp | egrep ":80|:443|:8053|:${UNBOUND_PORT}" || true
}

health_check_summary() {
  echo "==================== 健康检查 ===================="

  local failed=0

  if ! command -v curl >/dev/null 2>&1; then
    c_err "未安装 curl，无法执行健康检查"
    return 1
  fi

  local homepage_code doh_code
  homepage_code="$(curl -k -sS -o /dev/null -w "%{http_code}" "https://${DOMAIN}/" || echo "000")"
  doh_code="$(curl -k -sS -o /dev/null -w "%{http_code}" "https://${DOMAIN}${DOH_PATH}" || echo "000")"

  if [[ "${homepage_code}" =~ ^(200|301|302|404)$ ]]; then
    c_ok "伪装页访问正常，HTTP_CODE=${homepage_code}"
  else
    c_err "伪装页访问异常，HTTP_CODE=${homepage_code}"
    failed=1
  fi

  if [[ "${doh_code}" =~ ^(200|400|405)$ ]]; then
    c_ok "DoH 路径访问正常，HTTP_CODE=${doh_code}"
  else
    c_err "DoH 路径访问异常，HTTP_CODE=${doh_code}"
    failed=1
  fi

  if (( failed == 0 )); then
    c_ok "结论：健康检查一切正常"
  else
    c_warn "结论：健康检查存在异常，请检查域名解析、证书、Nginx 与 mosdns 配置"
  fi
}

check_cert_days() {
  local pem="${NGINX_SSL_DIR}/fullchain.pem"
  if [[ ! -f "${pem}" ]]; then
    c_err "找不到证书: ${pem}"
    return
  fi

  local end_date end_ts now_ts diff_days
  end_date="$(openssl x509 -in "${pem}" -noout -enddate 2>/dev/null | cut -d= -f2-)"
  if [[ -z "${end_date}" ]]; then
    c_err "无法读取证书到期时间"
    return
  fi

  end_ts="$(date -d "${end_date}" +%s 2>/dev/null || true)"
  now_ts="$(date +%s)"

  if [[ -z "${end_ts}" ]]; then
    c_err "无法解析证书时间格式"
    echo "原始到期时间: ${end_date}"
    return
  fi

  diff_days=$(( (end_ts - now_ts) / 86400 ))

  echo "==================== 证书有效期检查 ===================="
  echo "证书路径: ${pem}"
  echo "到期时间: ${end_date}"

  if (( end_ts > now_ts )); then
    c_ok "证书仍在有效期内"
    c_info "距离过期还有 ${diff_days} 天"
  else
    c_err "证书已经过期"
    c_warn "距离过期已超过 $(( -diff_days )) 天"
  fi
}

uninstall_all() {
  c_warn "你即将执行【彻底卸载】"
  echo "将删除以下内容："
  echo " - mosdns 服务"
  echo " - ${CONF_DIR}"
  echo " - ${WORK_DIR}"
  echo " - ${UNBOUND_SNIPPET}"
  echo " - ${NGINX_SITE_DIR}/doh_${DOMAIN}.conf"
  echo " - ${NGINX_LINK_DIR}/doh_${DOMAIN}.conf"
  echo " - ${NGINX_SSL_DIR}"
  echo " - /usr/local/bin/mosdns"
  echo
  read -r -p "请输入 YES 确认彻底卸载: " confirm
  [[ "${confirm}" == "YES" ]] || { c_warn "已取消卸载"; return; }

  log_action "begin uninstall all"

  systemctl stop mosdns 2>/dev/null || true
  systemctl disable mosdns 2>/dev/null || true

  remove_if_exists "/etc/systemd/system/mosdns.service"
  systemctl daemon-reload

  remove_if_exists "${CONF_DIR}"
  remove_if_exists "${WORK_DIR}"
  remove_if_exists "${UNBOUND_SNIPPET}"
  remove_if_exists "${NGINX_LINK_DIR}/doh_${DOMAIN}.conf"
  remove_if_exists "${NGINX_SITE_DIR}/doh_${DOMAIN}.conf"
  remove_if_exists "${NGINX_SSL_DIR}"
  remove_if_exists "/usr/local/bin/mosdns"

  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  unbound-checkconf >/dev/null 2>&1 && systemctl restart unbound >/dev/null 2>&1 || true

  c_ok "彻底卸载完成"
  log_action "uninstall all done"
}

show_menu() {
  cat <<EOF
==================== DoH Manager PRO ${SCRIPT_VERSION} ====================

 1. 安装/修复环境            2. 快速初始化向导
 3. 显示当前配置            4. 修改 DOMAIN
 5. 修改 DOH_PATH           6. 修改 allowlist 路径

 7. 查看 allowlist          8. 新增 allowlist 项
 9. 删除 allowlist 项       10. 批量导入 allowlist
11. 编辑 allowlist(vim)     12. allowlist 去重排序

13. 查看上游 DoT            14. 新增上游 DoT
15. 删除上游 DoT            16. 编辑 Unbound 参数
17. 编辑 mosdns 参数        18. 编辑 Nginx 参数

19. 路径冲突检测            20. 生成配置并应用
21. 签发证书                22. 强制续期证书
23. 查看证书有效期          24. 查看服务状态

25. 查看端口监听            26. 健康检查
27. 查看日志尾部            28. 启动服务
29. 停止服务                30. 重启服务

31. 彻底卸载                99. 退出

=========================================================================
EOF
}

main() {
  need_root
  ensure_state_file
  load_state
  ensure_allowlist_file

  log_action "run doh-manager-pro-allinone.sh"
  show_brief_runtime_status

  if [[ "${FIRST_RUN}" == "yes" ]]; then
    echo
    read -r -p "检测到首次运行，是否进入快速初始化向导？(y/n): " first_run_wizard
    case "${first_run_wizard}" in
      y|Y) quick_setup_wizard ;;
      *) c_info "已跳过快速初始化向导" ;;
    esac
  fi

  while true; do
    show_menu
    read -r -p "请选择操作: " opt
    echo
    case "${opt}" in
      1) ensure_environment ;;
      2) quick_setup_wizard ;;

      3) show_config ;;
      4) set_domain ;;
      5) set_doh_path ;;
      6) set_allowlist_file ;;

      7) show_allowlist ;;
      8) add_allowlist_one ;;
      9) remove_allowlist_one ;;
      10) batch_import_allowlist ;;
      11) edit_allowlist_vim ;;
      12) allowlist_dedupe_sort ;;

      13) list_upstreams ;;
      14) add_upstream ;;
      15) remove_upstream ;;
      16) edit_unbound_params ;;
      17) edit_mosdns_params ;;
      18) edit_nginx_params ;;

      19) doh_path_conflict_check ;;
      20)
        if check_domain_cert_before_apply; then
          apply_all
        fi
        ;;

      21) issue_cert ;;
      22) renew_cert ;;
      23) check_cert_days ;;
      24) service_status_summary ;;

      25) show_ports_summary ;;
      26) health_check_summary ;;
      27) show_logs_tail ;;
      28) start_services ;;
      29) stop_services ;;
      30) restart_services ;;

      31) uninstall_all ;;

      99) c_ok "退出"; log_action "exit"; exit 0 ;;
      *) c_warn "无效选项" ;;
    esac
    pause_enter
  done
}

main "$@"
