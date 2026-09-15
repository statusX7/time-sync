#!/bin/bash
set -u

SERVER_TOOLKIT_VERSION="v2.8"

# ---------- v2.8 reinstall state: all globals have defaults under set -u ----------
REINSTALL_UPSTREAM_URL="https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh"
REINSTALL_UPSTREAM_URL_CN="https://gitee.com/mb9e8j2/Tools/raw/master/Linux_reinstall/InstallNET.sh"
REINSTALL_BASE_DIR="/root/server-toolkit-reinstall"
REINSTALL_ARGS=()
REINSTALL_PLAN_READY=0
REINSTALL_PASSWORD_SET=0
REINSTALL_DISTRO_FLAG=""
REINSTALL_TARGET_KIND=""
REINSTALL_VERSION=""
REINSTALL_LAST_WORKDIR=""
REINSTALL_LAST_RESULT=""
DOWNLOADED_SCRIPT_URL=""


# ============================================================
# server-toolkit.sh v2.8
# 适用：Debian 10/11/12/13/testing/sid、Ubuntu 20.04/22.04/24.04/26.04、
#      CentOS 7/Stream 8/9/10、RHEL 8/9/10、Alma/Rocky/Oracle、
#      Fedora、Amazon Linux 2/2023。
# 原则：先备份、先检测、尽量不破坏当前 SSH 会话；危险操作默认取消并使用数字确认。
# v2.8 摘要：恢复 v2.6 双栏 UI；重装线性向导、单次确认；初始化下载地址；
#            保存真实日志/上游返回码/引导备份；仅验证完成标志+新安装文件后认定“等待重启”。
#            修复菜单 EOF、URL 校验、SSH 别名验证/恢复、APT 混合源保护、F2B 失败码等。
# 注意：重装准备不等于新系统安装完成；本工具不自动 reboot，必须保留救援控制台。
#       后台备份/语法/有效配置校验不是重复交互；不要禁用它们。未覆盖全部发行版实机测试。
# ============================================================

# ---------- 彩色输出 / UI ----------
UI_COLOR_ENABLED=0
UI_EMOJI_ENABLED=1
UI_HR_CHAR="-"
UI_RESET=""
UI_GREEN=""
UI_YELLOW=""
UI_RED=""
UI_CYAN=""
UI_BLUE=""
UI_MAGENTA=""
UI_DIM=""

ui_init() {
  local locale_name="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    UI_COLOR_ENABLED=1
    UI_RESET=$'\033[0m'
    UI_GREEN=$'\033[1;32m'
    UI_YELLOW=$'\033[1;33m'
    UI_RED=$'\033[1;31m'
    UI_CYAN=$'\033[1;36m'
    UI_BLUE=$'\033[1;34m'
    UI_MAGENTA=$'\033[1;35m'
    UI_DIM=$'\033[2m'
  fi
  case "$locale_name" in
    *UTF-8*|*utf8*|*UTF8*) UI_HR_CHAR="─" ;;
    *) UI_EMOJI_ENABLED=0; UI_HR_CHAR="-" ;;
  esac
  case "${SERVER_TOOLKIT_NO_EMOJI:-0}" in 1|yes|true) UI_EMOJI_ENABLED=0 ;; esac
}
ui_init

ui_icon() {
  local kind="${1:-info}"
  if [ "$UI_EMOJI_ENABLED" -eq 0 ]; then
    case "$kind" in success) printf '[OK]' ;; warning) printf '[!]' ;; error) printf '[X]' ;; info) printf '[i]' ;; title) printf '[*]' ;; back) printf '<-' ;; prompt) printf '>' ;; menu) printf '-' ;; *) printf '-' ;; esac
  else
    case "$kind" in success) printf '✅' ;; warning) printf '⚠️' ;; error) printf '❌' ;; info) printf 'ℹ️' ;; title) printf '🧰' ;; back) printf '↩️' ;; prompt) printf '👉' ;; menu) printf '🔹' ;; *) printf '•' ;; esac
  fi
}

ui_symbol() {
  local kind="${1:-menu}"
  [ "$UI_EMOJI_ENABLED" -eq 1 ] || return 0
  case "$kind" in
    time) printf '⏱️' ;; firewall) printf '🛡️' ;; selinux) printf '🔐' ;; ssh) printf '🔒' ;;
    ban) printf '🚫' ;; key) printf '🔑' ;; media) printf '🎬' ;; info) printf '📊' ;;
    benchmark) printf '🧪' ;; reboot) printf '🔄' ;; nezha) printf '📡' ;; world) printf '🌍' ;;
    ipv6) printf '🌐' ;; harden) printf '🧱' ;; package) printf '📦' ;; reinstall) printf '💿' ;;
    exit) printf '🚪' ;; menu) printf '📚' ;; host) printf '🖥️' ;; linux) printf '🐧' ;;
    kernel) printf '🧩' ;; arch) printf '🏗️' ;; cpu) printf '⚙️' ;; cores) printf '🧮' ;;
    load) printf '📈' ;; memory) printf '🧠' ;; disk) printf '🗄️' ;; network) printf '🌐' ;;
    receive) printf '📥' ;; speed) printf '🚀' ;; dns) printf '🔎' ;; uptime) printf '⏱️' ;;
    swap) printf '💾' ;; *) printf '🔹' ;;
  esac
}

ui_terminal_columns() {
  local cols="" tty_size=""
  if command -v stty >/dev/null 2>&1; then
    # stdin may be a different attached PTY than /dev/tty; prefer the actual input terminal.
    if [ -t 0 ]; then tty_size="$(stty size 2>/dev/null <&0)" || tty_size=""; fi
    if [ -z "$tty_size" ]; then tty_size="$(stty size 2>/dev/null </dev/tty)" || tty_size=""; fi
    cols="${tty_size##* }"
  fi
  [[ "$cols" =~ ^[1-9][0-9]{1,3}$ ]] || cols="${COLUMNS:-}"
  if ! [[ "$cols" =~ ^[1-9][0-9]{1,3}$ ]]; then
    cols="$(tput cols 2>/dev/null)" || cols=80
  fi
  [[ "$cols" =~ ^[1-9][0-9]{1,3}$ ]] || cols=80
  [ "$cols" -gt 120 ] && cols=120
  [ "$cols" -lt 20 ] && cols=20
  printf '%s' "$cols"
}

ui_repeat() {
  local char="${1:--}" count="${2:-60}" out=""
  [[ "$count" =~ ^[0-9]+$ ]] || count=60
  while [ "${#out}" -lt "$count" ]; do out="${out}${char}"; done
  printf '%s' "${out:0:count}"
}

ui_hr() {
  local cols
  cols="$(ui_terminal_columns)"
  printf '%s' "$UI_CYAN"
  ui_repeat "$UI_HR_CHAR" "$cols"
  printf '%s\n' "$UI_RESET"
}

ui_clear() {
  if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then printf '\033[2J\033[H'; fi
}

ui_message() {
  local color="${1:-}" kind="${2:-info}" msg="${3:-}"
  printf '%s' "$color"
  ui_icon "$kind"
  printf '  %s%s\n' "$msg" "$UI_RESET"
}

echo_color() { ui_message "$UI_GREEN" success "${1:-}"; }
echo_warn()  { ui_message "$UI_YELLOW" warning "${1:-}"; }
echo_error() { ui_message "$UI_RED" error "${1:-}"; }
echo_info()  { ui_message "$UI_CYAN" info "${1:-}"; }
echo_blue()  { ui_message "$UI_BLUE" info "${1:-}"; }
echo_pink()  { ui_message "$UI_MAGENTA" info "${1:-}"; }
echo_dim()   { printf '%s  • %s%s\n' "$UI_DIM" "${1:-}" "$UI_RESET"; }

ui_title() {
  local title="${1:-server-toolkit}"
  printf '\n'
  ui_hr
  printf '%s  ' "$UI_MAGENTA"
  ui_icon title
  printf '  %s%s\n' "$title" "$UI_RESET"
  ui_hr
}

ui_option() {
  local num="${1:-}" text="${2:-}"
  printf '  %s%2s)%s  ' "$UI_GREEN" "$num" "$UI_RESET"
  ui_icon menu
  printf '  %s\n' "$text"
}

ui_back() {
  printf '  %s%2s)%s  ' "$UI_RED" "0" "$UI_RESET"
  ui_icon back
  printf '  返回\n'
}

ui_prompt() {
  # Use a private namespace: Bash dynamically scopes local variables (no nameref on Bash 4.2).
  local _stk_ui_target="${1:-}" _stk_ui_prompt="${2:-请选择}" _stk_ui_input=""
  [[ "$_stk_ui_target" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
  if ! read -r -p "$(ui_icon prompt)  ${_stk_ui_prompt}: " _stk_ui_input; then
    printf -v "$_stk_ui_target" '%s' '0'
    return 1
  fi
  printf -v "$_stk_ui_target" '%s' "$_stk_ui_input"
}

pause_return() {
  local _pause_dummy=""
  printf '\n'
  read -r -p "$(ui_icon back)  按 Enter 返回菜单..." _pause_dummy || return 0
}

ui_kv() {
  local symbol_kind="${1:-menu}" label="${2:-}" value="${3:-}" symbol=""
  symbol="$(ui_symbol "$symbol_kind")"
  [ -n "$symbol" ] && label="${symbol}  ${label}"
  if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ "$(ui_terminal_columns)" -ge 64 ]; then
    printf '  %s%s%s' "$UI_CYAN" "$label" "$UI_RESET"
    printf '\033[28G%s\n' "$value"
  else
    printf '  %s: %s\n' "$label" "$value"
  fi
}

ui_main_row() {
  local left="${1:-}" right="${2:-}" cols split
  cols="$(ui_terminal_columns)"
  if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ "$cols" -ge 94 ] && [ -n "$right" ]; then
    split=$((cols / 2 + 1))
    printf '  %s' "$left"
    printf '\033[%sG%s\n' "$split" "$right"
  else
    [ -n "$left" ] && printf '  %s\n' "$left"
    [ -n "$right" ] && printf '  %s\n' "$right"
  fi
}

ui_menu_label() {
  local kind="${1:-menu}" num="${2:-}" text="${3:-}" symbol=""
  symbol="$(ui_symbol "$kind")"
  if [ -n "$symbol" ]; then
    printf '%s  %2s) %s' "$symbol" "$num" "$text"
  else
    printf '%2s) %s' "$num" "$text"
  fi
}
ui_menu_section() {
  local title="${1:-}" kind="${2:-menu}" symbol=""
  [ -n "$title" ] || return 0
  symbol="$(ui_symbol "$kind")"
  printf '\n%s  %s%s%s\n' "$UI_CYAN" "${symbol:+${symbol}  }" "$title" "$UI_RESET"
}

ui_menu_note() {
  printf '%s  · %s%s\n' "$UI_DIM" "${1:-}" "$UI_RESET"
}

ui_action_pause() {
  # 子菜单动作结束后统一停留一次，再重新绘制当前子菜单。
  pause_return
}

confirm_action() {
  # One confirmation per operation. An empty answer/EOF NEVER grants consent.
  local _stk_confirm_answer=""
  echo_warn "${1:-确认继续？}"
  ui_option 1 "继续"
  ui_option 2 "取消（默认）"
  ui_back
  ui_prompt _stk_confirm_answer "请选择 [默认 2]" || return 1
  case "${_stk_confirm_answer:-2}" in
    1) return 0 ;;
    2|0) return 1 ;;
    *) echo_error "无效选项，已取消。"; return 1 ;;
  esac
}

choice_ssh_port_keep_policy() {
  # 不要通过 $(choice_...) 获取结果：该函数会绘制 UI，命令替换会把菜单文字一起捕获。
  # 使用输出变量名保持 Bash 4.2（CentOS 7）兼容，不依赖 nameref。
  local outvar="${1:-}" answer result
  [ -n "$outvar" ] || { echo_error "内部错误：未指定 SSH 端口策略输出变量。"; return 1; }
  ui_option 1 "只保留新端口"
  ui_option 2 "新旧端口都保留（默认，推荐）"
  ui_back
  ui_prompt answer "请选择 [默认 2]" || { printf -v "$outvar" '%s' "cancel"; return 1; }
  answer="${answer:-2}"
  case "$answer" in
    1) result="new_only" ;;
    2) result="keep_both" ;;
    0) result="cancel" ;;
    *) echo_error "无效选项，已取消。"; result="cancel" ;;
  esac
  printf -v "$outvar" '%s' "$result"
  return 0
}

choice_private_key_action() {
  local outvar="${1:-}" answer result
  [ -n "$outvar" ] || { echo_error "内部错误：未指定私钥菜单输出变量。"; return 1; }
  ui_option 1 "显示私钥"
  ui_option 2 "不显示，仅保留服务器路径（默认，推荐）"
  ui_option 3 "删除服务器上的私钥文件（确认本地已保存后再用）"
  ui_back
  ui_prompt answer "请选择 [默认 2]" || { printf -v "$outvar" '%s' "2"; return 1; }
  answer="${answer:-2}"
  case "$answer" in
    1|2|3|0) result="$answer" ;;
    *) echo_error "无效选项，按默认不显示处理。"; result="2" ;;
  esac
  printf -v "$outvar" '%s' "$result"
  return 0
}

# ---------- 基础 / 发行版检测 ----------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo_error "请使用 root 运行此脚本。"
    exit 1
  fi
}

OS_ID="unknown"
OS_ID_LIKE=""
OS_VERSION_ID=""
OS_VERSION_CODENAME=""
OS_PRETTY_NAME="unknown"
OS_MAJOR=""
PKG_MANAGER=""

parse_os_release() {
  OS_ID="unknown"
  OS_ID_LIKE=""
  OS_VERSION_ID=""
  OS_VERSION_CODENAME=""
  OS_PRETTY_NAME="unknown"
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    OS_PRETTY_NAME="${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"
  elif [ -r /etc/redhat-release ]; then
    OS_PRETTY_NAME="$(cat /etc/redhat-release 2>/dev/null || echo unknown)"
    OS_ID="rhel"
    OS_ID_LIKE="rhel fedora"
    OS_VERSION_ID="$(printf '%s\n' "$OS_PRETTY_NAME" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1 || true)"
  elif [ -r /etc/debian_version ]; then
    OS_ID="debian"
    OS_ID_LIKE="debian"
    OS_VERSION_ID="$(cat /etc/debian_version 2>/dev/null || echo unknown)"
    OS_PRETTY_NAME="Debian $OS_VERSION_ID"
  fi
  OS_MAJOR="${OS_VERSION_ID%%.*}"
  [ -n "$OS_MAJOR" ] || OS_MAJOR="0"
}

os_like_contains() {
  local needle="${1:-}"
  case " $OS_ID $OS_ID_LIKE " in
    *" $needle "*) return 0 ;;
    *) return 1 ;;
  esac
}

is_debian_like() {
  parse_os_release
  os_like_contains debian || [ "$OS_ID" = "ubuntu" ] || [ "$OS_ID" = "debian" ]
}

is_redhat_like() {
  parse_os_release
  os_like_contains rhel || os_like_contains fedora || [ "$OS_ID" = "fedora" ] || [ "$OS_ID" = "amzn" ] || [ "$OS_ID" = "amazon" ]
}

is_rhel_subscription_os() {
  parse_os_release
  [ "$OS_ID" = "rhel" ] || [ "$OS_ID" = "redhat" ]
}

show_os_detected() {
  parse_os_release
  echo_info "系统识别：$OS_PRETTY_NAME"
  echo_info "ID=$OS_ID ID_LIKE=${OS_ID_LIKE:-无} VERSION_ID=${OS_VERSION_ID:-无} CODENAME=${OS_VERSION_CODENAME:-无}"
}

is_systemd_available() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

is_container_env() {
  [ -e /.dockerenv ] || [ -e /run/.containerenv ] || [ -e /run/systemd/container ] || {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
      systemd-detect-virt --container >/dev/null 2>&1 && return 0
    fi
    grep -qaE '(docker|lxc|containerd|kubepods|podman)' /proc/1/cgroup 2>/dev/null
    return $?
  }
}

has_cap_sys_time() {
  if command -v capsh >/dev/null 2>&1; then
    capsh --print 2>/dev/null | grep -Eq '(^|[,=[:space:]])cap_sys_time([,+[:space:]]|$)' && return 0
  fi
  [ -r /proc/self/status ] || return 1
  local hex low
  hex="$(awk '/CapEff/ {print $2; exit}' /proc/self/status 2>/dev/null || true)"
  [ -n "$hex" ] || return 1
  low="${hex: -8}"
  [[ "$low" =~ ^[0-9A-Fa-f]{1,8}$ ]] || return 1
  [ $((16#$low & (1<<25))) -ne 0 ]
}

backup_file() {
  local file="${1:-}" dest=""
  [ -n "$file" ] || return 1
  if [ -e "$file" ] || [ -L "$file" ]; then
    dest="$(mktemp "${file}.bak.$(date +%F_%H-%M-%S).XXXXXX")" || return 1
    cp -a -- "$file" "$dest" || { rm -f -- "$dest"; echo_error "备份失败：$file" >&2; return 1; }
  fi
  return 0
}

make_backup_dir() {
  local name="${1:-backup}" base="/root/server-toolkit-backups" dir=""
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
  [ ! -L "$base" ] || { echo_error "备份目录不能是符号链接：$base" >&2; return 1; }
  mkdir -p "$base" && chmod 700 "$base" || return 1
  dir="$(mktemp -d "${base}/${name}-$(date +%F_%H-%M-%S).XXXXXX")" || return 1
  chmod 700 "$dir" || return 1
  printf '%s\n' "$dir"
}

backup_path_to_dir() {
  local src="${1:-}" dir="${2:-}" dest=""
  [[ "$src" == /* && "$dir" == /* && "$src" != / && "$dir" != / ]] || return 1
  case "/$src/$dir/" in *'/../'*|*'/./'*) return 1 ;; esac
  [ -e "$src" ] || [ -L "$src" ] || return 0
  dest="$dir$src"
  [ ! -e "$dest" ] && [ ! -L "$dest" ] || { echo_error "拒绝覆盖已有备份：$dest" >&2; return 1; }
  mkdir -p -- "$(dirname "$dest")" || return 1
  cp -a -- "$src" "$dest" || { echo_error "备份失败：$src" >&2; return 1; }
}

restore_path_from_dir() {
  # Copy into a same-filesystem staging directory BEFORE replacing the live path.
  local src="${1:-}" dir="${2:-}" parent="" tmp="" base=""
  [[ "$src" == /* && "$dir" == /* && "$src" != / && "$dir" != / ]] || return 1
  case "/$src/$dir/" in *'/../'*|*'/./'*) return 1 ;; esac
  [ -e "$dir$src" ] || [ -L "$dir$src" ] || return 1
  parent="$(dirname "$src")"; base="$(basename "$src")"
  mkdir -p -- "$parent" || return 1
  tmp="$(mktemp -d "$parent/.server-toolkit-restore.XXXXXX")" || return 1
  if ! cp -a -- "$dir$src" "$tmp/$base"; then rm -rf -- "$tmp"; return 1; fi
  if [ -e "$src" ] || [ -L "$src" ]; then
    mv -- "$src" "$tmp/previous" || { rm -rf -- "$tmp"; return 1; }
  fi
  if ! mv -- "$tmp/$base" "$src"; then
    if [ -e "$tmp/previous" ] || [ -L "$tmp/previous" ]; then
      mv -- "$tmp/previous" "$src" || echo_error "紧急：恢复失败，当前文件保留在 $tmp/previous" >&2
    fi
    echo_error "回滚未完成；临时副本：$tmp" >&2
    return 1
  fi
  rm -rf -- "$tmp"
}

# ---------- 包管理器抽象 ----------
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    PKG_MANAGER="none"
  fi
  echo "$PKG_MANAGER"
}

pkg_map_name() {
  local name="${1:-}"
  local pm
  pm="$(detect_pkg_manager)"
  case "$pm:$name" in
    apt:openssh-server) echo "openssh-server" ;;
    apt:openssh-client) echo "openssh-client" ;;
    apt:dns-tools) echo "dnsutils" ;;
    apt:cron|apt:cronie) echo "cron" ;;
    apt:semanage) echo "policycoreutils-python-utils" ;;
    apt:python3-systemd) echo "python3-systemd" ;;
    apt:systemd-timesyncd) echo "systemd-timesyncd" ;;
    dnf:openssh-client|yum:openssh-client) echo "openssh-clients" ;;
    dnf:dns-tools|yum:dns-tools) echo "bind-utils" ;;
    dnf:cron|yum:cron|dnf:cronie|yum:cronie) echo "cronie" ;;
    dnf:semanage|yum:semanage)
      parse_os_release
      if [ "${OS_MAJOR:-0}" = "7" ]; then echo "policycoreutils-python"; else echo "policycoreutils-python-utils"; fi
      ;;
    dnf:python3-systemd|yum:python3-systemd) echo "python3-systemd" ;;
    dnf:systemd-timesyncd|yum:systemd-timesyncd) echo "" ;;
    *) echo "$name" ;;
  esac
}

pkg_makecache() {
  local pm
  pm="$(detect_pkg_manager)"
  case "$pm" in
    apt)
      echo_info "正在刷新 APT 缓存..."
      apt_update_with_log
      ;;
    dnf)
      echo_info "正在刷新 DNF 缓存..."
      dnf -y makecache
      ;;
    yum)
      echo_info "正在刷新 YUM 缓存..."
      yum -y makecache
      ;;
    *) echo_error "未检测到支持的包管理器。"; return 1 ;;
  esac
}

pkg_update() { pkg_makecache; }

pkg_install() {
  local pm mapped p
  local pkgs=()
  pm="$(detect_pkg_manager)"
  [ "$pm" = "none" ] && { echo_error "未检测到支持的包管理器。"; return 1; }
  for p in "$@"; do
    mapped="$(pkg_map_name "$p")"
    [ -n "$mapped" ] && pkgs+=("$mapped")
  done
  [ -n "${pkgs[*]-}" ] || { echo_warn "没有可安装的软件包。"; return 0; }
  echo_info "正在安装：${pkgs[*]}"
  case "$pm" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y "${pkgs[@]+"${pkgs[@]}"}" ;;
    dnf) dnf install -y "${pkgs[@]+"${pkgs[@]}"}" ;;
    yum) yum install -y "${pkgs[@]+"${pkgs[@]}"}" ;;
  esac
}

pkg_upgrade() {
  local pm
  pm="$(detect_pkg_manager)"
  case "$pm" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y ;;
    dnf) dnf upgrade -y ;;
    yum) yum update -y ;;
    *) echo_error "未检测到支持的包管理器。"; return 1 ;;
  esac
}

pkg_upgrade_packages() {
  local pm mapped p
  local pkgs=()
  pm="$(detect_pkg_manager)"
  for p in "$@"; do
    mapped="$(pkg_map_name "$p")"
    [ -n "$mapped" ] && pkgs+=("$mapped")
  done
  [ -n "${pkgs[*]-}" ] || return 0
  echo_info "正在定向升级：${pkgs[*]}"
  case "$pm" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install --only-upgrade -y "${pkgs[@]+"${pkgs[@]}"}" ;;
    dnf) dnf upgrade -y "${pkgs[@]+"${pkgs[@]}"}" ;;
    yum) yum update -y "${pkgs[@]+"${pkgs[@]}"}" ;;
    *) echo_error "未检测到支持的包管理器。"; return 1 ;;
  esac
}

pkg_full_upgrade() {
  local pm
  pm="$(detect_pkg_manager)"
  case "$pm" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade -y || return 1
      DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || return 1
      ;;
    dnf) dnf upgrade -y --refresh && dnf autoremove -y ;;
    yum) yum update -y ;;
    *) echo_error "未检测到支持的包管理器。"; return 1 ;;
  esac
}

pkg_remove() {
  local pm mapped p
  local pkgs=()
  pm="$(detect_pkg_manager)"
  for p in "$@"; do
    mapped="$(pkg_map_name "$p")"
    [ -n "$mapped" ] && pkgs+=("$mapped")
  done
  [ -n "${pkgs[*]-}" ] || return 0
  case "$pm" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get remove -y "${pkgs[@]+"${pkgs[@]}"}" ;;
    dnf) dnf remove -y "${pkgs[@]+"${pkgs[@]}"}" ;;
    yum) yum remove -y "${pkgs[@]+"${pkgs[@]}"}" ;;
    *) echo_error "未检测到支持的包管理器。"; return 1 ;;
  esac
}

ensure_command() {
  local cmd="${1:-}" pkg="${2:-}"
  [ -n "$cmd" ] || return 1
  [ -n "$pkg" ] || pkg="$cmd"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  echo_warn "未检测到命令：$cmd，准备安装软件包：$pkg"
  pkg_install "$pkg" || return 1
  command -v "$cmd" >/dev/null 2>&1 || { echo_error "安装后仍未检测到命令：$cmd"; return 1; }
}

service_enable_now() {
  local svc="${1:-}"
  [ -n "$svc" ] || return 1
  if is_systemd_available; then
    systemctl enable --now "$svc"
    return $?
  fi
  if command -v service >/dev/null 2>&1; then
    if command -v update-rc.d >/dev/null 2>&1; then update-rc.d "$svc" defaults >/dev/null 2>&1 || true; fi
    if command -v chkconfig >/dev/null 2>&1; then chkconfig "$svc" on >/dev/null 2>&1 || true; fi
    service "$svc" start
    return $?
  fi
  echo_warn "当前环境没有可用的服务管理器，无法启动 $svc。"
  return 1
}

service_restart_safe() {
  local svc="${1:-}"
  [ -n "$svc" ] || return 1
  if is_systemd_available; then
    systemctl restart "$svc" && systemctl is-active "$svc" >/dev/null 2>&1
    return $?
  fi
  if command -v service >/dev/null 2>&1; then
    service "$svc" restart
    return $?
  fi
  echo_warn "当前环境没有可用的服务管理器，无法重启 $svc。"
  return 1
}

service_reload_or_restart() {
  local svc="${1:-}"
  [ -n "$svc" ] || return 1
  if is_systemd_available; then
    if systemctl reload "$svc" 2>/dev/null && systemctl is-active "$svc" >/dev/null 2>&1; then return 0; fi
    systemctl restart "$svc" && systemctl is-active "$svc" >/dev/null 2>&1
    return $?
  fi
  if command -v service >/dev/null 2>&1; then
    service "$svc" reload 2>/dev/null || service "$svc" restart
    return $?
  fi
  echo_warn "当前环境没有可用的服务管理器，无法 reload/restart $svc。"
  return 1
}

ensure_crontab() {
  command -v crontab >/dev/null 2>&1 || pkg_install cron || return 1
  command -v crontab >/dev/null 2>&1 || { echo_error "cron/cronie 安装后仍无 crontab。"; return 1; }
  if is_systemd_available; then
    if systemctl list-unit-files --no-legend 2>/dev/null | grep -q '^cron.service'; then service_enable_now cron; else service_enable_now crond; fi
  else
    service_enable_now cron || service_enable_now crond
  fi
}

# ---------- 防火墙 ----------
firewalld_active() { command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; }
ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; }

allow_port_firewall() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  echo_info "尝试放行 TCP 端口：$port"

  # 先处理真正处于 active 状态的防火墙，避免“工具已安装但未启用”造成错误安全判断。
  if firewalld_active; then
    firewalld_allow_port "$port" || return 1
    echo_color "firewalld 已放行 TCP/$port（活动 zone + 默认 zone）。"
    return 0
  firewall-cmd --permanent --add-port="${port}/tcp" || return 1
    firewall-cmd --reload || return 1
    echo_color "firewalld 已放行 ${port}/tcp。"
    return 0
  fi
  if ufw_active; then
    ufw allow "${port}/tcp" || return 1
    echo_color "ufw 已放行 ${port}/tcp。"
    return 0
  fi

  # iptables 可能是 legacy，也可能是 nft 后端；命令可用时追加 ACCEPT 是比猜测 nft 表/链更稳妥的运行时保护。
  if command -v iptables >/dev/null 2>&1; then
    if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
      iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || return 1
      echo_warn "iptables 已添加运行时规则放行 ${port}/tcp；是否持久化取决于发行版防火墙管理方式。"
    else
      echo_color "iptables 已存在 ${port}/tcp 放行规则。"
    fi
    return 0
  fi

  # 纯 nftables 环境无法可靠猜测用户的 table/chain/hook/priority，要求用户明确人工确认。
  if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q '[^[:space:]]'; then
    echo_warn "检测到活动 nftables 规则，但无法安全推断应修改的 input chain；未自动改写规则集。"
    return 2
  fi

  # 没有活动过滤器时，可提前写入未来可能启用的工具配置。
  if command -v firewall-offline-cmd >/dev/null 2>&1 && command -v firewall-cmd >/dev/null 2>&1; then
    firewall-offline-cmd --add-port="${port}/tcp" >/dev/null 2>&1 || return 1
    echo_color "已在未启动的 firewalld 永久配置中预放行 ${port}/tcp。"
    return 0
  fi
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp" || return 1
    echo_color "已预先写入 ufw 放行规则 ${port}/tcp（ufw 当前未启用）。"
    return 0
  fi

  echo_warn "未检测到可安全自动处理的本机防火墙。仍需确认云厂商安全组和本机规则已放行端口 $port。"
  return 2
}

allow_ssh_ports_before_firewall_enable() {
  local ports p failed=0
  ports="$(get_current_ssh_ports 2>/dev/null || echo 22)"
  [ -n "$ports" ] || ports="22"
  for p in ${ports//,/ }; do
    if [[ "$p" =~ ^[0-9]+$ ]]; then
      allow_port_firewall "$p" || failed=1
    fi
  done
  return "$failed"
}

firewall_status() {
  ui_title "防火墙状态"
  echo_warn "云厂商安全组不受本脚本控制，请在云后台另行确认 SSH 端口。"
  echo_info "SSH 当前端口：$(get_current_ssh_ports 2>/dev/null || echo 22)"
  if command -v firewall-cmd >/dev/null 2>&1; then
    echo_info "firewalld 状态：$(firewall-cmd --state 2>/dev/null || echo inactive)"
    firewall-cmd --get-active-zones 2>/dev/null || true
    firewall-cmd --list-all 2>/dev/null || true
  else
    echo_dim "未检测到 firewall-cmd。"
  fi
  if command -v ufw >/dev/null 2>&1; then
    echo_info "ufw 状态："
    ufw status verbose 2>/dev/null || true
  else
    echo_dim "未检测到 ufw。"
  fi
  if command -v nft >/dev/null 2>&1; then
    echo_info "nftables 规则摘要："
    nft list ruleset 2>/dev/null | sed -n '1,80p' || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    echo_info "iptables INPUT 摘要："
    iptables -S INPUT 2>/dev/null | sed -n '1,80p' || true
  fi
}

manage_firewall() {
  while true; do
    ui_title "防火墙管理"
    ui_menu_note "逻辑：先查看状态；开启时先保护 SSH；关闭属于高风险操作。"
    ui_option 1 "查看当前状态与规则"
    ui_option 2 "安全开启防火墙（先放行当前 SSH 端口）"
    ui_option 3 "关闭本机防火墙（高风险）"
    ui_back
    local opt ports p
    ui_prompt opt || return 0
    case "$opt" in
      1) firewall_status; ui_action_pause ;;
      2)
        ports="$(get_current_ssh_ports 2>/dev/null || echo 22)"
        echo_warn "开启前必须先放行当前 SSH 端口：$ports"
        echo_warn "云厂商安全组不受本脚本控制。"
        confirm_action "确认开启本机防火墙？缺少时会安装 firewalld/ufw，并预放行 SSH；其他业务端口需自行放行。" "2" || { echo_warn "已取消。"; ui_action_pause; continue; }
        if is_redhat_like; then
          if ufw_active; then echo_error "ufw 已运行，不同时启用 firewalld。"; ui_action_pause; continue; fi
          pkg_install firewalld || { echo_error "firewalld 安装失败。"; ui_action_pause; continue; }
          if ! command -v firewall-offline-cmd >/dev/null 2>&1 && ! firewalld_active; then
            echo_error "firewalld 尚未运行且缺少 firewall-offline-cmd，无法在启动前安全放行 SSH，已中止。"
            ui_action_pause; continue
          fi
          for p in ${ports//,/ }; do
            [[ "$p" =~ ^[0-9]+$ ]] || continue
            firewalld_allow_port "$p" || { echo_error "无法在启动前放行 SSH 端口 $p，已中止。"; ui_action_pause; continue 2; }
          done
          service_enable_now firewalld || { echo_error "firewalld 启动失败。"; ui_action_pause; continue; }
          firewall-cmd --reload >/dev/null 2>&1 || { echo_error "firewalld reload 失败。"; ui_action_pause; continue; }
          echo_color "firewalld 已安全开启。"
        elif is_debian_like; then
          if firewalld_active; then echo_error "firewalld 已运行，不同时启用 ufw。"; ui_action_pause; continue; fi
          if ! command -v ufw >/dev/null 2>&1; then
            pkg_install ufw || { echo_error "ufw 安装失败。"; ui_action_pause; continue; }
          fi
          for p in ${ports//,/ }; do
            [[ "$p" =~ ^[0-9]+$ ]] || continue
            ufw allow "${p}/tcp" || { echo_error "无法在启用前写入 SSH 端口 $p 放行规则，已中止。"; ui_action_pause; continue 2; }
          done
          ufw --force enable || { echo_error "ufw enable 失败。"; ui_action_pause; continue; }
          echo_color "ufw 已安全开启。"
        else
          echo_warn "当前系统未识别，未自动开启防火墙。"
        fi
        ui_action_pause
        ;;
      3)
        echo_warn "关闭本机防火墙会减少网络访问控制；云厂商安全组不受影响。"
        confirm_action "确认关闭本机 firewalld/ufw？" "2" || { echo_warn "已取消。"; ui_action_pause; continue; }
        if is_systemd_available; then
          systemctl stop firewalld 2>/dev/null || true
          systemctl disable firewalld 2>/dev/null || true
          systemctl stop ufw 2>/dev/null || true
          systemctl disable ufw 2>/dev/null || true
        fi
        command -v ufw >/dev/null 2>&1 && ufw disable >/dev/null 2>&1 || true
        echo_color "防火墙服务已尝试关闭。"
        ui_action_pause
        ;;
      0) return 0 ;;
      *) echo_error "无效选项"; ui_action_pause ;;
    esac
  done
}

selinux_state() {
  if command -v getenforce >/dev/null 2>&1; then
    getenforce 2>/dev/null || echo "unknown"
  else
    echo "absent"
  fi
}

selinux_allow_ssh_port() {
  local port="${1:-}" state="" table="" types=""
  normalize_port port || return 1
  command -v getenforce >/dev/null 2>&1 || return 0
  state="$(getenforce)" || return 1
  [ "$state" = Disabled ] && return 0
  ensure_command semanage semanage || return 1
  table="$(LC_ALL=C semanage port -l)" || return 1
  types="$(printf '%s\n' "$table" | awk -v p="$port" '$2=="tcp" {
    for(i=3;i<=NF;i++){gsub(/,/,"",$i); n=split($i,a,"-");
      if((n==1 && a[1]==p) || (n==2 && p>=a[1] && p<=a[2])) print $1
    }}')"
  if printf '%s\n' "$types" | grep -qx ssh_port_t; then return 0; fi
  # A generic unreserved range is not an explicit ownership assignment.
  types="$(printf '%s\n' "$types" | grep -Ev '^(unreserved_port_t|port_t|ephemeral_port_t)?$' || :)"
  [ -z "$types" ] || { echo_error "TCP/$port 已分配给 SELinux 类型 $types；不自动夺取其他服务端口。"; return 1; }
  semanage port -a -t ssh_port_t -p tcp "$port" || { echo_error "SELinux 新增端口失败，未使用 -m 强制覆盖其他类型。"; return 1; }
}

manage_selinux() {
  while true; do
    ui_title "SELinux 管理"
    if command -v getenforce >/dev/null 2>&1; then
      echo_info "当前状态：$(getenforce 2>/dev/null || echo unknown)"
    else
      echo_warn "未检测到 SELinux 工具；Debian/Ubuntu 通常不启用 SELinux。"
    fi
    ui_option 1 "查看 SELinux 完整状态"
    ui_option 2 "设置 Permissive（排障/过渡）"
    ui_option 3 "设置 Enforcing（推荐正常状态）"
    ui_option 4 "设置 Disabled（高风险，重启后生效）"
    ui_option 5 "查看 SSH 的 SELinux 端口策略 ssh_port_t"
    ui_back
    local opt conf
    conf="/etc/selinux/config"
    ui_prompt opt || return 0
    case "$opt" in
      1)
        if command -v sestatus >/dev/null 2>&1; then sestatus; elif command -v getenforce >/dev/null 2>&1; then getenforce; else echo_warn "当前系统没有 SELinux 管理工具。"; fi
        ui_action_pause
        ;;
      2)
        [ -f "$conf" ] || { echo_warn "未找到 $conf"; ui_action_pause; continue; }
        backup_file "$conf" || { echo_error "SELinux 配置备份失败，已中止。"; ui_action_pause; continue; }
        sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$conf" || { echo_error "SELinux 配置写入失败。"; ui_action_pause; continue; }
        setenforce 0 2>/dev/null || echo_warn "当前会话未能立即切换，可能需要重启。"
        echo_color "SELinux 已设置为 Permissive。"
        ui_action_pause
        ;;
      3)
        [ -f "$conf" ] || { echo_warn "未找到 $conf"; ui_action_pause; continue; }
        echo_warn "若系统当前为 Disabled，直接恢复 Enforcing 可能需要文件系统 relabel。建议先使用 Permissive 验证。"
        confirm_action "确认设置 SELinux Enforcing？" "2" || { ui_action_pause; continue; }
        backup_file "$conf" || { echo_error "SELinux 配置备份失败，已中止。"; ui_action_pause; continue; }
        sed -i 's/^SELINUX=.*/SELINUX=enforcing/' "$conf" || { echo_error "SELinux 配置写入失败。"; ui_action_pause; continue; }
        setenforce 1 2>/dev/null || echo_warn "当前会话未能立即切到 Enforcing，可能需重启。"
        echo_warn "若从 Disabled 恢复，请根据发行版文档评估 relabel，再安排维护窗口重启。"
        ui_action_pause
        ;;
      4)
        [ -f "$conf" ] || { echo_warn "未找到 $conf"; ui_action_pause; continue; }
        confirm_action "确认设置 SELinux Disabled？完全生效需要重启。" "2" || { ui_action_pause; continue; }
        backup_file "$conf" || { echo_error "SELinux 配置备份失败，已中止。"; ui_action_pause; continue; }
        sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$conf" || { echo_error "SELinux 配置写入失败。"; ui_action_pause; continue; }
        setenforce 0 2>/dev/null || true
        echo_warn "SELinux 已设置为 Disabled，需重启后完全生效。"
        ui_action_pause
        ;;
      5)
        command -v semanage >/dev/null 2>&1 && semanage port -l | grep '^ssh_port_t' || echo_warn "未检测到 semanage 或无 ssh_port_t 输出。"
        ui_action_pause
        ;;
      0) return 0 ;;
      *) echo_error "无效选项"; ui_action_pause ;;
    esac
  done
}

ssh_service_name() {
  if is_systemd_available; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then echo "ssh"; else echo "sshd"; fi
    return 0
  fi
  if [ -x /etc/init.d/ssh ]; then echo "ssh"; else echo "sshd"; fi
}

sshd_main_config() { echo "/etc/ssh/sshd_config"; }
sshd_toolkit_dropin() { echo "/etc/ssh/sshd_config.d/00-server-toolkit.conf"; }

sshd_effective_config() {
  command -v sshd >/dev/null 2>&1 || return 127
  sshd -T 2>/dev/null
}

get_current_session_ssh_port() {
  local port=""
  if [ -n "${SSH_CONNECTION:-}" ]; then
    port="$(printf '%s\n' "$SSH_CONNECTION" | awk '{print $4; exit}')"
  elif [ -n "${SSH_CLIENT:-}" ]; then
    # SSH_CLIENT = client address, client port, server port.
    port="$(printf '%s\n' "$SSH_CLIENT" | awk '{print $3; exit}')"
  fi
  normalize_port port || return 1
  printf '%s\n' "$port"
}

get_listening_sshd_ports() {
  local addr port
  command -v ss >/dev/null 2>&1 || return 1
  ss -H -ltnp 2>/dev/null | awk '/users:\(\("sshd"/ {print $4}' | while IFS= read -r addr; do
    port="${addr##*:}"
    port="${port%] }"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && printf '%s\n' "$port"
  done
}

get_current_ssh_ports() {
  # 同时纳入“配置将监听的端口”和“当前会话/当前 daemon 正在使用的端口”。
  # 这样在 sshd_config 已改但 daemon 尚未 reload 的场景下，开启防火墙仍会保护当前 SSH 会话。
  local ports
  ports="$({
    sshd_effective_config 2>/dev/null | awk '$1=="port"{print $2}' || true
    get_current_session_ssh_port 2>/dev/null || true
    get_listening_sshd_ports 2>/dev/null || true
  } | awk '/^[0-9]+$/ && $1>=1 && $1<=65535 {print $1}' | sort -n -u | paste -sd, -)"
  if [ -z "$ports" ]; then
    # 无法识别时保持旧行为以兼容非 SSH 控制台，但调用高风险防火墙功能前会再次提示用户。
    ports="22"
  fi
  printf '%s\n' "$ports"
}

port_in_use() {
  local port="${1:-}"
  local hex=""
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1

  # ss 的字段布局会随 iproute2 版本和选项变化；直接使用 sport 过滤比解析列更可靠，
  # 同时可正确识别 IPv4、IPv6、通配地址和仅绑定单个地址的监听套接字。
  if command -v ss >/dev/null 2>&1; then
    if ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then
      return 0
    fi
    return 1
  fi

  if command -v netstat >/dev/null 2>&1; then
    if netstat -ltn 2>/dev/null | awk -v p="$port" '
      NR > 2 {
        addr=$4
        sub(/^.*:/, "", addr)
        if (addr == p) found=1
      }
      END { exit !found }
    '; then
      return 0
    fi
    return 1
  fi

  hex="$(printf '%04X' "$port")"
  awk -v p=":${hex}" '$2 ~ p"$" && $4=="0A" {found=1} END{exit !found}'     /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

backup_ssh_tree() {
  local dir="${1:-}"
  [ -n "$dir" ] || return 1
  backup_path_to_dir /etc/ssh/sshd_config "$dir" || return 1
  if [ -d /etc/ssh/sshd_config.d ]; then
    backup_path_to_dir /etc/ssh/sshd_config.d "$dir" || return 1
  else
    : > "$dir/.sshd_config_d_absent"
  fi
}

restore_ssh_tree() {
  local dir="${1:-}" failed=0
  [ -f "$dir/etc/ssh/sshd_config" ] || { echo_error "SSH 备份缺失，未删除当前配置：$dir"; return 1; }
  if [ ! -f "$dir/.sshd_config_d_absent" ] && [ ! -d "$dir/etc/ssh/sshd_config.d" ]; then
    echo_error "SSH 目录备份不完整，未修改当前文件。"; return 1
  fi
  restore_path_from_dir /etc/ssh/sshd_config "$dir" || failed=1
  if [ -f "$dir/.sshd_config_d_absent" ]; then
    rm -rf -- /etc/ssh/sshd_config.d || failed=1
  else
    restore_path_from_dir /etc/ssh/sshd_config.d "$dir" || failed=1
  fi
  if [ "$failed" -ne 0 ]; then
    echo_error "SSH 回滚未完整完成，请保持当前会话；备份：$dir"; return 1
  fi
  echo_warn "SSH 配置已恢复：$dir"
}

sshd_ensure_include() {
  local main tmp mode owner group
  main="$(sshd_main_config)"
  [ -f "$main" ] || { echo_error "找不到 $main"; return 1; }
  mkdir -p /etc/ssh/sshd_config.d || return 1
  tmp="$(mktemp "${main}.server-toolkit.XXXXXX")" || return 1
  mode="$(stat -c '%a' "$main" 2>/dev/null || echo 600)"
  owner="$(stat -c '%u' "$main" 2>/dev/null || echo 0)"
  group="$(stat -c '%g' "$main" 2>/dev/null || echo 0)"
  {
    echo "Include /etc/ssh/sshd_config.d/*.conf"
    sed -E '/^[[:space:]]*Include[[:space:]]+\/etc\/ssh\/sshd_config\.d\/\*\.conf[[:space:]]*$/Id' "$main"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
  chown "$owner:$group" "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$main" || { rm -f "$tmp"; return 1; }
}

sshd_comment_key_in_file() {
  local file="${1:-}" key="${2:-}" tmp=""
  [ -f "$file" ] && [[ "$key" =~ ^[A-Za-z]+$ ]] || return 1
  tmp="$(mktemp "${file}.server-toolkit.XXXXXX")" || return 1
  # tolower() works in both mawk (Debian) and gawk. Never rewrite Match-specific policies.
  awk -v key="$key" '
    BEGIN { in_match=0; key=tolower(key) }
    tolower($1)=="match" { in_match=1 }
    !in_match && tolower($1)==key { print "# server-toolkit disabled duplicate: " $0; next }
    { print }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$file" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

sshd_prepare_effective_key() {
  local key="${1:-}" f toolkit
  [ -n "$key" ] || return 1
  toolkit="$(sshd_toolkit_dropin)"
  sshd_ensure_include || return 1
  sshd_comment_key_in_file "$(sshd_main_config)" "$key" || return 1
  if [ -d /etc/ssh/sshd_config.d ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$f" ] || continue
      [ "$f" = "$toolkit" ] && continue
      sshd_comment_key_in_file "$f" "$key" || return 1
    done
  fi
  return 0
}

sshd_dropin_set_key() {
  local key="${1:-}" val="${2:-}" file
  [ -n "$key" ] || return 1
  file="$(sshd_toolkit_dropin)"
  mkdir -p "$(dirname "$file")" || return 1
  touch "$file" || return 1
  chmod 600 "$file" 2>/dev/null || true
  sed -i -E "/^[[:space:]]*${key}[[:space:]]+/Id" "$file" || return 1
  printf '%s %s\n' "$key" "$val" >> "$file" || return 1
}

sshd_set_ports_dropin() {
  local ports="${1:-}" file p wrote=0
  [ -n "$ports" ] || return 1
  file="$(sshd_toolkit_dropin)"
  mkdir -p "$(dirname "$file")" || return 1
  touch "$file" || return 1
  chmod 600 "$file" 2>/dev/null || true
  sed -i -E '/^[[:space:]]*Port[[:space:]]+/Id' "$file" || return 1
  for p in ${ports//,/ }; do
    if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
      printf 'Port %s\n' "$p" >> "$file" || return 1
      wrote=1
    else
      echo_error "拒绝写入非法 SSH 端口：${p:-空}"
      return 1
    fi
  done
  [ "$wrote" -eq 1 ]
}

set_sshd_kv_effective() {
  local key="${1:-}" val="${2:-}" config="" file=""
  [[ "$key" =~ ^[A-Za-z]+$ ]] && [ -n "$val" ] || return 1
  case "$val" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "${key,,}" in kbdinteractiveauthentication|challengeresponseauthentication)
    config="$(sshd_effective_config)" || return 1
    if printf '%s\n' "$config" | grep -q '^kbdinteractiveauthentication '; then key=KbdInteractiveAuthentication; else key=ChallengeResponseAuthentication; fi
    sshd_prepare_effective_key KbdInteractiveAuthentication || return 1
    sshd_prepare_effective_key ChallengeResponseAuthentication || return 1
    file="$(sshd_toolkit_dropin)"
    if [ -f "$file" ]; then
      sed -i -E '/^[[:space:]]*(KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]+/Id' "$file" || return 1
    fi
    ;;
    *) sshd_prepare_effective_key "$key" || return 1 ;;
  esac
  sshd_dropin_set_key "$key" "$val"
}

set_sshd_kv() { set_sshd_kv_effective "$@"; }

test_sshd_config() {
  command -v sshd >/dev/null 2>&1 || { echo_error "未找到 sshd 命令。"; return 1; }
  sshd -t
}

ssh_socket_activation_present() {
  is_systemd_available || return 1
  systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'
}

ssh_refresh_socket_activation() {
  ssh_socket_activation_present || return 0
  # Ubuntu 22.10+ 默认可能使用 ssh.socket；Ubuntu 24.04 的 Port 等设置由 systemd generator 生成 socket 配置。
  systemctl daemon-reload || { echo_error "systemctl daemon-reload 失败，ssh.socket 端口配置可能未刷新。"; return 1; }
  if systemctl is-active ssh.socket >/dev/null 2>&1; then
    systemctl restart ssh.socket || { echo_error "ssh.socket 重启失败。"; return 1; }
    systemctl is-active ssh.socket >/dev/null 2>&1 || { echo_error "ssh.socket 未处于 active 状态。"; return 1; }
  elif systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    systemctl start ssh.socket || { echo_error "ssh.socket 启动失败。"; return 1; }
  fi
  return 0
}

restart_ssh_service() {
  local svc
  svc="$(ssh_service_name)"
  # 先刷新 socket generator，再 reload/restart ssh/sshd。已建立的 SSH 会话通常不会因 reload 而断开。
  ssh_refresh_socket_activation || return 1
  service_reload_or_restart "$svc" || { echo_error "SSH 服务 reload/restart 失败：$svc"; return 1; }
}

sshd_check_effective_key() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  ssh_verify_expectations "$1=$2"
}

sshd_check_listening_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  if port_in_use "$port"; then
    echo_color "检测到端口 $port 正在监听。"
    return 0
  fi
  echo_warn "暂未检测到端口 $port 监听。请用另一个终端测试 SSH。"
  return 1
}

ssh_verify_expectations() {
  local item="" key="" expected="" actual="" config="" expected_norm="" actual_norm=""
  config="$(sshd_effective_config)" || { echo_error "sshd -T 失败。"; return 1; }
  for item in "$@"; do
    [[ "$item" == *=* ]] || return 1
    key="${item%%=*}"; expected="${item#*=}"; key="${key,,}"
    case "$key" in
      port)
        fail2ban_validate_ports "$expected" || return 1
        expected_norm="$(printf '%s' "$expected" | tr ',' '\n' | sort -nu | paste -sd, -)"
        actual_norm="$(printf '%s\n' "$config" | awk '$1=="port"{print $2}' | sort -nu | paste -sd, -)"
        [ "$actual_norm" = "$expected_norm" ] || { echo_error "端口验证失败：期望 $expected_norm；实际 $actual_norm"; return 1; }
        ;;
      *)
        case "$key" in kbdinteractiveauthentication|challengeresponseauthentication)
          actual="$(printf '%s\n' "$config" | awk '$1=="kbdinteractiveauthentication" || $1=="challengeresponseauthentication"{print $2; exit}')" ;;
          *) actual="$(printf '%s\n' "$config" | awk -v k="$key" '$1==k{print $2; exit}')" ;;
        esac
        [ "$actual" = "$expected" ] || { echo_error "sshd -T 验证失败：$key 期望 $expected，实际 ${actual:-空}"; return 1; }
        ;;
    esac
  done
}

ssh_apply_with_rollback() {
  local desc="${1:-SSH 配置}" backup_dir="${2:-}"
  shift 2 || true
  [ -n "$backup_dir" ] || return 1
  if ! test_sshd_config; then
    echo_error "$desc：sshd -t 失败，开始回滚。"
    restore_ssh_tree "$backup_dir" || true
    return 1
  fi
  if ! sshd_effective_config >/dev/null 2>&1; then
    echo_error "$desc：sshd -T 无法解析最终配置，开始回滚。"
    restore_ssh_tree "$backup_dir" || true
    return 1
  fi
  if [ "$#" -gt 0 ] && ! ssh_verify_expectations "$@"; then
    echo_error "$desc：最终生效值不符合预期，开始回滚。"
    restore_ssh_tree "$backup_dir" || true
    return 1
  fi
  if ! restart_ssh_service; then
    echo_error "$desc：SSH 服务应用失败，开始回滚。"
    restore_ssh_tree "$backup_dir" || true
    restart_ssh_service || true
    return 1
  fi
  if [ "$#" -gt 0 ] && ! ssh_verify_expectations "$@"; then
    echo_error "$desc：服务 reload/restart 后生效值异常，开始回滚。"
    restore_ssh_tree "$backup_dir" || true
    restart_ssh_service || true
    return 1
  fi
  echo_color "$desc 已应用。"
  echo_warn "全局配置校验不等于实际登录测试；Match/PAM/安全组仍需另开终端验证。"
  return 0
}

show_ssh_effective_config() {
  ui_title "SSH 生效配置"
  if command -v sshd >/dev/null 2>&1; then
    sshd_effective_config | grep -Ei '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|pubkeyauthentication|permitemptypasswords|maxauthtries|logingracetime|usedns|x11forwarding|allowtcpforwarding|clientaliveinterval|clientalivecountmax|maxstartups) ' || true
  else
    echo_warn "未找到 sshd 命令。"
  fi
}

prepare_new_ssh_port_access() {
  local port="${1:-}" rc
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  allow_port_firewall "$port"
  rc=$?
  case "$rc" in
    0) ;;
    2)
      echo_warn "脚本无法确认本机 nftables/云安全组已放行端口 $port。"
      confirm_action "你是否已手动确认所有外部和本机防火墙均放行该端口？" "2" || return 1
      ;;
    *) echo_error "防火墙端口放行失败，已中止 SSH 修改。"; return 1 ;;
  esac
  selinux_allow_ssh_port "$port" || { echo_error "SELinux ssh_port_t 配置失败，已中止 SSH 修改。"; return 1; }
}

show_ssh_connection_summary() {
  local session_port configured_ports listening_ports rootlogin passlogin pubkey socket_mode
  ui_title "SSH 连接与登录状态"
  session_port="$(get_current_session_ssh_port 2>/dev/null || true)"
  configured_ports="$(sshd_effective_config 2>/dev/null | awk '$1=="port"{print $2}' | sort -n -u | paste -sd, - || true)"
  listening_ports="$(get_listening_sshd_ports 2>/dev/null | sort -n -u | paste -sd, - || true)"
  rootlogin="$(sshd_effective_config 2>/dev/null | awk '$1=="permitrootlogin"{print $2; exit}' || true)"
  passlogin="$(sshd_effective_config 2>/dev/null | awk '$1=="passwordauthentication"{print $2; exit}' || true)"
  pubkey="$(sshd_effective_config 2>/dev/null | awk '$1=="pubkeyauthentication"{print $2; exit}' || true)"
  if ssh_socket_activation_present; then socket_mode="ssh.socket 可用"; else socket_mode="传统 ssh/sshd service"; fi
  ui_kv ssh "当前会话服务端口" "${session_port:-非 SSH 会话/无法识别}"
  ui_kv network "sshd -T 配置端口" "${configured_ports:-无法识别}"
  ui_kv network "当前 sshd 监听端口" "${listening_ports:-无法识别}"
  ui_kv ssh "PermitRootLogin" "${rootlogin:-无法识别}"
  ui_kv key "PasswordAuthentication" "${passlogin:-无法识别}"
  ui_kv key "PubkeyAuthentication" "${pubkey:-无法识别}"
  ui_kv info "启动模式" "$socket_mode"
  echo_warn "云厂商安全组不会被 sshd_config 自动修改；改端口前仍需确认云后台已放行新端口。"
}

change_ssh_port_only() {
  local new_port old_ports keep_ports backup_dir final_ports ans
  read -r -p "请输入新的 SSH 端口 (1-65535，输入 q 取消): " new_port || return 0
  [[ "$new_port" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
    echo_error "端口不合法。"
    return 1
  fi
  old_ports="$(get_current_ssh_ports)"
  if port_in_use "$new_port" && ! printf ',%s,' "$old_ports" | grep -q ",$new_port,"; then
    echo_error "端口 $new_port 已被占用，请换一个。"
    return 1
  fi
  echo_warn "当前 SSH 端口：$old_ports"
  echo_warn "默认会临时保留旧端口，并同时监听新端口，避免断连。"
  choice_ssh_port_keep_policy ans || { echo_warn "未能读取端口策略，已取消。"; return 0; }
  case "$ans" in
    new_only) final_ports="$new_port" ;;
    keep_both)
      keep_ports="$old_ports,$new_port"
      final_ports="$(printf '%s\n' "$keep_ports" | awk -F, '{for(i=1;i<=NF;i++) if($i && !seen[$i]++) out=out (out? ",":"") $i; print out}')"
      ;;
    cancel) echo_warn "已取消。"; return 0 ;;
    *) echo_warn "已取消。"; return 0 ;;
  esac
  backup_dir="$(make_backup_dir ssh)" || return 1
  backup_ssh_tree "$backup_dir" || { echo_error "SSH 配置备份失败，已中止。"; return 1; }
  prepare_new_ssh_port_access "$new_port" || return 1
  sshd_prepare_effective_key "Port" || {
    restore_ssh_tree "$backup_dir" || true
    echo_warn "SSH 配置尚未应用；为避免误断连，刚新增的防火墙/SELinux端口规则不会自动删除。"
    return 1
  }
  sshd_set_ports_dropin "$final_ports" || { restore_ssh_tree "$backup_dir" || true; return 1; }
  if ssh_apply_with_rollback "SSH 端口配置" "$backup_dir" "Port=$final_ports"; then
    sshd_effective_config | awk '$1=="port"{print "生效端口: "$2}'
    if ! sshd_check_listening_port "$new_port"; then
      echo_error "SSH 配置显示端口已生效，但系统未监听新端口 $new_port；开始回滚，避免下次登录失败。"
      restore_ssh_tree "$backup_dir" || return 1
      restart_ssh_service || { echo_error "回滚后 SSH 服务恢复失败，请保持当前会话并立即检查。"; return 1; }
      return 1
    fi
    fail2ban_refresh_ssh_port_silent || echo_warn "Fail2Ban 端口刷新失败，请进入菜单手动检查。"
    echo_warn "请不要关闭当前 SSH 连接。请另开终端测试：ssh -p ${new_port} root@你的服务器IP"
    echo_warn "如果回滚过 SSH 配置，防火墙/SELinux 中新增的端口规则可能仍保留；这通常安全，但可在确认后手动清理。"
    return 0
  fi
  return 1
}

get_root_password_hash() {
  getent shadow root 2>/dev/null | awk -F: '{print $2; exit}'
}

restore_root_password_hash() {
  [ "$#" -eq 1 ] || return 1
  printf 'root:%s\n' "$1" | chpasswd -e
}

root_password_login_summary() {
  local locked rootlogin passlogin
  locked="$(passwd -S root 2>/dev/null | awk '{print $2}' || true)"
  rootlogin="$(sshd_effective_config 2>/dev/null | awk '$1=="permitrootlogin"{print $2; exit}' || true)"
  passlogin="$(sshd_effective_config 2>/dev/null | awk '$1=="passwordauthentication"{print $2; exit}' || true)"
  echo_info "root 密码状态=${locked:-未知} PermitRootLogin=${rootlogin:-未知} PasswordAuthentication=${passlogin:-未知}"
  if [ "$passlogin" != "yes" ] || [ "$rootlogin" = "no" ] || [ "$rootlogin" = "prohibit-password" ] || [ "$rootlogin" = "without-password" ] || [ "$rootlogin" = "forced-commands-only" ]; then
    echo_warn "密码可以修改，但当前 SSH 生效配置可能不允许 root 使用密码登录。"
  fi
}

change_root_password_only() {
  local new_password confirm_password
  ui_title "修改 root 密码"
  root_password_login_summary
  echo_info "安全提示：输入密码时终端不会显示字符或星号，这是正常现象。"
  read -r -s -p "请输入 root 新密码（直接回车取消）: " new_password || return 0; echo
  [ -n "$new_password" ] || { echo_warn "已取消。"; return 0; }
  read -r -s -p "请再次输入新密码: " confirm_password || return 0; echo
  [ "$new_password" = "$confirm_password" ] || { echo_error "两次密码不一致。"; return 1; }
  printf 'root:%s\n' "$new_password" | chpasswd || { echo_error "修改密码失败。"; return 1; }
  echo_color "root 密码已更新。"
  if passwd -S root 2>/dev/null | awk '{exit !($2=="L" || $2=="LK")}'; then
    echo_warn "root 账户仍处于锁定状态。"
    if confirm_action "是否解除 root 本地密码锁定？这不会自动开启 SSH root 登录。" "2"; then
      if passwd -u root; then
        echo_color "root 本地密码锁定已解除。"
      else
        echo_error "root 解锁失败；密码已经修改，但账户仍可能处于锁定状态，请执行 passwd -S root 检查。"
        return 1
      fi
    fi
  fi
  root_password_login_summary
}

change_ssh_port_and_password_together() {
  local new_port new_password confirm_password old_ports final_ports ans keep_ports backup_dir old_hash
  ui_title "同时修改 SSH 端口和 root 密码"
  read -r -p "请输入新的 SSH 端口 (1-65535，输入 q 取消): " new_port || return 0
  [[ "$new_port" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ] || { echo_error "端口不合法。"; return 1; }
  old_ports="$(get_current_ssh_ports)"
  if port_in_use "$new_port" && ! printf ',%s,' "$old_ports" | grep -q ",$new_port,"; then echo_error "端口 $new_port 已被占用。"; return 1; fi
  echo_info "安全提示：输入密码时终端不会显示字符或星号，这是正常现象。"
  read -r -s -p "请输入 root 新密码（直接回车取消）: " new_password || return 0; echo
  [ -n "$new_password" ] || { echo_warn "已取消；端口和密码均未修改。"; return 0; }
  read -r -s -p "请再次输入 root 新密码: " confirm_password || return 0; echo
  [ "$new_password" = "$confirm_password" ] || { echo_error "两次密码不一致；未做任何修改。"; return 1; }
  echo_info "密码已读取并通过两次一致性校验（密码内容不会显示）。"
  choice_ssh_port_keep_policy ans || { echo_warn "未能读取端口策略；端口和密码均未修改。"; return 0; }
  case "$ans" in
    new_only) final_ports="$new_port" ;;
    keep_both) keep_ports="$old_ports,$new_port"; final_ports="$(printf '%s\n' "$keep_ports" | awk -F, '{for(i=1;i<=NF;i++) if($i && !seen[$i]++) out=out (out? ",":"") $i; print out}')" ;;
    *) echo_warn "已取消；端口和密码均未修改。"; return 0 ;;
  esac
  backup_dir="$(make_backup_dir ssh-port-pass)" || return 1
  backup_ssh_tree "$backup_dir" || { echo_error "SSH 配置备份失败，已中止。"; return 1; }
  old_hash="$(get_root_password_hash)"
  [ -n "$old_hash" ] || { echo_error "无法读取 root 原密码哈希，已中止。"; return 1; }
  prepare_new_ssh_port_access "$new_port" || return 1
  sshd_prepare_effective_key Port || {
    restore_ssh_tree "$backup_dir" || true
    echo_warn "SSH 配置尚未应用；为避免误断连，刚新增的防火墙/SELinux端口规则不会自动删除。"
    return 1
  }
  sshd_set_ports_dropin "$final_ports" || { restore_ssh_tree "$backup_dir" || true; return 1; }
  if ! test_sshd_config; then restore_ssh_tree "$backup_dir"; echo_error "sshd -t 失败，密码尚未修改。"; return 1; fi
  printf 'root:%s\n' "$new_password" | chpasswd || { restore_ssh_tree "$backup_dir"; echo_error "root 密码修改失败，已恢复 SSH 配置。"; return 1; }
  if ssh_apply_with_rollback "SSH 端口和 root 密码配置" "$backup_dir" "Port=$final_ports"; then
    if ! sshd_check_listening_port "$new_port"; then
      echo_error "SSH 配置显示端口已生效，但系统未监听新端口 $new_port；开始回滚 SSH 配置和 root 密码。"
      restore_ssh_tree "$backup_dir" || echo_error "SSH 配置回滚失败，请保持当前会话并立即人工检查。"
      restart_ssh_service || echo_error "回滚后 SSH 服务恢复失败，请保持当前会话。"
      restore_root_password_hash "$old_hash" || echo_error "自动恢复 root 原密码哈希失败，请立即通过当前会话人工修复。"
      return 1
    fi
    fail2ban_refresh_ssh_port_silent || echo_warn "Fail2Ban 端口刷新失败，请进入菜单手动检查。"
    echo_color "SSH 端口与 root 密码已更新。"
    echo_warn "请保持当前会话，另开终端测试：ssh -p ${new_port} root@服务器IP"
    return 0
  fi
  restore_root_password_hash "$old_hash" || echo_error "自动恢复 root 原密码哈希失败，请立即通过当前会话人工修复。"
  echo_warn "SSH 应用失败，已尝试回滚 SSH 配置及 root 密码。防火墙/SELinux新增放行规则为避免断连而保留，可稍后手动移除。"
  return 1
}

restore_user_ssh_from_backup() {
  local ssh_dir="${1:-}" backup_dir="${2:-}" existed="${3:-0}"
  [ -n "$ssh_dir" ] && [ -n "$backup_dir" ] || return 1
  if [ "$existed" -eq 1 ]; then
    restore_path_from_dir "$ssh_dir" "$backup_dir" || { echo_error "用户 .ssh 自动回滚失败：$ssh_dir"; return 1; }
  else
    rm -rf "$ssh_dir" || return 1
  fi
}

configure_key_login_existing() {
  local user pubkey home_dir ssh_dir auth_file backup_dir ssh_dir_existed=0
  read -r -p "请输入要配置密钥的用户名（默认 root，输入 q 取消）: " user || return 0
  user="${user:-root}"
  [[ "$user" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  id "$user" >/dev/null 2>&1 || { echo_error "用户不存在：$user"; return 1; }
  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  [ -n "$home_dir" ] && [ -d "$home_dir" ] || { echo_error "无法确定用户家目录。"; return 1; }
  ssh_dir="${home_dir}/.ssh"
  auth_file="${ssh_dir}/authorized_keys"
  echo_info "请粘贴一整行 SSH 公钥（ssh-rsa / ssh-ed25519 / ecdsa-sha2-* 开头），空内容取消："
  read -r pubkey || return 0
  [ -z "$pubkey" ] && { echo_warn "已取消。"; return 0; }
  case "$pubkey" in ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-*\ *) ;; *) echo_error "不像合法 SSH 公钥。"; return 1 ;; esac
  backup_dir="$(make_backup_dir ssh-key)" || return 1
  backup_ssh_tree "$backup_dir" || { echo_error "SSH 配置备份失败，已中止。"; return 1; }
  if [ -d "$ssh_dir" ]; then ssh_dir_existed=1; backup_path_to_dir "$ssh_dir" "$backup_dir" || return 1; fi
  mkdir -p "$ssh_dir" || { restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true; return 1; }
  touch "$auth_file" || { restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true; return 1; }
  if ! grep -qxF "$pubkey" "$auth_file"; then
    printf '%s\n' "$pubkey" >> "$auth_file" || { restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true; return 1; }
  fi
  chown -R "$user:$(id -gn "$user")" "$ssh_dir" || { restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true; return 1; }
  chmod 700 "$ssh_dir" || { restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true; return 1; }
  chmod 600 "$auth_file" || { restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true; return 1; }
  if ! set_sshd_kv_effective "PubkeyAuthentication" "yes"; then
    restore_ssh_tree "$backup_dir" || true
    restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true
    return 1
  fi
  if ssh_apply_with_rollback "密钥登录配置" "$backup_dir" "PubkeyAuthentication=yes"; then
    sshd_check_effective_key PubkeyAuthentication yes || true
    echo_warn "请另开终端测试密钥登录成功后，再考虑关闭密码登录。"
    return 0
  fi
  restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true
  return 1
}

generate_key_login_and_output_private() {
  local user home_dir ssh_dir key_name key_path pub_path auth_file comment backup_dir ans ssh_dir_existed=0
  read -r -p "请输入要生成密钥的用户名（默认 root，输入 q 取消）: " user || return 0
  user="${user:-root}"
  [[ "$user" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  id "$user" >/dev/null 2>&1 || { echo_error "用户不存在：$user"; return 1; }
  ensure_command ssh-keygen openssh-client || return 1
  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  [ -n "$home_dir" ] && [ -d "$home_dir" ] || { echo_error "无法确定用户家目录。"; return 1; }
  ssh_dir="${home_dir}/.ssh"
  key_name="server-toolkit_${user}_ed25519_$(date +%Y%m%d_%H%M%S)"
  key_path="${ssh_dir}/${key_name}"
  pub_path="${key_path}.pub"
  auth_file="${ssh_dir}/authorized_keys"
  comment="server-toolkit-${user}-$(hostname 2>/dev/null)-$(date +%F)"
  backup_dir="$(make_backup_dir ssh-keygen)" || return 1
  backup_ssh_tree "$backup_dir" || { echo_error "SSH 配置备份失败，已中止。"; return 1; }
  if [ -d "$ssh_dir" ]; then ssh_dir_existed=1; backup_path_to_dir "$ssh_dir" "$backup_dir" || return 1; fi
  mkdir -p "$ssh_dir" || { restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true; return 1; }
  chmod 700 "$ssh_dir" || { restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true; return 1; }
  ssh-keygen -t ed25519 -N "" -C "$comment" -f "$key_path" || { echo_error "生成密钥失败。"; restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true; return 1; }
  touch "$auth_file" || { restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true; return 1; }
  cat "$pub_path" >> "$auth_file" || { restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true; return 1; }
  chown -R "$user:$(id -gn "$user")" "$ssh_dir" || { restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true; return 1; }
  chmod 600 "$auth_file" "$key_path" || { restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true; return 1; }
  chmod 644 "$pub_path" || { restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true; return 1; }
  if ! set_sshd_kv_effective "PubkeyAuthentication" "yes"; then
    restore_ssh_tree "$backup_dir" || true
    restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true
    return 1
  fi
  if ! ssh_apply_with_rollback "自动生成密钥" "$backup_dir" "PubkeyAuthentication=yes"; then
    restore_user_ssh_from_backup "$ssh_dir" "$backup_dir" "$ssh_dir_existed" || true
    return 1
  fi
  echo_color "已为用户 $user 生成密钥，并写入 authorized_keys。"
  echo_info "私钥保存路径：$key_path"
  echo_info "公钥内容："
  cat "$pub_path"
  echo_warn "默认不直接输出私钥，避免终端录屏/日志泄漏。"
  while true; do
    choice_private_key_action ans || { echo_warn "未能读取选择，按默认不显示私钥处理。"; ans="2"; }
    case "$ans" in
      1)
        echo "==================== PRIVATE KEY START ===================="
        cat "$key_path"
        echo "===================== PRIVATE KEY END ====================="
        echo_warn "复制到本地后请执行：chmod 600 私钥文件"
        ;;
      2) echo_info "已保留私钥在服务器路径：$key_path"; return 0 ;;
      3)
        confirm_action "删除服务器上的私钥文件前，请确认你已经把私钥安全保存到本地。" "2" || continue
        rm -f "$key_path" || { echo_error "删除私钥失败：$key_path"; return 1; }
        echo_warn "已删除服务器上的私钥文件：$key_path"
        return 0
        ;;
      0) return 0 ;;
    esac
  done
}

check_authorized_keys_safe() {
  local user="${1:-}" home_dir="" auth_file="" path="" owner="" mode="" uid=""
  [ -n "$user" ] || return 1
  uid="$(id -u "$user")" || return 1
  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  [[ "$home_dir" == /* && "$home_dir" != / ]] || return 1
  auth_file="$home_dir/.ssh/authorized_keys"
  [ -s "$auth_file" ] || { echo_error "公钥文件不存在或为空：$auth_file"; return 1; }
  for path in "$home_dir" "$home_dir/.ssh" "$auth_file"; do
    owner="$(stat -Lc %u "$path")" && mode="$(stat -Lc %a "$path")" || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    if { [ "$owner" != "$uid" ] && [ "$owner" != 0 ]; } || [ "$((8#$mode & 022))" -ne 0 ]; then
      echo_error "权限不安全：$path；请先修复属主/组或其他人可写权限。此次检查不会修改文件。"; return 1
    fi
  done
  command -v ssh-keygen >/dev/null 2>&1 || { echo_error "缺少 ssh-keygen，无法验证公钥。"; return 1; }
  ssh-keygen -l -f "$auth_file" >/dev/null 2>&1 || { echo_error "未检测到可解析的 SSH 公钥。"; return 1; }
}

toggle_password_login() {
  ui_title "密码登录开关"
  ui_option 1 "开启密码登录"
  ui_option 2 "关闭密码登录（先检查 authorized_keys，默认取消）"
  ui_back
  local opt user backup_dir
  ui_prompt opt || return 0
  case "$opt" in
    1)
      backup_dir="$(make_backup_dir ssh-passwd-on)" || return 1
      backup_ssh_tree "$backup_dir" || return 1
      set_sshd_kv_effective "PasswordAuthentication" "yes" || { restore_ssh_tree "$backup_dir" || true; return 1; }
      set_sshd_kv_effective "KbdInteractiveAuthentication" "yes" || { restore_ssh_tree "$backup_dir" || true; return 1; }
      ssh_apply_with_rollback "开启密码登录" "$backup_dir" "PasswordAuthentication=yes" "KbdInteractiveAuthentication=yes" "ChallengeResponseAuthentication=yes"
      ;;
    2)
      read -r -p "请输入已确认可用密钥登录的用户名（默认 root）: " user || return 0
      user="${user:-root}"
      check_authorized_keys_safe "$user" || return 1
      confirm_action "关闭密码登录可能导致无法登录。确认已经另开终端测试密钥登录成功？" "2" || { echo_warn "已取消。"; return 0; }
      backup_dir="$(make_backup_dir ssh-passwd-off)" || return 1
      backup_ssh_tree "$backup_dir" || return 1
      set_sshd_kv_effective "PasswordAuthentication" "no" || { restore_ssh_tree "$backup_dir" || true; return 1; }
      set_sshd_kv_effective "KbdInteractiveAuthentication" "no" || { restore_ssh_tree "$backup_dir" || true; return 1; }
      ssh_apply_with_rollback "关闭密码登录" "$backup_dir" "PasswordAuthentication=no" "KbdInteractiveAuthentication=no" "ChallengeResponseAuthentication=no"
      ;;
    0) return 0 ;;
    *) echo_error "无效选项"; return 1 ;;
  esac
}

ensure_sudo_for_user() {
  local user="${1:-}" group sudoers_file backup_dir
  [ -n "$user" ] || return 1
  id "$user" >/dev/null 2>&1 || { echo_error "用户不存在：$user"; return 1; }
  ensure_command sudo sudo || return 1
  if getent group sudo >/dev/null 2>&1; then group="sudo"; else group="wheel"; fi
  getent group "$group" >/dev/null 2>&1 || groupadd "$group" || return 1
  usermod -aG "$group" "$user" || return 1
  id -nG "$user" | tr ' ' '\n' | grep -qx "$group" || { echo_error "用户 $user 未能加入 $group 组。"; return 1; }
  mkdir -p /etc/sudoers.d || { echo_error "无法创建 /etc/sudoers.d。"; return 1; }
  sudoers_file="/etc/sudoers.d/99-server-toolkit-${group}"
  backup_dir="$(make_backup_dir sudoers)" || return 1
  backup_path_to_dir /etc/sudoers "$backup_dir" || return 1
  backup_path_to_dir /etc/sudoers.d "$backup_dir" || return 1
  if ! grep -RqsE "^%${group}[[:space:]]+ALL=" /etc/sudoers /etc/sudoers.d 2>/dev/null; then
    printf '%%%s ALL=(ALL:ALL) ALL\n' "$group" > "$sudoers_file" || {
      echo_error "写入 sudoers drop-in 失败，开始回滚。"
      restore_path_from_dir /etc/sudoers "$backup_dir" || true
      restore_path_from_dir /etc/sudoers.d "$backup_dir" || true
      return 1
    }
    chmod 440 "$sudoers_file" || { echo_error "设置 sudoers 权限失败，开始回滚。"; restore_path_from_dir /etc/sudoers.d "$backup_dir" || true; return 1; }
  fi
  if command -v visudo >/dev/null 2>&1 && ! visudo -cf /etc/sudoers >/dev/null 2>&1; then
    echo_error "sudoers 检测失败，开始回滚。"
    restore_path_from_dir /etc/sudoers "$backup_dir" || true
    if [ -d "$backup_dir/etc/sudoers.d" ]; then rm -rf /etc/sudoers.d; cp -a "$backup_dir/etc/sudoers.d" /etc/sudoers.d; fi
    return 1
  fi
  if su - "$user" -c 'sudo -n true' >/dev/null 2>&1; then
    echo_color "用户 $user 已加入 $group，且当前可无交互执行 sudo。"
  else
    echo_warn "用户 $user 已加入 $group；由于 sudo 需要密码，脚本无法无交互完成真实 sudo 验证。请另开终端执行：sudo -v"
  fi
}

create_or_configure_sudo_user() {
  local user="" pass="" pass2="" existed=0
  ui_title "创建 / 配置 sudo 用户"
  read -r -p "用户名（q 或回车取消）: " user || return 0
  [[ "$user" =~ ^[Qq]$ || -z "$user" ]] && return 0
  [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo_error "用户名无效。"; return 1; }
  if id "$user" >/dev/null 2>&1; then
    existed=1
    [ "$(id -u "$user")" != 0 ] || { echo_error "请使用专用的 root 密码管理功能。"; return 1; }
  fi
  read -r -s -p "新密码（输入不回显；回车取消）: " pass || return 0; echo
  [ -n "$pass" ] || return 0
  read -r -s -p "再次输入密码: " pass2 || return 0; echo
  [ "$pass" = "$pass2" ] || { echo_error "两次密码不一致，未创建或修改账号。"; return 1; }
  confirm_action "确认创建/更新用户 $user 的密码和 sudo 权限？不修改 root SSH。" || return 0
  ensure_command sudo sudo || return 1
  if [ "$existed" -eq 0 ]; then useradd -m -s /bin/bash "$user" || return 1; fi
  if ! printf '%s:%s\n' "$user" "$pass" | chpasswd; then
    pass=""; pass2=""
    echo_error "密码设置失败；如用户为新建，其账号已创建但未完成，请检查 $user。"; return 1
  fi
  pass=""; pass2=""
  ensure_sudo_for_user "$user" || return 1
  echo_color "用户 $user 已配置；请另开终端测试 SSH 和 sudo -v。"
}

disable_root_ssh_login() {
  local user group backup_dir passlogin has_key=0
  ui_title "关闭 root SSH 登录"
  read -r -p "请输入已验证可登录且可 sudo 的替代用户名: " user || return 0
  [ -n "$user" ] || { echo_warn "已取消。"; return 0; }
  id "$user" >/dev/null 2>&1 || { echo_error "用户不存在：$user"; return 1; }
  [ "$(id -u "$user")" != "0" ] || { echo_error "替代管理员不能是 root 或其他 UID 0 账号。"; return 1; }
  command -v sudo >/dev/null 2>&1 || { echo_error "未安装 sudo，拒绝关闭 root 登录。"; return 1; }
  sudo -l -U "$user" >/dev/null 2>&1 || { echo_error "sudo 无法确认该用户的授权，未关闭 root。"; return 1; }
  if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Eq '^(sudo|wheel)$'; then
    group="sudo/wheel"
  else
    echo_error "用户 $user 当前不在 sudo/wheel 组，拒绝关闭 root SSH 登录。"
    return 1
  fi
  check_authorized_keys_safe "$user" >/dev/null 2>&1 && has_key=1 || true
  passlogin="$(sshd_effective_config 2>/dev/null | awk '$1=="passwordauthentication"{print $2; exit}' || true)"
  if [ "$has_key" -eq 0 ] && [ "$passlogin" != "yes" ]; then
    echo_error "用户 $user 没有可验证的 authorized_keys，且 PasswordAuthentication 不是 yes；拒绝关闭 root。"
    return 1
  fi
  echo_info "替代管理员：$user（组检查：$group；密钥文件检查：$([ "$has_key" -eq 1 ] && echo 通过 || echo 未通过/依赖密码登录)）"
  confirm_action "确认你已经在另一个终端实际测试 $user 可以登录并执行 sudo？" "2" || return 0
  backup_dir="$(make_backup_dir ssh-root-off)" || return 1
  backup_ssh_tree "$backup_dir" || return 1
  set_sshd_kv_effective "PermitRootLogin" "no" || { restore_ssh_tree "$backup_dir" || true; return 1; }
  ssh_apply_with_rollback "关闭 root SSH 登录" "$backup_dir" "PermitRootLogin=no" || return 1
  echo_warn "root SSH 登录已关闭。请保持当前会话，直到再次确认 $user 登录和 sudo 正常。"
}

enable_root_ssh_login() {
  local backup_dir
  backup_dir="$(make_backup_dir ssh-root-on)" || return 1
  backup_ssh_tree "$backup_dir" || return 1
  set_sshd_kv_effective "PermitRootLogin" "yes" || { restore_ssh_tree "$backup_dir" || true; return 1; }
  ssh_apply_with_rollback "恢复 root SSH 登录" "$backup_dir" "PermitRootLogin=yes"
}

manage_root_login_user() {
  while true; do
    ui_title "sudo 用户 / root SSH 登录管理"
    ui_menu_note "创建管理员账号和关闭 root 是两个独立动作，避免中途取消时产生半完成状态。"
    ui_option 1 "创建 / 配置 sudo 用户（不修改 root SSH 登录）"
    ui_option 2 "关闭 root SSH 登录（要求先验证替代 sudo 用户）"
    ui_option 3 "恢复 root SSH 登录"
    ui_back
    local opt
    ui_prompt opt || return 0
    case "$opt" in
      1) create_or_configure_sudo_user; ui_action_pause ;;
      2) disable_root_ssh_login; ui_action_pause ;;
      3) enable_root_ssh_login; ui_action_pause ;;
      0) return 0 ;;
      *) echo_error "无效选项"; ui_action_pause ;;
    esac
  done
}

ssh_security_recommended() {
  local backup_dir
  backup_dir="$(make_backup_dir ssh-secure)" || return 1
  backup_ssh_tree "$backup_dir" || return 1
  echo_info "应用保守推荐配置：不禁用 root、不禁用密码、不改端口。"
  set_sshd_kv_effective "LoginGraceTime" "30" || { restore_ssh_tree "$backup_dir" || true; return 1; }
  set_sshd_kv_effective "MaxAuthTries" "3" || { restore_ssh_tree "$backup_dir" || true; return 1; }
  set_sshd_kv_effective "PermitEmptyPasswords" "no" || { restore_ssh_tree "$backup_dir" || true; return 1; }
  set_sshd_kv_effective "UseDNS" "no" || { restore_ssh_tree "$backup_dir" || true; return 1; }
  set_sshd_kv_effective "X11Forwarding" "no" || { restore_ssh_tree "$backup_dir" || true; return 1; }
  set_sshd_kv_effective "PermitUserEnvironment" "no" || { restore_ssh_tree "$backup_dir" || true; return 1; }
  set_sshd_kv_effective "ClientAliveInterval" "300" || { restore_ssh_tree "$backup_dir" || true; return 1; }
  set_sshd_kv_effective "ClientAliveCountMax" "2" || { restore_ssh_tree "$backup_dir" || true; return 1; }
  ssh_apply_with_rollback "SSH 保守增强" "$backup_dir"     "LoginGraceTime=30" "MaxAuthTries=3" "PermitEmptyPasswords=no" "UseDNS=no"     "X11Forwarding=no" "PermitUserEnvironment=no" "ClientAliveInterval=300" "ClientAliveCountMax=2"
}

ssh_security_custom() {
  # v2.7：逐项选择只保存在内存，直到“应用”才写配置；避免用户中途 Ctrl+C 后留下未 reload 但会在未来重启生效的半成品文件。
  local opt v a b backup_dir rc
  local max_auth="" grace="" empty_pass="" use_dns="" x11="" tcp_forward="" alive_interval="" alive_count=""
  local expectations=()
  while true; do
    ui_title "SSH 安全策略 · 逐项配置"
    ui_menu_note "当前选择只暂存在内存；选 9 才会备份、写入、sshd -t/sshd -T 验证并应用；0 直接放弃。"
    ui_option 1 "MaxAuthTries：${max_auth:-未修改}"
    ui_option 2 "LoginGraceTime：${grace:-未修改}"
    ui_option 3 "PermitEmptyPasswords：${empty_pass:-未修改}"
    ui_option 4 "UseDNS：${use_dns:-未修改}"
    ui_option 5 "X11Forwarding：${x11:-未修改}"
    ui_option 6 "AllowTcpForwarding：${tcp_forward:-未修改}"
    ui_option 7 "ClientAlive：${alive_interval:-未修改}/${alive_count:-未修改}"
    ui_option 8 "查看当前 SSH 生效配置"
    ui_option 9 "检测并应用以上暂存修改"
    ui_back
    ui_prompt opt || return 0
    case "$opt" in
      1)
        read -r -p "MaxAuthTries（建议 3）: " v || return 0
        [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ] && [ "$v" -le 100 ] && max_auth="$v" || echo_error "请输入 1-100 的整数。"
        ;;
      2)
        read -r -p "LoginGraceTime 秒数（建议 30）: " v || return 0
        [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -le 3600 ] && grace="$v" || echo_error "请输入 0-3600 的整数。"
        ;;
      3) empty_pass="no"; echo_info "已暂存：PermitEmptyPasswords=no" ;;
      4) use_dns="no"; echo_info "已暂存：UseDNS=no" ;;
      5) x11="no"; echo_info "已暂存：X11Forwarding=no" ;;
      6)
        read -r -p "AllowTcpForwarding 设置为 yes/no: " v || return 0
        case "$v" in yes|no) tcp_forward="$v" ;; *) echo_error "只能输入 yes 或 no" ;; esac
        ;;
      7)
        read -r -p "ClientAliveInterval（建议 300）: " a || return 0
        read -r -p "ClientAliveCountMax（建议 2）: " b || return 0
        if [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] && [ "$a" -le 86400 ] && [ "$b" -le 100 ]; then
          alive_interval="$a"; alive_count="$b"
        else
          echo_error "请输入合理的非负整数。"
        fi
        ;;
      8) show_ssh_effective_config; ui_action_pause ;;
      9)
        if [ -z "$max_auth$grace$empty_pass$use_dns$x11$tcp_forward$alive_interval$alive_count" ]; then
          echo_warn "尚未选择任何修改。"
          ui_action_pause
          continue
        fi
        backup_dir="$(make_backup_dir ssh-custom)" || return 1
        backup_ssh_tree "$backup_dir" || return 1
        expectations=()
        if [ -n "$max_auth" ]; then set_sshd_kv_effective MaxAuthTries "$max_auth" || { restore_ssh_tree "$backup_dir" || true; return 1; }; expectations+=("MaxAuthTries=$max_auth"); fi
        if [ -n "$grace" ]; then set_sshd_kv_effective LoginGraceTime "$grace" || { restore_ssh_tree "$backup_dir" || true; return 1; }; expectations+=("LoginGraceTime=$grace"); fi
        if [ -n "$empty_pass" ]; then set_sshd_kv_effective PermitEmptyPasswords "$empty_pass" || { restore_ssh_tree "$backup_dir" || true; return 1; }; expectations+=("PermitEmptyPasswords=$empty_pass"); fi
        if [ -n "$use_dns" ]; then set_sshd_kv_effective UseDNS "$use_dns" || { restore_ssh_tree "$backup_dir" || true; return 1; }; expectations+=("UseDNS=$use_dns"); fi
        if [ -n "$x11" ]; then set_sshd_kv_effective X11Forwarding "$x11" || { restore_ssh_tree "$backup_dir" || true; return 1; }; expectations+=("X11Forwarding=$x11"); fi
        if [ -n "$tcp_forward" ]; then set_sshd_kv_effective AllowTcpForwarding "$tcp_forward" || { restore_ssh_tree "$backup_dir" || true; return 1; }; expectations+=("AllowTcpForwarding=$tcp_forward"); fi
        if [ -n "$alive_interval" ]; then set_sshd_kv_effective ClientAliveInterval "$alive_interval" || { restore_ssh_tree "$backup_dir" || true; return 1; }; expectations+=("ClientAliveInterval=$alive_interval"); fi
        if [ -n "$alive_count" ]; then set_sshd_kv_effective ClientAliveCountMax "$alive_count" || { restore_ssh_tree "$backup_dir" || true; return 1; }; expectations+=("ClientAliveCountMax=$alive_count"); fi
        ssh_apply_with_rollback "SSH 逐项安全配置" "$backup_dir" "${expectations[@]+"${expectations[@]}"}"
        rc=$?
        return "$rc"
        ;;
      0) echo_info "已放弃本轮暂存修改；磁盘配置未发生变化。"; return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

configure_key_login() {
  while true; do
    ui_title "SSH 密钥登录配置"
    ui_option 1 "粘贴已有公钥并写入 authorized_keys"
    ui_option 2 "自动生成 ed25519 密钥对（默认不显示私钥）"
    ui_back
    local opt
    ui_prompt opt || return 0
    case "$opt" in
      1) configure_key_login_existing; pause_return ;;
      2) generate_key_login_and_output_private; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

secure_ssh() {
  [ -f /etc/ssh/sshd_config ] || { echo_error "找不到 /etc/ssh/sshd_config"; return 1; }
  while true; do
    ui_title "SSH 安全策略"
    ui_menu_note "这里只调整安全参数；端口、密码、密钥和 root/sudo 用户请使用主菜单 6。"
    ui_option 1 "查看当前 SSH 安全配置"
    ui_option 2 "一键保守增强（不禁 root、不禁密码、不改端口）"
    ui_option 3 "逐项调整安全参数并统一检测应用"
    ui_back
    local opt
    ui_prompt opt || return 0
    case "$opt" in
      1) show_ssh_effective_config; ui_action_pause ;;
      2) ssh_security_recommended; ui_action_pause ;;
      3) ssh_security_custom; ui_action_pause ;;
      0) return 0 ;;
      *) echo_error "无效选项"; ui_action_pause ;;
    esac
  done
}

change_ssh_port_password() {
  local opt=""
  while true; do
    ui_title "SSH 端口 / 密码 / 密钥 / root"
    ui_option 1 "查看当前 SSH 配置 / 连接端口"
    ui_option 2 "只修改 SSH 端口"
    ui_option 3 "只修改 root 密码"
    ui_option 4 "同时修改 SSH 端口和 root 密码"
    ui_option 5 "导入已有公钥"
    ui_option 6 "生成新的 SSH 密钥"
    ui_option 7 "开启 / 关闭密码登录"
    ui_option 8 "创建 / 配置 sudo 用户"
    ui_option 9 "关闭 root SSH 登录"
    ui_option 10 "恢复 root SSH 登录"
    ui_back
    ui_prompt opt || return 0
    case "$opt" in
      1) show_ssh_connection_summary ;;
      2) change_ssh_port_only ;;
      3) change_root_password_only ;;
      4) change_ssh_port_and_password_together ;;
      5) configure_key_login_existing ;;
      6) generate_key_login_and_output_private ;;
      7) toggle_password_login ;;
      8) create_or_configure_sudo_user ;;
      9) disable_root_ssh_login ;;
      10) enable_root_ssh_login ;;
      0) return 0 ;;
      *) echo_error "无效选项。" ;;
    esac
    ui_action_pause
  done
}

validate_ntp_servers() {
  local input="${1:-}" item="" count=0
  [ -n "$input" ] || return 1
  case "$input" in *$'\n'*|*$'\r'*) echo_error "NTP 源必须在同一行，用空格分隔。" >&2; return 1 ;; esac
  for item in $input; do
    [[ "$item" =~ ^[A-Za-z0-9_][A-Za-z0-9_.:-]*$ || "$item" =~ ^:[A-Fa-f0-9:]+$ ]] || return 1
    case "$item" in -*|*..*|*::*::*) return 1 ;; esac
    count=$((count+1))
    [ "$count" -le 16 ] || return 1
  done
  [ "$count" -gt 0 ]
}

show_timesync_diagnostics() {
  echo_info "时间同步诊断："
  timedatectl status 2>/dev/null || true
  timedatectl show-timesync --all 2>/dev/null || true
  systemd-analyze cat-config systemd/timesyncd.conf --tldr 2>/dev/null || true
  chronyc tracking 2>/dev/null || true
  chronyc sources -v 2>/dev/null || true
}

time_sync_can_set_clock() {
  if is_container_env; then echo_warn "检测到容器环境，长期时间同步应由宿主机管理。"; return 1; fi
  if ! has_cap_sys_time; then echo_warn "当前进程缺少 CAP_SYS_TIME，无法安全修改系统时钟。"; return 1; fi
  return 0
}

TIME_SYNC_STOPPED_SERVICES=""

time_sync_restore_stopped_clients() {
  local item="" svc="" enabled="" failed=0
  for item in ${TIME_SYNC_STOPPED_SERVICES:-}; do
    svc="${item%%:*}"; enabled="${item#*:}"
    if [ "$enabled" = enabled ]; then systemctl enable "$svc" || failed=1; fi
    systemctl start "$svc" || failed=1
  done
  TIME_SYNC_STOPPED_SERVICES=""
  [ "$failed" -eq 0 ] || echo_error "部分原时间客户端恢复失败，请查看服务状态。"
  return "$failed"
}

time_sync_stop_conflicting_clients() {
  local target="${1:-}" svc="" candidates="" enabled=""
  TIME_SYNC_STOPPED_SERVICES=""
  is_systemd_available || return 0
  case "$target" in timesyncd) candidates="chrony chronyd ntp ntpd" ;; chrony) candidates="systemd-timesyncd ntp ntpd" ;; *) return 1 ;; esac
  for svc in $candidates; do
    if systemctl is-active "$svc" >/dev/null 2>&1; then
      enabled="$(systemctl is-enabled "$svc" 2>/dev/null)" || enabled=disabled
      TIME_SYNC_STOPPED_SERVICES="$TIME_SYNC_STOPPED_SERVICES $svc:$enabled"
      echo_info "切换时间客户端，停用冲突服务：$svc"
      if ! systemctl disable --now "$svc"; then time_sync_restore_stopped_clients; return 1; fi
    fi
  done
}

time_sync_configure_timesyncd() {
  local ntp="${1:-}"
  local conf_dir="/etc/systemd/timesyncd.conf.d"
  local conf="${conf_dir}/server-toolkit.conf"
  local backup_dir existed=0
  validate_ntp_servers "$ntp" || return 1
  if ! is_systemd_available; then echo_warn "当前环境没有可用 systemd，无法配置 systemd-timesyncd。"; return 1; fi
  time_sync_can_set_clock || return 2
  command -v timedatectl >/dev/null 2>&1 || { echo_warn "未检测到 timedatectl。"; return 1; }
  if ! systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd\.service'; then pkg_install systemd-timesyncd || return 1; fi
  systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd\.service' || { echo_warn "未检测到 systemd-timesyncd.service。"; return 1; }
  [ -f "$conf" ] && existed=1
  backup_dir="$(make_backup_dir timesyncd)" || return 1
  if [ "$existed" -eq 1 ]; then
    backup_path_to_dir "$conf" "$backup_dir" || { echo_error "systemd-timesyncd 原配置备份失败，已中止。"; return 1; }
  fi
  time_sync_stop_conflicting_clients timesyncd || return 1
  mkdir -p "$conf_dir" || { time_sync_restore_stopped_clients; return 1; }
  if ! cat > "$conf" <<EOF_TS
# server-toolkit v2.8: systemd-timesyncd NTP
[Time]
NTP=$ntp
FallbackNTP=time.google.com time.cloudflare.com
EOF_TS
  then
    echo_error "systemd-timesyncd 配置写入失败，开始回滚。"
    if [ "$existed" -eq 1 ]; then restore_path_from_dir "$conf" "$backup_dir" || true; else rm -f "$conf"; fi
    time_sync_restore_stopped_clients
    return 1
  fi
  timedatectl set-ntp true >/dev/null 2>&1 || echo_warn "timedatectl set-ntp true 失败，继续尝试启动服务。"
  if ! systemctl enable --now systemd-timesyncd || ! systemctl restart systemd-timesyncd; then
    echo_error "systemd-timesyncd 启动/重启失败，回滚配置。"
    if [ "$existed" -eq 1 ]; then restore_path_from_dir "$conf" "$backup_dir" || true; else rm -f "$conf"; fi
    systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
    time_sync_restore_stopped_clients
    return 1
  fi
  if ! systemctl is-active systemd-timesyncd >/dev/null 2>&1; then
    echo_error "systemd-timesyncd 未处于 active，回滚配置。"
    if [ "$existed" -eq 1 ]; then restore_path_from_dir "$conf" "$backup_dir" || true; else rm -f "$conf"; fi
    time_sync_restore_stopped_clients
    return 1
  fi
  TIME_SYNC_STOPPED_SERVICES=""
  echo_color "已配置 systemd-timesyncd。"
  show_timesync_diagnostics
}

chrony_config_path() {
  parse_os_release
  if [ -f /etc/chrony/chrony.conf ]; then echo "/etc/chrony/chrony.conf"; return; fi
  if [ -f /etc/chrony.conf ]; then echo "/etc/chrony.conf"; return; fi
  if is_debian_like; then echo "/etc/chrony/chrony.conf"; else echo "/etc/chrony.conf"; fi
}

chrony_service_name() {
  if is_systemd_available && systemctl list-unit-files 2>/dev/null | grep -q '^chrony\.service'; then echo "chrony"; else echo "chronyd"; fi
}

time_sync_configure_chrony() {
  local ntp="${1:-}"
  local conf service line tmp backup_dir existed=0
  validate_ntp_servers "$ntp" || return 1
  time_sync_can_set_clock || return 2
  command -v chronyd >/dev/null 2>&1 || pkg_install chrony || return 1
  conf="$(chrony_config_path)"
  service="$(chrony_service_name)"
  mkdir -p "$(dirname "$conf")" || return 1
  [ -f "$conf" ] && existed=1
  backup_dir="$(make_backup_dir chrony)" || return 1
  if [ "$existed" -eq 1 ]; then
    backup_path_to_dir "$conf" "$backup_dir" || { echo_error "chrony 原配置备份失败，已中止。"; return 1; }
  fi
  time_sync_stop_conflicting_clients chrony || return 1
  tmp="$(mktemp /tmp/server-toolkit-chrony.XXXXXX)" || { time_sync_restore_stopped_clients; return 1; }
  if [ -f "$conf" ]; then
    sed '/server-toolkit v[0-9.]* BEGIN/,/server-toolkit v[0-9.]* END/d' "$conf" > "$tmp" || { rm -f "$tmp"; time_sync_restore_stopped_clients; return 1; }
  fi
  {
    cat "$tmp"
    echo
    echo "# server-toolkit v2.8 BEGIN"
    for line in $ntp; do printf 'server %s iburst\n' "$line"; done
    echo "makestep 1.0 3"
    echo "# server-toolkit v2.8 END"
  } > "$conf" || {
    rm -f "$tmp"
    if [ "$existed" -eq 1 ]; then restore_path_from_dir "$conf" "$backup_dir" || :; else rm -f "$conf"; fi
    time_sync_restore_stopped_clients; return 1
  }
  rm -f "$tmp"
  if ! chronyd -p -f "$conf" >"$backup_dir/chrony-test.log" 2>&1; then
    echo_error "chrony 配置检测失败，开始回滚：$backup_dir/chrony-test.log"
    if [ "$existed" -eq 1 ]; then restore_path_from_dir "$conf" "$backup_dir" || true; else rm -f "$conf"; fi
    time_sync_restore_stopped_clients
    return 1
  fi
  if ! service_enable_now "$service" || ! service_restart_safe "$service"; then
    echo_error "chrony 服务启动/重启失败，开始回滚。"
    if [ "$existed" -eq 1 ]; then restore_path_from_dir "$conf" "$backup_dir" || true; else rm -f "$conf"; fi
    service_restart_safe "$service" >/dev/null 2>&1 || true
    time_sync_restore_stopped_clients
    return 1
  fi
  TIME_SYNC_STOPPED_SERVICES=""
  echo_color "已配置 chrony：$conf"
  show_timesync_diagnostics
}

time_sync_one_shot_fallback() {
  local ntp="${1:-}" s first
  validate_ntp_servers "$ntp" || return 1
  time_sync_can_set_clock || { echo_warn "已跳过一次性校时，只显示当前时间状态。"; show_timesync_diagnostics; return 2; }
  first="$(printf '%s\n' "$ntp" | awk '{print $1}')"
  if command -v chronyd >/dev/null 2>&1; then
    echo_info "尝试 chronyd -q 一次性校时..."
    chronyd -q "server $first iburst" && return 0
  fi
  if command -v ntpdate >/dev/null 2>&1; then
    for s in $ntp; do ntpdate -u "$s" && return 0; done
  fi
  if command -v sntp >/dev/null 2>&1; then
    for s in $ntp; do sntp -S "$s" && return 0; done
  fi
  echo_warn "没有可用的一次性校时工具。可安装 chrony 后重试。"
  return 1
}

time_sync_prompt_ntp() {
  local outvar="${1:-}" custom defaults="time.google.com time.cloudflare.com"
  [ -n "$outvar" ] || return 1
  read -r -p "NTP 源 [直接回车使用默认：$defaults]: " custom || return 0
  custom="${custom:-$defaults}"
  validate_ntp_servers "$custom" || { echo_error "NTP 源格式无效，只允许域名/IP及空格分隔。"; return 1; }
  printf -v "$outvar" '%s' "$custom"
}

time_sync_apply_recommended() {
  local ntp="${1:-}" method
  [ -n "$ntp" ] || return 1
  time_sync_can_set_clock || { show_timesync_diagnostics; return 2; }
  if is_debian_like; then method="timesyncd"; else method="chrony"; fi
  echo_info "推荐策略：$(is_debian_like && echo 'Debian/Ubuntu → systemd-timesyncd 优先' || echo 'RedHat/Fedora/Amazon → chrony 优先')"
  if [ "$method" = "timesyncd" ]; then
    time_sync_configure_timesyncd "$ntp" || time_sync_configure_chrony "$ntp" || time_sync_one_shot_fallback "$ntp"
  else
    time_sync_configure_chrony "$ntp" || time_sync_configure_timesyncd "$ntp" || time_sync_one_shot_fallback "$ntp"
  fi
}

time_sync() {
  local opt ntp
  while true; do
    ui_title "时间同步管理"
    show_os_detected
    ui_menu_note "配置时会自动停用冲突的时间客户端；失败恢复原配置。默认 NTP 为 Google / Cloudflare。"
    ui_option 1 "查看当前同步状态"
    ui_option 2 "按发行版推荐策略配置（推荐）"
    ui_option 3 "强制配置 systemd-timesyncd"
    ui_option 4 "强制配置 chrony / chronyd"
    ui_option 5 "只执行一次性校时 fallback"
    ui_back
    ui_prompt opt || return 0
    case "$opt" in
      1) show_timesync_diagnostics; ui_action_pause ;;
      2)
        time_sync_prompt_ntp ntp && confirm_action "确认校时/配置 NTP（必要时安装组件并停用冲突客户端）？" && time_sync_apply_recommended "$ntp"
        ui_action_pause
        ;;
      3)
        time_sync_prompt_ntp ntp && confirm_action "确认校时/配置 NTP（必要时安装组件并停用冲突客户端）？" && { time_sync_configure_timesyncd "$ntp" || time_sync_one_shot_fallback "$ntp"; }
        ui_action_pause
        ;;
      4)
        time_sync_prompt_ntp ntp && confirm_action "确认校时/配置 NTP（必要时安装组件并停用冲突客户端）？" && { time_sync_configure_chrony "$ntp" || time_sync_one_shot_fallback "$ntp"; }
        ui_action_pause
        ;;
      5)
        time_sync_prompt_ntp ntp && confirm_action "确认校时/配置 NTP（必要时安装组件并停用冲突客户端）？" && time_sync_one_shot_fallback "$ntp"
        ui_action_pause
        ;;
      0) return 0 ;;
      *) echo_error "无效选项"; ui_action_pause ;;
    esac
  done
}

get_os_id() { parse_os_release; echo "$OS_ID"; }

get_os_codename() {
  parse_os_release
  if [ -n "$OS_VERSION_CODENAME" ]; then echo "$OS_VERSION_CODENAME"; return; fi
  case "$OS_ID:$OS_VERSION_ID" in
    debian:10*) echo "buster" ;;
    debian:11*) echo "bullseye" ;;
    debian:12*) echo "bookworm" ;;
    debian:13*) echo "trixie" ;;
    ubuntu:20.04*) echo "focal" ;;
    ubuntu:22.04*) echo "jammy" ;;
    ubuntu:24.04*) echo "noble" ;;
    ubuntu:26.04*) echo "resolute" ;;
    *) echo "" ;;
  esac
}

debian_components_by_codename() {
  local code="${1:-}"
  case "$code" in
    bookworm|trixie|forky|testing|stable|oldstable) echo "main contrib non-free non-free-firmware" ;;
    sid|unstable) echo "main contrib non-free non-free-firmware" ;;
    *) echo "main contrib non-free" ;;
  esac
}

apt_signed_by_line() {
  local os="${1:-}"
  if [ "$os" = "ubuntu" ] && [ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]; then
    echo "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg"
  elif [ "$os" = "debian" ] && [ -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
    echo "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg"
  fi
}

apt_backup_all() {
  local dir="${1:-}" path manifest
  [ -n "$dir" ] || return 1
  mkdir -p "$dir" || return 1
  manifest="$dir/.absent-paths"
  : > "$manifest" || return 1
  for path in /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/apt.conf.d; do
    if [ -e "$path" ]; then
      backup_path_to_dir "$path" "$dir" || return 1
    else
      printf '%s\n' "$path" >> "$manifest" || return 1
    fi
  done
}

apt_restore_all() {
  local dir="${1:-}" path="" failed=0
  [ -f "$dir/.absent-paths" ] || { echo_error "APT 备份清单缺失，未删除当前配置。"; return 1; }
  for path in /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/apt.conf.d; do
    if [ ! -e "$dir$path" ] && [ ! -L "$dir$path" ] && ! grep -qxF "$path" "$dir/.absent-paths"; then
      echo_error "APT 备份不完整：$path；未开始回滚。"; return 1
    fi
  done
  for path in /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/apt.conf.d; do
    if grep -qxF "$path" "$dir/.absent-paths"; then
      rm -rf -- "$path" || failed=1
    else
      restore_path_from_dir "$path" "$dir" || failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

apt_is_distribution_source_file() {
  local file="${1:-}"
  [ -f "$file" ] || return 1
  case "$(basename "$file")" in
    ubuntu.list|ubuntu.sources|debian.list|debian.sources|official*.list|official*.sources) return 0 ;;
  esac
  grep -Eqi '(archive\.ubuntu\.com|security\.ubuntu\.com|old-releases\.ubuntu\.com|deb\.debian\.org|security\.debian\.org|archive\.debian\.org|mirror\.google\.com/(linux/ubuntu|debian)|mirror\.yandex\.(ru|net)/(ubuntu|debian)|cloudflaremirrors\.com/(ubuntu|debian))' "$file"
}

apt_disable_conflicting_distro_sources() {
  local f="" tmp="" format=""
  mkdir -p /etc/apt/sources.list.d || return 1
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    format=list; [[ "$f" == *.sources ]] && format=sources
    tmp="$(mktemp "${f}.server-toolkit.XXXXXX")" || return 1
    if ! apt_filter_distribution_records "$f" "$tmp" "$format"; then
      rm -f "$tmp"; echo_error "源文件含混合 URIs 或无法解析：$f；中止自动替换并由调用者回滚。"; return 1
    fi
    cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
  done
}

apt_set_archive_mode() {
  local mode="${1:-normal}" conf="/etc/apt/apt.conf.d/99-server-toolkit-archive"
  mkdir -p /etc/apt/apt.conf.d || return 1
  if [ "$mode" = "archive" ]; then
    cat > "$conf" <<'EOF_ARCH'
Acquire::Check-Valid-Until "false";
EOF_ARCH
  else
    rm -f "$conf" || return 1
  fi
}

apt_suite_available() {
  local base="${1:-}" suite="${2:-}"
  [ -n "$base" ] && [ -n "$suite" ] || return 1
  curl_has_release "$base" "$suite"
}

apt_collect_suites() {
  local base="${1:-}" code="${2:-}" kind="${3:-base}" out="" candidate
  [ -n "$base" ] && [ -n "$code" ] || return 1
  case "$code" in sid|unstable) if [ "$kind" = base ]; then printf '%s\n' "$code"; fi; return 0 ;; esac
  if [ "$kind" = "base" ]; then
    out="$code"
    for candidate in "${code}-updates" "${code}-backports"; do
      apt_suite_available "$base" "$candidate" && out="$out $candidate"
    done
  else
    case "$code" in buster) candidate="buster/updates" ;; *) candidate="${code}-security" ;; esac
    apt_suite_available "$base" "$candidate" && out="$candidate"
  fi
  printf '%s\n' "$out"
}

write_debian_sources() { apt_write_managed_sources debian "$@"; }

write_ubuntu_sources() { apt_write_managed_sources ubuntu "$@"; }

apt_source_candidates() {
  local os="${1:-}"
  if [ "$os" = "ubuntu" ]; then
    cat <<'EOF_CAND'
official|官方源 archive.ubuntu.com|https://archive.ubuntu.com/ubuntu/|https://security.ubuntu.com/ubuntu/|normal
official-http|官方源 HTTP archive.ubuntu.com|http://archive.ubuntu.com/ubuntu/|http://security.ubuntu.com/ubuntu/|normal
google|Google 镜像 mirror.google.com|https://mirror.google.com/linux/ubuntu/|https://mirror.google.com/linux/ubuntu/|normal
cloudflare|Cloudflare Mirrors|https://cloudflaremirrors.com/ubuntu/|https://cloudflaremirrors.com/ubuntu/|normal
yandex|Yandex 镜像 mirror.yandex.ru|https://mirror.yandex.ru/ubuntu/|https://mirror.yandex.ru/ubuntu/|normal
old-releases|Ubuntu old-releases 旧发行版兜底|https://old-releases.ubuntu.com/ubuntu/|https://old-releases.ubuntu.com/ubuntu/|archive
EOF_CAND
  else
    cat <<'EOF_CAND'
official|官方源 deb.debian.org|https://deb.debian.org/debian/|https://security.debian.org/debian-security/|normal
official-http|官方源 HTTP deb.debian.org|http://deb.debian.org/debian/|http://security.debian.org/debian-security/|normal
google|Google 镜像 mirror.google.com/debian|https://mirror.google.com/debian/|https://security.debian.org/debian-security/|normal
cloudflare|Cloudflare Mirrors|https://cloudflaremirrors.com/debian/|https://security.debian.org/debian-security/|normal
yandex|Yandex 镜像 mirror.yandex.ru/debian|https://mirror.yandex.ru/debian/|https://mirror.yandex.ru/debian-security/|normal
archive|Debian archive 旧发行版兜底|https://archive.debian.org/debian/|https://archive.debian.org/debian-security/|archive
EOF_CAND
  fi
}

curl_has_release() {
  local base="${1:-}" suite="${2:-}" url tmp
  [ -n "$base" ] && [ -n "$suite" ] || return 1
  url="${base%/}/dists/${suite}/Release"
  if command -v curl >/dev/null 2>&1; then
    curl -fsI --connect-timeout 6 --max-time 15 "$url" >/dev/null 2>&1 || curl -fsL --connect-timeout 6 --max-time 20 "$url" -o /dev/null >/dev/null 2>&1
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q --spider --timeout=15 "$url" >/dev/null 2>&1
    return
  fi
  tmp="$(mktemp /tmp/server-toolkit-release.XXXXXX)" || return 1
  echo_warn "缺少 curl/wget，无法探测候选源：$url"
  rm -f "$tmp"
  return 1
}

apt_update_with_log() {
  local log="${1:-}" rc=0
  if [ -z "$log" ]; then log="$(mktemp /tmp/server-toolkit-apt-update.XXXXXX)" || return 1; fi
  [ ! -L "$log" ] || return 1
  (umask 077; : > "$log") || return 1
  LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -o APT::Update::Error-Mode=any update >"$log" 2>&1 || rc=$?
  # Older APT may ignore Error-Mode=any and return 0 after partial index failures.
  if [ "$rc" -eq 0 ] && grep -Eq '^(Err:|E:|W: Failed to fetch|W: Some index files failed)' "$log"; then rc=1; fi
  [ "$rc" -eq 0 ] || echo_error "APT 缓存更新失败；日志：$log"
  return "$rc"
}

apt_apply_source_profile() {
  local os="${1:-}" code="${2:-}" label="${3:-}" base="${4:-}" secbase="${5:-}" archive_mode="${6:-normal}" backup_dir log
  [ -n "$os" ] && [ -n "$code" ] && [ -n "$base" ] && [ -n "$secbase" ] || return 1
  backup_dir="$(make_backup_dir apt-source)" || return 1
  apt_backup_all "$backup_dir" || { echo_error "APT 配置完整备份失败，未进行改源。"; return 1; }
  log="$backup_dir/apt-update.log"
  echo_info "准备写入 APT 源：$label"
  if [ "$os" = "ubuntu" ]; then
    write_ubuntu_sources "$base" "$secbase" "$code" "$archive_mode"
  else
    write_debian_sources "$base" "$secbase" "$code" "$archive_mode"
  fi
  if [ "$?" -ne 0 ]; then
    echo_error "APT 源文件写入失败，开始回滚。"
    apt_restore_all "$backup_dir"
    return 1
  fi
  apt-get clean >/dev/null 2>&1 || true
  if apt_update_with_log "$log"; then
    echo_color "APT 源已修复/切换成功：$label"
    echo_info "备份目录：$backup_dir"
    return 0
  fi
  echo_error "apt-get update 失败，日志：$log"
  tail -n 30 "$log" 2>/dev/null || true
  echo_warn "开始回滚 APT 源配置。"
  apt_restore_all "$backup_dir" || { echo_error "APT 配置自动回滚失败，备份位于：$backup_dir"; return 1; }
  apt_update_with_log "$log.rollback" || echo_warn "回滚后 apt-get update 仍失败，请手动检查日志：$log.rollback"
  return 1
}

apt_try_auto_repair_sources() {
  local os="${1:-}" code="${2:-}" key label base secbase archive_mode
  while IFS='|' read -r key label base secbase archive_mode; do
    [ -n "$key" ] || continue
    if curl_has_release "$base" "$code"; then
      echo_color "检测可用：$label"
      apt_apply_source_profile "$os" "$code" "$label" "$base" "$secbase" "$archive_mode" && return 0
    else
      echo_dim "跳过不可用或不含当前发行版的源：$label"
    fi
  done <<EOF_AUTO
$(apt_source_candidates "$os")
EOF_AUTO
  return 1
}

apt_source_interactive_chooser() {
  local os code tmp idx key label base secbase archive_mode opt line
  is_debian_like || { echo_warn "当前不是 Debian/Ubuntu 系。"; return 0; }
  os="$(get_os_id)"; [ "$os" = "ubuntu" ] || os="debian"
  code="$(get_os_codename)"
  [ -n "$code" ] || { echo_error "无法识别系统代号。"; return 1; }
  tmp="$(mktemp /tmp/server-toolkit-apt-candidates.XXXXXX)" || return 1
  idx=1
  ui_title "APT 源池检测 / 切换"
  echo_info "系统识别：$os / $code"
  while IFS='|' read -r key label base secbase archive_mode; do
    [ -n "$key" ] || continue
    if curl_has_release "$base" "$code"; then
      printf '%s|%s|%s|%s|%s\n' "$idx" "$label" "$base" "$secbase" "$archive_mode" >> "$tmp"
      ui_option "$idx" "$label"
      idx=$((idx + 1))
    else
      echo_dim "  --   不可用/不含当前发行版：$label"
    fi
  done <<EOF_CHOICE
$(apt_source_candidates "$os")
EOF_CHOICE
  [ "$idx" -gt 1 ] || { rm -f "$tmp"; echo_error "未检测到可用候选源。"; return 1; }
  ui_back
  read -r -p "请选择要写入的源: " opt || return 0
  [ "$opt" = "0" ] && { rm -f "$tmp"; echo_warn "已取消。"; return 0; }
  [[ "$opt" =~ ^[0-9]+$ ]] || { rm -f "$tmp"; echo_error "输入无效。"; return 1; }
  line="$(awk -F'|' -v n="$opt" '$1==n{print; exit}' "$tmp")"
  rm -f "$tmp"
  [ -n "$line" ] || { echo_error "选项不存在。"; return 1; }
  IFS='|' read -r _ label base secbase archive_mode <<EOF_LINE
$line
EOF_LINE
  apt_apply_source_profile "$os" "$code" "$label" "$base" "$secbase" "$archive_mode"
}

show_apt_sources_current() {
  ui_title "当前 APT 源"
  [ -f /etc/apt/sources.list ] && { echo_info "/etc/apt/sources.list"; sed -n '1,180p' /etc/apt/sources.list; } || echo_warn "未找到 /etc/apt/sources.list"
  echo_info "/etc/apt/sources.list.d/"
  if ls /etc/apt/sources.list.d/* >/dev/null 2>&1; then
    local f
    for f in /etc/apt/sources.list.d/*; do [ -f "$f" ] || continue; echo_dim "----- $f -----"; sed -n '1,120p' "$f"; done
  else
    echo_warn "未发现 sources.list.d 条目。"
  fi
}

repair_apt_sources_auto() {
  local os code log_file rc
  is_debian_like || { echo_warn "当前不是 Debian/Ubuntu 系，跳过 APT 源修复。"; return 0; }
  os="$(get_os_id)"; [ "$os" = "ubuntu" ] || os="debian"
  code="$(get_os_codename)"
  [ -n "$code" ] || { echo_error "无法识别系统代号，无法自动换源。"; return 1; }
  log_file="/tmp/server-toolkit-apt-update.$(date +%s).log"
  ui_title "自动检测并修复 APT 源"
  echo_info "系统识别：$os / $code"
  if apt_update_with_log "$log_file"; then
    echo_color "当前 APT 源可正常 update，不需要修复。"
    if confirm_action "当前源正常。是否仍要检测并手动切换镜像？" "2"; then
      apt_source_interactive_chooser
      rc=$?
      return "$rc"
    fi
    echo_info "已保留当前 APT 源。"
    return 0
  fi
  echo_warn "当前 APT 源 update 失败，日志：$log_file"
  tail -n 25 "$log_file" 2>/dev/null || true
  echo_warn "将自动检测候选源并尝试修复；修改前会完整备份 /etc/apt。"
  apt_try_auto_repair_sources "$os" "$code" || { echo_error "自动修复 APT 源失败。"; return 1; }
}

rpm_check_repos() {
  ui_title "RPM 源检测"
  show_os_detected
  if is_rhel_subscription_os; then
    echo_warn "RHEL 官方源由 subscription-manager 管理，本脚本不强行改 redhat.repo。"
    command -v subscription-manager >/dev/null 2>&1 && subscription-manager status 2>/dev/null || true
  fi
  pkg_makecache
}

rpm_enable_crb_like() {
  parse_os_release
  if is_rhel_subscription_os; then
    echo_warn "RHEL 请使用 subscription-manager 管理 CodeReady Builder；本脚本不会修改 redhat.repo。"
    return 2
  fi
  if command -v dnf >/dev/null 2>&1; then
    if ! dnf config-manager --help >/dev/null 2>&1; then
      pkg_install dnf-plugins-core >/dev/null 2>&1 || { echo_warn "dnf-plugins-core 安装失败，无法使用 config-manager。"; return 1; }
    fi
    case "$OS_ID" in
      rocky|almalinux|ol|centos)
        if dnf config-manager --set-enabled crb >/dev/null 2>&1 || dnf config-manager --set-enabled powertools >/dev/null 2>&1; then
          echo_color "已启用 CRB/PowerTools 类仓库。"; return 0
        fi
        echo_warn "未能启用 CRB/PowerTools，可能该版本不需要或仓库名称不同。"; return 1
        ;;
      fedora) echo_info "Fedora 通常不需要 CRB。"; return 0 ;;
      amzn|amazon) echo_info "Amazon Linux 不使用 CRB。"; return 0 ;;
      *) echo_warn "当前发行版未定义 CRB 自动启用规则。"; return 2 ;;
    esac
  fi
  if command -v yum >/dev/null 2>&1; then
    if ! command -v yum-config-manager >/dev/null 2>&1; then
      pkg_install yum-utils >/dev/null 2>&1 || { echo_warn "yum-utils 安装失败，无法使用 yum-config-manager。"; return 1; }
    fi
    if yum-config-manager --enable extras >/dev/null 2>&1; then
      echo_color "已启用 extras 仓库。"
      return 0
    fi
    echo_warn "extras 仓库启用失败。"
    return 1
  fi
  echo_warn "未检测到可用的 DNF/YUM config-manager。"
  return 1
}

rpm_install_epel_safely() {
  parse_os_release
  if is_rhel_subscription_os; then
    echo_warn "RHEL 安装 EPEL 前请确认 subscription-manager 与 CodeReady Builder 状态；本脚本不会修改 redhat.repo。"
  fi
  case "$OS_ID" in
    fedora|amzn|amazon)
      echo_info "当前系统不使用传统 EPEL 安装流程，已安全跳过。"; return 0 ;;
  esac
  confirm_action "确认安装/启用 EPEL？" "2" || return 0
  rpm_enable_crb_like || echo_warn "CRB/PowerTools/Extras 未能自动启用，将继续尝试 EPEL，但稍后会验证缓存。"
  if ! pkg_install epel-release; then
    echo_error "epel-release 安装失败。"
    return 1
  fi
  pkg_makecache || { echo_error "EPEL 安装后软件源缓存刷新失败，请检查仓库配置。"; return 1; }
  echo_color "EPEL 已安装/启用并通过 makecache 检查。"
}

rpm_repair_repos() {
  while true; do
    ui_title "DNF / YUM 软件源管理"
    ui_menu_note "RHEL 仅检测 subscription-manager，不会强行修改 redhat.repo。"
    ui_option 1 "查看 / 检测当前仓库可用性（makecache）"
    ui_option 2 "启用 CRB / PowerTools / Extras 类仓库"
    ui_option 3 "安全安装 / 启用 EPEL"
    ui_back
    local opt
    ui_prompt opt || return 0
    case "$opt" in
      1) rpm_check_repos; ui_action_pause ;;
      2)
        if rpm_enable_crb_like; then pkg_makecache || echo_error "仓库启用后 makecache 失败。"; else echo_warn "仓库启用未完成，请根据上方提示检查。"; fi
        ui_action_pause
        ;;
      3) rpm_install_epel_safely; ui_action_pause ;;
      0) return 0 ;;
      *) echo_error "无效选项"; ui_action_pause ;;
    esac
  done
}

repair_sources_menu() {
  if is_debian_like; then
    while true; do
      ui_title "APT 软件源管理"
      ui_menu_note "先查看/检测；只有明确选择修复或切换时才会写入配置，失败自动回滚。"
      ui_option 1 "查看当前 APT 源"
      ui_option 2 "检测当前源；失败时自动修复"
      ui_option 3 "手动检测并选择镜像源"
      ui_back
      local opt
      ui_prompt opt || return 0
      case "$opt" in
        1) show_apt_sources_current; ui_action_pause ;;
        2) repair_apt_sources_auto; ui_action_pause ;;
        3) apt_source_interactive_chooser; ui_action_pause ;;
        0) return 0 ;;
        *) echo_error "无效选项"; ui_action_pause ;;
      esac
    done
  elif is_redhat_like; then
    rpm_repair_repos
  else
    echo_warn "当前系统暂不支持自动源修复。"
    ui_action_pause
  fi
}

fail2ban_backend_config() {
  local logpath
  if command -v journalctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    if ! python3 -c 'import systemd.journal' >/dev/null 2>&1; then
      echo_warn "journald 可用但缺少 Python systemd 模块，尝试安装 python3-systemd。" >&2
      pkg_install python3-systemd >/dev/null 2>&1 || true
    fi
    if python3 -c 'import systemd.journal' >/dev/null 2>&1; then
      echo "backend = systemd"
      return 0
    fi
  fi
  if is_redhat_like; then logpath="/var/log/secure"; else logpath="/var/log/auth.log"; fi
  if [ -r "$logpath" ]; then
    echo "backend = auto"
    echo "logpath = $logpath"
    return 0
  fi
  echo_error "既没有可用的 systemd backend，也没有可读取的认证日志 $logpath。请先安装/启用 rsyslog 或 python3-systemd。" >&2
  return 1
}

fail2ban_banaction() {
  local dir="/etc/fail2ban/action.d"
  if firewalld_active && [ -f "$dir/firewallcmd-ipset.conf" ]; then echo "firewallcmd-ipset"; return 0; fi
  if ufw_active && [ -f "$dir/ufw.conf" ]; then echo "ufw"; return 0; fi
  if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1 && [ -f "$dir/nftables-multiport.conf" ]; then echo "nftables-multiport"; return 0; fi
  if command -v iptables >/dev/null 2>&1 && [ -f "$dir/iptables-multiport.conf" ]; then echo "iptables-multiport"; return 0; fi
  # 不硬编码一个系统里可能不存在的 action；留空时让 Fail2Ban 使用发行版默认值，再由 fail2ban-server -t 验证。
  return 1
}

fail2ban_write_global_dropin() {
  local level="${1:-INFO}" file="/etc/fail2ban/fail2ban.d/server-toolkit.conf"
  case "$level" in CRITICAL|ERROR|WARNING|NOTICE|INFO|DEBUG) ;; *) echo_error "Fail2Ban 日志等级无效：$level"; return 1 ;; esac
  mkdir -p /etc/fail2ban/fail2ban.d || return 1
  cat > "$file" <<EOF_F2B_GLOBAL
# server-toolkit v2.8: global drop-in, does not overwrite fail2ban.local
[Definition]
allowipv6 = auto
loglevel = $level
EOF_F2B_GLOBAL
}

validate_fail2ban_ignoreip() {
  local input="${1:-}" item="" address="" prefix=""
  [ -z "$input" ] && return 0
  case "$input" in *$'\r'*|*$'\n'*) return 1 ;; esac
  input="${input//,/ }"
  for item in $input; do
    [[ "$item" =~ ^[0-9A-Fa-f:./]+$ ]] || return 1
    if command -v python3 >/dev/null 2>&1; then
      python3 -c 'import ipaddress,sys; ipaddress.ip_network(sys.argv[1],strict=False)' "$item" >/dev/null 2>&1 || return 1
    else
      address="${item%%/*}"
      if [[ "$address" == *:* ]]; then
        echo_error "没有 Python ipaddress，无法严格验证 IPv6 白名单，未写入配置。" >&2; return 1
      fi
      validate_ipv4_value "$address" || return 1
      if [[ "$item" == */* ]]; then
        prefix="${item#*/}"
        [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && [ "$((10#$prefix))" -le 32 ] || return 1
      fi
    fi
  done
  return 0
}

fail2ban_write_sshd_jail() {
  local ssh_ports="${1:-}" bantime="${2:-3600}" findtime="${3:-600}" maxretry="${4:-3}" ignoreip="${5:-}"
  local file="/etc/fail2ban/jail.d/server-toolkit-sshd.conf" backend banaction=""
  [ -n "$ssh_ports" ] || return 1
  fail2ban_validate_ports "$ssh_ports" || return 1
  ignoreip="${ignoreip//,/ }"
  validate_fail2ban_ignoreip "$ignoreip" || return 1
  backend="$(fail2ban_backend_config)" || return 1
  banaction="$(fail2ban_banaction 2>/dev/null || true)"
  mkdir -p /etc/fail2ban/jail.d || return 1
  {
    echo "# server-toolkit v2.8: sshd jail, does not overwrite jail.local"
    echo "[sshd]"
    echo "enabled = true"
    echo "port = $ssh_ports"
    echo "bantime = $bantime"
    echo "findtime = $findtime"
    echo "maxretry = $maxretry"
    echo "ignoreip = 127.0.0.1/8 ::1 $ignoreip"
    [ -n "$banaction" ] && echo "banaction = $banaction"
    printf '%s\n' "$backend"
  } > "$file" || return 1
}

fail2ban_validate_and_restart() {
  local test_log=""
  command -v fail2ban-server >/dev/null 2>&1 || { echo_error "未安装 fail2ban-server。"; return 1; }
  test_log="$(mktemp /tmp/server-toolkit-fail2ban-test.XXXXXX)" || return 1
  if ! fail2ban-server -t >"$test_log" 2>&1; then
    echo_error "Fail2Ban 配置检测失败；日志：$test_log"; cat "$test_log"; return 1
  fi
  if ! service_enable_now fail2ban || ! service_restart_safe fail2ban; then
    echo_error "Fail2Ban 服务启动失败；配置检测日志：$test_log"
    journalctl -u fail2ban -n 30 --no-pager 2>/dev/null || :
    return 1
  fi
  rm -f "$test_log"
}

fail2ban_restore_from_backup() {
  local backup_dir="${1:-}" restart_failed=0
  [ -n "$backup_dir" ] || return 1
  if [ -d "$backup_dir/etc/fail2ban" ]; then
    restore_path_from_dir /etc/fail2ban "$backup_dir" || return 1
  else
    rm -f /etc/fail2ban/jail.d/server-toolkit-sshd.conf || return 1
    rm -f /etc/fail2ban/fail2ban.d/server-toolkit.conf || return 1
  fi
  if command -v fail2ban-server >/dev/null 2>&1; then
    service_restart_safe fail2ban >/dev/null 2>&1 || restart_failed=1
  fi
  if [ "$restart_failed" -ne 0 ]; then
    echo_error "Fail2Ban 配置已回滚，但服务未能重新启动。请执行 fail2ban-server -t 并检查服务日志。"
    return 1
  fi
  return 0
}

setup_fail2ban_default() {
  ui_title "安装/配置 Fail2Ban"
  pkg_install fail2ban python3-systemd || pkg_install fail2ban || return 1
  local backup_dir ssh_ports
  backup_dir="$(make_backup_dir fail2ban)" || return 1
  backup_path_to_dir /etc/fail2ban "$backup_dir" || return 1
  ssh_ports="$(get_current_ssh_ports)"
  fail2ban_write_global_dropin INFO || { fail2ban_restore_from_backup "$backup_dir"; return 1; }
  fail2ban_write_sshd_jail "$ssh_ports" 3600 600 3 "" || { fail2ban_restore_from_backup "$backup_dir"; return 1; }
  if fail2ban_validate_and_restart; then
    echo_color "Fail2Ban 已配置完成，SSH 端口：$ssh_ports"
  else
    echo_error "Fail2Ban 启动失败，开始回滚。"
    fail2ban_restore_from_backup "$backup_dir"
    return 1
  fi
}

fail2ban_refresh_ssh_port_silent() {
  command -v fail2ban-server >/dev/null 2>&1 || return 0
  local file="/etc/fail2ban/jail.d/server-toolkit-sshd.conf" backup_dir ssh_ports tmp
  [ -f "$file" ] || { echo_warn "没有 toolkit SSH jail；未改动你自行维护的 Fail2Ban。请检查其端口设置。"; return 2; }
  backup_dir="$(make_backup_dir fail2ban-port)" || return 1
  backup_path_to_dir /etc/fail2ban "$backup_dir" || return 1
  ssh_ports="$(sshd_effective_config | awk '$1=="port"{print $2}' | sort -nu | paste -sd, -)"
  fail2ban_validate_ports "$ssh_ports" || return 1
  tmp="$(mktemp /tmp/server-toolkit-f2b-port.XXXXXX)" || return 1
  awk -v p="$ssh_ports" 'BEGIN{done=0} /^[[:space:]]*port[[:space:]]*=/{if(!done){print "port = " p; done=1}; next} {print} END{if(!done) print "port = " p}' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file" || { rm -f "$tmp"; fail2ban_restore_from_backup "$backup_dir"; return 1; }
  fail2ban_validate_and_restart || { fail2ban_restore_from_backup "$backup_dir"; return 1; }
}

fail2ban_refresh_ssh_port() { fail2ban_refresh_ssh_port_silent && echo_color "已刷新 Fail2Ban SSH 端口：$(get_current_ssh_ports)"; }
fail2ban_status() { systemctl status fail2ban --no-pager -l 2>/dev/null || service fail2ban status 2>/dev/null || true; fail2ban-client status 2>/dev/null || true; }
fail2ban_recent_logs() { journalctl -u fail2ban -n 80 --no-pager 2>/dev/null || tail -n 80 /var/log/fail2ban.log 2>/dev/null || echo_warn "未找到 Fail2Ban 日志。"; }
fail2ban_show_banned() { fail2ban-client status sshd 2>/dev/null || { echo_warn "sshd jail 未运行。"; return 1; }; }

fail2ban_set_loglevel() {
  local level backup_dir
  echo "可选等级：CRITICAL / ERROR / WARNING / NOTICE / INFO / DEBUG"
  read -r -p "请输入日志等级（默认 INFO）: " level || return 0
  level="${level:-INFO}"
  case "$level" in CRITICAL|ERROR|WARNING|NOTICE|INFO|DEBUG) ;; *) echo_error "日志等级无效。"; return 1 ;; esac
  backup_dir="$(make_backup_dir fail2ban-loglevel)" || return 1
  backup_path_to_dir /etc/fail2ban "$backup_dir" || return 1
  fail2ban_write_global_dropin "$level" || { fail2ban_restore_from_backup "$backup_dir"; return 1; }
  fail2ban_validate_and_restart || { fail2ban_restore_from_backup "$backup_dir"; return 1; }
  echo_color "Fail2Ban 日志等级已设置为：$level"
}

fail2ban_unban_ip() {
  local ip=""
  read -r -p "请输入要解封的单个 IP（回车取消）: " ip || return 0
  [ -n "$ip" ] || return 0
  [[ "$ip" != *[[:space:]/,]* ]] && validate_fail2ban_ignoreip "$ip" || { echo_error "IP 格式无效。"; return 1; }
  if fail2ban-client set sshd unbanip "$ip"; then
    echo_color "解封请求已提交：$ip"
  else
    echo_error "解封失败，请检查 sshd jail 和 Fail2Ban 状态。"; return 1
  fi
}

fail2ban_validate_ports() {
  local ports="${1:-}" p
  [[ "$ports" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
  for p in ${ports//,/ }; do
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1
  done
}

fail2ban_config_jail() {
  local ssh_ports custom_ports bantime findtime maxretry ignoreip backup_dir
  ssh_ports="$(get_current_ssh_ports)"
  echo_info "自动识别 SSH 端口：$ssh_ports"
  read -r -p "手动覆盖端口？回车使用自动识别，示例 22,2222: " custom_ports || return 0
  [ -n "$custom_ports" ] && ssh_ports="$custom_ports"
  fail2ban_validate_ports "$ssh_ports" || { echo_error "端口格式或范围无效。"; return 1; }
  read -r -p "bantime 秒（默认 3600）: " bantime || return 0
  read -r -p "findtime 秒（默认 600）: " findtime || return 0
  read -r -p "maxretry（默认 3）: " maxretry || return 0
  read -r -p "ignoreip 白名单，可空: " ignoreip || return 0
  bantime="${bantime:-3600}"; findtime="${findtime:-600}"; maxretry="${maxretry:-3}"
  [[ "$bantime" =~ ^[0-9]+$ && "$findtime" =~ ^[0-9]+$ && "$maxretry" =~ ^[0-9]+$ ]] || { echo_error "参数必须是数字。"; return 1; }
  backup_dir="$(make_backup_dir fail2ban-config)" || return 1
  backup_path_to_dir /etc/fail2ban "$backup_dir" || return 1
  fail2ban_write_sshd_jail "$ssh_ports" "$bantime" "$findtime" "$maxretry" "$ignoreip" || { fail2ban_restore_from_backup "$backup_dir"; return 1; }
  fail2ban_validate_and_restart || { echo_error "配置失败，开始回滚。"; fail2ban_restore_from_backup "$backup_dir"; return 1; }
  echo_color "Fail2Ban jail 配置已更新。"
}

manage_fail2ban() {
  while true; do
    ui_title "Fail2Ban 管理"
    ui_menu_note "状态与日志放在前面；安装、同步和修改配置放在后面。server-toolkit 不覆盖 jail.local。"
    ui_option 1 "查看服务与 jail 总览"
    ui_option 2 "查看 sshd jail 与 banned IP"
    ui_option 3 "查看最近 80 条日志"
    ui_option 4 "安装或写入默认 SSH 防护配置"
    ui_option 5 "同步当前 SSH 端口到 Fail2Ban"
    ui_option 6 "配置 sshd 防护参数"
    ui_option 7 "设置 Fail2Ban 日志等级"
    ui_option 8 "解封指定 IP"
    ui_back
    local opt
    ui_prompt opt || return 0
    case "$opt" in
      1) fail2ban_status; ui_action_pause ;;
      2) fail2ban_show_banned; ui_action_pause ;;
      3) fail2ban_recent_logs; ui_action_pause ;;
      4) setup_fail2ban_default; ui_action_pause ;;
      5) fail2ban_refresh_ssh_port; ui_action_pause ;;
      6) fail2ban_config_jail; ui_action_pause ;;
      7) fail2ban_set_loglevel; ui_action_pause ;;
      8) fail2ban_unban_ip; ui_action_pause ;;
      0) return 0 ;;
      *) echo_error "无效选项"; ui_action_pause ;;
    esac
  done
}

sysctl_key_exists() { local key="${1:-}"; [ -n "$key" ] && sysctl -n "$key" >/dev/null 2>&1; }

grub_file_detect() { [ -f /etc/default/grub ] && echo "/etc/default/grub" || echo ""; }

grub_cmdline_remove_param() {
  local file="${1:-}" param="${2:-}" tmp escaped
  [ -n "$file" ] && [ -n "$param" ] && [ -f "$file" ] || return 0
  escaped="$(printf '%s' "$param" | sed 's/[][\\.^$*+?{}|()]/\\\\&/g')"
  tmp="$(mktemp /tmp/server-toolkit-grub.XXXXXX)" || return 1
  awk -v param="$escaped" '
    /^GRUB_CMDLINE_LINUX=/ {
      line=$0
      gsub(param "=[^ \" ]+ ?", "", line)
      gsub(param " ?", "", line)
      gsub(/  +/, " ", line)
      gsub(/=\" /, "=\"", line)
      print line
      next
    }
    {print}
  ' "$file" > "$tmp" && cat "$tmp" > "$file"
  local rc=$?
  rm -f "$tmp"
  return "$rc"
}

grub_cmdline_add_param() {
  local file="${1:-}" param="${2:-}"
  [ -n "$file" ] && [ -n "$param" ] && [ -f "$file" ] || return 0
  grep -Fq "$param" "$file" && return 0
  if grep -q '^GRUB_CMDLINE_LINUX=' "$file"; then
    sed -i -E "s/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"${param} /" "$file"
  else
    printf 'GRUB_CMDLINE_LINUX="%s"\n' "$param" >> "$file"
  fi
}

update_grub_ipv6_param() {
  local mode="${1:-}" file original="" rc=0
  if is_container_env; then echo_warn "检测到容器环境，跳过 GRUB 修改。"; return 0; fi
  file="$(grub_file_detect)"
  if [ -n "$file" ]; then
    original="$(mktemp /tmp/server-toolkit-grub.XXXXXX)" || return 1
    cp -a "$file" "$original" || { rm -f "$original"; return 1; }
    backup_file "$file" || { rm -f "$original"; return 1; }
    if [ "$mode" = "disable" ]; then
      grub_cmdline_add_param "$file" "ipv6.disable=1" || rc=1
    else
      grub_cmdline_remove_param "$file" "ipv6.disable" || rc=1
    fi
    if [ "$rc" -ne 0 ]; then
      cp -a "$original" "$file" || true
      rm -f "$original"
      echo_error "GRUB 参数文件修改失败，已恢复原文件。"
      return 1
    fi
  elif ! command -v grubby >/dev/null 2>&1; then
    echo_warn "未找到 /etc/default/grub 或 grubby，跳过 GRUB 修改。"
    return 0
  fi
  if command -v grubby >/dev/null 2>&1; then
    if [ "$mode" = "disable" ]; then grubby --update-kernel=ALL --args="ipv6.disable=1" || rc=1; else grubby --update-kernel=ALL --remove-args="ipv6.disable=1" || rc=1; fi
  elif command -v update-grub >/dev/null 2>&1; then
    update-grub || rc=1
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    if [ -f /boot/grub2/grub.cfg ] || [ -d /boot/grub2 ]; then grub2-mkconfig -o /boot/grub2/grub.cfg || rc=1
    elif [ -f /boot/grub/grub.cfg ] || [ -d /boot/grub ]; then grub2-mkconfig -o /boot/grub/grub.cfg || rc=1
    else echo_warn "未找到标准 grub.cfg；为避免破坏 UEFI vendor stub，未执行。"; rc=1; fi
  else
    echo_warn "未检测到 update-grub/grub2-mkconfig/grubby。"
    rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    [ -n "$file" ] && [ -n "$original" ] && cp -a "$original" "$file"
    echo_error "GRUB 更新失败，已恢复可恢复的配置文件。"
    [ -n "$original" ] && rm -f "$original"
    return 1
  fi
  [ -n "$original" ] && rm -f "$original"
  return 0
}

show_ipv6_status() {
  ui_title "IPv6 状态"
  sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null || true
  sysctl net.ipv6.conf.default.disable_ipv6 2>/dev/null || true
  sysctl net.ipv6.conf.lo.disable_ipv6 2>/dev/null || true
  ip -6 addr 2>/dev/null || echo_warn "ip 命令不可用或无 IPv6 地址。"
  grep -n 'ipv6.disable' /etc/default/grub 2>/dev/null || echo_info "未发现 GRUB ipv6.disable 参数。"
}

manage_ipv6() {
  local conf="/etc/sysctl.d/99-server-toolkit-ipv6.conf" opt backup_dir
  while true; do
    ui_title "IPv6 管理"
    ui_menu_note "先查看状态；开启/关闭会修改 sysctl，非容器环境还会安全更新 GRUB 参数。"
    ui_option 1 "查看 IPv6 当前状态"
    ui_option 2 "开启 IPv6"
    ui_option 3 "关闭 IPv6（高风险，默认取消）"
    ui_back
    ui_prompt opt || return 0
    case "$opt" in
      1) show_ipv6_status; ui_action_pause ;;
      2)
        backup_dir="$(make_backup_dir ipv6-enable)" || { ui_action_pause; continue; }
        backup_path_to_dir "$conf" "$backup_dir" || { echo_error "IPv6 配置备份失败。"; ui_action_pause; continue; }
        if ! {
          echo "# server-toolkit v2.8: ipv6 enable"
          sysctl_key_exists net.ipv6.conf.all.disable_ipv6 && echo "net.ipv6.conf.all.disable_ipv6=0"
          sysctl_key_exists net.ipv6.conf.default.disable_ipv6 && echo "net.ipv6.conf.default.disable_ipv6=0"
          if sysctl_key_exists net.ipv6.conf.lo.disable_ipv6; then echo "net.ipv6.conf.lo.disable_ipv6=0"; fi
        } > "$conf"; then
          echo_error "IPv6 sysctl 配置写入失败，已中止。"
          rm -f "$conf"
          restore_path_from_dir "$conf" "$backup_dir" >/dev/null 2>&1 || true
          ui_action_pause; continue
        fi
        if ! update_grub_ipv6_param enable; then rm -f "$conf"; restore_path_from_dir "$conf" "$backup_dir" || true; ui_action_pause; continue; fi
        sysctl -p "$conf" || echo_warn "部分运行时 sysctl 未能应用，可能需要重启。"
        show_ipv6_status
        ui_action_pause
        ;;
      3)
        if [[ "${SSH_CONNECTION:-}" == *:* ]]; then
          echo_error "当前 SSH 会话使用 IPv6，拒绝直接关闭 IPv6。请从 IPv4 SSH 或云控制台操作。"; ui_action_pause; continue
        fi
        confirm_action "确认关闭 IPv6？此操作可能影响业务网络。" "2" || { echo_warn "已取消。"; ui_action_pause; continue; }
        backup_dir="$(make_backup_dir ipv6-disable)" || { ui_action_pause; continue; }
        backup_path_to_dir "$conf" "$backup_dir" || { echo_error "IPv6 配置备份失败。"; ui_action_pause; continue; }
        if ! {
          echo "# server-toolkit v2.8: ipv6 disable"
          sysctl_key_exists net.ipv6.conf.all.disable_ipv6 && echo "net.ipv6.conf.all.disable_ipv6=1"
          sysctl_key_exists net.ipv6.conf.default.disable_ipv6 && echo "net.ipv6.conf.default.disable_ipv6=1"
          if sysctl_key_exists net.ipv6.conf.lo.disable_ipv6; then echo "net.ipv6.conf.lo.disable_ipv6=1"; fi
        } > "$conf"; then
          echo_error "IPv6 sysctl 配置写入失败，已中止。"
          rm -f "$conf"
          restore_path_from_dir "$conf" "$backup_dir" >/dev/null 2>&1 || true
          ui_action_pause; continue
        fi
        if ! update_grub_ipv6_param disable; then rm -f "$conf"; restore_path_from_dir "$conf" "$backup_dir" || true; ui_action_pause; continue; fi
        sysctl -p "$conf" || echo_warn "部分运行时 sysctl 未能应用，可能需要重启。"
        show_ipv6_status
        ui_action_pause
        ;;
      0) return 0 ;;
      *) echo_error "无效选项"; ui_action_pause ;;
    esac
  done
}

format_bytes() {
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN{if(b>=1099511627776)printf "%.2fT",b/1099511627776;else if(b>=1073741824)printf "%.2fG",b/1073741824;else if(b>=1048576)printf "%.2fM",b/1048576;else if(b>=1024)printf "%.2fK",b/1024;else printf "%dB",b;}'
}

get_default_iface() {
  if command -v ip >/dev/null 2>&1; then
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
  fi
}

public_ip_detect() {
  local v4="" v6=""
  if command -v curl >/dev/null 2>&1; then
    v4="$(curl -4 -fsS --connect-timeout 4 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    v6="$(curl -6 -fsS --connect-timeout 4 --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
  fi
  printf 'IPv4=%s IPv6=%s' "${v4:-未知}" "${v6:-未知}"
}

show_system_info() {
  ui_title "服务器基本信息"
  local hostname osver kernel arch cpu_model cpu_cores cpu_freq loadavg mem_total mem_avail mem_used mem_pct swap_total swap_free swap_used swap_pct disk_used disk_total disk_pct iface rx tx algo qdisc dns uptime_sec days hours mins pub
  hostname="$(hostname 2>/dev/null || echo '-')"
  parse_os_release; osver="$OS_PRETTY_NAME"
  kernel="$(uname -r 2>/dev/null || echo '-')"
  arch="$(uname -m 2>/dev/null || echo '-')"
  cpu_model="$(awk -F: '/model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  [ -z "$cpu_model" ] && cpu_model="$(command -v lscpu >/dev/null 2>&1 && lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' || true)"
  cpu_cores="$(command -v nproc >/dev/null 2>&1 && nproc || echo '-')"
  cpu_freq="$(awk -F: '/cpu MHz/ {mhz=$2; gsub(/^[ \t]+/,"",mhz); printf "%.1f GHz", mhz/1000; exit}' /proc/cpuinfo 2>/dev/null || true)"; [ -n "$cpu_freq" ] || cpu_freq="-"
  loadavg="$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null || echo '-')"
  mem_total="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"; mem_avail="$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  [[ "$mem_total" =~ ^[0-9]+$ ]] || mem_total=0; [[ "$mem_avail" =~ ^[0-9]+$ ]] || mem_avail=0
  mem_used=$((mem_total-mem_avail)); [ "$mem_used" -lt 0 ] && mem_used=0
  mem_pct="$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{if(t>0)printf "%.2f",u/t*100;else printf "0"}')"
  swap_total="$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"; swap_free="$(awk '/SwapFree/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  [[ "$swap_total" =~ ^[0-9]+$ ]] || swap_total=0; [[ "$swap_free" =~ ^[0-9]+$ ]] || swap_free=0
  swap_used=$((swap_total-swap_free)); [ "$swap_used" -lt 0 ] && swap_used=0
  swap_pct="$(awk -v u="$swap_used" -v t="$swap_total" 'BEGIN{if(t>0)printf "%.0f",u/t*100;else printf "0"}')"
  disk_used="$(df -h / 2>/dev/null | awk 'NR==2{print $3}')"; disk_total="$(df -h / 2>/dev/null | awk 'NR==2{print $2}')"; disk_pct="$(df -h / 2>/dev/null | awk 'NR==2{print $5}')"
  iface="$(get_default_iface 2>/dev/null || true)"; [ -n "$iface" ] || iface="$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -n1 || true)"
  if [ -n "$iface" ] && [ -e "/sys/class/net/$iface/statistics/rx_bytes" ]; then rx="$(cat "/sys/class/net/$iface/statistics/rx_bytes")"; tx="$(cat "/sys/class/net/$iface/statistics/tx_bytes")"; else rx=0; tx=0; fi
  algo="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '-')"; qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '-')"
  dns="$(grep -E '^nameserver ' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd' ' -)"; [ -n "$dns" ] || dns="-"
  uptime_sec="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"; [[ "$uptime_sec" =~ ^[0-9]+$ ]] || uptime_sec=0
  days=$((uptime_sec/86400)); hours=$((uptime_sec%86400/3600)); mins=$((uptime_sec%3600/60)); pub="$(public_ip_detect)"
  ui_kv host "主机名" "$hostname"
  ui_kv linux "系统版本" "$osver"
  ui_kv kernel "Linux 内核" "$kernel"
  ui_kv arch "CPU 架构" "$arch"
  ui_kv cpu "CPU 型号" "${cpu_model:-未知}"
  ui_kv cores "CPU 核心/频率" "$cpu_cores / $cpu_freq"
  ui_kv load "系统负载" "$loadavg"
  ui_kv memory "物理内存" "$(awk -v k="$mem_used" 'BEGIN{printf "%.2fM",k/1024}') / $(awk -v k="$mem_total" 'BEGIN{printf "%.2fM",k/1024}') (${mem_pct}%)"
  ui_kv swap "Swap" "$(awk -v k="$swap_used" 'BEGIN{printf "%.0fM",k/1024}') / $(awk -v k="$swap_total" 'BEGIN{printf "%.0fM",k/1024}') (${swap_pct}%)"
  ui_kv disk "硬盘占用" "${disk_used:-未知} / ${disk_total:-未知} (${disk_pct:-未知})"
  ui_kv network "默认网卡" "${iface:-未知}"
  ui_kv receive "接收 / 发送" "$(format_bytes "$rx") / $(format_bytes "$tx")"
  ui_kv speed "网络算法" "$algo / $qdisc"
  ui_kv dns "DNS" "$dns"
  ui_kv world "公网地址" "$pub"
  ui_kv uptime "运行时长" "${days}天 ${hours}时 ${mins}分"
}

download_url_to_file() {
  local url="${1:-}" dest="${2:-}"
  [ -n "$url" ] && [ -n "$dest" ] || return 1
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 12 --max-time 240 --retry 2 --retry-delay 2 -A "server-toolkit/${SERVER_TOOLKIT_VERSION}" "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$dest" --timeout=30 --tries=3 --user-agent="server-toolkit/${SERVER_TOOLKIT_VERSION}" "$url"
  else
    return 1
  fi
}

download_shell_script_with_fallback() {
  local dest="${1:-}" name="${2:-远程脚本}" url="" part="" syntax_log=""
  [ "$#" -ge 3 ] && [ -n "$dest" ] || return 1
  shift 2
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    ensure_command curl curl || return 1
  fi
  part="$(mktemp "${dest}.download.XXXXXX")" || return 1
  syntax_log="${dest}.syntax.log"
  for url in "$@"; do
    [ -n "$url" ] || continue
    echo_info "下载：$url"
    : > "$part" || { rm -f "$part"; return 1; }
    if download_url_to_file "$url" "$part"; then
      if [ ! -s "$part" ] || [ "$(wc -c < "$part")" -lt 200 ]; then
        echo_warn "内容为空或过短，尝试备用地址。"; continue
      fi
      if head -n 5 "$part" | grep -Eqi '<!DOCTYPE|<html|Access Denied|Bad Gateway'; then
        echo_warn "下载到错误网页，尝试备用地址。"; continue
      fi
      if ! (umask 077; bash -n "$part" >"$syntax_log" 2>&1); then
        echo_warn "脚本语法检查未通过：$syntax_log"; continue
      fi
      chmod 600 "$part" && mv -f -- "$part" "$dest" || { rm -f "$part"; return 1; }
      DOWNLOADED_SCRIPT_URL="$url"
      printf '%s\n' "$url" >"${dest}.source" || return 1
      chmod 600 "${dest}.source" "$syntax_log" || return 1
      echo_color "$name 已下载并通过 bash -n。"
      return 0
    fi
    echo_warn "下载失败，尝试备用地址。"
  done
  rm -f -- "$part"
  echo_error "$name 下载失败；未执行。请检查 DNS、TLS 与出站网络。"
  return 1
}

run_remote_script_confirm() {
  local name="${1:-远程脚本}" workdir="" tmp="" opt="" rc=0
  local pipeline_status=()
  [ "$#" -ge 2 ] || return 1
  shift
  ui_title "$name"
  echo_warn "第三方脚本可能安装软件或修改系统；下载后选择 1 即确认执行，不再二次询问。"
  workdir="$(mktemp -d /tmp/server-toolkit-remote.XXXXXX)" || return 1
  tmp="$workdir/script.sh"
  if ! download_shell_script_with_fallback "$tmp" "$name" "$@"; then
    echo_info "下载诊断目录：$workdir"; return 1
  fi
  while true; do
    ui_option 1 "执行 $name（确认信任来源）"
    ui_option 2 "查看脚本前 120 行"
    ui_option 3 "保留脚本并返回"
    ui_option 0 "取消并删除临时文件（默认）"
    ui_prompt opt "请选择 [默认 0]" || opt=0
    case "${opt:-0}" in
      1)
        (umask 077; cd "$workdir" && bash "$tmp") 2>&1 | (umask 077; tee "$workdir/run.log")
        pipeline_status=("${PIPESTATUS[@]}")
        rc="${pipeline_status[0]:-1}"
        if [ "${pipeline_status[1]:-1}" -ne 0 ]; then echo_error "运行日志写入失败。"; [ "$rc" -ne 0 ] || rc=1; fi
        if [ "$rc" -eq 0 ]; then echo_color "$name 执行完成。"; else echo_error "$name 返回退出码 $rc。"; fi
        echo_info "脚本与日志保留在：$workdir"
        return "$rc" ;;
      2) sed -n '1,120p' "$tmp" ;;
      3) echo_info "已保留：$workdir"; return 0 ;;
      0) rm -rf -- "$workdir"; return 0 ;;
      *) echo_error "无效选项。" ;;
    esac
  done
}

check_media_unlock() {
  run_remote_script_confirm "流媒体解锁检测" \
    "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh" \
    "https://check.unlock.media"
}

yabs_test() {
  run_remote_script_confirm "YABS 测试" \
    "https://raw.githubusercontent.com/masonr/yet-another-bench-script/master/yabs.sh" \
    "https://yabs.sh"
}

check_ip_quality() {
  run_remote_script_confirm "IP 质量检测" \
    "https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh" \
    "https://IP.Check.Place"
}

apply_sysctl_if_exists() {
  local key="${1:-}" val="${2:-}" file="${3:-}"
  [ -n "$key" ] && [ -n "$val" ] && [ -n "$file" ] || return 1
  if sysctl_key_exists "$key"; then echo "$key=$val" >> "$file"; else echo_dim "跳过不存在的 sysctl：$key"; fi
}

apply_conservative_sysctl_hardening() {
  local conf="/etc/sysctl.d/98-server-toolkit-hardening.conf" tmp backup_dir existed=0
  [ -f "$conf" ] && existed=1
  backup_dir="$(make_backup_dir sysctl-hardening)" || return 1
  if [ "$existed" -eq 1 ]; then
    backup_path_to_dir "$conf" "$backup_dir" || { echo_error "原 sysctl 加固配置备份失败，已中止。"; return 1; }
  fi
  tmp="$(mktemp /tmp/server-toolkit-sysctl.XXXXXX)" || return 1
  echo "# server-toolkit v2.8: conservative hardening" > "$tmp"
  apply_sysctl_if_exists net.ipv4.tcp_syncookies 1 "$tmp"
  apply_sysctl_if_exists net.ipv4.conf.all.accept_redirects 0 "$tmp"
  apply_sysctl_if_exists net.ipv4.conf.default.accept_redirects 0 "$tmp"
  apply_sysctl_if_exists net.ipv4.conf.all.secure_redirects 0 "$tmp"
  apply_sysctl_if_exists net.ipv4.conf.default.secure_redirects 0 "$tmp"
  apply_sysctl_if_exists net.ipv4.conf.all.send_redirects 0 "$tmp"
  apply_sysctl_if_exists net.ipv4.conf.default.send_redirects 0 "$tmp"
  apply_sysctl_if_exists net.ipv4.conf.all.accept_source_route 0 "$tmp"
  apply_sysctl_if_exists net.ipv4.conf.default.accept_source_route 0 "$tmp"
  apply_sysctl_if_exists net.ipv4.icmp_echo_ignore_broadcasts 1 "$tmp"
  apply_sysctl_if_exists net.ipv4.icmp_ignore_bogus_error_responses 1 "$tmp"
  apply_sysctl_if_exists kernel.kptr_restrict 1 "$tmp"
  apply_sysctl_if_exists kernel.dmesg_restrict 1 "$tmp"
  apply_sysctl_if_exists fs.protected_hardlinks 1 "$tmp"
  apply_sysctl_if_exists fs.protected_symlinks 1 "$tmp"
  sysctl_snapshot_runtime "$tmp" "$backup_dir/runtime.before" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$conf" || { rm -f "$tmp"; return 1; }
  if ! sysctl -p "$conf"; then
    echo_error "sysctl 加固应用失败，开始恢复原配置及已修改的运行值。"
    sysctl -p "$backup_dir/runtime.before" || echo_error "部分运行值恢复失败，请检查备份：$backup_dir"
    if [ "$existed" -eq 1 ]; then restore_path_from_dir "$conf" "$backup_dir" || true; else rm -f "$conf"; fi
    return 1
  fi
  echo_color "保守 sysctl 加固已应用。"
}

toggle_unpriv_userns() {
  local conf="/etc/sysctl.d/97-server-toolkit-userns.conf" opt backup_dir existed=0 value
  ui_title "非特权 user namespace"
  if ! sysctl_key_exists kernel.unprivileged_userns_clone; then
    echo_warn "当前内核不存在 kernel.unprivileged_userns_clone，已安全跳过。"
    return 0
  fi
  echo_warn "关闭 unprivileged user namespace 可能影响 rootless Docker、Chrome、Snap、部分容器。"
  ui_option 1 "关闭（降低部分本地提权攻击面）"
  ui_option 2 "恢复开启"
  ui_back
  ui_prompt opt || return 0
  case "$opt" in 1) confirm_action "确认关闭？" "2" || return 0; value=0 ;; 2) value=1 ;; 0) return 0 ;; *) echo_error "无效选项"; return 1 ;; esac
  [ -f "$conf" ] && existed=1
  backup_dir="$(make_backup_dir userns)" || return 1
  if [ "$existed" -eq 1 ]; then
    backup_path_to_dir "$conf" "$backup_dir" || { echo_error "原 user namespace 配置备份失败，已中止。"; return 1; }
  fi
  printf 'kernel.unprivileged_userns_clone=%s\n' "$value" > "$conf" || return 1
  if ! sysctl -p "$conf"; then
    echo_error "user namespace sysctl 应用失败，开始回滚。"
    if [ "$existed" -eq 1 ]; then restore_path_from_dir "$conf" "$backup_dir" || true; else rm -f "$conf"; fi
    return 1
  fi
}

apply_regresshion_mitigation() {
  ui_title "CVE-2024-6387 / regreSSHion 临时缓解"
  echo_warn "正式修复应升级 OpenSSH 包；临时缓解只调整 sshd 登录窗口与并发，不替代升级。"
  confirm_action "确认应用临时缓解 LoginGraceTime=0 MaxStartups=10:30:60？" "2" || return 0
  local backup_dir
  backup_dir="$(make_backup_dir ssh-regresshion)" || return 1
  backup_ssh_tree "$backup_dir" || return 1
  set_sshd_kv_effective LoginGraceTime 0 || { restore_ssh_tree "$backup_dir" || true; return 1; }
  set_sshd_kv_effective MaxStartups "10:30:60" || { restore_ssh_tree "$backup_dir" || true; return 1; }
  ssh_apply_with_rollback "regreSSHion 临时缓解" "$backup_dir" "LoginGraceTime=0" "MaxStartups=10:30:60"
}

restore_regresshion_mitigation() {
  local backup_dir
  backup_dir="$(make_backup_dir ssh-regresshion-restore)" || return 1
  backup_ssh_tree "$backup_dir" || return 1
  set_sshd_kv_effective LoginGraceTime 30 || { restore_ssh_tree "$backup_dir" || true; return 1; }
  set_sshd_kv_effective MaxStartups "10:30:100" || { restore_ssh_tree "$backup_dir" || true; return 1; }
  ssh_apply_with_rollback "regreSSHion 缓解恢复" "$backup_dir" "LoginGraceTime=30" "MaxStartups=10:30:100"
}

apply_copy_fail_mitigation() {
  ui_title "CVE-2026-31431 / Copy Fail 临时缓解"
  echo_warn "正式修复应升级内核并重启；临时禁用 algif_aead/authencesn 只作为临时缓解，可能影响 IPsec/AF_ALG 加密相关功能。"
  uname -a || true
  lsmod 2>/dev/null | grep -E '^(algif_aead|authencesn)' || echo_info "当前未看到 algif_aead/authencesn 模块已加载。"
  confirm_action "确认写入临时禁用 algif_aead/authencesn 规则？" "2" || return 0
  local conf="/etc/modprobe.d/server-toolkit-copy-fail.conf"
  backup_file "$conf" || { echo_error "临时缓解配置备份失败，已中止。"; return 1; }
  cat > "$conf" <<'EOF_CF'
# server-toolkit v2.8: CVE-2026-31431 temporary mitigation
# 临时缓解不能替代升级内核；如使用 IPsec/AF_ALG 相关功能，启用前必须评估影响。
install algif_aead /bin/false
blacklist algif_aead
install authencesn /bin/false
blacklist authencesn
EOF_CF
  [ -s "$conf" ] || { echo_error "临时缓解配置写入失败。"; return 1; }
  modprobe -r algif_aead 2>/dev/null || true
  modprobe -r authencesn 2>/dev/null || true
  echo_color "已写入临时缓解。请尽快升级内核并重启。"
}

remove_copy_fail_mitigation() {
  local conf="/etc/modprobe.d/server-toolkit-copy-fail.conf"
  [ -f "$conf" ] || { echo_warn "未找到临时缓解文件。"; return 0; }
  backup_file "$conf" || { echo_error "临时缓解配置备份失败，未删除。"; return 1; }
  rm -f "$conf" || return 1
  echo_color "已移除 Copy Fail 临时缓解文件。"
}

show_vulnerability_status() {
  ui_title "加固状态查看"
  echo_info "OpenSSH 版本："; ssh -V 2>&1 || true; command -v sshd >/dev/null 2>&1 && sshd -V 2>&1 || true
  echo_info "内核版本：$(uname -r 2>/dev/null)"
  echo_info "regreSSHion 相关 SSH 生效项："; sshd_effective_config | grep -Ei '^(logingracetime|maxstartups) ' || true
  echo_info "Copy Fail 临时缓解："; [ -f /etc/modprobe.d/server-toolkit-copy-fail.conf ] && cat /etc/modprobe.d/server-toolkit-copy-fail.conf || echo "未启用。"
  echo_info "sysctl 加固文件："; [ -f /etc/sysctl.d/98-server-toolkit-hardening.conf ] && cat /etc/sysctl.d/98-server-toolkit-hardening.conf || echo "未启用。"
}

one_click_safe_hardening() {
  ui_title "一键保守加固"
  echo_warn "将依次应用保守 sysctl 加固 + SSH 保守增强；不会禁 root、不会禁密码、不会改端口；不包含 Copy Fail 临时缓解。"
  confirm_action "确认继续？" "2" || return 0
  apply_conservative_sysctl_hardening || { echo_error "sysctl 加固失败，已停止后续 SSH 修改。"; return 1; }
  ssh_security_recommended || { echo_error "SSH 保守增强失败，sysctl 已保持成功状态，可通过加固状态菜单查看。"; return 1; }
}

security_update_core_packages() {
  ui_title "安全更新核心包"
  echo_warn "生产环境建议先做快照/备份；OpenSSH、sudo、证书包升级可能触发服务重载。"
  confirm_action "确认执行核心包定向安全更新？" "2" || return 0
  pkg_makecache || return 1
  pkg_install openssh-server openssh-client sudo curl ca-certificates || return 1
  pkg_upgrade_packages openssh-server openssh-client sudo ca-certificates || return 1
  echo_color "核心包定向更新完成。"
}

server_hardening() {
  while true; do
    ui_title "服务器加固"
    ui_option 1 "查看当前加固与缓解状态"
    ui_option 2 "一键保守加固（sysctl + SSH 保守增强）"
    ui_option 3 "仅应用保守 sysctl 加固"
    ui_option 4 "安全更新核心软件包"
    ui_option 5 "应用 CVE-2024-6387 / regreSSHion 临时缓解"
    ui_option 6 "移除 regreSSHion 临时缓解"
    ui_option 7 "应用 CVE-2026-31431 / Copy Fail 临时缓解"
    ui_option 8 "移除 Copy Fail 临时缓解"
    ui_option 9 "关闭 / 恢复 unprivileged user namespace"
    ui_back
    local opt
    ui_prompt opt || return 0
    case "$opt" in
      1) show_vulnerability_status; ui_action_pause ;;
      2) one_click_safe_hardening; ui_action_pause ;;
      3) apply_conservative_sysctl_hardening; ui_action_pause ;;
      4) security_update_core_packages; ui_action_pause ;;
      5) apply_regresshion_mitigation; ui_action_pause ;;
      6) restore_regresshion_mitigation; ui_action_pause ;;
      7) apply_copy_fail_mitigation; ui_action_pause ;;
      8) remove_copy_fail_mitigation; ui_action_pause ;;
      9) toggle_unpriv_userns; ui_action_pause ;;
      0) return 0 ;;
      *) echo_error "无效选项"; ui_action_pause ;;
    esac
  done
}

openssh_security_upgrade() {
  echo_info "正在尝试定向升级/安装 OpenSSH 安全更新..."
  pkg_makecache || return 1
  pkg_install openssh-server openssh-client || return 1
  pkg_upgrade_packages openssh-server openssh-client || return 1
  test_sshd_config || { echo_error "OpenSSH 更新后 sshd -t 检测失败，请立即检查。"; return 1; }
  echo_color "OpenSSH 定向安全更新流程已完成。"
}

ensure_package_sources_ready() {
  if pkg_makecache; then return 0; fi
  echo_error "软件源不可用，已停止更新。请直接使用第 15 项的源修复后再更新；不会隐式改源。"
  return 1
}

new_server_basic_update() {
  echo_warn "保守更新：检查软件源 → 安装常用工具 → 定向升级 OpenSSH。不会自动执行全量 dist-upgrade。"
  confirm_action "确认执行保守更新？" "2" || { echo_warn "已取消。"; return 0; }
  ensure_package_sources_ready || return 1
  pkg_install wget curl sudo vim git unzip openssh-server openssh-client ca-certificates || return 1
  openssh_security_upgrade || return 1
}

new_server_full_update() {
  echo_warn "全量更新：检查软件源 → 全量升级 → autoremove → OpenSSH 检查。可能更新内核并影响生产业务。"
  echo_warn "生产环境建议先创建云快照或完整备份。"
  confirm_action "确认执行全量系统更新？" "2" || { echo_warn "已取消。"; return 0; }
  ensure_package_sources_ready || return 1
  pkg_full_upgrade || return 1
  openssh_security_upgrade || return 1
}

new_server_init_menu() {
  local opt=""
  while true; do
    ui_title "初始化 / 软件源 / 系统更新"
    show_os_detected
    ui_option 1 "只检测当前软件源"
    ui_option 2 "自动修复源（APT / DNF / YUM）"
    ui_option 3 "选择其他 APT 镜像源"
    ui_option 4 "保守更新：常用工具 + OpenSSH"
    ui_option 5 "全量系统更新（含自动移除无用依赖）"
    ui_option 6 "仅升级 / 修复 OpenSSH"
    ui_option 7 "查看源配置"
    ui_back
    ui_prompt opt || return 0
    case "$opt" in
      1) pkg_makecache ;;
      2)
        if is_debian_like; then
          confirm_action "确认自动修复发行版源？会备份原配置，验证失败时回滚。" && apt_try_auto_repair_sources "$(get_os_id)" "$(get_os_codename)"
        else rpm_repair_repos; fi
        ;;
      3)
        if is_debian_like; then apt_source_interactive_chooser "$(get_os_id)" "$(get_os_codename)"; else echo_warn "此选择器仅适用于 Debian/Ubuntu。"; fi
        ;;
      4) new_server_basic_update ;;
      5) new_server_full_update ;;
      6) confirm_action "确认升级 OpenSSH？建议先做快照，并保留当前 SSH 会话。" && openssh_security_upgrade ;;
      7) if is_debian_like; then show_apt_sources_current; else rpm_check_repos; fi ;;
      0) return 0 ;;
      *) echo_error "无效选项。" ;;
    esac
    ui_action_pause
  done
}

write_interval_guard_script() {
  local target="${1:-}" interval="${2:-}" command_line="${3:-}"
  local script state_dir state_file now
  [ -n "$target" ] && [[ "$interval" =~ ^[0-9]+$ ]] && [ -n "$command_line" ] || return 1
  case "$target" in periodic-reboot|nezha-agent-restart) ;; *) return 1 ;; esac
  [[ "$interval" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$interval))" -ge 1 ] && [ "$((10#$interval))" -le 720 ] || return 1
  interval="$((10#$interval))"
  state_dir="/var/lib/server-toolkit"
  state_file="${state_dir}/${target}.last"
  script="/usr/local/sbin/server-toolkit-${target}-guard"
  mkdir -p "$state_dir" || return 1
  chmod 700 "$state_dir" || return 1
  backup_file "$script" || return 1
  backup_file "$state_file" || return 1
  now="$(date +%s)"
  printf '%s\n' "$now" > "$state_file" || return 1
  cat > "$script" <<EOF_GUARD
#!/bin/bash
set -u
INTERVAL_SECONDS=$((interval * 3600))
STATE_FILE="$state_file"
NOW=\$(date +%s)
LAST=\$(cat "\$STATE_FILE" 2>/dev/null || echo "\$NOW")
case "\$LAST" in ''|*[!0-9]*) LAST="\$NOW" ;; esac
if [ \$((NOW - LAST)) -ge "\$INTERVAL_SECONDS" ]; then
  if $command_line; then
    printf '%s\\n' "\$NOW" > "\$STATE_FILE"
  else
    exit 1
  fi
fi
EOF_GUARD
  chmod 700 "$script" || { rm -f "$script"; return 1; }
  [ -s "$script" ] || { rm -f "$script"; return 1; }
  printf '%s\n' "$script"
}

setup_cron_reboot() {
  local interval=""
  read -r -p "每隔多少小时重启（1-720，回车取消）: " interval || return 0
  [ -n "$interval" ] || return 0
  [[ "$interval" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$interval))" -ge 1 ] && [ "$((10#$interval))" -le 720 ] || { echo_error "间隔无效。"; return 1; }
  confirm_action "确认每 $interval 小时重启系统？将安装/启用 cron（如需），业务应能自动恢复。" || return 0
  schedule_interval_task periodic-reboot "$interval" '# server-toolkit: reboot' 7 '/sbin/reboot'
}

show_cron_reboot_status() {
  ui_title "定时重启状态"
  crontab -l 2>/dev/null | grep -F '# server-toolkit: reboot' || echo_info "未配置 server-toolkit 定时重启任务。"
  [ -f /usr/local/sbin/server-toolkit-periodic-reboot-guard ] && sed -n '1,80p' /usr/local/sbin/server-toolkit-periodic-reboot-guard || true
}

remove_cron_reboot() {
  command -v crontab >/dev/null 2>&1 || { echo_info "crontab 未安装，无任务可移除。"; return 0; }
  confirm_action "确认移除本工具的定时重启任务？" || return 0
  cron_update_marker '# server-toolkit: reboot' '' || return 1
  rm -f /usr/local/sbin/server-toolkit-periodic-reboot-guard /var/lib/server-toolkit/periodic-reboot.last || return 1
  echo_color "定时重启已移除。"
}

manage_cron_reboot() {
  while true; do
    ui_title "定时重启管理"
    ui_menu_note "先查看当前任务；设置和移除都只操作 server-toolkit 自己的 marker，不覆盖其他 crontab。"
    ui_option 1 "查看当前定时重启任务"
    ui_option 2 "设置 / 更新定时重启"
    ui_option 3 "移除定时重启任务"
    ui_back
    local opt
    ui_prompt opt || return 0
    case "$opt" in
      1) show_cron_reboot_status; ui_action_pause ;;
      2) setup_cron_reboot; ui_action_pause ;;
      3) remove_cron_reboot; ui_action_pause ;;
      0) return 0 ;;
      *) echo_error "无效选项"; ui_action_pause ;;
    esac
  done
}

setup_nezha_agent_restart_cron() {
  local interval=""
  read -r -p "每隔多少小时重启 Agent（1-720，回车取消）: " interval || return 0
  [ -n "$interval" ] || return 0
  [[ "$interval" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$interval))" -ge 1 ] && [ "$((10#$interval))" -le 720 ] || return 1
  confirm_action "确认每 $interval 小时重启 nezha-agent？将安装/启用 cron（如需）。" || return 0
  schedule_interval_task nezha-agent-restart "$interval" '# server-toolkit: nezha-agent-restart' 13 'if [ -d /run/systemd/system ]; then systemctl restart nezha-agent; else service nezha-agent restart; fi'
}

remove_nezha_agent_restart_cron() {
  command -v crontab >/dev/null 2>&1 || { echo_info "crontab 未安装，无任务可移除。"; return 0; }
  confirm_action "确认移除本工具的 Agent 定期重启任务？" || return 0
  cron_update_marker '# server-toolkit: nezha-agent-restart' '' || return 1
  rm -f /usr/local/sbin/server-toolkit-nezha-agent-restart-guard /var/lib/server-toolkit/nezha-agent-restart.last || return 1
  echo_color "Agent 定期重启已移除。"
}

nezha_status() {
  ui_title "哪吒状态"
  if is_systemd_available; then
    ui_kv info "nezha-agent" "$(systemctl is-active nezha-agent 2>/dev/null || echo not-found/inactive)"
    ui_kv info "nezha-dashboard" "$(systemctl is-active nezha-dashboard 2>/dev/null || echo not-found/inactive)"
  else
    echo_warn "当前环境不是标准 systemd；仅检查进程。"
    pgrep -af 'nezha-agent|nezha-dashboard' 2>/dev/null || echo_info "未发现哪吒进程。"
  fi
  echo_info "Agent 定期重启任务："
  if command -v crontab >/dev/null 2>&1; then
    crontab -l 2>/dev/null | grep -F '# server-toolkit: nezha-agent-restart' || echo_dim "未配置 server-toolkit Agent 定期重启。"
  else
    echo_dim "crontab 不可用。"
  fi
}

restart_nezha_both() {
  local failed=0
  if service_restart_safe nezha-agent; then echo_color "nezha-agent 已重启。"; else echo_warn "nezha-agent 重启失败或服务不存在。"; failed=1; fi
  if service_restart_safe nezha-dashboard; then echo_color "nezha-dashboard 已重启。"; else echo_warn "nezha-dashboard 重启失败或服务不存在。"; failed=1; fi
  return "$failed"
}

manage_nezha() {
  while true; do
    ui_title "哪吒面板管理"
    ui_option 1 "查看 Agent / Dashboard / 定时任务状态"
    ui_option 2 "重启哪吒 Agent"
    ui_option 3 "重启哪吒 Dashboard"
    ui_option 4 "同时重启 Agent + Dashboard"
    ui_option 5 "设置定期重启 Agent"
    ui_option 6 "移除 Agent 定期重启任务"
    ui_option 7 "卸载哪吒面板 / 探针（高风险）"
    ui_back
    local opt
    ui_prompt opt || return 0
    case "$opt" in
      1) nezha_status; ui_action_pause ;;
      2) service_restart_safe nezha-agent && echo_color "nezha-agent 已重启。" || echo_warn "nezha-agent 重启失败或不存在。"; ui_action_pause ;;
      3) service_restart_safe nezha-dashboard && echo_color "nezha-dashboard 已重启。" || echo_warn "nezha-dashboard 重启失败或不存在。"; ui_action_pause ;;
      4) restart_nezha_both || true; ui_action_pause ;;
      5) setup_nezha_agent_restart_cron; ui_action_pause ;;
      6) remove_nezha_agent_restart_cron; ui_action_pause ;;
      7)
        echo_warn "此操作会删除 /opt/nezha /etc/nezha /var/log/nezha。"
        confirm_action "确认卸载哪吒面板/探针，删除 /opt/nezha、/etc/nezha、日志和服务文件？" "2" || { echo_warn "已取消。"; ui_action_pause; continue; }
        if is_systemd_available; then
          systemctl stop nezha-agent 2>/dev/null || true; systemctl stop nezha-dashboard 2>/dev/null || true
          systemctl disable nezha-agent 2>/dev/null || true; systemctl disable nezha-dashboard 2>/dev/null || true
        else
          service nezha-agent stop 2>/dev/null || true; service nezha-dashboard stop 2>/dev/null || true
        fi
        rm -f /etc/systemd/system/nezha-agent.service /etc/systemd/system/nezha-dashboard.service || echo_warn "部分 systemd service 文件删除失败。"
        if rm -rf /opt/nezha /etc/nezha /var/log/nezha; then
          echo_color "哪吒面板/探针目录已移除。"
        else
          echo_error "部分哪吒目录删除失败，请手动检查。"
        fi
        is_systemd_available && systemctl daemon-reload 2>/dev/null || true
        ui_action_pause
        ;;
      0) return 0 ;;
      *) echo_error "无效选项"; ui_action_pause ;;
    esac
  done
}

validate_simple_version() { [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]]; }
validate_hostname_value() { [[ "${1:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; }
validate_http_url() {
  local url="${1:-}" rest="" authority="" host="" port=""
  case "$url" in http://*|https://*) ;; *) return 1 ;; esac
  case "$url" in *[[:space:]]*|*\'*|*\"*|*\`*|*\$*|*\\*|*\;*|*\|*|*\<*|*\>*) return 1 ;; esac
  rest="${url#*://}"; authority="${rest%%/*}"; authority="${authority%%\?*}"; authority="${authority%%\#*}"
  [ -n "$authority" ] || return 1
  case "$authority" in
    \[*\]*)
      host="${authority#\[}"; host="${host%%\]*}"
      [[ "$host" =~ ^[A-Fa-f0-9:]+$ && "$host" == *:* ]] || return 1
      rest="${authority#*\]}"
      case "$rest" in '') ;; :*) port="${rest#:}"; normalize_port port || return 1 ;; *) return 1 ;; esac
      ;;
    *)
      host="${authority%%:*}"
      [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] || return 1
      if [ "$host" != "$authority" ]; then port="${authority#*:}"; normalize_port port || return 1; fi
      ;;
  esac
  return 0
}

validate_ipv4_value() {
  local ip="${1:-}" a="" b="" c="" d="" octet=""
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r a b c d <<< "$ip"
  for octet in "$a" "$b" "$c" "$d"; do
    [ "$((10#$octet))" -le 255 ] || return 1
    # Avoid ambiguous octal notation in downstream applications.
    [[ "$octet" == 0 || "$octet" != 0* ]] || return 1
  done
}

reinstall_choose_distro() {
  local opt="" version="" default=""
  ui_title "系统重装 · 选择目标系统"
  ui_option 1 "Debian"; ui_option 2 "Ubuntu"; ui_option 3 "CentOS / Stream"
  ui_option 4 "AlmaLinux"; ui_option 5 "Rocky Linux"; ui_option 6 "Fedora"
  ui_option 7 "Kali"; ui_option 8 "Alpine"; ui_option 9 "Windows"
  ui_option 10 "自定义 DD 镜像"; ui_back
  ui_prompt opt || return 1
  case "$opt" in
    1) REINSTALL_DISTRO_FLAG="-debian"; REINSTALL_TARGET_KIND="linux-native"; default=13 ;;
    2) REINSTALL_DISTRO_FLAG="-ubuntu"; REINSTALL_TARGET_KIND="dd-like"; default=24.04 ;;
    3) REINSTALL_DISTRO_FLAG="-centos"; REINSTALL_TARGET_KIND="linux-native"; default=9-stream ;;
    4) REINSTALL_DISTRO_FLAG="-almalinux"; REINSTALL_TARGET_KIND="linux-native"; default=9 ;;
    5) REINSTALL_DISTRO_FLAG="-rockylinux"; REINSTALL_TARGET_KIND="linux-native"; default=9 ;;
    6) REINSTALL_DISTRO_FLAG="-fedora"; REINSTALL_TARGET_KIND="linux-native"; default=43 ;;
    7) REINSTALL_DISTRO_FLAG="-kali"; REINSTALL_TARGET_KIND="linux-native"; default=rolling ;;
    8) REINSTALL_DISTRO_FLAG="-alpine"; REINSTALL_TARGET_KIND="dd-like"; default=edge ;;
    9) REINSTALL_DISTRO_FLAG="-windows"; REINSTALL_TARGET_KIND="windows"; default=2022 ;;
    10) REINSTALL_DISTRO_FLAG="-dd"; REINSTALL_TARGET_KIND="dd-like" ;;
    0|'') return 1 ;;
    *) echo_error "无效系统编号。"; return 1 ;;
  esac
  if [ "$REINSTALL_DISTRO_FLAG" = -dd ]; then
    read -r -p "完整 DD 镜像 URL（q 取消）: " version || return 1
    case "$version" in q|Q) return 1 ;; esac
    validate_http_url "$version" || { echo_error "镜像 URL 无效。"; return 1; }
  else
    read -r -p "系统版本 [默认 $default，q 取消]: " version || return 1
    case "$version" in q|Q) return 1 ;; esac
    version="${version:-$default}"
    validate_simple_version "$version" || { echo_error "版本参数含非法字符。"; return 1; }
  fi
  REINSTALL_VERSION="$version"
  if [ "$REINSTALL_DISTRO_FLAG" = -ubuntu ]; then
    case "$version" in 20.04|22.04|24.04) ;; *) echo_warn "上游 README 未明确列出 Ubuntu $version；保留你的输入，由上游检测支持情况。" ;; esac
  fi
}

reinstall_current_arch() {
  case "$(uname -m)" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; i386|i686) echo i386 ;; *) echo_error "未知 CPU 架构，请显式填写目标架构。" >&2; return 1 ;; esac
}

reinstall_collect_plan() {
  local arch="" port="" password="" hostname="" mirror="" timezone=""
  local network="" ip="" prefix="" gate="" dns="" ipv6="" f2b="" current_port="" win_lang=""
  REINSTALL_ARGS=(); REINSTALL_PASSWORD_SET=0; REINSTALL_PLAN_READY=0
  reinstall_choose_distro || return 1
  REINSTALL_ARGS+=("$REINSTALL_DISTRO_FLAG" "$REINSTALL_VERSION")
  read -r -p "架构 amd64/arm64/i386 [默认 $(reinstall_current_arch)]: " arch || return 1
  arch="${arch:-$(reinstall_current_arch)}"
  case "$arch" in amd64|arm64|i386) REINSTALL_ARGS+=("-architecture" "$arch") ;; *) echo_error "架构无效。"; return 1 ;; esac
  current_port="$(get_current_session_ssh_port 2>/dev/null)" || current_port=""
  [ -n "$current_port" ] || current_port="$(get_current_ssh_ports | cut -d, -f1)"
  if [ "$REINSTALL_TARGET_KIND" = windows ]; then
    read -r -p "Windows 语言 cn/en/jp [默认 en]: " win_lang || return 1
    win_lang="${win_lang:-en}"
    case "$win_lang" in cn|en|jp) REINSTALL_ARGS+=("-lang" "$win_lang") ;; *) echo_error "语言无效。"; return 1 ;; esac
    echo_warn "Windows 不支持 -port；远程桌面端口由镜像决定。"
  else
    read -r -p "新系统 SSH 端口 [默认 ${current_port:-22}]: " port || return 1
    port="${port:-${current_port:-22}}"
    normalize_port port || { echo_error "端口须为 1-65535。"; return 1; }
    REINSTALL_ARGS+=("-port" "$port")
  fi
  if [ "$REINSTALL_TARGET_KIND" = linux-native ]; then
    echo_info "新系统 root 密码仅输入一次，不回显；空输入取消。上游低内存 DD 模式可能不采用此密码。"
    read -r -s -p "新 root 密码: " password || { printf '\n'; return 1; }; printf '\n'
    [ -n "$password" ] || return 1
    case "$password" in *$'\r'*|*$'\n'*) echo_error "密码不能含换行。"; return 1 ;; esac
    REINSTALL_ARGS+=("-pwd" "$password"); REINSTALL_PASSWORD_SET=1
    password=""
    echo_warn "密码会短暂出现在上游进程参数中；安装日志/预置文件按敏感文件保护。"
  else
    echo_warn "上游说明此模式可能不支持 -pwd；不要求填写一个可能无效的密码。"
    echo_warn "请从云控制台登录，核对镜像凭据并立即修改默认密码。"
  fi
  # All optional settings remain in a single linear wizard, without nested menus.
  read -r -p "主机名 [回车用上游默认]: " hostname || return 1
  if [ -n "$hostname" ]; then validate_hostname_value "$hostname" || { echo_error "主机名无效。"; return 1; }; REINSTALL_ARGS+=("-hostname" "$hostname"); fi
  read -r -p "镜像站 URL [回车自动]: " mirror || return 1
  if [ -n "$mirror" ]; then validate_http_url "$mirror" || { echo_error "镜像地址无效。"; return 1; }; REINSTALL_ARGS+=("-mirror" "$mirror"); fi
  read -r -p "时区 [回车用上游默认，如 Asia/Shanghai]: " timezone || return 1
  if [ -n "$timezone" ]; then
    [[ "$timezone" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || { echo_error "时区格式无效。"; return 1; }
    REINSTALL_ARGS+=("-timezone" "$timezone")
  fi
  read -r -p "网络 [回车自动检测；1=强制 DHCP；2=填写静态 IPv4]: " network || return 1
  case "$network" in
    '') ;;
    1) REINSTALL_ARGS+=("--network" "dhcp") ;;
    2)
      read -r -p "IPv4: " ip || return 1
      read -r -p "CIDR 前缀长度（如 24）: " prefix || return 1
      read -r -p "IPv4 网关: " gate || return 1
      read -r -p "DNS IPv4: " dns || return 1
      validate_ipv4_value "$ip" && validate_ipv4_value "$gate" && validate_ipv4_value "$dns" || { echo_error "IPv4/网关/DNS 格式无效。"; return 1; }
      [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && [ "$((10#$prefix))" -le 32 ] || { echo_error "CIDR 前缀须为 0-32。"; return 1; }
      REINSTALL_ARGS+=("--network" "static" "--ip-addr" "$ip" "--ip-mask" "$((10#$prefix))" "--ip-gate" "$gate" "--ip-dns" "$dns") ;;
    *) echo_error "网络选项无效。"; return 1 ;;
  esac
  read -r -p "IPv6 [回车保留；0=禁用]: " ipv6 || return 1
  case "$ipv6" in ''|1) ;; 0) REINSTALL_ARGS+=("--setipv6" "0") ;; *) echo_error "IPv6 选项无效。"; return 1 ;; esac
  read -r -p "Fail2Ban [回车自动；1=启用；0=禁用]: " f2b || return 1
  case "$f2b" in '') ;; 0|1) REINSTALL_ARGS+=("--fail2ban" "$f2b") ;; *) echo_error "Fail2Ban 选项无效。"; return 1 ;; esac
  REINSTALL_PLAN_READY=1
}

reinstall_display_plan() {
  local arg="" hide=0
  [ "${REINSTALL_PLAN_READY:-0}" = 1 ] || { echo_warn "尚未配置重装参数。"; return 1; }
  printf 'bash InstallNET.sh'
  for arg in "${REINSTALL_ARGS[@]+"${REINSTALL_ARGS[@]}"}"; do
    if [ "$hide" -eq 1 ]; then printf ' %q' '********'; hide=0; continue; fi
    printf ' %q' "$arg"
    case "$arg" in -pwd|-password) hide=1 ;; esac
  done
  printf '\n'
}

reinstall_preflight() {
  # Read-only host checks; package installation happens only AFTER the user's single confirmation.
  if is_container_env; then echo_error "容器不能通过此功能重装宿主系统，已停止。"; return 1; fi
  if [ ! -d /boot ]; then echo_error "未找到 /boot，不能安全准备网络重装。"; return 1; fi
  if ! { [ -s /boot/grub/grub.cfg ] || [ -s /boot/grub2/grub.cfg ] || [ -s /boot/grub/grub.conf ] || [ -s /boot/grub2/grub.conf ] || [ -d /boot/efi/EFI ]; }; then
    echo_error "未识别可用 GRUB/EFI 启动配置；请从云控制台使用适配本机的重装方式。"; return 1
  fi
  command -v findmnt >/dev/null 2>&1 && findmnt -no SOURCE,FSTYPE / || :
  df -h / /boot 2>/dev/null || :
  echo_warn "重装会覆盖系统盘；准备过程也会修改引导和部分系统设置，不能保证自动撤销。"
  echo_warn "确认已有离机备份/快照、云控制台和新端口安全组放行。本工具不会自动 reboot。"
  return 0
}

reinstall_download_script() {
  local dest="${1:-}"
  [ -n "$dest" ] || return 1
  # Fallback defaults also protect sourced/test invocations from unset globals.
  download_shell_script_with_fallback "$dest" "InstallNET.sh" \
    "${REINSTALL_UPSTREAM_URL:-https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh}" \
    "${REINSTALL_UPSTREAM_URL_CN:-https://gitee.com/mb9e8j2/Tools/raw/master/Linux_reinstall/InstallNET.sh}" || return 1
  if ! grep -qE 'InstallNET|Relese=|targetRelese=' "$dest" || ! grep -q -- '-debian' "$dest"; then
    echo_error "下载内容不具备预期的 InstallNET 特征；保留文件供检查，未执行。"
    return 1
  fi
}

manage_system_reinstall() {
  local workdir="" rc=0
  # One linear workflow, one confirmation; no staging/menu/preview confirmation maze.
  REINSTALL_ARGS=(); REINSTALL_PLAN_READY=0; REINSTALL_PASSWORD_SET=0
  if ! reinstall_collect_plan; then
    REINSTALL_ARGS=(); REINSTALL_PLAN_READY=0
    echo_warn "已取消或参数无效，未执行重装。"
    return 0
  fi
  if ! reinstall_preflight; then REINSTALL_ARGS=(); REINSTALL_PLAN_READY=0; return 1; fi
  echo_info "即将执行的计划（密码已隐藏）："
  reinstall_display_plan
  if ! confirm_action "确认按上述参数准备重装？会改写引导并在你手动 reboot 后覆盖系统盘。"; then
    REINSTALL_ARGS=(); REINSTALL_PLAN_READY=0
    echo_warn "已取消，未下载或执行重装脚本。"; return 0
  fi
  workdir="$(reinstall_create_workdir)" || { REINSTALL_ARGS=(); REINSTALL_PLAN_READY=0; echo_error "无法创建可写且受保护的现场目录，已中止。"; return 1; }
  REINSTALL_LAST_WORKDIR="$workdir"
  echo_info "本次现场目录（已创建）：$workdir"
  if ! ensure_command wget wget; then
    printf 'dependency_failed\n' > "$workdir/status"
    REINSTALL_ARGS=(); REINSTALL_PLAN_READY=0
    echo_error "缺少上游依赖 wget；状态文件：$workdir/status"; return 1
  fi
  reinstall_execute_plan "$workdir"
  rc=$?
  REINSTALL_ARGS=(); REINSTALL_PLAN_READY=0; REINSTALL_PASSWORD_SET=0
  if [ -f "$workdir/install.log" ] && [ -f "$workdir/status" ]; then
    echo_info "实际保留文件："
    ls -lah "$workdir"
    echo_warn "目录可能包含密码/哈希/网络参数；顶层目录 700、日志 600。请勿公开上传。"
  else
    echo_error "现场目录不完整：$workdir（可能是磁盘错误或上游删除了文件）。"
    [ "$rc" -ne 0 ] || rc=1
  fi
  return "$rc"
}

print_menu() {
  local menu_symbol
  ui_clear
  printf '\n'
  ui_hr
  printf '%s  ' "$UI_MAGENTA"
  ui_icon title
  printf '  server-toolkit %s · Linux 服务器工具箱%s\n' "$SERVER_TOOLKIT_VERSION" "$UI_RESET"
  ui_hr
  menu_symbol="$(ui_symbol menu)"
  if [ -n "$menu_symbol" ]; then printf '%s  %s  功能菜单%s\n' "$UI_CYAN" "$menu_symbol" "$UI_RESET"; else printf '%s  功能菜单%s\n' "$UI_CYAN" "$UI_RESET"; fi
  printf '%s' "$UI_DIM"; ui_repeat "$UI_HR_CHAR" "$(ui_terminal_columns)"; printf '%s\n' "$UI_RESET"
  ui_main_row "$(ui_menu_label time 1 '时间同步')"               "$(ui_menu_label benchmark 9 'YABS 测试')"
  ui_main_row "$(ui_menu_label firewall 2 '防火墙管理')"        "$(ui_menu_label reboot 10 '定时重启管理')"
  ui_main_row "$(ui_menu_label selinux 3 'SELinux 管理')"       "$(ui_menu_label nezha 11 '哪吒面板管理')"
  ui_main_row "$(ui_menu_label ssh 4 'SSH 安全增强')"           "$(ui_menu_label world 12 'IP 质量检测')"
  ui_main_row "$(ui_menu_label ban 5 'Fail2Ban 管理')"          "$(ui_menu_label ipv6 13 'IPv6 开启/关闭')"
  ui_main_row "$(ui_menu_label key 6 'SSH 端口/密码/密钥/root')" "$(ui_menu_label harden 14 '服务器加固')"
  ui_main_row "$(ui_menu_label media 7 '流媒体解锁检测')"       "$(ui_menu_label package 15 '初始化/软件源修复')"
  ui_main_row "$(ui_menu_label info 8 '显示服务器信息')"        "$(ui_menu_label reinstall 16 '系统重装（高风险）')"
  ui_main_row ""                                                 "$(ui_menu_label exit 0 '退出')"
  printf '%s' "$UI_DIM"; ui_repeat "$UI_HR_CHAR" "$(ui_terminal_columns)"; printf '%s\n' "$UI_RESET"
}


normalize_port() {
  local _stk_port_var="${1:-}" _stk_port_value=""
  [[ "$_stk_port_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
  _stk_port_value="${!_stk_port_var-}"
  [[ "$_stk_port_value" =~ ^[0-9]{1,5}$ ]] || return 1
  _stk_port_value="$((10#$_stk_port_value))"
  [ "$_stk_port_value" -ge 1 ] && [ "$_stk_port_value" -le 65535 ] || return 1
  printf -v "$_stk_port_var" '%s' "$_stk_port_value"
}

reinstall_create_workdir() {
  local base="${REINSTALL_BASE_DIR:-/root/server-toolkit-reinstall}" dir=""
  [[ "$base" == /* && "$base" != / && ! -L "$base" ]] || return 1
  mkdir -p -- "$base" && chmod 700 "$base" || return 1
  dir="$(mktemp -d "$base/$(date +%F_%H-%M-%S).XXXXXX")" || return 1
  chmod 700 "$dir" || return 1
  (umask 077; : > "$dir/install.log"; : > "$dir/artifacts.tsv"; printf 'created\n' > "$dir/status") || return 1
  [ -f "$dir/install.log" ] && [ -f "$dir/status" ] || return 1
  printf '%s\n' "$dir"
}

reinstall_boot_paths() {
  printf '%s\n' /etc/default/grub /etc/grub.d /boot/grub/grub.cfg /boot/grub/grubenv \
    /boot/grub/grub.conf /boot/grub2/grub.cfg /boot/grub2/grubenv /boot/grub2/grub.conf \
    /boot/loader/entries /boot/efi/EFI
}

reinstall_snapshot_before() {
  local dir="${1:-}" path="" name=""
  [ -d "$dir" ] || return 1
  mkdir -p "$dir/before" || return 1
  : > "$dir/before-files.tsv" || return 1
  # Preserve relevant boot configuration; this is not a full system/disk backup.
  while IFS= read -r path; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      backup_path_to_dir "$path" "$dir/before" || return 1
      stat -Lc '%n\t%s\t%y\t%z' -- "$path" >> "$dir/before-files.tsv" || return 1
    fi
  done < <(reinstall_boot_paths)
  for path in /boot/vmlinuz /boot/initrd.img; do
    name="${path##*/}"
    if [ -f "$path" ]; then
      stat -Lc '%i|%s|%y|%z' -- "$path" > "$dir/before-${name}.stat" || return 1
      backup_path_to_dir "$path" "$dir/before" || return 1
    else
      printf 'absent\n' > "$dir/before-${name}.stat" || return 1
    fi
  done
  date +%s > "$dir/start-epoch"
}

reinstall_collect_artifacts() {
  local dir="${1:-}" path="" dest="" state="" failed=0
  [ -d "$dir" ] || return 1
  mkdir -p "$dir/artifacts" || return 1
  : > "$dir/artifacts.tsv" || return 1
  # Do not copy all of /tmp/boot (it is an unpacked initramfs, potentially huge).
  while IFS= read -r path; do
    state=missing
    if [ -f "$path" ]; then
      dest="$dir/artifacts$path"
      if mkdir -p "$(dirname "$dest")" && cp -pL -- "$path" "$dest" && chmod 600 "$dest"; then
        state=copied
      else
        state=copy_failed; failed=1
      fi
    fi
    printf '%s\t%s\n' "$state" "$path" >> "$dir/artifacts.tsv" || failed=1
  done <<'EOF_STK_ARTIFACTS'
/tmp/boot/preseed.cfg
/tmp/boot/ks.cfg
/tmp/boot/startup.sh
/tmp/grub.new
/etc/default/grub
/etc/grub.d/40_custom
/boot/grub/grub.cfg
/boot/grub/grubenv
/boot/grub/grub.conf
/boot/grub2/grub.cfg
/boot/grub2/grubenv
/boot/grub2/grub.conf
EOF_STK_ARTIFACTS
  for path in /boot/vmlinuz /boot/initrd.img; do
    if [ -s "$path" ]; then
      stat -Lc '%n\t%s\t%y\t%z' -- "$path" >> "$dir/artifacts.tsv" || failed=1
      sha256sum -- "$path" >> "$dir/artifacts.tsv" || failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

reinstall_verify_prepared() {
  local dir="${1:-}" rc="${2:-1}" clean="" file="" before="" after="" grub_ok=0
  case "$rc" in 0|1) ;; *) return 1 ;; esac
  [ -f "$dir/install.log" ] || return 1
  clean="$dir/install.clean.log"
  LC_ALL=C sed -E $'s/\033\\[[0-9;]*[[:alpha:]]//g;s/\r//g' "$dir/install.log" > "$clean" || return 1
  chmod 600 "$clean" || return 1
  # Upstream deliberately ends its successful PREPARATION path with exit 1.
  # Never convert every exit 1 into success: require its finish marker plus new boot artifacts.
  awk 'NF { last=$0 } END { print last }' "$clean" | grep -Fq "Input 'reboot' to continue the subsequential installation." || return 1
  for file in /boot/vmlinuz /boot/initrd.img; do
    [ -s "$file" ] && [ -r "$file" ] || return 1
    before="$(cat "$dir/before-${file##*/}.stat" 2>/dev/null)" || return 1
    after="$(stat -Lc '%i|%s|%y|%z' -- "$file")" || return 1
    [ "$before" != "$after" ] || return 1
  done
  for file in /boot/grub/grub.cfg /boot/grub2/grub.cfg /boot/grub/grub.conf /boot/grub2/grub.conf /boot/efi/EFI/*/grub.cfg; do
    [ -s "$file" ] || continue
    if grep -Eq '^[[:space:]]*(linux|linuxefi|linux16|kernel)[[:space:]].*/?vmlinuz([[:space:]]|$)' "$file" && \
       grep -Eq '^[[:space:]]*(initrd|initrdefi|initrd16)[[:space:]].*/?initrd\.img([[:space:]]|$)' "$file"; then
      grub_ok=1
    fi
  done
  [ "$grub_ok" -eq 1 ]
}

reinstall_execute_plan() {
  local workdir="${1:-}" script="" rc=1 tee_rc=1 snapshot_rc=0 result=""
  local ps=()
  [ -d "$workdir" ] && [ "${REINSTALL_PLAN_READY:-0}" = 1 ] || return 1
  script="$workdir/InstallNET.sh"
  (umask 077; reinstall_display_plan > "$workdir/plan.txt") || return 1
  printf 'downloading\n' > "$workdir/status" || return 1
  reinstall_download_script "$script" 2>&1 | tee -a "$workdir/install.log"
  ps=("${PIPESTATUS[@]}")
  if [ "${ps[0]:-1}" -ne 0 ] || [ "${ps[1]:-1}" -ne 0 ]; then
    printf 'download_failed\n' > "$workdir/status"
    return 1
  fi
  sha256sum "$script" > "$workdir/script.sha256" || return 1
  reinstall_snapshot_before "$workdir" || { echo_error "引导文件备份失败，未执行重装。"; printf 'backup_failed\n' > "$workdir/status"; return 1; }
  mkdir -p "$workdir/run" || return 1
  cp -p "$script" "$workdir/run/InstallNET.sh" || return 1
  printf 'running\n' > "$workdir/status" || return 1
  echo_info "执行记录：$workdir/install.log"
  (
    umask 077
    trap 'printf "interrupted\n" > "$workdir/status"; exit 130' INT
    trap 'printf "terminated\n" > "$workdir/status"; exit 143' TERM
    trap 'printf "hangup\n" > "$workdir/status"; exit 129' HUP
    cd "$workdir/run" && env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS bash ./InstallNET.sh "${REINSTALL_ARGS[@]+"${REINSTALL_ARGS[@]}"}"
  ) 2>&1 | tee -a "$workdir/install.log"
  ps=("${PIPESTATUS[@]}"); rc="${ps[0]:-1}"; tee_rc="${ps[1]:-1}"
  printf '%s\n' "$rc" > "$workdir/upstream-exit-code" || return 1
  reinstall_collect_artifacts "$workdir" || snapshot_rc=1
  if [ "$tee_rc" -ne 0 ]; then
    result=log_write_failed; echo_error "日志写入失败，无法可靠判断结果。"
  elif reinstall_verify_prepared "$workdir" "$rc"; then
    result=prepared_waiting_reboot
    echo_color "安装准备已完成，等待手动重启；不是系统已重装完成。"
    [ "$rc" -eq 0 ] || echo_info "上游准备成功路径返回 $rc；完成标记、更新的内核/initrd 与引导引用均已核对。"
    echo_warn "先把日志/备份复制到本地，再在云控制台准备就绪后自行执行：reboot"
    echo_warn "本机现场在重装清盘后可能消失；本工具不会自动重启。"
  else
    result=failed_or_unverified
    echo_error "上游退出码 $rc，未通过准备完成核验。不要据此直接 reboot；先检查日志与引导文件。"
    echo_warn "上游可能已部分修改系统；为避免错误恢复引导，不自动回滚外部重装过程。"
  fi
  REINSTALL_LAST_RESULT="$result"
  printf '%s\n' "$result" > "$workdir/status" || return 1
  if [ "$snapshot_rc" -ne 0 ]; then echo_warn "部分现场文件复制失败，详见 artifacts.tsv；不要把此目录当成完整快照。"; fi
  if [ "$result" = prepared_waiting_reboot ]; then return 0; fi
  [ "$rc" -ne 0 ] && return "$rc"
  return 1
}

apt_filter_distribution_records() {
  local source="${1:-}" dest="${2:-}" format="${3:-list}"
  [ -r "$source" ] && [ -n "$dest" ] || return 1
  awk -v format="$format" '
    function official(x,host,path,pos) {
      x=tolower(x); pos=match(x,/https?:\/\//); if(!pos) return 0
      x=substr(x,pos); sub(/^https?:\/\//,"",x); sub(/[ \t].*$/,"",x)
      host=x; sub(/\/.*$/,"",host); path=substr(x,length(host)+1)
      if (host ~ /^(deb\.debian\.org|security\.debian\.org|archive\.debian\.org)$/) return path ~ /^\/(debian|debian-security)(\/|$)/
      if (host ~ /^(archive\.ubuntu\.com|[a-z][a-z]\.archive\.ubuntu\.com|security\.ubuntu\.com|old-releases\.ubuntu\.com)$/) return path ~ /^\/ubuntu(\/|$)/
      if (host=="ports.ubuntu.com") return path ~ /^\/ubuntu-ports(\/|$)/
      if (host=="mirror.google.com") return path ~ /^\/(linux\/ubuntu|debian)(\/|$)/
      if (host ~ /^(mirror\.yandex\.(ru|net)|cloudflaremirrors\.com)$/) return path ~ /^\/(ubuntu|debian|debian-security)(\/|$)/
      return 0
    }
    BEGIN { if (format=="sources") { RS=""; ORS="\n\n" } }
    format=="list" {
      if ($0 ~ /^[[:space:]]*deb(-src)?[[:space:]]/ && official($0)) print "# server-toolkit disabled distribution source: " $0
      else print
      next
    }
    {
      n=split($0, lines, "\n"); uris=""; field=0
      for (i=1;i<=n;i++) {
        if (tolower(lines[i]) ~ /^uris:/) { uris=substr(lines[i],6); field=1 }
        else if (field && lines[i] ~ /^[ \t]/) uris=uris " " lines[i]
        else field=0
      }
      total=split(uris, a, /[ \t]+/); dist=0; vendor=0
      for (i=1;i<=total;i++) if(a[i]!="") { if(official(a[i])) dist++; else vendor++ }
      if (dist && vendor) { exit 42 }
      if (!dist) print $0
      else { for (i=1;i<=n;i++) printline=printline "# server-toolkit disabled: " lines[i] "\n"; printf "%s\n", printline; printline="" }
    }
  ' "$source" > "$dest"
}

apt_write_managed_sources() {
  local os="${1:-}" base="${2:-}" secbase="${3:-}" code="${4:-}" mode="${5:-normal}"
  local file="/etc/apt/sources.list.d/server-toolkit.sources" components="" signed="" suites="" security="" tmp=""
  case "$os" in debian) components="$(debian_components_by_codename "$code")" ;; ubuntu) components="main restricted universe multiverse" ;; *) return 1 ;; esac
  signed="$(apt_signed_by_line "$os")"
  [ -n "$signed" ] || { echo_error "缺少 $os 官方 keyring，请先修复证书/发行版密钥包；不关闭签名验证。"; return 1; }
  if [ -s "$file" ] && ! grep -q '^# server-toolkit managed sources' "$file"; then
    echo_error "$file 不是本脚本管理的文件，拒绝覆盖。"; return 1
  fi
  suites="$(apt_collect_suites "$base" "$code" base)" || return 1
  security="$(apt_collect_suites "$secbase" "$code" security)" || return 1
  [ -n "$suites" ] || return 1
  apt_disable_conflicting_distro_sources || return 1
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  {
    printf '# server-toolkit managed sources\nTypes: deb\nURIs: %s\nSuites: %s\nComponents: %s\n%s\n' "$base" "$suites" "$components" "$signed"
    if [ "$mode" = archive ]; then printf 'Check-Valid-Until: no\n'; fi
    if [ -n "$security" ]; then
      printf '\nTypes: deb\nURIs: %s\nSuites: %s\nComponents: %s\n%s\n' "$secbase" "$security" "$components" "$signed"
      if [ "$mode" = archive ]; then printf 'Check-Valid-Until: no\n'; fi
    fi
    :
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 644 "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  # Retire only the toolkit-owned global expiry override; archive policy is now per stanza.
  apt_set_archive_mode normal || return 1
  [ -n "$security" ] || echo_warn "此候选未探测到独立 security 套件（sid/归档可能正常）；请查看生成的源配置。"
  return 0
}

firewalld_allow_port() {
  local port="${1:-}" zone="" zones=""
  normalize_port port || return 1
  if firewalld_active; then
    zones="$( { firewall-cmd --get-default-zone; firewall-cmd --get-active-zones | awk '/^[^[:space:]]/{print $1}'; } | sort -u)"
    [ -n "$zones" ] || return 1
    for zone in $zones; do
      [[ "$zone" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
      firewall-cmd --zone="$zone" --add-port="${port}/tcp" || return 1
      firewall-cmd --permanent --zone="$zone" --add-port="${port}/tcp" || return 1
    done
    # Do not reload: it can drop unrelated runtime-only rules. Both stores were updated.
  else
    command -v firewall-offline-cmd >/dev/null 2>&1 || return 1
    # Existing interface/source bindings can select a nondefault zone. Pre-open known zones.
    zones="$(firewall-offline-cmd --get-zones)" || return 1
    [ -n "$zones" ] || return 1
    for zone in $zones; do
      [[ "$zone" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
      firewall-offline-cmd --zone="$zone" --add-port="${port}/tcp" || return 1
    done
    echo_warn "已在 firewalld 现有 zones 预放行 SSH TCP/$port；启用后可按需要收窄。"
  fi
}

cron_read_current() {
  local dest="${1:-}" err="" rc=0
  [ -n "$dest" ] || return 1
  err="$(mktemp /tmp/server-toolkit-cron-error.XXXXXX)" || return 1
  LC_ALL=C crontab -l > "$dest" 2> "$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 1 ] && grep -qi '^no crontab for ' "$err"; then : > "$dest"; rc=0
    else echo_error "无法读取原 crontab，拒绝覆盖；错误记录：$err"; cat "$err" >&2; return 1; fi
  fi
  rm -f "$err"
  return "$rc"
}

cron_update_marker() {
  local marker="${1:-}" entry="${2:-}" dir="" tmp=""
  [[ "$marker" == '# server-toolkit: '* ]] || return 1
  dir="$(make_backup_dir crontab)" || return 1
  cron_read_current "$dir/crontab.before" || return 1
  tmp="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || return 1
  # Match complete marker at line end, not a substring belonging to another task.
  awk -v marker="$marker" 'length($0)<length(marker) || substr($0,length($0)-length(marker)+1)!=marker {print}' "$dir/crontab.before" > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -n "$entry" ]; then printf '%s %s\n' "$entry" "$marker" >> "$tmp" || { rm -f "$tmp"; return 1; }; fi
  if ! crontab "$tmp"; then rm -f "$tmp"; echo_error "crontab 写入失败，原任务备份：$dir/crontab.before"; return 1; fi
  rm -f "$tmp"
}

schedule_interval_task() {
  local target="${1:-}" interval="${2:-}" marker="${3:-}" minute="${4:-}" cmd="${5:-}" dir="" guard="" state="" path=""
  ensure_crontab || return 1
  dir="$(make_backup_dir schedule)" || return 1
  guard="/usr/local/sbin/server-toolkit-${target}-guard"; state="/var/lib/server-toolkit/${target}.last"
  for path in "$guard" "$state"; do
    if [ -e "$path" ]; then backup_path_to_dir "$path" "$dir" || return 1; fi
  done
  if ! write_interval_guard_script "$target" "$interval" "$cmd" > "$dir/guard-path" || ! cron_update_marker "$marker" "$minute * * * * $guard >/dev/null 2>&1"; then
    for path in "$guard" "$state"; do
      if [ -e "$dir$path" ]; then restore_path_from_dir "$path" "$dir" || echo_error "任务文件恢复失败：$path"; else rm -f "$path"; fi
    done
    return 1
  fi
  echo_color "定时任务已设置：每 $interval 小时（按整点附近每小时检查）。"
}

sysctl_snapshot_runtime() {
  local config="${1:-}" snapshot="${2:-}" key="" rest="" value=""
  : > "$snapshot" || return 1
  while IFS='=' read -r key rest; do
    [[ "$key" =~ ^[a-z0-9_.]+$ ]] || continue
    value="$(sysctl -n "$key")" || return 1
    printf '%s=%s\n' "$key" "$value" >> "$snapshot" || return 1
  done < "$config"
}

main() {
  parse_os_release
  require_root
  while true; do
    print_menu
    local option
    ui_prompt option "请选择一个操作" || return 0
    case "$option" in
      1) time_sync ;;
      2) manage_firewall ;;
      3) manage_selinux ;;
      4) secure_ssh ;;
      5) manage_fail2ban ;;
      6) change_ssh_port_password ;;
      7) check_media_unlock; pause_return ;;
      8) show_system_info; pause_return ;;
      9) yabs_test; pause_return ;;
      10) manage_cron_reboot ;;
      11) manage_nezha ;;
      12) check_ip_quality; pause_return ;;
      13) manage_ipv6 ;;
      14) server_hardening ;;
      15) new_server_init_menu ;;
      16) manage_system_reinstall; pause_return ;;
      0) echo_color "已退出 server-toolkit。"; return 0 ;;
      *) echo_error "无效选项：${option:-空}。请输入 0-16。"; pause_return ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
