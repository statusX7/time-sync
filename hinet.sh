#!/usr/bin/env bash
# ============================================================
# hinet-gfw-changeip-v2.3.sh
# HiNet 被墙检测 + Globalping 中国节点 ping 弱检测 + 双 API 自动换 IP
# v2.3：改为 systemd timer + 独立 runner 包装器，强制中文文件日志落盘，彻底排查/修复 oneshot 空日志问题
# 适合上传 GitHub：脚本本身不包含任何敏感信息，敏感 API 写入 /etc 配置文件
# ============================================================

set -u -o pipefail

APP_NAME="hinet-gfw-changeip"
APP_VERSION="hinet-gfw-changeip-v2.3"
INSTALL_PATH="/usr/local/bin/${APP_NAME}"
CONF_DIR="/etc/${APP_NAME}"
CONF_FILE="${CONF_DIR}/config.env"
STATE_DIR="/var/lib/${APP_NAME}"
LOG_DIR="/var/log/${APP_NAME}"
LOG_FILE="${LOG_DIR}/${APP_NAME}.log"
HISTORY_FILE="${STATE_DIR}/ip_change_history.log"
STATUS_FILE="${STATE_DIR}/status.env"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
TIMER_FILE="/etc/systemd/system/${APP_NAME}.timer"
RUNNER_PATH="/usr/local/libexec/${APP_NAME}/run-check"
CHANGE_LOCK_FILE="/run/${APP_NAME}-change.lock"
GLOBALPING_API_BASE="https://api.globalping.io/v1"

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

cecho() { printf '%b\n' "$*"; }
info() { cecho "ℹ️  $*"; }
ok() { cecho "✅ $*"; }
warn() { cecho "⚠️  $*"; }
err() { cecho "❌ $*" >&2; }
now_human() { date '+%Y-%m-%d %H:%M:%S%z'; }
now_epoch() { date '+%s'; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

mkdirs() {
    mkdir -p "$CONF_DIR" "$STATE_DIR" "$LOG_DIR"
    chmod 700 "$CONF_DIR" "$STATE_DIR" 2>/dev/null || true
    chmod 755 "$LOG_DIR" 2>/dev/null || true
    touch "$LOG_FILE" "$HISTORY_FILE" "$STATUS_FILE" 2>/dev/null || true
    chmod 600 "$LOG_FILE" "$HISTORY_FILE" "$STATUS_FILE" 2>/dev/null || true
}

log() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    local line
    line="[$(now_human)] $*"
    printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || printf '%s\n' "[$(now_human)] ⚠️ 文件日志写入失败：${LOG_FILE}" >&2
    printf '%s\n' "$line"
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请使用 root 执行：sudo bash $0"
        exit 1
    fi
}

number_in_range() {
    local n="${1:-}" min="${2:-}" max="${3:-}"
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    (( n >= min && n <= max ))
}

normalize_choice() {
    printf '%s' "${1:-}" | sed 's/[[:space:]]//g; s/０/0/g; s/１/1/g; s/２/2/g; s/３/3/g; s/４/4/g; s/５/5/g; s/６/6/g; s/７/7/g; s/８/8/g; s/９/9/g'
}

quote_env() { printf '%q' "$1"; }

mask_url() {
    local s="${1:-}"
    [[ -z "$s" ]] && { printf '未配置'; return 0; }
    printf '%s' "$s" | sed -E 's#([?&][^=]*(api[_-]?key|apikey|token|key|password|passwd|secret|auth)[^=]*=)[^&]+#\1***#Ig'
}

install_packages() {
    local need=0
    for c in curl jq flock; do has_cmd "$c" || need=1; done
    has_cmd dig || need=1
    [[ "$need" -eq 0 ]] && return 0

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
install_dependencies() { install_packages; }

load_config() {
    if [[ -f "$CONF_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
    fi
    SHOW_IP_API_URL="${SHOW_IP_API_URL:-}"
    CHANGE_IP_API_URL="${CHANGE_IP_API_URL:-${HINET_API_URL:-}}"
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

    number_in_range "$CHECK_INTERVAL" 30 3600 || CHECK_INTERVAL="$DEFAULT_CHECK_INTERVAL"
    number_in_range "$CN_PROBES" 1 50 || CN_PROBES="$DEFAULT_CN_PROBES"
    number_in_range "$FAIL_THRESHOLD" 1 30 || FAIL_THRESHOLD="$DEFAULT_FAIL_THRESHOLD"
    number_in_range "$GP_PACKETS" 1 20 || GP_PACKETS="$DEFAULT_GP_PACKETS"
    number_in_range "$GP_RESULT_WAIT_SECONDS" 10 180 || GP_RESULT_WAIT_SECONDS="$DEFAULT_RESULT_WAIT_SECONDS"
    number_in_range "$COOLDOWN_SECONDS" 0 86400 || COOLDOWN_SECONDS="$DEFAULT_COOLDOWN_SECONDS"
    number_in_range "$CURL_TIMEOUT" 5 180 || CURL_TIMEOUT="$DEFAULT_CURL_TIMEOUT"
    number_in_range "$POST_CHANGE_WAIT_SECONDS" 0 1800 || POST_CHANGE_WAIT_SECONDS="$DEFAULT_POST_CHANGE_WAIT_SECONDS"
    number_in_range "$MIN_API_INTERVAL" 0 3600 || MIN_API_INTERVAL="$DEFAULT_MIN_API_INTERVAL"
}

save_config() {
    mkdirs
    cat > "$CONF_FILE" <<EOF_CONF
# ${APP_NAME} config
# 由 ${APP_VERSION} 生成。敏感 URL 不要上传 GitHub。
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

load_status() {
    FAILURE_COUNT=0
    LAST_CHANGE_EPOCH=0
    LAST_API_CALL_EPOCH=0
    LAST_CHECK_EPOCH=0
    LAST_TARGET=""
    LAST_RESOLVED_IP=""
    LAST_RESULT="unknown"
    LAST_MEASUREMENT_ID=""
    [[ -f "$STATUS_FILE" ]] && source "$STATUS_FILE" 2>/dev/null || true
    FAILURE_COUNT="${FAILURE_COUNT:-0}"
    LAST_CHANGE_EPOCH="${LAST_CHANGE_EPOCH:-0}"
    LAST_API_CALL_EPOCH="${LAST_API_CALL_EPOCH:-0}"
    LAST_CHECK_EPOCH="${LAST_CHECK_EPOCH:-0}"
    LAST_TARGET="${LAST_TARGET:-}"
    LAST_RESOLVED_IP="${LAST_RESOLVED_IP:-}"
    LAST_RESULT="${LAST_RESULT:-unknown}"
    LAST_MEASUREMENT_ID="${LAST_MEASUREMENT_ID:-}"
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
LAST_MEASUREMENT_ID=$(quote_env "${LAST_MEASUREMENT_ID:-}")
EOF_STATUS
    chmod 600 "$STATUS_FILE" 2>/dev/null || true
}

validate_config_safe() {
    load_config
    [[ -n "$SHOW_IP_API_URL" ]] || { log "❌ 配置缺失：SHOW_IP_API_URL 获取当前 IP API 未配置。"; return 1; }
    [[ -n "$CHANGE_IP_API_URL" ]] || { log "❌ 配置缺失：CHANGE_IP_API_URL 更换 IP API 未配置。"; return 1; }
    [[ -n "$CHECK_TARGET" ]] || { log "❌ 配置缺失：CHECK_TARGET 检测目标未配置。"; return 1; }
    return 0
}

validate_config_or_exit() {
    validate_config_safe || { err "配置不完整，请先执行：${APP_NAME} init"; exit 1; }
}

is_public_ipv4() {
    local ip="$1" a b c d IFS=.
    read -r a b c d <<< "$ip"
    for x in "$a" "$b" "$c" "$d"; do [[ "$x" =~ ^[0-9]+$ ]] && (( x >= 0 && x <= 255 )) || return 1; done
    (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1
    (( a == 169 && b == 254 )) && return 1
    (( a == 172 && b >= 16 && b <= 31 )) && return 1
    (( a == 192 && b == 168 )) && return 1
    (( a == 198 && (b == 18 || b == 19) )) && return 1
    return 0
}

extract_public_ipv4() {
    local text="${1:-}" ip
    while read -r ip; do
        is_public_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
    done < <(printf '%s' "$text" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '!seen[$0]++')
    return 1
}

shorten() {
    local s="${1:-}"
    s="$(printf '%s' "$s" | tr '\n\r\t' '   ' | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-360)"
    printf '%s' "$s"
}

curl_get() {
    local url="$1" timeout="${2:-$CURL_TIMEOUT}"
    curl -sS -L --connect-timeout 10 --max-time "$timeout" "$url" 2>&1
}

resolve_target_ip() {
    local target="${1:-$CHECK_TARGET}" resolver="${DNS_RESOLVER:-$DEFAULT_RESOLVER}" ip=""
    if [[ "$target" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && is_public_ipv4 "$target"; then
        printf '%s' "$target"; return 0
    fi
    if has_cmd dig; then
        ip="$(dig +short A "$target" "@${resolver}" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | while read -r x; do is_public_ipv4 "$x" && { echo "$x"; break; }; done)"
    fi
    if [[ -z "$ip" ]] && has_cmd getent; then
        ip="$(getent ahostsv4 "$target" 2>/dev/null | awk '{print $1}' | while read -r x; do is_public_ipv4 "$x" && { echo "$x"; break; }; done)"
    fi
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
    return 1
}

get_current_ip_from_api() {
    load_config
    local body ip
    body="$(curl_get "$SHOW_IP_API_URL" "$CURL_TIMEOUT")"
    ip="$(extract_public_ipv4 "$body" 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
        printf '%s' "$ip"
        return 0
    fi
    log "❌ 获取当前 IP API 未返回公网 IPv4。返回摘要：$(shorten "$body")"
    return 1
}

show_current_ip() {
    require_root
    load_config
    validate_config_or_exit
    local api_ip="" ddns_ip=""
    cecho "🌐 当前 HiNet IP / DDNS 解析"
    cecho "----------------------------------------"
    api_ip="$(get_current_ip_from_api 2>/dev/null || true)"
    ddns_ip="$(resolve_target_ip 2>/dev/null || true)"
    cecho "获取 IP API：$(mask_url "$SHOW_IP_API_URL")"
    cecho "API 当前 IP：${api_ip:-获取失败}"
    cecho "检测目标：${CHECK_TARGET}"
    cecho "DDNS 解析 IP：${ddns_ip:-解析失败}"
}

warn_if_showip_action() {
    local url="${1:-}"
    if printf '%s' "$url" | grep -qiE '([?&])action=showip(&|$)'; then
        warn "你填的【更换 IP API】里包含 action=showip，这通常更像查询 IP。确认它是真正更换 IP 的 API 后再保存。"
    fi
}

# -----------------------------
# Globalping 检测
# 返回码：0=至少一个 CN probe ping 正常；1=所有返回的 CN probe 均失败；2=API/探针异常，不计失败。
# -----------------------------
globalping_create_measurement() {
    local target="$1" payload body id
    payload="$(jq -nc \
        --arg target "$target" \
        --arg country "CN" \
        --argjson limit "${CN_PROBES:-2}" \
        --argjson packets "${GP_PACKETS:-3}" \
        '{type:"ping",target:$target,locations:[{country:$country,limit:$limit}],measurementOptions:{packets:$packets}}' 2>/dev/null)"
    [[ -n "$payload" ]] || { log "⚠️ 生成 Globalping 请求 JSON 失败。"; return 1; }
    body="$(curl -sS -L --connect-timeout 10 --max-time "$CURL_TIMEOUT" -H 'Content-Type: application/json' -d "$payload" "${GLOBALPING_API_BASE}/measurements" 2>&1)"
    id="$(printf '%s' "$body" | jq -r '.id // .measurementId // empty' 2>/dev/null)"
    if [[ -z "$id" || "$id" == "null" ]]; then
        log "⚠️ Globalping 创建 measurement 失败，不计入连续失败。返回摘要：$(shorten "$body")"
        return 1
    fi
    printf '%s' "$id"
}

globalping_parse_result() {
    jq -r '
      def norm: tostring | ascii_downcase;
      def num(x): (x | tonumber? // 0);
      def raw: (.result.rawOutput? // .rawOutput? // "");
      def rx: num(.result.stats.packetsReceived? // .result.stats.received? // .result.stats.receivedPackets? // .result.stats.packets_received? // 0);
      def loss: (.result.stats.packetLoss? // .result.stats.loss? // .result.stats.packet_loss? // 100 | tonumber? // 100);
      def probe_ok: ((rx > 0) or ((raw | test("(?i)(bytes from|ttl=|time=[0-9]+[.]?[0-9]*[[:space:]]*ms)"))) or (loss < 100));
      [.results[]?] as $r |
      ($r | length) as $total |
      ($r | map(select(probe_ok)) | length) as $ok |
      (.status // "unknown") as $status |
      [$status, $total, $ok] | @tsv
    ' 2>/dev/null
}

globalping_check_target() {
    load_config
    local target="${1:-$CHECK_TARGET}" id deadline body parsed status total okn
    log "🧪 Globalping 请求开始：target=${target}，country=CN，probes=${CN_PROBES}，packets=${GP_PACKETS}"
    id="$(globalping_create_measurement "$target")"
    if [[ -z "$id" ]]; then
        return 2
    fi
    LAST_MEASUREMENT_ID="$id"
    deadline=$(( $(now_epoch) + GP_RESULT_WAIT_SECONDS ))

    while true; do
        body="$(curl -sS -L --connect-timeout 10 --max-time "$CURL_TIMEOUT" "${GLOBALPING_API_BASE}/measurements/${id}" 2>&1)"
        parsed="$(printf '%s' "$body" | globalping_parse_result)"
        status="$(printf '%s' "$parsed" | awk -F'\t' '{print $1}')"
        total="$(printf '%s' "$parsed" | awk -F'\t' '{print $2}')"
        okn="$(printf '%s' "$parsed" | awk -F'\t' '{print $3}')"

        if [[ "$total" =~ ^[0-9]+$ && "$okn" =~ ^[0-9]+$ && "$total" -gt 0 ]]; then
            if [[ "$status" != "in-progress" && "$status" != "unknown" && "$status" != "" ]]; then
                if (( okn > 0 )); then
                    log "✅ Globalping CN ping 正常：target=${target}，ok=${okn}/${total}，measurement=${id}"
                    return 0
                fi
                log "❌ Globalping CN ping 全部失败：target=${target}，ok=0/${total}，measurement=${id}"
                return 1
            fi
        fi

        if (( $(now_epoch) >= deadline )); then
            if [[ "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]]; then
                if (( okn > 0 )); then
                    log "✅ Globalping CN ping 正常：target=${target}，ok=${okn}/${total}，measurement=${id}"
                    return 0
                fi
                log "❌ Globalping CN ping 全部失败：target=${target}，ok=0/${total}，measurement=${id}"
                return 1
            fi
            log "⚠️ Globalping 等待结果超时或无中国探针结果，measurement=${id}，不计入连续失败。最后状态=${status:-unknown}"
            return 2
        fi
        sleep 3
    done
}

run_single_check() {
    require_root
    validate_config_or_exit
    local resolved_ip rc
    resolved_ip="$(resolve_target_ip 2>/dev/null || true)"
    info "开始检测目标：${CHECK_TARGET}"
    [[ -n "$resolved_ip" ]] && info "当前解析 IP：${resolved_ip}"
    info "Globalping 中国节点：${CN_PROBES} 个。"
    globalping_check_target "$CHECK_TARGET"
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
        ok "检测结果：CN ping 正常。"
    elif [[ "$rc" -eq 1 ]]; then
        warn "检测结果：CN ping 全部失败。"
    else
        warn "检测结果：Globalping API/探针不可用，本次不应计为被墙失败。"
    fi
    return "$rc"
}

# -----------------------------
# 更换 IP
# -----------------------------
append_history() {
    local old_ip="$1" new_ip="$2" old_ddns="$3" new_ddns="$4" reason="$5" note="$6"
    mkdirs
    printf '%s\told_ip=%s\tnew_ip=%s\told_ddns=%s\tnew_ddns=%s\treason=%s\tnote=%s\n' \
        "$(now_human)" "$old_ip" "$new_ip" "$old_ddns" "$new_ddns" "$reason" "$note" >> "$HISTORY_FILE"
}

change_ip() {
    local reason="${1:-manual}" official="${2:-1}"
    require_root
    load_config
    validate_config_or_exit
    load_status
    mkdirs

    exec 8>"$CHANGE_LOCK_FILE"
    if ! flock -n 8; then
        log "⚠️ 更换 IP 锁被占用，已有换 IP 流程正在执行，本次跳过。reason=${reason}"
        return 1
    fi

    local now last_delta old_ip old_ddns body returned_ip new_ip new_ddns note
    now="$(now_epoch)"
    last_delta=$(( now - ${LAST_API_CALL_EPOCH:-0} ))
    if (( MIN_API_INTERVAL > 0 && LAST_API_CALL_EPOCH > 0 && last_delta < MIN_API_INTERVAL )); then
        log "⏳ 距离上次调用更换 IP API 仅 ${last_delta}s，小于最小间隔 ${MIN_API_INTERVAL}s，本次不调用。"
        return 1
    fi

    old_ip="$(get_current_ip_from_api 2>/dev/null || true)"
    old_ddns="$(resolve_target_ip 2>/dev/null || true)"
    log "🔁 准备调用更换 IP API，reason=${reason}，old_ip=${old_ip:-unknown}，old_ddns=${old_ddns:-unknown}，target=${CHECK_TARGET}"

    body="$(curl_get "$CHANGE_IP_API_URL" "$CURL_TIMEOUT")"
    LAST_API_CALL_EPOCH="$(now_epoch)"
    save_status
    log "🧾 更换 IP API 返回摘要：$(shorten "$body")"

    returned_ip="$(extract_public_ipv4 "$body" 2>/dev/null || true)"
    [[ -n "$returned_ip" ]] && log "ℹ️ 更换 IP API 返回公网 IP：${returned_ip}"

    if (( POST_CHANGE_WAIT_SECONDS > 0 )); then
        log "⏳ 等待 ${POST_CHANGE_WAIT_SECONDS} 秒后确认获取 API / DDNS 结果。"
        sleep "$POST_CHANGE_WAIT_SECONDS"
    fi

    new_ip="$(get_current_ip_from_api 2>/dev/null || true)"
    new_ddns="$(resolve_target_ip 2>/dev/null || true)"

    note="api_called"
    if [[ -n "$returned_ip" ]]; then
        note="api_returned_public_ip"
    fi
    if [[ -n "$old_ip" && -n "$new_ip" && "$old_ip" == "$new_ip" && -n "$old_ddns" && -n "$new_ddns" && "$old_ddns" == "$new_ddns" ]]; then
        log "⚠️ API 已调用，但当前 IP/DDNS 暂未变化：old_ip=${old_ip}，new_ip=${new_ip}，old_ddns=${old_ddns}，new_ddns=${new_ddns}。可能是 API 错误、DDNS 未更新或商家暂未完成切换。"
        note="api_called_but_ip_not_changed"
    fi

    log "✅ 换 IP 流程完成：${old_ip:-unknown} -> ${new_ip:-${returned_ip:-unknown}}，DDNS：${old_ddns:-unknown} -> ${new_ddns:-unknown}，reason=${reason}，note=${note}"
    LAST_CHANGE_EPOCH="$(now_epoch)"
    LAST_RESOLVED_IP="$new_ddns"
    save_status
    if [[ "$official" == "1" ]]; then
        append_history "${old_ip:-unknown}" "${new_ip:-${returned_ip:-unknown}}" "${old_ddns:-unknown}" "${new_ddns:-unknown}" "$reason" "$note"
    fi
    return 0
}

test_show_ip_api() {
    require_root
    load_config
    [[ -n "$SHOW_IP_API_URL" ]] || { err "获取当前 IP API 未配置。"; return 1; }
    local body ip
    body="$(curl_get "$SHOW_IP_API_URL" "$CURL_TIMEOUT")"
    ip="$(extract_public_ipv4 "$body" 2>/dev/null || true)"
    cecho "🔎 获取当前 IP API 测试"
    cecho "----------------------------------------"
    cecho "API：$(mask_url "$SHOW_IP_API_URL")"
    cecho "返回摘要：$(shorten "$body")"
    if [[ -n "$ip" ]]; then ok "提取公网 IP：${ip}"; else err "未提取到公网 IPv4。"; return 1; fi
}

test_vendor_api() {
    warn "这会调用【真正更换 IP API】，可能真的更换 HiNet IP；但不会写入正式换 IP 历史记录。"
    read -r -p "确认测试更换 IP API？输入 1 继续，其它取消：" yn
    yn="$(normalize_choice "$yn")"
    [[ "$yn" == "1" ]] || { warn "已取消。"; return 0; }
    change_ip "test_vendor_api" "0"
}

# -----------------------------
# 定时检测：systemd timer 触发的单次检查
# -----------------------------
check_once() {
    require_root
    mkdirs
    load_config
    load_status

    log "🧭 check-once entry：version=${APP_VERSION}，pid=$$，conf=${CONF_FILE}，log=${LOG_FILE}"

    if ! validate_config_safe; then
        LAST_RESULT="config_invalid"
        LAST_CHECK_EPOCH="$(now_epoch)"
        save_status
        log "💤 配置不可用，本轮不检测。"
        return 0
    fi

    local resolved_ip rc now last_delta
    resolved_ip="$(resolve_target_ip 2>/dev/null || true)"
    LAST_CHECK_EPOCH="$(now_epoch)"
    LAST_TARGET="$CHECK_TARGET"
    LAST_RESOLVED_IP="$resolved_ip"
    save_status

    log "🛰️ 定时检测开始：target=${CHECK_TARGET}，resolved_ip=${resolved_ip:-unknown}，failure=${FAILURE_COUNT}/${FAIL_THRESHOLD}，interval=${CHECK_INTERVAL}s"

    globalping_check_target "$CHECK_TARGET"
    rc=$?

    if [[ "$rc" -eq 0 ]]; then
        FAILURE_COUNT=0
        LAST_RESULT="ok"
        save_status
        log "✅ 定时判定：CN ping 正常，失败计数已清零。"
    elif [[ "$rc" -eq 1 ]]; then
        FAILURE_COUNT=$(( FAILURE_COUNT + 1 ))
        LAST_RESULT="cn_ping_failed"
        save_status
        log "⚠️ 定时判定：CN ping 全部失败，连续失败计数：${FAILURE_COUNT}/${FAIL_THRESHOLD}。"
        if (( FAILURE_COUNT >= FAIL_THRESHOLD )); then
            now="$(now_epoch)"
            last_delta=$(( now - ${LAST_CHANGE_EPOCH:-0} ))
            if (( COOLDOWN_SECONDS > 0 && LAST_CHANGE_EPOCH > 0 && last_delta < COOLDOWN_SECONDS )); then
                log "⏳ 达到失败阈值，但仍在冷却期：剩余 $(( COOLDOWN_SECONDS - last_delta )) 秒，本次不换 IP。"
            else
                log "🚨 达到失败阈值，开始自动调用更换 IP API。"
                if change_ip "globalping_cn_ping_failed_${FAILURE_COUNT}_times" "1"; then
                    FAILURE_COUNT=0
                    LAST_RESULT="changed_ip"
                    LAST_RESOLVED_IP="$(resolve_target_ip 2>/dev/null || true)"
                    save_status
                    log "✅ 自动换 IP 完成，失败计数已清零。"
                else
                    LAST_RESULT="change_ip_failed"
                    save_status
                    log "❌ 自动换 IP 失败，保留失败计数，等待下一轮。"
                fi
            fi
        fi
    else
        LAST_RESULT="globalping_unknown"
        save_status
        log "⚠️ 定时判定：Globalping API/探针异常，本轮不计入连续失败。"
    fi

    log "🏁 定时检测结束：last_result=${LAST_RESULT}，failure_count=${FAILURE_COUNT}/${FAIL_THRESHOLD}"
    return 0
}


write_runner() {
    mkdir -p "$(dirname "$RUNNER_PATH")" "$LOG_DIR" "$STATE_DIR"
    cat > "$RUNNER_PATH" <<EOF_RUNNER
#!/usr/bin/env bash
# ${APP_NAME} systemd runner - generated by ${APP_VERSION}
set +e
APP_NAME="${APP_NAME}"
INSTALL_PATH="${INSTALL_PATH}"
LOG_DIR="${LOG_DIR}"
LOG_FILE="${LOG_FILE}"
CONF_FILE="${CONF_FILE}"
STATUS_FILE="${STATUS_FILE}"
mkdir -p "\$LOG_DIR" "${STATE_DIR}" 2>/dev/null || true
now_human_runner() { date '+%Y-%m-%d %H:%M:%S%z'; }
rlog() {
    local line="[\$(now_human_runner)] \$*"
    printf '%s\n' "\$line" >> "\$LOG_FILE" 2>/dev/null || true
    printf '%s\n' "\$line"
}
rlog "🚪 systemd runner entry：准备执行定时检测，pid=\$\$，script=\$INSTALL_PATH"
if [[ ! -x "\$INSTALL_PATH" ]]; then
    rlog "❌ 主脚本不可执行或不存在：\$INSTALL_PATH"
    exit 0
fi
if [[ ! -f "\$CONF_FILE" ]]; then
    rlog "❌ 配置文件不存在：\$CONF_FILE，请先执行 init。"
    exit 0
fi
/bin/bash "\$INSTALL_PATH" check-once >> "\$LOG_FILE" 2>&1
rc=\$?
rlog "🏁 systemd runner exit：check-once 已结束，rc=\$rc。"
exit 0
EOF_RUNNER
    chmod 755 "$RUNNER_PATH"
}

# -----------------------------
# systemd timer / 安装卸载
# -----------------------------
write_units() {
    load_config
    local interval="${CHECK_INTERVAL:-60}"
    number_in_range "$interval" 30 3600 || interval=60
    write_runner

    cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=HiNet GFW Auto Change IP - one-shot Globalping CN check
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${RUNNER_PATH}
TimeoutStartSec=900
WorkingDirectory=/
Environment=LANG=C.UTF-8
Environment=LC_ALL=C.UTF-8
StandardOutput=journal
StandardError=journal
EOF_SERVICE

    cat > "$TIMER_FILE" <<EOF_TIMER
[Unit]
Description=Run HiNet GFW Auto Change IP check every ${interval}s

[Timer]
OnBootSec=30s
OnUnitActiveSec=${interval}s
AccuracySec=1s
Unit=${APP_NAME}.service
Persistent=false

[Install]
WantedBy=timers.target
EOF_TIMER

    chmod 644 "$SERVICE_FILE" "$TIMER_FILE"
    systemctl daemon-reload
}

install_self() {
    require_root
    has_cmd systemctl || { err "当前系统未检测到 systemctl。本脚本使用 systemd 管理后台定时器。"; exit 1; }
    install_packages
    mkdirs
    local src="${BASH_SOURCE[0]}"
    if [[ "$src" != "$INSTALL_PATH" ]]; then
        cp -f "$src" "$INSTALL_PATH"
        chmod 755 "$INSTALL_PATH"
    else
        chmod 755 "$INSTALL_PATH"
    fi
    if ! /usr/bin/env bash -n "$INSTALL_PATH"; then
        err "安装后的脚本语法自检失败：$INSTALL_PATH"
        exit 1
    fi
    write_units
    log "✅ 安装/覆盖完成：${INSTALL_PATH}，版本=${APP_VERSION}。"
    ok "安装完成：${INSTALL_PATH}"
    ok "服务文件：${SERVICE_FILE}"
    ok "定时器文件：${TIMER_FILE}"
}

service_start() {
    require_root
    install_self
    validate_config_or_exit
    write_units
    systemctl enable --now "${APP_NAME}.timer"
    systemctl start "${APP_NAME}.service" 2>/dev/null || true
    ok "已启动定时器：${APP_NAME}.timer"
    systemctl --no-pager --full status "${APP_NAME}.timer" || true
}

service_stop() {
    require_root
    systemctl disable --now "${APP_NAME}.timer" 2>/dev/null || true
    systemctl stop "${APP_NAME}.service" 2>/dev/null || true
    ok "已停止定时器和当前检测任务。"
}

service_restart() {
    require_root
    install_self
    validate_config_or_exit
    write_units
    systemctl restart "${APP_NAME}.timer"
    systemctl start "${APP_NAME}.service" 2>/dev/null || true
    ok "已重启定时器，并立即触发一次检测。"
}

service_status() {
    require_root
    load_config
    load_status
    cecho "🧩 ${APP_VERSION} 状态"
    cecho "----------------------------------------"
    cecho "⏱️ timer 状态："
    systemctl --no-pager --full status "${APP_NAME}.timer" || true
    cecho ""
    cecho "🧪 最近一次 service 状态："
    systemctl --no-pager --full status "${APP_NAME}.service" || true
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
    cecho "  Runner：${RUNNER_PATH}"
    cecho "  获取 IP API：$(mask_url "${SHOW_IP_API_URL:-}")"
    cecho "  更换 IP API：$(mask_url "${CHANGE_IP_API_URL:-}")"
    cecho ""
    cecho "📊 最近状态："
    cecho "  LAST_TARGET=${LAST_TARGET:-unknown}"
    cecho "  LAST_RESOLVED_IP=${LAST_RESOLVED_IP:-unknown}"
    cecho "  LAST_RESULT=${LAST_RESULT:-unknown}"
    cecho "  LAST_MEASUREMENT_ID=${LAST_MEASUREMENT_ID:-unknown}"
    cecho "  FAILURE_COUNT=${FAILURE_COUNT:-0}"
    cecho "  LAST_CHECK_EPOCH=${LAST_CHECK_EPOCH:-0}"
    cecho "  LAST_CHANGE_EPOCH=${LAST_CHANGE_EPOCH:-0}"
    cecho "  LAST_API_CALL_EPOCH=${LAST_API_CALL_EPOCH:-0}"
    cecho ""
    if has_cmd systemctl; then
        cecho "📅 定时器列表："
        systemctl list-timers --all "${APP_NAME}.timer" || true
    fi
}

quick_init() {
    require_root
    install_packages
    install_self
    mkdirs
    cecho "🚀 ${APP_VERSION} 快速初始化"
    cecho "----------------------------------------"
    warn "请输入你的真实 API 地址。脚本不会内置示例 URL，也不会把敏感信息上传 GitHub。"
    warn "v2.3 使用 systemd timer + 独立 runner 包装器，确保中文文件日志每轮落盘。"
    cecho ""

    local show_api change_api target interval probes threshold packets wait cooldown timeout post_wait min_api resolver start_now
    read -r -p "🔎 请输入【获取当前 IP API】地址：" show_api
    while [[ -z "$show_api" ]]; do read -r -p "🔎 获取当前 IP API 地址不能为空，请重新输入：" show_api; done
    read -r -p "🔁 请输入【真正更换 IP API】地址：" change_api
    while [[ -z "$change_api" ]]; do read -r -p "🔁 更换 IP API 地址不能为空，请重新输入：" change_api; done
    warn_if_showip_action "$change_api"
    if [[ "$show_api" == "$change_api" ]]; then warn "获取 IP API 和更换 IP API 完全相同，请确认没有填错。"; fi
    read -r -p "🎯 请输入【检测目标域名/IP】（建议填 HiNet DDNS 域名）：" target
    while [[ -z "$target" ]]; do read -r -p "🎯 检测目标不能为空，请重新输入：" target; done

    read -r -p "⏱️ 检测间隔秒 [默认 ${DEFAULT_CHECK_INTERVAL}]：" interval; interval="${interval:-$DEFAULT_CHECK_INTERVAL}"
    read -r -p "🇨🇳 每次使用几个中国节点 [默认 ${DEFAULT_CN_PROBES}，建议 1-2]：" probes; probes="${probes:-$DEFAULT_CN_PROBES}"
    read -r -p "🚨 连续几次 CN ping 全部失败后换 IP [默认 ${DEFAULT_FAIL_THRESHOLD}]：" threshold; threshold="${threshold:-$DEFAULT_FAIL_THRESHOLD}"
    read -r -p "📦 每个节点 ping 包数量 [默认 ${DEFAULT_GP_PACKETS}]：" packets; packets="${packets:-$DEFAULT_GP_PACKETS}"
    read -r -p "⌛ 等待 Globalping 结果秒数 [默认 ${DEFAULT_RESULT_WAIT_SECONDS}]：" wait; wait="${wait:-$DEFAULT_RESULT_WAIT_SECONDS}"
    read -r -p "🧊 自动换 IP 冷却秒数 [默认 ${DEFAULT_COOLDOWN_SECONDS}]：" cooldown; cooldown="${cooldown:-$DEFAULT_COOLDOWN_SECONDS}"
    read -r -p "🌐 API curl 最大超时秒数 [默认 ${DEFAULT_CURL_TIMEOUT}]：" timeout; timeout="${timeout:-$DEFAULT_CURL_TIMEOUT}"
    read -r -p "⏳ 换 IP 后等待 DDNS/API 更新秒数 [默认 ${DEFAULT_POST_CHANGE_WAIT_SECONDS}]：" post_wait; post_wait="${post_wait:-$DEFAULT_POST_CHANGE_WAIT_SECONDS}"
    read -r -p "🧭 解析 DDNS 使用的 DNS 服务器 [默认 ${DEFAULT_RESOLVER}]：" resolver; resolver="${resolver:-$DEFAULT_RESOLVER}"
    read -r -p "🛡️ 更换 IP API 最小调用间隔秒 [默认 ${DEFAULT_MIN_API_INTERVAL}]：" min_api; min_api="${min_api:-$DEFAULT_MIN_API_INTERVAL}"

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
    DNS_RESOLVER="$resolver"
    MIN_API_INTERVAL="$min_api"
    load_config
    save_config
    write_units

    ok "配置已保存：${CONF_FILE}（权限 600）"
    info "获取 IP API：$(mask_url "$SHOW_IP_API_URL")"
    info "更换 IP API：$(mask_url "$CHANGE_IP_API_URL")"
    info "检测目标：${CHECK_TARGET}"

    info "正在测试获取 IP API..."
    test_show_ip_api || warn "获取 IP API 测试失败，请检查 URL。"
    info "正在测试检测目标解析..."
    local tip=""
    tip="$(resolve_target_ip 2>/dev/null || true)"
    if [[ -n "$tip" ]]; then ok "当前解析公网 IP：${tip}"; else warn "检测目标暂时无法解析到公网 IPv4。"; fi
    info "正在测试 Globalping CN ping，不会调用更换 IP API..."
    run_single_check || true

    read -r -p "🚀 是否立即启动后台定时检测？[Y/n]：" start_now
    start_now="${start_now:-Y}"
    if [[ "$start_now" =~ ^[Yy]$ ]]; then service_start; fi
}

edit_config() {
    require_root
    install_self
    load_config
    cecho "🛠️ 修改已有配置：直接回车保留原值"
    cecho "----------------------------------------"
    local v
    read -r -p "🔎 获取当前 IP API [$(mask_url "$SHOW_IP_API_URL")]：" v; [[ -n "$v" ]] && SHOW_IP_API_URL="$v"
    read -r -p "🔁 真正更换 IP API [$(mask_url "$CHANGE_IP_API_URL")]：" v; [[ -n "$v" ]] && CHANGE_IP_API_URL="$v"
    warn_if_showip_action "$CHANGE_IP_API_URL"
    if [[ "$SHOW_IP_API_URL" == "$CHANGE_IP_API_URL" ]]; then warn "获取 IP API 和更换 IP API 完全相同，请确认没有填错。"; fi
    read -r -p "🎯 检测目标域名/IP [${CHECK_TARGET}]：" v; [[ -n "$v" ]] && CHECK_TARGET="$v"
    read -r -p "⏱️ 检测间隔秒 [${CHECK_INTERVAL}]：" v; [[ -n "$v" ]] && CHECK_INTERVAL="$v"
    read -r -p "🇨🇳 中国节点数量 [${CN_PROBES}]：" v; [[ -n "$v" ]] && CN_PROBES="$v"
    read -r -p "🚨 失败阈值 [${FAIL_THRESHOLD}]：" v; [[ -n "$v" ]] && FAIL_THRESHOLD="$v"
    read -r -p "📦 ping 包数量 [${GP_PACKETS}]：" v; [[ -n "$v" ]] && GP_PACKETS="$v"
    read -r -p "⌛ Globalping 等待秒数 [${GP_RESULT_WAIT_SECONDS}]：" v; [[ -n "$v" ]] && GP_RESULT_WAIT_SECONDS="$v"
    read -r -p "🧊 冷却秒数 [${COOLDOWN_SECONDS}]：" v; [[ -n "$v" ]] && COOLDOWN_SECONDS="$v"
    read -r -p "🌐 curl 超时秒数 [${CURL_TIMEOUT}]：" v; [[ -n "$v" ]] && CURL_TIMEOUT="$v"
    read -r -p "⏳ 换 IP 后等待秒数 [${POST_CHANGE_WAIT_SECONDS}]：" v; [[ -n "$v" ]] && POST_CHANGE_WAIT_SECONDS="$v"
    read -r -p "🧭 DNS 服务器 [${DNS_RESOLVER}]：" v; [[ -n "$v" ]] && DNS_RESOLVER="$v"
    read -r -p "🛡️ 更换 API 最小间隔秒 [${MIN_API_INTERVAL}]：" v; [[ -n "$v" ]] && MIN_API_INTERVAL="$v"
    load_config
    save_config
    write_units
    ok "配置已更新。"
    if systemctl is-active --quiet "${APP_NAME}.timer" 2>/dev/null; then
        systemctl restart "${APP_NAME}.timer"
        ok "定时器已按新间隔重启。"
    fi
}

view_logs() {
    require_root
    mkdirs
    cecho "🧾 中文日志文件：${LOG_FILE}"
    cecho "----------------------------------------"
    info "显示中文文件日志。按 Ctrl+C 退出。"
    if [[ ! -s "$LOG_FILE" ]]; then
        warn "当前文件日志为空。下面先给出 timer/service 状态。"
        systemctl --no-pager --full status "${APP_NAME}.timer" 2>/dev/null || true
        systemctl --no-pager --full status "${APP_NAME}.service" 2>/dev/null || true
    fi
    tail -n 120 -F "$LOG_FILE"
}

view_journal_logs() {
    require_root
    cecho "🧾 systemd journal：journalctl -u ${APP_NAME}.service -u ${APP_NAME}.timer -f -o cat"
    cecho "----------------------------------------"
    journalctl -u "${APP_NAME}.service" -u "${APP_NAME}.timer" -n 120 -f -o cat || true
}

show_config_masked() {
    require_root
    load_config
    cecho "🔐 当前脱敏配置"
    cecho "----------------------------------------"
    cecho "获取 IP API：$(mask_url "$SHOW_IP_API_URL")"
    cecho "更换 IP API：$(mask_url "$CHANGE_IP_API_URL")"
    cecho "检测目标：${CHECK_TARGET:-未配置}"
    cecho "检测间隔：${CHECK_INTERVAL}s"
    cecho "中国节点：${CN_PROBES}"
    cecho "失败阈值：${FAIL_THRESHOLD}"
    cecho "ping 包数：${GP_PACKETS}"
    cecho "等待结果：${GP_RESULT_WAIT_SECONDS}s"
    cecho "冷却：${COOLDOWN_SECONDS}s"
    cecho "curl 超时：${CURL_TIMEOUT}s"
    cecho "换 IP 后等待：${POST_CHANGE_WAIT_SECONDS}s"
    cecho "DNS 服务器：${DNS_RESOLVER}"
    cecho "API 最小间隔：${MIN_API_INTERVAL}s"
}

history_recent() {
    require_root
    mkdirs
    local days="$1" since
    cecho "📜 最近 ${days} 天 IP 更换记录：${HISTORY_FILE}"
    cecho "----------------------------------------"
    if [[ ! -s "$HISTORY_FILE" ]]; then warn "暂无历史记录。"; return 0; fi
    since="$(date -d "${days} days ago" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')"
    awk -v s="$since" '$1 >= s {print}' "$HISTORY_FILE" || true
}

uninstall_script() {
    require_root
    warn "将停止并删除 systemd service/timer 和安装入口，但保留配置、日志、历史。"
    read -r -p "确认卸载？输入 1 继续：" yn
    yn="$(normalize_choice "$yn")"
    [[ "$yn" == "1" ]] || { warn "已取消。"; return 0; }
    systemctl disable --now "${APP_NAME}.timer" 2>/dev/null || true
    systemctl stop "${APP_NAME}.service" 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$RUNNER_PATH" "$INSTALL_PATH"
    systemctl daemon-reload 2>/dev/null || true
    ok "已卸载程序和 systemd 单元。配置保留：${CONF_FILE}"
}

doctor() {
    require_root
    mkdirs
    cecho "🩺 ${APP_VERSION} 自检"
    cecho "----------------------------------------"
    local ok_all=1
    for c in bash curl jq flock systemctl; do
        if has_cmd "$c"; then ok "依赖存在：$c"; else err "缺少依赖：$c"; ok_all=0; fi
    done
    if /usr/bin/env bash -n "${BASH_SOURCE[0]}"; then ok "脚本语法检查通过。"; else err "脚本语法检查失败。"; ok_all=0; fi
    if [[ -w "$LOG_FILE" ]]; then ok "中文日志可写：$LOG_FILE"; else warn "中文日志不可写或不存在，尝试创建。"; mkdirs; [[ -w "$LOG_FILE" ]] && ok "中文日志已恢复可写。" || ok_all=0; fi
    load_config
    if [[ -n "$SHOW_IP_API_URL" && -n "$CHANGE_IP_API_URL" && -n "$CHECK_TARGET" ]]; then ok "配置字段完整。"; else warn "配置不完整，请执行 init。"; fi
    if [[ -f "$SERVICE_FILE" ]]; then ok "service 文件存在：$SERVICE_FILE"; else warn "service 文件不存在，执行 init/start 会自动生成。"; fi
    if [[ -f "$TIMER_FILE" ]]; then ok "timer 文件存在：$TIMER_FILE"; else warn "timer 文件不存在，执行 init/start 会自动生成。"; fi
    if [[ -x "$RUNNER_PATH" ]]; then ok "runner 包装器存在且可执行：$RUNNER_PATH"; else warn "runner 包装器不存在或不可执行，执行 init/start 会自动生成。"; fi
    systemctl list-timers --all "${APP_NAME}.timer" 2>/dev/null || true
    [[ "$ok_all" -eq 1 ]] && ok "自检完成。" || warn "自检发现问题，请按上方提示处理。"
}

print_help() {
    cat <<EOF_HELP
${APP_VERSION}

用法：
  ${APP_NAME} init                    快速初始化 / 安装
  ${APP_NAME} start                   启动 systemd timer 后台检测
  ${APP_NAME} stop                    停止 systemd timer
  ${APP_NAME} restart                 重启 systemd timer 并立即检测一次
  ${APP_NAME} status                  查看状态
  ${APP_NAME} check-once              systemd timer 使用：执行一次检测并自动处理失败计数
  ${APP_NAME} check                   手动 Globalping 检测一次
  ${APP_NAME} change                  手动调用更换 IP API
  ${APP_NAME} show-ip                 显示当前 IP / DDNS 解析
  ${APP_NAME} logs                    中文文件日志
  ${APP_NAME} journal                 systemd 原始日志
  ${APP_NAME} edit-config             修改配置
  ${APP_NAME} doctor                  自检
EOF_HELP
}

menu() {
    while true; do
        cecho ""
        cecho "🌏 ${APP_VERSION} 管理菜单"
        cecho "========================================"
        cecho "  1. 🚀 快速初始化 / 安装"
        cecho "  2. ▶️  启动自动检测定时器"
        cecho "  3. ⏹️  停止自动检测定时器"
        cecho "  4. 🔄 重启自动检测定时器"
        cecho "  5. 📊 查看 timer/service 状态"
        cecho "  6. 🌐 显示当前 HiNet IP / DDNS 解析"
        cecho "  7. 🧪 手动检测一次 Globalping CN ping"
        cecho "  8. 🔁 手动调用更换 IP API"
        cecho "  9. 📜 查看最近三天 IP 更换记录"
        cecho " 10. 🗓️  查看最近一个月 IP 更换记录"
        cecho " 11. 🧾 查看中文实时日志"
        cecho " 12. 🔐 查看脱敏配置"
        cecho " 13. 🛠️  修改已有配置"
        cecho " 14. 🔎 手动测试获取当前 IP API（安全）"
        cecho " 15. 🧪 手动测试更换 IP API（可能换 IP，不写正式记录）"
        cecho " 16. 🗑️  卸载脚本"
        cecho " 17. 🩺 脚本自检"
        cecho " 18. 🧾 查看 systemd journal 原始日志"
        cecho "  0. 🚪 退出"
        cecho "========================================"
        local choice
        read -r -p "请输入选项 [0-18]：" choice
        choice="$(normalize_choice "$choice")"
        case "$choice" in
            1|init) quick_init ;;
            2|start) service_start ;;
            3|stop) service_stop ;;
            4|restart) service_restart ;;
            5|status) service_status ;;
            6|show|show-ip) show_current_ip ;;
            7|check) run_single_check ;;
            8|change|change-ip|manual) change_ip "manual_menu" "1" ;;
            9) history_recent 3 ;;
            10) history_recent 30 ;;
            11|logs|log) view_logs ;;
            12|config) show_config_masked ;;
            13|edit|edit-config) edit_config ;;
            14|test-show|test-show-api) test_show_ip_api ;;
            15|test-api|test-change-api) test_vendor_api ;;
            16|uninstall) uninstall_script ;;
            17|doctor) doctor ;;
            18|journal) view_journal_logs ;;
            0|exit|quit|q) exit 0 ;;
            *) warn "无效输入，请重新输入。" ;;
        esac
    done
}

main() {
    local cmd="${1:-menu}"
    case "$cmd" in
        init) quick_init ;;
        start) service_start ;;
        stop) service_stop ;;
        restart) service_restart ;;
        status) service_status ;;
        check-once) check_once ;;
        daemon) check_once ;; # 兼容旧 service，不再使用长期 daemon
        check|7) run_single_check ;;
        change|8) change_ip "manual_cli" "1" ;;
        show|show-ip|6) show_current_ip ;;
        logs|log|11) view_logs ;;
        journal|18) view_journal_logs ;;
        edit|edit-config|13) edit_config ;;
        config|show-config|12) show_config_masked ;;
        test-show-api|test-show|14) test_show_ip_api ;;
        test-api|test-change-api|15) test_vendor_api ;;
        history3|9) history_recent 3 ;;
        history30|10) history_recent 30 ;;
        doctor|17) doctor ;;
        uninstall|16) uninstall_script ;;
        help|-h|--help) print_help ;;
        menu|*) menu ;;
    esac
}

main "$@"
