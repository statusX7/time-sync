#!/usr/bin/env bash
# cfcname - Cloudflare CNAME Pair-Swap Manager
# Version: 1.7
# License: MIT
#
# 功能简要注释：
# 1. 用 cfcname 菜单管理 Cloudflare CNAME 定时互换任务。
# 2. 核心场景：A 记录正常指向 1.com，B 记录正常指向 2.com；到指定时间互换，到恢复时间换回。
# 3. 不在脚本中写死任何真实域名、Zone ID、Token，适合 GitHub 公开。
# 4. 支持多个域名配置、多个成对互换任务、日志等级、网络重试、备份恢复。
# 5. 默认只处理 CNAME；遇到同名 A/AAAA/其他记录会停止，避免误删生产记录。

set -Eeuo pipefail

APP_NAME="cfcname"
APP_VERSION="1.7"
INSTALL_BIN="/usr/local/bin/${APP_NAME}"
INSTALL_BIN_COMPAT="/usr/bin/${APP_NAME}"
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

print_header() {
  clear 2>/dev/null || true
  printf "%b\n" "${C_CYAN}${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
  printf "%b\n" "${C_CYAN}${C_BOLD}║             cfcname v${APP_VERSION} - CNAME 成对互换管理器       ║${C_RESET}"
  printf "%b\n" "${C_CYAN}${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
  printf "%b\n" "${C_DIM}配置: ${CONFIG_FILE}${C_RESET}"
  printf "%b\n" "${C_DIM}日志: ${LOG_FILE}${C_RESET}"
  echo
}

section_title() {
  printf "%b\n" "${C_BOLD}${C_BLUE}▶ $*${C_RESET}"
}

hint() {
  printf "%b\n" "${C_DIM}$*${C_RESET}"
}

cn_num() {
  case "${1:-}" in
    0) echo "零" ;; 1) echo "一" ;; 2) echo "二" ;; 3) echo "三" ;; 4) echo "四" ;;
    5) echo "五" ;; 6) echo "六" ;; 7) echo "七" ;; 8) echo "八" ;; 9) echo "九" ;; 10) echo "十" ;;
    *) echo "$1" ;;
  esac
}

menu_item() {
  local n="$1" text="$2"
  # v1.7 UI：统一使用 1. / 2. / 3. 这种编号，避免中文编号在终端里显得混乱。
  printf "  %s. %s\n" "$n" "$text"
}

choice_num() {
  local x="${1:-}"
  x="${x//$'\r'/}"
  x="${x//$'\n'/}"
  x="${x//[[:space:]]/}"
  x="${x//./}"; x="${x//)/}"; x="${x//、/}"
  case "$x" in
    0|零|〇) echo 0 ;;
    1|一|壹) echo 1 ;;
    2|二|两|貳|贰) echo 2 ;;
    3|三|叁) echo 3 ;;
    4|四|肆) echo 4 ;;
    5|五|伍) echo 5 ;;
    6|六|陆) echo 6 ;;
    7|七|柒) echo 7 ;;
    8|八|捌) echo 8 ;;
    9|九|玖) echo 9 ;;
    10|十|拾) echo 10 ;;
    *) echo "$x" ;;
  esac
}

pause_enter() {
  echo
  read -r -p "按 Enter 返回..." _ || true
}

confirm_select() {
  local msg="$1" ans
  echo
  printf "%b\n" "${C_YELLOW}${msg}${C_RESET}"
  menu_item 1 "确认"
  menu_item 2 "取消"
  while true; do
    read -r -p "请选择 [1-2]: " ans || return 1
    ans="$(choice_num "$ans")"
    case "$ans" in
      1) return 0 ;;
      2) return 1 ;;
      *) echo "请输入 1 或 2。" ;;
    esac
  done
}

# ---------- 日志 ----------
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

current_log_level() {
  if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.settings.log_level // "INFO"' "$CONFIG_FILE" 2>/dev/null || echo "INFO"
  else
    echo "INFO"
  fi
}

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
need_root() {
  [[ "$(id -u)" -eq 0 ]] || { echo "请使用 root 运行：sudo $0" >&2; exit 1; }
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR" "$LOG_DIR"
  chmod 700 "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
  chmod 755 "$LOG_DIR" 2>/dev/null || true
}

sanitize_token() {
  printf '%s' "${1:-}" | tr -d '[:space:]'
}

trim_text() {
  local s="${1:-}"
  s="${s//$'\r'/}"
  s="$(printf '%s' "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  printf '%s' "$s"
}

valid_zone_id() {
  [[ "${1:-}" =~ ^[a-fA-F0-9]{32}$ ]]
}

valid_domain() {
  [[ "${1:-}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}\.?$ ]]
}

valid_hhmm() {
  [[ "${1:-}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

hhmm_to_minutes() {
  local t="$1" h m
  h="${t%:*}"; m="${t#*:}"
  echo $((10#$h * 60 + 10#$m))
}

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

normalize_cname_target() {
  local input
  input="$(trim_text "$1")"
  input="${input#http://}"
  input="${input#https://}"
  input="${input%%/*}"
  input="${input%.}"
  printf '%s' "$input"
}

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

gen_id() {
  local prefix="$1"
  printf '%s_%s_%05d' "$prefix" "$(date +%Y%m%d%H%M%S)" "$((RANDOM * RANDOM % 100000))"
}

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

init_config() {
  ensure_dirs
  if [[ ! -f "$CONFIG_FILE" ]]; then
    default_config_json > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    log_msg INFO "已创建空配置：${CONFIG_FILE}"
  fi
}

validate_config_file() {
  [[ -f "$CONFIG_FILE" ]] || return 1
  jq -e '.settings and (.zones|type=="array") and (.tasks|type=="array")' "$CONFIG_FILE" >/dev/null 2>&1
}

save_config_from_stdin() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  jq '.' "$tmp" >/dev/null || { rm -f "$tmp"; log_msg ERROR "配置 JSON 校验失败，未保存。"; return 1; }
  install -m 600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

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
    .tasks = ((.tasks // []) | map(if (.task_type // "") == "" then . + {task_type:"legacy"} else . end))
  ' "$CONFIG_FILE" > "$tmp"
  install -m 600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

# ---------- 依赖和安装 ----------
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v apk >/dev/null 2>&1; then echo apk
  else echo unknown
  fi
}

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

  # 兼容 sudo secure_path：部分系统 sudo 找不到 /usr/local/bin，所以同时提供 /usr/bin/cfcname。
  if [[ "$INSTALL_BIN" != "$INSTALL_BIN_COMPAT" ]]; then
    ln -sf "$INSTALL_BIN" "$INSTALL_BIN_COMPAT" 2>/dev/null || install -m 755 "$INSTALL_BIN" "$INSTALL_BIN_COMPAT"
  fi
  hash -r 2>/dev/null || true

  setup_scheduler
  log_msg INFO "已安装 ${APP_NAME} v${APP_VERSION} 到 ${INSTALL_BIN}，兼容命令：${INSTALL_BIN_COMPAT}"
  echo "安装完成。可输入以下任一命令进入菜单："
  echo "  sudo cfcname"
  echo "  sudo /usr/bin/cfcname"
  echo "  sudo /usr/local/bin/cfcname"
}

uninstall_self() {
  need_root
  print_header
  echo "卸载会删除命令和定时器。配置文件默认保留。"
  if ! confirm_select "确认卸载 cfcname？"; then return 0; fi
  disable_scheduler || true
  rm -f "$INSTALL_BIN" "$INSTALL_BIN_COMPAT"
  log_msg INFO "已卸载命令：${INSTALL_BIN} ${INSTALL_BIN_COMPAT}"
  if confirm_select "是否同时删除配置、状态、日志？"; then
    rm -rf "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"
    echo "已删除配置、状态、日志。"
  else
    echo "已保留配置：${CONFIG_DIR}，状态：${STATE_DIR}，日志：${LOG_DIR}"
  fi
}

# ---------- 调度器 ----------
setup_systemd_timer() {
  cat > "$SYSTEMD_SERVICE" <<UNIT
[Unit]
Description=cfcname Cloudflare CNAME pair swap
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_BIN_COMPAT} run --quiet
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

setup_cron_timer() {
  cat > "$CRON_FILE" <<CRON
# cfcname v${APP_VERSION} - run every minute
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root flock -n /run/${APP_NAME}.lock ${INSTALL_BIN_COMPAT} run --quiet >/dev/null 2>&1
CRON
  chmod 644 "$CRON_FILE"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
    systemctl reload cron >/dev/null 2>&1 || systemctl reload crond >/dev/null 2>&1 || true
  fi
  log_msg INFO "已启用 cron 定时任务：${CRON_FILE}"
}

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

disable_scheduler() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "${APP_NAME}.timer" >/dev/null 2>&1 || true
  fi
  rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER" "$CRON_FILE"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  log_msg INFO "已移除定时器。"
}

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

# ---------- 服务控制 ----------
# 说明：cfcname 的后台执行依靠 systemd timer 或 cron。
# 启动 = 创建并启用调度器；停止 = 停用调度器但保留配置；重启 = 重建调度器。
scheduler_start() {
  need_root
  ensure_dirs
  migrate_config
  setup_scheduler
  log_msg INFO "服务已启动：定时检查已启用。"
}

scheduler_stop() {
  need_root
  disable_scheduler
  log_msg INFO "服务已停止：定时检查已停用，配置保留。"
}

scheduler_restart() {
  need_root
  disable_scheduler || true
  setup_scheduler
  log_msg INFO "服务已重启：定时检查已重新启用。"
}

scheduler_reload() {
  need_root
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  log_msg INFO "服务配置已重载。"
}

service_control_menu() {
  while true; do
    print_header
    section_title "服务控制"
    echo "这里控制的是 cfcname 的定时执行服务。"
    echo "启动后，脚本会按分钟检查是否需要在切换时间/恢复时间更新 CNAME。"
    echo
    menu_item 1 "▶️  启动定时服务"
    menu_item 2 "🔄 重启定时服务"
    menu_item 3 "⏹️  停止定时服务"
    menu_item 4 "📊 查看服务状态"
    menu_item 5 "🛠️  修复/重装定时服务"
    menu_item 0 "返回主菜单"
    echo
    read -r -p "请选择: " ans || true
    ans="$(choice_num "$ans")"
    case "$ans" in
      1) scheduler_start; pause_enter ;;
      2) scheduler_restart; pause_enter ;;
      3) if confirm_select "确认停止 cfcname 定时服务？配置不会删除。"; then scheduler_stop; fi; pause_enter ;;
      4) print_header; scheduler_status; pause_enter ;;
      5) setup_scheduler; pause_enter ;;
      0) return 0 ;;
      *) log_msg WARN "无效选项"; pause_enter ;;
    esac
  done
}

# ---------- Cloudflare API ----------
cf_setting() {
  local key="$1" default="$2"
  jq -r --arg k "$key" --arg d "$default" '.settings[$k] // $d' "$CONFIG_FILE"
}

curl_supports_option() {
  local opt="$1"
  if curl --help all >/dev/null 2>&1; then
    curl --help all 2>/dev/null | grep -q -- "$opt"
  else
    curl --help 2>/dev/null | grep -q -- "$opt" || curl --manual 2>/dev/null | grep -q -- "$opt"
  fi
}

is_retryable_http_code() {
  case "${1:-}" in
    408|425|429|500|502|503|504) return 0 ;;
    *) return 1 ;;
  esac
}

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

test_zone_api() {
  local zone_id="$1" token="$2"
  cf_api "$zone_id" "$token" GET "/zones/${zone_id}/dns_records?per_page=1" >/dev/null
}

list_records_by_name() {
  local zone_id="$1" token="$2" name="$3" encoded
  encoded="$(urlencode "$name")"
  cf_api "$zone_id" "$token" GET "/zones/${zone_id}/dns_records?name=${encoded}&per_page=100"
}

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
select_zone() {
  local count idx zid
  count="$(jq '.zones | length' "$CONFIG_FILE")"
  if [[ "$count" -eq 0 ]]; then
    echo "当前没有域名配置，请先添加。" >&2
    return 1
  fi
  echo "可选域名配置：" >&2
  jq -r '.zones | to_entries[] | "  \(.key+1). \(.value.name)  ZoneID=\(.value.zone_id)  Token=" + ((.value.token // "")[0:5]) + "..."' "$CONFIG_FILE" >&2
  while true; do
    read -r -p "请选择 [1-${count}]: " idx || return 1
    idx="$(choice_num "$idx")"
    [[ "$idx" =~ ^[0-9]+$ ]] || { echo "请输入数字" >&2; continue; }
    (( idx >= 1 && idx <= count )) || { echo "超出范围" >&2; continue; }
    zid="$(jq -r --argjson i "$((idx-1))" '.zones[$i].id' "$CONFIG_FILE")"
    echo "$zid"
    return 0
  done
}

add_zone_wizard() {
  print_header
  section_title "添加 Cloudflare 域名配置"
  echo "说明：Zone ID 是 32 位十六进制；API Token 建议只给该 Zone 的 DNS Read + DNS Write 权限。"
  echo
  local zone_name zone_id token zone_obj zone_ref
  while true; do
    zone_name="$(prompt_input "根域名" "example.com")"
    zone_name="${zone_name%.}"
    valid_domain "$zone_name" && break
    echo "域名格式不正确。示例：example.com"
  done
  while true; do
    zone_id="$(prompt_input "Cloudflare Zone ID" "")"
    if valid_zone_id "$zone_id"; then break; fi
    echo "Zone ID 格式不正确，应为 32 位十六进制。不要输入根域名。"
  done
  token="$(prompt_secret_token "Cloudflare API Token")"

  echo
  echo "正在测试 API 权限..."
  if ! test_zone_api "$zone_id" "$token"; then
    echo
    echo "API 测试失败，未保存。请检查：Token 是否为空、权限是否包含 DNS Read/Write、Zone ID 是否正确、服务器能否访问 api.cloudflare.com。"
    return 1
  fi
  echo "API 测试通过。"

  zone_ref="zone_$(date +%Y%m%d%H%M%S)_$((RANDOM%9999))"
  zone_obj="$(jq -n --arg id "$zone_ref" --arg name "$zone_name" --arg zone_id "$zone_id" --arg token "$token" '{id:$id, name:$name, zone_id:$zone_id, token:$token}')"
  jq --argjson z "$zone_obj" '.zones += [$z]' "$CONFIG_FILE" | save_config_from_stdin
  log_msg INFO "已保存域名配置：${zone_name}，ZoneID=${zone_id}，Token=$(mask_token "$token")"
}

list_zones() {
  print_header
  section_title "域名配置列表"
  echo
  if [[ "$(jq '.zones | length' "$CONFIG_FILE")" -eq 0 ]]; then
    echo "暂无域名配置。"
  else
    jq -r '.zones[] | "- 名称: \(.name)\n  内部ID: \(.id)\n  Zone ID: \(.zone_id)\n  Token: " + ((.token // "")[0:5]) + "..." + ((.token // "")[-4:]) + "\n"' "$CONFIG_FILE"
  fi
}

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

edit_zone_menu() {
  print_header
  local zid old_name old_zone_id old_token name zone_id token
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
    token="$(prompt_secret_token "新的 Cloudflare API Token")"
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

zone_menu() {
  while true; do
    print_header
    section_title "域名 / Token 配置"
    menu_item 1 "查看域名配置"
    menu_item 2 "添加域名配置"
    menu_item 3 "编辑域名配置"
    menu_item 4 "测试 API 权限"
    menu_item 5 "删除域名配置"
    menu_item 0 "返回主菜单"
    echo
    read -r -p "请选择: " ans || true
    ans="$(choice_num "$ans")"
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

# ---------- 成对互换任务 ----------
select_task() {
  local count idx tid
  count="$(jq '[.tasks[] | select(.task_type=="pair_swap")] | length' "$CONFIG_FILE")"
  if [[ "$count" -eq 0 ]]; then
    echo "当前没有成对互换任务。" >&2
    return 1
  fi
  echo "可选任务：" >&2
  jq -r '[.tasks[] | select(.task_type=="pair_swap")] | to_entries[] | "  \(.key+1). " + (if .value.enabled then "✅" else "⏸️" end) + " " + .value.name + "  切换=" + .value.swap_time + " 恢复=" + .value.restore_time' "$CONFIG_FILE" >&2
  while true; do
    read -r -p "请选择 [1-${count}]: " idx || return 1
    idx="$(choice_num "$idx")"
    [[ "$idx" =~ ^[0-9]+$ ]] || { echo "请输入数字" >&2; continue; }
    (( idx >= 1 && idx <= count )) || { echo "超出范围" >&2; continue; }
    tid="$(jq -r --argjson i "$((idx-1))" '[.tasks[] | select(.task_type=="pair_swap")][$i].id' "$CONFIG_FILE")"
    echo "$tid"
    return 0
  done
}

pair_mode_by_time() {
  local swap_time="$1" restore_time="$2" tz now_min swap_min restore_min
  tz="$(jq -r '.settings.timezone // "Asia/Shanghai"' "$CONFIG_FILE")"
  now_min="$(TZ="$tz" date '+%H %M' | awk '{print $1*60+$2}')"
  swap_min="$(hhmm_to_minutes "$swap_time")"
  restore_min="$(hhmm_to_minutes "$restore_time")"

  if (( swap_min == restore_min )); then
    echo "invalid"
    return 1
  fi

  if (( swap_min < restore_min )); then
    if (( now_min >= swap_min && now_min < restore_min )); then echo "swapped"; else echo "normal"; fi
  else
    if (( now_min >= swap_min || now_min < restore_min )); then echo "swapped"; else echo "normal"; fi
  fi
}

pair_mode_label() {
  case "$1" in
    normal) echo "正常/恢复模式" ;;
    swapped) echo "互换模式" ;;
    *) echo "$1" ;;
  esac
}

pair_targets_json() {
  local task_json="$1" mode="$2"
  if [[ "$mode" == "swapped" ]]; then
    jq -c '{(.record_a): .target_b, (.record_b): .target_a}' <<<"$task_json"
  else
    jq -c '{(.record_a): .target_a, (.record_b): .target_b}' <<<"$task_json"
  fi
}

print_pair_task_human() {
  local task_json="$1" mode
  mode="$(pair_mode_by_time "$(jq -r '.swap_time' <<<"$task_json")" "$(jq -r '.restore_time' <<<"$task_json")" 2>/dev/null || echo normal)"
  jq -r --arg mode "$mode" '
    "任务名称：" + .name + "\n" +
    "状态：" + (if .enabled then "启用" else "停用" end) + "\n" +
    "当前应处于：" + (if $mode=="swapped" then "互换模式" else "正常/恢复模式" end) + "\n" +
    "切换时间：" + .swap_time + "\n" +
    "恢复时间：" + .restore_time + "\n\n" +
    "正常/恢复模式：\n" +
    "  " + .record_a + " -> " + .target_a + "\n" +
    "  " + .record_b + " -> " + .target_b + "\n\n" +
    "互换模式：\n" +
    "  " + .record_a + " -> " + .target_b + "\n" +
    "  " + .record_b + " -> " + .target_a
  ' <<<"$task_json"
}

list_tasks() {
  print_header
  section_title "成对互换任务列表"
  echo
  if [[ "$(jq '[.tasks[] | select(.task_type=="pair_swap")] | length' "$CONFIG_FILE")" -eq 0 ]]; then
    echo "暂无成对互换任务。"
    echo
    echo "适合你的目标示例："
    echo "  正常：x001 -> 1.com，x002 -> 2.com"
    echo "  21:00：x001 -> 2.com，x002 -> 1.com"
    echo "  02:00：x001 -> 1.com，x002 -> 2.com"
    return 0
  fi

  jq -c '.tasks[] | select(.task_type=="pair_swap")' "$CONFIG_FILE" | while read -r task; do
    echo "────────────────────────────────────────"
    print_pair_task_human "$task"
    echo
  done

  local legacy_count
  legacy_count="$(jq '[.tasks[] | select(.task_type=="legacy")] | length' "$CONFIG_FILE")"
  if [[ "$legacy_count" -gt 0 ]]; then
    echo "⚠️ 检测到 ${legacy_count} 个旧版通用任务。1.6 主逻辑已改为成对互换，建议重新创建任务。"
  fi
}

add_pair_task_wizard() {
  print_header
  section_title "新增成对互换任务"
  echo "这个向导专门对应你的场景："
  echo "  正常：记录A -> 目标A，记录B -> 目标B"
  echo "  到切换时间：记录A -> 目标B，记录B -> 目标A"
  echo "  到恢复时间：记录A -> 目标A，记录B -> 目标B"
  echo

  local zone_ref zone_name task_name task_id record_a record_b target_a target_b swap_time restore_time ttl proxied auto_create task_json
  zone_ref="$(select_zone)" || { echo "请先添加域名配置。"; return 1; }
  zone_name="$(jq -r --arg id "$zone_ref" '.zones[] | select(.id==$id) | .name' "$CONFIG_FILE")"

  task_name="$(prompt_input "任务名称" "x001-x002-pair-swap")"
  task_id="$(gen_id task)"

  while true; do
    record_a="$(prompt_input "记录A，例如 x001 或 x001.example.com" "x001")"
    record_a="$(normalize_record_name "$record_a" "$zone_name")"
    valid_domain "$record_a" && break
    echo "记录A格式不正确。"
  done
  while true; do
    record_b="$(prompt_input "记录B，例如 x002 或 x002.example.com" "x002")"
    record_b="$(normalize_record_name "$record_b" "$zone_name")"
    valid_domain "$record_b" && [[ "$record_b" != "$record_a" ]] && break
    echo "记录B格式不正确，且不能与记录A相同。"
  done
  while true; do
    target_a="$(prompt_input "正常模式下，记录A指向的 CNAME 目标" "target-a.example.net")"
    target_a="$(normalize_cname_target "$target_a")"
    valid_domain "$target_a" && break
    echo "目标A格式不正确，不要输入 URL，只输入域名。"
  done
  while true; do
    target_b="$(prompt_input "正常模式下，记录B指向的 CNAME 目标" "target-b.example.net")"
    target_b="$(normalize_cname_target "$target_b")"
    valid_domain "$target_b" && [[ "$target_b" != "$target_a" ]] && break
    echo "目标B格式不正确，且建议不要与目标A相同。"
  done
  while true; do
    swap_time="$(prompt_input "每天几点开始互换，格式 HH:MM" "21:00")"
    valid_hhmm "$swap_time" && break
    echo "时间格式不正确，例如 21:00。"
  done
  while true; do
    restore_time="$(prompt_input "每天几点恢复原状，格式 HH:MM" "02:00")"
    valid_hhmm "$restore_time" && [[ "$restore_time" != "$swap_time" ]] && break
    echo "恢复时间格式不正确，且不能与切换时间相同。"
  done

  ttl="$(jq -r '.settings.default_ttl' "$CONFIG_FILE")"
  proxied="$(jq -r '.settings.default_proxied' "$CONFIG_FILE")"
  auto_create="$(jq -r '.settings.auto_create_missing' "$CONFIG_FILE")"

  task_json="$(jq -n \
    --arg id "$task_id" \
    --arg name "$task_name" \
    --arg zone_ref "$zone_ref" \
    --arg record_a "$record_a" \
    --arg record_b "$record_b" \
    --arg target_a "$target_a" \
    --arg target_b "$target_b" \
    --arg swap_time "$swap_time" \
    --arg restore_time "$restore_time" \
    --argjson ttl "$ttl" \
    --argjson proxied "$proxied" \
    --argjson auto_create "$auto_create" \
    '{id:$id, task_type:"pair_swap", name:$name, enabled:true, zone_ref:$zone_ref, record_a:$record_a, record_b:$record_b, target_a:$target_a, target_b:$target_b, swap_time:$swap_time, restore_time:$restore_time, ttl:$ttl, proxied:$proxied, auto_create_missing:$auto_create}')"

  echo
  section_title "任务预览"
  print_pair_task_human "$task_json"
  echo
  hint "说明：如果切换时间是 21:00，恢复时间是 02:00，则 21:00-01:59 为互换模式，02:00-20:59 为正常模式。"
  confirm_select "确认保存并启用该任务？" || return 0

  jq --argjson task "$task_json" '.tasks += [$task]' "$CONFIG_FILE" | save_config_from_stdin
  log_msg INFO "已新增成对互换任务：${task_name}，ID=${task_id}"
  setup_scheduler || true

  if confirm_select "是否立即按当前时间执行一次？"; then
    apply_pair_task_by_id "$task_id" "current" "force"
  fi
}

edit_pair_task_menu() {
  print_header
  section_title "编辑成对互换任务"
  local tid task ans field value zone_name zone_ref
  tid="$(select_task)" || return 0
  task="$(jq -c --arg id "$tid" '.tasks[] | select(.id==$id)' "$CONFIG_FILE")"
  zone_ref="$(jq -r '.zone_ref' <<<"$task")"
  zone_name="$(jq -r --arg id "$zone_ref" '.zones[]? | select(.id==$id) | .name' "$CONFIG_FILE")"

  while true; do
    print_header
    section_title "当前任务"
    task="$(jq -c --arg id "$tid" '.tasks[] | select(.id==$id)' "$CONFIG_FILE")"
    print_pair_task_human "$task"
    echo
    menu_item 1 "修改任务名称"
    menu_item 2 "修改记录A / 记录B"
    menu_item 3 "修改目标A / 目标B"
    menu_item 4 "修改切换时间 / 恢复时间"
    menu_item 5 "启用 / 停用"
    menu_item 0 "返回"
    echo
    read -r -p "请选择: " ans || true
    ans="$(choice_num "$ans")"
    case "$ans" in
      1)
        value="$(prompt_input "新的任务名称" "$(jq -r '.name' <<<"$task")")"
        jq --arg id "$tid" --arg v "$value" '(.tasks[] | select(.id==$id)).name=$v' "$CONFIG_FILE" | save_config_from_stdin
        ;;
      2)
        while true; do
          value="$(prompt_input "记录A" "$(jq -r '.record_a' <<<"$task")")"
          value="$(normalize_record_name "$value" "$zone_name")"
          valid_domain "$value" && break; echo "记录A格式不正确。"
        done
        local new_a="$value" new_b
        while true; do
          new_b="$(prompt_input "记录B" "$(jq -r '.record_b' <<<"$task")")"
          new_b="$(normalize_record_name "$new_b" "$zone_name")"
          valid_domain "$new_b" && [[ "$new_b" != "$new_a" ]] && break; echo "记录B格式不正确，且不能与记录A相同。"
        done
        jq --arg id "$tid" --arg a "$new_a" --arg b "$new_b" '(.tasks[] | select(.id==$id)) |= (.record_a=$a | .record_b=$b)' "$CONFIG_FILE" | save_config_from_stdin
        ;;
      3)
        while true; do
          value="$(prompt_input "目标A" "$(jq -r '.target_a' <<<"$task")")"
          value="$(normalize_cname_target "$value")"
          valid_domain "$value" && break; echo "目标A格式不正确。"
        done
        local new_ta="$value" new_tb
        while true; do
          new_tb="$(prompt_input "目标B" "$(jq -r '.target_b' <<<"$task")")"
          new_tb="$(normalize_cname_target "$new_tb")"
          valid_domain "$new_tb" && [[ "$new_tb" != "$new_ta" ]] && break; echo "目标B格式不正确，且建议不要与目标A相同。"
        done
        jq --arg id "$tid" --arg a "$new_ta" --arg b "$new_tb" '(.tasks[] | select(.id==$id)) |= (.target_a=$a | .target_b=$b)' "$CONFIG_FILE" | save_config_from_stdin
        ;;
      4)
        local new_swap new_restore
        while true; do
          new_swap="$(prompt_input "切换时间" "$(jq -r '.swap_time' <<<"$task")")"
          valid_hhmm "$new_swap" && break; echo "时间格式不正确。"
        done
        while true; do
          new_restore="$(prompt_input "恢复时间" "$(jq -r '.restore_time' <<<"$task")")"
          valid_hhmm "$new_restore" && [[ "$new_restore" != "$new_swap" ]] && break; echo "恢复时间格式不正确，且不能与切换时间相同。"
        done
        jq --arg id "$tid" --arg s "$new_swap" --arg r "$new_restore" '(.tasks[] | select(.id==$id)) |= (.swap_time=$s | .restore_time=$r)' "$CONFIG_FILE" | save_config_from_stdin
        ;;
      5)
        local enabled new_enabled
        enabled="$(jq -r '.enabled' <<<"$task")"
        [[ "$enabled" == "true" ]] && new_enabled=false || new_enabled=true
        jq --arg id "$tid" --argjson e "$new_enabled" '(.tasks[] | select(.id==$id)).enabled=$e' "$CONFIG_FILE" | save_config_from_stdin
        ;;
      0) return 0 ;;
      *) echo "无效选项"; pause_enter ;;
    esac
    rm -f "${STATE_DIR}/task_${tid}.state" 2>/dev/null || true
    log_msg INFO "已修改任务：${tid}"
  done
}

delete_task_menu() {
  print_header
  local tid
  tid="$(select_task)" || return 0
  confirm_select "确认删除该任务？" || return 0
  jq --arg id "$tid" '.tasks = [.tasks[] | select(.id != $id)]' "$CONFIG_FILE" | save_config_from_stdin
  rm -f "${STATE_DIR}/task_${tid}.state" 2>/dev/null || true
  log_msg INFO "已删除任务：${tid}"
}

query_pair_dns_menu() {
  print_header
  section_title "查看任务对应 DNS 当前状态"
  local tid task zone_ref zone_json zone_id token
  tid="$(select_task)" || return 0
  task="$(jq -c --arg id "$tid" '.tasks[] | select(.id==$id)' "$CONFIG_FILE")"
  zone_ref="$(jq -r '.zone_ref' <<<"$task")"
  zone_json="$(jq -c --arg id "$zone_ref" '.zones[]? | select(.id==$id)' "$CONFIG_FILE")"
  [[ -n "$zone_json" && "$zone_json" != "null" ]] || { echo "该任务引用的域名配置不存在。"; return 1; }
  zone_id="$(jq -r '.zone_id' <<<"$zone_json")"
  token="$(jq -r '.token' <<<"$zone_json")"

  for name in "$(jq -r '.record_a' <<<"$task")" "$(jq -r '.record_b' <<<"$task")"; do
    echo "────────────────────────────────────────"
    echo "${name}"
    local resp
    resp="$(list_records_by_name "$zone_id" "$token" "$name")" || continue
    if [[ "$(jq '.result | length' <<<"$resp")" -eq 0 ]]; then
      echo "  当前不存在记录。"
    else
      jq -r '.result[] | "  \(.type) -> \(.content)  ttl=\(.ttl)  proxied=\(.proxied)"' <<<"$resp"
    fi
  done
}

manual_update_cname_menu() {
  print_header
  section_title "手动立即修改 CNAME"
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

apply_task_mode_menu() {
  print_header
  section_title "立即执行指定任务"
  local tid ans mode
  tid="$(select_task)" || return 0
  echo
  menu_item 1 "按当前时间自动判断"
  menu_item 2 "强制执行正常/恢复模式"
  menu_item 3 "强制执行互换模式"
  menu_item 0 "返回"
  echo
  read -r -p "请选择: " ans || true
  ans="$(choice_num "$ans")"
  case "$ans" in
    1) mode=current ;;
    2) mode=normal ;;
    3) mode=swapped ;;
    0) return 0 ;;
    *) echo "无效选项"; return 1 ;;
  esac
  apply_pair_task_by_id "$tid" "$mode" "force"
}

task_menu() {
  while true; do
    print_header
    section_title "CNAME 成对互换任务"
    menu_item 1 "查看任务"
    menu_item 2 "新增成对互换任务"
    menu_item 3 "编辑任务"
    menu_item 4 "删除任务"
    menu_item 5 "查看任务对应 DNS 当前状态"
    menu_item 6 "立即执行指定任务"
    menu_item 7 "手动立即修改任意 CNAME"
    menu_item 0 "返回主菜单"
    echo
    read -r -p "请选择: " ans || true
    ans="$(choice_num "$ans")"
    case "$ans" in
      1) list_tasks; pause_enter ;;
      2) add_pair_task_wizard; pause_enter ;;
      3) edit_pair_task_menu; pause_enter ;;
      4) delete_task_menu; pause_enter ;;
      5) query_pair_dns_menu; pause_enter ;;
      6) apply_task_mode_menu; pause_enter ;;
      7) manual_update_cname_menu; pause_enter ;;
      0) return 0 ;;
      *) log_msg WARN "无效选项"; pause_enter ;;
    esac
  done
}

# ---------- 任务执行 ----------
state_key_for_pair() {
  local task_id="$1" mode="$2" targets_json="$3"
  printf '%s|%s|%s' "$task_id" "$mode" "$(jq -cS '.' <<<"$targets_json")" | sha256sum | awk '{print $1}'
}

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

apply_pair_task_json() {
  local task_json="$1" desired_mode="${2:-current}" force="${3:-normal}"
  local task_id task_name zone_ref zone_json zone_id token mode targets_json key state_file old_key auto_create ttl proxied names

  task_id="$(jq -r '.id' <<<"$task_json")"
  task_name="$(jq -r '.name' <<<"$task_json")"
  zone_ref="$(jq -r '.zone_ref' <<<"$task_json")"
  zone_json="$(jq -c --arg id "$zone_ref" '.zones[]? | select(.id==$id)' "$CONFIG_FILE")"
  if [[ -z "$zone_json" || "$zone_json" == "null" ]]; then
    log_msg ERROR "任务 ${task_name} 引用的域名配置不存在：${zone_ref}"
    return 1
  fi
  zone_id="$(jq -r '.zone_id' <<<"$zone_json")"
  token="$(jq -r '.token' <<<"$zone_json")"

  if [[ "$desired_mode" == "current" ]]; then
    mode="$(pair_mode_by_time "$(jq -r '.swap_time' <<<"$task_json")" "$(jq -r '.restore_time' <<<"$task_json")")" || return 1
  else
    mode="$desired_mode"
  fi
  if [[ "$mode" != "normal" && "$mode" != "swapped" ]]; then
    log_msg ERROR "任务 ${task_name} 的模式无效：${mode}"
    return 1
  fi

  targets_json="$(pair_targets_json "$task_json" "$mode")"
  key="$(state_key_for_pair "$task_id" "$mode" "$targets_json")"
  state_file="${STATE_DIR}/task_${task_id}.state"
  old_key="$(cat "$state_file" 2>/dev/null || true)"

  if [[ "$force" != "force" && "$key" == "$old_key" ]]; then
    log_msg DEBUG "任务 ${task_name} 当前已经是 $(pair_mode_label "$mode")，跳过。"
    return 0
  fi

  auto_create="$(jq -r '.auto_create_missing // true' <<<"$task_json")"
  ttl="$(jq -r '.ttl // 1' <<<"$task_json")"
  proxied="$(jq -r '.proxied // false' <<<"$task_json")"
  names="$(jq -r 'keys[]' <<<"$targets_json")"

  backup_records "$zone_id" "$token" "$names" "$task_id" || true
  log_msg INFO "开始执行任务：${task_name}，模式：$(pair_mode_label "$mode")"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local target
    target="$(jq -r --arg n "$name" '.[$n]' <<<"$targets_json")"
    update_or_create_cname "$zone_id" "$token" "$name" "$target" "$ttl" "$proxied" "$auto_create" || return 1
  done <<<"$names"

  echo "$key" > "$state_file"
  chmod 600 "$state_file"
  log_msg INFO "任务完成：${task_name}，模式：$(pair_mode_label "$mode")"
}

apply_pair_task_by_id() {
  local task_id="$1" mode="${2:-current}" force="${3:-normal}" task_json
  task_json="$(jq -c --arg id "$task_id" '.tasks[] | select(.id==$id and .task_type=="pair_swap")' "$CONFIG_FILE")"
  [[ -n "$task_json" && "$task_json" != "null" ]] || { log_msg ERROR "未找到任务：${task_id}"; return 1; }
  apply_pair_task_json "$task_json" "$mode" "$force"
}

run_tasks() {
  local force="${1:-normal}" tasks
  migrate_config
  tasks="$(jq -c '[.tasks[] | select(.enabled==true and .task_type=="pair_swap")]' "$CONFIG_FILE")"
  if [[ "$(jq 'length' <<<"$tasks")" -eq 0 ]]; then
    log_msg DEBUG "没有需要执行的启用成对互换任务。"
    return 0
  fi
  jq -c '.[]' <<<"$tasks" | while read -r task; do
    apply_pair_task_json "$task" "current" "$force" || true
  done
}

# ---------- 备份恢复 ----------
list_backups() {
  print_header
  section_title "DNS 备份列表"
  echo
  ls -1t "$BACKUP_DIR"/*.json 2>/dev/null | head -n 30 || echo "暂无备份。"
}

restore_backup_menu() {
  print_header
  local files file idx zone_ref zone_id token
  mapfile -t files < <(ls -1t "$BACKUP_DIR"/*.json 2>/dev/null | head -n 20 || true)
  if [[ ${#files[@]} -eq 0 ]]; then echo "暂无备份。"; return 0; fi
  echo "选择要恢复的备份："
  local i=1
  for file in "${files[@]}"; do echo "  $i. $file"; i=$((i+1)); done
  read -r -p "请选择 [1-${#files[@]}]: " idx || return 0
  idx="$(choice_num "$idx")"
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

export_config_full_menu() {
  print_header
  section_title "导出完整配置"
  echo "完整配置会包含 Cloudflare API Token，只适合自己迁移备份，不要上传 GitHub。"
  local out
  out="$(prompt_input "导出文件路径" "/root/cfcname_config_full_$(date +%Y%m%d_%H%M%S).json")"
  confirm_select "确认导出完整配置到 ${out}？" || return 0
  install -m 600 "$CONFIG_FILE" "$out"
  log_msg INFO "已导出完整配置：${out}"
  echo "已导出：${out}"
}

export_config_safe_menu() {
  print_header
  section_title "导出去敏配置"
  echo "去敏配置会移除 Token，适合发给别人排查或放 GitHub 示例。"
  local out
  out="$(prompt_input "导出文件路径" "/root/cfcname_config_safe_$(date +%Y%m%d_%H%M%S).json")"
  confirm_select "确认导出去敏配置到 ${out}？" || return 0
  jq '(.zones[]?.token) = "__SET_YOUR_CLOUDFLARE_API_TOKEN__"' "$CONFIG_FILE" > "$out"
  chmod 644 "$out" 2>/dev/null || true
  log_msg INFO "已导出去敏配置：${out}"
  echo "已导出：${out}"
}

import_config_menu() {
  print_header
  section_title "导入配置"
  echo "导入会替换当前 ${CONFIG_FILE}。脚本会先自动备份当前配置。"
  local in backup empty_tokens
  in="$(prompt_input "请输入要导入的 JSON 配置路径" "")"
  [[ -f "$in" ]] || { echo "文件不存在：${in}"; return 1; }
  jq -e '.settings and (.zones|type=="array") and (.tasks|type=="array")' "$in" >/dev/null 2>&1 || { echo "配置格式不正确，未导入。"; return 1; }
  echo
  echo "将导入：${in}"
  empty_tokens="$(jq '[.zones[]? | select((.token // "") == "" or (.token // "") == "__SET_YOUR_CLOUDFLARE_API_TOKEN__")] | length' "$in")"
  if [[ "$empty_tokens" -gt 0 ]]; then
    echo "⚠️  检测到 ${empty_tokens} 个空 Token/占位 Token，导入后需要重新编辑域名配置。"
  fi
  confirm_select "确认替换当前配置？" || return 0
  backup="${CONFIG_FILE}.before_import.$(date +%Y%m%d%H%M%S)"
  [[ -f "$CONFIG_FILE" ]] && install -m 600 "$CONFIG_FILE" "$backup"
  install -m 600 "$in" "$CONFIG_FILE"
  migrate_config
  log_msg INFO "已导入配置：${in}；旧配置备份：${backup}"
  echo "导入完成。旧配置备份：${backup}"
}

backup_menu() {
  while true; do
    print_header
    section_title "备份 / 恢复 / 导入导出"
    menu_item 1 "查看最近 DNS 备份"
    menu_item 2 "从 DNS 备份恢复 CNAME 目标"
    menu_item 3 "导出完整配置（包含 Token，私密迁移用）"
    menu_item 4 "导出去敏配置（不含 Token，适合 GitHub/排查）"
    menu_item 5 "导入配置（替换当前配置，自动备份旧配置）"
    menu_item 0 "返回主菜单"
    echo
    read -r -p "请选择: " ans || true
    ans="$(choice_num "$ans")"
    case "$ans" in
      1) list_backups; pause_enter ;;
      2) restore_backup_menu; pause_enter ;;
      3) export_config_full_menu; pause_enter ;;
      4) export_config_safe_menu; pause_enter ;;
      5) import_config_menu; pause_enter ;;
      0) return 0 ;;
      *) log_msg WARN "无效选项"; pause_enter ;;
    esac
  done
}

# ---------- 系统设置 ----------
show_settings() {
  print_header
  section_title "当前系统设置"
  echo
  jq '.settings' "$CONFIG_FILE"
  echo
  scheduler_status
}

set_log_level_menu() {
  print_header
  section_title "日志等级"
  menu_item 1 "DEBUG  最详细，排障用"
  menu_item 2 "INFO   默认，记录主要动作"
  menu_item 3 "WARN   只记录警告和错误"
  menu_item 4 "ERROR  只记录错误"
  menu_item 5 "OFF    关闭日志"
  read -r -p "请选择 [1-5]: " ans || true
  ans="$(choice_num "$ans")"
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

set_curl_menu() {
  print_header
  section_title "curl 网络参数"
  local http retry delay conn max
  echo "建议：HTTP 版本保持 1.1；旧版 curl 也可以使用脚本内置重试。"
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

set_general_menu() {
  print_header
  section_title "通用设置"
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

settings_menu() {
  while true; do
    print_header
    section_title "系统设置"
    menu_item 1 "查看当前设置和定时器状态"
    menu_item 2 "设置日志等级"
    menu_item 3 "设置 curl 网络参数"
    menu_item 4 "设置时区 / 默认 TTL / 自动创建"
    menu_item 5 "重装/修复定时服务"
    menu_item 6 "停用定时服务"
    menu_item 7 "查看最近 80 行日志"
    menu_item 8 "实时查看日志"
    menu_item 0 "返回主菜单"
    echo
    read -r -p "请选择: " ans || true
    ans="$(choice_num "$ans")"
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
quick_init_wizard() {
  print_header
  section_title "快速初始化向导"
  echo "推荐流程："
  echo "  1. 添加或选择 Cloudflare 域名配置"
  echo "  2. 创建一组成对互换任务"
  echo "  3. 启用定时器"
  echo
  echo "目标模型："
  echo "  正常：记录A -> 目标A，记录B -> 目标B"
  echo "  21:00：记录A -> 目标B，记录B -> 目标A"
  echo "  02:00：记录A -> 目标A，记录B -> 目标B"
  echo
  confirm_select "是否开始快速初始化？" || return 0

  if [[ "$(jq '.zones | length' "$CONFIG_FILE")" -eq 0 ]]; then
    add_zone_wizard || { echo "域名配置失败，向导已停止。"; return 1; }
  else
    echo "已检测到域名配置。"
    if confirm_select "是否新增一个域名配置？选择取消则使用已有配置。"; then
      add_zone_wizard || { echo "域名配置失败，向导已停止。"; return 1; }
    fi
  fi

  add_pair_task_wizard || { echo "任务创建失败，向导已停止。"; return 1; }
  setup_scheduler || true
  echo
  echo "快速初始化完成。以后输入 sudo cfcname 即可管理。"
}

# ---------- 自检 ----------
self_check() {
  print_header
  section_title "自检"
  echo
  local ok=1
  for cmd in curl jq flock; do
    if command -v "$cmd" >/dev/null 2>&1; then echo "✅ 依赖存在：$cmd"; else echo "❌ 缺少依赖：$cmd"; ok=0; fi
  done
  if command -v curl >/dev/null 2>&1; then
    echo "ℹ️  curl 版本：$(curl --version | head -n 1)"
    if curl_supports_option --http1.1; then
      echo "✅ curl 支持 --http1.1"
    else
      echo "⚠️  curl 不支持 --http1.1；脚本会自动使用默认 HTTP 协议。"
    fi
  fi
  if validate_config_file; then echo "✅ 配置 JSON 正常：${CONFIG_FILE}"; else echo "❌ 配置 JSON 异常：${CONFIG_FILE}"; ok=0; fi
  if [[ -x "$INSTALL_BIN" ]]; then echo "✅ 管理命令存在：${INSTALL_BIN}"; else echo "⚠️  管理命令不存在：${INSTALL_BIN}"; fi
  if [[ -x "$INSTALL_BIN_COMPAT" || -L "$INSTALL_BIN_COMPAT" ]]; then echo "✅ sudo 兼容命令存在：${INSTALL_BIN_COMPAT}"; else echo "⚠️  sudo 兼容命令不存在：${INSTALL_BIN_COMPAT}"; fi
  if command -v cfcname >/dev/null 2>&1; then echo "✅ 当前 PATH 可找到：$(command -v cfcname)"; else echo "⚠️  当前 PATH 找不到 cfcname，可执行 sudo bash $0 install 修复。"; fi
  local empty_tokens bad_zone pair_count legacy_count
  empty_tokens="$(jq '[.zones[]? | select((.token // "") == "")] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)"
  bad_zone="$(jq -r '.zones[]? | select((.zone_id|test("^[a-fA-F0-9]{32}$")|not)) | .name + " => " + .zone_id' "$CONFIG_FILE" 2>/dev/null || true)"
  pair_count="$(jq '[.tasks[]? | select(.task_type=="pair_swap")] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)"
  legacy_count="$(jq '[.tasks[]? | select(.task_type=="legacy")] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)"
  [[ "$empty_tokens" -eq 0 ]] && echo "✅ 未发现空 Token" || { echo "❌ 发现空 Token 配置：${empty_tokens} 个"; ok=0; }
  if [[ -n "$bad_zone" ]]; then echo "❌ 发现格式异常的 Zone ID："; echo "$bad_zone"; ok=0; else echo "✅ Zone ID 格式检查通过"; fi
  echo "✅ 成对互换任务数量：${pair_count}"
  [[ "$legacy_count" -eq 0 ]] || echo "⚠️  旧版通用任务数量：${legacy_count}，建议重新创建为成对互换任务。"
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
    echo "推荐：第一次使用选 1；日常改互换规则选 3；服务启停选 5；排障选 7。"
    echo
    menu_item 1 "🚀 快速初始化：创建 21点互换 / 2点恢复任务"
    menu_item 2 "🌐 域名 / Token 配置"
    menu_item 3 "🔁 CNAME 成对互换任务"
    menu_item 4 "💾 备份 / 恢复 / 导入导出"
    menu_item 5 "🧭 服务控制：启动 / 重启 / 停止"
    menu_item 6 "⚙️  系统设置 / 日志等级"
    menu_item 7 "🔎 自检"
    menu_item 8 "▶️  立即执行所有启用任务"
    menu_item 9 "🧹 卸载 cfcname"
    menu_item 0 "退出"
    echo
    read -r -p "请选择: " ans || true
    ans="$(choice_num "$ans")"
    case "$ans" in
      1) quick_init_wizard; pause_enter ;;
      2) zone_menu ;;
      3) task_menu ;;
      4) backup_menu ;;
      5) service_control_menu ;;
      6) settings_menu ;;
      7) self_check; pause_enter ;;
      8) run_tasks force; pause_enter ;;
      9) uninstall_self; pause_enter ;;
      0) exit 0 ;;
      *) log_msg WARN "无效选项"; pause_enter ;;
    esac
  done
}

usage() {
  cat <<USAGE
cfcname v${APP_VERSION}

用法：
  sudo bash cfcname_v${APP_VERSION}.sh install     安装/更新管理命令 cfcname
  sudo cfcname                                    打开菜单
  sudo cfcname run --quiet                       定时器调用，按当前时间执行
  sudo cfcname run --force                       立即强制执行所有启用任务
  sudo cfcname start                             启动定时服务
  sudo cfcname stop                              停止定时服务
  sudo cfcname restart                           重启定时服务
  sudo cfcname status                            查看定时服务状态
  sudo cfcname self-check                        自检
  sudo cfcname uninstall                         卸载

核心逻辑：
  正常/恢复模式：记录A -> 目标A，记录B -> 目标B
  互换模式：记录A -> 目标B，记录B -> 目标A

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
      run_tasks "$force"
      ;;
    start) scheduler_start ;;
    stop) scheduler_stop ;;
    restart) scheduler_restart ;;
    status) need_root; migrate_config; scheduler_status ;;
    self-check|check) need_root; migrate_config; self_check ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
