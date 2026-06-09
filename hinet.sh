#!/usr/bin/env bash
# ============================================================
# hinet-gfw-changeip-v2.0.sh
# HiNet 被墙检测 + Globalping 中国节点 ping 弱检测 + 双 API 自动换 IP
# v2.0：移除 GitHub 自动更新功能，修复后台日志/守护循环/配置残留问题
# 适合上传 GitHub：脚本本身不包含任何敏感信息，敏感 API 写入 /etc 配置文件
# ============================================================

set -Eeuo pipefail

APP_NAME="hinet-gfw-changeip"
APP_VERSION="hinet-gfw-changeip-v2.0"
INSTALL_PATH="/usr/local/bin/${APP_NAME}"
CONF_DIR="/etc/${APP_NAME}"
CONF_FILE="${CONF_DIR}/config.env"
STATE_DIR="/var/lib/${APP_NAME}"
LOG_DIR="/var/log/${APP_NAME}"
LOG_FILE="${LOG_DIR}/${APP_NAME}.log"
HISTORY_FILE="${STATE_DIR}/ip_change_history.log"
STATUS_FILE="${STATE_DIR}/status.env"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
LOCK_FILE="/run/${APP_NAME}.lock"
CHANGE_LOCK_FILE="/run/${APP_NAME}-change.lock"
GLOBALPING_API_BASE="https://api.globalping.io/v1"

# 默认值：快速初始化时可改
DEFAULT_CHECK_INTERVAL="60"
DEFAULT_CN_PROBES="2"
DEFAULT_FAIL_THRESHOLD="3"
DEFAULT_GP_PACKETS="3"
DEFAULT_RESULT_WAIT_SECONDS="35"
DEFAULT_COOLDOWN_SECONDS="600"
DEFAULT_CURL_TIMEOUT="35"
DEFAULT_POST_CHANGE_WAIT_SECONDS="180"
DEFAULT_MIN_API_INTERVAL="60"
DEFAULT_RESOLVER="1.1.1.1"

# -----------------------------
# 基础输出
# -----------------------------
cecho() { printf '%b\n' "$*"; }
info() { cecho "ℹ️  $*"; }
ok() { cecho "✅ $*"; }
warn() { cecho "⚠️  $*"; }
err() { cecho "❌ $*" >&2; }
now_human() { date '+%Y-%m-%d %H:%M:%S%z'; }
now_epoch() { date '+%s'; }

log() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    local line
    line="[$(now_human)] $*"
    # 文件日志是菜单 11 的主要来源；写文件失败不能让 daemon 因 set -e 退出。
    if ! printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null; then
        printf '%s\n' "[$(now_human)] ⚠️ 文件日志写入失败：${LOG_FILE}" >&2 || true
    fi
    # 同时输出到 stdout：systemd 会收进 journalctl，作为备用排查通道。
    printf '%s\n' "$line"
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请使用 root 执行：sudo bash $0"
        exit 1
    fi
}

mkdirs() {
    mkdir -p "$CONF_DIR" "$STATE_DIR" "$LOG_DIR"
    chmod 700 "$CONF_DIR" "$STATE_DIR"
    chmod 755 "$LOG_DIR"
    touch "$LOG_FILE" "$HISTORY_FILE"
    chmod 600 "$LOG_FILE" "$HISTORY_FILE" 2>/dev/null || true
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

install_packages() {
    local need_install=0
    for c in curl jq flock; do
        has_cmd "$c" || need_install=1
    done
    # dig 不是绝对必须，但用于稳定解析 DDNS 当前 A 记录；没有 dig 时会回退 getent。
    has_cmd dig || need_install=1
    [[ "$need_install" -eq 0 ]] && return 0

    warn "准备检查/安装依赖：curl jq flock dig。"
    if has_cmd apt-get; then
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq ca-certificates util-linux dnsutils
    elif has_cmd dnf; then
        dnf install -y curl jq ca-certificates util-linux bind-utils
    elif has_cmd yum; then
        yum install -y epel-release || true
        yum install -y curl jq ca-certificates util-linux bind-utils
    elif has_cmd apk; then
        apk add --no-cache curl jq ca-certificates util-linux bind-tools
    else
        err "无法自动识别包管理器，请手动安装：curl jq ca-certificates util-linux dig"
        exit 1
    fi

    for c in curl jq flock; do
        has_cmd "$c" || { err "依赖 $c 不可用，请手动安装后重试。"; exit 1; }
    done
}

# 兼容旧版本/误调用：v1.5 曾经把 install_packages 写成 install_dependencies。
install_dependencies() { install_packages; }

# -----------------------------
# URL 脱敏与配置
# -----------------------------
mask_url() {
    local s="${1:-}"
    [[ -z "$s" ]] && { printf '未配置'; return 0; }
    printf '%s' "$s" | sed -E 's#([?&][^=]*(api[_-]?key|apikey|token|key|password|passwd|secret|auth)[^=]*=)[^&]+#\1***#Ig'
}

quote_env() { printf '%q' "$1"; }

load_config() {
    if [[ -f "$CONF_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
    fi

    # v1.5 使用双 API：SHOW_IP_API_URL 用于获取当前 IP，CHANGE_IP_API_URL 用于真正更换 IP。
    # 兼容 v1.1-v1.4 的 HINET_API_URL：如果存在，仅迁移为 CHANGE_IP_API_URL。
    SHOW_IP_API_URL="${SHOW_IP_API_URL:-}"
    CHANGE_IP_API_URL="${CHANGE_IP_API_URL:-${HINET_API_URL:-}}"
    HINET_API_URL="${HINET_API_URL:-}"
    CHECK_TARGET="${CHECK_TARGET:-}"
    CHECK_INTERVAL="${CHECK_INTERVAL:-$DEFAULT_CHECK_INTERVAL}"
    CN_PROBES="${CN_PROBES:-$DEFAULT_CN_PROBES}"
    FAIL_THRESHOLD="${FAIL_THRESHOLD:-$DEFAULT_FAIL_THRESHOLD}"
    GP_PACKETS="${GP_PACKETS:-$DEFAULT_GP_PACKETS}"
    GP_RESULT_WAIT_SECONDS="${GP_RESULT_WAIT_SECONDS:-$DEFAULT_RESULT_WAIT_SECONDS}"
    COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-$DEFAULT_COOLDOWN_SECONDS}"
    CURL_TIMEOUT="${CURL_TIMEOUT:-$DEFAULT_CURL_TIMEOUT}"
    POST_CHANGE_WAIT_SECONDS="${POST_CHANGE_WAIT_SECONDS:-$DEFAULT_POST_CHANGE_WAIT_SECONDS}"
    DNS_RESOLVER="${DNS_RESOLVER:-$DEFAULT_RESOLVER}"
    MIN_API_INTERVAL="${MIN_API_INTERVAL:-$DEFAULT_MIN_API_INTERVAL}"
}

save_config() {
    mkdirs
    cat > "$CONF_FILE" <<EOF_CONF
# ${APP_NAME} config
# 由 ${APP_VERSION} 生成。敏感 URL 不要上传 GitHub。
# SHOW_IP_API_URL：商家提供的获取当前 HiNet 公网 IP API。调用后不应触发换 IP。
# CHANGE_IP_API_URL：商家提供的真正更换 HiNet IP API。调用后应触发换 IP，并可能返回新公网 IP 或成功文本。
# CHECK_TARGET：用于 Globalping 中国节点检测的目标，建议填你的 HiNet DDNS 域名，也可以填公网 IPv4。
SHOW_IP_API_URL=$(quote_env "$SHOW_IP_API_URL")
CHANGE_IP_API_URL=$(quote_env "$CHANGE_IP_API_URL")
CHECK_TARGET=$(quote_env "$CHECK_TARGET")
CHECK_INTERVAL=$(quote_env "$CHECK_INTERVAL")
CN_PROBES=$(quote_env "$CN_PROBES")
FAIL_THRESHOLD=$(quote_env "$FAIL_THRESHOLD")
GP_PACKETS=$(quote_env "$GP_PACKETS")
GP_RESULT_WAIT_SECONDS=$(quote_env "$GP_RESULT_WAIT_SECONDS")
COOLDOWN_SECONDS=$(quote_env "$COOLDOWN_SECONDS")
CURL_TIMEOUT=$(quote_env "$CURL_TIMEOUT")
POST_CHANGE_WAIT_SECONDS=$(quote_env "$POST_CHANGE_WAIT_SECONDS")
DNS_RESOLVER=$(quote_env "$DNS_RESOLVER")
MIN_API_INTERVAL=$(quote_env "$MIN_API_INTERVAL")
EOF_CONF
    chmod 600 "$CONF_FILE"
}

validate_number() {
    local v="$1" min="$2" max="$3" name="$4"
    if ! [[ "$v" =~ ^[0-9]+$ ]]; then
        err "$name 必须是数字。"
        exit 1
    fi
    if (( v < min || v > max )); then
        err "$name 范围应为 ${min}-${max}。"
        exit 1
    fi
}

normalize_choice() {
    # 兼容：前后空格、全角数字、中文顿号/句号、08 这类输入。
    local c="${1:-}"
    c="${c//$'\r'/}"
    c="${c//$'\t'/}"
    c="$(printf '%s' "$c" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    c="$(printf '%s' "$c" | sed \
        -e 's/０/0/g' -e 's/１/1/g' -e 's/２/2/g' -e 's/３/3/g' -e 's/４/4/g' \
        -e 's/５/5/g' -e 's/６/6/g' -e 's/７/7/g' -e 's/８/8/g' -e 's/９/9/g' \
        -e 's/[．。]//g')"
    if [[ "$c" =~ ^0*[0-9]+$ ]]; then
        c="$((10#$c))"
    fi
    printf '%s' "$c"
}


validate_config_or_exit() {
    load_config
    [[ -n "$SHOW_IP_API_URL" ]] || { err "未配置 SHOW_IP_API_URL（获取当前 IP API），请先执行快速初始化或修改配置。"; exit 1; }
    [[ -n "$CHANGE_IP_API_URL" ]] || { err "未配置 CHANGE_IP_API_URL（更换 IP API），请先执行快速初始化或修改配置。"; exit 1; }
    [[ -n "$CHECK_TARGET" ]] || { err "未配置 CHECK_TARGET，请先执行快速初始化。"; exit 1; }
    validate_number "$CHECK_INTERVAL" 30 3600 "检测间隔秒"
    validate_number "$CN_PROBES" 1 2 "中国节点数量"
    validate_number "$FAIL_THRESHOLD" 1 20 "连续失败阈值"
    validate_number "$GP_PACKETS" 1 10 "每节点 ping 包数量"
    validate_number "$GP_RESULT_WAIT_SECONDS" 10 120 "Globalping 结果等待秒数"
    validate_number "$COOLDOWN_SECONDS" 0 86400 "换 IP 冷却秒数"
    validate_number "$CURL_TIMEOUT" 5 120 "curl 超时秒数"
    validate_number "$POST_CHANGE_WAIT_SECONDS" 180 1800 "换 IP 后等待 DDNS 秒数"
    validate_number "$MIN_API_INTERVAL" 0 3600 "商家 API 最小调用间隔秒数"
}

# -----------------------------
# IP / 域名处理
# -----------------------------
valid_ipv4() {
    local ip="$1" IFS=. a b c d
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r a b c d <<< "$ip"
    for n in "$a" "$b" "$c" "$d"; do
        [[ "$n" =~ ^[0-9]+$ ]] || return 1
        (( n >= 0 && n <= 255 )) || return 1
    done
    return 0
}

public_ipv4() {
    local ip="$1" IFS=. a b c d
    valid_ipv4 "$ip" || return 1
    read -r a b c d <<< "$ip"
    (( a == 10 )) && return 1
    (( a == 127 )) && return 1
    (( a == 0 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1
    (( a == 169 && b == 254 )) && return 1
    (( a == 172 && b >= 16 && b <= 31 )) && return 1
    (( a == 192 && b == 168 )) && return 1
    (( a == 192 && b == 0 && c == 2 )) && return 1
    (( a == 198 && (b == 18 || b == 19) )) && return 1
    (( a == 198 && b == 51 && c == 100 )) && return 1
    (( a == 203 && b == 0 && c == 113 )) && return 1
    (( a >= 224 )) && return 1
    return 0
}

extract_public_ipv4() {
    local body="$1" ip
    while read -r ip; do
        if public_ipv4 "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    done < <(printf '%s' "$body" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '!seen[$0]++')
    return 1
}

resolve_target_ip() {
    load_config
    local target="$CHECK_TARGET" ip
    if public_ipv4 "$target"; then
        printf '%s\n' "$target"
        return 0
    fi

    if has_cmd dig; then
        while read -r ip; do
            if public_ipv4 "$ip"; then
                printf '%s\n' "$ip"
                return 0
            fi
        done < <(dig +time=3 +tries=1 +short A "$target" @"$DNS_RESOLVER" 2>/dev/null | awk '!seen[$0]++')
    fi

    if has_cmd getent; then
        while read -r ip _rest; do
            if public_ipv4 "$ip"; then
                printf '%s\n' "$ip"
                return 0
            fi
        done < <(getent ahostsv4 "$target" 2>/dev/null | awk '!seen[$1]++')
    fi
    return 1
}

show_current_ip() {
    validate_config_or_exit
    local api_ip="" ddns_ip="" api_body="" api_summary=""

    cecho "🌐 当前 HiNet IP / DDNS 状态"
    cecho "----------------------------------------"

    if api_body="$(http_get_silent "$SHOW_IP_API_URL" 2>/dev/null)"; then
        api_summary="$(api_response_summary "$api_body")"
        api_ip="$(extract_public_ipv4 "$api_body" 2>/dev/null || true)"
        cecho "🔎 获取 IP API：$(mask_url "$SHOW_IP_API_URL")"
        cecho "🧾 API 返回摘要：${api_summary}"
        if [[ -n "$api_ip" ]]; then
            ok "API 当前公网 IP：${api_ip}"
        else
            warn "获取 IP API 返回内容里没有可识别的公网 IPv4。"
        fi
    else
        warn "获取 IP API 请求失败：$(mask_url "$SHOW_IP_API_URL")"
    fi

    if ddns_ip="$(resolve_target_ip 2>/dev/null)"; then
        ok "检测目标：${CHECK_TARGET}"
        ok "DDNS 当前解析公网 IP：${ddns_ip}"
    else
        warn "无法解析 CHECK_TARGET 的公网 IPv4。请检查 DDNS 域名、DNS 解析或 DNS_RESOLVER。"
    fi

    if [[ -n "$api_ip" && -n "$ddns_ip" && "$api_ip" != "$ddns_ip" ]]; then
        warn "获取 IP API 与 DDNS 解析不一致：API=${api_ip}，DDNS=${ddns_ip}。可能是 DDNS 尚未同步或检测目标不是同一台 HiNet。"
    fi
}

query_current_ip_prefer_show() {
    load_config
    local body="" ip=""
    if [[ -n "${SHOW_IP_API_URL:-}" ]]; then
        if body="$(http_get_silent "$SHOW_IP_API_URL" 2>/dev/null)"; then
            ip="$(extract_public_ipv4 "$body" 2>/dev/null || true)"
            if [[ -n "$ip" ]]; then
                printf '%s\n' "$ip"
                return 0
            fi
        fi
    fi
    resolve_target_ip
}

http_get_silent() {
    local url="$1"
    curl -fsSL --connect-timeout 10 --max-time "$CURL_TIMEOUT" \
        -A "${APP_NAME}/${APP_VERSION}" \
        "$url"
}

append_history() {
    local old_ip="$1" new_ip="$2" reason="$3" note="${4:-}"
    mkdirs
    printf '%s|old=%s|new=%s|target=%s|reason=%s|note=%s\n' \
        "$(now_human)" "${old_ip:-unknown}" "${new_ip:-unknown}" "${CHECK_TARGET:-unknown}" "${reason:-manual}" "${note:-}" >> "$HISTORY_FILE"
}


api_response_summary() {
    local body="${1:-}"
    body="$(printf '%s' "$body" | tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -z "$body" ]] && { printf 'empty_response'; return 0; }
    printf '%s' "$body" | cut -c 1-240
}

api_url_has_showip_action() {
    local url="${1:-}"
    printf '%s' "$url" | grep -qiE '([?&]action=showip)(&|$)'
}

warn_if_showip_action() {
    local url="${1:-}"
    if api_url_has_showip_action "$url"; then
        warn "检测到商家 API URL 里包含 action=showip。它可能只是查询 IP，不一定会更换 IP；脚本不会阻止保存，但建议先用【手动测试商家 API】确认。"
    fi
}

enforce_api_min_interval() {
    load_config
    load_status
    local now delta remain
    now="$(now_epoch)"
    delta=$(( now - ${LAST_API_CALL_EPOCH:-0} ))
    if (( MIN_API_INTERVAL > 0 && LAST_API_CALL_EPOCH > 0 && delta < MIN_API_INTERVAL )); then
        remain=$(( MIN_API_INTERVAL - delta ))
        warn "商家 API 最小调用间隔限制中，剩余 ${remain} 秒。为避免触发商家风控，本次不调用。"
        log "⚠️ 商家 API 调用间隔限制：remain=${remain}s"
        return 1
    fi
    return 0
}

mark_api_called() {
    load_status
    LAST_API_CALL_EPOCH="$(now_epoch)"
    save_status
}

judgement_wait_seconds() {
    local v="${POST_CHANGE_WAIT_SECONDS:-$DEFAULT_POST_CHANGE_WAIT_SECONDS}"
    if ! [[ "$v" =~ ^[0-9]+$ ]]; then
        v="$DEFAULT_POST_CHANGE_WAIT_SECONDS"
    fi
    (( v < 180 )) && v=180
    printf '%s\n' "$v"
}

change_ip_inner() {
    validate_config_or_exit
    enforce_api_min_interval || return 1

    local reason="${1:-manual}" old_ip="" api_body="" api_summary="" api_ip="" new_ip="" note="" wait_s=""

    old_ip="$(query_current_ip_prefer_show 2>/dev/null || true)"
    local old_ddns_ip="" new_ddns_ip=""
    old_ddns_ip="$(resolve_target_ip 2>/dev/null || true)"
    log "🔁 准备调用更换 IP API，reason=${reason}，old_ip=${old_ip:-unknown}，old_ddns=${old_ddns_ip:-unknown}，target=${CHECK_TARGET}"
    cecho "🔁 准备调用【更换 IP API】。"
    cecho "📌 原当前 IP：${old_ip:-unknown}"
    cecho "📌 原 DDNS 解析 IP：${old_ddns_ip:-unknown}"

    mark_api_called
    api_body="$(http_get_silent "$CHANGE_IP_API_URL")" || {
        log "❌ 更换 IP API 请求失败，reason=${reason}"
        append_history "$old_ip" "unknown" "$reason" "change_api_request_failed"
        err "更换 IP API 请求失败。请检查 URL、网络、商家面板限制或 API Key。"
        return 1
    }

    api_summary="$(api_response_summary "$api_body")"
    api_ip="$(extract_public_ipv4 "$api_body" 2>/dev/null || true)"
    cecho "🧾 API 返回摘要：${api_summary}"
    log "🧾 更换 IP API 返回摘要：${api_summary}"

    if [[ -n "$api_ip" ]]; then
        note="api_returned_public_ip"
        log "ℹ️ 更换 IP API 返回公网 IP：${api_ip}"
    else
        note="api_no_public_ip"
        log "⚠️ 更换 IP API 未直接返回公网 IPv4，将等待后通过获取 IP API / DDNS 复核。"
    fi

    wait_s="$(judgement_wait_seconds)"
    log "⏳ 等待 DDNS/线路更新 ${wait_s} 秒后确认解析结果。"
    cecho "⏳ 等待 ${wait_s} 秒后确认 DDNS 解析变化。"
    sleep "$wait_s"

    new_ip="$(query_current_ip_prefer_show 2>/dev/null || true)"
    new_ddns_ip="$(resolve_target_ip 2>/dev/null || true)"
    cecho "📌 新当前 IP：${new_ip:-unknown}"
    cecho "📌 新 DDNS 解析 IP：${new_ddns_ip:-unknown}"

    if [[ -z "$new_ip" ]]; then
        new_ip="${api_ip:-unknown}"
        note="${note}_current_ip_query_failed_after_change"
        warn "换 IP 后无法通过获取 IP API/DDNS 获得公网 IPv4。"
    elif [[ -n "$api_ip" && "$new_ip" != "$api_ip" ]]; then
        note="${note}_current_ip_not_match_api_return"
        warn "更换 API 返回 IP=${api_ip}，但当前查询 IP=${new_ip}，可能是返回旧 IP、DDNS 尚未同步或商家 API 返回格式特殊。"
        log "⚠️ 更换 API 返回 IP=${api_ip}，当前查询 IP=${new_ip}。"
    fi

    if [[ -n "$old_ip" && -n "$new_ip" && "$new_ip" == "$old_ip" ]]; then
        note="${note}_ip_unchanged_possible_wrong_change_api_or_delay"
        warn "更换 API 调用完成，但当前 IP 未变化：${old_ip}。可能填成了获取 IP API、商家未实际换 IP，或等待时间不够。"
        log "⚠️ 更换 API 调用完成但当前 IP 未变化：${old_ip}。"
    fi

    if [[ -n "$new_ip" && -n "$new_ddns_ip" && "$new_ip" != "$new_ddns_ip" ]]; then
        note="${note}_ddns_not_match_current_ip"
        warn "当前 IP=${new_ip}，但 DDNS=${new_ddns_ip}，可能是 DDNS 更新延迟。"
    fi

    append_history "$old_ip" "$new_ip" "$reason" "$note"
    log "✅ 换 IP 流程完成：${old_ip:-unknown} -> ${new_ip}，reason=${reason}，note=${note}"
    ok "换 IP 流程完成：${old_ip:-unknown} -> ${new_ip}"
    return 0
}
change_ip() {
    # 防止后台自动触发、菜单手动触发、命令行手动触发同时调用商家 API。
    mkdir -p /run
    exec 8>"$CHANGE_LOCK_FILE"
    if ! flock -n 8; then
        warn "已有换 IP 流程正在执行，本次跳过，避免重复调用商家 API。"
        log "⚠️ 换 IP 流程已被锁定，跳过 reason=${1:-manual}"
        return 1
    fi
    change_ip_inner "${1:-manual}"
}


test_show_ip_api() {
    require_root
    validate_config_or_exit
    cecho "🧪 手动测试【获取当前 IP API】"
    cecho "----------------------------------------"
    local body summary ip ddns_ip
    body="$(http_get_silent "$SHOW_IP_API_URL")" || { err "获取 IP API 请求失败。"; return 1; }
    summary="$(api_response_summary "$body")"
    ip="$(extract_public_ipv4 "$body" 2>/dev/null || true)"
    ddns_ip="$(resolve_target_ip 2>/dev/null || true)"
    cecho "🧾 API 返回摘要：${summary}"
    [[ -n "$ip" ]] && ok "API 当前公网 IP：${ip}" || warn "API 返回内容里没有可识别的公网 IPv4。"
    [[ -n "$ddns_ip" ]] && ok "DDNS 当前解析公网 IP：${ddns_ip}" || warn "DDNS 解析失败。"
    if [[ -n "$ip" && -n "$ddns_ip" && "$ip" != "$ddns_ip" ]]; then
        warn "获取 IP API 与 DDNS 不一致：API=${ip}，DDNS=${ddns_ip}。"
    fi
    log "🧪 获取 IP API 测试完成：api_ip=${ip:-none}, ddns=${ddns_ip:-none}, summary=${summary}"
}

test_vendor_api() {
    require_root
    validate_config_or_exit

    mkdir -p /run
    exec 8>"$CHANGE_LOCK_FILE"
    if ! flock -n 8; then
        warn "已有换 IP 流程正在执行，本次测试跳过，避免重复调用更换 IP API。"
        return 1
    fi

    enforce_api_min_interval || return 1

    cecho "🧪 手动测试【更换 IP API】"
    cecho "----------------------------------------"
    warn "这个测试会真实调用更换 IP API，可能会触发 HiNet 换 IP；但不会写入正式 IP 更换记录。"
    warn_if_showip_action "$CHANGE_IP_API_URL"
    local ans old_ip old_ddns api_body api_summary api_ip new_ip new_ddns wait_s
    read -r -p "确认调用？输入 1 继续，其它取消：" ans
    [[ "$ans" == "1" ]] || { info "已取消测试。"; return 0; }

    old_ip="$(query_current_ip_prefer_show 2>/dev/null || true)"
    old_ddns="$(resolve_target_ip 2>/dev/null || true)"
    cecho "📌 原当前 IP：${old_ip:-unknown}"
    cecho "📌 原 DDNS 解析 IP：${old_ddns:-unknown}"

    mark_api_called
    api_body="$(http_get_silent "$CHANGE_IP_API_URL")" || {
        err "更换 IP API 请求失败。"
        log "❌ 手动测试更换 IP API 请求失败。"
        return 1
    }

    api_summary="$(api_response_summary "$api_body")"
    api_ip="$(extract_public_ipv4 "$api_body" 2>/dev/null || true)"
    cecho "🧾 API 返回摘要：${api_summary}"
    [[ -n "$api_ip" ]] && cecho "🌐 更换 API 返回公网 IP：${api_ip}" || warn "更换 API 返回内容里没有可识别的公网 IPv4。"

    wait_s="$(judgement_wait_seconds)"
    cecho "⏳ 等待 ${wait_s} 秒后重新查询当前 IP / DDNS。"
    sleep "$wait_s"

    new_ip="$(query_current_ip_prefer_show 2>/dev/null || true)"
    new_ddns="$(resolve_target_ip 2>/dev/null || true)"
    cecho "📌 新当前 IP：${new_ip:-unknown}"
    cecho "📌 新 DDNS 解析 IP：${new_ddns:-unknown}"

    if [[ -n "$old_ip" && -n "$new_ip" && "$old_ip" == "$new_ip" ]]; then
        warn "更换 API 调用成功返回，但当前 IP 未变化。可能是把获取 IP API 填到了更换 API，或商家/DDNS 尚未更新。"
    elif [[ -n "$old_ip" && -n "$new_ip" ]]; then
        ok "当前 IP 已变化：${old_ip} -> ${new_ip}"
    else
        warn "无法完成前后 IP 对比，请检查获取 IP API 和 DDNS。"
    fi

    log "🧪 更换 IP API 测试完成：old=${old_ip:-unknown}, new=${new_ip:-unknown}, api_ip=${api_ip:-none}, summary=${api_summary}"
    ok "手动测试完成；本次未写入正式 IP 更换记录。"
}

# -----------------------------
# Globalping CN ping 检测
# 返回：0=有中国探针 ping 成功；1=中国探针全部失败；2=API/探针不可用，不能作为失败计数
# -----------------------------
globalping_measurement_create() {
    local target="$1" payload response id
    payload="$(jq -nc \
        --arg target "$target" \
        --argjson limit "$CN_PROBES" \
        --argjson packets "$GP_PACKETS" \
        '{target:$target,type:"ping",locations:[{country:"CN",limit:$limit}],measurementOptions:{packets:$packets}}')"

    response="$(curl -fsSL --connect-timeout 10 --max-time 30 \
        -A "${APP_NAME}/${APP_VERSION}" \
        -H 'Content-Type: application/json' \
        -X POST "${GLOBALPING_API_BASE}/measurements" \
        --data "$payload")" || return 1

    id="$(printf '%s' "$response" | jq -r '.id // empty' 2>/dev/null)"
    [[ -n "$id" ]] || return 1
    printf '%s\n' "$id"
}

globalping_measurement_get() {
    local id="$1"
    curl -fsSL --connect-timeout 10 --max-time 30 \
        -A "${APP_NAME}/${APP_VERSION}" \
        "${GLOBALPING_API_BASE}/measurements/${id}"
}

parse_globalping_result() {
    jq -r '
      def n: tonumber? // 0;
      def raw: (.result.rawOutput? // .result.output? // .result.raw? // "");
      def ok_by_stats:
        (((.result.stats.rcv? // .result.stats.received? // .result.stats.packetsReceived? // 0) | n) > 0);
      def ok_by_raw:
        (raw | test("(^|[^0-9])([1-9][0-9]*)[[:space:]]+(packets[[:space:]]+)?received|(^|[^0-9])0%[[:space:]]+packet[[:space:]]+loss"; "i"));
      [
        (.status // "unknown"),
        ((.results // []) | length),
        ([.results[]? | select(ok_by_stats or ok_by_raw)] | length)
      ] | @tsv
    ' 2>/dev/null || printf 'parse_error\t0\t0\n'
}

globalping_check_target() {
    validate_config_or_exit
    local target="$1" id start deadline json parsed status total okn
    id="$(globalping_measurement_create "$target" 2>/dev/null || true)"
    if [[ -z "$id" ]]; then
        log "⚠️ Globalping 创建 measurement 失败，不计入连续失败。"
        return 2
    fi

    start="$(now_epoch)"
    deadline=$(( start + GP_RESULT_WAIT_SECONDS ))

    while true; do
        json="$(globalping_measurement_get "$id" 2>/dev/null || true)"
        if [[ -n "$json" ]]; then
            parsed="$(printf '%s' "$json" | parse_globalping_result)"
            status="$(printf '%s' "$parsed" | awk -F'\t' '{print $1}')"
            total="$(printf '%s' "$parsed" | awk -F'\t' '{print $2}')"
            okn="$(printf '%s' "$parsed" | awk -F'\t' '{print $3}')"

            if [[ "$status" != "in-progress" && "$status" != "unknown" && "$status" != "parse_error" ]]; then
                if [[ "$total" =~ ^[0-9]+$ && "$okn" =~ ^[0-9]+$ ]]; then
                    if (( total < 1 )); then
                        log "⚠️ Globalping 未返回中国探针结果，measurement=${id}，不计入连续失败。"
                        return 2
                    fi
                    if (( okn > 0 )); then
                        log "✅ Globalping CN ping 正常：target=${target}，ok=${okn}/${total}，measurement=${id}"
                        return 0
                    fi
                    log "❌ Globalping CN ping 全部失败：target=${target}，ok=0/${total}，measurement=${id}"
                    return 1
                fi
            fi
        fi

        if (( $(now_epoch) >= deadline )); then
            log "⚠️ Globalping 等待结果超时，measurement=${id}，不计入连续失败。"
            return 2
        fi
        sleep 3
    done
}

run_single_check() {
    validate_config_or_exit
    local resolved_ip="" rc
    resolved_ip="$(resolve_target_ip 2>/dev/null || true)"
    info "开始检测目标：${CHECK_TARGET}"
    [[ -n "$resolved_ip" ]] && info "当前解析 IP：${resolved_ip}"
    info "Globalping 中国节点：${CN_PROBES} 个。"
    if globalping_check_target "$CHECK_TARGET"; then
        ok "检测结果：CN ping 正常。"
    else
        rc=$?
        if [[ "$rc" -eq 1 ]]; then
            warn "检测结果：CN ping 全部失败。"
        else
            warn "检测结果：Globalping API/探针不可用，本次不应计为被墙失败。"
        fi
        return "$rc"
    fi
}

# -----------------------------
# 状态持久化
# -----------------------------
load_status() {
    FAILURE_COUNT=0
    LAST_CHANGE_EPOCH=0
    LAST_API_CALL_EPOCH=0
    LAST_CHECK_EPOCH=0
    LAST_TARGET=""
    LAST_RESOLVED_IP=""
    LAST_RESULT="unknown"
    [[ -f "$STATUS_FILE" ]] && source "$STATUS_FILE" || true
    FAILURE_COUNT="${FAILURE_COUNT:-0}"
    LAST_CHANGE_EPOCH="${LAST_CHANGE_EPOCH:-0}"
    LAST_API_CALL_EPOCH="${LAST_API_CALL_EPOCH:-0}"
    LAST_CHECK_EPOCH="${LAST_CHECK_EPOCH:-0}"
    LAST_TARGET="${LAST_TARGET:-}"
    LAST_RESOLVED_IP="${LAST_RESOLVED_IP:-}"
    LAST_RESULT="${LAST_RESULT:-unknown}"
}

save_status() {
    mkdirs
    cat > "$STATUS_FILE" <<EOF_STATUS
FAILURE_COUNT=$(quote_env "${FAILURE_COUNT:-0}")
LAST_CHANGE_EPOCH=$(quote_env "${LAST_CHANGE_EPOCH:-0}")
LAST_API_CALL_EPOCH=$(quote_env "${LAST_API_CALL_EPOCH:-0}")
LAST_CHECK_EPOCH=$(quote_env "${LAST_CHECK_EPOCH:-0}")
LAST_TARGET=$(quote_env "${LAST_TARGET:-}")
LAST_RESOLVED_IP=$(quote_env "${LAST_RESOLVED_IP:-}")
LAST_RESULT=$(quote_env "${LAST_RESULT:-unknown}")
EOF_STATUS
    chmod 600 "$STATUS_FILE"
}

# -----------------------------
# 后台守护
# -----------------------------
daemon_loop() {
    require_root
    mkdirs
    log "🧭 daemon entry：开始启动后台守护进程。"

    # daemon 内不再自动 apt/yum 安装依赖，避免服务启动时卡在包管理器导致日志静默。
    for c in curl jq flock; do
        if ! has_cmd "$c"; then
            log "❌ daemon 缺少依赖：$c。请执行 ${INSTALL_PATH} doctor 或重新 init。"
            exit 1
        fi
    done

    validate_config_or_exit

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "⚠️ 已有守护进程在运行，退出。"
        exit 0
    fi

    load_status
    log "🚀 ${APP_VERSION} 守护进程启动。target=${CHECK_TARGET}, interval=${CHECK_INTERVAL}s, cn_probes=${CN_PROBES}, threshold=${FAIL_THRESHOLD}, cooldown=${COOLDOWN_SECONDS}s"

    while true; do
        load_config
        load_status


        local rc=2 now last_delta resolved_ip=""
        now="$(now_epoch)"
        LAST_CHECK_EPOCH="$now"
        LAST_TARGET="$CHECK_TARGET"
        resolved_ip="$(resolve_target_ip 2>/dev/null || true)"
        LAST_RESOLVED_IP="$resolved_ip"

        # 重要：globalping_check_target 返回 1 表示“CN ping 全部失败”，这是业务状态，不能让 set -e 直接退出守护进程。
        # v1.6 的后台自动换 IP 失效核心原因就在这里：非 0 返回值会在执行到 rc=$? 之前触发 errexit。
        log "🛰️ 后台检测开始：target=${CHECK_TARGET}，resolved_ip=${resolved_ip:-unknown}，threshold=${FAILURE_COUNT}/${FAIL_THRESHOLD}"
        set +e
        globalping_check_target "$CHECK_TARGET"
        rc=$?
        set -e

        if [[ "$rc" -eq 0 ]]; then
            FAILURE_COUNT=0
            LAST_RESULT="ok"
            save_status
        elif [[ "$rc" -eq 1 ]]; then
            FAILURE_COUNT=$(( FAILURE_COUNT + 1 ))
            LAST_RESULT="cn_ping_failed"
            save_status
            log "⚠️ 连续失败计数：${FAILURE_COUNT}/${FAIL_THRESHOLD}，target=${CHECK_TARGET}，resolved_ip=${resolved_ip:-unknown}"

            if (( FAILURE_COUNT >= FAIL_THRESHOLD )); then
                now="$(now_epoch)"
                last_delta=$(( now - LAST_CHANGE_EPOCH ))
                if (( COOLDOWN_SECONDS > 0 && last_delta < COOLDOWN_SECONDS )); then
                    log "⏳ 已达到失败阈值，但仍在冷却期：剩余 $(( COOLDOWN_SECONDS - last_delta )) 秒，本次不换 IP。"
                else
                    if change_ip "globalping_cn_ping_failed_${FAILURE_COUNT}_times"; then
                        LAST_CHANGE_EPOCH="$(now_epoch)"
                        FAILURE_COUNT=0
                        LAST_RESULT="changed_ip"
                        LAST_RESOLVED_IP="$(resolve_target_ip 2>/dev/null || true)"
                        save_status
                    else
                        LAST_RESULT="change_ip_failed"
                        save_status
                    fi
                fi
            fi
        else
            LAST_RESULT="globalping_unknown"
            save_status
            log "⚠️ Globalping 本轮结果不可用或探针异常，不计入连续失败。target=${CHECK_TARGET}，resolved_ip=${resolved_ip:-unknown}"
        fi

        log "💤 后台检测结束，${CHECK_INTERVAL} 秒后进行下一轮。last_result=${LAST_RESULT}，failure_count=${FAILURE_COUNT}/${FAIL_THRESHOLD}"
        sleep "$CHECK_INTERVAL"
    done
}

# -----------------------------
# systemd / 安装卸载
# -----------------------------
write_service() {
    cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=HiNet GFW Auto Change IP by Globalping CN Ping
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env bash ${INSTALL_PATH} daemon
Restart=always
RestartSec=15
WorkingDirectory=/
Environment=LANG=C.UTF-8
Environment=LC_ALL=C.UTF-8
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
}

install_self() {
    require_root
    has_cmd systemctl || { err "当前系统未检测到 systemctl。本脚本使用 systemd 管理后台服务。"; exit 1; }
    install_packages
    mkdirs

    local src="${BASH_SOURCE[0]}"
    if [[ "$src" != "$INSTALL_PATH" ]]; then
        cp -f "$src" "$INSTALL_PATH"
        chmod 755 "$INSTALL_PATH"
    else
        chmod 755 "$INSTALL_PATH"
    fi

    # 自检：确保安装后的入口文件可被 bash 解释，避免 systemd 203/EXEC。
    if ! /usr/bin/env bash -n "$INSTALL_PATH"; then
        err "安装后的脚本语法自检失败：$INSTALL_PATH"
        exit 1
    fi

    write_service
    log "✅ 安装/覆盖完成：${INSTALL_PATH}，版本=${APP_VERSION}。"
    ok "安装完成：${INSTALL_PATH}"
    ok "服务文件：${SERVICE_FILE}"
}

quick_init() {
    require_root
    install_packages
    install_self
    mkdirs

    cecho "🚀 ${APP_VERSION} 快速初始化"
    cecho "----------------------------------------"
    warn "请输入你的真实 API 地址。脚本不会内置示例 URL，也不会把敏感信息上传 GitHub。"
    warn "v2.0 使用双 API：获取当前 IP API 不应换 IP；更换 IP API 只在手动/自动触发时调用。"
    cecho ""

    local show_api change_api target interval probes threshold packets wait cooldown timeout post_wait min_api resolver start_now

    read -r -p "🔎 请输入【获取当前 IP API】地址：" show_api
    while [[ -z "$show_api" ]]; do
        read -r -p "🔎 获取当前 IP API 地址不能为空，请重新输入：" show_api
    done

    read -r -p "🔁 请输入【真正更换 IP API】地址：" change_api
    while [[ -z "$change_api" ]]; do
        read -r -p "🔁 更换 IP API 地址不能为空，请重新输入：" change_api
    done

    warn_if_showip_action "$change_api"

    read -r -p "🎯 请输入【检测目标域名/IP】（建议填 HiNet DDNS 域名）：" target
    while [[ -z "$target" ]]; do
        read -r -p "🎯 检测目标不能为空，请重新输入：" target
    done

    read -r -p "⏱️ 检测间隔秒 [默认 ${DEFAULT_CHECK_INTERVAL}]：" interval
    interval="${interval:-$DEFAULT_CHECK_INTERVAL}"

    read -r -p "🇨🇳 每次使用几个中国节点 [默认 ${DEFAULT_CN_PROBES}，建议 1-2]：" probes
    probes="${probes:-$DEFAULT_CN_PROBES}"

    read -r -p "🚨 连续几次 CN ping 全部失败后换 IP [默认 ${DEFAULT_FAIL_THRESHOLD}]：" threshold
    threshold="${threshold:-$DEFAULT_FAIL_THRESHOLD}"

    read -r -p "📦 每个节点 ping 包数量 [默认 ${DEFAULT_GP_PACKETS}]：" packets
    packets="${packets:-$DEFAULT_GP_PACKETS}"

    read -r -p "⌛ 等待 Globalping 结果秒数 [默认 ${DEFAULT_RESULT_WAIT_SECONDS}]：" wait
    wait="${wait:-$DEFAULT_RESULT_WAIT_SECONDS}"

    read -r -p "🧊 自动换 IP 冷却秒数 [默认 ${DEFAULT_COOLDOWN_SECONDS}]：" cooldown
    cooldown="${cooldown:-$DEFAULT_COOLDOWN_SECONDS}"

    read -r -p "🌐 API curl 最大超时秒数 [默认 ${DEFAULT_CURL_TIMEOUT}]：" timeout
    timeout="${timeout:-$DEFAULT_CURL_TIMEOUT}"

    read -r -p "⏳ 换 IP 后等待 IP/DDNS 更新秒数 [默认 ${DEFAULT_POST_CHANGE_WAIT_SECONDS}，最小 180]：" post_wait
    post_wait="${post_wait:-$DEFAULT_POST_CHANGE_WAIT_SECONDS}"

    read -r -p "🧯 更换 IP API 最小调用间隔秒数 [默认 ${DEFAULT_MIN_API_INTERVAL}]：" min_api
    min_api="${min_api:-$DEFAULT_MIN_API_INTERVAL}"

    read -r -p "🧭 解析 DDNS 使用的 DNS 服务器 [默认 ${DEFAULT_RESOLVER}]：" resolver
    resolver="${resolver:-$DEFAULT_RESOLVER}"

    SHOW_IP_API_URL="$show_api"
    CHANGE_IP_API_URL="$change_api"
    CHECK_TARGET="$target"
    CHECK_INTERVAL="$interval"
    CN_PROBES="$probes"
    FAIL_THRESHOLD="$threshold"
    GP_PACKETS="$packets"
    GP_RESULT_WAIT_SECONDS="$wait"
    COOLDOWN_SECONDS="$cooldown"
    CURL_TIMEOUT="$timeout"
    POST_CHANGE_WAIT_SECONDS="$post_wait"
    MIN_API_INTERVAL="$min_api"
    DNS_RESOLVER="$resolver"

    validate_number "$CHECK_INTERVAL" 30 3600 "检测间隔秒"
    validate_number "$CN_PROBES" 1 2 "中国节点数量"
    validate_number "$FAIL_THRESHOLD" 1 20 "连续失败阈值"
    validate_number "$GP_PACKETS" 1 10 "每节点 ping 包数量"
    validate_number "$GP_RESULT_WAIT_SECONDS" 10 120 "Globalping 结果等待秒数"
    validate_number "$COOLDOWN_SECONDS" 0 86400 "换 IP 冷却秒数"
    validate_number "$CURL_TIMEOUT" 5 120 "curl 超时秒数"
    validate_number "$POST_CHANGE_WAIT_SECONDS" 180 1800 "换 IP 后等待秒数"
    validate_number "$MIN_API_INTERVAL" 0 3600 "更换 IP API 最小调用间隔秒数"

    save_config
    ok "配置已保存：${CONF_FILE}（权限 600）"
    info "获取 IP API：$(mask_url "$SHOW_IP_API_URL")"
    info "更换 IP API：$(mask_url "$CHANGE_IP_API_URL")"
    info "检测目标：${CHECK_TARGET}"

    cecho ""
    info "正在测试当前 IP / DDNS，不会调用更换 IP API..."
    show_current_ip || warn "当前 IP / DDNS 测试失败，但配置已保存。"

    cecho ""
    info "正在测试 Globalping CN ping，不会调用更换 IP API..."
    run_single_check || true

    cecho ""
    read -r -p "🚀 是否立即启动后台自动检测服务？[Y/n]：" start_now
    start_now="${start_now:-Y}"
    if [[ "$start_now" =~ ^[Yy]$ ]]; then
        systemctl enable --now "$APP_NAME"
        ok "已启动并设置开机自启：${APP_NAME}"
        systemctl --no-pager --full status "$APP_NAME" || true
    else
        info "你可以稍后执行：${INSTALL_PATH} start"
    fi
}


prompt_keep() {
    local label="$1" current="$2" varname="$3" input=""
    read -r -p "${label} [当前：${current}]，回车保留：" input
    if [[ -n "$input" ]]; then
        printf -v "$varname" '%s' "$input"
    fi
}

edit_config() {
    require_root
    install_self
    load_config

    cecho "🛠️ 修改已有配置"
    cecho "----------------------------------------"
    cecho "回车表示保留当前值。API 会脱敏显示。"

    local input_show="" input_change="" show_api="$SHOW_IP_API_URL" change_api="$CHANGE_IP_API_URL" target="$CHECK_TARGET" interval="$CHECK_INTERVAL" probes="$CN_PROBES" threshold="$FAIL_THRESHOLD" packets="$GP_PACKETS" wait="$GP_RESULT_WAIT_SECONDS" cooldown="$COOLDOWN_SECONDS" timeout="$CURL_TIMEOUT" post_wait="$POST_CHANGE_WAIT_SECONDS" min_api="$MIN_API_INTERVAL" resolver="$DNS_RESOLVER" restart_now=""

    read -r -p "🔎 获取当前 IP API [当前：$(mask_url "$show_api")]，回车保留：" input_show
    [[ -n "${input_show:-}" ]] && show_api="$input_show"

    read -r -p "🔁 真正更换 IP API [当前：$(mask_url "$change_api")]，回车保留：" input_change
    if [[ -n "${input_change:-}" ]]; then
        change_api="$input_change"
        warn_if_showip_action "$change_api"
    else
        warn_if_showip_action "$change_api"
    fi

    prompt_keep "🎯 检测目标域名/IP" "$target" target
    prompt_keep "⏱️ 检测间隔秒" "$interval" interval
    prompt_keep "🇨🇳 每次中国节点数，建议 1-2" "$probes" probes
    prompt_keep "🚨 连续失败阈值" "$threshold" threshold
    prompt_keep "📦 每节点 ping 包数量" "$packets" packets
    prompt_keep "⌛ Globalping 结果等待秒数" "$wait" wait
    prompt_keep "🧊 自动换 IP 冷却秒数" "$cooldown" cooldown
    prompt_keep "🌐 API curl 最大超时秒数" "$timeout" timeout
    prompt_keep "⏳ 换 IP 后等待秒数，最小 180" "$post_wait" post_wait
    prompt_keep "🧯 更换 IP API 最小调用间隔秒数" "$min_api" min_api
    prompt_keep "🧭 DDNS 解析 DNS 服务器" "$resolver" resolver
    SHOW_IP_API_URL="$show_api"
    CHANGE_IP_API_URL="$change_api"
    CHECK_TARGET="$target"
    CHECK_INTERVAL="$interval"
    CN_PROBES="$probes"
    FAIL_THRESHOLD="$threshold"
    GP_PACKETS="$packets"
    GP_RESULT_WAIT_SECONDS="$wait"
    COOLDOWN_SECONDS="$cooldown"
    CURL_TIMEOUT="$timeout"
    POST_CHANGE_WAIT_SECONDS="$post_wait"
    MIN_API_INTERVAL="$min_api"
    DNS_RESOLVER="$resolver"

    [[ -n "$SHOW_IP_API_URL" ]] || { err "获取当前 IP API 地址不能为空。"; return 1; }
    [[ -n "$CHANGE_IP_API_URL" ]] || { err "更换 IP API 地址不能为空。"; return 1; }
    [[ -n "$CHECK_TARGET" ]] || { err "检测目标不能为空。"; return 1; }
    validate_number "$CHECK_INTERVAL" 30 3600 "检测间隔秒"
    validate_number "$CN_PROBES" 1 2 "中国节点数量"
    validate_number "$FAIL_THRESHOLD" 1 20 "连续失败阈值"
    validate_number "$GP_PACKETS" 1 10 "每节点 ping 包数量"
    validate_number "$GP_RESULT_WAIT_SECONDS" 10 120 "Globalping 结果等待秒数"
    validate_number "$COOLDOWN_SECONDS" 0 86400 "换 IP 冷却秒数"
    validate_number "$CURL_TIMEOUT" 5 120 "curl 超时秒数"
    validate_number "$POST_CHANGE_WAIT_SECONDS" 180 1800 "换 IP 后等待秒数"
    validate_number "$MIN_API_INTERVAL" 0 3600 "更换 IP API 最小调用间隔秒数"
    save_config
    ok "配置已更新：${CONF_FILE}"
    show_config_masked

    if systemctl is-active --quiet "$APP_NAME" 2>/dev/null; then
        read -r -p "🔄 检测到服务正在运行，是否立即重启让新配置生效？[Y/n]：" restart_now
        restart_now="${restart_now:-Y}"
        if [[ "$restart_now" =~ ^[Yy]$ ]]; then
            systemctl restart "$APP_NAME"
            ok "服务已重启。"
        fi
    fi
}

service_start() {
    require_root
    install_self
    validate_config_or_exit
    systemctl enable --now "$APP_NAME"
    ok "已启动：${APP_NAME}"
}

service_stop() {
    require_root
    systemctl stop "$APP_NAME" 2>/dev/null || true
    ok "已停止：${APP_NAME}"
}

service_restart() {
    require_root
    install_self
    validate_config_or_exit
    systemctl restart "$APP_NAME"
    ok "已重启：${APP_NAME}"
}

service_status() {
    require_root
    load_config
    load_status
    cecho "🧩 ${APP_VERSION} 状态"
    cecho "----------------------------------------"
    systemctl --no-pager --full status "$APP_NAME" || true
    cecho ""
    cecho "📌 当前配置："
    cecho "  检测目标：${CHECK_TARGET:-未配置}"
    cecho "  检测间隔：${CHECK_INTERVAL:-未配置}s"
    cecho "  中国节点：${CN_PROBES:-未配置} 个"
    cecho "  失败阈值：${FAIL_THRESHOLD:-未配置} 次"
    cecho "  冷却时间：${COOLDOWN_SECONDS:-未配置}s"
    cecho "  换 IP 后等待：${POST_CHANGE_WAIT_SECONDS:-未配置}s"
    cecho "  DNS 解析器：${DNS_RESOLVER:-未配置}"
    cecho "  API 最小间隔：${MIN_API_INTERVAL:-未配置}s"
    cecho "  获取 IP API：$(mask_url "${SHOW_IP_API_URL:-}")"
    cecho "  更换 IP API：$(mask_url "${CHANGE_IP_API_URL:-}")"
    cecho ""
    cecho "📊 最近状态："
    cecho "  LAST_TARGET=${LAST_TARGET:-unknown}"
    cecho "  LAST_RESOLVED_IP=${LAST_RESOLVED_IP:-unknown}"
    cecho "  LAST_RESULT=${LAST_RESULT:-unknown}"
    cecho "  FAILURE_COUNT=${FAILURE_COUNT:-0}"
    cecho "  LAST_CHECK_EPOCH=${LAST_CHECK_EPOCH:-0}"
    cecho "  LAST_CHANGE_EPOCH=${LAST_CHANGE_EPOCH:-0}"
    cecho "  LAST_API_CALL_EPOCH=${LAST_API_CALL_EPOCH:-0}"
}

view_logs() {
    require_root
    mkdirs
    cecho "🧾 中文日志文件：${LOG_FILE}"
    cecho "----------------------------------------"
    info "显示原来的中文文件日志。按 Ctrl+C 退出。"
    if [[ ! -s "$LOG_FILE" ]]; then
        warn "当前文件日志为空。下面先给出服务状态，方便判断后台是否真正运行。"
        if has_cmd systemctl && systemctl list-unit-files "${APP_NAME}.service" >/dev/null 2>&1; then
            systemctl --no-pager --full status "$APP_NAME" || true
            cecho ""
            warn "如果服务状态正常但文件日志仍为空，可执行：${APP_NAME} journal 查看 systemd journal 原始输出。"
        fi
    fi
    tail -n 120 -F "$LOG_FILE"
}

view_journal_logs() {
    require_root
    cecho "🧾 systemd journal：journalctl -u ${APP_NAME} -f -o cat"
    cecho "----------------------------------------"
    if has_cmd journalctl; then
        journalctl -u "$APP_NAME" -n 120 -f -o cat || true
    else
        err "当前系统未检测到 journalctl。"
        return 1
    fi
}

show_config_masked() {
    require_root
    load_config
    cecho "🔐 当前配置（已脱敏）"
    cecho "----------------------------------------"
    cecho "SHOW_IP_API_URL=$(mask_url "${SHOW_IP_API_URL:-}")"
    cecho "CHANGE_IP_API_URL=$(mask_url "${CHANGE_IP_API_URL:-}")"
    cecho "CHECK_TARGET=${CHECK_TARGET:-}"
    cecho "CHECK_INTERVAL=${CHECK_INTERVAL:-$DEFAULT_CHECK_INTERVAL}"
    cecho "CN_PROBES=${CN_PROBES:-$DEFAULT_CN_PROBES}"
    cecho "FAIL_THRESHOLD=${FAIL_THRESHOLD:-$DEFAULT_FAIL_THRESHOLD}"
    cecho "GP_PACKETS=${GP_PACKETS:-$DEFAULT_GP_PACKETS}"
    cecho "GP_RESULT_WAIT_SECONDS=${GP_RESULT_WAIT_SECONDS:-$DEFAULT_RESULT_WAIT_SECONDS}"
    cecho "COOLDOWN_SECONDS=${COOLDOWN_SECONDS:-$DEFAULT_COOLDOWN_SECONDS}"
    cecho "CURL_TIMEOUT=${CURL_TIMEOUT:-$DEFAULT_CURL_TIMEOUT}"
    cecho "POST_CHANGE_WAIT_SECONDS=${POST_CHANGE_WAIT_SECONDS:-$DEFAULT_POST_CHANGE_WAIT_SECONDS}"
    cecho "DNS_RESOLVER=${DNS_RESOLVER:-$DEFAULT_RESOLVER}"
    cecho "MIN_API_INTERVAL=${MIN_API_INTERVAL:-$DEFAULT_MIN_API_INTERVAL}"
}

history_days() {
    require_root
    local days="$1" since
    mkdirs
    since="$(date -d "${days} days ago" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')"
    cecho "📜 最近 ${days} 天 IP 更换记录"
    cecho "----------------------------------------"
    if [[ ! -s "$HISTORY_FILE" ]]; then
        warn "暂无记录。"
        return 0
    fi
    awk -F'|' -v since="$since" 'substr($1,1,10) >= since {print}' "$HISTORY_FILE" | tail -n 500 || true
}

uninstall_app() {
    require_root
    local ans
    warn "将停止服务并删除程序文件。默认保留配置和日志。"
    read -r -p "确认卸载？输入 1 继续，其它退出：" ans
    [[ "$ans" == "1" ]] || { info "已取消。"; return 0; }
    systemctl disable --now "$APP_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$INSTALL_PATH"
    ok "已卸载程序和 systemd 服务。"
    info "配置保留：${CONF_FILE}"
    info "日志保留：${LOG_FILE}"
    info "历史保留：${HISTORY_FILE}"
}

self_check() {
    require_root
    cecho "🩺 ${APP_VERSION} 自检"
    cecho "----------------------------------------"
    mkdirs
    if /usr/bin/env bash -n "${BASH_SOURCE[0]}"; then
        ok "脚本语法检查通过。"
    else
        err "脚本语法检查失败。"
        return 1
    fi
    for fn in install_packages quick_init install_self write_service globalping_measurement_create change_ip test_show_ip_api test_vendor_api daemon_loop view_logs view_journal_logs; do
        if declare -F "$fn" >/dev/null 2>&1; then
            ok "函数存在：$fn"
        else
            err "函数缺失：$fn"
            return 1
        fi
    done
    for c in curl jq flock systemctl; do
        if has_cmd "$c"; then
            ok "命令可用：$c"
        else
            warn "命令缺失：$c"
        fi
    done
    if [[ -w "$LOG_FILE" || ! -e "$LOG_FILE" ]]; then
        ok "文件日志可写：$LOG_FILE"
    else
        warn "文件日志当前不可写：$LOG_FILE"
    fi
    if has_cmd journalctl; then
        ok "journalctl 可用：可使用 ${APP_NAME} journal 查看原始日志"
    else
        warn "journalctl 不可用：只能查看文件日志"
    fi
    if [[ -f "$CONF_FILE" ]]; then
        load_config
        ok "配置文件存在：$CONF_FILE"
        cecho "  获取 IP API：$(mask_url "${SHOW_IP_API_URL:-}")"
        cecho "  更换 IP API：$(mask_url "${CHANGE_IP_API_URL:-}")"
        cecho "  检测目标：${CHECK_TARGET:-未配置}"
            else
        warn "配置文件不存在，首次使用请执行快速初始化。"
    fi
}

print_usage() {
    cat <<EOF_USAGE
${APP_VERSION}

用法：
  bash ${APP_NAME}.sh                 打开管理菜单
  bash ${APP_NAME}.sh init            快速初始化并安装
  ${APP_NAME} start                   启动服务
  ${APP_NAME} stop                    停止服务
  ${APP_NAME} restart                 重启服务
  ${APP_NAME} status                  查看状态
  ${APP_NAME} current-ip              显示检测目标当前解析 IP
  ${APP_NAME} check                   手动检测一次
  ${APP_NAME} test-show-api           手动测试获取当前 IP API
  ${APP_NAME} test-api                手动测试更换 IP API，不写入正式换 IP记录
  ${APP_NAME} change                  手动调用更换 IP API 换 IP
  ${APP_NAME} 8                       等同于 change，兼容菜单编号
  ${APP_NAME} edit-config             修改已有配置
  ${APP_NAME} history3                最近三天 IP 更换记录
  ${APP_NAME} history30               最近一个月 IP 更换记录
  ${APP_NAME} logs                    实时中文文件日志
  ${APP_NAME} journal                 查看 systemd journal 原始日志
  ${APP_NAME} config                  查看脱敏配置
  ${APP_NAME} doctor                  自检脚本/依赖/配置
  ${APP_NAME} uninstall               卸载
EOF_USAGE
}

menu() {
    require_root
    while true; do
        cecho ""
        cecho "🌏 ${APP_VERSION} 管理菜单"
        cecho "========================================"
        cecho "  1. 🚀 快速初始化 / 安装"
        cecho "  2. ▶️  启动自动检测服务"
        cecho "  3. ⏹️  停止自动检测服务"
        cecho "  4. 🔄 重启自动检测服务"
        cecho "  5. 📊 查看服务状态"
        cecho "  6. 🌐 显示当前 HiNet IP / DDNS 解析"
        cecho "  7. 🧪 手动检测一次 Globalping CN ping"
        cecho "  8. 🔁 手动调用更换 IP API"
        cecho "  9. 📜 查看最近三天 IP 更换记录"
        cecho " 10. 🗓️  查看最近一个月 IP 更换记录"
        cecho " 11. 🧾 查看实时日志"
        cecho " 12. 🔐 查看脱敏配置"
        cecho " 13. 🛠️  修改已有配置"
        cecho " 14. 🔎 手动测试获取当前 IP API（安全）"
        cecho " 15. 🧪 手动测试更换 IP API（不写正式记录）"
        cecho " 16. 🗑️  卸载脚本"
        cecho " 17. 🩺 脚本自检"
        cecho " 18. 🧾 查看 systemd journal 原始日志"
        cecho "  0. 🚪 退出"
        cecho "========================================"
        read -r -p "请输入选项 [0-18]：" choice
        choice="$(normalize_choice "$choice")"
        case "$choice" in
            1|init|install) quick_init ;;
            2|start) service_start ;;
            3|stop) service_stop ;;
            4|restart) service_restart ;;
            5|status) service_status ;;
            6|ip|showip|current-ip) show_current_ip ;;
            7|check|test) run_single_check ;;
            8|change|change-ip|manual) change_ip "manual_menu" ;;
            9|history3) history_days 3 ;;
            10|history30) history_days 30 ;;
            11|log|logs) view_logs ;;
            12|config) show_config_masked ;;
            13|edit|edit-config|modify|settings) edit_config ;;
            14|test-show-api|showapi|show-api) test_show_ip_api ;;
            15|test-api|test-change-api|apitest|vendor-test) test_vendor_api ;;
            16|uninstall|remove) uninstall_app ;;
            17|doctor|check-script|self-check) self_check ;;
            18|journal|journal-logs) view_journal_logs ;;
            0|q|quit|exit) exit 0 ;;
            *) warn "无效选项：${choice:-空输入}，请输入 0-18；手动换 IP 可输入 8 或 change。" ;;
        esac
    done
}

main() {
    local cmd="${1:-menu}"
    case "$cmd" in
        init|install) quick_init ;;
        start) service_start ;;
        stop) service_stop ;;
        restart) service_restart ;;
        status) service_status ;;
        daemon) daemon_loop ;;
        current-ip|showip|ip) show_current_ip ;;
        check|test) run_single_check ;;
        test-show-api|showapi|show-api|14) test_show_ip_api ;;
        test-api|test-change-api|apitest|vendor-test|15) test_vendor_api ;;
        change|change-ip|manual|8) change_ip "manual_cli" ;;
        edit|edit-config|modify|settings|13) edit_config ;;
        history3) history_days 3 ;;
        history30) history_days 30 ;;
        logs|log|11) view_logs ;;
        journal|journal-logs|18) view_journal_logs ;;
        config) show_config_masked ;;
        doctor|check-script|self-check|17) self_check ;;
        uninstall|remove) uninstall_app ;;
        help|-h|--help) print_usage ;;
        menu|*) menu ;;
    esac
}

main "$@"
