#!/usr/bin/env bash
set -euo pipefail

############################################
# DoH Manager PRO (All-in-One + allowlist.txt)
# Version: v2.1
# mosdns-x + unbound + nginx + acme.sh
#
# ✅ v2.1 修复：
# 1) 修复 bash 数组长度判断 bad substitution 问题
# 2) 保留 v2.0 的启动/停止/重启/彻底卸载功能
############################################

# ==========================================================
# 固定路径（与原部署脚本一致）
# ==========================================================
SCRIPT_VERSION="v2.1"

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

# ========== 彩色输出 ==========
c_ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
c_warn() { echo -e "\033[1;33m[!]\033[0m  $*"; }
c_err()  { echo -e "\033[1;31m[-]\033[0m $*"; }
c_info() { echo -e "\033[1;36m[i]\033[0m  $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    c_err "请使用 root 运行此脚本"
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

# ==========================================================
# 开源安全默认参数（首次运行写入 STATE_FILE）
# ==========================================================
DEFAULT_DOMAIN="example.com"
DEFAULT_DOH_PATH="/dns-query"

DEFAULT_UPSTREAM_DOT=(
  "1.1.1.1@853"
  "8.8.8.8@853"
)

# ---------- A) Unbound 参数默认 ----------
DEFAULT_UB_MSG_CACHE="64m"
DEFAULT_UB_RRSET_CACHE="128m"
DEFAULT_UB_MIN_TTL="60"
DEFAULT_UB_MAX_TTL="86400"
DEFAULT_UB_PREFETCH="yes"
DEFAULT_UB_SERVE_EXPIRED="yes"
DEFAULT_UB_SERVE_EXPIRED_TTL="3600"
DEFAULT_UB_SERVE_EXPIRED_REPLY_TTL="30"
DEFAULT_UB_DO_IP6="no"

# ---------- B) mosdns 参数默认 ----------
DEFAULT_MOS_LOG_LEVEL="info"
DEFAULT_DENY_MODE="refused"

# ---------- C) nginx 参数默认 ----------
DEFAULT_NGX_HTTP2="yes"
DEFAULT_NGX_LIMIT_REQ="no"
DEFAULT_NGX_RPS="20"
DEFAULT_NGX_BURST="40"

# ---------- PRO: 双机同步默认 ----------
DEFAULT_SYNC_ENABLE="no"
DEFAULT_SYNC_CERTS="no"
DEFAULT_PEERS=()

# ---------- 伪装首页模板 ----------
TEMPLATE_SIMPLE='<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>OK</title></head><body><h1>OK</h1></body></html>'
TEMPLATE_404='<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>404 Not Found</title></head><body><h1>404 Not Found</h1></body></html>'
TEMPLATE_MINIMAL='<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Welcome</title></head><body>Welcome</body></html>'

# ==========================================================
# 当前参数（从 STATE_FILE 读取）
# ==========================================================
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

SYNC_ENABLE=""
SYNC_CERTS=""
PEERS=()

NGINX_SSL_DIR=""

# ==========================================================
# 状态文件读写
# ==========================================================
ensure_state_file() {
  mkdir -p "$(dirname "${STATE_FILE}")"
  if [[ ! -f "${STATE_FILE}" ]]; then
    c_warn "未发现状态文件，初始化：${STATE_FILE}"
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

      echo "SYNC_ENABLE=\"${DEFAULT_SYNC_ENABLE}\""
      echo "SYNC_CERTS=\"${DEFAULT_SYNC_CERTS}\""
      echo "PEERS=("
      for p in "${DEFAULT_PEERS[@]}"; do
        echo "  \"${p}\""
      done
      echo ")"
    } > "${STATE_FILE}"
    c_ok "初始化完成（开源安全默认值）"
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

  SYNC_ENABLE="${SYNC_ENABLE:-${DEFAULT_SYNC_ENABLE}}"
  SYNC_CERTS="${SYNC_CERTS:-${DEFAULT_SYNC_CERTS}}"

  if (( ${#PEERS[@]} <= 0 )); then
    PEERS=("${DEFAULT_PEERS[@]}")
  fi
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

    echo "SYNC_ENABLE=\"${SYNC_ENABLE}\""
    echo "SYNC_CERTS=\"${SYNC_CERTS}\""
    echo "PEERS=("
    for p in "${PEERS[@]}"; do echo "  \"${p}\""; done
    echo ")"
  } > "${STATE_FILE}"

  c_ok "已保存状态：${STATE_FILE}"
  log_action "save state"
}

# ==========================================================
# allowlist.txt 管理
# ==========================================================
ensure_allowlist_file() {
  mkdir -p "$(dirname "${ALLOWLIST_FILE}")"
  if [[ ! -f "${ALLOWLIST_FILE}" ]]; then
    c_warn "未发现 allowlist.txt，初始化：${ALLOWLIST_FILE}"
    cat > "${ALLOWLIST_FILE}" <<EOF
# allowlist.txt
# 每行一个域名/后缀（匹配该域名及其子域）
# 支持注释：以 # 开头
#
# 示例：
# example.com
# api.example.com
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
  tmp="/tmp/allowlist.$$.tmp"
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
  read -r -p "请输入要新增的域名/后缀（例如 example.com）： " s
  [[ -n "${s}" ]] || { c_warn "未输入，取消"; return; }
  s="$(echo "${s}" | tr -d '\r' | sed -e 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"
  [[ -n "${s}" ]] || { c_warn "空输入，取消"; return; }

  if grep -qxF "${s}" "${ALLOWLIST_FILE}" 2>/dev/null; then
    c_warn "已存在：${s}"
    return
  fi

  echo "${s}" >> "${ALLOWLIST_FILE}"
  allowlist_dedupe_sort
  c_ok "已新增：${s}"
  log_action "allowlist add ${s}"
}

remove_allowlist_one() {
  ensure_allowlist_file
  show_allowlist
  read -r -p "请输入要删除的域名/后缀（完整匹配）： " s
  [[ -n "${s}" ]] || { c_warn "未输入，取消"; return; }

  if ! grep -qxF "${s}" "${ALLOWLIST_FILE}" 2>/dev/null; then
    c_warn "未找到：${s}"
    return
  fi

  tmp="/tmp/allowlist.rm.$$.tmp"
  grep -vxF "${s}" "${ALLOWLIST_FILE}" > "${tmp}" || true
  mv "${tmp}" "${ALLOWLIST_FILE}"
  allowlist_dedupe_sort
  c_ok "已删除：${s}"
  log_action "allowlist remove ${s}"
}

# ==========================================================
# 批量导入 allowlist
# ==========================================================
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
  c_info "批量导入 allowlist.txt（支持 domain:/DOMAIN-SUFFIX/YAML/JSON 等）"
  echo
  echo "请粘贴域名列表（可多行），粘贴完后输入一行：END 结束"
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

  c_ok "导入完成：新增 ${added} 条；原有 ${before} -> 现在 ${after}"
  log_action "batch import allowlist added=${added} total=${after}"
}

# ==========================================================
# 显示配置
# ==========================================================
show_config() {
  echo "==================== 关键参数（主线） ===================="
  echo "版本            : ${SCRIPT_VERSION}"
  echo "DOMAIN          : ${DOMAIN}         (DoH 域名 / 伪装域名)"
  echo "DOH_PATH        : ${DOH_PATH}       (伪装路径 / DoH Path)"
  echo "ALLOWLIST_FILE  : ${ALLOWLIST_FILE} (白名单文件路径)"
  echo "ALLOWLIST_CNT   : $(allowlist_count)"
  echo
  echo "UPSTREAM_DOT (Unbound 上游DoT)："
  for u in "${UPSTREAM_DOT[@]}"; do echo "  - ${u}"; done
  echo "========================================================="
  echo
  echo "==================== PRO: 同步参数 ======================="
  echo "SYNC_ENABLE     : ${SYNC_ENABLE}   (yes/no)"
  echo "SYNC_CERTS      : ${SYNC_CERTS}    (yes/no)"
  echo "PEERS："
  if [[ "${#PEERS[@]}" -eq 0 ]]; then
    echo "  - (空) 你还没添加对端机器"
  else
    for p in "${PEERS[@]}"; do echo "  - ${p}"; done
  fi
  echo "========================================================="
  echo
  echo "伪装站: https://${DOMAIN}/"
  echo "DoH    : https://${DOMAIN}${DOH_PATH}"
  echo "日志   : ${LOG_FILE}"
  echo
}

# ==========================================================
# DoH 路径冲突检测
# ==========================================================
doh_path_conflict_check() {
  c_info "DoH 路径冲突检测..."

  if [[ "${DOH_PATH:0:1}" != "/" ]]; then
    c_err "DOH_PATH 必须以 / 开头：当前 ${DOH_PATH}"
    return 1
  fi

  if [[ "${DOH_PATH}" == "/" ]]; then
    c_err "DOH_PATH 不能是 /（会与伪装站根路径冲突）"
    return 1
  fi

  if [[ "${DOH_PATH}" == "/.well-known/acme-challenge/"* ]]; then
    c_err "DOH_PATH 与 ACME HTTP-01 冲突：${DOH_PATH}"
    return 1
  fi

  local static_file="${STATIC_ROOT}${DOH_PATH}"
  if [[ -f "${static_file}" ]]; then
    c_warn "STATIC_ROOT 中存在同名文件：${static_file}"
    c_warn "虽 Nginx 用 location = 精确匹配通常不会走静态，但不建议这样配置。"
  fi

  if [[ "${DOH_PATH}" != */*.* ]]; then
    c_warn "DOH_PATH 不像资源路径（如 /static/logo.png），伪装特征可能偏弱：${DOH_PATH}"
  fi

  c_ok "路径冲突检测通过"
  return 0
}

# ==========================================================
# 0) 安装/修复环境（All-in-One）
# ==========================================================
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget jq unzip tar \
    nginx openssl socat \
    unbound rsync
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl enable unbound >/dev/null 2>&1 || true
  c_ok "依赖安装完成（nginx/unbound/rsync/curl/jq...）"
  log_action "apt install deps"
}

create_user_and_dirs() {
  if ! id -u "${MOSDNS_USER}" >/dev/null 2>&1; then
    useradd --system --home "${WORK_DIR}" --shell /usr/sbin/nologin "${MOSDNS_USER}"
    c_ok "已创建用户：${MOSDNS_USER}"
    log_action "create user ${MOSDNS_USER}"
  fi

  mkdir -p "${CONF_DIR}" "${WORK_DIR}" "${NGINX_SSL_DIR}" "${ACME_WEBROOT}" "${STATIC_ROOT}"
  chown -R "${MOSDNS_USER}:${MOSDNS_USER}" "${WORK_DIR}"
}

download_and_install_mosdnsx() {
  c_info "安装/更新 mosdns-x (latest release)..."

  local arch arch_key
  arch="$(dpkg --print-architecture)"
  case "${arch}" in
    amd64) arch_key="amd64" ;;
    arm64) arch_key="arm64" ;;
    *) c_err "不支持架构: ${arch}（仅支持 amd64/arm64）"; return 1 ;;
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
    c_err "没找到匹配的 mosdns-x 资产（linux/${arch_key}）"
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

  c_ok "mosdns-x 安装/更新完成：/usr/local/bin/mosdns"
  log_action "install mosdns-x"
}

install_mosdns_systemd() {
  c_info "安装/修复 mosdns systemd 服务..."
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
  c_info "开始安装/修复环境（All-in-One）..."
  apt_install
  create_user_and_dirs
  ensure_allowlist_file
  download_and_install_mosdnsx
  install_mosdns_systemd
  c_ok "环境准备完成 ✅"
  log_action "ensure environment done"
}

# ==========================================================
# A) 写入 Unbound 配置
# ==========================================================
write_unbound_forward() {
  c_info "写入 Unbound 配置：${UNBOUND_SNIPPET}"
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
    c_err "unbound-checkconf 检查失败，请检查 ${UNBOUND_SNIPPET}"
    exit 1
  }
  c_ok "Unbound 配置 OK"
  log_action "write unbound config"
}

# ==========================================================
# B) 写入 mosdns 配置（从 allowlist.txt 读取）
# ==========================================================
build_domain_rules_from_allowlist() {
  ensure_allowlist_file

  local cnt
  cnt="$(allowlist_count)"
  if (( cnt <= 0 )); then
    c_err "allowlist.txt 为空：${ALLOWLIST_FILE}"
    c_err "请先添加至少 1 条域名/后缀，再应用配置"
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
  c_info "写入 mosdns-x 配置：${CONF_DIR}/config.yaml"
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

  c_ok "mosdns-x 配置 OK（allowlist.txt 已生效）"
  log_action "write mosdns config"
}

# ==========================================================
# C) 写入 Nginx 配置
# ==========================================================
write_nginx_site() {
  local nginx_site="${NGINX_SITE_DIR}/doh_${DOMAIN}.conf"
  local nginx_link="${NGINX_LINK_DIR}/doh_${DOMAIN}.conf"

  c_info "写入 Nginx 配置：${nginx_site}"
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
  c_info "重载服务：unbound / mosdns / nginx"
  systemctl restart unbound >/dev/null 2>&1 || true
  systemctl restart mosdns  >/dev/null 2>&1 || true
  systemctl reload nginx    >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
  c_ok "服务重载完成"
  log_action "reload services"
}

start_services() {
  c_info "启动服务：unbound / mosdns / nginx"
  systemctl start unbound >/dev/null 2>&1 || true
  systemctl start mosdns  >/dev/null 2>&1 || true
  systemctl start nginx   >/dev/null 2>&1 || true
  c_ok "启动完成"
  log_action "start services"
}

stop_services() {
  c_info "停止服务：mosdns / unbound / nginx"
  systemctl stop mosdns  >/dev/null 2>&1 || true
  systemctl stop unbound >/dev/null 2>&1 || true
  systemctl stop nginx   >/dev/null 2>&1 || true
  c_ok "停止完成"
  log_action "stop services"
}

restart_services() {
  c_info "重启服务：unbound / mosdns / nginx"
  systemctl restart unbound >/dev/null 2>&1 || true
  systemctl restart mosdns  >/dev/null 2>&1 || true
  systemctl restart nginx   >/dev/null 2>&1 || true
  c_ok "重启完成"
  log_action "restart services"
}

health_check() {
  c_info "健康检查（伪装页 + DoH HTTP CODE）..."
  echo
  if command -v curl >/dev/null 2>&1; then
    echo "1) 伪装页："
    curl -k -sS "https://${DOMAIN}/" | head -n 2 || true
    echo
    echo "2) DoH 路径："
    curl -k -sS -o /dev/null -w "HTTP_CODE=%{http_code}\n" "https://${DOMAIN}${DOH_PATH}" || true
    echo
  else
    c_warn "curl 未安装，跳过"
  fi
}

# ==========================================================
# D) 证书管理（acme.sh）
# ==========================================================
acme_sh_path() { echo "/root/.acme.sh/acme.sh"; }

ensure_acme_sh() {
  if [[ ! -d /root/.acme.sh ]]; then
    c_info "安装 acme.sh..."
    curl -fsSL https://get.acme.sh | sh
    c_ok "acme.sh 安装完成"
    log_action "install acme.sh"
  fi
}

write_nginx_http_only_for_acme() {
  local nginx_site="${NGINX_SITE_DIR}/doh_${DOMAIN}.conf"
  local nginx_link="${NGINX_LINK_DIR}/doh_${DOMAIN}.conf"

  c_info "临时写入 Nginx(80) 仅用于 ACME..."
  mkdir -p "${NGINX_SITE_DIR}" "${NGINX_LINK_DIR}" "${ACME_WEBROOT}"

  cat > "${nginx_site}" <<EOF
server {
  listen 80;
  server_name ${DOMAIN};

  location ^~ /.well-known/acme-challenge/ {
    root ${ACME_WEBROOT};
    default_type "text/plain";
    try_files \$uri =404;
  }

  location / {
    return 200 "OK";
  }
}
EOF

  ln -sf "${nginx_site}" "${nginx_link}"
  nginx -t >/dev/null
  systemctl restart nginx >/dev/null 2>&1 || true
  c_ok "ACME HTTP-01 环境准备完成"
}

issue_cert() {
  ensure_acme_sh
  local ACME
  ACME="$(acme_sh_path)"

  c_info "签发证书（Let’s Encrypt + HTTP-01 webroot）"
  mkdir -p "${ACME_WEBROOT}" "${NGINX_SSL_DIR}"

  write_nginx_http_only_for_acme

  "${ACME}" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

  "${ACME}" --issue --server letsencrypt -d "${DOMAIN}" --webroot "${ACME_WEBROOT}" --keylength 2048
  "${ACME}" --install-cert --server letsencrypt -d "${DOMAIN}" \
    --key-file       "${NGINX_SSL_DIR}/${DOMAIN}.key" \
    --fullchain-file "${NGINX_SSL_DIR}/fullchain.pem" \
    --reloadcmd     "systemctl reload nginx"

  c_ok "证书签发/安装完成：${NGINX_SSL_DIR}"
  log_action "issue cert for ${DOMAIN}"
}

renew_cert() {
  ensure_acme_sh
  local ACME
  ACME="$(acme_sh_path)"

  c_info "续期证书（acme.sh --renew）"
  "${ACME}" --renew -d "${DOMAIN}" --force >/dev/null 2>&1 || true
  c_ok "续期完成"
  systemctl reload nginx >/dev/null 2>&1 || true
  log_action "renew cert for ${DOMAIN}"
}

check_cert_days() {
  local pem="${NGINX_SSL_DIR}/fullchain.pem"
  if [[ ! -f "${pem}" ]]; then
    c_warn "找不到证书：${pem}"
    return
  fi
  c_info "证书有效期："
  openssl x509 -in "${pem}" -noout -dates || true
}

# ==========================================================
# 交互：关键参数修改
# ==========================================================
set_domain() {
  echo "当前 DOMAIN: ${DOMAIN}"
  read -r -p "请输入新的 DOMAIN（例如 doh.example.com）： " newd
  [[ -n "${newd}" ]] || { c_warn "未输入，取消"; return; }
  DOMAIN="${newd}"
  NGINX_SSL_DIR="/etc/nginx/ssl/${DOMAIN}"
  c_ok "DOMAIN 已设置为: ${DOMAIN}"
  c_warn "注意：换 DOMAIN 后必须重新申请证书，否则 443 会失败。"
  log_action "set DOMAIN=${DOMAIN}"
  save_state
}

set_doh_path() {
  echo "当前 DOH_PATH: ${DOH_PATH}"
  read -r -p "请输入新的 DOH_PATH（必须以 / 开头，例如 /static/logo.png）： " p
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
  echo "当前 allowlist.txt 路径: ${ALLOWLIST_FILE}"
  read -r -p "请输入新的 allowlist.txt 路径（回车取消）： " p
  [[ -n "${p}" ]] || { c_warn "未输入，取消"; return; }
  ALLOWLIST_FILE="${p}"
  ensure_allowlist_file
  c_ok "ALLOWLIST_FILE 已设置为: ${ALLOWLIST_FILE}"
  log_action "set ALLOWLIST_FILE=${ALLOWLIST_FILE}"
  save_state
}

list_upstreams() {
  echo "UPSTREAM_DOT 当前列表："
  local i=1
  for u in "${UPSTREAM_DOT[@]}"; do
    echo "  [$i] ${u}"
    i=$((i+1))
  done
}

add_upstream() {
  read -r -p "请输入要新增的 DoT 上游（格式 1.1.1.1@853）： " u
  [[ -n "${u}" ]] || { c_warn "未输入，取消"; return; }
  for x in "${UPSTREAM_DOT[@]}"; do
    if [[ "${x}" == "${u}" ]]; then
      c_warn "已存在：${u}"
      return
    fi
  done
  UPSTREAM_DOT+=("${u}")
  c_ok "已新增：${u}"
  log_action "add UPSTREAM_DOT+=${u}"
  save_state
}

remove_upstream() {
  list_upstreams
  read -r -p "请输入要删除的序号： " idx
  [[ "${idx}" =~ ^[0-9]+$ ]] || { c_err "请输入数字序号"; return; }
  local n="${#UPSTREAM_DOT[@]}"
  if (( idx < 1 || idx > n )); then
    c_err "超出范围"
    return
  fi
  local target="${UPSTREAM_DOT[$((idx-1))]}"
  UPSTREAM_DOT=( "${UPSTREAM_DOT[@]:0:$((idx-1))}" "${UPSTREAM_DOT[@]:$idx}" )
  c_ok "已删除：${target}"
  log_action "remove UPSTREAM_DOT-=${target}"
  save_state
}

# ==========================================================
# A/B/C 参数编辑
# ==========================================================
edit_unbound_params() {
  echo "==================== A) Unbound 参数编辑 ===================="
  echo "1) msg-cache-size           (当前: ${UB_MSG_CACHE})"
  echo "2) rrset-cache-size         (当前: ${UB_RRSET_CACHE})"
  echo "3) cache-min-ttl            (当前: ${UB_MIN_TTL})"
  echo "4) cache-max-ttl            (当前: ${UB_MAX_TTL})"
  echo "5) prefetch (yes/no)        (当前: ${UB_PREFETCH})"
  echo "6) serve-expired (yes/no)   (当前: ${UB_SERVE_EXPIRED})"
  echo "7) serve-expired-ttl        (当前: ${UB_SERVE_EXPIRED_TTL})"
  echo "8) serve-expired-reply-ttl  (当前: ${UB_SERVE_EXPIRED_REPLY_TTL})"
  echo "9) do-ip6 (yes/no)          (当前: ${UB_DO_IP6})"
  echo "0) 返回"
  echo "============================================================="
  read -r -p "选择: " opt

  case "${opt}" in
    1) read -r -p "输入 msg-cache-size(例 64m): " v; [[ -n "${v}" ]] && UB_MSG_CACHE="${v}" ;;
    2) read -r -p "输入 rrset-cache-size(例 128m): " v; [[ -n "${v}" ]] && UB_RRSET_CACHE="${v}" ;;
    3) read -r -p "输入 cache-min-ttl(秒): " v; [[ -n "${v}" ]] && UB_MIN_TTL="${v}" ;;
    4) read -r -p "输入 cache-max-ttl(秒): " v; [[ -n "${v}" ]] && UB_MAX_TTL="${v}" ;;
    5) read -r -p "输入 prefetch yes/no: " v; [[ -n "${v}" ]] && UB_PREFETCH="${v}" ;;
    6) read -r -p "输入 serve-expired yes/no: " v; [[ -n "${v}" ]] && UB_SERVE_EXPIRED="${v}" ;;
    7) read -r -p "输入 serve-expired-ttl(秒): " v; [[ -n "${v}" ]] && UB_SERVE_EXPIRED_TTL="${v}" ;;
    8) read -r -p "输入 serve-expired-reply-ttl(秒): " v; [[ -n "${v}" ]] && UB_SERVE_EXPIRED_REPLY_TTL="${v}" ;;
    9) read -r -p "输入 do-ip6 yes/no: " v; [[ -n "${v}" ]] && UB_DO_IP6="${v}" ;;
    0) return ;;
    *) c_warn "无效选项" ;;
  esac

  c_ok "已更新 Unbound 参数（未应用，需执行“应用配置”）"
  log_action "edit Unbound params"
  save_state
}

edit_mosdns_params() {
  echo "==================== B) mosdns 参数编辑 ====================="
  echo "1) log.level (info/debug/warn/error)  (当前: ${MOS_LOG_LEVEL})"
  echo "2) deny-mode 非白名单策略            (当前: ${DENY_MODE})"
  echo "   - refused  : 直接拒绝（更硬）"
  echo "   - nxdomain : 返回不存在（更兼容某些客户端）"
  echo "0) 返回"
  echo "============================================================="
  read -r -p "选择: " opt

  case "${opt}" in
    1) read -r -p "输入日志级别: " v; [[ -n "${v}" ]] && MOS_LOG_LEVEL="${v}" ;;
    2) read -r -p "输入 deny-mode (refused/nxdomain): " v; [[ -n "${v}" ]] && DENY_MODE="${v}" ;;
    0) return ;;
    *) c_warn "无效选项" ;;
  esac

  c_ok "已更新 mosdns 参数（未应用，需执行“应用配置”）"
  log_action "edit mosdns params"
  save_state
}

choose_html_template() {
  echo "========= 伪装首页模板 ========="
  echo "1) Simple OK (默认)"
  echo "2) Fake 404"
  echo "3) Minimal Welcome"
  echo "4) 手动编辑（vim）"
  echo "0) 返回"
  echo "==============================="
  read -r -p "选择: " opt

  mkdir -p "${STATIC_ROOT}"
  case "${opt}" in
    1) echo "${TEMPLATE_SIMPLE}" > "${STATIC_ROOT}/index.html"; c_ok "已应用 Simple OK 模板" ;;
    2) echo "${TEMPLATE_404}" > "${STATIC_ROOT}/index.html"; c_ok "已应用 Fake 404 模板" ;;
    3) echo "${TEMPLATE_MINIMAL}" > "${STATIC_ROOT}/index.html"; c_ok "已应用 Minimal Welcome 模板" ;;
    4)
      if [[ ! -f "${STATIC_ROOT}/index.html" ]]; then
        echo "${TEMPLATE_SIMPLE}" > "${STATIC_ROOT}/index.html"
      fi
      c_warn "使用 vim 编辑（保存 :wq，退出 :q）"
      sleep 1
      vim "${STATIC_ROOT}/index.html"
      c_ok "已保存 index.html"
      ;;
    0) return ;;
    *) c_warn "无效选项" ;;
  esac

  log_action "update index.html template"
}

edit_nginx_params() {
  echo "==================== C) Nginx 参数编辑 ======================"
  echo "1) http2 开关 (yes/no)            (当前: ${NGX_HTTP2})"
  echo "2) limit_req 防刷开关 (yes/no)    (当前: ${NGX_LIMIT_REQ})"
  echo "3) limit_req rps (每秒请求数)     (当前: ${NGX_RPS})"
  echo "4) limit_req burst (突发)         (当前: ${NGX_BURST})"
  echo "5) 伪装首页模板一键切换"
  echo "0) 返回"
  echo "============================================================="
  read -r -p "选择: " opt

  case "${opt}" in
    1) read -r -p "输入 http2 yes/no: " v; [[ -n "${v}" ]] && NGX_HTTP2="${v}" ;;
    2) read -r -p "输入 limit_req yes/no: " v; [[ -n "${v}" ]] && NGX_LIMIT_REQ="${v}" ;;
    3) read -r -p "输入 rps (例如 20): " v; [[ -n "${v}" ]] && NGX_RPS="${v}" ;;
    4) read -r -p "输入 burst (例如 40): " v; [[ -n "${v}" ]] && NGX_BURST="${v}" ;;
    5) choose_html_template ;;
    0) return ;;
    *) c_warn "无效选项" ;;
  esac

  c_ok "已更新 Nginx 参数（未应用，需执行“应用配置”）"
  log_action "edit nginx params"
  save_state
}

# ==========================================================
# PRO 1) 双机同步：参数管理 + 推送
# ==========================================================
sync_show() {
  echo "==================== PRO: 同步设置 ===================="
  echo "SYNC_ENABLE : ${SYNC_ENABLE}"
  echo "SYNC_CERTS  : ${SYNC_CERTS}"
  echo "PEERS："
  if [[ "${#PEERS[@]}" -eq 0 ]]; then
    echo "  - (空)"
  else
    for p in "${PEERS[@]}"; do echo "  - ${p}"; done
  fi
  echo "======================================================="
}

sync_toggle() {
  echo "当前 SYNC_ENABLE=${SYNC_ENABLE}"
  read -r -p "是否启用同步？(yes/no): " v
  [[ -n "${v}" ]] || return
  SYNC_ENABLE="${v}"
  c_ok "SYNC_ENABLE=${SYNC_ENABLE}"
  log_action "set SYNC_ENABLE=${SYNC_ENABLE}"
  save_state
}

sync_toggle_certs() {
  echo "当前 SYNC_CERTS=${SYNC_CERTS}"
  read -r -p "是否同步证书目录？(yes/no): " v
  [[ -n "${v}" ]] || return
  SYNC_CERTS="${v}"
  c_ok "SYNC_CERTS=${SYNC_CERTS}"
  log_action "set SYNC_CERTS=${SYNC_CERTS}"
  save_state
}

sync_add_peer() {
  read -r -p "请输入对端(格式 root@IP 或 user@host): " p
  [[ -n "${p}" ]] || { c_warn "未输入，取消"; return; }
  for x in "${PEERS[@]}"; do
    [[ "${x}" == "${p}" ]] && { c_warn "已存在：${p}"; return; }
  done
  PEERS+=("${p}")
  c_ok "已新增对端：${p}"
  log_action "add peer ${p}"
  save_state
}

sync_remove_peer() {
  sync_show
  read -r -p "请输入要删除的序号: " idx
  [[ "${idx}" =~ ^[0-9]+$ ]] || { c_err "请输入数字"; return; }
  local n="${#PEERS[@]}"
  (( idx>=1 && idx<=n )) || { c_err "超出范围"; return; }
  local target="${PEERS[$((idx-1))]}"
  PEERS=( "${PEERS[@]:0:$((idx-1))}" "${PEERS[@]:$idx}" )
  c_ok "已删除：${target}"
  log_action "remove peer ${target}"
  save_state
}

sync_push_to_peers() {
  if [[ "${SYNC_ENABLE}" != "yes" ]]; then
    c_warn "同步未启用（SYNC_ENABLE!=yes），跳过"
    return 0
  fi
  if [[ "${#PEERS[@]}" -eq 0 ]]; then
    c_warn "没有设置对端 PEERS，跳过同步"
    return 0
  fi

  c_info "开始同步到对端（rsync/ssh）..."
  command -v rsync >/dev/null 2>&1 || {
    c_err "未安装 rsync，请先执行菜单：0) 安装/修复环境"
    return 1
  }

  local nginx_site="${NGINX_SITE_DIR}/doh_${DOMAIN}.conf"

  local files_to_sync=(
    "${STATE_FILE}"
    "${CONF_DIR}/config.yaml"
    "${UNBOUND_SNIPPET}"
    "${nginx_site}"
    "${STATIC_ROOT}/index.html"
    "${ALLOWLIST_FILE}"
    "/etc/systemd/system/mosdns.service"
    "/usr/local/bin/mosdns"
  )

  for peer in "${PEERS[@]}"; do
    c_info "-> 同步到：${peer}"

    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6 "${peer}" "mkdir -p \
      $(dirname "${STATE_FILE}") \
      ${CONF_DIR} \
      $(dirname "${UNBOUND_SNIPPET}") \
      ${NGINX_SITE_DIR} \
      ${NGINX_LINK_DIR} \
      ${STATIC_ROOT} \
      ${ACME_WEBROOT} \
      ${NGINX_SSL_DIR} \
      $(dirname "${ALLOWLIST_FILE}")" >/dev/null 2>&1 || {
        c_warn "连接失败或创建目录失败：${peer}"
        continue
      }

      for f in "${files_to_sync[@]}"; do
        if [[ -f "${f}" ]]; then
          rsync -az -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6" "${f}" "${peer}:${f}" >/dev/null 2>&1 || {
            c_warn "同步失败：${peer} -> ${f}"
            continue
          }
        fi
      done

      if [[ "${SYNC_CERTS}" == "yes" ]]; then
        if [[ -d "${NGINX_SSL_DIR}" ]]; then
          rsync -az -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6" "${NGINX_SSL_DIR}/" "${peer}:${NGINX_SSL_DIR}/" >/dev/null 2>&1 || {
            c_warn "证书同步失败：${peer}"
          }
        fi
      fi

      ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6 "${peer}" "\
        systemctl daemon-reload || true; \
        ln -sf ${nginx_site} ${NGINX_LINK_DIR}/doh_${DOMAIN}.conf && \
        nginx -t && \
        systemctl restart unbound || true; \
        systemctl restart mosdns || true; \
        systemctl reload nginx || systemctl restart nginx || true" >/dev/null 2>&1 || {
          c_warn "对端重载失败：${peer}"
          continue
        }

      c_ok "同步完成：${peer}"
      log_action "sync push done -> ${peer}"
    done

    c_ok "所有对端同步流程结束"
}

# ==========================================================
# 应用：写配置 + reload +（可选同步）
# ==========================================================
apply_all() {
  doh_path_conflict_check || {
    c_err "检测未通过，已阻止应用（请修正 DOH_PATH）"
    return
  }

  ensure_allowlist_file

  local cnt
  cnt="$(allowlist_count)"
  if (( cnt <= 0 )); then
    c_err "allowlist.txt 为空（${ALLOWLIST_FILE}），已阻止应用"
    return
  fi

  if [[ ! -x /usr/local/bin/mosdns ]]; then
    c_warn "检测到 mosdns-x 未安装，建议先执行：0) 安装/修复环境"
  fi
  if [[ ! -f /etc/systemd/system/mosdns.service ]]; then
    c_warn "检测到 mosdns.service 不存在，建议先执行：0) 安装/修复环境"
  fi

  c_info "生成配置 + 应用..."
  write_unbound_forward
  write_mosdns_config
  write_nginx_site
  reload_services

  c_ok "本机应用完成 ✅"
  log_action "apply all done (local)"

  sync_push_to_peers || true
}

# ==========================================================
# 状态/端口/日志
# ==========================================================
show_status() {
  echo "==================== 服务状态 ===================="
  systemctl --no-pager --full status mosdns 2>/dev/null | sed -n '1,12p' || true
  echo "--------------------------------------------------"
  systemctl --no-pager --full status unbound 2>/dev/null | sed -n '1,12p' || true
  echo "--------------------------------------------------"
  systemctl --no-pager --full status nginx 2>/dev/null | sed -n '1,12p' || true
  echo "=================================================="
}

show_ports() {
  c_info "端口监听检查（80/443/8053/5335）"
  ss -lntp | egrep ":80|:443|:8053|:${UNBOUND_PORT}" || true
}

show_logs_tail() {
  c_info "PRO 日志 tail（最后 40 行）：${LOG_FILE}"
  tail -n 40 "${LOG_FILE}" 2>/dev/null || true
}

# ==========================================================
# 卸载
# ==========================================================
remove_if_exists() {
  local path="$1"
  if [[ -e "${path}" || -L "${path}" ]]; then
    rm -rf "${path}"
    c_ok "已删除: ${path}"
  else
    c_warn "不存在，跳过: ${path}"
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

# ==========================================================
# 菜单
# ==========================================================
show_menu() {
  cat <<EOF
==================== DoH 管理脚本 PRO（All-in-One） ====================
版本: ${SCRIPT_VERSION}

 0) 安装/修复环境(依赖+mosdns-x+systemd+allowlist初始化)

 1) 显示关键参数(主线+PRO同步)
 2) 修改 DOMAIN(doh域名/伪装域名)
 3) 修改 DOH_PATH(doh伪装路径，例如/static/logo.png)
 4) 修改 allowlist.txt 路径(白名单文件路径)

==================== allowlist.txt 白名单维护 ==========================
 5) 查看 allowlist.txt(允许解析的域名白名单)
 6) 新增 allowlist.txt(加域名/后缀)
 7) 删除 allowlist.txt(删域名/后缀)
 8) 批量导入 allowlist.txt(粘贴多行->自动去重)
 9) 打开编辑 allowlist.txt(vim)
10) allowlist.txt 去重排序(清洗维护)

==================== UPSTREAM_DOT（Unbound DoT上游） ====================
11) 查看 UPSTREAM_DOT(Unbound 上游DoT列表)
12) 新增 UPSTREAM_DOT(加 DoT 上游 1.1.1.1@853)
13) 删除 UPSTREAM_DOT(删 DoT 上游)

==================== A/B/C 参数高级配置 ===============================
14) A) 编辑 Unbound 参数(缓存/serve-expired/IPv6等)
15) B) 编辑 mosdns 参数(日志级别/拒绝策略等)
16) C) 编辑 Nginx 参数(HTTP2/限速/伪装页模板等)

==================== 应用 & 检测 ======================================
17) DoH 路径冲突检测(防止与伪装站/ACME冲突)
18) 生成配置 + 应用并重载(nginx/unbound/mosdns) + (可选同步)

==================== D) 证书管理（acme.sh） ============================
19) 证书签发(acme.sh + Let's Encrypt)
20) 证书续期(强制renew)
21) 查看证书有效期(起止时间)

==================== PRO: 双机同步 =====================================
22) 查看同步设置(PEERS/SYNC_ENABLE/SYNC_CERTS)
23) 启用/关闭同步(SYNC_ENABLE yes/no)
24) 是否同步证书目录(SYNC_CERTS yes/no)
25) 添加对端机器(PEERS += root@IP)
26) 删除对端机器(PEERS -= root@IP)
27) 立刻推送同步(把配置推到对端并重载)

==================== 服务控制 ==========================================
28) 服务状态查看(systemctl)
29) 端口监听检查(ss -lntp)
30) 健康检查(curl访问伪装页+DoH路径)
31) 查看PRO变更日志(tail)
32) 启动服务(mosdns/unbound/nginx)
33) 停止服务(mosdns/unbound/nginx)
34) 重启服务(mosdns/unbound/nginx)

==================== 卸载 ==============================================
35) 彻底卸载(删除服务/配置/证书/二进制)

 99) 退出
=======================================================================
EOF
}

# ==========================================================
# 主循环
# ==========================================================
main() {
  need_root
  ensure_state_file
  load_state
  ensure_allowlist_file

  log_action "run doh-manager-pro-allinone.sh"

  while true; do
    show_menu
    read -r -p "请选择操作: " opt
    echo
    case "${opt}" in
      0) ensure_environment ;;

      1) show_config ;;
      2) set_domain ;;
      3) set_doh_path ;;
      4) set_allowlist_file ;;

      5) show_allowlist ;;
      6) add_allowlist_one ;;
      7) remove_allowlist_one ;;
      8) batch_import_allowlist ;;
      9) edit_allowlist_vim ;;
      10) allowlist_dedupe_sort ;;

      11) list_upstreams ;;
      12) add_upstream ;;
      13) remove_upstream ;;

      14) edit_unbound_params ;;
      15) edit_mosdns_params ;;
      16) edit_nginx_params ;;

      17) doh_path_conflict_check ;;
      18) apply_all ;;

      19) issue_cert ;;
      20) renew_cert ;;
      21) check_cert_days ;;

      22) sync_show ;;
      23) sync_toggle ;;
      24) sync_toggle_certs ;;
      25) sync_add_peer ;;
      26) sync_remove_peer ;;
      27) sync_push_to_peers ;;

      28) show_status ;;
      29) show_ports ;;
      30) health_check ;;
      31) show_logs_tail ;;
      32) start_services ;;
      33) stop_services ;;
      34) restart_services ;;

      35) uninstall_all ;;

      99) c_ok "退出"; log_action "exit"; exit 0 ;;
      *) c_warn "无效选项" ;;
    esac
    echo
  done
}

main "$@"
