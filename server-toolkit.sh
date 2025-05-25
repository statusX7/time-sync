#!/bin/bash

set -e

# 彩色输出函数
print_info() {
  echo -e "\033[1;34m[INFO]\033[0m $1"
}

print_success() {
  echo -e "\033[1;32m[SUCCESS]\033[0m $1"
}

print_warning() {
  echo -e "\033[1;33m[WARNING]\033[0m $1"
}

print_error() {
  echo -e "\033[1;31m[ERROR]\033[0m $1"
}

sync_time() {
  print_info "正在检查 ntpdate 是否安装..."
  if ! command -v ntpdate &> /dev/null; then
    print_info "ntpdate 未安装，正在安装..."
    yum install -y ntpdate
  else
    print_info "ntpdate 已安装，检查是否为最新版本..."
    yum update -y ntpdate
  fi

  print_info "正在设置每30分钟自动同步时间..."
  echo '*/30 * * * * /usr/sbin/ntpdate time.google.com &> /dev/null && echo "时间已同步: $(date)"' > /etc/cron.d/time-sync
  chmod 644 /etc/cron.d/time-sync
  systemctl restart crond
  print_success "已设置每30分钟同步时间。"
}

disable_firewall() {
  print_info "正在关闭防火墙..."
  systemctl stop firewalld
  systemctl disable firewalld
  print_success "防火墙已关闭。"
}

disable_selinux() {
  print_info "正在关闭 SELinux..."
  sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
  setenforce 0 || true
  print_success "SELinux 已关闭（可能需要重启生效）。"
}

secure_ssh() {
  print_info "正在增强 SSH 安全性..."
  SSH_CONFIG="/etc/ssh/sshd_config"
  sed -i 's/^#*\s*Protocol.*/Protocol 2/' "$SSH_CONFIG"
  sed -i 's/^#*\s*PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$SSH_CONFIG"
  sed -i 's/^#*\s*PermitRootLogin.*/PermitRootLogin yes/' "$SSH_CONFIG"
  sed -i 's/^#*\s*MaxAuthTries.*/MaxAuthTries 3/' "$SSH_CONFIG"
  sed -i 's/^#*\s*LoginGraceTime.*/LoginGraceTime 30/' "$SSH_CONFIG"
  sed -i 's/^#*\s*UseDNS.*/UseDNS no/' "$SSH_CONFIG"
  systemctl restart sshd
  print_success "SSH 配置已增强。"
}

install_fail2ban() {
  print_info "正在安装 Fail2Ban..."
  yum install -y epel-release
  yum install -y fail2ban
  cat >/etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/secure
maxretry = 3
bantime = 3600
EOF
  systemctl enable fail2ban
  systemctl restart fail2ban
  print_success "Fail2Ban 已安装并配置成功。"
}

change_ssh_port_password() {
  print_info "修改 SSH 端口和密码"
  echo "请不要关闭当前 SSH 连接，另开终端测试新连接是否成功！"
  read -p "请输入新 SSH 端口（例如 2222）: " new_port
  read -s -p "请输入 root 新密码: " new_pass
  echo

  SSH_CONFIG="/etc/ssh/sshd_config"
  sed -i "/^#Port/c\Port $new_port" $SSH_CONFIG
  sed -i "/^Port/c\Port $new_port" $SSH_CONFIG

  echo "root:$new_pass" | chpasswd
  systemctl restart sshd
  print_success "SSH 端口和密码已更新，请确认新连接正常后关闭当前会话。"
}

unlock_media() {
  print_info "运行流媒体解锁检测脚本..."
  bash <(curl -L -s check.unlock.media)
}

show_system_info() {
  print_info "系统基本信息如下："
  echo -e "\n\033[1;36m==== 🧠 CPU 信息 ===\033[0m"
  lscpu | grep -E 'Model name|CPU\(s\):|MHz|Cache' | sed 's/^/  /'

  echo -e "\n\033[1;36m==== 💽 硬盘使用 ===\033[0m"
  df -h --total | grep -E 'Filesystem|total' | sed 's/^/  /'

  echo -e "\n\033[1;36m==== 🧮 内存与 Swap ===\033[0m"
  free -h | sed 's/^/  /'

  echo -e "\n\033[1;36m==== ⏱️ 在线时间与负载 ===\033[0m"
  uptime | sed 's/^/  /'

  echo -e "\n\033[1;36m==== 🖥️ 系统版本 ===\033[0m"
  (cat /etc/redhat-release 2>/dev/null || cat /etc/os-release) | sed 's/^/  /'

  echo -e "\n\033[1;36m==== ⚙️ 虚拟化支持 ===\033[0m"
  grep -E -c 'vmx|svm' /proc/cpuinfo | awk '{print "  虚拟化支持线程数: "$1}'
}

yabs_test() {
  print_info "运行 YABS 性能测试..."
  curl -sL yabs.sh | bash
}

while true; do
  echo -e "\n=========== 🛠️ 服务器工具箱菜单 ==========="
  echo "1) 每30分钟自动同步时间"
  echo "2) 关闭防火墙"
  echo "3) 关闭 SELinux"
  echo "4) SSH 安全性增强"
  echo "5) 安装并配置 Fail2Ban"
  echo "6) 修改 SSH 端口和密码"
  echo "7) 流媒体解锁检测"
  echo "8) 显示服务器基本信息"
  echo "9) YABS 性能测试"
  echo "0) 退出"
  echo "==========================================="
  read -p "请输入选项编号: " option
  case $option in
    1) sync_time;;
    2) disable_firewall;;
    3) disable_selinux;;
    4) secure_ssh;;
    5) install_fail2ban;;
    6) change_ssh_port_password;;
    7) unlock_media;;
    8) show_system_info;;
    9) yabs_test;;
    0) exit;;
    *) print_error "无效选项，请重新输入。";;
  esac
done
