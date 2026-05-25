#!/bin/bash
set -u

SERVER_TOOLKIT_VERSION="v2.2"
SERVER_TOOLKIT_NAME="server-toolkit.sh"
TOOLKIT_BACKUP_DIR="/root/server-toolkit-backups"

# ============================================================
# server-toolkit.sh v2.2
# 适用范围：Debian 10/11/12/13/testing/sid、Ubuntu 20.04/22.04/24.04/26.04、
#           CentOS 7、CentOS Stream 8/9/10、RHEL 8/9/10、AlmaLinux、Rocky Linux、
#           Oracle Linux、Fedora、Amazon Linux 2/2023。
# 原则：先检测、先备份、最小改动、危险操作二次确认、尽量不破坏当前 SSH 会话。
# v2.2 摘要：重构 OS/包管理器抽象；重构 APT/YUM/DNF 源检测修复；
#           时间同步改为 systemd-timesyncd/chrony 优先；SSH 改为 drop-in 生效配置；
#           增强 firewalld/ufw/iptables/nftables、Fail2Ban、SELinux、IPv6、外部脚本安全。
# ============================================================

# ========== 彩色输出 ==========
echo_color() { printf "\033[1;32m%s\033[0m\n" "$1"; }
echo_warn()  { printf "\033[1;33m%s\033[0m\n" "$1"; }
echo_error() { printf "\033[1;31m%s\033[0m\n" "$1"; }
echo_info()  { printf "\033[1;36m%s\033[0m\n" "$1"; }
echo_blue()  { printf "\033[1;34m%s\033[0m\n" "$1"; }
echo_pink()  { printf "\033[1;35m%s\033[0m\n" "$1"; }
echo_dim()   { printf "\033[2m%s\033[0m\n" "$1"; }

pause_return() {
  echo
  read -r -p "按 Enter 返回菜单..." _pause_dummy
}

# ========== UI 辅助函数 ==========
UI_LINE="────────────────────────────────────────────────────────────"

ui_hr() { printf "\033[1;36m%s\033[0m\n" "$UI_LINE"; }
ui_title() {
  echo
  ui_hr
  printf "\033[1;35m  %s\033[0m\n" "$1"
  ui_hr
}
ui_option() {
  local num="$1" text="$2"
  printf "  \033[1;32m%-4s\033[0m %s\n" "${num})" "$text"
}
ui_back() { printf "  \033[1;31m%-4s\033[0m %s\n" "0)" "返回"; }
ui_prompt() {
  local __var="$1"
  read -r -p "请选择: " "$__var"
}
confirm_yes() {
  local prompt="${1:-此操作存在风险，输入 YES 继续: }"
  local confirm
  read -r -p "$prompt" confirm
  [ "$confirm" = "YES" ]
}
confirm_yn() {
  local prompt="${1:-确认执行？[y/N]: }"
  local confirm
  read -r -p "$prompt" confirm
  [[ "$confirm" =~ ^[Yy]$ ]]
}

# ========== 基础检测 / 发行版识别 ==========
OS_ID="unknown"
OS_ID_LIKE=""
OS_VERSION_ID=""
OS_VERSION_CODENAME=""
OS_PRETTY_NAME="unknown"
PKG_MANAGER=""

load_os_release() {
  OS_ID="unknown"; OS_ID_LIKE=""; OS_VERSION_ID=""; OS_VERSION_CODENAME=""; OS_PRETTY_NAME="unknown"
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
    OS_PRETTY_NAME="${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"
  elif [ -r /etc/redhat-release ]; then
    OS_PRETTY_NAME="$(cat /etc/redhat-release 2>/dev/null)"
    OS_ID="rhel"
  elif [ -r /etc/debian_version ]; then
    OS_PRETTY_NAME="Debian $(cat /etc/debian_version 2>/dev/null)"
    OS_ID="debian"
  fi

  if [ -z "$OS_VERSION_CODENAME" ] && command -v lsb_release >/dev/null 2>&1; then
    OS_VERSION_CODENAME="$(lsb_release -sc 2>/dev/null || true)"
  fi

  # Debian testing/sid 常见没有 VERSION_CODENAME，尽量从 /etc/debian_version 推断。
  if [ "$OS_ID" = "debian" ] && [ -z "$OS_VERSION_CODENAME" ] && [ -r /etc/debian_version ]; then
    case "$(cat /etc/debian_version 2>/dev/null)" in
      10*|buster*) OS_VERSION_CODENAME="buster" ;;
      11*|bullseye*) OS_VERSION_CODENAME="bullseye" ;;
      12*|bookworm*) OS_VERSION_CODENAME="bookworm" ;;
      13*|trixie*) OS_VERSION_CODENAME="trixie" ;;
      testing*) OS_VERSION_CODENAME="testing" ;;
      sid*|unstable*) OS_VERSION_CODENAME="sid" ;;
    esac
  fi
}

os_like_contains() { printf '%s %s\n' "$OS_ID" "$OS_ID_LIKE" | grep -Eiq "(^|[[:space:]])$1([[:space:]]|$)"; }
os_is_debian_like() { os_like_contains "debian" || [ -r /etc/debian_version ]; }
os_is_redhat_like() { os_like_contains "rhel|fedora|centos" || [ -r /etc/redhat-release ]; }
os_is_rhel_exact() { [ "$OS_ID" = "rhel" ]; }
os_is_amazon() { [ "$OS_ID" = "amzn" ] || [ "$OS_ID" = "amazon" ]; }
os_major_version() { printf '%s' "$OS_VERSION_ID" | awk -F. '{print $1}'; }
os_codename() { printf '%s' "$OS_VERSION_CODENAME"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo_error "请使用 root 运行此脚本。"
    exit 1
  fi
}

has_systemd() {
  [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

in_container() {
  [ -f /.dockerenv ] && return 0
  grep -qaE '(docker|lxc|kubepods|containerd|podman|openvz)' /proc/1/cgroup 2>/dev/null && return 0
  command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -cq >/dev/null 2>&1 && return 0
  return 1
}

backup_file() {
  local file="$1" ts
  ts="$(date +%F_%H-%M-%S)"
  mkdir -p "$TOOLKIT_BACKUP_DIR"
  if [ -e "$file" ]; then
    cp -a "$file" "${file}.bak.${ts}"
    cp -a "$file" "$TOOLKIT_BACKUP_DIR/$(basename "$file").bak.${ts}" 2>/dev/null || true
  fi
}

backup_path_to() {
  local path="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  [ -e "$path" ] && cp -a "$path" "$dest"
}

run_cmd() {
  echo_dim "+ $*"
  "$@"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ========== 包管理器抽象 ==========
detect_pkg_manager() {
  if command_exists apt-get; then
    PKG_MANAGER="apt"
  elif command_exists dnf; then
    PKG_MANAGER="dnf"
  elif command_exists yum; then
    PKG_MANAGER="yum"
  else
    PKG_MANAGER="none"
  fi
  printf '%s' "$PKG_MANAGER"
}

apt_env() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export APT_LISTCHANGES_FRONTEND=none
  export UCF_FORCE_CONFFOLD=1
}

apt_opts() {
  printf '%s\n' \
    '-o' 'Dpkg::Options::=--force-confdef' \
    '-o' 'Dpkg::Options::=--force-confold'
}

pkg_map_one() {
  local name="$1" pm
  pm="${PKG_MANAGER:-$(detect_pkg_manager)}"
  case "$pm:$name" in
    apt:cron) echo "cron" ;;
    dnf:cron|yum:cron) echo "cronie" ;;
    apt:dnsutils) echo "dnsutils" ;;
    dnf:dnsutils|yum:dnsutils) echo "bind-utils" ;;
    apt:openssh-client) echo "openssh-client" ;;
    dnf:openssh-client|yum:openssh-client) echo "openssh-clients" ;;
    apt:openssh-clients) echo "openssh-client" ;;
    dnf:openssh-clients|yum:openssh-clients) echo "openssh-clients" ;;
    apt:python3-systemd) echo "python3-systemd" ;;
    dnf:python3-systemd|yum:python3-systemd) echo "python3-systemd" ;;
    apt:policycoreutils-python-utils) echo "policycoreutils-python-utils" ;;
    dnf:policycoreutils-python-utils|yum:policycoreutils-python-utils) echo "policycoreutils-python-utils" ;;
    apt:net-tools|dnf:net-tools|yum:net-tools) echo "net-tools" ;;
    apt:chrony|dnf:chrony|yum:chrony) echo "chrony" ;;
    apt:ufw) echo "ufw" ;;
    dnf:ufw|yum:ufw) echo "" ;;
    *) echo "$name" ;;
  esac
}

pkg_map_list() {
  local p mapped out=()
  for p in "$@"; do
    mapped="$(pkg_map_one "$p")"
    [ -n "$mapped" ] && out+=("$mapped")
  done
  printf '%s\n' "${out[@]}"
}

pkg_update() {
  local pm
  pm="${PKG_MANAGER:-$(detect_pkg_manager)}"
  case "$pm" in
    apt)
      apt_env
      apt-get update -y
      ;;
    dnf)
      dnf -y makecache
      ;;
    yum)
      yum -y makecache
      ;;
    *) echo_error "未检测到支持的包管理器。"; return 1 ;;
  esac
}

pkg_makecache() { pkg_update; }

pkg_install() {
  local pm pkgs=() p
  pm="${PKG_MANAGER:-$(detect_pkg_manager)}"
  while IFS= read -r p; do [ -n "$p" ] && pkgs+=("$p"); done < <(pkg_map_list "$@")
  [ "${#pkgs[@]}" -gt 0 ] || { echo_warn "没有需要安装的软件包。"; return 0; }
  case "$pm" in
    apt)
      apt_env
      apt-get install -y $(apt_opts) "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    *) echo_error "未检测到支持的包管理器。"; return 1 ;;
  esac
}

pkg_upgrade() {
  local pm
  pm="${PKG_MANAGER:-$(detect_pkg_manager)}"
  case "$pm" in
    apt)
      apt_env
      apt-get upgrade -y $(apt_opts)
      ;;
    dnf)
      dnf upgrade -y
      ;;
    yum)
      yum update -y
      ;;
    *) echo_error "未检测到支持的包管理器。"; return 1 ;;
  esac
}

pkg_full_upgrade() {
  local pm
  pm="${PKG_MANAGER:-$(detect_pkg_manager)}"
  case "$pm" in
    apt)
      apt_env
      apt-get dist-upgrade -y $(apt_opts)
      apt-get full-upgrade -y $(apt_opts)
      apt-get autoremove -y --purge
      ;;
    dnf)
      dnf upgrade -y
      dnf autoremove -y || true
      ;;
    yum)
      yum update -y
      ;;
    *) echo_error "未检测到支持的包管理器。"; return 1 ;;
  esac
}

pkg_remove() {
  local pm pkgs=() p
  pm="${PKG_MANAGER:-$(detect_pkg_manager)}"
  while IFS= read -r p; do [ -n "$p" ] && pkgs+=("$p"); done < <(pkg_map_list "$@")
  [ "${#pkgs[@]}" -gt 0 ] || return 0
  case "$pm" in
    apt)
      apt_env
      apt-get remove -y "${pkgs[@]}"
      ;;
    dnf) dnf remove -y "${pkgs[@]}" ;;
    yum) yum remove -y "${pkgs[@]}" ;;
    *) echo_error "未检测到支持的包管理器。"; return 1 ;;
  esac
}

pkg_check_command_after_install() {
  local cmd="$1"; shift
  if command_exists "$cmd"; then return 0; fi
  echo_warn "未检测到命令 $cmd，准备安装依赖：$*"
  pkg_install "$@" || return 1
  command_exists "$cmd" || { echo_error "安装后仍未检测到命令：$cmd"; return 1; }
}

# ========== systemd 服务抽象 ==========
service_unit_exists() {
  local svc="$1"
  has_systemd || return 1
  systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "^$svc\.service"
}

service_enable_now() {
  local svc="$1"
  if ! has_systemd; then
    echo_warn "当前环境没有 systemd，无法 enable/start $svc。"
    return 1
  fi
  systemctl enable --now "$svc" >/dev/null 2>&1 || {
    echo_error "启动或设置开机自启失败：$svc"
    systemctl status "$svc" --no-pager -l 2>/dev/null || true
    return 1
  }
}

service_restart_safe() {
  local svc="$1"
  if ! has_systemd; then
    echo_warn "当前环境没有 systemd，无法重启 $svc。"
    return 1
  fi
  systemctl restart "$svc" || {
    echo_error "重启失败：$svc"
    systemctl status "$svc" --no-pager -l 2>/dev/null || true
    return 1
  }
  systemctl is-active "$svc" >/dev/null 2>&1 || {
    echo_error "服务未处于 active 状态：$svc"
    systemctl status "$svc" --no-pager -l 2>/dev/null || true
    return 1
  }
}

service_reload_or_restart() {
  local svc="$1"
  if ! has_systemd; then
    echo_warn "当前环境没有 systemd，无法 reload/restart $svc。"
    return 1
  fi
  if systemctl reload "$svc" >/dev/null 2>&1; then
    systemctl is-active "$svc" >/dev/null 2>&1 && return 0
  fi
  service_restart_safe "$svc"
}

# ========== SSH 通用函数 ==========
SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_TOOLKIT_DROPIN="/etc/ssh/sshd_config.d/00-server-toolkit.conf"
SSHD_OLD_DROPIN="/etc/ssh/sshd_config.d/99-server-toolkit.conf"

ssh_service_name() {
  if has_systemd && service_unit_exists ssh; then
    echo "ssh"
  elif has_systemd && service_unit_exists sshd; then
    echo "sshd"
  else
    echo "sshd"
  fi
}

sshd_effective_config() {
  if command_exists sshd; then
    sshd -T -C user=root -C host="$(hostname 2>/dev/null || echo localhost)" -C addr=127.0.0.1 2>/dev/null || sshd -T 2>/dev/null
  else
    return 1
  fi
}

sshd_effective_get() {
  local key="$1"
  sshd_effective_config | awk -v k="$(printf '%s' "$key" | tr 'A-Z' 'a-z')" '$1==k{print substr($0, index($0,$2))}'
}

sshd_find_include_files() {
  local pattern
  [ -f "$SSHD_MAIN" ] || return 0
  awk 'tolower($1)=="include"{for(i=2;i<=NF;i++) print $i}' "$SSHD_MAIN" 2>/dev/null | while read -r pattern; do
    # shellcheck disable=SC2086
    for f in $pattern; do [ -f "$f" ] && printf '%s\n' "$f"; done
  done
}

sshd_report_conflicts() {
  local key_re='^(Port|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitRootLogin|PubkeyAuthentication|MaxAuthTries|LoginGraceTime|UseDNS|X11Forwarding|ClientAliveInterval|ClientAliveCountMax|MaxStartups)[[:space:]]+'
  echo_info "SSH 相关配置位置扫描："
  if [ -f "$SSHD_MAIN" ]; then
    grep -nEi "^[[:space:]]*#?[[:space:]]*$key_re" "$SSHD_MAIN" 2>/dev/null | sed "s|^|$SSHD_MAIN:|" || true
  fi
  if [ -d "$SSHD_DROPIN_DIR" ]; then
    grep -RInEi "^[[:space:]]*#?[[:space:]]*$key_re" "$SSHD_DROPIN_DIR" 2>/dev/null || true
  fi
  echo_dim "说明：v2.2 使用 $SSHD_TOOLKIT_DROPIN，并尽量放在 Include 最前面，解决 Ubuntu 24.04 drop-in/主配置覆盖导致不生效的问题。"
}

sshd_backup_all() {
  local ts dest
  ts="$(date +%F_%H-%M-%S)"
  dest="$TOOLKIT_BACKUP_DIR/ssh-${ts}"
  mkdir -p "$dest"
  [ -e "$SSHD_MAIN" ] && cp -a "$SSHD_MAIN" "$dest/sshd_config"
  [ -d "$SSHD_DROPIN_DIR" ] && cp -a "$SSHD_DROPIN_DIR" "$dest/sshd_config.d"
  echo "$dest"
}

sshd_restore_backup() {
  local dest="$1"
  [ -d "$dest" ] || return 1
  if [ -f "$dest/sshd_config" ]; then
    cp -a "$dest/sshd_config" "$SSHD_MAIN"
  fi
  if [ -d "$dest/sshd_config.d" ]; then
    rm -rf "$SSHD_DROPIN_DIR"
    cp -a "$dest/sshd_config.d" "$SSHD_DROPIN_DIR"
  fi
}

sshd_ensure_include_first() {
  [ -f "$SSHD_MAIN" ] || { echo_error "找不到 $SSHD_MAIN"; return 1; }
  mkdir -p "$SSHD_DROPIN_DIR"
  if grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_MAIN"; then
    return 0
  fi
  backup_file "$SSHD_MAIN"
  local tmp
  tmp="$(mktemp /tmp/server-toolkit-sshd.XXXXXX)" || return 1
  {
    echo "Include /etc/ssh/sshd_config.d/*.conf"
    cat "$SSHD_MAIN"
  } > "$tmp"
  cat "$tmp" > "$SSHD_MAIN"
  rm -f "$tmp"
}

sshd_migrate_old_dropin() {
  if [ -f "$SSHD_OLD_DROPIN" ] && [ "$SSHD_OLD_DROPIN" != "$SSHD_TOOLKIT_DROPIN" ]; then
    backup_file "$SSHD_OLD_DROPIN"
    mv "$SSHD_OLD_DROPIN" "${SSHD_OLD_DROPIN}.disabled-by-server-toolkit.$(date +%F_%H-%M-%S)" 2>/dev/null || true
  fi
}

sshd_dropin_remove_key() {
  local key="$1" file="$SSHD_TOOLKIT_DROPIN" tmp
  [ -f "$file" ] || return 0
  tmp="$(mktemp /tmp/server-toolkit-dropin.XXXXXX)" || return 1
  awk -v k="$(printf '%s' "$key" | tr 'A-Z' 'a-z')" 'tolower($1)!=k {print}' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

sshd_dropin_set_lines() {
  local key="$1"; shift
  mkdir -p "$SSHD_DROPIN_DIR"
  touch "$SSHD_TOOLKIT_DROPIN"
  sshd_dropin_remove_key "$key"
  {
    grep -q '^# server-toolkit managed sshd drop-in' "$SSHD_TOOLKIT_DROPIN" 2>/dev/null || echo "# server-toolkit managed sshd drop-in v2.2"
    for v in "$@"; do
      printf '%s %s\n' "$key" "$v"
    done
  } >> "$SSHD_TOOLKIT_DROPIN"
  chmod 0644 "$SSHD_TOOLKIT_DROPIN"
}

sshd_validate_config() {
  command_exists sshd || { echo_error "未检测到 sshd 命令。"; return 1; }
  sshd -t 2>/tmp/server-toolkit-sshd-test.log || {
    echo_error "sshd -t 检测失败："
    cat /tmp/server-toolkit-sshd-test.log 2>/dev/null || true
    return 1
  }
}

set_sshd_kv_effective() {
  local key="$1" expected="$2" backup_dir effective key_lc
  backup_dir="$(sshd_backup_all)"
  key_lc="$(printf '%s' "$key" | tr 'A-Z' 'a-z')"
  sshd_ensure_include_first || return 1
  sshd_migrate_old_dropin
  sshd_dropin_set_lines "$key" "$expected"
  if ! sshd_validate_config; then
    echo_error "配置检测失败，正在回滚 SSH 配置。"
    sshd_restore_backup "$backup_dir"
    return 1
  fi
  effective="$(sshd_effective_get "$key_lc" | head -n1 || true)"
  if [ "$key_lc" != "port" ] && [ -n "$effective" ] && [ "$effective" != "$expected" ]; then
    echo_error "sshd -T 显示 $key 最终值为 '$effective'，不是期望值 '$expected'。"
    sshd_report_conflicts
    echo_error "正在回滚 SSH 配置。"
    sshd_restore_backup "$backup_dir"
    return 1
  fi
}

set_sshd_ports_effective() {
  local backup_dir="$1"; shift
  local p ports_effective ok=0
  sshd_ensure_include_first || return 1
  sshd_migrate_old_dropin
  sshd_dropin_remove_key "Port"
  for p in "$@"; do sshd_dropin_set_lines "Port" "$p"; done
  # 上面逐次 set 会删除前面的 Port，因此重新写入多行。
  sshd_dropin_remove_key "Port"
  for p in "$@"; do echo "Port $p" >> "$SSHD_TOOLKIT_DROPIN"; done
  if ! sshd_validate_config; then
    echo_error "配置检测失败，正在回滚 SSH 配置。"
    sshd_restore_backup "$backup_dir"
    return 1
  fi
  ports_effective="$(sshd_effective_config | awk '$1=="port"{print $2}' | sort -n | paste -sd, -)"
  for p in "$@"; do
    echo ",$ports_effective," | grep -q ",$p," || ok=1
  done
  if [ "$ok" -ne 0 ]; then
    echo_error "sshd -T 最终端口为：$ports_effective，未包含期望端口。"
    sshd_report_conflicts
    sshd_restore_backup "$backup_dir"
    return 1
  fi
}

restart_ssh_service() {
  local svc
  svc="$(ssh_service_name)"
  echo_info "正在 reload/restart SSH 服务：$svc"
  service_reload_or_restart "$svc" || return 1
  echo_color "SSH 服务已应用配置：$svc"
}

get_current_ssh_ports() {
  local ports
  ports="$(sshd_effective_config 2>/dev/null | awk '$1=="port"{print $2}' | sort -n | paste -sd, -)"
  [ -n "$ports" ] || ports="22"
  printf '%s' "$ports"
}

port_in_use() {
  local port="$1"
  if command_exists ss; then
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  elif command_exists netstat; then
    netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  else
    return 1
  fi
}

ssh_port_listening() {
  local port="$1"
  if command_exists ss; then
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  elif command_exists netstat; then
    netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  else
    echo_warn "未检测到 ss/netstat，无法确认端口监听。"
    return 0
  fi
}

# ========== 防火墙兼容 ==========
firewalld_active() { has_systemd && systemctl is-active firewalld >/dev/null 2>&1 && command_exists firewall-cmd; }
ufw_active() { command_exists ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; }
iptables_available() { command_exists iptables; }
nft_available() { command_exists nft; }

firewall_allow_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  if firewalld_active; then
    firewall-cmd --permanent --add-port="${port}/tcp" || return 1
    firewall-cmd --reload || return 1
    echo_color "firewalld 已放行 TCP $port。"
  fi
  if ufw_active; then
    ufw allow "${port}/tcp" || return 1
    echo_color "ufw 已放行 TCP $port。"
  fi
  if ! firewalld_active && ! ufw_active && iptables_available; then
    if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
      iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || true
      echo_warn "已临时写入 iptables 放行 TCP $port；是否持久化取决于系统规则保存机制。"
    fi
  fi
  if ! firewalld_active && ! ufw_active && nft_available; then
    if nft list chain inet filter input >/dev/null 2>&1; then
      nft list chain inet filter input 2>/dev/null | grep -q "tcp dport $port" || nft add rule inet filter input tcp dport "$port" accept 2>/dev/null || true
      echo_warn "已尝试写入 nftables inet filter input 放行 TCP $port；是否持久化取决于你的 nftables 配置。"
    else
      echo_dim "检测到 nft，但没有标准 inet filter input 链，未盲目写入。"
    fi
  fi
}

allow_ssh_ports_before_firewall_enable() {
  local ports p
  ports="$(get_current_ssh_ports)"
  for p in ${ports//,/ }; do firewall_allow_port "$p" || true; done
}

firewall_status() {
  ui_title "防火墙状态"
  echo_warn "云厂商安全组不受本脚本控制，请在云面板同步放行 SSH 端口。"
  echo_info "当前 SSH 端口：$(get_current_ssh_ports)"
  echo
  if command_exists firewall-cmd; then
    echo_info "firewalld："
    systemctl is-active firewalld 2>/dev/null || true
    firewall-cmd --get-active-zones 2>/dev/null || true
    firewall-cmd --list-all 2>/dev/null || true
  else
    echo_dim "未检测到 firewall-cmd。"
  fi
  echo
  if command_exists ufw; then
    echo_info "ufw："
    ufw status verbose 2>/dev/null || true
  else
    echo_dim "未检测到 ufw。"
  fi
  echo
  if command_exists iptables; then
    echo_info "iptables INPUT 前 30 行："
    iptables -S INPUT 2>/dev/null | sed -n '1,30p' || true
  fi
  if command_exists nft; then
    echo_info "nftables 规则摘要："
    nft list ruleset 2>/dev/null | sed -n '1,80p' || true
  fi
}

manage_firewall() {
  local opt confirm p ports
  while true; do
    ui_title "防火墙管理"
    ui_option 1 "查看防火墙状态/规则/SSH 端口放行情况"
    ui_option 2 "开启防火墙（先放行当前 SSH 端口）"
    ui_option 3 "关闭 firewalld/ufw（不影响云安全组）"
    ui_option 4 "手动放行一个 TCP 端口"
    ui_back
    ui_prompt opt
    case "$opt" in
      1) firewall_status; pause_return ;;
      2)
        echo_warn "开启前会放行当前 SSH 端口：$(get_current_ssh_ports)"
        echo_warn "云厂商安全组仍需你在云面板放行。"
        confirm_yes "输入 YES 开启系统防火墙: " || { echo_warn "已取消。"; pause_return; continue; }
        allow_ssh_ports_before_firewall_enable
        if os_is_redhat_like; then
          if ! command_exists firewall-cmd; then
            confirm_yn "未安装 firewalld，是否安装？[y/N]: " && pkg_install firewalld || { echo_warn "已跳过安装。"; pause_return; continue; }
          fi
          service_enable_now firewalld && allow_ssh_ports_before_firewall_enable
        else
          if ! command_exists ufw; then
            confirm_yn "未安装 ufw，是否安装？[y/N]: " && pkg_install ufw || { echo_warn "已跳过安装。"; pause_return; continue; }
          fi
          ports="$(get_current_ssh_ports)"
          for p in ${ports//,/ }; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
          ufw --force enable || true
          echo_color "ufw 已尝试开启，并已放行当前 SSH 端口。"
        fi
        pause_return
        ;;
      3)
        echo_warn "此操作会停止/禁用本机 firewalld/ufw，不影响云安全组。"
        confirm_yes "输入 YES 关闭系统防火墙服务: " || { echo_warn "已取消。"; pause_return; continue; }
        has_systemd && systemctl disable --now firewalld 2>/dev/null || true
        command_exists ufw && ufw disable || true
        has_systemd && systemctl disable --now ufw 2>/dev/null || true
        echo_color "已尝试关闭 firewalld/ufw。"
        pause_return
        ;;
      4)
        read -r -p "请输入要放行的 TCP 端口: " p
        if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then firewall_allow_port "$p"; else echo_error "端口无效。"; fi
        pause_return
        ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ========== SELinux ==========
selinux_status_text() {
  if command_exists getenforce; then getenforce 2>/dev/null || echo "unknown"; else echo "not-installed"; fi
}

selinux_install_semanage_hint() {
  if command_exists semanage; then return 0; fi
  echo_warn "未检测到 semanage。RHEL/Alma/Rocky/Oracle/Fedora 通常需要 policycoreutils-python-utils。"
  if os_is_redhat_like && confirm_yn "是否尝试安装 policycoreutils-python-utils？[y/N]: "; then
    pkg_install policycoreutils-python-utils || return 1
  fi
  command_exists semanage
}

selinux_allow_ssh_port() {
  local port="$1" status
  status="$(selinux_status_text)"
  [ "$status" = "Enforcing" ] || [ "$status" = "Permissive" ] || return 0
  [ "$port" = "22" ] && return 0
  if ! selinux_install_semanage_hint; then
    echo_warn "SELinux 当前为 $status，但 semanage 不可用；非 22 SSH 端口可能被 SELinux 拦截。"
    return 1
  fi
  if semanage port -l 2>/dev/null | awk '$1=="ssh_port_t"{print $0}' | grep -Eq "(^|, | )${port}(,|$|-)"; then
    echo_color "SELinux 已允许 ssh_port_t tcp/$port。"
    return 0
  fi
  if semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null; then
    echo_color "SELinux 已新增 ssh_port_t tcp/$port。"
  else
    semanage port -m -t ssh_port_t -p tcp "$port" || {
      echo_error "SELinux 添加 ssh_port_t tcp/$port 失败。"
      return 1
    }
  fi
}

manage_selinux() {
  local opt conf="/etc/selinux/config" status
  while true; do
    ui_title "SELinux 管理"
    status="$(selinux_status_text)"
    echo_info "当前状态：$status"
    command_exists sestatus && sestatus 2>/dev/null | sed -n '1,8p' || true
    ui_option 1 "设置 Enforcing（从 Disabled 恢复建议先 Permissive，并考虑 autorelabel）"
    ui_option 2 "设置 Permissive（宽容模式）"
    ui_option 3 "设置 Disabled（需重启完全生效）"
    ui_option 4 "查看 ssh_port_t 端口"
    ui_back
    ui_prompt opt
    case "$opt" in
      1)
        if [ ! -f "$conf" ]; then echo_warn "未找到 $conf，当前系统可能未启用 SELinux。"; pause_return; continue; fi
        echo_warn "如果当前是 Disabled，直接切 Enforcing 可能触发大量标签问题，建议先 Permissive 并检查日志。"
        confirm_yes "输入 YES 设置 Enforcing: " || { echo_warn "已取消。"; pause_return; continue; }
        backup_file "$conf"; sed -i 's/^SELINUX=.*/SELINUX=enforcing/' "$conf"; setenforce 1 2>/dev/null || true
        echo_color "已设置 Enforcing；如之前为 Disabled，请重启并关注 relabel。"
        pause_return
        ;;
      2)
        [ -f "$conf" ] || { echo_warn "未找到 $conf。"; pause_return; continue; }
        backup_file "$conf"; sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$conf"; setenforce 0 2>/dev/null || true
        echo_color "已设置 Permissive。"; pause_return ;;
      3)
        [ -f "$conf" ] || { echo_warn "未找到 $conf。"; pause_return; continue; }
        confirm_yes "输入 YES 设置 Disabled（需重启）: " || { echo_warn "已取消。"; pause_return; continue; }
        backup_file "$conf"; sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$conf"; setenforce 0 2>/dev/null || true
        echo_color "已设置 Disabled；需要重启后完全生效。"; pause_return ;;
      4)
        if command_exists semanage; then semanage port -l | grep '^ssh_port_t' || true; else echo_warn "未检测到 semanage。"; fi
        pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ========== 时间同步 ==========
time_sync_configure_timesyncd() {
  local servers="$1" conf_dir="/etc/systemd/timesyncd.conf.d" conf="$conf_dir/server-toolkit.conf"
  mkdir -p "$conf_dir"
  backup_file "$conf"
  cat > "$conf" <<EOF
# server-toolkit managed timesyncd config v2.2
[Time]
NTP=$servers
FallbackNTP=time.google.com time.cloudflare.com
EOF
  service_enable_now systemd-timesyncd || service_restart_safe systemd-timesyncd || return 1
  timedatectl set-ntp true 2>/dev/null || true
}

time_sync_configure_chrony() {
  local servers="$1" conf svc s
  if [ -f /etc/chrony/chrony.conf ] || os_is_debian_like; then
    conf="/etc/chrony/chrony.conf"; svc="chrony"
  else
    conf="/etc/chrony.conf"; svc="chronyd"
  fi
  [ -f "$conf" ] || { mkdir -p "$(dirname "$conf")"; touch "$conf"; }
  backup_file "$conf"
  sed -i '/server-toolkit managed chrony/,/server-toolkit end chrony/d' "$conf"
  {
    echo ""
    echo "# server-toolkit managed chrony v2.2"
    for s in $servers; do echo "server $s iburst"; done
    echo "# server-toolkit end chrony"
  } >> "$conf"
  service_enable_now "$svc" || service_restart_safe "$svc" || return 1
  command_exists chronyc && chronyc tracking 2>/dev/null || true
}

time_sync_status() {
  ui_title "时间同步状态"
  timedatectl status 2>/dev/null || echo_warn "timedatectl 不可用。"
  echo
  if command_exists chronyc; then
    echo_info "chronyc tracking："; chronyc tracking 2>/dev/null || true
    echo_info "chronyc sources："; chronyc sources -v 2>/dev/null || true
  fi
  echo
  if has_systemd; then
    systemctl is-active systemd-timesyncd 2>/dev/null | sed 's/^/systemd-timesyncd: /' || true
    systemctl is-active chrony 2>/dev/null | sed 's/^/chrony: /' || true
    systemctl is-active chronyd 2>/dev/null | sed 's/^/chronyd: /' || true
  fi
}

time_sync_one_shot() {
  local servers="$1" first
  first="$(printf '%s' "$servers" | awk '{print $1}')"
  if in_container; then
    echo_warn "检测到容器环境，可能没有 CAP_SYS_TIME；一次性校时可能失败，这不一定是脚本错误。"
  fi
  if command_exists chronyd; then
    chronyd -q "server $first iburst" && return 0
  fi
  if command_exists ntpdate; then
    ntpdate -u $servers && return 0
  fi
  if command_exists sntp; then
    sntp -sS "$first" && return 0
  fi
  echo_warn "未检测到 chronyd/ntpdate/sntp，未执行一次性校时。"
  return 1
}

time_sync_manage_cron_fallback() {
  local opt marker tmp servers="time.google.com time.cloudflare.com"
  marker="# server-toolkit: time-sync-fallback"
  ui_title "时间同步 cron fallback"
  ui_option 1 "写入每 30 分钟 fallback 校时任务（不推荐，只有无 systemd 时使用）"
  ui_option 2 "移除 fallback 校时任务"
  ui_option 3 "查看 fallback 任务"
  ui_back
  ui_prompt opt
  case "$opt" in
    1)
      pkg_check_command_after_install crontab cron || return 1
      tmp="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || return 1
      crontab -l 2>/dev/null | grep -v "$marker" > "$tmp" || true
      echo "*/30 * * * * command -v chronyd >/dev/null 2>&1 && chronyd -q 'server time.google.com iburst' >/dev/null 2>&1 || command -v ntpdate >/dev/null 2>&1 && ntpdate -u $servers >/dev/null 2>&1 $marker" >> "$tmp"
      crontab "$tmp" && rm -f "$tmp" || { rm -f "$tmp"; return 1; }
      echo_color "已写入 cron fallback。" ;;
    2)
      tmp="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || return 1
      crontab -l 2>/dev/null | grep -v "$marker" > "$tmp" || true
      crontab "$tmp" && rm -f "$tmp" || { rm -f "$tmp"; return 1; }
      echo_color "已移除 cron fallback。" ;;
    3) crontab -l 2>/dev/null | grep "$marker" || echo_warn "未发现 fallback 任务。" ;;
    0) return 0 ;;
    *) echo_error "无效选项" ;;
  esac
}

time_sync() {
  local opt servers="time.google.com time.cloudflare.com" custom
  while true; do
    ui_title "时间同步 · systemd-timesyncd / chrony 优先"
    echo_info "默认时间源：$servers"
    ui_option 1 "自动配置推荐方案（Debian/Ubuntu 优先 timesyncd/chrony；红帽系优先 chrony）"
    ui_option 2 "自定义 NTP 源并配置"
    ui_option 3 "查看时间同步状态"
    ui_option 4 "执行一次性校时 fallback（chronyd -q / ntpdate / sntp）"
    ui_option 5 "管理 cron fallback（唯一 marker，可移除）"
    ui_back
    ui_prompt opt
    case "$opt" in
      1|2)
        if [ "$opt" = "2" ]; then
          read -r -p "请输入 NTP 源，空格分隔: " custom
          [ -n "$custom" ] && servers="$custom"
        fi
        if in_container; then echo_warn "检测到容器环境；如果宿主未授予 CAP_SYS_TIME，时间同步服务可能无法真正改系统时间。"; fi
        if ! has_systemd; then
          echo_warn "当前没有 systemd，跳过 timesyncd/chrony 服务配置，只可尝试 fallback。"
          time_sync_one_shot "$servers" || true
          pause_return; continue
        fi
        if os_is_redhat_like; then
          command_exists chronyd || command_exists chronyc || pkg_install chrony || true
          time_sync_configure_chrony "$servers" || echo_error "chrony 配置失败。"
        else
          if service_unit_exists systemd-timesyncd || command_exists timedatectl; then
            time_sync_configure_timesyncd "$servers" || {
              echo_warn "systemd-timesyncd 配置失败，尝试 chrony。"
              command_exists chronyc || pkg_install chrony || true
              time_sync_configure_chrony "$servers" || true
            }
          else
            command_exists chronyc || pkg_install chrony || true
            time_sync_configure_chrony "$servers" || true
          fi
        fi
        time_sync_status
        pause_return
        ;;
      3) time_sync_status; pause_return ;;
      4) time_sync_one_shot "$servers" || true; pause_return ;;
      5) time_sync_manage_cron_fallback; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ========== SSH 安全性增强 ==========
show_ssh_effective_config() {
  ui_title "当前 SSH 最终生效配置"
  if command_exists sshd; then
    sshd_effective_config | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitemptypasswords|maxauthtries|logingracetime|usedns|x11forwarding|allowtcpforwarding|clientaliveinterval|clientalivecountmax|maxstartups) ' || true
  else
    echo_warn "未找到 sshd 命令。"
  fi
  echo
  sshd_report_conflicts
}

ssh_security_recommended() {
  local backup_dir
  [ -f "$SSHD_MAIN" ] || { echo_error "找不到 $SSHD_MAIN"; return 1; }
  backup_dir="$(sshd_backup_all)"
  echo_info "应用保守推荐配置：不禁用 root、不禁用密码、不改端口。"
  sshd_ensure_include_first || return 1
  sshd_migrate_old_dropin
  sshd_dropin_set_lines LoginGraceTime 30
  sshd_dropin_set_lines MaxAuthTries 3
  sshd_dropin_set_lines PermitEmptyPasswords no
  sshd_dropin_set_lines UseDNS no
  sshd_dropin_set_lines X11Forwarding no
  sshd_dropin_set_lines PermitUserEnvironment no
  sshd_dropin_set_lines ClientAliveInterval 300
  sshd_dropin_set_lines ClientAliveCountMax 2
  if ! sshd_validate_config; then sshd_restore_backup "$backup_dir"; return 1; fi
  restart_ssh_service && echo_color "SSH 保守安全增强已完成。"
}

ssh_security_custom() {
  local opt v a b backup_dir
  [ -f "$SSHD_MAIN" ] || { echo_error "找不到 $SSHD_MAIN"; return 1; }
  while true; do
    ui_title "SSH 安全性增强 · 逐项配置"
    ui_option 1 "MaxAuthTries：限制认证失败次数"
    ui_option 2 "LoginGraceTime：限制登录认证窗口"
    ui_option 3 "PermitEmptyPasswords：禁止空密码"
    ui_option 4 "UseDNS：关闭反向 DNS 查询"
    ui_option 5 "X11Forwarding：关闭 X11 转发"
    ui_option 6 "AllowTcpForwarding：SSH 隧道开关"
    ui_option 7 "ClientAliveInterval/CountMax：空闲连接保活/断开策略"
    ui_option 8 "查看当前 SSH 生效配置"
    ui_back
    ui_prompt opt
    backup_dir=""
    case "$opt" in
      1) read -r -p "MaxAuthTries（建议 3）: " v; [[ "$v" =~ ^[0-9]+$ ]] && set_sshd_kv_effective MaxAuthTries "$v" && restart_ssh_service || echo_error "输入或应用失败"; pause_return ;;
      2) read -r -p "LoginGraceTime 秒数（建议 30）: " v; [[ "$v" =~ ^[0-9]+$ ]] && set_sshd_kv_effective LoginGraceTime "$v" && restart_ssh_service || echo_error "输入或应用失败"; pause_return ;;
      3) set_sshd_kv_effective PermitEmptyPasswords no && restart_ssh_service; pause_return ;;
      4) set_sshd_kv_effective UseDNS no && restart_ssh_service; pause_return ;;
      5) set_sshd_kv_effective X11Forwarding no && restart_ssh_service; pause_return ;;
      6) read -r -p "AllowTcpForwarding 设置为 yes/no: " v; [[ "$v" == "yes" || "$v" == "no" ]] && set_sshd_kv_effective AllowTcpForwarding "$v" && restart_ssh_service || echo_error "只能输入 yes 或 no"; pause_return ;;
      7) read -r -p "ClientAliveInterval（建议 300）: " a; read -r -p "ClientAliveCountMax（建议 2）: " b; if [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]]; then backup_dir="$(sshd_backup_all)"; sshd_ensure_include_first && sshd_dropin_set_lines ClientAliveInterval "$a" && sshd_dropin_set_lines ClientAliveCountMax "$b" && sshd_validate_config && restart_ssh_service || { [ -n "$backup_dir" ] && sshd_restore_backup "$backup_dir"; }; else echo_error "输入无效"; fi; pause_return ;;
      8) show_ssh_effective_config; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

secure_ssh() {
  local opt
  [ -f "$SSHD_MAIN" ] || { echo_error "找不到 $SSHD_MAIN"; return 1; }
  while true; do
    ui_title "SSH 安全性增强向导"
    ui_option 1 "查看当前 SSH 关键配置和冲突扫描"
    ui_option 2 "一键保守增强（不禁 root、不禁密码、不改端口）"
    ui_option 3 "逐项配置（带说明，使用 v2.2 drop-in 生效逻辑）"
    ui_back
    ui_prompt opt
    case "$opt" in
      1) show_ssh_effective_config; pause_return ;;
      2) ssh_security_recommended; pause_return ;;
      3) ssh_security_custom ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ========== Fail2Ban 管理 ==========
fail2ban_log_path() {
  if os_is_redhat_like; then echo "/var/log/secure"; else echo "/var/log/auth.log"; fi
}

fail2ban_backend_line() {
  if command_exists journalctl && has_systemd && python3 -c 'import systemd.journal' >/dev/null 2>&1; then
    echo "backend = systemd"
  else
    echo "backend = auto"
    echo "logpath = $(fail2ban_log_path)"
  fi
}

fail2ban_banaction() {
  if firewalld_active; then echo "firewallcmd-rich-rules"; return; fi
  if ufw_active; then echo "ufw"; return; fi
  if command_exists nft; then echo "nftables-multiport"; return; fi
  echo "iptables-multiport"
}

fail2ban_write_base_local() {
  local level="${1:-INFO}" file="/etc/fail2ban/fail2ban.local"
  mkdir -p /etc/fail2ban
  backup_file "$file"
  cat > "$file" <<EOF
# server-toolkit: fail2ban 全局配置 v2.2
[Definition]
allowipv6 = auto
loglevel = $level
EOF
}

fail2ban_write_sshd_jail() {
  local ssh_ports="$1" bantime="$2" findtime="$3" maxretry="$4" ignoreip="$5" file="/etc/fail2ban/jail.d/server-toolkit-sshd.conf" backend banaction
  mkdir -p /etc/fail2ban/jail.d
  backup_file "$file"
  backend="$(fail2ban_backend_line)"
  banaction="$(fail2ban_banaction)"
  cat > "$file" <<EOF
# server-toolkit: fail2ban sshd jail v2.2
[sshd]
enabled = true
port = $ssh_ports
bantime = $bantime
findtime = $findtime
maxretry = $maxretry
ignoreip = 127.0.0.1/8 ::1 $ignoreip
banaction = $banaction
$backend
EOF
}

fail2ban_validate_and_restart() {
  command_exists fail2ban-server || { echo_warn "fail2ban-server 不存在。"; return 1; }
  if ! fail2ban-server -t >/tmp/server-toolkit-fail2ban-test.log 2>&1; then
    echo_error "Fail2Ban 配置检测失败："
    cat /tmp/server-toolkit-fail2ban-test.log 2>/dev/null || true
    return 1
  fi
  service_enable_now fail2ban || service_restart_safe fail2ban || return 1
  echo_color "Fail2Ban 配置检测通过并已重启。"
}

setup_fail2ban_default() {
  echo_info "正在安装/配置 Fail2Ban..."
  if ! command_exists fail2ban-client; then
    pkg_install fail2ban python3-systemd || pkg_install fail2ban || return 1
  fi
  fail2ban_write_base_local INFO
  fail2ban_write_sshd_jail "$(get_current_ssh_ports)" 3600 600 3 ""
  fail2ban_validate_and_restart
}

fail2ban_refresh_ssh_port() {
  command_exists fail2ban-client || return 0
  fail2ban_write_sshd_jail "$(get_current_ssh_ports)" 3600 600 3 ""
  fail2ban_validate_and_restart || true
}

fail2ban_status() {
  systemctl status fail2ban --no-pager -l 2>/dev/null || true
  fail2ban-client status 2>/dev/null || echo_warn "fail2ban-client 不可用或服务未运行。"
}

fail2ban_recent_logs() {
  journalctl -u fail2ban -n 80 --no-pager 2>/dev/null || tail -n 80 /var/log/fail2ban.log 2>/dev/null || echo_warn "未找到 Fail2Ban 日志。"
}

fail2ban_config_jail() {
  local bantime findtime maxretry ignoreip ports custom
  ports="$(get_current_ssh_ports)"
  echo_info "自动识别当前 SSH 端口：$ports"
  read -r -p "手动覆盖端口？回车使用自动识别，格式 22,2222: " custom
  [ -n "$custom" ] && ports="$custom"
  [[ "$ports" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo_error "端口格式无效。"; return 1; }
  read -r -p "bantime 秒（默认 3600）: " bantime; bantime="${bantime:-3600}"
  read -r -p "findtime 秒（默认 600）: " findtime; findtime="${findtime:-600}"
  read -r -p "maxretry（默认 3）: " maxretry; maxretry="${maxretry:-3}"
  read -r -p "ignoreip 白名单，可空: " ignoreip
  [[ "$bantime" =~ ^[0-9]+$ && "$findtime" =~ ^[0-9]+$ && "$maxretry" =~ ^[0-9]+$ ]] || { echo_error "参数必须是数字。"; return 1; }
  fail2ban_write_base_local INFO
  fail2ban_write_sshd_jail "$ports" "$bantime" "$findtime" "$maxretry" "$ignoreip"
  fail2ban_validate_and_restart
}

fail2ban_unban_ip() {
  local ip
  read -r -p "请输入要解封的 IP: " ip
  [ -z "$ip" ] && { echo_warn "已取消。"; return 0; }
  fail2ban-client set sshd unbanip "$ip" && echo_color "已解封：$ip" || echo_error "解封失败。"
}

fail2ban_banned_ips() {
  fail2ban-client status sshd 2>/dev/null | sed -n '/Banned IP list/,$p' || echo_warn "sshd jail 未启用或 Fail2Ban 未运行。"
}

manage_fail2ban() {
  local opt level
  while true; do
    ui_title "Fail2Ban 管理"
    ui_option 1 "安装/写入默认 SSH 防护配置（jail.d，不覆盖复杂 jail.local）"
    ui_option 2 "刷新 SSH 端口到 Fail2Ban"
    ui_option 3 "查看服务状态和 jail 列表"
    ui_option 4 "查看 sshd jail 状态"
    ui_option 5 "查看 banned IP"
    ui_option 6 "查看最近 80 条日志"
    ui_option 7 "设置日志等级"
    ui_option 8 "配置 sshd 防护参数"
    ui_option 9 "解封指定 IP"
    ui_back
    ui_prompt opt
    case "$opt" in
      1) setup_fail2ban_default; pause_return ;;
      2) fail2ban_refresh_ssh_port; pause_return ;;
      3) fail2ban_status; pause_return ;;
      4) fail2ban-client status sshd 2>/dev/null || echo_warn "sshd jail 未启用或 Fail2Ban 未运行。"; pause_return ;;
      5) fail2ban_banned_ips; pause_return ;;
      6) fail2ban_recent_logs; pause_return ;;
      7) read -r -p "等级 CRITICAL/ERROR/WARNING/NOTICE/INFO/DEBUG: " level; case "$level" in CRITICAL|ERROR|WARNING|NOTICE|INFO|DEBUG) fail2ban_write_base_local "$level"; fail2ban_validate_and_restart ;; *) echo_error "等级无效" ;; esac; pause_return ;;
      8) fail2ban_config_jail; pause_return ;;
      9) fail2ban_unban_ip; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ========== SSH 端口/密码/密钥/root管理 ==========
change_ssh_port_only() {
  local new_port keep_old old_ports all_ports backup_dir p unique_ports=()
  read -r -p "请输入新的 SSH 端口 (1-65535，输入 q 取消): " new_port
  [[ "$new_port" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ] || { echo_error "端口不合法。"; return 1; }
  if port_in_use "$new_port" && ! echo ",$(get_current_ssh_ports)," | grep -q ",$new_port,"; then echo_error "端口 $new_port 已被占用。"; return 1; fi
  old_ports="$(get_current_ssh_ports)"
  read -r -p "是否保留旧端口同时监听，避免断连？[Y/n]: " keep_old
  if [[ "$keep_old" =~ ^[Nn]$ ]]; then all_ports="$new_port"; else all_ports="$old_ports,$new_port"; fi
  for p in ${all_ports//,/ }; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    echo " ${unique_ports[*]} " | grep -q " $p " || unique_ports+=("$p")
  done
  echo_warn "将写入 SSH 端口：${unique_ports[*]}"
  echo_warn "会先放行系统防火墙，但云安全组仍需你手动放行。"
  confirm_yes "输入 YES 继续修改 SSH 端口: " || { echo_warn "已取消。"; return 0; }
  backup_dir="$(sshd_backup_all)"
  for p in "${unique_ports[@]}"; do firewall_allow_port "$p" || true; selinux_allow_ssh_port "$p" || true; done
  set_sshd_ports_effective "$backup_dir" "${unique_ports[@]}" || return 1
  if ! restart_ssh_service; then sshd_restore_backup "$backup_dir"; restart_ssh_service || true; return 1; fi
  if ssh_port_listening "$new_port"; then echo_color "新 SSH 端口 $new_port 已监听。"; else echo_error "未确认新端口监听，请检查 systemctl status $(ssh_service_name)。"; fi
  fail2ban_refresh_ssh_port || true
  echo_warn "请不要关闭当前 SSH 窗口，另开终端测试：ssh -p ${new_port} root@你的服务器IP"
  echo_warn "确认新端口可登录后，可再次进入本菜单选择不保留旧端口，仅保留新端口。"
}

change_root_password_only() {
  local new_password prl pa
  read -s -p "请输入 root 新密码（直接回车取消）: " new_password; echo
  [ -z "$new_password" ] && { echo_warn "已取消。"; return 0; }
  if passwd -S root 2>/dev/null | grep -Eq ' root (L|LK) '; then
    echo_warn "检测到 root 账户可能处于 locked 状态；本脚本不会自动解锁。"
  fi
  echo "root:${new_password}" | chpasswd || { echo_error "修改密码失败。"; return 1; }
  echo_color "root 密码已更新。"
  prl="$(sshd_effective_get PermitRootLogin | head -n1 || true)"
  pa="$(sshd_effective_get PasswordAuthentication | head -n1 || true)"
  if [ "$pa" != "yes" ] || echo "$prl" | grep -Eq '^(no|prohibit-password|forced-commands-only)$'; then
    echo_warn "注意：密码已修改，但当前 SSH 可能不允许 root 密码登录。"
    echo_warn "PermitRootLogin=$prl，PasswordAuthentication=$pa"
  fi
}

configure_key_login_existing() {
  local user pubkey home_dir ssh_dir auth_file
  read -r -p "请输入要配置密钥的用户名（默认 root，输入 q 取消）: " user
  user="${user:-root}"
  [[ "$user" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  id "$user" >/dev/null 2>&1 || { echo_error "用户不存在：$user"; return 1; }
  echo_info "请粘贴一整行 SSH 公钥，空内容取消："
  read -r pubkey
  [ -z "$pubkey" ] && { echo_warn "已取消。"; return 0; }
  case "$pubkey" in ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-*\ *) ;; *) echo_error "看起来不像合法 SSH 公钥。"; return 1 ;; esac
  home_dir="$(getent passwd "$user" | cut -d: -f6)"; ssh_dir="${home_dir}/.ssh"; auth_file="${ssh_dir}/authorized_keys"
  mkdir -p "$ssh_dir"; touch "$auth_file"; grep -qxF "$pubkey" "$auth_file" || echo "$pubkey" >> "$auth_file"
  chown -R "$user:$user" "$ssh_dir" 2>/dev/null || chown -R "$user" "$ssh_dir"
  chmod 700 "$ssh_dir"; chmod 600 "$auth_file"
  set_sshd_kv_effective PubkeyAuthentication yes && restart_ssh_service
  echo_color "密钥已写入 $auth_file。请另开终端测试。"
}

generate_key_login_and_output_private() {
  local user home_dir ssh_dir key_name key_path pub_path auth_file comment show_priv
  read -r -p "请输入要生成密钥的用户名（默认 root，输入 q 取消）: " user
  user="${user:-root}"; [[ "$user" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  id "$user" >/dev/null 2>&1 || { echo_error "用户不存在：$user"; return 1; }
  command_exists ssh-keygen || { echo_error "未找到 ssh-keygen。"; return 1; }
  home_dir="$(getent passwd "$user" | cut -d: -f6)"; ssh_dir="${home_dir}/.ssh"; auth_file="${ssh_dir}/authorized_keys"
  key_name="server-toolkit_${user}_ed25519_$(date +%Y%m%d_%H%M%S)"; key_path="${ssh_dir}/${key_name}"; pub_path="${key_path}.pub"
  comment="server-toolkit-${user}-$(hostname 2>/dev/null)-$(date +%F)"
  mkdir -p "$ssh_dir"; chmod 700 "$ssh_dir"
  ssh-keygen -t ed25519 -N "" -C "$comment" -f "$key_path" >/dev/null || { echo_error "生成密钥失败。"; return 1; }
  touch "$auth_file"; cat "$pub_path" >> "$auth_file"
  chown -R "$user:$user" "$ssh_dir" 2>/dev/null || chown -R "$user" "$ssh_dir"; chmod 600 "$auth_file" "$key_path"; chmod 644 "$pub_path"
  set_sshd_kv_effective PubkeyAuthentication yes && restart_ssh_service
  echo_color "已生成密钥并写入 authorized_keys。"
  echo_info "私钥路径：$key_path"
  echo_info "公钥路径：$pub_path"
  echo_warn "默认不把私钥输出到屏幕，避免泄露。"
  read -r -p "确需在屏幕显示私钥？输入 YES: " show_priv
  if [ "$show_priv" = "YES" ]; then
    echo "==================== PRIVATE KEY START ===================="; cat "$key_path"; echo "===================== PRIVATE KEY END ====================="
  fi
}

configure_key_login() {
  local opt
  while true; do
    ui_title "SSH 密钥登录配置"
    ui_option 1 "粘贴已有公钥并写入 authorized_keys"
    ui_option 2 "自动生成 ed25519 密钥对（默认不输出私钥）"
    ui_back
    ui_prompt opt
    case "$opt" in
      1) configure_key_login_existing; pause_return ;;
      2) generate_key_login_and_output_private; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

authorized_keys_ok_for_user() {
  local user="$1" home_dir auth_file
  home_dir="$(getent passwd "$user" | cut -d: -f6)"; auth_file="${home_dir}/.ssh/authorized_keys"
  [ -s "$auth_file" ] || return 1
  chmod 700 "${home_dir}/.ssh" 2>/dev/null || true
  chmod 600 "$auth_file" 2>/dev/null || true
}

toggle_password_login() {
  local opt user backup_dir
  ui_title "密码登录开关"
  echo_warn "关闭密码登录前，必须确认密钥登录可用，否则可能无法登录。"
  ui_option 1 "开启密码登录"
  ui_option 2 "关闭密码登录"
  ui_back
  ui_prompt opt
  case "$opt" in
    1)
      backup_dir="$(sshd_backup_all)"
      sshd_ensure_include_first && sshd_dropin_set_lines PasswordAuthentication yes && sshd_dropin_set_lines KbdInteractiveAuthentication yes && sshd_dropin_set_lines ChallengeResponseAuthentication yes && sshd_validate_config && restart_ssh_service || { sshd_restore_backup "$backup_dir"; return 1; }
      echo_color "密码登录已开启。" ;;
    2)
      read -r -p "请输入已确认可密钥登录的用户名（默认 root）: " user; user="${user:-root}"
      if ! authorized_keys_ok_for_user "$user"; then echo_error "$user 的 authorized_keys 不存在或为空，拒绝关闭密码登录。"; return 1; fi
      confirm_yes "确认已经另开终端测试密钥登录成功？输入 YES 继续: " || { echo_warn "已取消。"; return 0; }
      backup_dir="$(sshd_backup_all)"
      sshd_ensure_include_first && sshd_dropin_set_lines PasswordAuthentication no && sshd_dropin_set_lines KbdInteractiveAuthentication no && sshd_dropin_set_lines ChallengeResponseAuthentication no && sshd_validate_config && restart_ssh_service || { sshd_restore_backup "$backup_dir"; return 1; }
      echo_color "密码登录已关闭。" ;;
    0) return 0 ;;
    *) echo_error "无效选项"; return 1 ;;
  esac
}

manage_root_login_user() {
  local opt user pass group backup_dir
  ui_title "root 登录 / sudo 用户管理"
  echo_warn "关闭 root 登录前，必须新建并测试普通 sudo 用户。"
  ui_option 1 "新增 sudo 用户，并关闭 root SSH 登录"
  ui_option 2 "恢复 root SSH 登录"
  ui_back
  ui_prompt opt
  case "$opt" in
    1)
      read -r -p "请输入新用户名（输入 q 取消）: " user
      [[ "$user" =~ ^[Qq]$ || -z "$user" ]] && { echo_warn "已取消。"; return 0; }
      id "$user" >/dev/null 2>&1 || useradd -m -s /bin/bash "$user"
      read -s -p "请输入新用户密码: " pass; echo
      [ -z "$pass" ] && { echo_error "密码不能为空。"; return 1; }
      echo "${user}:${pass}" | chpasswd
      if getent group sudo >/dev/null 2>&1; then group="sudo"; else group="wheel"; fi
      usermod -aG "$group" "$user"
      confirm_yes "确认已记录新用户密码，输入 YES 关闭 root SSH 登录: " || { echo_warn "已取消关闭 root。"; return 0; }
      backup_dir="$(sshd_backup_all)"
      sshd_ensure_include_first && sshd_dropin_set_lines PermitRootLogin no && sshd_validate_config && restart_ssh_service || { sshd_restore_backup "$backup_dir"; return 1; }
      echo_color "已创建/配置 sudo 用户：$user，并关闭 root SSH 登录。请另开终端测试。" ;;
    2)
      set_sshd_kv_effective PermitRootLogin yes && restart_ssh_service && echo_color "已恢复 root SSH 登录。" ;;
    0) return 0 ;;
    *) echo_error "无效选项" ;;
  esac
}

change_ssh_port_and_password_together() {
  change_ssh_port_only || return 1
  change_root_password_only || return 1
}

change_ssh_port_password() {
  local opt
  [ -f "$SSHD_MAIN" ] || { echo_error "找不到 $SSHD_MAIN"; return 1; }
  while true; do
    ui_title "SSH 端口 / 密码 / 密钥 / root 管理"
    echo_warn "请不要关闭当前 SSH 连接，另开终端测试新连接是否成功。"
    ui_option 1 "修改 SSH 端口（默认过渡保留旧端口，自动放行防火墙/SELinux/F2B）"
    ui_option 2 "只修改 root 密码（会提示 SSH 是否允许密码登录）"
    ui_option 3 "同时修改 SSH 端口和 root 密码"
    ui_option 4 "配置密钥登录 / 自动生成密钥"
    ui_option 5 "开启/关闭密码登录"
    ui_option 6 "关闭 root 登录并新增 sudo 用户 / 恢复 root 登录"
    ui_option 7 "查看当前 SSH 关键配置和冲突扫描"
    ui_back
    ui_prompt opt
    case "$opt" in
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

# ========== 外部脚本安全执行 ==========
run_remote_script_safely() {
  local name="$1" url="$2" opt tmp
  ui_title "$name · 远程脚本执行确认"
  echo_warn "来源：$url"
  echo_warn "风险：远程脚本会以 root 权限执行，请只在信任来源且已确认网络未被劫持时继续。"
  ui_option 1 "查看将执行的命令"
  ui_option 2 "下载到临时文件并预览前 120 行"
  ui_option 3 "下载后执行（需要输入 YES）"
  ui_back
  ui_prompt opt
  case "$opt" in
    1) echo "curl -fsSL --connect-timeout 10 --max-time 120 '$url' -o /tmp/${name}.sh && bash /tmp/${name}.sh" ;;
    2)
      command_exists curl || { echo_error "未检测到 curl。"; return 1; }
      tmp="$(mktemp /tmp/server-toolkit-remote.XXXXXX.sh)" || return 1
      curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$tmp" || { rm -f "$tmp"; echo_error "下载失败。"; return 1; }
      sed -n '1,120p' "$tmp"; echo_info "临时文件：$tmp" ;;
    3)
      command_exists curl || { echo_error "未检测到 curl。"; return 1; }
      confirm_yes "输入 YES 下载并执行远程脚本: " || { echo_warn "已取消。"; return 0; }
      tmp="$(mktemp /tmp/server-toolkit-remote.XXXXXX.sh)" || return 1
      curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$tmp" || { rm -f "$tmp"; echo_error "下载失败。"; return 1; }
      bash "$tmp"
      rm -f "$tmp" ;;
    0) return 0 ;;
    *) echo_error "无效选项" ;;
  esac
}

check_media_unlock() { run_remote_script_safely "check.unlock.media" "https://check.unlock.media"; }
yabs_test() { run_remote_script_safely "yabs" "https://yabs.sh"; }
check_ip_quality() { run_remote_script_safely "IP.Check.Place" "https://IP.Check.Place"; }

# ========== 服务器基本信息 ==========
format_bytes() {
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN{ if(b>=1099511627776) printf "%.2fT", b/1099511627776; else if(b>=1073741824) printf "%.2fG", b/1073741824; else if(b>=1048576) printf "%.2fM", b/1048576; else if(b>=1024) printf "%.2fK", b/1024; else printf "%dB", b; }'
}

get_default_iface() {
  command_exists ip && ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

cpu_usage_percent() {
  [ -r /proc/stat ] || { echo "0"; return; }
  local a b c d e f g h i j idle1 total1 idle2 total2 diff_idle diff_total
  read -r _ a b c d e f g h i j < /proc/stat
  idle1=$((d+e)); total1=$((a+b+c+d+e+f+g+h+i+j))
  sleep 1
  read -r _ a b c d e f g h i j < /proc/stat
  idle2=$((d+e)); total2=$((a+b+c+d+e+f+g+h+i+j))
  diff_idle=$((idle2-idle1)); diff_total=$((total2-total1))
  [ "$diff_total" -le 0 ] && echo "0" || awk -v i="$diff_idle" -v t="$diff_total" 'BEGIN{printf "%.0f", (1-i/t)*100}'
}

public_ip_detect() {
  local ip4 ip6
  if command_exists curl; then
    ip4="$(curl -4 -fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    ip6="$(curl -6 -fsS --connect-timeout 3 --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  fi
  [ -n "${ip4:-}" ] || ip4="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s|%s' "${ip4:-}" "${ip6:-}"
}

show_system_info() {
  local hostname osver kernel arch cpu_model cpu_cores cpu_freq cpu_usage loadavg tcp_count udp_count
  local mem_total mem_avail mem_used mem_pct swap_total swap_free swap_used swap_pct disk_total disk_used disk_pct
  local iface rx tx algo qdisc dns public_pair public_ip4 public_ip6 tz now uptime_sec days hours mins
  hostname="$(hostname 2>/dev/null || echo '-')"; osver="$OS_PRETTY_NAME"; kernel="$(uname -r 2>/dev/null || echo '-')"; arch="$(uname -m 2>/dev/null || echo '-')"
  cpu_model="$(awk -F: '/model name|Hardware/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"; [ -n "$cpu_model" ] || cpu_model="$(command_exists lscpu && lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"; [ -n "$cpu_model" ] || cpu_model="-"
  cpu_cores="$(command_exists nproc && nproc 2>/dev/null || echo '-')"
  cpu_freq="$(awk -F: '/cpu MHz/ {mhz=$2; gsub(/^[ \t]+/,"",mhz); printf "%.1f GHz", mhz/1000; exit}' /proc/cpuinfo 2>/dev/null)"; [ -n "$cpu_freq" ] || cpu_freq="-"
  cpu_usage="$(cpu_usage_percent)%"; loadavg="$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null || echo '-')"
  tcp_count="$(command_exists ss && ss -tan 2>/dev/null | awk 'NR>1{c++} END{print c+0}' || echo '-')"; udp_count="$(command_exists ss && ss -uan 2>/dev/null | awk 'NR>1{c++} END{print c+0}' || echo '-')"
  mem_total="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"; mem_avail="$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"; mem_used=$((mem_total-mem_avail)); [ "$mem_total" -gt 0 ] && mem_pct="$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{printf "%.2f", u/t*100}')" || mem_pct="0"
  mem_used="$(awk -v k="$mem_used" 'BEGIN{printf "%.2fM", k/1024}')"; mem_total="$(awk -v k="$mem_total" 'BEGIN{printf "%.2fM", k/1024}')"
  swap_total="$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"; swap_free="$(awk '/SwapFree/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"; swap_used=$((swap_total-swap_free)); [ "$swap_total" -gt 0 ] && swap_pct="$(awk -v u="$swap_used" -v t="$swap_total" 'BEGIN{printf "%.0f", u/t*100}')" || swap_pct="0"
  swap_used="$(awk -v k="$swap_used" 'BEGIN{printf "%.0fM", k/1024}')"; swap_total="$(awk -v k="$swap_total" 'BEGIN{printf "%.0fM", k/1024}')"
  disk_used="$(df -h / 2>/dev/null | awk 'NR==2{print $3}')"; disk_total="$(df -h / 2>/dev/null | awk 'NR==2{print $2}')"; disk_pct="$(df -h / 2>/dev/null | awk 'NR==2{print $5}')"
  iface="$(get_default_iface)"; [ -n "$iface" ] || iface="$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -n1)"; rx=0; tx=0; [ -n "$iface" ] && [ -r "/sys/class/net/$iface/statistics/rx_bytes" ] && rx="$(cat "/sys/class/net/$iface/statistics/rx_bytes")" && tx="$(cat "/sys/class/net/$iface/statistics/tx_bytes")"
  algo="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '-')"; qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '-')"; dns="$(grep -E '^nameserver ' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd' ' -)"; [ -n "$dns" ] || dns="-"
  public_pair="$(public_ip_detect)"; public_ip4="${public_pair%%|*}"; public_ip6="${public_pair#*|}"
  tz="$(timedatectl 2>/dev/null | awk -F': ' '/Time zone/ {print $2}' | awk '{print $1}')"; [ -n "$tz" ] || tz="$(date +%Z)"; now="$(date '+%F %T')"; uptime_sec="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"; days=$((uptime_sec/86400)); hours=$((uptime_sec%86400/3600)); mins=$((uptime_sec%3600/60))
  ui_title "服务器基本信息"
  printf "%-18s %s\n" "主机名:" "$hostname"; printf "%-18s %s\n" "系统版本:" "$osver"; printf "%-18s %s\n" "内核版本:" "$kernel"; printf "%-18s %s\n" "CPU架构:" "$arch"; printf "%-18s %s\n" "CPU型号:" "$cpu_model"; printf "%-18s %s\n" "CPU核心/频率:" "$cpu_cores / $cpu_freq"; printf "%-18s %s\n" "CPU占用:" "$cpu_usage"; printf "%-18s %s\n" "系统负载:" "$loadavg"; printf "%-18s %s|%s\n" "TCP|UDP连接:" "$tcp_count" "$udp_count"; printf "%-18s %s/%s (%s%%)\n" "物理内存:" "$mem_used" "$mem_total" "$mem_pct"; printf "%-18s %s/%s (%s%%)\n" "Swap:" "$swap_used" "$swap_total" "$swap_pct"; printf "%-18s %s/%s (%s)\n" "硬盘占用:" "$disk_used" "$disk_total" "$disk_pct"; printf "%-18s %s / %s\n" "总接收/发送:" "$(format_bytes "$rx")" "$(format_bytes "$tx")"; printf "%-18s %s %s\n" "网络算法:" "$algo" "$qdisc"; printf "%-18s %s\n" "IPv4公网:" "${public_ip4:--}"; printf "%-18s %s\n" "IPv6公网:" "${public_ip6:--}"; printf "%-18s %s\n" "DNS地址:" "$dns"; printf "%-18s %s %s\n" "系统时间:" "$tz" "$now"; printf "%-18s %s天 %s时 %s分\n" "运行时长:" "$days" "$hours" "$mins"
}

# ========== 定时重启 / 哪吒 ==========
setup_cron_reboot() {
  local interval marker tmp
  read -r -p "请输入每隔多少小时重启一次（例如 12，输入 q 取消）: " interval
  [[ "$interval" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  [[ "$interval" =~ ^[0-9]+$ ]] && [ "$interval" -ge 1 ] && [ "$interval" -le 720 ] || { echo_error "请输入 1-720 的有效小时数。"; return 1; }
  echo_warn "此操作会定时重启系统。"
  confirm_yes "输入 YES 写入定时重启任务: " || { echo_warn "已取消。"; return 0; }
  pkg_check_command_after_install crontab cron || return 1
  marker="# server-toolkit: reboot"
  tmp="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || return 1
  crontab -l 2>/dev/null | grep -v "$marker" > "$tmp" || true
  echo "0 */$interval * * * /sbin/reboot $marker" >> "$tmp"
  crontab "$tmp" && rm -f "$tmp" || { rm -f "$tmp"; echo_error "写入 crontab 失败。"; return 1; }
  echo_color "已设置每隔 $interval 小时自动重启。"
}

setup_nezha_agent_restart_cron() {
  local interval marker tmp
  read -r -p "请输入每隔多少小时重启 nezha-agent（例如 12，输入 q 取消）: " interval
  [[ "$interval" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  [[ "$interval" =~ ^[0-9]+$ ]] && [ "$interval" -ge 1 ] && [ "$interval" -le 720 ] || { echo_error "请输入 1-720 的有效小时数。"; return 1; }
  pkg_check_command_after_install crontab cron || return 1
  marker="# server-toolkit: nezha-agent-restart"
  tmp="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || return 1
  crontab -l 2>/dev/null | grep -v "$marker" > "$tmp" || true
  echo "0 */$interval * * * systemctl restart nezha-agent >/dev/null 2>&1 $marker" >> "$tmp"
  crontab "$tmp" && rm -f "$tmp" || { rm -f "$tmp"; return 1; }
  echo_color "已设置每隔 $interval 小时自动重启 nezha-agent。"
}

remove_nezha_agent_restart_cron() {
  local marker="# server-toolkit: nezha-agent-restart" tmp
  tmp="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || return 1
  crontab -l 2>/dev/null | grep -v "$marker" > "$tmp" || true
  crontab "$tmp" && rm -f "$tmp" || { rm -f "$tmp"; return 1; }
  echo_color "已移除 nezha-agent 定期重启任务。"
}

manage_nezha() {
  local opt confirm
  while true; do
    ui_title "哪吒面板管理"
    ui_option 1 "重启哪吒 Agent"
    ui_option 2 "重启哪吒 Dashboard"
    ui_option 3 "重启 Agent + Dashboard"
    ui_option 4 "设置定期重启 Agent"
    ui_option 5 "移除 Agent 定期重启任务"
    ui_option 6 "卸载哪吒面板/探针"
    ui_back
    ui_prompt opt
    case "$opt" in
      1) service_restart_safe nezha-agent || true; pause_return ;;
      2) service_restart_safe nezha-dashboard || true; pause_return ;;
      3) service_restart_safe nezha-agent || true; service_restart_safe nezha-dashboard || true; pause_return ;;
      4) setup_nezha_agent_restart_cron; pause_return ;;
      5) remove_nezha_agent_restart_cron; pause_return ;;
      6)
        echo_warn "此操作会删除 /opt/nezha /etc/nezha /var/log/nezha。"
        confirm_yes "输入 YES 确认卸载哪吒: " || { echo_warn "已取消。"; pause_return; continue; }
        has_systemd && systemctl disable --now nezha-agent 2>/dev/null || true
        has_systemd && systemctl disable --now nezha-dashboard 2>/dev/null || true
        rm -f /etc/systemd/system/nezha-agent.service /etc/systemd/system/nezha-dashboard.service
        rm -rf /opt/nezha /etc/nezha /var/log/nezha
        has_systemd && systemctl daemon-reload || true
        echo_color "哪吒面板/探针已移除。"; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ========== IPv6 / GRUB / sysctl ==========
grub_cfg_paths() {
  printf '%s\n' "/boot/grub/grub.cfg" "/boot/grub2/grub.cfg" "/boot/efi/EFI/$(ls /boot/efi/EFI 2>/dev/null | head -n1)/grub.cfg"
}

grub_remove_arg() {
  local file="$1" arg="$2"
  python3 - "$file" "$arg" <<'PYEOF' 2>/dev/null || sed -i "s/${arg}//g" "$file"
import sys, re
path, arg = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="ignore").read().splitlines()
out = []
for line in text:
    if line.startswith("GRUB_CMDLINE_LINUX="):
        m = re.match(r'GRUB_CMDLINE_LINUX="(.*)"', line)
        if m:
            parts = [x for x in m.group(1).split() if x != arg]
            line = 'GRUB_CMDLINE_LINUX="' + ' '.join(parts) + '"'
    out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PYEOF
}

grub_add_arg() {
  local file="$1" arg="$2"
  grep -q '^GRUB_CMDLINE_LINUX=' "$file" || echo 'GRUB_CMDLINE_LINUX=""' >> "$file"
  grep -q "$arg" "$file" || sed -i -E "s/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"${arg} /" "$file"
}

update_grub_ipv6_param() {
  local mode="$1" grub_file="/etc/default/grub" path
  if in_container; then echo_warn "检测到容器环境，跳过 GRUB 修改。"; return 0; fi
  [ -f "$grub_file" ] || { echo_warn "未找到 $grub_file，跳过 GRUB 修改。"; return 0; }
  backup_file "$grub_file"
  if [ "$mode" = "disable" ]; then grub_add_arg "$grub_file" "ipv6.disable=1"; else grub_remove_arg "$grub_file" "ipv6.disable=1"; fi
  if command_exists update-grub; then update-grub || true
  elif command_exists grub2-mkconfig; then
    for path in $(grub_cfg_paths); do [ -n "$path" ] && [ -e "$(dirname "$path")" ] && grub2-mkconfig -o "$path" >/dev/null 2>&1 && break; done
  fi
}

manage_ipv6() {
  local opt conf="/etc/sysctl.d/99-server-toolkit-ipv6.conf"
  ui_title "IPv6 一键开启/关闭"
  ui_option 1 "一键开启 IPv6"
  ui_option 2 "一键关闭 IPv6"
  ui_option 3 "查看 IPv6 状态"
  ui_back
  ui_prompt opt
  case "$opt" in
    1)
      backup_file "$conf"; cat > "$conf" <<EOF
# server-toolkit: ipv6 enable
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.lo.disable_ipv6=0
EOF
      update_grub_ipv6_param enable; sysctl --system >/dev/null 2>&1 || true; echo_color "IPv6 已设置为开启。" ;;
    2)
      echo_warn "关闭 IPv6 可能影响依赖 IPv6 的服务。"
      confirm_yes "输入 YES 关闭 IPv6: " || { echo_warn "已取消。"; return 0; }
      backup_file "$conf"; cat > "$conf" <<EOF
# server-toolkit: ipv6 disable
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
      update_grub_ipv6_param disable; sysctl --system >/dev/null 2>&1 || true; echo_color "IPv6 已设置为关闭，建议重启后确认。" ;;
    3)
      sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6 2>/dev/null || true
      command_exists ip && ip -6 addr || true
      grep -n 'ipv6.disable' /etc/default/grub 2>/dev/null || echo "GRUB 未发现 ipv6.disable 参数。" ;;
    0) return 0 ;;
    *) echo_error "无效选项" ;;
  esac
}

# ========== 安全加固 ==========
sysctl_key_exists() { sysctl -a 2>/dev/null | awk -F= '{gsub(/[ \t]/,"",$1); print $1}' | grep -qx "$1"; }
apply_sysctl_if_exists() {
  local file="$1" key="$2" val="$3"
  if sysctl_key_exists "$key"; then echo "$key=$val" >> "$file"; else echo_dim "跳过不存在的 sysctl：$key"; fi
}

apply_conservative_sysctl_hardening() {
  local conf="/etc/sysctl.d/98-server-toolkit-hardening.conf"
  backup_file "$conf"
  : > "$conf"
  echo "# server-toolkit conservative hardening v2.2" >> "$conf"
  apply_sysctl_if_exists "$conf" net.ipv4.tcp_syncookies 1
  apply_sysctl_if_exists "$conf" net.ipv4.conf.all.accept_redirects 0
  apply_sysctl_if_exists "$conf" net.ipv4.conf.default.accept_redirects 0
  apply_sysctl_if_exists "$conf" net.ipv4.conf.all.secure_redirects 0
  apply_sysctl_if_exists "$conf" net.ipv4.conf.default.secure_redirects 0
  apply_sysctl_if_exists "$conf" net.ipv4.conf.all.send_redirects 0
  apply_sysctl_if_exists "$conf" net.ipv4.conf.default.send_redirects 0
  apply_sysctl_if_exists "$conf" net.ipv4.conf.all.accept_source_route 0
  apply_sysctl_if_exists "$conf" net.ipv4.conf.default.accept_source_route 0
  apply_sysctl_if_exists "$conf" net.ipv4.icmp_echo_ignore_broadcasts 1
  apply_sysctl_if_exists "$conf" net.ipv4.icmp_ignore_bogus_error_responses 1
  apply_sysctl_if_exists "$conf" kernel.kptr_restrict 1
  apply_sysctl_if_exists "$conf" kernel.dmesg_restrict 1
  apply_sysctl_if_exists "$conf" fs.protected_hardlinks 1
  apply_sysctl_if_exists "$conf" fs.protected_symlinks 1
  sysctl --system >/dev/null 2>&1 || true
  echo_color "保守 sysctl 加固已应用。"
}

apply_regresshion_mitigation() {
  echo_warn "CVE-2024-6387 / regreSSHion 临时缓解适用于受影响 OpenSSH 版本，正式修复仍应升级 OpenSSH。"
  echo_warn "将设置 LoginGraceTime 0 和 MaxStartups 10:30:60，可能改变未认证连接行为。"
  confirm_yes "输入 YES 应用临时缓解: " || { echo_warn "已取消。"; return 0; }
  local backup_dir
  backup_dir="$(sshd_backup_all)"
  sshd_ensure_include_first && sshd_dropin_set_lines LoginGraceTime 0 && sshd_dropin_set_lines MaxStartups "10:30:60" && sshd_validate_config && restart_ssh_service || { sshd_restore_backup "$backup_dir"; return 1; }
  echo_color "已应用 regreSSHion 临时缓解。"
}

restore_regresshion_mitigation() {
  local backup_dir
  backup_dir="$(sshd_backup_all)"
  sshd_ensure_include_first && sshd_dropin_set_lines LoginGraceTime 30 && sshd_dropin_set_lines MaxStartups "10:30:100" && sshd_validate_config && restart_ssh_service || { sshd_restore_backup "$backup_dir"; return 1; }
  echo_color "已恢复 SSH 登录宽限时间和 MaxStartups。"
}

apply_copy_fail_mitigation() {
  local conf="/etc/modprobe.d/server-toolkit-copy-fail.conf"
  echo_warn "CVE-2026-31431 / Copy Fail：正式修复应以升级内核并重启为主。"
  echo_warn "临时禁用 authencesn 可能影响 IPsec/加密相关功能。"
  uname -r | sed 's/^/当前内核: /'
  lsmod 2>/dev/null | grep '^authencesn' && echo_warn "当前已加载 authencesn。" || echo_info "当前未发现 authencesn 已加载。"
  confirm_yes "输入 YES 写入临时禁用 authencesn: " || { echo_warn "已取消。"; return 0; }
  backup_file "$conf"
  cat > "$conf" <<EOF
# server-toolkit: CVE-2026-31431 temporary mitigation v2.2
install authencesn /bin/false
blacklist authencesn
EOF
  modprobe -r authencesn 2>/dev/null || true
  echo_color "已写入临时缓解。请尽快升级内核并重启。"
}

remove_copy_fail_mitigation() {
  local conf="/etc/modprobe.d/server-toolkit-copy-fail.conf"
  [ -f "$conf" ] || { echo_warn "未找到临时缓解配置。"; return 0; }
  backup_file "$conf"; rm -f "$conf"; echo_color "已移除 Copy Fail 临时缓解配置。"
}

harden_status() {
  ui_title "服务器加固状态"
  [ -f /etc/sysctl.d/98-server-toolkit-hardening.conf ] && cat /etc/sysctl.d/98-server-toolkit-hardening.conf || echo_warn "未发现 server-toolkit sysctl 加固配置。"
  echo
  sshd_effective_config 2>/dev/null | grep -Ei '^(logingracetime|maxstartups) ' || true
  echo
  [ -f /etc/modprobe.d/server-toolkit-copy-fail.conf ] && cat /etc/modprobe.d/server-toolkit-copy-fail.conf || echo_warn "未发现 Copy Fail 临时缓解配置。"
}

manage_hardening() {
  local opt
  while true; do
    ui_title "服务器加固"
    ui_option 1 "应用保守 sysctl 加固（逐项检测内核是否支持）"
    ui_option 2 "应用 CVE-2024-6387 / regreSSHion 临时缓解"
    ui_option 3 "恢复 regreSSHion 临时缓解"
    ui_option 4 "应用 CVE-2026-31431 / Copy Fail 临时缓解"
    ui_option 5 "移除 Copy Fail 临时缓解"
    ui_option 6 "查看加固状态"
    ui_back
    ui_prompt opt
    case "$opt" in
      1) apply_conservative_sysctl_hardening; pause_return ;;
      2) apply_regresshion_mitigation; pause_return ;;
      3) restore_regresshion_mitigation; pause_return ;;
      4) apply_copy_fail_mitigation; pause_return ;;
      5) remove_copy_fail_mitigation; pause_return ;;
      6) harden_status; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ========== 源修复 / 新服务器初始化 ==========
apt_supports_deb822_preferred() {
  [ "$OS_ID" = "debian" ] && case "$(os_codename)" in bookworm|trixie|forky|testing|sid) return 0;; esac
  [ "$OS_ID" = "ubuntu" ] && case "$(os_codename)" in noble|plucky|questing|resolute*) return 0;; esac
  [ -f /etc/apt/sources.list.d/debian.sources ] || [ -f /etc/apt/sources.list.d/ubuntu.sources ]
}

apt_components() {
  local code="$1"
  if [ "$OS_ID" = "ubuntu" ]; then echo "main restricted universe multiverse"; return; fi
  case "$code" in bookworm|trixie|forky|testing|sid|stable) echo "main contrib non-free non-free-firmware" ;; *) echo "main contrib non-free" ;; esac
}

apt_security_suite() {
  local code="$1"
  if [ "$OS_ID" = "ubuntu" ]; then echo "${code}-security"; return; fi
  case "$code" in buster) echo "buster/updates" ;; testing|sid|unstable) echo "" ;; *) echo "${code}-security" ;; esac
}

apt_candidates() {
  if [ "$OS_ID" = "ubuntu" ]; then
    cat <<EOF
official|官方源|http://archive.ubuntu.com/ubuntu|http://security.ubuntu.com/ubuntu|normal
google|Google 镜像|https://mirror.google.com/linux/ubuntu|https://mirror.google.com/linux/ubuntu|normal
cloudflare|Cloudflare 镜像|https://cloudflaremirrors.com/ubuntu|https://cloudflaremirrors.com/ubuntu|normal
yandex|Yandex 镜像|https://mirror.yandex.ru/ubuntu|https://mirror.yandex.ru/ubuntu|normal
old|Ubuntu old-releases|http://old-releases.ubuntu.com/ubuntu|http://old-releases.ubuntu.com/ubuntu|archive
EOF
  else
    cat <<EOF
official|官方源|http://deb.debian.org/debian|http://security.debian.org/debian-security|normal
google|Google 镜像|https://mirror.google.com/debian|http://security.debian.org/debian-security|normal
cloudflare|Cloudflare 镜像|https://cloudflaremirrors.com/debian|http://security.debian.org/debian-security|normal
yandex|Yandex 镜像|https://mirror.yandex.ru/debian|https://mirror.yandex.ru/debian-security|normal
archive|Debian archive|http://archive.debian.org/debian|http://archive.debian.org/debian-security|archive
EOF
  fi
}

apt_probe_release() {
  local base="$1" suite="$2" url
  command_exists curl || command_exists wget || return 0
  url="${base%/}/dists/${suite}/Release"
  if command_exists curl; then curl -fsI --connect-timeout 5 --max-time 10 "$url" >/dev/null 2>&1; else wget -q --spider --timeout=10 "$url" >/dev/null 2>&1; fi
}

apt_backup_snapshot() {
  local ts archive
  ts="$(date +%F_%H-%M-%S)"; mkdir -p "$TOOLKIT_BACKUP_DIR"
  archive="$TOOLKIT_BACKUP_DIR/apt-sources-${ts}.tar.gz"
  tar -czf "$archive" /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/apt.conf.d/99-server-toolkit-archive 2>/dev/null || true
  echo "$archive"
}

apt_restore_snapshot() {
  local archive="$1"
  [ -f "$archive" ] || return 1
  tar -xzf "$archive" -C / 2>/dev/null || return 1
}

apt_disable_conflicting_distro_sources() {
  local f ts
  ts="$(date +%F_%H-%M-%S)"
  mkdir -p /etc/apt/sources.list.d
  for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    if grep -Eiq '(debian|ubuntu|archive\.ubuntu|deb\.debian|security\.debian|old-releases\.ubuntu|cloudflaremirrors\.com/(debian|ubuntu)|mirror\.google\.com/(debian|linux/ubuntu)|mirror\.yandex\.ru/(debian|ubuntu))' "$f"; then
      mv "$f" "${f}.disabled-by-server-toolkit.${ts}"
      echo_warn "已停用可能冲突的发行版源：$f"
      echo_dim "恢复方式：mv '${f}.disabled-by-server-toolkit.${ts}' '$f'"
    fi
  done
}

apt_write_deb822() {
  local base="$1" secbase="$2" code="$3" archive_mode="$4" file components sec_suite
  components="$(apt_components "$code")"; mkdir -p /etc/apt/sources.list.d
  if [ "$OS_ID" = "ubuntu" ]; then file="/etc/apt/sources.list.d/ubuntu.sources"; else file="/etc/apt/sources.list.d/debian.sources"; fi
  backup_file "$file"; apt_disable_conflicting_distro_sources; : > /etc/apt/sources.list
  cat > "$file" <<EOF
# server-toolkit managed deb822 sources v2.2
Types: deb
URIs: $base
Suites: $code ${code}-updates ${code}-backports
Components: $components
Enabled: yes

EOF
  sec_suite="$(apt_security_suite "$code")"
  if [ -n "$sec_suite" ]; then
    cat >> "$file" <<EOF
Types: deb
URIs: $secbase
Suites: $sec_suite
Components: $components
Enabled: yes
EOF
  fi
  if [ "$archive_mode" = "archive" ]; then
    cat > /etc/apt/apt.conf.d/99-server-toolkit-archive <<EOF
Acquire::Check-Valid-Until "false";
EOF
  else
    rm -f /etc/apt/apt.conf.d/99-server-toolkit-archive
  fi
}

apt_write_list() {
  local base="$1" secbase="$2" code="$3" archive_mode="$4" file="/etc/apt/sources.list" components sec_suite
  components="$(apt_components "$code")"; backup_file "$file"; apt_disable_conflicting_distro_sources
  cat > "$file" <<EOF
# server-toolkit managed sources.list v2.2
deb $base $code $components
deb $base ${code}-updates $components
deb $base ${code}-backports $components
EOF
  sec_suite="$(apt_security_suite "$code")"
  [ -n "$sec_suite" ] && echo "deb $secbase $sec_suite $components" >> "$file"
  if [ "$archive_mode" = "archive" ]; then echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99-server-toolkit-archive; else rm -f /etc/apt/apt.conf.d/99-server-toolkit-archive; fi
}

apt_apply_source() {
  local label="$1" base="$2" secbase="$3" archive_mode="$4" code snapshot log="/tmp/server-toolkit-apt-update.log"
  code="$(os_codename)"; [ -n "$code" ] || { echo_error "无法识别系统代号。"; return 1; }
  if ! apt_probe_release "$base" "$code"; then echo_warn "预检未确认 $label 包含 $code，仍可继续尝试。"; fi
  snapshot="$(apt_backup_snapshot)"
  if apt_supports_deb822_preferred; then apt_write_deb822 "$base" "$secbase" "$code" "$archive_mode"; else apt_write_list "$base" "$secbase" "$code" "$archive_mode"; fi
  apt_env
  if apt-get update -y >"$log" 2>&1; then
    echo_color "APT 源修复成功：$label"
    return 0
  fi
  echo_error "apt-get update 失败，自动回滚到修改前备份。最近输出："
  tail -n 30 "$log" 2>/dev/null || true
  apt_restore_snapshot "$snapshot" || echo_error "自动回滚失败，请手动恢复：$snapshot"
  apt-get update -y >/dev/null 2>&1 || true
  return 1
}

repair_apt_sources_auto() {
  local code key label base secbase mode confirm
  os_is_debian_like || { echo_warn "当前不是 Debian/Ubuntu，跳过 APT。"; return 0; }
  code="$(os_codename)"; [ -n "$code" ] || { echo_error "无法识别 VERSION_CODENAME。"; return 1; }
  ui_title "APT 源检测 / 自动修复"
  echo_info "系统：$OS_PRETTY_NAME，代号：$code"
  apt_env
  if apt-get update -y >/tmp/server-toolkit-apt-current.log 2>&1; then
    echo_color "当前 APT 源可正常 update。"
    confirm_yn "是否仍要选择官方/Google/Cloudflare/Yandex/归档源切换？[y/N]: " || return 0
  else
    echo_warn "当前 APT 源 update 失败，将尝试候选源。最近输出："
    tail -n 20 /tmp/server-toolkit-apt-current.log 2>/dev/null || true
  fi
  while IFS='|' read -r key label base secbase mode; do
    [ -n "$key" ] || continue
    if apt_probe_release "$base" "$code" || [ "$mode" = "archive" ]; then
      apt_apply_source "$label" "$base" "$secbase" "$mode" && return 0
    else
      echo_dim "跳过不可用候选：$label"
    fi
  done <<EOF
$(apt_candidates)
EOF
  echo_error "APT 自动修复失败。"
  return 1
}

apt_source_interactive_chooser() {
  local idx=1 tmp opt line key label base secbase mode
  os_is_debian_like || { echo_warn "当前不是 Debian/Ubuntu，跳过 APT。"; return 0; }
  tmp="$(mktemp /tmp/server-toolkit-apt-candidates.XXXXXX)" || return 1
  ui_title "APT 源池手动选择"
  while IFS='|' read -r key label base secbase mode; do
    [ -n "$key" ] || continue
    printf '%s|%s|%s|%s|%s\n' "$idx" "$label" "$base" "$secbase" "$mode" >> "$tmp"
    ui_option "$idx" "$label - $base"
    idx=$((idx+1))
  done <<EOF
$(apt_candidates)
EOF
  ui_back; ui_prompt opt
  [ "$opt" = "0" ] && { rm -f "$tmp"; return 0; }
  line="$(awk -F'|' -v n="$opt" '$1==n{print; exit}' "$tmp")"; rm -f "$tmp"
  [ -n "$line" ] || { echo_error "选项不存在。"; return 1; }
  IFS='|' read -r _ label base secbase mode <<EOF
$line
EOF
  apt_apply_source "$label" "$base" "$secbase" "$mode"
}

show_apt_sources_current() {
  ui_title "当前 APT 源"
  [ -f /etc/apt/sources.list ] && { echo_info "/etc/apt/sources.list"; sed -n '1,220p' /etc/apt/sources.list; }
  if [ -d /etc/apt/sources.list.d ]; then
    for f in /etc/apt/sources.list.d/*; do [ -f "$f" ] && { echo_dim "----- $f -----"; sed -n '1,120p' "$f"; }; done
  fi
}

rhel_repo_detect() {
  ui_title "DNF/YUM 源可用性检测"
  echo_info "系统：$OS_PRETTY_NAME"
  if os_is_rhel_exact; then
    if command_exists subscription-manager; then subscription-manager status 2>/dev/null || true; else echo_warn "RHEL 未检测到 subscription-manager；未注册时不建议乱改官方源。"; fi
  fi
  pkg_makecache && echo_color "当前 DNF/YUM 源 makecache 成功。" || echo_error "当前 DNF/YUM 源 makecache 失败。"
  command_exists dnf && dnf repolist all 2>/dev/null | sed -n '1,120p' || yum repolist all 2>/dev/null | sed -n '1,120p' || true
}

centos7_write_vault_repo() {
  local file="/etc/yum.repos.d/CentOS-Base.repo"
  backup_file "$file"
  cat > "$file" <<'EOF'
# server-toolkit managed CentOS 7 vault repo v2.2
[base]
name=CentOS-7 - Base - vault.centos.org
baseurl=http://vault.centos.org/7.9.2009/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[updates]
name=CentOS-7 - Updates - vault.centos.org
baseurl=http://vault.centos.org/7.9.2009/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[extras]
name=CentOS-7 - Extras - vault.centos.org
baseurl=http://vault.centos.org/7.9.2009/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
EOF
  sed -i 's|RPM-GPG-KEY-CentOS-7|RPM-GPG-KEY-CentOS-7|g' "$file"
}

rhel_enable_crb_epel() {
  local major
  major="$(os_major_version)"
  if os_is_rhel_exact; then
    echo_warn "RHEL 官方源依赖订阅注册；不自动改 repo。需要先 subscription-manager register/attach。"
    return 0
  fi
  pkg_install dnf-plugins-core || true
  if command_exists dnf; then
    dnf config-manager --set-enabled crb >/dev/null 2>&1 || dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
  fi
  if confirm_yn "是否安装/启用 EPEL？[y/N]: "; then
    case "$OS_ID" in
      fedora) echo_warn "Fedora 通常不需要 EPEL，已跳过。" ;;
      amzn) amazon-linux-extras install -y epel 2>/dev/null || pkg_install epel-release || true ;;
      *) pkg_install epel-release || echo_warn "epel-release 安装失败，可能需要按发行版手动处理。" ;;
    esac
  fi
}

repair_rhel_repos_auto() {
  ui_title "DNF/YUM 源自动修复"
  echo_info "系统：$OS_PRETTY_NAME"
  if os_is_rhel_exact; then
    echo_warn "RHEL 不自动替换官方源。未注册时请先处理 subscription-manager。"
    command_exists subscription-manager && subscription-manager status 2>/dev/null || true
    return 0
  fi
  if [ "$OS_ID" = "centos" ] && [ "$(os_major_version)" = "7" ]; then
    echo_warn "CentOS 7 已 EOL，将写入 vault.centos.org。"
    confirm_yes "输入 YES 写入 CentOS 7 vault 源: " || { echo_warn "已取消。"; return 0; }
    centos7_write_vault_repo
  fi
  rhel_enable_crb_epel
  pkg_makecache && echo_color "DNF/YUM 源检测/修复完成。" || echo_error "makecache 仍失败，请检查网络/DNS/发行版状态。"
}

openssh_security_upgrade() {
  echo_info "正在尝试升级 OpenSSH 安全更新..."
  pkg_update || true
  if os_is_debian_like; then pkg_install openssh-server openssh-client; apt-get install -y --only-upgrade $(apt_opts) openssh-server openssh-client || true
  elif os_is_redhat_like; then pkg_install openssh-server openssh-client; case "${PKG_MANAGER:-$(detect_pkg_manager)}" in dnf) dnf upgrade -y openssh openssh-server openssh-clients || true ;; yum) yum update -y openssh openssh-server openssh-clients || true ;; esac
  else echo_warn "当前系统暂不支持自动升级 OpenSSH。"; fi
}

new_server_basic_update() {
  echo_warn "保守更新：修复/检测源 -> 安装常用工具 -> 尝试升级 OpenSSH。"
  confirm_yes "输入 YES 执行保守更新: " || { echo_warn "已取消。"; return 0; }
  os_is_debian_like && repair_apt_sources_auto || true
  os_is_redhat_like && rhel_repo_detect || true
  pkg_update || return 1
  pkg_install wget curl sudo vim git unzip openssh-server openssh-client cron dnsutils net-tools || true
  openssh_security_upgrade
}

new_server_full_update() {
  echo_warn "全量更新可能升级内核、替换大量包，生产环境请先快照。"
  confirm_yes "输入 YES 执行全量更新: " || { echo_warn "已取消。"; return 0; }
  os_is_debian_like && repair_apt_sources_auto || true
  os_is_redhat_like && rhel_repo_detect || true
  pkg_update || return 1
  pkg_full_upgrade || return 1
  pkg_install unzip vim git curl screen htop vnstat net-tools dnsutils sudo wget openssh-server openssh-client cron || true
  openssh_security_upgrade
}

new_server_init_menu() {
  local opt
  while true; do
    ui_title "新服务器初始化 / 源修复 / 更新"
    echo_info "系统识别：$OS_PRETTY_NAME / ID=$OS_ID / ID_LIKE=$OS_ID_LIKE / VERSION_ID=$OS_VERSION_ID / CODENAME=$OS_VERSION_CODENAME / PKG=$(detect_pkg_manager)"
    ui_option 1 "Debian/Ubuntu：自动检测并修复 APT 源（deb822/list，失败自动回滚）"
    ui_option 2 "Debian/Ubuntu：手动选择官方/Google/Cloudflare/Yandex/归档源"
    ui_option 3 "Debian/Ubuntu：查看当前 APT 源"
    ui_option 4 "红帽系：只检测 DNF/YUM 源可用性"
    ui_option 5 "红帽系：自动修复/启用 CRB/EPEL/CentOS7 vault（RHEL 不乱改）"
    ui_option 6 "保守更新：常用工具 + OpenSSH"
    ui_option 7 "全量更新：系统升级 + 常用工具 + OpenSSH"
    ui_option 8 "仅尝试升级 OpenSSH"
    ui_back
    ui_prompt opt
    case "$opt" in
      1) repair_apt_sources_auto; pause_return ;;
      2) apt_source_interactive_chooser; pause_return ;;
      3) show_apt_sources_current; pause_return ;;
      4) rhel_repo_detect; pause_return ;;
      5) repair_rhel_repos_auto; pause_return ;;
      6) new_server_basic_update; pause_return ;;
      7) new_server_full_update; pause_return ;;
      8) openssh_security_upgrade; pause_return ;;
      0) return 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

# ========== 主菜单 ==========
menu_text_width() {
  local text="$1" chars bytes wide
  chars=$(printf "%s" "$text" | wc -m | awk '{print $1}')
  bytes=$(printf "%s" "$text" | wc -c | awk '{print $1}')
  wide=$(( (bytes - chars) / 2 ))
  echo $((chars + wide))
}
menu_pad_right() {
  local text="$1" target="$2" width i
  width=$(menu_text_width "$text")
  printf "%s" "$text"
  for ((i=width; i<target; i++)); do printf " "; done
}
menu_row() {
  local left="$1" right="$2"
  printf "  \033[1;32m"; menu_pad_right "$left" 38; printf "\033[0m │ \033[1;32m"; menu_pad_right "$right" 38; printf "\033[0m\n"
}
print_menu() {
  [ -n "${TERM:-}" ] && clear 2>/dev/null || true
  printf "\n"
  printf "\033[1;36m┌──────────────────────────────────────────────────────────────────────────────┐\033[0m\n"
  printf "\033[1;36m│\033[0m  \033[1;35m"; menu_pad_right "server-toolkit ${SERVER_TOOLKIT_VERSION} · Linux 服务器工具箱" 74; printf "\033[0m \033[1;36m│\033[0m\n"
  printf "\033[1;36m└──────────────────────────────────────────────────────────────────────────────┘\033[0m\n"
  printf "\033[1;36m功能菜单\033[0m\n"
  printf "\033[2m──────────────────────────────────────────────────────────────────────────────\033[0m\n"
  menu_row "1)  时间同步（timesyncd/chrony）"  "9)  YABS 测试"
  menu_row "2)  防火墙开启/关闭"              "10) 设置定时重启"
  menu_row "3)  SELinux 开启/关闭"             "11) 哪吒面板管理"
  menu_row "4)  SSH 安全性增强向导"            "12) IP 质量检测"
  menu_row "5)  Fail2Ban 管理"                 "13) IPv6 一键开启/关闭"
  menu_row "6)  SSH 端口/密码/密钥/root 管理"  "14) 服务器加固"
  menu_row "7)  流媒体解锁检测"                "15) 新服务器初始化/源修复"
  menu_row "8)  显示服务器基本信息"            "0)  退出"
  printf "\033[2m──────────────────────────────────────────────────────────────────────────────\033[0m\n"
}

main() {
  local option
  load_os_release
  detect_pkg_manager >/dev/null
  require_root
  while true; do
    print_menu
    read -r -p "请选择一个操作: " option
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
      10) setup_cron_reboot; pause_return ;;
      11) manage_nezha ;;
      12) check_ip_quality; pause_return ;;
      13) manage_ipv6; pause_return ;;
      14) manage_hardening ;;
      15) new_server_init_menu ;;
      0) echo_color "已退出。"; exit 0 ;;
      *) echo_error "无效选项"; pause_return ;;
    esac
  done
}

main "$@"
