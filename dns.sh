#!/usr/bin/env bash
set -euo pipefail

############################################
# DoH Manager PRO (All-in-One + allowlist.txt)
# Version: v2.6.3
#
# v2.6.3 修复：
# 1) 修复白名单清洗误删字母 r（.org 变 .og）和规则格式解析错误
# 2) 修复日志等级兼容、实时日志中断和服务检测问题
# 3) 修复失败仍报成功、配置部分覆盖及证书签发破坏 HTTPS 的问题
# 4) 修复状态文件、临时文件、输入校验、健康检查和卸载逻辑
# 保留 v2.6.2 的菜单、布局、选项与解析架构；不增加功能入口。
# 总行数: 2230（含注释和空行；LF 换行）
############################################

SCRIPT_VERSION="v2.6.3"
SCRIPT_NAME="DoH Manager PRO"
MOSDNS_UNIT="mosdns"
NGINX_UNIT="nginx"
UNBOUND_UNIT="unbound"

OS_ID=""
OS_NAME=""
PKG_MGR=""
ARCH_RAW=""
ARCH_KEY=""
NGINX_SITE_DIR=""
NGINX_LINK_DIR=""
UNBOUND_CONF_DIR=""
USE_NGINX_LINK="yes"

MOSDNS_USER="mosdns"
CONF_DIR="/etc/mosdns-x"
WORK_DIR="/var/lib/mosdns-x"
MOSDNS_HTTP_ADDR="127.0.0.1:8053"

ACME_WEBROOT="/var/www/acme"
STATIC_ROOT="/var/www/html"

UNBOUND_PORT="5335"
UNBOUND_SNIPPET=""

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

MENU_REQUIRED_FUNCTIONS=(
  ensure_environment
  quick_setup_wizard
  show_config
  set_domain
  set_doh_path
  set_allowlist_file
  show_allowlist
  add_allowlist_one
  remove_allowlist_one
  batch_import_allowlist
  edit_allowlist_vim
  allowlist_dedupe_sort
  list_upstreams
  add_upstream
  remove_upstream
  doh_path_conflict_check
  apply_all
  issue_cert
  renew_cert
  check_cert_days
  service_status_summary
  show_ports_summary
  health_check_summary
  log_settings_menu
  start_services
  stop_services
  restart_services
  uninstall_all
)

CORE_REQUIRED_FUNCTIONS=(
  c_ok
  c_warn
  c_err
  c_info
  need_root
  pause_enter
  log_action
  backup_file
  remove_if_exists
  have_cmd
  function_exists
  service_load_state
  service_exists
  service_active
  mosdns_process_exists
  self_check_menu_functions
  integrity_check_core_functions
  show_integrity_summary
  detect_platform
  ensure_state_file
  load_state
  save_state
  is_installed
  service_is_running
  ensure_allowlist_file
  allowlist_count
  show_brief_runtime_status
  show_allowlist
  edit_allowlist_vim
  allowlist_dedupe_sort
  add_allowlist_one
  remove_allowlist_one
  normalize_domain_line
  batch_import_allowlist
  show_config
  set_domain
  set_doh_path
  set_allowlist_file
  list_upstreams
  add_upstream
  remove_upstream
  quick_setup_wizard
  doh_path_conflict_check
  cert_exists_for_domain
  check_domain_cert_before_apply
  install_packages
  download_and_install_mosdnsx
  create_user_and_dirs
  install_mosdns_systemd
  ensure_environment
  write_unbound_forward
  build_domain_rules_from_allowlist
  write_mosdns_config
  write_nginx_site
  validate_mos_log_level
  apply_mosdns_log_level
  set_mosdns_log_level_menu
  show_recent_logs_50
  follow_mosdns_logs
  log_settings_menu
  acme_sh_path
  ensure_acme_sh
  write_nginx_http_only_for_acme
  issue_cert
  renew_cert
  check_cert_days
  reload_services
  start_services
  stop_services
  restart_services
  apply_all
  service_status_summary
  show_ports_summary
  health_check_summary
  uninstall_all
  show_menu
  trim_text
  valid_domain
  normalize_hostname
  valid_doh_path
  valid_allowlist_path
  valid_uint
  validate_runtime_values
  validate_dot
  state_keys
  set_defaults
  state_value
  atomic_copy
  new_workdir
  snapshot_file
  restore_file
  normalize_allowlist_file
  commit_allowlist
  wait_service
  service_error
  nginx_reload_or_start
  verify_nginx_included
  unbound_includes_target
  ca_bundle_path
  render_dot_upstream
  cert_valid
  mos_native_log
  run_action
)

c_ok() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m[!]\033[0m  %s\n' "$*" >&2; }
c_err() { printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; }
c_info() { printf '\033[1;36m[i]\033[0m  %s\n' "$*"; }
need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    c_err "请使用 root 运行"
    exit 1
  fi
}

pause_enter() {
  local reply
  echo
  read -r -p "按回车继续..." reply || return 0
}
log_action() {
  local msg="$*"
  if ! mkdir -p -- "$(dirname -- "$LOG_FILE")" || [[ -L "$LOG_FILE" ]] || \
    ! printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$SCRIPT_VERSION" "$msg" >> "$LOG_FILE"; then
    printf '[!] 无法写入管理日志: %s\n' "$LOG_FILE" >&2
  fi
  return 0
}
backup_file() {
  local file="$1" dest
  if [[ -e "$file" || -L "$file" ]]; then
    dest="${file}.bak.$(date +%Y%m%d_%H%M%S).${BASHPID}.${RANDOM}"
    cp -a -- "$file" "$dest" || { c_err "备份失败: $file"; return 1; }
    c_ok "已备份: $file"
    log_action "backup $file -> $dest"
  fi
}
remove_if_exists() {
  local path="$1"
  # Uninstall may delete only this deployment's explicit paths, never an arbitrary root.
  case "$path" in
    "$CONF_DIR"|"$WORK_DIR"|"$UNBOUND_SNIPPET"|"$NGINX_SITE_DIR/doh_${DOMAIN}.conf"|"$NGINX_LINK_DIR/doh_${DOMAIN}.conf"|"$NGINX_SSL_DIR"|/usr/local/bin/mosdns|"/etc/systemd/system/${MOSDNS_UNIT}.service"|"$ALLOWLIST_FILE") ;;
    *) c_err "拒绝删除未授权路径: $path"; return 1 ;;
  esac
  case "$path" in ''|/|/etc|/var|/var/lib|/usr|/usr/local|/root|/etc/nginx|/etc/unbound) c_err "拒绝危险删除路径"; return 1 ;; esac
  if [[ -e "$path" || -L "$path" ]]; then
    rm -rf -- "$path" || return 1
    c_ok "已删除: $path"
  else
    c_warn "不存在，跳过: $path"
  fi
}
have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

function_exists() {
  declare -F "$1" >/dev/null 2>&1
}

service_load_state() {
  local output
  # --value is unavailable in some systemd 219 installations.
  output="$(systemctl show -p LoadState "${1%.service}.service" 2>/dev/null)" || return 1
  printf '%s\n' "$output" | sed -n 's/^LoadState=//p'
}
service_exists() {
  local state
  state="$(service_load_state "$1")" || return 1
  case "$state" in loaded|masked|error|bad-setting|merged) return 0 ;; *) return 1 ;; esac
}
service_active() {
  systemctl is-active --quiet "$1" >/dev/null 2>&1
}

mosdns_process_exists() {
  pgrep -x mosdns >/dev/null 2>&1 || pgrep -x mosdns-x >/dev/null 2>&1
}
self_check_menu_functions() {
  local missing=0 fn
  for fn in "${MENU_REQUIRED_FUNCTIONS[@]}"; do
    if ! function_exists "$fn"; then c_err "菜单函数缺失: $fn"; missing=$((missing+1)); fi
  done
  (( missing == 0 )) || { c_err "启动自检失败，已阻止执行"; return 1; }
}
integrity_check_core_functions() {
  local missing=0 fn
  for fn in "${CORE_REQUIRED_FUNCTIONS[@]}"; do
    if ! function_exists "$fn"; then c_err "核心函数缺失: $fn"; missing=$((missing+1)); fi
  done
  (( missing == 0 )) || { c_err "版本完整性检查失败，已阻止执行"; return 1; }
}
show_integrity_summary() {
  c_ok "启动自检通过"
  c_ok "版本完整性检查通过（菜单及所需函数存在性；不等于联网测试）"
}
detect_platform() {
  [[ -r /etc/os-release ]] || { c_err "无法识别 Linux 发行版"; return 1; }
  # This file belongs to the operating system, not to user-provided state.
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-unknown}"; OS_NAME="${PRETTY_NAME:-unknown}"
  if have_cmd apt-get; then PKG_MGR=apt
  elif have_cmd dnf; then PKG_MGR=dnf
  elif have_cmd yum; then PKG_MGR=yum
  else c_err "未检测到支持的包管理器（apt/dnf/yum）"; return 1
  fi
  [[ -d /run/systemd/system ]] && have_cmd systemctl || { c_err "本脚本需要已运行的 systemd，不能在非 systemd 容器内直接部署"; return 1; }
  ARCH_RAW="$(uname -m)" || return 1
  case "$ARCH_RAW" in
    x86_64|amd64) ARCH_KEY=amd64 ;;
    aarch64|arm64) ARCH_KEY=arm64 ;;
    *) c_err "不支持的架构: $ARCH_RAW"; return 1 ;;
  esac
  if [[ -f /etc/nginx/nginx.conf ]]; then
    if grep -Eq '^[[:space:]]*include[[:space:]]+"?/etc/nginx/sites-enabled/' /etc/nginx/nginx.conf; then
      USE_NGINX_LINK=yes
    elif grep -Eq '^[[:space:]]*include[[:space:]]+"?/etc/nginx/conf\.d/' /etc/nginx/nginx.conf; then
      USE_NGINX_LINK=no
    else
      # Do not rewrite a custom nginx.conf based on a package-manager guess.
      [[ "$PKG_MGR" == apt ]] && USE_NGINX_LINK=yes || USE_NGINX_LINK=no
    fi
  else
    [[ "$PKG_MGR" == apt ]] && USE_NGINX_LINK=yes || USE_NGINX_LINK=no
  fi
  if [[ "$USE_NGINX_LINK" == yes ]]; then
    NGINX_SITE_DIR=/etc/nginx/sites-available; NGINX_LINK_DIR=/etc/nginx/sites-enabled
  else
    NGINX_SITE_DIR=/etc/nginx/conf.d; NGINX_LINK_DIR=/etc/nginx/conf.d
  fi
  if [[ -f /etc/unbound/unbound.conf.d/doh-forward.conf ]]; then
    UNBOUND_CONF_DIR=/etc/unbound/unbound.conf.d
  elif [[ -f /etc/unbound/conf.d/doh-forward.conf ]]; then
    UNBOUND_CONF_DIR=/etc/unbound/conf.d
  elif [[ "$PKG_MGR" != apt && -d /etc/unbound/conf.d ]]; then
    UNBOUND_CONF_DIR=/etc/unbound/conf.d
  else
    UNBOUND_CONF_DIR=/etc/unbound/unbound.conf.d
  fi
  UNBOUND_SNIPPET="$UNBOUND_CONF_DIR/doh-forward.conf"
}
ensure_state_file() {
  [[ ! -L "$CONF_DIR" && ! -L "$STATE_FILE" ]] || { c_err "状态目录或文件不能是符号链接"; return 1; }
  mkdir -p -- "$(dirname -- "$STATE_FILE")" || return 1
  if [[ ! -e "$STATE_FILE" ]]; then
    FIRST_RUN=yes
    set_defaults || return 1
    c_warn "未发现状态文件，开始初始化: $STATE_FILE"
    save_state || return 1
    c_ok "初始化完成"
  fi
}
load_state() {
  local line key value in_array=no seen_array=no number=0 token
  local -a tokens=()
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || { c_err "状态文件不存在或不安全"; return 1; }
  set_defaults || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number+1))
    line="$(trim_text "$line")" || return 1
    [[ -n "$line" && "$line" != \#* ]] || continue
    if [[ "$in_array" == yes ]]; then
      if [[ "$line" == ')' ]]; then in_array=no; continue; fi
      value="$(state_value "$line")" && validate_dot "$value" || { c_err "状态文件第 $number 行 DoT 数据无效"; return 1; }
      UPSTREAM_DOT+=("$value")
      continue
    fi
    if [[ "$line" == UPSTREAM_DOT=\(* ]]; then
      [[ "$seen_array" == no ]] || { c_err "状态文件重复定义 UPSTREAM_DOT"; return 1; }
      UPSTREAM_DOT=(); seen_array=yes
      value="$(trim_text "${line#UPSTREAM_DOT=(}")"
      if [[ "$value" == *')' ]]; then
        value="${value%)}"
        read -r -a tokens <<< "$value" || true
        for token in ${tokens[@]+"${tokens[@]}"}; do
          token="$(state_value "$token")" && validate_dot "$token" || { c_err "状态文件 DoT 数组无效"; return 1; }
          UPSTREAM_DOT+=("$token")
        done
      elif [[ -z "$value" ]]; then
        in_array=yes
      else
        c_err "状态文件第 $number 行数组格式无效"; return 1
      fi
      continue
    fi
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || { c_err "状态文件第 $number 行格式无效"; return 1; }
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    case "$key" in
      DOMAIN|DOH_PATH|ALLOWLIST_FILE|UB_MSG_CACHE|UB_RRSET_CACHE|UB_MIN_TTL|UB_MAX_TTL|UB_PREFETCH|UB_SERVE_EXPIRED|UB_SERVE_EXPIRED_TTL|UB_SERVE_EXPIRED_REPLY_TTL|UB_DO_IP6|MOS_LOG_LEVEL|DENY_MODE|NGX_HTTP2|NGX_LIMIT_REQ|NGX_RPS|NGX_BURST) ;;
      *) c_err "状态文件包含未知字段 $key；未执行其中的内容"; return 1 ;;
    esac
    value="$(state_value "$value")" || { c_err "状态文件第 $number 行包含非法转义或命令字符"; return 1; }
    # Old versions occasionally saved empty scalar values; keep their defaults.
    [[ -z "$value" ]] || printf -v "$key" '%s' "$value"
  done < "$STATE_FILE"
  [[ "$in_array" == no ]] || { c_err "状态文件中的数组没有闭合"; return 1; }
  if [[ -z "${UPSTREAM_DOT[*]-}" ]]; then UPSTREAM_DOT=("${DEFAULT_UPSTREAM_DOT[@]}"); fi
  DOMAIN="$(normalize_hostname "$DOMAIN")" || { c_err "状态文件 DOMAIN 不合法"; return 1; }
  NGINX_SSL_DIR="/etc/nginx/ssl/$DOMAIN"
  validate_runtime_values
}
save_state() {
  local tmp key value u
  validate_runtime_values || return 1
  [[ ! -L "$STATE_FILE" && ! -L "$CONF_DIR" ]] || return 1
  mkdir -p -- "$(dirname -- "$STATE_FILE")" || return 1
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! {
    while IFS= read -r key; do
      value="${!key}"
      # Validation excludes quotes, shell substitutions and control characters.
      printf '%s="%s"\n' "$key" "$value"
    done < <(state_keys)
    printf 'UPSTREAM_DOT=(\n'
    for u in "${UPSTREAM_DOT[@]}"; do printf '  "%s"\n' "$u"; done
    printf ')\n'
  } > "$tmp"; then rm -f -- "$tmp"; return 1; fi
  if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$STATE_FILE"; then rm -f -- "$tmp"; return 1; fi
  c_ok "已保存状态: $STATE_FILE"
  log_action "save state"
}
is_installed() {
  [[ -x /usr/local/bin/mosdns && -f /etc/systemd/system/${MOSDNS_UNIT}.service && -d "${CONF_DIR}" ]]
}

service_is_running() {
  service_active "${MOSDNS_UNIT}" && service_active "${UNBOUND_UNIT}" && service_active "${NGINX_UNIT}"
}

ensure_allowlist_file() {
  valid_allowlist_path "$ALLOWLIST_FILE" || { c_err "白名单路径无效: $ALLOWLIST_FILE"; return 1; }
  mkdir -p -- "$(dirname -- "$ALLOWLIST_FILE")" || return 1
  if [[ ! -e "$ALLOWLIST_FILE" ]]; then
    c_warn "未发现 allowlist.txt，开始初始化: $ALLOWLIST_FILE"
    printf '# allowlist.txt\n# 每行一个域名或后缀\n' > "$ALLOWLIST_FILE" || return 1
    chmod 644 "$ALLOWLIST_FILE" || return 1
    c_ok "allowlist.txt 初始化完成"
    log_action "init allowlist $ALLOWLIST_FILE"
  fi
}
allowlist_count() {
  # A read-only numeric helper must not initialize files or print UI messages.
  [[ -f "$ALLOWLIST_FILE" ]] || { printf '0\n'; return 0; }
  awk '!/^[[:space:]]*(#|$)/ {count++} END {print count+0}' "$ALLOWLIST_FILE"
}
show_brief_runtime_status() {
  echo "=============================================================="
  echo " ${SCRIPT_NAME} ${SCRIPT_VERSION}"
  echo " 系统: ${OS_NAME}"
  echo " 包管理器: ${PKG_MGR}"
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
  ensure_allowlist_file || return 1
  local total
  total="$(allowlist_count)" || return 1
  echo "==================== allowlist.txt ===================="
  echo "路径: ${ALLOWLIST_FILE}"
  echo "条数: ${total}"
  echo "--------------------------------------------------------"
  awk '!/^[[:space:]]*(#|$)/ {n++; if(n<=200) print " - " $0}' "$ALLOWLIST_FILE" || return 1
  if (( total > 200 )); then
    echo "..."
    echo "(仅显示前200条，总计 ${total} 条)"
  fi
  echo "========================================================"
}
edit_allowlist_vim() {
  local dir
  ensure_allowlist_file || return 1
  have_cmd vim || { c_err "未安装 vim，请先执行安装/修复环境"; return 1; }
  dir="$(new_workdir)" || return 1
  cp -- "$ALLOWLIST_FILE" "$dir/edit.txt" || { rm -rf -- "$dir"; return 1; }
  c_warn "使用 vim 编辑（保存 :wq，退出 :q）"
  if ! vim "$dir/edit.txt" || ! normalize_allowlist_file "$dir/edit.txt" "$dir/normalized" || ! commit_allowlist "$dir/normalized"; then
    c_err "编辑内容无效或保存失败，原白名单没有被覆盖"
    rm -rf -- "$dir"; return 1
  fi
  rm -rf -- "$dir"
  c_ok "已保存 allowlist.txt"
  log_action "edit allowlist by vim"
}
allowlist_dedupe_sort() {
  local dir
  ensure_allowlist_file || return 1
  dir="$(new_workdir)" || return 1
  if ! normalize_allowlist_file "$ALLOWLIST_FILE" "$dir/list" || ! commit_allowlist "$dir/list"; then
    rm -rf -- "$dir"; return 1
  fi
  rm -rf -- "$dir"
  c_ok "allowlist.txt 已去重排序"
  log_action "dedupe/sort allowlist"
}
add_allowlist_one() {
  local s dir
  ensure_allowlist_file || return 1
  read -r -p "请输入要新增的域名/后缀: " s || return 0
  [[ -n "$s" ]] || { c_warn "未输入，取消"; return 0; }
  s="$(normalize_domain_line "$s")" && [[ -n "$s" ]] || { c_err "域名格式无效"; return 1; }
  dir="$(new_workdir)" || return 1
  if ! normalize_allowlist_file "$ALLOWLIST_FILE" "$dir/list"; then rm -rf -- "$dir"; return 1; fi
  if grep -qxF -- "$s" "$dir/list"; then c_warn "已存在: $s"; rm -rf -- "$dir"; return 0; fi
  if ! printf '%s\n' "$s" >> "$dir/list" || ! LC_ALL=C sort -u -o "$dir/list" "$dir/list" || ! commit_allowlist "$dir/list"; then
    rm -rf -- "$dir"; return 1
  fi
  rm -rf -- "$dir"
  c_ok "已新增: $s"
  log_action "allowlist add $s"
}
remove_allowlist_one() {
  local s dir
  ensure_allowlist_file || return 1
  show_allowlist || return 1
  read -r -p "请输入要删除的域名/后缀（完整匹配）: " s || return 0
  [[ -n "$s" ]] || { c_warn "未输入，取消"; return 0; }
  s="$(normalize_domain_line "$s")" && [[ -n "$s" ]] || { c_err "域名格式无效"; return 1; }
  dir="$(new_workdir)" || return 1
  if ! normalize_allowlist_file "$ALLOWLIST_FILE" "$dir/list"; then rm -rf -- "$dir"; return 1; fi
  if ! grep -qxF -- "$s" "$dir/list"; then c_warn "未找到: $s"; rm -rf -- "$dir"; return 0; fi
  if ! awk -v target="$s" '$0 != target' "$dir/list" > "$dir/new" || ! commit_allowlist "$dir/new"; then
    rm -rf -- "$dir"; return 1
  fi
  rm -rf -- "$dir"
  c_ok "已删除: $s"
  c_info "修改仅保存至白名单；选择 17 后应用，空白名单会阻止应用。"
  log_action "allowlist remove $s"
}
normalize_domain_line() {
  local line="$1" kind tail
  # Only remove actual CR bytes. The old ${line//\r/} deleted the letter r.
  line="${line//$'\r'/}"
  line="${line#$'\xef\xbb\xbf'}"
  line="$(trim_text "$line")" || return 1
  [[ -n "$line" && "$line" != \#* ]] || return 0
  [[ "$line" != '- '* ]] || line="$(trim_text "${line#- }")"
  # Strip wrapping quotes, not letters or comma separators within rules.
  line="${line%,}"
  if [[ "$line" == \"*\" || "$line" == \'*\' ]]; then line="${line:1:${#line}-2}"; fi
  [[ "$line" != geosite:* ]] || return 0
  [[ "$line" != payload: && "$line" != rules: && "$line" != '[' && "$line" != ']' ]] || return 0
  case "${line^^}" in
    DOMAIN-SUFFIX,*|DOMAIN,*)
      IFS=',' read -r kind line tail <<< "$line"
      ;;
    *','*) return 1 ;;
  esac
  line="$(trim_text "$line")" || return 1
  if [[ "$line" == \"*\" || "$line" == \'*\' ]]; then line="${line:1:${#line}-2}"; fi
  [[ "$line" != domain:* ]] || line="${line#domain:}"
  case "$line" in
    http://*|https://*)
      line="${line#*://}"; line="${line%%/*}"; line="${line%%\?*}"; line="${line%%#*}"; line="${line%%:*}"
      ;;
  esac
  # Common suffix notation has the same domain-and-subdomain meaning here.
  [[ "$line" != +.* ]] || line="${line#+.}"
  [[ "$line" != \*.* ]] || line="${line#\*.}"
  line="${line%.}"; line="${line,,}"
  valid_domain "$line" || return 1
  printf '%s\n' "$line"
}
batch_import_allowlist() {
  local dir line before after first ended=no
  ensure_allowlist_file || return 1
  c_info "批量导入 allowlist.txt"
  echo
  echo "请粘贴域名列表，多行均可，输入 END 结束"
  echo "------------------------------------------------------------"
  dir="$(new_workdir)" || return 1
  : > "$dir/input"
  while IFS= read -r line; do
    if [[ "${line%$'\r'}" == END ]]; then ended=yes; break; fi
    printf '%s\n' "$line" >> "$dir/input" || { rm -rf -- "$dir"; return 1; }
  done
  if [[ "$ended" != yes ]]; then c_warn "输入已结束，未提交不完整导入"; rm -rf -- "$dir"; return 0; fi
  first="$(sed -n '/[^[:space:]]/{p;q;}' "$dir/input")"
  first="$(trim_text "$first")"
  if [[ "$first" == '['* || "$first" == '{'* ]]; then
    have_cmd jq || { c_err "JSON 导入需要 jq，请先安装/修复环境"; rm -rf -- "$dir"; return 1; }
    # Accept arrays of strings, or payload/rules/domains arrays; no blind URL extraction.
    if ! jq -er 'if type == "array" then . elif type == "object" then (.payload // .rules // .domains) else error("unsupported JSON") end | if type == "array" and all(.[]; type == "string") then .[] else error("expected string array") end' \
        "$dir/input" > "$dir/json-lines"; then
      c_err "JSON 结构无效，未修改白名单"; rm -rf -- "$dir"; return 1
    fi
    mv -- "$dir/json-lines" "$dir/input" || { rm -rf -- "$dir"; return 1; }
  fi
  if ! normalize_allowlist_file "$ALLOWLIST_FILE" "$dir/old" || ! normalize_allowlist_file "$dir/input" "$dir/new"; then
    c_err "导入内容含无效行，原白名单没有改动"; rm -rf -- "$dir"; return 1
  fi
  before="$(wc -l < "$dir/old")"
  if ! cat "$dir/old" "$dir/new" | LC_ALL=C sort -u > "$dir/all" || ! commit_allowlist "$dir/all"; then
    rm -rf -- "$dir"; return 1
  fi
  after="$(wc -l < "$dir/all")"
  rm -rf -- "$dir"
  c_ok "导入完成: 新增 $((after-before)) 条；原有 $before -> 现在 $after"
  log_action "batch import allowlist added=$((after-before)) total=$after"
}
show_config() {
  echo "==================== 当前配置 ===================="
  echo "版本: ${SCRIPT_VERSION}"
  echo "系统: ${OS_NAME}"
  echo "包管理器: ${PKG_MGR}"
  echo "架构: ${ARCH_RAW}"
  echo "DOMAIN: ${DOMAIN}"
  echo "DOH_PATH: ${DOH_PATH}"
  echo "ALLOWLIST_FILE: ${ALLOWLIST_FILE}"
  echo "ALLOWLIST_COUNT: $(allowlist_count)"
  echo "NGINX_SITE_DIR: ${NGINX_SITE_DIR}"
  echo "UNBOUND_CONF_DIR: ${UNBOUND_CONF_DIR}"
  echo "MOS_LOG_LEVEL: ${MOS_LOG_LEVEL}"
  echo
  echo "UPSTREAM_DOT:"
  local u
  for u in "${UPSTREAM_DOT[@]}"; do
    echo "  - ${u}"
  done
  echo "=================================================="
}

set_domain() {
  local newd old="$DOMAIN"
  echo "当前 DOMAIN: ${DOMAIN}"
  read -r -p "请输入新的伪装域名: " newd || return 0
  [[ -n "$newd" ]] || { c_warn "未输入，取消"; return 0; }
  newd="$(normalize_hostname "$newd")" || { c_err "请输入有效域名，不要填写协议、路径或端口"; return 1; }
  DOMAIN="$newd"; NGINX_SSL_DIR="/etc/nginx/ssl/$DOMAIN"
  if ! save_state; then DOMAIN="$old"; NGINX_SSL_DIR="/etc/nginx/ssl/$DOMAIN"; return 1; fi
  c_ok "DOMAIN 已设置为: $DOMAIN"
  c_warn "更换 DOMAIN 后需要重新签发证书；保存设置本身不会删除旧域名站点"
  log_action "set DOMAIN=$DOMAIN"
}
set_doh_path() {
  local p old="$DOH_PATH"
  echo "当前 DOH_PATH: ${DOH_PATH}"
  read -r -p "请输入新的伪装路径: " p || return 0
  [[ -n "$p" ]] || { c_warn "未输入，取消"; return 0; }
  p="$(trim_text "$p")"
  valid_doh_path "$p" || { c_err "路径无效：必须以 / 开头，不能是根路径、ACME 路径或包含查询参数/配置字符"; return 1; }
  DOH_PATH="$p"
  if ! save_state; then DOH_PATH="$old"; return 1; fi
  c_ok "DOH_PATH 已设置为: $DOH_PATH"
  log_action "set DOH_PATH=$DOH_PATH"
}
set_allowlist_file() {
  local p old="$ALLOWLIST_FILE"
  echo "当前 allowlist 路径: ${ALLOWLIST_FILE}"
  read -r -p "请输入新的 allowlist.txt 路径: " p || return 0
  [[ -n "$p" ]] || { c_warn "未输入，取消"; return 0; }
  p="$(trim_text "$p")"
  valid_allowlist_path "$p" || { c_err "请填写安全的绝对 .txt 文件路径，不能是目录或符号链接"; return 1; }
  ALLOWLIST_FILE="$p"
  if ! ensure_allowlist_file || ! save_state; then ALLOWLIST_FILE="$old"; return 1; fi
  c_ok "ALLOWLIST_FILE 已设置为: $ALLOWLIST_FILE"
  c_info "旧文件未删除；新文件中的域名以实际内容为准。"
  log_action "set ALLOWLIST_FILE=$ALLOWLIST_FILE"
}
list_upstreams() {
  echo "UPSTREAM_DOT 列表:"
  local i=1
  local u
  for u in "${UPSTREAM_DOT[@]}"; do
    echo "  [$i] ${u}"
    i=$((i+1))
  done
}

add_upstream() {
  local u x
  read -r -p "请输入新的 DoT 上游（例如 1.1.1.1@853）: " u || return 0
  [[ -n "$u" ]] || { c_warn "未输入，取消"; return 0; }
  u="$(trim_text "$u")"
  validate_dot "$u" || { c_err "上游格式无效；填写 IP或域名@端口，可附 #证书名，不能填写 DoH URL"; return 1; }
  for x in "${UPSTREAM_DOT[@]}"; do
    if [[ "$x" == "$u" ]]; then c_warn "已存在: $u"; return 0; fi
  done
  UPSTREAM_DOT+=("$u")
  if ! save_state; then unset 'UPSTREAM_DOT[${#UPSTREAM_DOT[@]}-1]'; return 1; fi
  c_ok "已新增: $u"
  log_action "add UPSTREAM_DOT+=$u"
}
remove_upstream() {
  local idx n target
  local -a previous=("${UPSTREAM_DOT[@]}")
  list_upstreams
  read -r -p "请输入要删除的序号: " idx || return 0
  [[ "$idx" =~ ^[0-9]{1,5}$ ]] || { c_err "请输入数字"; return 1; }
  idx=$((10#$idx)); n=${#UPSTREAM_DOT[@]}
  (( idx >= 1 && idx <= n )) || { c_err "超出范围"; return 1; }
  (( n > 1 )) || { c_err "必须至少保留一个 DoT 上游，已取消删除"; return 1; }
  target="${UPSTREAM_DOT[$((idx-1))]}"
  unset 'UPSTREAM_DOT[idx-1]'
  UPSTREAM_DOT=("${UPSTREAM_DOT[@]}")
  if ! save_state; then UPSTREAM_DOT=("${previous[@]}"); return 1; fi
  c_ok "已删除: $target"
  log_action "remove UPSTREAM_DOT-=$target"
}
quick_setup_wizard() {
  local input_domain input_path input_domains item dir apply_now
  local old_domain="$DOMAIN" old_path="$DOH_PATH"
  local -a domains_arr=()
  c_info "快速初始化向导"
  echo
  read -r -p "域名是什么？ " input_domain || return 0
  [[ -n "$input_domain" ]] || { c_warn "域名为空，取消"; return 0; }
  input_domain="$(normalize_hostname "$input_domain")" || { c_err "域名格式无效"; return 1; }
  read -r -p "路径是什么？ " input_path || return 0
  input_path="$(trim_text "$input_path")"
  [[ -n "$input_path" ]] || { c_warn "路径为空，取消"; return 0; }
  [[ "$input_path" == /* ]] || input_path="/$input_path"
  valid_doh_path "$input_path" || { c_err "路径无效或与 ACME 校验路径冲突"; return 1; }
  read -r -p "要添加进 allowlist.txt 的域名是什么？以英文逗号分割: " input_domains || return 0
  [[ -n "$input_domains" ]] || { c_warn "allowlist 为空，取消"; return 0; }
  ensure_allowlist_file || return 1
  dir="$(new_workdir)" || return 1
  snapshot_file "$dir" state "$STATE_FILE" && snapshot_file "$dir" allow "$ALLOWLIST_FILE" || { rm -rf -- "$dir"; return 1; }
  if ! normalize_allowlist_file "$ALLOWLIST_FILE" "$dir/list"; then rm -rf -- "$dir"; return 1; fi
  IFS=',' read -r -a domains_arr <<< "$input_domains"
  for item in "${domains_arr[@]}"; do
    item="$(normalize_domain_line "$item")" && [[ -n "$item" ]] || { c_err "输入含无效域名；未清空原白名单"; rm -rf -- "$dir"; return 1; }
    printf '%s\n' "$item" >> "$dir/list" || { rm -rf -- "$dir"; return 1; }
  done
  LC_ALL=C sort -u -o "$dir/list" "$dir/list" || { rm -rf -- "$dir"; return 1; }
  DOMAIN="$input_domain"; DOH_PATH="$input_path"; NGINX_SSL_DIR="/etc/nginx/ssl/$DOMAIN"
  if ! commit_allowlist "$dir/list" || ! save_state; then
    restore_file "$dir" state "$STATE_FILE" || c_err "状态文件恢复失败，备份位于 $dir"
    restore_file "$dir" allow "$ALLOWLIST_FILE" || c_err "白名单恢复失败，备份位于 $dir"
    DOMAIN="$old_domain"; DOH_PATH="$old_path"; NGINX_SSL_DIR="/etc/nginx/ssl/$DOMAIN"
    return 1
  fi
  rm -rf -- "$dir"
  c_ok "快速初始化完成"
  c_info "DOMAIN = $DOMAIN"
  c_info "DOH_PATH = $DOH_PATH"
  c_info "ALLOWLIST_COUNT = $(allowlist_count)"
  log_action "quick setup wizard done"
  c_info "开始安装/修复环境..."
  ensure_environment || return 1
  c_info "开始自动尝试为当前 DOMAIN 签发证书..."
  if issue_cert; then c_ok "证书已准备完成"; else c_warn "签发失败，未启用新 HTTPS 配置，请稍后手动重试"; return 1; fi
  echo
  read -r -p "是否立即应用配置？(y/n): " apply_now || return 0
  case "$apply_now" in y|Y) apply_all ;; *) c_info "已跳过立即应用配置" ;; esac
}
doh_path_conflict_check() {
  c_info "DoH 路径冲突检测"
  valid_doh_path "$DOH_PATH" || { c_err "DOH_PATH 无效或与根路径/ACME 冲突: $DOH_PATH"; return 1; }
  if [[ -e "${STATIC_ROOT}${DOH_PATH}" ]]; then
    c_warn "静态目录中存在同名文件或目录: ${STATIC_ROOT}${DOH_PATH}；精确 DoH 路由会优先匹配"
  fi
  c_ok "路径检测通过"
}
cert_exists_for_domain() {
  [[ -s "${NGINX_SSL_DIR}/fullchain.pem" && -s "${NGINX_SSL_DIR}/${DOMAIN}.key" ]]
}
check_domain_cert_before_apply() {
  if cert_valid; then c_ok "当前 DOMAIN 的证书存在、处于有效期且域名/私钥匹配"; return 0; fi
  c_err "当前 DOMAIN 证书不存在、为空、已过期/尚未生效，或域名/私钥不匹配"
  echo " - ${NGINX_SSL_DIR}/fullchain.pem"
  echo " - ${NGINX_SSL_DIR}/${DOMAIN}.key"
  c_warn "请先查看证书有效期或签发证书，已阻止应用"
  return 1
}
install_packages() {
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update || { c_err "软件源更新失败，未继续安装"; return 1; }
      apt-get install -y --no-install-recommends ca-certificates curl wget jq unzip tar nginx openssl socat unbound vim iproute2 procps util-linux cron python3 || return 1
      ;;
    dnf|yum)
      case "$OS_ID" in centos|rocky|almalinux|rhel|ol)
        "$PKG_MGR" install -y epel-release || c_warn "EPEL 未安装；继续尝试现有软件源，不更改系统源地址"
        ;;
      esac
      "$PKG_MGR" install -y ca-certificates curl wget jq unzip tar nginx openssl socat unbound vim-enhanced iproute procps-ng util-linux cronie python3 || {
        c_err "依赖安装失败。请检查发行版软件源（尤其已停止维护的系统），未修改防火墙或禁用 SELinux。"; return 1;
      }
      ;;
    *) c_err "不支持的包管理器: $PKG_MGR"; return 1 ;;
  esac
  local command_name cron_unit
  for command_name in curl jq nginx openssl unbound unbound-checkconf vim ss pgrep flock timeout crontab python3; do
    have_cmd "$command_name" || { c_err "安装后仍缺少命令: $command_name"; return 1; }
  done
  if [[ "$PKG_MGR" == apt ]]; then cron_unit=cron; else cron_unit=crond; fi
  systemctl enable --now "$cron_unit" || { c_err "证书定时续期所需的 cron 服务无法启动"; return 1; }
  systemctl enable "$NGINX_UNIT" "$UNBOUND_UNIT" || return 1
  c_ok "依赖安装完成"
  log_action "install deps by $PKG_MGR"
}
download_and_install_mosdnsx() {
  local json name url dir bin target_tmp digest actual
  c_info "安装/更新 mosdns-x"
  json="$(curl -fsSL --connect-timeout 10 --max-time 40 --retry 2 https://api.github.com/repos/pmkol/mosdns-x/releases/latest)" || { c_err "无法读取 mosdns-x 发行信息"; return 1; }
  name="$(printf '%s' "$json" | jq -er --arg arch "$ARCH_KEY" '[.assets[] | select((.name|ascii_downcase|test("linux")) and (.name|ascii_downcase|test($arch)) and ((.name|endswith(".zip")) or (.name|endswith(".tar.gz"))))][0].name // error("asset not found")')" || return 1
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { c_err "发行包名称无效"; return 1; }
  url="$(printf '%s' "$json" | jq -er --arg n "$name" '.assets[]|select(.name==$n)|.browser_download_url')" || return 1
  [[ "$url" == https://github.com/pmkol/mosdns-x/releases/download/* ]] || { c_err "发行包地址无效"; return 1; }
  dir="$(new_workdir)" || return 1
  if ! curl -fL --connect-timeout 10 --max-time 180 --retry 2 -o "$dir/$name" "$url"; then rm -rf -- "$dir"; return 1; fi
  digest="$(printf '%s' "$json" | jq -r --arg n "$name" '.assets[]|select(.name==$n)|.digest // ""')" || { rm -rf -- "$dir"; return 1; }
  if [[ "$digest" == sha256:* ]]; then
    actual="$(sha256sum "$dir/$name")" || { rm -rf -- "$dir"; return 1; }
    [[ "${actual%% *}" == "${digest#sha256:}" ]] || { c_err "发行包校验失败"; rm -rf -- "$dir"; return 1; }
  fi
  mkdir "$dir/out" || { rm -rf -- "$dir"; return 1; }
  if [[ "$name" == *.zip ]]; then
    unzip -q "$dir/$name" -d "$dir/out" || { rm -rf -- "$dir"; return 1; }
  else
    tar -xzf "$dir/$name" -C "$dir/out" --no-same-owner || { rm -rf -- "$dir"; return 1; }
  fi
  bin="$(find "$dir/out" -maxdepth 3 -type f \( -name mosdns -o -name mosdns-x \) -print -quit)" || { rm -rf -- "$dir"; return 1; }
  [[ -n "$bin" ]] || { c_err "解压后未找到 mosdns 二进制"; rm -rf -- "$dir"; return 1; }
  chmod 755 "$bin" && timeout 10 "$bin" --help >/dev/null || { c_err "二进制无法执行，可能架构或系统版本不兼容"; rm -rf -- "$dir"; return 1; }
  backup_file /usr/local/bin/mosdns || { rm -rf -- "$dir"; return 1; }
  # Rename instead of overwriting a running executable (avoids ETXTBSY).
  if ! atomic_copy "$bin" /usr/local/bin/mosdns 0755; then rm -rf -- "$dir"; return 1; fi
  rm -rf -- "$dir"
  c_ok "mosdns-x 安装完成: /usr/local/bin/mosdns"
  log_action "install mosdns-x $name"
}
create_user_and_dirs() {
  local shell dir group
  shell="$(command -v nologin)" || shell=/sbin/nologin
  [[ -x "$shell" ]] || { c_err "找不到 nologin"; return 1; }
  if ! id -u "$MOSDNS_USER" >/dev/null 2>&1; then
    useradd --system --user-group --home-dir "$WORK_DIR" --shell "$shell" "$MOSDNS_USER" || return 1
    c_ok "已创建用户: $MOSDNS_USER"
    log_action "create user $MOSDNS_USER"
  fi
  for dir in "$CONF_DIR" "$WORK_DIR" "$NGINX_SSL_DIR" "$ACME_WEBROOT" "$STATIC_ROOT" "$UNBOUND_CONF_DIR" "$NGINX_SITE_DIR"; do
    [[ ! -L "$dir" ]] || { c_err "拒绝更改符号链接目录: $dir"; return 1; }
    mkdir -p -- "$dir" || return 1
  done
  group="$(id -gn "$MOSDNS_USER")" || return 1
  chown "$MOSDNS_USER:$group" "$WORK_DIR" && chmod 750 "$WORK_DIR" || return 1
  chmod 755 "$CONF_DIR" "$ACME_WEBROOT" "$STATIC_ROOT" || return 1
}
install_mosdns_systemd() {
  local group dir file="/etc/systemd/system/${MOSDNS_UNIT}.service"
  group="$(id -gn "$MOSDNS_USER")" || return 1
  dir="$(new_workdir)" || return 1
  c_info "安装/修复 mosdns systemd 服务"
  cat > "$dir/unit" <<EOF2 || { rm -rf -- "$dir"; return 1; }
[Unit]
Description=mosdns-x (DoH backend)
After=network-online.target
Wants=network-online.target

[Service]
User=${MOSDNS_USER}
Group=${group}
WorkingDirectory=${WORK_DIR}
ExecStart=/usr/local/bin/mosdns start -c ${CONF_DIR}/config.yaml -d ${WORK_DIR}
Restart=on-failure
RestartSec=1s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF2
  if ! backup_file "$file" || ! atomic_copy "$dir/unit" "$file" 0644 || ! systemctl daemon-reload || ! systemctl enable "$MOSDNS_UNIT"; then
    rm -rf -- "$dir"; return 1
  fi
  rm -rf -- "$dir"
  c_ok "mosdns systemd 已就绪"
  log_action "install systemd mosdns"
}
ensure_environment() {
  local dir running=no unit="/etc/systemd/system/${MOSDNS_UNIT}.service"
  c_info "开始安装/修复环境"
  install_packages || return 1
  detect_platform || return 1
  create_user_and_dirs || return 1
  ensure_allowlist_file || return 1
  dir="$(new_workdir)" || return 1
  snapshot_file "$dir" binary /usr/local/bin/mosdns && snapshot_file "$dir" unit "$unit" || { rm -rf -- "$dir"; return 1; }
  service_active "$MOSDNS_UNIT" && running=yes
  if ! download_and_install_mosdnsx || ! install_mosdns_systemd; then
    restore_file "$dir" binary /usr/local/bin/mosdns || c_err "二进制恢复失败，备份: $dir"
    restore_file "$dir" unit "$unit" || c_err "服务文件恢复失败，备份: $dir"
    systemctl daemon-reload || true
    return 1
  fi
  if [[ "$running" == yes ]]; then
    if ! systemctl restart "$MOSDNS_UNIT" || ! wait_service "$MOSDNS_UNIT"; then
      service_error "$MOSDNS_UNIT"
      restore_file "$dir" binary /usr/local/bin/mosdns && restore_file "$dir" unit "$unit" || { c_err "恢复失败，备份: $dir"; return 1; }
      systemctl daemon-reload && systemctl restart "$MOSDNS_UNIT" && wait_service "$MOSDNS_UNIT" || c_err "旧版服务也未恢复，请检查 $dir"
      return 1
    fi
  fi
  rm -rf -- "$dir"
  c_ok "环境准备完成"
  log_action "ensure environment done"
}
write_unbound_forward() {
  local dir main_conf=/etc/unbound/unbound.conf ca u port interfaces
  validate_runtime_values || return 1
  have_cmd unbound-checkconf || { c_err "缺少 unbound-checkconf，请先安装/修复环境"; return 1; }
  [[ -f "$main_conf" && ! -L "$main_conf" ]] || { c_err "Unbound 主配置不存在或为符号链接: $main_conf"; return 1; }
  ca="$(ca_bundle_path)" || return 1
  dir="$(new_workdir)" || return 1
  mkdir -p -- "$UNBOUND_CONF_DIR" || { rm -rf -- "$dir"; return 1; }
  snapshot_file "$dir" snippet "$UNBOUND_SNIPPET" && snapshot_file "$dir" main "$main_conf" || { rm -rf -- "$dir"; return 1; }
  c_info "写入 Unbound 配置: $UNBOUND_SNIPPET"
  cat > "$dir/config" <<EOF2 || { rm -rf -- "$dir"; return 1; }
server:
  interface: 127.0.0.1
  port: ${UNBOUND_PORT}
  access-control: 127.0.0.0/8 allow
  msg-cache-size: ${UB_MSG_CACHE}
  rrset-cache-size: ${UB_RRSET_CACHE}
  cache-min-ttl: ${UB_MIN_TTL}
  cache-max-ttl: ${UB_MAX_TTL}
  prefetch: ${UB_PREFETCH}
  prefetch-key: ${UB_PREFETCH}
  serve-expired: ${UB_SERVE_EXPIRED}
  serve-expired-ttl: ${UB_SERVE_EXPIRED_TTL}
  serve-expired-reply-ttl: ${UB_SERVE_EXPIRED_REPLY_TTL}
  do-ip6: ${UB_DO_IP6}
  hide-identity: yes
  hide-version: yes
  qname-minimisation: yes
  tls-cert-bundle: "${ca}"

forward-zone:
  name: "."
  forward-tls-upstream: yes
EOF2
  for u in "${UPSTREAM_DOT[@]}"; do
    if ! render_dot_upstream "$u" >> "$dir/config"; then rm -rf -- "$dir"; return 1; fi
  done
  unbound-checkconf "$dir/config" || { c_err "新 Unbound 配置检查失败，未替换旧配置"; rm -rf -- "$dir"; return 1; }
  backup_file "$UNBOUND_SNIPPET" && atomic_copy "$dir/config" "$UNBOUND_SNIPPET" 0644 || { rm -rf -- "$dir"; return 1; }
  if ! unbound_includes_target "$main_conf" "$UNBOUND_SNIPPET"; then
    backup_file "$main_conf" || { restore_file "$dir" snippet "$UNBOUND_SNIPPET"; rm -rf -- "$dir"; return 1; }
    if ! { cat "$main_conf"; printf '\n# BEGIN DOH-MANAGER-INCLUDE\ninclude-toplevel: "%s"\n# END DOH-MANAGER-INCLUDE\n' "$UNBOUND_SNIPPET"; } > "$dir/main-new" || \
      ! atomic_copy "$dir/main-new" "$main_conf" 0644; then
      restore_file "$dir" snippet "$UNBOUND_SNIPPET" || true
      rm -rf -- "$dir"; return 1
    fi
  fi
  if ! unbound-checkconf "$main_conf"; then
    c_err "Unbound 合并配置检查失败，恢复原文件"
    restore_file "$dir" snippet "$UNBOUND_SNIPPET" && restore_file "$dir" main "$main_conf" || { c_err "恢复失败，备份: $dir"; return 1; }
    rm -rf -- "$dir"; return 1
  fi
  port="$(unbound-checkconf -o port "$main_conf")" || port=""
  interfaces="$(unbound-checkconf -o interface "$main_conf")" || interfaces=""
  if [[ "$port" != "$UNBOUND_PORT" ]] || printf '%s\n' "$interfaces" | grep -Eq '(^|[[:space:]])(0\.0\.0\.0|::0?|\*)(@|$|[[:space:]])'; then
    c_err "Unbound 未使用预期本地端口，或其他配置把监听暴露到所有接口，已取消覆盖"
    restore_file "$dir" snippet "$UNBOUND_SNIPPET" && restore_file "$dir" main "$main_conf" || { c_err "恢复失败，备份: $dir"; return 1; }
    rm -rf -- "$dir"; return 1
  fi
  rm -rf -- "$dir"
  c_ok "Unbound 配置 OK"
  log_action "write unbound config"
}
build_domain_rules_from_allowlist() {
  local dir
  [[ -f "$ALLOWLIST_FILE" ]] || { c_err "白名单文件不存在: $ALLOWLIST_FILE" >&2; return 1; }
  dir="$(new_workdir)" || return 1
  if ! normalize_allowlist_file "$ALLOWLIST_FILE" "$dir/list"; then rm -rf -- "$dir"; return 1; fi
  if [[ ! -s "$dir/list" ]]; then c_err "allowlist.txt 为空: $ALLOWLIST_FILE" >&2; rm -rf -- "$dir"; return 1; fi
  awk '{print "        - \"domain:" $0 "\""}' "$dir/list"
  local result=$?
  rm -rf -- "$dir"
  return "$result"
}
write_mosdns_config() {
  local dir domain_rules log_block deny_action=_new_refused_response
  validate_runtime_values || return 1
  domain_rules="$(build_domain_rules_from_allowlist)" || return 1
  log_block="$(mos_native_log)" || return 1
  [[ "$DENY_MODE" != nxdomain ]] || deny_action=_new_nxdomain_response
  mkdir -p -- "$CONF_DIR" || return 1
  dir="$(new_workdir)" || return 1
  c_info "写入 mosdns 配置: ${CONF_DIR}/config.yaml"
  cat > "$dir/config" <<EOF2 || { rm -rf -- "$dir"; return 1; }
log:
${log_block}

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
EOF2
  if ! backup_file "$CONF_DIR/config.yaml" || ! atomic_copy "$dir/config" "$CONF_DIR/config.yaml" 0644; then
    rm -rf -- "$dir"; return 1
  fi
  rm -rf -- "$dir"
  c_ok "mosdns 配置已写入，服务启动检查通过后才算生效"
  log_action "write mosdns config"
}
write_nginx_site() {
  local nginx_site="${NGINX_SITE_DIR}/doh_${DOMAIN}.conf" nginx_link="${NGINX_LINK_DIR}/doh_${DOMAIN}.conf"
  local dir http2_line="" limit_req_block="" limit_req_apply="" zone
  validate_runtime_values && check_domain_cert_before_apply || return 1
  mkdir -p -- "$NGINX_SITE_DIR" "$NGINX_LINK_DIR" "$ACME_WEBROOT" "$STATIC_ROOT" || return 1
  dir="$(new_workdir)" || return 1
  snapshot_file "$dir" site "$nginx_site" || { rm -rf -- "$dir"; return 1; }
  if [[ "$USE_NGINX_LINK" == yes ]]; then snapshot_file "$dir" link "$nginx_link" || { rm -rf -- "$dir"; return 1; }; fi
  [[ "$NGX_HTTP2" != yes ]] || http2_line=http2
  zone="doh_$(printf '%s' "$DOMAIN" | sha256sum)"; zone="${zone:0:20}"
  if [[ "$NGX_LIMIT_REQ" == yes ]]; then
    limit_req_block="limit_req_zone \$binary_remote_addr zone=${zone}:10m rate=${NGX_RPS}r/s;"
    if (( NGX_BURST > 0 )); then
      limit_req_apply="    limit_req zone=${zone} burst=${NGX_BURST} nodelay;"
    else
      limit_req_apply="    limit_req zone=${zone};"
    fi
  fi
  if [[ ! -f "$STATIC_ROOT/index.html" ]]; then printf '%s\n' "$TEMPLATE_SIMPLE" > "$STATIC_ROOT/index.html" || { rm -rf -- "$dir"; return 1; }; fi
  c_info "写入 Nginx 配置: $nginx_site"
  cat > "$dir/config" <<EOF2 || { rm -rf -- "$dir"; return 1; }
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
    return 301 https://${DOMAIN}\$request_uri;
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
EOF2
  if ! backup_file "$nginx_site" || ! atomic_copy "$dir/config" "$nginx_site" 0644; then rm -rf -- "$dir"; return 1; fi
  if [[ "$USE_NGINX_LINK" == yes ]] && ! ln -sfn -- "$nginx_site" "$nginx_link"; then
    restore_file "$dir" site "$nginx_site" || true
    rm -rf -- "$dir"; return 1
  fi
  if ! nginx -t 2> "$dir/check"; then
    # Older OpenSSL builds may not recognize TLSv1.3; never disable TLSv1.2.
    if grep -Eq 'invalid value.*TLSv1\.3|invalid.*TLSv1\.3' "$dir/check"; then
      sed 's/ssl_protocols TLSv1.2 TLSv1.3;/ssl_protocols TLSv1.2;/' "$dir/config" > "$dir/compatible"
      atomic_copy "$dir/compatible" "$nginx_site" 0644 || true
    fi
  fi
  if ! nginx -t || ! verify_nginx_included; then
    cat "$dir/check" >&2
    restore_file "$dir" site "$nginx_site" || { c_err "恢复失败，备份: $dir"; return 1; }
    if [[ "$USE_NGINX_LINK" == yes ]]; then restore_file "$dir" link "$nginx_link" || { c_err "恢复失败，备份: $dir"; return 1; }; fi
    rm -rf -- "$dir"; return 1
  fi
  rm -rf -- "$dir"
  c_ok "Nginx 配置 OK"
  log_action "write nginx site"
}
validate_mos_log_level() {
  case "$1" in none|error|warning|warn|info|debug) return 0 ;; *) return 1 ;; esac
}
apply_mosdns_log_level() {
  local dir config="$CONF_DIR/config.yaml" running=no native="$MOS_LOG_LEVEL" rc=0
  validate_mos_log_level "$MOS_LOG_LEVEL" || { c_err "非法日志等级: $MOS_LOG_LEVEL"; return 1; }
  if [[ ! -f "$config" ]]; then
    save_state || return 1
    c_warn "尚无运行配置；等级已保存，在生成配置并应用后生效"
    return 0
  fi
  dir="$(new_workdir)" || return 1
  snapshot_file "$dir" state "$STATE_FILE" && snapshot_file "$dir" config "$config" || { rm -rf -- "$dir"; return 1; }
  [[ "$native" != warning ]] || native=warn
  [[ "$native" != none ]] || native=error
  # Change only log.level/log.file. Do NOT apply pending domain/path/allowlist edits.
  if ! awk -v lvl="$native" -v silent="$MOS_LOG_LEVEL" '
    BEGIN {inside=0; found=0}
    /^log:[[:space:]]*(#.*)?$/ {if(found) exit 4; found=1; inside=1; print; print "  level: " lvl; if(silent=="none") print "  file: /dev/null"; next}
    inside && /^[^[:space:]#]/ {inside=0}
    inside && /^[[:space:]]+level:/ {next}
    inside && /^[[:space:]]+file:/ {if(silent=="none" || $0 ~ /\/dev\/null/) next}
    {print}
    END {if(!found) exit 3}
  ' "$config" > "$dir/new"; then
    c_err "当前 YAML 的 log 段不是预期格式，未覆盖运行配置"; rm -rf -- "$dir"; return 1
  fi
  service_active "$MOSDNS_UNIT" && running=yes
  if ! backup_file "$config" || ! atomic_copy "$dir/new" "$config" 0644 || ! save_state; then rc=1; fi
  if (( rc == 0 )) && [[ "$running" == yes ]]; then
    if ! systemctl restart "$MOSDNS_UNIT" || ! wait_service "$MOSDNS_UNIT"; then service_error "$MOSDNS_UNIT"; rc=1; fi
  fi
  if (( rc != 0 )); then
    restore_file "$dir" state "$STATE_FILE" && restore_file "$dir" config "$config" || { c_err "恢复失败，备份: $dir"; return 1; }
    if [[ "$running" == yes ]]; then
      systemctl restart "$MOSDNS_UNIT" && wait_service "$MOSDNS_UNIT" || { c_err "恢复旧配置后服务仍未正常运行，保留备份: $dir"; return 1; }
    fi
    load_state || { c_err "旧状态文件读取失败，保留备份: $dir"; return 1; }
    rm -rf -- "$dir"
    c_err "修改失败，已恢复原日志设置"
    return 1
  fi
  rm -rf -- "$dir"
  if [[ "$running" == yes ]]; then
    c_ok "日志等级已生效，mosdns 已重启"
  elif service_exists "$MOSDNS_UNIT"; then
    c_ok "日志等级已保存；mosdns 保持停止状态，下次启动生效"
  else
    c_warn "日志等级已写入配置；非 systemd 进程需要由原启动方式重启"
  fi
  if [[ "$MOS_LOG_LEVEL" == none ]]; then c_info "none 只抑制 mosdns 运行日志；不删除历史日志和 systemd 的启停记录。"; fi
  log_action "set MOS_LOG_LEVEL=$MOS_LOG_LEVEL"
}
set_mosdns_log_level_menu() {
  local level_opt old_level="$MOS_LOG_LEVEL"
  echo "==================== 日志等级设置 ===================="
  echo "当前日志等级: ${MOS_LOG_LEVEL}"
  echo
  echo "1. none     - 不记录日志"
  echo "2. error    - 只记录错误"
  echo "3. warning  - 记录错误和警告"
  echo "4. info     - 记录常规信息，推荐默认"
  echo "5. debug    - 记录最详细日志，适合排障"
  echo "0. 返回"
  echo "======================================================"
  read -r -p "请选择日志等级: " level_opt || return 0

  case "${level_opt}" in
    1) MOS_LOG_LEVEL="none" ;;
    2) MOS_LOG_LEVEL="error" ;;
    3) MOS_LOG_LEVEL="warning" ;;
    4) MOS_LOG_LEVEL="info" ;;
    5) MOS_LOG_LEVEL="debug" ;;
    0) return ;;
    *) c_warn "无效选项"; return ;;
  esac

  c_info "已设置日志等级为: ${MOS_LOG_LEVEL}"
  if ! apply_mosdns_log_level; then MOS_LOG_LEVEL="$old_level"; return 1; fi
}
show_recent_logs_50() {
  local output
  echo "==================== 最近50条日志 ===================="
  have_cmd journalctl || { c_err "缺少 journalctl，无法读取系统日志"; return 1; }
  output="$(journalctl -u "$MOSDNS_UNIT" -n 50 --no-pager -o short-iso 2>&1)" || { c_err "$output"; return 1; }
  if [[ -n "$output" && "$output" != *'-- No entries --'* && "$output" != *'No journal files'* ]]; then
    printf '%s\n' "$output"
    return 0
  fi
  output="$(journalctl _COMM=mosdns _COMM=mosdns-x -n 50 --no-pager -o short-iso 2>&1)" || { c_err "$output"; return 1; }
  if [[ -z "$output" || "$output" == *'-- No entries --'* || "$output" == *'No journal files'* ]]; then
    c_warn "未找到历史运行日志。可能尚未产生、已轮转、日志等级为 none，或进程未输出至 journald；不据此判断服务未安装。"
  else
    printf '%s\n' "$output"
  fi
}
follow_mosdns_logs() {
  local rc=0 old_trap interrupted=no
  local -a selectors=()
  echo "==================== 实时查看日志 ===================="
  c_info "按 Ctrl+C 退出实时日志查看"
  have_cmd journalctl || { c_err "缺少 journalctl"; return 1; }
  if service_exists "$MOSDNS_UNIT" || service_active "$MOSDNS_UNIT"; then
    selectors=(-u "$MOSDNS_UNIT")
  else
    selectors=(_COMM=mosdns _COMM=mosdns-x)
    c_warn "当前没有可加载的 mosdns unit，按进程名跟随 journald；没有输出不等于服务未安装。"
  fi
  old_trap="$(trap -p INT)"
  trap 'interrupted=yes' INT
  if journalctl "${selectors[@]}" -n 20 -f --no-pager -o short-iso; then rc=0; else rc=$?; fi
  if [[ -n "$old_trap" ]]; then eval "$old_trap"; else trap - INT; fi
  if [[ "$interrupted" == yes ]] || (( rc == 130 )); then
    printf '\n'; return 0
  fi
  (( rc == 0 )) || { c_err "实时日志读取失败（返回码 $rc）"; return "$rc"; }
}
log_settings_menu() {
  local subopt reply
  while true; do
    echo "==================== 日志设置 ===================="
    echo "1. 日志等级设置"
    echo "2. 查看最近50条日志"
    echo "3. 实时查看日志"
    echo "0. 返回上一级"
    echo "=================================================="
    read -r -p "请选择操作: " subopt || return 0
    echo
    case "$subopt" in
      1) run_action set_mosdns_log_level_menu ;;
      2) run_action show_recent_logs_50 ;;
      3) run_action follow_mosdns_logs ;;
      0) return 0 ;;
      *) c_warn "无效选项" ;;
    esac
    echo
    read -r -p "按回车继续返回日志菜单..." reply || return 0
    echo
  done
}
acme_sh_path() { echo "/root/.acme.sh/acme.sh"; }

ensure_acme_sh() {
  local acme dir
  acme="$(acme_sh_path)"
  if [[ -x "$acme" ]]; then return 0; fi
  have_cmd curl && have_cmd crontab || { c_err "缺少 curl/crontab，请先安装/修复环境"; return 1; }
  c_info "安装 acme.sh..."
  dir="$(new_workdir)" || return 1
  if ! curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 https://get.acme.sh -o "$dir/install.sh" || \
     ! sh "$dir/install.sh" || [[ ! -x "$acme" ]]; then
    rm -rf -- "$dir"
    c_err "acme.sh 安装失败或安装不完整"
    return 1
  fi
  rm -rf -- "$dir"
  c_ok "acme.sh 安装完成"
  log_action "install acme.sh"
}
write_nginx_http_only_for_acme() {
  local site="$NGINX_SITE_DIR/doh_${DOMAIN}.conf" link="$NGINX_LINK_DIR/doh_${DOMAIN}.conf" dir
  valid_domain "$DOMAIN" && [[ "$DOMAIN" != *_* ]] || return 1
  mkdir -p -- "$NGINX_SITE_DIR" "$NGINX_LINK_DIR" "$ACME_WEBROOT" || return 1
  dir="$(new_workdir)" || return 1
  c_info "临时写入 Nginx(80) 用于 ACME"
  cat > "$dir/config" <<EOF2 || { rm -rf -- "$dir"; return 1; }
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
EOF2
  # The caller snapshots the existing site and restores it on all exit paths.
  if ! atomic_copy "$dir/config" "$site" 0644; then rm -rf -- "$dir"; return 1; fi
  if [[ "$USE_NGINX_LINK" == yes ]] && ! ln -sfn -- "$site" "$link"; then rm -rf -- "$dir"; return 1; fi
  rm -rf -- "$dir"
  nginx -t && verify_nginx_included && nginx_reload_or_start || return 1
  c_ok "ACME 环境准备完成"
}
issue_cert() {
  local acme dir site link rc=0 changed=no was_active=no probe body issue_rc
  DOMAIN="$(normalize_hostname "$DOMAIN")" || { c_err "域名格式无效"; return 1; }
  NGINX_SSL_DIR="/etc/nginx/ssl/$DOMAIN"
  case "$DOMAIN" in example.com|example.net|example.org|*.example.com|*.example.net|*.example.org)
    c_err "当前是保留示例域名，请填写你控制的真实域名"; return 1 ;;
  esac
  have_cmd nginx && have_cmd openssl || { c_err "请先执行安装/修复环境"; return 1; }
  if cert_valid; then c_ok "当前域名证书仍有效，复用现有证书；需要重签时使用强制续期"; return 0; fi
  ensure_acme_sh || return 1
  acme="$(acme_sh_path)"; site="$NGINX_SITE_DIR/doh_${DOMAIN}.conf"; link="$NGINX_LINK_DIR/doh_${DOMAIN}.conf"
  mkdir -p -- "$ACME_WEBROOT/.well-known/acme-challenge" "$NGINX_SSL_DIR" "$NGINX_SITE_DIR" "$NGINX_LINK_DIR" || return 1
  chmod 755 "$ACME_WEBROOT" "$ACME_WEBROOT/.well-known" "$ACME_WEBROOT/.well-known/acme-challenge" || return 1
  [[ ! -L "$NGINX_SSL_DIR" ]] || { c_err "证书目录不能为符号链接"; return 1; }
  dir="$(new_workdir)" || return 1
  snapshot_file "$dir" site "$site" && snapshot_file "$dir" cert "$NGINX_SSL_DIR/fullchain.pem" && \
    snapshot_file "$dir" key "$NGINX_SSL_DIR/$DOMAIN.key" || { rm -rf -- "$dir"; return 1; }
  if [[ "$USE_NGINX_LINK" == yes ]]; then snapshot_file "$dir" link "$link" || { rm -rf -- "$dir"; return 1; }; fi
  service_active "$NGINX_UNIT" && was_active=yes
  probe="doh-check-${BASHPID}-${RANDOM}"
  printf '%s' "$probe" > "$ACME_WEBROOT/.well-known/acme-challenge/$probe" || { rm -rf -- "$dir"; return 1; }
  chmod 644 "$ACME_WEBROOT/.well-known/acme-challenge/$probe" || { rm -f -- "$ACME_WEBROOT/.well-known/acme-challenge/$probe"; rm -rf -- "$dir"; return 1; }
  body="$(curl --noproxy '*' -fsS --connect-timeout 3 --max-time 6 --resolve "$DOMAIN:80:127.0.0.1" "http://$DOMAIN/.well-known/acme-challenge/$probe" 2>/dev/null)" || body=""
  if [[ "$body" != "$probe" ]]; then
    changed=yes
    if ! write_nginx_http_only_for_acme; then rc=1; fi
  fi
  rm -f -- "$ACME_WEBROOT/.well-known/acme-challenge/$probe"
  if (( rc == 0 )); then
    c_info "开始签发证书"
    # Always select the CA explicitly; do not alter other acme.sh users' defaults.
    if "$acme" --issue --server letsencrypt -d "$DOMAIN" --webroot "$ACME_WEBROOT" --keylength 2048; then
      issue_rc=0
    else issue_rc=$?; fi
    if (( issue_rc != 0 && issue_rc != 2 )); then
      c_err "证书申请失败（返回码 $issue_rc），不会继续安装证书"; rc=1
    elif ! "$acme" --install-cert --server letsencrypt -d "$DOMAIN" \
      --key-file "$NGINX_SSL_DIR/$DOMAIN.key" --fullchain-file "$NGINX_SSL_DIR/fullchain.pem" \
      --reloadcmd "nginx -t && systemctl reload $NGINX_UNIT"; then
      rc=1
    elif ! cert_valid; then
      c_err "申请结果未通过有效期/域名/私钥检查"; rc=1
    fi
  fi
  if (( rc != 0 )); then
    restore_file "$dir" cert "$NGINX_SSL_DIR/fullchain.pem" && restore_file "$dir" key "$NGINX_SSL_DIR/$DOMAIN.key" || { c_err "证书恢复失败，备份: $dir"; return 1; }
  else
    chmod 600 "$NGINX_SSL_DIR/$DOMAIN.key" || rc=1
  fi
  # Restore an existing HTTPS site even when issuance failed; do not leave it HTTP-only.
  if [[ "$changed" == yes ]] && { [[ -f "$dir/site.exists" ]] || (( rc != 0 )); }; then
    restore_file "$dir" site "$site" || { c_err "站点恢复失败，备份: $dir"; return 1; }
    if [[ "$USE_NGINX_LINK" == yes ]]; then restore_file "$dir" link "$link" || { c_err "站点链接恢复失败，备份: $dir"; return 1; }; fi
    if [[ "$was_active" == yes ]]; then
      nginx_reload_or_start || { c_err "恢复原站点后 Nginx 校验或重载失败，备份: $dir"; return 1; }
    elif (( rc != 0 )); then
      systemctl stop "$NGINX_UNIT" || { c_err "Nginx 状态恢复失败"; return 1; }
    fi
  fi
  rm -rf -- "$dir"
  (( rc == 0 )) || { c_err "证书签发/安装未完成；请检查域名 A/AAAA、80端口、CAA、系统时间及 ACME 输出"; return 1; }
  c_ok "证书签发完成: $NGINX_SSL_DIR"
  log_action "issue cert for $DOMAIN"
}
renew_cert() {
  local acme dir rc=0
  DOMAIN="$(normalize_hostname "$DOMAIN")" || return 1
  NGINX_SSL_DIR="/etc/nginx/ssl/$DOMAIN"
  acme="$(acme_sh_path)"
  [[ -x "$acme" ]] || { c_err "acme.sh 不存在，请先签发证书"; return 1; }
  dir="$(new_workdir)" || return 1
  snapshot_file "$dir" cert "$NGINX_SSL_DIR/fullchain.pem" && snapshot_file "$dir" key "$NGINX_SSL_DIR/$DOMAIN.key" || { rm -rf -- "$dir"; return 1; }
  c_info "强制续期证书"
  c_warn "强制续期会消耗 CA 配额；重复测试请避免频繁操作。"
  if ! "$acme" --renew -d "$DOMAIN" --force; then
    rc=1
  elif ! cert_valid; then
    c_err "续期后部署证书未通过检查"; rc=1
  elif ! nginx_reload_or_start; then
    rc=1
  fi
  if (( rc != 0 )); then
    restore_file "$dir" cert "$NGINX_SSL_DIR/fullchain.pem" && restore_file "$dir" key "$NGINX_SSL_DIR/$DOMAIN.key" || { c_err "恢复失败，备份: $dir"; return 1; }
    if service_active "$NGINX_UNIT"; then nginx -t && systemctl reload "$NGINX_UNIT" || c_err "原证书恢复后重载仍失败"; fi
    rm -rf -- "$dir"; c_err "续期没有成功完成，已恢复原部署证书"; return 1
  fi
  rm -rf -- "$dir"
  c_ok "续期完成"
  log_action "renew cert for $DOMAIN"
}
check_cert_days() {
  local pem="$NGINX_SSL_DIR/fullchain.pem" end_date begin_date end_ts begin_ts now_ts remaining subject sans
  have_cmd openssl || { c_err "未安装 openssl"; return 1; }
  [[ -s "$pem" ]] || { c_err "找不到证书或证书为空: $pem"; return 1; }
  end_date="$(openssl x509 -in "$pem" -noout -enddate)" && begin_date="$(openssl x509 -in "$pem" -noout -startdate)" && \
    subject="$(openssl x509 -in "$pem" -noout -subject)" || { c_err "证书格式损坏，无法读取"; return 1; }
  end_date="${end_date#*=}"; begin_date="${begin_date#*=}"; subject="${subject#subject=}"
  end_ts="$(LC_ALL=C date -d "$end_date" +%s)" && begin_ts="$(LC_ALL=C date -d "$begin_date" +%s)" && now_ts="$(date +%s)" || return 1
  sans="$(openssl x509 -in "$pem" -noout -text | awk '/X509v3 Subject Alternative Name:/ {inside=1; next} inside && /X509v3|Signature Algorithm:/ {inside=0} inside {print}')" || return 1
  echo "==================== 证书有效期检查 ===================="
  echo "证书路径: $pem"
  echo "证书主题: $subject"
  echo "证书域名: $(trim_text "$sans")"
  echo "生效时间: $begin_date"
  echo "到期时间: $end_date"
  if (( now_ts < begin_ts )); then
    c_err "证书尚未生效，请检查系统时间"; return 1
  elif (( now_ts >= end_ts )); then
    c_err "证书已经过期"
    c_warn "已过期 $(((now_ts-end_ts)/86400)) 天 $((((now_ts-end_ts)%86400)/3600)) 小时"
    return 1
  fi
  remaining=$((end_ts-now_ts))
  c_ok "证书仍在有效期内"
  c_info "距离过期还有 $((remaining/86400)) 天 $(((remaining%86400)/3600)) 小时"
  if ! cert_valid; then c_err "但当前 DOMAIN 或私钥与证书不匹配；不要直接应用"; return 1; fi
  (( remaining >= 7*86400 )) || c_warn "证书不足 7 天到期，请检查自动续期任务"
  return 0
}
reload_services() {
  local svc
  c_info "重载服务: ${UNBOUND_UNIT} / ${MOSDNS_UNIT} / ${NGINX_UNIT}"
  for svc in "$UNBOUND_UNIT" "$MOSDNS_UNIT"; do
    if ! service_exists "$svc" || ! systemctl restart "$svc" || ! wait_service "$svc"; then service_error "$svc"; return 1; fi
  done
  if ! nginx_reload_or_start; then service_error "$NGINX_UNIT"; return 1; fi
  c_ok "服务重载完成"
  log_action "reload services"
}
start_services() {
  local svc
  c_info "启动服务: ${UNBOUND_UNIT} / ${MOSDNS_UNIT} / ${NGINX_UNIT}"
  check_domain_cert_before_apply || return 1
  for svc in "$UNBOUND_UNIT" "$MOSDNS_UNIT" "$NGINX_UNIT"; do
    if ! service_exists "$svc" || ! systemctl start "$svc" || ! wait_service "$svc"; then service_error "$svc"; return 1; fi
  done
  c_ok "启动完成"
  log_action "start services"
}
stop_services() {
  local svc failed=0 confirm
  c_info "停止服务: ${MOSDNS_UNIT} / ${UNBOUND_UNIT} / ${NGINX_UNIT}"
  c_warn "此操作会停止这三个系统服务；同机共用 Nginx/Unbound 的站点或解析也会中断。"
  read -r -p "请输入 YES 确认停止: " confirm || return 0
  [[ "$confirm" == YES ]] || { c_warn "已取消"; return 0; }
  for svc in "$MOSDNS_UNIT" "$UNBOUND_UNIT" "$NGINX_UNIT"; do
    if ! service_exists "$svc"; then c_warn "$svc 服务不存在"; continue; fi
    if ! systemctl stop "$svc" || service_active "$svc"; then service_error "$svc"; failed=1; fi
  done
  if mosdns_process_exists; then c_err "仍有非 systemd 管理的 mosdns 进程，未擅自终止它"; failed=1; fi
  (( failed == 0 )) || return 1
  c_ok "停止完成"
  log_action "stop services"
}
restart_services() {
  local svc confirm
  c_info "重启服务: ${UNBOUND_UNIT} / ${MOSDNS_UNIT} / ${NGINX_UNIT}"
  c_warn "重启会短暂中断 DoH，并影响同机共用的 Nginx/Unbound。"
  read -r -p "请输入 YES 确认重启: " confirm || return 0
  [[ "$confirm" == YES ]] || { c_warn "已取消"; return 0; }
  check_domain_cert_before_apply && nginx -t && unbound-checkconf || return 1
  for svc in "$UNBOUND_UNIT" "$MOSDNS_UNIT" "$NGINX_UNIT"; do
    if ! service_exists "$svc" || ! systemctl restart "$svc" || ! wait_service "$svc"; then service_error "$svc"; return 1; fi
  done
  c_ok "重启完成"
  log_action "restart services"
}
apply_all() {
  local dir svc idx rc=0
  local -a paths=("$UNBOUND_SNIPPET" /etc/unbound/unbound.conf "$CONF_DIR/config.yaml" "$NGINX_SITE_DIR/doh_${DOMAIN}.conf")
  local -a was_running=() services=("$UNBOUND_UNIT" "$MOSDNS_UNIT" "$NGINX_UNIT")
  validate_runtime_values && doh_path_conflict_check && check_domain_cert_before_apply || return 1
  [[ -x /usr/local/bin/mosdns ]] && service_exists "$MOSDNS_UNIT" || { c_err "mosdns 或服务定义缺失，请先安装/修复环境"; return 1; }
  [[ -f "$ALLOWLIST_FILE" ]] && (( $(allowlist_count) > 0 )) || { c_err "allowlist.txt 为空，已阻止应用"; return 1; }
  if [[ "$USE_NGINX_LINK" == yes ]]; then paths+=("$NGINX_LINK_DIR/doh_${DOMAIN}.conf"); fi
  dir="$(new_workdir)" || return 1
  for idx in "${!paths[@]}"; do
    snapshot_file "$dir" "file$idx" "${paths[$idx]}" || { rm -rf -- "$dir"; return 1; }
  done
  for svc in "${services[@]}"; do
    if service_active "$svc"; then was_running+=(yes); else was_running+=(no); fi
  done
  c_info "生成配置并应用..."
  if ! write_unbound_forward || ! write_mosdns_config || ! write_nginx_site || ! reload_services; then rc=1; fi
  if (( rc != 0 )); then
    c_err "应用失败，开始恢复应用前的配置和服务状态"
    for idx in "${!paths[@]}"; do
      restore_file "$dir" "file$idx" "${paths[$idx]}" || { c_err "恢复文件失败，保留备份: $dir"; return 1; }
    done
    for idx in "${!services[@]}"; do
      svc="${services[$idx]}"
      if [[ "${was_running[$idx]}" == yes ]]; then
        if [[ "$svc" == "$NGINX_UNIT" ]]; then
          nginx_reload_or_start || { service_error "$svc"; c_err "保留备份: $dir"; return 1; }
        else
          systemctl restart "$svc" && wait_service "$svc" || { service_error "$svc"; c_err "保留备份: $dir"; return 1; }
        fi
      else
        systemctl stop "$svc" || { c_err "$svc 未能恢复停止状态，保留备份: $dir"; return 1; }
      fi
    done
    rm -rf -- "$dir"
    c_err "未应用新配置；已恢复旧运行配置，编辑中的参数仍保存在状态文件中。"
    return 1
  fi
  rm -rf -- "$dir"
  c_ok "本机应用完成"
  log_action "apply all done"
}
service_status_summary() {
  local failed=0 svc sub
  echo "==================== 服务状态检查 ===================="
  for svc in "$MOSDNS_UNIT" "$UNBOUND_UNIT" "$NGINX_UNIT"; do
    if service_exists "$svc"; then
      sub="$(systemctl show -p SubState "$svc" 2>/dev/null)" || sub=""
      if service_active "$svc" && [[ "$sub" == SubState=running ]]; then
        c_ok "$svc 正在正常运行中（进程状态）"
      else
        failed=1
        service_error "$svc"
      fi
    elif [[ "$svc" == "$MOSDNS_UNIT" ]] && mosdns_process_exists; then
      c_warn "$MOSDNS_UNIT 没有 systemd unit，但检测到进程；无法据此确认解析服务正常"
      pgrep -ax mosdns || pgrep -ax mosdns-x || true
      failed=1
    else
      c_err "$svc 的 systemd unit 未找到"
      failed=1
    fi
  done
  if (( failed == 0 )); then
    c_ok "结论：全部服务进程正在运行；实际 DNS 查询结果请看健康检查"
  else
    c_warn "结论：存在异常或无法确认的服务，请查看上面的状态与原始错误日志"
  fi
  return "$failed"
}
show_ports_summary() {
  local failed=0 tcp udp p rows expected
  echo "==================== 端口监听检查 ===================="
  have_cmd ss || { c_err "未安装 ss，无法检查监听端口"; return 1; }
  tcp="$(ss -H -lntp)" && udp="$(ss -H -lnup)" || { c_err "无法读取端口监听信息"; return 1; }
  for p in 80 443 8053 "$UNBOUND_PORT"; do
    case "$p" in 80|443) expected=nginx ;; 8053) expected=mosdns ;; *) expected=unbound ;; esac
    rows="$(printf '%s\n' "$tcp" | awk -v port="$p" '$4 ~ (":" port "$")')"
    if [[ -z "$rows" ]]; then
      c_err "TCP 端口 $p 未监听"; failed=1
    elif [[ "$rows" != *"\"$expected"* ]]; then
      c_err "TCP 端口 $p 已被监听，但未确认由 $expected 持有"; printf '%s\n' "$rows"; failed=1
    elif [[ "$p" == 8053 || "$p" == "$UNBOUND_PORT" ]]; then
      if printf '%s\n' "$rows" | awk '$4 !~ /^(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]):/ {bad=1} END {exit !bad}'; then
        c_err "端口 $p 存在非回环监听，可能绕过 DoH 白名单入口"; failed=1
      else c_ok "端口 $p 正在本机监听（$expected）"; fi
    else
      if printf '%s\n' "$rows" | awk '$4 !~ /^(127\.|\[::1\])/ {found=1} END {exit !found}'; then
        c_ok "端口 $p 正在监听（$expected）"
      else c_err "端口 $p 仅绑定回环，公网无法直接访问"; failed=1; fi
    fi
  done
  rows="$(printf '%s\n' "$udp" | awk -v port="$UNBOUND_PORT" '$4 ~ (":" port "$")')"
  if [[ -z "$rows" || "$rows" != *'"unbound'* ]]; then
    c_err "本机 Unbound UDP/$UNBOUND_PORT 未由 unbound 监听"; failed=1
  elif printf '%s\n' "$rows" | awk '$4 !~ /^(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]):/ {bad=1} END {exit !bad}'; then
    c_err "UDP/$UNBOUND_PORT 存在非回环监听"; failed=1
  else c_ok "UDP/$UNBOUND_PORT 正在本机监听"; fi
  if (( failed == 0 )); then c_ok "结论：端口监听一切正常（不代表公网防火墙已放行）"
  else c_warn "结论：存在监听异常，请检查对应服务和端口占用"; fi
  printf '%s\n' "$tcp" "$udp" | awk -v port="$UNBOUND_PORT" '$4 ~ (":(80|443|8053|" port ")$")'
  return "$failed"
}
health_check_summary() {
  local dir homepage_code doh_code domain failed=0 content_type
  echo "==================== 健康检查 ===================="
  have_cmd curl && have_cmd python3 || { c_err "缺少 curl/python3，请先执行安装/修复环境"; return 1; }
  normalize_hostname "$DOMAIN" >/dev/null && valid_doh_path "$DOH_PATH" || { c_err "域名或路径无效"; return 1; }
  [[ "$DOMAIN" != example.com ]] || { c_err "当前仍是默认示例域名，不能据此检查你的服务"; return 1; }
  dir="$(new_workdir)" || return 1
  if ! normalize_allowlist_file "$ALLOWLIST_FILE" "$dir/list" || [[ ! -s "$dir/list" ]]; then
    c_err "白名单为空或无效，没有可用于健康检查的域名"; rm -rf -- "$dir"; return 1
  fi
  IFS= read -r domain < "$dir/list" || { rm -rf -- "$dir"; return 1; }
  if homepage_code="$(curl --noproxy '*' -sS --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' "https://$DOMAIN/" 2> "$dir/home.err")" && \
    [[ "$homepage_code" =~ ^(200|301|302|404)$ ]]; then
    c_ok "伪装页访问正常，HTTP_CODE=$homepage_code（已验证 HTTPS 证书）"
  else
    c_err "伪装页访问异常，HTTP_CODE=${homepage_code:-000}"
    cat "$dir/home.err" >&2; failed=1
  fi
  if ! python3 - "$domain" "$dir/query" <<'PY'
import struct, sys
name = sys.argv[1].rstrip('.')
try:
    labels = name.encode('ascii').split(b'.')
    if any(not label or len(label) > 63 for label in labels):
        raise ValueError('invalid DNS labels')
    question = b''.join(bytes([len(label)]) + label for label in labels) + b'\0' + struct.pack('!HH', 1, 1)
    with open(sys.argv[2], 'wb') as stream:
        stream.write(struct.pack('!HHHHHH', 0, 0x0100, 1, 0, 0, 0) + question)
except Exception as exc:
    print('无法构造 DNS 查询: {}'.format(exc), file=sys.stderr)
    sys.exit(1)
PY
  then rm -rf -- "$dir"; return 1; fi
  if doh_code="$(curl --noproxy '*' -sS --connect-timeout 5 --max-time 20 \
    -H 'Content-Type: application/dns-message' -H 'Accept: application/dns-message' \
    --data-binary "@$dir/query" -D "$dir/headers" -o "$dir/answer" -w '%{http_code}' \
    "https://$DOMAIN$DOH_PATH" 2> "$dir/doh.err")" && [[ "$doh_code" == 200 ]]; then
    content_type="$(awk 'tolower($1)=="content-type:" {$1=""; print tolower($0)}' "$dir/headers" | tr -d '\r')"
    if [[ "$content_type" != *application/dns-message* ]]; then
      c_err "HTTP 200 但返回的不是 DNS 报文，不能判定 DoH 正常"; failed=1
    elif python3 - "$dir/query" "$dir/answer" <<'PY'
import struct, sys

def read_name(data, offset):
    labels, seen, end = [], set(), None
    while True:
        if offset >= len(data) or offset in seen:
            raise ValueError('invalid DNS name/pointer')
        seen.add(offset)
        length = data[offset]
        if length & 0xc0 == 0xc0:
            if offset + 1 >= len(data):
                raise ValueError('truncated DNS pointer')
            if end is None:
                end = offset + 2
            offset = ((length & 0x3f) << 8) | data[offset + 1]
            continue
        if length & 0xc0 or length > 63:
            raise ValueError('invalid DNS label length')
        offset += 1
        if length == 0:
            return b'.'.join(labels).lower(), end if end is not None else offset
        if offset + length > len(data):
            raise ValueError('truncated DNS label')
        labels.append(data[offset:offset + length])
        offset += length
        if len(seen) > 255:
            raise ValueError('DNS name too long')
try:
    query = open(sys.argv[1], 'rb').read()
    data = open(sys.argv[2], 'rb').read()
    if not 12 <= len(data) <= 65535:
        raise ValueError('not a complete DNS message')
    ident, flags, qd, an, ns, ar = struct.unpack('!HHHHHH', data[:12])
    if ident != struct.unpack('!H', query[:2])[0] or not (flags & 0x8000) or flags & 0x7800 or qd != 1:
        raise ValueError('DNS response ID/header mismatch')
    qname, qend = read_name(query, 12)
    name, offset = read_name(data, 12)
    if name != qname or data[offset:offset+4] != query[qend:qend+4]:
        raise ValueError('DNS question mismatch')
    offset += 4
    address_answers = 0
    for index in range(an + ns + ar):
        owner, offset = read_name(data, offset)
        if offset + 10 > len(data):
            raise ValueError('truncated resource record')
        rtype, rclass, ttl, length = struct.unpack('!HHIH', data[offset:offset+10])
        offset += 10
        if offset + length > len(data):
            raise ValueError('truncated record data')
        if index < an and rtype == 1 and rclass == 1 and length == 4:
            address_answers += 1
        offset += length
    if offset != len(data) or flags & 0x0200:
        raise ValueError('truncated DNS response or trailing data')
    rcode = flags & 15
    if rcode != 0:
        raise ValueError('DNS RCODE={} (3=NXDOMAIN, 2=SERVFAIL, 5=REFUSED)'.format(rcode))
    if not address_answers:
        raise ValueError('NOERROR but no A record; protocol responded, target address not verified')
    print('[OK] DoH 查询成功: {}，A记录 {} 条'.format(name.decode('ascii'), address_answers))
except Exception as exc:
    print('[-] DNS 检查未通过: {}'.format(exc), file=sys.stderr)
    sys.exit(1)
PY
    then
      c_ok "DoH 路径访问正常，HTTP_CODE=$doh_code"
    else
      failed=1
    fi
  else
    c_err "DoH 路径访问异常，HTTP_CODE=${doh_code:-000}"
    cat "$dir/doh.err" >&2; failed=1
  fi
  rm -rf -- "$dir"
  if (( failed == 0 )); then
    c_ok "结论：本次健康检查正常（HTTPS 与所测域名 DNS 响应）；不等于所有域名和网络均已验证"
  else
    c_warn "结论：健康检查存在异常，请检查上面的证书、网络或 DNS 具体错误"
  fi
  return "$failed"
}
uninstall_all() {
  local dir idx confirm svc acme main_conf=/etc/unbound/unbound.conf rc=0 mos_running=no mos_enabled=no
  local -a paths=("$UNBOUND_SNIPPET" "$main_conf" "$NGINX_SITE_DIR/doh_${DOMAIN}.conf")
  local -a was_running=() services=("$UNBOUND_UNIT" "$NGINX_UNIT")
  validate_runtime_values || return 1
  [[ ! -L "$CONF_DIR" && ! -L "$WORK_DIR" && ! -L "$NGINX_SSL_DIR" ]] || { c_err "部署目录为符号链接，已阻止自动卸载"; return 1; }
  c_warn "你即将执行【彻底卸载】"
  echo "将删除以下内容："
  echo " - mosdns 服务"
  echo " - ${CONF_DIR}"
  echo " - ${WORK_DIR}"
  echo " - ${UNBOUND_SNIPPET}"
  echo " - ${NGINX_SITE_DIR}/doh_${DOMAIN}.conf"
  if [[ "$USE_NGINX_LINK" == yes ]]; then echo " - ${NGINX_LINK_DIR}/doh_${DOMAIN}.conf"; paths+=("$NGINX_LINK_DIR/doh_${DOMAIN}.conf"); fi
  echo " - ${NGINX_SSL_DIR}"
  echo " - /usr/local/bin/mosdns"
  if [[ "$ALLOWLIST_FILE" != "$CONF_DIR/"* ]]; then echo " - ${ALLOWLIST_FILE}"; fi
  c_warn "仅清理当前部署；保留共享的 nginx/unbound 软件包、acme.sh、其他站点、静态目录和管理日志。"
  echo
  read -r -p "请输入 YES 确认彻底卸载: " confirm || return 0
  [[ "$confirm" == YES ]] || { c_warn "已取消卸载"; return 0; }
  if ! service_exists "$MOSDNS_UNIT" && mosdns_process_exists; then
    c_err "存在非 systemd 管理的 mosdns 进程；请先由原启动方式停止，防止删除后仍在运行"; return 1
  fi
  dir="$(new_workdir)" || return 1
  for idx in "${!paths[@]}"; do snapshot_file "$dir" "file$idx" "${paths[$idx]}" || { rm -rf -- "$dir"; return 1; }; done
  for svc in "${services[@]}"; do if service_active "$svc"; then was_running+=(yes); else was_running+=(no); fi; done
  service_active "$MOSDNS_UNIT" && mos_running=yes
  if systemctl is-enabled --quiet "$MOSDNS_UNIT" 2>/dev/null; then mos_enabled=yes; fi
  log_action "begin uninstall all"
  if [[ -f "$main_conf" ]]; then
    if ! awk '/^# BEGIN DOH-MANAGER-INCLUDE$/ {block=1;next} /^# END DOH-MANAGER-INCLUDE$/ {block=0;next} !block {print}' "$main_conf" > "$dir/unbound-main" || \
      ! atomic_copy "$dir/unbound-main" "$main_conf" 0644; then rm -rf -- "$dir"; return 1; fi
  fi
  rm -f -- "$UNBOUND_SNIPPET" "$NGINX_SITE_DIR/doh_${DOMAIN}.conf" || rc=1
  if [[ "$USE_NGINX_LINK" == yes ]]; then rm -f -- "$NGINX_LINK_DIR/doh_${DOMAIN}.conf" || rc=1; fi
  if have_cmd nginx; then nginx -t || rc=1; fi
  if have_cmd unbound-checkconf; then unbound-checkconf || rc=1; fi
  if (( rc == 0 )); then
    if [[ "${was_running[0]}" == yes ]]; then systemctl restart "$UNBOUND_UNIT" && wait_service "$UNBOUND_UNIT" || rc=1; fi
    if [[ "${was_running[1]}" == yes ]]; then nginx_reload_or_start || rc=1; fi
  fi
  if (( rc == 0 )) && service_exists "$MOSDNS_UNIT"; then
    if ! systemctl stop "$MOSDNS_UNIT" || ! systemctl disable "$MOSDNS_UNIT"; then
      c_err "mosdns 未能停用，取消删除程序和配置"; rc=1
    fi
  fi
  if (( rc == 0 )) && mosdns_process_exists; then
    c_err "mosdns 进程仍存在，取消删除其文件"; rc=1
  fi
  acme="$(acme_sh_path)"
  if (( rc == 0 )) && [[ -x "$acme" && -d "/root/.acme.sh/$DOMAIN" ]]; then
    if ! "$acme" --remove -d "$DOMAIN"; then
      c_err "无法撤销当前域名的自动续期，取消删除证书"; rc=1
    fi
  fi
  if (( rc != 0 )); then
    for idx in "${!paths[@]}"; do
      restore_file "$dir" "file$idx" "${paths[$idx]}" || { c_err "恢复失败，备份: $dir"; return 1; }
    done
    if [[ "${was_running[0]}" == yes ]]; then systemctl restart "$UNBOUND_UNIT" && wait_service "$UNBOUND_UNIT" || c_err "原 Unbound 状态未能恢复"; fi
    if [[ "${was_running[1]}" == yes ]]; then nginx_reload_or_start || c_err "原 Nginx 状态未能恢复"; fi
    if [[ "$mos_enabled" == yes ]]; then systemctl enable "$MOSDNS_UNIT" || c_err "mosdns 开机启动状态恢复失败"; fi
    if [[ "$mos_running" == yes ]]; then systemctl start "$MOSDNS_UNIT" && wait_service "$MOSDNS_UNIT" || c_err "mosdns 运行状态恢复失败"; fi
    c_err "卸载未完成，已尝试恢复原配置与运行状态；原始备份: $dir"
    return 1
  fi
  remove_if_exists "/etc/systemd/system/${MOSDNS_UNIT}.service" || return 1
  systemctl daemon-reload || return 1
  if [[ "$ALLOWLIST_FILE" != "$CONF_DIR/"* ]]; then remove_if_exists "$ALLOWLIST_FILE" || return 1; fi
  remove_if_exists "$CONF_DIR" && remove_if_exists "$WORK_DIR" && remove_if_exists "$NGINX_SSL_DIR" && remove_if_exists /usr/local/bin/mosdns || return 1
  rm -rf -- "$dir"
  c_ok "当前 DoH 部署卸载完成；共享组件和管理日志保留"
  log_action "uninstall all done"
  # Exit immediately; do not recreate a just-deleted state/allowlist on the next menu.
  exit 0
}
show_menu() {
  cat <<EOF2
==================== ${SCRIPT_NAME} ${SCRIPT_VERSION} ====================

 1. 安装/修复环境            2. 快速初始化向导
 3. 显示当前配置            4. 修改 DOMAIN
 5. 修改 DOH_PATH           6. 修改 allowlist 路径

 7. 查看 allowlist          8. 新增 allowlist 项
 9. 删除 allowlist 项       10. 批量导入 allowlist
11. 编辑 allowlist(vim)     12. allowlist 去重排序

13. 查看上游 DoT            14. 新增上游 DoT
15. 删除上游 DoT            16. 路径冲突检测

17. 生成配置并应用          18. 签发证书
19. 强制续期证书            20. 查看证书有效期

21. 查看服务状态            22. 查看端口监听
23. 健康检查                24. 日志设置
25. 启动服务                26. 停止服务
27. 重启服务                28. 彻底卸载

99. 退出

=========================================================================
EOF2
}

# ==========================================================
# 内部校验与失败恢复（不增加菜单）
# ==========================================================
trim_text() {
  local text="${1//$'\r'/}"
  text="${text#${text%%[![:space:]]*}}"
  text="${text%${text##*[![:space:]]}}"
  printf '%s' "$text"
}

valid_domain() {
  local value="$1" label
  local -a labels=()
  [[ ${#value} -le 253 && "$value" == *.* && "$value" != *..* ]] || return 1
  [[ "$value" =~ ^[A-Za-z0-9_.-]+$ && "$value" != *. ]] || return 1
  [[ ! "$value" =~ ^[0-9.]+$ ]] || return 1
  IFS='.' read -r -a labels <<< "$value"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || return 1
  done
}

normalize_hostname() {
  local value
  value="$(trim_text "$1")" || return 1
  value="${value%.}"
  value="${value,,}"
  valid_domain "$value" || return 1
  [[ "$value" != *_* ]] || return 1
  printf '%s\n' "$value"
}

valid_doh_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._~/-]+$ && "$1" != / && "$1" != *//* ]] || return 1
  [[ "/${1#/}/" != */../* && "/${1#/}/" != */./* ]] || return 1
  [[ "$1" != /.well-known/acme-challenge && "$1" != /.well-known/acme-challenge/* ]]
}

valid_allowlist_path() {
  local value="$1" real
  [[ "$value" == /* && "$value" == *.txt && "$value" != *//* ]] || return 1
  [[ "$value" =~ ^/[A-Za-z0-9_./[:space:]:@+-]+$ && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  [[ "/${value#/}/" != */../* && "/${value#/}/" != */./* ]] || return 1
  real="$(readlink -m -- "$value")" || return 1
  case "$real" in /proc/*|/sys/*|/dev/*|/boot/*|/etc/passwd|/etc/shadow) return 1 ;; esac
  [[ ! -L "$value" && ! -d "$value" ]]
}

valid_uint() {
  [[ "$1" =~ ^(0|[1-9][0-9]{0,9})$ ]]
}

validate_runtime_values() {
  local value key upstream
  valid_domain "$DOMAIN" && [[ "$DOMAIN" != *_* ]] || { c_err "DOMAIN 格式无效"; return 1; }
  valid_doh_path "$DOH_PATH" || { c_err "DOH_PATH 格式无效或与 ACME 冲突"; return 1; }
  valid_allowlist_path "$ALLOWLIST_FILE" || { c_err "allowlist 文件路径无效、指向目录或符号链接"; return 1; }
  for key in UB_MIN_TTL UB_MAX_TTL UB_SERVE_EXPIRED_TTL UB_SERVE_EXPIRED_REPLY_TTL NGX_RPS NGX_BURST; do
    value="${!key}"
    valid_uint "$value" || { c_err "$key 必须是非负十进制整数"; return 1; }
  done
  (( UB_MIN_TTL <= UB_MAX_TTL && NGX_RPS > 0 )) || { c_err "缓存 TTL 或 Nginx 请求速率无效"; return 1; }
  for key in UB_MSG_CACHE UB_RRSET_CACHE; do
    [[ "${!key}" =~ ^[1-9][0-9]*[kKmMgG]?$ ]] || { c_err "$key 大小格式无效"; return 1; }
  done
  for key in UB_PREFETCH UB_SERVE_EXPIRED UB_DO_IP6 NGX_HTTP2 NGX_LIMIT_REQ; do
    [[ "${!key}" == yes || "${!key}" == no ]] || { c_err "$key 必须是 yes 或 no"; return 1; }
  done
  validate_mos_log_level "$MOS_LOG_LEVEL" || { c_err "日志等级无效: $MOS_LOG_LEVEL"; return 1; }
  [[ "$DENY_MODE" == refused || "$DENY_MODE" == nxdomain ]] || { c_err "拒绝策略无效"; return 1; }
  (( ${#UPSTREAM_DOT[@]} > 0 )) || { c_err "至少保留一个 DoT 上游"; return 1; }
  for upstream in "${UPSTREAM_DOT[@]}"; do
    validate_dot "$upstream" || { c_err "DoT 上游格式无效: $upstream"; return 1; }
  done
}

validate_dot() {
  local value="$1" host port auth part octet
  [[ "$value" != *[[:space:]]* && "$value" != *://* && "$value" != *'"'* && "$value" != *"'"* ]] || return 1
  part="${value%%#*}"; auth=""
  if [[ "$value" == *#* ]]; then
    auth="${value#*#}"
    [[ "$auth" != *#* ]] && normalize_hostname "$auth" >/dev/null || return 1
  fi
  host="${part%%@*}"; port=853
  if [[ "$part" == *@* ]]; then port="${part#*@}"; fi
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port > 0 && 10#$port <= 65535 )) || return 1
  if [[ "$host" == *:* ]]; then
    [[ "$host" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    # unbound-checkconf performs the definitive IPv6 address check.
  elif [[ "$host" =~ ^[0-9.]+$ ]]; then
    [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    local -a octets=()
    IFS=. read -r -a octets <<< "$host"
    for octet in "${octets[@]}"; do
      [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( octet <= 255 )) || return 1
    done
  else
    normalize_hostname "$host" >/dev/null || return 1
  fi
}

state_keys() {
  printf '%s\n' DOMAIN DOH_PATH ALLOWLIST_FILE UB_MSG_CACHE UB_RRSET_CACHE UB_MIN_TTL UB_MAX_TTL \
    UB_PREFETCH UB_SERVE_EXPIRED UB_SERVE_EXPIRED_TTL UB_SERVE_EXPIRED_REPLY_TTL UB_DO_IP6 \
    MOS_LOG_LEVEL DENY_MODE NGX_HTTP2 NGX_LIMIT_REQ NGX_RPS NGX_BURST
}

set_defaults() {
  local key default_key
  while IFS= read -r key; do
    default_key="DEFAULT_${key}"
    printf -v "$key" '%s' "${!default_key}"
  done < <(state_keys)
  UPSTREAM_DOT=("${DEFAULT_UPSTREAM_DOT[@]}")
}

state_value() {
  local value
  value="$(trim_text "$1")" || return 1
  if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  # The state format is data only; never evaluate command substitutions.
  [[ "$value" != *\"* && "$value" != *\'* && "$value" != *'`'* && "$value" != *'$'* && "$value" != *'\'* && "$value" != *';'* ]] || return 1
  printf '%s' "$value"
}

atomic_copy() {
  local src="$1" dest="$2" mode="${3:-0644}" tmp
  [[ ! -L "$dest" && ! -d "$dest" ]] || { c_err "拒绝覆盖符号链接或目录: $dest"; return 1; }
  mkdir -p -- "$(dirname -- "$dest")" || return 1
  tmp="$(mktemp "${dest}.tmp.XXXXXX")" || return 1
  if ! install -m "$mode" -- "$src" "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  if have_cmd restorecon; then restorecon "$dest" >/dev/null 2>&1 || true; fi
}

new_workdir() {
  mktemp -d /tmp/doh-manager-pro.XXXXXXXX
}

snapshot_file() {
  local dir="$1" tag="$2" file="$3"
  if [[ -e "$file" || -L "$file" ]]; then
    cp -a -- "$file" "$dir/$tag" || return 1
    : > "$dir/$tag.exists"
  fi
}

restore_file() {
  local dir="$1" tag="$2" file="$3"
  if [[ -e "$dir/$tag.exists" ]]; then
    # Restore exactly the former file or symlink, never recurse over the parent.
    rm -f -- "$file" || return 1
    cp -a -- "$dir/$tag" "$file" || return 1
  else
    rm -f -- "$file" || return 1
  fi
}

normalize_allowlist_file() {
  local input="$1" output="$2" raw normalized line_no=0 bad=0
  : > "$output" || return 1
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line_no=$((line_no+1))
    if normalized="$(normalize_domain_line "$raw")"; then
      [[ -z "$normalized" ]] || printf '%s\n' "$normalized" >> "$output" || return 1
    else
      c_err "白名单第 $line_no 行格式错误: $raw" >&2
      bad=1
    fi
  done < "$input"
  (( bad == 0 )) || return 1
  LC_ALL=C sort -u -o "$output" "$output"
}

commit_allowlist() {
  local normalized="$1" tmp
  tmp="$(mktemp "${ALLOWLIST_FILE}.tmp.XXXXXX")" || return 1
  if ! { printf '# allowlist.txt (managed by %s)\n# each line: domain or suffix\n' "$SCRIPT_NAME"; cat "$normalized"; } > "$tmp"; then
    rm -f -- "$tmp"; return 1
  fi
  if ! backup_file "$ALLOWLIST_FILE" || ! atomic_copy "$tmp" "$ALLOWLIST_FILE" 0644; then
    rm -f -- "$tmp"; return 1
  fi
  rm -f -- "$tmp"
}

wait_service() {
  local svc="$1" step state
  for step in 1 2 3; do
    sleep 1
    service_active "$svc" || return 1
    state="$(systemctl show -p SubState "$svc" 2>/dev/null)" || return 1
    [[ "$state" == 'SubState=running' ]] || return 1
  done
}

service_error() {
  c_err "$1 操作失败；下面是服务状态和最近日志，不据此猜测唯一根因。"
  systemctl --no-pager --full status "$1" 2>&1 | sed -n '1,14p' || true
  journalctl -u "$1" -n 15 --no-pager 2>&1 || true
}

nginx_reload_or_start() {
  nginx -t || return 1
  if service_active "$NGINX_UNIT"; then
    systemctl reload "$NGINX_UNIT" || return 1
  else
    systemctl start "$NGINX_UNIT" || return 1
  fi
  wait_service "$NGINX_UNIT"
}

verify_nginx_included() {
  local dump
  dump="$(nginx -T 2>&1)" || { printf '%s\n' "$dump" >&2; return 1; }
  [[ "$dump" == *"# configuration file ${NGINX_SITE_DIR}/doh_${DOMAIN}.conf:"* || \
     "$dump" == *"# configuration file ${NGINX_LINK_DIR}/doh_${DOMAIN}.conf:"* ]] || {
    c_err "Nginx 主配置未包含当前 DoH 站点，已阻止应用"; return 1;
  }
}

unbound_includes_target() {
  # Traverse include paths without sourcing/evaluating any configuration text.
  local file="$1" target="$2" depth="${3:-0}" line pattern item
  [[ "$file" == "$target" ]] && return 0
  (( depth < 12 )) && [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*include(-toplevel)?:[[:space:]]*\"([^\"]+)\" ]]; then
      pattern="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^[[:space:]]*include(-toplevel)?:[[:space:]]*([^[:space:]\#]+) ]]; then
      pattern="${BASH_REMATCH[2]}"
    else
      continue
    fi
    [[ "$pattern" == /* ]] || pattern="$(dirname -- "$file")/$pattern"
    while IFS= read -r item; do
      if unbound_includes_target "$item" "$target" "$((depth+1))"; then return 0; fi
    done < <(compgen -G "$pattern" || true)
  done < "$file"
  return 1
}

ca_bundle_path() {
  local file
  for file in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem; do
    if [[ -s "$file" ]]; then printf '%s\n' "$file"; return 0; fi
  done
  c_err "未找到系统 CA 证书包，请执行安装/修复环境" >&2
  return 1
}

render_dot_upstream() {
  local value="$1" part host port auth addresses address
  validate_dot "$value" || return 1
  part="${value%%#*}"; host="${part%%@*}"; port=853; auth=""
  [[ "$part" != *@* ]] || port="${part#*@}"
  [[ "$value" != *#* ]] || auth="${value#*#}"
  if [[ "$host" =~ ^[0-9.]+$ || "$host" == *:* ]]; then
    addresses="$host"
  else
    host="${host,,}"; host="${host%.}"
    [[ -n "$auth" ]] || auth="$host"
    # Root forwarding with forward-host can create a bootstrap dependency.
    addresses="$(timeout 12 getent ahostsv4 "$host" | awk '{print $1}' | LC_ALL=C sort -u)" || {
      c_err "无法获取 DoT 上游 $host 的 IPv4 地址，原配置保持不变" >&2; return 1;
    }
    [[ -n "$addresses" ]] || return 1
  fi
  while IFS= read -r address; do
    if [[ -n "$auth" ]]; then
      printf '  forward-addr: "%s@%s#%s"\n' "$address" "$port" "$auth"
    else
      printf '  forward-addr: "%s@%s"\n' "$address" "$port"
    fi
  done <<< "$addresses"
}

cert_valid() {
  local pem="$NGINX_SSL_DIR/fullchain.pem" key="$NGINX_SSL_DIR/$DOMAIN.key" begin end now pub1 pub2 names name matched=no
  cert_exists_for_domain || return 1
  begin="$(openssl x509 -in "$pem" -noout -startdate 2>/dev/null)" || return 1
  end="$(openssl x509 -in "$pem" -noout -enddate 2>/dev/null)" || return 1
  begin="$(LC_ALL=C date -d "${begin#*=}" +%s)" || return 1
  end="$(LC_ALL=C date -d "${end#*=}" +%s)" || return 1
  now="$(date +%s)" || return 1
  (( now >= begin && now < end )) || return 1
  # Read DNS SAN names on both older and newer OpenSSL versions.
  names="$(openssl x509 -in "$pem" -noout -text | awk '/X509v3 Subject Alternative Name:/ {inside=1; next} inside && /X509v3|Signature Algorithm:/ {inside=0} inside {print}')" || return 1
  names="${names//,/ }"
  for name in $names; do
    [[ "$name" == DNS:* ]] || continue
    name="${name#DNS:}"; name="${name,,}"
    if [[ "$name" == "$DOMAIN" ]]; then matched=yes; fi
    if [[ "$name" == \*.* && "$DOMAIN" == *."${name#*.}" && "${DOMAIN%.${name#*.}}" != *.* ]]; then matched=yes; fi
  done
  [[ "$matched" == yes ]] || return 1
  pub1="$(openssl x509 -in "$pem" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)" || return 1
  pub2="$(openssl pkey -in "$key" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum)" || return 1
  [[ "$pub1" == "$pub2" ]]
}

mos_native_log() {
  case "$MOS_LOG_LEVEL" in
    warning|warn) printf '  level: warn\n' ;;
    none) printf '  level: error\n  file: /dev/null\n' ;;
    debug|info|error) printf '  level: %s\n' "$MOS_LOG_LEVEL" ;;
    *) return 1 ;;
  esac
}

run_action() {
  local result=0
  if "$@"; then return 0; else result=$?; fi
  c_err "本次操作未完成（返回码 $result），请查看上面的错误；未将失败当作成功。"
  return 0
}


main() {
  local opt first_run_wizard
  need_root
  [[ ${BASH_VERSINFO[0]} -ge 4 ]] || { c_err "需要 Bash 4 或更新版本"; return 1; }
  # Check function completeness before creating files or touching services.
  self_check_menu_functions && integrity_check_core_functions || return 1
  detect_platform || return 1
  # Serialize interactive maintenance; release automatically when the shell exits.
  have_cmd flock || { c_err "缺少 flock（util-linux），请先安装系统基础工具"; return 1; }
  [[ ! -L /run/lock/doh-manager-pro.lock ]] || { c_err "锁文件不能为符号链接"; return 1; }
  mkdir -p /run/lock || return 1
  exec 9>/run/lock/doh-manager-pro.lock
  flock -n 9 || { c_err "另一实例正在管理 DoH，请先退出另一窗口中的脚本"; return 1; }
  ensure_state_file && load_state && ensure_allowlist_file || return 1
  show_integrity_summary
  log_action "run doh-manager-pro-allinone.sh"
  show_brief_runtime_status
  if [[ "$FIRST_RUN" == yes ]]; then
    echo
    if read -r -p "检测到首次运行，是否进入快速初始化向导？(y/n): " first_run_wizard; then
      case "$first_run_wizard" in y|Y) run_action quick_setup_wizard ;; *) c_info "已跳过快速初始化向导" ;; esac
    else return 0; fi
  fi
  while true; do
    show_menu
    read -r -p "请选择操作: " opt || { c_info "输入结束，退出"; return 0; }
    echo
    case "$opt" in
      1) run_action ensure_environment ;;
      2) run_action quick_setup_wizard ;;
      3) run_action show_config ;;
      4) run_action set_domain ;;
      5) run_action set_doh_path ;;
      6) run_action set_allowlist_file ;;
      7) run_action show_allowlist ;;
      8) run_action add_allowlist_one ;;
      9) run_action remove_allowlist_one ;;
      10) run_action batch_import_allowlist ;;
      11) run_action edit_allowlist_vim ;;
      12) run_action allowlist_dedupe_sort ;;
      13) run_action list_upstreams ;;
      14) run_action add_upstream ;;
      15) run_action remove_upstream ;;
      16) run_action doh_path_conflict_check ;;
      17) run_action apply_all ;;
      18) run_action issue_cert ;;
      19) run_action renew_cert ;;
      20) run_action check_cert_days ;;
      21) run_action service_status_summary ;;
      22) run_action show_ports_summary ;;
      23) run_action health_check_summary ;;
      24) run_action log_settings_menu ;;
      25) run_action start_services ;;
      26) run_action stop_services ;;
      27) run_action restart_services ;;
      28) run_action uninstall_all ;;
      99) c_ok "退出"; log_action "exit"; return 0 ;;
      *) c_warn "无效选项" ;;
    esac
    pause_enter
  done
}
main "$@"
