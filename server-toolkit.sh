#!/bin/bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

function sync_time() {
    echo -e "${GREEN}同步时间...${RESET}"
    if [ -f /etc/redhat-release ]; then
        yum install -y ntpdate
    elif [ -f /etc/debian_version ]; then
        apt update && apt install -y ntpdate
    fi
    ntpdate time.google.com
    echo "0 */12 * * * /usr/sbin/ntpdate time.google.com > /dev/null 2>&1" > /etc/cron.d/time-sync
    echo -e "${GREEN}[√] 每12小时同步一次时间${RESET}"
}

function disable_firewall() {
    echo -e "${YELLOW}关闭防火墙...${RESET}"
    systemctl stop firewalld 2>/dev/null
    systemctl disable firewalld 2>/dev/null
    systemctl stop ufw 2>/dev/null
    systemctl disable ufw 2>/dev/null
    echo -e "${GREEN}[√] 防火墙已关闭${RESET}"
}

function disable_selinux() {
    echo -e "${YELLOW}关闭 SELinux...${RESET}"
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    setenforce 0 2>/dev/null
    echo -e "${GREEN}[√] SELinux 已禁用，重启后生效${RESET}"
}

function secure_ssh() {
    echo -e "${YELLOW}增强 SSH 安全性...${RESET}"
    SSHD_CONFIG="/etc/ssh/sshd_config"
    cp -a "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"

    sed -i 's/^#\?Protocol.*/Protocol 2/' "$SSHD_CONFIG"
    sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$SSHD_CONFIG"
    sed -i 's/^#\?UseDNS.*/UseDNS no/' "$SSHD_CONFIG"
    sed -i 's/^#\?LoginGraceTime.*/LoginGraceTime 30/' "$SSHD_CONFIG"
    sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' "$SSHD_CONFIG"
    sed -i 's/^#\?ClientAliveInterval.*/ClientAliveInterval 300/' "$SSHD_CONFIG"
    sed -i 's/^#\?ClientAliveCountMax.*/ClientAliveCountMax 2/' "$SSHD_CONFIG"
    sed -i 's/^#\?LogLevel.*/LogLevel VERBOSE/' "$SSHD_CONFIG"
    sed -i 's/^#\?UsePAM.*/UsePAM yes/' "$SSHD_CONFIG"

    systemctl restart sshd
    echo -e "${GREEN}[√] SSH 已强化${RESET}"
}

function install_fail2ban() {
    echo -e "${YELLOW}安装并配置 Fail2Ban...${RESET}"
    if [ -f /etc/redhat-release ]; then
        yum install -y epel-release
        yum install -y fail2ban
    elif [ -f /etc/debian_version ]; then
        apt update
        apt install -y fail2ban
    fi

    mkdir -p /etc/fail2ban
    cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = $( [ -f /etc/debian_version ] && echo "/var/log/auth.log" || echo "/var/log/secure" )
bantime = 600
findtime = 600
maxretry = 3
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    echo -e "${GREEN}[√] Fail2Ban 已配置并启动${RESET}"
}

function modify_ssh_port_password() {
    echo -e "${YELLOW}修改 SSH 端口和密码...${RESET}"
    read -p "请输入新端口 (1-65535): " new_port
    read -p "请输入要修改密码的用户名: " user
    passwd "$user"
    sed -i "s/^#\?Port .*/Port $new_port/" /etc/ssh/sshd_config
    systemctl restart sshd
    echo -e "${GREEN}[√] SSH 端口和密码已更新${RESET}"
}

function check_stream_unlock() {
    bash <(curl -L -s check.unlock.media)
}

function show_system_info() {
    echo -e "${GREEN}系统基本信息：${RESET}"
    echo "CPU型号: $(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo)"
    echo "CPU核心数: $(nproc)"
    echo "CPU频率: $(awk -F: '/cpu MHz/ {print $2; exit}' /proc/cpuinfo) MHz"
    echo "CPU缓存: $(awk -F: '/cache size/ {print $2; exit}' /proc/cpuinfo)"
    echo "内存: $(free -h | awk '/Mem/ {print $2}')"
    echo "Swap: $(free -h | awk '/Swap/ {print $2}')"
    echo "硬盘空间: $(df -h / | awk 'NR==2{print $2}')"
    echo "启动盘路径: $(df / | awk 'NR==2{print $1}')"
    echo "系统在线时间: $(uptime -p)"
    echo "系统负载: $(uptime | awk -F'load average: ' '{print $2}')"
    echo "系统版本: $(uname -a)"
    echo "虚拟化: $(systemd-detect-virt)"
    echo "VM-x/AMD-V支持: $(egrep -c '(vmx|svm)' /proc/cpuinfo > /dev/null && echo 有 || echo 无)"
    echo "TCP加速方式: $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
    echo "IPV4 ASN 与位置: $(curl -s ip-api.com/json | awk -F'"' '/as/ {a=$4} /country/ {c=$4} END{print a, c}')"
}

function menu() {
    echo -e "${GREEN}===== Linux 服务器管理工具 =====${RESET}"
    echo "1. 同步时间"
    echo "2. 关闭防火墙"
    echo "3. 关闭 SELinux"
    echo "4. 增强 SSH 配置"
    echo "5. 安装 & 配置 fail2ban"
    echo "6. 修改 SSH 端口和密码"
    echo "7. 流媒体解锁检测"
    echo "8. 显示服务器基本信息"
    echo "0. 退出"
    read -p "请输入选项 [0-8]: " choice

    case $choice in
        1) sync_time ;;
        2) disable_firewall ;;
        3) disable_selinux ;;
        4) secure_ssh ;;
        5) install_fail2ban ;;
        6) modify_ssh_port_password ;;
        7) check_stream_unlock ;;
        8) show_system_info ;;
        0) echo "退出"; exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo ""
done
