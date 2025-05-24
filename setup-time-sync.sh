#!/bin/bash

# 一键设置每 30 分钟同步一次系统时间（使用 ntpdate + cron）
# 兼容 CentOS 7 和 Debian/Ubuntu

set -e

echo "🔧 检测系统发行版..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "无法检测系统类型，退出。"
    exit 1
fi

echo "🔍 当前系统是: $OS"

# 安装 ntpdate
echo "📦 正在安装 ntpdate..."
if [[ "$OS" == "centos" ]]; then
    sudo yum install -y ntpdate
elif [[ "$OS" == "debian" || "$OS" == "ubuntu" ]]; then
    sudo apt update
    sudo apt install -y ntpdate
else
    echo "❌ 不支持的系统类型：$OS"
    exit 1
fi

# 获取 ntpdate 路径
NTPDATE_PATH=$(which ntpdate)
if [[ -z "$NTPDATE_PATH" ]]; then
    echo "❌ 未找到 ntpdate 命令，请确认安装成功。"
    exit 1
fi

echo "✅ ntpdate 路径为: $NTPDATE_PATH"

# 添加到 root 的 crontab
CRON_LINE="*/30 * * * * $NTPDATE_PATH time.google.com"

echo "🕒 正在添加 cron 任务（每 30 分钟同步时间）..."
( sudo crontab -l 2>/dev/null | grep -v "$NTPDATE_PATH" ; echo "$CRON_LINE" ) | sudo crontab -

echo "✅ cron 任务已添加："
echo "$CRON_LINE"

# 可选：立即同步一次时间
echo "⏱ 正在立即同步一次系统时间..."
sudo $NTPDATE_PATH time.google.com

echo "🎉 设置完成！系统将每 30 分钟自动同步时间。"
