#!/bin/bash
set -u

# ========== 彩色输出 ==========
echo_color() { echo -e "\e[1;32m$1\e[0m"; }
echo_warn()  { echo -e "\e[1;33m$1\e[0m"; }
echo_error() { echo -e "\e[1;31m$1\e[0m"; }

# ========== 基础检测 ==========
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo_error "请使用 root 运行此脚本。"
    exit 1
  fi
}

is_redhat() { [ -f /etc/redhat-release ]; }

ssh_service_name() {
  # Debian/Ubuntu 通常是 ssh；RHEL/CentOS 通常是 sshd
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

  # 幂等：加 marker，避免重复写入
  local marker="# server-toolkit: time_sync"
  crontab -l 2>/dev/null | grep -v "$marker" > /tmp/cron.tmp || true
  echo "*/30 * * * * /usr/sbin/ntpdate time.google.com >/dev/null 2>&1 $marker" >> /tmp/cron.tmp
  crontab /tmp/cron.tmp
  rm -f /tmp/cron.tmp

  echo_color "时间同步配置完成：每30分钟同步一次（cron）。"
}

# ========== 2. 关闭防火墙 ==========
disable_firewall() {
  echo_color "正在关闭防火墙..."
  systemctl stop firewalld 2>/dev/null || true
  systemctl disable firewalld 2>/dev/null || true
  systemctl stop ufw 2>/dev/null || true
  systemctl disable ufw 2>/dev/null || true
  echo_color "防火墙服务已尝试关闭（若有云厂商安全组/外部防火墙不在此范围）。"
}

# ========== 3. 关闭SELinux ==========
disable_selinux() {
  echo_color "正在关闭SELinux..."
  if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    setenforce 0 2>/dev/null || true
    echo_color "SELinux 已关闭（需重启后完全生效）。"
  else
    echo_warn "未找到 SELinux 配置文件（Debian/Ubuntu 属正常）。"
  fi
}

# ========== 4. SSH 安全性增强 ==========
secure_ssh() {
  echo_color "正在增强 SSH 安全性..."
  local SSH_CONFIG_FILE="/etc/ssh/sshd_config"
  [ -f "$SSH_CONFIG_FILE" ] || { echo_error "找不到 $SSH_CONFIG_FILE"; return 1; }

  cp "$SSH_CONFIG_FILE" "${SSH_CONFIG_FILE}.bak.$(date +%F_%T)"

  # 安全写入：存在就替换，不存在就追加
  set_kv() {
    local key="$1" val="$2" file="$3"
    if grep -Eq "^[#[:space:]]*$key[[:space:]]+" "$file"; then
      sed -i -E "s|^[#[:space:]]*$key[[:space:]].*|$key $val|g" "$file"
    else
      echo "$key $val" >> "$file"
    fi
  }

  # Protocol 2 在新 OpenSSH 上通常默认就是 2（可能被忽略），但写上无害
  set_kv "Protocol" "2" "$SSH_CONFIG_FILE"
  set_kv "LoginGraceTime" "30" "$SSH_CONFIG_FILE"
  set_kv "MaxAuthTries" "3" "$SSH_CONFIG_FILE"
  set_kv "PermitEmptyPasswords" "no" "$SSH_CONFIG_FILE"
  set_kv "UseDNS" "no" "$SSH_CONFIG_FILE"

  if ! test_sshd_config; then
    echo_error "sshd 配置检测失败（sshd -t）。已保留备份文件，请修复后再重启。"
    return 1
  fi

  restart_ssh_service || return 1
  echo_color "SSH 安全性配置已完成。"
}

# ========== 5. 安装并配置 Fail2Ban ==========
setup_fail2ban() {
  echo_color "正在安装并配置 Fail2Ban..."
  if is_redhat; then
    yum install -y epel-release
    yum install -y fail2ban
    local logpath="/var/log/secure"
  else
    apt-get update -y && apt-get install -y fail2ban
    local logpath="/var/log/auth.log"
  fi

  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
port = ssh
logpath = $logpath
EOF

  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  echo_color "Fail2Ban 安装并配置完成（maxretry=3，bantime=3600s）。"
}

# ========== 6. 修改 SSH 端口和密码（重点修复） ==========
change_ssh_port_password() {
  echo_color "请不要关闭当前 SSH 连接，另开终端测试新连接是否成功！"

  local SSH_CONFIG_FILE="/etc/ssh/sshd_config"
  [ -f "$SSH_CONFIG_FILE" ] || { echo_error "找不到 $SSH_CONFIG_FILE"; return 1; }

  read -p "请输入新的 SSH 端口 (1-65535): " new_port
  if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
    echo_error "端口不合法。"
    return 1
  fi

  # 端口占用检查
  if ss -lnt | awk '{print $4}' | grep -Eq "[:.]${new_port}$"; then
    echo_error "端口 $new_port 已被占用，请换一个。"
    return 1
  fi

  read -s -p "请输入 root 新密码: " new_password
  echo
  if [ -z "$new_password" ]; then
    echo_error "密码不能为空。"
    return 1
  fi

  cp "$SSH_CONFIG_FILE" "${SSH_CONFIG_FILE}.bak.$(date +%F_%T)"

  # 更稳的 Port 修改：替换任何 Port 行（含注释/空格），不存在则追加
  if grep -Eq "^[#[:space:]]*Port[[:space:]]+" "$SSH_CONFIG_FILE"; then
    sed -i -E "s|^[#[:space:]]*Port[[:space:]]+.*|Port ${new_port}|g" "$SSH_CONFIG_FILE"
  else
    echo "Port ${new_port}" >> "$SSH_CONFIG_FILE"
  fi

  # 提醒：如果启用了 sshd_config.d，里面还有 Port 22 可能导致同时监听
  if [ -d /etc/ssh/sshd_config.d ]; then
    if grep -RInE "^[#[:space:]]*Port[[:space:]]+22\b" /etc/ssh/sshd_config.d 2>/dev/null | head -n 1 >/dev/null; then
      echo_warn "检测到 /etc/ssh/sshd_config.d 中可能存在 Port 22，可能导致同时监听旧端口。"
      echo_warn "可用：sshd -T | grep -i '^port ' 查看最终生效端口。"
    fi
  fi

  if ! test_sshd_config; then
    echo_error "sshd 配置检测失败（sshd -t）。已保留备份，未重启。"
    return 1
  fi

  echo "root:${new_password}" | chpasswd || { echo_error "修改密码失败"; return 1; }

  restart_ssh_service || return 1

  echo_color "SSH 端口和密码已更新。"
  echo_color "请在新终端测试：ssh -p ${new_port} root@你的服务器IP"
  echo_warn  "确认新端口可登录后，再考虑放行/关闭旧端口（若仍在监听）。"
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
  echo -e " 系统              : ${OS_INFO:-$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d \")}"
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

# ========== 11. 卸载哪吒面板 ==========
uninstall_nezha() {
  echo_color "正在卸载哪吒面板..."
  systemctl stop nezha-agent 2>/dev/null || true
  systemctl stop nezha-dashboard 2>/dev/null || true
  systemctl disable nezha-agent 2>/dev/null || true
  systemctl disable nezha-dashboard 2>/dev/null || true
  rm -f /etc/systemd/system/nezha-agent.service
  rm -f /etc/systemd/system/nezha-dashboard.service
  rm -rf /opt/nezha /etc/nezha /var/log/nezha
  systemctl daemon-reload
  echo_color "哪吒面板已完全移除"
}

# ========== 12. IP 质量检测 ==========
check_ip_quality() { bash <(curl -Ls IP.Check.Place); }

# ========== 13. IPv6 一键开启/关闭 ==========
manage_ipv6() {
  echo_color "IPv6 一键开启/关闭"
  echo_warn  "提示：开启 IPv6 只是允许系统使用 IPv6；是否获得 IPv6 地址取决于服务商是否分配/路由。"

  # /proc 是否存在（模块/内核支持检查）
  if [ ! -d /proc/sys/net/ipv6 ]; then
    echo_warn "检测到 /proc/sys/net/ipv6 不存在，尝试加载 ipv6 模块..."
    modprobe ipv6 2>/dev/null || true
  fi
  if [ ! -d /proc/sys/net/ipv6 ]; then
    echo_error "当前内核/环境不支持 IPv6（或已被禁用到无法加载）。"
    return 1
  fi

  local cur_all cur_def cur_lo
  cur_all="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "N/A")"
  cur_def="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo "N/A")"
  cur_lo="$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || echo "N/A")"

  echo_color "当前状态："
  echo "  all.disable_ipv6     = $cur_all  (0=启用, 1=禁用)"
  echo "  default.disable_ipv6 = $cur_def  (0=启用, 1=禁用)"
  echo "  lo.disable_ipv6      = $cur_lo   (0=启用, 1=禁用)"
  echo

  echo "1) 一键开启 IPv6"
  echo "2) 一键关闭 IPv6"
  echo "3) 查看 IPv6 地址（ip -6 addr）"
  echo "0) 返回"
  read -p "请选择: " ipv6_opt

  local conf="/etc/sysctl.d/99-server-toolkit-ipv6.conf"
  case "$ipv6_opt" in
    1)
      echo_color "正在开启 IPv6（立即生效 + 持久化）..."
      sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
      sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
      sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true

      cat > "$conf" <<EOF
# server-toolkit: ipv6
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.lo.disable_ipv6=0
EOF
      sysctl --system >/dev/null 2>&1 || sysctl -p "$conf" >/dev/null 2>&1 || true

      echo_color "IPv6 已设置为开启。"
      echo_warn  "如仍未分配 IPv6 地址，请检查服务商是否提供 IPv6 / 是否需要在面板开启 / 是否有 RA 或静态 IPv6。"
      ;;
    2)
      echo_color "正在关闭 IPv6（立即生效 + 持久化）..."
      sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
      sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
      sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true

      cat > "$conf" <<EOF
# server-toolkit: ipv6
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
      sysctl --system >/dev/null 2>&1 || sysctl -p "$conf" >/dev/null 2>&1 || true

      echo_color "IPv6 已设置为关闭。"
      ;;
    3)
      echo_color "当前 IPv6 地址信息："
      ip -6 addr || true
      ;;
    0)
      return 0
      ;;
    *)
      echo_error "无效选项"
      ;;
  esac
}

# ========== 菜单 ==========
require_root

while true; do
  echo_color "\n=============== 服务器工具包菜单 ==============="
  echo "1) 时间同步"
  echo "2) 关闭防火墙"
  echo "3) 关闭SELinux"
  echo "4) SSH 安全性增强"
  echo "5) 安装并配置 Fail2Ban"
  echo "6) 修改 SSH 端口和密码"
  echo "7) 流媒体解锁检测"
  echo "8) 显示服务器基本信息"
  echo "9) YABS 测试"
  echo "10) 设置定时重启"
  echo "11) 卸载哪吒面板"
  echo "12) IP 质量检测"
  echo "13) IPv6 一键开启/关闭"
  echo "0) 退出"
  read -p "请选择一个操作: " option

  case $option in
    1) time_sync;;
    2) disable_firewall;;
    3) disable_selinux;;
    4) secure_ssh;;
    5) setup_fail2ban;;
    6) change_ssh_port_password;;
    7) check_media_unlock;;
    8) show_system_info;;
    9) yabs_test;;
    10) setup_cron_reboot;;
    11) uninstall_nezha;;
    12) check_ip_quality;;
    13) manage_ipv6;;
    0) echo_color "退出"; exit 0;;
    *) echo_error "无效的选项，请重新输入";;
  esac
done
