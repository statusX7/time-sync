#!/bin/bash

# 彩色输出函数
function colorEcho() {
    local color="$1"
    shift
    case $color in
        red) echo -e "\033[31m$@\033[0m";;
        green) echo -e "\033[32m$@\033[0m";;
        yellow) echo -e "\033[33m$@\033[0m";;
        blue) echo -e "\033[34m$@\033[0m";;
        magenta) echo -e "\033[35m$@\033[0m";;
        cyan) echo -e "\033[36m$@\033[0m";;
        *) echo "$@";;
    esac
}

# 功能7：显示服务器基本信息
function show_sys_info() {
    colorEcho cyan "---------------------服务器基本信息如下---------------------"

    cpu_model=$(awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo | sed 's/^ *//')
    cpu_cores=$(nproc)
    cpu_freq=$(awk -F: '/cpu MHz/ {print $2}' /proc/cpuinfo | awk '{sum+=$1} END {printf "%.3f", sum/NR}')
    cpu_cache_l1=$(lscpu | grep "L1d cache" | awk '{print $3}')
    cpu_cache_l2=$(lscpu | grep "L2 cache" | awk '{print $3}')
    cpu_cache_l3=$(lscpu | grep "L3 cache" | awk '{print $3}')
    aes_support=$(lscpu | grep -o aes &>/dev/null && echo "✔ Enabled" || echo "✘ Disabled")
    vmx_support=$(egrep -o 'vmx|svm' /proc/cpuinfo &>/dev/null && echo "✔ Enabled" || echo "✘ Disabled")

    mem_info=$(free -m)
    mem_total=$(echo "$mem_info" | awk '/Mem:/ {printf "%.2f", $2/1024}')
    mem_used=$(echo "$mem_info" | awk '/Mem:/ {printf "%.2f", ($2-$7)/1024}')
    swap_total=$(echo "$mem_info" | awk '/Swap:/ {printf "%.2f", $2/1024}')
    swap_used=$(echo "$mem_info" | awk '/Swap:/ {printf "%.2f", ($2-$3)/1024}')

    disk_info=$(df -h / | awk 'NR==2 {print $3" / "$2}')
    boot_disk=$(df -h / | awk 'NR==2 {print $1}')

    uptime_days=$(awk '{print int($1/86400)}' /proc/uptime)
    uptime_hours=$(awk '{print int(($1%86400)/3600)}' /proc/uptime)
    uptime_mins=$(awk '{print int(($1%3600)/60)}' /proc/uptime)

    load_avg=$(uptime | awk -F'load average:' '{print $2}' | sed 's/^ *//')
    os_info=$(awk -F= '/PRETTY_NAME/{print $2}' /etc/os-release | tr -d '"')
    arch_info=$(uname -m)
    kernel_info=$(uname -r)

    colorEcho green " CPU 型号          : $cpu_model"
    colorEcho green " CPU 核心数        : $cpu_cores"
    colorEcho green " CPU 频率          : ${cpu_freq} MHz"
    colorEcho green " CPU 缓存          : L1: ${cpu_cache_l1:-0.00 KB} / L2: ${cpu_cache_l2:-0.00 KB} / L3: ${cpu_cache_l3:-0.00 KB}"
    colorEcho green " AES-NI指令集      : $aes_support"
    colorEcho green " VM-x/AMD-V支持    : $vmx_support"
    colorEcho green " 内存              : ${mem_used} GiB / ${mem_total} GiB"
    colorEcho green " Swap              : ${swap_used} GiB / ${swap_total} GiB"
    colorEcho green " 硬盘空间          : $disk_info"
    colorEcho green " 启动盘路径        : $boot_disk"
    colorEcho green " 系统在线时间      : ${uptime_days} days, ${uptime_hours} hour ${uptime_mins} min"
    colorEcho green " 负载              : $load_avg"
    colorEcho green " 系统              : $os_info"
    colorEcho green " 架构              : $arch_info (64 Bit)"
    colorEcho green " 内核              : $kernel_info"
}

# 其余功能函数略（保留原 server-toolkit.sh 脚本的所有功能）

# 脚本主菜单（保持不变）
while true; do
    echo
    colorEcho yellow "========= 服务器管理工具 ========="
    echo "1）每30分钟自动同步时间"
    echo "2）关闭防火墙"
    echo "3）关闭SELinux"
    echo "4）SSH安全性增强"
    echo "5）安装并配置Fail2Ban"
    echo "6）修改SSH端口及密码"
    echo "7）流媒体解锁检测"
    echo "8）显示系统基本信息"
    echo "9）YABS性能测试"
    echo "0）退出"
    echo
    read -p "请选择操作: " choice

    case $choice in
        1) setup_time_sync;;
        2) disable_firewall;;
        3) disable_selinux;;
        4) secure_ssh_config;;
        5) install_fail2ban;;
        6) modify_ssh_port_and_password;;
        7) bash <(curl -L -s check.unlock.media);;
        8) show_sys_info;;
        9) bash <(curl -sL yabs.sh);;
        0) exit;;
        *) colorEcho red "无效选项，请重新选择。";;
    esac

done
