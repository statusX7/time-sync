#!/bin/bash

# 彩色输出函数
print_section() {
    echo -e "\n\033[1;36m---------------------$1---------------------\033[0m"
}

print_success() {
    echo -e "\033[1;32m$1\033[0m"
}

print_error() {
    echo -e "\033[1;31m$1\033[0m"
}

# 1. 每30分钟自动同步时间
sync_time() {
    print_section "启用每30分钟时间同步"
    if ! command -v ntpdate &> /dev/null; then
        print_section "安装 ntpdate..."
        if [ -f /etc/redhat-release ]; then
            yum install -y ntpdate
        else
            apt-get update && apt-get install -y ntpdate
        fi
    else
        print_success "ntpdate 已安装"
    fi

    ntpdate time.google.com && print_success "时间已同步"

    (crontab -l 2>/dev/null; echo "*/30 * * * * /usr/sbin/ntpdate time.google.com > /dev/null 2>&1") | sort -u | crontab -
    print_success "已设置每30分钟自动同步时间"
}

# 2. 关闭防火墙
stop_firewall() {
    print_section "关闭防火墙"
    systemctl stop firewalld
    systemctl disable firewalld
    print_success "防火墙已关闭并禁用"
}

# 3. 关闭 SELinux
stop_selinux() {
    print_section "关闭 SELinux"
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    setenforce 0
    print_success "SELinux 已关闭（重启后生效）"
}

# 4. SSH 安全性增强
secure_ssh_config() {
    print_section "增强 SSH 配置"
    SSH_CONFIG="/etc/ssh/sshd_config"

    sed -i '/^#*\s*Protocol/d' "$SSH_CONFIG"
    echo "Protocol 2" >> "$SSH_CONFIG"

    grep -q '^PermitEmptyPasswords' "$SSH_CONFIG" && sed -i 's/^PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$SSH_CONFIG" || echo "PermitEmptyPasswords no" >> "$SSH_CONFIG"
    grep -q '^LoginGraceTime' "$SSH_CONFIG" && sed -i 's/^LoginGraceTime.*/LoginGraceTime 30/' "$SSH_CONFIG" || echo "LoginGraceTime 30" >> "$SSH_CONFIG"
    grep -q '^MaxAuthTries' "$SSH_CONFIG" && sed -i 's/^MaxAuthTries.*/MaxAuthTries 3/' "$SSH_CONFIG" || echo "MaxAuthTries 3" >> "$SSH_CONFIG"
    grep -q '^IgnoreRhosts' "$SSH_CONFIG" || echo "IgnoreRhosts yes" >> "$SSH_CONFIG"
    grep -q '^HostbasedAuthentication' "$SSH_CONFIG" || echo "HostbasedAuthentication no" >> "$SSH_CONFIG"
    grep -q '^PermitRootLogin' "$SSH_CONFIG" || echo "PermitRootLogin yes" >> "$SSH_CONFIG"

    systemctl restart sshd
    print_success "SSH 配置已增强"
}

# 5. 安装并配置 fail2ban
setup_fail2ban() {
    print_section "安装并配置 fail2ban"
    if [ -f /etc/redhat-release ]; then
        yum install -y epel-release && yum install -y fail2ban
    else
        apt-get update && apt-get install -y fail2ban
    fi

    cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
backend = systemd
maxretry = 3
bantime = 3600
EOF

    systemctl enable fail2ban
    systemctl start fail2ban
    print_success "fail2ban 已安装并启动"
}

# 6. 修改 SSH 端口和密码
modify_ssh_port_password() {
    print_section "修改 SSH 端口和密码"
    read -p "请输入新的 SSH 端口 (默认 22): " new_port
    new_port=${new_port:-22}
    sed -i "s/^#Port .*/Port $new_port/;s/^Port .*/Port $new_port/" /etc/ssh/sshd_config

    read -p "请输入要修改密码的用户名 (默认 root): " user
    user=${user:-root}
    passwd "$user"

    print_error "请不要关闭当前 SSH 连接，另开终端测试新连接是否成功！"
    systemctl restart sshd
    print_success "SSH 端口和密码已修改"
}

# 7. 流媒体检测
media_unlock_test() {
    print_section "流媒体解锁检测"
    bash <(curl -L -s check.unlock.media)
}

# 8. 显示系统基本信息
show_system_info() {
    print_section "服务器基本信息如下"
    CPU_MODEL=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | xargs)
    CPU_CORES=$(grep -c ^processor /proc/cpuinfo)
    CPU_MHZ=$(awk -F: '/cpu MHz/ {print $2; exit}' /proc/cpuinfo | xargs)
    CPU_CACHE=$(lscpu | grep "L1d cache\|L2 cache\|L3 cache")
    AES=$(lscpu | grep -o aes)
    VMX=$(lscpu | grep -Eo 'vmx|svm')

    MEM_TOTAL=$(free -h | awk '/Mem:/ {print $2}')
    MEM_USED=$(free -h | awk '/Mem:/ {print $3}')
    SWAP_TOTAL=$(free -h | awk '/Swap:/ {print $2}')
    SWAP_USED=$(free -h | awk '/Swap:/ {print $3}')

    DISK_TOTAL=$(df -h --total | grep total | awk '{print $2}')
    DISK_USED=$(df -h --total | grep total | awk '{print $3}')
    ROOT_DISK=$(df -h / | awk 'NR==2{print $1}')

    UPTIME=$(uptime -p | cut -d " " -f2-)
    LOAD=$(uptime | awk -F 'load average:' '{print $2}' | xargs)
    OS=$(hostnamectl | grep "Operating System" | cut -d ':' -f2 | xargs)
    ARCH=$(uname -m)
    KERNEL=$(uname -r)

    echo -e "\033[1;32m CPU 型号          : $CPU_MODEL"
    echo -e " CPU 核心数        : $CPU_CORES"
    echo -e " CPU 频率          : ${CPU_MHZ} MHz"
    echo -e " AES-NI指令集      : $( [ "$AES" ] && echo ✔ Enabled || echo ✘ Disabled )"
    echo -e " VM-x/AMD-V支持    : $( [ "$VMX" ] && echo ✔ Enabled || echo ✘ Disabled )"
    echo -e " 内存              : $MEM_USED / $MEM_TOTAL"
    echo -e " Swap              : $SWAP_USED / $SWAP_TOTAL"
    echo -e " 硬盘空间          : $DISK_USED / $DISK_TOTAL"
    echo -e " 启动盘路径        : $ROOT_DISK"
    echo -e " 系统在线时间      : $UPTIME"
    echo -e " 负载              : $LOAD"
    echo -e " 系统              : $OS"
    echo -e " 架构              : $ARCH"
    echo -e " 内核              : $KERNEL\033[0m"
}

# 9. YABS 测试
run_yabs() {
    curl -sL yabs.sh | bash
}

# 10. 自定义周期重启
setup_cron_reboot() {
    print_section "设置周期性自动重启"
    read -p "请输入每隔多少小时重启一次 (1~168): " hours
    [[ -z "$hours" || ! "$hours" =~ ^[0-9]+$ || "$hours" -lt 1 || "$hours" -gt 168 ]] && print_error "输入无效" && return
    minute=$(( RANDOM % 60 ))
    echo "$minute */$hours * * * /sbin/reboot" | crontab -l 2>/dev/null | grep -v reboot; echo "$minute */$hours * * * /sbin/reboot" | crontab -
    print_success "已设置每隔 $hours 小时自动重启"
}

# 11. 卸载哪吒面板
uninstall_nezha() {
    print_section "卸载哪吒面板"
    systemctl stop nezha-agent
    systemctl stop nezha-dashboard

    systemctl disable nezha-agent
    systemctl disable nezha-dashboard

    rm -f /etc/systemd/system/nezha-agent.service
    rm -f /etc/systemd/system/nezha-dashboard.service

    rm -rf /opt/nezha
    rm -rf /etc/nezha
    rm -rf /var/log/nezha

    systemctl daemon-reload
    print_success "哪吒面板已完全移除"
}

# 菜单
while true; do
    echo -e "\n\033[1;34m========= 多功能服务器工具菜单 =========\033[0m"
    echo "1) 每30分钟时间同步"
    echo "2) 关闭防火墙"
    echo "3) 关闭 SELinux"
    echo "4) SSH 安全性增强"
    echo "5) 安装 & 配置 fail2ban"
    echo "6) 修改 SSH 端口和密码"
    echo "7) 流媒体解锁检测"
    echo "8) 显示服务器基本信息"
    echo "9) YABS 测试服务器性能"
    echo "10) 设置周期自动重启"
    echo "11) 卸载哪吒面板"
    echo "0) 退出"
    read -p "请选择一个操作: " choice

    case $choice in
        1) sync_time;;
        2) stop_firewall;;
        3) stop_selinux;;
        4) secure_ssh_config;;
        5) setup_fail2ban;;
        6) modify_ssh_port_password;;
        7) media_unlock_test;;
        8) show_system_info;;
        9) run_yabs;;
        10) setup_cron_reboot;;
        11) uninstall_nezha;;
        0) exit;;
        *) print_error "无效的选项，请重新选择";;
    esac

done
