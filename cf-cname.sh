#!/usr/bin/env bash
# cfcname - Cloudflare CNAME Scheduled Switch Manager
# Version: 1.4
# License: MIT
#
# 功能简要注释：
# 1. 用 cfcname 菜单管理 Cloudflare 域名、API Token、多个 CNAME 定时切换任务。
# 2. 支持快速初始化向导，不在脚本中写死任何真实域名、Zone ID、Token，适合 GitHub 公开。
# 3. 支持多个时间点，例如 21:00 指向 A，02:00 指向 B。
# 4. 支持日志等级、curl 超时/脚本内置重试、HTTP/1.1 优先请求，兼容旧版 curl。
# 5. 每次修改 DNS 前自动备份当前记录，支持按备份恢复 CNAME 目标。
# 6. 默认只处理 CNAME；遇到同名 A/AAAA/其他记录会停止，避免误删生产记录。

set -Eeuo pipefail

APP_NAME="cfcname"
APP_VERSION="1.4"
INSTALL_BIN="/usr/local/bin/${APP_NAME}"
CONFIG_DIR="/etc/${APP_NAME}"
CONFIG_FILE="${CONFIG_DIR}/config.json"
STATE_DIR="/var/lib/${APP_NAME}"
BACKUP_DIR="${STATE_DIR}/backups"
LOG_DIR="/var/log/${APP_NAME}"
LOG_FILE="${LOG_DIR}/${APP_NAME}.log"
SYSTEMD_SERVICE="/etc/systemd/system/${APP_NAME}.service"
SYSTEMD_TIMER="/etc/systemd/system/${APP_NAME}.timer"
CRON_FILE="/etc/cron.d/${APP_NAME}"
API_BASE="https://api.cloudflare.com/client/v4"
QUIET=0

# ---------- 基础 UI ----------
_is_tty() { [[ -t 1 ]]; }
if _is_tty; then
  C_RESET='\033[0m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_CYAN='\033[36m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_BOLD=''; C_DIM=''
fi

# 打印标题。用于菜单顶部。
print_header() {
  clear 2>/dev/null || true
  printf "%b\n" "${C_CYAN}${C_BOLD}┌──────────────────────────────────────────────────────────────┐${C_RESET}"
  printf "%b\n" "${C_CYAN}${C_BOLD}│        cfcname v${APP_VERSION} - Cloudflare CNAME 管理器        │${C_RESET}"
  printf "%b\n" "${C_CYAN}${C_BOLD}└──────────────────────────────────────────────────────────────┘${C_RESET}"
  printf "%b\n" "${C_DIM}配置: ${CONFIG_FILE}    日志: ${LOG_FILE}${C_RESET}"
  echo
}

# 暂停等待用户回车。用于菜单返回。
pause_enter() {
  echo
  read -r -p "按 Enter 返回菜单..." _ || true
}

# 菜单确认，不再要求输入 done，只需选择 1 或 2。
confirm_select() {
  local msg="$1" ans
  echo
  printf "%b\n" "${C_YELLOW}${msg}${C_RESET}"
  echo "  1) 确认"
  echo "  2) 取消"
  while true; do
    read -r -p "请选择 [1-2]: " ans || return 1
    case "$ans" in
      1) return 0 ;;
      2) return 1 ;;
      *) echo "请输入 1 或 2" ;;
    esac
  done
}

# ---------- 日志 ----------
# 将日志等级转换为数字，方便比较。
level_num() {
  case "${1^^}" in
    DEBUG) echo 10 ;;
    INFO) echo 20 ;;
    WARN) echo 30 ;;
    ERROR) echo 40 ;;
    OFF) echo 99 ;;
    *) echo 20 ;;
  esac
}

# 读取当前日志等级。配置损坏时默认 INFO。
current_log_level() {
  if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.settings.log_level // "INFO"' "$CONFIG_FILE" 2>/dev/null || echo "INFO"
  else
    echo "INFO"
  fi
}

# 记录日志。受日志等级控制；--quiet 时不输出到屏幕。
log_msg() {
  local level="${1^^}"; shift
  local msg="$*" cfg_level now
  cfg_level="$(current_log_level)"
  [[ "${cfg_level^^}" == "OFF" ]] && return 0
  [[ "$(level_num "$level")" -lt "$(level_num "$cfg_level")" ]] && return 0
  mkdir -p "$LOG_DIR"
  now="$(date '+%Y-%m-%d %H:%M:%S %z')"
  printf '[%s] [%s] %s\n' "$now" "$level" "$msg" >> "$LOG_FILE"
  if [[ "$QUIET" -eq 0 ]]; then
    case "$level" in
      ERROR) printf "%b\n" "${C_RED}[ERROR]${C_RESET} $msg" ;;
      WARN)  printf "%b\n" "${C_YELLOW}[WARN]${C_RESET} $msg" ;;
      INFO)  printf "%b\n" "${C_GREEN}[INFO]${C_RESET} $msg" ;;
      DEBUG) printf "%b\n" "${C_DIM}[DEBUG] $msg${C_RESET}" ;;
      *)     printf '[%s] %s\n' "$level" "$msg" ;;
    esac
  fi
}

# ---------- 通用工具 ----------
# root 检查。安装、修改 systemd、写 /etc 都需要 root。
need_root() {
  [[ "$(id -u)" -eq 0 ]] || { echo "请使用 root 运行：sudo $0" >&2; exit 1; }
}

# 安全创建目录和权限。
ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR" "$LOG_DIR"
  chmod 700 "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
  chmod 755 "$LOG_DIR" 2>/dev/null || true
}

# 清理用户输入的 Token，去除空格、TAB、CR、LF，修复粘贴换行导致 Authorization 头为空的问题。
sanitize_token() {
  printf '%s' "${1:-}" | tr -d '[:space:]'
}

# 清理普通输入，去除首尾空白和 CR。
trim_text() {
  local s="${1:-}"
  s="${s//$'\r'/}"
  s="$(printf '%s' "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  printf '%s' "$s"
}

# 校验 Cloudflare Zone ID。Zone ID 通常为 32 位十六进制。
valid_zone_id() {
  [[ "${1:-}" =~ ^[a-fA-F0-9]{32}$ ]]
}

# 校验域名格式，避免把 URL 或空值写入配置。
valid_domain() {
  [[ "${1:-}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}\.?$ ]]
}

# 校验 HH:MM 时间。
valid_hhmm() {
  [[ "${1:-}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

# 将用户输入的 x001 或 www.example.com 统一成完整域名。
normalize_record_name() {
  local input zone
  input="$(trim_text "$1")"
  zone="$(trim_text "$2")"
  input="${input%.}"
  zone="${zone%.}"
  if [[ "$input" == *"."* ]]; then
    printf '%s' "$input"
  else
    printf '%s.%s' "$input" "$zone"
  fi
}

# 清理 CNAME 目标，只接受域名，不接受 http:// URL。
normalize_cname_target() {
  local input
  input="$(trim_text "$1")"
  input="${input#http://}"
  input="${input#https://}"
  input="${input%%/*}"
  input="${input%.}"
  printf '%s' "$input"
}

# URL 编码，用于 DNS 记录名查询。
urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

# 生成简单 ID。
gen_id() {
  local prefix="$1"
  printf '%s_%s' "$prefix" "$(date +%Y%m%d%H%M%S)_$((RANDOM * RANDOM % 99999))"
}

# 读取输入，带默认值。
prompt_input() {
  local prompt="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [默认: ${default}]: " value || true
    value="$(trim_text "$value")"
    [[ -z "$value" ]] && value="$default"
  else
    read -r -p "${prompt}: " value || true
    value="$(trim_text "$value")"
  fi
  printf '%s' "$value"
}

# 读取敏感 Token，不回显；读取后强制去空白和换行。
prompt_secret_token() {
  local prompt="$1" value value2
  while true; do
    read -r -s -p "${prompt}: " value || true
    echo
    value="$(sanitize_token "$value")"
    if [[ -z "$value" ]]; then
      echo "Token 不能为空，请重新输入。"
      continue
    fi
    read -r -s -p "请再次输入 Token 以确认: " value2 || true
    echo
    value2="$(sanitize_token "$value2")"
    if [[ "$value" != "$value2" ]]; then
      echo "两次 Token 不一致，请重新输入。"
      continue
    fi
    printf '%s' "$value"
    return 0
  done
}

# 将 Token 脱敏显示。
mask_token() {
  local t
  t="$(sanitize_token "${1:-}")"
  if [[ ${#t} -le 10 ]]; then
    echo "***"
  else
    printf '%s...%s' "${t:0:5}" "${t: -4}"
  fi
}

# ---------- 配置读写 ----------
# 创建默认空配置，使用 example.com 作为说明示例，不包含任何真实敏感信息。
default_config_json() {
  cat <<JSON
{
  "version": "${APP_VERSION}",
  "settings": {
    "timezone": "Asia/Shanghai",
    "log_level": "INFO",
    "http_version": "1.1",
    "curl_retry": 3,
    "curl_retry_delay": 2,
    "connect_timeout": 10,
    "max_time": 30,
    "auto_create_missing": true,
    "default_ttl": 1,
    "default_proxied": false
  },
  "zones": [],
  "tasks": []
}
JSON
}

# 初始化配置文件，不覆盖已有配置。
init_config() {
  ensure_dirs
  if [[ ! -f "$CONFIG_FILE" ]]; then
    default_config_json > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    log_msg INFO "已创建空配置：${CONFIG_FILE}"
  fi
}

# 校验 JSON 配置是否可读。
validate_config_file() {
  [[ -f "$CONFIG_FILE" ]] || return 1
  jq -e '.settings and (.zones|type=="array") and (.tasks|type=="array")' "$CONFIG_FILE" >/dev/null 2>&1
}

# 保存 JSON 到配置文件，先写临时文件再原子替换，减少配置损坏风险。
save_config_from_stdin() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  jq '.' "$tmp" >/dev/null || { rm -f "$tmp"; log_msg ERROR "配置 JSON 校验失败，未保存。"; return 1; }
  install -m 600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

# 配置迁移：补齐 v1.3 新增字段。
migrate_config() {
  init_config
  if ! validate_config_file; then
    local bad="${CONFIG_FILE}.broken.$(date +%Y%m%d%H%M%S)"
    mv "$CONFIG_FILE" "$bad"
    default_config_json > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    log_msg WARN "旧配置损坏，已备份到 ${bad}，并创建空配置。"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  jq --arg ver "$APP_VERSION" '
    .version = $ver |
    .settings.timezone = (.settings.timezone // "Asia/Shanghai") |
    .settings.log_level = (.settings.log_level // "INFO") |
    .settings.http_version = (.settings.http_version // "1.1") |
    .settings.curl_retry = (.settings.curl_retry // 3) |
    .settings.curl_retry_delay = (.settings.curl_retry_delay // 2) |
    .settings.connect_timeout = (.settings.connect_timeout // 10) |
    .settings.max_time = (.settings.max_time // 30) |
    .settings.auto_create_missing = (.settings.auto_create_missing // true) |
    .settings.default_ttl = (.settings.default_ttl // 1) |
    .settings.default_proxied = (.settings.default_proxied // false) |
    .zones = (.zones // []) |
    .tasks = (.tasks // [])
  ' "$CONFIG_FILE" > "$tmp"
  install -m 600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

# ---------- 依赖和安装 ----------
# 检测包管理器。
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v apk >/dev/null 2>&1; then echo apk
  else echo unknown
  fi
}

# 安装 curl jq flock cron 等依赖。
install_deps() {
  local missing=() pm
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  command -v flock >/dev/null 2>&1 || missing+=(util-linux)
  [[ ${#missing[@]} -eq 0 ]] && return 0

  pm="$(detect_pkg_manager)"
  echo "准备安装依赖：${missing[*]}"
  case "$pm" in
    apt)
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq util-linux cron ca-certificates
      ;;
    dnf)
      dnf install -y curl jq util-linux cronie ca-certificates
      ;;
    yum)
      yum install -y curl jq util-linux cronie ca-certificates
      ;;
    apk)
      apk add --no-cache curl jq util-linux ca-certificates dcron
      ;;
    *)
      echo "无法识别包管理器，请手动安装 curl jq flock 后重试。" >&2
      exit 1
      ;;
  esac
}

# 安装 cfcname 命令本体。
install_self() {
  need_root
  install_deps
  ensure_dirs
  migrate_config
  if [[ "$(readlink -f "$0" 2>/dev/null || echo "$0")" != "$INSTALL_BIN" ]]; then
    install -m 755 "$0" "$INSTALL_BIN"
  else
    chmod 755 "$INSTALL_BIN"
  fi
  setup_scheduler
  log_msg INFO "已安装 ${APP_NAME} v${APP_VERSION} 到 ${INSTALL_BIN}"
  echo "安装完成。输入 sudo cfcname 进入菜单。"
}

# 卸载程序，但默认保留配置和日志。
uninstall_self() {
  need_root
  print_header
  echo "卸载会删除命令和定时器。配置文件默认保留。"
  if ! confirm_select "确认卸载 cfcname？"; then return 0; fi
  disable_scheduler || true
  rm -f "$INSTALL_BIN"
  log_msg INFO "已卸载命令：${INSTALL_BIN}"
  if confirm_select "是否同时删除配置、状态、日志？"; then
    rm -rf "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"
    echo "已删除配置、状态、日志。"
  else
    echo "已保留配置：${CONFIG_DIR}，状态：${STATE_DIR}，日志：${LOG_DIR}"
  fi
}

# ---------- 调度器 ----------
# 写入 systemd timer；用于每分钟检查是否需要切换。
setup_systemd_timer() {
  cat > "$SYSTEMD_SERVICE" <<UNIT
[Unit]
Description=cfcname Cloudflare CNAME scheduled switch
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_BIN} run --quiet
Nice=5
UNIT

  cat > "$SYSTEMD_TIMER" <<UNIT
[Unit]
Description=Run cfcname every minute

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=10s
Persistent=true
Unit=${APP_NAME}.service

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now "${APP_NAME}.timer" >/dev/null
  log_msg INFO "已启用 systemd timer：${APP_NAME}.timer"
}

# 写入 cron 任务；systemd 不可用时回退使用。
setup_cron_timer() {
  cat > "$CRON_FILE" <<CRON
# cfcname v${APP_VERSION} - run every minute
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root flock -n /run/${APP_NAME}.lock ${INSTALL_BIN} run --quiet >/dev/null 2>&1
CRON
  chmod 644 "$CRON_FILE"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
    systemctl reload cron >/dev/null 2>&1 || systemctl reload crond >/dev/null 2>&1 || true
  fi
  log_msg INFO "已启用 cron 定时任务：${CRON_FILE}"
}

# 启用定时器。优先 systemd，失败则回退 cron。
setup_scheduler() {
  if [[ ! -x "$INSTALL_BIN" && "$(readlink -f "$0" 2>/dev/null || echo "$0")" != "$INSTALL_BIN" ]]; then
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    setup_systemd_timer || setup_cron_timer
  else
    setup_cron_timer
  fi
}

# 禁用定时器。
disable_scheduler() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "${APP_NAME}.timer" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER" "$CRON_FILE"
  log_msg INFO "已移除定时器。"
}

# 查看定时器状态。
scheduler_status() {
  echo "systemd timer:"
  if command -v systemctl >/dev/null 2>&1 && [[ -f "$SYSTEMD_TIMER" ]]; then
    systemctl --no-pager status "${APP_NAME}.timer" || true
  else
    echo "  未检测到 systemd timer。"
  fi
  echo
  echo "cron:"
  if [[ -f "$CRON_FILE" ]]; then
    cat "$CRON_FILE"
  else
    echo "  未检测到 cron 文件。"
  fi
}

# ---------- Cloudflare API ----------
# 读取 curl 设置。
cf_setting() {
  local key="$1" default="$2"
  jq -r --arg k "$key" --arg d "$default" '.settings[$k] // $d' "$CONFIG_FILE"
}

# 判断 curl 是否支持某个参数。兼容 CentOS 7 等旧系统 curl，避免未知参数导致请求根本没有发出。
curl_supports_option() {
  local opt="$1"
  if curl --help all >/dev/null 2>&1; then
    curl --help all 2>/dev/null | grep -q -- "$opt"
  else
    curl --help 2>/dev/null | grep -q -- "$opt" || curl --manual 2>/dev/null | grep -q -- "$opt"
  fi
}

# 判断 HTTP 状态码是否值得重试。400/401/403 这类认证或权限错误不会重试，直接暴露真实原因。
is_retryable_http_code() {
  case "${1:-}" in
    408|425|429|500|502|503|504) return 0 ;;
    *) return 1 ;;
  esac
}

# 调用 Cloudflare API。
# v1.4 关键变化：不再依赖 curl --retry-all-errors，因为旧版 curl 不支持该参数；改为脚本自己循环重试。
cf_api() {
  local zone_id="$1" token="$2" method="$3" endpoint="$4" data="${5:-}"
  local tmp_body tmp_err http_code retry retry_delay connect_timeout max_time http_version curl_http_arg token_clean
  local attempts attempt rc curl_args shown_endpoint

  token_clean="$(sanitize_token "$token")"
  if [[ -z "$token_clean" ]]; then
    log_msg ERROR "Cloudflare API Token 为空，已停止请求。请重新编辑域名配置。"
    return 1
  fi
  if ! valid_zone_id "$zone_id"; then
    log_msg ERROR "Zone ID 格式不正确：${zone_id}；Zone ID 应为 32 位十六进制。"
    return 1
  fi

  retry="$(cf_setting curl_retry 3)"
  retry_delay="$(cf_setting curl_retry_delay 2)"
  connect_timeout="$(cf_setting connect_timeout 10)"
  max_time="$(cf_setting max_time 30)"
  http_version="$(cf_setting http_version 1.1)"

  [[ "$retry" =~ ^[0-9]+$ ]] || retry=3
  [[ "$retry_delay" =~ ^[0-9]+$ ]] || retry_delay=2
  [[ "$connect_timeout" =~ ^[0-9]+$ ]] || connect_timeout=10
  [[ "$max_time" =~ ^[0-9]+$ ]] || max_time=30
  attempts=$((retry + 1))

  # 老版本 curl 可能不支持 --http2 或 --http1.1。支持才加；不支持就让 curl 使用默认协议。
  if [[ "$http_version" == "2" || "$http_version" == "2.0" ]]; then
    curl_http_arg="--http2"
  else
    curl_http_arg="--http1.1"
  fi
  if ! curl_supports_option "$curl_http_arg"; then
    log_msg WARN "当前 curl 不支持 ${curl_http_arg}，将使用 curl 默认 HTTP 协议继续请求。"
    curl_http_arg=""
  fi

  tmp_body="$(mktemp)"
  tmp_err="$(mktemp)"
  shown_endpoint="${method} ${endpoint}"

  curl_args=(
    -sS
    --connect-timeout "$connect_timeout"
    --max-time "$max_time"
    -o "$tmp_body"
    -w '%{http_code}'
    -X "$method"
    "${API_BASE}${endpoint}"
    -H "Authorization: Bearer ${token_clean}"
    -H "Content-Type: application/json"
  )
  [[ -n "$curl_http_arg" ]] && curl_args=("$curl_http_arg" "${curl_args[@]}")
  if [[ -n "$data" ]]; then
    curl_args+=(--data "$data")
  fi

  attempt=1
  while (( attempt <= attempts )); do
    : > "$tmp_body"
    : > "$tmp_err"

    set +e
    http_code="$(curl "${curl_args[@]}" 2>"$tmp_err")"
    rc=$?
    set -e

    # curl 自身失败，例如 DNS、TLS、连接超时、网络中断。脚本层面重试，不依赖 curl 新参数。
    if [[ $rc -ne 0 ]]; then
      if (( attempt < attempts )); then
        log_msg WARN "curl 请求失败 rc=${rc}，准备第 $((attempt + 1))/${attempts} 次重试：${shown_endpoint}"
        if [[ -s "$tmp_err" ]]; then
          while IFS= read -r line; do [[ -n "$line" ]] && log_msg DEBUG "curl错误：${line}"; done < "$tmp_err"
        fi
        sleep "$retry_delay"
        attempt=$((attempt + 1))
        continue
      fi

      log_msg ERROR "curl 请求失败 rc=${rc}：${shown_endpoint}"
      if [[ -s "$tmp_err" ]]; then
        while IFS= read -r line; do [[ -n "$line" ]] && log_msg ERROR "curl错误：${line}"; done < "$tmp_err"
      fi
      rm -f "$tmp_body" "$tmp_err"
      return 1
    fi

    log_msg DEBUG "Cloudflare API HTTP ${http_code}：${shown_endpoint}"

    # Cloudflare 临时错误才重试；认证/权限类错误不重试，直接显示 API 返回的原因。
    if is_retryable_http_code "$http_code" && (( attempt < attempts )); then
      log_msg WARN "Cloudflare API HTTP ${http_code}，准备第 $((attempt + 1))/${attempts} 次重试：${shown_endpoint}"
      sleep "$retry_delay"
      attempt=$((attempt + 1))
      continue
    fi

    break
  done

  if [[ ! "$http_code" =~ ^2 ]]; then
    log_msg ERROR "Cloudflare API HTTP ${http_code}：${shown_endpoint}"
    if jq -e '.errors? | length > 0' "$tmp_body" >/dev/null 2>&1; then
      jq -r '.errors[]? | (.message // .)' "$tmp_body" | while read -r line; do
        [[ -n "$line" ]] && log_msg ERROR "API错误：${line}"
      done
    else
      log_msg ERROR "API响应：$(cat "$tmp_body")"
    fi
    rm -f "$tmp_body" "$tmp_err"
    return 1
  fi

  if ! jq -e '.success == true' "$tmp_body" >/dev/null 2>&1; then
    log_msg ERROR "Cloudflare API 返回 success=false：${shown_endpoint}"
    jq -r '.errors[]? | (.message // .)' "$tmp_body" | while read -r line; do
      [[ -n "$line" ]] && log_msg ERROR "API错误：${line}"
    done
    rm -f "$tmp_body" "$tmp_err"
    return 1
  fi

  cat "$tmp_body"
  rm -f "$tmp_body" "$tmp_err"
}

# 测试 Zone ID + Token 是否能访问 DNS Records 列表。
test_zone_api() {
  local zone_id="$1" token="$2"
  cf_api "$zone_id" "$token" GET "/zones/${zone_id}/dns_records?per_page=1" >/dev/null
}

# 按记录名查询 DNS 记录。
list_records_by_name() {
  local zone_id="$1" token="$2" name="$3" encoded
  encoded="$(urlencode "$name")"
  cf_api "$zone_id" "$token" GET "/zones/${zone_id}/dns_records?name=${encoded}&per_page=100"
}

# 查询单条 CNAME。遇到同名非 CNAME 或多个 CNAME 会报错停止。
get_single_cname_record() {
  local zone_id="$1" token="$2" name="$3" resp total cname_count
  resp="$(list_records_by_name "$zone_id" "$token" "$name")" || return 1
  total="$(jq '.result | length' <<<"$resp")"
  cname_count="$(jq '[.result[] | select(.type == "CNAME")] | length' <<<"$resp")"

  if [[ "$total" -gt "$cname_count" ]]; then
    log_msg ERROR "${name} 下存在非 CNAME 记录。为避免误删，脚本停止。"
    jq -r '.result[] | "type=\(.type) name=\(.name) content=\(.content) id=\(.id)"' <<<"$resp" | while read -r line; do log_msg ERROR "$line"; done
    return 2
  fi
  if [[ "$cname_count" -gt 1 ]]; then
    log_msg ERROR "${name} 存在多个 CNAME 记录，无法判断应更新哪一条。"
    return 2
  fi
  if [[ "$cname_count" -eq 0 ]]; then
    echo ""
  else
    jq -c '.result[] | select(.type == "CNAME")' <<<"$resp"
  fi
}

# 创建或更新 CNAME。
update_or_create_cname() {
  local zone_id="$1" token="$2" name="$3" target="$4" ttl="$5" proxied="$6" auto_create="$7"
  local record id current old_ttl old_proxied payload
  target="$(normalize_cname_target "$target")"

  if ! valid_domain "$name" || ! valid_domain "$target"; then
    log_msg ERROR "域名格式不正确：name=${name}, target=${target}"
    return 1
  fi

  record="$(get_single_cname_record "$zone_id" "$token" "$name")" || return 1

  if [[ -z "$record" ]]; then
    if [[ "$auto_create" != "true" ]]; then
      log_msg ERROR "${name} 不存在，且未开启自动创建。"
      return 1
    fi
    payload="$(jq -n --arg name "$name" --arg content "$target" --argjson ttl "$ttl" --argjson proxied "$proxied" '{type:"CNAME", name:$name, content:$content, ttl:$ttl, proxied:$proxied}')"
    cf_api "$zone_id" "$token" POST "/zones/${zone_id}/dns_records" "$payload" >/dev/null || return 1
    log_msg INFO "已创建 CNAME：${name} -> ${target}"
    return 0
  fi

  id="$(jq -r '.id' <<<"$record")"
  current="$(jq -r '.content' <<<"$record")"
  old_ttl="$(jq -r '.ttl // 1' <<<"$record")"
  old_proxied="$(jq -r '.proxied // false' <<<"$record")"
  if [[ "$current" == "$target" ]]; then
    log_msg INFO "无需更新：${name} 已指向 ${target}"
    return 0
  fi

  payload="$(jq -n --arg name "$name" --arg content "$target" --argjson ttl "$old_ttl" --argjson proxied "$old_proxied" '{type:"CNAME", name:$name, content:$content, ttl:$ttl, proxied:$proxied}')"
  cf_api "$zone_id" "$token" PATCH "/zones/${zone_id}/dns_records/${id}" "$payload" >/dev/null || return 1
  log_msg INFO "已更新 CNAME：${name} ${current} -> ${target}"
}

# ---------- Zone 配置管理 ----------
# 选择一个 Zone 配置，返回 zone id。
select_zone() {
  local count idx zid
  count="$(jq '.zones | length' "$CONFIG_FILE")"
  if [[ "$count" -eq 0 ]]; then
    echo "当前没有域名配置，请先添加。" >&2
    return 1
  fi
  echo "可选域名配置：" >&2
  jq -r '.zones | to_entries[] | "  \(.key+1)) \(.value.name)  ZoneID=\(.value.zone_id)  Token=" + (.value.token[0:5] // "") + "..."' "$CONFIG_FILE" >&2
  while true; do
    read -r -p "请选择 [1-${count}]: " idx || return 1
    [[ "$idx" =~ ^[0-9]+$ ]] || { echo "请输入数字" >&2; continue; }
    (( idx >= 1 && idx <= count )) || { echo "超出范围" >&2; continue; }
    zid="$(jq -r --argjson i "$((idx-1))" '.zones[$i].id' "$CONFIG_FILE")"
    echo "$zid"
    return 0
  done
}

# 添加或编辑域名配置。保存前会立即 API 测试。
add_zone_wizard() {
  print_header
  echo "添加 Cloudflare 域名配置"
  echo "说明：Zone ID 必须是 32 位十六进制；Token 建议只给 DNS Read + DNS Write 权限。"
  echo
  local zone_name zone_id token zone_obj zone_ref
  while true; do
    zone_name="$(prompt_input "请输入根域名" "example.com")"
    zone_name="${zone_name%.}"
    valid_domain "$zone_name" && break
    echo "域名格式不正确。示例：example.com"
  done
  while true; do
    zone_id="$(prompt_input "请输入 Cloudflare Zone ID" "")"
    if valid_zone_id "$zone_id"; then break; fi
    echo "Zone ID 格式不正确，应为 32 位十六进制。不要输入根域名。"
  done
  token="$(prompt_secret_token "请输入 Cloudflare API Token")"

  echo
  echo "准备测试 API 权限..."
  if ! test_zone_api "$zone_id" "$token"; then
    echo
    echo "API 测试失败，常见原因："
    echo "1. Token 粘贴为空或被换行打断。"
    echo "2. Token 没有该 Zone 的 DNS Read/DNS Write 权限。"
    echo "3. Zone ID 填成了根域名。"
    echo "4. 服务器网络无法访问 api.cloudflare.com。"
    return 1
  fi
  echo "API 测试通过。"

  zone_ref="zone_$(date +%Y%m%d%H%M%S)_$((RANDOM%9999))"
  zone_obj="$(jq -n --arg id "$zone_ref" --arg name "$zone_name" --arg zone_id "$zone_id" --arg token "$token" '{id:$id, name:$name, zone_id:$zone_id, token:$token}')"
  jq --argjson z "$zone_obj" '.zones += [$z]' "$CONFIG_FILE" | save_config_from_stdin
  log_msg INFO "已保存域名配置：${zone_name}，ZoneID=${zone_id}，Token=$(mask_token "$token")"
}

# 列出域名配置。
list_zones() {
  print_header
  echo "域名配置列表"
  echo
  if [[ "$(jq '.zones | length' "$CONFIG_FILE")" -eq 0 ]]; then
    echo "暂无域名配置。"
  else
    jq -r '.zones[] | "- 名称: \(.name)\n  内部ID: \(.id)\n  Zone ID: \(.zone_id)\n  Token: \(.token[0:5])...\(.token[-4:])\n"' "$CONFIG_FILE"
  fi
}

# 测试指定域名配置。
test_zone_menu() {
  print_header
  local zid zone_id token name
  zid="$(select_zone)" || return 0
  zone_id="$(jq -r --arg id "$zid" '.zones[] | select(.id==$id) | .zone_id' "$CONFIG_FILE")"
  token="$(jq -r --arg id "$zid" '.zones[] | select(.id==$id) | .token' "$CONFIG_FILE")"
  name="$(jq -r --arg id "$zid" '.zones[] | select(.id==$id) | .name' "$CONFIG_FILE")"
  echo "正在测试：${name}"
  if test_zone_api "$zone_id" "$token"; then
    echo "API 测试通过。"
  else
    echo "API 测试失败，请查看日志：${LOG_FILE}"
  fi
}

# 编辑域名配置。
edit_zone_menu() {
  print_header
  local zid old_name old_zone_id old_token name zone_id token update_token
  zid="$(select_zone)" || return 0
  old_name="$(jq -r --arg id "$zid" '.zones[] | select(.id==$id) | .name' "$CONFIG_FILE")"
  old_zone_id="$(jq -r --arg id "$zid" '.zones[] | select(.id==$id) | .zone_id' "$CONFIG_FILE")"
  old_token="$(jq -r --arg id "$zid" '.zones[] | select(.id==$id) | .token' "$CONFIG_FILE")"

  while true; do
    name="$(prompt_input "根域名" "$old_name")"; name="${name%.}"
    valid_domain "$name" && break
    echo "域名格式不正确。"
  done
  while true; do
    zone_id="$(prompt_input "Zone ID" "$old_zone_id")"
    valid_zone_id "$zone_id" && break
    echo "Zone ID 格式不正确，应为 32 位十六进制。"
  done
  echo "当前 Token：$(mask_token "$old_token")"
  if confirm_select "是否更换 Token？"; then
    token="$(prompt_secret_token "请输入新的 Cloudflare API Token")"
  else
    token="$old_token"
  fi

  echo "正在测试新配置..."
  test_zone_api "$zone_id" "$token" || { echo "测试失败，未保存。"; return 1; }
  jq --arg id "$zid" --arg name "$name" --arg zone_id "$zone_id" --arg token "$token" '
    (.zones[] | select(.id==$id)) |= (.name=$name | .zone_id=$zone_id | .token=$token)
  ' "$CONFIG_FILE" | save_config_from_stdin
  log_msg INFO "已修改域名配置：${name}，ZoneID=${zone_id}，Token=$(mask_token "$token")"
}

# 删除域名配置。已被任务引用时会提醒。
delete_zone_menu() {
  print_header
  local zid refs
  zid="$(select_zone)" || return 0
  refs="$(jq --arg id "$zid" '[.tasks[] | select(.zone_ref==$id)] | length' "$CONFIG_FILE")"
  if [[ "$refs" -gt 0 ]]; then
    echo "该域名配置被 ${refs} 个任务引用。删除后这些任务将不可用。"
  fi
  confirm_select "确认删除该域名配置？" || return 0
  jq --arg id "$zid" '.zones = [.zones[] | select(.id != $id)]' "$CONFIG_FILE" | save_config_from_stdin
  log_msg INFO "已删除域名配置：${zid}"
}

# 域名配置管理菜单。
zone_menu() {
  while true; do
    print_header
    echo "🌐 域名 / Token 配置管理"
    echo
    echo "  1) 查看域名配置"
    echo "  2) 添加域名配置"
    echo "  3) 编辑域名配置"
    echo "  4) 测试 API 权限"
    echo "  5) 删除域名配置"
    echo "  0) 返回主菜单"
    echo
    read -r -p "请选择: " ans || true
    case "$ans" in
      1) list_zones; pause_enter ;;
      2) add_zone_wizard; pause_enter ;;
      3) edit_zone_menu; pause_enter ;;
      4) test_zone_menu; pause_enter ;;
      5) delete_zone_menu; pause_enter ;;
      0) return 0 ;;
      *) log_msg WARN "无效选项"; pause_enter ;;
    esac
  done
}

# ---------- 任务管理 ----------
# 选择任务，返回 task id。
select_task() {
  local count idx tid
  count="$(jq '.tasks | length' "$CONFIG_FILE")"
  if [[ "$count" -eq 0 ]]; then
    echo "当前没有任务。" >&2
    return 1
  fi
  echo "可选任务：" >&2
  jq -r '.tasks | to_entries[] | "  \(.key+1)) " + (if .value.enabled then "✅" else "⏸️" end) + " " + .value.name + "  ID=" + .value.id' "$CONFIG_FILE" >&2
  while true; do
    read -r -p "请选择 [1-${count}]: " idx || return 1
    [[ "$idx" =~ ^[0-9]+$ ]] || { echo "请输入数字" >&2; continue; }
    (( idx >= 1 && idx <= count )) || { echo "超出范围" >&2; continue; }
    tid="$(jq -r --argjson i "$((idx-1))" '.tasks[$i].id' "$CONFIG_FILE")"
    echo "$tid"
    return 0
  done
}

# 列出任务。
list_tasks() {
  print_header
  echo "任务列表"
  echo
  if [[ "$(jq '.tasks | length' "$CONFIG_FILE")" -eq 0 ]]; then
    echo "暂无任务。"
    return 0
  fi
  jq -r '
    . as $root |
    .tasks[] |
    "- " + (if .enabled then "✅" else "⏸️" end) + " " + .name + "\n" +
    "  ID: " + .id + "\n" +
    "  域名配置: " + ((.zone_ref as $z | $root.zones[]? | select(.id==$z) | .name) // .zone_ref) + "\n" +
    "  自动创建缺失记录: " + ((.auto_create_missing // true)|tostring) + "\n" +
    "  时间点: " + ([.schedule[].time] | join(", ")) + "\n" +
    "  记录: " + ([.records[].name] | join(", ")) + "\n"
  ' "$CONFIG_FILE"
}

# 添加任务向导。支持多个 CNAME 和多个时间点。
add_task_wizard() {
  print_header
  echo "新增 CNAME 定时切换任务"
  echo
  local zone_ref zone_name task_name task_id record_names_json schedule_json add_more rec target time_point records_count ttl proxied auto_create
  zone_ref="$(select_zone)" || { echo "请先添加域名配置。"; return 1; }
  zone_name="$(jq -r --arg id "$zone_ref" '.zones[] | select(.id==$id) | .name' "$CONFIG_FILE")"
  task_name="$(prompt_input "任务名称" "example-cname-switch")"
  task_id="$(gen_id task)"
  ttl="$(jq -r '.settings.default_ttl' "$CONFIG_FILE")"
  proxied="$(jq -r '.settings.default_proxied' "$CONFIG_FILE")"
  auto_create="$(jq -r '.settings.auto_create_missing' "$CONFIG_FILE")"

  record_names_json='[]'
  while true; do
    rec="$(prompt_input "请输入要管理的 CNAME 记录名，例如 www 或 www.example.com" "www")"
    rec="$(normalize_record_name "$rec" "$zone_name")"
    if ! valid_domain "$rec"; then echo "记录名格式不正确。"; continue; fi
    record_names_json="$(jq --arg name "$rec" --argjson ttl "$ttl" --argjson proxied "$proxied" '. + [{name:$name, ttl:$ttl, proxied:$proxied}]' <<<"$record_names_json")"
    if ! confirm_select "是否继续添加其它 CNAME 记录？"; then break; fi
  done

  records_count="$(jq 'length' <<<"$record_names_json")"
  [[ "$records_count" -gt 0 ]] || { echo "至少需要一个 CNAME 记录。"; return 1; }

  schedule_json='[]'
  while true; do
    while true; do
      time_point="$(prompt_input "请输入切换时间，格式 HH:MM" "21:00")"
      valid_hhmm "$time_point" && break
      echo "时间格式不正确，例如 21:00 或 02:00。"
    done
    local targets_json='{}'
    while IFS= read -r rec; do
      target="$(prompt_input "${time_point} 时 ${rec} 指向的 CNAME 目标" "target-a.example.net")"
      target="$(normalize_cname_target "$target")"
      if ! valid_domain "$target"; then echo "目标格式不正确。"; return 1; fi
      targets_json="$(jq --arg name "$rec" --arg target "$target" '. + {($name):$target}' <<<"$targets_json")"
    done < <(jq -r '.[].name' <<<"$record_names_json")
    schedule_json="$(jq --arg t "$time_point" --argjson targets "$targets_json" '. + [{time:$t, targets:$targets}]' <<<"$schedule_json")"
    if ! confirm_select "是否继续添加其它切换时间点？"; then break; fi
  done

  local task_json
  task_json="$(jq -n \
    --arg id "$task_id" \
    --arg name "$task_name" \
    --arg zone_ref "$zone_ref" \
    --argjson records "$record_names_json" \
    --argjson schedule "$schedule_json" \
    --argjson auto_create "$auto_create" \
    '{id:$id, name:$name, enabled:true, zone_ref:$zone_ref, auto_create_missing:$auto_create, records:$records, schedule:$schedule}')"

  echo
  echo "任务预览："
  jq '.' <<<"$task_json"
  confirm_select "确认保存并启用该任务？" || return 0
  jq --argjson task "$task_json" '.tasks += [$task]' "$CONFIG_FILE" | save_config_from_stdin
  log_msg INFO "已新增任务：${task_name}，ID=${task_id}"
  setup_scheduler || true

  if confirm_select "是否立即按当前时间窗口执行一次？"; then
    run_tasks "force" "$task_id"
  fi
}

# 启用或停用任务。
toggle_task_menu() {
  print_header
  local tid enabled new
  tid="$(select_task)" || return 0
  enabled="$(jq -r --arg id "$tid" '.tasks[] | select(.id==$id) | .enabled' "$CONFIG_FILE")"
  if [[ "$enabled" == "true" ]]; then new=false; else new=true; fi
  jq --arg id "$tid" --argjson e "$new" '(.tasks[] | select(.id==$id)).enabled = $e' "$CONFIG_FILE" | save_config_from_stdin
  log_msg INFO "已将任务 ${tid} 启用状态改为 ${new}"
}

# 删除任务。
delete_task_menu() {
  print_header
  local tid
  tid="$(select_task)" || return 0
  confirm_select "确认删除该任务？" || return 0
  jq --arg id "$tid" '.tasks = [.tasks[] | select(.id != $id)]' "$CONFIG_FILE" | save_config_from_stdin
  rm -f "${STATE_DIR}/task_${tid}.state" 2>/dev/null || true
  log_msg INFO "已删除任务：${tid}"
}

# 编辑任务：提供重建式编辑，降低复杂度和 bug 率。
edit_task_menu() {
  print_header
  echo "编辑任务建议：删除旧任务后重新添加，避免复杂 JSON 手工修改导致错误。"
  echo "当前版本也支持直接打开配置文件修改：${CONFIG_FILE}"
  echo
  list_tasks
  echo
  echo "可选操作："
  echo "  1) 启用/停用任务"
  echo "  2) 删除任务后重新创建"
  echo "  0) 返回"
  read -r -p "请选择: " ans || true
  case "$ans" in
    1) toggle_task_menu ;;
    2) delete_task_menu; add_task_wizard ;;
    0) return 0 ;;
    *) echo "无效选项" ;;
  esac
}

# 手动修改指定 CNAME，不依赖任务。
manual_update_cname_menu() {
  print_header
  echo "手动立即修改 CNAME"
  echo
  local zone_ref zone_id token zone_name name target ttl proxied auto_create
  zone_ref="$(select_zone)" || return 0
  zone_id="$(jq -r --arg id "$zone_ref" '.zones[] | select(.id==$id) | .zone_id' "$CONFIG_FILE")"
  token="$(jq -r --arg id "$zone_ref" '.zones[] | select(.id==$id) | .token' "$CONFIG_FILE")"
  zone_name="$(jq -r --arg id "$zone_ref" '.zones[] | select(.id==$id) | .name' "$CONFIG_FILE")"
  ttl="$(jq -r '.settings.default_ttl' "$CONFIG_FILE")"
  proxied="$(jq -r '.settings.default_proxied' "$CONFIG_FILE")"
  auto_create="$(jq -r '.settings.auto_create_missing' "$CONFIG_FILE")"
  name="$(prompt_input "要修改的 CNAME 记录名，例如 www 或 www.example.com" "www")"
  name="$(normalize_record_name "$name" "$zone_name")"
  target="$(prompt_input "新的 CNAME 目标" "target-b.example.net")"
  target="$(normalize_cname_target "$target")"
  echo
  echo "即将修改：${name} -> ${target}"
  confirm_select "确认执行？" || return 0
  backup_records "$zone_id" "$token" "$name" "manual" || true
  update_or_create_cname "$zone_id" "$token" "$name" "$target" "$ttl" "$proxied" "$auto_create"
}

# 任务管理菜单。
task_menu() {
  while true; do
    print_header
    echo "🧩 CNAME 切换任务管理"
    echo
    echo "  1) 查看任务"
    echo "  2) 新增任务"
    echo "  3) 编辑任务 / 启停任务"
    echo "  4) 删除任务"
    echo "  5) 手动立即修改 CNAME"
    echo "  6) 立即执行所有启用任务"
    echo "  0) 返回主菜单"
    echo
    read -r -p "请选择: " ans || true
    case "$ans" in
      1) list_tasks; pause_enter ;;
      2) add_task_wizard; pause_enter ;;
      3) edit_task_menu; pause_enter ;;
      4) delete_task_menu; pause_enter ;;
      5) manual_update_cname_menu; pause_enter ;;
      6) run_tasks force ""; pause_enter ;;
      0) return 0 ;;
      *) log_msg WARN "无效选项"; pause_enter ;;
    esac
  done
}

# ---------- 任务执行 ----------
# 根据时区获取当前分钟数。
current_minutes_of_day() {
  local tz
  tz="$(jq -r '.settings.timezone // "Asia/Shanghai"' "$CONFIG_FILE")"
  TZ="$tz" date '+%H %M' | awk '{print $1*60+$2}'
}

# 选择当前应该生效的 schedule index。
select_schedule_index() {
  local task_json="$1" now_min t h m min idx=0 best=-1 max_min=-1 max_idx=0 i=0
  now_min="$(current_minutes_of_day)"
  while IFS= read -r t; do
    h="${t%:*}"; m="${t#*:}"; min=$((10#$h * 60 + 10#$m))
    if (( min <= now_min && min >= best )); then best=$min; idx=$i; fi
    if (( min > max_min )); then max_min=$min; max_idx=$i; fi
    i=$((i+1))
  done < <(jq -r '.schedule[].time' <<<"$task_json")
  if (( best == -1 )); then echo "$max_idx"; else echo "$idx"; fi
}

# 生成任务状态 key。目标不变时不会重复调用 Cloudflare。
schedule_state_key() {
  local task_id="$1" schedule_json="$2"
  printf '%s|%s' "$task_id" "$(jq -cS '.' <<<"$schedule_json")" | sha256sum | awk '{print $1}'
}

# 修改前备份记录。只备份脚本即将触碰的记录。
backup_records() {
  local zone_id="$1" token="$2" names_input="$3" reason="$4" ts file tmp name resp
  ts="$(date +%Y%m%d_%H%M%S)"
  file="${BACKUP_DIR}/backup_${ts}_${reason}.json"
  tmp="$(mktemp)"
  echo '[]' > "$tmp"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    resp="$(list_records_by_name "$zone_id" "$token" "$name")" || continue
    jq --argjson add "$(jq '.result' <<<"$resp")" '. + $add' "$tmp" > "${tmp}.new"
    mv "${tmp}.new" "$tmp"
  done <<<"$(printf '%s\n' "$names_input")"

  jq -n --arg version "$APP_VERSION" --arg reason "$reason" --arg created_at "$(date '+%Y-%m-%d %H:%M:%S %z')" --slurpfile records "$tmp" \
    '{version:$version, reason:$reason, created_at:$created_at, records:$records[0]}' > "$file"
  chmod 600 "$file"
  rm -f "$tmp"
  log_msg INFO "已备份 DNS 状态：${file}"
}

# 执行单个任务。
apply_task() {
  local task_json="$1" force="${2:-normal}" task_id task_name zone_ref zone_json zone_id token idx schedule_json key state_file old_key auto_create ttl proxied names
  task_id="$(jq -r '.id' <<<"$task_json")"
  task_name="$(jq -r '.name' <<<"$task_json")"
  zone_ref="$(jq -r '.zone_ref' <<<"$task_json")"
  zone_json="$(jq -c --arg id "$zone_ref" '.zones[] | select(.id==$id)' "$CONFIG_FILE")"
  if [[ -z "$zone_json" || "$zone_json" == "null" ]]; then
    log_msg ERROR "任务 ${task_name} 引用的域名配置不存在：${zone_ref}"
    return 1
  fi
  zone_id="$(jq -r '.zone_id' <<<"$zone_json")"
  token="$(jq -r '.token' <<<"$zone_json")"
  idx="$(select_schedule_index "$task_json")"
  schedule_json="$(jq -c --argjson i "$idx" '.schedule[$i]' <<<"$task_json")"
  key="$(schedule_state_key "$task_id" "$schedule_json")"
  state_file="${STATE_DIR}/task_${task_id}.state"
  old_key="$(cat "$state_file" 2>/dev/null || true)"

  if [[ "$force" != "force" && "$key" == "$old_key" ]]; then
    log_msg DEBUG "任务 ${task_name} 当前时间点已执行过，跳过。"
    return 0
  fi

  auto_create="$(jq -r '.auto_create_missing // .settings.auto_create_missing // true' <<<"$(jq --argjson task "$task_json" '. + {task:$task}' "$CONFIG_FILE")" 2>/dev/null || echo true)"
  auto_create="$(jq -r --arg id "$task_id" '(.tasks[] | select(.id==$id) | .auto_create_missing) // .settings.auto_create_missing // true' "$CONFIG_FILE")"
  names="$(jq -r '.targets | keys[]' <<<"$schedule_json")"
  backup_records "$zone_id" "$token" "$names" "$task_id" || true

  log_msg INFO "开始执行任务：${task_name}，时间点：$(jq -r '.time' <<<"$schedule_json")"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local target rec_conf
    target="$(jq -r --arg n "$name" '.targets[$n]' <<<"$schedule_json")"
    rec_conf="$(jq -c --arg n "$name" '.records[]? | select(.name==$n)' <<<"$task_json")"
    ttl="$(jq -r '.ttl // 1' <<<"${rec_conf:-{}}")"
    proxied="$(jq -r '.proxied // false' <<<"${rec_conf:-{}}")"
    update_or_create_cname "$zone_id" "$token" "$name" "$target" "$ttl" "$proxied" "$auto_create" || return 1
  done <<<"$names"

  echo "$key" > "$state_file"
  chmod 600 "$state_file"
  log_msg INFO "任务完成：${task_name}"
}

# 执行所有启用任务，或指定任务。
run_tasks() {
  local force="${1:-normal}" only_task="${2:-}" tasks
  migrate_config
  if [[ -n "$only_task" ]]; then
    tasks="$(jq -c --arg id "$only_task" '[.tasks[] | select(.id==$id)]' "$CONFIG_FILE")"
  else
    tasks="$(jq -c '[.tasks[] | select(.enabled==true)]' "$CONFIG_FILE")"
  fi
  if [[ "$(jq 'length' <<<"$tasks")" -eq 0 ]]; then
    log_msg DEBUG "没有需要执行的启用任务。"
    return 0
  fi
  jq -c '.[]' <<<"$tasks" | while read -r task; do
    apply_task "$task" "$force" || true
  done
}

# ---------- 备份恢复 ----------
# 列出备份。
list_backups() {
  print_header
  echo "DNS 备份列表"
  echo
  ls -1t "$BACKUP_DIR"/*.json 2>/dev/null | head -n 30 || echo "暂无备份。"
}

# 恢复最近一次备份中的 CNAME 目标。
restore_backup_menu() {
  print_header
  local files file idx zone_ref zone_id token
  mapfile -t files < <(ls -1t "$BACKUP_DIR"/*.json 2>/dev/null | head -n 20 || true)
  if [[ ${#files[@]} -eq 0 ]]; then echo "暂无备份。"; return 0; fi
  echo "选择要恢复的备份："
  local i=1
  for file in "${files[@]}"; do echo "  $i) $file"; i=$((i+1)); done
  read -r -p "请选择 [1-${#files[@]}]: " idx || return 0
  [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=${#files[@]} )) || { echo "无效选择"; return 1; }
  file="${files[$((idx-1))]}"

  echo "恢复需要选择对应 Cloudflare 域名配置，用于 API 权限。"
  zone_ref="$(select_zone)" || return 0
  zone_id="$(jq -r --arg id "$zone_ref" '.zones[] | select(.id==$id) | .zone_id' "$CONFIG_FILE")"
  token="$(jq -r --arg id "$zone_ref" '.zones[] | select(.id==$id) | .token' "$CONFIG_FILE")"

  echo "将恢复备份中的 CNAME 记录目标：${file}"
  confirm_select "确认恢复？" || return 0
  jq -c '.records[] | select(.type=="CNAME")' "$file" | while read -r rec; do
    local name content ttl proxied
    name="$(jq -r '.name' <<<"$rec")"
    content="$(jq -r '.content' <<<"$rec")"
    ttl="$(jq -r '.ttl // 1' <<<"$rec")"
    proxied="$(jq -r '.proxied // false' <<<"$rec")"
    update_or_create_cname "$zone_id" "$token" "$name" "$content" "$ttl" "$proxied" true || true
  done
  log_msg INFO "备份恢复完成：${file}"
}

# 备份管理菜单。
backup_menu() {
  while true; do
    print_header
    echo "💾 备份 / 恢复"
    echo
    echo "  1) 查看最近备份"
    echo "  2) 从备份恢复 CNAME 目标"
    echo "  0) 返回主菜单"
    echo
    read -r -p "请选择: " ans || true
    case "$ans" in
      1) list_backups; pause_enter ;;
      2) restore_backup_menu; pause_enter ;;
      0) return 0 ;;
      *) log_msg WARN "无效选项"; pause_enter ;;
    esac
  done
}

# ---------- 系统设置 ----------
# 查看当前设置。
show_settings() {
  print_header
  echo "当前系统设置"
  echo
  jq '.settings' "$CONFIG_FILE"
  echo
  scheduler_status
}

# 设置日志等级。
set_log_level_menu() {
  print_header
  echo "选择日志等级："
  echo "  1) DEBUG  最详细，排障用"
  echo "  2) INFO   默认，记录主要动作"
  echo "  3) WARN   只记录警告和错误"
  echo "  4) ERROR  只记录错误"
  echo "  5) OFF    关闭日志"
  read -r -p "请选择 [1-5]: " ans || true
  local level
  case "$ans" in
    1) level=DEBUG ;;
    2) level=INFO ;;
    3) level=WARN ;;
    4) level=ERROR ;;
    5) level=OFF ;;
    *) echo "无效选项"; return 1 ;;
  esac
  jq --arg level "$level" '.settings.log_level=$level' "$CONFIG_FILE" | save_config_from_stdin
  log_msg INFO "日志等级已设置为：${level}"
}

# 设置 curl 网络参数。
set_curl_menu() {
  print_header
  local http retry delay conn max
  echo "curl 网络参数设置"
  echo "建议：HTTP 版本保持 1.1；v1.4 已改为脚本内置重试，兼容旧版 curl。"
  http="$(prompt_input "HTTP 版本，填 1.1 或 2" "$(jq -r '.settings.http_version' "$CONFIG_FILE")")"
  [[ "$http" == "2" || "$http" == "2.0" ]] && http="2" || http="1.1"
  retry="$(prompt_input "失败重试次数" "$(jq -r '.settings.curl_retry' "$CONFIG_FILE")")"
  delay="$(prompt_input "失败重试间隔秒数" "$(jq -r '.settings.curl_retry_delay' "$CONFIG_FILE")")"
  conn="$(prompt_input "连接超时秒数" "$(jq -r '.settings.connect_timeout' "$CONFIG_FILE")")"
  max="$(prompt_input "单次请求最大耗时秒数" "$(jq -r '.settings.max_time' "$CONFIG_FILE")")"
  jq --arg http "$http" --argjson retry "$retry" --argjson delay "$delay" --argjson conn "$conn" --argjson max "$max" '
    .settings.http_version=$http |
    .settings.curl_retry=$retry |
    .settings.curl_retry_delay=$delay |
    .settings.connect_timeout=$conn |
    .settings.max_time=$max
  ' "$CONFIG_FILE" | save_config_from_stdin
  log_msg INFO "curl 网络参数已更新。"
}

# 设置时区和自动创建策略。
set_general_menu() {
  print_header
  local tz auto ttl proxied
  tz="$(prompt_input "定时判断时区" "$(jq -r '.settings.timezone' "$CONFIG_FILE")")"
  echo "缺失 CNAME 记录时是否自动创建？"
  if confirm_select "开启自动创建缺失 CNAME？"; then auto=true; else auto=false; fi
  ttl="$(prompt_input "默认 TTL，1 表示 Cloudflare Auto" "$(jq -r '.settings.default_ttl' "$CONFIG_FILE")")"
  echo "CNAME 是否开启 Cloudflare 代理 proxied？普通解析建议 false。"
  if confirm_select "默认开启 proxied？"; then proxied=true; else proxied=false; fi
  jq --arg tz "$tz" --argjson auto "$auto" --argjson ttl "$ttl" --argjson proxied "$proxied" '
    .settings.timezone=$tz |
    .settings.auto_create_missing=$auto |
    .settings.default_ttl=$ttl |
    .settings.default_proxied=$proxied
  ' "$CONFIG_FILE" | save_config_from_stdin
  log_msg INFO "通用设置已更新。"
}

# 系统设置菜单。
settings_menu() {
  while true; do
    print_header
    echo "⚙️  系统设置 / 日志等级"
    echo
    echo "  1) 查看当前设置和定时器状态"
    echo "  2) 设置日志等级"
    echo "  3) 设置 curl 网络参数"
    echo "  4) 设置时区 / 默认 TTL / 自动创建"
    echo "  5) 重装/修复定时器"
    echo "  6) 停用定时器"
    echo "  7) 查看最近 80 行日志"
    echo "  8) 实时查看日志"
    echo "  0) 返回主菜单"
    echo
    read -r -p "请选择: " ans || true
    case "$ans" in
      1) show_settings; pause_enter ;;
      2) set_log_level_menu; pause_enter ;;
      3) set_curl_menu; pause_enter ;;
      4) set_general_menu; pause_enter ;;
      5) setup_scheduler; pause_enter ;;
      6) disable_scheduler; pause_enter ;;
      7) print_header; tail -n 80 "$LOG_FILE" 2>/dev/null || echo "暂无日志"; pause_enter ;;
      8) print_header; echo "按 Ctrl+C 退出"; tail -f "$LOG_FILE" ;;
      0) return 0 ;;
      *) log_msg WARN "无效选项"; pause_enter ;;
    esac
  done
}

# ---------- 快速初始化 ----------
# 一站式初始化：添加 Zone、添加任务、启用定时器、可立即执行。
quick_init_wizard() {
  print_header
  echo "🚀 快速初始化向导"
  echo
  echo "这个向导会依次完成："
  echo "  1. 添加 Cloudflare 域名配置"
  echo "  2. 测试 API 权限"
  echo "  3. 添加一个或多个 CNAME 记录"
  echo "  4. 添加一个或多个切换时间点"
  echo "  5. 启用定时器"
  echo
  confirm_select "是否开始快速初始化？" || return 0
  add_zone_wizard || { echo "域名配置失败，向导已停止。"; return 1; }
  add_task_wizard || { echo "任务创建失败，向导已停止。"; return 1; }
  setup_scheduler || true
  echo
  echo "快速初始化完成。以后输入 sudo cfcname 即可管理。"
}

# ---------- 自检 ----------
# 检查依赖、配置、定时器、API Token 是否为空。
self_check() {
  print_header
  echo "🔎 自检"
  echo
  local ok=1
  for cmd in curl jq flock; do
    if command -v "$cmd" >/dev/null 2>&1; then echo "✅ 依赖存在：$cmd"; else echo "❌ 缺少依赖：$cmd"; ok=0; fi
  done
  if command -v curl >/dev/null 2>&1; then
    echo "ℹ️  curl 版本：$(curl --version | head -n 1)"
    if curl_supports_option --retry-all-errors; then
      echo "✅ curl 支持 --retry-all-errors；但 v1.4 已不再依赖它。"
    else
      echo "✅ curl 不支持 --retry-all-errors；v1.4 已使用脚本内置重试兼容旧版 curl。"
    fi
    if curl_supports_option --http1.1; then
      echo "✅ curl 支持 --http1.1"
    else
      echo "⚠️  curl 不支持 --http1.1；脚本会自动使用默认 HTTP 协议。"
    fi
  fi
  if validate_config_file; then echo "✅ 配置 JSON 正常：${CONFIG_FILE}"; else echo "❌ 配置 JSON 异常：${CONFIG_FILE}"; ok=0; fi
  if [[ -x "$INSTALL_BIN" ]]; then echo "✅ 管理命令存在：${INSTALL_BIN}"; else echo "⚠️  管理命令不存在：${INSTALL_BIN}"; fi
  local empty_tokens bad_zone
  empty_tokens="$(jq '[.zones[]? | select((.token // "") == "")] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)"
  bad_zone="$(jq -r '.zones[]? | select((.zone_id|test("^[a-fA-F0-9]{32}$")|not)) | .name + " => " + .zone_id' "$CONFIG_FILE" 2>/dev/null || true)"
  [[ "$empty_tokens" -eq 0 ]] && echo "✅ 未发现空 Token" || { echo "❌ 发现空 Token 配置：${empty_tokens} 个"; ok=0; }
  if [[ -n "$bad_zone" ]]; then echo "❌ 发现格式异常的 Zone ID："; echo "$bad_zone"; ok=0; else echo "✅ Zone ID 格式检查通过"; fi
  echo
  scheduler_status
  echo
  if [[ "$ok" -eq 1 ]]; then echo "自检完成：未发现明显问题。"; else echo "自检完成：发现问题，请按提示修复。"; fi
}

# ---------- 主菜单 ----------
main_menu() {
  need_root
  migrate_config
  while true; do
    print_header
    echo "  1) 🚀 快速初始化向导"
    echo "  2) 🌐 域名 / Token 配置管理"
    echo "  3) 🧩 CNAME 切换任务管理"
    echo "  4) 💾 备份 / 恢复"
    echo "  5) ⚙️  系统设置 / 日志等级"
    echo "  6) 🔎 自检"
    echo "  7) ▶️  立即执行所有启用任务"
    echo "  8) 🧹 卸载 cfcname"
    echo "  0) 退出"
    echo
    read -r -p "请选择: " ans || true
    case "$ans" in
      1) quick_init_wizard; pause_enter ;;
      2) zone_menu ;;
      3) task_menu ;;
      4) backup_menu ;;
      5) settings_menu ;;
      6) self_check; pause_enter ;;
      7) run_tasks force ""; pause_enter ;;
      8) uninstall_self; pause_enter ;;
      0) exit 0 ;;
      *) log_msg WARN "无效选项"; pause_enter ;;
    esac
  done
}

usage() {
  cat <<USAGE
cfcname v${APP_VERSION}

用法：
  sudo bash cfcname_v${APP_VERSION}.sh install     安装/更新到 /usr/local/bin/cfcname
  sudo cfcname                                    打开菜单
  sudo cfcname run --quiet                       定时器调用，按当前时间执行
  sudo cfcname run --force                       立即强制执行所有启用任务
  sudo cfcname self-check                        自检
  sudo cfcname uninstall                         卸载

配置路径：${CONFIG_FILE}
日志路径：${LOG_FILE}
USAGE
}

main() {
  local cmd="${1:-menu}"
  case "$cmd" in
    install) install_self ;;
    uninstall) uninstall_self ;;
    menu) main_menu ;;
    run)
      need_root
      migrate_config
      shift || true
      local force="normal"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --quiet) QUIET=1 ;;
          --force) force="force" ;;
        esac
        shift || true
      done
      run_tasks "$force" ""
      ;;
    self-check|check) need_root; migrate_config; self_check ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
