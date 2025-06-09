#!/bin/bash

# 彩色输出函数
echo_color() {
    echo -e "\e[1;32m$1\e[0m"
}

echo_error() {
    echo -e "\e[1;31m$1\e[0m"
}

# 1. 时间同步
time_sync() {
    echo_color "正在配置每30分钟自动同步时间..."
    if ! command -v ntpdate &> /dev/null; then
        echo_color "ntpdate 未安装，正在安装..."
        if [ -f /etc/redhat-release ]; then
            yum install -y ntpdate
        else
            apt-get update && apt-get install -y ntpdate
        fi
    else
        echo_color "ntpdate 已安装"
    fi

    ntpdate time.google.com

    (crontab -l 2>/dev/null; echo "*/30 * * * * /usr/sbin/ntpdate time.google.com > /dev/null 2>&1") | crontab -
    echo_color "时间同步配置完成，每30分钟同步一次。"
}

# 2. 关闭防火墙
disable_firewall() {
    echo_color "正在关闭防火墙..."
    systemctl stop firewalld 2>/dev/null
    systemctl disable firewalld 2>/dev/null
    systemctl stop ufw 2>/dev/null
    systemctl disable ufw 2>/dev/null
    echo_color "防火墙已关闭。"
}

# 3. 关闭SELinux
disable_selinux() {
    echo_color "正在关闭SELinux..."
    if [ -f /etc/selinux/config ]; then
        sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
        setenforce 0 2>/dev/null
        echo_color "SELinux 已关闭（需重启后完全生效）。"
    else
        echo_error "未找到 SELinux 配置文件。"
    fi
}

# 4. SSH 安全性增强
secure_ssh() {
    echo_color "正在增强 SSH 安全性..."
    SSH_CONFIG_FILE="/etc/ssh/sshd_config"
    cp $SSH_CONFIG_FILE ${SSH_CONFIG_FILE}.bak

    grep -q "^Protocol" $SSH_CONFIG_FILE && sed -i "s/^Protocol.*/Protocol 2/" $SSH_CONFIG_FILE || echo "Protocol 2" >> $SSH_CONFIG_FILE
    grep -q "^LoginGraceTime" $SSH_CONFIG_FILE && sed -i "s/^LoginGraceTime.*/LoginGraceTime 30/" $SSH_CONFIG_FILE || echo "LoginGraceTime 30" >> $SSH_CONFIG_FILE
    grep -q "^MaxAuthTries" $SSH_CONFIG_FILE && sed -i "s/^MaxAuthTries.*/MaxAuthTries 3/" $SSH_CONFIG_FILE || echo "MaxAuthTries 3" >> $SSH_CONFIG_FILE
    grep -q "^PermitEmptyPasswords" $SSH_CONFIG_FILE && sed -i "s/^PermitEmptyPasswords.*/PermitEmptyPasswords no/" $SSH_CONFIG_FILE || echo "PermitEmptyPasswords no" >> $SSH_CONFIG_FILE
    grep -q "^UseDNS" $SSH_CONFIG_FILE && sed -i "s/^UseDNS.*/UseDNS no/" $SSH_CONFIG_FILE || echo "UseDNS no" >> $SSH_CONFIG_FILE

    systemctl restart sshd
    echo_color "SSH 安全性配置已完成。"
}

# 5. 安装并配置 Fail2Ban
setup_fail2ban() {
    echo_color "正在安装并配置 Fail2Ban..."
    if [ -f /etc/redhat-release ]; then
        yum install -y epel-release
        yum install -y fail2ban
    else
        apt-get update && apt-get install -y fail2ban
    fi

    cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ssh
logpath = /var/log/secure
maxretry = 3
bantime = 3600
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    echo_color "Fail2Ban 安装并配置完成。"
}

# 6. 修改 SSH 端口和密码
change_ssh_port_password() {
    echo_color "请不要关闭当前 SSH 连接，另开终端测试新连接是否成功！"
    read -p "请输入新的 SSH 端口: " new_port
    read -s -p "请输入 root 新密码: " new_password
    echo

    sed -i "/^#Port/c\Port ${new_port}" /etc/ssh/sshd_config
    echo "root:${new_password}" | chpasswd
    systemctl restart sshd
    echo_color "SSH 端口和密码已更新。"
}

# 7. 流媒体解锁检测
check_media_unlock() {
    bash <(curl -L -s check.unlock.media)
}

# 8. 显示服务器基本信息
show_system_info() {
    echo_color "---------------------服务器基本信息如下---------------------"
    CPU_MODEL=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^ //')
    CPU_CORES=$(nproc)
    CPU_FREQ=$(awk -F: '/cpu MHz/ {print $2; exit}' /proc/cpuinfo | sed 's/^ //')
    CACHE=$(lscpu | grep "L1d cache\|L2 cache\|L3 cache" | awk '{print $3}' | xargs | sed 's/ / \/ /g')
    AES_SUPPORT=$(lscpu | grep -q aes && echo "✔ Enabled" || echo "✘ Disabled")
    VM_SUPPORT=$(egrep -q 'vmx|svm' /proc/cpuinfo && echo "✔ Enabled" || echo "✘ Disabled")
    MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')
    SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
    DISK_INFO=$(df -h / | awk 'NR==2 {print $3 " / " $2}')
    BOOT_DISK=$(df -h / | awk 'NR==2 {print $1}')
    UPTIME=$(uptime -p)
    LOAD_AVG=$(uptime | awk -F'load average:' '{ print $2 }')
    OS_INFO=$(hostnamectl | grep "Operating System" | cut -d: -f2 | sed 's/^ //')
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
    echo -e " 系统              : $OS_INFO"
    echo -e " 架构              : $ARCH_INFO (64 Bit)"
    echo -e " 内核              : $KERNEL"
}

# 9. YABS 测试
yabs_test() {
    curl -sL yabs.sh | bash
}

# 10. 设置定时重启
setup_cron_reboot() {
    read -p "请输入每隔多少小时重启一次（例如 12）: " interval
    if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
        echo_error "请输入有效的数字"
        return
    fi

    (crontab -l 2>/dev/null; echo "0 */$interval * * * /sbin/reboot") | crontab -
    echo_color "已设置每隔 $interval 小时自动重启系统"
}

# 11. 卸载哪吒面板
uninstall_nezha() {
    echo_color "正在卸载哪吒面板..."
    systemctl stop nezha-agent
    systemctl stop nezha-dashboard
    systemctl disable nezha-agent
    systemctl disable nezha-dashboard
    rm -f /etc/systemd/system/nezha-agent.service
    rm -f /etc/systemd/system/nezha-dashboard.service
    rm -rf /opt/nezha /etc/nezha /var/log/nezha
    systemctl daemon-reload
    echo_color "哪吒面板已完全移除"
}

# 12. IP 质量检测
check_ip_quality() {
    bash <(curl -Ls IP.Check.Place)
}

# 菜单
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
        0) echo_color "退出"; exit 0;;
        *) echo_error "无效的选项，请重新输入";;
    esac

done
