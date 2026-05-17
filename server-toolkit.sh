#!/bin/bash
set -u

SERVER_TOOLKIT_VERSION="v2.0"

# ============================================================
# server-toolkit.sh v2.0
# 适用：Debian / Ubuntu / CentOS / RHEL-like
# 原则：先备份、先检测、尽量不破坏当前 SSH 会话。
# ============================================================

# ========== 彩色输出 ==========
echo_color() { echo -e "\e[1;32m$1\e[0m"; }
echo_warn()  { echo -e "\e[1;33m$1\e[0m"; }
echo_error() { echo -e "\e[1;31m$1\e[0m"; }
echo_info()  { echo -e "\e[1;36m$1\e[0m"; }
echo_blue()  { echo -e "\e[1;34m$1\e[0m"; }
echo_pink()  { echo -e "\e[1;35m$1\e[0m"; }
echo_dim()   { echo -e "\e[2m$1\e[0m"; }

pause_return() {
  echo
  read -r -p "按 Enter 返回菜单..."
}

# ========== UI 辅助函数（v2.0 统一风格） ==========
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
  printf "  \e[1;32m%2s\e[0m  %s\n" "${num})" "$text"
}

ui_back() {
  printf "  \e[1;31m%2s\e[0m  %s\n" "0)" "返回"
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

backup_file() {
  local file="$1"
  if [ -f "$file" ]; then
    cp -a "$file" "${file}.bak.$(date +%F_%H-%M-%S)"
  fi
}

ssh_service_name() {
  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    echo "ssh"
  else
    echo "sshd"
  fi
}

restart_ssh_service() {
  local svc
  svc="$(ssh_service_name)"
  echo_color "正在重启 SSH 服务：$svc ..."
  systemctl restart "$svc" 2>/dev/null || {
    echo_error "重启 $svc 失败，请手动检查：systemctl status $svc"
    return 1
  }
  systemctl is-active "$svc" >/dev/null 2>&1 || {
    echo_error "SSH 服务未处于 active 状态，请检查配置是否错误。"
    return 1
  }
  return 0
}

test_sshd_config() {
  if command -v sshd >/dev/null 2>&1; then
    sshd -t 2>/dev/null
    return $?
  fi
  return 0
}

set_sshd_kv() {
  local key="$1"
  local val="$2"
  local file="/etc/ssh/sshd_config"

  if grep -Eq "^[#[:space:]]*$key[[:space:]]+" "$file"; then
    sed -i -E "s|^[#[:space:]]*$key[[:space:]].*|$key $val|g" "$file"
  else
    echo "$key $val" >> "$file"
  fi
}

get_current_ssh_ports() {
  local ports
  ports="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -n | paste -sd, - 2>/dev/null || true)"
  # v1.9：如果 sshd -T 不可用，回退到数字 22，避免防火墙放行时因 "ssh" 字符串被跳过。
  if [ -z "$ports" ]; then
    ports="22"
  fi
  echo "$ports"
}

# ========== 1. 时间同步 ==========
time_sync() {
  ui_title "时间同步 · ntpdate + cron"
  echo_color "正在配置 ntpdate 时间同步（每30分钟自动同步）..."

  # v2.0：按要求只保留 Google 与 Cloudflare 两个 NTP 源。
  # 同时继续清理 v1.8 遗留的 HTTP 时间同步脚本和 cron 任务，避免两套同步逻辑并存。

  if ! command -v ntpdate >/dev/null 2>&1; then
    echo_warn "未检测到 ntpdate，正在安装..."
    if is_redhat; then
      yum install -y ntpdate || yum install -y ntp || true
    else
      apt-get update -y && (apt-get install -y ntpdate || apt-get install -y ntpsec-ntpdate || true)
    fi
  fi

  if ! command -v crontab >/dev/null 2>&1; then
    echo_warn "未检测到 crontab，正在安装 cron 服务..."
    if is_redhat; then
      yum install -y cronie || true
    else
      apt-get update -y && apt-get install -y cron || true
    fi
  fi

  if ! command -v ntpdate >/dev/null 2>&1; then
    echo_error "ntpdate 仍不可用，无法配置时间同步。请先修复软件源后再试。"
    return 1
  fi

  if ! command -v crontab >/dev/null 2>&1; then
    echo_error "crontab 仍不可用，无法写入定时任务。请先安装 cron/cronie。"
    return 1
  fi

  local sync_bin="/usr/local/sbin/server-toolkit-ntpdate-sync"
  local log_file="/var/log/server-toolkit-ntpdate-sync.log"

  cat > "$sync_bin" <<'EOF'
#!/bin/sh
# server-toolkit: ntpdate time sync v2.0
# 仅保留 Google 与 Cloudflare 两个 NTP 源；成功一个即退出。
# -u 使用非特权源端口，能绕过部分网络环境下的 NTP 端口限制。

LOG_FILE="/var/log/server-toolkit-ntpdate-sync.log"
NTP_BIN="$(command -v ntpdate 2>/dev/null || echo /usr/sbin/ntpdate)"
SERVERS="time.google.com time.cloudflare.com"

log_msg() {
  printf '%s %s\n' "$(date '+%F %T %Z' 2>/dev/null)" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

if [ ! -x "$NTP_BIN" ]; then
  log_msg "FAIL ntpdate_not_found path=$NTP_BIN"
  exit 1
fi

for server in $SERVERS; do
  if "$NTP_BIN" -u "$server" >> "$LOG_FILE" 2>&1; then
    command -v hwclock >/dev/null 2>&1 && hwclock -w >/dev/null 2>&1 || true
    log_msg "OK server=$server"
    exit 0
  else
    log_msg "TRY_FAILED server=$server"
  fi
done

log_msg "FAIL all_ntp_servers_failed"
exit 1
EOF
  chmod +x "$sync_bin"

  if systemctl list-unit-files 2>/dev/null | grep -q '^cron\.service'; then
    systemctl enable --now cron >/dev/null 2>&1 || true
  elif systemctl list-unit-files 2>/dev/null | grep -q '^crond\.service'; then
    systemctl enable --now crond >/dev/null 2>&1 || true
  fi

  rm -f /usr/local/sbin/server-toolkit-http-time-sync 2>/dev/null || true

  local marker_ntp="# server-toolkit: time_sync"
  local marker_http="# server-toolkit: http_time_sync"
  local tmpcron
  tmpcron="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || {
    echo_error "创建临时 crontab 文件失败。"
    return 1
  }

  crontab -l 2>/dev/null | grep -v "$marker_ntp" | grep -v "$marker_http" > "$tmpcron" || true
  echo "*/30 * * * * $sync_bin >/dev/null 2>&1 $marker_ntp" >> "$tmpcron"

  if crontab "$tmpcron"; then
    rm -f "$tmpcron"
  else
    rm -f "$tmpcron"
    echo_error "写入 crontab 失败。"
    return 1
  fi

  if "$sync_bin"; then
    echo_color "ntpdate 时间同步成功：$(date '+%F %T %Z')"
    echo_color "时间同步配置完成：每30分钟执行一次 ntpdate（cron）。"
  else
    echo_warn "ntpdate 本次立即同步失败；已写入每30分钟自动同步任务。"
    echo_warn "可能原因：NTP 出口被限制、Google/Cloudflare 时间源不可达、系统不允许修改时间，或容器/虚拟化限制 CAP_SYS_TIME。"
    echo_info "最近日志：$log_file"
    tail -n 10 "$log_file" 2>/dev/null || true
  fi
}

# ========== 2. 防火墙管理 ==========
allow_ssh_ports_before_firewall_enable() {
  local ports p
  ports="$(get_current_ssh_ports)"
  [ -z "$ports" ] && ports="22"
  for p in ${ports//,/ }; do
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
  systemctl is-active firewalld 2>/dev/null || true
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
        ;;
      2)
        echo_warn "开启防火墙前会自动放行当前 SSH 端口：$(get_current_ssh_ports)"
        read -r -p "确认开启？[y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; continue; }
        allow_ssh_ports_before_firewall_enable
        if command -v firewall-cmd >/dev/null 2>&1 || systemctl list-unit-files | grep -q '^firewalld\.service'; then
          systemctl enable --now firewalld 2>/dev/null || true
          allow_ssh_ports_before_firewall_enable
          firewall-cmd --reload >/dev/null 2>&1 || true
          echo_color "firewalld 已尝试开启，并已放行当前 SSH 端口。"
        elif command -v ufw >/dev/null 2>&1; then
          yes | ufw enable >/dev/null 2>&1 || true
          echo_color "ufw 已尝试开启，并已放行当前 SSH 端口。"
        else
          echo_warn "未检测到 firewalld/ufw，未执行开启。"
        fi
        ;;
      3)
        echo_warn "此操作只关闭系统内 firewalld / ufw，不影响云厂商安全组。"
        read -r -p "确认关闭防火墙服务？[y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; continue; }
        systemctl stop firewalld 2>/dev/null || true
        systemctl disable firewalld 2>/dev/null || true
        ufw disable >/dev/null 2>&1 || true
        systemctl stop ufw 2>/dev/null || true
        systemctl disable ufw 2>/dev/null || true
        echo_color "防火墙服务已尝试关闭。"
        ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
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
  set_sshd_kv "Protocol" "2"
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
      1) show_ssh_effective_config ;;
      2) ssh_security_recommended ;;
      3) ssh_security_custom ;;
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
  # v2.0：Debian 12/Ubuntu minimal 常常没有 /var/log/auth.log，使用 systemd backend 更稳。
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
  if command -v fail2ban-server >/dev/null 2>&1; then
    if ! fail2ban-server -t >/tmp/server-toolkit-fail2ban-test.log 2>&1; then
      echo_error "Fail2Ban 配置检测失败，未重启服务。检测输出如下："
      cat /tmp/server-toolkit-fail2ban-test.log 2>/dev/null || true
      return 1
    fi
  fi

  systemctl enable fail2ban >/dev/null 2>&1 || true
  if systemctl restart fail2ban; then
    echo_color "Fail2Ban 服务已成功启动/重启。"
    return 0
  else
    echo_error "Fail2Ban 重启失败，最近日志如下："
    journalctl -u fail2ban -n 30 --no-pager 2>/dev/null || true
    return 1
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
  backup_file /etc/fail2ban/jail.local

  cat > /etc/fail2ban/jail.local <<EOF
# server-toolkit: fail2ban sshd 防护配置
# bantime  = 封禁时长，单位秒；3600 = 1 小时
# findtime = 统计失败次数的时间窗口，单位秒；600 = 10 分钟
# maxretry = 在 findtime 内失败多少次后封禁
# ignoreip = 白名单 IP，不会被封禁；建议加入你的固定管理 IP
# port     = 当前 SSH 端口；支持多个端口，例如 22,2222
# backend  = v2.0 自动选择；systemd 环境优先用 journal，避免 /var/log/auth.log 不存在导致启动失败

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

setup_fail2ban_default() {
  echo_color "正在安装并配置 Fail2Ban..."
  if is_redhat; then
    yum install -y epel-release || true
    yum install -y fail2ban python3-systemd || yum install -y fail2ban || return 1
  else
    apt-get update -y || return 1
    apt-get install -y fail2ban python3-systemd || apt-get install -y fail2ban || return 1
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
  local ssh_ports
  ssh_ports="$(get_current_ssh_ports)"

  fail2ban_write_base_local "INFO"
  fail2ban_write_sshd_jail "$ssh_ports" "3600" "600" "3" ""

  if fail2ban_validate_and_restart; then
    echo_color "已自动识别并刷新 Fail2Ban SSH 端口：${ssh_ports}"
  else
    return 1
  fi
}

fail2ban_status() {
  echo_info "Fail2Ban 服务状态："
  systemctl status fail2ban --no-pager -l || true
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

  if ! [[ "$ssh_ports" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
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
      1) setup_fail2ban_default ;;
      2) fail2ban_refresh_ssh_port ;;
      3) fail2ban_status ;;
      4) fail2ban-client status sshd 2>/dev/null || echo_warn "sshd jail 未启用或 Fail2Ban 未运行。" ;;
      5) fail2ban_recent_logs ;;
      6) fail2ban_set_loglevel ;;
      7) fail2ban_config_jail ;;
      8) fail2ban_unban_ip ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

# ========== 6. SSH 端口/密码/密钥/root管理 ==========
change_ssh_port_only() {
  local SSH_CONFIG_FILE="/etc/ssh/sshd_config"
  local new_port

  read -p "请输入新的 SSH 端口 (1-65535，输入 q 取消): " new_port
  [[ "$new_port" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }

  if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
    echo_error "端口不合法。"
    return 1
  fi

  if ss -lnt | awk '{print $4}' | grep -Eq "[:.]${new_port}$"; then
    echo_error "端口 $new_port 已被占用，请换一个。"
    return 1
  fi

  backup_file "$SSH_CONFIG_FILE"

  if grep -Eq "^[#[:space:]]*Port[[:space:]]+" "$SSH_CONFIG_FILE"; then
    sed -i -E "s|^[#[:space:]]*Port[[:space:]]+.*|Port ${new_port}|g" "$SSH_CONFIG_FILE"
  else
    echo "Port ${new_port}" >> "$SSH_CONFIG_FILE"
  fi

  if ! test_sshd_config; then
    echo_error "sshd 配置检测失败，未重启。"
    return 1
  fi

  restart_ssh_service || return 1
  echo_color "SSH 端口已更新为：$new_port"
  echo_warn "请另开终端测试：ssh -p ${new_port} root@你的服务器IP"
  echo_warn "如已启用 Fail2Ban，请进入第 5 项刷新 SSH 端口。"
}

change_root_password_only() {
  local new_password
  read -s -p "请输入 root 新密码（直接回车取消）: " new_password
  echo

  [ -z "$new_password" ] && { echo_warn "已取消。"; return 0; }

  echo "root:${new_password}" | chpasswd || { echo_error "修改密码失败。"; return 1; }
  echo_color "root 密码已更新。"
}

configure_key_login_existing() {
  local user pubkey home_dir ssh_dir auth_file
  read -r -p "请输入要配置密钥的用户名（默认 root，输入 q 取消）: " user
  user="${user:-root}"
  [[ "$user" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }

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
  local user home_dir ssh_dir key_name key_path pub_path auth_file comment

  read -r -p "请输入要生成密钥的用户名（默认 root，输入 q 取消）: " user
  user="${user:-root}"
  [[ "$user" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }

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

      if id "$user" >/dev/null 2>&1; then
        echo_warn "用户已存在：$user"
      else
        useradd -m -s /bin/bash "$user"
      fi

      read -s -p "请输入新用户密码: " pass
      echo
      [ -z "$pass" ] && { echo_error "密码不能为空。"; return 1; }
      echo "${user}:${pass}" | chpasswd

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
  local new_port new_password

  read -p "请输入新的 SSH 端口 (1-65535，输入 q 取消): " new_port
  [[ "$new_port" =~ ^[Qq]$ ]] && { echo_warn "已取消。"; return 0; }

  if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
    echo_error "端口不合法。"
    return 1
  fi

  if ss -lnt | awk '{print $4}' | grep -Eq "[:.]${new_port}$"; then
    echo_error "端口 $new_port 已被占用，请换一个。"
    return 1
  fi

  read -s -p "请输入 root 新密码（直接回车取消）: " new_password
  echo
  [ -z "$new_password" ] && { echo_warn "已取消。"; return 0; }

  backup_file "$SSH_CONFIG_FILE"

  if grep -Eq "^[#[:space:]]*Port[[:space:]]+" "$SSH_CONFIG_FILE"; then
    sed -i -E "s|^[#[:space:]]*Port[[:space:]]+.*|Port ${new_port}|g" "$SSH_CONFIG_FILE"
  else
    echo "Port ${new_port}" >> "$SSH_CONFIG_FILE"
  fi

  if ! test_sshd_config; then
    echo_error "sshd 配置检测失败，未重启，也未修改密码。"
    return 1
  fi

  echo "root:${new_password}" | chpasswd || { echo_error "修改密码失败。"; return 1; }
  restart_ssh_service || return 1
  echo_color "SSH 端口已更新为：$new_port，root 密码已更新。"
  echo_warn "请另开终端测试：ssh -p ${new_port} root@你的服务器IP"
  echo_warn "如已启用 Fail2Ban，请进入第 5 项刷新 SSH 端口。"
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
    read -p "请选择: " mode

    case "$mode" in
      1) change_ssh_port_only ;;
      2) change_root_password_only ;;
      3) change_ssh_port_and_password_together ;;
      4) configure_key_login ;;
      5) toggle_password_login ;;
      6) manage_root_login_user ;;
      7) show_ssh_effective_config ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

# ========== 7. 流媒体解锁检测 ==========
check_media_unlock() { bash <(curl -L -s check.unlock.media); }

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
  local iface rx tx algo qdisc dns ipinfo public_ip asn org loc tz now uptime_sec days hours mins

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
  mem_used=$((mem_total-mem_avail))
  mem_pct="$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{printf "%.2f", u/t*100}')"
  mem_used="$(awk -v k="$mem_used" 'BEGIN{printf "%.2fM", k/1024}')"
  mem_total="$(awk -v k="$mem_total" 'BEGIN{printf "%.2fM", k/1024}')"

  swap_total="$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"
  swap_free="$(awk '/SwapFree/ {print $2}' /proc/meminfo)"
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
yabs_test() { curl -sL yabs.sh | bash; }

# ========== 10. 设置定时重启 ==========
setup_cron_reboot() {
  read -p "请输入每隔多少小时重启一次（例如 12）: " interval
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ] || [ "$interval" -gt 720 ]; then
    echo_error "请输入有效的小时数字（1-720）。"
    return
  fi

  local marker="# server-toolkit: reboot"
  local tmpcron
  tmpcron="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || { echo_error "创建临时 crontab 文件失败。"; return 1; }
  crontab -l 2>/dev/null | grep -v "$marker" > "$tmpcron" || true
  echo "0 */$interval * * * /sbin/reboot $marker" >> "$tmpcron"
  crontab "$tmpcron" && rm -f "$tmpcron" || { rm -f "$tmpcron"; echo_error "写入 crontab 失败。"; return 1; }

  echo_color "已设置每隔 $interval 小时自动重启系统。"
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
  marker="# server-toolkit: nezha-agent-restart"
  tmpcron="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || { echo_error "创建临时 crontab 文件失败。"; return 1; }
  crontab -l 2>/dev/null | grep -v "$marker" > "$tmpcron" || true
  echo "0 */$interval * * * systemctl restart nezha-agent >/dev/null 2>&1 $marker" >> "$tmpcron"
  crontab "$tmpcron" && rm -f "$tmpcron" || { rm -f "$tmpcron"; echo_error "写入 crontab 失败。"; return 1; }
  echo_color "已设置每隔 $interval 小时自动重启 nezha-agent。"
}

remove_nezha_agent_restart_cron() {
  local marker="# server-toolkit: nezha-agent-restart"
  local tmpcron
  tmpcron="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || { echo_error "创建临时 crontab 文件失败。"; return 1; }
  crontab -l 2>/dev/null | grep -v "$marker" > "$tmpcron" || true
  crontab "$tmpcron" && rm -f "$tmpcron" || { rm -f "$tmpcron"; echo_error "写入 crontab 失败。"; return 1; }
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
    read -p "请选择: " nezha_opt

    case "$nezha_opt" in
      1) systemctl restart nezha-agent 2>/dev/null || true; echo_color "已尝试重启 nezha-agent。" ;;
      2) systemctl restart nezha-dashboard 2>/dev/null || true; echo_color "已尝试重启 nezha-dashboard。" ;;
      3) systemctl restart nezha-agent 2>/dev/null || true; systemctl restart nezha-dashboard 2>/dev/null || true; echo_color "已尝试重启哪吒相关服务。" ;;
      4) setup_nezha_agent_restart_cron ;;
      5) remove_nezha_agent_restart_cron ;;
      6)
        echo_warn "此操作会删除 /opt/nezha /etc/nezha /var/log/nezha。"
        read -r -p "确认卸载？[y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; continue; }
        systemctl stop nezha-agent 2>/dev/null || true
        systemctl stop nezha-dashboard 2>/dev/null || true
        systemctl disable nezha-agent 2>/dev/null || true
        systemctl disable nezha-dashboard 2>/dev/null || true
        rm -f /etc/systemd/system/nezha-agent.service
        rm -f /etc/systemd/system/nezha-dashboard.service
        rm -rf /opt/nezha /etc/nezha /var/log/nezha
        systemctl daemon-reload
        echo_color "哪吒面板/探针已移除。"
        ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

# ========== 12. IP 质量检测 ==========
check_ip_quality() { bash <(curl -Ls IP.Check.Place); }

# ========== 13. IPv6 一键开启/关闭 ==========
update_grub_ipv6_param() {
  local mode="$1"
  local grub_file="/etc/default/grub"

  [ -f "$grub_file" ] || return 0
  backup_file "$grub_file"

  if [[ "$mode" == "disable" ]]; then
    if grep -q '^GRUB_CMDLINE_LINUX=' "$grub_file"; then
      if ! grep -q 'ipv6.disable=1' "$grub_file"; then
        sed -i 's/^GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="ipv6.disable=1 /' "$grub_file"
      fi
    else
      echo 'GRUB_CMDLINE_LINUX="ipv6.disable=1"' >> "$grub_file"
    fi
  else
    sed -i 's/ipv6.disable=1//g' "$grub_file"
    sed -i 's/  */ /g' "$grub_file"
    sed -i 's/=" /="/g' "$grub_file"
  fi

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
  read -p "请选择: " ipv6_opt

  case "$ipv6_opt" in
    1)
      cat > "$conf" <<EOF
# server-toolkit: ipv6 enable
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.lo.disable_ipv6=0
EOF
      update_grub_ipv6_param "enable"
      sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
      sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
      sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
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
  mkdir -p /etc/modprobe.d
  touch "$conf"
  backup_file "$conf"

  sed -i '/server-toolkit: CVE-2026-31431/,/server-toolkit: end CVE-2026-31431/d' "$conf"

  cat >> "$conf" <<EOF

# server-toolkit: CVE-2026-31431 temporary mitigation
# 临时禁用 authencesn 模块，降低 Copy Fail 本地提权风险。
# 注意：这不能替代升级并重启内核；如果你使用 IPsec/相关加密功能，请先评估影响。
install authencesn /bin/false
blacklist authencesn
# server-toolkit: end CVE-2026-31431
EOF

  modprobe -r authencesn 2>/dev/null || true

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
  echo_warn "CVE-2024-6387 临时缓解会设置 LoginGraceTime 0，并收紧 MaxStartups。"
  echo_warn "优点：降低相关 race condition 风险；坏处：未认证连接可能更久占用，需配合 MaxStartups。"
  read -r -p "确认应用？[y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; return 0; }

  backup_file /etc/ssh/sshd_config
  set_sshd_kv "LoginGraceTime" "0"
  set_sshd_kv "MaxStartups" "10:30:60"

  if ! test_sshd_config; then
    echo_error "sshd 配置检测失败，未重启。"
    return 1
  fi

  restart_ssh_service || return 1
  echo_color "已应用 CVE-2024-6387 临时缓解。"
}

restore_regresshion_mitigation() {
  backup_file /etc/ssh/sshd_config
  set_sshd_kv "LoginGraceTime" "30"
  set_sshd_kv "MaxStartups" "10:30:100"

  if ! test_sshd_config; then
    echo_error "sshd 配置检测失败，未重启。"
    return 1
  fi

  restart_ssh_service || return 1
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
    yum makecache -y || true
    yum update -y kernel sudo openssh-server openssh-clients glibc || yum update -y
  else
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none UCF_FORCE_CONFFOLD=1
    apt-get update -y
    apt-get install -y --only-upgrade -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" sudo openssh-server openssh-client libc6 || true

    # Debian 常见内核元包：linux-image-amd64；Ubuntu 常见内核元包：linux-generic。
    if dpkg -l 2>/dev/null | awk '{print $2}' | grep -qx 'linux-image-amd64'; then
      apt-get install -y --only-upgrade -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" linux-image-amd64 || true
    fi
    if dpkg -l 2>/dev/null | awk '{print $2}' | grep -qx 'linux-generic'; then
      apt-get install -y --only-upgrade -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" linux-generic || true
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

  if command -v fail2ban-client >/dev/null 2>&1 || systemctl list-unit-files | grep -q '^fail2ban\.service'; then
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
      1) one_click_safe_hardening ;;
      2) apply_copy_fail_mitigation ;;
      3) remove_copy_fail_mitigation ;;
      4) apply_regresshion_mitigation ;;
      5) restore_regresshion_mitigation ;;
      6) toggle_unpriv_userns ;;
      7) security_update_core_packages ;;
      8) show_vulnerability_status ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}


# ========== 15. 新服务器初始化 / 源修复 / 更新 ==========
apt_env_prefix() {
  echo "DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none UCF_FORCE_CONFFOLD=1"
}

get_os_id() {
  . /etc/os-release 2>/dev/null && echo "${ID:-unknown}" || echo "unknown"
}

get_os_codename() {
  . /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}" || true
}

curl_has_release() {
  local base="$1" suite="$2" url1 url2
  url1="${base%/}/dists/${suite}/InRelease"
  url2="${base%/}/dists/${suite}/Release"

  if command -v curl >/dev/null 2>&1; then
    curl -fsIL --max-time 8 "$url1" >/dev/null 2>&1 || curl -fsIL --max-time 8 "$url2" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget --spider -q --timeout=8 "$url1" >/dev/null 2>&1 || wget --spider -q --timeout=8 "$url2" >/dev/null 2>&1
  else
    echo_warn "未检测到 curl/wget，无法自动检测源有效性。"
    return 1
  fi
}

write_ubuntu_sources() {
  local base="$1" code="$2"
  backup_file /etc/apt/sources.list
  cat > /etc/apt/sources.list <<EOF
# server-toolkit v1.9 generated Ubuntu sources
# base: $base
deb ${base} ${code} main restricted universe multiverse
deb ${base} ${code}-updates main restricted universe multiverse
deb ${base} ${code}-security main restricted universe multiverse
deb ${base} ${code}-backports main restricted universe multiverse
EOF
}

write_debian_sources() {
  local base="$1" secbase="$2" code="$3"
  backup_file /etc/apt/sources.list
  cat > /etc/apt/sources.list <<EOF
# server-toolkit v1.9 generated Debian sources
# base: $base
deb ${base} ${code} main contrib non-free non-free-firmware
deb ${base} ${code}-updates main contrib non-free non-free-firmware
deb ${secbase} ${code}-security main contrib non-free non-free-firmware
EOF
}

repair_apt_sources_auto() {
  if ! is_debian_like; then
    echo_warn "当前不是 Debian/Ubuntu 系，跳过 APT 源修复。"
    return 0
  fi

  local os code base secbase
  os="$(get_os_id)"
  code="$(get_os_codename)"
  [ -z "$code" ] && { echo_error "无法识别系统代号，无法自动换源。"; return 1; }

  mkdir -p /etc/apt/apt.conf.d

  if [ "$os" = "ubuntu" ]; then
    echo_info "检测到 Ubuntu：$code，开始检测可用源..."
    for base in \
      "https://mirror.yandex.ru/ubuntu/" \
      "https://ru.archive.ubuntu.com/ubuntu/" \
      "https://archive.ubuntu.com/ubuntu/" \
      "http://archive.ubuntu.com/ubuntu/" \
      "https://old-releases.ubuntu.com/ubuntu/" \
      "http://old-releases.ubuntu.com/ubuntu/"; do
      if curl_has_release "$base" "$code"; then
        echo_color "找到可用 Ubuntu 源：$base"
        write_ubuntu_sources "$base" "$code"
        apt-get clean
        apt-get update -y && return 0
      fi
    done
    echo_error "未找到可用 Ubuntu 源。"
    return 1
  else
    echo_info "检测到 Debian-like：$code，开始检测可用源..."
    for base in \
      "https://deb.debian.org/debian/" \
      "https://mirror.yandex.ru/debian/" \
      "http://deb.debian.org/debian/" \
      "https://archive.debian.org/debian/" \
      "http://archive.debian.org/debian/"; do
      if curl_has_release "$base" "$code"; then
        if echo "$base" | grep -q 'archive.debian.org'; then
          secbase="$base"
          cat >/etc/apt/apt.conf.d/99-server-toolkit-archive <<EOF
Acquire::Check-Valid-Until "false";
EOF
        else
          if curl_has_release "https://security.debian.org/debian-security/" "${code}-security"; then
            secbase="https://security.debian.org/debian-security/"
          elif curl_has_release "https://mirror.yandex.ru/debian-security/" "${code}-security"; then
            secbase="https://mirror.yandex.ru/debian-security/"
          else
            secbase="$base"
          fi
        fi
        echo_color "找到可用 Debian 源：$base"
        write_debian_sources "$base" "$secbase" "$code"
        apt-get clean
        apt-get update -y && return 0
      fi
    done
    echo_error "未找到可用 Debian 源。"
    return 1
  fi
}

openssh_security_upgrade() {
  echo_info "正在尝试升级/安装 OpenSSH 安全更新..."
  if is_redhat; then
    yum makecache -y || true
    yum update -y openssh openssh-server openssh-clients || yum update -y openssh-server || true
  elif is_debian_like; then
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none UCF_FORCE_CONFFOLD=1
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" openssh-server openssh-client || true
    apt-get install -y --only-upgrade -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" openssh-server openssh-client || true
  fi
  echo_color "OpenSSH 安全更新流程已执行。"
}

new_server_basic_update() {
  echo_warn "保守更新：修复源 -> apt update -> 安装 wget/curl/sudo/vim/git/unzip -> 尝试升级 OpenSSH。"
  read -r -p "确认执行？[y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; return 0; }

  if is_debian_like; then
    repair_apt_sources_auto || true
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none UCF_FORCE_CONFFOLD=1
    apt-get update -y
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" wget curl sudo vim git unzip openssh-server openssh-client
    openssh_security_upgrade
  elif is_redhat; then
    yum makecache -y || true
    yum install -y wget curl sudo vim git unzip openssh-server openssh-clients
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
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none UCF_FORCE_CONFFOLD=1
    apt-get update -y
    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade
    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade
    apt-get -y autoremove --purge
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" unzip vim git curl screen htop vnstat net-tools dnsutils sudo wget openssh-server openssh-client
    openssh_security_upgrade
  elif is_redhat; then
    yum makecache -y || true
    yum update -y
    yum install -y unzip vim git curl screen htop vnstat net-tools bind-utils sudo wget openssh-server openssh-clients
    openssh_security_upgrade
  else
    echo_error "暂不支持当前系统。"
  fi
}

new_server_init_menu() {
  while true; do
    echo
    ui_title "新服务器初始化 / 源修复 / 更新"
    ui_option 1 "自动检测并修复 APT 源（含旧发行版 old-releases/archive 修复）"
    ui_option 2 "保守更新：安装 wget/curl/sudo/vim/git/unzip，并顺带升级 OpenSSH"
    ui_option 3 "全量更新：upgrade/dist-upgrade/full-upgrade/autoremove + 常用工具 + OpenSSH"
    ui_option 4 "仅尝试修复 OpenSSH 高危漏洞（升级 openssh-server/client）"
    ui_option 5 "查看当前 sources.list"
    ui_back
    read -r -p "请选择: " opt
    case "$opt" in
      1) repair_apt_sources_auto ;;
      2) new_server_basic_update ;;
      3) new_server_full_update ;;
      4) openssh_security_upgrade ;;
      5) cat /etc/apt/sources.list 2>/dev/null || echo_warn "未找到 /etc/apt/sources.list" ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

# ========== 菜单：双竖排（v2.0 统一 UI） ==========
# 说明：v2.0 继续使用稳定双栏列表，避免不同终端/字体下中文宽度错位。
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
  menu_row "1)  时间同步（ntpdate+cron）"      "9)  YABS 测试"
  menu_row "2)  防火墙开启/关闭"              "10) 设置定时重启"
  menu_row "3)  SELinux 开启/关闭"             "11) 哪吒面板管理"
  menu_row "4)  SSH 安全性增强向导"            "12) IP 质量检测"
  menu_row "5)  Fail2Ban 管理"                 "13) IPv6 一键开启/关闭"
  menu_row "6)  SSH 端口/密码/密钥/root 管理"  "14) 服务器加固"
  menu_row "7)  流媒体解锁检测"                "15) 新服务器初始化/源修复"
  menu_row "8)  显示服务器基本信息"            "0)  退出"
  printf "\e[2m──────────────────────────────────────────────────────────────────────────────\e[0m\n"
}

require_root

while true; do
  print_menu
  read -p "请选择一个操作: " option

  case $option in
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
    13) manage_ipv6 ;;
    14) server_hardening ;;
    15) new_server_init_menu ;;
    0) echo_color "退出"; exit 0 ;;
    *) echo_error "无效的选项，请重新输入"; pause_return ;;
  esac
done
