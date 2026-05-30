#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2015,SC2155
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SERVER_TOOLKIT_VERSION="v2.3"
ST_LOG_FILE="/var/log/server-toolkit.log"

# ============================================================
# server-toolkit.sh v2.3
# 适用：Debian / Ubuntu / CentOS 7 / RHEL-like
# 原则：先备份、先检测、尽量不破坏当前 SSH 会话。
# ============================================================

# ========== 彩色输出 ==========
echo_color() { printf "\033[1;32m%s\033[0m\n" "$1"; }
echo_warn()  { printf "\033[1;33m%s\033[0m\n" "$1"; }
echo_error() { printf "\033[1;31m%s\033[0m\n" "$1"; }
echo_info()  { printf "\033[1;36m%s\033[0m\n" "$1"; }
echo_blue()  { printf "\033[1;34m%s\033[0m\n" "$1"; }
echo_pink()  { printf "\033[1;35m%s\033[0m\n" "$1"; }
echo_dim()   { printf "\033[2m%s\033[0m\n" "$1"; }

log_line() {
  local level="$1"
  shift || true
  mkdir -p "$(dirname "$ST_LOG_FILE")" 2>/dev/null || true
  printf '%s [%s] %s\n' "$(date '+%F %T %Z' 2>/dev/null || date)" "$level" "$*" >> "$ST_LOG_FILE" 2>/dev/null || true
}

log_info()  { log_line "INFO" "$@"; echo_info "$*"; }
log_warn()  { log_line "WARN" "$@"; echo_warn "$*"; }
log_error() { log_line "ERROR" "$@"; echo_error "$*"; }

show_recent_log() {
  local file="${1:-$ST_LOG_FILE}"
  local lines="${2:-40}"
  [ -f "$file" ] || return 0
  echo_info "最近日志：$file"
  tail -n "$lines" "$file" 2>/dev/null || true
}

run_cmd_show_error() {
  local desc="$1"
  shift
  local tmp rc
  tmp="$(mktemp /tmp/server-toolkit-cmd.XXXXXX)" || return 1
  log_line "INFO" "RUN ${desc}: $*"
  if "$@" >"$tmp" 2>&1; then
    cat "$tmp" >> "$ST_LOG_FILE" 2>/dev/null || true
    rm -f "$tmp"
    return 0
  fi
  rc=$?
  cat "$tmp" >> "$ST_LOG_FILE" 2>/dev/null || true
  echo_error "${desc} 失败，返回码：${rc}"
  tail -n 40 "$tmp" 2>/dev/null || true
  rm -f "$tmp"
  return "$rc"
}

pause_return() {
  echo
  read -r -p "按 Enter 返回菜单..."
}

run_menu_action() {
  local name="$1"
  local func="$2"
  local pause_mode="${3:-pause}"
  local rc

  echo
  echo_info "开始执行：${name}"
  if declare -F "$func" >/dev/null 2>&1; then
    "$func"
    rc=$?
  else
    echo_error "内部错误：函数未定义：${func}"
    rc=127
  fi

  if [ "$rc" -eq 0 ]; then
    echo_color "执行完成：${name}"
  else
    echo_error "执行失败：${name}，返回码：${rc}"
    show_recent_log "$ST_LOG_FILE" 30
  fi

  [ "$pause_mode" = "nopause" ] || pause_return
  return "$rc"
}

run_submenu_action() {
  run_menu_action "$1" "$2" pause
}

# ========== UI 辅助函数（v2.3 统一风格） ==========
UI_LINE="────────────────────────────────────────────────────────────"

ui_hr() {
  printf "\e[1;36m%s\e[0m\n" "$UI_LINE"
}

ui_title() {
  echo
  ui_hr
  printf "\e[1;35m  %s\e[0m\n" "$1"
  ui_hr
}

ui_option() {
  # 统一子菜单风格：不用复杂边框，避免中文宽度在不同终端错位。
  local num="$1"
  local text="$2"
  printf "  \e[1;32m%-4s\e[0m %s\n" "${num})" "$text"
}

ui_back() {
  printf "  \e[1;31m%-4s\e[0m %s\n" "0)" "返回"
}

ui_prompt() {
  read -r -p "请选择: " "$1"
}

# ========== 基础检测 ==========
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo_error "请使用 root 运行此脚本。"
    exit 1
  fi
}

is_redhat() { [ -f /etc/redhat-release ]; }
is_debian_like() { [ -f /etc/debian_version ]; }
is_centos7() {
  [ -f /etc/os-release ] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || return 1
  [ "${ID:-}" = "centos" ] && [[ "${VERSION_ID:-}" == 7* ]]
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt-get"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  else
    echo "unknown"
    return 1
  fi
}

apt_env_export() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export APT_LISTCHANGES_FRONTEND=none
  export UCF_FORCE_CONFFOLD=1
}

backup_file() {
  local file="$1"
  if [ -f "$file" ]; then
    cp -a "$file" "${file}.bak.$(date +%F_%H-%M-%S)"
  fi
}

ssh_service_name() {
  if has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    echo "ssh"
  else
    echo "sshd"
  fi
}

ensure_sshd_runtime_dir() {
  mkdir -p /run/sshd /var/run/sshd 2>/dev/null || true
  chmod 755 /run/sshd /var/run/sshd 2>/dev/null || true
}

restart_ssh_service() {
  local svc
  svc="$(ssh_service_name)"
  echo_color "正在重启 SSH 服务：$svc ..."
  ensure_sshd_runtime_dir
  if has_systemd; then
    run_cmd_show_error "重启 SSH 服务 $svc" systemctl restart "$svc" || {
      journalctl -u "$svc" -n 40 --no-pager 2>/dev/null || true
      return 1
    }
    systemctl is-active "$svc" >/dev/null 2>&1 || {
      echo_error "SSH 服务未处于 active 状态，请检查配置是否错误。"
      systemctl status "$svc" --no-pager -l 2>/dev/null || true
      return 1
    }
  elif command -v service >/dev/null 2>&1; then
    run_cmd_show_error "重启 SSH 服务 $svc" service "$svc" restart || run_cmd_show_error "重启 SSH 服务 ssh" service ssh restart || {
      echo_error "重启 SSH 服务失败，请手动检查。"
      return 1
    }
  else
    echo_error "重启 $svc 失败，请手动检查：systemctl status $svc"
    return 1
  fi
  return 0
}

test_sshd_config() {
  local log="/tmp/server-toolkit-sshd-test.log"
  ensure_sshd_runtime_dir
  if command -v sshd >/dev/null 2>&1; then
    if sshd -t >"$log" 2>&1; then
      return 0
    fi
    echo_error "sshd -t 检测失败，输出如下："
    cat "$log" 2>/dev/null || true
    cat "$log" >> "$ST_LOG_FILE" 2>/dev/null || true
    return 1
  fi
  echo_warn "未找到 sshd 命令，跳过配置语法检测。"
  return 0
}

test_sshd_effective_config() {
  local log="/tmp/server-toolkit-sshd-effective.log"
  ensure_sshd_runtime_dir
  command -v sshd >/dev/null 2>&1 || return 0
  if sshd -T >"$log" 2>&1; then
    return 0
  fi
  echo_error "sshd -T 检测失败，输出如下："
  cat "$log" 2>/dev/null || true
  cat "$log" >> "$ST_LOG_FILE" 2>/dev/null || true
  return 1
}

sshd_managed_config_file() {
  local main="/etc/ssh/sshd_config"
  local dir="/etc/ssh/sshd_config.d"
  if [ -f "$main" ] && grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$main"; then
    mkdir -p "$dir"
    echo "$dir/99-server-toolkit.conf"
  else
    echo "$main"
  fi
}

snapshot_ssh_config() {
  local dir f base
  dir="$(mktemp -d /tmp/server-toolkit-ssh-backup.XXXXXX)" || return 1
  for f in /etc/ssh/sshd_config "$(sshd_managed_config_file)"; do
    [ -f "$f" ] || continue
    base="$(printf '%s' "$f" | sed 's#/#__#g')"
    cp -a "$f" "${dir}/${base}" 2>/dev/null || true
  done
  printf '%s\n' "$dir"
}

restore_ssh_config_snapshot() {
  local dir="$1"
  local f target
  [ -d "$dir" ] || return 1
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    target="$(basename "$f" | sed 's#__#/#g')"
    cp -a "$f" "$target" 2>/dev/null || true
  done
}

verify_sshd_port_effective() {
  local port="$1"
  ensure_sshd_runtime_dir
  command -v sshd >/dev/null 2>&1 || return 0
  sshd -T 2>/tmp/server-toolkit-sshd-effective.log | awk '$1=="port"{print $2}' | grep -qx "$port"
}

set_sshd_kv() {
  local key="$1"
  local val="$2"
  local file
  local tmp

  file="$(sshd_managed_config_file)"
  [ -f "$file" ] || touch "$file"
  backup_file "$file"
  tmp="$(mktemp /tmp/server-toolkit-sshd.XXXXXX)" || return 1

  if awk -v key="$key" -v val="$val" '
    BEGIN { done=0; in_match=0; pat="^[#[:space:]]*" key "[[:space:]]+" }
    /^[[:space:]]*Match[[:space:]]/ {
      if (!done) { print key " " val; done=1 }
      in_match=1
      print
      next
    }
    !in_match && $0 ~ pat {
      if (!done) { print key " " val; done=1 }
      next
    }
    { print }
    END {
      if (!done) print key " " val
    }
  ' "$file" > "$tmp"; then
    cat "$tmp" > "$file" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

delete_sshd_kv() {
  local key="$1"
  local file tmp

  for file in /etc/ssh/sshd_config "$(sshd_managed_config_file)"; do
    [ -f "$file" ] || continue
    backup_file "$file"
    tmp="$(mktemp /tmp/server-toolkit-sshd.XXXXXX)" || return 1

    if awk -v key="$key" '
      BEGIN { in_match=0; pat="^[#[:space:]]*" key "[[:space:]]+" }
      /^[[:space:]]*Match[[:space:]]/ { in_match=1; print; next }
      !in_match && $0 ~ pat { next }
      { print }
    ' "$file" > "$tmp"; then
      cat "$tmp" > "$file" || { rm -f "$tmp"; return 1; }
    else
      rm -f "$tmp"
      return 1
    fi
    rm -f "$tmp"
  done
}

get_current_ssh_ports() {
  local ports
  ensure_sshd_runtime_dir
  ports="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -n | paste -sd, - 2>/dev/null || true)"
  if [ -z "$ports" ] && [ -f /etc/ssh/sshd_config ]; then
    ports="$(awk '
      /^[[:space:]]*Match[[:space:]]/ { exit }
      /^[[:space:]]*Port[[:space:]]+[0-9]+/ { print $2 }
    ' /etc/ssh/sshd_config | sort -n | paste -sd, - 2>/dev/null || true)"
  fi
  # 如果 sshd -T 不可用，回退到数字 22，避免防火墙放行时因 "ssh" 字符串被跳过。
  if [ -z "$ports" ]; then
    ports="22"
  fi
  echo "$ports"
}

port_is_current_ssh_port() {
  local port="$1"
  local ports p
  local port_list=()
  ports="$(get_current_ssh_ports)"
  IFS=',' read -r -a port_list <<< "$ports"
  for p in "${port_list[@]}"; do
    [ "$p" = "$port" ] && return 0
  done
  return 1
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  else
    return 1
  fi
}

repair_centos7_yum_repos() {
  is_centos7 || { echo_warn "当前不是 CentOS 7，跳过 Vault 源修复。"; return 0; }

  local tag repo
  tag="$(date +%F_%H-%M-%S)"
  mkdir -p /etc/yum.repos.d

  for repo in /etc/yum.repos.d/CentOS-*.repo; do
    [ -f "$repo" ] || continue
    cp -a "$repo" "${repo}.bak.${tag}" 2>/dev/null || true
  done

  cat > /etc/yum.repos.d/CentOS-Base.repo <<'EOF'
# server-toolkit v2.3: CentOS 7 EOL Vault source
[base]
name=CentOS-7.9.2009 - Base - vault.centos.org
baseurl=http://vault.centos.org/7.9.2009/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[updates]
name=CentOS-7.9.2009 - Updates - vault.centos.org
baseurl=http://vault.centos.org/7.9.2009/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[extras]
name=CentOS-7.9.2009 - Extras - vault.centos.org
baseurl=http://vault.centos.org/7.9.2009/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[centosplus]
name=CentOS-7.9.2009 - Plus - vault.centos.org
baseurl=http://vault.centos.org/7.9.2009/centosplus/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=0
EOF

  yum clean all >/dev/null 2>&1 || true
  grep -q 'vault.centos.org/7.9.2009' /etc/yum.repos.d/CentOS-Base.repo || {
    echo_error "CentOS 7 Vault repo 写入校验失败。"
    return 1
  }
  if run_cmd_show_error "CentOS 7 Vault makecache" yum makecache -y; then
    echo_color "CentOS 7 Vault 源已修复。"
    return 0
  fi

  echo_error "CentOS 7 Vault 源修复后 yum makecache 仍失败，请检查网络/DNS。"
  return 1
}

repair_epel7_yum_repo() {
  is_centos7 || { echo_warn "当前不是 CentOS 7，跳过 EPEL 7 源修复。"; return 0; }

  local gpgcheck
  if ! rpm -q epel-release >/dev/null 2>&1; then
    yum_install_auto epel-release >/dev/null 2>&1 || true
  fi

  gpgcheck=1
  [ -f /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7 ] || gpgcheck=0

  cat > /etc/yum.repos.d/epel.repo <<EOF
# server-toolkit v2.3: EPEL 7 archive source
[epel]
name=Extra Packages for Enterprise Linux 7 - archive
baseurl=https://archives.fedoraproject.org/pub/archive/epel/7/\$basearch
enabled=1
gpgcheck=${gpgcheck}
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7

[epel-debuginfo]
name=Extra Packages for Enterprise Linux 7 - archive - Debug
baseurl=https://archives.fedoraproject.org/pub/archive/epel/7/\$basearch/debug
enabled=0
gpgcheck=${gpgcheck}
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7

[epel-source]
name=Extra Packages for Enterprise Linux 7 - archive - Source
baseurl=https://archives.fedoraproject.org/pub/archive/epel/7/SRPMS
enabled=0
gpgcheck=${gpgcheck}
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7
EOF

  yum clean metadata >/dev/null 2>&1 || true
  grep -q 'archives.fedoraproject.org/pub/archive/epel/7' /etc/yum.repos.d/epel.repo || {
    echo_error "EPEL 7 archive repo 写入校验失败。"
    return 1
  }
  run_cmd_show_error "EPEL 7 archive makecache" yum --enablerepo=epel makecache -y || {
    echo_error "EPEL 7 archive makecache 失败。请检查 DNS/网络/TLS 或手动检查 /etc/yum.repos.d/epel.repo。"
    return 1
  }
  echo_color "EPEL 7 archive 源已写入。"
}

pkg_makecache() {
  local pm
  pm="$(detect_pkg_manager)" || { echo_error "未检测到 apt-get/dnf/yum。"; return 1; }
  case "$pm" in
    apt-get)
      apt_env_export
      run_cmd_show_error "apt-get update" apt-get update
      ;;
    dnf)
      run_cmd_show_error "dnf makecache" dnf makecache -y || run_cmd_show_error "dnf makecache --refresh" dnf makecache --refresh -y
      ;;
    yum)
      run_cmd_show_error "yum makecache" yum makecache -y || { is_centos7 && repair_centos7_yum_repos && run_cmd_show_error "yum makecache" yum makecache -y; }
      ;;
  esac
}

pkg_update() {
  pkg_makecache
}

pkg_install() {
  local pm
  pm="$(detect_pkg_manager)" || { echo_error "未检测到 apt-get/dnf/yum。"; return 1; }
  [ "$#" -gt 0 ] || { echo_error "pkg_install 未收到包名。"; return 1; }
  case "$pm" in
    apt-get)
      apt_env_export
      run_cmd_show_error "apt-get install $*" apt-get install -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold "$@"
      ;;
    dnf)
      run_cmd_show_error "dnf install $*" dnf install -y "$@"
      ;;
    yum)
      run_cmd_show_error "yum install $*" yum install -y "$@" || { is_centos7 && repair_centos7_yum_repos && run_cmd_show_error "yum install $*" yum install -y "$@"; }
      ;;
  esac
}

pkg_upgrade() {
  local pm
  pm="$(detect_pkg_manager)" || { echo_error "未检测到 apt-get/dnf/yum。"; return 1; }
  case "$pm" in
    apt-get)
      apt_env_export
      if [ "$#" -gt 0 ]; then
        run_cmd_show_error "apt-get upgrade packages $*" apt-get install -y --only-upgrade \
          -o Dpkg::Options::=--force-confdef \
          -o Dpkg::Options::=--force-confold "$@"
      else
        run_cmd_show_error "apt-get upgrade" apt-get upgrade -y \
          -o Dpkg::Options::=--force-confdef \
          -o Dpkg::Options::=--force-confold
      fi
      ;;
    dnf)
      run_cmd_show_error "dnf upgrade ${*:-all}" dnf upgrade -y "$@"
      ;;
    yum)
      run_cmd_show_error "yum update ${*:-all}" yum update -y "$@" || { is_centos7 && repair_centos7_yum_repos && run_cmd_show_error "yum update ${*:-all}" yum update -y "$@"; }
      ;;
  esac
}

yum_makecache_auto() { pkg_makecache; }
yum_install_auto() { pkg_install "$@"; }
yum_update_auto() { pkg_upgrade "$@"; }

ensure_cron_service() {
  if ! command -v crontab >/dev/null 2>&1; then
    echo_warn "未检测到 crontab，正在安装 cron 服务..."
    if is_redhat; then
      yum_install_auto cronie || return 1
    else
      pkg_update && pkg_install cron || return 1
    fi
  fi

  if has_systemd; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^cron\.service'; then
      systemctl enable --now cron >/dev/null 2>&1 || true
    elif systemctl list-unit-files 2>/dev/null | grep -q '^crond\.service'; then
      systemctl enable --now crond >/dev/null 2>&1 || true
    fi
  fi

  command -v crontab >/dev/null 2>&1
}

remove_cron_lines_by_marker() {
  local marker="$1"
  local tmpcron
  command -v crontab >/dev/null 2>&1 || return 0
  tmpcron="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || return 1
  crontab -l 2>/dev/null | grep -F -v "$marker" > "$tmpcron" || true
  crontab "$tmpcron" >/dev/null 2>&1 || true
  rm -f "$tmpcron"
}

run_remote_bash() {
  local name="$1"
  local url="$2"
  local confirm tmpfile rc size

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo_warn "未检测到 curl/wget，正在尝试安装 curl..."
    pkg_update || true
    pkg_install curl || { echo_error "无法安装 curl，不能下载远程脚本。"; return 1; }
  fi

  echo_warn "即将从以下地址下载并执行：$url"
  read -r -p "确认执行 ${name}？[y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; return 0; }

  tmpfile="$(mktemp /tmp/server-toolkit-remote.XXXXXX)" || return 1
  log_line "INFO" "download remote script name=${name} url=${url}"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 120 -o "$tmpfile" "$url" > /tmp/server-toolkit-remote-download.log 2>&1
    rc=$?
  else
    wget -q -T 120 -O "$tmpfile" "$url" > /tmp/server-toolkit-remote-download.log 2>&1
    rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    echo_error "${name} 下载失败，返回码：$rc"
    echo_warn "可能原因：DNS、网络、TLS、远程地址不可达。"
    cat /tmp/server-toolkit-remote-download.log 2>/dev/null || true
    rm -f "$tmpfile" /tmp/server-toolkit-remote-download.log
    return "$rc"
  fi

  if [ ! -s "$tmpfile" ]; then
    echo_error "${name} 下载结果为空，已取消执行。"
    rm -f "$tmpfile" /tmp/server-toolkit-remote-download.log
    return 1
  fi

  size="$(wc -c < "$tmpfile" 2>/dev/null | awk '{print $1}')"
  echo_info "远程脚本已下载：${size:-unknown} bytes"
  echo_info "前 8 行预览："
  sed -n '1,8p' "$tmpfile" 2>/dev/null || true
  echo
  read -r -p "确认执行已下载的 ${name} 脚本？[y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消执行。"; rm -f "$tmpfile" /tmp/server-toolkit-remote-download.log; return 0; }

  bash "$tmpfile" 2>&1 | tee -a "$ST_LOG_FILE"
  rc=${PIPESTATUS[0]}
  rm -f "$tmpfile" /tmp/server-toolkit-remote-download.log

  if [ "$rc" -ne 0 ]; then
    echo_error "${name} 远程脚本执行失败，返回码：$rc"
    return "$rc"
  fi
  return 0
}

# ========== 1. 时间同步 ==========
chrony_service_name() {
  if has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^chrony\.service'; then
    echo "chrony"
  elif has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^chronyd\.service'; then
    echo "chronyd"
  elif is_redhat; then
    echo "chronyd"
  else
    echo "chrony"
  fi
}

chrony_config_file() {
  if [ -f /etc/chrony/chrony.conf ]; then
    echo "/etc/chrony/chrony.conf"
  elif [ -f /etc/chrony.conf ]; then
    echo "/etc/chrony.conf"
  elif is_redhat; then
    echo "/etc/chrony.conf"
  else
    echo "/etc/chrony/chrony.conf"
  fi
}

install_chrony_if_needed() {
  if command -v chronyd >/dev/null 2>&1 && command -v chronyc >/dev/null 2>&1; then
    return 0
  fi

  echo_warn "未检测到 chrony，正在安装..."
  if is_redhat; then
    yum_install_auto chrony || return 1
  else
    pkg_update && pkg_install chrony || return 1
  fi
}

configure_chrony_sources() {
  local conf marker_begin marker_end tmp
  conf="$(chrony_config_file)"
  marker_begin="# server-toolkit: chrony sources begin"
  marker_end="# server-toolkit: chrony sources end"

  mkdir -p "$(dirname "$conf")"
  [ -f "$conf" ] || touch "$conf"
  backup_file "$conf"

  tmp="$(mktemp /tmp/server-toolkit-chrony.XXXXXX)" || return 1
  sed "/${marker_begin}/,/${marker_end}/d" "$conf" > "$tmp"
  cat >> "$tmp" <<EOF

${marker_begin}
server time.cloudflare.com iburst
server time.google.com iburst
pool pool.ntp.org iburst
${marker_end}
EOF

  if ! grep -Eq '^[[:space:]]*makestep[[:space:]]+' "$tmp"; then
    echo "makestep 1.0 3" >> "$tmp"
  fi
  if ! grep -Eq '^[[:space:]]*rtcsync([[:space:]]+|$)' "$tmp"; then
    echo "rtcsync" >> "$tmp"
  fi

  cat "$tmp" > "$conf"
  rm -f "$tmp"
}

disable_conflicting_time_daemons() {
  has_systemd || return 0
  systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
  systemctl disable --now ntp >/dev/null 2>&1 || true
  systemctl disable --now ntpd >/dev/null 2>&1 || true
}

cleanup_legacy_ntpdate_cron() {
  remove_cron_lines_by_marker "# server-toolkit: time_sync"
  remove_cron_lines_by_marker "# server-toolkit: http_time_sync"
  rm -f /usr/local/sbin/server-toolkit-ntpdate-sync 2>/dev/null || true
  rm -f /usr/local/sbin/server-toolkit-http-time-sync 2>/dev/null || true
}

time_sync_ntpdate_fallback() {
  echo_warn "chrony 配置失败，尝试 ntpdate 一次性兜底同步。"
  if ! command -v ntpdate >/dev/null 2>&1; then
    if is_redhat; then
      yum_install_auto ntpdate || yum_install_auto ntp || true
    else
      pkg_update && (pkg_install ntpsec-ntpdate || pkg_install ntpdate || true)
    fi
  fi

  if command -v ntpdate >/dev/null 2>&1; then
    ntpdate -u time.cloudflare.com || ntpdate -u time.google.com
  else
    return 1
  fi
}

time_sync() {
  local svc

  ui_title "时间同步 · chrony"
  echo_color "正在配置 chrony 时间同步（Debian/Ubuntu/CentOS 7 通用）..."

  cleanup_legacy_ntpdate_cron

  if ! install_chrony_if_needed; then
    time_sync_ntpdate_fallback || {
      echo_error "chrony/ntpdate 均不可用，无法配置时间同步。请先修复软件源或网络后再试。"
      return 1
    }
    return 0
  fi

  configure_chrony_sources || return 1
  disable_conflicting_time_daemons

  svc="$(chrony_service_name)"
  if has_systemd; then
    systemctl enable --now "$svc" >/dev/null 2>&1 || systemctl restart "$svc" || {
      echo_error "启动 chrony 服务失败，请检查：systemctl status $svc"
      return 1
    }
  elif command -v service >/dev/null 2>&1; then
    service "$svc" restart 2>/dev/null || service chronyd restart 2>/dev/null || true
  fi

  chronyc -a makestep >/dev/null 2>&1 || true
  command -v hwclock >/dev/null 2>&1 && hwclock -w >/dev/null 2>&1 || true

  echo_color "chrony 时间同步已配置完成。"
  echo_info "chrony 服务：$svc"
  echo_info "配置文件：$(chrony_config_file)"
  echo_info "当前同步状态："
  chronyc tracking 2>/dev/null || timedatectl status 2>/dev/null || echo_warn "无法读取同步状态，可能是容器限制或 chrony 尚未完成首次同步。"
}

# ========== 2. 防火墙管理 ==========
allow_ssh_ports_before_firewall_enable() {
  local ports p
  local port_list=()
  ports="$(get_current_ssh_ports)"
  [ -z "$ports" ] && ports="22"
  IFS=',' read -r -a port_list <<< "$ports"
  for p in "${port_list[@]}"; do
    if [[ "$p" =~ ^[0-9]+$ ]]; then
      # firewalld 未启动时 firewall-cmd 可能失败，因此优先尝试 firewall-offline-cmd。
      firewall-offline-cmd --add-port="${p}/tcp" >/dev/null 2>&1 || true
      firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
      ufw allow "${p}/tcp" >/dev/null 2>&1 || true
    fi
  done
}

firewall_status() {
  echo_info "firewalld 状态："
  if has_systemd; then
    systemctl is-active firewalld 2>/dev/null || true
  else
    echo_warn "当前环境未检测到 systemd。"
  fi
  echo_info "ufw 状态："
  ufw status 2>/dev/null || echo_warn "ufw 未安装或不可用"
}

manage_firewall() {
  while true; do
    echo
    ui_title "防火墙管理"
    ui_option 1 "查看防火墙状态"
    ui_option 2 "开启防火墙（自动放行当前 SSH 端口，尽量避免断连）"
    ui_option 3 "关闭防火墙"
    ui_back
    read -r -p "请选择: " opt
    case "$opt" in
      1)
        firewall_status
        pause_return
        ;;
      2)
        echo_warn "开启防火墙前会自动放行当前 SSH 端口：$(get_current_ssh_ports)"
        read -r -p "确认开启？[y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; continue; }
        allow_ssh_ports_before_firewall_enable
        if command -v firewall-cmd >/dev/null 2>&1 || { has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^firewalld\.service'; }; then
          has_systemd && systemctl enable --now firewalld 2>/dev/null || true
          allow_ssh_ports_before_firewall_enable
          firewall-cmd --reload >/dev/null 2>&1 || true
          echo_color "firewalld 已尝试开启，并已放行当前 SSH 端口。"
        elif command -v ufw >/dev/null 2>&1; then
          yes | ufw enable >/dev/null 2>&1 || true
          echo_color "ufw 已尝试开启，并已放行当前 SSH 端口。"
        else
          echo_warn "未检测到 firewalld/ufw，未执行开启。"
        fi
        pause_return
        ;;
      3)
        echo_warn "此操作只关闭系统内 firewalld / ufw，不影响云厂商安全组。"
        read -r -p "确认关闭防火墙服务？[y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; continue; }
        has_systemd && systemctl stop firewalld 2>/dev/null || true
        has_systemd && systemctl disable firewalld 2>/dev/null || true
        ufw disable >/dev/null 2>&1 || true
        has_systemd && systemctl stop ufw 2>/dev/null || true
        has_systemd && systemctl disable ufw 2>/dev/null || true
        echo_color "防火墙服务已尝试关闭。"
        pause_return
        ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

allow_tcp_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1

  if command -v firewall-offline-cmd >/dev/null 2>&1; then
    firewall-offline-cmd --add-port="${port}/tcp" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
}

configure_selinux_ssh_port() {
  local port="$1"
  is_redhat || return 0
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  command -v getenforce >/dev/null 2>&1 || return 0
  [ "$(getenforce 2>/dev/null || echo Disabled)" = "Disabled" ] && return 0

  if ! command -v semanage >/dev/null 2>&1; then
    echo_warn "SELinux 已启用但缺少 semanage，正在尝试安装策略工具..."
    yum_install_auto policycoreutils-python >/dev/null 2>&1 || yum_install_auto policycoreutils-python-utils >/dev/null 2>&1 || true
  fi

  if ! command -v semanage >/dev/null 2>&1; then
    echo_warn "无法安装 semanage；若 SSH 新端口启动失败，请手动执行：semanage port -a -t ssh_port_t -p tcp ${port}"
    return 0
  fi

  if semanage port -l 2>/dev/null | awk '$1=="ssh_port_t" && $2=="tcp"{print $0}' | tr ',' ' ' | grep -qw "$port"; then
    return 0
  fi

  semanage port -a -t ssh_port_t -p tcp "$port" >/dev/null 2>&1 || \
    semanage port -m -t ssh_port_t -p tcp "$port" >/dev/null 2>&1 || {
      echo_warn "SELinux 放行 SSH 端口 ${port} 失败；如重启 SSH 失败，请检查 semanage port -l。"
      return 0
    }
  echo_color "SELinux 已允许 sshd 监听 TCP ${port}。"
}

prepare_ssh_port_change() {
  local port="$1"
  configure_selinux_ssh_port "$port"
  allow_tcp_port "$port"
}

refresh_fail2ban_ssh_port_if_present() {
  if command -v fail2ban-client >/dev/null 2>&1 || { has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^fail2ban\.service'; }; then
    fail2ban_refresh_ssh_port >/dev/null 2>&1 || true
  fi
}

# ========== 3. SELinux 管理 ==========
manage_selinux() {
  while true; do
    echo
    ui_title "SELinux 管理"
    if command -v getenforce >/dev/null 2>&1; then
      echo "当前状态: $(getenforce 2>/dev/null || true)"
    else
      echo_warn "未检测到 getenforce；Debian/Ubuntu 通常不使用 SELinux。"
    fi
    ui_option 1 "开启 SELinux（Enforcing，可能需要重启）"
    ui_option 2 "关闭 SELinux（Disabled，需重启后完全生效）"
    ui_option 3 "设置为宽容模式（Permissive，当前会话生效）"
    ui_back
    read -r -p "请选择: " opt
    case "$opt" in
      1)
        if [ -f /etc/selinux/config ]; then
          backup_file /etc/selinux/config
          sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
          setenforce 1 2>/dev/null || true
          echo_color "SELinux 已设置为 Enforcing；如当前未完全生效，请重启。"
        else
          echo_warn "未找到 /etc/selinux/config。"
        fi
        pause_return
        ;;
      2)
        if [ -f /etc/selinux/config ]; then
          backup_file /etc/selinux/config
          sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
          setenforce 0 2>/dev/null || true
          echo_color "SELinux 已设置为 Disabled，需重启后完全生效。"
        else
          echo_warn "未找到 SELinux 配置文件（Debian/Ubuntu 属正常）。"
        fi
        pause_return
        ;;
      3)
        if [ -f /etc/selinux/config ]; then
          backup_file /etc/selinux/config
          sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
          setenforce 0 2>/dev/null || true
          echo_color "SELinux 已设置为 Permissive。"
        else
          echo_warn "未找到 SELinux 配置文件。"
        fi
        pause_return
        ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

# ========== 4. SSH 安全性增强 ==========
show_ssh_effective_config() {
  echo_info "当前 SSH 最终生效配置（部分关键项）："
  if command -v sshd >/dev/null 2>&1; then
    sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitemptypasswords|maxauthtries|logingracetime|usedns|x11forwarding|allowtcpforwarding|clientaliveinterval|clientalivecountmax|maxstartups) ' || true
  else
    echo_warn "未找到 sshd 命令。"
  fi
}

ssh_security_recommended() {
  local f="/etc/ssh/sshd_config"
  backup_file "$f"

  echo_info "应用保守推荐配置：不禁用 root、不禁用密码、不改端口。"
  # OpenSSH 7.6+ 已移除 Protocol 选项；保留它会导致新系统 sshd -t 失败。
  delete_sshd_kv "Protocol"
  set_sshd_kv "LoginGraceTime" "30"
  set_sshd_kv "MaxAuthTries" "3"
  set_sshd_kv "PermitEmptyPasswords" "no"
  set_sshd_kv "UseDNS" "no"
  set_sshd_kv "X11Forwarding" "no"
  set_sshd_kv "PermitUserEnvironment" "no"
  set_sshd_kv "ClientAliveInterval" "300"
  set_sshd_kv "ClientAliveCountMax" "2"

  if ! test_sshd_config; then
    echo_error "sshd 配置检测失败，未重启 SSH。"
    return 1
  fi

  restart_ssh_service && echo_color "SSH 保守安全增强已完成。"
}

ssh_security_custom() {
  local f="/etc/ssh/sshd_config"
  backup_file "$f"

  while true; do
    echo
    ui_title "SSH 安全性增强 · 逐项配置"
    ui_option 1 "MaxAuthTries：限制单次连接最大认证失败次数；优点：降低暴力破解效率；坏处：输错几次会断开。"
    ui_option 2 "LoginGraceTime：限制登录认证窗口；优点：减少僵尸连接；坏处：弱网下登录时间更短。"
    ui_option 3 "PermitEmptyPasswords：禁止空密码；强烈建议 no。"
    ui_option 4 "UseDNS：关闭反向 DNS 查询；优点：登录更快；坏处：日志中少部分主机名信息减少。"
    ui_option 5 "X11Forwarding：关闭 X11 转发；优点：减少攻击面；坏处：不能通过 SSH 转发图形界面。"
    ui_option 6 "AllowTcpForwarding：是否允许 SSH 隧道；关闭可减少滥用；坏处：影响端口转发/跳板用途。"
    ui_option 7 "ClientAliveInterval/CountMax：空闲连接保活/断开策略；优点：减少僵尸会话；坏处：长时间挂机会断开。"
    ui_option 8 "查看当前 SSH 生效配置"
    ui_option 0 "返回并应用"
    read -r -p "请选择: " opt

    case "$opt" in
      1)
        read -r -p "请输入 MaxAuthTries（建议 3）: " v
        [[ "$v" =~ ^[0-9]+$ ]] && set_sshd_kv "MaxAuthTries" "$v" || echo_error "输入无效"
        ;;
      2)
        read -r -p "请输入 LoginGraceTime 秒数（建议 30）: " v
        [[ "$v" =~ ^[0-9]+$ ]] && set_sshd_kv "LoginGraceTime" "$v" || echo_error "输入无效"
        ;;
      3)
        echo_warn "空密码非常危险，建议永远设置为 no。"
        read -r -p "是否设置 PermitEmptyPasswords no？[Y/n]: " v
        [[ "$v" =~ ^[Nn]$ ]] || set_sshd_kv "PermitEmptyPasswords" "no"
        ;;
      4)
        read -r -p "是否关闭 UseDNS？建议关闭，输入 y 确认：[y/N]: " v
        [[ "$v" =~ ^[Yy]$ ]] && set_sshd_kv "UseDNS" "no"
        ;;
      5)
        read -r -p "是否关闭 X11Forwarding？建议关闭，输入 y 确认：[y/N]: " v
        [[ "$v" =~ ^[Yy]$ ]] && set_sshd_kv "X11Forwarding" "no"
        ;;
      6)
        echo_warn "如果你依赖 SSH 隧道/端口转发，不要关闭。"
        read -r -p "AllowTcpForwarding 设置为 yes/no: " v
        [[ "$v" == "yes" || "$v" == "no" ]] && set_sshd_kv "AllowTcpForwarding" "$v" || echo_error "只能输入 yes 或 no"
        ;;
      7)
        read -r -p "ClientAliveInterval（建议 300）: " a
        read -r -p "ClientAliveCountMax（建议 2）: " b
        if [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]]; then
          set_sshd_kv "ClientAliveInterval" "$a"
          set_sshd_kv "ClientAliveCountMax" "$b"
        else
          echo_error "输入无效"
        fi
        ;;
      8)
        show_ssh_effective_config
        ;;
      0)
        if ! test_sshd_config; then
          echo_error "sshd 配置检测失败，未重启 SSH。"
          return 1
        fi
        restart_ssh_service && echo_color "SSH 配置已应用。"
        return 0
        ;;
      *)
        echo_error "无效选项"
        ;;
    esac
  done
}

secure_ssh() {
  local SSH_CONFIG_FILE="/etc/ssh/sshd_config"
  [ -f "$SSH_CONFIG_FILE" ] || { echo_error "找不到 $SSH_CONFIG_FILE"; return 1; }

  while true; do
    echo
    ui_title "SSH 安全性增强向导"
    ui_option 1 "查看当前 SSH 关键配置"
    ui_option 2 "一键保守增强（不禁 root、不禁密码、不改端口）"
    ui_option 3 "逐项配置（带说明）"
    ui_back
    read -r -p "请选择: " opt

    case "$opt" in
      1) run_submenu_action "查看当前 SSH 关键配置" show_ssh_effective_config ;;
      2) run_submenu_action "一键保守增强 SSH" ssh_security_recommended ;;
      3) run_submenu_action "逐项配置 SSH" ssh_security_custom ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

# ========== 5. Fail2Ban 管理 ==========
fail2ban_log_path() {
  if is_redhat; then
    echo "/var/log/secure"
  else
    echo "/var/log/auth.log"
  fi
}

fail2ban_detect_backend_lines() {
  # v2.3：Debian 12/Ubuntu minimal 常常没有 /var/log/auth.log，使用 systemd backend 更稳。
  # 若非 systemd 环境，则回退到传统日志文件，并尽量创建空日志文件避免服务启动失败。
  local logpath
  logpath="$(fail2ban_log_path)"

  if command -v journalctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && python3 -c 'import systemd.journal' >/dev/null 2>&1; then
    printf 'backend = systemd\n'
  else
    [ -e "$logpath" ] || touch "$logpath" 2>/dev/null || true
    printf 'backend = auto\n'
    printf 'logpath = %s\n' "$logpath"
  fi
}

fail2ban_write_base_local() {
  local level="${1:-INFO}"
  mkdir -p /etc/fail2ban
  cat > /etc/fail2ban/fail2ban.local <<EOF
# server-toolkit: fail2ban 全局配置
# allowipv6 = auto 可消除部分新版 fail2ban 的 allowipv6 警告。
# loglevel 越低日志越少，DEBUG 最详细但日志最多。
[Definition]
allowipv6 = auto
loglevel = $level
EOF
}

fail2ban_validate_and_restart() {
  if command -v fail2ban-client >/dev/null 2>&1; then
    if ! fail2ban-client -t >/tmp/server-toolkit-fail2ban-test.log 2>&1; then
      echo_error "Fail2Ban 配置检测失败，未重启服务。检测输出如下："
      cat /tmp/server-toolkit-fail2ban-test.log 2>/dev/null || true
      fail2ban_restore_last_jail
      return 1
    fi
  fi

  has_systemd && systemctl enable fail2ban >/dev/null 2>&1 || true
  if { has_systemd && systemctl restart fail2ban; } || { command -v service >/dev/null 2>&1 && service fail2ban restart; }; then
    echo_color "Fail2Ban 服务已成功启动/重启。"
    return 0
  else
    echo_error "Fail2Ban 重启失败，最近日志如下："
    journalctl -u fail2ban -n 30 --no-pager 2>/dev/null || true
    fail2ban_restore_last_jail
    return 1
  fi
}

fail2ban_restore_last_jail() {
  local backup="/tmp/server-toolkit-fail2ban-jail.local.prev"
  if [ -f "$backup" ]; then
    cp -a "$backup" /etc/fail2ban/jail.local 2>/dev/null || true
    echo_warn "已尝试回滚 /etc/fail2ban/jail.local。"
  fi
}

fail2ban_write_sshd_jail() {
  local ssh_ports="$1"
  local bantime="$2"
  local findtime="$3"
  local maxretry="$4"
  local ignoreip="$5"
  local backend_lines
  backend_lines="$(fail2ban_detect_backend_lines)"

  mkdir -p /etc/fail2ban
  [ -f /etc/fail2ban/jail.local ] && cp -a /etc/fail2ban/jail.local /tmp/server-toolkit-fail2ban-jail.local.prev 2>/dev/null || true
  backup_file /etc/fail2ban/jail.local

  cat > /etc/fail2ban/jail.local <<EOF
# server-toolkit: fail2ban sshd 防护配置
# bantime  = 封禁时长，单位秒；3600 = 1 小时
# findtime = 统计失败次数的时间窗口，单位秒；600 = 10 分钟
# maxretry = 在 findtime 内失败多少次后封禁
# ignoreip = 白名单 IP，不会被封禁；建议加入你的固定管理 IP
# port     = 当前 SSH 端口；支持多个端口，例如 22,2222
# backend  = v2.3 自动选择；systemd 环境优先用 journal，避免 /var/log/auth.log 不存在导致启动失败

[DEFAULT]
bantime = $bantime
findtime = $findtime
maxretry = $maxretry
ignoreip = 127.0.0.1/8 ::1 $ignoreip

[sshd]
enabled = true
port = $ssh_ports
$backend_lines
EOF
}

validate_fail2ban_ports() {
  [[ "${1:-}" =~ ^[0-9]+(,[0-9]+)*$ ]]
}

validate_fail2ban_ignoreip() {
  local value="${1:-}"
  [ -z "$value" ] && return 0
  [[ "$value" =~ ^[0-9A-Za-z.:/_,-]+([[:space:]][0-9A-Za-z.:/_,-]+)*$ ]]
}

fail2ban_current_value() {
  local key="$1"
  local default="$2"
  local file="/etc/fail2ban/jail.local"
  local value
  if [ -f "$file" ]; then
    value="$(awk -F= -v k="$key" '
      $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
        v=$2
        sub(/^[[:space:]]+/, "", v)
        sub(/[[:space:]]+$/, "", v)
        print v
        exit
      }
    ' "$file")"
  fi
  printf '%s\n' "${value:-$default}"
}

setup_fail2ban_default() {
  echo_color "正在安装并配置 Fail2Ban..."
  if is_redhat; then
    yum_install_auto epel-release || true
    is_centos7 && repair_epel7_yum_repo
    yum_install_auto fail2ban python3-systemd || yum_install_auto fail2ban || return 1
  else
    pkg_update || return 1
    pkg_install fail2ban python3-systemd || pkg_install fail2ban || return 1
  fi

  local ssh_ports
  ssh_ports="$(get_current_ssh_ports)"

  fail2ban_write_base_local "INFO"
  fail2ban_write_sshd_jail "$ssh_ports" "3600" "600" "3" ""

  if fail2ban_validate_and_restart; then
    echo_color "Fail2Ban 已安装并配置完成。"
    echo_info "已自动写入当前 SSH 端口：${ssh_ports}"
  else
    echo_error "Fail2Ban 安装完成，但配置/启动失败。已保留备份文件，请根据上方日志排查。"
    return 1
  fi
}

fail2ban_refresh_ssh_port() {
  local ssh_ports bantime findtime maxretry ignoreip
  ssh_ports="$(get_current_ssh_ports)"
  validate_fail2ban_ports "$ssh_ports" || { echo_error "自动识别到的 SSH 端口格式异常：$ssh_ports"; return 1; }

  bantime="$(fail2ban_current_value bantime 3600)"
  findtime="$(fail2ban_current_value findtime 600)"
  maxretry="$(fail2ban_current_value maxretry 3)"
  ignoreip="$(fail2ban_current_value ignoreip "")"
  ignoreip="$(printf '%s\n' "$ignoreip" | sed 's/127\.0\.0\.1\/8//g; s/::1//g; s/^ *//; s/ *$//')"
  validate_fail2ban_ignoreip "$ignoreip" || {
    echo_warn "现有 ignoreip 含有不安全字符，刷新端口时不沿用该值。"
    ignoreip=""
  }

  fail2ban_write_base_local "INFO"
  fail2ban_write_sshd_jail "$ssh_ports" "$bantime" "$findtime" "$maxretry" "$ignoreip"

  if fail2ban_validate_and_restart; then
    echo_color "已自动识别并刷新 Fail2Ban SSH 端口：${ssh_ports}"
    echo_info "已保留现有 bantime/findtime/maxretry/ignoreip（如可安全解析）。"
  else
    return 1
  fi
}

fail2ban_status() {
  echo_info "Fail2Ban 服务状态："
  if has_systemd; then
    systemctl status fail2ban --no-pager -l || true
  else
    service fail2ban status 2>/dev/null || echo_warn "当前环境未检测到 systemd。"
  fi
  echo
  echo_info "Fail2Ban jail 列表："
  fail2ban-client status 2>/dev/null || echo_warn "fail2ban-client 不可用或服务未运行。"
}

fail2ban_recent_logs() {
  echo_info "最近 50 条 Fail2Ban 日志："
  journalctl -u fail2ban -n 50 --no-pager 2>/dev/null || {
    [ -f /var/log/fail2ban.log ] && tail -n 50 /var/log/fail2ban.log || echo_warn "未找到 Fail2Ban 日志。"
  }
}

fail2ban_set_loglevel() {
  echo "可选等级：CRITICAL / ERROR / WARNING / NOTICE / INFO / DEBUG"
  read -r -p "请输入日志等级（建议 INFO）: " level

  case "$level" in
    CRITICAL|ERROR|WARNING|NOTICE|INFO|DEBUG) ;;
    *) echo_error "日志等级无效"; return 1 ;;
  esac

  fail2ban_write_base_local "$level"
  fail2ban_validate_and_restart || return 1
  echo_color "Fail2Ban 日志等级已设置为：$level"
}

fail2ban_config_jail() {
  local bantime findtime maxretry ignoreip ssh_ports custom_ports
  ssh_ports="$(get_current_ssh_ports)"

  echo_info "自动识别到当前 SSH 端口：${ssh_ports}"
  read -r -p "是否手动覆盖端口？直接回车使用自动识别端口，或输入例如 22,2222: " custom_ports
  [ -n "$custom_ports" ] && ssh_ports="$custom_ports"

  if ! validate_fail2ban_ports "$ssh_ports"; then
    echo_error "端口格式无效，只支持数字或逗号分隔，例如 22 或 22,2222。"
    return 1
  fi

  read -r -p "封禁时长 bantime 秒（默认 3600）: " bantime
  read -r -p "统计窗口 findtime 秒（默认 600）: " findtime
  read -r -p "失败次数 maxretry（默认 3）: " maxretry
  read -r -p "白名单 ignoreip，可空，例如 127.0.0.1/8 你的IP: " ignoreip

  bantime="${bantime:-3600}"
  findtime="${findtime:-600}"
  maxretry="${maxretry:-3}"

  if ! [[ "$bantime" =~ ^[0-9]+$ && "$findtime" =~ ^[0-9]+$ && "$maxretry" =~ ^[0-9]+$ ]]; then
    echo_error "bantime / findtime / maxretry 必须是数字"
    return 1
  fi
  if ! validate_fail2ban_ignoreip "$ignoreip"; then
    echo_error "ignoreip 含有不安全字符，只允许 IP/CIDR/主机名并用空格分隔。"
    return 1
  fi

  fail2ban_write_base_local "INFO"
  fail2ban_write_sshd_jail "$ssh_ports" "$bantime" "$findtime" "$maxretry" "$ignoreip"

  if fail2ban_validate_and_restart; then
    echo_color "Fail2Ban jail 配置已更新。"
  else
    return 1
  fi
}

fail2ban_unban_ip() {
  read -r -p "请输入要解封的 IP: " ip
  [ -z "$ip" ] && { echo_warn "已取消。"; return 0; }
  fail2ban-client set sshd unbanip "$ip" 2>/dev/null && echo_color "已尝试解封：$ip" || echo_error "解封失败，请确认 sshd jail 是否存在。"
}

manage_fail2ban() {
  while true; do
    echo
    ui_title "Fail2Ban 管理"
    ui_option 1 "安装/写入默认 SSH 防护配置（自动识别 SSH 端口）"
    ui_option 2 "自动识别当前 SSH 端口并刷新 Fail2Ban 配置"
    ui_option 3 "查看 Fail2Ban 服务状态"
    ui_option 4 "查看 sshd jail 状态"
    ui_option 5 "查看最近 50 条 Fail2Ban 日志"
    ui_option 6 "设置 Fail2Ban 日志等级"
    ui_option 7 "配置 sshd 防护参数（bantime/findtime/maxretry/ignoreip/port）"
    ui_option 8 "解封指定 IP"
    ui_back
    read -r -p "请选择: " opt

    case "$opt" in
      1) run_submenu_action "安装/写入默认 Fail2Ban SSH 防护配置" setup_fail2ban_default ;;
      2) run_submenu_action "刷新 Fail2Ban SSH 端口" fail2ban_refresh_ssh_port ;;
      3) run_submenu_action "查看 Fail2Ban 服务状态" fail2ban_status ;;
      4) fail2ban-client status sshd 2>/dev/null || echo_warn "sshd jail 未启用或 Fail2Ban 未运行。"; pause_return ;;
      5) run_submenu_action "查看 Fail2Ban 日志" fail2ban_recent_logs ;;
      6) run_submenu_action "设置 Fail2Ban 日志等级" fail2ban_set_loglevel ;;
      7) run_submenu_action "配置 Fail2Ban sshd jail" fail2ban_config_jail ;;
      8) run_submenu_action "解封指定 IP" fail2ban_unban_ip ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

# ========== 6. SSH 端口/密码/密钥/root管理 ==========
change_ssh_port_only() {
  local SSH_CONFIG_FILE="/etc/ssh/sshd_config"
  local new_port rollback_dir

  read -r -p "请输入新的 SSH 端口 (1-65535，输入 q 取消): " new_port
  [[ "$new_port" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }

  if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
    echo_error "端口不合法。"
    return 1
  fi

  if port_in_use "$new_port" && ! port_is_current_ssh_port "$new_port"; then
    echo_error "端口 $new_port 已被占用，请换一个。"
    return 1
  fi

  rollback_dir="$(snapshot_ssh_config)" || { echo_error "创建 SSH 配置回滚快照失败。"; return 1; }
  prepare_ssh_port_change "$new_port"
  set_sshd_kv "Port" "$new_port"

  if ! test_sshd_config || ! test_sshd_effective_config || ! verify_sshd_port_effective "$new_port"; then
    echo_error "sshd 配置检测失败或新端口未生效，正在回滚。"
    restore_ssh_config_snapshot "$rollback_dir"
    return 1
  fi

  if ! restart_ssh_service; then
    echo_error "SSH 重启失败，正在回滚配置并尝试恢复旧服务。"
    restore_ssh_config_snapshot "$rollback_dir"
    restart_ssh_service || true
    return 1
  fi
  refresh_fail2ban_ssh_port_if_present
  rm -rf "$rollback_dir" 2>/dev/null || true
  echo_color "SSH 端口已更新为：$new_port"
  echo_info "已尝试自动放行防火墙端口；云厂商安全组仍需你在控制台确认放行。"
  echo_warn "请另开终端测试：ssh -p ${new_port} root@你的服务器IP"
  echo_warn "如已启用 Fail2Ban，脚本已尝试自动刷新 sshd jail 端口。"
}

change_root_password_only() {
  local new_password
  read -r -s -p "请输入 root 新密码（直接回车取消）: " new_password
  echo

  [ -z "$new_password" ] && { echo_warn "已取消。"; return 0; }

  printf 'root:%s\n' "$new_password" | chpasswd || {
    echo_error "修改密码失败，正在回滚 SSH 配置。"
    restore_ssh_config_snapshot "$rollback_dir"
    return 1
  }
  echo_color "root 密码已更新。"
}

configure_key_login_existing() {
  local user pubkey home_dir ssh_dir auth_file
  read -r -p "请输入要配置密钥的用户名（默认 root，输入 q 取消）: " user
  user="${user:-root}"
  [[ "$user" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ || "$user" = "root" ]] || { echo_error "用户名格式无效。"; return 1; }

  if ! id "$user" >/dev/null 2>&1; then
    echo_error "用户不存在：$user"
    return 1
  fi

  echo_info "请粘贴一整行 SSH 公钥（ssh-rsa / ssh-ed25519 开头），输入空内容取消："
  read -r pubkey
  [ -z "$pubkey" ] && { echo_warn "已取消。"; return 0; }

  case "$pubkey" in
    ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-*\ *) ;;
    *) echo_error "看起来不像合法 SSH 公钥。"; return 1 ;;
  esac

  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  ssh_dir="${home_dir}/.ssh"
  auth_file="${ssh_dir}/authorized_keys"

  mkdir -p "$ssh_dir"
  touch "$auth_file"
  grep -qxF "$pubkey" "$auth_file" || echo "$pubkey" >> "$auth_file"

  chown -R "$user:$user" "$ssh_dir" 2>/dev/null || chown -R "$user" "$ssh_dir"
  chmod 700 "$ssh_dir"
  chmod 600 "$auth_file"

  set_sshd_kv "PubkeyAuthentication" "yes"

  if ! test_sshd_config; then
    echo_error "sshd 配置检测失败，未重启。"
    return 1
  fi

  restart_ssh_service || return 1
  echo_color "密钥登录已配置到用户：$user"
  echo_warn "请先另开终端测试密钥登录成功，再考虑关闭密码登录。"
}

generate_key_login_and_output_private() {
  local user home_dir ssh_dir key_name key_path pub_path auth_file comment confirm_delete

  read -r -p "请输入要生成密钥的用户名（默认 root，输入 q 取消）: " user
  user="${user:-root}"
  [[ "$user" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ || "$user" = "root" ]] || { echo_error "用户名格式无效。"; return 1; }

  if ! id "$user" >/dev/null 2>&1; then
    echo_error "用户不存在：$user"
    return 1
  fi

  home_dir="$(getent passwd "$user" | cut -d: -f6)"
  ssh_dir="${home_dir}/.ssh"
  key_name="server-toolkit_${user}_ed25519_$(date +%Y%m%d_%H%M%S)"
  key_path="${ssh_dir}/${key_name}"
  pub_path="${key_path}.pub"
  auth_file="${ssh_dir}/authorized_keys"
  comment="server-toolkit-${user}-$(hostname)-$(date +%F)"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo_error "未找到 ssh-keygen，请先安装 openssh-client/openssh。"
    return 1
  fi

  ssh-keygen -t ed25519 -N "" -C "$comment" -f "$key_path" >/dev/null || {
    echo_error "生成密钥失败。"
    return 1
  }

  touch "$auth_file"
  cat "$pub_path" >> "$auth_file"
  chown -R "$user:$user" "$ssh_dir" 2>/dev/null || chown -R "$user" "$ssh_dir"
  chmod 600 "$auth_file"
  chmod 600 "$key_path"
  chmod 644 "$pub_path"

  set_sshd_kv "PubkeyAuthentication" "yes"

  if ! test_sshd_config; then
    echo_error "sshd 配置检测失败，未重启。"
    return 1
  fi

  restart_ssh_service || return 1

  echo_color "已为用户 $user 生成密钥，并写入 authorized_keys。"
  echo_info "私钥文件保存在服务器：$key_path"
  echo_warn "下面会输出私钥，请立刻复制保存到本地安全位置。不要把私钥发给别人。"
  echo "==================== PRIVATE KEY START ===================="
  cat "$key_path"
  echo "===================== PRIVATE KEY END ====================="
  echo_warn "本地保存后请设置权限：chmod 600 私钥文件"
  echo_warn "测试示例：ssh -i 私钥文件 ${user}@你的服务器IP"
  read -r -p "确认已经保存私钥，是否删除服务器端私钥文件？[y/N]: " confirm_delete
  if [[ "$confirm_delete" =~ ^[Yy]$ ]]; then
    rm -f "$key_path"
    echo_color "已删除服务器端私钥文件：$key_path"
  else
    echo_warn "服务器端私钥仍保留在：$key_path，请妥善保护或稍后手动删除。"
  fi
}

configure_key_login() {
  while true; do
    echo
    ui_title "SSH 密钥登录配置"
    ui_option 1 "粘贴已有公钥并写入 authorized_keys"
    ui_option 2 "自动生成 ed25519 密钥对，并输出私钥"
    ui_back
    read -r -p "请选择: " opt

    case "$opt" in
      1) configure_key_login_existing ;;
      2) generate_key_login_and_output_private ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

toggle_password_login() {
  ui_title "密码登录开关"
  echo_warn "关闭密码登录前，必须确认你已经可以用密钥登录，否则可能无法登录服务器。"
  ui_option 1 "开启密码登录"
  ui_option 2 "关闭密码登录"
  ui_option 0 "取消"
  read -r -p "请选择: " opt

  case "$opt" in
    1)
      backup_file /etc/ssh/sshd_config
      set_sshd_kv "PasswordAuthentication" "yes"
      set_sshd_kv "KbdInteractiveAuthentication" "yes"
      set_sshd_kv "ChallengeResponseAuthentication" "yes"
      ;;
    2)
      read -r -p "确认已经测试密钥登录成功？输入 YES 继续: " confirm
      [ "$confirm" = "YES" ] || { echo_warn "已取消。"; return 0; }
      backup_file /etc/ssh/sshd_config
      set_sshd_kv "PasswordAuthentication" "no"
      set_sshd_kv "KbdInteractiveAuthentication" "no"
      set_sshd_kv "ChallengeResponseAuthentication" "no"
      ;;
    0)
      return 0
      ;;
    *)
      echo_error "无效选项"
      return 1
      ;;
  esac

  if ! test_sshd_config; then
    echo_error "sshd 配置检测失败，未重启。"
    return 1
  fi

  restart_ssh_service || return 1
  echo_color "密码登录配置已更新。"
}

manage_root_login_user() {
  ui_title "root 登录 / sudo 用户管理"
  echo_warn "关闭 root 登录前，必须新建并测试普通 sudo 用户，否则可能无法管理服务器。"
  ui_option 1 "新增 sudo 用户，并关闭 root SSH 登录"
  ui_option 2 "恢复 root SSH 登录"
  ui_back
  read -r -p "请选择: " opt

  case "$opt" in
    1)
      local user pass group
      read -r -p "请输入新用户名（输入 q 取消）: " user
      [[ "$user" =~ ^[Qq]$ || -z "$user" ]] && { echo_warn "已取消。"; return 0; }
      [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || { echo_error "用户名格式无效。"; return 1; }

      if id "$user" >/dev/null 2>&1; then
        echo_warn "用户已存在：$user"
      else
        useradd -m -s /bin/bash "$user"
      fi

      read -r -s -p "请输入新用户密码: " pass
      echo
      [ -z "$pass" ] && { echo_error "密码不能为空。"; return 1; }
      printf '%s:%s\n' "$user" "$pass" | chpasswd

      if getent group sudo >/dev/null 2>&1; then
        group="sudo"
      else
        group="wheel"
      fi
      usermod -aG "$group" "$user"

      backup_file /etc/ssh/sshd_config
      set_sshd_kv "PermitRootLogin" "no"

      if ! test_sshd_config; then
        echo_error "sshd 配置检测失败，未重启。"
        return 1
      fi

      restart_ssh_service || return 1
      echo_color "已创建/配置 sudo 用户：$user，并关闭 root SSH 登录。"
      echo_warn "请另开终端测试：ssh ${user}@你的服务器IP，并确认 sudo 可用。"
      ;;
    2)
      backup_file /etc/ssh/sshd_config
      set_sshd_kv "PermitRootLogin" "yes"
      if ! test_sshd_config; then
        echo_error "sshd 配置检测失败，未重启。"
        return 1
      fi
      restart_ssh_service || return 1
      echo_color "已恢复 root SSH 登录。"
      ;;
    0)
      return 0
      ;;
    *)
      echo_error "无效选项"
      ;;
  esac
}

change_ssh_port_and_password_together() {
  local SSH_CONFIG_FILE="/etc/ssh/sshd_config"
  local new_port new_password rollback_dir

  read -r -p "请输入新的 SSH 端口 (1-65535，输入 q 取消): " new_port
  [[ "$new_port" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }

  if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
    echo_error "端口不合法。"
    return 1
  fi

  if port_in_use "$new_port" && ! port_is_current_ssh_port "$new_port"; then
    echo_error "端口 $new_port 已被占用，请换一个。"
    return 1
  fi

  read -r -s -p "请输入 root 新密码（直接回车取消）: " new_password
  echo
  [ -z "$new_password" ] && { echo_warn "已取消。"; return 0; }

  rollback_dir="$(snapshot_ssh_config)" || { echo_error "创建 SSH 配置回滚快照失败。"; return 1; }
  prepare_ssh_port_change "$new_port"
  set_sshd_kv "Port" "$new_port"

  if ! test_sshd_config || ! test_sshd_effective_config || ! verify_sshd_port_effective "$new_port"; then
    echo_error "sshd 配置检测失败或新端口未生效，正在回滚，未修改密码。"
    restore_ssh_config_snapshot "$rollback_dir"
    return 1
  fi

  printf 'root:%s\n' "$new_password" | chpasswd || { echo_error "修改密码失败。"; return 1; }
  if ! restart_ssh_service; then
    echo_error "SSH 重启失败，正在回滚配置并尝试恢复旧服务。"
    restore_ssh_config_snapshot "$rollback_dir"
    restart_ssh_service || true
    return 1
  fi
  refresh_fail2ban_ssh_port_if_present
  rm -rf "$rollback_dir" 2>/dev/null || true
  echo_color "SSH 端口已更新为：$new_port，root 密码已更新。"
  echo_info "已尝试自动放行防火墙端口；云厂商安全组仍需你在控制台确认放行。"
  echo_warn "请另开终端测试：ssh -p ${new_port} root@你的服务器IP"
  echo_warn "如已启用 Fail2Ban，脚本已尝试自动刷新 sshd jail 端口。"
}

change_ssh_port_password() {
  local SSH_CONFIG_FILE="/etc/ssh/sshd_config"
  [ -f "$SSH_CONFIG_FILE" ] || { echo_error "找不到 $SSH_CONFIG_FILE"; return 1; }

  while true; do
    ui_title "SSH 端口 / 密码 / 密钥 / root 管理"
    echo_color "请不要关闭当前 SSH 连接，另开终端测试新连接是否成功！"
    ui_option 1 "只修改 SSH 端口"
    ui_option 2 "只修改 root 密码"
    ui_option 3 "同时修改 SSH 端口和 root 密码"
    ui_option 4 "配置密钥登录 / 自动生成密钥"
    ui_option 5 "开启/关闭密码登录"
    ui_option 6 "关闭 root 登录并新增 sudo 用户 / 恢复 root 登录"
    ui_option 7 "查看当前 SSH 关键配置"
    ui_back
    read -r -p "请选择: " mode

    case "$mode" in
      1) run_submenu_action "只修改 SSH 端口" change_ssh_port_only ;;
      2) run_submenu_action "只修改 root 密码" change_root_password_only ;;
      3) run_submenu_action "同时修改 SSH 端口和 root 密码" change_ssh_port_and_password_together ;;
      4) run_submenu_action "配置 SSH 密钥登录" configure_key_login ;;
      5) run_submenu_action "开启/关闭密码登录" toggle_password_login ;;
      6) run_submenu_action "root 登录 / sudo 用户管理" manage_root_login_user ;;
      7) run_submenu_action "查看当前 SSH 关键配置" show_ssh_effective_config ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

# ========== 7. 流媒体解锁检测 ==========
check_media_unlock() { run_remote_bash "流媒体解锁检测" "https://check.unlock.media"; }

# ========== 8. 显示服务器基本信息 ==========
format_bytes() {
  local b="$1"
  awk -v b="$b" 'BEGIN{
    if (b>=1099511627776) printf "%.2fT", b/1099511627776;
    else if (b>=1073741824) printf "%.2fG", b/1073741824;
    else if (b>=1048576) printf "%.2fM", b/1048576;
    else if (b>=1024) printf "%.2fK", b/1024;
    else printf "%dB", b;
  }'
}

get_default_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

cpu_usage_percent() {
  local a b idle1 total1 idle2 total2 diff_idle diff_total
  read -r _ a b c d e f g h i j < /proc/stat
  idle1=$((d+e)); total1=$((a+b+c+d+e+f+g+h+i+j))
  sleep 1
  read -r _ a b c d e f g h i j < /proc/stat
  idle2=$((d+e)); total2=$((a+b+c+d+e+f+g+h+i+j))
  diff_idle=$((idle2-idle1)); diff_total=$((total2-total1))
  if [ "$diff_total" -le 0 ]; then echo "0"; else awk -v i="$diff_idle" -v t="$diff_total" 'BEGIN{printf "%.0f", (1-i/t)*100}'; fi
}

show_system_info() {
  local hostname osver kernel arch cpu_model cpu_cores cpu_freq cpu_usage loadavg tcp_count udp_count
  local mem_total mem_avail mem_used mem_pct swap_total swap_free swap_used swap_pct disk_total disk_used disk_pct
  local iface rx tx algo qdisc dns ipinfo public_ip asn loc tz now uptime_sec days hours mins

  hostname="$(hostname 2>/dev/null || echo '-')"
  osver="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo '-')"
  kernel="$(uname -r)"
  arch="$(uname -m)"
  cpu_model="$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^ //')"
  [ -z "$cpu_model" ] && cpu_model="$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
  cpu_cores="$(nproc 2>/dev/null || echo '-')"
  cpu_freq="$(awk -F: '/cpu MHz/ {mhz=$2; gsub(/^[ \t]+/,"",mhz); printf "%.1f GHz", mhz/1000; exit}' /proc/cpuinfo)"
  [ -z "$cpu_freq" ] && cpu_freq="-"
  cpu_usage="$(cpu_usage_percent)%"
  loadavg="$(awk '{print $1", "$2", "$3}' /proc/loadavg)"
  tcp_count="$(ss -tan 2>/dev/null | awk 'NR>1{c++} END{print c+0}')"
  udp_count="$(ss -uan 2>/dev/null | awk 'NR>1{c++} END{print c+0}')"

  mem_total="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  mem_avail="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
  [ -z "$mem_total" ] && mem_total=0
  if [ -z "$mem_avail" ]; then
    mem_avail="$(awk '
      /MemFree/ {free=$2}
      /Buffers/ {buf=$2}
      /^Cached:/ {cache=$2}
      END {print free + buf + cache}
    ' /proc/meminfo)"
  fi
  [ -z "$mem_avail" ] && mem_avail=0
  mem_used=$((mem_total-mem_avail))
  if [ "$mem_total" -gt 0 ]; then
    mem_pct="$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{printf "%.2f", u/t*100}')"
  else
    mem_pct="0.00"
  fi
  mem_used="$(awk -v k="$mem_used" 'BEGIN{printf "%.2fM", k/1024}')"
  mem_total="$(awk -v k="$mem_total" 'BEGIN{printf "%.2fM", k/1024}')"

  swap_total="$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"
  swap_free="$(awk '/SwapFree/ {print $2}' /proc/meminfo)"
  [ -z "$swap_total" ] && swap_total=0
  [ -z "$swap_free" ] && swap_free=0
  swap_used=$((swap_total-swap_free))
  if [ "$swap_total" -gt 0 ]; then
    swap_pct="$(awk -v u="$swap_used" -v t="$swap_total" 'BEGIN{printf "%.0f", u/t*100}')"
  else
    swap_pct="0"
  fi
  swap_used="$(awk -v k="$swap_used" 'BEGIN{printf "%.0fM", k/1024}')"
  swap_total="$(awk -v k="$swap_total" 'BEGIN{printf "%.0fM", k/1024}')"

  disk_used="$(df -h / | awk 'NR==2{print $3}')"
  disk_total="$(df -h / | awk 'NR==2{print $2}')"
  disk_pct="$(df -h / | awk 'NR==2{print $5}')"

  iface="$(get_default_iface)"
  [ -z "$iface" ] && iface="$(ls /sys/class/net | grep -v '^lo$' | head -n1)"
  if [ -n "$iface" ] && [ -e "/sys/class/net/$iface/statistics/rx_bytes" ]; then
    rx="$(cat /sys/class/net/$iface/statistics/rx_bytes)"
    tx="$(cat /sys/class/net/$iface/statistics/tx_bytes)"
  else
    rx=0; tx=0
  fi

  algo="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '-')"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '-')"
  dns="$(grep -E '^nameserver ' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd' ' -)"
  [ -z "$dns" ] && dns="-"

  public_ip="$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
  ipinfo="$(curl -4 -fsS --max-time 5 "http://ip-api.com/line/${public_ip}?fields=as,query,country,regionName,city" 2>/dev/null || true)"
  asn="$(echo "$ipinfo" | sed -n '1p')"
  [ -z "$asn" ] && asn="-"
  loc="$(echo "$ipinfo" | awk 'NR==3{country=$0} NR==4{region=$0} NR==5{city=$0} END{print country" "region" "city}' | sed 's/[[:space:]]*$//')"
  [ -z "$loc" ] && loc="-"

  tz="$(timedatectl 2>/dev/null | awk -F': ' '/Time zone/ {print $2}' | awk '{print $1}')"
  [ -z "$tz" ] && tz="$(date +%Z)"
  now="$(date '+%F %I:%M %p')"
  uptime_sec="$(awk '{print int($1)}' /proc/uptime)"
  days=$((uptime_sec/86400)); hours=$((uptime_sec%86400/3600)); mins=$((uptime_sec%3600/60))

  echo_color "系统信息查询"
  echo "-------------"
  printf "%-16s %s\n" "主机名:" "$hostname"
  printf "%-16s %s\n" "系统版本:" "$osver"
  printf "%-16s %s\n" "Linux版本:" "$kernel"
  echo "-------------"
  printf "%-16s %s\n" "CPU架构:" "$arch"
  printf "%-16s %s\n" "CPU型号:" "$cpu_model"
  printf "%-16s %s\n" "CPU核心数:" "$cpu_cores"
  printf "%-16s %s\n" "CPU频率:" "$cpu_freq"
  echo "-------------"
  printf "%-16s %s\n" "CPU占用:" "$cpu_usage"
  printf "%-16s %s\n" "系统负载:" "$loadavg"
  printf "%-16s %s|%s\n" "TCP|UDP连接数:" "$tcp_count" "$udp_count"
  printf "%-16s %s/%s (%s%%)\n" "物理内存:" "$mem_used" "$mem_total" "$mem_pct"
  printf "%-16s %s/%s (%s%%)\n" "虚拟内存:" "$swap_used" "$swap_total" "$swap_pct"
  printf "%-16s %s/%s (%s)\n" "硬盘占用:" "$disk_used" "$disk_total" "$disk_pct"
  echo "-------------"
  printf "%-16s %s\n" "总接收:" "$(format_bytes "$rx")"
  printf "%-16s %s\n" "总发送:" "$(format_bytes "$tx")"
  echo "-------------"
  printf "%-16s %s %s\n" "网络算法:" "$algo" "$qdisc"
  echo "-------------"
  printf "%-16s %s\n" "运营商:" "$asn"
  printf "%-16s %s\n" "IPv4地址:" "$public_ip"
  printf "%-16s %s\n" "DNS地址:" "$dns"
  printf "%-16s %s\n" "地理位置:" "$loc"
  printf "%-16s %s %s\n" "系统时间:" "$tz" "$now"
  echo "-------------"
  printf "%-16s %s天 %s时 %s分\n" "运行时长:" "$days" "$hours" "$mins"
}

# ========== 9. YABS 测试 ==========
yabs_test() { run_remote_bash "YABS 测试" "https://yabs.sh"; }

# ========== 10. 设置定时重启 ==========
setup_cron_reboot() {
  read -r -p "请输入每隔多少小时重启一次（例如 12）: " interval
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ] || [ "$interval" -gt 720 ]; then
    echo_error "请输入有效的小时数字（1-720）。"
    return
  fi

  ensure_cron_service || { echo_error "cron/crontab 不可用，无法设置定时重启。"; return 1; }

  local marker="# server-toolkit: reboot"
  local tmpcron
  local runner="/usr/local/sbin/server-toolkit-reboot-if-due"

  cat > "$runner" <<'EOF'
#!/bin/sh
STATE_FILE="/var/lib/server-toolkit/reboot-last"
LOG_FILE="/var/log/server-toolkit.log"
INTERVAL_HOURS="${1:-0}"

log_msg() {
  printf '%s [REBOOT-RUNNER] %s\n' "$(date '+%F %T %Z' 2>/dev/null || date)" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

case "$INTERVAL_HOURS" in
  ''|*[!0-9]*) exit 1 ;;
esac

mkdir -p /var/lib/server-toolkit
now="$(date +%s)"
last="0"
[ -f "$STATE_FILE" ] && last="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
case "$last" in
  ''|*[!0-9]*) last=0 ;;
esac

need=$((INTERVAL_HOURS * 3600))
if [ $((now - last)) -ge "$need" ]; then
  echo "$now" > "$STATE_FILE"
  log_msg "interval ${INTERVAL_HOURS}h reached, rebooting"
  /sbin/reboot
else
  log_msg "skip, interval ${INTERVAL_HOURS}h not reached"
fi
EOF
  chmod +x "$runner"
  mkdir -p /var/lib/server-toolkit
  date +%s > /var/lib/server-toolkit/reboot-last 2>/dev/null || true

  tmpcron="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || { echo_error "创建临时 crontab 文件失败。"; return 1; }
  crontab -l 2>/dev/null | grep -F -v "$marker" > "$tmpcron" || true
  echo "0 * * * * $runner $interval >/dev/null 2>&1 $marker" >> "$tmpcron"
  crontab "$tmpcron" && rm -f "$tmpcron" || { rm -f "$tmpcron"; echo_error "写入 crontab 失败。"; return 1; }

  echo_color "已设置每隔 $interval 小时自动重启系统。"
  echo_info "说明：v2.3 使用每小时检查器，因此 24-720 小时也能按间隔生效。"
}

# ========== 11. 哪吒面板管理 ==========
setup_nezha_agent_restart_cron() {
  local interval marker tmpcron
  read -r -p "请输入每隔多少小时重启 nezha-agent（例如 12，输入 q 取消）: " interval
  [[ "$interval" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ] || [ "$interval" -gt 720 ]; then
    echo_error "请输入 1-720 的有效小时数。"
    return 1
  fi
  ensure_cron_service || { echo_error "cron/crontab 不可用，无法设置定时任务。"; return 1; }
  marker="# server-toolkit: nezha-agent-restart"
  local runner="/usr/local/sbin/server-toolkit-nezha-restart-if-due"
  cat > "$runner" <<'EOF'
#!/bin/sh
STATE_FILE="/var/lib/server-toolkit/nezha-agent-restart-last"
LOG_FILE="/var/log/server-toolkit.log"
INTERVAL_HOURS="${1:-0}"

log_msg() {
  printf '%s [NEZHA-RUNNER] %s\n' "$(date '+%F %T %Z' 2>/dev/null || date)" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

case "$INTERVAL_HOURS" in
  ''|*[!0-9]*) exit 1 ;;
esac

mkdir -p /var/lib/server-toolkit
now="$(date +%s)"
last="0"
[ -f "$STATE_FILE" ] && last="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
case "$last" in
  ''|*[!0-9]*) last=0 ;;
esac

need=$((INTERVAL_HOURS * 3600))
if [ $((now - last)) -ge "$need" ]; then
  echo "$now" > "$STATE_FILE"
  log_msg "interval ${INTERVAL_HOURS}h reached, restarting nezha-agent"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart nezha-agent >/dev/null 2>&1 || true
  else
    service nezha-agent restart >/dev/null 2>&1 || true
  fi
else
  log_msg "skip, interval ${INTERVAL_HOURS}h not reached"
fi
EOF
  chmod +x "$runner"
  mkdir -p /var/lib/server-toolkit
  date +%s > /var/lib/server-toolkit/nezha-agent-restart-last 2>/dev/null || true
  tmpcron="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || { echo_error "创建临时 crontab 文件失败。"; return 1; }
  crontab -l 2>/dev/null | grep -F -v "$marker" > "$tmpcron" || true
  echo "0 * * * * $runner $interval >/dev/null 2>&1 $marker" >> "$tmpcron"
  crontab "$tmpcron" && rm -f "$tmpcron" || { rm -f "$tmpcron"; echo_error "写入 crontab 失败。"; return 1; }
  echo_color "已设置每隔 $interval 小时自动重启 nezha-agent。"
  echo_info "说明：v2.3 使用每小时检查器，因此 24-720 小时也能按间隔生效。"
}

remove_nezha_agent_restart_cron() {
  local marker="# server-toolkit: nezha-agent-restart"
  local tmpcron
  tmpcron="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || { echo_error "创建临时 crontab 文件失败。"; return 1; }
  crontab -l 2>/dev/null | grep -F -v "$marker" > "$tmpcron" || true
  crontab "$tmpcron" && rm -f "$tmpcron" || { rm -f "$tmpcron"; echo_error "写入 crontab 失败。"; return 1; }
  rm -f /usr/local/sbin/server-toolkit-nezha-restart-if-due /var/lib/server-toolkit/nezha-agent-restart-last 2>/dev/null || true
  echo_color "已移除 nezha-agent 定期重启任务。"
}

manage_nezha() {
  while true; do
    echo
    ui_title "哪吒面板管理"
    ui_option 1 "重启哪吒 Agent"
    ui_option 2 "重启哪吒 Dashboard"
    ui_option 3 "重启 Agent + Dashboard"
    ui_option 4 "设置定期重启 Agent"
    ui_option 5 "移除 Agent 定期重启任务"
    ui_option 6 "卸载哪吒面板/探针"
    ui_back
    read -r -p "请选择: " nezha_opt

    case "$nezha_opt" in
      1) if has_systemd; then systemctl restart nezha-agent 2>/dev/null || true; else service nezha-agent restart 2>/dev/null || true; fi; echo_color "已尝试重启 nezha-agent。"; pause_return ;;
      2) if has_systemd; then systemctl restart nezha-dashboard 2>/dev/null || true; else service nezha-dashboard restart 2>/dev/null || true; fi; echo_color "已尝试重启 nezha-dashboard。"; pause_return ;;
      3) if has_systemd; then systemctl restart nezha-agent 2>/dev/null || true; systemctl restart nezha-dashboard 2>/dev/null || true; else service nezha-agent restart 2>/dev/null || true; service nezha-dashboard restart 2>/dev/null || true; fi; echo_color "已尝试重启哪吒相关服务。"; pause_return ;;
      4) run_submenu_action "设置定期重启 nezha-agent" setup_nezha_agent_restart_cron ;;
      5) run_submenu_action "移除 nezha-agent 定期重启任务" remove_nezha_agent_restart_cron ;;
      6)
        echo_warn "此操作会删除 /opt/nezha /etc/nezha /var/log/nezha。"
        read -r -p "确认卸载？[y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; continue; }
        if has_systemd; then
          systemctl stop nezha-agent 2>/dev/null || true
          systemctl stop nezha-dashboard 2>/dev/null || true
          systemctl disable nezha-agent 2>/dev/null || true
          systemctl disable nezha-dashboard 2>/dev/null || true
        fi
        rm -f /etc/systemd/system/nezha-agent.service
        rm -f /etc/systemd/system/nezha-dashboard.service
        rm -rf /opt/nezha /etc/nezha /var/log/nezha
        has_systemd && systemctl daemon-reload
        echo_color "哪吒面板/探针已移除。"
        pause_return
        ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

# ========== 12. IP 质量检测 ==========
check_ip_quality() { run_remote_bash "IP 质量检测" "https://IP.Check.Place"; }

# ========== 13. IPv6 一键开启/关闭 ==========
update_grub_ipv6_param() {
  local mode="$1"
  local grub_file="/etc/default/grub"
  local tmp

  if [ ! -f "$grub_file" ]; then
    echo_warn "未找到 $grub_file，可能是容器/OpenVZ/LXC 或非 GRUB 环境，跳过 GRUB 参数修改。"
    return 0
  fi
  if [ ! -w "$grub_file" ]; then
    echo_warn "$grub_file 不可写，跳过 GRUB 参数修改。"
    return 0
  fi
  backup_file "$grub_file"

  tmp="$(mktemp /tmp/server-toolkit-grub.XXXXXX)" || return 1
  awk -v mode="$mode" '
    BEGIN { done=0 }
    /^GRUB_CMDLINE_LINUX=/ {
      done=1
      val=$0
      sub(/^GRUB_CMDLINE_LINUX=/, "", val)
      gsub(/^"/, "", val)
      gsub(/"$/, "", val)
      gsub(/(^|[[:space:]])ipv6\.disable=1([[:space:]]|$)/, " ", val)
      gsub(/[[:space:]]+/, " ", val)
      gsub(/^ /, "", val)
      gsub(/ $/, "", val)
      if (mode == "disable") {
        val = (val == "" ? "ipv6.disable=1" : "ipv6.disable=1 " val)
      }
      print "GRUB_CMDLINE_LINUX=\"" val "\""
      next
    }
    { print }
    END {
      if (!done && mode == "disable") {
        print "GRUB_CMDLINE_LINUX=\"ipv6.disable=1\""
      }
    }
  ' "$grub_file" > "$tmp" && cat "$tmp" > "$grub_file"
  rm -f "$tmp"

  if command -v update-grub >/dev/null 2>&1; then
    update-grub >/dev/null 2>&1 || true
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    if [ -d /boot/grub2 ]; then
      grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1 || true
    elif [ -d /boot/grub ]; then
      grub2-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
    fi
  fi
}

manage_ipv6() {
  ui_title "IPv6 一键开启/关闭"
  echo_warn  "关闭 IPv6 将写入 sysctl + GRUB 参数，重启后也尽量保持生效。"

  local conf="/etc/sysctl.d/99-server-toolkit-ipv6.conf"

  ui_option 1 "一键开启 IPv6"
  ui_option 2 "一键关闭 IPv6"
  ui_option 3 "查看 IPv6 状态"
  ui_back
  read -r -p "请选择: " ipv6_opt

  case "$ipv6_opt" in
    1)
      [ -f "$conf" ] && backup_file "$conf"
      rm -f "$conf" 2>/dev/null || true
      update_grub_ipv6_param "enable"
      sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
      sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
      sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
      sysctl --system >/dev/null 2>&1 || true
      echo_color "IPv6 已设置为开启。如之前完全禁用过，建议重启确认。"
      ;;
    2)
      cat > "$conf" <<EOF
# server-toolkit: ipv6 disable
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
      update_grub_ipv6_param "disable"
      sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
      sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
      sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true
      sysctl --system >/dev/null 2>&1 || true
      echo_color "IPv6 已设置为关闭。建议重启后用本菜单第 3 项确认。"
      ;;
    3)
      echo_info "sysctl IPv6 状态："
      sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null || true
      sysctl net.ipv6.conf.default.disable_ipv6 2>/dev/null || true
      sysctl net.ipv6.conf.lo.disable_ipv6 2>/dev/null || true
      echo
      echo_info "IPv6 地址："
      ip -6 addr || true
      echo
      echo_info "GRUB IPv6 参数："
      grep -n 'ipv6.disable' /etc/default/grub 2>/dev/null || echo "未发现 ipv6.disable 参数。"
      ;;
    0)
      return 0
      ;;
    *)
      echo_error "无效选项"
      ;;
  esac
}

# ========== 14. 服务器加固 ==========
apply_copy_fail_mitigation() {
  local conf="/etc/modprobe.d/security.conf"
  local affected_hint=0
  mkdir -p /etc/modprobe.d
  touch "$conf"
  backup_file "$conf"

  echo_warn "CVE-2026-31431 / Copy Fail 是 Linux kernel algif_aead/authencesn 相关本地提权风险。"
  echo_warn "下面仅是临时缓解，不等于正式修复；正式修复仍需升级内核并重启。"
  modinfo authencesn >/dev/null 2>&1 && affected_hint=1
  modinfo algif_aead >/dev/null 2>&1 && affected_hint=1
  [ "$affected_hint" -eq 1 ] || echo_warn "当前内核未检测到 authencesn/algif_aead 模块信息，仍会写入防御性配置。"

  sed -i '/server-toolkit: CVE-2026-31431/,/server-toolkit: end CVE-2026-31431/d' "$conf"

  cat >> "$conf" <<EOF

# server-toolkit: CVE-2026-31431 temporary mitigation
# 临时禁用 authencesn/algif_aead 相关模块，降低 Copy Fail 本地提权风险。
# 注意：这不能替代升级并重启内核；如果你使用 IPsec/相关加密功能，请先评估影响。
install authencesn /bin/false
blacklist authencesn
install algif_aead /bin/false
blacklist algif_aead
# server-toolkit: end CVE-2026-31431
EOF
  grep -q 'server-toolkit: CVE-2026-31431' "$conf" || { echo_error "写入 $conf 失败。"; return 1; }

  modprobe -r authencesn 2>/dev/null || true
  modprobe -r algif_aead 2>/dev/null || true

  echo_color "已写入 CVE-2026-31431 临时缓解：禁用 authencesn。"
  echo_warn "请尽快升级内核并重启，这才是正式修复。"
}

remove_copy_fail_mitigation() {
  local conf="/etc/modprobe.d/security.conf"
  [ -f "$conf" ] || { echo_warn "未找到 $conf"; return 0; }

  backup_file "$conf"
  sed -i '/server-toolkit: CVE-2026-31431/,/server-toolkit: end CVE-2026-31431/d' "$conf"
  echo_color "已移除 CVE-2026-31431 临时缓解配置。"
}

apply_regresshion_mitigation() {
  local rollback_dir
  echo_warn "CVE-2024-6387 临时缓解会设置 LoginGraceTime 0，并收紧 MaxStartups。"
  echo_warn "优点：降低相关 race condition 风险；坏处：未认证连接可能更久占用，需配合 MaxStartups。"
  read -r -p "确认应用？[y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; return 0; }

  rollback_dir="$(snapshot_ssh_config)" || return 1
  set_sshd_kv "LoginGraceTime" "0"
  set_sshd_kv "MaxStartups" "10:30:60"

  if ! test_sshd_config; then
    echo_error "sshd 配置检测失败，正在回滚。"
    restore_ssh_config_snapshot "$rollback_dir"
    return 1
  fi

  restart_ssh_service || { restore_ssh_config_snapshot "$rollback_dir"; restart_ssh_service || true; return 1; }
  echo_color "已应用 CVE-2024-6387 临时缓解。"
}

restore_regresshion_mitigation() {
  local rollback_dir
  rollback_dir="$(snapshot_ssh_config)" || return 1
  set_sshd_kv "LoginGraceTime" "30"
  set_sshd_kv "MaxStartups" "10:30:100"

  if ! test_sshd_config; then
    echo_error "sshd 配置检测失败，正在回滚。"
    restore_ssh_config_snapshot "$rollback_dir"
    return 1
  fi

  restart_ssh_service || { restore_ssh_config_snapshot "$rollback_dir"; restart_ssh_service || true; return 1; }
  echo_color "已恢复 SSH 登录宽限时间为 30 秒，并设置 MaxStartups 10:30:100。"
}

apply_conservative_sysctl_hardening() {
  local conf="/etc/sysctl.d/98-server-toolkit-hardening.conf"
  backup_file "$conf"

  cat > "$conf" <<EOF
# server-toolkit: conservative hardening
# 这些配置偏保守，主要减少常见网络攻击面，不会主动修改 SSH 端口/账号。
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.default.secure_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.log_martians=1
kernel.kptr_restrict=1
kernel.dmesg_restrict=1
fs.protected_hardlinks=1
fs.protected_symlinks=1
fs.protected_fifos=2
fs.protected_regular=2
fs.suid_dumpable=0
EOF

  if [ -d /proc/sys/net/ipv6 ]; then
    cat >> "$conf" <<EOF
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
EOF
  fi

  sysctl -p "$conf" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
  echo_color "保守 sysctl 加固已应用。"
}

toggle_unpriv_userns() {
  echo_warn "关闭 unprivileged user namespaces 可降低部分本地提权/容器逃逸风险。"
  echo_warn "坏处：可能影响 rootless Docker、部分容器、Chrome/Snap/某些沙箱程序。"
  if ! sysctl kernel.unprivileged_userns_clone >/dev/null 2>&1; then
    echo_warn "当前内核未提供 kernel.unprivileged_userns_clone，跳过。"
    return 0
  fi
  ui_option 1 "关闭 unprivileged userns"
  ui_option 2 "恢复 unprivileged userns"
  ui_back
  read -r -p "请选择: " opt

  local conf="/etc/sysctl.d/97-server-toolkit-userns.conf"
  case "$opt" in
    1)
      cat > "$conf" <<EOF
# server-toolkit: disable unprivileged user namespaces
kernel.unprivileged_userns_clone=0
EOF
      sysctl -p "$conf" >/dev/null 2>&1 || true
      echo_color "已尝试关闭 unprivileged user namespaces。"
      ;;
    2)
      cat > "$conf" <<EOF
# server-toolkit: enable unprivileged user namespaces
kernel.unprivileged_userns_clone=1
EOF
      sysctl -p "$conf" >/dev/null 2>&1 || true
      echo_color "已尝试恢复 unprivileged user namespaces。"
      ;;
    0)
      return 0
      ;;
    *)
      echo_error "无效选项"
      ;;
  esac
}

security_update_core_packages() {
  echo_warn "此操作会更新系统关键安全包。内核更新后通常需要重启才真正生效。"
  read -r -p "确认执行系统安全更新？[y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; return 0; }

  if is_redhat; then
    yum_makecache_auto || true
    yum_update_auto kernel sudo openssh-server openssh-clients glibc || yum_update_auto
  else
    apt_env_export
    pkg_update
    pkg_upgrade sudo openssh-server openssh-client libc6 || true

    # Debian 常见内核元包：linux-image-amd64；Ubuntu 常见内核元包：linux-generic。
    if dpkg -l 2>/dev/null | awk '{print $2}' | grep -qx 'linux-image-amd64'; then
      pkg_upgrade linux-image-amd64 || true
    fi
    if dpkg -l 2>/dev/null | awk '{print $2}' | grep -qx 'linux-generic'; then
      pkg_upgrade linux-generic || true
    fi
  fi

  echo_color "安全更新已执行。若更新了内核/glibc/openssh/sudo，建议评估后重启。"
}

show_vulnerability_status() {
  echo_info "系统与关键组件版本："
  echo "内核: $(uname -r)"
  echo "系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || true)"
  echo "OpenSSH: $(sshd -V 2>&1 || true)"
  echo "sudo: $(sudo -V 2>/dev/null | head -n 1 || true)"
  echo "glibc: $(ldd --version 2>/dev/null | head -n 1 || true)"
  echo

  echo_info "CVE-2026-31431 / Copy Fail 临时缓解状态："
  grep -n 'authencesn' /etc/modprobe.d/security.conf 2>/dev/null || echo "未发现 authencesn 禁用配置。"
  echo

  echo_info "CVE-2024-6387 / regreSSHion 相关 SSH 配置："
  sshd -T 2>/dev/null | grep -Ei '^(logingracetime|maxstartups) ' || true
  echo

  echo_info "unprivileged userns 状态："
  sysctl kernel.unprivileged_userns_clone 2>/dev/null || echo "当前系统未提供 kernel.unprivileged_userns_clone 参数。"
  echo

  echo_info "关键 sysctl 状态："
  for k in \
    net.ipv4.tcp_syncookies \
    net.ipv4.conf.all.accept_redirects \
    net.ipv4.conf.all.accept_source_route \
    kernel.kptr_restrict \
    kernel.dmesg_restrict \
    fs.protected_hardlinks \
    fs.protected_symlinks \
    fs.suid_dumpable
  do
    sysctl "$k" 2>/dev/null || true
  done
}

one_click_safe_hardening() {
  echo_warn "一键保守加固不会关闭 SSH、不会改 SSH 端口、不会关闭 root、不会关闭密码登录。"
  echo_warn "包含：保守 sysctl + CVE-2026-31431 临时缓解 + Fail2Ban 自动识别 SSH 端口。"
  read -r -p "确认执行？[y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; return 0; }

  apply_conservative_sysctl_hardening
  apply_copy_fail_mitigation

  if command -v fail2ban-client >/dev/null 2>&1 || { has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^fail2ban\.service'; }; then
    fail2ban_refresh_ssh_port || true
  else
    echo_warn "未检测到 Fail2Ban，跳过 Fail2Ban 配置。可在第 5 项安装。"
  fi

  echo_color "一键保守加固完成。"
}

server_hardening() {
  while true; do
    echo
    ui_title "服务器加固（保守模式）"
    ui_option 1 "一键保守加固（sysctl + Copy Fail 临时缓解 + Fail2Ban端口刷新）"
    ui_option 2 "仅应用 CVE-2026-31431 / Copy Fail 临时缓解"
    ui_option 3 "移除 CVE-2026-31431 临时缓解"
    ui_option 4 "应用 CVE-2024-6387 / regreSSHion 临时缓解"
    ui_option 5 "恢复 CVE-2024-6387 临时缓解相关 SSH 参数"
    ui_option 6 "关闭/恢复 unprivileged user namespaces（可选强力加固）"
    ui_option 7 "更新内核 / sudo / OpenSSH / glibc 等关键安全包"
    ui_option 8 "查看漏洞/加固状态"
    ui_back
    read -r -p "请选择: " opt

    case "$opt" in
      1) run_submenu_action "一键保守加固" one_click_safe_hardening ;;
      2) run_submenu_action "应用 Copy Fail 临时缓解" apply_copy_fail_mitigation ;;
      3) run_submenu_action "移除 Copy Fail 临时缓解" remove_copy_fail_mitigation ;;
      4) run_submenu_action "应用 regreSSHion 临时缓解" apply_regresshion_mitigation ;;
      5) run_submenu_action "恢复 regreSSHion 参数" restore_regresshion_mitigation ;;
      6) run_submenu_action "关闭/恢复 unprivileged userns" toggle_unpriv_userns ;;
      7) run_submenu_action "更新关键安全包" security_update_core_packages ;;
      8) run_submenu_action "查看漏洞/加固状态" show_vulnerability_status ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}


# ========== 15. 新服务器初始化 / 源修复 / 更新 ==========
get_os_id() {
  . /etc/os-release 2>/dev/null && echo "${ID:-unknown}" || echo "unknown"
}

get_os_codename() {
  . /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}" || true
}

apt_probe_tool_exists() {
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

curl_has_release() {
  local base="$1" suite="$2" url1 url2
  url1="${base%/}/dists/${suite}/InRelease"
  url2="${base%/}/dists/${suite}/Release"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 5 --max-time 10 -o /dev/null "$url1" >/dev/null 2>&1 || \
      curl -fsSL --connect-timeout 5 --max-time 10 -o /dev/null "$url2" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget --spider -q --timeout=10 "$url1" >/dev/null 2>&1 || \
      wget --spider -q --timeout=10 "$url2" >/dev/null 2>&1
  else
    return 2
  fi
}

debian_components_by_codename() {
  local code="$1"
  case "$code" in
    wheezy|jessie|stretch|buster|bullseye)
      echo "main contrib non-free"
      ;;
    *)
      echo "main contrib non-free non-free-firmware"
      ;;
  esac
}

apt_set_archive_mode() {
  local mode="$1"
  local conf="/etc/apt/apt.conf.d/99-server-toolkit-archive"
  mkdir -p /etc/apt/apt.conf.d
  if [ "$mode" = "archive" ]; then
    cat > "$conf" <<EOF
// server-toolkit v2.3: old archive sources often have expired Release metadata.
Acquire::Check-Valid-Until "false";
EOF
    echo_warn "已为归档源写入：$conf"
  else
    if [ -f "$conf" ]; then
      backup_file "$conf"
      rm -f "$conf"
      echo_info "已移除旧归档源 Valid-Until 放宽配置。"
    fi
  fi
}

apt_disable_conflicting_distro_sources() {
  local tag f
  tag="$(date +%F_%H-%M-%S)"
  mkdir -p /etc/apt/sources.list.d

  for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    case "$f" in
      *.server-toolkit-disabled.*|*.bak.*) continue ;;
    esac
    if grep -Eiq '(archive\.ubuntu\.com|security\.ubuntu\.com|old-releases\.ubuntu\.com|deb\.debian\.org|security\.debian\.org|archive\.debian\.org|mirror\.google\.com|mirror\.yandex\.ru|cloudflaremirrors\.com)' "$f"; then
      cp -a "$f" "${f}.bak.${tag}" 2>/dev/null || true
      mv "$f" "${f}.server-toolkit-disabled.${tag}" 2>/dev/null || true
      echo_warn "已暂时停用可能冲突的发行版源文件：$f"
    fi
  done
}

apt_write_header() {
  local file="$1" os="$2" label="$3" base="$4"
  cat > "$file" <<EOF
# server-toolkit v2.3 generated $os sources
# source: $label
# base: $base
# generated_at: $(date '+%F %T %Z')
EOF
}

apt_add_deb_line_if_exists() {
  local file="$1" base="$2" suite="$3" components="$4"
  if ! apt_probe_tool_exists; then
    printf 'deb %s %s %s\n' "$base" "$suite" "$components" >> "$file"
    return 0
  fi
  if curl_has_release "$base" "$suite"; then
    printf 'deb %s %s %s\n' "$base" "$suite" "$components" >> "$file"
    return 0
  fi
  return 1
}

apt_detect_ubuntu_security_base() {
  local base="$1" preferred_secbase="$2" code="$3"
  if ! apt_probe_tool_exists; then
    echo "${preferred_secbase:-$base}"
  elif [ -n "$preferred_secbase" ] && curl_has_release "$preferred_secbase" "${code}-security"; then
    echo "$preferred_secbase"
  elif curl_has_release "$base" "${code}-security"; then
    echo "$base"
  else
    echo ""
  fi
}

apt_detect_debian_security_ref() {
  local base="$1" preferred_secbase="$2" code="$3" item b s
  if ! apt_probe_tool_exists; then
    printf '%s|%s\n' "${preferred_secbase:-$base}" "${code}-security"
    return 0
  fi
  for item in \
    "${preferred_secbase}|${code}-security" \
    "https://security.debian.org/debian-security/|${code}-security" \
    "http://security.debian.org/debian-security/|${code}-security" \
    "https://deb.debian.org/debian-security/|${code}-security" \
    "http://deb.debian.org/debian-security/|${code}-security" \
    "https://archive.debian.org/debian-security/|${code}/updates" \
    "http://archive.debian.org/debian-security/|${code}/updates" \
    "https://archive.debian.org/debian-security/|${code}-security" \
    "http://archive.debian.org/debian-security/|${code}-security" \
    "${base}|${code}-security"; do
    b="${item%%|*}"
    s="${item#*|}"
    [ -n "$b" ] || continue
    if curl_has_release "$b" "$s"; then
      printf '%s|%s\n' "$b" "$s"
      return 0
    fi
  done
  printf '|\n'
}

write_ubuntu_sources() {
  local base="$1" secbase="$2" code="$3" label="$4" archive_mode="$5"
  local file="/etc/apt/sources.list" final_secbase
  backup_file "$file"
  apt_disable_conflicting_distro_sources
  apt_write_header "$file" "Ubuntu" "$label" "$base"

  if ! apt_add_deb_line_if_exists "$file" "$base" "$code" "main restricted universe multiverse"; then
    echo_error "源 $base 不包含 Ubuntu ${code}，未写入。"
    return 1
  fi
  apt_add_deb_line_if_exists "$file" "$base" "${code}-updates" "main restricted universe multiverse" || true
  final_secbase="$(apt_detect_ubuntu_security_base "$base" "$secbase" "$code")"
  if [ -n "$final_secbase" ]; then
    apt_add_deb_line_if_exists "$file" "$final_secbase" "${code}-security" "main restricted universe multiverse" || true
  else
    echo_warn "未检测到 ${code}-security，已跳过 security 行。"
  fi
  apt_add_deb_line_if_exists "$file" "$base" "${code}-backports" "main restricted universe multiverse" || true
  apt_set_archive_mode "$archive_mode"
}

write_debian_sources() {
  local base="$1" secbase="$2" code="$3" label="$4" archive_mode="$5"
  local file="/etc/apt/sources.list" components sec_ref sec_final sec_suite
  components="$(debian_components_by_codename "$code")"
  backup_file "$file"
  apt_disable_conflicting_distro_sources
  apt_write_header "$file" "Debian" "$label" "$base"

  if ! apt_add_deb_line_if_exists "$file" "$base" "$code" "$components"; then
    echo_error "源 $base 不包含 Debian ${code}，未写入。"
    return 1
  fi
  apt_add_deb_line_if_exists "$file" "$base" "${code}-updates" "$components" || true
  sec_ref="$(apt_detect_debian_security_ref "$base" "$secbase" "$code")"
  sec_final="${sec_ref%%|*}"
  sec_suite="${sec_ref#*|}"
  if [ -n "$sec_final" ] && [ -n "$sec_suite" ]; then
    printf 'deb %s %s %s\n' "$sec_final" "$sec_suite" "$components" >> "$file"
  else
    echo_warn "未检测到 Debian security 源，已跳过 security 行。"
  fi
  apt_set_archive_mode "$archive_mode"
}

apt_source_candidates() {
  local os="$1"
  if [ "$os" = "ubuntu" ]; then
    cat <<'EOF'
official|官方源 archive.ubuntu.com + security.ubuntu.com|https://archive.ubuntu.com/ubuntu/|https://security.ubuntu.com/ubuntu/|normal
official-http|官方源 HTTP archive.ubuntu.com|http://archive.ubuntu.com/ubuntu/|http://security.ubuntu.com/ubuntu/|normal
google|Google 镜像 mirror.google.com|https://mirror.google.com/linux/ubuntu/|https://mirror.google.com/linux/ubuntu/|normal
cloudflare|Cloudflare Mirrors（检测可用才会写入）|https://cloudflaremirrors.com/ubuntu/|https://cloudflaremirrors.com/ubuntu/|normal
yandex|Yandex 镜像 mirror.yandex.ru|https://mirror.yandex.ru/ubuntu/|https://mirror.yandex.ru/ubuntu/|normal
yandex-http|Yandex 镜像 HTTP mirror.yandex.ru|http://mirror.yandex.ru/ubuntu/|http://mirror.yandex.ru/ubuntu/|normal
old-releases|Ubuntu old-releases 旧发行版兜底|https://old-releases.ubuntu.com/ubuntu/|https://old-releases.ubuntu.com/ubuntu/|archive
old-releases-http|Ubuntu old-releases HTTP 旧发行版兜底|http://old-releases.ubuntu.com/ubuntu/|http://old-releases.ubuntu.com/ubuntu/|archive
EOF
  else
    cat <<'EOF'
official|官方源 deb.debian.org + security.debian.org|https://deb.debian.org/debian/|https://security.debian.org/debian-security/|normal
official-http|官方源 HTTP deb.debian.org|http://deb.debian.org/debian/|http://security.debian.org/debian-security/|normal
google|Google 镜像 mirror.google.com/debian|https://mirror.google.com/debian/|https://security.debian.org/debian-security/|normal
cloudflare|Cloudflare Mirrors cloudflaremirrors.com/debian|https://cloudflaremirrors.com/debian/|https://security.debian.org/debian-security/|normal
yandex|Yandex 镜像 mirror.yandex.ru/debian|https://mirror.yandex.ru/debian/|https://mirror.yandex.ru/debian-security/|normal
yandex-http|Yandex 镜像 HTTP mirror.yandex.ru/debian|http://mirror.yandex.ru/debian/|http://mirror.yandex.ru/debian-security/|normal
archive|Debian archive.debian.org 旧发行版兜底|https://archive.debian.org/debian/|https://archive.debian.org/debian-security/|archive
archive-http|Debian archive HTTP 旧发行版兜底|http://archive.debian.org/debian/|http://archive.debian.org/debian-security/|archive
EOF
  fi
}

apt_snapshot_sources() {
  local dir
  dir="$(mktemp -d /tmp/server-toolkit-apt-sources.XXXXXX)" || return 1
  mkdir -p "$dir/sources.list.d"
  [ -f /etc/apt/sources.list ] && cp -a /etc/apt/sources.list "$dir/sources.list" 2>/dev/null || true
  if [ -d /etc/apt/sources.list.d ]; then
    cp -a /etc/apt/sources.list.d/. "$dir/sources.list.d/" 2>/dev/null || true
  fi
  printf '%s\n' "$dir"
}

apt_restore_sources() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  if [ -f "$dir/sources.list" ]; then
    cp -a "$dir/sources.list" /etc/apt/sources.list 2>/dev/null || true
  fi
  mkdir -p /etc/apt/sources.list.d
  find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -exec mv {} {}.server-toolkit-failed \; 2>/dev/null || true
  cp -a "$dir/sources.list.d/." /etc/apt/sources.list.d/ 2>/dev/null || true
  echo_warn "已尝试回滚 APT 源配置。"
}

apt_apply_candidate() {
  local os="$1" code="$2" key="$3" label="$4" base="$5" secbase="$6" archive_mode="$7"
  local snapshot
  : "$key"
  echo_info "准备写入 APT 源：$label"
  echo_info "Base: $base"
  snapshot="$(apt_snapshot_sources)" || { echo_error "创建 APT 源快照失败。"; return 1; }
  if [ "$os" = "ubuntu" ]; then
    write_ubuntu_sources "$base" "$secbase" "$code" "$label" "$archive_mode" || { apt_restore_sources "$snapshot"; return 1; }
  else
    write_debian_sources "$base" "$secbase" "$code" "$label" "$archive_mode" || { apt_restore_sources "$snapshot"; return 1; }
  fi

  apt_env_export
  apt-get clean >/dev/null 2>&1 || true
  if apt-get update; then
    echo_color "APT 源已修复/切换成功：$label"
    return 0
  fi

  echo_error "apt-get update 失败：$label"
  apt_restore_sources "$snapshot"
  apt_env_export
  apt-get update >/tmp/server-toolkit-apt-rollback-update.log 2>&1 || {
    echo_warn "回滚后 apt-get update 仍失败，最近输出："
    tail -n 40 /tmp/server-toolkit-apt-rollback-update.log 2>/dev/null || true
  }
  return 1
}

apt_try_auto_repair_sources() {
  local os="$1" code="$2" key label base secbase archive_mode
  local tried=0

  echo_info "开始按候选源自动检测并尝试修复。"
  while IFS='|' read -r key label base secbase archive_mode; do
    [ -n "$key" ] || continue
    tried=$((tried + 1))
    if apt_probe_tool_exists; then
      if curl_has_release "$base" "$code"; then
        echo_color "检测可用：$label"
      else
        echo_dim "跳过不可用或不包含当前发行版的源：$label"
        continue
      fi
    else
      echo_warn "未检测到 curl/wget，无法预检源有效性，将直接尝试：$label"
    fi

    if apt_apply_candidate "$os" "$code" "$key" "$label" "$base" "$secbase" "$archive_mode"; then
      return 0
    fi
  done <<EOF
$(apt_source_candidates "$os")
EOF

  [ "$tried" -gt 0 ] || echo_error "未生成任何 APT 候选源。"
  return 1
}

apt_source_interactive_chooser() {
  if ! is_debian_like; then
    echo_warn "当前不是 Debian/Ubuntu 系，跳过 APT 源选择。"
    return 0
  fi

  local os code tmp idx key label base secbase archive_mode opt line
  os="$(get_os_id)"
  code="$(get_os_codename)"
  [ -z "$code" ] && { echo_error "无法识别系统代号，无法选择 APT 源。"; return 1; }
  [ "$os" = "ubuntu" ] || os="debian"

  tmp="$(mktemp /tmp/server-toolkit-apt-candidates.XXXXXX)" || { echo_error "创建临时文件失败。"; return 1; }
  idx=1

  ui_title "APT 源池检测 / 切换"
  echo_info "系统识别：$os / $code"
  echo_warn "说明：这里是切换一个可用镜像源，不会同时叠加多个同类发行版源，避免 APT 重复源警告。"

  while IFS='|' read -r key label base secbase archive_mode; do
    [ -n "$key" ] || continue
    if apt_probe_tool_exists; then
      if curl_has_release "$base" "$code"; then
        printf '%s|%s|%s|%s|%s|%s\n' "$idx" "$key" "$label" "$base" "$secbase" "$archive_mode" >> "$tmp"
        ui_option "$idx" "$label"
        idx=$((idx + 1))
      else
        echo_dim "  --   不可用/不含当前发行版：$label"
      fi
    else
      printf '%s|%s|%s|%s|%s|%s\n' "$idx" "$key" "$label" "$base" "$secbase" "$archive_mode" >> "$tmp"
      ui_option "$idx" "$label（未预检，直接尝试）"
      idx=$((idx + 1))
    fi
  done <<EOF
$(apt_source_candidates "$os")
EOF

  if [ "$idx" -eq 1 ]; then
    rm -f "$tmp"
    echo_error "未检测到可用候选源。"
    return 1
  fi

  ui_back
  read -r -p "请选择要写入的源: " opt
  if [ "$opt" = "0" ]; then
    rm -f "$tmp"
    echo_warn "已取消。"
    return 0
  fi
  if ! [[ "$opt" =~ ^[0-9]+$ ]]; then
    rm -f "$tmp"
    echo_error "输入无效。"
    return 1
  fi

  line="$(awk -F'|' -v n="$opt" '$1==n{print; exit}' "$tmp")"
  rm -f "$tmp"
  [ -n "$line" ] || { echo_error "选项不存在。"; return 1; }

  IFS='|' read -r _ key label base secbase archive_mode <<EOF
$line
EOF

  apt_apply_candidate "$os" "$code" "$key" "$label" "$base" "$secbase" "$archive_mode"
}

show_apt_sources_current() {
  ui_title "当前 APT 源"
  if [ -f /etc/apt/sources.list ]; then
    echo_info "/etc/apt/sources.list"
    sed -n '1,220p' /etc/apt/sources.list
  else
    echo_warn "未找到 /etc/apt/sources.list"
  fi

  echo
  echo_info "/etc/apt/sources.list.d/"
  if ls /etc/apt/sources.list.d/* >/dev/null 2>&1; then
    for f in /etc/apt/sources.list.d/*; do
      [ -f "$f" ] || continue
      echo_dim "----- $f -----"
      sed -n '1,120p' "$f"
    done
  else
    echo_warn "未发现 sources.list.d 条目。"
  fi
}

repair_apt_sources_auto() {
  if ! is_debian_like; then
    echo_warn "当前不是 Debian/Ubuntu 系，跳过 APT 源修复。"
    return 0
  fi

  local os code confirm log_file
  os="$(get_os_id)"
  code="$(get_os_codename)"
  [ -z "$code" ] && { echo_error "无法识别系统代号，无法自动换源。"; return 1; }
  [ "$os" = "ubuntu" ] || os="debian"
  log_file="/tmp/server-toolkit-apt-update.log"

  ui_title "自动检测并修复 APT 源"
  echo_info "系统识别：$os / $code"
  echo_info "先检测当前 APT 源是否可用。"

  apt_env_export
  if apt-get update >"$log_file" 2>&1; then
    echo_color "当前 APT 源可正常 update，未强制改写。"
    read -r -p "是否继续检测并切换到官方/Google/Cloudflare/Yandex/归档源？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      apt_source_interactive_chooser
    else
      echo_warn "已保留当前 APT 源。"
    fi
    return 0
  fi

  echo_warn "当前 APT 源 update 失败，最近输出如下："
  tail -n 25 "$log_file" 2>/dev/null || true
  echo
  echo_warn "将自动检测候选源并尝试修复；修改前会备份 sources.list，并停用可能冲突的发行版源文件。"

  if apt_try_auto_repair_sources "$os" "$code"; then
    read -r -p "是否继续检测并切换到其它可用源？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      apt_source_interactive_chooser
    fi
    return 0
  fi

  echo_error "自动修复 APT 源失败。请检查网络、DNS、系统代号是否仍被上游支持。"
  return 1
}

openssh_security_upgrade() {
  echo_info "正在尝试升级/安装 OpenSSH 安全更新..."
  if is_redhat; then
    yum_makecache_auto || true
    yum_update_auto openssh openssh-server openssh-clients || yum_update_auto openssh-server || true
  elif is_debian_like; then
    apt_env_export
    pkg_install openssh-server openssh-client || true
    pkg_upgrade openssh-server openssh-client || true
  fi
  echo_color "OpenSSH 安全更新流程已执行。"
}

new_server_basic_update() {
  echo_warn "保守更新：修复源 -> apt update -> 安装 wget/curl/sudo/vim/git/unzip -> 尝试升级 OpenSSH。"
  read -r -p "确认执行？[y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; return 0; }

  if is_debian_like; then
    repair_apt_sources_auto || true
    apt_env_export
    pkg_update
    pkg_install wget curl sudo vim git unzip openssh-server openssh-client
    openssh_security_upgrade
  elif is_redhat; then
    yum_makecache_auto || true
    yum_install_auto wget curl sudo vim git unzip openssh-server openssh-clients
    openssh_security_upgrade
  else
    echo_error "暂不支持当前系统。"
  fi
}

new_server_full_update() {
  echo_warn "全量更新会执行 upgrade/dist-upgrade/full-upgrade/autoremove，并尝试升级 OpenSSH。"
  echo_warn "可能更新内核，更新完成后通常需要你自行决定是否重启。"
  read -r -p "确认执行？[y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; return 0; }

  if is_debian_like; then
    repair_apt_sources_auto || true
    apt_env_export
    pkg_update
    pkg_upgrade
    run_cmd_show_error "apt-get dist-upgrade" apt-get dist-upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
    run_cmd_show_error "apt-get full-upgrade" apt-get full-upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
    run_cmd_show_error "apt-get autoremove" apt-get autoremove -y --purge
    pkg_install unzip vim git curl screen htop vnstat net-tools dnsutils sudo wget openssh-server openssh-client
    openssh_security_upgrade
  elif is_redhat; then
    yum_makecache_auto || true
    yum_update_auto
    yum_install_auto unzip vim git curl screen htop vnstat net-tools bind-utils sudo wget openssh-server openssh-clients
    openssh_security_upgrade
  else
    echo_error "暂不支持当前系统。"
  fi
}

new_server_init_menu() {
  while true; do
    echo
    ui_title "新服务器初始化 / 源修复 / 更新"
    ui_option 1 "自动检测并修复 APT 源；可选官方/Google/Cloudflare/Yandex/归档源"
    ui_option 2 "保守更新：安装 wget/curl/sudo/vim/git/unzip，并顺带升级 OpenSSH"
    ui_option 3 "全量更新：upgrade/dist-upgrade/full-upgrade/autoremove + 常用工具 + OpenSSH"
    ui_option 4 "仅尝试修复 OpenSSH 高危漏洞（升级 openssh-server/client）"
    ui_option 5 "查看当前 APT 源（sources.list + sources.list.d）"
    ui_option 6 "手动检测并切换 APT 源池"
    ui_option 7 "修复 CentOS 7 Vault YUM 源（CentOS 7 EOL 专用）"
    ui_option 8 "修复 CentOS 7 EPEL archive 源（Fail2Ban 等依赖）"
    ui_back
    read -r -p "请选择: " opt
    case "$opt" in
      1) run_submenu_action "自动检测并修复 APT 源" repair_apt_sources_auto ;;
      2) run_submenu_action "新服务器保守更新" new_server_basic_update ;;
      3) run_submenu_action "新服务器全量更新" new_server_full_update ;;
      4) run_submenu_action "OpenSSH 安全更新" openssh_security_upgrade ;;
      5) run_submenu_action "查看当前 APT 源" show_apt_sources_current ;;
      6) run_submenu_action "手动检测并切换 APT 源池" apt_source_interactive_chooser ;;
      7) run_submenu_action "修复 CentOS 7 Vault YUM 源" repair_centos7_yum_repos ;;
      8) run_submenu_action "修复 CentOS 7 EPEL archive 源" repair_epel7_yum_repo ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

# ========== 菜单：双竖排（v2.3 统一 UI） ==========
# 说明：v2.3 继续使用稳定双栏列表，避免不同终端/字体下中文宽度错位。
menu_text_width() {
  local text="$1"
  local chars bytes wide
  chars=$(printf "%s" "$text" | wc -m | awk '{print $1}')
  bytes=$(printf "%s" "$text" | wc -c | awk '{print $1}')
  wide=$(( (bytes - chars) / 2 ))
  echo $((chars + wide))
}

menu_pad_right() {
  local text="$1"
  local target="$2"
  local width i
  width=$(menu_text_width "$text")
  printf "%s" "$text"
  for ((i=width; i<target; i++)); do
    printf " "
  done
}

menu_row() {
  local left="$1" right="$2"
  printf "  \e[1;32m"
  menu_pad_right "$left" 38
  printf "\e[0m │ \e[1;32m"
  menu_pad_right "$right" 38
  printf "\e[0m\n"
}

print_menu() {
  [ -n "${TERM:-}" ] && clear 2>/dev/null || true
  printf "\n"
  printf "\e[1;36m┌──────────────────────────────────────────────────────────────────────────────┐\e[0m\n"
  printf "\e[1;36m│\e[0m  \e[1;35m"
  menu_pad_right "server-toolkit ${SERVER_TOOLKIT_VERSION} · Linux 服务器工具箱" 74
  printf "\e[0m \e[1;36m│\e[0m\n"
  printf "\e[1;36m└──────────────────────────────────────────────────────────────────────────────┘\e[0m\n"
  printf "\e[1;36m功能菜单\e[0m\n"
  printf "\e[2m──────────────────────────────────────────────────────────────────────────────\e[0m\n"
  menu_row "1)  时间同步（chrony）"            "9)  YABS 测试"
  menu_row "2)  防火墙开启/关闭"              "10) 设置定时重启"
  menu_row "3)  SELinux 开启/关闭"             "11) 哪吒面板管理"
  menu_row "4)  SSH 安全性增强向导"            "12) IP 质量检测"
  menu_row "5)  Fail2Ban 管理"                 "13) IPv6 一键开启/关闭"
  menu_row "6)  SSH 端口/密码/密钥/root 管理"  "14) 服务器加固"
  menu_row "7)  流媒体解锁检测"                "15) 新服务器初始化/源修复"
  menu_row "8)  显示服务器基本信息"            "0)  退出"
  printf "\e[2m──────────────────────────────────────────────────────────────────────────────\e[0m\n"
}

main_loop() {
  require_root

  while true; do
    print_menu
    read -r -p "请选择一个操作: " option

    case "$option" in
      1) run_menu_action "时间同步" time_sync ;;
      2) run_menu_action "防火墙管理" manage_firewall nopause ;;
      3) run_menu_action "SELinux 管理" manage_selinux nopause ;;
      4) run_menu_action "SSH 安全性增强向导" secure_ssh nopause ;;
      5) run_menu_action "Fail2Ban 管理" manage_fail2ban nopause ;;
      6) run_menu_action "SSH 端口/密码/密钥/root 管理" change_ssh_port_password nopause ;;
      7) run_menu_action "流媒体解锁检测" check_media_unlock ;;
      8) run_menu_action "显示服务器基本信息" show_system_info ;;
      9) run_menu_action "YABS 测试" yabs_test ;;
      10) run_menu_action "设置定时重启" setup_cron_reboot ;;
      11) run_menu_action "哪吒面板管理" manage_nezha nopause ;;
      12) run_menu_action "IP 质量检测" check_ip_quality ;;
      13) run_menu_action "IPv6 一键开启/关闭" manage_ipv6 ;;
      14) run_menu_action "服务器加固" server_hardening nopause ;;
      15) run_menu_action "新服务器初始化/源修复" new_server_init_menu nopause ;;
      0) echo_color "退出"; exit 0 ;;
      "") echo_error "请输入菜单编号。"; pause_return ;;
      *) echo_error "无效的选项，请重新输入"; pause_return ;;
    esac
  done
}

if [ "${SERVER_TOOLKIT_TEST_MODE:-0}" != "1" ]; then
  main_loop "$@"
fi
