#!/bin/bash

SSHD_CONFIG="/etc/ssh/sshd_config"

echo "========== 开始 SSH 安全性强化 =========="

# 备份原配置
if [ ! -f "${SSHD_CONFIG}.bak" ]; then
    cp -a "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"
    echo "[+] 备份 sshd_config 到 sshd_config.bak"
else
    echo "[*] 备份文件已存在，跳过备份"
fi

# 修改配置
sed -i 's/^#\?Protocol.*/Protocol 2/' "$SSHD_CONFIG"
sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$SSHD_CONFIG"
sed -i 's/^#\?UseDNS.*/UseDNS no/' "$SSHD_CONFIG"
sed -i 's/^#\?LoginGraceTime.*/LoginGraceTime 30/' "$SSHD_CONFIG"
sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' "$SSHD_CONFIG"
sed -i 's/^#\?MaxSessions.*/MaxSessions 2/' "$SSHD_CONFIG"
sed -i 's/^#\?MaxStartups.*/MaxStartups 3:50:10/' "$SSHD_CONFIG"
sed -i 's/^#\?ClientAliveInterval.*/ClientAliveInterval 300/' "$SSHD_CONFIG"
sed -i 's/^#\?ClientAliveCountMax.*/ClientAliveCountMax 2/' "$SSHD_CONFIG"
sed -i 's/^#\?LogLevel.*/LogLevel VERBOSE/' "$SSHD_CONFIG"
sed -i 's/^#\?UsePAM.*/UsePAM yes/' "$SSHD_CONFIG"

# 追加缺失配置（避免被注释或者不存在）
grep -q "^Protocol 2" "$SSHD_CONFIG" || echo "Protocol 2" >> "$SSHD_CONFIG"
grep -q "^PermitEmptyPasswords no" "$SSHD_CONFIG" || echo "PermitEmptyPasswords no" >> "$SSHD_CONFIG"
grep -q "^UseDNS no" "$SSHD_CONFIG" || echo "UseDNS no" >> "$SSHD_CONFIG"
grep -q "^LoginGraceTime 30" "$SSHD_CONFIG" || echo "LoginGraceTime 30" >> "$SSHD_CONFIG"
grep -q "^MaxAuthTries 3" "$SSHD_CONFIG" || echo "MaxAuthTries 3" >> "$SSHD_CONFIG"
grep -q "^MaxSessions 2" "$SSHD_CONFIG" || echo "MaxSessions 2" >> "$SSHD_CONFIG"
grep -q "^MaxStartups 3:50:10" "$SSHD_CONFIG" || echo "MaxStartups 3:50:10" >> "$SSHD_CONFIG"
grep -q "^ClientAliveInterval 300" "$SSHD_CONFIG" || echo "ClientAliveInterval 300" >> "$SSHD_CONFIG"
grep -q "^ClientAliveCountMax 2" "$SSHD_CONFIG" || echo "ClientAliveCountMax 2" >> "$SSHD_CONFIG"
grep -q "^LogLevel VERBOSE" "$SSHD_CONFIG" || echo "LogLevel VERBOSE" >> "$SSHD_CONFIG"
grep -q "^UsePAM yes" "$SSHD_CONFIG" || echo "UsePAM yes" >> "$SSHD_CONFIG"

echo "[+] 重启 SSH 服务..."
systemctl restart sshd

echo "========== SSH 安全强化完成 =========="


echo "========== 开始安装和配置 fail2ban =========="

# 检测系统类型
if [ -f /etc/redhat-release ]; then
    OS="centos"
    echo "[+] 系统检测为 CentOS"
    yum install -y epel-release
    yum install -y fail2ban
elif [ -f /etc/debian_version ]; then
    OS="debian"
    echo "[+] 系统检测为 Debian/Ubuntu"
    apt update
    apt install -y fail2ban
else
    echo "[-] 不支持的系统，脚本退出"
    exit 1
fi

echo "[+] 启动并设置开机自启 fail2ban"
systemctl enable fail2ban
systemctl start fail2ban

echo "[+] 写入 fail2ban SSH 监控配置"

cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/secure
bantime = 600
findtime = 600
maxretry = 3
EOF

# Debian 日志路径修正
if [ "$OS" = "debian" ]; then
    sed -i 's|/var/log/secure|/var/log/auth.log|' /etc/fail2ban/jail.local
fi

echo "[+] 重启 fail2ban 使配置生效"
systemctl restart fail2ban

echo "========== fail2ban 安装和配置完成 =========="

echo ""
echo "[✔] 全部完成！"
echo "👉 请不要关闭当前 SSH 连接，建议另开一个终端测试 SSH 是否能正常登录。"
echo "👉 fail2ban 配置为：输错密码3次封禁10分钟，不影响 VPN 使用。"
