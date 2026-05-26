#!/bin/bash
set -u

SERVER_TOOLKIT_VERSION="v2.3"

# ============================================================
# server-toolkit.sh v2.3
# 适用：Debian 10/11/12/13/testing/sid、Ubuntu 20.04/22.04/24.04/26.04、
#      CentOS 7/Stream 8/9/10、RHEL 8/9/10、Alma/Rocky/Oracle、
#      Fedora、Amazon Linux 2/2023。
# 原则：先备份、先检测、尽量不破坏当前 SSH 会话；危险操作默认取消并使用数字确认。
# v2.3 摘要：清理 v2.2 历史重复函数层，只保留 main() 实际调用的一套函数；
#            修复 set -u/local 同行引用、Fail2Ban 旧函数混用、系统信息旧函数依赖、
#            chrony 配置路径、Copy Fail 临时缓解模块、SSH 组合修改交互、
#            APT/DNF/YUM 源修复回滚、外部脚本返回码和统一数字确认。
# ============================================================

# ---------- 彩色输出 / UI ----------
echo_color() { echo -e "\e[1;32m$1\e[0m"; }
echo_warn()  { echo -e "\e[1;33m$1\e[0m"; }
echo_error() { echo -e "\e[1;31m$1\e[0m"; }
echo_info()  { echo -e "\e[1;36m$1\e[0m"; }
echo_blue()  { echo -e "\e[1;34m$1\e[0m"; }
echo_pink()  { echo -e "\e[1;35m$1\e[0m"; }
echo_dim()   { echo -e "\e[2m$1\e[0m"; }

UI_LINE="────────────────────────────────────────────────────────────"

ui_hr() { printf "\e[1;36m%s\e[0m\n" "$UI_LINE"; }
ui_title() { echo; ui_hr; printf "\e[1;35m  %s\e[0m\n" "$1"; ui_hr; }
ui_option() { local num="${1:-}" text="${2:-}"; printf "  \e[1;32m%-4s\e[0m %s\n" "${num})" "$text"; }
ui_back() { printf "  \e[1;31m%-4s\e[0m %s\n" "0)" "返回"; }
ui_prompt() { read -r -p "请选择: " "$1"; }
pause_return() { echo; read -r -p "按 Enter 返回菜单..." _pause_dummy; }

confirm_action() {
  local msg="${1:-确认继续？}"
  local default="${2:-2}"
  local ans
  echo_warn "$msg"
  ui_option 1 "继续"
  ui_option 2 "取消（默认）"
  ui_back
  read -r -p "请选择 [默认 ${default}]: " ans
  ans="${ans:-$default}"
  case "$ans" in
    1) return 0 ;;
    2|0) return 1 ;;
    *) echo_error "无效选项，已取消。"; return 1 ;;
  esac
}

choice_ssh_port_keep_policy() {
  local ans
  ui_option 1 "只保留新端口"
  ui_option 2 "新旧端口都保留（默认，推荐）"
  ui_back
  read -r -p "请选择 [默认 2]: " ans
  ans="${ans:-2}"
  case "$ans" in
    1) echo "new_only" ;;
    2) echo "keep_both" ;;
    0) echo "cancel" ;;
    *) echo_error "无效选项，已取消。"; echo "cancel" ;;
  esac
}

choice_private_key_action() {
  local ans
  ui_option 1 "显示私钥"
  ui_option 2 "不显示，仅保留服务器路径（默认，推荐）"
  ui_option 3 "删除服务器上的私钥文件（确认本地已保存后再用）"
  ui_back
  read -r -p "请选择 [默认 2]: " ans
  ans="${ans:-2}"
  case "$ans" in
    1|2|3|0) echo "$ans" ;;
    *) echo_error "无效选项，按默认不显示处理。"; echo "2" ;;
  esac
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
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    systemd-detect-virt --container >/dev/null 2>&1 && return 0
  fi
  grep -qaE '(docker|lxc|containerd|kubepods|podman)' /proc/1/cgroup 2>/dev/null
}

has_cap_sys_time() {
  if command -v capsh >/dev/null 2>&1; then
    capsh --print 2>/dev/null | grep -q 'cap_sys_time' && return 0 || return 1
  fi
  [ -r /proc/1/status ] || return 1
  local hex
  hex="$(awk '/CapEff/ {print $2; exit}' /proc/1/status 2>/dev/null || true)"
  [ -n "$hex" ] || return 1
  [ $((16#$hex & (1<<25))) -ne 0 ]
}

backup_file() {
  local file="${1:-}"
  [ -n "$file" ] || return 1
  if [ -e "$file" ]; then
    cp -a "$file" "${file}.bak.$(date +%F_%H-%M-%S)"
  fi
}

make_backup_dir() {
  local name="${1:-backup}"
  local dir
  dir="/root/server-toolkit-backups/${name}-$(date +%F_%H-%M-%S)"
  mkdir -p "$dir"
  chmod 700 /root/server-toolkit-backups 2>/dev/null || true
  echo "$dir"
}

backup_path_to_dir() {
  local src="${1:-}" dir="${2:-}" dest
  [ -n "$src" ] && [ -n "$dir" ] || return 1
  [ -e "$src" ] || return 0
  dest="$dir$src"
  mkdir -p "$(dirname "$dest")"
  cp -a "$src" "$dest"
}

restore_path_from_dir() {
  local src="${1:-}" dir="${2:-}"
  [ -n "$src" ] && [ -n "$dir" ] || return 1
  if [ -e "$dir$src" ]; then
    rm -rf "$src"
    mkdir -p "$(dirname "$src")"
    cp -a "$dir$src" "$src"
    return 0
  fi
  return 1
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
      DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold update
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
  [ "${#pkgs[@]}" -eq 0 ] && { echo_warn "没有可安装的软件包。"; return 0; }
  echo_info "正在安装：${pkgs[*]}"
  case "$pm" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y "${pkgs[@]}" ;;
    dnf) dnf install -y "${pkgs[@]}" ;;
    yum) yum install -y "${pkgs[@]}" ;;
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

pkg_full_upgrade() {
  local pm
  pm="$(detect_pkg_manager)"
  case "$pm" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade -y
      DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
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
  [ "${#pkgs[@]}" -eq 0 ] && return 0
  case "$pm" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get remove -y "${pkgs[@]}" ;;
    dnf) dnf remove -y "${pkgs[@]}" ;;
    yum) yum remove -y "${pkgs[@]}" ;;
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
  is_systemd_available || { echo_warn "当前环境没有可用 systemd，无法 enable/start $svc。"; return 1; }
  systemctl enable --now "$svc"
}

service_restart_safe() {
  local svc="${1:-}"
  [ -n "$svc" ] || return 1
  is_systemd_available || { echo_warn "当前环境没有可用 systemd，无法重启 $svc。"; return 1; }
  systemctl restart "$svc" && systemctl is-active "$svc" >/dev/null 2>&1
}

service_reload_or_restart() {
  local svc="${1:-}"
  [ -n "$svc" ] || return 1
  is_systemd_available || { echo_warn "当前环境没有可用 systemd，无法 reload/restart $svc。"; return 1; }
  if systemctl reload "$svc" 2>/dev/null; then
    systemctl is-active "$svc" >/dev/null 2>&1 && return 0
  fi
  systemctl restart "$svc" && systemctl is-active "$svc" >/dev/null 2>&1
}

ensure_crontab() {
  if command -v crontab >/dev/null 2>&1; then
    return 0
  fi
  echo_warn "未检测到 crontab。"
  if confirm_action "是否安装 cron/cronie？" "2"; then
    pkg_install cron || return 1
    service_enable_now cron >/dev/null 2>&1 || service_enable_now crond >/dev/null 2>&1 || true
  fi
  command -v crontab >/dev/null 2>&1 || { echo_error "crontab 仍不可用。"; return 1; }
}

# ---------- 防火墙 ----------
firewalld_active() { command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; }
ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; }

allow_port_firewall() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  echo_info "尝试放行 TCP 端口：$port"
  if firewalld_active; then
    firewall-cmd --permanent --add-port="${port}/tcp" || return 1
    firewall-cmd --reload || return 1
    echo_color "firewalld 已放行 ${port}/tcp。"
  elif command -v ufw >/dev/null 2>&1 && ufw_active; then
    ufw allow "${port}/tcp" || return 1
    echo_color "ufw 已放行 ${port}/tcp。"
  elif command -v nft >/dev/null 2>&1; then
    echo_warn "检测到 nftables，但不同系统规则集差异很大，未自动写入永久规则；请手动确认。"
  elif command -v iptables >/dev/null 2>&1; then
    if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
      iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || return 1
      echo_warn "iptables 已添加运行时规则放行 ${port}/tcp；重启后可能失效。"
    fi
  else
    echo_warn "未检测到本机防火墙工具。仍需确认云厂商安全组已放行端口 $port。"
  fi
}

allow_ssh_ports_before_firewall_enable() {
  local ports p
  ports="$(get_current_ssh_ports 2>/dev/null || echo 22)"
  [ -n "$ports" ] || ports="22"
  for p in ${ports//,/ }; do
    [[ "$p" =~ ^[0-9]+$ ]] && allow_port_firewall "$p" || true
  done
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
    ui_option 1 "查看防火墙状态"
    ui_option 2 "开启防火墙（先放行当前 SSH 端口）"
    ui_option 3 "关闭本机 firewalld/ufw"
    ui_back
    local opt
    ui_prompt opt
    case "$opt" in
      1) firewall_status; pause_return ;;
      2)
        echo_warn "开启本机防火墙前会先放行当前 SSH 端口：$(get_current_ssh_ports 2>/dev/null || echo 22)"
        echo_warn "云厂商安全组不受本脚本控制。"
        confirm_action "确认开启本机防火墙？" "2" || { echo_warn "已取消。"; pause_return; continue; }
        if is_redhat_like; then
          pkg_install firewalld || true
          service_enable_now firewalld || { echo_error "firewalld 启动失败。"; pause_return; continue; }
          allow_ssh_ports_before_firewall_enable
          firewall-cmd --reload >/dev/null 2>&1 || true
        elif is_debian_like; then
          if ! command -v ufw >/dev/null 2>&1; then
            confirm_action "未安装 ufw，是否安装？" "2" && pkg_install ufw || { echo_warn "未安装 ufw，已取消。"; pause_return; continue; }
          fi
          allow_ssh_ports_before_firewall_enable
          ufw --force enable || echo_error "ufw enable 失败。"
        else
          echo_warn "当前系统未识别，未自动开启防火墙。"
        fi
        pause_return
        ;;
      3)
        echo_warn "此操作只关闭本机 firewalld/ufw，不影响云厂商安全组。"
        confirm_action "确认关闭本机防火墙服务？" "2" || { echo_warn "已取消。"; pause_return; continue; }
        systemctl stop firewalld 2>/dev/null || true
        systemctl disable firewalld 2>/dev/null || true
        ufw disable >/dev/null 2>&1 || true
        systemctl stop ufw 2>/dev/null || true
        systemctl disable ufw 2>/dev/null || true
        echo_color "防火墙服务已尝试关闭。"
        pause_return
        ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ---------- SELinux ----------
selinux_state() {
  if command -v getenforce >/dev/null 2>&1; then
    getenforce 2>/dev/null || echo "unknown"
  else
    echo "absent"
  fi
}

selinux_allow_ssh_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  command -v getenforce >/dev/null 2>&1 || return 0
  local state
  state="$(getenforce 2>/dev/null || echo Disabled)"
  case "$state" in Disabled) return 0 ;; esac
  [ "$port" = "22" ] && return 0
  if ! command -v semanage >/dev/null 2>&1; then
    echo_warn "SELinux 当前为 $state，但缺少 semanage，准备安装相关包。"
    pkg_install semanage || { echo_warn "无法安装 semanage。请手动执行：semanage port -a -t ssh_port_t -p tcp $port"; return 1; }
  fi
  if semanage port -l 2>/dev/null | awk '$1=="ssh_port_t" && $2=="tcp"{print $0}' | grep -Eq "(^|[, ])${port}([, ]|$)"; then
    echo_color "SELinux 已允许 ssh_port_t tcp/$port。"
    return 0
  fi
  if semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null; then
    echo_color "SELinux 已新增 ssh_port_t tcp/$port。"
  else
    semanage port -m -t ssh_port_t -p tcp "$port" || { echo_error "SELinux 端口策略写入失败。"; return 1; }
  fi
}

manage_selinux() {
  while true; do
    ui_title "SELinux 管理"
    if command -v getenforce >/dev/null 2>&1; then
      echo_info "当前状态：$(getenforce 2>/dev/null || echo unknown)"
      command -v sestatus >/dev/null 2>&1 && sestatus 2>/dev/null | sed -n '1,12p' || true
    else
      echo_warn "未检测到 SELinux 工具；Debian/Ubuntu 通常不启用 SELinux。"
    fi
    ui_option 1 "设置 Enforcing（如从 Disabled 恢复，建议先 Permissive 并重启检查）"
    ui_option 2 "设置 Permissive"
    ui_option 3 "设置 Disabled（需重启完全生效）"
    ui_option 4 "查看 ssh_port_t 端口"
    ui_back
    local opt conf
    conf="/etc/selinux/config"
    ui_prompt opt
    case "$opt" in
      1)
        [ -f "$conf" ] || { echo_warn "未找到 $conf"; pause_return; continue; }
        echo_warn "从 Disabled 恢复 Enforcing 可能需要 relabel；建议先切 Permissive 并观察。"
        confirm_action "确认设置 SELinux Enforcing？" "2" || { pause_return; continue; }
        backup_file "$conf"
        sed -i 's/^SELINUX=.*/SELINUX=enforcing/' "$conf"
        setenforce 1 2>/dev/null || echo_warn "当前会话未能立即切到 Enforcing，可能需重启。"
        echo_warn "如从 Disabled 恢复，必要时请评估 touch /.autorelabel 后重启。"
        pause_return
        ;;
      2)
        [ -f "$conf" ] || { echo_warn "未找到 $conf"; pause_return; continue; }
        backup_file "$conf"
        sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$conf"
        setenforce 0 2>/dev/null || true
        echo_color "SELinux 已设置为 Permissive。"
        pause_return
        ;;
      3)
        [ -f "$conf" ] || { echo_warn "未找到 $conf"; pause_return; continue; }
        confirm_action "确认设置 SELinux Disabled？完全生效需要重启。" "2" || { pause_return; continue; }
        backup_file "$conf"
        sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$conf"
        setenforce 0 2>/dev/null || true
        echo_warn "SELinux 已设置为 Disabled，需重启后完全生效。"
        pause_return
        ;;
      4) command -v semanage >/dev/null 2>&1 && semanage port -l | grep '^ssh_port_t' || echo_warn "未检测到 semanage 或无输出。"; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ---------- SSH 管理 ----------
ssh_service_name() {
  if is_systemd_available; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
      echo "ssh"
    else
      echo "sshd"
    fi
  else
    echo "sshd"
  fi
}

sshd_main_config() { echo "/etc/ssh/sshd_config"; }
sshd_toolkit_dropin() { echo "/etc/ssh/sshd_config.d/00-server-toolkit.conf"; }

sshd_effective_config() {
  if command -v sshd >/dev/null 2>&1; then
    sshd -T 2>/dev/null || true
  fi
}

get_current_ssh_ports() {
  local ports
  ports="$(sshd_effective_config | awk '$1=="port"{print $2}' | sort -n | paste -sd, - 2>/dev/null || true)"
  [ -n "$ports" ] || ports="22"
  echo "$ports"
}

port_in_use() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\.)${port}$"
    return
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk 'NR>2{print $4}' | grep -Eq "(^|:|\.)${port}$"
    return
  fi
  return 1
}

backup_ssh_tree() {
  local dir="${1:-}"
  [ -n "$dir" ] || return 1
  backup_path_to_dir /etc/ssh/sshd_config "$dir"
  [ -d /etc/ssh/sshd_config.d ] && backup_path_to_dir /etc/ssh/sshd_config.d "$dir"
}

restore_ssh_tree() {
  local dir="${1:-}"
  [ -n "$dir" ] || return 1
  restore_path_from_dir /etc/ssh/sshd_config "$dir" || true
  if [ -d "$dir/etc/ssh/sshd_config.d" ]; then
    rm -rf /etc/ssh/sshd_config.d
    cp -a "$dir/etc/ssh/sshd_config.d" /etc/ssh/sshd_config.d
  fi
  echo_warn "已从 $dir 回滚 SSH 配置。"
}

sshd_ensure_include() {
  local main
  main="$(sshd_main_config)"
  [ -f "$main" ] || { echo_error "找不到 $main"; return 1; }
  mkdir -p /etc/ssh/sshd_config.d
  if grep -Eqi '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$main"; then
    # OpenSSH 大多数单值项遵循 first value wins。为确保 drop-in 生效，把 include 调整到最前。
    cp -a "$main" "${main}.tmp.$$"
    {
      echo "Include /etc/ssh/sshd_config.d/*.conf"
      sed -E '/^[[:space:]]*Include[[:space:]]+\/etc\/ssh\/sshd_config\.d\/\*\.conf[[:space:]]*$/Id' "${main}.tmp.$$"
    } > "$main"
    rm -f "${main}.tmp.$$"
  else
    cp -a "$main" "${main}.tmp.$$"
    { echo "Include /etc/ssh/sshd_config.d/*.conf"; cat "${main}.tmp.$$"; } > "$main"
    rm -f "${main}.tmp.$$"
  fi
}

sshd_comment_key_in_file() {
  local file="${1:-}" key="${2:-}"
  [ -n "$file" ] && [ -n "$key" ] && [ -f "$file" ] || return 0
  sed -i -E "s/^([[:space:]]*)(${key})([[:space:]]+.*)$/# server-toolkit disabled duplicate: \2\3/I" "$file"
}

sshd_prepare_effective_key() {
  local key="${1:-}" f toolkit
  [ -n "$key" ] || return 1
  toolkit="$(sshd_toolkit_dropin)"
  sshd_ensure_include || return 1
  sshd_comment_key_in_file "$(sshd_main_config)" "$key"
  if [ -d /etc/ssh/sshd_config.d ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$f" ] || continue
      [ "$f" = "$toolkit" ] && continue
      sshd_comment_key_in_file "$f" "$key"
    done
  fi
}

sshd_dropin_set_key() {
  local key="${1:-}" val="${2:-}" file
  [ -n "$key" ] || return 1
  file="$(sshd_toolkit_dropin)"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  sed -i -E "/^[[:space:]]*${key}[[:space:]]+/Id" "$file"
  printf '%s %s\n' "$key" "$val" >> "$file"
}

sshd_set_ports_dropin() {
  local ports="${1:-}" file p
  [ -n "$ports" ] || return 1
  file="$(sshd_toolkit_dropin)"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  sed -i -E '/^[[:space:]]*Port[[:space:]]+/Id' "$file"
  for p in ${ports//,/ }; do
    [[ "$p" =~ ^[0-9]+$ ]] && printf 'Port %s\n' "$p" >> "$file"
  done
}

set_sshd_kv_effective() {
  local key="${1:-}" val="${2:-}"
  [ -n "$key" ] && [ -n "$val" ] || return 1
  sshd_prepare_effective_key "$key" || return 1
  sshd_dropin_set_key "$key" "$val"
}

set_sshd_kv() { set_sshd_kv_effective "$@"; }

test_sshd_config() {
  command -v sshd >/dev/null 2>&1 || { echo_error "未找到 sshd 命令。"; return 1; }
  sshd -t
}

restart_ssh_service() {
  local svc
  svc="$(ssh_service_name)"
  service_reload_or_restart "$svc" || { echo_error "SSH 服务 reload/restart 失败：$svc"; return 1; }
}

sshd_check_effective_key() {
  local key="${1:-}" expected="${2:-}" actual
  [ -n "$key" ] && [ -n "$expected" ] || return 1
  actual="$(sshd_effective_config | awk -v k="$(printf '%s' "$key" | tr 'A-Z' 'a-z')" '$1==k{print $2; exit}')"
  if [ "$actual" = "$expected" ]; then
    echo_color "sshd -T 验证通过：$key=$actual"
    return 0
  fi
  echo_error "sshd -T 验证失败：$key 期望 $expected，实际 ${actual:-空}"
  return 1
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

ssh_apply_with_rollback() {
  local desc="${1:-SSH 配置}" backup_dir="${2:-}"
  [ -n "$backup_dir" ] || return 1
  if ! test_sshd_config; then
    echo_error "$desc：sshd -t 失败，开始回滚。"
    restore_ssh_tree "$backup_dir" || true
    return 1
  fi
  if ! restart_ssh_service; then
    echo_error "$desc：SSH 服务应用失败，开始回滚。"
    restore_ssh_tree "$backup_dir" || true
    restart_ssh_service || true
    return 1
  fi
  echo_color "$desc 已应用。"
}

show_ssh_effective_config() {
  ui_title "SSH 生效配置"
  if command -v sshd >/dev/null 2>&1; then
    sshd_effective_config | grep -Ei '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|pubkeyauthentication|permitemptypasswords|maxauthtries|logingracetime|usedns|x11forwarding|allowtcpforwarding|clientaliveinterval|clientalivecountmax|maxstartups) ' || true
  else
    echo_warn "未找到 sshd 命令。"
  fi
}

change_ssh_port_only() {
  local new_port old_ports keep_ports backup_dir final_ports ans
  read -r -p "请输入新的 SSH 端口 (1-65535，输入 q 取消): " new_port
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
  ans="$(choice_ssh_port_keep_policy)"
  case "$ans" in
    new_only) final_ports="$new_port" ;;
    keep_both)
      keep_ports="$old_ports,$new_port"
      final_ports="$(printf '%s\n' "$keep_ports" | awk -F, '{for(i=1;i<=NF;i++) if($i && !seen[$i]++) out=out (out? ",":"") $i; print out}')"
      ;;
    cancel) echo_warn "已取消。"; return 0 ;;
    *) echo_warn "已取消。"; return 0 ;;
  esac
  backup_dir="$(make_backup_dir ssh)"
  backup_ssh_tree "$backup_dir"
  allow_port_firewall "$new_port" || echo_warn "防火墙自动放行未完全成功，请手动确认。"
  selinux_allow_ssh_port "$new_port" || echo_warn "SELinux 端口放行未完全成功，请手动确认。"
  sshd_prepare_effective_key "Port" || return 1
  sshd_set_ports_dropin "$final_ports"
  if ssh_apply_with_rollback "SSH 端口配置" "$backup_dir"; then
    sshd_effective_config | awk '$1=="port"{print "生效端口: "$2}'
    sshd_check_listening_port "$new_port" || true
    fail2ban_refresh_ssh_port_silent || true
    echo_warn "请不要关闭当前 SSH 连接。请另开终端测试：ssh -p ${new_port} root@你的服务器IP"
    echo_warn "如果回滚过 SSH 配置，防火墙/SELinux 中新增的端口规则可能仍保留；这通常安全，但可在确认后手动清理。"
  fi
}

change_root_password_only() {
  local new_password status prl pa
  if command -v passwd >/dev/null 2>&1; then
    status="$(passwd -S root 2>/dev/null || true)"
    [ -n "$status" ] && echo_info "root 密码状态：$status"
  fi
  read -r -s -p "请输入 root 新密码（直接回车取消）: " new_password
  echo
  [ -z "$new_password" ] && { echo_warn "已取消。"; return 0; }
  echo "root:${new_password}" | chpasswd || { echo_error "修改密码失败。"; return 1; }
  echo_color "root 密码已更新。"
  prl="$(sshd_effective_config | awk '$1=="permitrootlogin"{print $2; exit}')"
  pa="$(sshd_effective_config | awk '$1=="passwordauthentication"{print $2; exit}')"
  if [ "${pa:-no}" != "yes" ] || [ "${prl:-no}" != "yes" ]; then
    echo_warn "注意：密码已修改，但当前 SSH 可能不允许 root 密码登录。PermitRootLogin=${prl:-未知} PasswordAuthentication=${pa:-未知}"
  fi
}

change_ssh_port_and_password_together() {
  local new_port new_password old_ports final_ports ans keep_ports backup_dir
  ui_title "同时修改 SSH 端口和 root 密码"
  read -r -p "请输入新的 SSH 端口 (1-65535，输入 q 取消): " new_port
  [[ "$new_port" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
    echo_error "端口不合法。"; return 1
  fi
  old_ports="$(get_current_ssh_ports)"
  if port_in_use "$new_port" && ! printf ',%s,' "$old_ports" | grep -q ",$new_port,"; then
    echo_error "端口 $new_port 已被占用，请换一个。"; return 1
  fi
  read -r -s -p "请输入 root 新密码（直接回车取消）: " new_password
  echo
  [ -z "$new_password" ] && { echo_warn "已取消；未修改 SSH 端口。"; return 0; }
  echo_warn "先收集端口和密码，再统一应用；默认保留旧 SSH 端口以防断连。"
  ans="$(choice_ssh_port_keep_policy)"
  case "$ans" in
    new_only) final_ports="$new_port" ;;
    keep_both)
      keep_ports="$old_ports,$new_port"
      final_ports="$(printf '%s\n' "$keep_ports" | awk -F, '{for(i=1;i<=NF;i++) if($i && !seen[$i]++) out=out (out? ",":"") $i; print out}')"
      ;;
    cancel) echo_warn "已取消；未修改密码和 SSH 端口。"; return 0 ;;
    *) echo_warn "已取消。"; return 0 ;;
  esac
  backup_dir="$(make_backup_dir ssh-port-pass)"
  backup_ssh_tree "$backup_dir"
  backup_path_to_dir /etc/shadow "$backup_dir"
  if ! echo "root:${new_password}" | chpasswd; then
    echo_error "修改 root 密码失败，未应用 SSH 端口。"
    restore_path_from_dir /etc/shadow "$backup_dir" || true
    return 1
  fi
  allow_port_firewall "$new_port" || echo_warn "防火墙自动放行未完全成功，请手动确认。"
  selinux_allow_ssh_port "$new_port" || echo_warn "SELinux 端口放行未完全成功，请手动确认。"
  sshd_prepare_effective_key "Port" || { restore_path_from_dir /etc/shadow "$backup_dir" || true; return 1; }
  sshd_set_ports_dropin "$final_ports"
  if ssh_apply_with_rollback "SSH 端口和 root 密码配置" "$backup_dir"; then
    fail2ban_refresh_ssh_port_silent || true
    echo_color "SSH 端口与 root 密码已更新。"
    echo_warn "请另开终端测试：ssh -p ${new_port} root@你的服务器IP"
  else
    restore_path_from_dir /etc/shadow "$backup_dir" || true
    echo_warn "SSH 配置失败，已尝试回滚 root 密码文件。"
    return 1
  fi
}

configure_key_login_existing() {
  local user pubkey home_dir ssh_dir auth_file backup_dir
  read -r -p "请输入要配置密钥的用户名（默认 root，输入 q 取消）: " user
  user="${user:-root}"
  [[ "$user" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  id "$user" >/dev/null 2>&1 || { echo_error "用户不存在：$user"; return 1; }
  echo_info "请粘贴一整行 SSH 公钥（ssh-rsa / ssh-ed25519 / ecdsa-sha2-* 开头），空内容取消："
  read -r pubkey
  [ -z "$pubkey" ] && { echo_warn "已取消。"; return 0; }
  case "$pubkey" in ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-*\ *) ;; *) echo_error "不像合法 SSH 公钥。"; return 1 ;; esac
  backup_dir="$(make_backup_dir ssh-key)"
  backup_ssh_tree "$backup_dir"
  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  ssh_dir="${home_dir}/.ssh"
  auth_file="${ssh_dir}/authorized_keys"
  mkdir -p "$ssh_dir"
  touch "$auth_file"
  grep -qxF "$pubkey" "$auth_file" || echo "$pubkey" >> "$auth_file"
  chown -R "$user:$user" "$ssh_dir" 2>/dev/null || chown -R "$user" "$ssh_dir"
  chmod 700 "$ssh_dir"
  chmod 600 "$auth_file"
  set_sshd_kv_effective "PubkeyAuthentication" "yes"
  if ssh_apply_with_rollback "密钥登录配置" "$backup_dir"; then
    sshd_check_effective_key PubkeyAuthentication yes || true
    echo_warn "请另开终端测试密钥登录成功后，再考虑关闭密码登录。"
  fi
}

generate_key_login_and_output_private() {
  local user home_dir ssh_dir key_name key_path pub_path auth_file comment backup_dir ans
  read -r -p "请输入要生成密钥的用户名（默认 root，输入 q 取消）: " user
  user="${user:-root}"
  [[ "$user" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  id "$user" >/dev/null 2>&1 || { echo_error "用户不存在：$user"; return 1; }
  ensure_command ssh-keygen openssh-client || return 1
  backup_dir="$(make_backup_dir ssh-keygen)"
  backup_ssh_tree "$backup_dir"
  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  ssh_dir="${home_dir}/.ssh"
  key_name="server-toolkit_${user}_ed25519_$(date +%Y%m%d_%H%M%S)"
  key_path="${ssh_dir}/${key_name}"
  pub_path="${key_path}.pub"
  auth_file="${ssh_dir}/authorized_keys"
  comment="server-toolkit-${user}-$(hostname 2>/dev/null)-$(date +%F)"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  ssh-keygen -t ed25519 -N "" -C "$comment" -f "$key_path" || { echo_error "生成密钥失败。"; return 1; }
  touch "$auth_file"
  cat "$pub_path" >> "$auth_file"
  chown -R "$user:$user" "$ssh_dir" 2>/dev/null || chown -R "$user" "$ssh_dir"
  chmod 600 "$auth_file" "$key_path"
  chmod 644 "$pub_path"
  set_sshd_kv_effective "PubkeyAuthentication" "yes"
  ssh_apply_with_rollback "自动生成密钥" "$backup_dir" || return 1
  echo_color "已为用户 $user 生成密钥，并写入 authorized_keys。"
  echo_info "私钥保存路径：$key_path"
  echo_info "公钥内容："
  cat "$pub_path"
  echo_warn "默认不直接输出私钥，避免终端录屏/日志泄漏。"
  while true; do
    ans="$(choice_private_key_action)"
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
        rm -f "$key_path"
        echo_warn "已删除服务器上的私钥文件：$key_path"
        return 0
        ;;
      0) return 0 ;;
    esac
  done
}

check_authorized_keys_safe() {
  local user="${1:-}" home_dir ssh_dir auth_file
  [ -n "$user" ] || return 1
  id "$user" >/dev/null 2>&1 || return 1
  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  ssh_dir="${home_dir}/.ssh"
  auth_file="${ssh_dir}/authorized_keys"
  [ -s "$auth_file" ] || { echo_error "$auth_file 不存在或为空。"; return 1; }
  chmod 700 "$ssh_dir" 2>/dev/null || true
  chmod 600 "$auth_file" 2>/dev/null || true
  chown -R "$user:$user" "$ssh_dir" 2>/dev/null || true
}

toggle_password_login() {
  ui_title "密码登录开关"
  ui_option 1 "开启密码登录"
  ui_option 2 "关闭密码登录（先检查 authorized_keys，默认取消）"
  ui_back
  local opt user backup_dir
  ui_prompt opt
  case "$opt" in
    1)
      backup_dir="$(make_backup_dir ssh-passwd-on)"; backup_ssh_tree "$backup_dir"
      set_sshd_kv_effective "PasswordAuthentication" "yes"
      set_sshd_kv_effective "KbdInteractiveAuthentication" "yes"
      set_sshd_kv_effective "ChallengeResponseAuthentication" "yes"
      ssh_apply_with_rollback "开启密码登录" "$backup_dir" && sshd_check_effective_key PasswordAuthentication yes || true
      ;;
    2)
      read -r -p "请输入已确认可用密钥登录的用户名（默认 root）: " user
      user="${user:-root}"
      check_authorized_keys_safe "$user" || return 1
      confirm_action "关闭密码登录可能导致无法登录。确认已经另开终端测试密钥登录成功？" "2" || { echo_warn "已取消。"; return 0; }
      backup_dir="$(make_backup_dir ssh-passwd-off)"; backup_ssh_tree "$backup_dir"
      set_sshd_kv_effective "PasswordAuthentication" "no"
      set_sshd_kv_effective "KbdInteractiveAuthentication" "no"
      set_sshd_kv_effective "ChallengeResponseAuthentication" "no"
      ssh_apply_with_rollback "关闭密码登录" "$backup_dir" && sshd_check_effective_key PasswordAuthentication no || true
      ;;
    0) return 0 ;;
    *) echo_error "无效选项" ;;
  esac
}

ensure_sudo_for_user() {
  local user="${1:-}" group
  [ -n "$user" ] || return 1
  ensure_command sudo sudo || return 1
  if getent group sudo >/dev/null 2>&1; then group="sudo"; else group="wheel"; fi
  usermod -aG "$group" "$user" || return 1
  if id -nG "$user" | tr ' ' '\n' | grep -qx "$group"; then
    echo_color "用户 $user 已加入 $group 组。"
  else
    echo_error "用户 $user 未能加入 $group 组。"
    return 1
  fi
  if [ "$group" = "wheel" ] && [ -d /etc/sudoers.d ]; then
    if ! grep -RqsE '^%wheel[[:space:]]+ALL=\(ALL\)[[:space:]]+ALL' /etc/sudoers /etc/sudoers.d 2>/dev/null; then
      echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/99-server-toolkit-wheel
      chmod 440 /etc/sudoers.d/99-server-toolkit-wheel
      visudo -cf /etc/sudoers >/dev/null 2>&1 || echo_warn "sudoers 检测未通过，请手动检查。"
    fi
  fi
}

manage_root_login_user() {
  ui_title "root 登录 / sudo 用户管理"
  echo_warn "关闭 root 登录前必须确认普通 sudo 用户可登录。"
  ui_option 1 "新增 sudo 用户，并关闭 root SSH 登录"
  ui_option 2 "恢复 root SSH 登录"
  ui_back
  local opt user pass backup_dir
  ui_prompt opt
  case "$opt" in
    1)
      read -r -p "请输入新用户名（输入 q 取消）: " user
      [[ "$user" =~ ^[Qq]$ || -z "$user" ]] && { echo_warn "已取消。"; return 0; }
      if ! id "$user" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$user" || return 1
      fi
      read -r -s -p "请输入新用户密码: " pass; echo
      [ -z "$pass" ] && { echo_error "密码不能为空。"; return 1; }
      echo "${user}:${pass}" | chpasswd || return 1
      ensure_sudo_for_user "$user" || return 1
      echo_warn "请另开终端测试该用户可登录并可执行 sudo。"
      confirm_action "确认继续关闭 root SSH 登录？" "2" || return 0
      backup_dir="$(make_backup_dir ssh-root-off)"; backup_ssh_tree "$backup_dir"
      set_sshd_kv_effective "PermitRootLogin" "no"
      ssh_apply_with_rollback "关闭 root SSH 登录" "$backup_dir" && echo_warn "请再次确认 ${user} 的 SSH/sudo 可用。"
      ;;
    2)
      backup_dir="$(make_backup_dir ssh-root-on)"; backup_ssh_tree "$backup_dir"
      set_sshd_kv_effective "PermitRootLogin" "yes"
      ssh_apply_with_rollback "恢复 root SSH 登录" "$backup_dir"
      ;;
    0) return 0 ;;
    *) echo_error "无效选项" ;;
  esac
}

ssh_security_recommended() {
  local backup_dir
  backup_dir="$(make_backup_dir ssh-secure)"
  backup_ssh_tree "$backup_dir"
  echo_info "应用保守推荐配置：不禁用 root、不禁用密码、不改端口。"
  set_sshd_kv_effective "LoginGraceTime" "30"
  set_sshd_kv_effective "MaxAuthTries" "3"
  set_sshd_kv_effective "PermitEmptyPasswords" "no"
  set_sshd_kv_effective "UseDNS" "no"
  set_sshd_kv_effective "X11Forwarding" "no"
  set_sshd_kv_effective "PermitUserEnvironment" "no"
  set_sshd_kv_effective "ClientAliveInterval" "300"
  set_sshd_kv_effective "ClientAliveCountMax" "2"
  ssh_apply_with_rollback "SSH 保守增强" "$backup_dir"
}

ssh_security_custom() {
  local opt v a b backup_dir
  backup_dir="$(make_backup_dir ssh-custom)"
  backup_ssh_tree "$backup_dir"
  while true; do
    ui_title "SSH 安全性增强 · 逐项配置"
    ui_option 1 "MaxAuthTries：最大认证失败次数"
    ui_option 2 "LoginGraceTime：登录认证窗口"
    ui_option 3 "PermitEmptyPasswords：禁止空密码"
    ui_option 4 "UseDNS：关闭反向 DNS 查询"
    ui_option 5 "X11Forwarding：关闭 X11 转发"
    ui_option 6 "AllowTcpForwarding：SSH 隧道开关"
    ui_option 7 "ClientAliveInterval/CountMax：空闲连接策略"
    ui_option 8 "查看当前 SSH 生效配置"
    ui_option 9 "应用并返回"
    ui_back
    ui_prompt opt
    case "$opt" in
      1) read -r -p "MaxAuthTries（建议 3）: " v; [[ "$v" =~ ^[0-9]+$ ]] && set_sshd_kv_effective MaxAuthTries "$v" || echo_error "输入无效" ;;
      2) read -r -p "LoginGraceTime 秒数（建议 30）: " v; [[ "$v" =~ ^[0-9]+$ ]] && set_sshd_kv_effective LoginGraceTime "$v" || echo_error "输入无效" ;;
      3) set_sshd_kv_effective PermitEmptyPasswords no ;;
      4) set_sshd_kv_effective UseDNS no ;;
      5) set_sshd_kv_effective X11Forwarding no ;;
      6) read -r -p "AllowTcpForwarding 设置为 yes/no: " v; case "$v" in yes|no) set_sshd_kv_effective AllowTcpForwarding "$v" ;; *) echo_error "只能输入 yes 或 no" ;; esac ;;
      7) read -r -p "ClientAliveInterval（建议 300）: " a; read -r -p "ClientAliveCountMax（建议 2）: " b; [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] && { set_sshd_kv_effective ClientAliveInterval "$a"; set_sshd_kv_effective ClientAliveCountMax "$b"; } || echo_error "输入无效" ;;
      8) show_ssh_effective_config; pause_return ;;
      9) ssh_apply_with_rollback "SSH 逐项配置" "$backup_dir"; return 0 ;;
      0) echo_warn "未应用本轮未生效配置；如已写入 drop-in，可手动查看 $(sshd_toolkit_dropin)。"; return 0 ;;
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
    ui_prompt opt
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
    ui_title "SSH 安全性增强向导"
    ui_option 1 "查看当前 SSH 关键配置"
    ui_option 2 "一键保守增强（不禁 root、不禁密码、不改端口）"
    ui_option 3 "逐项配置（带说明）"
    ui_back
    local opt
    ui_prompt opt
    case "$opt" in
      1) show_ssh_effective_config; pause_return ;;
      2) ssh_security_recommended; pause_return ;;
      3) ssh_security_custom; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

change_ssh_port_password() {
  [ -f /etc/ssh/sshd_config ] || { echo_error "找不到 /etc/ssh/sshd_config"; return 1; }
  while true; do
    ui_title "SSH 端口 / 密码 / 密钥 / root 管理"
    echo_color "请不要关闭当前 SSH 连接，另开终端测试新连接是否成功。"
    ui_option 1 "只修改 SSH 端口"
    ui_option 2 "只修改 root 密码"
    ui_option 3 "同时修改 SSH 端口和 root 密码"
    ui_option 4 "配置密钥登录 / 自动生成密钥"
    ui_option 5 "开启/关闭密码登录"
    ui_option 6 "关闭 root 登录并新增 sudo 用户 / 恢复 root 登录"
    ui_option 7 "查看当前 SSH 关键配置"
    ui_back
    local mode
    ui_prompt mode
    case "$mode" in
      1) change_ssh_port_only; pause_return ;;
      2) change_root_password_only; pause_return ;;
      3) change_ssh_port_and_password_together; pause_return ;;
      4) configure_key_login ;;
      5) toggle_password_login; pause_return ;;
      6) manage_root_login_user; pause_return ;;
      7) show_ssh_effective_config; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ---------- 时间同步 ----------
validate_ntp_servers() {
  local input="${1:-}" item
  [ -n "$input" ] || return 1
  for item in $input; do
    if ! [[ "$item" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
      echo_error "NTP 源包含不允许的字符：$item"
      return 1
    fi
    case "$item" in -*|*..*|*::*::*) echo_error "NTP 源格式可疑：$item"; return 1 ;; esac
  done
  return 0
}

show_timesync_diagnostics() {
  echo_info "时间同步诊断："
  timedatectl status 2>/dev/null || true
  timedatectl show-timesync --all 2>/dev/null || true
  systemd-analyze cat-config systemd/timesyncd.conf --tldr 2>/dev/null || true
  chronyc tracking 2>/dev/null || true
  chronyc sources -v 2>/dev/null || true
}

time_sync_stop_conflicting_clients() {
  local target="${1:-}" svc
  [ -n "$target" ] || return 0
  if [ "$target" = "timesyncd" ]; then
    for svc in chrony chronyd ntp ntpd; do
      if is_systemd_available && systemctl is-active "$svc" >/dev/null 2>&1; then
        echo_warn "检测到 ${svc} 正在运行。多个 NTP 客户端同时运行可能争用时间同步。"
        confirm_action "是否安全停用 ${svc}，改用 systemd-timesyncd？" "2" && systemctl disable --now "$svc" || true
      fi
    done
  elif [ "$target" = "chrony" ]; then
    if is_systemd_available && systemctl is-active systemd-timesyncd >/dev/null 2>&1; then
      echo_warn "检测到 systemd-timesyncd 正在运行。多个 NTP 客户端同时运行可能争用时间同步。"
      confirm_action "是否安全停用 systemd-timesyncd，改用 chrony？" "2" && systemctl disable --now systemd-timesyncd || true
    fi
  fi
}

time_sync_configure_timesyncd() {
  local ntp="${1:-}"
  local conf_dir="/etc/systemd/timesyncd.conf.d"
  local conf="${conf_dir}/server-toolkit.conf"
  validate_ntp_servers "$ntp" || return 1
  if ! is_systemd_available; then
    echo_warn "当前环境没有可用 systemd，无法配置 systemd-timesyncd。"
    return 1
  fi
  if is_container_env || ! has_cap_sys_time; then
    echo_warn "当前可能是容器或缺少 CAP_SYS_TIME，配置 NTP 服务可能无法真正校时；将继续尝试但不保证成功。"
  fi
  if ! command -v timedatectl >/dev/null 2>&1; then
    echo_warn "未检测到 timedatectl，无法使用 systemd-timesyncd。"
    return 1
  fi
  if ! systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd\.service'; then
    pkg_install systemd-timesyncd || true
  fi
  if ! systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd\.service'; then
    echo_warn "未检测到 systemd-timesyncd.service。"
    return 1
  fi
  mkdir -p "$conf_dir"
  backup_file "$conf"
  cat > "$conf" <<EOF_TS
# server-toolkit v2.3: systemd-timesyncd NTP
[Time]
NTP=$ntp
FallbackNTP=time.google.com time.cloudflare.com
EOF_TS
  time_sync_stop_conflicting_clients timesyncd
  timedatectl set-ntp true || echo_warn "timedatectl set-ntp true 失败，继续尝试启动 timesyncd。"
  systemctl enable --now systemd-timesyncd || { echo_error "启动 systemd-timesyncd 失败。"; return 1; }
  systemctl restart systemd-timesyncd || { echo_error "重启 systemd-timesyncd 失败。"; return 1; }
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
  local conf service line tmp
  validate_ntp_servers "$ntp" || return 1
  command -v chronyd >/dev/null 2>&1 || pkg_install chrony || return 1
  conf="$(chrony_config_path)"
  service="$(chrony_service_name)"
  mkdir -p "$(dirname "$conf")"
  touch "$conf"
  backup_file "$conf"
  tmp="$(mktemp /tmp/server-toolkit-chrony.XXXXXX)" || return 1
  sed '/server-toolkit v2.3 BEGIN/,/server-toolkit v2.3 END/d; /server-toolkit v2.2 BEGIN/,/server-toolkit v2.2 END/d' "$conf" > "$tmp"
  {
    cat "$tmp"
    echo ""
    echo "# server-toolkit v2.3 BEGIN"
    for line in $ntp; do echo "server $line iburst"; done
    echo "makestep 1.0 3"
    echo "# server-toolkit v2.3 END"
  } > "$conf"
  rm -f "$tmp"
  time_sync_stop_conflicting_clients chrony
  service_enable_now "$service" || service_enable_now chronyd || service_enable_now chrony || true
  service_restart_safe "$service" || service_restart_safe chronyd || service_restart_safe chrony || { echo_error "chrony 服务启动/重启失败。"; return 1; }
  echo_color "已配置 chrony：$conf"
  show_timesync_diagnostics
}

time_sync_one_shot_fallback() {
  local ntp="${1:-}" s first
  validate_ntp_servers "$ntp" || return 1
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

time_sync() {
  ui_title "时间同步 · systemd-timesyncd / chrony"
  show_os_detected
  local ntp custom method
  ntp="time.google.com time.cloudflare.com"
  read -r -p "NTP 源，直接回车使用默认 [$ntp]，或输入自定义多个域名/IP: " custom
  if [ -n "$custom" ]; then
    if validate_ntp_servers "$custom"; then ntp="$custom"; else echo_error "自定义 NTP 源未通过校验。"; return 1; fi
  fi
  if is_debian_like; then method="timesyncd"; else method="chrony"; fi
  echo_info "默认策略：Debian/Ubuntu 优先 timesyncd；RedHat/Fedora/Amazon 优先 chrony。"
  ui_option 1 "按默认策略配置（推荐：$method）"
  ui_option 2 "强制使用 systemd-timesyncd"
  ui_option 3 "强制使用 chrony"
  ui_option 4 "只执行一次性校时 fallback"
  ui_option 5 "查看时间同步状态"
  ui_back
  local opt
  ui_prompt opt
  case "$opt" in
    1) if [ "$method" = "timesyncd" ]; then time_sync_configure_timesyncd "$ntp" || time_sync_configure_chrony "$ntp" || time_sync_one_shot_fallback "$ntp"; else time_sync_configure_chrony "$ntp" || time_sync_configure_timesyncd "$ntp" || time_sync_one_shot_fallback "$ntp"; fi ;;
    2) time_sync_configure_timesyncd "$ntp" || time_sync_one_shot_fallback "$ntp" ;;
    3) time_sync_configure_chrony "$ntp" || time_sync_one_shot_fallback "$ntp" ;;
    4) time_sync_one_shot_fallback "$ntp" ;;
    5) show_timesync_diagnostics ;;
    0) return 0 ;;
    *) echo_error "无效选项" ;;
  esac
}

# ---------- APT / RPM 源修复 ----------
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
  local dir="${1:-}"
  [ -n "$dir" ] || return 1
  backup_path_to_dir /etc/apt/sources.list "$dir"
  [ -d /etc/apt/sources.list.d ] && backup_path_to_dir /etc/apt/sources.list.d "$dir"
  [ -d /etc/apt/apt.conf.d ] && backup_path_to_dir /etc/apt/apt.conf.d "$dir"
}

apt_restore_all() {
  local dir="${1:-}"
  [ -n "$dir" ] || return 1
  restore_path_from_dir /etc/apt/sources.list "$dir" || true
  if [ -d "$dir/etc/apt/sources.list.d" ]; then rm -rf /etc/apt/sources.list.d; cp -a "$dir/etc/apt/sources.list.d" /etc/apt/sources.list.d; fi
  if [ -d "$dir/etc/apt/apt.conf.d" ]; then rm -rf /etc/apt/apt.conf.d; cp -a "$dir/etc/apt/apt.conf.d" /etc/apt/apt.conf.d; fi
}

apt_disable_conflicting_distro_sources() {
  local f code
  code="$(get_os_codename)"
  mkdir -p /etc/apt/sources.list.d
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    case "$f" in *server-toolkit*|*/debian.sources|*/ubuntu.sources) ;;
    esac
    if grep -Eq "(^deb |Suites: ).*(${code}|stable|oldstable|testing|sid|noble|jammy|focal|bookworm|bullseye|trixie)" "$f" 2>/dev/null; then
      mv "$f" "${f}.disabled-by-server-toolkit.$(date +%F_%H-%M-%S)"
      echo_warn "已暂时停用可能冲突的发行版源：$f"
    fi
  done
  : > /etc/apt/sources.list
}

apt_set_archive_mode() {
  local mode="${1:-normal}" conf="/etc/apt/apt.conf.d/99-server-toolkit-archive"
  if [ "$mode" = "archive" ]; then
    cat > "$conf" <<'EOF_ARCH'
Acquire::Check-Valid-Until "false";
EOF_ARCH
  else
    rm -f "$conf"
  fi
}

write_debian_sources() {
  local base="${1:-}" secbase="${2:-}" code="${3:-}" archive_mode="${4:-normal}" file components signed
  [ -n "$base" ] && [ -n "$code" ] || return 1
  file="/etc/apt/sources.list.d/debian.sources"
  components="$(debian_components_by_codename "$code")"
  signed="$(apt_signed_by_line debian)"
  apt_disable_conflicting_distro_sources
  cat > "$file" <<EOF_DEB
Types: deb
URIs: $base
Suites: $code ${code}-updates ${code}-backports
Components: $components
$signed

Types: deb
URIs: $secbase
Suites: ${code}-security
Components: $components
$signed
EOF_DEB
  apt_set_archive_mode "$archive_mode"
}

write_ubuntu_sources() {
  local base="${1:-}" secbase="${2:-}" code="${3:-}" archive_mode="${4:-normal}" file signed
  [ -n "$base" ] && [ -n "$code" ] || return 1
  file="/etc/apt/sources.list.d/ubuntu.sources"
  signed="$(apt_signed_by_line ubuntu)"
  apt_disable_conflicting_distro_sources
  cat > "$file" <<EOF_UBU
Types: deb
URIs: $base
Suites: $code ${code}-updates ${code}-backports
Components: main restricted universe multiverse
$signed

Types: deb
URIs: $secbase
Suites: ${code}-security
Components: main restricted universe multiverse
$signed
EOF_UBU
  apt_set_archive_mode "$archive_mode"
}

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
  local base="${1:-}" suite="${2:-}"
  [ -n "$base" ] && [ -n "$suite" ] || return 1
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsI --connect-timeout 6 --max-time 12 "${base%/}/dists/${suite}/Release" >/dev/null 2>&1 || \
    curl -fsL --connect-timeout 6 --max-time 12 "${base%/}/dists/${suite}/Release" -o /dev/null >/dev/null 2>&1
}

apt_update_with_log() {
  local log="${1:-/tmp/server-toolkit-apt-update.log}"
  DEBIAN_FRONTEND=noninteractive apt-get update -y >"$log" 2>&1
}

apt_apply_source_profile() {
  local os="${1:-}" code="${2:-}" label="${3:-}" base="${4:-}" secbase="${5:-}" archive_mode="${6:-normal}" backup_dir log
  [ -n "$os" ] && [ -n "$code" ] && [ -n "$base" ] && [ -n "$secbase" ] || return 1
  backup_dir="$(make_backup_dir apt-source)"
  apt_backup_all "$backup_dir"
  log="/tmp/server-toolkit-apt-update.$(date +%s).log"
  echo_info "准备写入 APT 源：$label"
  if [ "$os" = "ubuntu" ]; then write_ubuntu_sources "$base" "$secbase" "$code" "$archive_mode"; else write_debian_sources "$base" "$secbase" "$code" "$archive_mode"; fi
  apt-get clean >/dev/null 2>&1 || true
  if apt_update_with_log "$log"; then
    echo_color "APT 源已修复/切换成功：$label"
    echo_info "备份目录：$backup_dir"
    return 0
  fi
  echo_error "apt-get update 失败，日志：$log"
  tail -n 30 "$log" 2>/dev/null || true
  echo_warn "开始回滚 APT 源配置。"
  apt_restore_all "$backup_dir"
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
  read -r -p "请选择要写入的源: " opt
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
  local os code log_file
  is_debian_like || { echo_warn "当前不是 Debian/Ubuntu 系，跳过 APT 源修复。"; return 0; }
  os="$(get_os_id)"; [ "$os" = "ubuntu" ] || os="debian"
  code="$(get_os_codename)"
  [ -n "$code" ] || { echo_error "无法识别系统代号，无法自动换源。"; return 1; }
  log_file="/tmp/server-toolkit-apt-update.$(date +%s).log"
  ui_title "自动检测并修复 APT 源"
  echo_info "系统识别：$os / $code"
  if apt_update_with_log "$log_file"; then
    echo_color "当前 APT 源可正常 update，未强制改写。"
    if confirm_action "是否继续检测并切换到官方/Google/Cloudflare/Yandex/归档源？" "2"; then apt_source_interactive_chooser; else echo_warn "已保留当前 APT 源。"; fi
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
    echo_warn "RHEL 请用 subscription-manager 启用仓库，本脚本不强改订阅源。"
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y dnf-plugins-core >/dev/null 2>&1 || true
    case "$OS_ID" in
      rocky|almalinux|ol|centos)
        dnf config-manager --set-enabled crb >/dev/null 2>&1 || dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
        ;;
      fedora) echo_info "Fedora 通常不需要 CRB。" ;;
      amzn|amazon) echo_info "Amazon Linux 使用 amazon-linux-extras 或 dnf/yum 官方源，未启用 CRB。" ;;
    esac
  elif command -v yum-config-manager >/dev/null 2>&1; then
    yum-config-manager --enable extras >/dev/null 2>&1 || true
  fi
}

rpm_install_epel_safely() {
  parse_os_release
  if is_rhel_subscription_os; then
    echo_warn "RHEL 安装 EPEL 前请确认订阅与 CodeReady Builder 状态。"
  fi
  case "$OS_ID" in
    fedora|amzn|amazon)
      echo_warn "当前系统不使用传统 EPEL 安装流程，跳过。"; return 0 ;;
  esac
  confirm_action "确认安装/启用 EPEL？" "2" || return 0
  rpm_enable_crb_like || true
  pkg_install epel-release || echo_warn "epel-release 安装失败，请按发行版官方文档手动处理。"
}

rpm_repair_repos() {
  while true; do
    ui_title "DNF/YUM 源检测与修复"
    ui_option 1 "只检测源可用性（makecache）"
    ui_option 2 "启用 CRB/PowerTools/Extras 类仓库（兼容发行版）"
    ui_option 3 "安全安装/启用 EPEL"
    ui_back
    local opt
    ui_prompt opt
    case "$opt" in
      1) rpm_check_repos; pause_return ;;
      2) rpm_enable_crb_like; pkg_makecache || true; pause_return ;;
      3) rpm_install_epel_safely; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

repair_sources_menu() {
  if is_debian_like; then
    while true; do
      ui_title "APT 源修复"
      ui_option 1 "查看当前 APT 源"
      ui_option 2 "自动检测并修复 APT 源"
      ui_option 3 "手动选择官方/Google/Cloudflare/Yandex/归档源"
      ui_back
      local opt
      ui_prompt opt
      case "$opt" in
        1) show_apt_sources_current; pause_return ;;
        2) repair_apt_sources_auto; pause_return ;;
        3) apt_source_interactive_chooser; pause_return ;;
        0) return 0 ;;
        *) echo_error "无效选项"; pause_return ;;
      esac
    done
  elif is_redhat_like; then
    rpm_repair_repos
  else
    echo_warn "当前系统暂不支持自动源修复。"
  fi
}

# ---------- Fail2Ban ----------
fail2ban_backend_config() {
  local logpath
  if command -v journalctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    if python3 -c 'import systemd.journal' >/dev/null 2>&1; then
      echo "backend = systemd"
      return 0
    fi
    echo_warn "检测到 journald，但 Python systemd 模块不可用，尝试安装 python3-systemd。" >&2
    pkg_install python3-systemd >/dev/null 2>&1 || true
    if python3 -c 'import systemd.journal' >/dev/null 2>&1; then
      echo "backend = systemd"
      return 0
    fi
  fi
  if is_redhat_like; then logpath="/var/log/secure"; else logpath="/var/log/auth.log"; fi
  if [ ! -e "$logpath" ]; then
    echo_warn "未找到 $logpath，Fail2Ban 可能无法读取认证日志。建议安装 rsyslog 或 python3-systemd。" >&2
    touch "$logpath" 2>/dev/null || true
  fi
  echo "backend = auto"
  echo "logpath = $logpath"
}

fail2ban_banaction() {
  if firewalld_active; then echo "firewallcmd-ipset"; return; fi
  if command -v nft >/dev/null 2>&1; then echo "nftables-multiport"; return; fi
  if command -v ufw >/dev/null 2>&1 && ufw_active; then echo "ufw"; return; fi
  echo "iptables-multiport"
}

fail2ban_write_global_dropin() {
  local level="${1:-INFO}" file="/etc/fail2ban/fail2ban.d/server-toolkit.conf"
  mkdir -p /etc/fail2ban/fail2ban.d
  cat > "$file" <<EOF_F2B_GLOBAL
# server-toolkit v2.3: global drop-in, does not overwrite fail2ban.local
[Definition]
allowipv6 = auto
loglevel = $level
EOF_F2B_GLOBAL
}

validate_fail2ban_ignoreip() {
  local input="${1:-}" item
  [ -z "$input" ] && return 0
  input="$(printf '%s' "$input" | tr ',' ' ')"
  for item in $input; do
    if ! [[ "$item" =~ ^[0-9A-Fa-f:.\/]+$ ]]; then
      echo_error "ignoreip 包含不允许的字符：$item"
      return 1
    fi
  done
}

fail2ban_write_sshd_jail() {
  local ssh_ports="${1:-}" bantime="${2:-3600}" findtime="${3:-600}" maxretry="${4:-3}" ignoreip="${5:-}" file="/etc/fail2ban/jail.d/server-toolkit-sshd.conf"
  [ -n "$ssh_ports" ] || return 1
  validate_fail2ban_ignoreip "$ignoreip" || return 1
  mkdir -p /etc/fail2ban/jail.d
  cat > "$file" <<EOF_F2B_JAIL
# server-toolkit v2.3: sshd jail, does not overwrite jail.local
[sshd]
enabled = true
port = $ssh_ports
bantime = $bantime
findtime = $findtime
maxretry = $maxretry
ignoreip = 127.0.0.1/8 ::1 $ignoreip
banaction = $(fail2ban_banaction)
$(fail2ban_backend_config)
EOF_F2B_JAIL
}

fail2ban_validate_and_restart() {
  command -v fail2ban-server >/dev/null 2>&1 || { echo_error "fail2ban-server 不存在。"; return 1; }
  if ! fail2ban-server -t >/tmp/server-toolkit-fail2ban-test.log 2>&1; then
    echo_error "Fail2Ban 配置检测失败："
    cat /tmp/server-toolkit-fail2ban-test.log 2>/dev/null || true
    return 1
  fi
  service_enable_now fail2ban || true
  service_restart_safe fail2ban || { journalctl -u fail2ban -n 50 --no-pager 2>/dev/null || true; return 1; }
}

fail2ban_restore_from_backup() {
  local backup_dir="${1:-}"
  [ -n "$backup_dir" ] || return 1
  if [ -d "$backup_dir/etc/fail2ban" ]; then
    rm -rf /etc/fail2ban
    cp -a "$backup_dir/etc/fail2ban" /etc/fail2ban
  fi
}

setup_fail2ban_default() {
  ui_title "安装/配置 Fail2Ban"
  pkg_install fail2ban python3-systemd || pkg_install fail2ban || return 1
  local backup_dir ssh_ports
  backup_dir="$(make_backup_dir fail2ban)"
  backup_path_to_dir /etc/fail2ban "$backup_dir"
  ssh_ports="$(get_current_ssh_ports)"
  fail2ban_write_global_dropin INFO
  fail2ban_write_sshd_jail "$ssh_ports" 3600 600 3 ""
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
  [ -d /etc/fail2ban ] || return 0
  local backup_dir ssh_ports
  backup_dir="$(make_backup_dir fail2ban-port)"
  backup_path_to_dir /etc/fail2ban "$backup_dir"
  ssh_ports="$(get_current_ssh_ports)"
  fail2ban_write_sshd_jail "$ssh_ports" 3600 600 3 ""
  fail2ban_validate_and_restart || { fail2ban_restore_from_backup "$backup_dir"; return 1; }
}

fail2ban_refresh_ssh_port() { fail2ban_refresh_ssh_port_silent && echo_color "已刷新 Fail2Ban SSH 端口：$(get_current_ssh_ports)"; }
fail2ban_status() { systemctl status fail2ban --no-pager -l 2>/dev/null || service fail2ban status 2>/dev/null || true; fail2ban-client status 2>/dev/null || true; }
fail2ban_recent_logs() { journalctl -u fail2ban -n 80 --no-pager 2>/dev/null || tail -n 80 /var/log/fail2ban.log 2>/dev/null || echo_warn "未找到 Fail2Ban 日志。"; }
fail2ban_show_banned() { fail2ban-client status sshd 2>/dev/null || { echo_warn "sshd jail 未运行。"; return 1; }; }

fail2ban_set_loglevel() {
  local level backup_dir
  echo "可选等级：CRITICAL / ERROR / WARNING / NOTICE / INFO / DEBUG"
  read -r -p "请输入日志等级（默认 INFO）: " level
  level="${level:-INFO}"
  case "$level" in CRITICAL|ERROR|WARNING|NOTICE|INFO|DEBUG) ;; *) echo_error "日志等级无效。"; return 1 ;; esac
  backup_dir="$(make_backup_dir fail2ban-loglevel)"
  backup_path_to_dir /etc/fail2ban "$backup_dir"
  fail2ban_write_global_dropin "$level"
  fail2ban_validate_and_restart || { fail2ban_restore_from_backup "$backup_dir"; return 1; }
  echo_color "Fail2Ban 日志等级已设置为：$level"
}

fail2ban_unban_ip() {
  local ip
  read -r -p "请输入要解封的 IP: " ip
  [ -z "$ip" ] && { echo_warn "已取消。"; return 0; }
  if ! [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]; then echo_error "IP 格式包含非法字符。"; return 1; fi
  fail2ban-client set sshd unbanip "$ip" 2>/dev/null && echo_color "已尝试解封：$ip" || echo_error "解封失败，请确认 sshd jail 是否存在。"
}

fail2ban_config_jail() {
  local ssh_ports custom_ports bantime findtime maxretry ignoreip backup_dir
  ssh_ports="$(get_current_ssh_ports)"
  echo_info "自动识别 SSH 端口：$ssh_ports"
  read -r -p "手动覆盖端口？回车使用自动识别，示例 22,2222: " custom_ports
  [ -n "$custom_ports" ] && ssh_ports="$custom_ports"
  [[ "$ssh_ports" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo_error "端口格式无效。"; return 1; }
  read -r -p "bantime 秒（默认 3600）: " bantime
  read -r -p "findtime 秒（默认 600）: " findtime
  read -r -p "maxretry（默认 3）: " maxretry
  read -r -p "ignoreip 白名单，可空: " ignoreip
  bantime="${bantime:-3600}"; findtime="${findtime:-600}"; maxretry="${maxretry:-3}"
  [[ "$bantime" =~ ^[0-9]+$ && "$findtime" =~ ^[0-9]+$ && "$maxretry" =~ ^[0-9]+$ ]] || { echo_error "参数必须是数字。"; return 1; }
  backup_dir="$(make_backup_dir fail2ban-config)"
  backup_path_to_dir /etc/fail2ban "$backup_dir"
  fail2ban_write_sshd_jail "$ssh_ports" "$bantime" "$findtime" "$maxretry" "$ignoreip"
  fail2ban_validate_and_restart || { echo_error "配置失败，开始回滚。"; fail2ban_restore_from_backup "$backup_dir"; return 1; }
  echo_color "Fail2Ban jail 配置已更新。"
}

manage_fail2ban() {
  while true; do
    ui_title "Fail2Ban 管理"
    ui_option 1 "安装/写入默认 SSH 防护配置（jail.d，不覆盖 jail.local）"
    ui_option 2 "自动识别当前 SSH 端口并刷新配置"
    ui_option 3 "查看 Fail2Ban 服务状态"
    ui_option 4 "查看 sshd jail / banned IP"
    ui_option 5 "查看最近 80 条日志"
    ui_option 6 "设置 Fail2Ban 日志等级（drop-in，不覆盖 fail2ban.local）"
    ui_option 7 "配置 sshd 防护参数"
    ui_option 8 "解封指定 IP"
    ui_back
    local opt
    ui_prompt opt
    case "$opt" in
      1) setup_fail2ban_default; pause_return ;;
      2) fail2ban_refresh_ssh_port; pause_return ;;
      3) fail2ban_status; pause_return ;;
      4) fail2ban_show_banned; pause_return ;;
      5) fail2ban_recent_logs; pause_return ;;
      6) fail2ban_set_loglevel; pause_return ;;
      7) fail2ban_config_jail; pause_return ;;
      8) fail2ban_unban_ip; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ---------- IPv6 / GRUB ----------
sysctl_key_exists() { local key="${1:-}"; [ -n "$key" ] && sysctl -n "$key" >/dev/null 2>&1; }

grub_file_detect() { [ -f /etc/default/grub ] && echo "/etc/default/grub" || echo ""; }

grub_cmdline_remove_param() {
  local file="${1:-}" param="${2:-}"
  [ -n "$file" ] && [ -n "$param" ] && [ -f "$file" ] || return 0
  local tmp
  tmp="$(mktemp /tmp/server-toolkit-grub.XXXXXX)" || return 1
  awk -v param="$param" '
    BEGIN{changed=0}
    /^GRUB_CMDLINE_LINUX=/ {
      line=$0
      gsub(param "=[^ \" ]+ ?", "", line)
      gsub(param " ?", "", line)
      gsub(/  +/, " ", line)
      gsub(/=\" /, "=\"", line)
      print line
      changed=1
      next
    }
    {print}
  ' "$file" > "$tmp" && cat "$tmp" > "$file"
  rm -f "$tmp"
}

grub_cmdline_add_param() {
  local file="${1:-}" param="${2:-}"
  [ -n "$file" ] && [ -n "$param" ] && [ -f "$file" ] || return 0
  grep -q "${param}" "$file" && return 0
  if grep -q '^GRUB_CMDLINE_LINUX=' "$file"; then
    sed -i -E "s/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"${param} /" "$file"
  else
    printf 'GRUB_CMDLINE_LINUX="%s"\n' "$param" >> "$file"
  fi
}

update_grub_ipv6_param() {
  local mode="${1:-}" file
  file="$(grub_file_detect)"
  if is_container_env; then
    echo_warn "检测到容器环境，跳过 GRUB 修改。"
    return 0
  fi
  [ -n "$file" ] || { echo_warn "未找到 /etc/default/grub，跳过 GRUB 修改。"; return 0; }
  backup_file "$file"
  if [ "$mode" = "disable" ]; then grub_cmdline_add_param "$file" "ipv6.disable=1"; else grub_cmdline_remove_param "$file" "ipv6.disable"; fi
  if command -v grubby >/dev/null 2>&1; then
    if [ "$mode" = "disable" ]; then grubby --update-kernel=ALL --args="ipv6.disable=1" >/dev/null 2>&1 || true; else grubby --update-kernel=ALL --remove-args="ipv6.disable=1" >/dev/null 2>&1 || true; fi
  elif command -v update-grub >/dev/null 2>&1; then
    update-grub >/dev/null 2>&1 || true
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    [ -d /boot/grub2 ] && grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1 || true
    [ -d /boot/grub ] && grub2-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
    [ -d /boot/efi/EFI ] && find /boot/efi/EFI -maxdepth 2 -name grub.cfg -type f -print -quit | while read -r cfg; do grub2-mkconfig -o "$cfg" >/dev/null 2>&1 || true; done
  else
    echo_warn "未检测到 update-grub/grub2-mkconfig/grubby，GRUB 配置文件已改但未重生成。"
  fi
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
  ui_title "IPv6 一键开启/关闭"
  local conf="/etc/sysctl.d/99-server-toolkit-ipv6.conf" opt
  ui_option 1 "一键开启 IPv6"
  ui_option 2 "一键关闭 IPv6（默认取消，可能影响网络）"
  ui_option 3 "查看 IPv6 状态"
  ui_back
  ui_prompt opt
  case "$opt" in
    1)
      backup_file "$conf"
      {
        echo "# server-toolkit v2.3: ipv6 enable"
        sysctl_key_exists net.ipv6.conf.all.disable_ipv6 && echo "net.ipv6.conf.all.disable_ipv6=0"
        sysctl_key_exists net.ipv6.conf.default.disable_ipv6 && echo "net.ipv6.conf.default.disable_ipv6=0"
        sysctl_key_exists net.ipv6.conf.lo.disable_ipv6 && echo "net.ipv6.conf.lo.disable_ipv6=0"
      } > "$conf"
      update_grub_ipv6_param enable
      sysctl -p "$conf" || true
      show_ipv6_status
      ;;
    2)
      confirm_action "确认关闭 IPv6？此操作可能影响业务网络。" "2" || { echo_warn "已取消。"; return 0; }
      backup_file "$conf"
      {
        echo "# server-toolkit v2.3: ipv6 disable"
        sysctl_key_exists net.ipv6.conf.all.disable_ipv6 && echo "net.ipv6.conf.all.disable_ipv6=1"
        sysctl_key_exists net.ipv6.conf.default.disable_ipv6 && echo "net.ipv6.conf.default.disable_ipv6=1"
        sysctl_key_exists net.ipv6.conf.lo.disable_ipv6 && echo "net.ipv6.conf.lo.disable_ipv6=1"
      } > "$conf"
      update_grub_ipv6_param disable
      sysctl -p "$conf" || true
      show_ipv6_status
      ;;
    3) show_ipv6_status ;;
    0) return 0 ;;
    *) echo_error "无效选项" ;;
  esac
}

# ---------- 系统信息 ----------
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
  printf "%-18s %s\n" "主机名:" "$hostname"
  printf "%-18s %s\n" "系统版本:" "$osver"
  printf "%-18s %s\n" "Linux内核:" "$kernel"
  printf "%-18s %s\n" "CPU架构:" "$arch"
  printf "%-18s %s\n" "CPU型号:" "${cpu_model:-未知}"
  printf "%-18s %s / %s\n" "CPU核心/频率:" "$cpu_cores" "$cpu_freq"
  printf "%-18s %s\n" "系统负载:" "$loadavg"
  printf "%-18s %s/%s (%s%%)\n" "物理内存:" "$(awk -v k="$mem_used" 'BEGIN{printf "%.2fM",k/1024}')" "$(awk -v k="$mem_total" 'BEGIN{printf "%.2fM",k/1024}')" "$mem_pct"
  printf "%-18s %s/%s (%s%%)\n" "Swap:" "$(awk -v k="$swap_used" 'BEGIN{printf "%.0fM",k/1024}')" "$(awk -v k="$swap_total" 'BEGIN{printf "%.0fM",k/1024}')" "$swap_pct"
  printf "%-18s %s/%s (%s)\n" "硬盘占用:" "${disk_used:-未知}" "${disk_total:-未知}" "${disk_pct:-未知}"
  printf "%-18s %s / %s\n" "总接收/发送:" "$(format_bytes "$rx")" "$(format_bytes "$tx")"
  printf "%-18s %s %s\n" "网络算法:" "$algo" "$qdisc"
  printf "%-18s %s\n" "DNS地址:" "$dns"
  printf "%-18s %s\n" "公网地址:" "$pub"
  printf "%-18s %s天 %s时 %s分\n" "运行时长:" "$days" "$hours" "$mins"
}

# ---------- 外部脚本安全执行 ----------
run_remote_script_confirm() {
  local name="${1:-远程脚本}" url="${2:-}" tmp opt rc
  [ -n "$url" ] || return 1
  ui_title "$name"
  echo_warn "将从以下地址下载第三方脚本：$url"
  echo_warn "远程脚本可能修改系统配置，请只在信任来源时继续。"
  ensure_command curl curl || return 1
  tmp="$(mktemp /tmp/server-toolkit-remote.XXXXXX.sh)" || return 1
  if ! curl -fsSL --connect-timeout 8 --max-time 60 "$url" -o "$tmp"; then
    rm -f "$tmp"
    echo_error "下载失败：$url"
    return 1
  fi
  chmod 600 "$tmp"
  while true; do
    ui_option 1 "查看前 120 行脚本"
    ui_option 2 "执行脚本"
    ui_option 3 "保留脚本路径并返回"
    ui_back
    ui_prompt opt
    case "$opt" in
      1) sed -n '1,120p' "$tmp"; pause_return ;;
      2)
        confirm_action "确认执行 $name？远程脚本可能修改系统配置。" "2" || continue
        bash "$tmp"
        rc=$?
        rm -f "$tmp"
        return "$rc"
        ;;
      3) echo_info "已保留临时脚本：$tmp"; return 0 ;;
      0) rm -f "$tmp"; return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

check_media_unlock() { run_remote_script_confirm "流媒体解锁检测" "https://check.unlock.media"; }
yabs_test() { run_remote_script_confirm "YABS 测试" "https://yabs.sh"; }
check_ip_quality() { run_remote_script_confirm "IP 质量检测" "https://IP.Check.Place"; }

# ---------- 服务器加固 ----------
apply_sysctl_if_exists() {
  local key="${1:-}" val="${2:-}" file="${3:-}"
  [ -n "$key" ] && [ -n "$val" ] && [ -n "$file" ] || return 1
  if sysctl_key_exists "$key"; then echo "$key=$val" >> "$file"; else echo_dim "跳过不存在的 sysctl：$key"; fi
}

apply_conservative_sysctl_hardening() {
  local conf="/etc/sysctl.d/98-server-toolkit-hardening.conf" tmp
  backup_file "$conf"
  tmp="$(mktemp /tmp/server-toolkit-sysctl.XXXXXX)" || return 1
  echo "# server-toolkit v2.3: conservative hardening" > "$tmp"
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
  mv "$tmp" "$conf"
  sysctl --system >/dev/null 2>&1 || sysctl -p "$conf" || true
  echo_color "保守 sysctl 加固已应用。"
}

toggle_unpriv_userns() {
  local conf="/etc/sysctl.d/97-server-toolkit-userns.conf" opt
  ui_title "非特权 user namespace"
  echo_warn "关闭 unprivileged user namespace 可能影响 rootless Docker、Chrome、Snap、部分容器。"
  ui_option 1 "关闭（降低部分本地提权攻击面）"
  ui_option 2 "恢复开启"
  ui_back
  ui_prompt opt
  case "$opt" in
    1) confirm_action "确认关闭？" "2" || return 0; backup_file "$conf"; echo 'kernel.unprivileged_userns_clone=0' > "$conf"; sysctl -p "$conf" || true ;;
    2) backup_file "$conf"; echo 'kernel.unprivileged_userns_clone=1' > "$conf"; sysctl -p "$conf" || true ;;
    0) return 0 ;;
    *) echo_error "无效选项" ;;
  esac
}

apply_regresshion_mitigation() {
  ui_title "CVE-2024-6387 / regreSSHion 临时缓解"
  echo_warn "正式修复应升级 OpenSSH 包；临时缓解只调整 sshd 登录窗口与并发，不替代升级。"
  confirm_action "确认应用临时缓解 LoginGraceTime=0 MaxStartups=10:30:60？" "2" || return 0
  local backup_dir
  backup_dir="$(make_backup_dir ssh-regresshion)"; backup_ssh_tree "$backup_dir"
  set_sshd_kv_effective LoginGraceTime 0
  set_sshd_kv_effective MaxStartups "10:30:60"
  ssh_apply_with_rollback "regreSSHion 临时缓解" "$backup_dir"
}

restore_regresshion_mitigation() {
  local backup_dir
  backup_dir="$(make_backup_dir ssh-regresshion-restore)"; backup_ssh_tree "$backup_dir"
  set_sshd_kv_effective LoginGraceTime 30
  set_sshd_kv_effective MaxStartups "10:30:100"
  ssh_apply_with_rollback "regreSSHion 缓解恢复" "$backup_dir"
}

apply_copy_fail_mitigation() {
  ui_title "CVE-2026-31431 / Copy Fail 临时缓解"
  echo_warn "正式修复应升级内核并重启；临时禁用 algif_aead/authencesn 只作为临时缓解，可能影响 IPsec/AF_ALG 加密相关功能。"
  uname -a || true
  lsmod 2>/dev/null | grep -E '^(algif_aead|authencesn)' || echo_info "当前未看到 algif_aead/authencesn 模块已加载。"
  confirm_action "确认写入临时禁用 algif_aead/authencesn 规则？" "2" || return 0
  local conf="/etc/modprobe.d/server-toolkit-copy-fail.conf"
  backup_file "$conf"
  cat > "$conf" <<'EOF_CF'
# server-toolkit v2.3: CVE-2026-31431 temporary mitigation
# 临时缓解不能替代升级内核；如使用 IPsec/AF_ALG 相关功能，启用前必须评估影响。
install algif_aead /bin/false
blacklist algif_aead
install authencesn /bin/false
blacklist authencesn
EOF_CF
  modprobe -r algif_aead 2>/dev/null || true
  modprobe -r authencesn 2>/dev/null || true
  echo_color "已写入临时缓解。请尽快升级内核并重启。"
}

remove_copy_fail_mitigation() {
  local conf="/etc/modprobe.d/server-toolkit-copy-fail.conf"
  [ -f "$conf" ] || { echo_warn "未找到临时缓解文件。"; return 0; }
  backup_file "$conf"
  rm -f "$conf"
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
  echo_warn "将应用保守 sysctl 加固 + SSH 保守增强；不会禁 root、不会禁密码、不会改端口；不包含 Copy Fail 临时缓解。"
  confirm_action "确认继续？" "2" || return 0
  apply_conservative_sysctl_hardening
  ssh_security_recommended
}

security_update_core_packages() {
  ui_title "安全更新核心包"
  echo_warn "生产环境建议先做快照/备份；软件包升级可能触发服务重启或内核更新。"
  confirm_action "确认执行核心包安全更新？" "2" || return 0
  pkg_makecache || return 1
  pkg_install openssh-server openssh-client sudo curl ca-certificates || true
  pkg_upgrade || true
}

server_hardening() {
  while true; do
    ui_title "服务器加固"
    ui_option 1 "一键保守加固（sysctl + SSH 保守增强）"
    ui_option 2 "应用保守 sysctl 加固"
    ui_option 3 "CVE-2024-6387 / regreSSHion 临时缓解"
    ui_option 4 "恢复 regreSSHion 临时缓解默认值"
    ui_option 5 "CVE-2026-31431 / Copy Fail 临时缓解"
    ui_option 6 "移除 Copy Fail 临时缓解"
    ui_option 7 "关闭/恢复 unprivileged user namespace"
    ui_option 8 "安全更新核心包"
    ui_option 9 "查看加固状态"
    ui_back
    local opt
    ui_prompt opt
    case "$opt" in
      1) one_click_safe_hardening; pause_return ;;
      2) apply_conservative_sysctl_hardening; pause_return ;;
      3) apply_regresshion_mitigation; pause_return ;;
      4) restore_regresshion_mitigation; pause_return ;;
      5) apply_copy_fail_mitigation; pause_return ;;
      6) remove_copy_fail_mitigation; pause_return ;;
      7) toggle_unpriv_userns; pause_return ;;
      8) security_update_core_packages; pause_return ;;
      9) show_vulnerability_status; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ---------- 新服务器初始化 / 更新 ----------
openssh_security_upgrade() {
  echo_info "正在尝试升级/安装 OpenSSH 安全更新..."
  pkg_makecache || return 1
  pkg_install openssh-server openssh-client || true
  pkg_upgrade || true
  echo_color "OpenSSH 安全更新流程已执行。"
}

new_server_basic_update() {
  echo_warn "保守更新：修复源 -> 更新缓存 -> 安装常用工具 -> 尝试升级 OpenSSH。"
  confirm_action "确认执行保守更新？" "2" || { echo_warn "已取消。"; return 0; }
  repair_sources_menu || true
  pkg_makecache || return 1
  pkg_install wget curl sudo vim git unzip openssh-server openssh-client ca-certificates
  openssh_security_upgrade || true
}

new_server_full_update() {
  echo_warn "全量更新会执行 upgrade/dist-upgrade/autoremove，可能更新内核。生产环境建议先快照。"
  confirm_action "确认执行全量更新？" "2" || { echo_warn "已取消。"; return 0; }
  repair_sources_menu || true
  pkg_makecache || return 1
  pkg_full_upgrade
  openssh_security_upgrade || true
}

new_server_init_menu() {
  while true; do
    ui_title "新服务器初始化 / 源修复"
    show_os_detected
    ui_option 1 "自动检测并修复软件源（APT/DNF/YUM）"
    ui_option 2 "保守更新：安装常用工具并升级 OpenSSH"
    ui_option 3 "全量系统更新"
    ui_option 4 "单独升级/修复 OpenSSH"
    ui_back
    local opt
    ui_prompt opt
    case "$opt" in
      1) repair_sources_menu ;;
      2) new_server_basic_update; pause_return ;;
      3) new_server_full_update; pause_return ;;
      4) openssh_security_upgrade; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ---------- 定时重启 / 哪吒 ----------
setup_cron_reboot() {
  local interval marker tmpcron
  ui_title "设置定时重启"
  echo_warn "定时重启会影响在线业务，建议确认业务可自动恢复。"
  read -r -p "请输入每隔多少小时重启一次（1-720，输入 q 取消）: " interval
  [[ "$interval" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ] || [ "$interval" -gt 720 ]; then echo_error "请输入 1-720 的有效小时数。"; return 1; fi
  confirm_action "确认写入每 ${interval} 小时自动重启任务？" "2" || return 0
  ensure_crontab || return 1
  marker="# server-toolkit: reboot"
  tmpcron="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || { echo_error "创建临时 crontab 文件失败。"; return 1; }
  crontab -l 2>/dev/null | grep -v "$marker" > "$tmpcron" || true
  echo "0 */$interval * * * /sbin/reboot $marker" >> "$tmpcron"
  crontab "$tmpcron" && rm -f "$tmpcron" || { rm -f "$tmpcron"; echo_error "写入 crontab 失败。"; return 1; }
  echo_color "已设置每隔 $interval 小时自动重启系统。"
}

setup_nezha_agent_restart_cron() {
  local interval marker tmpcron
  read -r -p "请输入每隔多少小时重启 nezha-agent（1-720，输入 q 取消）: " interval
  [[ "$interval" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ] || [ "$interval" -gt 720 ]; then echo_error "请输入 1-720 的有效小时数。"; return 1; fi
  ensure_crontab || return 1
  marker="# server-toolkit: nezha-agent-restart"
  tmpcron="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || { echo_error "创建临时 crontab 文件失败。"; return 1; }
  crontab -l 2>/dev/null | grep -v "$marker" > "$tmpcron" || true
  echo "0 */$interval * * * systemctl restart nezha-agent >/dev/null 2>&1 $marker" >> "$tmpcron"
  crontab "$tmpcron" && rm -f "$tmpcron" || { rm -f "$tmpcron"; echo_error "写入 crontab 失败。"; return 1; }
  echo_color "已设置每隔 $interval 小时自动重启 nezha-agent。"
}

remove_nezha_agent_restart_cron() {
  local marker tmpcron
  ensure_crontab || return 1
  marker="# server-toolkit: nezha-agent-restart"
  tmpcron="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || { echo_error "创建临时 crontab 文件失败。"; return 1; }
  crontab -l 2>/dev/null | grep -v "$marker" > "$tmpcron" || true
  crontab "$tmpcron" && rm -f "$tmpcron" || { rm -f "$tmpcron"; echo_error "写入 crontab 失败。"; return 1; }
  echo_color "已移除 nezha-agent 定期重启任务。"
}

manage_nezha() {
  while true; do
    ui_title "哪吒面板管理"
    ui_option 1 "重启哪吒 Agent"
    ui_option 2 "重启哪吒 Dashboard"
    ui_option 3 "重启 Agent + Dashboard"
    ui_option 4 "设置定期重启 Agent"
    ui_option 5 "移除 Agent 定期重启任务"
    ui_option 6 "卸载哪吒面板/探针"
    ui_back
    local opt
    ui_prompt opt
    case "$opt" in
      1) service_restart_safe nezha-agent || echo_warn "nezha-agent 重启失败或不存在。"; pause_return ;;
      2) service_restart_safe nezha-dashboard || echo_warn "nezha-dashboard 重启失败或不存在。"; pause_return ;;
      3) service_restart_safe nezha-agent || true; service_restart_safe nezha-dashboard || true; pause_return ;;
      4) setup_nezha_agent_restart_cron; pause_return ;;
      5) remove_nezha_agent_restart_cron; pause_return ;;
      6)
        echo_warn "此操作会删除 /opt/nezha /etc/nezha /var/log/nezha。"
        confirm_action "确认卸载哪吒面板/探针？" "2" || { echo_warn "已取消。"; pause_return; continue; }
        systemctl stop nezha-agent 2>/dev/null || true; systemctl stop nezha-dashboard 2>/dev/null || true
        systemctl disable nezha-agent 2>/dev/null || true; systemctl disable nezha-dashboard 2>/dev/null || true
        rm -f /etc/systemd/system/nezha-agent.service /etc/systemd/system/nezha-dashboard.service
        rm -rf /opt/nezha /etc/nezha /var/log/nezha
        systemctl daemon-reload 2>/dev/null || true
        echo_color "哪吒面板/探针已尝试移除。"; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ---------- 主菜单 ----------
menu_row() { printf "  %-38s %s\n" "${1:-}" "${2:-}"; }

print_menu() {
  [ -n "${TERM:-}" ] && clear 2>/dev/null || true
  printf "\n"
  printf "\e[1;36m──────────────────────────────────────────────────────────────────────────────\e[0m\n"
  printf "  \e[1;35mserver-toolkit %s · Linux 服务器工具箱\e[0m\n" "$SERVER_TOOLKIT_VERSION"
  printf "\e[1;36m──────────────────────────────────────────────────────────────────────────────\e[0m\n"
  printf "\e[1;36m功能菜单\e[0m\n"
  printf "\e[2m──────────────────────────────────────────────────────────────────────────────\e[0m\n"
  menu_row "1)  时间同步（timesyncd/chrony）" "9)  YABS 测试"
  menu_row "2)  防火墙开启/关闭"              "10) 设置定时重启"
  menu_row "3)  SELinux 开启/关闭"             "11) 哪吒面板管理"
  menu_row "4)  SSH 安全性增强向导"            "12) IP 质量检测"
  menu_row "5)  Fail2Ban 管理"                 "13) IPv6 一键开启/关闭"
  menu_row "6)  SSH 端口/密码/密钥/root 管理"  "14) 服务器加固"
  menu_row "7)  流媒体解锁检测"                "15) 新服务器初始化/源修复"
  menu_row "8)  显示服务器基本信息"            "0)  退出"
  printf "\e[2m──────────────────────────────────────────────────────────────────────────────\e[0m\n"
}

main() {
  parse_os_release
  require_root
  while true; do
    print_menu
    local option
    read -r -p "请选择一个操作: " option
    case "$option" in
      1) time_sync; pause_return ;;
      2) manage_firewall ;;
      3) manage_selinux ;;
      4) secure_ssh ;;
      5) manage_fail2ban ;;
      6) change_ssh_port_password ;;
      7) check_media_unlock ;;
      8) show_system_info; pause_return ;;
      9) yabs_test ;;
      10) setup_cron_reboot; pause_return ;;
      11) manage_nezha ;;
      12) check_ip_quality ;;
      13) manage_ipv6; pause_return ;;
      14) server_hardening ;;
      15) new_server_init_menu ;;
      0) echo_color "退出"; exit 0 ;;
      *) echo_error "无效的选项，请重新输入"; pause_return ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
