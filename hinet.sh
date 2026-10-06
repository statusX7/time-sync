#!/usr/bin/env bash
# ============================================================
# hinet-gfw-changeip-v2.7.sh
# HiNet 被墙检测 + Globalping 中国节点 ping 弱检测 + 双 API 自动换 IP
# v2.7：支持 curl 流式执行后安装；部署后的 URL/响应完整显示；全量配置导入导出。
# v2.7：导入先校验、备份和回读核对；可选择恢复定时器，不导入旧失败计数。
# v2.6：修复配置覆盖，配置/状态安全解析与原子保存；统一请求、换 IP 证据和 Globalping 判定。
# v2.6：修复 IPv4 局部变量污染、锁未释放及安装/systemd 失败仍显示成功。
# v2.4：systemd timer 调用独立 worker，worker 内部直接完成 Globalping 检测、连续失败计数和自动换 IP，不再依赖主脚本 check-once 分发
# 适合上传 GitHub：脚本本身不包含任何敏感信息，敏感 API 写入 /etc 配置文件
# ============================================================

# 启动封装仅解决流式输入的完整落盘，主体函数及独立 worker 架构保持。
hinet_program() {
set -u -o pipefail

APP_NAME="hinet-gfw-changeip"
APP_VERSION="hinet-gfw-changeip-v2.7"
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

cecho() { printf '%s\n' "$*"; }
info() { cecho "ℹ️  $*"; }
ok() { cecho "✅ $*"; }
warn() { cecho "⚠️  $*"; }
err() { cecho "❌ $*" >&2; }
now_human() { date '+%Y-%m-%d %H:%M:%S%z'; }
now_epoch() { date '+%s'; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

mkdirs() {
    local d f
    for d in "${CONF_DIR:-/etc/hinet-gfw-changeip}" "$STATE_DIR" "$LOG_DIR"; do
        [[ ! -L "$d" ]] || { printf '❌ 拒绝符号链接目录：%s\n' "$d" >&2; return 1; }
    done
    mkdir -p -- "${CONF_DIR:-/etc/hinet-gfw-changeip}" "$STATE_DIR" "$LOG_DIR" || return 1
    chmod 700 "${CONF_DIR:-/etc/hinet-gfw-changeip}" "$STATE_DIR" || return 1
    chmod 755 "$LOG_DIR" || return 1
    for f in "$LOG_FILE" "$HISTORY_FILE" "$STATUS_FILE"; do
        [[ ! -L "$f" && ! -d "$f" ]] || return 1
        (umask 077; : >> "$f") || return 1
        chmod 600 "$f" || return 1
    done
}

log() {
    local line
    line="[$(now_human)] $*"
    if [[ ! -L "$LOG_FILE" ]] && mkdir -p -- "$LOG_DIR" 2>/dev/null; then
        (umask 077; printf '%s\n' "$line" >> "$LOG_FILE") 2>/dev/null || printf '⚠️ 中文文件日志写入失败。\n' >&2
    fi
    # 日志只走 stderr，避免 command substitution 将日志误当 IP / measurement ID。
    printf '%s\n' "$line" >&2
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请使用 root 执行：sudo bash $0"
        exit 1
    fi
}

number_in_range() {
    local n="${1:-}" min="${2:-}" max="${3:-}"
    [[ "$n" =~ ^[0-9]{1,12}$ ]] || return 1
    (( 10#$n >= min && 10#$n <= max ))
}

normalize_choice() {
    printf '%s' "${1:-}" | sed 's/[[:space:]]//g; s/０/0/g; s/１/1/g; s/２/2/g; s/３/3/g; s/４/4/g; s/５/5/g; s/６/6/g; s/７/7/g; s/８/8/g; s/９/9/g'
}

quote_env() { printf '%q' "$1"; }

display_value() {
    if [[ -n "${1:-}" ]]; then printf '%s' "$1"; else printf '未配置'; fi
}

install_packages() {
    local need=0
    for c in curl jq flock timeout; do has_cmd "$c" || need=1; done
    has_cmd dig || need=1
    [[ "$need" -eq 0 ]] && return 0

    warn "准备检查/安装依赖：curl jq flock dig。"
    if has_cmd apt-get; then
        apt-get update -y || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq ca-certificates util-linux dnsutils || return 1
    elif has_cmd dnf; then
        dnf install -y curl jq ca-certificates util-linux bind-utils || return 1
    elif has_cmd yum; then
        yum install -y epel-release || true
        yum install -y curl jq ca-certificates util-linux bind-utils || return 1
    elif has_cmd apk; then
        apk add --no-cache curl jq ca-certificates util-linux bind-tools || return 1
    else
        err "无法自动识别包管理器，请手动安装：curl jq ca-certificates util-linux dig"
        exit 1
    fi

    for c in curl jq flock timeout dig; do
        has_cmd "$c" || { err "依赖 $c 不可用，请手动安装后重试。"; exit 1; }
    done
}
install_dependencies() { install_packages; }


# 只读已知 KEY=value；支持 v2.5 printf %q、单/双引号和 ANSI-C 引号。
# 不使用 source/eval，不执行变量、命令或算术展开；未知旧字段只忽略，不执行。
CONFIG_KEYS=(SHOW_IP_API_URL CHANGE_IP_API_URL CHECK_TARGET CHECK_INTERVAL CN_PROBES FAIL_THRESHOLD GP_PACKETS GP_RESULT_WAIT_SECONDS COOLDOWN_SECONDS CURL_TIMEOUT POST_CHANGE_WAIT_SECONDS DNS_RESOLVER MIN_API_INTERVAL)
STATUS_KEYS=(FAILURE_COUNT LAST_CHANGE_EPOCH LAST_API_CALL_EPOCH LAST_CHECK_EPOCH LAST_TARGET LAST_RESOLVED_IP LAST_RESULT LAST_MEASUREMENT_ID)

decode_env_value() {
    local s="$1" out="" mode=u ch next esc="" i=0
    while (( i < ${#s} )); do
        ch="${s:i:1}"
        case "$mode" in
            u)
                case "$ch" in
                    "'") mode=s ;;
                    '"') mode=d ;;
                    '\') i=$((i+1)); (( i < ${#s} )) || return 1; out+="${s:i:1}" ;;
                    '$')
                        if [[ "${s:i+1:1}" == "'" ]]; then mode=a; esc=""; i=$((i+1)); else out+="$ch"; fi ;;
                    *) out+="$ch" ;;
                esac ;;
            s) if [[ "$ch" == "'" ]]; then mode=u; else out+="$ch"; fi ;;
            d)
                if [[ "$ch" == '"' ]]; then mode=u
                elif [[ "$ch" == '\' ]]; then
                    i=$((i+1)); (( i < ${#s} )) || return 1; next="${s:i:1}"
                    case "$next" in '$'|'`'|'"'|'\') out+="$next" ;; *) out+="\\$next" ;; esac
                else out+="$ch"; fi ;;
            a)
                if [[ "$ch" == "'" ]]; then
                    printf -v next '%b' "$esc" || return 1
                    out+="$next"; mode=u
                elif [[ "$ch" == '\' ]]; then
                    i=$((i+1)); (( i < ${#s} )) || return 1
                    next="${s:i:1}"
                    # 保留旧 %q ANSI-C 编码；拒绝会截断输出的 \c。
                    [[ "$next" != c ]] || return 1
                    case "$next" in
                        "'"|'"'|'?') esc+="$next" ;;
                        *) esc+="\\$next" ;;
                    esac
                else esc+="$ch"; fi ;;
        esac
        i=$((i+1))
    done
    [[ "$mode" == u ]] || return 1
    REPLY="$out"
}

read_env_file() {
    local file="$1" kind="$2" line key encoded REPLY="" allowed line_key line_no=0
    local -A parsed=()
    [[ -e "$file" ]] || return 0
    [[ -f "$file" && -r "$file" && ! -L "$file" ]] || { log "❌ 配置/状态文件不可读或为符号链接。"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no+1)); line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            log "❌ 配置/状态第 ${line_no} 行不是 KEY=value；拒绝执行。"; return 1
        fi
        key="${BASH_REMATCH[1]}"; encoded="${BASH_REMATCH[2]}"; allowed=0
        if [[ "$kind" == config ]]; then
            for line_key in "${CONFIG_KEYS[@]}" HINET_API_URL; do [[ "$key" == "$line_key" ]] && allowed=1; done
        else
            for line_key in "${STATUS_KEYS[@]}"; do [[ "$key" == "$line_key" ]] && allowed=1; done
        fi
        (( allowed == 1 )) || continue
        [[ ! ${parsed[$key]+present} ]] || { log "❌ 配置/状态存在重复字段：${key}"; return 1; }
        decode_env_value "$encoded" || { log "❌ 配置/状态字段编码无效：${key}"; return 1; }
        parsed["$key"]="$REPLY"
    done < "$file" || return 1
    for key in "${!parsed[@]}"; do printf -v "$key" '%s' "${parsed[$key]}" || return 1; done
}

validate_numbers() {
    local spec key min max
    for spec in CHECK_INTERVAL:30:3600 CN_PROBES:1:50 FAIL_THRESHOLD:1:30 GP_PACKETS:1:20 GP_RESULT_WAIT_SECONDS:10:180 COOLDOWN_SECONDS:0:86400 CURL_TIMEOUT:5:180 POST_CHANGE_WAIT_SECONDS:0:1800 MIN_API_INTERVAL:0:3600; do
        IFS=: read -r key min max <<< "$spec"
        number_in_range "${!key}" "$min" "$max" || { log "❌ ${key} 必须为 ${min}-${max} 的十进制整数；没有保存或采用默认值。"; return 1; }
    done
    # 先全部校验，再规范十进制，防止 08/09 被 Bash 视为八进制。
    for key in CHECK_INTERVAL CN_PROBES FAIL_THRESHOLD GP_PACKETS GP_RESULT_WAIT_SECONDS COOLDOWN_SECONDS CURL_TIMEOUT POST_CHANGE_WAIT_SECONDS MIN_API_INTERVAL; do
        printf -v "$key" '%s' "$((10#${!key}))"
    done
}

validate_status_numbers() {
    local key max
    for key in FAILURE_COUNT LAST_CHANGE_EPOCH LAST_API_CALL_EPOCH LAST_CHECK_EPOCH; do
        max=253402300799; [[ "$key" == FAILURE_COUNT ]] && max=1000000000
        number_in_range "${!key}" 0 "$max" || { log "❌ 状态字段 ${key} 非法，停止本轮，保留原状态文件。"; return 1; }
    done
    for key in FAILURE_COUNT LAST_CHANGE_EPOCH LAST_API_CALL_EPOCH LAST_CHECK_EPOCH; do printf -v "$key" '%s' "$((10#${!key}))"; done
}

config_snapshot() {
    local key
    for key in "${CONFIG_KEYS[@]}"; do printf '%s=%q\n' "$key" "${!key}" || return 1; done
}

status_snapshot() {
    local key
    for key in "${STATUS_KEYS[@]}"; do printf '%s=%q\n' "$key" "${!key}" || return 1; done
}

is_domain() {
    [[ "${1:-}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]([A-Za-z0-9-]*[A-Za-z0-9])?\.?$ ]]
}

is_http_url() {
    [[ "${1:-}" =~ ^[Hh][Tt][Tt][Pp][Ss]?://[^/[:space:]]+ && ! "$1" =~ [[:cntrl:]] ]]
}

validate_runtime_config() {
    validate_numbers || return 1
    is_http_url "$CHANGE_IP_API_URL" || { log "❌ 更换 IP API 必须为 HTTP/HTTPS 地址。"; return 1; }
    if ! is_domain "$SHOW_IP_API_URL" && ! is_http_url "$SHOW_IP_API_URL"; then
        log "❌ 获取 IP 来源必须为裸域名或 HTTP/HTTPS API。"; return 1
    fi
    if ! is_domain "$CHECK_TARGET" && ! is_public_ipv4 "$CHECK_TARGET"; then
        log "❌ CHECK_TARGET 必须为裸域名或公网 IPv4。"; return 1
    fi
    [[ "$DNS_RESOLVER" =~ ^[A-Za-z0-9:][A-Za-z0-9.:-]*$ ]] || { log "❌ DNS_RESOLVER 格式无效。"; return 1; }
}

load_config() {
    SHOW_IP_API_URL=""
    CHANGE_IP_API_URL=""
    HINET_API_URL=""
    CHECK_TARGET=""
    CHECK_INTERVAL="$DEFAULT_CHECK_INTERVAL"
    CN_PROBES="$DEFAULT_CN_PROBES"
    FAIL_THRESHOLD="$DEFAULT_FAIL_THRESHOLD"
    GP_PACKETS="$DEFAULT_GP_PACKETS"
    GP_RESULT_WAIT_SECONDS="$DEFAULT_RESULT_WAIT_SECONDS"
    COOLDOWN_SECONDS="$DEFAULT_COOLDOWN_SECONDS"
    CURL_TIMEOUT="$DEFAULT_CURL_TIMEOUT"
    POST_CHANGE_WAIT_SECONDS="$DEFAULT_POST_CHANGE_WAIT_SECONDS"
    DNS_RESOLVER="$DEFAULT_RESOLVER"
    MIN_API_INTERVAL="$DEFAULT_MIN_API_INTERVAL"
    read_env_file "$CONF_FILE" config || return 1
    [[ -n "$CHANGE_IP_API_URL" ]] || CHANGE_IP_API_URL="$HINET_API_URL"
    validate_numbers
}

save_config() {
    local tmp expected actual backup="" key
    validate_numbers || return 1
    for key in SHOW_IP_API_URL CHANGE_IP_API_URL CHECK_TARGET DNS_RESOLVER; do
        [[ -n "${!key}" ]] || { err "${key} 不能为空，配置未保存。"; return 1; }
    done
    [[ ! -L "$CONF_DIR" ]] || { err "配置目录不能是符号链接。"; return 1; }
    mkdir -p -- "$CONF_DIR" || { err "创建配置目录失败。"; return 1; }
    chmod 700 "$CONF_DIR" || { err "设置配置目录权限失败。"; return 1; }
    [[ ! -L "$CONF_FILE" && ! -d "$CONF_FILE" ]] || { err "配置目标不能是符号链接或目录。"; return 1; }
    expected="$(config_snapshot)" || return 1
    tmp="$(mktemp "${CONF_DIR}/.config.XXXXXX")" || { err "创建临时配置失败。"; return 1; }
    if ! { printf '# %s config\n# 由 %s 生成。敏感 URL 不要上传 GitHub。\n' "$APP_NAME" "$APP_VERSION" && config_snapshot; } > "$tmp" || ! chmod 600 "$tmp"; then
        rm -f -- "$tmp"; err "写入临时配置失败；原配置保持不变。"; return 1
    fi
    actual="$(CONF_FILE="$tmp"; load_config && config_snapshot)" || { rm -f -- "$tmp"; err "临时配置重新读取失败。"; return 1; }
    if [[ "$actual" != "$expected" ]]; then rm -f -- "$tmp"; err "临时配置逐字段校验不一致。"; return 1; fi
    if [[ -f "$CONF_FILE" ]]; then
        backup="${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S).${BASHPID}"
        if ! cp -p -- "$CONF_FILE" "$backup" || ! chmod 600 "$backup"; then
            rm -f -- "$tmp"; err "备份原配置失败；未覆盖原配置。"; return 1
        fi
    fi
    if ! mv -f -- "$tmp" "$CONF_FILE"; then rm -f -- "$tmp"; err "配置安全替换失败；原配置未截断。"; return 1; fi
    if ! load_config || ! actual="$(config_snapshot)" || [[ "$actual" != "$expected" ]]; then
        err "保存后重新读取/核对失败，不能报告配置已更新。"
        if [[ -n "$backup" ]]; then
            tmp="$(mktemp "${CONF_DIR}/.restore.XXXXXX")" || return 1
            if cp -p -- "$backup" "$tmp" && mv -f -- "$tmp" "$CONF_FILE"; then
                err "已回滚原配置。"
            else
                rm -f -- "$tmp"; err "回滚失败；原配置备份位于 ${backup}。"
            fi
        fi
        return 1
    fi
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
    read_env_file "$STATUS_FILE" status || return 1
    validate_status_numbers
}

save_status() {
    local tmp expected actual
    validate_status_numbers || return 1
    mkdirs || return 1
    [[ ! -L "$STATUS_FILE" ]] || { log "❌ 状态文件不能是符号链接。"; return 1; }
    expected="$(status_snapshot)" || return 1
    tmp="$(mktemp "${STATE_DIR}/.status.XXXXXX")" || { log "❌ 创建临时状态文件失败。"; return 1; }
    if ! status_snapshot > "$tmp" || ! chmod 600 "$tmp"; then
        rm -f -- "$tmp"; log "❌ 写入临时状态文件失败；原状态未替换。"; return 1
    fi
    actual="$(STATUS_FILE="$tmp"; load_status && status_snapshot)" || { rm -f -- "$tmp"; log "❌ 临时状态读取校验失败。"; return 1; }
    if [[ "$actual" != "$expected" ]] || ! mv -f -- "$tmp" "$STATUS_FILE"; then
        rm -f -- "$tmp"; log "❌ 状态安全替换失败。"; return 1
    fi
}

validate_config_safe() {
    validate_runtime_config
}

validate_config_or_exit() {
    load_config && validate_config_safe || { err "配置不可用，请执行 ${APP_NAME} edit-config 或 init。"; return 1; }
}

is_public_ipv4() {
    local ip="${1:-}" a b c d x IFS=.
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r a b c d <<< "$ip"
    for x in "$a" "$b" "$c" "$d"; do
        [[ "$x" == 0 || "$x" != 0* ]] || return 1
        number_in_range "$x" 0 255 || return 1
    done
    (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1
    (( a == 169 && b == 254 )) && return 1
    (( a == 172 && b >= 16 && b <= 31 )) && return 1
    (( a == 192 && b == 168 )) && return 1
    (( a == 198 && (b == 18 || b == 19) )) && return 1
    (( a == 192 && b == 0 && (c == 0 || c == 2) )) && return 1
    (( a == 198 && b == 51 && c == 100 )) && return 1
    (( a == 203 && b == 0 && c == 113 )) && return 1
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


# 返回 0=传输成功且 HTTP 2xx；非 0=失败。错误信息绝不并入正文。
# HTTP_SENT 只在 curl 报告实际 HTTP 请求字节时置 1；TLS/DNS 失败不视为已发出 API。
http_request() {
    local url="$1" timeout="$2" payload="${3:-}" redirects="${4:-1}" dir meta rc escaped curl_error=""
    HTTP_BODY=""; HTTP_CODE=000; HTTP_CURL_RC=0; HTTP_SENT=0; HTTP_STARTED_AT=0
    is_http_url "$url" && number_in_range "$timeout" 1 180 || { log "❌ HTTP 请求参数无效，未发送。"; return 3; }
    has_cmd curl || { log "❌ curl 不存在，未发送。"; return 3; }
    dir="$(mktemp -d)" || { log "❌ HTTP 临时目录创建失败，未发送。"; return 3; }
    chmod 700 "$dir" || { rm -rf -- "$dir"; return 3; }
    escaped="${url//\\/\\\\}"; escaped="${escaped//\"/\\\"}"
    if ! (umask 077; printf 'url = "%s"\n' "$escaped" > "$dir/request.conf"); then rm -rf -- "$dir"; return 3; fi
    local -a args=(-q -sS --globoff --retry 0 --connect-timeout 10 --max-time "$timeout" --proto '=http,https' --output "$dir/body" --write-out '%{http_code}\t%{size_request}' --config "$dir/request.conf")
    # 查询沿用重定向；有副作用的换 IP 请求不追随重定向，避免重复执行。
    [[ "$redirects" == 1 ]] && args+=(-L --max-redirs 5 --proto-redir '=http,https')
    [[ -n "$payload" ]] && args+=(-H 'Content-Type: application/json' --data "$payload")
    HTTP_STARTED_AT="$(now_epoch)"
    number_in_range "$HTTP_STARTED_AT" 0 253402300799 || { rm -rf -- "$dir"; log "❌ 读取系统时间失败，未发送。"; return 3; }
    log "🌐 HTTP 请求地址：${url}"
    meta="$(curl "${args[@]}" 2>"$dir/error")"; rc=$?
    HTTP_CURL_RC="$rc"
    local sent_bytes=0
    IFS=$'\t' read -r HTTP_CODE sent_bytes <<< "$meta"
    [[ "$HTTP_CODE" =~ ^[0-9]{3}$ ]] || HTTP_CODE=000
    if [[ "$sent_bytes" =~ ^[0-9]{1,12}$ ]] && (( 10#$sent_bytes > 0 )); then HTTP_SENT=1; fi
    case "$rc" in 3|5|6|7|35|51|58|60|77|83|127) HTTP_SENT=0 ;; esac
    if [[ -f "$dir/body" ]]; then HTTP_BODY="$(cat -- "$dir/body")" || rc=23; fi
    HTTP_CURL_RC="$rc"
    if [[ -f "$dir/error" ]]; then curl_error="$(cat -- "$dir/error")" || curl_error="无法读取 curl 错误输出"; fi
    [[ -z "$curl_error" ]] || log "🧾 curl 错误输出（完整）：${curl_error}"
    if [[ "$url" != "${GLOBALPING_API_BASE}/"* ]] || (( rc != 0 )) || [[ ! "$HTTP_CODE" =~ ^2[0-9]{2}$ ]]; then
        log "🧾 HTTP 响应正文（完整）：${HTTP_BODY}"
    fi
    rm -rf -- "$dir" || { log "⚠️ HTTP 临时文件清理失败。"; return 1; }
    if (( rc != 0 )) || [[ ! "$HTTP_CODE" =~ ^2[0-9]{2}$ ]]; then
        log "❌ HTTP 请求失败：curl_rc=${rc}，HTTP=${HTTP_CODE}；未把错误正文作为成功结果。"
        return 1
    fi
    return 0
}

unique_public_ipv4() {
    local text="${1:-}" ip found=""
    while IFS= read -r ip; do
        is_public_ipv4 "$ip" || continue
        [[ -z "$found" || "$found" == "$ip" ]] || return 1
        found="$ip"
    done <<< "$text"
    [[ -n "$found" ]] || return 1
    printf '%s' "$found"
}

# 仅解析明确的 IP 字段/纯 IP；HTML、错误页和任意文本里的 IP 不作为当前 IP 证据。
response_public_ipv4() {
    local body="${1:-}" candidates
    body="${body#"${body%%[![:space:]]*}"}"; body="${body%"${body##*[![:space:]]}"}"
    if is_public_ipv4 "$body"; then printf '%s' "$body"; return 0; fi
    candidates="$(printf '%s' "$body" | jq -er '
        if type == "string" then .
        elif type == "object" then
          [.mainip?, .ip?, .ipv4?, .public_ip?, .current_ip?,
           (if (.data? | type) == "string" then .data else empty end),
           (if (.data? | type) == "object" then (.data.mainip?, .data.ip?, .data.ipv4?, .data.public_ip?, .data.current_ip?) else empty end)]
          | .[] | select(type == "string")
        else empty end' 2>/dev/null)" || return 1
    unique_public_ipv4 "$candidates"
}

vendor_response_kind() {
    local body="${1:-}" flags text
    if printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1; then
        flags="$(printf '%s' "$body" | jq -r '
          def s: tostring | ascii_downcase;
          if (([.success?, .ok?] | any(. != null and (s | test("^(false|0|no|failed|failure|error)$")))) or ((.error? != null) and (.error != false) and (.error != "") and (.error != 0))) then "failure"
          elif ([.status?, .code?] | any(. != null and ((s | test("^(fail(ed|ure)?|error|denied|invalid)$")) or ((s | test("^[45][0-9][0-9]$")))))) then "failure"
          elif (([.msg?,.message?] | map(select(type == "string")) | join(" ")) | test("失败|错误|无效|拒绝|频繁|未成功|(?i)\\b(failed|failure|invalid|denied|error)\\b")) then "failure"
          elif (.success? == true or .ok? == true or ([.status?,.code?] | any(. != null and (s | test("^(1000|200|201|202|204|success|ok|true)$"))))) then "success"
          else "unknown" end' 2>/dev/null)" || flags=unknown
        printf '%s' "$flags"; return 0
    fi
    if response_public_ipv4 "$body" >/dev/null 2>&1; then printf 'success'; return 0; fi
    text="$(printf '%s' "$body" | tr '\r\n' '  ')"
    if [[ "$text" == *'<'* || "$text" == *'{'* || "$text" == *'['* ]]; then printf 'unknown'
    elif printf '%s' "$text" | grep -qiE '失败|错误|无效|拒绝|频繁|未成功|failed|failure|invalid|denied|error'; then printf 'failure'
    elif printf '%s' "$text" | grep -qiE '^[[:space:]]*(ok|success|true|成功|重置IP成功|更换IP成功)[.!。[:space:]]*$'; then printf 'success'
    else printf 'unknown'; fi
}

vendor_summary() {
    local kind ip
    kind="$(vendor_response_kind "${1:-}")"
    ip="$(response_public_ipv4 "${1:-}" 2>/dev/null || true)"
    printf '业务判定=%s，明确IP字段=%s\n返回正文（完整）：%s' "$kind" "${ip:-无}" "${1:-}"
}

curl_get() {
    local url="$1" timeout="${2:-$CURL_TIMEOUT}"
    http_request "$url" "$timeout" || return 1
    printf '%s' "$HTTP_BODY"
}

resolve_target_ip() {
    local target="${1:-$CHECK_TARGET}" resolver="${DNS_RESOLVER:-$DEFAULT_RESOLVER}" body="" ip=""
    if is_public_ipv4 "$target"; then printf '%s' "$target"; return 0; fi
    is_domain "$target" || return 1
    if has_cmd dig; then
        body="$(dig +time=3 +tries=1 +short A "$target" "@${resolver}" 2>/dev/null)" || body=""
        body="$(printf '%s\n' "$body" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true)"
        # 有 A 答案但多 IP/非公网时不回退挑选另一 IP，避免 DNS 轮询伪装成换 IP。
        if [[ -n "$body" ]]; then unique_public_ipv4 "$body"; return $?; fi
    fi
    if has_cmd getent && has_cmd timeout; then
        body="$(timeout 10 getent ahostsv4 "$target" 2>/dev/null | awk '{print $1}')" || body=""
        ip="$(unique_public_ipv4 "$body")" || return 1
    fi
    [[ -n "$ip" ]] || return 1
    printf '%s' "$ip"
}

get_current_ip_from_api() {
    local body ip kind
    if is_domain "$SHOW_IP_API_URL"; then
        if ip="$(resolve_target_ip "$SHOW_IP_API_URL")"; then printf '%s' "$ip"; return 0; fi
        log "❌ 获取当前 IP 域名未返回唯一公网 IPv4。"; return 1
    fi
    body="$(curl_get "$SHOW_IP_API_URL" "$CURL_TIMEOUT")" || return 1
    kind="$(vendor_response_kind "$body")"
    [[ "$kind" != failure ]] || { log "❌ 获取当前 IP API 返回业务失败；不提取其中的 IP。"; return 1; }
    if ip="$(response_public_ipv4 "$body")"; then printf '%s' "$ip"; return 0; fi
    log "❌ 获取当前 IP API 未返回明确且唯一的公网 IPv4。"
    return 1
}

show_current_ip() {
    require_root
    load_config || return 1
    validate_config_or_exit || return 1
    local api_ip="" ddns_ip=""
    cecho "🌐 当前 HiNet IP / DDNS 解析"
    cecho "----------------------------------------"
    api_ip="$(get_current_ip_from_api 2>/dev/null || true)"
    ddns_ip="$(resolve_target_ip 2>/dev/null || true)"
    cecho "获取 IP API：$(display_value "$SHOW_IP_API_URL")"
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
    local target="$1" payload id
    payload="$(jq -nc --arg target "$target" --argjson limit "$CN_PROBES" --argjson packets "$GP_PACKETS" \
        '{type:"ping",target:$target,locations:[{country:"CN",limit:$limit}],measurementOptions:{packets:$packets,ipVersion:4}}')" || return 1
    http_request "${GLOBALPING_API_BASE}/measurements" "$CURL_TIMEOUT" "$payload" || return 1
    id="$(printf '%s' "$HTTP_BODY" | jq -er '.id | select(type == "string")' 2>/dev/null)" || { log "⚠️ Globalping 创建任务返回无效 JSON/ID。"; return 1; }
    [[ "$id" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || { log "⚠️ Globalping measurement ID 格式无效。"; return 1; }
    printf '%s' "$id"
}

globalping_parse_result() {
    jq -er '
      def integer: if type == "number" then . == floor else false end;
      def valid:
        .result as $p |
        ($p.status == "finished") and
        (($p.failureSource? // "target") == "target") and
        ($p.stats.total | integer) and ($p.stats.rcv | integer) and
        ($p.stats.total > 0) and ($p.stats.rcv >= 0) and ($p.stats.rcv <= $p.stats.total) and
        (if $p.stats.loss? == null then true else
          (($p.stats.loss | type) == "number") and ($p.stats.loss >= 0) and ($p.stats.loss <= 100) and
          (if $p.stats.rcv == 0 then $p.stats.loss == 100 else $p.stats.loss < 100 end)
        end);
      if type != "object" or (.status != "in-progress" and .status != "finished") or (.results | type) != "array"
      then error("invalid measurement") else . end |
      [.results[] | select(.probe.country? == "CN")] as $r |
      ($r | map(select(valid))) as $v |
      [.status, ($r|length), ($v|length), ($v|map(select(.result.stats.rcv > 0))|length)] | @tsv
    ' 2>/dev/null
}

globalping_check_target() {
    local target="${1:-$CHECK_TARGET}" id deadline parsed status total valid okn remaining req_timeout
    LAST_MEASUREMENT_ID=""
    validate_numbers || return 2
    log "🧪 Globalping 请求开始：target=${target}，country=CN，probes=${CN_PROBES}，packets=${GP_PACKETS}"
    id="$(globalping_create_measurement "$target")" || return 2
    LAST_MEASUREMENT_ID="$id"
    deadline=$(( $(now_epoch) + GP_RESULT_WAIT_SECONDS ))
    while true; do
        remaining=$((deadline - $(now_epoch)))
        if (( remaining <= 0 )); then log "⚠️ Globalping 结果仍未完成，本轮不计失败，measurement=${id}"; return 2; fi
        req_timeout="$CURL_TIMEOUT"; (( req_timeout > remaining )) && req_timeout="$remaining"
        http_request "${GLOBALPING_API_BASE}/measurements/${id}" "$req_timeout" || return 2
        parsed="$(printf '%s' "$HTTP_BODY" | globalping_parse_result)" || { log "⚠️ Globalping 响应格式无效，本轮不计失败。"; return 2; }
        IFS=$'\t' read -r status total valid okn <<< "$parsed"
        if [[ "$status" == finished ]]; then
            if (( valid > 0 && okn > 0 )); then
                log "✅ Globalping CN ping 正常：target=${target}，ok=${okn}/${valid}，measurement=${id}"; return 0
            fi
            if (( total > 0 && valid == total )); then
                log "❌ Globalping CN ping 全部失败：target=${target}，ok=0/${valid}，measurement=${id}"; return 1
            fi
            log "⚠️ Globalping 无有效 CN 探针或存在未完成/离线/内部错误：valid=${valid}/${total}，不计失败。"; return 2
        fi
        sleep 3 || return 2
    done
}

run_single_check() {
    require_root
    validate_config_or_exit || return 1
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
    mkdirs || return 1
    printf '%s\told_ip=%s\tnew_ip=%s\told_ddns=%s\tnew_ddns=%s\treason=%s\tnote=%s\n' \
        "$(now_human)" "$old_ip" "$new_ip" "$old_ddns" "$new_ddns" "$reason" "$note" >> "$HISTORY_FILE" || { log "❌ 写入正式成功历史失败。"; return 1; }
}

change_ip() (
    local reason="${1:-manual}" official="${2:-1}"
    require_root
    mkdirs || { log "❌ 无法准备状态目录，未发出换 IP 请求。"; return 3; }
    if [[ "${CHANGE_LOCK_HELD:-0}" != 1 ]]; then
        exec 8>"$CHANGE_LOCK_FILE" || { log "❌ 无法打开换 IP 锁。"; return 3; }
        flock -n 8 || { log "⚠️ 更换 IP/检测锁被占用，本次未发送请求。"; return 3; }
        load_config && validate_runtime_config || return 3
    fi
    load_status || return 3
    local now last_delta old_ip old_ddns body returned_ip new_ip new_ddns note kind request_rc call_time
    now="$(now_epoch)"
    last_delta=$((now - LAST_API_CALL_EPOCH))
    if (( LAST_API_CALL_EPOCH > now || LAST_CHANGE_EPOCH > now )); then
        log "⚠️ 本机时钟早于上次操作时间，本次未发出请求。"; return 3
    fi
    if (( MIN_API_INTERVAL > 0 && LAST_API_CALL_EPOCH > 0 && last_delta < MIN_API_INTERVAL )); then
        log "⏳ 距离上次调用更换 IP API 仅 ${last_delta}s，小于最小间隔 ${MIN_API_INTERVAL}s，本次不调用。"; return 3
    fi
    if [[ "$reason" == globalping_* ]] && (( COOLDOWN_SECONDS > 0 && LAST_CHANGE_EPOCH > 0 && now - LAST_CHANGE_EPOCH < COOLDOWN_SECONDS )); then
        log "⏳ 自动换 IP 仍在冷却期，本次不调用。"; return 3
    fi
    old_ip="$(get_current_ip_from_api 2>/dev/null || true)"
    old_ddns="$(resolve_target_ip 2>/dev/null || true)"
    # 在实际请求前确认状态能安全写入；不提前改变 API 调用时间。
    save_status || { log "❌ 状态不可写，未发出换 IP 请求。"; return 3; }
    log "🔁 准备调用更换 IP API，reason=${reason}，old_ip=${old_ip:-unknown}，old_ddns=${old_ddns:-unknown}，target=${CHECK_TARGET}"
    http_request "$CHANGE_IP_API_URL" "$CURL_TIMEOUT" "" 0; request_rc=$?
    body="$HTTP_BODY"; call_time="$HTTP_STARTED_AT"
    if [[ "$HTTP_SENT" == 1 ]]; then
        LAST_API_CALL_EPOCH="$call_time"
        save_status || { log "❌ 请求已发出，但调用时间保存失败；请暂停自动任务检查存储。"; return 4; }
    fi
    if (( request_rc != 0 )); then
        log "❌ 更换 IP 请求失败：curl_rc=${HTTP_CURL_RC}，HTTP=${HTTP_CODE}，request_sent=${HTTP_SENT}；保留失败计数和上次成功时间。"
        [[ "$request_rc" == 3 ]] && return 3
        return 1
    fi
    [[ "$HTTP_SENT" == 1 ]] || { log "⚠️ 无法核对请求是否发出，结果未确认。"; return 2; }
    log "🧾 更换 IP API 返回摘要：$(vendor_summary "$body")"
    kind="$(vendor_response_kind "$body")"
    if [[ "$kind" == failure ]]; then log "❌ 更换 IP API 明确返回业务失败，保留失败计数。"; return 1; fi
    returned_ip="$(response_public_ipv4 "$body" 2>/dev/null || true)"
    if (( POST_CHANGE_WAIT_SECONDS > 0 )); then
        log "⏳ 等待 ${POST_CHANGE_WAIT_SECONDS} 秒后确认获取 API / DDNS 结果。"
        sleep "$POST_CHANGE_WAIT_SECONDS" || { log "⚠️ 等待被中断，换 IP 未确认。"; return 2; }
    fi
    new_ip="$(get_current_ip_from_api 2>/dev/null || true)"
    new_ddns="$(resolve_target_ip 2>/dev/null || true)"
    log "ℹ️ 换 IP 前后对比：old_ip=${old_ip:-unknown}，new_ip=${new_ip:-unknown}，old_ddns=${old_ddns:-unknown}，new_ddns=${new_ddns:-unknown}"
    # 证据：同一独立获取来源前后均为唯一公网 IPv4，且不同；有返回 IP 时还必须与复查一致。
    if [[ "$kind" != success ]] || ! is_public_ipv4 "$old_ip" || ! is_public_ipv4 "$new_ip" || [[ "$old_ip" == "$new_ip" ]] || [[ -n "$returned_ip" && "$returned_ip" != "$new_ip" ]]; then
        log "⚠️ 请求已完成，但未确认公网 IP 变化：可能是 showip 查询接口、DDNS/API 未更新或响应证据不足；不清零计数，不记正式成功。"; return 2
    fi
    note="confirmed_by_current_ip_source"
    LAST_CHANGE_EPOCH="$(now_epoch)"
    FAILURE_COUNT=0
    LAST_RESULT="changed_ip"
    LAST_RESOLVED_IP="$new_ddns"
    save_status || { log "❌ 公网 IP 已确认变化，但结果状态保存失败。"; return 4; }
    if [[ "$official" == 1 ]]; then
        append_history "$old_ip" "$new_ip" "${old_ddns:-unknown}" "${new_ddns:-unknown}" "$reason" "$note" || return 4
    fi
    log "✅ 已确认公网 IP 变化：${old_ip} -> ${new_ip}，DDNS：${old_ddns:-unknown} -> ${new_ddns:-unknown}，reason=${reason}，note=${note}"
    return 0
)

test_show_ip_api() {
    require_root
    load_config || return 1
    [[ -n "$SHOW_IP_API_URL" ]] || { err "获取当前 IP API / 域名未配置。"; return 1; }
    local ip
    cecho "🔎 获取当前 IP API / 域名测试"
    cecho "----------------------------------------"
    cecho "来源：$(display_value "$SHOW_IP_API_URL")"
    if ip="$(get_current_ip_from_api)"; then ok "提取公网 IP：${ip}"; else err "没有取得可靠的公网 IPv4。"; return 1; fi
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
check_once() (
    require_root
    mkdirs || return 1
    log "🧭 check-once entry：version=${APP_VERSION}，pid=$$，conf=${CONF_FILE}，log=${LOG_FILE}"
    exec 8>"$CHANGE_LOCK_FILE" || { log "❌ 无法打开检测/换 IP 锁。"; return 1; }
    flock -n 8 || { log "⚠️ 已有检测或换 IP 流程运行，本轮跳过。"; return 0; }
    local CHANGE_LOCK_HELD=1
    if ! load_config || ! validate_runtime_config; then log "❌ 配置无效，本轮未检测。"; return 1; fi
    load_status || return 1
    local resolved_ip rc change_rc
    if [[ -n "$LAST_TARGET" && "$LAST_TARGET" != "$CHECK_TARGET" ]]; then
        FAILURE_COUNT=0
        log "ℹ️ 检测目标已变更，旧目标失败计数不计入新目标。"
    fi
    resolved_ip="$(resolve_target_ip 2>/dev/null || true)"
    LAST_CHECK_EPOCH="$(now_epoch)"; LAST_TARGET="$CHECK_TARGET"; LAST_RESOLVED_IP="$resolved_ip"
    save_status || return 1
    log "🛰️ 定时检测开始：target=${CHECK_TARGET}，resolved_ip=${resolved_ip:-unknown}，failure=${FAILURE_COUNT}/${FAIL_THRESHOLD}，interval=${CHECK_INTERVAL}s"
    globalping_check_target "$CHECK_TARGET"; rc=$?
    if [[ "$rc" == 0 ]]; then
        FAILURE_COUNT=0; LAST_RESULT="ok"
        save_status || return 1
        log "✅ 定时判定：CN ping 正常，失败计数已清零。"
    elif [[ "$rc" == 1 ]]; then
        (( FAILURE_COUNT < 1000000000 )) && FAILURE_COUNT=$((FAILURE_COUNT+1))
        LAST_RESULT="cn_ping_failed"
        save_status || return 1
        log "⚠️ 定时判定：CN ping 全部失败，连续失败计数：${FAILURE_COUNT}/${FAIL_THRESHOLD}。"
        if (( FAILURE_COUNT >= FAIL_THRESHOLD )); then
            log "🚨 达到失败阈值，检查冷却/调用间隔后尝试更换 IP。"
            change_ip "globalping_cn_ping_failed_${FAILURE_COUNT}_times" 1; change_rc=$?
            # change 在子 shell 内更新状态；重新读盘，禁止用旧快照覆盖时间戳。
            load_status || return 1
            case "$change_rc" in
                0) log "✅ 自动换 IP 已确认，失败计数已清零。" ;;
                1) LAST_RESULT="change_ip_failed"; log "❌ 自动换 IP 请求或业务失败，保留失败计数。" ;;
                2) LAST_RESULT="change_ip_unconfirmed"; log "⚠️ 自动换 IP 未确认，保留失败计数。" ;;
                3) LAST_RESULT="change_ip_skipped"; log "⏳ 本轮未发出换 IP 请求，保留失败计数。" ;;
                *) log "❌ 换 IP 流程持久化失败，请检查存储；本轮报错。"; return 1 ;;
            esac
            save_status || return 1
        fi
    else
        LAST_RESULT="globalping_unknown"
        save_status || return 1
        log "⚠️ 定时判定：Globalping API/探针异常，本轮不计入连续失败。"
    fi
    log "🏁 定时检测结束：last_result=${LAST_RESULT}，failure_count=${FAILURE_COUNT}/${FAIL_THRESHOLD}"
    return 0
)


write_runner() {
    local runner_tmp
    mkdir -p -- "$(dirname "$RUNNER_PATH")" || { err "创建 worker 目录失败。"; return 1; }
    [[ ! -L "$RUNNER_PATH" ]] || { err "worker 路径不能是符号链接。"; return 1; }
    runner_tmp="$(mktemp "${RUNNER_PATH}.tmp.XXXXXX")" || { err "创建 worker 临时文件失败。"; return 1; }
    if ! cat > "$runner_tmp"; then
        rm -f -- "$runner_tmp"; err "写入 worker 失败。"; return 1
    fi <<'EOF_RUNNER'
#!/usr/bin/env bash
# hinet-gfw-changeip systemd worker
# 这个 worker 不再回调主脚本 check-once，而是在 worker 内直接完成：
# Globalping CN 检测 -> 连续失败计数 -> 达阈值自动调用更换 IP API。
set +e
set -u -o pipefail
APP_NAME="hinet-gfw-changeip"
APP_VERSION="hinet-gfw-changeip-v2.7-worker"
CONF_FILE="/etc/hinet-gfw-changeip/config.env"
STATE_DIR="/var/lib/hinet-gfw-changeip"
LOG_DIR="/var/log/hinet-gfw-changeip"
LOG_FILE="/var/log/hinet-gfw-changeip/hinet-gfw-changeip.log"
HISTORY_FILE="/var/lib/hinet-gfw-changeip/ip_change_history.log"
STATUS_FILE="/var/lib/hinet-gfw-changeip/status.env"
GLOBALPING_API_BASE="https://api.globalping.io/v1"
CHANGE_LOCK_FILE="/run/hinet-gfw-changeip-change.lock"
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

now_human() { date '+%Y-%m-%d %H:%M:%S%z'; }
now_epoch() { date '+%s'; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
mkdirs() {
    local d f
    for d in "${CONF_DIR:-/etc/hinet-gfw-changeip}" "$STATE_DIR" "$LOG_DIR"; do
        [[ ! -L "$d" ]] || { printf '❌ 拒绝符号链接目录：%s\n' "$d" >&2; return 1; }
    done
    mkdir -p -- "${CONF_DIR:-/etc/hinet-gfw-changeip}" "$STATE_DIR" "$LOG_DIR" || return 1
    chmod 700 "${CONF_DIR:-/etc/hinet-gfw-changeip}" "$STATE_DIR" || return 1
    chmod 755 "$LOG_DIR" || return 1
    for f in "$LOG_FILE" "$HISTORY_FILE" "$STATUS_FILE"; do
        [[ ! -L "$f" && ! -d "$f" ]] || return 1
        (umask 077; : >> "$f") || return 1
        chmod 600 "$f" || return 1
    done
}
wlog() {
    local line
    line="[$(now_human)] $*"
    if [[ ! -L "$LOG_FILE" ]] && mkdir -p -- "$LOG_DIR" 2>/dev/null; then
        (umask 077; printf '%s\n' "$line" >> "$LOG_FILE") 2>/dev/null || printf '⚠️ 中文文件日志写入失败。\n' >&2
    fi
    # 日志只走 stderr，避免 command substitution 将日志误当 IP / measurement ID。
    printf '%s\n' "$line" >&2
}
quote_env() { printf '%q' "$1"; }
shorten() { printf '%s' "${1:-}" | tr '\n\r\t' '   ' | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-360; }
number_in_range() {
    local n="${1:-}" min="${2:-}" max="${3:-}"
    [[ "$n" =~ ^[0-9]{1,12}$ ]] || return 1
    (( 10#$n >= min && 10#$n <= max ))
}


# 只读已知 KEY=value；支持 v2.5 printf %q、单/双引号和 ANSI-C 引号。
# 不使用 source/eval，不执行变量、命令或算术展开；未知旧字段只忽略，不执行。
CONFIG_KEYS=(SHOW_IP_API_URL CHANGE_IP_API_URL CHECK_TARGET CHECK_INTERVAL CN_PROBES FAIL_THRESHOLD GP_PACKETS GP_RESULT_WAIT_SECONDS COOLDOWN_SECONDS CURL_TIMEOUT POST_CHANGE_WAIT_SECONDS DNS_RESOLVER MIN_API_INTERVAL)
STATUS_KEYS=(FAILURE_COUNT LAST_CHANGE_EPOCH LAST_API_CALL_EPOCH LAST_CHECK_EPOCH LAST_TARGET LAST_RESOLVED_IP LAST_RESULT LAST_MEASUREMENT_ID)

decode_env_value() {
    local s="$1" out="" mode=u ch next esc="" i=0
    while (( i < ${#s} )); do
        ch="${s:i:1}"
        case "$mode" in
            u)
                case "$ch" in
                    "'") mode=s ;;
                    '"') mode=d ;;
                    '\') i=$((i+1)); (( i < ${#s} )) || return 1; out+="${s:i:1}" ;;
                    '$')
                        if [[ "${s:i+1:1}" == "'" ]]; then mode=a; esc=""; i=$((i+1)); else out+="$ch"; fi ;;
                    *) out+="$ch" ;;
                esac ;;
            s) if [[ "$ch" == "'" ]]; then mode=u; else out+="$ch"; fi ;;
            d)
                if [[ "$ch" == '"' ]]; then mode=u
                elif [[ "$ch" == '\' ]]; then
                    i=$((i+1)); (( i < ${#s} )) || return 1; next="${s:i:1}"
                    case "$next" in '$'|'`'|'"'|'\') out+="$next" ;; *) out+="\\$next" ;; esac
                else out+="$ch"; fi ;;
            a)
                if [[ "$ch" == "'" ]]; then
                    printf -v next '%b' "$esc" || return 1
                    out+="$next"; mode=u
                elif [[ "$ch" == '\' ]]; then
                    i=$((i+1)); (( i < ${#s} )) || return 1
                    next="${s:i:1}"
                    # 保留旧 %q ANSI-C 编码；拒绝会截断输出的 \c。
                    [[ "$next" != c ]] || return 1
                    case "$next" in
                        "'"|'"'|'?') esc+="$next" ;;
                        *) esc+="\\$next" ;;
                    esac
                else esc+="$ch"; fi ;;
        esac
        i=$((i+1))
    done
    [[ "$mode" == u ]] || return 1
    REPLY="$out"
}

read_env_file() {
    local file="$1" kind="$2" line key encoded REPLY="" allowed line_key line_no=0
    local -A parsed=()
    [[ -e "$file" ]] || return 0
    [[ -f "$file" && -r "$file" && ! -L "$file" ]] || { wlog "❌ 配置/状态文件不可读或为符号链接。"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no+1)); line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            wlog "❌ 配置/状态第 ${line_no} 行不是 KEY=value；拒绝执行。"; return 1
        fi
        key="${BASH_REMATCH[1]}"; encoded="${BASH_REMATCH[2]}"; allowed=0
        if [[ "$kind" == config ]]; then
            for line_key in "${CONFIG_KEYS[@]}" HINET_API_URL; do [[ "$key" == "$line_key" ]] && allowed=1; done
        else
            for line_key in "${STATUS_KEYS[@]}"; do [[ "$key" == "$line_key" ]] && allowed=1; done
        fi
        (( allowed == 1 )) || continue
        [[ ! ${parsed[$key]+present} ]] || { wlog "❌ 配置/状态存在重复字段：${key}"; return 1; }
        decode_env_value "$encoded" || { wlog "❌ 配置/状态字段编码无效：${key}"; return 1; }
        parsed["$key"]="$REPLY"
    done < "$file" || return 1
    for key in "${!parsed[@]}"; do printf -v "$key" '%s' "${parsed[$key]}" || return 1; done
}

validate_numbers() {
    local spec key min max
    for spec in CHECK_INTERVAL:30:3600 CN_PROBES:1:50 FAIL_THRESHOLD:1:30 GP_PACKETS:1:20 GP_RESULT_WAIT_SECONDS:10:180 COOLDOWN_SECONDS:0:86400 CURL_TIMEOUT:5:180 POST_CHANGE_WAIT_SECONDS:0:1800 MIN_API_INTERVAL:0:3600; do
        IFS=: read -r key min max <<< "$spec"
        number_in_range "${!key}" "$min" "$max" || { wlog "❌ ${key} 必须为 ${min}-${max} 的十进制整数；没有保存或采用默认值。"; return 1; }
    done
    # 先全部校验，再规范十进制，防止 08/09 被 Bash 视为八进制。
    for key in CHECK_INTERVAL CN_PROBES FAIL_THRESHOLD GP_PACKETS GP_RESULT_WAIT_SECONDS COOLDOWN_SECONDS CURL_TIMEOUT POST_CHANGE_WAIT_SECONDS MIN_API_INTERVAL; do
        printf -v "$key" '%s' "$((10#${!key}))"
    done
}

validate_status_numbers() {
    local key max
    for key in FAILURE_COUNT LAST_CHANGE_EPOCH LAST_API_CALL_EPOCH LAST_CHECK_EPOCH; do
        max=253402300799; [[ "$key" == FAILURE_COUNT ]] && max=1000000000
        number_in_range "${!key}" 0 "$max" || { wlog "❌ 状态字段 ${key} 非法，停止本轮，保留原状态文件。"; return 1; }
    done
    for key in FAILURE_COUNT LAST_CHANGE_EPOCH LAST_API_CALL_EPOCH LAST_CHECK_EPOCH; do printf -v "$key" '%s' "$((10#${!key}))"; done
}

config_snapshot() {
    local key
    for key in "${CONFIG_KEYS[@]}"; do printf '%s=%q\n' "$key" "${!key}" || return 1; done
}

status_snapshot() {
    local key
    for key in "${STATUS_KEYS[@]}"; do printf '%s=%q\n' "$key" "${!key}" || return 1; done
}

is_domain() {
    [[ "${1:-}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]([A-Za-z0-9-]*[A-Za-z0-9])?\.?$ ]]
}

is_http_url() {
    [[ "${1:-}" =~ ^[Hh][Tt][Tt][Pp][Ss]?://[^/[:space:]]+ && ! "$1" =~ [[:cntrl:]] ]]
}

validate_runtime_config() {
    validate_numbers || return 1
    is_http_url "$CHANGE_IP_API_URL" || { wlog "❌ 更换 IP API 必须为 HTTP/HTTPS 地址。"; return 1; }
    if ! is_domain "$SHOW_IP_API_URL" && ! is_http_url "$SHOW_IP_API_URL"; then
        wlog "❌ 获取 IP 来源必须为裸域名或 HTTP/HTTPS API。"; return 1
    fi
    if ! is_domain "$CHECK_TARGET" && ! is_public_ipv4 "$CHECK_TARGET"; then
        wlog "❌ CHECK_TARGET 必须为裸域名或公网 IPv4。"; return 1
    fi
    [[ "$DNS_RESOLVER" =~ ^[A-Za-z0-9:][A-Za-z0-9.:-]*$ ]] || { wlog "❌ DNS_RESOLVER 格式无效。"; return 1; }
}

load_config() {
    SHOW_IP_API_URL=""
    CHANGE_IP_API_URL=""
    HINET_API_URL=""
    CHECK_TARGET=""
    CHECK_INTERVAL="$DEFAULT_CHECK_INTERVAL"
    CN_PROBES="$DEFAULT_CN_PROBES"
    FAIL_THRESHOLD="$DEFAULT_FAIL_THRESHOLD"
    GP_PACKETS="$DEFAULT_GP_PACKETS"
    GP_RESULT_WAIT_SECONDS="$DEFAULT_RESULT_WAIT_SECONDS"
    COOLDOWN_SECONDS="$DEFAULT_COOLDOWN_SECONDS"
    CURL_TIMEOUT="$DEFAULT_CURL_TIMEOUT"
    POST_CHANGE_WAIT_SECONDS="$DEFAULT_POST_CHANGE_WAIT_SECONDS"
    DNS_RESOLVER="$DEFAULT_RESOLVER"
    MIN_API_INTERVAL="$DEFAULT_MIN_API_INTERVAL"
    read_env_file "$CONF_FILE" config || return 1
    [[ -n "$CHANGE_IP_API_URL" ]] || CHANGE_IP_API_URL="$HINET_API_URL"
    validate_numbers
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
    read_env_file "$STATUS_FILE" status || return 1
    validate_status_numbers
}
save_status() {
    local tmp expected actual
    validate_status_numbers || return 1
    mkdirs || return 1
    [[ ! -L "$STATUS_FILE" ]] || { wlog "❌ 状态文件不能是符号链接。"; return 1; }
    expected="$(status_snapshot)" || return 1
    tmp="$(mktemp "${STATE_DIR}/.status.XXXXXX")" || { wlog "❌ 创建临时状态文件失败。"; return 1; }
    if ! status_snapshot > "$tmp" || ! chmod 600 "$tmp"; then
        rm -f -- "$tmp"; wlog "❌ 写入临时状态文件失败；原状态未替换。"; return 1
    fi
    actual="$(STATUS_FILE="$tmp"; load_status && status_snapshot)" || { rm -f -- "$tmp"; wlog "❌ 临时状态读取校验失败。"; return 1; }
    if [[ "$actual" != "$expected" ]] || ! mv -f -- "$tmp" "$STATUS_FILE"; then
        rm -f -- "$tmp"; wlog "❌ 状态安全替换失败。"; return 1
    fi
}
validate_config() {
    validate_runtime_config
}
is_public_ipv4() {
    local ip="${1:-}" a b c d x IFS=.
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r a b c d <<< "$ip"
    for x in "$a" "$b" "$c" "$d"; do
        [[ "$x" == 0 || "$x" != 0* ]] || return 1
        number_in_range "$x" 0 255 || return 1
    done
    (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1
    (( a == 169 && b == 254 )) && return 1
    (( a == 172 && b >= 16 && b <= 31 )) && return 1
    (( a == 192 && b == 168 )) && return 1
    (( a == 198 && (b == 18 || b == 19) )) && return 1
    (( a == 192 && b == 0 && (c == 0 || c == 2) )) && return 1
    (( a == 198 && b == 51 && c == 100 )) && return 1
    (( a == 203 && b == 0 && c == 113 )) && return 1
    return 0
}
extract_public_ipv4() {
    local text="${1:-}" ip
    while read -r ip; do
        is_public_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
    done < <(printf '%s' "$text" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '!seen[$0]++')
    return 1
}

# 返回 0=传输成功且 HTTP 2xx；非 0=失败。错误信息绝不并入正文。
# HTTP_SENT 只在 curl 报告实际 HTTP 请求字节时置 1；TLS/DNS 失败不视为已发出 API。
http_request() {
    local url="$1" timeout="$2" payload="${3:-}" redirects="${4:-1}" dir meta rc escaped curl_error=""
    HTTP_BODY=""; HTTP_CODE=000; HTTP_CURL_RC=0; HTTP_SENT=0; HTTP_STARTED_AT=0
    is_http_url "$url" && number_in_range "$timeout" 1 180 || { wlog "❌ HTTP 请求参数无效，未发送。"; return 3; }
    has_cmd curl || { wlog "❌ curl 不存在，未发送。"; return 3; }
    dir="$(mktemp -d)" || { wlog "❌ HTTP 临时目录创建失败，未发送。"; return 3; }
    chmod 700 "$dir" || { rm -rf -- "$dir"; return 3; }
    escaped="${url//\\/\\\\}"; escaped="${escaped//\"/\\\"}"
    if ! (umask 077; printf 'url = "%s"\n' "$escaped" > "$dir/request.conf"); then rm -rf -- "$dir"; return 3; fi
    local -a args=(-q -sS --globoff --retry 0 --connect-timeout 10 --max-time "$timeout" --proto '=http,https' --output "$dir/body" --write-out '%{http_code}\t%{size_request}' --config "$dir/request.conf")
    # 查询沿用重定向；有副作用的换 IP 请求不追随重定向，避免重复执行。
    [[ "$redirects" == 1 ]] && args+=(-L --max-redirs 5 --proto-redir '=http,https')
    [[ -n "$payload" ]] && args+=(-H 'Content-Type: application/json' --data "$payload")
    HTTP_STARTED_AT="$(now_epoch)"
    number_in_range "$HTTP_STARTED_AT" 0 253402300799 || { rm -rf -- "$dir"; wlog "❌ 读取系统时间失败，未发送。"; return 3; }
    wlog "🌐 HTTP 请求地址：${url}"
    meta="$(curl "${args[@]}" 2>"$dir/error")"; rc=$?
    HTTP_CURL_RC="$rc"
    local sent_bytes=0
    IFS=$'\t' read -r HTTP_CODE sent_bytes <<< "$meta"
    [[ "$HTTP_CODE" =~ ^[0-9]{3}$ ]] || HTTP_CODE=000
    if [[ "$sent_bytes" =~ ^[0-9]{1,12}$ ]] && (( 10#$sent_bytes > 0 )); then HTTP_SENT=1; fi
    case "$rc" in 3|5|6|7|35|51|58|60|77|83|127) HTTP_SENT=0 ;; esac
    if [[ -f "$dir/body" ]]; then HTTP_BODY="$(cat -- "$dir/body")" || rc=23; fi
    HTTP_CURL_RC="$rc"
    if [[ -f "$dir/error" ]]; then curl_error="$(cat -- "$dir/error")" || curl_error="无法读取 curl 错误输出"; fi
    [[ -z "$curl_error" ]] || wlog "🧾 curl 错误输出（完整）：${curl_error}"
    if [[ "$url" != "${GLOBALPING_API_BASE}/"* ]] || (( rc != 0 )) || [[ ! "$HTTP_CODE" =~ ^2[0-9]{2}$ ]]; then
        wlog "🧾 HTTP 响应正文（完整）：${HTTP_BODY}"
    fi
    rm -rf -- "$dir" || { wlog "⚠️ HTTP 临时文件清理失败。"; return 1; }
    if (( rc != 0 )) || [[ ! "$HTTP_CODE" =~ ^2[0-9]{2}$ ]]; then
        wlog "❌ HTTP 请求失败：curl_rc=${rc}，HTTP=${HTTP_CODE}；未把错误正文作为成功结果。"
        return 1
    fi
    return 0
}

unique_public_ipv4() {
    local text="${1:-}" ip found=""
    while IFS= read -r ip; do
        is_public_ipv4 "$ip" || continue
        [[ -z "$found" || "$found" == "$ip" ]] || return 1
        found="$ip"
    done <<< "$text"
    [[ -n "$found" ]] || return 1
    printf '%s' "$found"
}

# 仅解析明确的 IP 字段/纯 IP；HTML、错误页和任意文本里的 IP 不作为当前 IP 证据。
response_public_ipv4() {
    local body="${1:-}" candidates
    body="${body#"${body%%[![:space:]]*}"}"; body="${body%"${body##*[![:space:]]}"}"
    if is_public_ipv4 "$body"; then printf '%s' "$body"; return 0; fi
    candidates="$(printf '%s' "$body" | jq -er '
        if type == "string" then .
        elif type == "object" then
          [.mainip?, .ip?, .ipv4?, .public_ip?, .current_ip?,
           (if (.data? | type) == "string" then .data else empty end),
           (if (.data? | type) == "object" then (.data.mainip?, .data.ip?, .data.ipv4?, .data.public_ip?, .data.current_ip?) else empty end)]
          | .[] | select(type == "string")
        else empty end' 2>/dev/null)" || return 1
    unique_public_ipv4 "$candidates"
}

vendor_response_kind() {
    local body="${1:-}" flags text
    if printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1; then
        flags="$(printf '%s' "$body" | jq -r '
          def s: tostring | ascii_downcase;
          if (([.success?, .ok?] | any(. != null and (s | test("^(false|0|no|failed|failure|error)$")))) or ((.error? != null) and (.error != false) and (.error != "") and (.error != 0))) then "failure"
          elif ([.status?, .code?] | any(. != null and ((s | test("^(fail(ed|ure)?|error|denied|invalid)$")) or ((s | test("^[45][0-9][0-9]$")))))) then "failure"
          elif (([.msg?,.message?] | map(select(type == "string")) | join(" ")) | test("失败|错误|无效|拒绝|频繁|未成功|(?i)\\b(failed|failure|invalid|denied|error)\\b")) then "failure"
          elif (.success? == true or .ok? == true or ([.status?,.code?] | any(. != null and (s | test("^(1000|200|201|202|204|success|ok|true)$"))))) then "success"
          else "unknown" end' 2>/dev/null)" || flags=unknown
        printf '%s' "$flags"; return 0
    fi
    if response_public_ipv4 "$body" >/dev/null 2>&1; then printf 'success'; return 0; fi
    text="$(printf '%s' "$body" | tr '\r\n' '  ')"
    if [[ "$text" == *'<'* || "$text" == *'{'* || "$text" == *'['* ]]; then printf 'unknown'
    elif printf '%s' "$text" | grep -qiE '失败|错误|无效|拒绝|频繁|未成功|failed|failure|invalid|denied|error'; then printf 'failure'
    elif printf '%s' "$text" | grep -qiE '^[[:space:]]*(ok|success|true|成功|重置IP成功|更换IP成功)[.!。[:space:]]*$'; then printf 'success'
    else printf 'unknown'; fi
}

vendor_summary() {
    local kind ip
    kind="$(vendor_response_kind "${1:-}")"
    ip="$(response_public_ipv4 "${1:-}" 2>/dev/null || true)"
    printf '业务判定=%s，明确IP字段=%s\n返回正文（完整）：%s' "$kind" "${ip:-无}" "${1:-}"
}

curl_get() {
    local url="$1" timeout="${2:-$CURL_TIMEOUT}"
    http_request "$url" "$timeout" || return 1
    printf '%s' "$HTTP_BODY"
}
resolve_target_ip() {
    local target="${1:-$CHECK_TARGET}" resolver="${DNS_RESOLVER:-$DEFAULT_RESOLVER}" body="" ip=""
    if is_public_ipv4 "$target"; then printf '%s' "$target"; return 0; fi
    is_domain "$target" || return 1
    if has_cmd dig; then
        body="$(dig +time=3 +tries=1 +short A "$target" "@${resolver}" 2>/dev/null)" || body=""
        body="$(printf '%s\n' "$body" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true)"
        # 有 A 答案但多 IP/非公网时不回退挑选另一 IP，避免 DNS 轮询伪装成换 IP。
        if [[ -n "$body" ]]; then unique_public_ipv4 "$body"; return $?; fi
    fi
    if has_cmd getent && has_cmd timeout; then
        body="$(timeout 10 getent ahostsv4 "$target" 2>/dev/null | awk '{print $1}')" || body=""
        ip="$(unique_public_ipv4 "$body")" || return 1
    fi
    [[ -n "$ip" ]] || return 1
    printf '%s' "$ip"
}
get_current_ip_from_api() {
    local body ip kind
    if is_domain "$SHOW_IP_API_URL"; then
        if ip="$(resolve_target_ip "$SHOW_IP_API_URL")"; then printf '%s' "$ip"; return 0; fi
        wlog "❌ 获取当前 IP 域名未返回唯一公网 IPv4。"; return 1
    fi
    body="$(curl_get "$SHOW_IP_API_URL" "$CURL_TIMEOUT")" || return 1
    kind="$(vendor_response_kind "$body")"
    [[ "$kind" != failure ]] || { wlog "❌ 获取当前 IP API 返回业务失败；不提取其中的 IP。"; return 1; }
    if ip="$(response_public_ipv4 "$body")"; then printf '%s' "$ip"; return 0; fi
    wlog "❌ 获取当前 IP API 未返回明确且唯一的公网 IPv4。"
    return 1
}
append_history() {
    local old_ip="$1" new_ip="$2" old_ddns="$3" new_ddns="$4" reason="$5" note="$6"
    mkdirs || return 1
    printf '%s\told_ip=%s\tnew_ip=%s\told_ddns=%s\tnew_ddns=%s\treason=%s\tnote=%s\n' \
        "$(now_human)" "$old_ip" "$new_ip" "$old_ddns" "$new_ddns" "$reason" "$note" >> "$HISTORY_FILE" || { wlog "❌ 写入正式成功历史失败。"; return 1; }
}

globalping_create_measurement() {
    local target="$1" payload id
    payload="$(jq -nc --arg target "$target" --argjson limit "$CN_PROBES" --argjson packets "$GP_PACKETS" \
        '{type:"ping",target:$target,locations:[{country:"CN",limit:$limit}],measurementOptions:{packets:$packets,ipVersion:4}}')" || return 1
    http_request "${GLOBALPING_API_BASE}/measurements" "$CURL_TIMEOUT" "$payload" || return 1
    id="$(printf '%s' "$HTTP_BODY" | jq -er '.id | select(type == "string")' 2>/dev/null)" || { wlog "⚠️ Globalping 创建任务返回无效 JSON/ID。"; return 1; }
    [[ "$id" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || { wlog "⚠️ Globalping measurement ID 格式无效。"; return 1; }
    printf '%s' "$id"
}

globalping_parse_result() {
    jq -er '
      def integer: if type == "number" then . == floor else false end;
      def valid:
        .result as $p |
        ($p.status == "finished") and
        (($p.failureSource? // "target") == "target") and
        ($p.stats.total | integer) and ($p.stats.rcv | integer) and
        ($p.stats.total > 0) and ($p.stats.rcv >= 0) and ($p.stats.rcv <= $p.stats.total) and
        (if $p.stats.loss? == null then true else
          (($p.stats.loss | type) == "number") and ($p.stats.loss >= 0) and ($p.stats.loss <= 100) and
          (if $p.stats.rcv == 0 then $p.stats.loss == 100 else $p.stats.loss < 100 end)
        end);
      if type != "object" or (.status != "in-progress" and .status != "finished") or (.results | type) != "array"
      then error("invalid measurement") else . end |
      [.results[] | select(.probe.country? == "CN")] as $r |
      ($r | map(select(valid))) as $v |
      [.status, ($r|length), ($v|length), ($v|map(select(.result.stats.rcv > 0))|length)] | @tsv
    ' 2>/dev/null
}

globalping_check_target() {
    local target="${1:-$CHECK_TARGET}" id deadline parsed status total valid okn remaining req_timeout
    LAST_MEASUREMENT_ID=""
    validate_numbers || return 2
    wlog "🧪 Globalping 请求开始：target=${target}，country=CN，probes=${CN_PROBES}，packets=${GP_PACKETS}"
    id="$(globalping_create_measurement "$target")" || return 2
    LAST_MEASUREMENT_ID="$id"
    deadline=$(( $(now_epoch) + GP_RESULT_WAIT_SECONDS ))
    while true; do
        remaining=$((deadline - $(now_epoch)))
        if (( remaining <= 0 )); then wlog "⚠️ Globalping 结果仍未完成，本轮不计失败，measurement=${id}"; return 2; fi
        req_timeout="$CURL_TIMEOUT"; (( req_timeout > remaining )) && req_timeout="$remaining"
        http_request "${GLOBALPING_API_BASE}/measurements/${id}" "$req_timeout" || return 2
        parsed="$(printf '%s' "$HTTP_BODY" | globalping_parse_result)" || { wlog "⚠️ Globalping 响应格式无效，本轮不计失败。"; return 2; }
        IFS=$'\t' read -r status total valid okn <<< "$parsed"
        if [[ "$status" == finished ]]; then
            if (( valid > 0 && okn > 0 )); then
                wlog "✅ Globalping CN ping 正常：target=${target}，ok=${okn}/${valid}，measurement=${id}"; return 0
            fi
            if (( total > 0 && valid == total )); then
                wlog "❌ Globalping CN ping 全部失败：target=${target}，ok=0/${valid}，measurement=${id}"; return 1
            fi
            wlog "⚠️ Globalping 无有效 CN 探针或存在未完成/离线/内部错误：valid=${valid}/${total}，不计失败。"; return 2
        fi
        sleep 3 || return 2
    done
}

change_ip_worker() (
    local reason="${1:-manual}" official="${2:-1}"
    mkdirs || { wlog "❌ 无法准备状态目录，未发出换 IP 请求。"; return 3; }
    if [[ "${CHANGE_LOCK_HELD:-0}" != 1 ]]; then
        exec 8>"$CHANGE_LOCK_FILE" || { wlog "❌ 无法打开换 IP 锁。"; return 3; }
        flock -n 8 || { wlog "⚠️ 更换 IP/检测锁被占用，本次未发送请求。"; return 3; }
        load_config && validate_runtime_config || return 3
    fi
    load_status || return 3
    local now last_delta old_ip old_ddns body returned_ip new_ip new_ddns note kind request_rc call_time
    now="$(now_epoch)"
    last_delta=$((now - LAST_API_CALL_EPOCH))
    if (( LAST_API_CALL_EPOCH > now || LAST_CHANGE_EPOCH > now )); then
        wlog "⚠️ 本机时钟早于上次操作时间，本次未发出请求。"; return 3
    fi
    if (( MIN_API_INTERVAL > 0 && LAST_API_CALL_EPOCH > 0 && last_delta < MIN_API_INTERVAL )); then
        wlog "⏳ 距离上次调用更换 IP API 仅 ${last_delta}s，小于最小间隔 ${MIN_API_INTERVAL}s，本次不调用。"; return 3
    fi
    if [[ "$reason" == globalping_* ]] && (( COOLDOWN_SECONDS > 0 && LAST_CHANGE_EPOCH > 0 && now - LAST_CHANGE_EPOCH < COOLDOWN_SECONDS )); then
        wlog "⏳ 自动换 IP 仍在冷却期，本次不调用。"; return 3
    fi
    old_ip="$(get_current_ip_from_api 2>/dev/null || true)"
    old_ddns="$(resolve_target_ip 2>/dev/null || true)"
    # 在实际请求前确认状态能安全写入；不提前改变 API 调用时间。
    save_status || { wlog "❌ 状态不可写，未发出换 IP 请求。"; return 3; }
    wlog "🔁 准备调用更换 IP API，reason=${reason}，old_ip=${old_ip:-unknown}，old_ddns=${old_ddns:-unknown}，target=${CHECK_TARGET}"
    http_request "$CHANGE_IP_API_URL" "$CURL_TIMEOUT" "" 0; request_rc=$?
    body="$HTTP_BODY"; call_time="$HTTP_STARTED_AT"
    if [[ "$HTTP_SENT" == 1 ]]; then
        LAST_API_CALL_EPOCH="$call_time"
        save_status || { wlog "❌ 请求已发出，但调用时间保存失败；请暂停自动任务检查存储。"; return 4; }
    fi
    if (( request_rc != 0 )); then
        wlog "❌ 更换 IP 请求失败：curl_rc=${HTTP_CURL_RC}，HTTP=${HTTP_CODE}，request_sent=${HTTP_SENT}；保留失败计数和上次成功时间。"
        [[ "$request_rc" == 3 ]] && return 3
        return 1
    fi
    [[ "$HTTP_SENT" == 1 ]] || { wlog "⚠️ 无法核对请求是否发出，结果未确认。"; return 2; }
    wlog "🧾 更换 IP API 返回摘要：$(vendor_summary "$body")"
    kind="$(vendor_response_kind "$body")"
    if [[ "$kind" == failure ]]; then wlog "❌ 更换 IP API 明确返回业务失败，保留失败计数。"; return 1; fi
    returned_ip="$(response_public_ipv4 "$body" 2>/dev/null || true)"
    if (( POST_CHANGE_WAIT_SECONDS > 0 )); then
        wlog "⏳ 等待 ${POST_CHANGE_WAIT_SECONDS} 秒后确认获取 API / DDNS 结果。"
        sleep "$POST_CHANGE_WAIT_SECONDS" || { wlog "⚠️ 等待被中断，换 IP 未确认。"; return 2; }
    fi
    new_ip="$(get_current_ip_from_api 2>/dev/null || true)"
    new_ddns="$(resolve_target_ip 2>/dev/null || true)"
    wlog "ℹ️ 换 IP 前后对比：old_ip=${old_ip:-unknown}，new_ip=${new_ip:-unknown}，old_ddns=${old_ddns:-unknown}，new_ddns=${new_ddns:-unknown}"
    # 证据：同一独立获取来源前后均为唯一公网 IPv4，且不同；有返回 IP 时还必须与复查一致。
    if [[ "$kind" != success ]] || ! is_public_ipv4 "$old_ip" || ! is_public_ipv4 "$new_ip" || [[ "$old_ip" == "$new_ip" ]] || [[ -n "$returned_ip" && "$returned_ip" != "$new_ip" ]]; then
        wlog "⚠️ 请求已完成，但未确认公网 IP 变化：可能是 showip 查询接口、DDNS/API 未更新或响应证据不足；不清零计数，不记正式成功。"; return 2
    fi
    note="confirmed_by_current_ip_source"
    LAST_CHANGE_EPOCH="$(now_epoch)"
    FAILURE_COUNT=0
    LAST_RESULT="changed_ip"
    LAST_RESOLVED_IP="$new_ddns"
    save_status || { wlog "❌ 公网 IP 已确认变化，但结果状态保存失败。"; return 4; }
    if [[ "$official" == 1 ]]; then
        append_history "$old_ip" "$new_ip" "${old_ddns:-unknown}" "${new_ddns:-unknown}" "$reason" "$note" || return 4
    fi
    wlog "✅ 已确认公网 IP 变化：${old_ip} -> ${new_ip}，DDNS：${old_ddns:-unknown} -> ${new_ddns:-unknown}，reason=${reason}，note=${note}"
    return 0
)

main_worker() (
    mkdirs || return 1
    wlog "🚪 worker entry：version=${APP_VERSION}，pid=$$，conf=${CONF_FILE}，log=${LOG_FILE}"
    exec 8>"$CHANGE_LOCK_FILE" || { wlog "❌ 无法打开检测/换 IP 锁。"; return 1; }
    flock -n 8 || { wlog "⚠️ 已有检测或换 IP 流程运行，本轮跳过。"; return 0; }
    local CHANGE_LOCK_HELD=1
    if ! load_config || ! validate_runtime_config; then wlog "❌ 配置无效，本轮未检测。"; return 1; fi
    load_status || return 1
    local resolved_ip rc change_rc
    if [[ -n "$LAST_TARGET" && "$LAST_TARGET" != "$CHECK_TARGET" ]]; then
        FAILURE_COUNT=0
        wlog "ℹ️ 检测目标已变更，旧目标失败计数不计入新目标。"
    fi
    resolved_ip="$(resolve_target_ip 2>/dev/null || true)"
    LAST_CHECK_EPOCH="$(now_epoch)"; LAST_TARGET="$CHECK_TARGET"; LAST_RESOLVED_IP="$resolved_ip"
    save_status || return 1
    wlog "🛰️ 定时检测开始：target=${CHECK_TARGET}，resolved_ip=${resolved_ip:-unknown}，failure=${FAILURE_COUNT}/${FAIL_THRESHOLD}，interval=${CHECK_INTERVAL}s"
    globalping_check_target "$CHECK_TARGET"; rc=$?
    if [[ "$rc" == 0 ]]; then
        FAILURE_COUNT=0; LAST_RESULT="ok"
        save_status || return 1
        wlog "✅ 定时判定：CN ping 正常，失败计数已清零。"
    elif [[ "$rc" == 1 ]]; then
        (( FAILURE_COUNT < 1000000000 )) && FAILURE_COUNT=$((FAILURE_COUNT+1))
        LAST_RESULT="cn_ping_failed"
        save_status || return 1
        wlog "⚠️ 定时判定：CN ping 全部失败，连续失败计数：${FAILURE_COUNT}/${FAIL_THRESHOLD}。"
        if (( FAILURE_COUNT >= FAIL_THRESHOLD )); then
            wlog "🚨 达到失败阈值，检查冷却/调用间隔后尝试更换 IP。"
            change_ip_worker "globalping_cn_ping_failed_${FAILURE_COUNT}_times" 1; change_rc=$?
            # change 在子 shell 内更新状态；重新读盘，禁止用旧快照覆盖时间戳。
            load_status || return 1
            case "$change_rc" in
                0) wlog "✅ 自动换 IP 已确认，失败计数已清零。" ;;
                1) LAST_RESULT="change_ip_failed"; wlog "❌ 自动换 IP 请求或业务失败，保留失败计数。" ;;
                2) LAST_RESULT="change_ip_unconfirmed"; wlog "⚠️ 自动换 IP 未确认，保留失败计数。" ;;
                3) LAST_RESULT="change_ip_skipped"; wlog "⏳ 本轮未发出换 IP 请求，保留失败计数。" ;;
                *) wlog "❌ 换 IP 流程持久化失败，请检查存储；本轮报错。"; return 1 ;;
            esac
            save_status || return 1
        fi
    else
        LAST_RESULT="globalping_unknown"
        save_status || return 1
        wlog "⚠️ 定时判定：Globalping API/探针异常，本轮不计入连续失败。"
    fi
    wlog "🏁 定时检测结束：last_result=${LAST_RESULT}，failure_count=${FAILURE_COUNT}/${FAIL_THRESHOLD}"
    return 0
)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main_worker; fi
EOF_RUNNER
    if ! bash -n "$runner_tmp" || ! chmod 755 "$runner_tmp" || ! mv -f -- "$runner_tmp" "$RUNNER_PATH"; then
        rm -f -- "$runner_tmp"; err "worker 语法校验/权限/安全替换失败。"; return 1
    fi
}

# -----------------------------
# systemd timer / 安装卸载
# -----------------------------
write_units() {
    # 不再隐式 load_config；调用者必须已保存并核对最终配置。
    validate_numbers || return 1
    local interval="$CHECK_INTERVAL" service_tmp timer_tmp timeout_start
    timeout_start=$((POST_CHANGE_WAIT_SECONDS + GP_RESULT_WAIT_SECONDS + 6*CURL_TIMEOUT + 180))
    service_tmp="$(mktemp "${SERVICE_FILE}.tmp.XXXXXX")" || { err "创建 service 临时文件失败。"; return 1; }
    timer_tmp="$(mktemp "${TIMER_FILE}.tmp.XXXXXX")" || { rm -f -- "$service_tmp"; err "创建 timer 临时文件失败。"; return 1; }
    if ! cat > "$service_tmp"; then
        rm -f -- "$service_tmp" "$timer_tmp"; err "写入 service 临时文件失败。"; return 1
    fi <<EOF_SERVICE
[Unit]
Description=HiNet GFW Auto Change IP - timer worker Globalping CN check
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${RUNNER_PATH}
TimeoutStartSec=${timeout_start}
WorkingDirectory=/
Environment=LANG=C.UTF-8
Environment=LC_ALL=C.UTF-8
UMask=0077
StandardOutput=journal
StandardError=journal
EOF_SERVICE
    if ! cat > "$timer_tmp"; then
        rm -f -- "$service_tmp" "$timer_tmp"; err "写入 timer 临时文件失败。"; return 1
    fi <<EOF_TIMER
[Unit]
Description=Run HiNet GFW Auto Change IP check every ${interval}s

[Timer]
OnBootSec=30s
OnUnitActiveSec=${interval}s
# 长任务完成后仍能重新安排下一轮；正常短任务继续使用上面的启动间隔。
OnUnitInactiveSec=${interval}s
AccuracySec=1s
Unit=${APP_NAME}.service
Persistent=false

[Install]
WantedBy=timers.target
EOF_TIMER
    if ! chmod 644 "$service_tmp" "$timer_tmp" || ! write_runner; then
        rm -f -- "$service_tmp" "$timer_tmp"; err "systemd 单元准备失败。"; return 1
    fi
    if ! mv -f -- "$service_tmp" "$SERVICE_FILE"; then rm -f -- "$service_tmp" "$timer_tmp"; err "service 安全替换失败。"; return 1; fi
    if ! mv -f -- "$timer_tmp" "$TIMER_FILE"; then rm -f -- "$timer_tmp"; err "timer 安全替换失败；service 已更新，尚未重新加载。"; return 1; fi
    systemctl daemon-reload || { err "systemctl daemon-reload 失败；文件已保存，但不能确认 systemd 已应用。"; return 1; }
}

install_self() {
    require_root
    has_cmd systemctl || { err "当前系统没有 systemctl，无法安装定时器。"; return 1; }
    load_config && validate_runtime_config || return 1
    install_packages || { err "依赖安装失败。"; return 1; }
    mkdirs || { err "创建目录或设置权限失败。"; return 1; }
    local src="${BASH_SOURCE[0]}" tmp backup
    [[ -f "$src" && -s "$src" ]] || { err "完整源码暂存文件不可读，未安装；请重新运行本版脚本。"; return 1; }
    bash -n "$src" || { err "源脚本语法检查失败，未安装。"; return 1; }
    [[ ! -L "$INSTALL_PATH" ]] || { err "安装路径不能是符号链接。"; return 1; }
    if [[ ! "$src" -ef "$INSTALL_PATH" ]]; then
        mkdir -p -- "$(dirname "$INSTALL_PATH")" || return 1
        tmp="$(mktemp "${INSTALL_PATH}.tmp.XXXXXX")" || { err "创建安装临时文件失败。"; return 1; }
        if ! cp -- "$src" "$tmp" || ! bash -n "$tmp" || ! chmod 755 "$tmp"; then rm -f -- "$tmp"; err "复制/校验安装脚本失败。"; return 1; fi
        if [[ -f "$INSTALL_PATH" ]]; then
            backup="${INSTALL_PATH}.bak.$(date +%Y%m%d%H%M%S).${BASHPID}"
            cp -p -- "$INSTALL_PATH" "$backup" || { rm -f -- "$tmp"; err "备份原脚本失败。"; return 1; }
        fi
        mv -f -- "$tmp" "$INSTALL_PATH" || { rm -f -- "$tmp"; err "安全替换主脚本失败。"; return 1; }
    else
        chmod 755 "$INSTALL_PATH" || { err "设置安装脚本权限失败。"; return 1; }
    fi
    write_units || { err "脚本可能已复制，但 worker/systemd 更新未全部完成。"; return 1; }
    log "✅ 安装/覆盖完成：${INSTALL_PATH}，版本=${APP_VERSION}。"
    ok "安装完成：${INSTALL_PATH}"
    ok "服务文件：${SERVICE_FILE}"
    ok "定时器文件：${TIMER_FILE}"
}

service_start() {
    require_root
    install_self || return 1
    systemctl enable --now "${APP_NAME}.timer" || { err "启用/启动 timer 失败。"; return 1; }
    systemctl start "${APP_NAME}.service" || { err "timer 已启用，但首次检测 service 失败，请查看中文日志。"; return 1; }
    ok "已启动定时器：${APP_NAME}.timer"
    systemctl --no-pager --full status "${APP_NAME}.timer"
}

service_stop() {
    require_root
    local failed=0
    systemctl disable --now "${APP_NAME}.timer" || { err "停止/禁用 timer 失败。"; failed=1; }
    systemctl stop "${APP_NAME}.service" || { err "停止当前 service 失败。"; failed=1; }
    (( failed == 0 )) || return 1
    ok "已停止定时器和当前检测任务。"
}

service_restart() {
    require_root
    install_self || return 1
    systemctl enable "${APP_NAME}.timer" || { err "启用 timer 开机启动失败。"; return 1; }
    systemctl restart "${APP_NAME}.timer" || { err "重启 timer 失败。"; return 1; }
    systemctl start "${APP_NAME}.service" || { err "timer 已重启，但当前 service 检测失败。"; return 1; }
    ok "已重启定时器，并执行一次检测。"
}

service_status() {
    require_root
    load_config || return 1
    load_status || return 1
    cecho "🧩 ${APP_VERSION} 状态"
    cecho "----------------------------------------"
    cecho "⏱️ timer 状态："
    systemctl --no-pager --full status "${APP_NAME}.timer" || true
    cecho ""
    cecho "🧪 最近一次 service 状态："
    systemctl --no-pager --full status "${APP_NAME}.service" || true
    cecho ""
    cecho "📌 当前配置："
    cecho "  检测目标：$(display_value "${CHECK_TARGET:-}")"
    cecho "  检测间隔：${CHECK_INTERVAL:-未配置}s"
    cecho "  中国节点：${CN_PROBES:-未配置} 个"
    cecho "  失败阈值：${FAIL_THRESHOLD:-未配置} 次"
    cecho "  冷却时间：${COOLDOWN_SECONDS:-未配置}s"
    cecho "  换 IP 后等待：${POST_CHANGE_WAIT_SECONDS:-未配置}s"
    cecho "  DNS 解析器：$(display_value "${DNS_RESOLVER:-}")"
    cecho "  API 最小间隔：${MIN_API_INTERVAL:-未配置}s"
    cecho "  Worker：${RUNNER_PATH}"
    cecho "  获取 IP API：$(display_value "${SHOW_IP_API_URL:-}")"
    cecho "  更换 IP API：$(display_value "${CHANGE_IP_API_URL:-}")"
    cecho ""
    cecho "📊 最近状态："
    cecho "  LAST_TARGET=$(display_value "${LAST_TARGET:-}")"
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


read_config_field() {
    local key="$1" prompt="$2" min="${3:-}" max="${4:-}" v candidate
    while true; do
        IFS= read -r -p "$prompt" v || { err "输入已结束，本次没有保存配置。"; return 1; }
        candidate="${v:-${!key}}"
        if [[ -n "$min" ]]; then
            if ! number_in_range "$candidate" "$min" "$max"; then err "${key} 必须为 ${min}-${max} 的十进制整数，请重新输入。"; continue; fi
            candidate="$((10#$candidate))"
        elif [[ -z "$candidate" ]]; then
            err "${key} 不能为空，请重新输入。"; continue
        fi
        printf -v "$key" '%s' "$candidate"
        return 0
    done
}

# 与检测共用短生命周期锁；提示输入期间不持锁、不复制脚本、不写 unit。
apply_config_changes() (
    validate_runtime_config || return 1
    install_packages || { err "依赖准备失败，配置未保存。"; return 1; }
    [[ -f "${BASH_SOURCE[0]}" && -s "${BASH_SOURCE[0]}" ]] && bash -n "${BASH_SOURCE[0]}" || { err "完整源码不可读或语法错误，配置未保存。"; return 1; }
    exec 8>"$CHANGE_LOCK_FILE" || { err "无法打开配置更新锁。"; return 1; }
    flock -w 10 8 || { err "检测/换 IP 正在运行，本次未保存，请结束后重试。"; return 1; }
    save_config || return 1
    install_self || { err "配置已写入并核对，但安装/systemd 应用失败；未报告全部成功。"; return 1; }
    local active
    active="$(systemctl show -p ActiveState --value "${APP_NAME}.timer")" || { err "读取 timer 状态失败；配置已保存。"; return 1; }
    if [[ "$active" == active || "$active" == activating ]]; then
        systemctl restart "${APP_NAME}.timer" || { err "配置已保存，daemon-reload 已完成，但 timer 重启失败。"; return 1; }
        ok "定时器已按最终保存的间隔重启。"
    fi
)

quick_init() {
    require_root
    load_config || return 1
    cecho "🚀 ${APP_VERSION} 快速初始化"
    cecho "----------------------------------------"
    warn "直接回车保留已有值；首次配置使用默认参数。初始化不会测试更换 IP API。"
    read_config_field SHOW_IP_API_URL "🔎 获取当前 IP API / 域名 [$(display_value "$SHOW_IP_API_URL")]：" || return 1
    read_config_field CHANGE_IP_API_URL "🔁 真正更换 IP API [$(display_value "$CHANGE_IP_API_URL")]：" || return 1
    read_config_field CHECK_TARGET "🎯 检测目标域名/IP [$(display_value "$CHECK_TARGET")]：" || return 1
    read_config_field CHECK_INTERVAL "⏱️ 检测间隔秒 [${CHECK_INTERVAL}]：" 30 3600 || return 1
    read_config_field CN_PROBES "🇨🇳 中国节点数量 [${CN_PROBES}]：" 1 50 || return 1
    read_config_field FAIL_THRESHOLD "🚨 失败阈值 [${FAIL_THRESHOLD}]：" 1 30 || return 1
    read_config_field GP_PACKETS "📦 ping 包数量 [${GP_PACKETS}]：" 1 20 || return 1
    read_config_field GP_RESULT_WAIT_SECONDS "⌛ Globalping 等待秒数 [${GP_RESULT_WAIT_SECONDS}]：" 10 180 || return 1
    read_config_field COOLDOWN_SECONDS "🧊 冷却秒数 [${COOLDOWN_SECONDS}]：" 0 86400 || return 1
    read_config_field CURL_TIMEOUT "🌐 curl 超时秒数 [${CURL_TIMEOUT}]：" 5 180 || return 1
    read_config_field POST_CHANGE_WAIT_SECONDS "⏳ 换 IP 后等待秒数 [${POST_CHANGE_WAIT_SECONDS}]：" 0 1800 || return 1
    read_config_field DNS_RESOLVER "🧭 DNS 服务器 [$(display_value "$DNS_RESOLVER")]：" || return 1
    read_config_field MIN_API_INTERVAL "🛡️ 更换 API 最小间隔秒 [${MIN_API_INTERVAL}]：" 0 3600 || return 1
    warn_if_showip_action "$CHANGE_IP_API_URL"
    apply_config_changes || return 1
    ok "配置已保存并重新读取核对：${CONF_FILE}（权限 600）"
    test_show_ip_api || warn "获取当前 IP 测试失败，请核对来源。"
    run_single_check || warn "Globalping 测试未成功，请查看上述结果；没有调用更换 IP API。"
    local start_now
    IFS= read -r -p "🚀 是否立即启动后台定时检测？[Y/n]：" start_now || return 0
    start_now="${start_now:-Y}"
    if [[ "$start_now" =~ ^[Yy]$ ]]; then service_start; fi
}

edit_config() {
    require_root
    load_config || return 1
    cecho "🛠️ 修改已有配置：直接回车保留原值"
    cecho "----------------------------------------"
    read_config_field SHOW_IP_API_URL "🔎 获取当前 IP API / 域名 [$(display_value "$SHOW_IP_API_URL")]：" || return 1
    read_config_field CHANGE_IP_API_URL "🔁 真正更换 IP API [$(display_value "$CHANGE_IP_API_URL")]：" || return 1
    read_config_field CHECK_TARGET "🎯 检测目标域名/IP [$(display_value "$CHECK_TARGET")]：" || return 1
    read_config_field CHECK_INTERVAL "⏱️ 检测间隔秒 [${CHECK_INTERVAL}]：" 30 3600 || return 1
    read_config_field CN_PROBES "🇨🇳 中国节点数量 [${CN_PROBES}]：" 1 50 || return 1
    read_config_field FAIL_THRESHOLD "🚨 失败阈值 [${FAIL_THRESHOLD}]：" 1 30 || return 1
    read_config_field GP_PACKETS "📦 ping 包数量 [${GP_PACKETS}]：" 1 20 || return 1
    read_config_field GP_RESULT_WAIT_SECONDS "⌛ Globalping 等待秒数 [${GP_RESULT_WAIT_SECONDS}]：" 10 180 || return 1
    read_config_field COOLDOWN_SECONDS "🧊 冷却秒数 [${COOLDOWN_SECONDS}]：" 0 86400 || return 1
    read_config_field CURL_TIMEOUT "🌐 curl 超时秒数 [${CURL_TIMEOUT}]：" 5 180 || return 1
    read_config_field POST_CHANGE_WAIT_SECONDS "⏳ 换 IP 后等待秒数 [${POST_CHANGE_WAIT_SECONDS}]：" 0 1800 || return 1
    read_config_field DNS_RESOLVER "🧭 DNS 服务器 [$(display_value "$DNS_RESOLVER")]：" || return 1
    read_config_field MIN_API_INTERVAL "🛡️ 更换 API 最小间隔秒 [${MIN_API_INTERVAL}]：" 0 3600 || return 1
    warn_if_showip_action "$CHANGE_IP_API_URL"
    if [[ "$SHOW_IP_API_URL" == "$CHANGE_IP_API_URL" ]]; then warn "获取与更换 IP API 完全相同，请核对用途。"; fi
    apply_config_changes || return 1
    ok "配置已更新，已重新读取核对，systemd 更新已完成。"
}


# -----------------------------
# 全量配置迁移：只迁移 CONFIG_KEYS，不执行导入文件，不携带运行状态/日志。
# -----------------------------
validate_import_file() {
    local file="$1" line key bytes
    local -A present=()
    [[ -f "$file" && -r "$file" && ! -L "$file" ]] || { err "导入文件不存在、不可读或是符号链接：${file}"; return 1; }
    bytes="$(wc -c < "$file")" || return 1
    bytes="${bytes//[[:space:]]/}"
    number_in_range "$bytes" 1 1048576 || { err "导入文件须为 1 字节至 1 MiB 的完整配置。"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || { err "导入文件有非 KEY=value 内容，未执行也未保存。"; return 1; }
        key="${BASH_REMATCH[1]}"
        case " ${CONFIG_KEYS[*]} " in
            *" ${key} "*) ;;
            *) err "导入文件包含未知字段 ${key}；请使用本脚本导出的全量配置。"; return 1 ;;
        esac
        [[ ! ${present[$key]+yes} ]] || { err "导入文件字段重复：${key}"; return 1; }
        present["$key"]=1
    done < "$file" || return 1
    for key in "${CONFIG_KEYS[@]}"; do
        [[ ${present[$key]+yes} ]] || { err "导入文件不完整，缺少 ${key}；不会用默认值替代。"; return 1; }
    done
    # CONF_FILE 仅在本函数动态作用域内改变，解码后的字段交给调用者。
    local CONF_FILE="$file"
    load_config && validate_runtime_config
}

export_config() (
    require_root
    local dest="${1:-}" tmp expected actual dir
    if [[ -z "$dest" ]]; then
        dest="${HOME:-/root}/${APP_NAME}-config-$(date +%Y%m%d-%H%M%S)-${BASHPID}.env"
    fi
    load_config && validate_runtime_config || return 1
    [[ ! -e "$dest" && ! -L "$dest" ]] || { err "导出目标已存在，不覆盖：${dest}"; return 1; }
    dir="$(dirname -- "$dest")"
    [[ -d "$dir" ]] || { err "导出目录不存在：${dir}"; return 1; }
    tmp="$(mktemp "${dir}/.hinet-export.XXXXXX")" || { err "创建导出临时文件失败。"; return 1; }
    trap 'rm -f -- "$tmp"' EXIT
    expected="$(config_snapshot)" || return 1
    if ! {
        printf '# %s 全量配置导出\n# 格式：兼容 config.env；完整明文，不包含运行状态和日志。\n' "$APP_VERSION"
        config_snapshot
    } > "$tmp" || ! chmod 600 "$tmp"; then err "写入导出文件失败。"; return 1; fi
    actual="$(validate_import_file "$tmp" && config_snapshot)" || { err "导出回读校验失败。"; return 1; }
    [[ "$actual" == "$expected" ]] || { err "导出逐字段校验不一致。"; return 1; }
    # 同目录硬链接原子发布：目标已存在时失败，不会覆盖另一份备份。
    ln -- "$tmp" "$dest" || { err "发布导出文件失败，未覆盖原文件。"; return 1; }
    rm -f -- "$tmp" || { err "导出已生成，但临时文件清理失败：${tmp}"; return 1; }
    trap - EXIT
    ok "全量配置已导出并核对：${dest}"
    info "全部 ${#CONFIG_KEYS[@]} 个字段包含完整 API/认证参数；权限 600。"
    info "请把此文件保存到其它机器；它是明文备份，不要提交到公开 GitHub。"
)

export_config_menu() {
    local dest
    IFS= read -r -p "📤 导出文件路径（回车使用家目录下自动命名文件）：" dest || return 0
    export_config "$dest"
}

import_config() (
    require_root
    local source_file="${1:-}" flag mode=ask yes=0 choice stage_dir stage snapshot actual
    local unit load_state status_backup="" tmp
    [[ $# -gt 0 ]] && shift
    for flag in "$@"; do
        case "$flag" in
            --start) mode=start ;;
            --no-start) mode=stopped ;;
            --yes) yes=1 ;;
            *) err "未知导入参数：${flag}"; return 64 ;;
        esac
    done
    if [[ -z "$source_file" ]]; then
        IFS= read -r -p "📥 请输入完整配置备份文件路径：" source_file || return 0
    fi
    [[ -n "$source_file" ]] || { warn "未选择文件。"; return 0; }
    # 先固定导入文件快照，防止预览/确认期间原文件发生变化。
    [[ -f "$source_file" && -r "$source_file" && ! -L "$source_file" ]] || { err "配置备份文件不可读：${source_file}"; return 1; }
    stage_dir="$(mktemp -d)" || { err "创建导入临时目录失败。"; return 1; }
    trap 'rm -rf -- "$stage_dir"' EXIT
    chmod 700 "$stage_dir" || return 1
    stage="${stage_dir}/config.env"
    cp -- "$source_file" "$stage" && chmod 600 "$stage" || { err "读取导入文件失败。"; return 1; }
    validate_import_file "$stage" || return 1
    snapshot="$(config_snapshot)" || return 1
    cecho "📥 待导入的完整配置：${source_file}"
    (CONF_FILE="$stage"; show_config) || return 1
    warn "导入将备份并替换配置、安装本版程序和定时器；失败计数重置，日志/历史保留。"
    if (( yes == 0 )); then
        if [[ "$mode" == ask ]]; then
            IFS= read -r -p "输入 1 导入并启动自动检测；2 仅导入暂不启动；回车取消：" choice || return 0
            choice="$(normalize_choice "$choice")"
            case "$choice" in 1) mode=start ;; 2) mode=stopped ;; *) warn "已取消。"; return 0 ;; esac
        else
            [[ "$mode" == start ]] && warn "本次将启动自动检测，满足失败阈值后会真实换 IP。"
            IFS= read -r -p "输入 1 确认导入，其它取消：" choice || return 0
            [[ "$(normalize_choice "$choice")" == 1 ]] || { warn "已取消。"; return 0; }
        fi
    elif [[ "$mode" == ask ]]; then
        mode=stopped
    fi
    has_cmd systemctl || { err "缺少 systemctl，未导入。"; return 1; }
    install_packages || { err "依赖安装失败，未导入。"; return 1; }
    [[ -f "${BASH_SOURCE[0]}" && -s "${BASH_SOURCE[0]}" ]] && bash -n "${BASH_SOURCE[0]}" || { err "本版完整源码校验失败，未导入。"; return 1; }
    mkdirs || { err "准备目录失败，未导入。"; return 1; }
    exec 8>"$CHANGE_LOCK_FILE" || { err "无法打开迁移锁，未导入。"; return 1; }
    flock -w 10 8 || { err "检测/换 IP 正在进行，未覆盖配置；请稍后重试。"; return 1; }
    # 持锁后不会终止正在发出商家请求的 worker。导入失败也不自动恢复任务。
    for unit in "${APP_NAME}.timer" "${APP_NAME}.service"; do
        load_state="$(systemctl show -p LoadState --value "$unit")" || { err "读取 ${unit} 状态失败，未导入。"; return 1; }
        case "$load_state" in
            not-found) continue ;;
            loaded|masked|error|bad-setting) ;;
            *) err "无法确认 ${unit} 的 LoadState=${load_state}，未导入。"; return 1 ;;
        esac
        if [[ "$unit" == *.timer ]]; then
            systemctl disable --now "$unit" || { err "停止并禁用旧 timer 失败，未导入。"; return 1; }
        else
            systemctl stop "$unit" || { err "停止旧 service 失败，未导入；timer 可能已停止。"; return 1; }
        fi
    done
    load_status || { err "旧状态文件无效，未替换配置；自动任务保持停止。"; return 1; }
    status_backup="${STATUS_FILE}.bak.$(date +%Y%m%d%H%M%S).${BASHPID}"
    cp -p -- "$STATUS_FILE" "$status_backup" && chmod 600 "$status_backup" || { err "备份旧状态失败，未替换配置。"; return 1; }
    save_config || { err "配置导入保存/回读失败；自动任务保持停止。"; return 1; }
    actual="$(config_snapshot)" || return 1
    [[ "$actual" == "$snapshot" ]] || { err "导入结果不一致；自动任务保持停止。"; return 1; }
    # 不迁移远端状态。保留本机实际调用/成功时间，防止同机恢复绕过最小间隔。
    FAILURE_COUNT=0; LAST_CHECK_EPOCH=0; LAST_TARGET=""; LAST_RESOLVED_IP=""
    LAST_RESULT="config_imported"; LAST_MEASUREMENT_ID=""
    save_status || { err "配置已导入，但重置失败计数失败；自动任务保持停止。"; return 1; }
    install_self || { err "配置已导入，但安装/systemd 应用失败；自动任务保持停止。"; return 1; }
    exec 8>&-
    ok "全量配置已导入、回读核对并安装：${CONF_FILE}"
    if [[ "$mode" == start ]]; then
        systemctl enable --now "${APP_NAME}.timer" || { err "导入完成，但启用 timer 失败。"; return 1; }
        systemctl start "${APP_NAME}.service" || { err "导入完成且 timer 已启用，但首次检测失败；请查看中文日志。"; return 1; }
        ok "自动检测已启动并设置开机自启。"
    else
        info "自动检测未启动；确认配置后执行：${APP_NAME} start"
    fi
)

view_logs() {
    require_root
    mkdirs || return 1
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

show_config() {
    require_root
    load_config || return 1
    cecho "🔐 当前完整配置"
    cecho "----------------------------------------"
    cecho "获取 IP API：$(display_value "$SHOW_IP_API_URL")"
    cecho "更换 IP API：$(display_value "$CHANGE_IP_API_URL")"
    cecho "检测目标：$(display_value "${CHECK_TARGET:-}")"
    cecho "检测间隔：${CHECK_INTERVAL}s"
    cecho "中国节点：${CN_PROBES}"
    cecho "失败阈值：${FAIL_THRESHOLD}"
    cecho "ping 包数：${GP_PACKETS}"
    cecho "等待结果：${GP_RESULT_WAIT_SECONDS}s"
    cecho "冷却：${COOLDOWN_SECONDS}s"
    cecho "curl 超时：${CURL_TIMEOUT}s"
    cecho "换 IP 后等待：${POST_CHANGE_WAIT_SECONDS}s"
    cecho "DNS 服务器：$(display_value "${DNS_RESOLVER:-}")"
    cecho "API 最小间隔：${MIN_API_INTERVAL}s"
}

history_recent() {
    require_root
    mkdirs || return 1
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
    local yn
    IFS= read -r -p "确认卸载？输入 1 继续：" yn || return 0
    yn="$(normalize_choice "$yn")"
    [[ "$yn" == 1 ]] || { warn "已取消。"; return 0; }
    service_stop || { err "停止失败，未继续删除文件。"; return 1; }
    rm -f -- "$SERVICE_FILE" "$TIMER_FILE" "$RUNNER_PATH" "$INSTALL_PATH" || { err "删除程序/unit 失败。"; return 1; }
    systemctl daemon-reload || { err "文件已删除，但 daemon-reload 失败。"; return 1; }
    ok "已卸载程序和 systemd 单元。配置保留：${CONF_FILE}"
}

doctor() {
    require_root
    cecho "🩺 ${APP_VERSION} 自检（不发送网络请求、不启动定时任务）"
    cecho "----------------------------------------"
    local ok_all=1 c
    for c in bash curl jq flock systemctl timeout; do
        if has_cmd "$c"; then ok "依赖存在：$c"; else err "缺少依赖：$c"; ok_all=0; fi
    done
    if ! has_cmd dig && ! has_cmd getent; then err "缺少 dig/getent 域名解析工具。"; ok_all=0; fi
    if bash -n "${BASH_SOURCE[0]}"; then ok "主脚本语法通过。"; else err "主脚本语法失败。"; ok_all=0; fi
    if load_config && validate_runtime_config; then ok "配置语法、字段和数值范围通过。"; else err "配置检查失败。"; ok_all=0; fi
    if load_status; then ok "状态字段检查通过。"; else ok_all=0; fi
    if [[ -w "$LOG_FILE" && ! -L "$LOG_FILE" ]]; then ok "中文日志可写。"; else warn "中文日志不可写或尚未安装。"; ok_all=0; fi
    if [[ -x "$RUNNER_PATH" ]] && bash -n "$RUNNER_PATH"; then ok "worker 存在且语法通过。"; else err "worker 缺失或校验失败。"; ok_all=0; fi
    [[ -f "$SERVICE_FILE" && -f "$TIMER_FILE" ]] || { err "service/timer 文件不完整。"; ok_all=0; }
    if [[ -f "$TIMER_FILE" ]] && ! grep -Fxq "OnUnitActiveSec=${CHECK_INTERVAL}s" "$TIMER_FILE"; then err "timer 间隔与最终配置不一致。"; ok_all=0; fi
    if (( ok_all == 1 )); then ok "自检完成。"; return 0; fi
    err "自检发现问题。"; return 1
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
  ${APP_NAME} check-once              兼容命令：执行一次检测并自动处理失败计数
  ${APP_NAME} check                   手动 Globalping 检测一次
  ${APP_NAME} change                  手动调用更换 IP API
  ${APP_NAME} show-ip                 显示当前 IP / DDNS 解析
  ${APP_NAME} logs                    中文文件日志
  ${APP_NAME} journal                 systemd 原始日志
  ${APP_NAME} edit-config             修改配置
  ${APP_NAME} doctor                  离线自检（不调用 API）
  ${APP_NAME} test-show-api           只测试获取当前 IP
  ${APP_NAME} test-api                真实调用更换 IP（需数字确认）
  ${APP_NAME} version                 显示版本
  ${APP_NAME} export-config [文件]    导出全部 13 个字段（完整明文）
  ${APP_NAME} import-config 文件      导入全量配置，数字选择是否启动
  ${APP_NAME} import-config 文件 --yes --no-start  无交互导入，不启动
  ${APP_NAME} import-config 文件 --yes --start     无交互导入并启动

本地文件、bash <(curl -fsSL URL)、curl -fsSL URL | bash 均支持。
管道模式的交互输入来自 /dev/tty；无终端时使用带参数的非交互命令。
备份仅含配置，不包含旧失败计数、冷却状态、日志或 HiNet 端 DDNS 程序。

换 IP 返回码：0=确认变化，1=请求/业务失败，2=未确认，3=未发送，4=持久化失败。
check-once/start/restart 会进入自动处理链路；不是无副作用测试命令。
EOF_HELP
    return $?
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
        cecho " 12. 🔐 查看完整配置"
        cecho " 13. 🛠️  修改已有配置"
        cecho " 14. 🔎 手动测试获取当前 IP API（安全）"
        cecho " 15. 🧪 手动测试更换 IP API（可能换 IP，不写正式记录）"
        cecho " 16. 🗑️  卸载脚本"
        cecho " 17. 🩺 脚本自检"
        cecho " 18. 🧾 查看 systemd journal 原始日志"
        cecho " 19. 📤 导出全量配置（含完整 API）"
        cecho " 20. 📥 导入全量配置 / 恢复部署"
        cecho "  0. 🚪 退出"
        cecho "========================================"
        local choice
        IFS= read -r -p "请输入选项 [0-20]：" choice || return 0
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
            12|config) show_config ;;
            13|edit|edit-config) edit_config ;;
            14|test-show|test-show-api) test_show_ip_api ;;
            15|test-api|test-change-api) test_vendor_api ;;
            16|uninstall) uninstall_script ;;
            17|doctor) doctor ;;
            18|journal) view_journal_logs ;;
            19|export|export-config) export_config_menu ;;
            20|import|import-config) import_config ;;
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
        export|export-config|19) export_config "${2:-}" ;;
        import|import-config|20) shift; import_config "$@" ;;
        edit|edit-config|13) edit_config ;;
        config|show-config|12) show_config ;;
        test-show-api|test-show|14) test_show_ip_api ;;
        test-api|test-change-api|15) test_vendor_api ;;
        history3|9) history_recent 3 ;;
        history30|10) history_recent 30 ;;
        doctor|17) doctor ;;
        uninstall|16) uninstall_script ;;
        help|-h|--help) print_help ;;
        version|--version) printf '%s\n' "$APP_VERSION" ;;
        menu) menu ;;
        *) err "未知命令：请使用 help 查看用法。"; return 64 ;;
    esac
}

if [[ "${1:-}" != __hinet_definitions__ ]]; then main "$@"; fi

}

# 完整解析主函数后再进入本启动器：/dev/fd、stdin、bash -c 不再回读已消费的流。
# declare -f 只写出本文件的两个静态函数，不复制运行中的 API/配置变量。
hinet_launch() (
    local __hinet_src="${BASH_SOURCE[0]:-}" __hinet_dir="" __hinet_stage="" __hinet_tty __hinet_rc
    if [[ "$-" != *s* && -z "${BASH_EXECUTION_STRING:-}" && -n "$__hinet_src" && -f "$__hinet_src" && -s "$__hinet_src" ]]; then
        hinet_program "$@"
        exit $?
    fi
    __hinet_dir="$(mktemp -d)" || { printf '❌ 无法创建完整源码暂存目录。\n' >&2; exit 1; }
    trap 'rm -rf -- "$__hinet_dir"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    chmod 700 "$__hinet_dir" || exit 1
    __hinet_stage="${__hinet_dir}/hinet-gfw-changeip.sh"
    if ! {
        printf '#!/usr/bin/env bash\n# hinet-gfw-changeip-v2.7；由完整静态函数生成的本地安装源。\n'
        declare -f hinet_program hinet_launch
        printf '%s\n' 'if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]]; then hinet_program __hinet_definitions__; else hinet_launch "$@"; fi'
    } > "$__hinet_stage" || ! chmod 700 "$__hinet_stage" || ! bash -n "$__hinet_stage"; then
        printf '❌ 完整源码暂存/语法校验失败，没有安装或修改配置。\n' >&2; exit 1
    fi
    # curl | bash 的 stdin 是源码流；不能把它当菜单输入，也不能读入剩余脚本文本。
    # bash <(curl) / bash -c 则保留原有 stdin，包括自动化传入的回答。
    if [[ "$-" == *s* && -z "${BASH_EXECUTION_STRING:-}" ]]; then
        if { exec {__hinet_tty}</dev/tty; } 2>/dev/null; then
            bash "$__hinet_stage" "$@" <&"$__hinet_tty"; __hinet_rc=$?
            exec {__hinet_tty}<&-
        else
            case "${1:-menu}" in
                menu|init|edit|edit-config|13|test-api|test-change-api|15|uninstall|16)
                    printf '❌ 当前管道没有交互终端。请在 SSH 终端运行，或改用先下载文件再 bash 执行的一行命令。\n' >&2; exit 1 ;;
            esac
            bash "$__hinet_stage" "$@" </dev/null; __hinet_rc=$?
        fi
    else
        bash "$__hinet_stage" "$@"; __hinet_rc=$?
    fi
    exit "$__hinet_rc"
)

if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]]; then
    hinet_program __hinet_definitions__
else
    hinet_launch "$@"
fi
