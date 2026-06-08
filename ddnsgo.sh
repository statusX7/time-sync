#!/usr/bin/env bash
# ddnsgo-manager-v1.0
# DDNS-GO Cloudflare 管理脚本
# 说明：本脚本本身不包含任何敏感信息；运行“快速初始化”后，Token 只会保存在本机 /etc/ddns-go/ 下，权限 600。

set -Eeuo pipefail

SCRIPT_VERSION="ddnsgo-manager-v1.0"
DDNS_GO_BIN="/usr/local/bin/ddns-go"
MANAGER_BIN="/usr/local/bin/ddnsgo-manager"
BASE_DIR="/etc/ddns-go"
CONFIG_FILE="${BASE_DIR}/ddns_go_config.yaml"
MANAGER_ENV="${BASE_DIR}/ddnsgo-manager.env"
UNIT_FILE="/etc/systemd/system/ddns-go.service"
WATCH_UNIT_FILE="/etc/systemd/system/ddnsgo-manager-watch.service"
WATCH_TIMER_FILE="/etc/systemd/system/ddnsgo-manager-watch.timer"
STATE_DIR="/var/lib/ddnsgo-manager"
STATE_FILE="${STATE_DIR}/record-state.db"
LOG_DIR="/var/log/ddnsgo-manager"
HISTORY_LOG="${LOG_DIR}/ip-history.log"
LOCK_FILE="/run/ddnsgo-manager.lock"
LATEST_URL="https://github.com/jeessy2/ddns-go/releases/latest"
DEFAULT_IPV4_URLS="https://api.ipify.org, https://4.ipw.cn, https://ifconfig.me/ip"
DEFAULT_IPV6_URLS="https://api6.ipify.org, https://6.ipw.cn, https://v6.ident.me"

C_RESET='\033[0m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'
C_CYAN='\033[36m'
C_BOLD='\033[1m'

ok() { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
info() { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
err() { echo -e "${C_RED}[ERR]${C_RESET} $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 运行：sudo bash $0"
    exit 1
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

pause() {
  echo
  read -r -p "按 Enter 返回菜单..." _ || true
}

confirm() {
  local prompt="${1:-确认继续？}"
  local ans
  read -r -p "${prompt} [y/N]: " ans || true
  [[ "${ans}" =~ ^[Yy]$ ]]
}

trim() {
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

normalize_csv() {
  local raw="${1:-}"
  echo "${raw}" | tr '，；;、 ' ',,,,,' | sed 's/,,*/,/g;s/^,//;s/,$//' | trim
}

shell_quote() {
  local s="${1:-}"
  printf "'"
  printf "%s" "${s}" | sed "s/'/'\\''/g"
  printf "'"
}

mask_secret() {
  local s="${1:-}"
  local len=${#s}
  if (( len <= 10 )); then
    echo "********"
  else
    echo "${s:0:6}...${s: -4}"
  fi
}

load_env() {
  if [[ -f "${MANAGER_ENV}" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "${MANAGER_ENV}"
    set +a
  fi
  CF_ZONE_ID="${CF_ZONE_ID:-}"
  CF_API_TOKEN="${CF_API_TOKEN:-}"
  CF_ZONE_NAME="${CF_ZONE_NAME:-}"
  DDNS_RECORDS="${DDNS_RECORDS:-}"
  IPV4_ENABLE="${IPV4_ENABLE:-1}"
  IPV6_ENABLE="${IPV6_ENABLE:-0}"
  PROXIED="${PROXIED:-false}"
  TTL="${TTL:-1}"
  LISTEN="${LISTEN:-127.0.0.1:9876}"
  INTERVAL="${INTERVAL:-300}"
  CACHE_TIMES="${CACHE_TIMES:-5}"
  CUSTOM_DNS="${CUSTOM_DNS:-1.1.1.1}"
  IPV4_URLS="${IPV4_URLS:-${DEFAULT_IPV4_URLS}}"
  IPV6_URLS="${IPV6_URLS:-${DEFAULT_IPV6_URLS}}"
  HTTPS_PROXY="${HTTPS_PROXY:-}"
  HTTP_PROXY="${HTTP_PROXY:-}"
  NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"
}

write_manager_env() {
  mkdir -p "${BASE_DIR}"
  cat > "${MANAGER_ENV}" <<ENVEOF
# ddnsgo-manager 本机配置，请勿上传 GitHub。
# 由 ${SCRIPT_VERSION} 生成。
CF_ZONE_ID=$(shell_quote "${CF_ZONE_ID}")
CF_API_TOKEN=$(shell_quote "${CF_API_TOKEN}")
CF_ZONE_NAME=$(shell_quote "${CF_ZONE_NAME}")
DDNS_RECORDS=$(shell_quote "${DDNS_RECORDS}")
IPV4_ENABLE=$(shell_quote "${IPV4_ENABLE}")
IPV6_ENABLE=$(shell_quote "${IPV6_ENABLE}")
PROXIED=$(shell_quote "${PROXIED}")
TTL=$(shell_quote "${TTL}")
LISTEN=$(shell_quote "${LISTEN}")
INTERVAL=$(shell_quote "${INTERVAL}")
CACHE_TIMES=$(shell_quote "${CACHE_TIMES}")
CUSTOM_DNS=$(shell_quote "${CUSTOM_DNS}")
IPV4_URLS=$(shell_quote "${IPV4_URLS}")
IPV6_URLS=$(shell_quote "${IPV6_URLS}")
HTTPS_PROXY=$(shell_quote "${HTTPS_PROXY}")
HTTP_PROXY=$(shell_quote "${HTTP_PROXY}")
NO_PROXY=$(shell_quote "${NO_PROXY}")
ENVEOF
  chmod 600 "${MANAGER_ENV}"
}

install_manager_self() {
  need_root
  local src="${BASH_SOURCE[0]}"
  if [[ "${src}" != "${MANAGER_BIN}" && -r "${src}" ]]; then
    install -m 0755 "${src}" "${MANAGER_BIN}"
    ok "管理脚本已安装到：${MANAGER_BIN}"
  elif [[ ! -x "${MANAGER_BIN}" ]]; then
    warn "无法自动复制脚本到 ${MANAGER_BIN}。如果你是通过管道执行，请先保存为文件再运行。"
  fi
}

install_deps() {
  need_root
  local need_list=()
  for c in curl tar gzip jq; do
    command_exists "$c" || need_list+=("$c")
  done
  if [[ ${#need_list[@]} -eq 0 ]]; then
    return 0
  fi
  info "安装依赖：${need_list[*]}"
  if command_exists apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar gzip jq ca-certificates
  elif command_exists dnf; then
    dnf install -y curl tar gzip jq ca-certificates
  elif command_exists yum; then
    yum install -y curl tar gzip jq ca-certificates
  elif command_exists apk; then
    apk add --no-cache curl tar gzip jq ca-certificates
  else
    err "未识别包管理器，请手动安装：curl tar gzip jq ca-certificates"
    exit 1
  fi
}

require_systemd() {
  if ! command_exists systemctl; then
    err "当前系统未检测到 systemctl。本脚本面向常见 Linux 服务器 systemd 环境。"
    exit 1
  fi
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    armv6l|armv6) echo "armv6" ;;
    i386|i686) echo "i386" ;;
    riscv64) echo "riscv64" ;;
    *) err "暂不支持的架构：${arch}"; exit 1 ;;
  esac
}

get_latest_version() {
  local effective ver
  effective="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${LATEST_URL}" 2>/dev/null || true)"
  ver="${effective##*/}"
  if [[ "${ver}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${ver}"
  else
    warn "无法自动获取最新版本，将使用备用版本 v6.17.0。"
    echo "v6.17.0"
  fi
}

install_or_update_ddns_go() {
  need_root
  install_deps
  local ver arch file url tmp
  ver="$(get_latest_version)"
  arch="$(detect_arch)"
  file="ddns-go_${ver#v}_linux_${arch}.tar.gz"
  url="https://github.com/jeessy2/ddns-go/releases/download/${ver}/${file}"
  tmp="$(mktemp -d)"
  info "下载 ddns-go ${ver} (${arch})"
  if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 -o "${tmp}/${file}" "${url}"; then
    err "下载失败：${url}"
    exit 1
  fi
  tar -xzf "${tmp}/${file}" -C "${tmp}"
  if [[ ! -f "${tmp}/ddns-go" ]]; then
    err "压缩包内未找到 ddns-go 二进制文件。"
    exit 1
  fi
  install -m 0755 "${tmp}/ddns-go" "${DDNS_GO_BIN}"
  rm -rf "${tmp}"
  ok "ddns-go 已安装/更新：$(${DDNS_GO_BIN} -v 2>/dev/null || echo "${ver}")"
}

records_to_lines() {
  echo "${DDNS_RECORDS:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d'
}

json_escape() {
  jq -Rn --arg v "$1" '$v'
}

yaml_domain_lines() {
  local domain final proxied
  proxied="${PROXIED:-false}"
  while IFS= read -r domain; do
    [[ -z "${domain}" ]] && continue
    if [[ "${domain}" == *\?* ]]; then
      final="${domain}"
    else
      final="${domain}?proxied=${proxied}"
    fi
    printf '        - "%s"\n' "${final//\"/\\\"}"
  done < <(records_to_lines)
}

write_ddns_go_config() {
  need_root
  mkdir -p "${BASE_DIR}"
  chmod 700 "${BASE_DIR}"
  local ipv4_domains ipv6_domains
  ipv4_domains="$(yaml_domain_lines)"
  ipv6_domains="$(yaml_domain_lines)"
  [[ -z "${ipv4_domains}" ]] && ipv4_domains='        - ""'
  [[ -z "${ipv6_domains}" ]] && ipv6_domains='        - ""'

  cat > "${CONFIG_FILE}" <<YAMLEOF
# ddns-go 配置文件，请勿上传 GitHub。
# 由 ${SCRIPT_VERSION} 生成。
dnsconf:
  - name: "cloudflare-main"
    ipv4:
      enable: ${IPV4_ENABLE}
      gettype: "url"
      url: "${IPV4_URLS//\"/\\\"}"
      netinterface: ""
      cmd: ""
      domains:
${ipv4_domains}
    ipv6:
      enable: ${IPV6_ENABLE}
      gettype: "url"
      url: "${IPV6_URLS//\"/\\\"}"
      netinterface: ""
      cmd: ""
      ipv6reg: ""
      domains:
${ipv6_domains}
    dns:
      name: "cloudflare"
      id: ""
      secret: "${CF_API_TOKEN//\"/\\\"}"
    ttl: "${TTL}"
    httpinterface: ""
user:
  username: ""
  password: ""
notallowwanaccess: true
lang: "zh"
webhook:
  webhookurl: ""
  webhookrequestbody: ""
  webhookheaders: ""
YAMLEOF
  chmod 600 "${CONFIG_FILE}"
  ok "ddns-go 配置已写入：${CONFIG_FILE}"
}

build_exec_start() {
  local cmd
  cmd="${DDNS_GO_BIN} -l ${LISTEN} -f ${INTERVAL} -cacheTimes ${CACHE_TIMES} -c ${CONFIG_FILE}"
  if [[ -n "${CUSTOM_DNS:-}" ]]; then
    cmd+=" -dns ${CUSTOM_DNS}"
  fi
  echo "${cmd}"
}

write_systemd_units() {
  need_root
  require_systemd
  local exec_start
  exec_start="$(build_exec_start)"
  cat > "${UNIT_FILE}" <<UNITEOF
[Unit]
Description=ddns-go Cloudflare DDNS Service
Documentation=https://github.com/jeessy2/ddns-go
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=-${MANAGER_ENV}
ExecStart=${exec_start}
Restart=always
RestartSec=10
WorkingDirectory=${BASE_DIR}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNITEOF

  cat > "${WATCH_UNIT_FILE}" <<UNITEOF
[Unit]
Description=ddnsgo-manager IP History Watcher
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${MANAGER_BIN} watch
UNITEOF

  cat > "${WATCH_TIMER_FILE}" <<UNITEOF
[Unit]
Description=Run ddnsgo-manager IP History Watcher every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
UNITEOF

  systemctl daemon-reload
  ok "systemd 服务已写入：${UNIT_FILE}"
  ok "IP 历史记录定时器已写入：${WATCH_TIMER_FILE}"
}

cf_api_get() {
  local path="$1"
  load_env
  curl -fsS --retry 2 --connect-timeout 10 --max-time 25 \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4${path}"
}

cf_records_get() {
  local record_type="$1" domain="$2"
  load_env
  curl -fsS --retry 2 --connect-timeout 10 --max-time 25 \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --get \
    --data-urlencode "type=${record_type}" \
    --data-urlencode "name=${domain}" \
    --data-urlencode "per_page=100" \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records"
}

validate_cloudflare() {
  load_env
  if [[ -z "${CF_ZONE_ID}" || -z "${CF_API_TOKEN}" ]]; then
    warn "未配置 Cloudflare ZoneID 或 API Token，跳过验证。"
    return 1
  fi
  if ! command_exists jq; then
    warn "未安装 jq，跳过 Cloudflare 返回值解析。"
    return 1
  fi
  local resp success zone_name
  resp="$(cf_api_get "/zones/${CF_ZONE_ID}" 2>/dev/null || true)"
  success="$(echo "${resp}" | jq -r '.success // false' 2>/dev/null || echo false)"
  if [[ "${success}" == "true" ]]; then
    zone_name="$(echo "${resp}" | jq -r '.result.name // empty' 2>/dev/null || true)"
    [[ -n "${zone_name}" ]] && CF_ZONE_NAME="${zone_name}" && write_manager_env
    ok "Cloudflare Token 与 ZoneID 验证成功：${zone_name:-${CF_ZONE_ID}}"
    return 0
  fi
  warn "Cloudflare 验证失败。请确认 Token 至少有 Zone:Read + DNS:Edit 权限，且 ZoneID 正确。"
  if [[ -n "${resp}" ]]; then
    echo "${resp}" | jq -r '.errors[]?.message // empty' 2>/dev/null | sed 's/^/[Cloudflare] /' || true
  fi
  return 1
}

curl_direct_ip() {
  local family="$1" url="$2"
  if [[ "${family}" == "4" ]]; then
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY curl -4 -fsS --connect-timeout 6 --max-time 10 "${url}" 2>/dev/null || true
  else
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY curl -6 -fsS --connect-timeout 6 --max-time 10 "${url}" 2>/dev/null || true
  fi
}

extract_ipv4() { grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1; }
extract_ipv6() { grep -Eio '([0-9a-f]{0,4}:){2,}[0-9a-f:.]{0,}' | head -n1; }

get_public_ip() {
  local family="$1" urls raw ip
  load_env
  if [[ "${family}" == "4" ]]; then
    urls="${IPV4_URLS}"
  else
    urls="${IPV6_URLS}"
  fi
  echo "${urls}" | tr ',' '\n' | while IFS= read -r url; do
    url="$(echo "${url}" | trim)"
    [[ -z "${url}" ]] && continue
    raw="$(curl_direct_ip "${family}" "${url}" || true)"
    if [[ "${family}" == "4" ]]; then
      ip="$(echo "${raw}" | extract_ipv4 || true)"
    else
      ip="$(echo "${raw}" | extract_ipv6 || true)"
    fi
    if [[ -n "${ip}" ]]; then
      echo "${ip}"
      exit 0
    fi
  done
}

show_current_ip() {
  load_env
  echo -e "${C_BOLD}📡 当前 IP / DNS 记录${C_RESET}"
  echo "版本：${SCRIPT_VERSION}"
  echo "配置文件：${CONFIG_FILE}"
  echo "Zone：${CF_ZONE_NAME:-未验证} (${CF_ZONE_ID:-未配置})"
  echo "Token：$(mask_secret "${CF_API_TOKEN:-}")"
  echo

  if [[ "${IPV4_ENABLE}" == "true" || "${IPV4_ENABLE}" == "1" ]]; then
    local ip4
    ip4="$(get_public_ip 4 || true)"
    echo "🌐 本机公网 IPv4：${ip4:-未获取到}"
  fi
  if [[ "${IPV6_ENABLE}" == "true" || "${IPV6_ENABLE}" == "1" ]]; then
    local ip6
    ip6="$(get_public_ip 6 || true)"
    echo "🌐 本机公网 IPv6：${ip6:-未获取到}"
  fi
  echo

  if [[ -z "${CF_ZONE_ID}" || -z "${CF_API_TOKEN}" || -z "${DDNS_RECORDS}" ]]; then
    warn "未完成快速初始化，无法查询 Cloudflare 记录。"
    return 0
  fi
  if ! command_exists jq; then
    err "缺少 jq，无法解析 Cloudflare 记录。请先执行快速初始化或安装依赖。"
    return 1
  fi

  local domain type resp success count
  while IFS= read -r domain; do
    for type in A AAAA; do
      if [[ "${type}" == "A" && !( "${IPV4_ENABLE}" == "true" || "${IPV4_ENABLE}" == "1" ) ]]; then
        continue
      fi
      if [[ "${type}" == "AAAA" && !( "${IPV6_ENABLE}" == "true" || "${IPV6_ENABLE}" == "1" ) ]]; then
        continue
      fi
      resp="$(cf_records_get "${type}" "${domain}" 2>/dev/null || true)"
      success="$(echo "${resp}" | jq -r '.success // false' 2>/dev/null || echo false)"
      if [[ "${success}" != "true" ]]; then
        echo "❌ ${type} ${domain}：查询失败"
        echo "${resp}" | jq -r '.errors[]?.message // empty' 2>/dev/null | sed 's/^/   - /' || true
        continue
      fi
      count="$(echo "${resp}" | jq -r '.result | length' 2>/dev/null || echo 0)"
      if [[ "${count}" == "0" ]]; then
        echo "⚠️  ${type} ${domain}：Cloudflare 暂无记录，等待 ddns-go 创建或检查配置。"
      else
        echo "${resp}" | jq -r --arg t "${type}" '.result[] | "✅ \($t) \(.name) -> \(.content) | proxied=\(.proxied) | ttl=\(.ttl)"'
      fi
    done
  done < <(records_to_lines)
}

watch_once() {
  local mode="${1:-timer}"
  load_env
  mkdir -p "${STATE_DIR}" "${LOG_DIR}"
  chmod 700 "${STATE_DIR}" "${LOG_DIR}"
  touch "${STATE_FILE}" "${HISTORY_LOG}"
  chmod 600 "${STATE_FILE}" "${HISTORY_LOG}"

  if [[ -z "${CF_ZONE_ID}" || -z "${CF_API_TOKEN}" || -z "${DDNS_RECORDS}" ]]; then
    [[ "${mode}" != "timer" ]] && warn "未完成快速初始化，跳过 IP 历史记录采集。"
    return 0
  fi
  command_exists jq || return 0

  local domain type resp success content old now tmp event
  now="$(date '+%Y-%m-%d %H:%M:%S')"

  exec 9>"${LOCK_FILE}" || true
  if command_exists flock; then
    flock -n 9 || exit 0
  fi

  while IFS= read -r domain; do
    for type in A AAAA; do
      if [[ "${type}" == "A" && !( "${IPV4_ENABLE}" == "true" || "${IPV4_ENABLE}" == "1" ) ]]; then
        continue
      fi
      if [[ "${type}" == "AAAA" && !( "${IPV6_ENABLE}" == "true" || "${IPV6_ENABLE}" == "1" ) ]]; then
        continue
      fi
      resp="$(cf_records_get "${type}" "${domain}" 2>/dev/null || true)"
      success="$(echo "${resp}" | jq -r '.success // false' 2>/dev/null || echo false)"
      [[ "${success}" != "true" ]] && continue
      content="$(echo "${resp}" | jq -r '[.result[].content] | join(",")' 2>/dev/null || true)"
      [[ -z "${content}" ]] && content="NO_RECORD"
      old="$(awk -F'|' -v t="${type}" -v d="${domain}" '$1==t && $2==d {print $3}' "${STATE_FILE}" 2>/dev/null | tail -n1)"
      if [[ "${old}" != "${content}" ]]; then
        if [[ -z "${old}" ]]; then
          event="INIT"
          old="EMPTY"
        else
          event="CHANGED"
        fi
        printf '%s|%s|%s|%s|%s|%s\n' "${now}" "${event}" "${type}" "${domain}" "${old}" "${content}" >> "${HISTORY_LOG}"
        tmp="$(mktemp)"
        awk -F'|' -v t="${type}" -v d="${domain}" '!( $1==t && $2==d )' "${STATE_FILE}" > "${tmp}" 2>/dev/null || true
        printf '%s|%s|%s\n' "${type}" "${domain}" "${content}" >> "${tmp}"
        mv "${tmp}" "${STATE_FILE}"
      fi
    done
  done < <(records_to_lines)

  [[ "${mode}" != "timer" ]] && ok "已采集当前 Cloudflare 解析状态并更新历史记录。"
}

show_history_days() {
  local days="$1"
  load_env
  watch_once "manual" >/dev/null 2>&1 || true
  if [[ ! -s "${HISTORY_LOG}" ]]; then
    warn "暂无 IP 历史记录。历史从你完成快速初始化并启用定时器后开始记录。"
    return 0
  fi
  local cutoff
  cutoff="$(date -d "-${days} days" '+%Y-%m-%d %H:%M:%S')"
  echo -e "${C_BOLD}🕒 最近 ${days} 天 IP 更换记录${C_RESET}"
  echo "记录文件：${HISTORY_LOG}"
  echo
  {
    echo "时间|事件|类型|域名|旧值|新值"
    awk -F'|' -v c="${cutoff}" '$1 >= c {print $0}' "${HISTORY_LOG}"
  } | if command_exists column; then column -t -s '|'; else cat; fi
}

service_start() {
  need_root
  require_systemd
  systemctl enable --now ddns-go.service
  systemctl enable --now ddnsgo-manager-watch.timer >/dev/null 2>&1 || true
  ok "ddns-go 已启动并设为开机自启。"
}

service_stop() {
  need_root
  require_systemd
  systemctl stop ddns-go.service || true
  ok "ddns-go 已停止。"
}

service_restart() {
  need_root
  require_systemd
  systemctl daemon-reload
  systemctl restart ddns-go.service
  systemctl enable ddns-go.service >/dev/null 2>&1 || true
  sleep 2
  watch_once "manual" >/dev/null 2>&1 || true
  ok "ddns-go 已重启。"
}

show_status() {
  require_systemd
  echo -e "${C_BOLD}📊 ddns-go 状态${C_RESET}"
  systemctl --no-pager --full status ddns-go.service || true
  echo
  echo -e "${C_BOLD}⏱️ IP 历史采集定时器${C_RESET}"
  systemctl --no-pager --full status ddnsgo-manager-watch.timer || true
}

show_logs() {
  require_systemd
  journalctl -u ddns-go.service -n 120 --no-pager || true
}

edit_config() {
  need_root
  local editor="${EDITOR:-vi}"
  info "编辑 ddns-go 配置：${CONFIG_FILE}"
  "${editor}" "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}" || true
  if confirm "是否立即重启 ddns-go 使配置生效？"; then
    service_restart
  fi
}

quick_init() {
  need_root
  require_systemd
  install_manager_self
  install_or_update_ddns_go

  mkdir -p "${BASE_DIR}" "${STATE_DIR}" "${LOG_DIR}"
  chmod 700 "${BASE_DIR}" "${STATE_DIR}" "${LOG_DIR}"

  echo -e "${C_BOLD}🚀 ddns-go Cloudflare 快速初始化${C_RESET}"
  echo "说明：推荐使用 Cloudflare API Token，不推荐 Global API Key。Token 至少需要 Zone:Read + DNS:Edit。"
  echo

  local input token proxy_input default_zone guess
  load_env

  read -r -p "请输入 Cloudflare Zone ID：" input
  CF_ZONE_ID="$(echo "${input}" | trim)"

  read -r -s -p "请输入 Cloudflare API Token：" token
  echo
  CF_API_TOKEN="$(echo "${token}" | trim)"

  read -r -p "请输入 Cloudflare 根域名 / Zone Name，例如 example.com（可留空自动尝试从 ZoneID 获取）：" input
  CF_ZONE_NAME="$(echo "${input}" | trim)"

  read -r -p "请输入需要 DDNS 的完整域名，可多个，用逗号隔开，例如 home.example.com, nas.example.com：" input
  DDNS_RECORDS="$(normalize_csv "${input}")"
  while [[ -z "${DDNS_RECORDS}" ]]; do
    warn "DDNS 域名不能为空。"
    read -r -p "请输入需要 DDNS 的完整域名：" input
    DDNS_RECORDS="$(normalize_csv "${input}")"
  done

  read -r -p "是否启用 IPv4 A 记录？[Y/n]: " input
  if [[ "${input}" =~ ^[Nn]$ ]]; then IPV4_ENABLE="false"; else IPV4_ENABLE="true"; fi

  read -r -p "是否启用 IPv6 AAAA 记录？[y/N]: " input
  if [[ "${input}" =~ ^[Yy]$ ]]; then IPV6_ENABLE="true"; else IPV6_ENABLE="false"; fi

  if [[ "${IPV4_ENABLE}" != "true" && "${IPV6_ENABLE}" != "true" ]]; then
    warn "IPv4 和 IPv6 不能同时关闭，已自动启用 IPv4。"
    IPV4_ENABLE="true"
  fi

  read -r -p "Cloudflare 是否开启代理小云朵？一般 DDNS 建议 DNS only。[y/N]: " input
  if [[ "${input}" =~ ^[Yy]$ ]]; then PROXIED="true"; else PROXIED="false"; fi

  read -r -p "TTL 设置，1 表示 Cloudflare Auto。[默认 1]: " input
  TTL="$(echo "${input:-1}" | trim)"
  [[ "${TTL}" =~ ^[0-9]+$ ]] || TTL="1"

  read -r -p "同步间隔秒。[默认 300]: " input
  INTERVAL="$(echo "${input:-300}" | trim)"
  [[ "${INTERVAL}" =~ ^[0-9]+$ ]] || INTERVAL="300"

  read -r -p "cacheTimes 缓存次数。[默认 5]: " input
  CACHE_TIMES="$(echo "${input:-5}" | trim)"
  [[ "${CACHE_TIMES}" =~ ^[0-9]+$ ]] || CACHE_TIMES="5"

  read -r -p "Web 管理监听地址。[默认 127.0.0.1:9876]: " input
  LISTEN="$(echo "${input:-127.0.0.1:9876}" | trim)"

  read -r -p "ddns-go 请求 DNS 服务器，留空则不指定。[默认 1.1.1.1]: " input
  CUSTOM_DNS="$(echo "${input:-1.1.1.1}" | trim)"

  read -r -p "公网 IPv4 获取接口，多个用逗号隔开。[默认内置]: " input
  IPV4_URLS="$(echo "${input:-${DEFAULT_IPV4_URLS}}" | trim)"

  read -r -p "公网 IPv6 获取接口，多个用逗号隔开。[默认内置]: " input
  IPV6_URLS="$(echo "${input:-${DEFAULT_IPV6_URLS}}" | trim)"

  read -r -p "HTTPS 代理地址，可留空，例如 socks5h://127.0.0.1:1080 或 http://127.0.0.1:7890：" proxy_input
  proxy_input="$(echo "${proxy_input}" | trim)"
  HTTPS_PROXY="${proxy_input}"
  HTTP_PROXY="${proxy_input}"
  NO_PROXY="127.0.0.1,localhost"

  write_manager_env
  validate_cloudflare || true
  load_env
  write_ddns_go_config
  write_systemd_units
  service_start
  sleep 3
  watch_once "manual" || true

  echo
  ok "快速初始化完成。"
  echo "🔐 敏感文件：${CONFIG_FILE}、${MANAGER_ENV}，权限已设置为 600，请勿上传 GitHub。"
  echo "🌐 Web 管理：${LISTEN}（默认仅本机访问；远程建议用 SSH 隧道或反代 HTTPS）"
  echo "📜 查看日志：journalctl -u ddns-go -f"
  echo "🕒 IP 历史：${HISTORY_LOG}"
}

uninstall_all() {
  need_root
  require_systemd
  warn "将停止并删除 ddns-go 服务、历史采集定时器和管理脚本。"
  if ! confirm "确认卸载？"; then
    return 0
  fi
  systemctl disable --now ddnsgo-manager-watch.timer >/dev/null 2>&1 || true
  systemctl disable --now ddns-go.service >/dev/null 2>&1 || true
  rm -f "${UNIT_FILE}" "${WATCH_UNIT_FILE}" "${WATCH_TIMER_FILE}"
  systemctl daemon-reload || true
  if confirm "是否同时删除 ddns-go 二进制文件 ${DDNS_GO_BIN}？"; then
    rm -f "${DDNS_GO_BIN}"
  fi
  if confirm "是否同时删除配置和历史记录？这会删除 Token、本地配置、历史日志。"; then
    rm -rf "${BASE_DIR}" "${STATE_DIR}" "${LOG_DIR}"
  fi
  if confirm "是否删除管理命令 ${MANAGER_BIN}？"; then
    rm -f "${MANAGER_BIN}"
  fi
  ok "卸载流程完成。"
}

show_config_summary() {
  load_env
  echo -e "${C_BOLD}⚙️ 当前配置摘要${C_RESET}"
  echo "脚本版本：${SCRIPT_VERSION}"
  echo "ddns-go：$([[ -x "${DDNS_GO_BIN}" ]] && ${DDNS_GO_BIN} -v 2>/dev/null || echo 未安装)"
  echo "ZoneID：${CF_ZONE_ID:-未配置}"
  echo "ZoneName：${CF_ZONE_NAME:-未配置}"
  echo "Token：$(mask_secret "${CF_API_TOKEN:-}")"
  echo "DDNS 域名：${DDNS_RECORDS:-未配置}"
  echo "IPv4：${IPV4_ENABLE:-未配置}"
  echo "IPv6：${IPV6_ENABLE:-未配置}"
  echo "Proxied：${PROXIED:-false}"
  echo "TTL：${TTL:-1}"
  echo "监听：${LISTEN:-127.0.0.1:9876}"
  echo "同步间隔：${INTERVAL:-300}s"
  echo "自定义 DNS：${CUSTOM_DNS:-未指定}"
  echo "配置文件：${CONFIG_FILE}"
  echo "管理配置：${MANAGER_ENV}"
  echo "历史文件：${HISTORY_LOG}"
}

menu() {
  while true; do
    clear || true
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_BOLD}🌐 ddns-go Cloudflare 管理脚本 ${SCRIPT_VERSION}${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo "  1. 🚀 快速初始化 / 一键配置"
    echo "  2. 🔄 重启 ddns-go"
    echo "  3. ⏹️  停止 ddns-go"
    echo "  4. ▶️  启动 ddns-go"
    echo "  5. 📡 显示当前 IP 与 Cloudflare 解析"
    echo "  6. 🕒 查看最近三天 IP 更换记录"
    echo "  7. 📅 查看最近一个月 IP 更换记录"
    echo "  8. 📊 查看服务状态"
    echo "  9. 📜 查看 ddns-go 最近日志"
    echo " 10. ✅ 验证 Cloudflare Token / ZoneID"
    echo " 11. ⚙️ 查看当前配置摘要"
    echo " 12. 📝 编辑 ddns-go 配置文件"
    echo " 13. ⬆️ 安装 / 更新 ddns-go 二进制"
    echo " 14. 🧹 卸载脚本与服务"
    echo "  0. 🚪 退出"
    echo -e "${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    read -r -p "请输入选择 [0-14]: " choice
    case "${choice}" in
      1) quick_init; pause ;;
      2) service_restart; pause ;;
      3) service_stop; pause ;;
      4) service_start; pause ;;
      5) show_current_ip; pause ;;
      6) show_history_days 3; pause ;;
      7) show_history_days 30; pause ;;
      8) show_status; pause ;;
      9) show_logs; pause ;;
      10) validate_cloudflare; pause ;;
      11) show_config_summary; pause ;;
      12) edit_config; pause ;;
      13) install_or_update_ddns_go; pause ;;
      14) uninstall_all; pause ;;
      0) exit 0 ;;
      *) warn "无效选项：${choice}"; sleep 1 ;;
    esac
  done
}

main() {
  local cmd="${1:-menu}"
  case "${cmd}" in
    menu) menu ;;
    install|init|quick-init) quick_init ;;
    restart) service_restart ;;
    stop) service_stop ;;
    start) service_start ;;
    status) show_status ;;
    ip) show_current_ip ;;
    history3) show_history_days 3 ;;
    history30|history-month) show_history_days 30 ;;
    logs) show_logs ;;
    validate) validate_cloudflare ;;
    summary) show_config_summary ;;
    update-ddns-go) install_or_update_ddns_go ;;
    watch) watch_once "timer" ;;
    uninstall) uninstall_all ;;
    version|-v|--version) echo "${SCRIPT_VERSION}" ;;
    *)
      echo "用法：$0 [menu|init|restart|stop|start|status|ip|history3|history30|logs|validate|summary|update-ddns-go|watch|uninstall]"
      exit 1
      ;;
  esac
}

main "$@"
