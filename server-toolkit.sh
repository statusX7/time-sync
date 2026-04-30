#!/bin/bash
set -u

SERVER_TOOLKIT_VERSION="v1.5"

# ============================================================
# server-toolkit.sh v1.5
# 适用：Debian / Ubuntu / CentOS / RHEL-like
# 原则：先备份、先检测、尽量不破坏当前 SSH 会话。
# ============================================================

# ========== 彩色输出 ==========
echo_color() { echo -e "\e[1;32m$1\e[0m"; }
echo_warn()  { echo -e "\e[1;33m$1\e[0m"; }
echo_error() { echo -e "\e[1;31m$1\e[0m"; }
echo_info()  { echo -e "\e[1;36m$1\e[0m"; }

pause_return() {
  echo
  read -r -p "按 Enter 返回菜单..."
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
  if [ -z "$ports" ]; then
    ports="ssh"
  fi
  echo "$ports"
}

# ========== 1. 时间同步 ==========
time_sync() {
  echo_color "正在配置每30分钟自动同步时间..."

  if ! command -v ntpdate &>/dev/null; then
    echo_color "ntpdate 未安装，正在安装..."
    if is_redhat; then
      yum install -y ntpdate
    else
      apt-get update -y && apt-get install -y ntpdate
    fi
  else
    echo_color "ntpdate 已安装"
  fi

  ntpdate time.google.com || echo_warn "ntpdate 同步失败（可能被阻断/解析异常），稍后可再试。"

  local marker="# server-toolkit: time_sync"
  crontab -l 2>/dev/null | grep -v "$marker" > /tmp/cron.tmp || true
  echo "*/30 * * * * /usr/sbin/ntpdate time.google.com >/dev/null 2>&1 $marker" >> /tmp/cron.tmp
  crontab /tmp/cron.tmp
  rm -f /tmp/cron.tmp

  echo_color "时间同步配置完成：每30分钟同步一次（cron）。"
}

# ========== 2. 关闭防火墙 ==========
disable_firewall() {
  echo_warn "此操作只关闭系统内 firewalld / ufw，不影响云厂商安全组。"
  read -r -p "确认关闭防火墙服务？[y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; return 0; }

  echo_color "正在关闭防火墙..."
  systemctl stop firewalld 2>/dev/null || true
  systemctl disable firewalld 2>/dev/null || true
  systemctl stop ufw 2>/dev/null || true
  systemctl disable ufw 2>/dev/null || true
  echo_color "防火墙服务已尝试关闭。"
}

# ========== 3. 关闭SELinux ==========
disable_selinux() {
  echo_color "正在关闭SELinux..."
  if [ -f /etc/selinux/config ]; then
    backup_file /etc/selinux/config
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    setenforce 0 2>/dev/null || true
    echo_color "SELinux 已关闭（需重启后完全生效）。"
  else
    echo_warn "未找到 SELinux 配置文件（Debian/Ubuntu 属正常）。"
  fi
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
    echo_info "SSH 安全性增强 - 逐项配置"
    echo "1) MaxAuthTries：限制单次连接最大认证失败次数；优点：降低暴力破解效率；坏处：输错几次会断开。"
    echo "2) LoginGraceTime：限制登录认证窗口；优点：减少僵尸连接；坏处：弱网下登录时间更短。"
    echo "3) PermitEmptyPasswords：禁止空密码；强烈建议 no。"
    echo "4) UseDNS：关闭反向 DNS 查询；优点：登录更快；坏处：日志中少部分主机名信息减少。"
    echo "5) X11Forwarding：关闭 X11 转发；优点：减少攻击面；坏处：不能通过 SSH 转发图形界面。"
    echo "6) AllowTcpForwarding：是否允许 SSH 隧道；关闭可减少滥用；坏处：影响端口转发/跳板用途。"
    echo "7) ClientAliveInterval/CountMax：空闲连接保活/断开策略；优点：减少僵尸会话；坏处：长时间挂机会断开。"
    echo "8) 查看当前 SSH 生效配置"
    echo "0) 返回并应用"
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
    echo_info "SSH 安全性增强向导"
    echo "1) 查看当前 SSH 关键配置"
    echo "2) 一键保守增强（不禁 root、不禁密码、不改端口）"
    echo "3) 逐项配置（带说明）"
    echo "0) 返回"
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

setup_fail2ban_default() {
  echo_color "正在安装并配置 Fail2Ban..."
  if is_redhat; then
    yum install -y epel-release
    yum install -y fail2ban
  else
    apt-get update -y && apt-get install -y fail2ban
  fi

  local logpath ssh_ports
  logpath="$(fail2ban_log_path)"
  ssh_ports="$(get_current_ssh_ports)"
  backup_file /etc/fail2ban/jail.local

  cat > /etc/fail2ban/jail.local <<EOF
# server-toolkit: fail2ban sshd 基础防护
#
# bantime  = 封禁时长，3600 秒 = 1 小时
# findtime = 统计失败次数的时间窗口，600 秒 = 10 分钟
# maxretry = 在 findtime 内失败多少次后封禁
# port     = 自动识别当前 sshd 监听端口：${ssh_ports}
#
# sshd jail 只监控 SSH 登录失败，不会影响普通网站/代理服务。

[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = auto

[sshd]
enabled = true
port = ${ssh_ports}
logpath = $logpath
EOF

  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  echo_color "Fail2Ban 已安装并配置完成。"
  echo_info "已自动写入当前 SSH 端口：${ssh_ports}"
}

fail2ban_refresh_ssh_port() {
  local ssh_ports logpath
  ssh_ports="$(get_current_ssh_ports)"
  logpath="$(fail2ban_log_path)"

  backup_file /etc/fail2ban/jail.local
  cat > /etc/fail2ban/jail.local <<EOF
# server-toolkit: fail2ban sshd 自动端口配置
# port 自动识别自 sshd -T，当前端口：${ssh_ports}

[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = auto

[sshd]
enabled = true
port = ${ssh_ports}
logpath = $logpath
EOF

  systemctl restart fail2ban
  echo_color "已自动识别并刷新 Fail2Ban SSH 端口：${ssh_ports}"
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

  mkdir -p /etc/fail2ban
  cat > /etc/fail2ban/fail2ban.local <<EOF
# server-toolkit: fail2ban 日志等级配置
# loglevel 越低日志越少，DEBUG 最详细但日志最多。
[Definition]
loglevel = $level
EOF

  systemctl restart fail2ban
  echo_color "Fail2Ban 日志等级已设置为：$level"
}

fail2ban_config_jail() {
  local logpath bantime findtime maxretry ignoreip ssh_ports custom_ports
  logpath="$(fail2ban_log_path)"
  ssh_ports="$(get_current_ssh_ports)"

  echo_info "自动识别到当前 SSH 端口：${ssh_ports}"
  read -r -p "是否手动覆盖端口？直接回车使用自动识别端口，或输入例如 22,2222: " custom_ports
  [ -n "$custom_ports" ] && ssh_ports="$custom_ports"

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

  backup_file /etc/fail2ban/jail.local

  cat > /etc/fail2ban/jail.local <<EOF
# server-toolkit: fail2ban sshd 自定义配置
# bantime  = 封禁时长，单位秒
# findtime = 统计失败次数的时间窗口
# maxretry = 在统计窗口内失败多少次后封禁
# ignoreip = 白名单 IP，不会被封禁；建议加入你的固定管理 IP
# port     = SSH 端口，默认自动识别：${ssh_ports}

[DEFAULT]
bantime = $bantime
findtime = $findtime
maxretry = $maxretry
backend = auto
ignoreip = 127.0.0.1/8 ::1 $ignoreip

[sshd]
enabled = true
port = $ssh_ports
logpath = $logpath
EOF

  systemctl restart fail2ban
  echo_color "Fail2Ban jail 配置已更新。"
}

fail2ban_unban_ip() {
  read -r -p "请输入要解封的 IP: " ip
  [ -z "$ip" ] && { echo_warn "已取消。"; return 0; }
  fail2ban-client set sshd unbanip "$ip" 2>/dev/null && echo_color "已尝试解封：$ip" || echo_error "解封失败，请确认 sshd jail 是否存在。"
}

manage_fail2ban() {
  while true; do
    echo
    echo_info "Fail2Ban 管理"
    echo "1) 安装/写入默认 SSH 防护配置（自动识别 SSH 端口）"
    echo "2) 自动识别当前 SSH 端口并刷新 Fail2Ban 配置"
    echo "3) 查看 Fail2Ban 服务状态"
    echo "4) 查看 sshd jail 状态"
    echo "5) 查看最近 50 条 Fail2Ban 日志"
    echo "6) 设置 Fail2Ban 日志等级"
    echo "7) 配置 sshd 防护参数（bantime/findtime/maxretry/ignoreip/port）"
    echo "8) 解封指定 IP"
    echo "0) 返回"
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
    echo_info "SSH 密钥登录配置"
    echo "1) 粘贴已有公钥并写入 authorized_keys"
    echo "2) 自动生成 ed25519 密钥对，并输出私钥"
    echo "0) 返回"
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
  echo_warn "关闭密码登录前，必须确认你已经可以用密钥登录，否则可能无法登录服务器。"
  echo "1) 开启密码登录"
  echo "2) 关闭密码登录"
  echo "0) 取消"
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
  echo_warn "关闭 root 登录前，必须新建并测试普通 sudo 用户，否则可能无法管理服务器。"
  echo "1) 新增 sudo 用户，并关闭 root SSH 登录"
  echo "2) 恢复 root SSH 登录"
  echo "0) 返回"
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

change_ssh_port_password() {
  local SSH_CONFIG_FILE="/etc/ssh/sshd_config"
  [ -f "$SSH_CONFIG_FILE" ] || { echo_error "找不到 $SSH_CONFIG_FILE"; return 1; }

  while true; do
    echo
    echo_color "请不要关闭当前 SSH 连接，另开终端测试新连接是否成功！"
    echo "1) 只修改 SSH 端口"
    echo "2) 只修改 root 密码"
    echo "3) 配置密钥登录 / 自动生成密钥"
    echo "4) 开启/关闭密码登录"
    echo "5) 关闭 root 登录并新增 sudo 用户 / 恢复 root 登录"
    echo "6) 查看当前 SSH 关键配置"
    echo "0) 返回"
    read -p "请选择: " mode

    case "$mode" in
      1) change_ssh_port_only ;;
      2) change_root_password_only ;;
      3) configure_key_login ;;
      4) toggle_password_login ;;
      5) manage_root_login_user ;;
      6) show_ssh_effective_config ;;
      0) return 0 ;;
      *) echo_error "无效选项" ;;
    esac
  done
}

# ========== 7. 流媒体解锁检测 ==========
check_media_unlock() { bash <(curl -L -s check.unlock.media); }

# ========== 8. 显示服务器基本信息 ==========
show_system_info() {
  echo_color "---------------------服务器基本信息如下---------------------"
  CPU_MODEL=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^ //')
  CPU_CORES=$(nproc)
  CPU_FREQ=$(awk -F: '/cpu MHz/ {print $2; exit}' /proc/cpuinfo | sed 's/^ //')
  CACHE=$(lscpu 2>/dev/null | awk -F: '
    /L1d cache/ {gsub(/^[ \t]+/, "", $2); l1=$2}
    /L2 cache/  {gsub(/^[ \t]+/, "", $2); l2=$2}
    /L3 cache/  {gsub(/^[ \t]+/, "", $2); l3=$2}
    END {printf "L1: %s / L2: %s / L3: %s", l1?l1:"-", l2?l2:"-", l3?l3:"-"}'
  )
  AES_SUPPORT=$(lscpu 2>/dev/null | grep -qi aes && echo "✔ Enabled" || echo "✘ Disabled")
  VM_SUPPORT=$(egrep -q 'vmx|svm' /proc/cpuinfo && echo "✔ Enabled" || echo "✘ Disabled")
  MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
  MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
  SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')
  SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
  DISK_INFO=$(df -h / | awk 'NR==2 {print $3 " / " $2}')
  BOOT_DISK=$(df -h / | awk 'NR==2 {print $1}')
  UPTIME=$(uptime -p)
  LOAD_AVG=$(uptime | awk -F'load average:' '{ print $2 }')
  OS_INFO=$(hostnamectl 2>/dev/null | grep "Operating System" | cut -d: -f2 | sed 's/^ //')
  ARCH_INFO=$(uname -m)
  KERNEL=$(uname -r)

  echo -e " CPU 型号          : $CPU_MODEL"
  echo -e " CPU 核心数        : $CPU_CORES"
  echo -e " CPU 频率          : ${CPU_FREQ} MHz"
  echo -e " CPU 缓存          : $CACHE"
  echo -e " AES-NI指令集      : $AES_SUPPORT"
  echo -e " VM-x/AMD-V支持    : $VM_SUPPORT"
  echo -e " 内存              : ${MEM_USED} MiB / ${MEM_TOTAL} MiB"
  echo -e " Swap              : ${SWAP_USED} MiB / ${SWAP_TOTAL} MiB"
  echo -e " 硬盘空间          : $DISK_INFO"
  echo -e " 启动盘路径        : $BOOT_DISK"
  echo -e " 系统在线时间      : $UPTIME"
  echo -e " 负载              : $LOAD_AVG"
  echo -e " 系统              : ${OS_INFO:-$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d \" )}" 
  echo -e " 架构              : $ARCH_INFO"
  echo -e " 内核              : $KERNEL"
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
  crontab -l 2>/dev/null | grep -v "$marker" > /tmp/cron.tmp || true
  echo "0 */$interval * * * /sbin/reboot $marker" >> /tmp/cron.tmp
  crontab /tmp/cron.tmp
  rm -f /tmp/cron.tmp

  echo_color "已设置每隔 $interval 小时自动重启系统。"
}

# ========== 11. 哪吒面板管理 ==========
manage_nezha() {
  echo "1) 重启哪吒 Agent"
  echo "2) 重启哪吒 Dashboard"
  echo "3) 重启 Agent + Dashboard"
  echo "4) 卸载哪吒面板/探针"
  echo "0) 返回"
  read -p "请选择: " nezha_opt

  case "$nezha_opt" in
    1)
      systemctl restart nezha-agent 2>/dev/null || true
      echo_color "已尝试重启 nezha-agent。"
      ;;
    2)
      systemctl restart nezha-dashboard 2>/dev/null || true
      echo_color "已尝试重启 nezha-dashboard。"
      ;;
    3)
      systemctl restart nezha-agent 2>/dev/null || true
      systemctl restart nezha-dashboard 2>/dev/null || true
      echo_color "已尝试重启哪吒相关服务。"
      ;;
    4)
      echo_warn "此操作会删除 /opt/nezha /etc/nezha /var/log/nezha。"
      read -r -p "确认卸载？[y/N]: " confirm
      [[ "$confirm" =~ ^[Yy]$ ]] || { echo_warn "已取消。"; return 0; }

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
    0)
      return 0
      ;;
    *)
      echo_error "无效选项"
      ;;
  esac
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
  echo_color "IPv6 一键开启/关闭"
  echo_warn  "关闭 IPv6 将写入 sysctl + GRUB 参数，重启后也尽量保持生效。"

  local conf="/etc/sysctl.d/99-server-toolkit-ipv6.conf"

  echo "1) 一键开启 IPv6"
  echo "2) 一键关闭 IPv6"
  echo "3) 查看 IPv6 状态"
  echo "0) 返回"
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
  echo "1) 关闭 unprivileged userns"
  echo "2) 恢复 unprivileged userns"
  echo "0) 返回"
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
    yum update -y kernel sudo openssh-server glibc || yum update -y
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --only-upgrade linux-image-amd64 sudo openssh-server libc6 2>/dev/null || apt-get -y upgrade
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
    echo_info "服务器加固（保守模式，不主动影响 SSH 登录）"
    echo "1) 一键保守加固（sysctl + Copy Fail 临时缓解 + Fail2Ban端口刷新）"
    echo "2) 仅应用 CVE-2026-31431 / Copy Fail 临时缓解"
    echo "3) 移除 CVE-2026-31431 临时缓解"
    echo "4) 应用 CVE-2024-6387 / regreSSHion 临时缓解"
    echo "5) 恢复 CVE-2024-6387 临时缓解相关 SSH 参数"
    echo "6) 关闭/恢复 unprivileged user namespaces（可选强力加固）"
    echo "7) 更新内核 / sudo / OpenSSH / glibc 等关键安全包"
    echo "8) 查看漏洞/加固状态"
    echo "0) 返回"
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

# ========== 菜单：双竖排 ==========
print_menu() {
  echo_color "\n====================== server-toolkit ${SERVER_TOOLKIT_VERSION} ======================"
  printf "  %-42s | %-42s\n" "1) 时间同步" "8) 显示服务器基本信息"
  printf "  %-42s | %-42s\n" "2) 关闭防火墙" "9) YABS 测试"
  printf "  %-42s | %-42s\n" "3) 关闭 SELinux" "10) 设置定时重启"
  printf "  %-42s | %-42s\n" "4) SSH 安全性增强向导" "11) 哪吒面板管理"
  printf "  %-42s | %-42s\n" "5) Fail2Ban 管理" "12) IP 质量检测"
  printf "  %-42s | %-42s\n" "6) SSH 端口/密码/密钥/root 管理" "13) IPv6 一键开启/关闭"
  printf "  %-42s | %-42s\n" "7) 流媒体解锁检测" "14) 服务器加固"
  printf "  %-42s\n" "0) 退出"
  echo_color "================================================================================="
}

require_root

while true; do
  print_menu
  read -p "请选择一个操作: " option

  case $option in
    1) time_sync; pause_return ;;
    2) disable_firewall; pause_return ;;
    3) disable_selinux; pause_return ;;
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
    0) echo_color "退出"; exit 0 ;;
    *) echo_error "无效的选项，请重新输入"; pause_return ;;
  esac
done
