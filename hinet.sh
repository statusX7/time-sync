#!/usr/bin/env bash
# ============================================================
# hinet-gfw-changeip-v1.0.sh
# HiNet 被墙检测 + Globalping 中国节点 ping 弱检测 + API 自动换 IP
# 适合上传 GitHub：脚本本身不包含任何敏感信息，敏感 API 写入 /etc 配置文件
# ============================================================

set -Eeuo pipefail

APP_NAME="hinet-gfw-changeip"
APP_VERSION="hinet-gfw-changeip-v1.0"
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

GLOBALPING_API_BASE="https://api.globalping.io/v1"

# 默认值：快速初始化时可改
DEFAULT_CHECK_INTERVAL="60"
DEFAULT_CN_PROBES="2"
DEFAULT_FAIL_THRESHOLD="3"
DEFAULT_GP_PACKETS="3"
DEFAULT_RESULT_WAIT_SECONDS="35"
DEFAULT_COOLDOWN_SECONDS="600"
DEFAULT_CURL_TIMEOUT="35"

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
    mkdir -p "$LOG_DIR"
    printf '[%s] %s\n' "$(now_human)" "$*" | tee -a "$LOG_FILE" >/dev/null
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
    local pkgs=(curl jq ca-certificates util-linux)
    local missing=()
    for c in curl jq flock; do
        has_cmd "$c" || missing+=("$c")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    warn "检测到缺少依赖：${missing[*]}，准备自动安装。"
    if has_cmd apt-get; then
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
    elif has_cmd dnf; then
        dnf install -y "${pkgs[@]}"
    elif has_cmd yum; then
        yum install -y epel-release || true
        yum install -y "${pkgs[@]}"
    elif has_cmd apk; then
        apk add --no-cache curl jq ca-certificates util-linux
    else
        err "无法自动识别包管理器，请手动安装：curl jq ca-certificates util-linux"
        exit 1
    fi

    for c in curl jq flock; do
        has_cmd "$c" || { err "依赖 $c 仍不可用，请手动安装后重试。"; exit 1; }
    done
}

mask_url() {
    local s="${1:-}"
    [[ -z "$s" ]] && { printf '未配置'; return 0; }
    # 脱敏常见 query key，避免泄漏 apikey/token/key/password/secret
    printf '%s' "$s" | sed -E 's#([?&][^=]*(api[_-]?key|apikey|token|key|password|passwd|secret)[^=]*=)[^&]+#\1***#Ig'
}

quote_env() {
    # 生成可被 bash source 的安全值
    printf '%q' "$1"
}

load_config() {
    if [[ -f "$CONF_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
    fi

    SHOW_IP_API_URL="${SHOW_IP_API_URL:-}"
    CHANGE_IP_API_URL="${CHANGE_IP_API_URL:-}"
    CHECK_INTERVAL="${CHECK_INTERVAL:-$DEFAULT_CHECK_INTERVAL}"
    CN_PROBES="${CN_PROBES:-$DEFAULT_CN_PROBES}"
    FAIL_THRESHOLD="${FAIL_THRESHOLD:-$DEFAULT_FAIL_THRESHOLD}"
    GP_PACKETS="${GP_PACKETS:-$DEFAULT_GP_PACKETS}"
    GP_RESULT_WAIT_SECONDS="${GP_RESULT_WAIT_SECONDS:-$DEFAULT_RESULT_WAIT_SECONDS}"
    COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-$DEFAULT_COOLDOWN_SECONDS}"
    CURL_TIMEOUT="${CURL_TIMEOUT:-$DEFAULT_CURL_TIMEOUT}"
}

save_config() {
    mkdirs
    cat > "$CONF_FILE" <<EOF
# ${APP_NAME} config
# 由 ${APP_VERSION} 生成。敏感 URL 不要上传 GitHub。
SHOW_IP_API_URL=$(quote_env "$SHOW_IP_API_URL")
CHANGE_IP_API_URL=$(quote_env "$CHANGE_IP_API_URL")
CHECK_INTERVAL=$(quote_env "$CHECK_INTERVAL")
CN_PROBES=$(quote_env "$CN_PROBES")
FAIL_THRESHOLD=$(quote_env "$FAIL_THRESHOLD")
GP_PACKETS=$(quote_env "$GP_PACKETS")
GP_RESULT_WAIT_SECONDS=$(quote_env "$GP_RESULT_WAIT_SECONDS")
COOLDOWN_SECONDS=$(quote_env "$COOLDOWN_SECONDS")
CURL_TIMEOUT=$(quote_env "$CURL_TIMEOUT")
EOF
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

validate_config_or_exit() {
    load_config
    [[ -n "$SHOW_IP_API_URL" ]] || { err "未配置 SHOW_IP_API_URL，请先执行快速初始化。"; exit 1; }
    [[ -n "$CHANGE_IP_API_URL" ]] || { err "未配置 CHANGE_IP_API_URL，请先执行快速初始化。"; exit 1; }
    validate_number "$CHECK_INTERVAL" 30 3600 "检测间隔秒"
    validate_number "$CN_PROBES" 1 2 "中国节点数量"
    validate_number "$FAIL_THRESHOLD" 1 20 "连续失败阈值"
    validate_number "$GP_PACKETS" 1 10 "每节点 ping 包数量"
    validate_number "$GP_RESULT_WAIT_SECONDS" 10 120 "Globalping 结果等待秒数"
    validate_number "$COOLDOWN_SECONDS" 0 86400 "换 IP 冷却秒数"
    validate_number "$CURL_TIMEOUT" 5 120 "curl 超时秒数"
}

# -----------------------------
# IP 解析与校验
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

    # 排除私网、回环、链路本地、CGNAT、组播/保留等，避免误把 URL 里的内网 vmip 当成当前公网 IP
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

# -----------------------------
# API：显示 / 更换 IP
# -----------------------------
http_get_silent() {
    local url="$1"
    curl -fsSL --connect-timeout 10 --max-time "$CURL_TIMEOUT" \
        -A "${APP_NAME}/${APP_VERSION}" \
        "$url"
}

get_current_ip() {
    load_config
    local body ip
    body="$(http_get_silent "$SHOW_IP_API_URL")" || return 1
    ip="$(extract_public_ipv4 "$body")" || return 1
    printf '%s\n' "$ip"
}

show_current_ip() {
    validate_config_or_exit
    local ip
    if ip="$(get_current_ip)"; then
        ok "当前 HiNet 公网 IP：${ip}"
    else
        err "获取当前 IP 失败。请检查 showip API 是否可访问，以及返回内容是否包含公网 IPv4。"
        return 1
    fi
}

append_history() {
    local old_ip="$1" new_ip="$2" reason="$3" note="${4:-}"
    mkdirs
    printf '%s|old=%s|new=%s|reason=%s|note=%s\n' \
        "$(now_human)" "${old_ip:-unknown}" "${new_ip:-unknown}" "${reason:-manual}" "${note:-}" >> "$HISTORY_FILE"
}

change_ip() {
    validate_config_or_exit
    local reason="${1:-manual}" old_ip="" body new_ip after_ip note=""

    old_ip="$(get_current_ip 2>/dev/null || true)"
    log "🔁 准备调用换 IP API，reason=${reason}，old_ip=${old_ip:-unknown}"

    body="$(http_get_silent "$CHANGE_IP_API_URL")" || {
        log "❌ 换 IP API 请求失败，reason=${reason}"
        return 1
    }

    new_ip="$(extract_public_ipv4 "$body" 2>/dev/null || true)"
    if [[ -z "$new_ip" ]]; then
        # 有些 API 只返回成功文本，不直接返回新 IP；稍等后用 showip 再确认
        sleep 8
        after_ip="$(get_current_ip 2>/dev/null || true)"
        new_ip="$after_ip"
        note="new_ip_from_showip"
    else
        note="new_ip_from_change_api"
    fi

    if [[ -z "$new_ip" ]]; then
        log "❌ 换 IP API 已请求，但未能解析新公网 IP。"
        append_history "$old_ip" "unknown" "$reason" "parse_failed"
        return 1
    fi

    append_history "$old_ip" "$new_ip" "$reason" "$note"
    log "✅ 换 IP 完成：${old_ip:-unknown} -> ${new_ip}，reason=${reason}"
    ok "换 IP 完成：${old_ip:-unknown} -> ${new_ip}"
    return 0
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
    # stdin: measurement JSON
    # 输出三列：status total_results ok_results
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

globalping_check_ip() {
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
    local ip rc
    ip="$(get_current_ip)" || { err "获取当前 IP 失败，无法检测。"; return 1; }
    info "开始检测当前 IP：${ip}，Globalping 中国节点：${CN_PROBES} 个。"
    if globalping_check_ip "$ip"; then
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
    LAST_CHECK_EPOCH=0
    LAST_TARGET_IP=""
    LAST_RESULT="unknown"
    [[ -f "$STATUS_FILE" ]] && source "$STATUS_FILE" || true
    FAILURE_COUNT="${FAILURE_COUNT:-0}"
    LAST_CHANGE_EPOCH="${LAST_CHANGE_EPOCH:-0}"
    LAST_CHECK_EPOCH="${LAST_CHECK_EPOCH:-0}"
    LAST_TARGET_IP="${LAST_TARGET_IP:-}"
    LAST_RESULT="${LAST_RESULT:-unknown}"
}

save_status() {
    mkdirs
    cat > "$STATUS_FILE" <<EOF
FAILURE_COUNT=$(quote_env "${FAILURE_COUNT:-0}")
LAST_CHANGE_EPOCH=$(quote_env "${LAST_CHANGE_EPOCH:-0}")
LAST_CHECK_EPOCH=$(quote_env "${LAST_CHECK_EPOCH:-0}")
LAST_TARGET_IP=$(quote_env "${LAST_TARGET_IP:-}")
LAST_RESULT=$(quote_env "${LAST_RESULT:-unknown}")
EOF
    chmod 600 "$STATUS_FILE"
}

# -----------------------------
# 后台守护
# -----------------------------
daemon_loop() {
    require_root
    mkdirs
    install_packages
    validate_config_or_exit

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "⚠️ 已有守护进程在运行，退出。"
        exit 0
    fi

    load_status
    log "🚀 ${APP_VERSION} 守护进程启动。interval=${CHECK_INTERVAL}s, cn_probes=${CN_PROBES}, threshold=${FAIL_THRESHOLD}, cooldown=${COOLDOWN_SECONDS}s"

    while true; do
        load_config
        load_status

        local ip="" rc=2 now last_delta
        now="$(now_epoch)"
        LAST_CHECK_EPOCH="$now"

        ip="$(get_current_ip 2>/dev/null || true)"
        if [[ -z "$ip" ]]; then
            LAST_RESULT="showip_failed"
            save_status
            log "⚠️ 获取当前 IP 失败，本轮跳过，不计入连续失败。"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        LAST_TARGET_IP="$ip"
        globalping_check_ip "$ip"
        rc=$?

        if [[ "$rc" -eq 0 ]]; then
            FAILURE_COUNT=0
            LAST_RESULT="ok"
            save_status
        elif [[ "$rc" -eq 1 ]]; then
            FAILURE_COUNT=$(( FAILURE_COUNT + 1 ))
            LAST_RESULT="cn_ping_failed"
            save_status
            log "⚠️ 连续失败计数：${FAILURE_COUNT}/${FAIL_THRESHOLD}，target=${ip}"

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
        fi

        sleep "$CHECK_INTERVAL"
    done
}

# -----------------------------
# systemd / 安装卸载
# -----------------------------
write_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=HiNet GFW Auto Change IP by Globalping CN Ping
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_PATH} daemon
Restart=always
RestartSec=15
WorkingDirectory=/
Environment=LANG=C.UTF-8
Environment=LC_ALL=C.UTF-8

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
}

install_self() {
    require_root
    has_cmd systemctl || { err "当前系统未检测到 systemctl。本脚本使用 systemd 管理后台服务，请改用 Debian/Ubuntu/CentOS/RHEL/Rocky/Alma 等 systemd 系统。"; exit 1; }
    install_packages
    mkdirs

    local src="${BASH_SOURCE[0]}"
    if [[ "$src" != "$INSTALL_PATH" ]]; then
        cp -f "$src" "$INSTALL_PATH"
        chmod 755 "$INSTALL_PATH"
    else
        chmod 755 "$INSTALL_PATH"
    fi

    write_service
    ok "安装完成：${INSTALL_PATH}"
    ok "服务文件：${SERVICE_FILE}"
}

quick_init() {
    require_root
    install_self

    cecho ""
    cecho "🧭 ${APP_VERSION} 快速初始化"
    cecho "----------------------------------------"
    warn "请输入你的真实 API 地址。脚本不会内置示例 URL，也不会把敏感信息上传 GitHub。"
    cecho ""

    local show_url change_url interval probes threshold packets wait cooldown timeout start_now

    read -r -p "🔎 请输入【显示当前 IP】API 地址：" show_url
    while [[ -z "$show_url" ]]; do
        read -r -p "🔎 显示当前 IP API 地址不能为空，请重新输入：" show_url
    done

    read -r -p "🔁 请输入【更换 IP】API 地址：" change_url
    while [[ -z "$change_url" ]]; do
        read -r -p "🔁 更换 IP API 地址不能为空，请重新输入：" change_url
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

    SHOW_IP_API_URL="$show_url"
    CHANGE_IP_API_URL="$change_url"
    CHECK_INTERVAL="$interval"
    CN_PROBES="$probes"
    FAIL_THRESHOLD="$threshold"
    GP_PACKETS="$packets"
    GP_RESULT_WAIT_SECONDS="$wait"
    COOLDOWN_SECONDS="$cooldown"
    CURL_TIMEOUT="$timeout"

    validate_number "$CHECK_INTERVAL" 30 3600 "检测间隔秒"
    validate_number "$CN_PROBES" 1 2 "中国节点数量"
    validate_number "$FAIL_THRESHOLD" 1 20 "连续失败阈值"
    validate_number "$GP_PACKETS" 1 10 "每节点 ping 包数量"
    validate_number "$GP_RESULT_WAIT_SECONDS" 10 120 "Globalping 结果等待秒数"
    validate_number "$COOLDOWN_SECONDS" 0 86400 "换 IP 冷却秒数"
    validate_number "$CURL_TIMEOUT" 5 120 "curl 超时秒数"

    save_config
    ok "配置已保存：${CONF_FILE}（权限 600）"
    info "显示 IP API：$(mask_url "$SHOW_IP_API_URL")"
    info "换 IP API：$(mask_url "$CHANGE_IP_API_URL")"

    cecho ""
    info "正在测试 showip API..."
    if show_current_ip; then
        ok "showip API 测试通过。"
    else
        warn "showip API 测试失败，但配置已保存。请确认 API 地址、网络和返回内容。"
    fi

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
    cecho "  检测间隔：${CHECK_INTERVAL:-未配置}s"
    cecho "  中国节点：${CN_PROBES:-未配置} 个"
    cecho "  失败阈值：${FAIL_THRESHOLD:-未配置} 次"
    cecho "  冷却时间：${COOLDOWN_SECONDS:-未配置}s"
    cecho "  showip：$(mask_url "${SHOW_IP_API_URL:-}")"
    cecho "  change：$(mask_url "${CHANGE_IP_API_URL:-}")"
    cecho ""
    cecho "📊 最近状态："
    cecho "  LAST_TARGET_IP=${LAST_TARGET_IP:-unknown}"
    cecho "  LAST_RESULT=${LAST_RESULT:-unknown}"
    cecho "  FAILURE_COUNT=${FAILURE_COUNT:-0}"
    cecho "  LAST_CHECK_EPOCH=${LAST_CHECK_EPOCH:-0}"
    cecho "  LAST_CHANGE_EPOCH=${LAST_CHANGE_EPOCH:-0}"
}

view_logs() {
    require_root
    mkdirs
    info "按 Ctrl+C 退出日志。"
    tail -n 80 -f "$LOG_FILE"
}

show_config_masked() {
    require_root
    load_config
    cecho "🔐 当前配置（已脱敏）"
    cecho "----------------------------------------"
    cecho "SHOW_IP_API_URL=$(mask_url "${SHOW_IP_API_URL:-}")"
    cecho "CHANGE_IP_API_URL=$(mask_url "${CHANGE_IP_API_URL:-}")"
    cecho "CHECK_INTERVAL=${CHECK_INTERVAL:-$DEFAULT_CHECK_INTERVAL}"
    cecho "CN_PROBES=${CN_PROBES:-$DEFAULT_CN_PROBES}"
    cecho "FAIL_THRESHOLD=${FAIL_THRESHOLD:-$DEFAULT_FAIL_THRESHOLD}"
    cecho "GP_PACKETS=${GP_PACKETS:-$DEFAULT_GP_PACKETS}"
    cecho "GP_RESULT_WAIT_SECONDS=${GP_RESULT_WAIT_SECONDS:-$DEFAULT_RESULT_WAIT_SECONDS}"
    cecho "COOLDOWN_SECONDS=${COOLDOWN_SECONDS:-$DEFAULT_COOLDOWN_SECONDS}"
    cecho "CURL_TIMEOUT=${CURL_TIMEOUT:-$DEFAULT_CURL_TIMEOUT}"
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

print_usage() {
    cat <<EOF
${APP_VERSION}

用法：
  bash ${APP_NAME}.sh                 打开管理菜单
  bash ${APP_NAME}.sh init            快速初始化并安装
  ${APP_NAME} start                   启动服务
  ${APP_NAME} stop                    停止服务
  ${APP_NAME} restart                 重启服务
  ${APP_NAME} status                  查看状态
  ${APP_NAME} current-ip              显示当前 IP
  ${APP_NAME} check                   手动检测一次
  ${APP_NAME} change                  手动更换 IP
  ${APP_NAME} history3                最近三天 IP 更换记录
  ${APP_NAME} history30               最近一个月 IP 更换记录
  ${APP_NAME} logs                    实时日志
  ${APP_NAME} config                  查看脱敏配置
  ${APP_NAME} uninstall               卸载
EOF
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
        cecho "  6. 🌐 显示当前 HiNet IP"
        cecho "  7. 🧪 手动检测一次 Globalping CN ping"
        cecho "  8. 🔁 手动更换 IP"
        cecho "  9. 📜 查看最近三天 IP 更换记录"
        cecho " 10. 🗓️  查看最近一个月 IP 更换记录"
        cecho " 11. 🧾 查看实时日志"
        cecho " 12. 🔐 查看脱敏配置"
        cecho " 13. 🗑️  卸载脚本"
        cecho "  0. 🚪 退出"
        cecho "========================================"
        read -r -p "请输入选项 [0-13]：" choice
        case "$choice" in
            1) quick_init ;;
            2) service_start ;;
            3) service_stop ;;
            4) service_restart ;;
            5) service_status ;;
            6) show_current_ip ;;
            7) run_single_check ;;
            8) change_ip "manual_menu" ;;
            9) history_days 3 ;;
            10) history_days 30 ;;
            11) view_logs ;;
            12) show_config_masked ;;
            13) uninstall_app ;;
            0) exit 0 ;;
            *) warn "无效选项，请重新输入。" ;;
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
        change|change-ip) change_ip "manual_cli" ;;
        history3) history_days 3 ;;
        history30) history_days 30 ;;
        logs|log) view_logs ;;
        config) show_config_masked ;;
        uninstall|remove) uninstall_app ;;
        help|-h|--help) print_usage ;;
        menu|*) menu ;;
    esac
}

main "$@"
