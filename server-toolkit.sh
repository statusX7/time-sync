#!/bin/bash

# ---------------- 函数定义区 ----------------

sync_time() {
    echo "\n[+] 检查并安装/更新 ntpdate..."
    if ! command -v ntpdate &>/dev/null; then
        echo "[+] 未检测到 ntpdate，开始安装..."
        if [ -f /etc/redhat-release ]; then
            yum install -y ntpdate
        else
            apt-get update && apt-get install -y ntpdate
        fi
    else
        echo "[+] ntpdate 已安装，检查是否需要更新..."
        if [ -f /etc/redhat-release ]; then
            yum update -y ntpdate
        else
            apt-get install --only-upgrade -y ntpdate
        fi
    fi

    echo "[+] 正在进行时间同步..."
    ntpdate time.google.com

    echo "[+] 添加定时任务：每30分钟自动同步时间"
    (crontab -l 2>/dev/null | grep -v 'ntpdate time.google.com'; echo "*/30 * * * * /usr/sbin/ntpdate time.google.com > /dev/null 2>&1") | crontab -
    echo "[✓] 时间同步设置完成，每30分钟将自动同步一次时间。"
}

close_firewall() {
    echo "[+] 正在关闭防火墙..."
    systemctl stop firewalld
    systemctl disable firewalld
    echo "[✓] 防火墙已关闭"
}

close_selinux() {
    echo "[+] 正在关闭 SELinux..."
    setenforce 0
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    echo "[✓] SELinux 已关闭（需要重启生效）"
}

secure_ssh_config() {
    echo "[+] 开始增强 SSH 配置安全性..."
    SSH_CONFIG="/etc/ssh/sshd_config"

    cp "$SSH_CONFIG" "$SSH_CONFIG.bak"

    sed -i 's/^#*Protocol .*/Protocol 2/' "$SSH_CONFIG"
    sed -i 's/^#*PermitEmptyPasswords .*/PermitEmptyPasswords no/' "$SSH_CONFIG"
    sed -i 's/^#*MaxAuthTries .*/MaxAuthTries 3/' "$SSH_CONFIG"
    sed -i 's/^#*LoginGraceTime .*/LoginGraceTime 30/' "$SSH_CONFIG"
    sed -i 's/^#*IgnoreRhosts .*/IgnoreRhosts yes/' "$SSH_CONFIG"
    sed -i 's/^#*HostbasedAuthentication .*/HostbasedAuthentication no/' "$SSH_CONFIG"
    sed -i 's/^#*PermitRootLogin .*/PermitRootLogin yes/' "$SSH_CONFIG"
    sed -i 's/^#*StrictModes .*/StrictModes yes/' "$SSH_CONFIG"

    echo "[✓] SSH 配置增强已完成，正在重启 sshd 服务以应用更改..."
    systemctl restart sshd
}

install_fail2ban() {
    echo "[+] 正在安装 Fail2Ban..."
    if [ -f /etc/redhat-release ]; then
        yum install -y epel-release
        yum install -y fail2ban
    else
        apt-get update
        apt-get install -y fail2ban
    fi

    cat >/etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/secure
maxretry = 3
bantime = 600
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    echo "[✓] Fail2Ban 安装并启动成功（3次失败登录将封禁10分钟）"
}

change_ssh_port_pass() {
    echo "[!] 请不要关闭当前 SSH 连接，另开终端测试新连接是否成功！"
    read -p "请输入新的 SSH 端口（默认22）: " NEW_PORT
    read -p "请输入新的 root 密码: " NEW_PASS

    if [[ -n "$NEW_PORT" ]]; then
        sed -i "/^#Port/s/^#//;s/^Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
        firewall-cmd --permanent --add-port=${NEW_PORT}/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    echo "root:$NEW_PASS" | chpasswd
    systemctl restart sshd
    echo "[✓] SSH 端口和密码已修改"
}

media_unlock_test() {
    bash <(curl -L -s check.unlock.media)
}

show_system_info() {
    echo -e "\n\e[1;32m---------------------服务器基本信息如下---------------------\e[0m"

    CPU_MODEL=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^ //')
    CPU_CORES=$(nproc)
    CPU_FREQ=$(awk -F: '/cpu MHz/ {print $2; exit}' /proc/cpuinfo | sed 's/^ //')
    CACHE=$(lscpu | grep "L1d cache" | awk '{print $3}')
    [[ -z "$CACHE" ]] && CACHE="0.00 KB"

    AES=$(lscpu | grep -o aes &>/dev/null && echo "✔ Enabled" || echo "✘ Disabled")
    VMX=$(lscpu | grep -E "vmx|svm" &>/dev/null && echo "✔ Enabled" || echo "✘ Disabled")

    MEM_INFO=$(free -h | awk '/Mem/ {print $3" / "$2}')
    SWAP_INFO=$(free -h | awk '/Swap/ {print $3" / "$2}')
    DISK_INFO=$(df -h / | awk 'NR==2{print $3" / "$2}')
    BOOT_DISK=$(df -h / | awk 'NR==2{print $1}')
    UPTIME=$(uptime -p | cut -d " " -f2-)
    LOAD=$(uptime | awk -F'load average:' '{ print $2 }' | sed 's/^ //')
    OS=$(hostnamectl | grep "Operating System" | cut -d: -f2 | sed 's/^ //')
    ARCH=$(uname -m)
    KERNEL=$(uname -r)

    echo " CPU 型号          : $CPU_MODEL"
    echo " CPU 核心数        : $CPU_CORES"
    echo " CPU 频率          : ${CPU_FREQ} MHz"
    echo " CPU 缓存          : L1: $CACHE / L2: 0.00 KB / L3: 0.00 KB"
    echo " AES-NI指令集      : $AES"
    echo " VM-x/AMD-V支持    : $VMX"
    echo " 内存              : $MEM_INFO"
    echo " Swap              : $SWAP_INFO"
    echo " 硬盘空间          : $DISK_INFO"
    echo " 启动盘路径        : $BOOT_DISK"
    echo " 系统在线时间      : $UPTIME"
    echo " 负载              : $LOAD"
    echo " 系统              : $OS"
    echo " 架构              : $ARCH (64 Bit)"
    echo " 内核              : $KERNEL"
}

yabs_test() {
    curl -sL yabs.sh | bash
}

# ---------------- 主菜单 ----------------

while true; do
    echo -e "\n\e[1;36m========= Server Toolkit 菜单 =========\e[0m"
    echo "1. 每30分钟自动同步时间"
    echo "2. 关闭防火墙"
    echo "3. 关闭 SELinux"
    echo "4. SSH 安全性增强"
    echo "5. 安装 & 配置 Fail2Ban"
    echo "6. 修改 SSH 端口和密码"
    echo "7. 流媒体解锁检测"
    echo "8. 显示服务器基本信息"
    echo "9. 进行 yabs 测试"
    echo "0. 退出"
    echo -n "请选择一个操作 [0-9]: "

    read choice
    case $choice in
        1) sync_time;;
        2) close_firewall;;
        3) close_selinux;;
        4) secure_ssh_config;;
        5) install_fail2ban;;
        6) change_ssh_port_pass;;
        7) media_unlock_test;;
        8) show_system_info;;
        9) yabs_test;;
        0) echo "退出脚本。"; exit 0;;
        *) echo "无效选择，请重新输入。";;
    esac

done
