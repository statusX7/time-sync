#!/usr/bin/env bash
set -u

SERVER_TOOLKIT_VERSION="v2.3"
UI_LINE="────────────────────────────────────────────────────────────"
OS_ID="unknown"
OS_ID_LIKE=""
OS_VERSION_ID=""
OS_VERSION_CODENAME=""
OS_PRETTY_NAME="unknown"
OS_MAJOR=""
PKG_MANAGER=""

# ============================================================
# server-toolkit.sh v2.3
# 生成说明：基于 v2.2 fixed 审查后去重输出，只保留每个函数的最终定义。
# 高风险路径均保持“先备份、先检测、默认取消危险操作、尽量不破坏当前 SSH 会话”。
# ============================================================
allow_port_firewall () 
{ 
    local port="$1";
    [[ "$port" =~ ^[0-9]+$ ]] || return 1;
    echo_info "尝试放行 TCP 端口：$port";
    if firewalld_active; then
        firewall-cmd --permanent --add-port="${port}/tcp" || return 1;
        firewall-cmd --reload || return 1;
        echo_color "firewalld 已放行 ${port}/tcp。";
    else
        if command -v ufw > /dev/null 2>&1; then
            ufw allow "${port}/tcp" || return 1;
            echo_color "ufw 已放行 ${port}/tcp。";
        else
            if command -v nft > /dev/null 2>&1; then
                echo_warn "检测到 nftables，但不同系统规则集差异很大，未自动写入永久规则。请手动确认安全组/防火墙。";
            else
                if command -v iptables > /dev/null 2>&1; then
                    if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT > /dev/null 2>&1; then
                        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || return 1;
                        echo_warn "iptables 已添加运行时规则放行 ${port}/tcp，但未保证重启后持久化。";
                    fi;
                else
                    echo_warn "未检测到 firewalld/ufw/nftables/iptables，本机防火墙未处理。";
                fi;
            fi;
        fi;
    fi;
    echo_warn "云厂商安全组不受本脚本控制，请确认云面板也已放行端口 $port。"
}

allow_ssh_ports_before_firewall_enable () 
{ 
    local ports p;
    ports="$(get_current_ssh_ports)";
    [ -z "$ports" ] && ports="22";
    for p in ${ports//,/ };
    do
        allow_port_firewall "$p" || true;
    done
}

apply_conservative_sysctl_hardening () 
{ 
    local conf="/etc/sysctl.d/98-server-toolkit-hardening.conf" tmp;
    backup_file "$conf";
    tmp="$(mktemp /tmp/server-toolkit-sysctl.XXXXXX)" || return 1;
    echo "# server-toolkit v2.3: conservative hardening" > "$tmp";
    apply_sysctl_if_exists net.ipv4.tcp_syncookies 1 "$tmp";
    apply_sysctl_if_exists net.ipv4.conf.all.accept_redirects 0 "$tmp";
    apply_sysctl_if_exists net.ipv4.conf.default.accept_redirects 0 "$tmp";
    apply_sysctl_if_exists net.ipv4.conf.all.secure_redirects 0 "$tmp";
    apply_sysctl_if_exists net.ipv4.conf.default.secure_redirects 0 "$tmp";
    apply_sysctl_if_exists net.ipv4.conf.all.send_redirects 0 "$tmp";
    apply_sysctl_if_exists net.ipv4.conf.default.send_redirects 0 "$tmp";
    apply_sysctl_if_exists net.ipv4.conf.all.accept_source_route 0 "$tmp";
    apply_sysctl_if_exists net.ipv4.conf.default.accept_source_route 0 "$tmp";
    apply_sysctl_if_exists net.ipv4.icmp_echo_ignore_broadcasts 1 "$tmp";
    apply_sysctl_if_exists net.ipv4.icmp_ignore_bogus_error_responses 1 "$tmp";
    apply_sysctl_if_exists kernel.kptr_restrict 1 "$tmp";
    apply_sysctl_if_exists kernel.dmesg_restrict 1 "$tmp";
    apply_sysctl_if_exists fs.protected_hardlinks 1 "$tmp";
    apply_sysctl_if_exists fs.protected_symlinks 1 "$tmp";
    mv "$tmp" "$conf";
    sysctl --system > /dev/null 2>&1 || sysctl -p "$conf" || true;
    echo_color "保守 sysctl 加固已应用。"
}

apply_copy_fail_mitigation () 
{ 
    ui_title "CVE-2026-31431 / Copy Fail 临时缓解";
    echo_warn "正式修复应升级内核并重启。临时缓解会禁止加载 algif_aead；同时禁用 authencesn 作为纵深防护。";
    echo_warn "可能影响 AF_ALG AEAD、IPsec 或依赖内核 AEAD 加密接口的工作负载。";
    uname -a || true;
    lsmod 2> /dev/null | grep -E '^(algif_aead|authencesn)' || echo_info "当前未看到 algif_aead/authencesn 模块已加载。";
    confirm_yes "确认写入 Copy Fail 临时缓解规则？" || return 0;
    local conf;
    conf="$(copy_fail_conf_path)";
    mkdir -p /etc/modprobe.d;
    backup_file "$conf";
    cat > "$conf" <<'EOF2'
# server-toolkit v2.3: CVE-2026-31431 / Copy Fail temporary mitigation
# Primary vendor mitigation: block algif_aead. authencesn is blocked as defense-in-depth.
# Remove this file after patched kernel is installed and rebooted if the workload needs these modules.
install algif_aead /bin/false
blacklist algif_aead
install authencesn /bin/false
blacklist authencesn
EOF2

    modprobe -r algif_aead 2> /dev/null || true;
    modprobe -r authencesn 2> /dev/null || true;
    echo_color "已写入临时缓解：$conf";
    if [ -d /sys/module/algif_aead ] || [ -d /sys/module/authencesn ]; then
        echo_warn "仍检测到相关模块目录，可能是内建模块或正在被使用；请升级内核并重启后确认。";
    fi;
    echo_warn "请尽快升级内核并重启，这才是正式修复。"
}

apply_regresshion_mitigation () 
{ 
    ui_title "CVE-2024-6387 / regreSSHion 临时缓解";
    echo_warn "正式修复应升级 OpenSSH 包；临时缓解只调整 sshd 登录窗口与并发。";
    confirm_yes "确认应用临时缓解 LoginGraceTime=0 MaxStartups=10:30:60？" || return 0;
    local backup_dir;
    backup_dir="$(make_backup_dir ssh-regresshion)";
    backup_ssh_tree "$backup_dir";
    set_sshd_kv_effective LoginGraceTime 0;
    set_sshd_kv_effective MaxStartups "10:30:60";
    ssh_apply_with_rollback "regreSSHion 临时缓解" "$backup_dir"
}

apply_sysctl_if_exists () 
{ 
    local key="$1" val="$2" file="$3";
    if sysctl_key_exists "$key"; then
        echo "$key=$val" >> "$file";
    else
        echo_dim "跳过不存在的 sysctl：$key";
    fi
}

apt_add_deb_line_if_exists () 
{ 
    local file="$1" base="$2" suite="$3" components="$4";
    if ! apt_probe_tool_exists; then
        printf 'deb %s %s %s\n' "$base" "$suite" "$components" >> "$file";
        return 0;
    fi;
    if curl_has_release "$base" "$suite"; then
        printf 'deb %s %s %s\n' "$base" "$suite" "$components" >> "$file";
        return 0;
    fi;
    return 1
}

apt_apply_candidate () 
{ 
    local os="$1" code="$2" key="$3" label="$4" base="$5" secbase="$6" archive_mode="$7";
    echo_info "准备写入 APT 源：$label";
    echo_info "Base: $base";
    if [ "$os" = "ubuntu" ]; then
        write_ubuntu_sources "$base" "$secbase" "$code" "$label" "$archive_mode" || return 1;
    else
        write_debian_sources "$base" "$secbase" "$code" "$label" "$archive_mode" || return 1;
    fi;
    apt_env_export;
    apt-get clean > /dev/null 2>&1 || true;
    if apt-get update -y; then
        echo_color "APT 源已修复/切换成功：$label";
        return 0;
    fi;
    echo_error "apt-get update 失败：$label";
    echo_warn "已保留 /etc/apt/sources.list 的备份，可根据 .bak 时间戳回滚。";
    return 1
}

apt_apply_source_profile () 
{ 
    local profile="$1" backup codename mirror security components archive_mode="no";
    parse_os_release;
    codename="$(apt_codename_guess)";
    backup="$(apt_backup_sources_dir)";
    apt_disable_official_sources_only "$backup";
    case "$OS_ID:$profile" in 
        ubuntu:official)
            mirror="http://archive.ubuntu.com";
            security="http://security.ubuntu.com"
        ;;
        ubuntu:google)
            mirror="https://mirrors.cloud.google.com";
            security="https://mirrors.cloud.google.com"
        ;;
        ubuntu:cloudflare)
            mirror="https://mirrors.cloudflare.com";
            security="https://mirrors.cloudflare.com"
        ;;
        ubuntu:yandex)
            mirror="https://mirror.yandex.ru";
            security="https://mirror.yandex.ru"
        ;;
        ubuntu:archive)
            mirror="http://old-releases.ubuntu.com";
            security="";
            archive_mode="yes"
        ;;
        debian:official)
            if [ "$OS_MAJOR" = "10" ]; then
                echo_warn "Debian 10 已进入归档场景，自动使用 archive.debian.org。";
                mirror="http://archive.debian.org";
                security="";
                archive_mode="yes";
            else
                mirror="http://deb.debian.org";
                security="http://security.debian.org";
            fi
        ;;
        debian:google)
            mirror="https://mirrors.cloud.google.com";
            security="https://mirrors.cloud.google.com"
        ;;
        debian:cloudflare)
            mirror="https://mirrors.cloudflare.com";
            security="https://mirrors.cloudflare.com"
        ;;
        debian:yandex)
            mirror="https://mirror.yandex.ru";
            security="https://mirror.yandex.ru"
        ;;
        debian:archive)
            mirror="http://archive.debian.org";
            security="";
            archive_mode="yes"
        ;;
        *)
            echo_error "APT 源 profile 不适用于当前系统：$OS_ID $profile";
            apt_restore_sources_dir "$backup" || true;
            return 1
        ;;
    esac;
    if [ "$archive_mode" != "yes" ]; then
        if ! apt_probe_release_url "$mirror" "${OS_ID}" "$codename" && ! apt_probe_release_url "$mirror" "ubuntu" "$codename" && ! apt_probe_release_url "$mirror" "debian" "$codename"; then
            echo_warn "候选源 $profile 未通过 Release 探测，仍会在 apt-get update 阶段验证并失败回滚。";
        fi;
    fi;
    if [ "$OS_ID" = "ubuntu" ]; then
        apt_write_ubuntu_deb822 "$codename" "$mirror" "$security" "$archive_mode";
    else
        components="$(apt_components_debian "$codename")";
        apt_write_debian_deb822 "$codename" "$mirror" "$security" "$components" "$archive_mode";
    fi;
    echo_info "正在执行 apt-get update 验证新源...";
    if apt_update_with_log; then
        echo_color "APT 源修复成功。备份目录：$backup";
        return 0;
    fi;
    echo_error "apt-get update 失败，开始回滚。";
    apt_restore_sources_dir "$backup";
    apt_update_with_log || true;
    return 1
}

apt_backup_sources_dir () 
{ 
    local dir;
    dir="$(make_backup_dir apt-sources)";
    backup_path_to_dir /etc/apt/sources.list "$dir";
    [ -d /etc/apt/sources.list.d ] && backup_path_to_dir /etc/apt/sources.list.d "$dir";
    [ -d /etc/apt/apt.conf.d ] && backup_path_to_dir /etc/apt/apt.conf.d "$dir";
    echo "$dir"
}

apt_check_sources () 
{ 
    ui_title "APT 源检测";
    show_os_detected;
    echo_info "当前源文件：";
    ls -la /etc/apt/sources.list /etc/apt/sources.list.d 2> /dev/null || true;
    echo;
    grep -RInE '^[[:space:]]*(deb|Types:|URIs:|Suites:|Components:)' /etc/apt/sources.list /etc/apt/sources.list.d 2> /dev/null || true;
    echo;
    apt_update_with_log
}

apt_codename_guess () 
{ 
    parse_os_release;
    if [ -n "$OS_VERSION_CODENAME" ]; then
        echo "$OS_VERSION_CODENAME";
        return;
    fi;
    case "$OS_ID:$OS_VERSION_ID" in 
        debian:10*)
            echo buster
        ;;
        debian:11*)
            echo bullseye
        ;;
        debian:12*)
            echo bookworm
        ;;
        debian:13*)
            echo trixie
        ;;
        ubuntu:20.04*)
            echo focal
        ;;
        ubuntu:22.04*)
            echo jammy
        ;;
        ubuntu:24.04*)
            echo noble
        ;;
        ubuntu:26.04*)
            echo resolute
        ;;
        *)
            echo "stable"
        ;;
    esac
}

apt_common_opts () 
{ 
    printf '%s\n' '-o' 'Dpkg::Options::=--force-confdef' '-o' 'Dpkg::Options::=--force-confold'
}

apt_components_debian () 
{ 
    local codename="$1";
    case "$codename" in 
        bookworm | trixie | forky | testing | sid | stable | oldstable)
            echo "main contrib non-free non-free-firmware"
        ;;
        *)
            echo "main contrib non-free"
        ;;
    esac
}

apt_detect_debian_security_ref () 
{ 
    local base="$1" preferred_secbase="$2" code="$3" item b s;
    if ! apt_probe_tool_exists; then
        printf '%s|%s\n' "${preferred_secbase:-$base}" "${code}-security";
        return 0;
    fi;
    for item in "${preferred_secbase}|${code}-security" "https://security.debian.org/debian-security/|${code}-security" "http://security.debian.org/debian-security/|${code}-security" "https://deb.debian.org/debian-security/|${code}-security" "http://deb.debian.org/debian-security/|${code}-security" "https://archive.debian.org/debian-security/|${code}/updates" "http://archive.debian.org/debian-security/|${code}/updates" "https://archive.debian.org/debian-security/|${code}-security" "http://archive.debian.org/debian-security/|${code}-security" "${base}|${code}-security";
    do
        b="${item%%|*}";
        s="${item#*|}";
        [ -n "$b" ] || continue;
        if curl_has_release "$b" "$s"; then
            printf '%s|%s\n' "$b" "$s";
            return 0;
        fi;
    done;
    printf '|\n'
}

apt_detect_ubuntu_security_base () 
{ 
    local base="$1" preferred_secbase="$2" code="$3";
    if ! apt_probe_tool_exists; then
        echo "${preferred_secbase:-$base}";
    else
        if [ -n "$preferred_secbase" ] && curl_has_release "$preferred_secbase" "${code}-security"; then
            echo "$preferred_secbase";
        else
            if curl_has_release "$base" "${code}-security"; then
                echo "$base";
            else
                echo "";
            fi;
        fi;
    fi
}

apt_disable_conflicting_distro_sources () 
{ 
    local tag f;
    tag="$(date +%F_%H-%M-%S)";
    mkdir -p /etc/apt/sources.list.d;
    for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list;
    do
        [ -f "$f" ] || continue;
        case "$f" in 
            *.server-toolkit-disabled.* | *.bak.*)
                continue
            ;;
        esac;
        if grep -Eiq '(archive\.ubuntu\.com|security\.ubuntu\.com|old-releases\.ubuntu\.com|deb\.debian\.org|security\.debian\.org|archive\.debian\.org|mirror\.google\.com|mirror\.yandex\.ru|cloudflaremirrors\.com)' "$f"; then
            cp -a "$f" "${f}.bak.${tag}" 2> /dev/null || true;
            mv "$f" "${f}.server-toolkit-disabled.${tag}" 2> /dev/null || true;
            echo_warn "已暂时停用可能冲突的发行版源文件：$f";
        fi;
    done
}

apt_disable_official_sources_only () 
{ 
    local backup="$1" f base;
    mkdir -p /etc/apt/sources.list.d;
    if [ -f /etc/apt/sources.list ]; then
        backup_file /etc/apt/sources.list;
        awk '
      /^[[:space:]]*deb(-src)?[[:space:]]/ && $0 ~ /(debian\.org|ubuntu\.com|old-releases\.ubuntu\.com|archive\.debian\.org|mirror\.yandex\.ru|mirrors\.cloud\.google\.com|mirrors\.cloudflare\.com)/ {print "# server-toolkit disabled official: "$0; next}
      {print}
    ' /etc/apt/sources.list > /etc/apt/sources.list.tmp && mv /etc/apt/sources.list.tmp /etc/apt/sources.list;
    fi;
    shopt -s nullglob;
    for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list;
    do
        base="$(basename "$f")";
        case "$base" in 
            server-toolkit-* | 00-server-toolkit-*)
                continue
            ;;
        esac;
        if grep -Eiq '(debian\.org|ubuntu\.com|old-releases\.ubuntu\.com|archive\.debian\.org|mirror\.yandex\.ru|mirrors\.cloud\.google\.com|mirrors\.cloudflare\.com)' "$f"; then
            cp -a "$f" "$backup/$(echo "$f" | sed 's#/#_#g').saved" 2> /dev/null || true;
            mv "$f" "${f}.disabled-by-server-toolkit-$(date +%F_%H-%M-%S)";
            echo_warn "已暂时停用官方同类源：$f；第三方源不会主动移动。恢复方式：查看 $backup 或去掉 .disabled-by-server-toolkit 后缀。";
        fi;
    done;
    shopt -u nullglob
}

apt_env_export () 
{ 
    export DEBIAN_FRONTEND=noninteractive;
    export NEEDRESTART_MODE=a;
    export APT_LISTCHANGES_FRONTEND=none;
    export UCF_FORCE_CONFFOLD=1
}

apt_probe_release_url () 
{ 
    local base="$1" path="$2" suite="$3";
    ensure_command curl curl > /dev/null 2>&1 || return 1;
    curl -fsI --connect-timeout 5 --max-time 10 "${base%/}/${path}/dists/${suite}/Release" > /dev/null 2>&1 || curl -fsL --connect-timeout 5 --max-time 10 "${base%/}/${path}/dists/${suite}/Release" -o /dev/null > /dev/null 2>&1
}

apt_probe_tool_exists () 
{ 
    command -v curl > /dev/null 2>&1 || command -v wget > /dev/null 2>&1
}

apt_repair_menu () 
{ 
    while true; do
        ui_title "APT 源检测与修复";
        echo_info "当前系统：$(apt_codename_guess) / $OS_PRETTY_NAME";
        ui_option 1 "只检测源可用性（apt-get update）";
        ui_option 2 "自动修复为官方源";
        ui_option 3 "尝试 Google 镜像源（探测失败会回滚）";
        ui_option 4 "尝试 Cloudflare 镜像源（探测失败会回滚）";
        ui_option 5 "尝试 Yandex 镜像源（探测失败会回滚）";
        ui_option 6 "旧发行版归档源 old-releases/archive";
        ui_back;
        local opt;
        ui_prompt opt;
        case "$opt" in 
            1)
                apt_check_sources;
                pause_return
            ;;
            2)
                apt_apply_source_profile official;
                pause_return
            ;;
            3)
                apt_apply_source_profile google;
                pause_return
            ;;
            4)
                apt_apply_source_profile cloudflare;
                pause_return
            ;;
            5)
                apt_apply_source_profile yandex;
                pause_return
            ;;
            6)
                apt_apply_source_profile archive;
                pause_return
            ;;
            0)
                return 0
            ;;
            *)
                echo_error "无效选项";
                pause_return
            ;;
        esac;
    done
}

apt_restore_sources_dir () 
{ 
    local dir="$1";
    [ -d "$dir/etc/apt" ] || return 1;
    rm -f /etc/apt/sources.list.d/00-server-toolkit-*.sources /etc/apt/sources.list.d/server-toolkit-*.sources 2> /dev/null || true;
    [ -f "$dir/etc/apt/sources.list" ] && cp -a "$dir/etc/apt/sources.list" /etc/apt/sources.list;
    if [ -d "$dir/etc/apt/sources.list.d" ]; then
        rm -rf /etc/apt/sources.list.d;
        cp -a "$dir/etc/apt/sources.list.d" /etc/apt/sources.list.d;
    fi;
    if [ -d "$dir/etc/apt/apt.conf.d" ]; then
        cp -a "$dir/etc/apt/apt.conf.d"/. /etc/apt/apt.conf.d/;
    fi;
    echo_warn "已回滚 APT 源到：$dir"
}

apt_set_archive_mode () 
{ 
    local mode="$1";
    local conf="/etc/apt/apt.conf.d/99-server-toolkit-archive";
    mkdir -p /etc/apt/apt.conf.d;
    if [ "$mode" = "archive" ]; then
        cat > "$conf" <<EOF
// server-toolkit v2.3: old archive sources often have expired Release metadata.
Acquire::Check-Valid-Until "false";
EOF

        echo_warn "已为归档源写入：$conf";
    else
        if [ -f "$conf" ]; then
            backup_file "$conf"
            rm -f "$conf";
            echo_info "已移除旧归档源 Valid-Until 放宽配置。";
        fi;
    fi
}

apt_signed_by_line () 
{ 
    local keyring="$1";
    if [ -r "$keyring" ]; then
        echo "Signed-By: $keyring";
    else
        echo_warn "未找到 keyring：$keyring；deb822 将不写 Signed-By，依赖系统默认 trusted keyrings。";
    fi
}

apt_source_candidates () 
{ 
    local os="$1";
    if [ "$os" = "ubuntu" ]; then
        cat <<'EOF'
official|官方源 archive.ubuntu.com + security.ubuntu.com|https://archive.ubuntu.com/ubuntu/|https://security.ubuntu.com/ubuntu/|normal
official-http|官方源 HTTP archive.ubuntu.com|http://archive.ubuntu.com/ubuntu/|http://security.ubuntu.com/ubuntu/|normal
google|Google 镜像 mirror.google.com|https://mirror.google.com/linux/ubuntu/|https://mirror.google.com/linux/ubuntu/|normal
cloudflare|Cloudflare Mirrors（检测可用才会写入）|https://cloudflaremirrors.com/ubuntu/|https://cloudflaremirrors.com/ubuntu/|normal
yandex|Yandex 镜像 mirror.yandex.ru|https://mirror.yandex.ru/ubuntu/|https://mirror.yandex.ru/ubuntu/|normal
yandex-http|Yandex 镜像 HTTP mirror.yandex.ru|http://mirror.yandex.ru/ubuntu/|http://mirror.yandex.ru/ubuntu/|normal
old-releases|Ubuntu old-releases 旧发行版兜底|https://old-releases.ubuntu.com/ubuntu/|https://old-releases.ubuntu.com/ubuntu/|archive
old-releases-http|Ubuntu old-releases HTTP 旧发行版兜底|http://old-releases.ubuntu.com/ubuntu/|http://old-releases.ubuntu.com/ubuntu/|archive
EOF

    else
        cat <<'EOF'
official|官方源 deb.debian.org + security.debian.org|https://deb.debian.org/debian/|https://security.debian.org/debian-security/|normal
official-http|官方源 HTTP deb.debian.org|http://deb.debian.org/debian/|http://security.debian.org/debian-security/|normal
google|Google 镜像 mirror.google.com/debian|https://mirror.google.com/debian/|https://security.debian.org/debian-security/|normal
cloudflare|Cloudflare Mirrors cloudflaremirrors.com/debian|https://cloudflaremirrors.com/debian/|https://security.debian.org/debian-security/|normal
yandex|Yandex 镜像 mirror.yandex.ru/debian|https://mirror.yandex.ru/debian/|https://mirror.yandex.ru/debian-security/|normal
yandex-http|Yandex 镜像 HTTP mirror.yandex.ru/debian|http://mirror.yandex.ru/debian/|http://mirror.yandex.ru/debian-security/|normal
archive|Debian archive.debian.org 旧发行版兜底|https://archive.debian.org/debian/|https://archive.debian.org/debian-security/|archive
archive-http|Debian archive HTTP 旧发行版兜底|http://archive.debian.org/debian/|http://archive.debian.org/debian-security/|archive
EOF

    fi
}

apt_source_interactive_chooser () 
{ 
    if ! is_debian_like; then
        echo_warn "当前不是 Debian/Ubuntu 系，跳过 APT 源选择。";
        return 0;
    fi;
    local os code tmp idx key label base secbase archive_mode opt line;
    os="$(get_os_id)";
    code="$(get_os_codename)";
    [ -z "$code" ] && { 
        echo_error "无法识别系统代号，无法选择 APT 源。";
        return 1
    };
    [ "$os" = "ubuntu" ] || os="debian";
    tmp="$(mktemp /tmp/server-toolkit-apt-candidates.XXXXXX)" || { 
        echo_error "创建临时文件失败。";
        return 1
    };
    idx=1;
    ui_title "APT 源池检测 / 切换";
    echo_info "系统识别：$os / $code";
    echo_warn "说明：这里是切换一个可用镜像源，不会同时叠加多个同类发行版源，避免 APT 重复源警告。";
    while IFS='|' read -r key label base secbase archive_mode; do
        [ -n "$key" ] || continue;
        if apt_probe_tool_exists; then
            if curl_has_release "$base" "$code"; then
                printf '%s|%s|%s|%s|%s|%s\n' "$idx" "$key" "$label" "$base" "$secbase" "$archive_mode" >> "$tmp";
                ui_option "$idx" "$label";
                idx=$((idx + 1));
            else
                echo_dim "  --   不可用/不含当前发行版：$label";
            fi;
        else
            printf '%s|%s|%s|%s|%s|%s\n' "$idx" "$key" "$label" "$base" "$secbase" "$archive_mode" >> "$tmp";
            ui_option "$idx" "$label（未预检，直接尝试）";
            idx=$((idx + 1));
        fi;
    done <<EOF
$(apt_source_candidates "$os")
EOF

    if [ "$idx" -eq 1 ]; then
        rm -f "$tmp";
        echo_error "未检测到可用候选源。";
        return 1;
    fi;
    ui_back;
    read -r -p "请选择要写入的源: " opt;
    if [ "$opt" = "0" ]; then
        rm -f "$tmp";
        echo_warn "已取消。";
        return 0;
    fi;
    if ! [[ "$opt" =~ ^[0-9]+$ ]]; then
        rm -f "$tmp";
        echo_error "输入无效。";
        return 1;
    fi;
    line="$(awk -F'|' -v n="$opt" '$1==n{print; exit}' "$tmp")";
    rm -f "$tmp";
    [ -n "$line" ] || { 
        echo_error "选项不存在。";
        return 1
    };
    IFS='|' read -r _ key label base secbase archive_mode <<EOF
$line
EOF

    apt_apply_candidate "$os" "$code" "$key" "$label" "$base" "$secbase" "$archive_mode"
}

apt_try_auto_repair_sources () 
{ 
    local os="$1" code="$2" key label base secbase archive_mode;
    local tried=0;
    echo_info "开始按候选源自动检测并尝试修复。";
    while IFS='|' read -r key label base secbase archive_mode; do
        [ -n "$key" ] || continue;
        tried=$((tried + 1));
        if apt_probe_tool_exists; then
            if curl_has_release "$base" "$code"; then
                echo_color "检测可用：$label";
            else
                echo_dim "跳过不可用或不包含当前发行版的源：$label";
                continue;
            fi;
        else
            echo_warn "未检测到 curl/wget，无法预检源有效性，将直接尝试：$label";
        fi;
        if apt_apply_candidate "$os" "$code" "$key" "$label" "$base" "$secbase" "$archive_mode"; then
            return 0;
        fi;
    done <<EOF
$(apt_source_candidates "$os")
EOF

    [ "$tried" -gt 0 ] || echo_error "未生成任何 APT 候选源。";
    return 1
}

apt_update_with_log () 
{ 
    local log;
    log="$(mktemp /tmp/server-toolkit-apt-update.XXXXXX.log)" || return 1;
    echo_info "APT 更新日志：$log";
    if DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold update > "$log" 2>&1; then
        echo_color "apt-get update 验证通过。日志：$log";
        return 0;
    fi;
    echo_error "apt-get update 失败，日志保存在：$log";
    tail -n 60 "$log" 2> /dev/null || true;
    return 1
}

apt_write_debian_deb822 () 
{ 
    local codename="$1" mirror="$2" security="$3" components="$4" old_archive="${5:-no}" file suites sec_suite signed;
    file="/etc/apt/sources.list.d/00-server-toolkit-debian.sources";
    mkdir -p /etc/apt/sources.list.d;
    signed="$(apt_signed_by_line /usr/share/keyrings/debian-archive-keyring.gpg)";
    if [ "$codename" = "sid" ]; then
        suites="sid";
        security="";
    else
        suites="$codename $codename-updates $codename-backports";
    fi;
    cat > "$file" <<EOF2
# server-toolkit v2.3 Debian deb822 sources
Types: deb
URIs: ${mirror%/}/debian
Suites: $suites
Components: $components
$signed
EOF2

    if [ -n "$security" ] && [ "$old_archive" != "yes" ]; then
        if [ "$codename" = "buster" ]; then
            sec_suite="buster/updates";
        else
            sec_suite="${codename}-security";
        fi;
        cat >> "$file" <<EOF2

Types: deb
URIs: ${security%/}/debian-security
Suites: ${sec_suite}
Components: $components
$signed
EOF2

    fi
    if [ "$old_archive" = "yes" ]; then
        cat > /etc/apt/apt.conf.d/99-server-toolkit-archive <<'EOF2'
Acquire::Check-Valid-Until "false";
EOF2

    else
        rm -f /etc/apt/apt.conf.d/99-server-toolkit-archive 2> /dev/null || true;
    fi
}

apt_write_header () 
{ 
    local file="$1" os="$2" label="$3" base="$4";
    cat > "$file" <<EOF
# server-toolkit v2.3 generated $os sources
# source: $label
# base: $base
# generated_at: $(date '+%F %T %Z')
EOF

}

apt_write_ubuntu_deb822 () 
{ 
    local codename="$1" mirror="$2" security="$3" file old_archive="${4:-no}" signed;
    file="/etc/apt/sources.list.d/00-server-toolkit-ubuntu.sources";
    mkdir -p /etc/apt/sources.list.d;
    signed="$(apt_signed_by_line /usr/share/keyrings/ubuntu-archive-keyring.gpg)";
    cat > "$file" <<EOF2
# server-toolkit v2.3 Ubuntu deb822 sources
Types: deb
URIs: ${mirror%/}/ubuntu
Suites: $codename ${codename}-updates ${codename}-backports
Components: main restricted universe multiverse
$signed
EOF2

    if [ "$old_archive" != "yes" ] && [ -n "$security" ]; then
        cat >> "$file" <<EOF2

Types: deb
URIs: ${security%/}/ubuntu
Suites: ${codename}-security
Components: main restricted universe multiverse
$signed
EOF2

    fi
    if [ "$old_archive" = "yes" ]; then
        cat > /etc/apt/apt.conf.d/99-server-toolkit-archive <<'EOF2'
Acquire::Check-Valid-Until "false";
EOF2

    else
        rm -f /etc/apt/apt.conf.d/99-server-toolkit-archive 2> /dev/null || true;
    fi
}

backup_file () 
{ 
    local file="$1";
    if [ -f "$file" ]; then
        cp -a "$file" "${file}.bak.$(date +%F_%H-%M-%S)";
    fi
}

backup_path_to_dir () 
{ 
    local src="$1" dir="$2" dest;
    [ -e "$src" ] || return 0;
    dest="$dir$src";
    mkdir -p "$(dirname "$dest")";
    cp -a "$src" "$dest"
}

backup_ssh_tree () 
{ 
    local dir="$1";
    backup_path_to_dir /etc/ssh/sshd_config "$dir";
    [ -d /etc/ssh/sshd_config.d ] && backup_path_to_dir /etc/ssh/sshd_config.d "$dir"
}

change_root_password_only () 
{ 
    local new_password status prl pa;
    if command -v passwd > /dev/null 2>&1; then
        status="$(passwd -S root 2> /dev/null || true)";
        [ -n "$status" ] && echo_info "root 密码状态：$status";
    fi;
    read -r -s -p "请输入 root 新密码（直接回车取消）: " new_password;
    echo;
    [ -z "$new_password" ] && { 
        echo_warn "已取消。";
        return 0
    };
    echo "root:${new_password}" | chpasswd || { 
        echo_error "修改密码失败。";
        return 1
    };
    echo_color "root 密码已更新。";
    prl="$(sshd_effective_config | awk '$1=="permitrootlogin"{print $2; exit}')";
    pa="$(sshd_effective_config | awk '$1=="passwordauthentication"{print $2; exit}')";
    if [ "$pa" != "yes" ] || { 
        [ "$prl" != "yes" ] && [ "$prl" != "prohibit-password" ]
    }; then
        echo_warn "注意：密码已修改，但当前 SSH 可能不允许 root 密码登录。PermitRootLogin=${prl:-未知} PasswordAuthentication=${pa:-未知}";
    fi
}

change_ssh_port_and_password_together () 
{ 
    local new_port new_password old_ports keep_ports final_ports ans prl pa;
    read -r -p "请输入新的 SSH 端口 (1-65535，输入 q 取消): " new_port;
    [[ "$new_port" =~ ^[Qq]$ ]] && { 
        echo_warn "已取消。";
        return 0
    };
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo_error "端口不合法。";
        return 1;
    fi;
    old_ports="$(get_current_ssh_ports)";
    if port_in_use "$new_port" && ! echo ",$old_ports," | grep -q ",$new_port,"; then
        echo_error "端口 $new_port 已被其他进程监听，请换一个。";
        return 1;
    fi;
    read -r -s -p "请输入 root 新密码（直接回车取消）: " new_password;
    echo;
    [ -z "$new_password" ] && { 
        echo_warn "已取消，未修改端口。";
        return 0
    };
    echo_warn "将先修改 root 密码；密码修改成功后再修改 SSH 端口。这样可避免“端口已改但密码输入取消”的半完成状态。";
    echo_warn "当前 SSH 端口：$old_ports";
    ans="$(choice_ssh_port_keep_policy)";
    case "$ans" in 
        new_only)
            final_ports="$new_port"
        ;;
        keep_both)
            keep_ports="$old_ports,$new_port";
            final_ports="$(echo "$keep_ports" | awk -F, '{for(i=1;i<=NF;i++) if($i && !seen[$i]++) out=out (out? ",":"") $i; print out}')"
        ;;
        cancel)
            echo_warn "已取消，未修改密码和端口。";
            return 0
        ;;
    esac;
    confirm_yes "确认同时修改 root 密码并应用 SSH 端口：$final_ports？" || { 
        echo_warn "已取消。";
        return 0
    };
    echo "root:${new_password}" | chpasswd || { 
        echo_error "修改 root 密码失败，未修改 SSH 端口。";
        return 1
    };
    echo_color "root 密码已更新。继续应用 SSH 端口配置。";
    change_ssh_port_apply_value "$new_port" "$final_ports" || return 1;
    prl="$(sshd_effective_config | awk '$1=="permitrootlogin"{print $2; exit}')";
    pa="$(sshd_effective_config | awk '$1=="passwordauthentication"{print $2; exit}')";
    if [ "$pa" != "yes" ] || { 
        [ "$prl" != "yes" ] && [ "$prl" != "prohibit-password" ]
    }; then
        echo_warn "注意：密码已修改，但当前 SSH 可能不允许 root 密码登录。PermitRootLogin=${prl:-未知} PasswordAuthentication=${pa:-未知}";
    fi
}

change_ssh_port_apply_value () 
{ 
    local new_port="$1" final_ports="$2" backup_dir;
    backup_dir="$(make_backup_dir ssh)";
    backup_ssh_tree "$backup_dir";
    allow_port_firewall "$new_port" || echo_warn "防火墙放行失败或未持久化；已继续，但请手动确认安全组/防火墙。";
    selinux_allow_ssh_port "$new_port" || echo_warn "SELinux 端口放行失败；如 Enforcing，请手动检查 ssh_port_t。";
    if ! sshd_prepare_effective_key "Port"; then
        restore_backup_dir "$backup_dir" || true;
        return 1;
    fi;
    sshd_set_ports_dropin "$final_ports" || { 
        restore_backup_dir "$backup_dir" || true;
        return 1
    };
    if ssh_apply_with_rollback "SSH 端口配置" "$backup_dir"; then
        sshd_effective_config | awk '$1=="port"{print "生效端口: "$2}';
        sshd_check_listening_port "$new_port" || true;
        fail2ban_refresh_ssh_port_silent || true;
        echo_warn "请不要关闭当前 SSH 连接。请另开终端测试：ssh -p ${new_port} root@你的服务器IP";
        echo_warn "如防火墙/SELinux 已写入但 SSH 配置回滚，相关放行规则不会自动删除；这比误删规则导致断连更安全。";
        return 0;
    fi;
    return 1
}

change_ssh_port_only () 
{ 
    local new_port old_ports keep_ports final_ports ans;
    read -r -p "请输入新的 SSH 端口 (1-65535，输入 q 取消): " new_port;
    [[ "$new_port" =~ ^[Qq]$ ]] && { 
        echo_warn "已取消。";
        return 0
    };
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo_error "端口不合法。";
        return 1;
    fi;
    old_ports="$(get_current_ssh_ports)";
    if port_in_use "$new_port" && ! echo ",$old_ports," | grep -q ",$new_port,"; then
        echo_error "端口 $new_port 已被其他进程监听，请换一个。";
        return 1;
    fi;
    echo_warn "当前 SSH 端口：$old_ports";
    echo_warn "为避免断连，默认会临时保留旧端口，并同时监听新端口。";
    ans="$(choice_ssh_port_keep_policy)";
    case "$ans" in 
        new_only)
            final_ports="$new_port"
        ;;
        keep_both)
            keep_ports="$old_ports,$new_port";
            final_ports="$(echo "$keep_ports" | awk -F, '{for(i=1;i<=NF;i++) if($i && !seen[$i]++) out=out (out? ",":"") $i; print out}')"
        ;;
        cancel)
            echo_warn "已取消。";
            return 0
        ;;
    esac;
    change_ssh_port_apply_value "$new_port" "$final_ports"
}

change_ssh_port_password () 
{ 
    [ -f /etc/ssh/sshd_config ] || { 
        echo_error "找不到 /etc/ssh/sshd_config";
        return 1
    };
    while true; do
        ui_title "SSH 端口 / 密码 / 密钥 / root 管理";
        echo_warn "请不要关闭当前 SSH 连接，所有 SSH 修改都会备份、检测、验证并尽量回滚。";
        ui_option 1 "只修改 SSH 端口（drop-in 生效 + 防火墙/SELinux/Fail2Ban）";
        ui_option 2 "只修改 root 密码";
        ui_option 3 "同时修改 SSH 端口和 root 密码";
        ui_option 4 "配置密钥登录 / 自动生成密钥";
        ui_option 5 "开启/关闭密码登录";
        ui_option 6 "关闭 root 登录并新增 sudo 用户 / 恢复 root 登录";
        ui_option 7 "查看当前 SSH 关键配置与冲突项";
        ui_back;
        local mode;
        ui_prompt mode;
        case "$mode" in 
            1)
                change_ssh_port_only;
                pause_return
            ;;
            2)
                change_root_password_only;
                pause_return
            ;;
            3)
                change_ssh_port_and_password_together;
                pause_return
            ;;
            4)
                configure_key_login
            ;;
            5)
                toggle_password_login;
                pause_return
            ;;
            6)
                manage_root_login_user;
                pause_return
            ;;
            7)
                show_ssh_effective_config;
                pause_return
            ;;
            0)
                return 0
            ;;
            *)
                echo_error "无效选项";
                pause_return
            ;;
        esac;
    done
}

check_authorized_keys_safe () 
{ 
    local user="$1" home_dir ssh_dir auth_file;
    id "$user" > /dev/null 2>&1 || return 1;
    home_dir="$(getent passwd "$user" | cut -d: -f6)";
    ssh_dir="${home_dir}/.ssh";
    auth_file="${ssh_dir}/authorized_keys";
    [ -s "$auth_file" ] || { 
        echo_error "$auth_file 不存在或为空。";
        return 1
    };
    chmod 700 "$ssh_dir" 2> /dev/null || true;
    chmod 600 "$auth_file" 2> /dev/null || true;
    chown -R "$user:$user" "$ssh_dir" 2> /dev/null || true
}

check_ip_quality () 
{ 
    run_remote_script_confirm "IP 质量检测" "https://IP.Check.Place"
}

check_media_unlock () 
{ 
    run_remote_script_confirm "流媒体解锁检测" "https://check.unlock.media"
}

choice_private_key_action () 
{ 
    local ans;
    ui_option 1 "显示私钥";
    ui_option 2 "不显示，仅保留服务器路径（默认，推荐）";
    ui_option 3 "删除服务器上的私钥文件（确认本地已保存后再用）";
    ui_back;
    read -r -p "请选择 [默认 2]: " ans;
    ans="${ans:-2}";
    case "$ans" in 
        1 | 2 | 3 | 0)
            echo "$ans"
        ;;
        *)
            echo_error "无效选项，按默认不显示处理。";
            echo "2"
        ;;
    esac
}

choice_ssh_port_keep_policy () 
{ 
    local ans;
    ui_option 1 "只保留新端口";
    ui_option 2 "新旧端口都保留（默认，推荐）";
    ui_back;
    read -r -p "请选择 [默认 2]: " ans;
    ans="${ans:-2}";
    case "$ans" in 
        1)
            echo "new_only"
        ;;
        2)
            echo "keep_both"
        ;;
        0)
            echo "cancel"
        ;;
        *)
            echo_error "无效选项，已取消。";
            echo "cancel"
        ;;
    esac
}

configure_key_login () 
{ 
    while true; do
        ui_title "SSH 密钥登录配置";
        ui_option 1 "粘贴已有公钥并写入 authorized_keys";
        ui_option 2 "自动生成 ed25519 密钥对（默认不输出私钥）";
        ui_back;
        local opt;
        ui_prompt opt;
        case "$opt" in 
            1)
                configure_key_login_existing;
                pause_return
            ;;
            2)
                generate_key_login_and_output_private;
                pause_return
            ;;
            0)
                return 0
            ;;
            *)
                echo_error "无效选项";
                pause_return
            ;;
        esac;
    done
}

configure_key_login_existing () 
{ 
    local user pubkey home_dir ssh_dir auth_file backup_dir;
    read -r -p "请输入要配置密钥的用户名（默认 root，输入 q 取消）: " user;
    user="${user:-root}";
    [[ "$user" =~ ^[Qq]$ ]] && { 
        echo_warn "已取消。";
        return 0
    };
    id "$user" > /dev/null 2>&1 || { 
        echo_error "用户不存在：$user";
        return 1
    };
    echo_info "请粘贴一整行 SSH 公钥（ssh-rsa / ssh-ed25519 / ecdsa-sha2-* 开头），空内容取消：";
    read -r pubkey;
    [ -z "$pubkey" ] && { 
        echo_warn "已取消。";
        return 0
    };
    case "$pubkey" in 
        ssh-rsa\ * | ssh-ed25519\ * | ecdsa-sha2-*\ *)

        ;;
        *)
            echo_error "不像合法 SSH 公钥。";
            return 1
        ;;
    esac;
    backup_dir="$(make_backup_dir ssh-key)";
    backup_ssh_tree "$backup_dir";
    home_dir="$(getent passwd "$user" | cut -d: -f6)";
    ssh_dir="${home_dir}/.ssh";
    auth_file="${ssh_dir}/authorized_keys";
    mkdir -p "$ssh_dir";
    touch "$auth_file";
    grep -qxF "$pubkey" "$auth_file" || echo "$pubkey" >> "$auth_file";
    chown -R "$user:$user" "$ssh_dir" 2> /dev/null || chown -R "$user" "$ssh_dir";
    chmod 700 "$ssh_dir";
    chmod 600 "$auth_file";
    set_sshd_kv_effective "PubkeyAuthentication" "yes";
    if ssh_apply_with_rollback "密钥登录配置" "$backup_dir"; then
        sshd_check_effective_key PubkeyAuthentication yes || true;
        echo_warn "请另开终端测试密钥登录成功后，再考虑关闭密码登录。";
    fi
}

confirm_action () 
{ 
    local msg="${1:-确认继续？}";
    local default="${2:-2}";
    local ans;
    echo_warn "$msg";
    ui_option 1 "继续";
    ui_option 2 "取消（默认）";
    ui_back;
    read -r -p "请选择 [默认 ${default}]: " ans;
    ans="${ans:-$default}";
    case "$ans" in 
        1)
            return 0
        ;;
        2 | 0)
            return 1
        ;;
        *)
            echo_error "无效选项，已取消。";
            return 1
        ;;
    esac
}

confirm_yes () 
{ 
    confirm_action "${1:-确认继续？}" "2"
}

copy_fail_conf_path () 
{ 
    echo "/etc/modprobe.d/server-toolkit-copy-fail.conf"
}

cpu_usage_percent () 
{ 
    local a b idle1 total1 idle2 total2 diff_idle diff_total;
    read -r _ a b c d e f g h i j < /proc/stat;
    idle1=$((d+e));
    total1=$((a+b+c+d+e+f+g+h+i+j));
    sleep 1;
    read -r _ a b c d e f g h i j < /proc/stat;
    idle2=$((d+e));
    total2=$((a+b+c+d+e+f+g+h+i+j));
    diff_idle=$((idle2-idle1));
    diff_total=$((total2-total1));
    if [ "$diff_total" -le 0 ]; then
        echo "0";
    else
        awk -v i="$diff_idle" -v t="$diff_total" 'BEGIN{printf "%.0f", (1-i/t)*100}';
    fi
}

curl_has_release () 
{ 
    local base="$1" suite="$2" url1 url2;
    url1="${base%/}/dists/${suite}/InRelease";
    url2="${base%/}/dists/${suite}/Release";
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL --connect-timeout 5 --max-time 10 -o /dev/null "$url1" > /dev/null 2>&1 || curl -fsSL --connect-timeout 5 --max-time 10 -o /dev/null "$url2" > /dev/null 2>&1;
    else
        if command -v wget > /dev/null 2>&1; then
            wget --spider -q --timeout=10 "$url1" > /dev/null 2>&1 || wget --spider -q --timeout=10 "$url2" > /dev/null 2>&1;
        else
            return 2;
        fi;
    fi
}

debian_components_by_codename () 
{ 
    local code="$1";
    case "$code" in 
        wheezy | jessie | stretch | buster | bullseye)
            echo "main contrib non-free"
        ;;
        *)
            echo "main contrib non-free non-free-firmware"
        ;;
    esac
}

detect_pkg_manager () 
{ 
    if command -v apt-get > /dev/null 2>&1; then
        PKG_MANAGER="apt";
    else
        if command -v dnf > /dev/null 2>&1; then
            PKG_MANAGER="dnf";
        else
            if command -v yum > /dev/null 2>&1; then
                PKG_MANAGER="yum";
            else
                PKG_MANAGER="none";
            fi;
        fi;
    fi;
    echo "$PKG_MANAGER"
}

echo_blue () 
{ 
    echo -e "\e[1;34m$1\e[0m"
}

echo_color () 
{ 
    echo -e "\e[1;32m$1\e[0m"
}

echo_dim () 
{ 
    echo -e "\e[2m$1\e[0m"
}

echo_error () 
{ 
    echo -e "\e[1;31m$1\e[0m"
}

echo_info () 
{ 
    echo -e "\e[1;36m$1\e[0m"
}

echo_pink () 
{ 
    echo -e "\e[1;35m$1\e[0m"
}

echo_warn () 
{ 
    echo -e "\e[1;33m$1\e[0m"
}

ensure_command () 
{ 
    local cmd="$1" pkg="${2:-$1}";
    if command -v "$cmd" > /dev/null 2>&1; then
        return 0;
    fi;
    echo_warn "未检测到命令：$cmd，准备安装软件包：$pkg";
    pkg_install "$pkg" || return 1;
    command -v "$cmd" > /dev/null 2>&1 || { 
        echo_error "安装后仍未检测到命令：$cmd";
        return 1
    }
}

ensure_crontab_available () 
{ 
    if command -v crontab > /dev/null 2>&1; then
        return 0;
    fi;
    echo_warn "未检测到 crontab，准备安装 cron/cronie。";
    pkg_install cron cronie || return 1;
    command -v crontab > /dev/null 2>&1 || { 
        echo_error "安装后仍未检测到 crontab。";
        return 1
    };
    if is_systemd_available; then
        systemctl enable --now cron 2> /dev/null || systemctl enable --now crond 2> /dev/null || true;
    fi
}

fail2ban_backend_line () 
{ 
    local logpath;
    if command -v journalctl > /dev/null 2>&1 && [ -d /run/systemd/system ] && python3 -c 'import systemd.journal' > /dev/null 2>&1; then
        echo "backend = systemd";
    else
        if is_redhat; then
            logpath="/var/log/secure";
        else
            logpath="/var/log/auth.log";
        fi;
        mkdir -p "$(dirname "$logpath")" 2> /dev/null || true;
        [ -e "$logpath" ] || touch "$logpath" 2> /dev/null || true;
        echo "logpath = $logpath";
        echo "backend = auto";
        echo_warn "Fail2Ban 未使用 systemd backend；已确保 $logpath 存在。如系统不写认证日志，请安装 python3-systemd 或 rsyslog。" 1>&2;
    fi
}

fail2ban_banaction () 
{ 
    if firewalld_active; then
        echo "firewallcmd-ipset";
        return;
    fi;
    if command -v nft > /dev/null 2>&1; then
        echo "nftables-multiport";
        return;
    fi;
    if command -v ufw > /dev/null 2>&1; then
        echo "ufw";
        return;
    fi;
    echo "iptables-multiport"
}

fail2ban_config_jail () 
{ 
    local ssh_ports custom_ports bantime findtime maxretry ignoreip backup_dir;
    ssh_ports="$(get_current_ssh_ports)";
    echo_info "自动识别 SSH 端口：$ssh_ports";
    read -r -p "手动覆盖端口？回车使用自动识别，示例 22,2222: " custom_ports;
    [ -n "$custom_ports" ] && ssh_ports="$custom_ports";
    [[ "$ssh_ports" =~ ^[0-9]+(,[0-9]+)*$ ]] || { 
        echo_error "端口格式无效。";
        return 1
    };
    read -r -p "bantime 秒（默认 3600）: " bantime;
    read -r -p "findtime 秒（默认 600）: " findtime;
    read -r -p "maxretry（默认 3）: " maxretry;
    read -r -p "ignoreip 白名单，可空: " ignoreip;
    bantime="${bantime:-3600}";
    findtime="${findtime:-600}";
    maxretry="${maxretry:-3}";
    [[ "$bantime" =~ ^[0-9]+$ && "$findtime" =~ ^[0-9]+$ && "$maxretry" =~ ^[0-9]+$ ]] || { 
        echo_error "参数必须是数字。";
        return 1
    };
    backup_dir="$(make_backup_dir fail2ban-config)";
    backup_path_to_dir /etc/fail2ban "$backup_dir";
    fail2ban_write_sshd_jail_v22 "$ssh_ports" "$bantime" "$findtime" "$maxretry" "$ignoreip" "$backup_dir";
    fail2ban_validate_and_restart || { 
        echo_error "配置失败，开始回滚。";
        [ -d "$backup_dir/etc/fail2ban" ] && { 
            rm -rf /etc/fail2ban;
            cp -a "$backup_dir/etc/fail2ban" /etc/fail2ban
        };
        return 1
    };
    echo_color "Fail2Ban jail 配置已更新。"
}

fail2ban_detect_backend_lines () 
{ 
    local logpath;
    logpath="$(fail2ban_log_path)";
    if command -v journalctl > /dev/null 2>&1 && [ -d /run/systemd/system ] && python3 -c 'import systemd.journal' > /dev/null 2>&1; then
        printf 'backend = systemd\n';
    else
        [ -e "$logpath" ] || touch "$logpath" 2> /dev/null || true;
        printf 'backend = auto\n';
        printf 'logpath = %s\n' "$logpath";
    fi
}

fail2ban_global_dropin () 
{ 
    echo "/etc/fail2ban/fail2ban.d/server-toolkit.conf"
}

fail2ban_log_path () 
{ 
    if is_redhat; then
        echo "/var/log/secure";
    else
        echo "/var/log/auth.log";
    fi
}

fail2ban_recent_logs () 
{ 
    journalctl -u fail2ban -n 80 --no-pager 2> /dev/null || tail -n 80 /var/log/fail2ban.log 2> /dev/null || echo_warn "未找到 Fail2Ban 日志。"
}

fail2ban_refresh_ssh_port () 
{ 
    fail2ban_refresh_ssh_port_silent && echo_color "已刷新 Fail2Ban SSH 端口：$(get_current_ssh_ports)"
}

fail2ban_refresh_ssh_port_silent () 
{ 
    command -v fail2ban-server > /dev/null 2>&1 || return 0;
    [ -d /etc/fail2ban ] || return 0;
    local backup_dir ssh_ports;
    backup_dir="$(make_backup_dir fail2ban-port)";
    backup_path_to_dir /etc/fail2ban "$backup_dir";
    ssh_ports="$(get_current_ssh_ports)";
    [ -n "$ssh_ports" ] || ssh_ports="22";
    fail2ban_write_sshd_jail_v22 "$ssh_ports" 3600 600 3 "" "$backup_dir";
    fail2ban_validate_and_restart || { 
        [ -d "$backup_dir/etc/fail2ban" ] && { 
            rm -rf /etc/fail2ban;
            cp -a "$backup_dir/etc/fail2ban" /etc/fail2ban
        };
        return 1
    }
}

fail2ban_set_loglevel () 
{ 
    local level backup_dir;
    echo "可选等级：CRITICAL / ERROR / WARNING / NOTICE / INFO / DEBUG";
    read -r -p "请输入日志等级（建议 INFO，输入 q 取消）: " level;
    [[ "$level" =~ ^[Qq]$ ]] && { 
        echo_warn "已取消。";
        return 0
    };
    case "$level" in 
        CRITICAL | ERROR | WARNING | NOTICE | INFO | DEBUG)

        ;;
        *)
            echo_error "日志等级无效";
            return 1
        ;;
    esac;
    backup_dir="$(make_backup_dir fail2ban-loglevel)";
    backup_path_to_dir /etc/fail2ban "$backup_dir";
    fail2ban_write_base_local "$level";
    fail2ban_validate_and_restart || { 
        echo_error "设置失败，开始回滚。";
        [ -d "$backup_dir/etc/fail2ban" ] && { 
            rm -rf /etc/fail2ban;
            cp -a "$backup_dir/etc/fail2ban" /etc/fail2ban
        };
        return 1
    };
    echo_color "Fail2Ban 日志等级已设置为：$level"
}

fail2ban_show_banned () 
{ 
    fail2ban-client status sshd 2> /dev/null || { 
        echo_warn "sshd jail 未运行。";
        return 1
    }
}

fail2ban_status () 
{ 
    systemctl status fail2ban --no-pager -l 2> /dev/null || service fail2ban status 2> /dev/null || true;
    fail2ban-client status 2> /dev/null || true
}

fail2ban_unban_ip () 
{ 
    local ip;
    read -r -p "请输入要解封的 IP（输入 q 取消）: " ip;
    [[ "$ip" =~ ^[Qq]$ || -z "$ip" ]] && { 
        echo_warn "已取消。";
        return 0
    };
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || { 
        echo_error "IP 格式可疑，已取消。";
        return 1
    };
    fail2ban-client set sshd unbanip "$ip" 2> /dev/null && echo_color "已解封：$ip" || echo_error "解封失败，请确认 sshd jail 是否存在且 Fail2Ban 正在运行。"
}

fail2ban_validate_and_restart () 
{ 
    if ! command -v fail2ban-server > /dev/null 2>&1; then
        echo_error "fail2ban-server 不存在。";
        return 1;
    fi;
    if ! fail2ban-server -t > /tmp/server-toolkit-fail2ban-test.log 2>&1; then
        echo_error "Fail2Ban 配置检测失败：";
        cat /tmp/server-toolkit-fail2ban-test.log 2> /dev/null || true;
        return 1;
    fi;
    if is_systemd_available; then
        systemctl enable fail2ban > /dev/null 2>&1 || true;
        systemctl restart fail2ban || { 
            journalctl -u fail2ban -n 50 --no-pager 2> /dev/null || true;
            return 1
        };
        systemctl is-active fail2ban > /dev/null 2>&1 || { 
            echo_error "Fail2Ban 未处于 active 状态。";
            return 1
        };
    else
        service fail2ban restart 2> /dev/null || fail2ban-client start 2> /dev/null || { 
            echo_error "非 systemd 环境启动 Fail2Ban 失败。";
            return 1
        };
    fi
}

fail2ban_write_base_local () 
{ 
    local level="${1:-INFO}" file;
    file="$(fail2ban_global_dropin)";
    mkdir -p "$(dirname "$file")";
    backup_file "$file";
    if [ -f /etc/fail2ban/fail2ban.local ] && grep -q '^# server-toolkit v2\.2:' /etc/fail2ban/fail2ban.local 2> /dev/null; then
        backup_file /etc/fail2ban/fail2ban.local;
        mv /etc/fail2ban/fail2ban.local "/etc/fail2ban/fail2ban.local.disabled-by-server-toolkit-v23-$(date +%F_%H-%M-%S)";
        echo_warn "已停用旧版 server-toolkit 写入的 fail2ban.local，改用 fail2ban.d drop-in。";
    fi;
    cat > "$file" <<EOF2
# server-toolkit v2.3: fail2ban global drop-in，不覆盖用户 fail2ban.local
[Definition]
allowipv6 = auto
loglevel = $level
EOF2

}

fail2ban_write_sshd_jail () 
{ 
    local ssh_ports="$1";
    local bantime="$2";
    local findtime="$3";
    local maxretry="$4";
    local ignoreip="$5";
    local backend_lines;
    backend_lines="$(fail2ban_detect_backend_lines)";
    mkdir -p /etc/fail2ban;
    backup_file /etc/fail2ban/jail.local;
    cat > /etc/fail2ban/jail.local <<EOF
# server-toolkit: fail2ban sshd 防护配置
# bantime  = 封禁时长，单位秒；3600 = 1 小时
# findtime = 统计失败次数的时间窗口，单位秒；600 = 10 分钟
# maxretry = 在 findtime 内失败多少次后封禁
# ignoreip = 白名单 IP，不会被封禁；建议加入你的固定管理 IP
# port     = 当前 SSH 端口；支持多个端口，例如 22,2222
# backend  = v2.2 自动选择；systemd 环境优先用 journal，避免 /var/log/auth.log 不存在导致启动失败

[DEFAULT]
bantime = $bantime
findtime = $findtime
maxretry = $maxretry
ignoreip = 127.0.0.1/8 ::1 $ignoreip

[sshd]
enabled = true
port = $ssh_ports
$backend_lines
EOF

}

fail2ban_write_sshd_jail_v22 () 
{ 
    local ssh_ports="${1:-22}" bantime="${2:-3600}" findtime="${3:-600}" maxretry="${4:-3}" ignoreip="${5:-}" file="/etc/fail2ban/jail.d/server-toolkit-sshd.conf" backup_dir="${6:-}";
    [ -n "$ssh_ports" ] || ssh_ports="22";
    [[ "$ssh_ports" =~ ^[0-9]+(,[0-9]+)*$ ]] || { 
        echo_error "SSH 端口格式无效：$ssh_ports";
        return 1
    };
    validate_fail2ban_ignoreip "$ignoreip" || return 1;
    mkdir -p /etc/fail2ban/jail.d;
    [ -n "$backup_dir" ] && backup_path_to_dir "$file" "$backup_dir";
    cat > "$file" <<EOF2
# server-toolkit v2.3: sshd jail，不覆盖用户 jail.local
[sshd]
enabled = true
port = $ssh_ports
bantime = $bantime
findtime = $findtime
maxretry = $maxretry
ignoreip = 127.0.0.1/8 ::1 $ignoreip
banaction = $(fail2ban_banaction)
$(fail2ban_backend_line)
EOF2

}

firewall_status () 
{ 
    local ports p;
    ui_title "防火墙状态";
    ports="$(get_current_ssh_ports)";
    echo_info "当前 SSH 生效端口：$ports";
    echo_warn "云厂商安全组不受本脚本控制。";
    echo;
    if command -v firewall-cmd > /dev/null 2>&1; then
        echo_info "firewalld：";
        firewall-cmd --state 2> /dev/null || true;
        firewall-cmd --get-active-zones 2> /dev/null || true;
        firewall-cmd --list-all 2> /dev/null || true;
    else
        echo_dim "firewalld 未安装。";
    fi;
    echo;
    if command -v ufw > /dev/null 2>&1; then
        echo_info "ufw：";
        ufw status verbose 2> /dev/null || true;
    else
        echo_dim "ufw 未安装。";
    fi;
    echo;
    if command -v nft > /dev/null 2>&1; then
        echo_info "nftables 规则摘要：";
        nft list ruleset 2> /dev/null | head -n 80 || true;
    else
        if command -v iptables > /dev/null 2>&1; then
            echo_info "iptables INPUT 规则摘要：";
            iptables -S INPUT 2> /dev/null | head -n 80 || true;
        fi;
    fi;
    echo;
    for p in ${ports//,/ };
    do
        if firewalld_active; then
            firewall-cmd --query-port="${p}/tcp" > /dev/null 2>&1 && echo_color "SSH 端口 $p 已在 firewalld 放行" || echo_warn "SSH 端口 $p 未在 firewalld 查询到放行";
        fi;
        if command -v ufw > /dev/null 2>&1; then
            ufw status 2> /dev/null | grep -q "${p}/tcp" && echo_color "SSH 端口 $p 已在 ufw 规则中出现" || true;
        fi;
    done
}

firewalld_active () 
{ 
    command -v firewall-cmd > /dev/null 2>&1 && firewall-cmd --state > /dev/null 2>&1
}

format_bytes () 
{ 
    local b="${1:-0}";
    awk -v b="$b" 'BEGIN{if(b>=1099511627776)printf "%.2fT",b/1099511627776;else if(b>=1073741824)printf "%.2fG",b/1073741824;else if(b>=1048576)printf "%.2fM",b/1048576;else if(b>=1024)printf "%.2fK",b/1024;else printf "%dB",b}'
}

generate_key_login_and_output_private () 
{ 
    local user home_dir ssh_dir key_name key_path pub_path auth_file comment backup_dir ans;
    read -r -p "请输入要生成密钥的用户名（默认 root，输入 q 取消）: " user;
    user="${user:-root}";
    [[ "$user" =~ ^[Qq]$ ]] && { 
        echo_warn "已取消。";
        return 0
    };
    id "$user" > /dev/null 2>&1 || { 
        echo_error "用户不存在：$user";
        return 1
    };
    ensure_command ssh-keygen openssh-client || return 1;
    backup_dir="$(make_backup_dir ssh-keygen)";
    backup_ssh_tree "$backup_dir";
    home_dir="$(getent passwd "$user" | cut -d: -f6)";
    ssh_dir="${home_dir}/.ssh";
    key_name="server-toolkit_${user}_ed25519_$(date +%Y%m%d_%H%M%S)";
    key_path="${ssh_dir}/${key_name}";
    pub_path="${key_path}.pub";
    auth_file="${ssh_dir}/authorized_keys";
    comment="server-toolkit-${user}-$(hostname 2> /dev/null)-$(date +%F)";
    mkdir -p "$ssh_dir";
    chmod 700 "$ssh_dir";
    ssh-keygen -t ed25519 -N "" -C "$comment" -f "$key_path" || { 
        echo_error "生成密钥失败。";
        return 1
    };
    touch "$auth_file";
    cat "$pub_path" >> "$auth_file";
    chown -R "$user:$user" "$ssh_dir" 2> /dev/null || chown -R "$user" "$ssh_dir";
    chmod 600 "$auth_file" "$key_path";
    chmod 644 "$pub_path";
    set_sshd_kv_effective "PubkeyAuthentication" "yes";
    ssh_apply_with_rollback "自动生成密钥" "$backup_dir" || return 1;
    echo_color "已为用户 $user 生成密钥，并写入 authorized_keys。";
    echo_info "私钥保存路径：$key_path";
    echo_info "公钥内容：";
    cat "$pub_path";
    echo_warn "默认不直接输出私钥，避免终端录屏/日志泄漏。";
    while true; do
        ans="$(choice_private_key_action)";
        case "$ans" in 
            1)
                echo "==================== PRIVATE KEY START ====================";
                cat "$key_path";
                echo "===================== PRIVATE KEY END =====================";
                echo_warn "复制到本地后请执行：chmod 600 私钥文件"
            ;;
            2)
                echo_info "已保留私钥在服务器路径：$key_path";
                return 0
            ;;
            3)
                confirm_action "删除服务器上的私钥文件前，请确认你已经把私钥安全保存到本地。" "2" || continue;
                rm -f "$key_path";
                echo_warn "已删除服务器上的私钥文件：$key_path";
                return 0
            ;;
            0)
                return 0
            ;;
        esac;
    done
}

get_current_ssh_ports () 
{ 
    local ports;
    ports="$(sshd_effective_config | awk '$1=="port"{print $2}' | sort -n | paste -sd, - 2> /dev/null || true)";
    [ -z "$ports" ] && ports="22";
    echo "$ports"
}

get_default_iface () 
{ 
    ip -o route get 1.1.1.1 2> /dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

get_os_codename () 
{ 
    . /etc/os-release 2> /dev/null && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}" || true
}

get_os_id () 
{ 
    . /etc/os-release 2> /dev/null && echo "${ID:-unknown}" || echo "unknown"
}

grub_cfg_outputs () 
{ 
    if [ -d /boot/grub2 ]; then
        echo /boot/grub2/grub.cfg;
    fi;
    if [ -d /boot/grub ]; then
        echo /boot/grub/grub.cfg;
    fi;
    if [ -d /boot/efi/EFI ]; then
        find /boot/efi/EFI -maxdepth 2 -name grub.cfg 2> /dev/null;
    fi
}

grub_cmdline_add_param () 
{ 
    local file="$1" param="$2";
    [ -f "$file" ] || return 0;
    grep -q '^GRUB_CMDLINE_LINUX=' "$file" || echo 'GRUB_CMDLINE_LINUX=""' >> "$file";
    grep -Fq "$param" "$file" || sed -i -E "s/^GRUB_CMDLINE_LINUX=\"(.*)\"/GRUB_CMDLINE_LINUX=\"${param} \1\"/" "$file"
}

grub_cmdline_remove_param () 
{ 
    local file="$1" param="$2";
    [ -f "$file" ] || return 0;
    sed -i -E "s/[[:space:]]*${param}//g; s/  +/ /g" "$file";
    sed -i -E 's/GRUB_CMDLINE_LINUX=" /GRUB_CMDLINE_LINUX="/' "$file"
}

grub_file_detect () 
{ 
    [ -f /etc/default/grub ] && echo /etc/default/grub
}

has_cap_sys_time () 
{ 
    if command -v capsh > /dev/null 2>&1; then
        capsh --print 2> /dev/null | grep -q 'cap_sys_time';
        return $?;
    fi;
    [ -r /proc/1/status ] || return 1;
    awk '/CapEff/ {print $2}' /proc/1/status | while read -r hex; do
        [ -z "$hex" ] && exit 1;
        if [ $((16#$hex & (1<<25))) -ne 0 ]; then
            exit 0;
        else
            exit 1;
        fi;
    done
}

is_container_env () 
{ 
    if command -v systemd-detect-virt > /dev/null 2>&1; then
        systemd-detect-virt --container > /dev/null 2>&1 && return 0;
    fi;
    grep -qaE '(docker|lxc|containerd|kubepods|podman)' /proc/1/cgroup 2> /dev/null
}

is_debian_like () 
{ 
    parse_os_release;
    os_like_contains debian || [ "$OS_ID" = "ubuntu" ] || [ "$OS_ID" = "debian" ]
}

is_redhat () 
{ 
    parse_os_release;
    os_like_contains rhel || os_like_contains fedora || [ "$OS_ID" = "fedora" ] || [ "$OS_ID" = "amzn" ] || [ "$OS_ID" = "amazon" ]
}

is_systemd_available () 
{ 
    command -v systemctl > /dev/null 2>&1 && [ -d /run/systemd/system ]
}

main () 
{ 
    parse_os_release;
    require_root;
    while true; do
        print_menu;
        local option;
        read -r -p "请选择一个操作: " option;
        case "$option" in 
            1)
                time_sync;
                pause_return
            ;;
            2)
                manage_firewall
            ;;
            3)
                manage_selinux
            ;;
            4)
                secure_ssh
            ;;
            5)
                manage_fail2ban
            ;;
            6)
                change_ssh_port_password
            ;;
            7)
                check_media_unlock
            ;;
            8)
                show_system_info;
                pause_return
            ;;
            9)
                yabs_test
            ;;
            10)
                setup_cron_reboot;
                pause_return
            ;;
            11)
                manage_nezha
            ;;
            12)
                check_ip_quality
            ;;
            13)
                manage_ipv6
            ;;
            14)
                server_hardening
            ;;
            15)
                new_server_init_menu
            ;;
            0)
                echo_color "退出";
                exit 0
            ;;
            *)
                echo_error "无效的选项，请重新输入";
                pause_return
            ;;
        esac;
    done
}

make_backup_dir () 
{ 
    local name="$1" dir;
    dir="/root/server-toolkit-backups/${name}-$(date +%F_%H-%M-%S)";
    mkdir -p "$dir";
    echo "$dir"
}

manage_fail2ban () 
{ 
    while true; do
        ui_title "Fail2Ban 管理";
        ui_option 1 "安装/写入默认 SSH 防护配置（jail.d，不覆盖 jail.local）";
        ui_option 2 "自动识别当前 SSH 端口并刷新配置";
        ui_option 3 "查看 Fail2Ban 服务状态";
        ui_option 4 "查看 sshd jail / banned IP";
        ui_option 5 "查看最近 80 条日志";
        ui_option 6 "设置 Fail2Ban 日志等级";
        ui_option 7 "配置 sshd 防护参数";
        ui_option 8 "解封指定 IP";
        ui_back;
        local opt;
        ui_prompt opt;
        case "$opt" in 
            1)
                setup_fail2ban_default;
                pause_return
            ;;
            2)
                fail2ban_refresh_ssh_port;
                pause_return
            ;;
            3)
                fail2ban_status;
                pause_return
            ;;
            4)
                fail2ban_show_banned;
                pause_return
            ;;
            5)
                fail2ban_recent_logs;
                pause_return
            ;;
            6)
                fail2ban_set_loglevel;
                pause_return
            ;;
            7)
                fail2ban_config_jail;
                pause_return
            ;;
            8)
                fail2ban_unban_ip;
                pause_return
            ;;
            0)
                return 0
            ;;
            *)
                echo_error "无效选项";
                pause_return
            ;;
        esac;
    done
}

manage_firewall () 
{ 
    while true; do
        ui_title "防火墙管理";
        ui_option 1 "查看状态/规则/SSH 端口放行情况";
        ui_option 2 "开启防火墙（先放行当前 SSH 端口）";
        ui_option 3 "关闭防火墙服务（危险，默认取消）";
        ui_option 4 "手动放行一个 TCP 端口";
        ui_back;
        local opt port;
        ui_prompt opt;
        case "$opt" in 
            1)
                firewall_status;
                pause_return
            ;;
            2)
                echo_warn "开启前会先放行当前 SSH 端口：$(get_current_ssh_ports)";
                confirm_yes "确认开启本机防火墙？" || { 
                    echo_warn "已取消。";
                    continue
                };
                allow_ssh_ports_before_firewall_enable;
                parse_os_release;
                if os_like_contains rhel || os_like_contains fedora || [ "$OS_ID" = "fedora" ] || [ "$OS_ID" = "amzn" ]; then
                    if ! command -v firewall-cmd > /dev/null 2>&1; then
                        read -r -p "未安装 firewalld，是否安装？[y/N]: " yn;
                        [[ "$yn" =~ ^[Yy]$ ]] && pkg_install firewalld;
                    fi;
                    service_enable_now firewalld && allow_ssh_ports_before_firewall_enable && echo_color "firewalld 已开启。";
                else
                    if command -v ufw > /dev/null 2>&1; then
                        allow_ssh_ports_before_firewall_enable;
                        ufw --force enable && echo_color "ufw 已开启。";
                    else
                        echo_warn "Debian/Ubuntu 未检测到 ufw。为避免误装影响规则，本脚本不会默认安装。";
                    fi;
                fi;
                pause_return
            ;;
            3)
                confirm_yes "确认关闭本机 firewalld/ufw？云厂商安全组不受影响。" || { 
                    echo_warn "已取消。";
                    continue
                };
                is_systemd_available && systemctl disable --now firewalld 2> /dev/null || true;
                command -v ufw > /dev/null 2>&1 && ufw disable || true;
                echo_color "已尝试关闭本机防火墙服务。";
                pause_return
            ;;
            4)
                read -r -p "请输入 TCP 端口: " port;
                if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                    allow_port_firewall "$port";
                else
                    echo_error "端口无效。";
                fi;
                pause_return
            ;;
            0)
                return 0
            ;;
            *)
                echo_error "无效选项";
                pause_return
            ;;
        esac;
    done
}

manage_ipv6 () 
{ 
    while true; do
        ui_title "IPv6 一键开启/关闭";
        ui_option 1 "一键开启 IPv6";
        ui_option 2 "一键关闭 IPv6（sysctl + 非容器环境 GRUB）";
        ui_option 3 "查看 IPv6 状态";
        ui_back;
        local opt conf="/etc/sysctl.d/99-server-toolkit-ipv6.conf";
        ui_prompt opt;
        case "$opt" in 
            1)
                backup_file "$conf";
                cat > "$conf" <<'EOF'
# server-toolkit v2.3: ipv6 enable
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.lo.disable_ipv6=0
EOF

                update_grub_ipv6_param enable;
                sysctl --system > /dev/null 2>&1 || true;
                show_ipv6_status;
                pause_return
            ;;
            2)
                confirm_yes "确认关闭 IPv6？可能影响依赖 IPv6 的服务。" || continue;
                backup_file "$conf";
                cat > "$conf" <<'EOF'
# server-toolkit v2.3: ipv6 disable
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF

                update_grub_ipv6_param disable;
                sysctl --system > /dev/null 2>&1 || true;
                show_ipv6_status;
                pause_return
            ;;
            3)
                show_ipv6_status;
                pause_return
            ;;
            0)
                return 0
            ;;
            *)
                echo_error "无效选项";
                pause_return
            ;;
        esac;
    done
}

manage_nezha () 
{ 
    while true; do
        ui_title "哪吒面板管理";
        ui_option 1 "重启哪吒 Agent";
        ui_option 2 "重启哪吒 Dashboard";
        ui_option 3 "重启 Agent + Dashboard";
        ui_option 4 "设置定期重启 Agent";
        ui_option 5 "移除 Agent 定期重启任务";
        ui_option 6 "卸载哪吒面板/探针（危险）";
        ui_back;
        local nezha_opt confirm;
        ui_prompt nezha_opt;
        case "$nezha_opt" in 
            1)
                service_restart_safe nezha-agent || systemctl restart nezha-agent 2> /dev/null || true;
                echo_color "已尝试重启 nezha-agent。";
                pause_return
            ;;
            2)
                service_restart_safe nezha-dashboard || systemctl restart nezha-dashboard 2> /dev/null || true;
                echo_color "已尝试重启 nezha-dashboard。";
                pause_return
            ;;
            3)
                service_restart_safe nezha-agent || true;
                service_restart_safe nezha-dashboard || true;
                echo_color "已尝试重启哪吒相关服务。";
                pause_return
            ;;
            4)
                setup_nezha_agent_restart_cron;
                pause_return
            ;;
            5)
                remove_nezha_agent_restart_cron;
                pause_return
            ;;
            6)
                echo_warn "此操作会删除 /opt/nezha /etc/nezha /var/log/nezha 以及 systemd 服务。";
                confirm_yes "确认卸载哪吒面板/探针？" || { 
                    echo_warn "已取消。";
                    continue
                };
                is_systemd_available && systemctl stop nezha-agent nezha-dashboard 2> /dev/null || true;
                is_systemd_available && systemctl disable nezha-agent nezha-dashboard 2> /dev/null || true;
                rm -f /etc/systemd/system/nezha-agent.service /etc/systemd/system/nezha-dashboard.service;
                rm -rf /opt/nezha /etc/nezha /var/log/nezha;
                is_systemd_available && systemctl daemon-reload || true;
                echo_color "哪吒面板/探针已移除。";
                pause_return
            ;;
            0)
                return 0
            ;;
            *)
                echo_error "无效选项";
                pause_return
            ;;
        esac;
    done
}

manage_root_login_user () 
{ 
    ui_title "root 登录 / sudo 用户管理";
    echo_warn "关闭 root 登录前必须确认普通 sudo 用户可登录并可 sudo。";
    ui_option 1 "新增 sudo 用户，并关闭 root SSH 登录";
    ui_option 2 "恢复 root SSH 登录";
    ui_back;
    local opt user pass backup_dir sudoers_file;
    ui_prompt opt;
    case "$opt" in 
        1)
            read -r -p "请输入新用户名（输入 q 取消，仅允许 Linux 常规用户名）: " user;
            [[ "$user" =~ ^[Qq]$ || -z "$user" ]] && { 
                echo_warn "已取消。";
                return 0
            };
            [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || { 
                echo_error "用户名格式不安全，已取消。";
                return 1
            };
            ensure_command sudo sudo || return 1;
            if ! id "$user" > /dev/null 2>&1; then
                useradd -m -s /bin/bash "$user" || return 1;
            fi;
            read -r -s -p "请输入新用户密码: " pass;
            echo;
            [ -z "$pass" ] && { 
                echo_error "密码不能为空。";
                return 1
            };
            echo "${user}:${pass}" | chpasswd || return 1;
            sudoers_file="/etc/sudoers.d/90-server-toolkit-${user}";
            printf '%s ALL=(ALL:ALL) ALL\n' "$user" > "$sudoers_file";
            chmod 440 "$sudoers_file";
            if command -v visudo > /dev/null 2>&1; then
                visudo -cf "$sudoers_file" || { 
                    rm -f "$sudoers_file";
                    echo_error "sudoers 校验失败，未关闭 root 登录。";
                    return 1
                };
            fi;
            echo_warn "请先另开终端测试：ssh ${user}@你的服务器IP，然后执行 sudo -v。";
            confirm_yes "确认已经测试 ${user} 可登录并可 sudo？继续后将关闭 root SSH 登录。" || return 0;
            backup_dir="$(make_backup_dir ssh-root-off)";
            backup_ssh_tree "$backup_dir";
            set_sshd_kv_effective "PermitRootLogin" "no";
            ssh_apply_with_rollback "关闭 root SSH 登录" "$backup_dir"
        ;;
        2)
            backup_dir="$(make_backup_dir ssh-root-on)";
            backup_ssh_tree "$backup_dir";
            set_sshd_kv_effective "PermitRootLogin" "yes";
            ssh_apply_with_rollback "恢复 root SSH 登录" "$backup_dir"
        ;;
        0)
            return 0
        ;;
        *)
            echo_error "无效选项"
        ;;
    esac
}

manage_selinux () 
{ 
    while true; do
        ui_title "SELinux 管理";
        selinux_status;
        ui_option 1 "设置 Enforcing（如从 Disabled 恢复，建议先 Permissive 并重启/重标记）";
        ui_option 2 "设置 Disabled（需重启完全生效）";
        ui_option 3 "设置 Permissive（当前会话尽量生效）";
        ui_option 4 "为 SSH 非标准端口添加 ssh_port_t";
        ui_back;
        local opt port;
        ui_prompt opt;
        case "$opt" in 
            1)
                [ -f /etc/selinux/config ] || { 
                    echo_warn "未找到 /etc/selinux/config。";
                    pause_return;
                    continue
                };
                echo_warn "如果当前是 Disabled，建议先改 Permissive 并 touch /.autorelabel 后重启，再改 Enforcing。";
                confirm_yes "确认设置 SELINUX=enforcing？" || continue;
                backup_file /etc/selinux/config;
                sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config;
                setenforce 1 2> /dev/null || true;
                echo_color "已设置 Enforcing；如之前为 Disabled，请重启并关注 autorelabel。";
                pause_return
            ;;
            2)
                [ -f /etc/selinux/config ] || { 
                    echo_warn "未找到 /etc/selinux/config。";
                    pause_return;
                    continue
                };
                confirm_yes "确认设置 SELINUX=disabled？需要重启完全生效。" || continue;
                backup_file /etc/selinux/config;
                sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config;
                setenforce 0 2> /dev/null || true;
                echo_color "已设置 Disabled，需重启后完全生效。";
                pause_return
            ;;
            3)
                [ -f /etc/selinux/config ] || { 
                    echo_warn "未找到 /etc/selinux/config。";
                    pause_return;
                    continue
                };
                backup_file /etc/selinux/config;
                sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config;
                setenforce 0 2> /dev/null || true;
                echo_color "已设置 Permissive。";
                pause_return
            ;;
            4)
                read -r -p "请输入 SSH TCP 端口: " port;
                if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                    selinux_allow_ssh_port "$port";
                else
                    echo_error "端口无效。";
                fi;
                pause_return
            ;;
            0)
                return 0
            ;;
            *)
                echo_error "无效选项";
                pause_return
            ;;
        esac;
    done
}

menu_pad_right () 
{ 
    local text="$1";
    local target="$2";
    local width i;
    width=$(menu_text_width "$text");
    printf "%s" "$text";
    for ((i=width; i<target; i++))
    do
        printf " ";
    done
}

menu_row () 
{ 
    local left="$1" right="$2";
    printf "  \e[1;32m";
    menu_pad_right "$left" 38;
    printf "\e[0m │ \e[1;32m";
    menu_pad_right "$right" 38;
    printf "\e[0m\n"
}

menu_text_width () 
{ 
    local text="$1";
    local chars bytes wide;
    chars=$(printf "%s" "$text" | wc -m | awk '{print $1}');
    bytes=$(printf "%s" "$text" | wc -c | awk '{print $1}');
    wide=$(( (bytes - chars) / 2 ));
    echo $((chars + wide))
}

new_server_basic_update () 
{ 
    ui_title "保守更新 / 常用工具安装";
    pkg_makecache || return 1;
    pkg_install ca-certificates curl wget sudo openssh-server openssh-client cron || return 1;
    pkg_install vim git unzip dns-tools || echo_warn "部分可选工具安装失败，已继续。";
    openssh_security_upgrade || true;
    echo_color "保守更新完成。"
}

new_server_full_update () 
{ 
    ui_title "全量系统更新";
    confirm_yes "全量更新可能升级大量包，生产环境建议先快照/备份。确认继续？" || return 0;
    pkg_makecache || return 1;
    pkg_full_upgrade
}

new_server_init_menu () 
{ 
    while true; do
        ui_title "新服务器初始化 / 源修复";
        show_os_detected;
        ui_option 1 "自动检测并修复包管理器源（APT 或 DNF/YUM）";
        ui_option 2 "只检测当前源可用性";
        ui_option 3 "保守更新：安装常用工具并更新 OpenSSH";
        ui_option 4 "全量更新：upgrade/dist-upgrade/full-upgrade/autoremove";
        ui_option 5 "单独修复/更新 OpenSSH 高危漏洞相关包";
        ui_back;
        local opt;
        ui_prompt opt;
        case "$opt" in 
            1)
                repair_sources_menu
            ;;
            2)
                if is_debian_like; then
                    apt_check_sources;
                else
                    rpm_check_repos;
                fi;
                pause_return
            ;;
            3)
                new_server_basic_update;
                pause_return
            ;;
            4)
                new_server_full_update;
                pause_return
            ;;
            5)
                openssh_security_upgrade;
                pause_return
            ;;
            0)
                return 0
            ;;
            *)
                echo_error "无效选项";
                pause_return
            ;;
        esac;
    done
}

one_click_safe_hardening () 
{ 
    ui_title "一键保守加固";
    echo_warn "将应用：保守 sysctl + SSH 保守增强；不会禁 root、不会禁密码、不会改端口。";
    echo_warn "Copy Fail 临时缓解需要单独在本菜单第 5 项执行，避免未经确认影响 IPsec/加密负载。";
    confirm_yes "确认继续？" || return 0;
    apply_conservative_sysctl_hardening;
    ssh_security_recommended
}

openssh_security_upgrade () 
{ 
    ui_title "OpenSSH 安全更新";
    parse_os_release;
    pkg_makecache || { 
        echo_error "软件源不可用，无法升级 OpenSSH。";
        return 1
    };
    pkg_install openssh-server openssh-client || return 1;
    pkg_upgrade || true;
    echo_color "OpenSSH 相关包已尝试更新。当前版本：";
    ssh -V 2>&1 || true;
    command -v sshd > /dev/null 2>&1 && sshd -V 2>&1 || true
}

os_like_contains () 
{ 
    local needle="$1";
    case " $OS_ID $OS_ID_LIKE " in 
        *" $needle "*)
            return 0
        ;;
        *)
            return 1
        ;;
    esac
}

parse_os_release () 
{ 
    OS_ID="unknown";
    OS_ID_LIKE="";
    OS_VERSION_ID="";
    OS_VERSION_CODENAME="";
    OS_PRETTY_NAME="unknown";
    if [ -r /etc/os-release ]; then
        . /etc/os-release;
        OS_ID="${ID:-unknown}";
        OS_ID_LIKE="${ID_LIKE:-}";
        OS_VERSION_ID="${VERSION_ID:-}";
        OS_VERSION_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}";
        OS_PRETTY_NAME="${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}";
    else
        if [ -r /etc/redhat-release ]; then
            OS_PRETTY_NAME="$(cat /etc/redhat-release 2> /dev/null)";
            OS_ID="rhel";
            OS_ID_LIKE="rhel fedora";
            OS_VERSION_ID="$(echo "$OS_PRETTY_NAME" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1 || true)";
        else
            if [ -r /etc/debian_version ]; then
                OS_ID="debian";
                OS_ID_LIKE="debian";
                OS_VERSION_ID="$(cat /etc/debian_version 2> /dev/null)";
                OS_PRETTY_NAME="Debian $OS_VERSION_ID";
            fi;
        fi;
    fi;
    OS_MAJOR="${OS_VERSION_ID%%.*}";
    [ "$OS_MAJOR" = "$OS_VERSION_ID" ] || true
}

pause_return () 
{ 
    echo;
    read -r -p "按 Enter 返回菜单..."
}

pkg_full_upgrade () 
{ 
    local pm;
    pm="$(detect_pkg_manager)";
    case "$pm" in 
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade -y;
            DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
        ;;
        dnf)
            dnf upgrade -y --refresh && dnf autoremove -y
        ;;
        yum)
            yum update -y
        ;;
        *)
            echo_error "未检测到支持的包管理器。";
            return 1
        ;;
    esac
}

pkg_install () 
{ 
    local pm mapped p pkgs=();
    pm="$(detect_pkg_manager)";
    [ "$pm" = "none" ] && { 
        echo_error "未检测到支持的包管理器。";
        return 1
    };
    for p in "$@";
    do
        mapped="$(pkg_map_name "$p")";
        [ -n "$mapped" ] && pkgs+=("$mapped");
    done;
    [ "${#pkgs[@]}" -eq 0 ] && { 
        echo_warn "没有可安装的软件包。";
        return 0
    };
    echo_info "正在安装：${pkgs[*]}";
    case "$pm" in 
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y "${pkgs[@]}"
        ;;
        dnf)
            dnf install -y "${pkgs[@]}"
        ;;
        yum)
            yum install -y "${pkgs[@]}"
        ;;
    esac
}

pkg_makecache () 
{ 
    local pm;
    pm="$(detect_pkg_manager)";
    case "$pm" in 
        apt)
            echo_info "正在刷新 APT 缓存...";
            DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold update
        ;;
        dnf)
            echo_info "正在刷新 DNF 缓存...";
            dnf -y makecache
        ;;
        yum)
            echo_info "正在刷新 YUM 缓存...";
            yum -y makecache
        ;;
        *)
            echo_error "未检测到支持的包管理器。";
            return 1
        ;;
    esac
}

pkg_map_name () 
{ 
    local name="$1";
    local pm;
    pm="$(detect_pkg_manager)";
    case "$pm:$name" in 
        apt:openssh-server)
            echo "openssh-server"
        ;;
        apt:openssh-client)
            echo "openssh-client"
        ;;
        apt:dns-tools)
            echo "dnsutils"
        ;;
        apt:cron)
            echo "cron"
        ;;
        apt:cronie)
            echo "cron"
        ;;
        apt:semanage)
            echo "policycoreutils-python-utils"
        ;;
        apt:python3-systemd)
            echo "python3-systemd"
        ;;
        apt:systemd-timesyncd)
            echo "systemd-timesyncd"
        ;;
        dnf:openssh-client | yum:openssh-client)
            echo "openssh-clients"
        ;;
        dnf:dns-tools | yum:dns-tools)
            echo "bind-utils"
        ;;
        dnf:cron | yum:cron)
            echo "cronie"
        ;;
        dnf:cronie | yum:cronie)
            echo "cronie"
        ;;
        dnf:semanage | yum:semanage)
            parse_os_release;
            if [ "$OS_MAJOR" = "7" ]; then
                echo "policycoreutils-python";
            else
                echo "policycoreutils-python-utils";
            fi
        ;;
        dnf:python3-systemd | yum:python3-systemd)
            echo "python3-systemd"
        ;;
        dnf:systemd-timesyncd | yum:systemd-timesyncd)
            echo ""
        ;;
        *)
            echo "$name"
        ;;
    esac
}

pkg_remove () 
{ 
    local pm mapped p pkgs=();
    pm="$(detect_pkg_manager)";
    for p in "$@";
    do
        mapped="$(pkg_map_name "$p")";
        [ -n "$mapped" ] && pkgs+=("$mapped");
    done;
    [ "${#pkgs[@]}" -eq 0 ] && return 0;
    case "$pm" in 
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get remove -y "${pkgs[@]}"
        ;;
        dnf)
            dnf remove -y "${pkgs[@]}"
        ;;
        yum)
            yum remove -y "${pkgs[@]}"
        ;;
        *)
            echo_error "未检测到支持的包管理器。";
            return 1
        ;;
    esac
}

pkg_update () 
{ 
    pkg_makecache
}

pkg_upgrade () 
{ 
    local pm;
    pm="$(detect_pkg_manager)";
    case "$pm" in 
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y
        ;;
        dnf)
            dnf upgrade -y
        ;;
        yum)
            yum update -y
        ;;
        *)
            echo_error "未检测到支持的包管理器。";
            return 1
        ;;
    esac
}

port_in_use () 
{ 
    local port="${1:-}";
    [[ "$port" =~ ^[0-9]+$ ]] || return 1;
    if command -v ss > /dev/null 2>&1; then
        ss -H -ltn "sport = :$port" 2> /dev/null | grep -q . && return 0;
        ss -H -ltn 2> /dev/null | awk '{print $4}' | grep -Eq "(^|[:.])${port}$" && return 0;
    else
        if command -v netstat > /dev/null 2>&1; then
            netstat -lnt 2> /dev/null | awk '{print $4}' | grep -Eq "(^|[:.])${port}$" && return 0;
        fi;
    fi;
    return 1
}

print_menu () 
{ 
    [ -n "${TERM:-}" ] && clear 2> /dev/null || true;
    printf "\n";
    printf "\e[1;36m──────────────────────────────────────────────────────────────────────────────\e[0m\n";
    printf "  \e[1;35mserver-toolkit %s · Linux 服务器工具箱\e[0m\n" "$SERVER_TOOLKIT_VERSION";
    printf "\e[1;36m──────────────────────────────────────────────────────────────────────────────\e[0m\n";
    printf "\e[1;36m功能菜单\e[0m\n";
    printf "\e[2m──────────────────────────────────────────────────────────────────────────────\e[0m\n";
    menu_row "1)  时间同步（timesyncd/chrony）" "9)  YABS 测试";
    menu_row "2)  防火墙开启/关闭" "10) 设置定时重启";
    menu_row "3)  SELinux 开启/关闭" "11) 哪吒面板管理";
    menu_row "4)  SSH 安全性增强向导" "12) IP 质量检测";
    menu_row "5)  Fail2Ban 管理" "13) IPv6 一键开启/关闭";
    menu_row "6)  SSH 端口/密码/密钥/root 管理" "14) 服务器加固";
    menu_row "7)  流媒体解锁检测" "15) 新服务器初始化/源修复";
    menu_row "8)  显示服务器基本信息" "0)  退出";
    printf "\e[2m──────────────────────────────────────────────────────────────────────────────\e[0m\n"
}

public_ip_detect () 
{ 
    local ip4 ip6;
    if command -v curl > /dev/null 2>&1; then
        ip4="$(curl -4 -fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2> /dev/null || true)";
        ip6="$(curl -6 -fsS --connect-timeout 3 --max-time 5 https://api64.ipify.org 2> /dev/null || true)";
    fi;
    [ -z "$ip4" ] && ip4="$(hostname -I 2> /dev/null | awk '{print $1}')";
    echo "IPv4=${ip4:-未知} IPv6=${ip6:-未知}"
}

remove_copy_fail_mitigation () 
{ 
    local conf;
    conf="$(copy_fail_conf_path)";
    [ -f "$conf" ] || { 
        echo_warn "未找到临时缓解文件。";
        return 0
    };
    backup_file "$conf";
    rm -f "$conf";
    echo_color "已移除 Copy Fail 临时缓解文件。若模块仍需恢复，请重启或手动 modprobe。"
}

remove_nezha_agent_restart_cron () 
{ 
    local marker="# server-toolkit: nezha-agent-restart" tmpcron;
    ensure_crontab_available || return 1;
    tmpcron="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || { 
        echo_error "创建临时 crontab 文件失败。";
        return 1
    };
    crontab -l 2> /dev/null | grep -v "$marker" > "$tmpcron" || true;
    crontab "$tmpcron" && rm -f "$tmpcron" && echo_color "已移除 nezha-agent 定期重启任务。" || { 
        rm -f "$tmpcron";
        echo_error "写入 crontab 失败。";
        return 1
    }
}

repair_apt_sources_auto () 
{ 
    if ! is_debian_like; then
        echo_warn "当前不是 Debian/Ubuntu 系，跳过 APT 源修复。";
        return 0;
    fi;
    local os code confirm log_file;
    os="$(get_os_id)";
    code="$(get_os_codename)";
    [ -z "$code" ] && { 
        echo_error "无法识别系统代号，无法自动换源。";
        return 1
    };
    [ "$os" = "ubuntu" ] || os="debian";
    log_file="/tmp/server-toolkit-apt-update.log";
    ui_title "自动检测并修复 APT 源";
    echo_info "系统识别：$os / $code";
    echo_info "先检测当前 APT 源是否可用。";
    apt_env_export;
    if apt-get update -y > "$log_file" 2>&1; then
        echo_color "当前 APT 源可正常 update，未强制改写。";
        read -r -p "是否继续检测并切换到官方/Google/Cloudflare/Yandex/归档源？[y/N]: " confirm;
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            apt_source_interactive_chooser;
        else
            echo_warn "已保留当前 APT 源。";
        fi;
        return 0;
    fi;
    echo_warn "当前 APT 源 update 失败，最近输出如下：";
    tail -n 25 "$log_file" 2> /dev/null || true;
    echo;
    echo_warn "将自动检测候选源并尝试修复；修改前会备份 sources.list，并停用可能冲突的发行版源文件。";
    if apt_try_auto_repair_sources "$os" "$code"; then
        read -r -p "是否继续检测并切换到其它可用源？[y/N]: " confirm;
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            apt_source_interactive_chooser;
        fi;
        return 0;
    fi;
    echo_error "自动修复 APT 源失败。请检查网络、DNS、系统代号是否仍被上游支持。";
    return 1
}

repair_sources_menu () 
{ 
    parse_os_release;
    if is_debian_like; then
        apt_repair_menu;
    else
        if is_redhat; then
            rpm_repo_menu;
        else
            echo_warn "当前系统暂不支持自动源修复：$OS_PRETTY_NAME";
            pause_return;
        fi;
    fi
}

require_root () 
{ 
    if [ "$(id -u)" -ne 0 ]; then
        echo_error "请使用 root 运行此脚本。";
        exit 1;
    fi
}

restart_ssh_service () 
{ 
    local svc;
    svc="$(ssh_service_name)";
    echo_info "正在 reload SSH 服务：$svc；失败则 restart。";
    if is_systemd_available; then
        service_reload_or_restart "$svc" || { 
            echo_error "SSH 服务 reload/restart 失败，请检查 systemctl status $svc。";
            return 1
        };
        systemctl is-active "$svc" > /dev/null 2>&1 || { 
            echo_error "SSH 服务未处于 active 状态。";
            return 1
        };
    else
        service "$svc" reload 2> /dev/null || service "$svc" restart 2> /dev/null || { 
            echo_error "非 systemd 环境重载 SSH 失败。";
            return 1
        };
    fi;
    echo_color "SSH 服务已应用配置。"
}

restore_backup_dir () 
{ 
    local dir="$1";
    [ -d "$dir/etc" ] || { 
        echo_warn "未找到可回滚备份：$dir";
        return 1
    };
    cp -a "$dir/etc/ssh/sshd_config" /etc/ssh/sshd_config 2> /dev/null || true;
    if [ -d "$dir/etc/ssh/sshd_config.d" ]; then
        rm -rf /etc/ssh/sshd_config.d;
        cp -a "$dir/etc/ssh/sshd_config.d" /etc/ssh/sshd_config.d;
    fi;
    echo_warn "已从 $dir 回滚 SSH 配置。"
}

restore_regresshion_mitigation () 
{ 
    local backup_dir;
    backup_dir="$(make_backup_dir ssh-regresshion-restore)";
    backup_ssh_tree "$backup_dir";
    set_sshd_kv_effective LoginGraceTime 30;
    set_sshd_kv_effective MaxStartups "10:30:100";
    ssh_apply_with_rollback "regreSSHion 缓解恢复" "$backup_dir"
}

rpm_check_repos () 
{ 
    ui_title "DNF/YUM 源检测";
    show_os_detected;
    local pm;
    pm="$(detect_pkg_manager)";
    [ "$pm" = "dnf" ] || [ "$pm" = "yum" ] || { 
        echo_error "当前不是 DNF/YUM 系统。";
        return 1
    };
    $pm repolist all || true;
    echo;
    $pm -y makecache
}

rpm_enable_crb_like () 
{ 
    local pm;
    parse_os_release;
    pm="$(detect_pkg_manager)";
    pkg_install dnf-plugins-core || pkg_install yum-utils || true;
    case "$OS_ID" in 
        almalinux | rocky | centos)
            $pm config-manager --set-enabled crb 2> /dev/null || $pm config-manager --set-enabled powertools 2> /dev/null || true
        ;;
        ol | olserver | oracle)
            $pm config-manager --set-enabled "ol${OS_MAJOR}_codeready_builder" 2> /dev/null || true
        ;;
        rhel)
            echo_warn "RHEL 需要 subscription-manager 注册并启用 CodeReady Builder，不自动改写 redhat.repo。";
            command -v subscription-manager > /dev/null 2>&1 && subscription-manager status || true
        ;;
        amzn | amazon)
            echo_info "Amazon Linux 不启用 CRB/PowerTools。"
        ;;
    esac
}

rpm_install_epel_safely () 
{ 
    parse_os_release;
    local pm;
    pm="$(detect_pkg_manager)";
    case "$OS_ID" in 
        rhel)
            echo_warn "RHEL 安装 EPEL 前应先注册订阅并启用 CRB。脚本不强行写第三方源。";
            command -v subscription-manager > /dev/null 2>&1 && subscription-manager status || true;
            return 1
        ;;
        amzn | amazon)
            if [ "$OS_MAJOR" = "2" ] && command -v amazon-linux-extras > /dev/null 2>&1; then
                amazon-linux-extras install epel -y || return 1;
            else
                echo_warn "Amazon Linux ${OS_VERSION_ID:-未知} 不自动安装 EPEL，避免混用不兼容第三方源。";
                return 1;
            fi
        ;;
        centos | almalinux | rocky | ol | olserver | oracle)
            rpm_enable_crb_like || true;
            pkg_install epel-release || { 
                echo_warn "epel-release 安装失败，请检查当前发行版官方仓库。";
                return 1
            }
        ;;
        fedora)
            echo_info "Fedora 通常不需要 EPEL。"
        ;;
        *)
            echo_warn "当前发行版不自动安装 EPEL。";
            return 1
        ;;
    esac;
    $pm -y makecache || true
}

rpm_repair_repos () 
{ 
    ui_title "DNF/YUM 源自动修复";
    show_os_detected;
    local pm;
    pm="$(detect_pkg_manager)";
    [ "$pm" = "dnf" ] || [ "$pm" = "yum" ] || { 
        echo_error "当前不是 DNF/YUM 系统。";
        return 1
    };
    case "$OS_ID" in 
        rhel)
            echo_warn "检测到 RHEL。官方仓库依赖 subscription-manager 和有效订阅，本脚本不会改写 redhat.repo。";
            command -v subscription-manager > /dev/null 2>&1 && subscription-manager status || echo_warn "未检测到 subscription-manager。"
        ;;
        centos)
            if echo "$OS_PRETTY_NAME" | grep -qi 'stream'; then
                rpm_enable_crb_like || true;
                $pm -y makecache || return 1;
                echo_color "CentOS Stream 源检测/CRB 启用流程完成。";
            else
                echo_warn "CentOS 非 Stream/EOL 场景差异较大，建议使用官方 vault 或迁移到 Alma/Rocky；本脚本不盲目替换 repo。";
            fi
        ;;
        almalinux | rocky | ol | olserver | oracle | fedora | amzn)
            rpm_enable_crb_like || true;
            $pm -y makecache || return 1;
            echo_color "已完成当前发行版 DNF/YUM 缓存验证。"
        ;;
        *)
            echo_warn "未知红帽系发行版，只执行 makecache，不改 repo。";
            $pm -y makecache
        ;;
    esac
}

rpm_repo_menu () 
{ 
    while true; do
        ui_title "DNF/YUM 源检测与修复";
        ui_option 1 "只检测源可用性（repolist/makecache）";
        ui_option 2 "自动修复/启用可用基础仓库（保守）";
        ui_option 3 "安装/启用 EPEL（按发行版保守处理）";
        ui_back;
        local opt;
        ui_prompt opt;
        case "$opt" in 
            1)
                rpm_check_repos;
                pause_return
            ;;
            2)
                rpm_repair_repos;
                pause_return
            ;;
            3)
                rpm_install_epel_safely;
                pause_return
            ;;
            0)
                return 0
            ;;
            *)
                echo_error "无效选项";
                pause_return
            ;;
        esac;
    done
}

run_cmd_quiet () 
{ 
    "$@" > /dev/null 2>&1
}

run_remote_script_confirm () 
{ 
    local name="$1" url="$2" tmp opt sha;
    ui_title "$name";
    echo_warn "将从以下地址下载并可选执行第三方脚本：$url";
    echo_warn "远程脚本可能修改系统配置，请只在信任来源时继续。";
    ensure_command curl curl || return 1;
    tmp="$(mktemp /tmp/server-toolkit-remote.XXXXXX.sh)" || return 1;
    if ! curl -fsSL --connect-timeout 8 --max-time 60 "$url" -o "$tmp"; then
        rm -f "$tmp";
        echo_error "下载失败：$url";
        return 1;
    fi;
    chmod 600 "$tmp";
    sha="$(sha256sum "$tmp" 2> /dev/null | awk '{print $1}')";
    [ -n "$sha" ] && echo_info "下载文件 SHA256：$sha";
    while true; do
        ui_option 1 "查看前 120 行脚本";
        ui_option 2 "执行脚本";
        ui_option 3 "保留脚本路径并返回";
        ui_back;
        ui_prompt opt;
        case "$opt" in 
            1)
                sed -n '1,120p' "$tmp";
                pause_return
            ;;
            2)
                confirm_action "确认执行 $name？远程脚本可能修改系统配置。" "2" || continue;
                bash "$tmp";
                local rc=$?;
                rm -f "$tmp";
                return "$rc"
            ;;
            3)
                echo_info "已保留临时脚本：$tmp";
                return 0
            ;;
            0)
                rm -f "$tmp";
                return 0
            ;;
            *)
                echo_error "无效选项"
            ;;
        esac;
    done
}

safe_systemctl () 
{ 
    is_systemd_available || return 1;
    systemctl "$@"
}

secure_ssh () 
{ 
    [ -f /etc/ssh/sshd_config ] || { 
        echo_error "找不到 /etc/ssh/sshd_config";
        return 1
    };
    while true; do
        ui_title "SSH 安全性增强向导";
        ui_option 1 "查看当前 SSH 关键配置与冲突项";
        ui_option 2 "一键保守增强（不禁 root、不禁密码、不改端口）";
        ui_option 3 "逐项配置（带说明）";
        ui_back;
        local opt;
        ui_prompt opt;
        case "$opt" in 
            1)
                show_ssh_effective_config;
                pause_return
            ;;
            2)
                ssh_security_recommended;
                pause_return
            ;;
            3)
                ssh_security_custom
            ;;
            0)
                return 0
            ;;
            *)
                echo_error "无效选项";
                pause_return
            ;;
        esac;
    done
}

security_update_core_packages () 
{ 
    ui_title "安全更新核心包";
    pkg_makecache || return 1;
    pkg_install openssh-server openssh-client sudo curl ca-certificates || true;
    pkg_upgrade || true
}

selinux_allow_ssh_port () 
{ 
    local port="$1";
    command -v getenforce > /dev/null 2>&1 || return 0;
    local mode;
    mode="$(getenforce 2> /dev/null || echo Disabled)";
    [ "$mode" = "Disabled" ] && return 0;
    [ "$port" = "22" ] && return 0;
    echo_info "SELinux 当前状态：$mode，准备允许 ssh_port_t 端口 $port。";
    if ! command -v semanage > /dev/null 2>&1; then
        echo_warn "未检测到 semanage，准备安装对应包。";
        pkg_install semanage || { 
            echo_warn "semanage 安装失败，请手动安装 policycoreutils-python-utils 后执行：semanage port -a -t ssh_port_t -p tcp $port";
            return 1
        };
    fi;
    if semanage port -l 2> /dev/null | awk '$1=="ssh_port_t"{print $0}' | grep -Eq "(^|[, ])${port}($|[, ])"; then
        echo_color "SELinux 已允许 SSH 端口 $port。";
        return 0;
    fi;
    if semanage port -a -t ssh_port_t -p tcp "$port" 2> /dev/null; then
        echo_color "已添加 SELinux ssh_port_t 端口：$port";
    else
        if semanage port -m -t ssh_port_t -p tcp "$port" 2> /dev/null; then
            echo_color "已修改 SELinux ssh_port_t 端口：$port";
        else
            echo_warn "SELinux 端口写入失败，请手动执行：semanage port -a -t ssh_port_t -p tcp $port";
            return 1;
        fi;
    fi
}

selinux_status () 
{ 
    if command -v getenforce > /dev/null 2>&1; then
        echo_info "getenforce: $(getenforce 2> /dev/null || true)";
    else
        echo_warn "未检测到 getenforce。Debian/Ubuntu 默认通常未启用 SELinux。";
    fi;
    command -v sestatus > /dev/null 2>&1 && sestatus || true;
    command -v semanage > /dev/null 2>&1 && semanage port -l 2> /dev/null | awk '$1=="ssh_port_t"{print}' || true
}

server_hardening () 
{ 
    while true; do
        ui_title "服务器加固";
        ui_option 1 "一键保守加固（不影响 SSH 登录策略）";
        ui_option 2 "应用保守 sysctl 加固";
        ui_option 3 "CVE-2024-6387 / regreSSHion 临时缓解";
        ui_option 4 "恢复 regreSSHion 临时缓解默认值";
        ui_option 5 "CVE-2026-31431 / Copy Fail 临时缓解";
        ui_option 6 "移除 Copy Fail 临时缓解";
        ui_option 7 "关闭/恢复 unprivileged user namespace";
        ui_option 8 "安全更新核心包";
        ui_option 9 "查看加固状态";
        ui_back;
        local opt;
        ui_prompt opt;
        case "$opt" in 
            1)
                one_click_safe_hardening;
                pause_return
            ;;
            2)
                apply_conservative_sysctl_hardening;
                pause_return
            ;;
            3)
                apply_regresshion_mitigation;
                pause_return
            ;;
            4)
                restore_regresshion_mitigation;
                pause_return
            ;;
            5)
                apply_copy_fail_mitigation;
                pause_return
            ;;
            6)
                remove_copy_fail_mitigation;
                pause_return
            ;;
            7)
                toggle_unpriv_userns;
                pause_return
            ;;
            8)
                security_update_core_packages;
                pause_return
            ;;
            9)
                show_vulnerability_status;
                pause_return
            ;;
            0)
                return 0
            ;;
            *)
                echo_error "无效选项";
                pause_return
            ;;
        esac;
    done
}

service_enable_now () 
{ 
    local svc="$1";
    if ! is_systemd_available; then
        echo_warn "当前环境没有可用 systemd，无法 enable/start $svc。";
        return 1;
    fi;
    systemctl enable --now "$svc"
}

service_reload_or_restart () 
{ 
    local svc="$1";
    if ! is_systemd_available; then
        echo_warn "当前环境没有可用 systemd，无法 reload/restart $svc。";
        return 1;
    fi;
    if systemctl reload "$svc" 2> /dev/null; then
        systemctl is-active "$svc" > /dev/null 2>&1 && return 0;
    fi;
    systemctl restart "$svc" && systemctl is-active "$svc" > /dev/null 2>&1
}

service_restart_safe () 
{ 
    local svc="$1";
    if ! is_systemd_available; then
        echo_warn "当前环境没有可用 systemd，无法重启 $svc。";
        return 1;
    fi;
    systemctl restart "$svc" && systemctl is-active "$svc" > /dev/null 2>&1
}

set_sshd_kv () 
{ 
    set_sshd_kv_effective "$@"
}

set_sshd_kv_effective () 
{ 
    local key="$1" val="$2";
    sshd_prepare_effective_key "$key" || return 1;
    sshd_dropin_set_key "$key" "$val"
}

setup_cron_reboot () 
{ 
    local interval marker tmpcron reboot_cmd;
    ui_title "设置定时重启";
    echo_warn "定时重启会影响在线业务，建议确认业务可自动恢复。";
    read -r -p "请输入每隔多少小时重启一次（1-720，输入 q 取消）: " interval;
    [[ "$interval" =~ ^[Qq]$ ]] && { 
        echo_warn "已取消。";
        return 0
    };
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ] || [ "$interval" -gt 720 ]; then
        echo_error "请输入 1-720 的有效小时数。";
        return 1;
    fi;
    ensure_crontab_available || return 1;
    reboot_cmd="$(command -v systemctl 2> /dev/null && echo 'systemctl reboot' || command -v reboot 2> /dev/null || echo /sbin/reboot)";
    confirm_yes "确认写入每 ${interval} 小时自动重启任务？" || return 0;
    marker="# server-toolkit: reboot";
    tmpcron="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || { 
        echo_error "创建临时 crontab 文件失败。";
        return 1
    };
    crontab -l 2> /dev/null | grep -v "$marker" > "$tmpcron" || true;
    echo "0 */$interval * * * $reboot_cmd $marker" >> "$tmpcron";
    if crontab "$tmpcron"; then
        rm -f "$tmpcron";
        echo_color "已设置每隔 $interval 小时自动重启系统。";
    else
        rm -f "$tmpcron";
        echo_error "写入 crontab 失败。";
        return 1;
    fi
}

setup_fail2ban_default () 
{ 
    ui_title "安装/配置 Fail2Ban";
    pkg_install fail2ban python3-systemd || pkg_install fail2ban || return 1;
    local backup_dir ssh_ports;
    backup_dir="$(make_backup_dir fail2ban)";
    backup_path_to_dir /etc/fail2ban "$backup_dir";
    ssh_ports="$(get_current_ssh_ports)";
    [ -n "$ssh_ports" ] || ssh_ports="22";
    fail2ban_write_base_local INFO;
    fail2ban_write_sshd_jail_v22 "$ssh_ports" 3600 600 3 "" "$backup_dir";
    if fail2ban_validate_and_restart; then
        echo_color "Fail2Ban 已配置完成，SSH 端口：$ssh_ports";
    else
        echo_error "Fail2Ban 启动失败，开始回滚。";
        [ -d "$backup_dir/etc/fail2ban" ] && { 
            rm -rf /etc/fail2ban;
            cp -a "$backup_dir/etc/fail2ban" /etc/fail2ban
        };
        return 1;
    fi
}

setup_nezha_agent_restart_cron () 
{ 
    local interval marker tmpcron;
    read -r -p "请输入每隔多少小时重启 nezha-agent（1-720，输入 q 取消）: " interval;
    [[ "$interval" =~ ^[Qq]$ ]] && { 
        echo_warn "已取消。";
        return 0
    };
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ] || [ "$interval" -gt 720 ]; then
        echo_error "请输入 1-720 的有效小时数。";
        return 1;
    fi;
    ensure_crontab_available || return 1;
    marker="# server-toolkit: nezha-agent-restart";
    tmpcron="$(mktemp /tmp/server-toolkit-cron.XXXXXX)" || { 
        echo_error "创建临时 crontab 文件失败。";
        return 1
    };
    crontab -l 2> /dev/null | grep -v "$marker" > "$tmpcron" || true;
    echo "0 */$interval * * * systemctl restart nezha-agent >/dev/null 2>&1 $marker" >> "$tmpcron";
    crontab "$tmpcron" && rm -f "$tmpcron" && echo_color "已设置每隔 $interval 小时自动重启 nezha-agent。" || { 
        rm -f "$tmpcron";
        echo_error "写入 crontab 失败。";
        return 1
    }
}

show_apt_sources_current () 
{ 
    ui_title "当前 APT 源";
    if [ -f /etc/apt/sources.list ]; then
        echo_info "/etc/apt/sources.list";
        sed -n '1,220p' /etc/apt/sources.list;
    else
        echo_warn "未找到 /etc/apt/sources.list";
    fi;
    echo;
    echo_info "/etc/apt/sources.list.d/";
    if ls /etc/apt/sources.list.d/* > /dev/null 2>&1; then
        for f in /etc/apt/sources.list.d/*;
        do
            [ -f "$f" ] || continue;
            echo_dim "----- $f -----";
            sed -n '1,120p' "$f";
        done;
    else
        echo_warn "未发现 sources.list.d 条目。";
    fi
}

show_ipv6_status () 
{ 
    echo_info "sysctl IPv6 状态：";
    sysctl net.ipv6.conf.all.disable_ipv6 2> /dev/null || true;
    sysctl net.ipv6.conf.default.disable_ipv6 2> /dev/null || true;
    sysctl net.ipv6.conf.lo.disable_ipv6 2> /dev/null || true;
    echo_info "IPv6 地址：";
    ip -6 addr 2> /dev/null || echo_warn "未检测到 ip 命令。";
    echo_info "GRUB IPv6 参数：";
    grep -n 'ipv6.disable' /etc/default/grub 2> /dev/null || echo "未发现 ipv6.disable 参数。";
    command -v grubby > /dev/null 2>&1 && grubby --info=ALL 2> /dev/null | grep -E '^(kernel|args)=' | grep -C1 'ipv6.disable' || true
}

show_os_detected () 
{ 
    parse_os_release;
    echo_info "系统识别：$OS_PRETTY_NAME";
    echo_info "ID=$OS_ID ID_LIKE=${OS_ID_LIKE:-无} VERSION_ID=${OS_VERSION_ID:-无} CODENAME=${OS_VERSION_CODENAME:-无}"
}

show_ssh_effective_config () 
{ 
    ui_title "SSH 最终生效配置";
    if ! command -v sshd > /dev/null 2>&1; then
        echo_warn "未找到 sshd 命令。";
        return 1;
    fi;
    sshd -T 2> /dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitemptypasswords|maxauthtries|logingracetime|usedns|x11forwarding|allowtcpforwarding|clientaliveinterval|clientalivecountmax|maxstartups) ' || true;
    echo;
    sshd_report_conflicts
}

show_system_info () 
{ 
    ui_title "服务器基本信息";
    parse_os_release;
    local hostname kernel arch cpu_model cpu_cores cpu_freq loadavg mem_total mem_avail mem_used mem_pct swap_total swap_free swap_used swap_pct disk_total disk_used disk_pct iface rx tx algo qdisc dns uptime_sec days hours mins pub;
    hostname="$(hostname 2> /dev/null || echo '-')";
    kernel="$(uname -r 2> /dev/null || echo '-')";
    arch="$(uname -m 2> /dev/null || echo '-')";
    cpu_model="$(awk -F: '/model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2> /dev/null)";
    [ -z "$cpu_model" ] && cpu_model="$(command -v lscpu > /dev/null 2>&1 && lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')";
    cpu_cores="$(command -v nproc > /dev/null 2>&1 && nproc || echo '-')";
    cpu_freq="$(awk -F: '/cpu MHz/ {mhz=$2; gsub(/^[ \t]+/,"",mhz); printf "%.1f GHz", mhz/1000; exit}' /proc/cpuinfo 2> /dev/null)";
    [ -z "$cpu_freq" ] && cpu_freq="-";
    loadavg="$(awk '{print $1", "$2", "$3}' /proc/loadavg 2> /dev/null || echo '-')";
    mem_total="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2> /dev/null || echo 0)";
    mem_avail="$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2> /dev/null || echo 0)";
    [ "$mem_total" -gt 0 ] 2> /dev/null || mem_total=0;
    [ "$mem_avail" -gt 0 ] 2> /dev/null || mem_avail=0;
    mem_used=$((mem_total-mem_avail));
    [ "$mem_used" -lt 0 ] && mem_used=0;
    mem_pct="$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{if(t>0)printf "%.2f",u/t*100;else printf "0"}')";
    swap_total="$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2> /dev/null || echo 0)";
    swap_free="$(awk '/SwapFree/ {print $2}' /proc/meminfo 2> /dev/null || echo 0)";
    swap_used=$((swap_total-swap_free));
    [ "$swap_used" -lt 0 ] && swap_used=0;
    swap_pct="$(awk -v u="$swap_used" -v t="$swap_total" 'BEGIN{if(t>0)printf "%.0f",u/t*100;else printf "0"}')";
    disk_used="$(df -h / 2> /dev/null | awk 'NR==2{print $3}')";
    disk_total="$(df -h / 2> /dev/null | awk 'NR==2{print $2}')";
    disk_pct="$(df -h / 2> /dev/null | awk 'NR==2{print $5}')";
    iface="$(get_default_iface 2> /dev/null || true)";
    [ -z "$iface" ] && iface="$(ls /sys/class/net 2> /dev/null | grep -v '^lo$' | head -n1)";
    if [ -n "$iface" ] && [ -e "/sys/class/net/$iface/statistics/rx_bytes" ]; then
        rx="$(cat "/sys/class/net/$iface/statistics/rx_bytes")";
        tx="$(cat "/sys/class/net/$iface/statistics/tx_bytes")";
    else
        rx=0;
        tx=0;
    fi;
    algo="$(sysctl -n net.ipv4.tcp_congestion_control 2> /dev/null || echo '-')";
    qdisc="$(sysctl -n net.core.default_qdisc 2> /dev/null || echo '-')";
    dns="$(grep -E '^nameserver ' /etc/resolv.conf 2> /dev/null | awk '{print $2}' | paste -sd' ' -)";
    [ -z "$dns" ] && dns="-";
    uptime_sec="$(awk '{print int($1)}' /proc/uptime 2> /dev/null || echo 0)";
    days=$((uptime_sec/86400));
    hours=$((uptime_sec%86400/3600));
    mins=$((uptime_sec%3600/60));
    pub="$(public_ip_detect)";
    printf "%-18s %s\n" "主机名:" "$hostname";
    printf "%-18s %s\n" "系统版本:" "$OS_PRETTY_NAME";
    printf "%-18s %s\n" "Linux内核:" "$kernel";
    printf "%-18s %s\n" "CPU架构:" "$arch";
    printf "%-18s %s\n" "CPU型号:" "${cpu_model:-未知}";
    printf "%-18s %s / %s\n" "CPU核心/频率:" "$cpu_cores" "$cpu_freq";
    printf "%-18s %s\n" "系统负载:" "$loadavg";
    printf "%-18s %s/%s (%s%%)\n" "物理内存:" "$(awk -v k="$mem_used" 'BEGIN{printf "%.2fM",k/1024}')" "$(awk -v k="$mem_total" 'BEGIN{printf "%.2fM",k/1024}')" "$mem_pct";
    printf "%-18s %s/%s (%s%%)\n" "Swap:" "$(awk -v k="$swap_used" 'BEGIN{printf "%.0fM",k/1024}')" "$(awk -v k="$swap_total" 'BEGIN{printf "%.0fM",k/1024}')" "$swap_pct";
    printf "%-18s %s/%s (%s)\n" "硬盘占用:" "${disk_used:-未知}" "${disk_total:-未知}" "${disk_pct:-未知}";
    printf "%-18s %s / %s\n" "总接收/发送:" "$(format_bytes "$rx")" "$(format_bytes "$tx")";
    printf "%-18s %s %s\n" "网络算法:" "$algo" "$qdisc";
    printf "%-18s %s\n" "DNS地址:" "$dns";
    printf "%-18s %s\n" "公网地址:" "$pub";
    printf "%-18s %s天 %s时 %s分\n" "运行时长:" "$days" "$hours" "$mins"
}

show_timesync_diagnostics () 
{ 
    echo_info "时间同步诊断：";
    timedatectl status 2> /dev/null || true;
    timedatectl show-timesync --all 2> /dev/null || true;
    systemd-analyze cat-config systemd/timesyncd.conf --tldr 2> /dev/null || true;
    chronyc tracking 2> /dev/null || true;
    chronyc sources -v 2> /dev/null || true
}

show_vulnerability_status () 
{ 
    ui_title "加固状态查看";
    echo_info "OpenSSH 版本：";
    ssh -V 2>&1 || true;
    command -v sshd > /dev/null 2>&1 && sshd -V 2>&1 || true;
    echo_info "内核版本：$(uname -r 2> /dev/null)";
    echo_info "regreSSHion 相关 SSH 生效项：";
    sshd_effective_config | grep -Ei '^(logingracetime|maxstartups) ' || true;
    echo_info "Copy Fail 临时缓解：";
    [ -f "$(copy_fail_conf_path)" ] && cat "$(copy_fail_conf_path)" || echo "未启用。";
    echo_info "相关模块加载状态：";
    lsmod 2> /dev/null | grep -E '^(algif_aead|authencesn)' || echo "未看到相关模块已加载。";
    echo_info "sysctl 加固文件：";
    [ -f /etc/sysctl.d/98-server-toolkit-hardening.conf ] && cat /etc/sysctl.d/98-server-toolkit-hardening.conf || echo "未启用。"
}

ssh_apply_with_rollback () 
{ 
    local verify_desc="$1" backup_dir="$2";
    if ! test_sshd_config; then
        echo_error "sshd -t 失败，开始回滚。";
        restore_backup_dir "$backup_dir" || true;
        test_sshd_config || true;
        return 1;
    fi;
    if ! restart_ssh_service; then
        echo_error "SSH 服务应用失败，开始回滚。";
        restore_backup_dir "$backup_dir" || true;
        restart_ssh_service || true;
        return 1;
    fi;
    echo_color "$verify_desc 已应用。"
}

ssh_security_custom () 
{ 
    while true; do
        ui_title "SSH 安全性增强 · 逐项配置";
        ui_option 1 "MaxAuthTries：限制认证失败次数";
        ui_option 2 "LoginGraceTime：限制登录认证窗口";
        ui_option 3 "PermitEmptyPasswords：禁止空密码";
        ui_option 4 "UseDNS：关闭反向 DNS 查询";
        ui_option 5 "X11Forwarding：关闭 X11 转发";
        ui_option 6 "AllowTcpForwarding：SSH 隧道开关";
        ui_option 7 "ClientAliveInterval/CountMax：空闲连接保活策略";
        ui_option 8 "查看当前 SSH 生效配置";
        ui_back;
        local opt v a b backup_dir;
        ui_prompt opt;
        case "$opt" in 
            1)
                read -r -p "MaxAuthTries（建议 3）: " v;
                [[ "$v" =~ ^[0-9]+$ ]] && backup_dir="$(make_backup_dir ssh-custom)" && backup_ssh_tree "$backup_dir" && set_sshd_kv_effective MaxAuthTries "$v" && ssh_apply_with_rollback "MaxAuthTries" "$backup_dir"
            ;;
            2)
                read -r -p "LoginGraceTime 秒数（建议 30）: " v;
                [[ "$v" =~ ^[0-9]+$ ]] && backup_dir="$(make_backup_dir ssh-custom)" && backup_ssh_tree "$backup_dir" && set_sshd_kv_effective LoginGraceTime "$v" && ssh_apply_with_rollback "LoginGraceTime" "$backup_dir"
            ;;
            3)
                backup_dir="$(make_backup_dir ssh-custom)";
                backup_ssh_tree "$backup_dir";
                set_sshd_kv_effective PermitEmptyPasswords no && ssh_apply_with_rollback "PermitEmptyPasswords" "$backup_dir"
            ;;
            4)
                backup_dir="$(make_backup_dir ssh-custom)";
                backup_ssh_tree "$backup_dir";
                set_sshd_kv_effective UseDNS no && ssh_apply_with_rollback "UseDNS" "$backup_dir"
            ;;
            5)
                backup_dir="$(make_backup_dir ssh-custom)";
                backup_ssh_tree "$backup_dir";
                set_sshd_kv_effective X11Forwarding no && ssh_apply_with_rollback "X11Forwarding" "$backup_dir"
            ;;
            6)
                read -r -p "AllowTcpForwarding 设置为 yes/no: " v;
                [[ "$v" = "yes" || "$v" = "no" ]] && backup_dir="$(make_backup_dir ssh-custom)" && backup_ssh_tree "$backup_dir" && set_sshd_kv_effective AllowTcpForwarding "$v" && ssh_apply_with_rollback "AllowTcpForwarding" "$backup_dir"
            ;;
            7)
                read -r -p "ClientAliveInterval（建议 300）: " a;
                read -r -p "ClientAliveCountMax（建议 2）: " b;
                if [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]]; then
                    backup_dir="$(make_backup_dir ssh-custom)";
                    backup_ssh_tree "$backup_dir";
                    set_sshd_kv_effective ClientAliveInterval "$a";
                    set_sshd_kv_effective ClientAliveCountMax "$b";
                    ssh_apply_with_rollback "ClientAlive" "$backup_dir";
                fi
            ;;
            8)
                show_ssh_effective_config;
                pause_return
            ;;
            0)
                return 0
            ;;
            *)
                echo_error "无效选项"
            ;;
        esac;
    done
}

ssh_security_recommended () 
{ 
    local backup_dir;
    backup_dir="$(make_backup_dir ssh-secure)";
    backup_ssh_tree "$backup_dir";
    echo_info "应用保守增强：不禁 root、不禁密码、不改端口。";
    set_sshd_kv_effective "LoginGraceTime" "30";
    set_sshd_kv_effective "MaxAuthTries" "3";
    set_sshd_kv_effective "PermitEmptyPasswords" "no";
    set_sshd_kv_effective "UseDNS" "no";
    set_sshd_kv_effective "X11Forwarding" "no";
    set_sshd_kv_effective "PermitUserEnvironment" "no";
    set_sshd_kv_effective "ClientAliveInterval" "300";
    set_sshd_kv_effective "ClientAliveCountMax" "2";
    ssh_apply_with_rollback "SSH 保守安全增强" "$backup_dir"
}

ssh_service_name () 
{ 
    if is_systemd_available; then
        if systemctl list-unit-files 2> /dev/null | grep -q '^ssh\.service'; then
            echo "ssh";
            return;
        fi;
        if systemctl list-unit-files 2> /dev/null | grep -q '^sshd\.service'; then
            echo "sshd";
            return;
        fi;
    fi;
    if [ -x /etc/init.d/ssh ]; then
        echo "ssh";
    else
        echo "sshd";
    fi
}

sshd_check_effective_key () 
{ 
    local key="$1" expected="$2" actual;
    actual="$(sshd_effective_config | awk -v k="$(echo "$key" | tr '[:upper:]' '[:lower:]')" '$1==k{print $2; exit}')";
    if [ "$actual" = "$expected" ]; then
        echo_color "sshd -T 验证通过：$key=$expected";
        return 0;
    fi;
    echo_error "sshd -T 验证失败：$key 期望 $expected，实际 ${actual:-空}";
    return 1
}

sshd_check_listening_port () 
{ 
    local port="$1";
    sleep 1;
    if command -v ss > /dev/null 2>&1; then
        ss -lnt 2> /dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$" && return 0;
    else
        if command -v netstat > /dev/null 2>&1; then
            netstat -lnt 2> /dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$" && return 0;
        fi;
    fi;
    echo_warn "未确认到端口 $port 正在监听；请执行 ss -lntp | grep ':$port' 手动确认。";
    return 1
}

sshd_comment_key_in_file () 
{ 
    local file="$1" key="$2" tmp;
    [ -f "$file" ] || return 0;
    tmp="$(mktemp /tmp/server-toolkit-sshd-comment.XXXXXX)" || return 1;
    awk -v key="$key" '
    BEGIN { IGNORECASE=1; inmatch=0; changed=0; pat="^[[:space:]]*" key "[[:space:]]+" }
    /^[[:space:]]*Match[[:space:]]+/ { inmatch=1 }
    !inmatch && $0 ~ pat { print "# server-toolkit disabled conflicting: " $0; changed=1; next }
    { print }
    END { if (changed) exit 2; else exit 0 }
  ' "$file" > "$tmp";
    local rc=$?;
    if [ "$rc" -eq 2 ]; then
        backup_file "$file";
        cat "$tmp" > "$file";
    fi;
    rm -f "$tmp";
    return 0
}

sshd_dropin_set_key () 
{ 
    local key="$1" val="$2" file;
    file="$(sshd_toolkit_dropin)";
    mkdir -p "$(dirname "$file")";
    touch "$file";
    if grep -Eiq "^[[:space:]]*${key}[[:space:]]+" "$file"; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]].*|${key} ${val}|Ig" "$file";
    else
        printf '%s %s\n' "$key" "$val" >> "$file";
    fi
}

sshd_effective_config () 
{ 
    if command -v sshd > /dev/null 2>&1; then
        sshd -T 2> /dev/null;
    else
        return 1;
    fi
}

sshd_ensure_include () 
{ 
    local main first_non_comment;
    main="$(sshd_main_config)";
    [ -f "$main" ] || { 
        echo_error "找不到 $main";
        return 1
    };
    mkdir -p /etc/ssh/sshd_config.d;
    first_non_comment="$(awk 'NF && $1 !~ /^#/ {print NR":"$0; exit}' "$main" 2> /dev/null || true)";
    if ! printf '%s\n' "$first_non_comment" | grep -Eq 'Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf'; then
        backup_file "$main";
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$main";
        echo_info "已在 sshd_config 顶部加入 Include /etc/ssh/sshd_config.d/*.conf，确保 toolkit drop-in 优先解析。";
    fi
}

sshd_find_include_files () 
{ 
    local dir="/etc/ssh/sshd_config.d";
    [ -d "$dir" ] || return 0;
    find "$dir" -maxdepth 1 -type f -name '*.conf' | sort
}

sshd_main_config () 
{ 
    echo "/etc/ssh/sshd_config"
}

sshd_prepare_effective_key () 
{ 
    local key="$1" file;
    sshd_ensure_include || return 1;
    sshd_comment_key_in_file "$(sshd_main_config)" "$key";
    while IFS= read -r file; do
        [ "$file" = "$(sshd_toolkit_dropin)" ] && continue;
        sshd_comment_key_in_file "$file" "$key";
    done < <(sshd_find_include_files)
}

sshd_report_conflicts () 
{ 
    local key="${1:-}";
    echo_info "SSH 配置冲突扫描：${key:-关键项}";
    local pattern='^(Port|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitRootLogin|PubkeyAuthentication)[[:space:]]+';
    [ -n "$key" ] && pattern="^${key}[[:space:]]+";
    grep -RInEi "$pattern" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2> /dev/null || echo_color "未发现显式冲突项。"
}

sshd_set_ports_dropin () 
{ 
    local ports_csv="$1" file p seen="";
    file="$(sshd_toolkit_dropin)";
    mkdir -p "$(dirname "$file")";
    touch "$file";
    sed -i -E '/^[[:space:]]*Port[[:space:]]+/Id' "$file";
    for p in ${ports_csv//,/ };
    do
        if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] && ! echo ",$seen," | grep -q ",$p,"; then
            printf 'Port %s\n' "$p" >> "$file";
            seen="${seen:+$seen,}$p";
        fi;
    done;
    [ -n "$seen" ] || { 
        echo_error "没有可写入的 SSH 端口。";
        return 1
    }
}

sshd_toolkit_dropin () 
{ 
    echo "/etc/ssh/sshd_config.d/00-server-toolkit.conf"
}

sysctl_key_exists () 
{ 
    sysctl -n "$1" > /dev/null 2>&1
}

test_sshd_config () 
{ 
    command -v sshd > /dev/null 2>&1 || { 
        echo_error "未检测到 sshd 命令。";
        return 1
    };
    sshd -t
}

time_sync () 
{ 
    ui_title "时间同步 · systemd-timesyncd / chrony";
    show_os_detected;
    local ntp custom method;
    ntp="time.google.com time.cloudflare.com";
    read -r -p "NTP 源，直接回车使用默认 [$ntp]，或输入自定义多个域名/IP: " custom;
    if [ -n "$custom" ]; then
        if validate_ntp_servers "$custom"; then
            ntp="$custom";
        else
            echo_error "自定义 NTP 源无效，已取消。";
            return 1;
        fi;
    fi;
    if is_container_env; then
        echo_warn "检测到容器环境。容器通常没有 CAP_SYS_TIME，时间应由宿主机同步。";
    fi;
    if ! has_cap_sys_time; then
        echo_warn "未确认当前环境具备 CAP_SYS_TIME。若是 LXC/Docker/OpenVZ，校时可能被内核拒绝。";
    fi;
    parse_os_release;
    if ! is_systemd_available; then
        echo_warn "当前无 systemd，跳过 systemd-timesyncd/chrony 服务管理，只尝试一次性校时。";
        time_sync_one_shot_fallback "$ntp" || true;
        return 0;
    fi;
    if is_debian_like; then
        echo_info "Debian/Ubuntu 系：优先 systemd-timesyncd；失败再使用 chrony。Debian 13/Trixie 不再依赖 ntpdate。";
        if time_sync_configure_timesyncd "$ntp"; then
            method="systemd-timesyncd";
        else
            if time_sync_configure_chrony "$ntp"; then
                method="chrony";
            fi;
        fi;
    else
        echo_info "RedHat/Fedora/Amazon 系：优先 chrony/chronyd。";
        time_sync_configure_chrony "$ntp" && method="chrony";
    fi;
    [ -n "${method:-}" ] && echo_color "时间同步配置完成：$method" || echo_warn "时间同步配置未完全成功，请查看上方错误。"
}

time_sync_configure_chrony () 
{ 
    local ntp="${1:-}" conf service line tmp;
    validate_ntp_servers "$ntp" || return 1;
    command -v chronyd > /dev/null 2>&1 || pkg_install chrony || return 1;
    parse_os_release;
    if [ -f /etc/chrony/chrony.conf ] || [ -d /etc/chrony ] || is_debian_like; then
        conf="/etc/chrony/chrony.conf";
        service="chrony";
    else
        conf="/etc/chrony.conf";
        service="chronyd";
    fi;
    if is_systemd_available; then
        if systemctl list-unit-files 2> /dev/null | grep -q '^chronyd\.service'; then
            service="chronyd";
        fi;
        if systemctl list-unit-files 2> /dev/null | grep -q '^chrony\.service'; then
            service="chrony";
        fi;
    fi;
    mkdir -p "$(dirname "$conf")";
    touch "$conf";
    backup_file "$conf";
    tmp="$(mktemp /tmp/server-toolkit-chrony.XXXXXX)" || return 1;
    sed '/server-toolkit v2\.3 BEGIN/,/server-toolkit v2\.3 END/d; /server-toolkit v2\.2 BEGIN/,/server-toolkit v2\.2 END/d' "$conf" > "$tmp";
    { 
        cat "$tmp";
        echo "";
        echo "# server-toolkit v2.3 BEGIN";
        for line in $ntp;
        do
            echo "server $line iburst";
        done;
        echo "makestep 1.0 3";
        echo "# server-toolkit v2.3 END"
    } > "$conf";
    rm -f "$tmp";
    if is_systemd_available && systemctl is-active systemd-timesyncd > /dev/null 2>&1; then
        echo_warn "检测到 systemd-timesyncd 正在运行。多个 NTP 客户端同时运行可能争用时间同步。";
        if confirm_action "是否安全停用 systemd-timesyncd，改用 chrony？" "2"; then
            systemctl disable --now systemd-timesyncd || echo_warn "停用 systemd-timesyncd 失败，请手动检查。";
        fi;
    fi;
    if is_systemd_available; then
        systemctl enable --now "$service" 2> /dev/null || systemctl enable --now chronyd 2> /dev/null || systemctl enable --now chrony 2> /dev/null || true;
        systemctl restart "$service" 2> /dev/null || systemctl restart chronyd 2> /dev/null || systemctl restart chrony 2> /dev/null || { 
            echo_error "chrony 服务启动/重启失败。";
            return 1
        };
    else
        service "$service" restart 2> /dev/null || service chronyd restart 2> /dev/null || service chrony restart 2> /dev/null || { 
            echo_error "chrony 服务启动/重启失败。";
            return 1
        };
    fi;
    echo_color "已配置 chrony：$conf / $service。";
    show_timesync_diagnostics
}

time_sync_configure_timesyncd () 
{ 
    local ntp="${1:-}";
    local conf_dir="/etc/systemd/timesyncd.conf.d";
    local conf="${conf_dir}/server-toolkit.conf";
    validate_ntp_servers "$ntp" || return 1;
    if ! is_systemd_available; then
        echo_warn "当前环境没有可用 systemd，无法配置 systemd-timesyncd。";
        return 1;
    fi;
    ensure_command timedatectl systemd || true;
    if ! command -v timedatectl > /dev/null 2>&1; then
        echo_warn "未检测到 timedatectl，无法使用 systemd-timesyncd。";
        return 1;
    fi;
    if ! systemctl list-unit-files 2> /dev/null | grep -q '^systemd-timesyncd\.service'; then
        pkg_install systemd-timesyncd || true;
    fi;
    if ! systemctl list-unit-files 2> /dev/null | grep -q '^systemd-timesyncd\.service'; then
        echo_warn "未检测到 systemd-timesyncd.service。";
        return 1;
    fi;
    mkdir -p "$conf_dir";
    backup_file "$conf";
    cat > "$conf" <<EOF
# server-toolkit v2.3: systemd-timesyncd NTP
[Time]
NTP=$ntp
FallbackNTP=time.google.com time.cloudflare.com
EOF

    time_sync_stop_conflicting_clients timesyncd;
    timedatectl set-ntp true || echo_warn "timedatectl set-ntp true 失败，继续尝试启动 timesyncd。";
    systemctl enable --now systemd-timesyncd || { 
        echo_error "启动 systemd-timesyncd 失败。";
        return 1
    };
    systemctl restart systemd-timesyncd || { 
        echo_error "重启 systemd-timesyncd 失败。";
        return 1
    };
    echo_color "已配置 systemd-timesyncd。";
    show_timesync_diagnostics
}

time_sync_one_shot_fallback () 
{ 
    local ntp="${1:-}" s first;
    validate_ntp_servers "$ntp" || return 1;
    first="$(echo "$ntp" | awk '{print $1}')";
    if command -v chronyd > /dev/null 2>&1; then
        echo_info "尝试 chronyd -q 一次性校时...";
        chronyd -q "server $first iburst" && return 0;
    fi;
    if command -v ntpdate > /dev/null 2>&1; then
        for s in $ntp;
        do
            ntpdate -u "$s" && return 0;
        done;
    fi;
    if command -v sntp > /dev/null 2>&1; then
        for s in $ntp;
        do
            sntp -S "$s" && return 0;
        done;
    fi;
    echo_warn "没有可用的一次性校时工具。";
    return 1
}

time_sync_stop_conflicting_clients () 
{ 
    local target="${1:-}" svc;
    [ "$target" = "timesyncd" ] || return 0;
    for svc in chrony chronyd ntp ntpd;
    do
        if is_systemd_available && systemctl is-active "$svc" > /dev/null 2>&1; then
            echo_warn "检测到 ${svc} 正在运行。多个 NTP 客户端同时运行可能争用时间同步。";
            if confirm_action "是否安全停用 ${svc}，改用 systemd-timesyncd？" "2"; then
                systemctl disable --now "$svc" || echo_warn "停用 ${svc} 失败，请稍后手动检查。";
            fi;
        fi;
    done
}

toggle_password_login () 
{ 
    ui_title "密码登录开关";
    ui_option 1 "开启密码登录";
    ui_option 2 "关闭密码登录（会先检查 authorized_keys）";
    ui_back;
    local opt user backup_dir;
    ui_prompt opt;
    case "$opt" in 
        1)
            backup_dir="$(make_backup_dir ssh-passwd-on)";
            backup_ssh_tree "$backup_dir";
            set_sshd_kv_effective "PasswordAuthentication" "yes";
            set_sshd_kv_effective "KbdInteractiveAuthentication" "yes";
            set_sshd_kv_effective "ChallengeResponseAuthentication" "yes";
            ssh_apply_with_rollback "开启密码登录" "$backup_dir" && sshd_check_effective_key PasswordAuthentication yes || true
        ;;
        2)
            read -r -p "请输入已确认可用密钥登录的用户名（默认 root）: " user;
            user="${user:-root}";
            check_authorized_keys_safe "$user" || return 1;
            confirm_yes "关闭密码登录可能导致无法登录。确认已经另开终端测试密钥登录成功？" || { 
                echo_warn "已取消。";
                return 0
            };
            backup_dir="$(make_backup_dir ssh-passwd-off)";
            backup_ssh_tree "$backup_dir";
            set_sshd_kv_effective "PasswordAuthentication" "no";
            set_sshd_kv_effective "KbdInteractiveAuthentication" "no";
            set_sshd_kv_effective "ChallengeResponseAuthentication" "no";
            ssh_apply_with_rollback "关闭密码登录" "$backup_dir" && sshd_check_effective_key PasswordAuthentication no || true
        ;;
        0)
            return 0
        ;;
        *)
            echo_error "无效选项"
        ;;
    esac
}

toggle_unpriv_userns () 
{ 
    local conf="/etc/sysctl.d/97-server-toolkit-userns.conf" opt;
    ui_title "非特权 user namespace";
    echo_warn "关闭 unprivileged user namespace 可能影响 rootless Docker、Chrome、Snap、部分容器。";
    ui_option 1 "关闭（降低部分本地提权攻击面）";
    ui_option 2 "恢复开启";
    ui_back;
    ui_prompt opt;
    case "$opt" in 
        1)
            confirm_yes "确认关闭？" || return 0;
            backup_file "$conf";
            echo 'kernel.unprivileged_userns_clone=0' > "$conf";
            sysctl -p "$conf" || true
        ;;
        2)
            backup_file "$conf";
            echo 'kernel.unprivileged_userns_clone=1' > "$conf";
            sysctl -p "$conf" || true
        ;;
        0)
            return 0
        ;;
        *)
            echo_error "无效选项"
        ;;
    esac
}

ufw_active () 
{ 
    command -v ufw > /dev/null 2>&1 && ufw status 2> /dev/null | grep -qi '^Status: active'
}

ui_back () 
{ 
    printf "  \e[1;31m%-4s\e[0m %s\n" "0)" "返回"
}

ui_hr () 
{ 
    printf "\e[1;36m%s\e[0m\n" "$UI_LINE"
}

ui_option () 
{ 
    local num="$1";
    local text="$2";
    printf "  \e[1;32m%-4s\e[0m %s\n" "${num})" "$text"
}

ui_prompt () 
{ 
    read -r -p "请选择: " "$1"
}

ui_title () 
{ 
    echo;
    ui_hr;
    printf "\e[1;35m  %s\e[0m\n" "$1";
    ui_hr
}

update_grub_ipv6_param () 
{ 
    local mode="$1" gf out;
    is_container_env && { 
        echo_warn "容器环境跳过 GRUB 修改。";
        return 0
    };
    gf="$(grub_file_detect)";
    if [ -n "$gf" ]; then
        backup_file "$gf";
        if [ "$mode" = "disable" ]; then
            grub_cmdline_add_param "$gf" "ipv6.disable=1";
        else
            grub_cmdline_remove_param "$gf" "ipv6.disable=1";
        fi;
    else
        echo_warn "未找到 /etc/default/grub。";
    fi;
    if command -v grubby > /dev/null 2>&1; then
        if [ "$mode" = "disable" ]; then
            grubby --update-kernel=ALL --args="ipv6.disable=1" || true;
        else
            grubby --update-kernel=ALL --remove-args="ipv6.disable=1" || true;
        fi;
        return 0;
    fi;
    if command -v update-grub > /dev/null 2>&1; then
        update-grub || true;
    else
        if command -v grub2-mkconfig > /dev/null 2>&1; then
            while IFS= read -r out; do
                [ -n "$out" ] && grub2-mkconfig -o "$out" || true;
            done < <(grub_cfg_outputs);
        else
            echo_warn "未检测到 update-grub/grub2-mkconfig/grubby，请重启前手动更新 GRUB。";
        fi;
    fi
}

validate_fail2ban_ignoreip () 
{ 
    local input="${1:-}" item;
    [ -z "$input" ] && return 0;
    for item in $input;
    do
        if ! [[ "$item" =~ ^[0-9A-Fa-f:.\/]+$ ]]; then
            echo_error "ignoreip 包含不允许的字符：$item";
            return 1;
        fi;
    done;
    return 0
}

validate_ntp_servers () 
{ 
    local input="${1:-}" item;
    [ -n "$input" ] || return 1;
    for item in $input;
    do
        if ! [[ "$item" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
            echo_error "NTP 源包含不允许的字符：$item";
            return 1;
        fi;
        case "$item" in 
            -* | *..* | *::*::*)
                echo_error "NTP 源格式可疑：$item";
                return 1
            ;;
        esac;
    done;
    return 0
}

version_banner () 
{ 
    echo "server-toolkit ${SERVER_TOOLKIT_VERSION:-v2.3}"
}

write_debian_sources () 
{ 
    local base="$1" secbase="$2" code="$3" label="$4" archive_mode="$5";
    local file="/etc/apt/sources.list" components sec_ref sec_final sec_suite;
    components="$(debian_components_by_codename "$code")";
    backup_file "$file";
    apt_disable_conflicting_distro_sources;
    apt_write_header "$file" "Debian" "$label" "$base";
    if ! apt_add_deb_line_if_exists "$file" "$base" "$code" "$components"; then
        echo_error "源 $base 不包含 Debian ${code}，未写入。";
        return 1;
    fi;
    apt_add_deb_line_if_exists "$file" "$base" "${code}-updates" "$components" || true;
    sec_ref="$(apt_detect_debian_security_ref "$base" "$secbase" "$code")";
    sec_final="${sec_ref%%|*}";
    sec_suite="${sec_ref#*|}";
    if [ -n "$sec_final" ] && [ -n "$sec_suite" ]; then
        printf 'deb %s %s %s\n' "$sec_final" "$sec_suite" "$components" >> "$file";
    else
        echo_warn "未检测到 Debian security 源，已跳过 security 行。";
    fi;
    apt_set_archive_mode "$archive_mode"
}

write_ubuntu_sources () 
{ 
    local base="$1" secbase="$2" code="$3" label="$4" archive_mode="$5";
    local file="/etc/apt/sources.list" final_secbase;
    backup_file "$file";
    apt_disable_conflicting_distro_sources;
    apt_write_header "$file" "Ubuntu" "$label" "$base";
    if ! apt_add_deb_line_if_exists "$file" "$base" "$code" "main restricted universe multiverse"; then
        echo_error "源 $base 不包含 Ubuntu ${code}，未写入。";
        return 1;
    fi;
    apt_add_deb_line_if_exists "$file" "$base" "${code}-updates" "main restricted universe multiverse" || true;
    final_secbase="$(apt_detect_ubuntu_security_base "$base" "$secbase" "$code")";
    if [ -n "$final_secbase" ]; then
        apt_add_deb_line_if_exists "$file" "$final_secbase" "${code}-security" "main restricted universe multiverse" || true;
    else
        echo_warn "未检测到 ${code}-security，已跳过 security 行。";
    fi;
    apt_add_deb_line_if_exists "$file" "$base" "${code}-backports" "main restricted universe multiverse" || true;
    apt_set_archive_mode "$archive_mode"
}

yabs_test () 
{ 
    run_remote_script_confirm "YABS 测试" "https://yabs.sh"
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
