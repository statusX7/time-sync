#!/bin/bash

echo "🔧 正在停止哪吒探针相关服务..."

# 停止服务
systemctl stop nezha-agent
systemctl stop nezha-dashboard

# 禁用服务
systemctl disable nezha-agent
systemctl disable nezha-dashboard

# 删除 systemd 服务文件
rm -f /etc/systemd/system/nezha-agent.service
rm -f /etc/systemd/system/nezha-dashboard.service

# 删除程序文件
rm -rf /opt/nezha
rm -rf /etc/nezha

# 删除日志文件
rm -rf /var/log/nezha

# 重新加载 systemd
systemctl daemon-reload

echo "✅ 哪吒探针已完全移除"
