#!/usr/bin/env bash
set -euo pipefail
umask 077

# cfdns v2.9 installer
# Cloudflare DNS multi-group A-record incremental sync tool

APP_NAME="cf-dns-sync"
APP_VERSION="2.9"
INSTALL_DIR="/opt/cfdns"
INSTALL_COPY="${INSTALL_DIR}/cfdns-installer.sh"
BASE_DIR="/etc/${APP_NAME}"
VAR_DIR="/var/lib/${APP_NAME}"
BACKUP_DIR="${VAR_DIR}/backups"
LOG_DIR="/var/log/${APP_NAME}"
LEGACY_LOG_FILE="/var/log/${APP_NAME}.log"
LEGACY_HISTORY_FILE="/var/log/${APP_NAME}-history.tsv"

BIN_SYNC="/usr/local/bin/${APP_NAME}.sh"
BIN_CTL="/usr/local/bin/cfdns"

SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
TIMER_FILE="/etc/systemd/system/${APP_NAME}.timer"
LOGROTATE_FILE="/etc/logrotate.d/${APP_NAME}"

SETTINGS_FILE="${BASE_DIR}/settings.conf"
GROUPS_FILE="${BASE_DIR}/groups.tsv"
FAILOVER_FILE="${BASE_DIR}/failover.tsv"
LOG_FILE="${LOG_DIR}/${APP_NAME}.log"
HISTORY_FILE="${LOG_DIR}/${APP_NAME}-history.tsv"
FAILOVER_HISTORY_FILE="${LOG_DIR}/${APP_NAME}-failover.tsv"
STATE_FILE="${VAR_DIR}/state.tsv"
RUNSTATE_FILE="${VAR_DIR}/runstate.tsv"
FAILOVER_STATE_FILE="${VAR_DIR}/failover-state.tsv"
GLOBALPING_USAGE_FILE="${VAR_DIR}/globalping-usage.tsv"

INSTALL_GUARD_ACTIVE=0
INSTALL_PREVIOUS_TIMER_ACTIVE=0
INSTALL_PREVIOUS_TIMER_ENABLED=0

restore_runtime_after_failed_install() {
  local rc=$?
  trap - EXIT
  if [[ "${INSTALL_GUARD_ACTIVE}" -eq 1 ]]; then
    echo "安装/升级未完成，正在恢复操作前的定时器状态……" >&2
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ "${INSTALL_PREVIOUS_TIMER_ENABLED}" -eq 1 ]]; then
      systemctl enable "${APP_NAME}.timer" >/dev/null 2>&1 || true
    else
      systemctl disable "${APP_NAME}.timer" >/dev/null 2>&1 || true
    fi
    if [[ "${INSTALL_PREVIOUS_TIMER_ACTIVE}" -eq 1 ]]; then
      systemctl start "${APP_NAME}.timer" >/dev/null 2>&1 || true
    else
      systemctl stop "${APP_NAME}.timer" >/dev/null 2>&1 || true
    fi
  fi
  exit "${rc}"
}

need_install_pkgs() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v jq >/dev/null 2>&1 || missing+=("jq")

  if ! command -v dig >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      missing+=("dnsutils")
    else
      missing+=("bind-utils")
    fi
  fi

  command -v logrotate >/dev/null 2>&1 || missing+=("logrotate")
  command -v zcat >/dev/null 2>&1 || missing+=("gzip")
  command -v gzip >/dev/null 2>&1 || missing+=("gzip")
  command -v tac >/dev/null 2>&1 || missing+=("coreutils")
  command -v flock >/dev/null 2>&1 || missing+=("util-linux")
  command -v find >/dev/null 2>&1 || missing+=("findutils")
  command -v xargs >/dev/null 2>&1 || missing+=("findutils")
  command -v tar >/dev/null 2>&1 || missing+=("tar")

  printf '%s\n' "${missing[@]}" | sed '/^$/d' | sort -u
}

run_package_command() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 300 "$@"
  else
    "$@"
  fi
}

install_missing_deps() {
  if [[ "${CFDNS_SKIP_DEPS:-0}" == "1" ]]; then
    echo "已跳过依赖安装检查（CFDNS_SKIP_DEPS=1）"
    return
  fi
  local pkgs
  pkgs="$(need_install_pkgs || true)"

  if [[ -z "${pkgs}" ]]; then
    echo "依赖已齐全，无需安装"
    return
  fi

  echo "检测到缺少依赖，准备安装："
  echo "${pkgs}"

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    run_package_command apt-get -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=2 update
    # shellcheck disable=SC2086
    run_package_command apt-get -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=2 install -y ${pkgs}
  elif command -v dnf >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    run_package_command dnf --setopt=timeout=20 --setopt=retries=2 install -y ${pkgs}
  elif command -v yum >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    run_package_command yum --setopt=timeout=20 --setopt=retries=2 install -y ${pkgs}
  else
    echo "不支持的包管理器，请手动安装：${pkgs}"
    exit 1
  fi
}

write_settings() {
  if [[ ! -f "${SETTINGS_FILE}" ]]; then
    cat > "${SETTINGS_FILE}" <<'CFG'
LOG_LEVEL="INFO"
FORCE_RECONCILE_SEC="3600"
DNS_SERVER=""
DNS_QUERY_TIMEOUT_SEC="2"
GLOBALPING_API_TOKEN=""
GLOBALPING_MAX_TESTS_PER_HOUR="240"
GLOBALPING_MEASUREMENT_TIMEOUT_SEC="12"
GLOBALPING_POLL_MAX_SEC="25"
CFG
  else
    sed -i 's/\r$//' "${SETTINGS_FILE}" 2>/dev/null || true
    grep -q '^LOG_LEVEL=' "${SETTINGS_FILE}" || echo 'LOG_LEVEL="INFO"' >> "${SETTINGS_FILE}"
    grep -q '^FORCE_RECONCILE_SEC=' "${SETTINGS_FILE}" || echo 'FORCE_RECONCILE_SEC="3600"' >> "${SETTINGS_FILE}"
    grep -q '^DNS_SERVER=' "${SETTINGS_FILE}" || echo 'DNS_SERVER=""' >> "${SETTINGS_FILE}"
    grep -q '^DNS_QUERY_TIMEOUT_SEC=' "${SETTINGS_FILE}" || echo 'DNS_QUERY_TIMEOUT_SEC="2"' >> "${SETTINGS_FILE}"
    grep -q '^GLOBALPING_API_TOKEN=' "${SETTINGS_FILE}" || echo 'GLOBALPING_API_TOKEN=""' >> "${SETTINGS_FILE}"
    grep -q '^GLOBALPING_MAX_TESTS_PER_HOUR=' "${SETTINGS_FILE}" || echo 'GLOBALPING_MAX_TESTS_PER_HOUR="240"' >> "${SETTINGS_FILE}"
    grep -q '^GLOBALPING_MEASUREMENT_TIMEOUT_SEC=' "${SETTINGS_FILE}" || echo 'GLOBALPING_MEASUREMENT_TIMEOUT_SEC="12"' >> "${SETTINGS_FILE}"
    grep -q '^GLOBALPING_POLL_MAX_SEC=' "${SETTINGS_FILE}" || echo 'GLOBALPING_POLL_MAX_SEC="25"' >> "${SETTINGS_FILE}"
  fi
  chmod 600 "${SETTINGS_FILE}"
}

validate_settings_file() {
  if ! bash -n "${SETTINGS_FILE}" >/dev/null 2>&1; then
    echo "settings.conf 语法错误，已停止安装/升级；请修正后重试：${SETTINGS_FILE}" >&2
    return 1
  fi
}

write_groups() {
  if [[ ! -f "${GROUPS_FILE}" ]]; then
    cat > "${GROUPS_FILE}" <<'TSV'
# group_name<TAB>enabled<TAB>interval_sec<TAB>api_token<TAB>zone_id<TAB>target_fqdn<TAB>ttl<TAB>proxied<TAB>mode<TAB>source_domains_csv
# 示例：
# group-a	true	60	please_fill_api_token	please_fill_zone_id	tiktokeu.example.com	60	false	ALL_IPS	src1.example.com,src2.example.com
TSV
    chmod 600 "${GROUPS_FILE}"
  fi
}

write_failover() {
  if [[ ! -f "${FAILOVER_FILE}" ]]; then
    cat > "${FAILOVER_FILE}" <<'TSV'
# group_name<TAB>enabled<TAB>backup_sources_csv<TAB>primary_check_target<TAB>backup_check_target<TAB>check_type<TAB>tcp_port<TAB>location<TAB>stable_interval_sec<TAB>fast_interval_sec<TAB>primary_fail_threshold<TAB>backup_success_threshold<TAB>primary_recovery_threshold
# 现有 groups.tsv 源域名自动视为 PRIMARY；未配置本文件的组保持 v2.5 行为。
# 示例：
# group-a	true	backup1.example.com,backup2.example.com	primary1.example.com	backup1.example.com	PING_ICMP	0	China	300	60	3	2	2
TSV
  else
    sed -i 's/\r$//' "${FAILOVER_FILE}" 2>/dev/null || true
  fi
  chmod 600 "${FAILOVER_FILE}"
}

legacy_log_family_exists() {
  local base="$1" f
  [[ -f "${base}" ]] && return 0
  shopt -s nullglob
  for f in "${base}".* "${base}"-*; do
    if [[ -f "${f}" ]]; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

move_legacy_log_family() {
  local old_base="$1" new_base="$2" suffix src dst tmp
  shopt -s nullglob
  local files=("${old_base}" "${old_base}".* "${old_base}"-*)
  shopt -u nullglob

  for src in "${files[@]}"; do
    [[ -f "${src}" ]] || continue
    if [[ -L "${src}" ]]; then
      echo "警告：跳过符号链接形式的旧日志：${src}"
      continue
    fi

    suffix="${src#"${old_base}"}"
    dst="${new_base}${suffix}"
    if [[ ! -e "${dst}" ]]; then
      if mv -- "${src}" "${dst}" 2>/dev/null; then
        chmod 600 "${dst}" 2>/dev/null || true
        echo "已迁移日志：${src} -> ${dst}"
      else
        echo "警告：日志迁移失败，旧文件保持不变：${src}"
      fi
      continue
    fi

    # 目标文件已存在时合并去重，避免产生无法被标准轮转规则管理的临时命名文件。
    tmp="$(mktemp "${LOG_DIR}/.log-migrate.XXXXXX")" || { echo "警告：无法创建迁移临时文件"; continue; }
    if [[ "${src}" == *.gz && "${dst}" == *.gz ]]; then
      if { gzip -cd -- "${dst}"; gzip -cd -- "${src}"; } 2>/dev/null | LC_ALL=C sort -u | gzip -c > "${tmp}"; then
        chmod 600 "${tmp}" && mv -f "${tmp}" "${dst}" && rm -f "${src}"
        echo "已合并旧日志：${src} -> ${dst}"
      else
        rm -f "${tmp}"
        echo "警告：压缩日志合并失败，旧文件保持不变：${src}"
      fi
    elif [[ "${src}" != *.gz && "${dst}" != *.gz ]]; then
      if { cat -- "${dst}"; cat -- "${src}"; } | LC_ALL=C sort -u > "${tmp}"; then
        chmod 600 "${tmp}" && mv -f "${tmp}" "${dst}" && rm -f "${src}"
        echo "已合并旧日志：${src} -> ${dst}"
      else
        rm -f "${tmp}"
        echo "警告：日志合并失败，旧文件保持不变：${src}"
      fi
    else
      rm -f "${tmp}"
      echo "警告：旧日志压缩格式与目标不一致，保持旧文件不变：${src}"
    fi
  done
}

migrate_legacy_logs() {
  mkdir -p "${LOG_DIR}"
  chmod 700 "${LOG_DIR}" 2>/dev/null || true
  move_legacy_log_family "${LEGACY_LOG_FILE}" "${LOG_FILE}"
  move_legacy_log_family "${LEGACY_HISTORY_FILE}" "${HISTORY_FILE}"
}

write_sync_script() {
  local tmp
  tmp="$(mktemp /usr/local/bin/.cf-dns-sync.sh.XXXXXX)"
  cat > "${tmp}" <<'SYNC'
#!/usr/bin/env bash
set -uo pipefail
umask 077

APP_VERSION="2.9"
BASE_DIR="/etc/cf-dns-sync"
VAR_DIR="/var/lib/cf-dns-sync"
SETTINGS_FILE="${BASE_DIR}/settings.conf"
GROUPS_FILE="${BASE_DIR}/groups.tsv"
FAILOVER_FILE="${BASE_DIR}/failover.tsv"
LOG_DIR="/var/log/cf-dns-sync"
LOG_FILE="${LOG_DIR}/cf-dns-sync.log"
HISTORY_FILE="${LOG_DIR}/cf-dns-sync-history.tsv"
FAILOVER_HISTORY_FILE="${LOG_DIR}/cf-dns-sync-failover.tsv"
STATE_FILE="${VAR_DIR}/state.tsv"
RUNSTATE_FILE="${VAR_DIR}/runstate.tsv"
RECONCILE_FILE="${VAR_DIR}/reconcile.tsv"
FAILOVER_STATE_FILE="${VAR_DIR}/failover-state.tsv"
GLOBALPING_USAGE_FILE="${VAR_DIR}/globalping-usage.tsv"
LOCK_FILE="/run/cf-dns-sync.lock"

[[ "$(id -u)" -eq 0 ]] || { echo "请使用 root 运行" >&2; exit 1; }
mkdir -p "${LOG_DIR}" "${VAR_DIR}" || { echo "无法创建日志或状态目录" >&2; exit 1; }
chmod 700 "${LOG_DIR}" 2>/dev/null || true
touch "${LOG_FILE}" "${HISTORY_FILE}" "${FAILOVER_HISTORY_FILE}" "${RUNSTATE_FILE}" "${RECONCILE_FILE}" "${STATE_FILE}" "${FAILOVER_STATE_FILE}" "${GLOBALPING_USAGE_FILE}" || {
  echo "无法创建日志或状态文件" >&2
  exit 1
}
chmod 600 "${LOG_FILE}" "${HISTORY_FILE}" "${FAILOVER_HISTORY_FILE}" "${RUNSTATE_FILE}" "${RECONCILE_FILE}" "${STATE_FILE}" "${FAILOVER_STATE_FILE}" "${GLOBALPING_USAGE_FILE}" 2>/dev/null || true

[[ -f "${SETTINGS_FILE}" ]] || { echo "配置文件不存在: ${SETTINGS_FILE}"; exit 1; }
[[ -f "${GROUPS_FILE}" ]] || { echo "组配置不存在: ${GROUPS_FILE}"; exit 1; }
[[ -f "${FAILOVER_FILE}" ]] || touch "${FAILOVER_FILE}" || { echo "无法创建故障转移配置: ${FAILOVER_FILE}" >&2; exit 1; }

# shellcheck disable=SC1090
if ! source "${SETTINGS_FILE}"; then
  echo "全局配置语法错误，已停止运行: ${SETTINGS_FILE}" >&2
  exit 1
fi
LOG_LEVEL="${LOG_LEVEL:-INFO}"
FORCE_RECONCILE_SEC="${FORCE_RECONCILE_SEC:-3600}"
DNS_SERVER="${DNS_SERVER:-}"
DNS_QUERY_TIMEOUT_SEC="${DNS_QUERY_TIMEOUT_SEC:-2}"
GLOBALPING_API_TOKEN="${GLOBALPING_API_TOKEN:-}"
GLOBALPING_MAX_TESTS_PER_HOUR="${GLOBALPING_MAX_TESTS_PER_HOUR:-240}"
GLOBALPING_MEASUREMENT_TIMEOUT_SEC="${GLOBALPING_MEASUREMENT_TIMEOUT_SEC:-12}"
GLOBALPING_POLL_MAX_SEC="${GLOBALPING_POLL_MAX_SEC:-25}"
[[ "${FORCE_RECONCILE_SEC}" =~ ^[0-9]+$ ]] && (( FORCE_RECONCILE_SEC >= 60 )) || FORCE_RECONCILE_SEC=3600
[[ "${DNS_QUERY_TIMEOUT_SEC}" =~ ^[0-9]+$ ]] && (( DNS_QUERY_TIMEOUT_SEC >= 1 )) || DNS_QUERY_TIMEOUT_SEC=2
[[ "${GLOBALPING_MAX_TESTS_PER_HOUR}" =~ ^[0-9]+$ ]] && (( GLOBALPING_MAX_TESTS_PER_HOUR >= 1 )) || GLOBALPING_MAX_TESTS_PER_HOUR=240
[[ "${GLOBALPING_MEASUREMENT_TIMEOUT_SEC}" =~ ^[0-9]+$ ]] && (( GLOBALPING_MEASUREMENT_TIMEOUT_SEC >= 5 && GLOBALPING_MEASUREMENT_TIMEOUT_SEC <= 30 )) || GLOBALPING_MEASUREMENT_TIMEOUT_SEC=12
[[ "${GLOBALPING_POLL_MAX_SEC}" =~ ^[0-9]+$ ]] && (( GLOBALPING_POLL_MAX_SEC >= GLOBALPING_MEASUREMENT_TIMEOUT_SEC && GLOBALPING_POLL_MAX_SEC <= 60 )) || GLOBALPING_POLL_MAX_SEC=25

COMMAND="${1:-AUTO}"
ARG1="${2:-}"
ARG2="${3:-}"
RUN_MODE="AUTO"
TARGET_GROUP="ALL"
FORCE_FLAG="0"
SPECIAL_MODE=""
SPECIAL_ROLE=""
case "${COMMAND}" in
  AUTO)
    RUN_MODE="AUTO"
    TARGET_GROUP="ALL"
    ;;
  ALL)
    RUN_MODE="ALL"
    TARGET_GROUP="ALL"
    FORCE_FLAG="1"
    ;;
  GPTEST)
    RUN_MODE="GPTEST"
    SPECIAL_MODE="GPTEST"
    TARGET_GROUP="${ARG1}"
    SPECIAL_ROLE="${ARG2^^}"
    ;;
  FOSWITCH)
    RUN_MODE="FOSWITCH"
    SPECIAL_MODE="FOSWITCH"
    TARGET_GROUP="${ARG1}"
    SPECIAL_ROLE="${ARG2^^}"
    ;;
  FORESET)
    RUN_MODE="FORESET"
    SPECIAL_MODE="FORESET"
    TARGET_GROUP="${ARG1}"
    ;;
  *)
    RUN_MODE="GROUP"
    TARGET_GROUP="${COMMAND}"
    [[ "${ARG1}" == "FORCE" || "${ARG1}" == "1" ]] && FORCE_FLAG="1"
    ;;
esac

FAILOVER_SWITCH_PENDING=0
FAILOVER_SWITCH_GROUP=""
FAILOVER_SWITCH_OLD_ROLE=""
FAILOVER_SWITCH_NEW_ROLE=""
FAILOVER_SWITCH_REASON=""
FAILOVER_SWITCH_MEASUREMENT_ID=""
FAILOVER_SWITCH_ACTION="SWITCH"
FAILOVER_PRE_SWITCH_STATE=""

# 自动任务不等待锁；人工同步/测试/切换最多等待30秒，避免“实际未执行却提示成功”。
if ! exec 9>"${LOCK_FILE}"; then
  printf '[%s] [ERROR] 无法打开同步锁文件: %s\n' "$(date '+%F %T')" "${LOCK_FILE}" >&2
  exit 1
fi
if [[ "${RUN_MODE}" == "AUTO" ]]; then
  flock -n 9 || exit 0
else
  flock -w 30 9 || {
    printf '[%s] [ERROR] 同步任务正由另一个进程执行，等待30秒后仍未取得锁\n' "$(date '+%F %T')" >&2
    exit 75
  }
fi

now_ts() { date +%s; }
timestamp() { date '+%F %T'; }

level_num() {
  case "${1:-INFO}" in
    NONE|OFF) echo -1 ;;
    ERROR) echo 0 ;;
    INFO) echo 1 ;;
    DEBUG) echo 2 ;;
    *) echo 1 ;;
  esac
}

log() {
  local level="${1:-INFO}"; shift || true
  local msg="$*" cur want
  cur="$(level_num "${LOG_LEVEL}")"
  want="$(level_num "${level}")"
  [[ "${cur}" -lt 0 ]] && return 0
  if [[ "${want}" -le "${cur}" ]]; then
    touch "${LOG_FILE}" 2>/dev/null || true
    chmod 600 "${LOG_FILE}" 2>/dev/null || true
    printf '[%s] [%s] %s\n' "$(timestamp)" "${level}" "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    if command -v systemd-cat >/dev/null 2>&1; then
      printf '[%s] [%s] %s\n' "$(timestamp)" "${level}" "${msg}" | systemd-cat -t cf-dns-sync 2>/dev/null || true
    fi
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log ERROR "缺少依赖命令: $1"
    exit 1
  }
}

for cmd in curl jq dig awk sed grep sort comm mktemp flock paste cut tr date wc cmp sleep; do
  need_cmd "${cmd}"
done

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

valid_ipv4() {
  awk -F. '
    NF==4 {
      for (i=1; i<=4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
      exit 0
    }
    {exit 1}
  ' <<< "$1"
}

valid_domain() {
  local domain="${1:-}" tld
  domain="${domain%.}"
  [[ -n "${domain}" && "${#domain}" -le 253 ]] || return 1
  [[ "${domain}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  tld="${domain##*.}"
  [[ "${tld}" =~ [A-Za-z] ]]
}

valid_group_name() {
  local value="${1:-}"
  [[ -n "${value}" && "${#value}" -le 128 && "${value}" != *$'\t'* && "${value}" != *$'\r'* && "${value}" != *$'\n'* && "${value}" != *\\* ]]
}

valid_ttl() {
  local ttl="${1:-}"
  [[ "${ttl}" =~ ^[0-9]+$ ]] || return 1
  [[ "${ttl}" -eq 1 || ( "${ttl}" -ge 60 && "${ttl}" -le 86400 ) ]]
}

cf_api() {
  local method="$1" token="$2" endpoint="$3" data="${4:-}"
  local hdr body rc http_code retry_after raw
  if ! hdr="$(mktemp)"; then
    jq -nc '{success:false,result:null,errors:[{message:"无法创建响应头临时文件"}],_http_status:0,_retry_after:0}'
    return 0
  fi
  if ! body="$(mktemp)"; then
    rm -f "${hdr}"
    jq -nc '{success:false,result:null,errors:[{message:"无法创建响应体临时文件"}],_http_status:0,_retry_after:0}'
    return 0
  fi

  local -a args=(
    -sS --connect-timeout 10 --max-time 35
    --retry 2 --retry-delay 1
    -D "${hdr}" -o "${body}" -w '%{http_code}'
    -X "${method}" "https://api.cloudflare.com/client/v4${endpoint}"
    -H "Authorization: Bearer ${token}"
    -H "Content-Type: application/json"
  )
  [[ -n "${data}" ]] && args+=(--data "${data}")

  http_code="$(curl "${args[@]}" 2>/dev/null)"
  rc=$?
  raw="$(cat "${body}" 2>/dev/null || true)"
  retry_after="$(awk 'tolower($1)=="retry-after:" {gsub("\\r", "", $2); print $2; exit}' "${hdr}" 2>/dev/null || true)"
  rm -f "${hdr}" "${body}"

  if [[ "${rc}" -ne 0 ]]; then
    jq -nc --arg msg "curl 请求失败，退出码=${rc}" --argjson status 0 \
      '{success:false,result:null,errors:[{message:$msg}],_http_status:$status,_retry_after:0}'
    return 0
  fi

  if ! jq -e . >/dev/null 2>&1 <<< "${raw}"; then
    jq -nc --arg msg "Cloudflare 返回了非 JSON 响应" --arg body "${raw:0:500}" \
      --argjson status "${http_code:-0}" --arg retry "${retry_after:-0}" \
      '{success:false,result:null,errors:[{message:$msg,body:$body}],_http_status:$status,_retry_after:($retry|tonumber? // 0)}'
    return 0
  fi

  jq --argjson status "${http_code:-0}" --arg retry "${retry_after:-0}" \
    '. + {_http_status:$status,_retry_after:($retry|tonumber? // 0)}' <<< "${raw}" 2>/dev/null || printf '%s\n' "${raw}"
}


valid_health_target() {
  valid_ipv4 "${1:-}" || valid_domain "${1:-}"
}

split_tsv_line() {
  local rest="${1-}"
  TSV_FIELDS=()
  while [[ "${rest}" == *$'\t'* ]]; do
    TSV_FIELDS+=("${rest%%$'\t'*}")
    rest="${rest#*$'\t'}"
  done
  TSV_FIELDS+=("${rest}")
}

gp_api() {
  local method="$1" endpoint="$2" data="${3:-}"
  local hdr body rc http_code raw retry_after
  if ! hdr="$(mktemp)"; then
    jq -nc '{error:{type:"local_io_error",message:"无法创建响应头临时文件"},_http_status:0,_retry_after:0}'
    return 0
  fi
  if ! body="$(mktemp)"; then
    rm -f "${hdr}"
    jq -nc '{error:{type:"local_io_error",message:"无法创建响应体临时文件"},_http_status:0,_retry_after:0}'
    return 0
  fi
  local -a args=(
    -sS --connect-timeout 10 --max-time 35
    --retry 1 --retry-delay 1
    -D "${hdr}" -o "${body}" -w '%{http_code}'
    -X "${method}" "https://api.globalping.io/v1${endpoint}"
    -H "User-Agent: cfdns/${APP_VERSION}"
    -H "Accept: application/json"
  )
  [[ -n "${GLOBALPING_API_TOKEN}" ]] && args+=(-H "Authorization: Bearer ${GLOBALPING_API_TOKEN}")
  if [[ -n "${data}" ]]; then
    args+=(-H "Content-Type: application/json" --data "${data}")
  fi

  http_code="$(curl "${args[@]}" 2>/dev/null)"
  rc=$?
  raw="$(cat "${body}" 2>/dev/null || true)"
  retry_after="$(awk 'tolower($1)=="retry-after:" {gsub("\\r", "", $2); print $2; exit}' "${hdr}" 2>/dev/null || true)"
  rm -f "${hdr}" "${body}"

  if [[ "${rc}" -ne 0 ]]; then
    jq -nc --arg msg "curl 请求失败，退出码=${rc}" --argjson status 0 \
      '{error:{type:"transport_error",message:$msg},_http_status:$status,_retry_after:0}'
    return 0
  fi
  if ! jq -e . >/dev/null 2>&1 <<< "${raw}"; then
    jq -nc --arg msg "Globalping 返回了非 JSON 响应" --arg body "${raw:0:500}" \
      --argjson status "${http_code:-0}" --arg retry "${retry_after:-0}" \
      '{error:{type:"non_json_response",message:$msg,body:$body},_http_status:$status,_retry_after:($retry|tonumber? // 0)}'
    return 0
  fi
  jq --argjson status "${http_code:-0}" --arg retry "${retry_after:-0}" \
    '. + {_http_status:$status,_retry_after:($retry|tonumber? // 0)}' <<< "${raw}" 2>/dev/null || printf '%s\n' "${raw}"
}

globalping_prune_usage() {
  local now cutoff tmp
  now="$(now_ts)"; cutoff=$((now-3600))
  tmp="$(mktemp "${VAR_DIR}/.globalping-usage.XXXXXX")" || return 1
  if ! awk -v c="${cutoff}" '
    NF == 0 {next}
    NF != 1 || $1 !~ /^[0-9]+$/ {bad=1; next}
    $1 >= c {print $1}
    END {exit bad ? 1 : 0}
  ' "${GLOBALPING_USAGE_FILE}" 2>/dev/null > "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  mv "${tmp}" "${GLOBALPING_USAGE_FILE}" || { rm -f "${tmp}"; return 1; }
  chmod 600 "${GLOBALPING_USAGE_FILE}" 2>/dev/null || return 1
}

globalping_usage_count() {
  globalping_prune_usage || return 1
  wc -l < "${GLOBALPING_USAGE_FILE}" | awk '{print $1}'
}

globalping_budget_available() {
  local count
  count="$(globalping_usage_count)" || return 2
  (( count < GLOBALPING_MAX_TESTS_PER_HOUR ))
}

globalping_record_usage() {
  local tests="${1:-1}" ts i
  [[ "${tests}" =~ ^[0-9]+$ ]] && (( tests >= 1 )) || tests=1
  ts="$(now_ts)"
  for ((i=0; i<tests; i++)); do
    printf '%s\n' "${ts}"
  done >> "${GLOBALPING_USAGE_FILE}" || return 1
  chmod 600 "${GLOBALPING_USAGE_FILE}" 2>/dev/null || return 1
}

globalping_health_check() {
  local group="$1" role="$2" target="$3" check_type="$4" port="$5" location="$6"
  local payload create_resp measurement_id probes_count start now resp status result_status failure_source
  local rcv loss probe_country probe_city resolved raw budget_rc usage_tests

  GP_CHECK_CLASS="UNKNOWN"
  GP_CHECK_DETAIL=""
  GP_MEASUREMENT_ID=""
  GP_PROBE=""
  GP_RESOLVED_ADDRESS=""

  globalping_budget_available
  budget_rc=$?
  case "${budget_rc}" in
    0) ;;
    1)
      GP_CHECK_DETAIL="本机一小时安全预算已用尽（${GLOBALPING_MAX_TESTS_PER_HOUR} tests/h）"
      log INFO "组 ${group}: Globalping ${role} 检测跳过：${GP_CHECK_DETAIL}"
      return 0
      ;;
    *)
      GP_CHECK_DETAIL="本机Globalping用量文件无法读取或更新；为防止超额，本次不创建测量"
      log ERROR "组 ${group}: Globalping ${role} 检测跳过：${GP_CHECK_DETAIL}"
      return 0
      ;;
  esac

  if [[ "${check_type}" == "PING_TCP" ]]; then
    payload="$(jq -nc --arg target "${target}" --arg location "${location}" \
      --argjson timeout "${GLOBALPING_MEASUREMENT_TIMEOUT_SEC}" --argjson port "${port}" \
      '{type:"ping",target:$target,locations:[{magic:$location,limit:1}],timeout:$timeout,measurementOptions:{protocol:"TCP",port:$port,packets:3,ipVersion:4}}')"
  else
    payload="$(jq -nc --arg target "${target}" --arg location "${location}" \
      --argjson timeout "${GLOBALPING_MEASUREMENT_TIMEOUT_SEC}" \
      '{type:"ping",target:$target,locations:[{magic:$location,limit:1}],timeout:$timeout,measurementOptions:{protocol:"ICMP",packets:3,ipVersion:4}}')"
  fi

  create_resp="$(gp_api POST /measurements "${payload}")"
  measurement_id="$(jq -r '.id // empty' <<< "${create_resp}" 2>/dev/null || true)"
  probes_count="$(jq -r '.probesCount // 0' <<< "${create_resp}" 2>/dev/null || echo 0)"
  # API 接受后按 probesCount 记录实际 tests；字段异常时至少记 1 次，避免低估 API 消耗。
  if [[ -n "${measurement_id}" ]]; then
    usage_tests=1
    [[ "${probes_count}" =~ ^[0-9]+$ ]] && (( probes_count >= 1 )) && usage_tests="${probes_count}"
    if ! globalping_record_usage "${usage_tests}"; then
      GP_CHECK_DETAIL="测量已创建（ID=${measurement_id}），但本机用量记录失败；为防止预算失控，本次结果按未知处理"
      log ERROR "组 ${group}: Globalping ${role} 检测未知：${GP_CHECK_DETAIL}"
      return 0
    fi
  fi
  if [[ -z "${measurement_id}" || ! "${probes_count}" =~ ^[0-9]+$ || "${probes_count}" -lt 1 ]]; then
    GP_CHECK_DETAIL="创建测量失败或没有可用探针，HTTP=$(jq -r '._http_status // 0' <<< "${create_resp}" 2>/dev/null || echo 0)，错误=$(jq -c '.error // .errors // {}' <<< "${create_resp}" 2>/dev/null || echo unknown)"
    log INFO "组 ${group}: Globalping ${role} 检测未知：${GP_CHECK_DETAIL}"
    return 0
  fi

  GP_MEASUREMENT_ID="${measurement_id}"
  start="$(now_ts)"
  resp=""
  while true; do
    resp="$(gp_api GET "/measurements/${measurement_id}")"
    if [[ "$(jq -r '._http_status // 0' <<< "${resp}" 2>/dev/null || echo 0)" != "200" ]]; then
      GP_CHECK_DETAIL="读取测量失败，HTTP=$(jq -r '._http_status // 0' <<< "${resp}" 2>/dev/null || echo 0)"
      log INFO "组 ${group}: Globalping ${role} 检测未知：${GP_CHECK_DETAIL}"
      return 0
    fi
    status="$(jq -r '.status // empty' <<< "${resp}" 2>/dev/null || true)"
    [[ "${status}" == "finished" ]] && break
    now="$(now_ts)"
    if (( now - start >= GLOBALPING_POLL_MAX_SEC )); then
      GP_CHECK_DETAIL="测量等待超过 ${GLOBALPING_POLL_MAX_SEC}s"
      log INFO "组 ${group}: Globalping ${role} 检测未知：${GP_CHECK_DETAIL}"
      return 0
    fi
    sleep 1
  done

  local result_count
  result_count="$(jq -r '.results | length // 0' <<< "${resp}" 2>/dev/null || echo 0)"
  [[ "${result_count}" =~ ^[0-9]+$ ]] || result_count=0
  if (( result_count < 1 )); then
    GP_CHECK_DETAIL="测量完成但没有探针结果"
    log INFO "组 ${group}: Globalping ${role} 检测未知：${GP_CHECK_DETAIL}"
    return 0
  fi

  result_status="$(jq -r '.results[0].result.status // empty' <<< "${resp}" 2>/dev/null || true)"
  failure_source="$(jq -r '.results[0].result.failureSource // empty' <<< "${resp}" 2>/dev/null || true)"
  rcv="$(jq -r '.results[0].result.stats.rcv // 0' <<< "${resp}" 2>/dev/null || echo 0)"
  loss="$(jq -r '.results[0].result.stats.loss // 100' <<< "${resp}" 2>/dev/null || echo 100)"
  probe_country="$(jq -r '.results[0].probe.country // empty' <<< "${resp}" 2>/dev/null || true)"
  probe_city="$(jq -r '.results[0].probe.city // empty' <<< "${resp}" 2>/dev/null || true)"
  resolved="$(jq -r '.results[0].result.resolvedAddress // empty' <<< "${resp}" 2>/dev/null || true)"
  raw="$(jq -r '.results[0].result.rawOutput // empty' <<< "${resp}" 2>/dev/null || true)"
  raw="$(tr '\r\n\t' '   ' <<< "${raw}" | sed 's/[[:space:]]\+/ /g' | cut -c1-240)"
  GP_PROBE="${probe_country}${probe_city:+/${probe_city}}"
  GP_RESOLVED_ADDRESS="${resolved}"

  case "${location,,}" in
    china|china+*|cn|cn+*)
      if [[ "${probe_country}" != "CN" ]]; then
        GP_CHECK_DETAIL="请求中国节点但实际探针国家=${probe_country:-unknown}"
        log INFO "组 ${group}: Globalping ${role} 检测未知：${GP_CHECK_DETAIL}"
        return 0
      fi
      ;;
  esac

  # Globalping 偶发返回负数或缺失统计时，将其视为平台结果未知，而不是目标故障，避免误切换。
  if ! [[ "${rcv}" =~ ^[0-9]+$ ]] || ! [[ "${loss}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    GP_CHECK_CLASS="UNKNOWN"
    GP_CHECK_DETAIL="探针统计无效，status=${result_status:-unknown}，rcv=${rcv:-empty}，loss=${loss:-empty}，${raw}"
  elif [[ "${result_status}" == "finished" && "${rcv}" -gt 0 ]]; then
    GP_CHECK_CLASS="SUCCESS"
    GP_CHECK_DETAIL="探针=${GP_PROBE:-unknown}，解析=${resolved:-unknown}，接收=${rcv}/3，丢包=${loss}%"
  elif [[ "${result_status}" == "failed" && "${failure_source}" == "internal" ]] || [[ "${result_status}" == "offline" ]]; then
    GP_CHECK_CLASS="UNKNOWN"
    GP_CHECK_DETAIL="探针/平台异常，status=${result_status:-unknown}，failureSource=${failure_source:-unknown}，${raw}"
  elif [[ "${result_status}" == "failed" || ( "${result_status}" == "finished" && "${rcv}" -eq 0 ) ]]; then
    GP_CHECK_CLASS="FAILURE"
    GP_CHECK_DETAIL="探针=${GP_PROBE:-unknown}，status=${result_status:-unknown}，failureSource=${failure_source:-target}，接收=${rcv}/3，${raw}"
  else
    GP_CHECK_CLASS="UNKNOWN"
    GP_CHECK_DETAIL="无法识别的结果状态=${result_status:-empty}，${raw}"
  fi
  return 0
}

get_failover_config_line() {
  local group="$1"
  awk -F '\t' -v g="${group}" '!/^#/ && $1==g{print; exit}' "${FAILOVER_FILE}" 2>/dev/null
}

load_failover_config() {
  local group="$1" line count
  count="$(awk -F '\t' -v g="${group}" '!/^#/ && $1==g{n++} END{print n+0}' "${FAILOVER_FILE}" 2>/dev/null)" || {
    log ERROR "组 ${group}: 无法读取 failover.tsv"
    return 1
  }
  [[ "${count}" -eq 1 ]] || {
    [[ "${count}" -gt 1 ]] && log ERROR "组 ${group}: failover.tsv 存在重复配置，已停止故障转移"
    return 1
  }
  line="$(get_failover_config_line "${group}")"
  [[ -n "${line}" ]] || return 1
  split_tsv_line "${line}"
  if (( ${#TSV_FIELDS[@]} != 13 )); then
    log ERROR "组 ${group}: failover.tsv 字段数量应为13，实际=${#TSV_FIELDS[@]}"
    return 1
  fi
  FO_GROUP="${TSV_FIELDS[0]}"; FO_ENABLED="${TSV_FIELDS[1]}"; FO_BACKUP_SOURCES="${TSV_FIELDS[2]}"
  FO_PRIMARY_TARGET="${TSV_FIELDS[3]}"; FO_BACKUP_TARGET="${TSV_FIELDS[4]}"; FO_CHECK_TYPE="${TSV_FIELDS[5]}"
  FO_PORT="${TSV_FIELDS[6]}"; FO_LOCATION="${TSV_FIELDS[7]}"; FO_STABLE_INTERVAL="${TSV_FIELDS[8]}"
  FO_FAST_INTERVAL="${TSV_FIELDS[9]}"; FO_PRIMARY_FAIL_THRESHOLD="${TSV_FIELDS[10]}"
  FO_BACKUP_SUCCESS_THRESHOLD="${TSV_FIELDS[11]}"; FO_PRIMARY_RECOVERY_THRESHOLD="${TSV_FIELDS[12]}"; FO_EXTRA=""
  return 0
}

csv_contains_value() {
  local csv="$1" value="$2"
  tr ',' '
' <<< "${csv}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk -v v="${value}" 'tolower($0)==tolower(v){found=1} END{exit !found}'
}

validate_failover_config() {
  local group="$1" primary_sources="$2" domain
  [[ "${FO_GROUP}" == "${group}" ]] || { log ERROR "组 ${group}: failover.tsv 组名字段不一致"; return 1; }
  [[ -z "${FO_EXTRA:-}" ]] || { log ERROR "组 ${group}: failover.tsv 字段数量超过13"; return 1; }
  [[ "${FO_ENABLED}" == "true" || "${FO_ENABLED}" == "false" ]] || { log ERROR "组 ${group}: 故障转移 enabled 必须是true/false"; return 1; }
  csv_to_sources_array "${FO_BACKUP_SOURCES}"
  (( ${#SOURCES_ARRAY[@]} >= 1 && ${#SOURCES_ARRAY[@]} <= 20 )) || { log ERROR "组 ${group}: BACKUP源域名数量必须为1~20"; return 1; }
  for domain in "${SOURCES_ARRAY[@]}"; do
    valid_domain "${domain}" || { log ERROR "组 ${group}: BACKUP源域名格式错误：${domain}"; return 1; }
    if csv_contains_value "${primary_sources}" "${domain}"; then log ERROR "组 ${group}: PRIMARY与BACKUP不能包含同一个源域名：${domain}"; return 1; fi
  done
  valid_health_target "${FO_PRIMARY_TARGET}" || { log ERROR "组 ${group}: PRIMARY健康检测目标格式错误"; return 1; }
  valid_health_target "${FO_BACKUP_TARGET}" || { log ERROR "组 ${group}: BACKUP健康检测目标格式错误"; return 1; }
  [[ "${FO_CHECK_TYPE}" == PING_ICMP || "${FO_CHECK_TYPE}" == PING_TCP ]] || { log ERROR "组 ${group}: 检测类型必须是PING_ICMP/PING_TCP"; return 1; }
  if [[ "${FO_CHECK_TYPE}" == PING_TCP ]]; then [[ "${FO_PORT}" =~ ^[0-9]+$ ]] && (( FO_PORT>=1 && FO_PORT<=65535 )) || { log ERROR "组 ${group}: TCP端口必须为1~65535"; return 1; }; else FO_PORT=0; fi
  [[ -n "${FO_LOCATION}" && "${FO_LOCATION}" != *$'\t'* && "${FO_LOCATION}" != *$'\n'* ]] || { log ERROR "组 ${group}: Globalping位置不能为空或包含TAB/换行"; return 1; }
  case "${FO_LOCATION,,}" in china|china+*|cn|cn+*) ;; *) log ERROR "组 ${group}: 本功能仅允许中国区Globalping位置（China/CN）"; return 1 ;; esac
  [[ "${FO_STABLE_INTERVAL}" =~ ^[0-9]+$ && "${FO_FAST_INTERVAL}" =~ ^[0-9]+$ ]] || { log ERROR "组 ${group}: Globalping检测周期必须为整数"; return 1; }
  (( FO_STABLE_INTERVAL>=60 && FO_FAST_INTERVAL>=60 && FO_STABLE_INTERVAL>=FO_FAST_INTERVAL )) || { log ERROR "组 ${group}: 稳定周期需>=快速周期且两者均>=60秒"; return 1; }
  [[ "${FO_PRIMARY_FAIL_THRESHOLD}" =~ ^[0-9]+$ && "${FO_BACKUP_SUCCESS_THRESHOLD}" =~ ^[0-9]+$ && "${FO_PRIMARY_RECOVERY_THRESHOLD}" =~ ^[0-9]+$ ]] || { log ERROR "组 ${group}: 故障转移阈值必须为整数"; return 1; }
  (( FO_PRIMARY_FAIL_THRESHOLD>=1 && FO_BACKUP_SUCCESS_THRESHOLD>=1 && FO_PRIMARY_RECOVERY_THRESHOLD>=1 )) || { log ERROR "组 ${group}: 故障转移阈值必须>=1"; return 1; }
  return 0
}

get_failover_state_line() {
  local group="$1"
  awk -F '\t' -v g="${group}" '$1==g{line=$0} END{print line}' "${FAILOVER_STATE_FILE}" 2>/dev/null
}

assign_failover_state_line() {
  split_tsv_line "$1"
  (( ${#TSV_FIELDS[@]} == 12 )) || return 1
  FS_GROUP="${TSV_FIELDS[0]}"; FS_ACTIVE_ROLE="${TSV_FIELDS[1]}"; FS_PHASE="${TSV_FIELDS[2]}"
  FS_PRIMARY_FAILS="${TSV_FIELDS[3]}"; FS_BACKUP_SUCCESSES="${TSV_FIELDS[4]}"; FS_PRIMARY_SUCCESSES="${TSV_FIELDS[5]}"
  FS_LAST_PRIMARY_CHECK="${TSV_FIELDS[6]}"; FS_LAST_BACKUP_CHECK="${TSV_FIELDS[7]}"; FS_LAST_RESULT="${TSV_FIELDS[8]}"
  FS_LAST_MEASUREMENT_ID="${TSV_FIELDS[9]}"; FS_LAST_SWITCH="${TSV_FIELDS[10]}"; FS_UPDATED="${TSV_FIELDS[11]}"
}

infer_initial_failover_role() {
  local group="$1" primary_csv="$2" backup_csv="$3" domain
  while IFS=$'\t' read -r _ domain _; do
    [[ -n "${domain}" ]] || continue
    if csv_contains_value "${backup_csv}" "${domain}" && ! csv_contains_value "${primary_csv}" "${domain}"; then
      printf 'BACKUP\n'
      return
    fi
  done < <(awk -F '\t' -v g="${group}" '$1==g{print}' "${STATE_FILE}" 2>/dev/null)
  printf 'PRIMARY\n'
}

load_failover_state() {
  local group="$1" primary_csv="$2" backup_csv="$3" line inferred count _v
  count="$(awk -F '\t' -v g="${group}" '$1==g{n++} END{print n+0}' "${FAILOVER_STATE_FILE}" 2>/dev/null)" || {
    log ERROR "组 ${group}: 无法读取 failover-state.tsv"
    return 1
  }
  if (( count > 1 )); then
    log ERROR "组 ${group}: failover-state.tsv 存在重复状态，已停止该组故障转移"
    return 1
  fi
  line="$(get_failover_state_line "${group}")"
  if [[ -n "${line}" ]]; then
    if ! assign_failover_state_line "${line}"; then
      split_tsv_line "${line}"
      log ERROR "组 ${group}: failover-state.tsv 字段数量应为12，实际=${#TSV_FIELDS[@]}"
      return 1
    fi
  else
    inferred="$(infer_initial_failover_role "${group}" "${primary_csv}" "${backup_csv}")"
    FS_GROUP="${group}"
    FS_ACTIVE_ROLE="${inferred}"
    if [[ "${inferred}" == "BACKUP" ]]; then FS_PHASE="BACKUP_FAST"; else FS_PHASE="PRIMARY_STABLE"; fi
    FS_PRIMARY_FAILS=0; FS_BACKUP_SUCCESSES=0; FS_PRIMARY_SUCCESSES=0
    FS_LAST_PRIMARY_CHECK=0; FS_LAST_BACKUP_CHECK=0; FS_LAST_RESULT="INIT"
    FS_LAST_MEASUREMENT_ID=""; FS_LAST_SWITCH=0; FS_UPDATED="$(now_ts)"
  fi

  [[ "${FS_GROUP}" == "${group}" ]] || { log ERROR "组 ${group}: 故障转移状态组名不一致"; return 1; }
  [[ "${FS_ACTIVE_ROLE}" == "PRIMARY" || "${FS_ACTIVE_ROLE}" == "BACKUP" ]] || {
    log ERROR "组 ${group}: 活动线路状态非法=${FS_ACTIVE_ROLE:-empty}"
    return 1
  }
  case "${FS_PHASE}" in
    PRIMARY_STABLE|PRIMARY_FAST|BACKUP_FAST|BACKUP_STABLE) ;;
    *) log ERROR "组 ${group}: 故障转移阶段非法=${FS_PHASE:-empty}"; return 1 ;;
  esac
  for _v in FS_PRIMARY_FAILS FS_BACKUP_SUCCESSES FS_PRIMARY_SUCCESSES FS_LAST_PRIMARY_CHECK FS_LAST_BACKUP_CHECK FS_LAST_SWITCH FS_UPDATED; do
    [[ "${!_v:-}" =~ ^[0-9]+$ ]] || { log ERROR "组 ${group}: 故障转移状态数值字段非法=${_v}"; return 1; }
  done
}

serialize_failover_state() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "${FS_GROUP}" "${FS_ACTIVE_ROLE}" "${FS_PHASE}" "${FS_PRIMARY_FAILS}" "${FS_BACKUP_SUCCESSES}" "${FS_PRIMARY_SUCCESSES}" \
    "${FS_LAST_PRIMARY_CHECK}" "${FS_LAST_BACKUP_CHECK}" "${FS_LAST_RESULT}" "${FS_LAST_MEASUREMENT_ID}" "${FS_LAST_SWITCH}" "${FS_UPDATED}"
}

replace_failover_state_line() {
  local group="$1" row="$2" tmp
  tmp="$(mktemp "${VAR_DIR}/.failover-state.XXXXXX")" || return 1
  if ! awk -F '\t' -v g="${group}" '$1!=g' "${FAILOVER_STATE_FILE}" 2>/dev/null > "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  printf '%s\n' "${row}" >> "${tmp}" || { rm -f "${tmp}"; return 1; }
  chmod 600 "${tmp}" || { rm -f "${tmp}"; return 1; }
  mv -f "${tmp}" "${FAILOVER_STATE_FILE}" || { rm -f "${tmp}"; return 1; }
}

save_failover_state() {
  local row
  FS_UPDATED="$(now_ts)"
  row="$(serialize_failover_state)"
  replace_failover_state_line "${FS_GROUP}" "${row}"
}

write_failover_history() {
  local group="$1" action="$2" from_role="$3" to_role="$4" reason="$5" measurement_id="$6"
  reason="$(tr '\r\n\t' '   ' <<< "${reason}" | sed 's/[[:space:]]\+/ /g' | cut -c1-300)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(timestamp)" "${group}" "${action}" "${from_role}" "${to_role}" "${reason}" "${measurement_id}" >> "${FAILOVER_HISTORY_FILE}"
}

remove_table_row() {
  local file="$1" group="$2" tmp
  tmp="$(mktemp "${VAR_DIR}/.remove-row.XXXXXX")" || return 1
  if ! awk -F '\t' -v g="${group}" '$1!=g' "${file}" 2>/dev/null > "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  chmod 600 "${tmp}" || { rm -f "${tmp}"; return 1; }
  mv -f "${tmp}" "${file}" || { rm -f "${tmp}"; return 1; }
}

mark_group_sync_due() {
  remove_table_row "${RUNSTATE_FILE}" "$1" || return 1
  remove_table_row "${RECONCILE_FILE}" "$1" || return 1
}

route_sources_ready_for_switch() {
  local group="$1" role="$2" sources_csv="$3" domain ips
  local failed=()
  csv_to_sources_array "${sources_csv}"
  (( ${#SOURCES_ARRAY[@]} >= 1 )) || { log ERROR "组 ${group}: ${role} 没有可用源域名，阻止线路切换"; return 1; }
  for domain in "${SOURCES_ARRAY[@]}"; do
    ips="$(resolve_domain_ipv4 "${domain}" | sort -u)"
    [[ -n "${ips}" ]] || failed+=("${domain}")
  done
  if (( ${#failed[@]} > 0 )); then
    log ERROR "组 ${group}: ${role} 源域名未全部解析到IPv4，阻止线路切换：$(IFS=,; echo "${failed[*]}")"
    return 1
  fi
  return 0
}

failover_switch_role() {
  local group="$1" new_role="$2" reason="$3" measurement_id="${4:-}" primary_sources="$5" backup_sources="$6"
  local action="${7:-SWITCH}" old_role route_sources before_state
  old_role="${FS_ACTIVE_ROLE}"
  [[ "${new_role}" == "PRIMARY" || "${new_role}" == "BACKUP" ]] || return 1
  [[ "${action}" == "SWITCH" || "${action}" == "RESET" ]] || return 1
  if [[ "${new_role}" == "BACKUP" ]]; then route_sources="${backup_sources}"; else route_sources="${primary_sources}"; fi
  if ! route_sources_ready_for_switch "${group}" "${new_role}" "${route_sources}"; then
    write_failover_history "${group}" BLOCKED "${old_role}" "${new_role}" "${reason}；目标线路本机源域名解析未就绪" "${measurement_id}"
    return 2
  fi

  # 保留本次健康检查后的旧线路状态。Cloudflare 未完整同步时必须恢复，不能把期望线路冒充为活动线路。
  FS_UPDATED="$(now_ts)"
  before_state="$(serialize_failover_state)"
  if ! mark_group_sync_due "${group}"; then
    log ERROR "组 ${group}: 无法标记线路切换同步任务"
    return 1
  fi

  FS_ACTIVE_ROLE="${new_role}"
  FS_PRIMARY_FAILS=0; FS_BACKUP_SUCCESSES=0; FS_PRIMARY_SUCCESSES=0
  FS_LAST_RESULT="SWITCH_${old_role}_TO_${new_role}"
  FS_LAST_MEASUREMENT_ID="${measurement_id}"
  FS_LAST_SWITCH="$(now_ts)"
  if [[ "${new_role}" == "BACKUP" ]]; then
    FS_PHASE="BACKUP_FAST"
    # 切换完成后按快速周期开始检测，避免5秒基础调度立即额外消耗一次Globalping测试。
    FS_LAST_BACKUP_CHECK="$(now_ts)"
  else
    FS_PHASE="PRIMARY_STABLE"
    FS_LAST_PRIMARY_CHECK="$(now_ts)"
  fi
  if ! save_failover_state; then
    assign_failover_state_line "${before_state}" || true
    log ERROR "组 ${group}: 无法暂存线路切换状态"
    return 1
  fi

  FAILOVER_SWITCH_PENDING=1
  FAILOVER_SWITCH_GROUP="${group}"
  FAILOVER_SWITCH_OLD_ROLE="${old_role}"
  FAILOVER_SWITCH_NEW_ROLE="${new_role}"
  FAILOVER_SWITCH_REASON="${reason}"
  FAILOVER_SWITCH_MEASUREMENT_ID="${measurement_id}"
  FAILOVER_SWITCH_ACTION="${action}"
  FAILOVER_PRE_SWITCH_STATE="${before_state}"
  log INFO "组 ${group}: 已准备 ${old_role} -> ${new_role}，正在核对 Cloudflare 后再确认线路切换"
}

finalize_failover_switch() {
  local group="$1" history_failed=0
  [[ "${FAILOVER_SWITCH_PENDING}" -eq 1 && "${FAILOVER_SWITCH_GROUP}" == "${group}" ]] || return 0
  if ! write_failover_history "${group}" "${FAILOVER_SWITCH_ACTION}" "${FAILOVER_SWITCH_OLD_ROLE}" "${FAILOVER_SWITCH_NEW_ROLE}" \
    "${FAILOVER_SWITCH_REASON}" "${FAILOVER_SWITCH_MEASUREMENT_ID}"; then
    history_failed=1
    log ERROR "组 ${group}: 线路已同步，但故障转移历史写入失败"
  fi
  log INFO "组 ${group}: Cloudflare 已核对，故障转移 ${FAILOVER_SWITCH_OLD_ROLE} -> ${FAILOVER_SWITCH_NEW_ROLE}，原因：${FAILOVER_SWITCH_REASON}"
  FAILOVER_SWITCH_PENDING=0
  (( history_failed == 0 ))
}

rollback_failover_switch() {
  local group="$1" rollback_failed=0
  [[ "${FAILOVER_SWITCH_PENDING}" -eq 1 && "${FAILOVER_SWITCH_GROUP}" == "${group}" ]] || return 0
  if ! replace_failover_state_line "${group}" "${FAILOVER_PRE_SWITCH_STATE}"; then
    rollback_failed=1
    log ERROR "组 ${group}: Cloudflare 同步失败，且切换前状态恢复失败；请立即运行自检"
  else
    assign_failover_state_line "${FAILOVER_PRE_SWITCH_STATE}" || rollback_failed=1
    mark_group_sync_due "${group}" || {
      rollback_failed=1
      log ERROR "组 ${group}: 切换已回滚，但无法安排旧线路立即复核"
    }
    write_failover_history "${group}" BLOCKED "${FAILOVER_SWITCH_OLD_ROLE}" "${FAILOVER_SWITCH_NEW_ROLE}" \
      "${FAILOVER_SWITCH_REASON}；Cloudflare同步失败，已恢复切换前状态" "${FAILOVER_SWITCH_MEASUREMENT_ID}" || rollback_failed=1
    log ERROR "组 ${group}: Cloudflare 未完整同步，已恢复线路 ${FAILOVER_SWITCH_OLD_ROLE}"
  fi
  FAILOVER_SWITCH_PENDING=0
  (( rollback_failed == 0 ))
}

failover_due() {
  local last="$1" interval="$2" now
  now="$(now_ts)"
  [[ "${last}" =~ ^[0-9]+$ ]] || last=0
  (( last <= now )) || return 0
  (( now - last >= interval ))
}

failover_record_check() {
  local role="$1"
  if [[ "${role}" == "PRIMARY" ]]; then FS_LAST_PRIMARY_CHECK="$(now_ts)"; else FS_LAST_BACKUP_CHECK="$(now_ts)"; fi
  FS_LAST_RESULT="${role}_${GP_CHECK_CLASS}"
  FS_LAST_MEASUREMENT_ID="${GP_MEASUREMENT_ID}"
  write_failover_history "${FS_GROUP}" CHECK "${role}" "${role}" "${GP_CHECK_CLASS}: ${GP_CHECK_DETAIL}" "${GP_MEASUREMENT_ID}"
}

switch_primary_to_backup_after_failures() {
  local group="$1" primary_sources="$2" backup_sources="$3" switch_rc
  if failover_switch_role "${group}" BACKUP "PRIMARY连续失败${FS_PRIMARY_FAILS}次" "${GP_MEASUREMENT_ID}" "${primary_sources}" "${backup_sources}"; then
    return 0
  else
    switch_rc=$?
  fi
  # 被阻止或暂存失败时仍保存本次检查时间，避免5秒基础调度反复消耗 Globalping 额度。
  FS_PRIMARY_FAILS="${FO_PRIMARY_FAIL_THRESHOLD}"
  save_failover_state || return 1
  return "${switch_rc}"
}

failover_tick() {
  local group="$1" group_enabled="$2" primary_sources="$3" state_repaired=0
  [[ "${group_enabled}" == true ]] || return 0
  load_failover_config "${group}" || return 0
  validate_failover_config "${group}" "${primary_sources}" || return 1
  [[ "${FO_ENABLED}" == true ]] || return 0
  load_failover_state "${group}" "${primary_sources}" "${FO_BACKUP_SOURCES}" || return 1

  if [[ "${FS_ACTIVE_ROLE}" == PRIMARY && "${FS_PHASE}" == BACKUP_* ]]; then FS_PHASE=PRIMARY_STABLE; state_repaired=1; fi
  if [[ "${FS_ACTIVE_ROLE}" == BACKUP && "${FS_PHASE}" == PRIMARY_* ]]; then FS_PHASE=BACKUP_FAST; state_repaired=1; fi
  (( state_repaired == 0 )) || save_failover_state || return 1

  case "${FS_PHASE}" in
    PRIMARY_STABLE)
      failover_due "${FS_LAST_PRIMARY_CHECK}" "${FO_STABLE_INTERVAL}" || return 0
      globalping_health_check "${group}" PRIMARY "${FO_PRIMARY_TARGET}" "${FO_CHECK_TYPE}" "${FO_PORT}" "${FO_LOCATION}"
      failover_record_check PRIMARY
      case "${GP_CHECK_CLASS}" in
        SUCCESS) FS_PRIMARY_FAILS=0; log DEBUG "组 ${group}: PRIMARY中国节点检测成功（稳定期）" ;;
        FAILURE)
          FS_PRIMARY_FAILS=1
          if (( FS_PRIMARY_FAILS >= FO_PRIMARY_FAIL_THRESHOLD )); then
            switch_primary_to_backup_after_failures "${group}" "${primary_sources}" "${FO_BACKUP_SOURCES}"
            return $?
          fi
          FS_PHASE=PRIMARY_FAST
          log INFO "组 ${group}: PRIMARY第一次失败，进入每${FO_FAST_INTERVAL}秒快速检测"
          ;;
        UNKNOWN) log INFO "组 ${group}: PRIMARY检测结果未知，不累计失败：${GP_CHECK_DETAIL}" ;;
      esac
      save_failover_state
      ;;
    PRIMARY_FAST)
      failover_due "${FS_LAST_PRIMARY_CHECK}" "${FO_FAST_INTERVAL}" || return 0
      globalping_health_check "${group}" PRIMARY "${FO_PRIMARY_TARGET}" "${FO_CHECK_TYPE}" "${FO_PORT}" "${FO_LOCATION}"
      failover_record_check PRIMARY
      case "${GP_CHECK_CLASS}" in
        SUCCESS) FS_PRIMARY_FAILS=0; FS_PHASE=PRIMARY_STABLE; log INFO "组 ${group}: PRIMARY快速检测恢复成功，返回稳定检测" ;;
        FAILURE)
          FS_PRIMARY_FAILS=$((FS_PRIMARY_FAILS+1)); log INFO "组 ${group}: PRIMARY连续失败 ${FS_PRIMARY_FAILS}/${FO_PRIMARY_FAIL_THRESHOLD}"
          if (( FS_PRIMARY_FAILS >= FO_PRIMARY_FAIL_THRESHOLD )); then
            switch_primary_to_backup_after_failures "${group}" "${primary_sources}" "${FO_BACKUP_SOURCES}"
            return $?
          fi
          ;;
        UNKNOWN) log INFO "组 ${group}: PRIMARY快速检测结果未知，不累计失败：${GP_CHECK_DETAIL}" ;;
      esac
      save_failover_state
      ;;
    BACKUP_FAST)
      failover_due "${FS_LAST_BACKUP_CHECK}" "${FO_FAST_INTERVAL}" || return 0
      globalping_health_check "${group}" BACKUP "${FO_BACKUP_TARGET}" "${FO_CHECK_TYPE}" "${FO_PORT}" "${FO_LOCATION}"
      failover_record_check BACKUP
      case "${GP_CHECK_CLASS}" in
        SUCCESS)
          FS_BACKUP_SUCCESSES=$((FS_BACKUP_SUCCESSES+1)); log INFO "组 ${group}: BACKUP连续成功 ${FS_BACKUP_SUCCESSES}/${FO_BACKUP_SUCCESS_THRESHOLD}"
          if (( FS_BACKUP_SUCCESSES >= FO_BACKUP_SUCCESS_THRESHOLD )); then
            FS_PHASE=BACKUP_STABLE; FS_PRIMARY_SUCCESSES=0; FS_LAST_PRIMARY_CHECK="$(now_ts)"; FS_LAST_BACKUP_CHECK="$(now_ts)"
            log INFO "组 ${group}: BACKUP已稳定，PRIMARY与BACKUP均改为每${FO_STABLE_INTERVAL}秒检测"
          fi
          ;;
        FAILURE) FS_BACKUP_SUCCESSES=0; log ERROR "组 ${group}: 当前活动BACKUP检测失败，保持BACKUP并继续快速检测" ;;
        UNKNOWN) log INFO "组 ${group}: BACKUP检测结果未知，不累计成功/失败：${GP_CHECK_DETAIL}" ;;
      esac
      save_failover_state
      ;;
    BACKUP_STABLE)
      if failover_due "${FS_LAST_PRIMARY_CHECK}" "${FO_STABLE_INTERVAL}"; then
        globalping_health_check "${group}" PRIMARY "${FO_PRIMARY_TARGET}" "${FO_CHECK_TYPE}" "${FO_PORT}" "${FO_LOCATION}"
        failover_record_check PRIMARY
        case "${GP_CHECK_CLASS}" in
          SUCCESS)
            FS_PRIMARY_SUCCESSES=$((FS_PRIMARY_SUCCESSES+1)); log INFO "组 ${group}: PRIMARY恢复成功 ${FS_PRIMARY_SUCCESSES}/${FO_PRIMARY_RECOVERY_THRESHOLD}"
            if (( FS_PRIMARY_SUCCESSES >= FO_PRIMARY_RECOVERY_THRESHOLD )); then
              if failover_switch_role "${group}" PRIMARY "PRIMARY连续成功${FS_PRIMARY_SUCCESSES}次" "${GP_MEASUREMENT_ID}" "${primary_sources}" "${FO_BACKUP_SOURCES}"; then
                return 0
              else
                local switch_rc=$?
                # PRIMARY本机源域名未就绪时保留BACKUP，并按稳定周期后再重试恢复检测。
                FS_PRIMARY_SUCCESSES="${FO_PRIMARY_RECOVERY_THRESHOLD}"
                save_failover_state || return 1
                return "${switch_rc}"
              fi
            fi
            ;;
          FAILURE) FS_PRIMARY_SUCCESSES=0; log DEBUG "组 ${group}: PRIMARY尚未恢复" ;;
          UNKNOWN) log INFO "组 ${group}: PRIMARY恢复检测结果未知，不改变连续成功计数" ;;
        esac
      fi
      if failover_due "${FS_LAST_BACKUP_CHECK}" "${FO_STABLE_INTERVAL}"; then
        globalping_health_check "${group}" BACKUP "${FO_BACKUP_TARGET}" "${FO_CHECK_TYPE}" "${FO_PORT}" "${FO_LOCATION}"
        failover_record_check BACKUP
        case "${GP_CHECK_CLASS}" in
          SUCCESS) log DEBUG "组 ${group}: BACKUP稳定检测成功" ;;
          FAILURE) FS_PHASE=BACKUP_FAST; FS_BACKUP_SUCCESSES=0; log ERROR "组 ${group}: 当前活动BACKUP在稳定期失败，重新进入快速检测" ;;
          UNKNOWN) log INFO "组 ${group}: BACKUP稳定检测结果未知，不切换状态" ;;
        esac
      fi
      save_failover_state
      ;;
    *)
      log ERROR "组 ${group}: 未知故障转移阶段=${FS_PHASE}"
      return 1
      ;;
  esac
  return 0
}

get_effective_group_sources() {
  local group="$1" primary_sources="$2"
  EFFECTIVE_ROUTE="PRIMARY"
  EFFECTIVE_SOURCES_CSV="${primary_sources}"
  load_failover_config "${group}" || return 0
  [[ "${FO_ENABLED}" == "true" ]] || return 0
  validate_failover_config "${group}" "${primary_sources}" || return 1
  load_failover_state "${group}" "${primary_sources}" "${FO_BACKUP_SOURCES}" || return 1
  if [[ "${FS_ACTIVE_ROLE}" == "BACKUP" ]]; then
    EFFECTIVE_ROUTE="BACKUP"
    EFFECTIVE_SOURCES_CSV="${FO_BACKUP_SOURCES}"
  fi
  return 0
}

find_group_record() {
  local wanted="$1"
  awk -F '\t' -v g="${wanted}" '!/^#/ && $1==g{print; exit}' "${GROUPS_FILE}"
}

parse_group_record_for_failover() {
  split_tsv_line "$1"
  (( ${#TSV_FIELDS[@]} == 10 )) || return 1
  MG_ENABLED="${TSV_FIELDS[1]}"
  MG_PRIMARY_SOURCES="${TSV_FIELDS[9]}"
}

manual_globalping_test() {
  local group="$1" role="$2" row target
  row="$(find_group_record "${group}")"
  [[ -n "${row}" ]] || { log ERROR "未找到组：${group}"; return 1; }
  parse_group_record_for_failover "${row}" || { log ERROR "组 ${group}: groups.tsv 字段数量不是10"; return 1; }
  load_failover_config "${group}" || { log ERROR "组 ${group} 尚未配置故障转移"; return 1; }
  validate_failover_config "${group}" "${MG_PRIMARY_SOURCES}" || return 1
  case "${role}" in
    PRIMARY) target="${FO_PRIMARY_TARGET}" ;;
    BACKUP) target="${FO_BACKUP_TARGET}" ;;
    *) log ERROR "测试角色必须是 PRIMARY 或 BACKUP"; return 1 ;;
  esac
  globalping_health_check "${group}" "${role}" "${target}" "${FO_CHECK_TYPE}" "${FO_PORT}" "${FO_LOCATION}"
  printf 'Globalping结果: %s\n组: %s\n角色: %s\n目标: %s\n探针: %s\n解析IP: %s\n测量ID: %s\n详情: %s\n' \
    "${GP_CHECK_CLASS}" "${group}" "${role}" "${target}" "${GP_PROBE:-unknown}" "${GP_RESOLVED_ADDRESS:-unknown}" "${GP_MEASUREMENT_ID:-none}" "${GP_CHECK_DETAIL}"
  case "${GP_CHECK_CLASS}" in SUCCESS) return 0 ;; FAILURE) return 1 ;; *) return 2 ;; esac
}

manual_failover_switch() {
  local group="$1" role="$2" row
  row="$(find_group_record "${group}")"
  [[ -n "${row}" ]] || { log ERROR "未找到组：${group}"; return 1; }
  parse_group_record_for_failover "${row}" || { log ERROR "组 ${group}: groups.tsv 字段数量不是10"; return 1; }
  [[ "${MG_ENABLED}" == "true" ]] || { log ERROR "组 ${group} 已禁用"; return 1; }
  load_failover_config "${group}" || { log ERROR "组 ${group} 尚未配置故障转移"; return 1; }
  [[ "${FO_ENABLED}" == "true" ]] || { log ERROR "组 ${group} 故障转移已禁用"; return 1; }
  validate_failover_config "${group}" "${MG_PRIMARY_SOURCES}" || return 1
  load_failover_state "${group}" "${MG_PRIMARY_SOURCES}" "${FO_BACKUP_SOURCES}" || return 1
  [[ "${role}" == "PRIMARY" || "${role}" == "BACKUP" ]] || { log ERROR "切换角色必须是 PRIMARY/BACKUP"; return 1; }
  if [[ "${FS_ACTIVE_ROLE}" == "${role}" ]]; then
    log INFO "组 ${group}: 当前已经是 ${role}"
  else
    failover_switch_role "${group}" "${role}" "人工切换" "manual" "${MG_PRIMARY_SOURCES}" "${FO_BACKUP_SOURCES}" || return $?
  fi
  return 0
}

manual_failover_reset() {
  local group="$1" row
  row="$(find_group_record "${group}")"
  [[ -n "${row}" ]] || { log ERROR "未找到组：${group}"; return 1; }
  parse_group_record_for_failover "${row}" || { log ERROR "组 ${group}: groups.tsv 字段数量不是10"; return 1; }
  load_failover_config "${group}" || { log ERROR "组 ${group} 尚未配置故障转移"; return 1; }
  validate_failover_config "${group}" "${MG_PRIMARY_SOURCES}" || return 1
  load_failover_state "${group}" "${MG_PRIMARY_SOURCES}" "${FO_BACKUP_SOURCES}" || return 1
  local old="${FS_ACTIVE_ROLE}"
  if [[ "${old}" == "BACKUP" ]]; then
    failover_switch_role "${group}" PRIMARY "人工重置状态" manual "${MG_PRIMARY_SOURCES}" "${FO_BACKUP_SOURCES}" RESET
    return $?
  fi
  FS_ACTIVE_ROLE="PRIMARY"; FS_PHASE="PRIMARY_STABLE"
  FS_PRIMARY_FAILS=0; FS_BACKUP_SUCCESSES=0; FS_PRIMARY_SUCCESSES=0
  FS_LAST_PRIMARY_CHECK=0; FS_LAST_BACKUP_CHECK=0; FS_LAST_RESULT="RESET"
  FS_LAST_MEASUREMENT_ID=""; FS_LAST_SWITCH="$(now_ts)"
  save_failover_state || return 1
  mark_group_sync_due "${group}" || return 1
  write_failover_history "${group}" RESET "${old}" PRIMARY "人工重置状态" manual || return 1
  return 0
}

normalize_sources_csv() {
  local csv="$1"
  awk -v RS=',' '
    {
      gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", $0)
      if ($0 != "" && !seen[$0]++) items[++n]=$0
    }
    END {
      for (i=1; i<=n; i++) printf "%s%s", items[i], (i<n ? "," : "")
    }
  ' <<< "${csv}"
}

csv_to_sources_array() {
  local normalized
  normalized="$(normalize_sources_csv "$1")"
  SOURCES_ARRAY=()
  [[ -z "${normalized}" ]] && return 0
  IFS=',' read -r -a SOURCES_ARRAY <<< "${normalized}"
}

resolve_domain_ipv4() {
  local domain="$1"
  local -a args=(+short "+time=${DNS_QUERY_TIMEOUT_SEC}" +tries=1 A "${domain}")
  if [[ -n "${DNS_SERVER}" ]]; then
    args=("@${DNS_SERVER}" +short "+time=${DNS_QUERY_TIMEOUT_SEC}" +tries=1 A "${domain}")
  fi
  local ip
  while IFS= read -r ip; do
    ip="${ip//$'\r'/}"
    valid_ipv4 "${ip}" && printf '%s\n' "${ip}"
  done < <(dig "${args[@]}" 2>/dev/null || true)
}

build_group_map() {
  local mode="$1" map_file="$2" failed_file="$3"
  shift 3
  local domain ip picked ips
  : > "${map_file}"
  : > "${failed_file}"

  for domain in "$@"; do
    [[ -n "${domain}" ]] || continue
    ips="$(resolve_domain_ipv4 "${domain}" | sort -u)"
    if [[ -z "${ips}" ]]; then
      printf '%s\n' "${domain}" >> "${failed_file}"
      continue
    fi

    if [[ "${mode}" == "SINGLE_IP" ]]; then
      picked="$(sed -n '1p' <<< "${ips}")"
      [[ -n "${picked}" ]] && printf '%s\t%s\n' "${domain}" "${picked}" >> "${map_file}"
    else
      while IFS= read -r ip; do
        [[ -n "${ip}" ]] && printf '%s\t%s\n' "${domain}" "${ip}" >> "${map_file}"
      done <<< "${ips}"
    fi
  done

  sort -u -o "${map_file}" "${map_file}" || return 1
  sort -u -o "${failed_file}" "${failed_file}" || return 1
}

get_table_value() {
  local file="$1" group="$2"
  awk -F '\t' -v g="${group}" '$1==g{v=$2} END{print v}' "${file}" 2>/dev/null
}

set_table_value() {
  local file="$1" group="$2" value="$3" tmp
  tmp="$(mktemp "${VAR_DIR}/.table.XXXXXX")" || return 1
  if ! awk -F '\t' -v g="${group}" '$1!=g' "${file}" 2>/dev/null > "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  printf '%s\t%s\n' "${group}" "${value}" >> "${tmp}" || { rm -f "${tmp}"; return 1; }
  chmod 600 "${tmp}" || { rm -f "${tmp}"; return 1; }
  mv -f "${tmp}" "${file}" || { rm -f "${tmp}"; return 1; }
}

get_group_last_run() { get_table_value "${RUNSTATE_FILE}" "$1"; }
set_group_last_run() { set_table_value "${RUNSTATE_FILE}" "$1" "$2"; }
get_group_last_reconcile() { get_table_value "${RECONCILE_FILE}" "$1"; }
set_group_last_reconcile() { set_table_value "${RECONCILE_FILE}" "$1" "$2"; }

should_run_group() {
  local group="$1" interval="$2" last now
  now="$(now_ts)"; last="$(get_group_last_run "${group}")"
  [[ -z "${last}" ]] && return 0
  [[ "${interval}" =~ ^[0-9]+$ ]] || return 1
  [[ "${last}" =~ ^[0-9]+$ ]] || return 0
  (( last <= now )) || return 0
  (( now - last >= interval ))
}

reconcile_due() {
  local group="$1" last now
  now="$(now_ts)"; last="$(get_group_last_reconcile "${group}")"
  [[ -z "${last}" ]] && return 0
  [[ "${FORCE_RECONCILE_SEC}" =~ ^[0-9]+$ ]] || FORCE_RECONCILE_SEC=3600
  [[ "${last}" =~ ^[0-9]+$ ]] || return 0
  (( last <= now )) || return 0
  (( now - last >= FORCE_RECONCILE_SEC ))
}

extract_group_state_map() {
  local group="$1" out="$2"
  awk -F '\t' -v g="${group}" '$1==g{print $2 "\t" $3}' "${STATE_FILE}" 2>/dev/null | sort -u > "${out}"
}

save_group_state() {
  local group="$1" map_file="$2" tmp
  tmp="$(mktemp "${VAR_DIR}/.state.XXXXXX")" || return 1
  if ! awk -F '\t' -v g="${group}" '$1!=g' "${STATE_FILE}" 2>/dev/null > "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  if ! awk -F '\t' -v g="${group}" '{print g "\t" $1 "\t" $2}' "${map_file}" >> "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  chmod 600 "${tmp}" || { rm -f "${tmp}"; return 1; }
  mv -f "${tmp}" "${STATE_FILE}" || { rm -f "${tmp}"; return 1; }
}

write_history() {
  local group="$1" action="$2" ip="$3" domains="$4" mode="$5" target="$6" note="$7"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(timestamp)" "${group}" "${action}" "${ip}" "${domains}" "${mode}" "${target}|${note}" >> "${HISTORY_FILE}"
}

domains_by_ip_from_map() {
  local map="$1" ip="$2"
  awk -F '\t' -v ip="${ip}" '$2==ip{print $1}' "${map}" | paste -sd ',' -
}

create_cf_record() {
  local token="$1" zone="$2" target="$3" ttl="$4" proxied="$5" ip="$6" payload resp
  payload="$(jq -nc --arg type A --arg name "${target}" --arg content "${ip}" \
    --argjson ttl "${ttl}" --argjson proxied "${proxied}" \
    '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')"
  resp="$(cf_api POST "${token}" "/zones/${zone}/dns_records" "${payload}")"
  if [[ "$(jq -r '.success // false' <<< "${resp}")" != "true" ]]; then
    log ERROR "创建 A 记录失败: ${target} -> ${ip}: $(jq -c '{status:._http_status,errors:.errors}' <<< "${resp}" 2>/dev/null || echo API_ERROR)"
    return 1
  fi
  return 0
}

delete_cf_record() {
  local token="$1" zone="$2" id="$3" resp
  resp="$(cf_api DELETE "${token}" "/zones/${zone}/dns_records/${id}")"
  if [[ "$(jq -r '.success // false' <<< "${resp}")" != "true" ]]; then
    log ERROR "删除 A 记录失败: record_id=${id}: $(jq -c '{status:._http_status,errors:.errors}' <<< "${resp}" 2>/dev/null || echo API_ERROR)"
    return 1
  fi
  return 0
}

update_cf_record_attributes() {
  local token="$1" zone="$2" id="$3" ttl="$4" proxied="$5" resp payload
  payload="$(jq -nc --argjson ttl "${ttl}" --argjson proxied "${proxied}" '{ttl:$ttl,proxied:$proxied}')"
  resp="$(cf_api PATCH "${token}" "/zones/${zone}/dns_records/${id}" "${payload}")"
  if [[ "$(jq -r '.success // false' <<< "${resp}")" != "true" ]]; then
    log ERROR "更新 A 记录属性失败: record_id=${id}: $(jq -c '{status:._http_status,errors:.errors}' <<< "${resp}" 2>/dev/null || echo API_ERROR)"
    return 1
  fi
  return 0
}

fetch_cf_a_records() {
  local group="$1" token="$2" zone="$3" target="$4" output="$5"
  local encoded page=1 total_pages=1 resp api_status retry_after
  encoded="$(urlencode "${target}")"
  : > "${output}"

  while (( page <= total_pages )); do
    resp="$(cf_api GET "${token}" "/zones/${zone}/dns_records?type=A&name=${encoded}&page=${page}&per_page=100")"
    if [[ "$(jq -r '.success // false' <<< "${resp}" 2>/dev/null)" != "true" ]]; then
      api_status="$(jq -r '._http_status // 0' <<< "${resp}" 2>/dev/null || echo 0)"
      retry_after="$(jq -r '._retry_after // 0' <<< "${resp}" 2>/dev/null || echo 0)"
      log ERROR "组 ${group}: Cloudflare API 查询失败，HTTP=${api_status}，retry-after=${retry_after}s，详情=$(jq -c '.errors' <<< "${resp}" 2>/dev/null || echo unknown)"
      return 1
    fi

    jq -r '.result[]? | [.id,.content,(.ttl | tostring),(.proxied | tostring)] | @tsv' <<< "${resp}" >> "${output}" || return 1
    total_pages="$(jq -r '.result_info.total_pages // 1' <<< "${resp}" 2>/dev/null || echo 1)"
    [[ "${total_pages}" =~ ^[0-9]+$ ]] || total_pages=1
    (( total_pages >= 1 )) || total_pages=1
    (( total_pages <= 1000 )) || {
      log ERROR "组 ${group}: Cloudflare 返回异常分页数量=${total_pages}，为安全起见停止同步"
      return 1
    }
    page=$((page+1))
  done

  return 0
}

sync_one_group() {
  local group_name="$1" enabled="$2" interval_sec="$3" api_token="$4" zone_id="$5"
  local target_fqdn="$6" ttl="$7" proxied="$8" mode="$9" sources_csv="${10}" active_route="${11:-PRIMARY}"

  if ! valid_group_name "${group_name}"; then
    log ERROR "组名为空、过长或包含 TAB、换行、回车或反斜杠"
    return 1
  fi

  if [[ "${enabled}" != "true" && "${enabled}" != "false" ]]; then
    log ERROR "组 ${group_name}: enabled 必须是 true 或 false"
    return 1
  fi
  if [[ "${enabled}" == "false" ]]; then
    [[ "${TARGET_GROUP}" == "${group_name}" ]] && log ERROR "组 ${group_name}: 已禁用，未执行"
    [[ "${RUN_MODE}" == "AUTO" ]] && return 0 || return 1
  fi

  if [[ "${RUN_MODE}" == "AUTO" ]] && ! should_run_group "${group_name}" "${interval_sec}"; then
    return 0
  fi

  if ! [[ "${interval_sec}" =~ ^[0-9]+$ ]] || (( interval_sec < 5 )); then
    log ERROR "组 ${group_name}: 检测周期必须是 >=5 秒的数字"
    return 1
  fi
  if ! valid_ttl "${ttl}"; then
    log ERROR "组 ${group_name}: TTL 必须为 1（自动）或 60~86400 秒"
    return 1
  fi
  if [[ -z "${api_token}" || -z "${zone_id}" || -z "${target_fqdn}" ]]; then
    log ERROR "组 ${group_name}: API Token、Zone ID 或目标域名为空"
    return 1
  fi
  if ! [[ "${zone_id}" =~ ^[a-fA-F0-9]{32}$ ]]; then
    log ERROR "组 ${group_name}: Zone ID 格式错误，应为32位十六进制字符串"
    return 1
  fi
  if ! valid_domain "${target_fqdn}"; then
    log ERROR "组 ${group_name}: 目标域名格式错误：${target_fqdn}"
    return 1
  fi
  if [[ "${proxied}" != "false" ]]; then
    log ERROR "组 ${group_name}: 当前版本仅支持 DNS only（proxied=false）"
    return 1
  fi
  if [[ "${mode}" != "ALL_IPS" && "${mode}" != "SINGLE_IP" ]]; then
    log ERROR "组 ${group_name}: 解析模式必须是 ALL_IPS 或 SINGLE_IP"
    return 1
  fi

  csv_to_sources_array "${sources_csv}"
  local source_count="${#SOURCES_ARRAY[@]}" source_domain
  if (( source_count < 1 || source_count > 20 )); then
    log ERROR "组 ${group_name}: 源域名数量必须为 1~20，当前=${source_count}"
    return 1
  fi
  for source_domain in "${SOURCES_ARRAY[@]}"; do
    if ! valid_domain "${source_domain}"; then
      log ERROR "组 ${group_name}: 源域名格式错误：${source_domain}"
      return 1
    fi
  done

  local tmpdir map_file failed_domains old_map desired current_records current_unique to_add to_del
  tmpdir="$(mktemp -d)" || { log ERROR "组 ${group_name}: 无法创建临时目录"; return 1; }
  map_file="${tmpdir}/map"; failed_domains="${tmpdir}/failed_domains"
  old_map="${tmpdir}/old_map"; desired="${tmpdir}/desired"
  current_records="${tmpdir}/records"; current_unique="${tmpdir}/current"
  to_add="${tmpdir}/to_add"; to_del="${tmpdir}/to_del"

  log DEBUG "组 ${group_name}: 开始本机检测 -> ${target_fqdn}，线路=${active_route}，周期=${interval_sec}s，源域名=${source_count}"
  if ! build_group_map "${mode}" "${map_file}" "${failed_domains}" "${SOURCES_ARRAY[@]}"; then
    log ERROR "组 ${group_name}: 无法生成源 IP 映射"
    rm -rf "${tmpdir}"
    return 1
  fi
  if ! set_group_last_run "${group_name}" "$(now_ts)"; then
    log ERROR "组 ${group_name}: 无法更新本地执行时间，已停止本轮同步"
    rm -rf "${tmpdir}"
    return 1
  fi

  # 任意一个源域名解析失败都停止本轮同步，防止把暂时解析失败误判成IP下线。
  if [[ -s "${failed_domains}" ]]; then
    log ERROR "组 ${group_name}: 以下源域名未解析到 IPv4：$(paste -sd ',' "${failed_domains}")；为防误删，未访问 Cloudflare"
    rm -rf "${tmpdir}"
    return 1
  fi

  if [[ ! -s "${map_file}" ]]; then
    log ERROR "组 ${group_name}: 未查询到任何源 IPv4；为防误删，未访问 Cloudflare"
    rm -rf "${tmpdir}"
    return 1
  fi

  if ! awk -F '\t' '{print $2}' "${map_file}" | sort -u > "${desired}"; then
    log ERROR "组 ${group_name}: 无法生成目标 IP 集合"
    rm -rf "${tmpdir}"
    return 1
  fi
  if ! extract_group_state_map "${group_name}" "${old_map}"; then
    log ERROR "组 ${group_name}: 无法读取本地成功状态，已停止本轮同步"
    rm -rf "${tmpdir}"
    return 1
  fi

  local local_changed=0 force_reconcile=0
  cmp -s "${map_file}" "${old_map}" || local_changed=1
  if [[ "${FORCE_FLAG}" == "1" ]] || reconcile_due "${group_name}" || [[ ! -s "${old_map}" ]]; then
    force_reconcile=1
  fi

  if (( local_changed == 0 && force_reconcile == 0 )); then
    log DEBUG "组 ${group_name}: 源 IP 无变化，未调用 Cloudflare API"
    rm -rf "${tmpdir}"
    return 0
  fi

  if (( local_changed == 1 )); then
    local old_ips new_ips
    old_ips="$(awk -F '\t' '{print $2}' "${old_map}" | sort -u | paste -sd ',' -)"
    new_ips="$(paste -sd ',' "${desired}")"
    log INFO "组 ${group_name}: 检测到源 IP 变化，旧集合=${old_ips:-空}，新集合=${new_ips:-空}"
  else
    log DEBUG "组 ${group_name}: 到达强制校准周期，开始核对 Cloudflare"
  fi

  if ! fetch_cf_a_records "${group_name}" "${api_token}" "${zone_id}" "${target_fqdn}" "${current_records}"; then
    rm -rf "${tmpdir}"
    return 1
  fi
  if ! cut -f2 "${current_records}" | sed '/^$/d' | sort -u > "${current_unique}"; then
    log ERROR "组 ${group_name}: 无法生成 Cloudflare 当前 IP 集合"
    rm -rf "${tmpdir}"
    return 1
  fi
  if ! comm -23 "${desired}" "${current_unique}" > "${to_add}" || ! comm -13 "${desired}" "${current_unique}" > "${to_del}"; then
    log ERROR "组 ${group_name}: 无法比较目标与 Cloudflare 当前 IP 集合"
    rm -rf "${tmpdir}"
    return 1
  fi

  local op_failed=0 add_failed=0 ip id domains first_id record_ttl record_proxied

  # 可用性优先：先把所有新 IP 添加成功，再删除旧 IP。
  # 任意新增失败时保留全部旧记录，避免在切换过程中造成目标域名无可用 A 记录。
  while IFS= read -r ip; do
    [[ -n "${ip}" ]] || continue
    domains="$(domains_by_ip_from_map "${map_file}" "${ip}")"
    [[ -n "${domains}" ]] || domains="unknown"
    if create_cf_record "${api_token}" "${zone_id}" "${target_fqdn}" "${ttl}" "${proxied}" "${ip}"; then
      write_history "${group_name}" ADD "${ip}" "${domains}" "${mode}" "${target_fqdn}" "route=${active_route};added_to_cloudflare"
      log INFO "组 ${group_name}: 已新增 IP ${ip}"
    else
      add_failed=1
      op_failed=1
    fi
  done < "${to_add}"

  if (( add_failed == 0 )); then
    # 同一 IP 已存在时仍核对 TTL/proxied，避免菜单修改成功但远端属性永久漂移。
    while IFS= read -r ip; do
      [[ -n "${ip}" ]] || continue
      id=""; record_ttl=""; record_proxied=""
      IFS=$'\t' read -r id _ record_ttl record_proxied < <(awk -F '\t' -v ip="${ip}" '$2==ip{print; exit}' "${current_records}") || true
      [[ -n "${id:-}" ]] || continue
      if [[ "${record_ttl}" != "${ttl}" || "${record_proxied}" != "${proxied}" ]]; then
        domains="$(domains_by_ip_from_map "${map_file}" "${ip}")"
        [[ -n "${domains}" ]] || domains="unknown"
        if update_cf_record_attributes "${api_token}" "${zone_id}" "${id}" "${ttl}" "${proxied}"; then
          write_history "${group_name}" UPDATE "${ip}" "${domains}" "${mode}" "${target_fqdn}" \
            "route=${active_route};attributes_updated;ttl=${record_ttl}->${ttl};proxied=${record_proxied}->${proxied}" || \
            log ERROR "组 ${group_name}: A 记录属性已更新，但历史写入失败：${ip}"
          log INFO "组 ${group_name}: 已修正 IP ${ip} 的记录属性（TTL=${ttl}, proxied=${proxied}）"
        else
          op_failed=1
        fi
      fi
    done < "${desired}"

    # 只有全部新增成功后，才删除已不再需要的旧 IP。
    while IFS=$'\t' read -r id ip _ _; do
      [[ -n "${id}" && -n "${ip}" ]] || continue
      if grep -Fxq "${ip}" "${to_del}"; then
        domains="$(domains_by_ip_from_map "${old_map}" "${ip}")"
        [[ -n "${domains}" ]] || domains="unknown"
        if delete_cf_record "${api_token}" "${zone_id}" "${id}"; then
          write_history "${group_name}" DELETE "${ip}" "${domains}" "${mode}" "${target_fqdn}" "route=${active_route};removed_from_cloudflare"
          log INFO "组 ${group_name}: 已删除旧 IP ${ip}"
        else
          op_failed=1
        fi
      fi
    done < "${current_records}"

    # 清理同一目标域名下的重复 A 记录，每个 IP 只保留一条。
    while IFS= read -r ip; do
      [[ -n "${ip}" ]] || continue
      first_id=""
      while IFS=$'\t' read -r id _ _ _; do
        [[ -n "${first_id}" ]] || { first_id="${id}"; continue; }
        if delete_cf_record "${api_token}" "${zone_id}" "${id}"; then
          domains="$(domains_by_ip_from_map "${map_file}" "${ip}")"
          [[ -n "${domains}" ]] || domains="unknown"
          write_history "${group_name}" DELETE "${ip}" "${domains}" "${mode}" "${target_fqdn}" "route=${active_route};duplicate_record_cleanup"
          log INFO "组 ${group_name}: 已清理重复 A 记录 ${ip}"
        else
          op_failed=1
        fi
      done < <(awk -F '\t' -v ip="${ip}" '$2==ip{print $1 "\t" $2}' "${current_records}")
    done < "${desired}"
  else
    log ERROR "组 ${group_name}: 新 IP 未全部添加成功，为保障可用性，本轮未删除任何旧 IP"
  fi

  if (( op_failed == 0 )); then
    if ! save_group_state "${group_name}" "${map_file}" || ! set_group_last_reconcile "${group_name}" "$(now_ts)"; then
      op_failed=1
      log ERROR "组 ${group_name}: Cloudflare 已操作，但本地成功状态保存失败；下个周期会重新核对"
    else
      if [[ ! -s "${to_add}" && ! -s "${to_del}" ]]; then
        log DEBUG "组 ${group_name}: Cloudflare 记录与源 IP 及属性一致"
      else
        log INFO "组 ${group_name}: 增量同步完成"
      fi
    fi
  fi
  if (( op_failed != 0 )); then
    log ERROR "组 ${group_name}: API 或本地状态操作失败，未推进本地成功状态；下个检测周期会重新核对并重试"
  fi

  rm -rf "${tmpdir}"
  return "${op_failed}"
}

assign_group_config_line() {
  split_tsv_line "$1"
  (( ${#TSV_FIELDS[@]} == 10 )) || return 1
  group_name="${TSV_FIELDS[0]}"; enabled="${TSV_FIELDS[1]}"; interval_sec="${TSV_FIELDS[2]}"
  api_token="${TSV_FIELDS[3]}"; zone_id="${TSV_FIELDS[4]}"; target_fqdn="${TSV_FIELDS[5]}"
  ttl="${TSV_FIELDS[6]}"; proxied="${TSV_FIELDS[7]}"; mode="${TSV_FIELDS[8]}"; sources_csv="${TSV_FIELDS[9]}"
}

main() {
  local configured=0 matched=0 enabled_count=0 failures=0 key row field_count
  local group_name enabled interval_sec api_token zone_id target_fqdn ttl proxied mode sources_csv
  declare -A group_name_count=() target_key_count=()

  if [[ "${SPECIAL_MODE}" == "GPTEST" ]]; then
    [[ -n "${TARGET_GROUP}" ]] || { log ERROR "GPTEST 缺少组名"; exit 1; }
    manual_globalping_test "${TARGET_GROUP}" "${SPECIAL_ROLE}"
    exit $?
  fi
  if [[ "${SPECIAL_MODE}" == "FOSWITCH" ]]; then
    [[ -n "${TARGET_GROUP}" ]] || { log ERROR "FOSWITCH 缺少组名"; exit 1; }
    manual_failover_switch "${TARGET_GROUP}" "${SPECIAL_ROLE}" || exit $?
    RUN_MODE="GROUP"; FORCE_FLAG="1"; SPECIAL_MODE=""
  elif [[ "${SPECIAL_MODE}" == "FORESET" ]]; then
    [[ -n "${TARGET_GROUP}" ]] || { log ERROR "FORESET 缺少组名"; exit 1; }
    manual_failover_reset "${TARGET_GROUP}" || exit $?
    RUN_MODE="GROUP"; FORCE_FLAG="1"; SPECIAL_MODE=""
  fi

  # 第一遍只做冲突统计。即使用户手工编辑 groups.tsv 造成重复，也不会让两个组互相覆盖同一目标记录。
  while IFS= read -r row || [[ -n "${row}" ]]; do
    [[ -z "${row}" || "${row}" =~ ^# ]] && continue
    assign_group_config_line "${row}" || continue
    [[ -n "${group_name}" ]] || continue
    group_name_count["${group_name}"]=$(( ${group_name_count["${group_name}"]:-0} + 1 ))
    if [[ -n "${zone_id}" && -n "${target_fqdn}" ]]; then
      key="${zone_id,,}|${target_fqdn,,}"
      target_key_count["${key}"]=$(( ${target_key_count["${key}"]:-0} + 1 ))
    fi
  done < "${GROUPS_FILE}"

  while IFS= read -r row || [[ -n "${row}" ]]; do
    [[ -z "${row}" || "${row}" =~ ^# ]] && continue
    split_tsv_line "${row}"
    field_count="${#TSV_FIELDS[@]}"
    group_name="${TSV_FIELDS[0]:-}"
    configured=$((configured+1))
    if [[ "${TARGET_GROUP}" != "ALL" && "${TARGET_GROUP}" != "${group_name}" ]]; then
      continue
    fi
    matched=$((matched+1))

    if (( field_count != 10 )); then
      log ERROR "组 ${group_name:-<空组名>}: groups.tsv 字段数量应为10，实际=${field_count}，已跳过该组"
      rollback_failover_switch "${group_name}" || true
      failures=$((failures+1)); continue
    fi
    assign_group_config_line "${row}" || { failures=$((failures+1)); continue; }
    [[ "${enabled}" == "true" ]] && enabled_count=$((enabled_count+1))
    if ! valid_group_name "${group_name}"; then
      log ERROR "组名为空、过长或包含 TAB、换行、回车或反斜杠，已跳过该配置"
      failures=$((failures+1)); continue
    fi
    if (( ${group_name_count["${group_name}"]:-0} > 1 )); then
      log ERROR "组名 ${group_name} 重复，为防止状态互相覆盖，已跳过所有同名组"
      rollback_failover_switch "${group_name}" || true
      failures=$((failures+1)); continue
    fi
    key="${zone_id,,}|${target_fqdn,,}"
    if [[ -n "${zone_id}" && -n "${target_fqdn}" ]] && (( ${target_key_count["${key}"]:-0} > 1 )); then
      log ERROR "目标 ${target_fqdn} 在同一 Zone 中被多个组重复管理，为防止互相覆盖，已跳过相关组"
      rollback_failover_switch "${group_name}" || true
      failures=$((failures+1)); continue
    fi

    # 只有自动调度推进 Globalping 状态机。手动同步只核对当前活动线路，避免意外消耗测试额度。
    if [[ "${RUN_MODE}" == "AUTO" ]]; then
      FAILOVER_SWITCH_PENDING=0
      if ! failover_tick "${group_name}" "${enabled}" "${sources_csv}"; then
        failures=$((failures+1))
        log ERROR "组 ${group_name}: 故障转移状态机执行失败；本轮不改变线路"
      fi
    fi

    if ! get_effective_group_sources "${group_name}" "${sources_csv}"; then
      failures=$((failures+1))
      log ERROR "组 ${group_name}: 无法确定当前活动线路，已跳过同步"
      rollback_failover_switch "${group_name}" || true
      continue
    fi

    if sync_one_group "${group_name}" "${enabled}" "${interval_sec}" "${api_token}" "${zone_id}" \
      "${target_fqdn}" "${ttl}" "${proxied}" "${mode}" "${EFFECTIVE_SOURCES_CSV}" "${EFFECTIVE_ROUTE}"; then
      if ! finalize_failover_switch "${group_name}"; then
        failures=$((failures+1))
      fi
    else
      rollback_failover_switch "${group_name}" || true
      failures=$((failures+1))
      log ERROR "组 ${group_name}: 本轮同步失败，已隔离该组，不影响其它组"
    fi
  done < "${GROUPS_FILE}"

  if [[ "${TARGET_GROUP}" == "ALL" ]]; then
    [[ "${configured}" -eq 0 ]] && log DEBUG "当前没有配置组，跳过检测"
    [[ "${configured}" -gt 0 && "${enabled_count}" -eq 0 ]] && log DEBUG "当前没有启用组，跳过检测"
    if [[ "${RUN_MODE}" != "AUTO" && "${failures}" -gt 0 ]]; then exit 1; fi
    exit 0
  fi
  if [[ "${matched}" -eq 0 ]]; then
    log ERROR "未找到需要同步的组: ${TARGET_GROUP}"
    exit 1
  fi
  [[ "${failures}" -gt 0 ]] && exit 1
  exit 0
}

main
SYNC
  if ! bash -n "${tmp}"; then
    echo "生成的同步脚本语法校验失败，保留现有版本" >&2
    rm -f "${tmp}"
    return 1
  fi
  install -m 700 "${tmp}" "${BIN_SYNC}"
  rm -f "${tmp}"
}

write_ctl_script() {
  local tmp
  tmp="$(mktemp /usr/local/bin/.cfdns.XXXXXX)"
  cat > "${tmp}" <<'CTL'
#!/usr/bin/env bash
set -uo pipefail
umask 077

APP_NAME="cf-dns-sync"
APP_VERSION="2.9"
BASE_DIR="/etc/${APP_NAME}"
VAR_DIR="/var/lib/${APP_NAME}"
SETTINGS_FILE="${BASE_DIR}/settings.conf"
GROUPS_FILE="${BASE_DIR}/groups.tsv"
FAILOVER_FILE="${BASE_DIR}/failover.tsv"
SERVICE_NAME="${APP_NAME}.service"
TIMER_NAME="${APP_NAME}.timer"
LOG_DIR="/var/log/${APP_NAME}"
LOG_FILE="${LOG_DIR}/${APP_NAME}.log"
HISTORY_FILE="${LOG_DIR}/${APP_NAME}-history.tsv"
FAILOVER_HISTORY_FILE="${LOG_DIR}/${APP_NAME}-failover.tsv"
LEGACY_LOG_FILE="/var/log/${APP_NAME}.log"
LEGACY_HISTORY_FILE="/var/log/${APP_NAME}-history.tsv"
STATE_FILE="${VAR_DIR}/state.tsv"
RUNSTATE_FILE="${VAR_DIR}/runstate.tsv"
RECONCILE_FILE="${VAR_DIR}/reconcile.tsv"
FAILOVER_STATE_FILE="${VAR_DIR}/failover-state.tsv"
GLOBALPING_USAGE_FILE="${VAR_DIR}/globalping-usage.tsv"
HISTORY_LOCK_FILE="/run/cf-dns-sync.lock"
INSTALL_COPY="/opt/cfdns/cfdns-installer.sh"
INIT_FLAG="${VAR_DIR}/.initialized"

[[ "$(id -u)" -eq 0 ]] || { echo "请使用 root 运行" >&2; exit 1; }
mkdir -p "${BASE_DIR}" "${VAR_DIR}" "${LOG_DIR}" || { echo "无法创建配置、状态或日志目录" >&2; exit 1; }
chmod 700 "${BASE_DIR}" "${VAR_DIR}" "${LOG_DIR}" 2>/dev/null || true

legacy_log_family_exists_local() {
  local base="$1" f
  [[ -f "${base}" ]] && return 0
  shopt -s nullglob
  for f in "${base}".* "${base}"-*; do
    if [[ -f "${f}" ]]; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

move_legacy_log_family_local() {
  local old_base="$1" new_base="$2" suffix src dst tmp
  shopt -s nullglob
  local files=("${old_base}" "${old_base}".* "${old_base}"-*)
  shopt -u nullglob
  for src in "${files[@]}"; do
    [[ -f "${src}" && ! -L "${src}" ]] || continue
    suffix="${src#"${old_base}"}"
    dst="${new_base}${suffix}"
    if [[ ! -e "${dst}" ]]; then
      mv -- "${src}" "${dst}" 2>/dev/null || continue
      chmod 600 "${dst}" 2>/dev/null || true
      continue
    fi
    tmp="$(mktemp "${LOG_DIR}/.log-migrate.XXXXXX")" || continue
    if [[ "${src}" == *.gz && "${dst}" == *.gz ]]; then
      if { gzip -cd -- "${dst}"; gzip -cd -- "${src}"; } 2>/dev/null | LC_ALL=C sort -u | gzip -c > "${tmp}"; then
        chmod 600 "${tmp}" && mv -f "${tmp}" "${dst}" && rm -f "${src}"
      else
        rm -f "${tmp}"
      fi
    elif [[ "${src}" != *.gz && "${dst}" != *.gz ]]; then
      if { cat -- "${dst}"; cat -- "${src}"; } | LC_ALL=C sort -u > "${tmp}"; then
        chmod 600 "${tmp}" && mv -f "${tmp}" "${dst}" && rm -f "${src}"
      else
        rm -f "${tmp}"
      fi
    else
      rm -f "${tmp}"
    fi
  done
}

migrate_legacy_logs_local() {
  mkdir -p "${LOG_DIR}"
  chmod 700 "${LOG_DIR}" 2>/dev/null || true
  move_legacy_log_family_local "${LEGACY_LOG_FILE}" "${LOG_FILE}"
  move_legacy_log_family_local "${LEGACY_HISTORY_FILE}" "${HISTORY_FILE}"
}

[[ -f "${SETTINGS_FILE}" ]] || cat > "${SETTINGS_FILE}" <<'CFG'
LOG_LEVEL="INFO"
FORCE_RECONCILE_SEC="3600"
DNS_SERVER=""
DNS_QUERY_TIMEOUT_SEC="2"
GLOBALPING_API_TOKEN=""
GLOBALPING_MAX_TESTS_PER_HOUR="240"
GLOBALPING_MEASUREMENT_TIMEOUT_SEC="12"
GLOBALPING_POLL_MAX_SEC="25"
CFG

[[ -f "${GROUPS_FILE}" ]] || cat > "${GROUPS_FILE}" <<'TSV'
# group_name<TAB>enabled<TAB>interval_sec<TAB>api_token<TAB>zone_id<TAB>target_fqdn<TAB>ttl<TAB>proxied<TAB>mode<TAB>source_domains_csv
TSV

[[ -f "${FAILOVER_FILE}" ]] || cat > "${FAILOVER_FILE}" <<'TSV'
# group_name<TAB>enabled<TAB>backup_sources_csv<TAB>primary_check_target<TAB>backup_check_target<TAB>check_type<TAB>tcp_port<TAB>location<TAB>stable_interval_sec<TAB>fast_interval_sec<TAB>primary_fail_threshold<TAB>backup_success_threshold<TAB>primary_recovery_threshold
# 示例：
# group-a	true	backup1.example.com,backup2.example.com	primary1.example.com	backup1.example.com	PING_ICMP	0	China	300	60	3	2	2
TSV

chmod 600 "${SETTINGS_FILE}" "${GROUPS_FILE}" "${FAILOVER_FILE}" 2>/dev/null || {
  echo "无法设置配置文件权限" >&2
  exit 1
}

# shellcheck disable=SC1090
if ! source "${SETTINGS_FILE}"; then
  echo "全局配置语法错误，已停止打开管理菜单: ${SETTINGS_FILE}" >&2
  exit 1
fi
LOG_LEVEL="${LOG_LEVEL:-INFO}"
FORCE_RECONCILE_SEC="${FORCE_RECONCILE_SEC:-3600}"
DNS_SERVER="${DNS_SERVER:-}"
DNS_QUERY_TIMEOUT_SEC="${DNS_QUERY_TIMEOUT_SEC:-2}"
GLOBALPING_API_TOKEN="${GLOBALPING_API_TOKEN:-}"
GLOBALPING_MAX_TESTS_PER_HOUR="${GLOBALPING_MAX_TESTS_PER_HOUR:-240}"
GLOBALPING_MEASUREMENT_TIMEOUT_SEC="${GLOBALPING_MEASUREMENT_TIMEOUT_SEC:-12}"
GLOBALPING_POLL_MAX_SEC="${GLOBALPING_POLL_MAX_SEC:-25}"
[[ "${GLOBALPING_MAX_TESTS_PER_HOUR}" =~ ^[0-9]+$ ]] && (( GLOBALPING_MAX_TESTS_PER_HOUR >= 1 )) || GLOBALPING_MAX_TESTS_PER_HOUR=240
[[ "${GLOBALPING_MEASUREMENT_TIMEOUT_SEC}" =~ ^[0-9]+$ ]] && (( GLOBALPING_MEASUREMENT_TIMEOUT_SEC >= 5 && GLOBALPING_MEASUREMENT_TIMEOUT_SEC <= 30 )) || GLOBALPING_MEASUREMENT_TIMEOUT_SEC=12
[[ "${GLOBALPING_POLL_MAX_SEC}" =~ ^[0-9]+$ ]] && (( GLOBALPING_POLL_MAX_SEC >= GLOBALPING_MEASUREMENT_TIMEOUT_SEC && GLOBALPING_POLL_MAX_SEC <= 60 )) || GLOBALPING_POLL_MAX_SEC=25

CHOSEN_INDEX=""
CHOSEN_LINE=""
CHOSEN_GROUP_NAME=""

color() {
  local code="$1"; shift
  printf "[%sm%s[0m" "${code}" "$*"
}

line() {
  printf "%s\n" "=========================================================================="
}

title() {
  clear 2>/dev/null || true
  line
  color "1;36" "cfdns 管理菜单 v${APP_VERSION}"
  echo
  color "0;37" "本机检测 · Globalping 故障转移 · 安全 DNS 联动"
  echo
  line
}


pause_wait() {
  echo
  read -n 1 -s -r -p "按任意键继续..." || true
}

save_settings() {
  local tmp
  tmp="$(mktemp "${BASE_DIR}/.settings.XXXXXX")" || return 1
  if ! {
    printf 'LOG_LEVEL=%q\n' "${LOG_LEVEL}"
    printf 'FORCE_RECONCILE_SEC=%q\n' "${FORCE_RECONCILE_SEC}"
    printf 'DNS_SERVER=%q\n' "${DNS_SERVER}"
    printf 'DNS_QUERY_TIMEOUT_SEC=%q\n' "${DNS_QUERY_TIMEOUT_SEC}"
    printf 'GLOBALPING_API_TOKEN=%q\n' "${GLOBALPING_API_TOKEN}"
    printf 'GLOBALPING_MAX_TESTS_PER_HOUR=%q\n' "${GLOBALPING_MAX_TESTS_PER_HOUR}"
    printf 'GLOBALPING_MEASUREMENT_TIMEOUT_SEC=%q\n' "${GLOBALPING_MEASUREMENT_TIMEOUT_SEC}"
    printf 'GLOBALPING_POLL_MAX_SEC=%q\n' "${GLOBALPING_POLL_MAX_SEC}"
  } > "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  bash -n "${tmp}" >/dev/null 2>&1 || { rm -f "${tmp}"; return 1; }
  chmod 600 "${tmp}" || { rm -f "${tmp}"; return 1; }
  mv -f "${tmp}" "${SETTINGS_FILE}" || { rm -f "${tmp}"; return 1; }
}

split_tsv_line() {
  local rest="${1-}"
  TSV_FIELDS=()
  while [[ "${rest}" == *$'\t'* ]]; do
    TSV_FIELDS+=("${rest%%$'\t'*}")
    rest="${rest#*$'\t'}"
  done
  TSV_FIELDS+=("${rest}")
}

normalize_sources_csv() {
  local csv="$1"
  printf '%s' "${csv}" | tr ',' '\n' | \
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
    awk 'NF && !seen[$0]++' | paste -sd ',' -
}

count_sources_csv() {
  local normalized
  normalized="$(normalize_sources_csv "${1}")"
  [[ -z "${normalized}" ]] && { echo 0; return; }
  awk -F',' '{print NF}' <<< "${normalized}"
}

valid_ttl() {
  local ttl="${1:-}"
  [[ "${ttl}" =~ ^[0-9]+$ ]] || return 1
  [[ "${ttl}" -eq 1 || ( "${ttl}" -ge 60 && "${ttl}" -le 86400 ) ]]
}

valid_zone_id() {
  [[ "${1:-}" =~ ^[a-fA-F0-9]{32}$ ]]
}

valid_api_token_field() {
  local value="${1:-}"
  [[ -n "${value}" && "${value}" != *$'\t'* && "${value}" != *$'\r'* && "${value}" != *$'\n'* && "${value}" != *\\* ]]
}

valid_group_name_field() {
  local value="${1:-}"
  [[ -n "${value}" && "${#value}" -le 128 && "${value}" != *$'\t'* && "${value}" != *$'\r'* && "${value}" != *$'\n'* && "${value}" != *\\* ]]
}

validate_sources_csv() {
  local csv="${1:-}" count domain
  count="$(count_sources_csv "${csv}")"
  [[ "${count}" -ge 1 && "${count}" -le 20 ]] || return 1
  parse_sources_to_array "${csv}"
  for domain in "${SOURCES_ARRAY[@]}"; do
    valid_domain "${domain}" || return 1
  done
  return 0
}

save_groups_with_tmp() {
  local tmp="$1" staged
  staged="$(mktemp "${BASE_DIR}/.groups.XXXXXX")" || { rm -f "${tmp}"; return 1; }
  cat -- "${tmp}" > "${staged}" || { rm -f "${tmp}" "${staged}"; return 1; }
  chmod 600 "${staged}" || { rm -f "${tmp}" "${staged}"; return 1; }
  mv -f "${staged}" "${GROUPS_FILE}" || { rm -f "${tmp}" "${staged}"; return 1; }
  rm -f "${tmp}"
}

get_group_count() {
  awk 'BEGIN{n=0} !/^#/ && NF>0 {n++} END{print n}' "${GROUPS_FILE}"
}

valid_domain() {
  local domain="${1:-}" tld
  domain="${domain%.}"
  [[ -n "${domain}" && "${#domain}" -le 253 ]] || return 1
  [[ "${domain}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  tld="${domain##*.}"
  [[ "${tld}" =~ [A-Za-z] ]]
}

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

ui_resolve_domain_ipv4() {
  local domain="$1"
  local -a args=(+short "+time=${DNS_QUERY_TIMEOUT_SEC}" +tries=1 A "${domain}")
  [[ -n "${DNS_SERVER}" ]] && args=("@${DNS_SERVER}" +short "+time=${DNS_QUERY_TIMEOUT_SEC}" +tries=1 A "${domain}")
  dig "${args[@]}" 2>/dev/null | awk -F. '
    NF==4 {
      ok=1
      for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i<0 || $i>255) ok=0
      if(ok) print $0
    }
  ' | sort -u
}

ui_cf_get() {
  local url="$1" token="$2" resp rc
  resp="$(curl -sS --connect-timeout 10 --max-time 35 --retry 2 --retry-delay 1 \
    -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' "${url}" 2>&1)"
  rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    jq -nc --arg msg "curl 请求失败，退出码=${rc}: ${resp}" '{success:false,errors:[{message:$msg}]}'
    return 0
  fi
  if ! jq -e . >/dev/null 2>&1 <<< "${resp}"; then
    jq -nc --arg msg "返回内容不是 JSON" --arg body "${resp:0:300}" '{success:false,errors:[{message:$msg,body:$body}]}'
    return 0
  fi
  printf '%s\n' "${resp}"
}

prompt_interval() {
  local choice custom
  echo "请选择检测周期："
  echo "1. ⚡ 5 秒（最快）"
  echo "2. 🚀 10 秒"
  echo "3. 🏃 15 秒"
  echo "4. ⏱️  30 秒"
  echo "5. 🕐 60 秒"
  echo "6. 🕔 300 秒"
  echo "7. 🕙 600 秒"
  echo "8. ✍️  自定义（最小 5 秒）"
  read -rp "请选择 [1-8]: " choice || return 1
  case "${choice}" in
    1) SELECTED_INTERVAL=5 ;;
    2) SELECTED_INTERVAL=10 ;;
    3) SELECTED_INTERVAL=15 ;;
    4) SELECTED_INTERVAL=30 ;;
    5|"") SELECTED_INTERVAL=60 ;;
    6) SELECTED_INTERVAL=300 ;;
    7) SELECTED_INTERVAL=600 ;;
    8)
      read -rp "请输入自定义秒数（>=5）: " custom || return 1
      [[ "${custom}" =~ ^[0-9]+$ && "${custom}" -ge 5 ]] || { echo "必须是 >=5 的整数"; return 1; }
      SELECTED_INTERVAL="${custom}"
      ;;
    *) echo "无效选择"; return 1 ;;
  esac
  return 0
}

remove_group_runtime_state() {
  local group="$1" file tmp
  for file in "${STATE_FILE}" "${RUNSTATE_FILE}" "${RECONCILE_FILE}"; do
    [[ -f "${file}" ]] || continue
    tmp="$(mktemp "${VAR_DIR}/.runtime-state.XXXXXX")" || return 1
    if ! awk -F '	' -v g="${group}" '$1!=g' "${file}" > "${tmp}"; then
      rm -f "${tmp}"
      return 1
    fi
    chmod 600 "${tmp}" || { rm -f "${tmp}"; return 1; }
    mv -f "${tmp}" "${file}" || { rm -f "${tmp}"; return 1; }
  done
}

invalidate_group_sync_state() {
  remove_group_runtime_state "$1"
}

find_duplicate_target() {
  local zone="$1" target="$2" exclude_group="${3:-}"
  awk -F '	' -v z="${zone}" -v t="${target}" -v x="${exclude_group}" \
    '!/^#/ && NF>0 && $1!=x && tolower($5)==tolower(z) && tolower($6)==tolower(t){print $1; exit}' "${GROUPS_FILE}"
}

list_groups_table() {
  local i=0 row group_name enabled interval_sec target_fqdn ttl proxied mode sources_csv count enabled_text proxy_text
  while IFS= read -r row || [[ -n "${row}" ]]; do
    [[ -z "${row}" || "${row}" =~ ^# ]] && continue
    i=$((i+1))
    split_tsv_line "${row}"
    if (( ${#TSV_FIELDS[@]} != 10 )); then
      printf '[%d] 配置损坏（字段应为10，实际为%d；请运行菜单24自检）\n\n' "${i}" "${#TSV_FIELDS[@]}"
      continue
    fi
    group_name="${TSV_FIELDS[0]}"; enabled="${TSV_FIELDS[1]}"; interval_sec="${TSV_FIELDS[2]}"
    target_fqdn="${TSV_FIELDS[5]}"; ttl="${TSV_FIELDS[6]}"; proxied="${TSV_FIELDS[7]}"
    mode="${TSV_FIELDS[8]}"; sources_csv="${TSV_FIELDS[9]}"
    count="$(count_sources_csv "${sources_csv}")"
    [[ "${enabled}" == true ]] && enabled_text="启用" || enabled_text="禁用"
    [[ "${proxied}" == true ]] && proxy_text="开启" || proxy_text="关闭"
    printf '[%d] %s\n' "${i}" "${group_name}"
    printf '    状态：%s  周期：%s 秒  模式：%s\n' "${enabled_text}" "${interval_sec}" "${mode}"
    printf '    目标：%s\n' "${target_fqdn}"
    printf '    TTL：%s  Cloudflare 代理：%s  源域名：%s 个\n\n' "${ttl}" "${proxy_text}" "${count}"
  done < "${GROUPS_FILE}"

  [[ "${i}" -eq 0 ]] && echo "当前还没有任何组。"
}

group_line_by_index() {
  local wanted="$1"
  local i=0 row
  while IFS= read -r row || [[ -n "${row}" ]]; do
    [[ -z "${row}" || "${row}" =~ ^# ]] && continue
    i=$((i+1))
    if [[ "${i}" -eq "${wanted}" ]]; then
      printf '%s\n' "${row}"
      return 0
    fi
  done < "${GROUPS_FILE}"
  return 1
}

select_group() {
  CHOSEN_INDEX=""
  CHOSEN_LINE=""
  CHOSEN_GROUP_NAME=""
  list_groups_table
  echo
  read -rp "请输入组序号: " idx || return 1
  [[ "${idx}" =~ ^[0-9]+$ ]] || return 1
  local line
  line="$(group_line_by_index "${idx}" || true)"
  [[ -n "${line}" ]] || return 1
  CHOSEN_INDEX="${idx}"
  CHOSEN_LINE="${line}"
  CHOSEN_GROUP_NAME="$(cut -f1 <<< "${line}")"
  return 0
}

split_line_to_vars() {
  local line="$1"
  split_tsv_line "${line}"
  (( ${#TSV_FIELDS[@]} == 10 )) || return 1
  GROUP_NAME="${TSV_FIELDS[0]}"; GROUP_ENABLED="${TSV_FIELDS[1]}"; GROUP_INTERVAL="${TSV_FIELDS[2]}"
  GROUP_API_TOKEN="${TSV_FIELDS[3]}"; GROUP_ZONE_ID="${TSV_FIELDS[4]}"; GROUP_TARGET_FQDN="${TSV_FIELDS[5]}"
  GROUP_TTL="${TSV_FIELDS[6]}"; GROUP_PROXIED="${TSV_FIELDS[7]}"; GROUP_MODE="${TSV_FIELDS[8]}"; GROUP_SOURCES_CSV="${TSV_FIELDS[9]}"
}

save_group_line_replace() {
  local old_group_name="$1" new_line="$2" tmp
  tmp="$(mktemp)" || return 1
  if ! awk -F '	' -v g="${old_group_name}" -v replacement="${new_line}" '
    BEGIN{done=0}
    /^#/ {print; next}
    NF==0 {next}
    $1==g && done==0 {print replacement; done=1; next}
    {print}
    END{if(done==0) print replacement}
  ' "${GROUPS_FILE}" > "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  save_groups_with_tmp "${tmp}"
}


build_group_line() {
  GROUP_SOURCES_CSV="$(normalize_sources_csv "${GROUP_SOURCES_CSV}")"
  printf '%s	%s	%s	%s	%s	%s	%s	%s	%s	%s' \
    "${GROUP_NAME}" "${GROUP_ENABLED}" "${GROUP_INTERVAL}" "${GROUP_API_TOKEN}" "${GROUP_ZONE_ID}" "${GROUP_TARGET_FQDN}" "${GROUP_TTL}" "${GROUP_PROXIED}" "${GROUP_MODE}" "${GROUP_SOURCES_CSV}"
}


valid_health_target() {
  local value="${1:-}"
  if [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    awk -F. 'NF==4{for(i=1;i<=4;i++) if($i!~/^[0-9]+$/ || $i<0 || $i>255) exit 1; exit 0}{exit 1}' <<< "${value}"
  else
    valid_domain "${value}"
  fi
}

get_failover_line_by_group() {
  local group="$1"
  awk -F '\t' -v g="${group}" '!/^#/ && $1==g{print; exit}' "${FAILOVER_FILE}" 2>/dev/null
}

load_failover_config_ui() {
  local group="$1" line
  line="$(get_failover_line_by_group "${group}")"
  [[ -n "${line}" ]] || return 1
  split_tsv_line "${line}"
  (( ${#TSV_FIELDS[@]} == 13 )) || return 1
  FO_GROUP="${TSV_FIELDS[0]}"; FO_ENABLED="${TSV_FIELDS[1]}"; FO_BACKUP_SOURCES="${TSV_FIELDS[2]}"
  FO_PRIMARY_TARGET="${TSV_FIELDS[3]}"; FO_BACKUP_TARGET="${TSV_FIELDS[4]}"; FO_CHECK_TYPE="${TSV_FIELDS[5]}"
  FO_PORT="${TSV_FIELDS[6]}"; FO_LOCATION="${TSV_FIELDS[7]}"; FO_STABLE_INTERVAL="${TSV_FIELDS[8]}"
  FO_FAST_INTERVAL="${TSV_FIELDS[9]}"; FO_PRIMARY_FAIL_THRESHOLD="${TSV_FIELDS[10]}"
  FO_BACKUP_SUCCESS_THRESHOLD="${TSV_FIELDS[11]}"; FO_PRIMARY_RECOVERY_THRESHOLD="${TSV_FIELDS[12]}"; FO_EXTRA=""
}

build_failover_line() {
  FO_BACKUP_SOURCES="$(normalize_sources_csv "${FO_BACKUP_SOURCES}")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "${FO_GROUP}" "${FO_ENABLED}" "${FO_BACKUP_SOURCES}" "${FO_PRIMARY_TARGET}" "${FO_BACKUP_TARGET}" "${FO_CHECK_TYPE}" "${FO_PORT}" "${FO_LOCATION}" \
    "${FO_STABLE_INTERVAL}" "${FO_FAST_INTERVAL}" "${FO_PRIMARY_FAIL_THRESHOLD}" "${FO_BACKUP_SUCCESS_THRESHOLD}" "${FO_PRIMARY_RECOVERY_THRESHOLD}"
}

save_failover_line_replace() {
  local old_group="$1" new_line="$2" tmp staged
  tmp="$(mktemp)" || return 1
  awk -F '\t' -v g="${old_group}" -v replacement="${new_line}" '
    BEGIN{done=0}
    /^#/ {print; next}
    NF==0 {next}
    $1==g && done==0 {print replacement; done=1; next}
    {print}
    END{if(done==0) print replacement}
  ' "${FAILOVER_FILE}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
  staged="$(mktemp "${BASE_DIR}/.failover.XXXXXX")" || { rm -f "${tmp}"; return 1; }
  cat "${tmp}" > "${staged}" && chmod 600 "${staged}" && mv -f "${staged}" "${FAILOVER_FILE}"
  local rc=$?
  rm -f "${tmp}" "${staged}" 2>/dev/null || true
  return "${rc}"
}

delete_failover_config_for_group() {
  local group="$1" tmp
  [[ -f "${FAILOVER_FILE}" ]] || return 0
  tmp="$(mktemp "${BASE_DIR}/.failover-delete.XXXXXX")" || return 1
  if ! awk -F '\t' -v g="${group}" '/^#/ || (NF>0 && $1!=g)' "${FAILOVER_FILE}" > "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  chmod 600 "${tmp}" && mv -f "${tmp}" "${FAILOVER_FILE}" || { rm -f "${tmp}"; return 1; }
}

remove_failover_state_for_group() {
  local group="$1" tmp
  [[ -f "${FAILOVER_STATE_FILE}" ]] || return 0
  tmp="$(mktemp "${VAR_DIR}/.failover-state-delete.XXXXXX")" || return 1
  if ! awk -F '\t' -v g="${group}" '$1!=g' "${FAILOVER_STATE_FILE}" > "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  chmod 600 "${tmp}" && mv -f "${tmp}" "${FAILOVER_STATE_FILE}" || { rm -f "${tmp}"; return 1; }
}

rename_failover_group() {
  local old="$1" new="$2" line tmp
  line="$(get_failover_line_by_group "${old}")"
  if [[ -n "${line}" ]]; then
    load_failover_config_ui "${old}" || return 1
    FO_GROUP="${new}"
    save_failover_line_replace "${old}" "$(build_failover_line)" || return 1
  fi
  if [[ -f "${FAILOVER_STATE_FILE}" ]]; then
    tmp="$(mktemp "${VAR_DIR}/.failover-state-rename.XXXXXX")" || return 1
    if ! awk -F '\t' -v old="${old}" -v new="${new}" 'BEGIN{OFS="\t"}{$1=($1==old?new:$1);print}' "${FAILOVER_STATE_FILE}" > "${tmp}"; then
      rm -f "${tmp}"
      return 1
    fi
    chmod 600 "${tmp}" && mv -f "${tmp}" "${FAILOVER_STATE_FILE}" || { rm -f "${tmp}"; return 1; }
  fi
}

mark_group_sync_due_ui() {
  local group="$1" file tmp
  for file in "${RUNSTATE_FILE}" "${RECONCILE_FILE}"; do
    [[ -f "${file}" ]] || continue
    tmp="$(mktemp "${VAR_DIR}/.due.XXXXXX")" || return 1
    if ! awk -F '\t' -v g="${group}" '$1!=g' "${file}" > "${tmp}"; then
      rm -f "${tmp}"
      return 1
    fi
    chmod 600 "${tmp}" || { rm -f "${tmp}"; return 1; }
    mv -f "${tmp}" "${file}" || { rm -f "${tmp}"; return 1; }
  done
}

load_failover_state_ui() {
  local group="$1" line
  line="$(awk -F '\t' -v g="${group}" '$1==g{v=$0} END{print v}' "${FAILOVER_STATE_FILE}" 2>/dev/null)"
  if [[ -n "${line}" ]]; then
    split_tsv_line "${line}"
    FS_GROUP="${TSV_FIELDS[0]:-}"; FS_ACTIVE_ROLE="${TSV_FIELDS[1]:-}"; FS_PHASE="${TSV_FIELDS[2]:-}"
    FS_PRIMARY_FAILS="${TSV_FIELDS[3]:-0}"; FS_BACKUP_SUCCESSES="${TSV_FIELDS[4]:-0}"; FS_PRIMARY_SUCCESSES="${TSV_FIELDS[5]:-0}"
    FS_LAST_PRIMARY_CHECK="${TSV_FIELDS[6]:-0}"; FS_LAST_BACKUP_CHECK="${TSV_FIELDS[7]:-0}"; FS_LAST_RESULT="${TSV_FIELDS[8]:-STATE_FIELDS_INVALID}"
    FS_LAST_MEASUREMENT_ID="${TSV_FIELDS[9]:-}"; FS_LAST_SWITCH="${TSV_FIELDS[10]:-0}"; FS_UPDATED="${TSV_FIELDS[11]:-0}"; FS_EXTRA=""
    (( ${#TSV_FIELDS[@]} == 12 )) || FS_EXTRA="invalid"
  else
    FS_GROUP="${group}"; FS_ACTIVE_ROLE="PRIMARY"; FS_PHASE="PRIMARY_STABLE"
    FS_PRIMARY_FAILS=0; FS_BACKUP_SUCCESSES=0; FS_PRIMARY_SUCCESSES=0
    FS_LAST_PRIMARY_CHECK=0; FS_LAST_BACKUP_CHECK=0; FS_LAST_RESULT="INIT"
    FS_LAST_MEASUREMENT_ID=""; FS_LAST_SWITCH=0; FS_UPDATED=0; FS_EXTRA=""
  fi
  [[ "${FS_UPDATED:-0}" =~ ^[0-9]+$ ]] || FS_UPDATED=0
  [[ -z "${FS_EXTRA:-}" ]] || FS_LAST_RESULT="STATE_FIELDS_INVALID"
}

save_failover_state_ui() {
  local tmp
  tmp="$(mktemp "${VAR_DIR}/.failover-state-ui.XXXXXX")" || return 1
  if ! awk -F '\t' -v g="${FS_GROUP}" '$1!=g' "${FAILOVER_STATE_FILE}" 2>/dev/null > "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${FS_GROUP}" "${FS_ACTIVE_ROLE}" "${FS_PHASE}" "${FS_PRIMARY_FAILS}" "${FS_BACKUP_SUCCESSES}" "${FS_PRIMARY_SUCCESSES}" \
    "${FS_LAST_PRIMARY_CHECK}" "${FS_LAST_BACKUP_CHECK}" "${FS_LAST_RESULT}" "${FS_LAST_MEASUREMENT_ID}" "${FS_LAST_SWITCH}" "$(date +%s)" >> "${tmp}"
  chmod 600 "${tmp}" && mv -f "${tmp}" "${FAILOVER_STATE_FILE}" || { rm -f "${tmp}"; return 1; }
}

reset_failover_counters_preserve_role() {
  local group="$1"
  load_failover_state_ui "${group}"
  if [[ "${FS_ACTIVE_ROLE}" == "BACKUP" ]]; then FS_PHASE="BACKUP_FAST"; else FS_ACTIVE_ROLE="PRIMARY"; FS_PHASE="PRIMARY_STABLE"; fi
  FS_PRIMARY_FAILS=0; FS_BACKUP_SUCCESSES=0; FS_PRIMARY_SUCCESSES=0
  FS_LAST_PRIMARY_CHECK=0; FS_LAST_BACKUP_CHECK=0; FS_LAST_RESULT="CONFIG_CHANGED"; FS_LAST_MEASUREMENT_ID=""
  save_failover_state_ui || return 1
  mark_group_sync_due_ui "${group}"
}

get_group_line_by_name() {
  local group="$1"
  awk -F '\t' -v g="${group}" '!/^#/ && $1==g{print; exit}' "${GROUPS_FILE}"
}

get_group_primary_sources() {
  local line
  line="$(get_group_line_by_name "$1")"
  [[ -n "${line}" ]] || return 1
  cut -f10 <<< "${line}"
}

get_group_enabled_ui() {
  local line
  line="$(get_group_line_by_name "$1")"
  [[ -n "${line}" ]] || return 1
  cut -f2 <<< "${line}"
}

activate_failover_scheduler() {
  local group="$1" base_enabled timer_state last_check last_display
  base_enabled="$(get_group_enabled_ui "${group}" 2>/dev/null || true)"
  if [[ "${base_enabled}" != "true" ]]; then
    echo "⚠️  组 ${group} 的主组状态为 ${base_enabled:-不存在}；故障转移配置已保存，但主组启用前不会自动检测。"
    return 2
  fi

  if ! systemctl daemon-reload; then
    echo "❌ systemd daemon-reload 失败；故障转移配置已保存，但自动调度未确认启动。"
    return 1
  fi
  systemctl reset-failed "${SERVICE_NAME}" "${TIMER_NAME}" 2>/dev/null || true
  if ! systemctl enable --now "${TIMER_NAME}"; then
    echo "❌ ${TIMER_NAME} 启用失败；请查看菜单22状态或运行菜单25一键修复。"
    return 1
  fi
  timer_state="$(systemctl is-active "${TIMER_NAME}" 2>/dev/null || true)"
  if [[ "${timer_state}" != "active" ]]; then
    echo "❌ ${TIMER_NAME} 当前状态为 ${timer_state:-unknown}，自动检测尚未启动。"
    return 1
  fi

  # 配置已将上次检查时间归零；立即运行一次 AUTO，避免用户等待下一个 timer 周期且无法判断是否启动。
  if ! systemctl start "${SERVICE_NAME}"; then
    echo "❌ ${SERVICE_NAME} 首次自动检测启动失败；请查看菜单19日志和菜单24自检。"
    return 1
  fi

  load_failover_state_ui "${group}"
  last_check="${FS_LAST_PRIMARY_CHECK:-0}"
  [[ "${last_check}" =~ ^[0-9]+$ ]] || last_check=0
  if [[ "${FS_LAST_BACKUP_CHECK:-0}" =~ ^[0-9]+$ ]] && (( FS_LAST_BACKUP_CHECK > last_check )); then
    last_check="${FS_LAST_BACKUP_CHECK}"
  fi
  if [[ "${last_check}" =~ ^[0-9]+$ ]] && (( last_check > 0 )); then
    last_display="$(date -d "@${last_check}" '+%F %T' 2>/dev/null || printf '%s' "${last_check}")"
    echo "✅ Globalping 自动检测已执行：组=${group}，时间=${last_display}，结果=${FS_LAST_RESULT:-unknown}"
    [[ "${FS_LAST_RESULT:-}" != *_UNKNOWN ]] || echo "⚠️  检测已启动但结果为 UNKNOWN；请查看故障转移历史了解 API 或探针错误。"
    return 0
  fi

  echo "⚠️  timer 已启动，但组 ${group} 尚未写入首次 Globalping 检测状态；请运行菜单24自检并查看菜单19日志。"
  return 3
}

first_source_from_csv() {
  normalize_sources_csv "$1" | cut -d, -f1
}

csv_overlap_value() {
  local a="$1" b="$2" item
  parse_sources_to_array "${a}"
  local first=("${SOURCES_ARRAY[@]}")
  parse_sources_to_array "${b}"
  local second=("${SOURCES_ARRAY[@]}")
  for item in "${first[@]}"; do
    printf '%s\n' "${second[@]}" | grep -Fxiq "${item}" && { printf '%s\n' "${item}"; return 0; }
  done
  return 1
}

validate_failover_ui() {
  local primary_sources="$1" overlap
  [[ -z "${FO_EXTRA:-}" ]] || { echo "failover.tsv 字段数量超过13"; return 1; }
  [[ "${FO_ENABLED}" == "true" || "${FO_ENABLED}" == "false" ]] || { echo "enabled 必须为 true/false"; return 1; }
  validate_sources_csv "${FO_BACKUP_SOURCES}" || { echo "BACKUP 源域名必须为1~20个有效域名"; return 1; }
  overlap="$(csv_overlap_value "${primary_sources}" "${FO_BACKUP_SOURCES}" || true)"
  [[ -z "${overlap}" ]] || { echo "PRIMARY 与 BACKUP 不能包含相同源域名：${overlap}"; return 1; }
  valid_health_target "${FO_PRIMARY_TARGET}" || { echo "PRIMARY健康检测目标格式错误"; return 1; }
  valid_health_target "${FO_BACKUP_TARGET}" || { echo "BACKUP健康检测目标格式错误"; return 1; }
  [[ "${FO_CHECK_TYPE}" == "PING_ICMP" || "${FO_CHECK_TYPE}" == "PING_TCP" ]] || { echo "检测类型错误"; return 1; }
  if [[ "${FO_CHECK_TYPE}" == "PING_TCP" ]]; then
    [[ "${FO_PORT}" =~ ^[0-9]+$ && "${FO_PORT}" -ge 1 && "${FO_PORT}" -le 65535 ]] || { echo "TCP端口必须为1~65535"; return 1; }
  else
    FO_PORT=0
  fi
  [[ -n "${FO_LOCATION}" && "${FO_LOCATION}" != *$'\t'* && "${FO_LOCATION}" != *$'\r'* && "${FO_LOCATION}" != *$'\n'* && "${FO_LOCATION}" != *\\* ]] || {
    echo "Globalping位置不能为空或包含 TAB、换行、回车或反斜杠"
    return 1
  }
  case "${FO_LOCATION,,}" in china|china+*|cn|cn+*) ;; *) echo "本功能仅允许中国区位置：China、CN 或 CN+标签"; return 1 ;; esac
  [[ "${FO_STABLE_INTERVAL}" =~ ^[0-9]+$ && "${FO_FAST_INTERVAL}" =~ ^[0-9]+$ ]] || { echo "检测周期必须为整数"; return 1; }
  [[ "${FO_STABLE_INTERVAL}" -ge 60 && "${FO_FAST_INTERVAL}" -ge 60 && "${FO_STABLE_INTERVAL}" -ge "${FO_FAST_INTERVAL}" ]] || { echo "稳定周期需>=快速周期，且两者均>=60秒"; return 1; }
  [[ "${FO_PRIMARY_FAIL_THRESHOLD}" =~ ^[0-9]+$ && "${FO_BACKUP_SUCCESS_THRESHOLD}" =~ ^[0-9]+$ && "${FO_PRIMARY_RECOVERY_THRESHOLD}" =~ ^[0-9]+$ ]] || { echo "阈值必须为整数"; return 1; }
  [[ "${FO_PRIMARY_FAIL_THRESHOLD}" -ge 1 && "${FO_BACKUP_SUCCESS_THRESHOLD}" -ge 1 && "${FO_PRIMARY_RECOVERY_THRESHOLD}" -ge 1 ]] || { echo "阈值必须>=1"; return 1; }
}

prompt_stable_interval() {
  local current="${1:-300}" preserve="${2:-0}" choice custom
  echo "请选择稳定检测周期："
  echo "1. 🕔 300 秒（5分钟，推荐）"
  echo "2. 🕙 600 秒（10分钟）"
  echo "3. ✍️  自定义（>=60秒）"
  [[ "${preserve}" -eq 1 ]] && echo "4. ➖ 保持当前：${current} 秒（回车默认）"
  read -rp "请选择 [1-4]: " choice || return 1
  case "${choice}" in
    "") if [[ "${preserve}" -eq 1 ]]; then SELECTED_STABLE_INTERVAL="${current}"; else SELECTED_STABLE_INTERVAL=300; fi ;;
    1) SELECTED_STABLE_INTERVAL=300 ;;
    2) SELECTED_STABLE_INTERVAL=600 ;;
    3) read -rp "请输入秒数: " custom || return 1; [[ "${custom}" =~ ^[0-9]+$ && "${custom}" -ge 60 ]] || { echo "必须是>=60的整数"; return 1; }; SELECTED_STABLE_INTERVAL="${custom}" ;;
    4) [[ "${preserve}" -eq 1 ]] || { echo "无效选择"; return 1; }; SELECTED_STABLE_INTERVAL="${current}" ;;
    *) echo "无效选择"; return 1 ;;
  esac
}

prompt_fast_interval() {
  local current="${1:-60}" preserve="${2:-0}" choice custom
  echo "请选择快速检测周期："
  echo "1. ⚡ 60 秒（1分钟，推荐）"
  echo "2. 🚀 120 秒（2分钟）"
  echo "3. ✍️  自定义（>=60秒）"
  [[ "${preserve}" -eq 1 ]] && echo "4. ➖ 保持当前：${current} 秒（回车默认）"
  read -rp "请选择 [1-4]: " choice || return 1
  case "${choice}" in
    "") if [[ "${preserve}" -eq 1 ]]; then SELECTED_FAST_INTERVAL="${current}"; else SELECTED_FAST_INTERVAL=60; fi ;;
    1) SELECTED_FAST_INTERVAL=60 ;;
    2) SELECTED_FAST_INTERVAL=120 ;;
    3) read -rp "请输入秒数: " custom || return 1; [[ "${custom}" =~ ^[0-9]+$ && "${custom}" -ge 60 ]] || { echo "必须是>=60的整数"; return 1; }; SELECTED_FAST_INTERVAL="${custom}" ;;
    4) [[ "${preserve}" -eq 1 ]] || { echo "无效选择"; return 1; }; SELECTED_FAST_INTERVAL="${current}" ;;
    *) echo "无效选择"; return 1 ;;
  esac
}

list_failover_status() {
  local timer_state
  timer_state="$(systemctl is-active "${TIMER_NAME}" 2>/dev/null || true)"
  echo "自动调度器 ${TIMER_NAME}: ${timer_state:-unknown}"
  local row group enabled found=0
  local base_enabled last_check last_display
  while IFS= read -r row || [[ -n "${row}" ]]; do
    [[ -z "${row}" || "${row}" =~ ^# ]] && continue
    found=1
    split_tsv_line "${row}"
    if (( ${#TSV_FIELDS[@]} != 13 )); then
      printf '\n[配置损坏]\n  failover.tsv 字段应为13，实际为%d；请运行菜单24自检。\n' "${#TSV_FIELDS[@]}"
      continue
    fi
    group="${TSV_FIELDS[0]}"; enabled="${TSV_FIELDS[1]}"
    base_enabled="$(get_group_enabled_ui "${group}" 2>/dev/null || true)"
    [[ -n "${base_enabled}" ]] || base_enabled="missing"
    load_failover_state_ui "${group}"
    last_check="${FS_LAST_PRIMARY_CHECK:-0}"
    [[ "${last_check}" =~ ^[0-9]+$ ]] || last_check=0
    if [[ "${FS_LAST_BACKUP_CHECK:-0}" =~ ^[0-9]+$ ]] && (( FS_LAST_BACKUP_CHECK > last_check )); then last_check="${FS_LAST_BACKUP_CHECK}"; fi
    if (( last_check > 0 )); then last_display="$(date -d "@${last_check}" '+%F %T' 2>/dev/null || printf '%s' "${last_check}")"; else last_display="从未"; fi
    printf '\n[%s]\n' "${group}"
    printf '  主组：%s  故障转移：%s  活动线路：%s\n' "${base_enabled}" "${enabled}" "${FS_ACTIVE_ROLE}"
    printf '  阶段：%s  P失败：%s  B成功：%s  P恢复：%s\n' "${FS_PHASE}" "${FS_PRIMARY_FAILS}" "${FS_BACKUP_SUCCESSES}" "${FS_PRIMARY_SUCCESSES}"
    printf '  最后检测：%s  结果：%s\n' "${last_display}" "${FS_LAST_RESULT}"
  done < "${FAILOVER_FILE}"
  [[ "${found}" -eq 1 ]] || echo "当前没有配置 Globalping 故障转移的组。现有 groups.tsv 组仍按 PRIMARY 正常同步。"
  echo "说明：只有 主组=true 且 故转=true 的组会执行自动 Globalping 检测。"
}

configure_failover_group() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}" || { echo "该组配置字段数量不是10，请运行菜单24自检"; return 1; }
  local primary_sources="${GROUP_SOURCES_CSV}" existing=0 input first_primary first_backup choice
  first_primary="$(first_source_from_csv "${primary_sources}")"
  if load_failover_config_ui "${GROUP_NAME}"; then existing=1; else
    FO_GROUP="${GROUP_NAME}"; FO_ENABLED=true; FO_BACKUP_SOURCES=""; FO_PRIMARY_TARGET="${first_primary}"; FO_BACKUP_TARGET=""
    FO_CHECK_TYPE="PING_ICMP"; FO_PORT=0; FO_LOCATION="China"; FO_STABLE_INTERVAL=300; FO_FAST_INTERVAL=60
    FO_PRIMARY_FAIL_THRESHOLD=3; FO_BACKUP_SUCCESS_THRESHOLD=2; FO_PRIMARY_RECOVERY_THRESHOLD=2; FO_EXTRA=""
  fi

  echo "PRIMARY 源域名（兼容现有配置，不会改写）：${primary_sources}"
  [[ "${existing}" -eq 1 ]] && echo "当前 BACKUP：${FO_BACKUP_SOURCES}"
  read -rp "请输入 BACKUP 源域名（英文逗号分隔，1~20个；回车保持现有）: " input || return
  [[ -z "${input}" && "${existing}" -eq 1 ]] || FO_BACKUP_SOURCES="$(normalize_sources_csv "${input}")"
  validate_sources_csv "${FO_BACKUP_SOURCES}" || { echo "BACKUP 源域名列表无效"; return; }
  first_backup="$(first_source_from_csv "${FO_BACKUP_SOURCES}")"

  read -rp "PRIMARY 健康检测目标（回车使用 ${FO_PRIMARY_TARGET:-${first_primary}}）: " input || return
  [[ -n "${input}" ]] && FO_PRIMARY_TARGET="${input}"; [[ -n "${FO_PRIMARY_TARGET}" ]] || FO_PRIMARY_TARGET="${first_primary}"
  read -rp "BACKUP 健康检测目标（回车使用 ${FO_BACKUP_TARGET:-${first_backup}}）: " input || return
  [[ -n "${input}" ]] && FO_BACKUP_TARGET="${input}"; [[ -n "${FO_BACKUP_TARGET}" ]] || FO_BACKUP_TARGET="${first_backup}"

  echo "请选择 Globalping 检测方式："
  echo "1. 📶 PING_ICMP（ICMP Ping）"
  echo "2. 🔌 PING_TCP（TCP Ping，需要端口）"
  echo "3. ➖ 保持当前：${FO_CHECK_TYPE}"
  read -rp "请选择 [1-3]: " choice || return
  case "${choice}" in
    1) FO_CHECK_TYPE="PING_ICMP"; FO_PORT=0 ;;
    2) FO_CHECK_TYPE="PING_TCP"; read -rp "请输入TCP端口: " FO_PORT ;;
    3|"") ;;
    *) echo "无效选择"; return ;;
  esac
  read -rp "Globalping位置（回车保持 ${FO_LOCATION:-China}）: " input || return
  [[ -n "${input}" ]] && FO_LOCATION="${input}"; [[ -n "${FO_LOCATION}" ]] || FO_LOCATION="China"
  prompt_stable_interval "${FO_STABLE_INTERVAL}" "${existing}" || return; FO_STABLE_INTERVAL="${SELECTED_STABLE_INTERVAL}"
  prompt_fast_interval "${FO_FAST_INTERVAL}" "${existing}" || return; FO_FAST_INTERVAL="${SELECTED_FAST_INTERVAL}"

  echo "阈值设置："
  echo "1. ✅ 使用推荐值：PRIMARY失败3次 / BACKUP成功2次 / PRIMARY恢复2次"
  echo "2. ✍️  自定义"
  [[ "${existing}" -eq 1 ]] && echo "3. ➖ 保持当前：${FO_PRIMARY_FAIL_THRESHOLD}/${FO_BACKUP_SUCCESS_THRESHOLD}/${FO_PRIMARY_RECOVERY_THRESHOLD}（回车默认）"
  read -rp "请选择 [1-3]: " choice || return
  case "${choice}" in
    "")
      if [[ "${existing}" -ne 1 ]]; then
        FO_PRIMARY_FAIL_THRESHOLD=3; FO_BACKUP_SUCCESS_THRESHOLD=2; FO_PRIMARY_RECOVERY_THRESHOLD=2
      fi
      ;;
    1) FO_PRIMARY_FAIL_THRESHOLD=3; FO_BACKUP_SUCCESS_THRESHOLD=2; FO_PRIMARY_RECOVERY_THRESHOLD=2 ;;
    2)
      read -rp "PRIMARY连续失败多少次切BACKUP: " FO_PRIMARY_FAIL_THRESHOLD || return
      read -rp "BACKUP连续成功多少次视为稳定: " FO_BACKUP_SUCCESS_THRESHOLD || return
      read -rp "PRIMARY连续成功多少次切回: " FO_PRIMARY_RECOVERY_THRESHOLD || return
      ;;
    3) [[ "${existing}" -eq 1 ]] || { echo "无效选择"; return; } ;;
    *) echo "无效选择"; return ;;
  esac
  FO_GROUP="${GROUP_NAME}"
  # 新建配置默认启用；更新既有配置时保留原来的启用/禁用状态，避免“只改参数却意外启用”。
  [[ "${existing}" -eq 1 ]] || FO_ENABLED=true
  validate_failover_ui "${primary_sources}" || return
  save_failover_line_replace "${GROUP_NAME}" "$(build_failover_line)" || { echo "保存故障转移配置失败"; return; }
  reset_failover_counters_preserve_role "${GROUP_NAME}" || {
    echo "故障转移配置已保存，但状态重置失败；请运行菜单24自检。"
    return 1
  }
  echo "已保存组 ${GROUP_NAME} 的 Globalping 故障转移配置（enabled=${FO_ENABLED}）。现有源域名保持为 PRIMARY。"
  if [[ "${FO_ENABLED}" == "true" ]]; then
    activate_failover_scheduler "${GROUP_NAME}" || return $?
  else
    echo "当前故障转移配置保持禁用，不会消耗 Globalping 用量。"
  fi
}

manage_backup_sources() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}" || { echo "该组配置字段数量不是10，请运行菜单24自检"; return 1; }
  load_failover_config_ui "${GROUP_NAME}" || { echo "该组尚未配置故障转移"; return; }
  parse_sources_to_array "${FO_BACKUP_SOURCES}"
  local choice input idx
  while true; do
    clear 2>/dev/null || true; line; echo "🛟 BACKUP 源域名管理 - ${GROUP_NAME}"; line
    local i=0; for s in "${SOURCES_ARRAY[@]}"; do i=$((i+1)); printf '%2d. %s\n' "${i}" "${s}"; done
    echo "1. ➕ 添加单个"; echo "2. 🗑️ 删除单个"; echo "3. 📥 批量覆盖导入（英文逗号）"; echo "4. 📤 导出"; echo "0. ↩️ 返回"
    read -rp "请选择: " choice || return
    case "${choice}" in
      1)
        (( ${#SOURCES_ARRAY[@]} < 20 )) || { echo "最多20个"; pause_wait; continue; }
        read -rp "新BACKUP源域名: " input || return
        valid_domain "${input}" || { echo "域名格式错误"; pause_wait; continue; }
        printf '%s\n' "${SOURCES_ARRAY[@]}" | grep -Fxiq "${input}" || SOURCES_ARRAY+=("${input}")
        ;;
      2)
        (( ${#SOURCES_ARRAY[@]} > 1 )) || { echo "至少保留1个"; pause_wait; continue; }
        read -rp "删除序号: " idx || return
        [[ "${idx}" =~ ^[0-9]+$ && "${idx}" -ge 1 && "${idx}" -le "${#SOURCES_ARRAY[@]}" ]] || { echo "序号无效"; pause_wait; continue; }
        unset 'SOURCES_ARRAY[idx-1]'; SOURCES_ARRAY=("${SOURCES_ARRAY[@]}")
        ;;
      3)
        read -rp "BACKUP源域名列表: " input || return
        input="$(normalize_sources_csv "${input}")"; validate_sources_csv "${input}" || { echo "列表无效"; pause_wait; continue; }
        parse_sources_to_array "${input}"
        ;;
      4) (IFS=,; echo "${SOURCES_ARRAY[*]}"); pause_wait; continue ;;
      0) return ;;
      *) echo "无效选择"; pause_wait; continue ;;
    esac
    FO_BACKUP_SOURCES="$(IFS=,; echo "${SOURCES_ARRAY[*]}")"
    local primary_sources; primary_sources="$(get_group_primary_sources "${GROUP_NAME}")"
    [[ -n "${FO_BACKUP_TARGET}" ]] || FO_BACKUP_TARGET="$(first_source_from_csv "${FO_BACKUP_SOURCES}")"
    validate_failover_ui "${primary_sources}" || { echo "保存前校验失败"; pause_wait; continue; }
    save_failover_line_replace "${GROUP_NAME}" "$(build_failover_line)" || { echo "保存失败"; pause_wait; continue; }
    reset_failover_counters_preserve_role "${GROUP_NAME}" || { echo "配置已保存，但状态重置失败"; pause_wait; return 1; }
  done
}

toggle_failover_enabled() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}" || { echo "该组配置字段数量不是10，请运行菜单24自检"; return 1; }
  load_failover_config_ui "${GROUP_NAME}" || { echo "该组尚未配置故障转移，请先配置"; return; }

  local primary_sources="${GROUP_SOURCES_CSV}" rc=0 new_state
  if [[ "${FO_ENABLED}" == "true" ]]; then
    new_state="false"
  else
    new_state="true"
  fi
  FO_ENABLED="${new_state}"
  validate_failover_ui "${primary_sources}" || return
  save_failover_line_replace "${GROUP_NAME}" "$(build_failover_line)" || { echo "保存启用状态失败"; return; }

  # 无论启用还是禁用，都从 PRIMARY_STABLE 重新开始，并立即把目标域名核对到 PRIMARY。
  # 这样不会因之前停留在 BACKUP 状态而出现“已启用但仍走 BACKUP”的联动错误。
  /usr/local/bin/cf-dns-sync.sh FORESET "${GROUP_NAME}" || rc=$?
  if [[ "${new_state}" == "true" ]]; then
    if [[ "${rc}" -eq 0 ]]; then
      echo "故障转移已启用，已重置为 PRIMARY 稳定状态并完成一次同步。"
    else
      echo "故障转移已启用并重置为 PRIMARY，但立即同步失败（退出码=${rc}）；定时任务会继续重试。"
    fi
    activate_failover_scheduler "${GROUP_NAME}" || return $?
  else
    if [[ "${rc}" -eq 0 ]]; then
      echo "故障转移已禁用，已回到 PRIMARY 并完成一次同步。"
    else
      echo "故障转移已禁用并重置为 PRIMARY，但立即同步失败（退出码=${rc}）；定时任务会继续按 PRIMARY 重试。"
    fi
  fi
}

test_failover_role() {
  local role="$1" rc=0
  echo; select_group || { echo "序号无效"; return; }
  /usr/local/bin/cf-dns-sync.sh GPTEST "${CHOSEN_GROUP_NAME}" "${role}" || rc=$?
  case "${rc}" in 0) echo "✅ ${role} 检测成功" ;; 1) echo "❌ ${role} 检测失败" ;; 2) echo "⚠️ ${role} 检测结果未知，未计入故障次数" ;; 75) echo "同步任务占用锁，本次未测试" ;; *) echo "测试执行异常，退出码=${rc}" ;; esac
}

manual_failover_switch_ui() {
  local role="$1" rc=0
  echo; select_group || { echo "序号无效"; return; }
  /usr/local/bin/cf-dns-sync.sh FOSWITCH "${CHOSEN_GROUP_NAME}" "${role}" || rc=$?
  [[ "${rc}" -eq 0 ]] && echo "已人工切换到 ${role} 并立即强制同步" || echo "切换失败，退出码=${rc}"
}

reset_failover_state_ui_action() {
  local rc=0
  echo; select_group || { echo "序号无效"; return; }
  /usr/local/bin/cf-dns-sync.sh FORESET "${CHOSEN_GROUP_NAME}" || rc=$?
  [[ "${rc}" -eq 0 ]] && echo "已重置为PRIMARY稳定状态并立即同步" || echo "重置失败，退出码=${rc}"
}

safe_settings_value() {
  local value="${1:-}"
  [[ "${value}" != *$'\t'* && "${value}" != *$'\r'* && "${value}" != *$'\n'* ]]
}

globalping_settings_menu() {
  local choice value old_token old_budget old_timeout old_poll
  while true; do
    clear 2>/dev/null || true; line; echo "🌏 Globalping 全局设置"; line
    echo "API Token: $([[ -n "${GLOBALPING_API_TOKEN}" ]] && echo 已设置 || echo 未设置/匿名)"
    echo "本机安全预算: ${GLOBALPING_MAX_TESTS_PER_HOUR} tests/h"
    echo "测量超时: ${GLOBALPING_MEASUREMENT_TIMEOUT_SEC}s；最长等待: ${GLOBALPING_POLL_MAX_SEC}s"
    echo "1. 🔑 设置/替换 API Token"; echo "2. 🧹 清空 Token（匿名）"; echo "3. 📊 设置每小时本机安全预算"; echo "4. ⏳ 设置测量超时"; echo "0. ↩️ 返回"
    read -rp "请选择: " choice || return
    old_token="${GLOBALPING_API_TOKEN}"
    old_budget="${GLOBALPING_MAX_TESTS_PER_HOUR}"
    old_timeout="${GLOBALPING_MEASUREMENT_TIMEOUT_SEC}"
    old_poll="${GLOBALPING_POLL_MAX_SEC}"
    case "${choice}" in
      1)
        read -rsp "Globalping API Token: " value || return
        echo
        [[ -n "${value}" ]] || { echo "Token不能为空"; pause_wait; continue; }
        safe_settings_value "${value}" || { echo "Token包含不能安全写入settings.conf的字符"; pause_wait; continue; }
        GLOBALPING_API_TOKEN="${value}"
        ;;
      2) GLOBALPING_API_TOKEN="" ;;
      3) read -rp "请输入 tests/h（匿名建议不超过240）: " value || return; [[ "${value}" =~ ^[0-9]+$ && "${value}" -ge 1 ]] || { echo "无效数字"; pause_wait; continue; }; GLOBALPING_MAX_TESTS_PER_HOUR="${value}" ;;
      4)
        read -rp "测量timeout秒数（5~30）: " value || return
        [[ "${value}" =~ ^[0-9]+$ && "${value}" -ge 5 && "${value}" -le 30 ]] || { echo "无效数字"; pause_wait; continue; }; GLOBALPING_MEASUREMENT_TIMEOUT_SEC="${value}"
        GLOBALPING_POLL_MAX_SEC=$((value+13)); (( GLOBALPING_POLL_MAX_SEC > 60 )) && GLOBALPING_POLL_MAX_SEC=60
        ;;
      0) return ;;
      *) echo "无效选择"; pause_wait; continue ;;
    esac
    if save_settings; then
      echo "已保存"
    else
      GLOBALPING_API_TOKEN="${old_token}"
      GLOBALPING_MAX_TESTS_PER_HOUR="${old_budget}"
      GLOBALPING_MEASUREMENT_TIMEOUT_SEC="${old_timeout}"
      GLOBALPING_POLL_MAX_SEC="${old_poll}"
      echo "保存失败，原配置保持不变"
    fi
    pause_wait
  done
}

show_globalping_limits() {
  local -a args=(-sS --connect-timeout 10 --max-time 30 -H 'Accept: application/json' -H "User-Agent: cfdns/${APP_VERSION}")
  [[ -n "${GLOBALPING_API_TOKEN}" ]] && args+=(-H "Authorization: Bearer ${GLOBALPING_API_TOKEN}")
  local now cutoff count invalid local_remaining timer_state usage_summary usage_read_error=0
  local configured=0 failover_enabled=0 runnable=0 parent_disabled=0 malformed_config=0
  local row group fo_enabled base_enabled latest_check=0 group_last latest_group="" latest_result=""
  local body resp rc http_code remote_limit remote_remaining remote_reset remote_type remote_used error_detail

  now="$(date +%s)"; cutoff=$((now-3600))
  count=0; invalid=0
  if [[ -f "${GLOBALPING_USAGE_FILE}" ]]; then
    if usage_summary="$(awk -v c="${cutoff}" '
      NF == 1 && $1 ~ /^[0-9]+$/ {if ($1 >= c) n++; next}
      NF {bad++}
      END {print n+0, bad+0}
    ' "${GLOBALPING_USAGE_FILE}" 2>/dev/null)"; then
      read -r count invalid <<< "${usage_summary}"
    else
      usage_read_error=1
    fi
  fi
  [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  [[ "${invalid}" =~ ^[0-9]+$ ]] || invalid=0
  local_remaining=$((GLOBALPING_MAX_TESTS_PER_HOUR-count)); (( local_remaining >= 0 )) || local_remaining=0

  timer_state="$(systemctl is-active "${TIMER_NAME}" 2>/dev/null || true)"
  while IFS= read -r row || [[ -n "${row}" ]]; do
    [[ -z "${row}" || "${row}" =~ ^# ]] && continue
    configured=$((configured+1))
    split_tsv_line "${row}"
    if (( ${#TSV_FIELDS[@]} != 13 )); then malformed_config=$((malformed_config+1)); continue; fi
    group="${TSV_FIELDS[0]}"; fo_enabled="${TSV_FIELDS[1]}"
    [[ "${fo_enabled}" == "true" ]] || continue
    failover_enabled=$((failover_enabled+1))
    base_enabled="$(get_group_enabled_ui "${group}" 2>/dev/null || true)"
    if [[ "${base_enabled}" != "true" ]]; then parent_disabled=$((parent_disabled+1)); continue; fi
    runnable=$((runnable+1))
    load_failover_state_ui "${group}"
    group_last="${FS_LAST_PRIMARY_CHECK:-0}"
    [[ "${group_last}" =~ ^[0-9]+$ ]] || group_last=0
    if [[ "${FS_LAST_BACKUP_CHECK:-0}" =~ ^[0-9]+$ ]] && (( FS_LAST_BACKUP_CHECK > group_last )); then group_last="${FS_LAST_BACKUP_CHECK}"; fi
    if (( group_last > latest_check )); then latest_check="${group_last}"; latest_group="${group}"; latest_result="${FS_LAST_RESULT:-unknown}"; fi
  done < "${FAILOVER_FILE}"

  line
  echo "📈 Globalping 用量与自动调度诊断"
  line
  if [[ "${usage_read_error}" -eq 0 ]]; then
    echo "本机滑动1小时已记录 tests：${count}/${GLOBALPING_MAX_TESTS_PER_HOUR}（剩余安全预算 ${local_remaining}）"
  else
    echo "本机滑动1小时已记录 tests：无法读取（不会误报为 0）"
  fi
  echo "自动调度器：${TIMER_NAME}=${timer_state:-unknown}"
  echo "故障转移配置：总数=${configured}，自身启用=${failover_enabled}，主组同时启用=${runnable}，主组禁用/缺失=${parent_disabled}"
  (( malformed_config == 0 )) || echo "⚠️  另有 ${malformed_config} 条故障转移配置字段损坏，未纳入启用统计；请运行菜单24自检。"
  if (( latest_check > 0 )); then
    echo "最近自动检测：$(date -d "@${latest_check}" '+%F %T' 2>/dev/null || printf '%s' "${latest_check}")，组=${latest_group}，结果=${latest_result}"
  else
    echo "最近自动检测：尚无状态记录"
  fi
  if (( invalid > 0 )); then
    echo "⚠️  本机用量文件含 ${invalid} 条非法记录，新测量已暂停以防超额。"
    echo "请先备份 ${GLOBALPING_USAGE_FILE}，确认最近1小时用量后人工修正；菜单25不会自动清空，以免低估额度。"
  fi

  if (( count == 0 && usage_read_error == 0 )); then
    echo "0 次诊断："
    (( configured > 0 )) || echo "- 尚未配置任何故障转移组。"
    (( configured == 0 || failover_enabled > 0 )) || echo "- 所有故障转移配置均为禁用。"
    (( parent_disabled == 0 )) || echo "- 有 ${parent_disabled} 个故障转移配置的主组被禁用或已不存在。"
    [[ "${timer_state}" == "active" ]] || echo "- timer 未处于 active，自动 Globalping 检测不会运行。"
    if (( runnable > 0 && latest_check == 0 )); then echo "- 存在可运行组但从未写入检测状态；请运行菜单24自检并查看菜单19日志。"; fi
    if (( latest_check >= cutoff )) && [[ "${latest_result}" == *_UNKNOWN ]]; then echo "- 最近调度已执行但结果为 UNKNOWN；创建请求可能被 API 拒绝，请查看菜单13故障转移历史。"; fi
    if (( latest_check > 0 && latest_check < cutoff )); then echo "- 最近一次检测已超过1小时，本地滑动窗口显示0属于预期；请检查 timer 和配置周期。"; fi
  fi

  body="$(mktemp)" || { echo "Globalping limits API读取失败：无法创建临时文件"; return 1; }
  http_code="$(curl "${args[@]}" -o "${body}" -w '%{http_code}' https://api.globalping.io/v1/limits 2>/dev/null)"; rc=$?
  resp="$(cat "${body}" 2>/dev/null || true)"; rm -f "${body}"
  if [[ "${rc}" -eq 0 && "${http_code}" == "200" ]] && jq -e . >/dev/null 2>&1 <<< "${resp}"; then
    remote_limit="$(jq -r '.rateLimit.measurements.create.limit // empty' <<< "${resp}")"
    remote_remaining="$(jq -r '.rateLimit.measurements.create.remaining // empty' <<< "${resp}")"
    remote_reset="$(jq -r '.rateLimit.measurements.create.reset // empty' <<< "${resp}")"
    remote_type="$(jq -r '.rateLimit.measurements.create.type // "unknown"' <<< "${resp}")"
    if [[ "${remote_limit}" =~ ^[0-9]+$ && "${remote_remaining}" =~ ^[0-9]+$ ]]; then
      [[ "${remote_reset}" =~ ^[0-9]+$ ]] || remote_reset="unknown"
      [[ "${remote_type}" == "ip" || "${remote_type}" == "user" ]] || remote_type="unknown"
      remote_used=$((remote_limit-remote_remaining)); (( remote_used >= 0 )) || remote_used=0
      echo "Globalping远端当前窗口：已用 ${remote_used}/${remote_limit}，剩余 ${remote_remaining}，约 ${remote_reset:-unknown}s 后重置，类型=${remote_type}"
      echo "说明：远端额度按当前 Token 或出口 IP 统计，可能包含其他程序；本机数字只统计 cfdns 成功创建的 tests。"
    else
      echo "Globalping limits API返回成功，但缺少可识别的 measurements.create 限额字段。"
    fi
  else
    error_detail="$(jq -r '.error.message // .message // empty' <<< "${resp}" 2>/dev/null || true)"
    [[ -n "${error_detail}" ]] || error_detail="$(tr '\r\n\t' '   ' <<< "${resp}" | cut -c1-240)"
    error_detail="$(tr '\r\n\t' '   ' <<< "${error_detail}" | sed 's/[[:space:]]\+/ /g' | cut -c1-240)"
    echo "Globalping limits API读取失败：HTTP=${http_code:-0}，curl_rc=${rc}，详情=${error_detail:-empty}"
  fi
}

test_backup_sources_local_dns() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}" || { echo "该组配置字段数量不是10，请运行菜单24自检"; return 1; }
  load_failover_config_ui "${GROUP_NAME}" || { echo "该组尚未配置故障转移"; return; }
  parse_sources_to_array "${FO_BACKUP_SOURCES}"
  echo "测试组 ${GROUP_NAME} 的 BACKUP 源域名本机解析情况"
  local i=0 domain ips count joined
  for domain in "${SOURCES_ARRAY[@]}"; do
    i=$((i+1)); ips="$(ui_resolve_domain_ipv4 "${domain}")"
    count="$(sed '/^$/d' <<< "${ips}" | wc -l | awk '{print $1}')"; joined="$(paste -sd ',' <<< "${ips}")"
    echo
    printf '[%d] %s\n' "${i}" "${domain}"
    if [[ "${count}" -gt 0 ]]; then
      printf '  状态：正常  IPv4 数量：%s\n  结果：%s\n' "${count}" "${joined}"
    else
      echo "  状态：失败  IPv4 数量：0"
      echo "  结果：-"
    fi
  done
}

remove_failover_config_ui() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}" || { echo "该组配置字段数量不是10，请运行菜单24自检"; return 1; }
  load_failover_config_ui "${GROUP_NAME}" || { echo "该组没有故障转移配置"; return; }
  echo "删除故障转移配置前会先切回 PRIMARY 并强制同步。"
  echo "1. ✅ 切回PRIMARY并删除配置"
  echo "2. ↩️ 取消"
  read -rp "请选择 [1-2]: " choice || return
  [[ "${choice}" == "1" ]] || { echo "已取消"; return; }
  local rc=0
  /usr/local/bin/cf-dns-sync.sh FORESET "${GROUP_NAME}" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "切回PRIMARY或同步失败（退出码=${rc}），未删除配置，避免活动线路失去定义。"
    return
  fi
  delete_failover_config_for_group "${GROUP_NAME}" || { echo "删除故障转移配置失败"; return; }
  remove_failover_state_for_group "${GROUP_NAME}" || { echo "配置已删除，但故障转移状态清理失败；请运行菜单24自检"; return 1; }
  mark_group_sync_due_ui "${GROUP_NAME}" || { echo "配置与状态已删除，但无法安排 PRIMARY 立即复核；请运行菜单24自检"; return 1; }
  echo "已删除该组故障转移配置；groups.tsv 与 PRIMARY 配置保持不变。"
}

show_failover_history() {
  local days choice limit_choice limit=200 cutoff output t group action from to reason measurement_id extra shown=0 failed
  local HISTORY_FILE="${FAILOVER_HISTORY_FILE}"
  echo "1. 最近3天"; echo "2. 最近7天"; echo "3. 最近30天"; echo "4. 最近180天"; echo "5. 自定义天数"; echo "0. 返回"
  read -rp "请选择: " choice || return
  case "${choice}" in
    1) days=3 ;;
    2) days=7 ;;
    3) days=30 ;;
    4) days=180 ;;
    5) read -rp "天数: " days || return; [[ "${days}" =~ ^[0-9]+$ && "${days}" -ge 1 ]] || { echo "天数无效"; return; } ;;
    0) return ;;
    *) echo "无效选择"; return ;;
  esac

  echo "单次显示上限：1) 100  2) 200（默认）  3) 500  4) 1000"
  read -rp "请选择 [1-4，回车默认 200]: " limit_choice || return
  case "${limit_choice}" in
    1) limit=100 ;; ''|2) limit=200 ;; 3) limit=500 ;; 4) limit=1000 ;; *) echo "无效选择"; return ;;
  esac

  cutoff="$(date -d "${days} days ago" '+%F %T' 2>/dev/null)" || { echo "无法计算历史时间范围"; return 1; }
  output="$(mktemp)" || { echo "无法创建临时文件"; return 1; }
  echo "正在读取最新故障转移记录；达到 ${limit} 条后停止扫描旧文件……"
  if ! collect_recent_history_to_file "${cutoff}" all '' "${limit}" "${output}"; then
    rm -f "${output}"
    echo "读取故障转移历史失败"
    return 1
  fi

  while IFS=$'\t' read -r t group action from to reason measurement_id extra; do
    [[ -n "${t}" && -n "${group}" && -n "${action}" && -z "${extra:-}" ]] || continue
    printf '\n[%s] %s\n' "${t}" "${group}"
    printf '  动作：%s  线路：%s -> %s\n' "${action}" "${from}" "${to}"
    printf '  原因：%s\n' "${reason}"
    [[ -z "${measurement_id}" ]] || printf '  测量 ID：%s\n' "${measurement_id}"
    shown=$((shown+1))
  done < "${output}"
  rm -f "${output}"
  [[ "${shown}" -gt 0 ]] || echo "暂无符合条件的故障转移记录"
  echo
  echo "已显示 ${shown} 条（最新在前）；扫描文件 ${HISTORY_FILES_SCANNED}/${HISTORY_TOTAL_FILES}。"
  [[ "${HISTORY_FILES_SKIPPED}" -eq 0 ]] || echo "已按日期跳过 ${HISTORY_FILES_SKIPPED} 个旧轮转文件。"
  [[ "${HISTORY_LIMIT_REACHED}" -eq 0 ]] || echo "已达到 ${limit} 条显示上限。"
  for failed in "${HISTORY_READ_ERRORS[@]}"; do
    echo "警告：无法完整读取 ${failed##*/}，该文件结果未显示。" >&2
  done
}

failover_menu() {
  local choice
  while true; do
    clear 2>/dev/null || true; line; color '1;36' '🌏 Globalping 中国节点故障转移'; echo; line
    echo " 1. 📊 查看故障转移配置与状态"
    echo " 2. 🧭 配置/更新组故障转移"
    echo " 3. 🛟 管理 BACKUP 源域名"
    echo " 4. 🔘 启用/禁用组故障转移"
    echo " 5. 🧪 Globalping 测试 PRIMARY（不改状态计数，会记录API用量）"
    echo " 6. 🧪 Globalping 测试 BACKUP（不改状态计数，会记录API用量）"
    echo " 7. 🔎 测试 BACKUP 本机 DNS 解析"
    echo " 8. ⏪ 人工切换到 PRIMARY"
    echo " 9. ⏩ 人工切换到 BACKUP"
    echo "10. ♻️ 重置状态并回到 PRIMARY"
    echo "11. ⚙️ Globalping 全局设置"
    echo "12. 📈 查看 Globalping 配额/本机使用量/调度诊断"
    echo "13. 📜 查看故障转移历史"
    echo "14. 🗑️ 删除组故障转移配置（保留PRIMARY组）"
    echo " 0. ↩️ 返回主菜单"
    read -rp "请选择: " choice || return
    case "${choice}" in
      1) list_failover_status; pause_wait ;; 2) configure_failover_group; pause_wait ;; 3) manage_backup_sources ;;
      4) toggle_failover_enabled; pause_wait ;; 5) test_failover_role PRIMARY; pause_wait ;; 6) test_failover_role BACKUP; pause_wait ;;
      7) test_backup_sources_local_dns; pause_wait ;; 8) manual_failover_switch_ui PRIMARY; pause_wait ;; 9) manual_failover_switch_ui BACKUP; pause_wait ;;
      10) reset_failover_state_ui_action; pause_wait ;; 11) globalping_settings_menu ;; 12) show_globalping_limits; pause_wait ;;
      13) show_failover_history; pause_wait ;; 14) remove_failover_config_ui; pause_wait ;; 0) return ;;
      *) echo "无效选择"; sleep 1 ;;
    esac
  done
}

activate_after_init() {
  local group_name="${1:-ALL}"
  systemctl daemon-reload || { echo "systemd daemon-reload 失败"; return 1; }
  systemctl reset-failed "${SERVICE_NAME}" "${TIMER_NAME}" 2>/dev/null || true
  systemctl enable --now "${TIMER_NAME}" || { echo "${TIMER_NAME} 启用失败"; return 1; }
  /usr/local/bin/cf-dns-sync.sh "${group_name}" FORCE || { echo "首次同步失败，请查看项目日志"; return 1; }
}


init_wizard_needed() {
  [[ -f "${INIT_FLAG}" ]] && return 1
  if [[ "$(get_group_count)" -gt 0 ]]; then
    touch "${INIT_FLAG}"
    chmod 600 "${INIT_FLAG}"
    return 1
  fi
  return 0
}

run_init_wizard() {
  init_wizard_needed || return 0

  clear 2>/dev/null || true
  line
  color "1;33" "🧭 首次运行快速初始化向导"
  echo
  color "0;37" "这次向导结束后，会直接把脚本切到可用状态。"
  line
  echo "1. 🚀 开始初始化"
  echo "2. ⏭️  跳过，稍后在菜单中手动配置"
  line
  read -rp "请选择 [1-2]: " wizard_choice || {
    echo "未读取到选择，初始化状态保持不变。"
    return 1
  }

  local before_count after_count init_ok=0
  before_count="$(get_group_count)"
  case "${wizard_choice}" in
    1)
      quick_add_first_group && init_ok=1
      after_count="$(get_group_count)"
      if [[ "${after_count}" -gt "${before_count}" ]]; then
        touch "${INIT_FLAG}"
        chmod 600 "${INIT_FLAG}"
        if [[ "${init_ok}" -ne 1 ]]; then
          echo "首组配置已保存，但自动调度或首次同步未成功；为避免重复建组，初始化向导不再重复，请运行菜单24/25诊断修复。"
        fi
      else
        echo "初始化未完成，下次进入 cfdns 时仍会显示快速初始化向导。"
      fi
      ;;
    2|"")
      touch "${INIT_FLAG}"
      chmod 600 "${INIT_FLAG}"
      ;;
    *)
      echo "无效选择；初始化状态未写入。"
      ;;
  esac
}

quick_add_first_group() {
  echo
  color "1;33" "🧱 创建第一个组"
  echo
  read -rp "组名（例如 group-a）: " group_name || return
  valid_group_name_field "${group_name}" || { echo "组名不能为空、不能超过128字符，且不能包含 TAB、换行或反斜杠"; return; }
  if awk -F '	' -v g="${group_name}" '!/^#/ && $1==g{found=1} END{exit !found}' "${GROUPS_FILE}"; then
    echo "组名已存在"; return
  fi

  prompt_interval || return
  interval_sec="${SELECTED_INTERVAL}"
  read -rsp "Cloudflare API Token: " api_token || return; echo
  valid_api_token_field "${api_token}" || { echo "API Token 不能为空，且不能包含 TAB、换行或反斜杠"; return; }
  read -rp "Zone ID: " zone_id || return
  valid_zone_id "${zone_id}" || { echo "Zone ID 必须是32位十六进制字符串"; return; }
  read -rp "目标域名（例如 tiktokeu.example.com）: " target_fqdn || return
  valid_domain "${target_fqdn}" || { echo "目标域名格式不正确"; return; }
  duplicate="$(find_duplicate_target "${zone_id}" "${target_fqdn}")"
  [[ -z "${duplicate}" ]] || { echo "目标域名已由组 ${duplicate} 管理，禁止重复管理"; return; }
  read -rp "TTL（推荐60）: " ttl || return
  valid_ttl "${ttl}" || { echo "TTL 必须为 1（自动）或 60~86400 秒"; return; }

  echo "解析模式："
  echo "1. 🌐 ALL_IPS（全部IP模式）"
  echo "2. 🎯 SINGLE_IP（单IP模式）"
  read -rp "请选择 [1-2]: " mode_choice || return
  case "${mode_choice}" in 1|"") mode="ALL_IPS" ;; 2) mode="SINGLE_IP" ;; *) echo "无效选择"; return ;; esac

  echo "请输入源域名，使用英文逗号分隔，最多20个："
  read -rp "源域名列表: " sources_csv || return
  sources_csv="$(normalize_sources_csv "${sources_csv}")"
  src_count="$(count_sources_csv "${sources_csv}")"
  [[ "${src_count}" -ge 1 && "${src_count}" -le 20 ]] || { echo "源域名数量必须为1~20"; return; }
  validate_sources_csv "${sources_csv}" || { echo "源域名列表中存在格式错误的域名"; return; }

  new_line="$(printf '%s	%s	%s	%s	%s	%s	%s	%s	%s	%s' \
    "${group_name}" true "${interval_sec}" "${api_token}" "${zone_id}" "${target_fqdn}" "${ttl}" false "${mode}" "${sources_csv}")"
  save_group_line_replace "${group_name}" "${new_line}" || { echo "首组配置保存失败"; return 1; }
  invalidate_group_sync_state "${group_name}" || { echo "首组已保存，但旧状态清理失败"; return 1; }
  if activate_after_init "${group_name}"; then
    echo "初始化完成：已启用定时器并立即强制同步组 ${group_name}。"
  else
    echo "组配置已保存，但初始化未完全可用；请运行菜单24自检或菜单25一键修复。"
    return 1
  fi
}


move_group_up() {
  echo
  select_group || { echo "序号无效"; return; }
  [[ "${CHOSEN_INDEX}" -gt 1 ]] || { echo "该组已经在最上方"; return; }

  local tmp
  tmp="$(mktemp)" || { echo "无法创建临时文件"; return 1; }
  if ! awk -v target="${CHOSEN_INDEX}" '
    BEGIN{n=0}
    /^#/ {comments[++c]=$0; next}
    NF==0 {next}
    {rows[++n]=$0}
    END{
      for(i=1;i<=c;i++) print comments[i]
      tmpv=rows[target-1]
      rows[target-1]=rows[target]
      rows[target]=tmpv
      for(i=1;i<=n;i++) print rows[i]
    }
  ' "${GROUPS_FILE}" > "${tmp}"; then
    rm -f "${tmp}"
    echo "读取组配置失败"
    return 1
  fi

  save_groups_with_tmp "${tmp}" || { echo "组上移保存失败"; return 1; }
  echo "已上移"
}

move_group_down() {
  echo
  select_group || { echo "序号无效"; return; }

  local total
  total="$(get_group_count)"
  [[ "${CHOSEN_INDEX}" -lt "${total}" ]] || { echo "该组已经在最下方"; return; }

  local tmp
  tmp="$(mktemp)" || { echo "无法创建临时文件"; return 1; }
  if ! awk -v target="${CHOSEN_INDEX}" '
    BEGIN{n=0}
    /^#/ {comments[++c]=$0; next}
    NF==0 {next}
    {rows[++n]=$0}
    END{
      for(i=1;i<=c;i++) print comments[i]
      tmpv=rows[target+1]
      rows[target+1]=rows[target]
      rows[target]=tmpv
      for(i=1;i<=n;i++) print rows[i]
    }
  ' "${GROUPS_FILE}" > "${tmp}"; then
    rm -f "${tmp}"
    echo "读取组配置失败"
    return 1
  fi

  save_groups_with_tmp "${tmp}" || { echo "组下移保存失败"; return 1; }
  echo "已下移"
}

add_group() {
  echo
  color "1;33" "➕ 新增组（公开脚本模式）"
  echo
  read -rp "请输入组名（例如 group-a）: " group_name || return
  valid_group_name_field "${group_name}" || { echo "组名不能为空、不能超过128字符，且不能包含 TAB、换行或反斜杠"; return; }
  if awk -F '	' -v g="${group_name}" '!/^#/ && $1==g{found=1} END{exit !found}' "${GROUPS_FILE}"; then echo "组名已存在"; return; fi

  echo "是否启用该组："
  echo "1. ✅ true（启用）"
  echo "2. ⛔ false（禁用）"
  read -rp "请选择 [1-2]: " enabled_choice || return
  case "${enabled_choice}" in 1|"") enabled=true ;; 2) enabled=false ;; *) echo "无效选择"; return ;; esac

  prompt_interval || return
  interval_sec="${SELECTED_INTERVAL}"
  read -rsp "请输入 Cloudflare API Token: " api_token || return; echo
  valid_api_token_field "${api_token}" || { echo "API Token 不能为空，且不能包含 TAB、换行或反斜杠"; return; }
  read -rp "请输入 Zone ID: " zone_id || return
  valid_zone_id "${zone_id}" || { echo "Zone ID 必须是32位十六进制字符串"; return; }
  read -rp "请输入目标域名（例如 tiktokeu.example.com）: " target_fqdn || return
  valid_domain "${target_fqdn}" || { echo "目标域名格式不正确"; return; }
  duplicate="$(find_duplicate_target "${zone_id}" "${target_fqdn}")"
  [[ -z "${duplicate}" ]] || { echo "目标域名已由组 ${duplicate} 管理，禁止重复管理"; return; }
  read -rp "请输入 TTL（推荐 60）: " ttl || return
  valid_ttl "${ttl}" || { echo "TTL 必须为 1（自动）或 60~86400 秒"; return; }

  echo "请选择解析模式："
  echo "1. 🌐 ALL_IPS（全部IP模式）"
  echo "2. 🎯 SINGLE_IP（单IP模式）"
  read -rp "请输入序号 [1-2]: " mode_choice || return
  case "${mode_choice}" in 1|"") mode=ALL_IPS ;; 2) mode=SINGLE_IP ;; *) echo "无效选择"; return ;; esac

  echo "1. ☁️ false（DNS only / 关闭代理）"
  read -rp "请输入序号 [1]: " proxied_choice || return
  case "${proxied_choice}" in 1|"") proxied=false ;; *) echo "无效选择"; return ;; esac

  echo "请输入源域名，使用英文逗号分隔，最多20个："
  read -rp "源域名列表: " sources_csv || return
  sources_csv="$(normalize_sources_csv "${sources_csv}")"
  src_count="$(count_sources_csv "${sources_csv}")"
  [[ "${src_count}" -ge 1 && "${src_count}" -le 20 ]] || { echo "源域名数量必须为1~20"; return; }
  validate_sources_csv "${sources_csv}" || { echo "源域名列表中存在格式错误的域名"; return; }

  new_line="$(printf '%s	%s	%s	%s	%s	%s	%s	%s	%s	%s' \
    "${group_name}" "${enabled}" "${interval_sec}" "${api_token}" "${zone_id}" "${target_fqdn}" "${ttl}" "${proxied}" "${mode}" "${sources_csv}")"
  save_group_line_replace "${group_name}" "${new_line}" || { echo "组配置保存失败"; return 1; }
  invalidate_group_sync_state "${group_name}" || { echo "组已保存，但旧状态清理失败"; return 1; }
  if [[ "${enabled}" == "true" ]]; then
    if systemctl enable --now "${TIMER_NAME}"; then
      echo "组已添加：${group_name}；最快会在下一个5秒调度周期检测。"
    else
      echo "组已添加，但 ${TIMER_NAME} 启用失败；请运行菜单24自检或菜单25一键修复。"
      return 1
    fi
  else
    echo "组已添加：${group_name}（当前禁用，不会自动检测）。"
  fi
}


delete_group() {
  echo
  select_group || { echo "序号无效"; return; }
  local group_name="${CHOSEN_GROUP_NAME}" tmp
  echo "1. ✅ 确认删除"
  echo "2. ↩️  取消"
  read -rp "请选择 [1-2]: " ans || return
  [[ "${ans}" == "1" ]] || { echo "已取消"; return; }

  tmp="$(mktemp)" || { echo "无法创建临时文件"; return 1; }
  awk -F '\t' -v g="${group_name}" '/^#/ || (NF>0 && $1!=g)' "${GROUPS_FILE}" > "${tmp}" || { rm -f "${tmp}"; echo "生成新组配置失败"; return 1; }
  save_groups_with_tmp "${tmp}" || { echo "保存组配置失败"; return 1; }
  local cleanup_failed=0
  delete_failover_config_for_group "${group_name}" || cleanup_failed=1
  remove_group_runtime_state "${group_name}" || cleanup_failed=1
  remove_failover_state_for_group "${group_name}" || cleanup_failed=1
  if [[ "${cleanup_failed}" -eq 0 ]]; then
    echo "已删除组、故障转移配置及本地状态：${group_name}"
  else
    echo "组配置已删除，但部分故障转移或本地状态清理失败；请运行菜单24自检。"
    return 1
  fi
}

toggle_group_enabled() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}" || { echo "该组配置字段数量不是10，请运行菜单24自检"; return 1; }
  if [[ "${GROUP_ENABLED}" == "true" ]]; then GROUP_ENABLED=false; else GROUP_ENABLED=true; fi
  save_group_line_replace "${CHOSEN_GROUP_NAME}" "$(build_group_line)" || { echo "保存失败"; return; }
  if [[ "${GROUP_ENABLED}" == "true" ]]; then
    invalidate_group_sync_state "${GROUP_NAME}" || { echo "组已启用，但同步状态清理失败"; return 1; }
    if load_failover_config_ui "${GROUP_NAME}" >/dev/null 2>&1; then
      reset_failover_counters_preserve_role "${GROUP_NAME}" || { echo "组已启用，但故障转移状态重置失败"; return 1; }
    fi
    if ! systemctl enable --now "${TIMER_NAME}"; then
      echo "组 ${GROUP_NAME} 已启用，但 ${TIMER_NAME} 启用失败；请运行菜单24自检或菜单25一键修复。"
      return 1
    fi
  fi
  echo "组 ${GROUP_NAME} 已切换为 ${GROUP_ENABLED}"
}

set_group_interval() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}" || { echo "该组配置字段数量不是10，请运行菜单24自检"; return 1; }
  echo "当前周期：${GROUP_INTERVAL} 秒"
  prompt_interval || return
  GROUP_INTERVAL="${SELECTED_INTERVAL}"
  save_group_line_replace "${CHOSEN_GROUP_NAME}" "$(build_group_line)" || { echo "检测周期保存失败"; return 1; }
  # 清除上次检查时间，使新周期立即生效。
  tmp="$(mktemp "${VAR_DIR}/.runstate.XXXXXX")" || { echo "无法创建状态临时文件"; return 1; }
  if ! awk -F '	' -v g="${GROUP_NAME}" '$1!=g' "${RUNSTATE_FILE}" 2>/dev/null > "${tmp}"; then
    rm -f "${tmp}"
    echo "无法读取执行状态，周期已保存但未能立即生效"
    return 1
  fi
  chmod 600 "${tmp}" && mv -f "${tmp}" "${RUNSTATE_FILE}" || {
    rm -f "${tmp}"
    echo "周期已保存但执行状态更新失败"
    return 1
  }
  echo "组 ${GROUP_NAME} 的检测周期已更新为 ${GROUP_INTERVAL} 秒"
}


parse_sources_to_array() {
  local csv="$1"
  local normalized
  normalized="$(normalize_sources_csv "${csv}")"
  SOURCES_ARRAY=()
  [[ -z "${normalized}" ]] && return 0
  IFS=',' read -r -a SOURCES_ARRAY <<< "${normalized}"
}

join_sources_array() {
  local IFS=,
  echo "${SOURCES_ARRAY[*]}"
}

manage_group_sources() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}" || { echo "该组配置字段数量不是10，请运行菜单24自检"; return 1; }
  parse_sources_to_array "${GROUP_SOURCES_CSV}"

  while true; do
    clear 2>/dev/null || true
    line
    color "1;36" "🌐 PRIMARY 源域名管理 - ${GROUP_NAME}"
    echo
    echo "说明：为保持 v2.5 配置兼容，groups.tsv 中的现有源域名始终作为 PRIMARY。"
    line
    local i=0
    for s in "${SOURCES_ARRAY[@]}"; do i=$((i+1)); printf "%2d. %s\n" "${i}" "${s}"; done
    [[ "${#SOURCES_ARRAY[@]}" -eq 0 ]] && echo "当前无源域名"
    line
    echo "1. ➕ 添加单个源域名"
    echo "2. 🗑️  删除单个源域名"
    echo "3. 📥 批量导入源域名（英文逗号分隔）"
    echo "4. 📤 导出当前源域名（英文逗号分隔）"
    echo "0. ↩️  返回上级"
    line
    read -rp "请选择: " choice || return

    local before_csv new_csv overlap
    before_csv="$(IFS=,; echo "${SOURCES_ARRAY[*]}")"
    case "${choice}" in
      1)
        (( ${#SOURCES_ARRAY[@]} < 20 )) || { echo "最多只能配置20个源域名"; pause_wait; continue; }
        read -rp "请输入新的源域名: " new_domain || return
        new_domain="$(normalize_sources_csv "${new_domain}")"
        [[ -n "${new_domain}" ]] || { echo "不能为空"; pause_wait; continue; }
        valid_domain "${new_domain}" || { echo "源域名格式不正确"; pause_wait; continue; }
        printf '%s\n' "${SOURCES_ARRAY[@]}" | grep -Fxiq "${new_domain}" && { echo "该源域名已存在"; pause_wait; continue; }
        SOURCES_ARRAY+=("${new_domain}")
        ;;
      2)
        (( ${#SOURCES_ARRAY[@]} > 1 )) || { echo "至少保留1个源域名"; pause_wait; continue; }
        read -rp "请输入要删除的序号: " del_idx || return
        [[ "${del_idx}" =~ ^[0-9]+$ && "${del_idx}" -ge 1 && "${del_idx}" -le "${#SOURCES_ARRAY[@]}" ]] || { echo "序号无效"; pause_wait; continue; }
        unset 'SOURCES_ARRAY[del_idx-1]'; SOURCES_ARRAY=("${SOURCES_ARRAY[@]}")
        ;;
      3)
        read -rp "请输入源域名列表（英文逗号分隔，最多20个）: " import_csv || return
        import_csv="$(normalize_sources_csv "${import_csv}")"
        validate_sources_csv "${import_csv}" || { echo "导入内容必须是1~20个有效源域名"; pause_wait; continue; }
        parse_sources_to_array "${import_csv}"
        ;;
      4)
        (IFS=,; echo "${SOURCES_ARRAY[*]}")
        pause_wait; continue
        ;;
      0) return ;;
      *) echo "无效选择"; pause_wait; continue ;;
    esac

    new_csv="$(IFS=,; echo "${SOURCES_ARRAY[*]}")"
    if load_failover_config_ui "${GROUP_NAME}" >/dev/null 2>&1; then
      overlap="$(csv_overlap_value "${new_csv}" "${FO_BACKUP_SOURCES}" || true)"
      if [[ -n "${overlap}" ]]; then
        echo "保存被拒绝：PRIMARY 与 BACKUP 不能包含相同域名：${overlap}"
        parse_sources_to_array "${before_csv}"
        pause_wait
        continue
      fi
    fi
    GROUP_SOURCES_CSV="${new_csv}"
    save_group_line_replace "${CHOSEN_GROUP_NAME}" "$(build_group_line)" || { echo "保存失败"; parse_sources_to_array "${before_csv}"; pause_wait; continue; }
    if ! invalidate_group_sync_state "${GROUP_NAME}"; then
      echo "源域名已保存，但旧同步状态清理失败；请运行菜单24自检。"
      return 1
    fi
    if load_failover_config_ui "${GROUP_NAME}" >/dev/null 2>&1 && ! reset_failover_counters_preserve_role "${GROUP_NAME}"; then
      echo "源域名已保存，但故障转移状态重置失败；请运行菜单24自检。"
      return 1
    fi
  done
}

edit_group_basic() {
  echo
  select_group || { echo "序号无效"; return; }
  local old_group_name="${CHOSEN_GROUP_NAME}" new_line duplicate backup_groups backup_fo backup_fos rollback_failed
  split_line_to_vars "${CHOSEN_LINE}" || { echo "该组配置字段数量不是10，请运行菜单24自检"; return 1; }

  echo "当前组名: ${GROUP_NAME}"
  read -rp "新组名（回车保持）: " new_group_name || return
  [[ -z "${new_group_name}" ]] || GROUP_NAME="${new_group_name}"
  valid_group_name_field "${GROUP_NAME}" || { echo "组名不能为空、不能超过128字符，且不能包含 TAB、换行或反斜杠"; return; }
  if [[ "${GROUP_NAME}" != "${old_group_name}" ]] && awk -F '\t' -v g="${GROUP_NAME}" '!/^#/ && $1==g{found=1} END{exit !found}' "${GROUPS_FILE}"; then
    echo "新组名已经存在"; return
  fi

  echo "当前目标域名: ${GROUP_TARGET_FQDN}"
  read -rp "新目标域名（回车保持）: " new_target || return
  [[ -z "${new_target}" ]] || GROUP_TARGET_FQDN="${new_target}"
  valid_domain "${GROUP_TARGET_FQDN}" || { echo "目标域名格式不正确"; return; }

  echo "当前 TTL: ${GROUP_TTL}"
  read -rp "新 TTL（回车保持）: " new_ttl || return
  [[ -z "${new_ttl}" ]] || GROUP_TTL="${new_ttl}"
  valid_ttl "${GROUP_TTL}" || { echo "TTL 必须为1（自动）或60~86400秒"; return; }

  echo "当前 Zone ID: ${GROUP_ZONE_ID}"
  read -rp "新 Zone ID（回车保持）: " new_zone || return
  [[ -z "${new_zone}" ]] || GROUP_ZONE_ID="${new_zone}"
  valid_zone_id "${GROUP_ZONE_ID}" || { echo "Zone ID 必须是32位十六进制字符串"; return; }

  echo "当前 API Token: 已隐藏"
  read -rsp "新 API Token（回车保持）: " new_token || return; echo
  [[ -z "${new_token}" ]] || GROUP_API_TOKEN="${new_token}"
  valid_api_token_field "${GROUP_API_TOKEN}" || { echo "API Token 不能为空，且不能包含 TAB、换行或反斜杠"; return; }

  duplicate="$(find_duplicate_target "${GROUP_ZONE_ID}" "${GROUP_TARGET_FQDN}" "${old_group_name}")"
  [[ -z "${duplicate}" ]] || { echo "目标域名已由组 ${duplicate} 管理，禁止重复管理"; return; }

  echo "当前解析模式: ${GROUP_MODE}"
  echo "1. ➖ 保持不变"; echo "2. 🌐 ALL_IPS（全部IP模式）"; echo "3. 🎯 SINGLE_IP（单IP模式）"
  read -rp "请选择 [1-3]: " mode_choice || return
  case "${mode_choice}" in 1|"") ;; 2) GROUP_MODE=ALL_IPS ;; 3) GROUP_MODE=SINGLE_IP ;; *) echo "无效选择"; return ;; esac

  new_line="$(build_group_line)"
  backup_groups="$(mktemp)" || { echo "无法创建组配置备份"; return 1; }
  backup_fo="$(mktemp)" || { rm -f "${backup_groups}"; echo "无法创建故障转移配置备份"; return 1; }
  backup_fos="$(mktemp)" || { rm -f "${backup_groups}" "${backup_fo}"; echo "无法创建故障转移状态备份"; return 1; }
  cp -f "${GROUPS_FILE}" "${backup_groups}" || { rm -f "${backup_groups}" "${backup_fo}" "${backup_fos}"; echo "无法备份组配置"; return 1; }
  if [[ -f "${FAILOVER_FILE}" ]]; then cp -f "${FAILOVER_FILE}" "${backup_fo}" || { rm -f "${backup_groups}" "${backup_fo}" "${backup_fos}"; echo "无法备份故障转移配置"; return 1; }; else : > "${backup_fo}"; fi
  if [[ -f "${FAILOVER_STATE_FILE}" ]]; then cp -f "${FAILOVER_STATE_FILE}" "${backup_fos}" || { rm -f "${backup_groups}" "${backup_fo}" "${backup_fos}"; echo "无法备份故障转移状态"; return 1; }; else : > "${backup_fos}"; fi
  if ! save_group_line_replace "${old_group_name}" "${new_line}"; then
    rm -f "${backup_groups}" "${backup_fo}" "${backup_fos}"; echo "保存组配置失败"; return
  fi
  if [[ "${GROUP_NAME}" != "${old_group_name}" ]] && ! rename_failover_group "${old_group_name}" "${GROUP_NAME}"; then
    rollback_failed=0
    install -m 600 "${backup_groups}" "${GROUPS_FILE}" || rollback_failed=1
    install -m 600 "${backup_fo}" "${FAILOVER_FILE}" || rollback_failed=1
    install -m 600 "${backup_fos}" "${FAILOVER_STATE_FILE}" || rollback_failed=1
    rm -f "${backup_groups}" "${backup_fo}" "${backup_fos}"
    if [[ "${rollback_failed}" -eq 0 ]]; then
      echo "故障转移联动重命名失败，已回滚"
    else
      echo "故障转移联动重命名失败且回滚不完整；请立即从升级备份恢复并运行菜单24自检"
    fi
    return 1
  fi
  rm -f "${backup_groups}" "${backup_fo}" "${backup_fos}"
  if ! remove_group_runtime_state "${old_group_name}"; then
    echo "组配置已保存，但旧同步状态清理失败；请运行菜单24自检。"
    return 1
  fi
  if [[ "${GROUP_NAME}" != "${old_group_name}" ]] && ! remove_group_runtime_state "${GROUP_NAME}"; then
    echo "组配置已保存，但新组名对应的旧状态清理失败；请运行菜单24自检。"
    return 1
  fi
  if load_failover_config_ui "${GROUP_NAME}" >/dev/null 2>&1 && ! reset_failover_counters_preserve_role "${GROUP_NAME}"; then
    echo "组配置已保存，但故障转移状态重置失败；请运行菜单24自检。"
    return 1
  fi
  echo "组配置已原位更新；故障转移配置/状态已联动，旧同步状态已清理。"
}

set_log_level() {
  local old_log_level="${LOG_LEVEL}"
  echo
  echo "请选择日志等级："
  echo "1. 🔇 NONE（空日志）"
  echo "2. ❌ ERROR（仅错误）"
  echo "3. ℹ️  INFO（普通信息）"
  echo "4. 🐞 DEBUG（调试详情）"
  read -rp "请输入序号 [1-4]: " choice || return

  case "${choice}" in
    1) LOG_LEVEL="NONE" ;;
    2) LOG_LEVEL="ERROR" ;;
    3) LOG_LEVEL="INFO" ;;
    4) LOG_LEVEL="DEBUG" ;;
    *) echo "无效选择"; return ;;
  esac

  if save_settings; then
    echo "日志等级已设置为 ${LOG_LEVEL}"
  else
    LOG_LEVEL="${old_log_level}"
    echo "日志等级保存失败，原配置保持不变"
    return 1
  fi
}

test_group_token() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}" || { echo "该组配置字段数量不是10，请运行菜单24自检"; return 1; }
  echo "正在测试组 ${GROUP_NAME} 的 API Token 与 Zone ID..."
  local resp
  resp="$(ui_cf_get "https://api.cloudflare.com/client/v4/zones/${GROUP_ZONE_ID}" "${GROUP_API_TOKEN}")"
  if [[ "$(jq -r '.success // false' <<< "${resp}" 2>/dev/null)" == "true" ]]; then
    echo "✅ 测试成功"
    echo "Zone: $(jq -r '.result.name // "unknown"' <<< "${resp}")"
    echo "状态: $(jq -r '.result.status // "unknown"' <<< "${resp}")"
  else
    echo "❌ 测试失败"
    jq . <<< "${resp}" 2>/dev/null || printf '%s\n' "${resp}"
  fi
}


test_group_sources_dns() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}" || { echo "该组配置字段数量不是10，请运行菜单24自检"; return 1; }
  parse_sources_to_array "${GROUP_SOURCES_CSV}"
  echo "测试组 ${GROUP_NAME} 的 PRIMARY 源域名解析情况"
  local i=0 domain ips count joined
  for domain in "${SOURCES_ARRAY[@]}"; do
    i=$((i+1)); ips="$(ui_resolve_domain_ipv4 "${domain}")"
    count="$(sed '/^$/d' <<< "${ips}" | wc -l | awk '{print $1}')"; joined="$(paste -sd ',' <<< "${ips}")"
    echo
    printf '[%d] %s\n' "${i}" "${domain}"
    if [[ "${count}" -gt 0 ]]; then
      printf '  状态：正常  IPv4 数量：%s\n  结果：%s\n' "${count}" "${joined}"
    else
      echo "  状态：失败  IPv4 数量：0"
      echo "  结果：-"
    fi
  done
}

view_group_current_ips() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}" || { echo "该组配置字段数量不是10，请运行菜单24自检"; return 1; }
  local active_role="PRIMARY" backup_csv="" failover_enabled="false"
  if load_failover_config_ui "${GROUP_NAME}" >/dev/null 2>&1 && [[ "${FO_ENABLED}" == "true" ]]; then
    failover_enabled=true; backup_csv="${FO_BACKUP_SOURCES}"; load_failover_state_ui "${GROUP_NAME}"
    [[ "${FS_ACTIVE_ROLE}" == "BACKUP" ]] && active_role="BACKUP"
  fi
  local tmp_all i domain ips selected count joined resp encoded csv label
  tmp_all="$(mktemp)" || { echo "无法创建临时文件"; return 1; }
  : > "${tmp_all}" || { rm -f "${tmp_all}"; echo "无法初始化临时文件"; return 1; }

  echo "📡 当前组别解析 IP：${GROUP_NAME}"
  echo "目标域名: ${GROUP_TARGET_FQDN}"
  echo "解析模式: ${GROUP_MODE}"
  echo "当前活动线路: ${active_role}；故障转移: ${failover_enabled}"
  echo "DNS解析器: ${DNS_SERVER:-系统默认}"

  for label in PRIMARY BACKUP; do
    [[ "${label}" == PRIMARY ]] && csv="${GROUP_SOURCES_CSV}" || csv="${backup_csv}"
    [[ -n "${csv}" ]] || continue
    echo; echo "${label} 源域名解析$([[ "${label}" == "${active_role}" ]] && echo '（当前用于同步）' || true)："
    parse_sources_to_array "${csv}"; i=0
    for domain in "${SOURCES_ARRAY[@]}"; do
      i=$((i+1)); ips="$(ui_resolve_domain_ipv4 "${domain}")"
      if [[ "${GROUP_MODE}" == "SINGLE_IP" ]]; then
        selected="$(sed '/^$/d' <<< "${ips}" | head -n1)"; count=$([[ -n "${selected}" ]] && echo 1 || echo 0); joined="${selected:-}"
        [[ "${label}" == "${active_role}" && -n "${selected}" ]] && echo "${selected}" >> "${tmp_all}"
      else
        count="$(sed '/^$/d' <<< "${ips}" | wc -l | awk '{print $1}')"; joined="$(paste -sd ',' <<< "${ips}")"
        [[ "${label}" == "${active_role}" ]] && sed '/^$/d' <<< "${ips}" >> "${tmp_all}"
      fi
      [[ -n "${joined}" ]] || joined="-"
      echo
      printf '[%d] %s\n' "${i}" "${domain}"
      printf '  IPv4 数量：%s\n  结果：%s\n' "${count}" "${joined}"
    done
  done

  echo; echo "去重后当前活动线路将用于同步的 IPv4："
  sort -u "${tmp_all}" | sed '/^$/d' | nl -w2 -s'. '
  echo "总数: $(sort -u "${tmp_all}" | sed '/^$/d' | wc -l | awk '{print $1}')"

  echo; echo "Cloudflare 当前目标 A 记录："
  encoded="$(urlencode "${GROUP_TARGET_FQDN}")"
  local cf_ips page=1 total_pages=1 cf_failed=0
  cf_ips="$(mktemp)" || { rm -f "${tmp_all}"; echo "无法创建临时文件"; return 1; }
  : > "${cf_ips}" || { rm -f "${tmp_all}" "${cf_ips}"; echo "无法初始化临时文件"; return 1; }
  while (( page <= total_pages )); do
    resp="$(ui_cf_get "https://api.cloudflare.com/client/v4/zones/${GROUP_ZONE_ID}/dns_records?type=A&name=${encoded}&page=${page}&per_page=100" "${GROUP_API_TOKEN}")"
    if [[ "$(jq -r '.success // false' <<< "${resp}" 2>/dev/null)" != true ]]; then echo "无法读取 Cloudflare 当前记录：$(jq -c '.errors // []' <<< "${resp}" 2>/dev/null || echo unknown)"; cf_failed=1; break; fi
    jq -r '.result[]?.content' <<< "${resp}" >> "${cf_ips}" 2>/dev/null || { cf_failed=1; break; }
    total_pages="$(jq -r '.result_info.total_pages // 1' <<< "${resp}" 2>/dev/null || echo 1)"; [[ "${total_pages}" =~ ^[0-9]+$ ]] || total_pages=1
    (( total_pages >= 1 && total_pages <= 1000 )) || { echo "Cloudflare 返回异常分页数量：${total_pages}"; cf_failed=1; break; }
    page=$((page+1))
  done
  if [[ "${cf_failed}" -eq 0 ]]; then sort -u "${cf_ips}" | sed '/^$/d' | nl -w2 -s'. '; echo "总数: $(sort -u "${cf_ips}" | sed '/^$/d' | wc -l | awk '{print $1}')"; fi
  rm -f "${tmp_all}" "${cf_ips}"
}

start_sync() {
  systemctl daemon-reload || { echo "启动失败：systemd daemon-reload 失败"; return 1; }
  systemctl reset-failed "${SERVICE_NAME}" "${TIMER_NAME}" 2>/dev/null || true
  systemctl enable --now "${TIMER_NAME}" || { echo "启动失败：${TIMER_NAME} 无法启用"; return 1; }
  systemctl start "${SERVICE_NAME}" || { echo "启动失败：${SERVICE_NAME} 首次运行失败"; return 1; }
  systemctl is-active --quiet "${TIMER_NAME}" || { echo "启动失败：${TIMER_NAME} 未处于 active"; return 1; }
  echo "已启动并完成一次调度"
}

stop_sync() {
  local rc=0
  systemctl stop "${TIMER_NAME}" || rc=1
  systemctl stop "${SERVICE_NAME}" || rc=1
  if systemctl is-enabled --quiet "${TIMER_NAME}" 2>/dev/null; then
    systemctl disable "${TIMER_NAME}" || rc=1
  fi
  if systemctl is-active --quiet "${TIMER_NAME}" || systemctl is-active --quiet "${SERVICE_NAME}"; then
    rc=1
  fi
  if [[ "${rc}" -eq 0 ]]; then
    echo "已停止服务，并禁用定时器"
  else
    echo "停止未完整完成；请使用菜单22查看 service/timer 状态"
    return 1
  fi
}

restart_sync() {
  systemctl daemon-reload || { echo "重启失败：systemd daemon-reload 失败"; return 1; }
  systemctl reset-failed "${SERVICE_NAME}" "${TIMER_NAME}" 2>/dev/null || true
  systemctl enable --now "${TIMER_NAME}" || { echo "重启失败：${TIMER_NAME} 无法启用"; return 1; }
  systemctl restart "${SERVICE_NAME}" || { echo "重启失败：${SERVICE_NAME} 运行失败"; return 1; }
  systemctl is-active --quiet "${TIMER_NAME}" || { echo "重启失败：${TIMER_NAME} 未处于 active"; return 1; }
  echo "已重启并完成一次调度"
}

manual_run_all() {
  local rc=0
  /usr/local/bin/cf-dns-sync.sh ALL FORCE || rc=$?
  case "${rc}" in
    0) echo "已强制核对并同步全部启用组" ;;
    75) echo "同步任务正在运行，等待30秒后仍未取得锁，本次未执行" ;;
    *) echo "手动同步失败，退出码=${rc}；请查看项目日志或运行自检" ;;
  esac
  return "${rc}"
}


manual_run_one() {
  local rc=0
  echo
  select_group || { echo "序号无效"; return; }
  /usr/local/bin/cf-dns-sync.sh "${CHOSEN_GROUP_NAME}" FORCE || rc=$?
  case "${rc}" in
    0) echo "已强制核对并同步组：${CHOSEN_GROUP_NAME}" ;;
    75) echo "同步任务正在运行，等待30秒后仍未取得锁，本次未执行" ;;
    *) echo "手动同步失败，退出码=${rc}；请查看项目日志或运行自检" ;;
  esac
  return "${rc}"
}


managed_log_file_kind() {
  local base="$1" path="$2" suffix
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  if [[ "${path}" == "${base}" ]]; then
    printf '%s\n' current
    return 0
  fi
  suffix="${path#"${base}"}"
  [[ "${suffix}" != "${path}" ]] || return 1
  if [[ "${suffix}" =~ ^\.[0-9]+(\.gz)?$ || "${suffix}" =~ ^-[0-9]{8}(\.gz)?$ ]]; then
    printf '%s\n' rotated
    return 0
  fi
  return 1
}

collect_managed_log_files() {
  local base="$1" f mtime
  local -a rotated_files=()
  LOG_FILES=()
  if managed_log_file_kind "${base}" "${base}" >/dev/null 2>&1; then
    LOG_FILES+=("${base}")
  fi
  shopt -s nullglob
  for f in "${base}".* "${base}"-*; do
    managed_log_file_kind "${base}" "${f}" >/dev/null 2>&1 || continue
    rotated_files+=("${f}")
  done
  shopt -u nullglob
  if [[ "${#rotated_files[@]}" -gt 0 ]]; then
    while IFS=$'\t' read -r _ f; do
      [[ -n "${f}" ]] && LOG_FILES+=("${f}")
    done < <(
      for f in "${rotated_files[@]}"; do
        mtime="$(stat -c '%Y' "${f}" 2>/dev/null)" || continue
        printf '%s\t%s\n' "${mtime}" "${f}"
      done | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2r
    )
  fi
}

collect_log_family_to_file() {
  local base="$1" output="$2" f
  : > "${output}" || return 1
  collect_managed_log_files "${base}"
  LOG_READ_ERRORS=()
  for f in "${LOG_FILES[@]}"; do
    if [[ "${f}" == *.gz ]]; then
      gzip -cd -- "${f}" >> "${output}" 2>/dev/null || { LOG_READ_ERRORS+=("${f}"); return 1; }
    else
      cat -- "${f}" >> "${output}" 2>/dev/null || { LOG_READ_ERRORS+=("${f}"); return 1; }
    fi
  done
}

collect_runtime_logs_to_file() {
  collect_log_family_to_file "${LOG_FILE}" "$1"
}

runtime_extract_recent_from_file() {
  local file="$1" target_group="$2" limit="$3"
  managed_log_file_kind "${LOG_FILE}" "${file}" >/dev/null 2>&1 || return 1
  [[ "${limit}" =~ ^[0-9]+$ && "${limit}" -ge 1 && "${limit}" -le 1000 ]] || return 1
  if [[ "${file}" == *.gz ]]; then
    gzip -cd -- "${file}" 2>/dev/null | LC_ALL=C awk -v group="${target_group}" -v limit="${limit}" '
      /^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]/ {
        if (group != "" && index($0, "组 " group ":") == 0) next
        slot = seen % limit
        rows[slot] = $0
        seen++
      }
      END {
        count = seen < limit ? seen : limit
        for (i = 0; i < count; i++) {
          slot = (seen - 1 - i) % limit
          print rows[slot]
        }
      }
    '
    local -a pipe_status=("${PIPESTATUS[@]}")
    [[ "${pipe_status[0]}" -eq 0 && "${pipe_status[1]}" -eq 0 ]]
    return
  fi

  LC_ALL=C tac -- "${file}" 2>/dev/null | LC_ALL=C awk -v group="${target_group}" -v limit="${limit}" '
    /^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]/ &&
    (group == "" || index($0, "组 " group ":") != 0) {
      print
      count++
      if (count >= limit) exit 75
    }
  '
  local -a pipe_status=("${PIPESTATUS[@]}")
  [[ "${pipe_status[1]}" -eq 75 ]] && return 0
  [[ "${pipe_status[0]}" -eq 0 && "${pipe_status[1]}" -eq 0 ]]
}

collect_recent_runtime_to_file() {
  local target_group="$1" limit="$2" output="$3" candidate part count=0 remaining
  : > "${output}" || return 1
  part="$(mktemp)" || return 1
  collect_managed_log_files "${LOG_FILE}"
  RUNTIME_TOTAL_FILES="${#LOG_FILES[@]}"
  RUNTIME_FILES_SCANNED=0
  RUNTIME_LIMIT_REACHED=0
  RUNTIME_RESULT_COUNT=0
  RUNTIME_READ_ERRORS=()
  for candidate in "${LOG_FILES[@]}"; do
    remaining=$((limit-count))
    (( remaining > 0 )) || { RUNTIME_LIMIT_REACHED=1; break; }
    : > "${part}"
    RUNTIME_FILES_SCANNED=$((RUNTIME_FILES_SCANNED+1))
    if runtime_extract_recent_from_file "${candidate}" "${target_group}" "${remaining}" > "${part}"; then
      cat -- "${part}" >> "${output}" || { rm -f "${part}"; return 1; }
    else
      RUNTIME_READ_ERRORS+=("${candidate}")
    fi
    read -r count < <(wc -l < "${output}")
    if (( count >= limit )); then RUNTIME_LIMIT_REACHED=1; break; fi
  done
  rm -f "${part}"
  RUNTIME_RESULT_COUNT="${count}"
}

runtime_log_renderer_self_test() {
  local dir base raw out unsafe_link rc=0
  dir="$(mktemp -d)" || return 1
  base="${dir}/runtime.log"
  printf '%s\n' '[2026-01-01 00:00:00] [INFO] old-rotated-log' > "${base}-20260101"
  printf '%s\n' '[2026-01-02 00:00:00] [INFO] compressed-log' > "${base}-20260102"
  gzip -f "${base}-20260102"
  printf '%s\n' '[2026-01-03 00:00:00] [INFO] current-log' > "${base}"
  unsafe_link="${base}.9"
  ln -s "${base}" "${unsafe_link}" || rc=1
  raw="${dir}/raw"
  local LOG_FILE="${base}"
  collect_recent_runtime_to_file '' 2 "${raw}" || rc=1
  out="$(cat "${raw}")"
  [[ "${RUNTIME_RESULT_COUNT}" -eq 2 && "${RUNTIME_LIMIT_REACHED}" -eq 1 ]] || rc=1
  [[ "${RUNTIME_TOTAL_FILES}" -eq 3 ]] || rc=1
  [[ "${out}" == *current-log* && "${out}" == *compressed-log* && "${out}" != *old-rotated-log* ]] || rc=1
  rm -rf "${dir}"
  return "${rc}"
}

filter_runtime_logs() {
  local input="$1" output="$2" days="$3" target_group="${4:-}" cutoff
  if [[ "${days}" == "0" ]]; then
    cutoff="0000-00-00 00:00:00"
  else
    cutoff="$(date -d "${days} days ago" '+%F %T' 2>/dev/null)" || return 1
  fi
  awk -v cutoff="${cutoff}" -v group="${target_group}" '
    /^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]/ {
      ts=substr($0,2,19)
      if (ts < cutoff) next
      if (group != "" && index($0, "组 " group ":") == 0) next
      print
    }
  ' "${input}" > "${output}"
}

display_log_file() {
  local file="$1"
  [[ -s "${file}" ]] || { echo "暂无符合条件的项目运行日志"; return 0; }
  if [[ -t 0 && -t 1 ]] && command -v less >/dev/null 2>&1; then
    less -R "${file}"
  else
    cat "${file}"
  fi
}

runtime_logs_menu() {
  local target_group="${1:-}" choice days raw sorted filtered latest failed
  while true; do
    clear 2>/dev/null || true
    line
    if [[ -n "${target_group}" ]]; then
      echo "📌 查看单组运行日志：${target_group}"
    else
      echo "📄 查看 cfdns 项目运行日志"
    fi
    line
    echo "1. 🧾 查看跨全部轮转文件的最近 200 条"
    echo "2. 🕒 查看最近 3 天"
    echo "3. 📅 查看最近 7 天"
    echo "4. 🗓️  查看最近 30 天"
    echo "5. ✍️  自定义最近多少天"
    echo "6. 📚 查看当前保留的全部项目日志"
    echo "0. ↩️  返回"
    read -rp "请选择: " choice || return
    case "${choice}" in
      1) days=0 ;;
      2) days=3 ;;
      3) days=7 ;;
      4) days=30 ;;
      5)
        read -rp "请输入天数（>=1）: " days || return
        [[ "${days}" =~ ^[0-9]+$ && "${days}" -ge 1 ]] || { echo "天数无效"; pause_wait; continue; }
        ;;
      6) days=0 ;;
      0) return ;;
      *) echo "无效选择"; pause_wait; continue ;;
    esac

    if [[ "${choice}" == "1" ]]; then
      latest="$(mktemp)" || { echo "无法创建临时文件"; pause_wait; continue; }
      echo "正在读取最新 200 条；达到上限后停止扫描旧文件……"
      if ! collect_recent_runtime_to_file "${target_group}" 200 "${latest}"; then
        rm -f "${latest}"
        echo "读取项目运行日志失败"
        pause_wait
        continue
      fi
      display_log_file "${latest}"
      rm -f "${latest}"
      echo
      echo "已显示 ${RUNTIME_RESULT_COUNT} 条（最新在前）；扫描文件 ${RUNTIME_FILES_SCANNED}/${RUNTIME_TOTAL_FILES}。"
      [[ "${RUNTIME_LIMIT_REACHED}" -eq 0 ]] || echo "已达到 200 条显示上限。"
      for failed in "${RUNTIME_READ_ERRORS[@]}"; do echo "警告：无法完整读取 ${failed##*/}，该文件结果未显示。" >&2; done
    else
      raw="$(mktemp)" || { echo "无法创建临时文件"; pause_wait; continue; }
      sorted="$(mktemp)" || { rm -f "${raw}"; echo "无法创建临时文件"; pause_wait; continue; }
      filtered="$(mktemp)" || { rm -f "${raw}" "${sorted}"; echo "无法创建临时文件"; pause_wait; continue; }
      if ! collect_runtime_logs_to_file "${raw}"; then
        rm -f "${raw}" "${sorted}" "${filtered}"
        echo "日志族中存在无法读取或损坏的文件，未显示不完整结果。"
        pause_wait
        continue
      fi
      if ! LC_ALL=C sort "${raw}" > "${sorted}"; then
        rm -f "${raw}" "${sorted}" "${filtered}"
        echo "日志排序失败"
        pause_wait
        continue
      fi
      if ! filter_runtime_logs "${sorted}" "${filtered}" "${days}" "${target_group}"; then
        rm -f "${raw}" "${sorted}" "${filtered}"
        echo "日志筛选失败"
        pause_wait
        continue
      fi
      display_log_file "${filtered}"
      rm -f "${raw}" "${sorted}" "${filtered}"
    fi
    pause_wait
  done
}

show_logs() {
  runtime_logs_menu ""
}

follow_logs() {
  touch "${LOG_FILE}" || { echo "无法创建或访问当前项目日志"; return 1; }
  chmod 600 "${LOG_FILE}" || { echo "无法设置当前项目日志权限"; return 1; }
  echo "按 Ctrl+C 退出实时日志。实时模式会自动跟随日志轮转；历史轮转日志请使用菜单 19 查询。"
  tail -n 50 -F "${LOG_FILE}"
}

show_group_runtime_logs() {
  echo
  select_group || { echo "序号无效"; return; }
  runtime_logs_menu "${CHOSEN_GROUP_NAME}"
}


show_status() {
  systemctl status "${SERVICE_NAME}" --no-pager -l || true
  echo
  systemctl status "${TIMER_NAME}" --no-pager -l || true
  echo
  echo "LOG_LEVEL=${LOG_LEVEL}"
  echo "基础调度器=5秒；每组检测周期以 groups.tsv 为准（最短5秒）"
  echo "FORCE_RECONCILE_SEC=${FORCE_RECONCILE_SEC}"
  echo "DNS_SERVER=${DNS_SERVER:-系统默认解析器}"
  echo "LOG_DIR=${LOG_DIR}"
}


show_dep_status() {
  printf '%-18s %-10s\n' "Command" "Status"
  printf '%-18s %-10s\n' "------------------" "----------"
  for cmd in curl jq dig flock logrotate zcat gzip tac awk sed grep comm mktemp paste cut tr date wc stat find xargs tar install; do
    if command -v "${cmd}" >/dev/null 2>&1; then
      printf '%-18s %-10s\n' "${cmd}" "OK"
    else
      printf '%-18s %-10s\n' "${cmd}" "MISSING"
    fi
  done
}

show_runstate() {
  local group epoch readable shown=0 tmp
  if [[ ! -s "${RUNSTATE_FILE}" ]]; then
    echo "暂无运行状态记录"
    return
  fi

  tmp="$(mktemp)" || { echo "无法创建临时文件"; return 1; }
  if ! sort -t $'\t' -k1,1 "${RUNSTATE_FILE}" > "${tmp}" 2>/dev/null; then
    rm -f "${tmp}"
    echo "无法读取执行状态"
    return 1
  fi
  while IFS=$'\t' read -r group epoch _; do
    [[ -n "${group}" && "${epoch}" =~ ^[0-9]+$ ]] || continue
    readable="$(date -d "@${epoch}" '+%F %T' 2>/dev/null || true)"
    [[ -n "${readable}" ]] || continue
    printf '[%s] %s\n' "${group}" "${readable}"
    shown=$((shown+1))
  done < "${tmp}"
  rm -f "${tmp}"
  [[ "${shown}" -gt 0 ]] || echo "暂无有效的运行状态记录"
}

collect_history_to_file() {
  collect_log_family_to_file "${HISTORY_FILE}" "$1"
}

managed_history_file_kind() {
  local path="$1" suffix
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  if [[ "${path}" == "${HISTORY_FILE}" ]]; then
    printf '%s\n' current
    return 0
  fi

  suffix="${path#"${HISTORY_FILE}"}"
  [[ "${suffix}" != "${path}" ]] || return 1
  if [[ "${suffix}" =~ ^\.[0-9]+(\.gz)?$ || "${suffix}" =~ ^-[0-9]{8}(\.gz)?$ ]]; then
    printf '%s\n' rotated
    return 0
  fi
  return 1
}

collect_managed_history_files() {
  local f mtime
  local -a rotated_files=()
  HISTORY_FILES=()

  if managed_history_file_kind "${HISTORY_FILE}" >/dev/null 2>&1; then
    HISTORY_FILES+=("${HISTORY_FILE}")
  fi

  shopt -s nullglob
  for f in "${HISTORY_FILE}".* "${HISTORY_FILE}"-*; do
    managed_history_file_kind "${f}" >/dev/null 2>&1 || continue
    rotated_files+=("${f}")
  done
  shopt -u nullglob

  if [[ "${#rotated_files[@]}" -gt 0 ]]; then
    while IFS=$'\t' read -r _ f; do
      [[ -n "${f}" ]] && HISTORY_FILES+=("${f}")
    done < <(
      for f in "${rotated_files[@]}"; do
        mtime="$(stat -c '%Y' "${f}" 2>/dev/null)" || continue
        printf '%s\t%s\n' "${mtime}" "${f}"
      done | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2r
    )
  fi
}

history_file_may_match_cutoff() {
  local path="$1" cutoff_day="$2" suffix stamp compact_cutoff
  [[ "${path}" == "${HISTORY_FILE}" ]] && return 0
  suffix="${path#"${HISTORY_FILE}"}"
  if [[ "${suffix}" =~ ^[.-]([0-9]{8})(\.gz)?$ ]]; then
    stamp="${BASH_REMATCH[1]}"
    compact_cutoff="${cutoff_day//-/}"
    [[ "${stamp}" < "${compact_cutoff}" ]] && return 1
  fi
  return 0
}

history_extract_recent_from_file() {
  local file="$1" cutoff="$2" record_mode="$3" target_group="$4" limit="$5"
  managed_history_file_kind "${file}" >/dev/null 2>&1 || return 1
  [[ "${record_mode}" == "all" || "${record_mode}" == "deleted" ]] || return 1
  [[ "${limit}" =~ ^[0-9]+$ && "${limit}" -ge 1 && "${limit}" -le 1000 ]] || return 1

  if [[ "${file}" == *.gz ]]; then
    gzip -cd -- "${file}" 2>/dev/null | LC_ALL=C awk -F '\t' \
      -v cutoff="${cutoff}" -v record_mode="${record_mode}" \
      -v target_group="${target_group}" -v limit="${limit}" '
        function wanted() {
          if (NF != 7 || length($1) != 19) return 0
          if ($1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) return 0
          if ($1 < cutoff) return 0
          if (target_group != "" && $2 != target_group) return 0
          if (record_mode == "deleted" && $3 != "DELETE") return 0
          return 1
        }
        wanted() {
          slot = seen % limit
          rows[slot] = $0
          seen++
        }
        END {
          count = seen < limit ? seen : limit
          for (i = 0; i < count; i++) {
            slot = (seen - 1 - i) % limit
            print rows[slot]
          }
        }
      '
    return
  fi

  (
    set +o pipefail
    LC_ALL=C tac -- "${file}" 2>/dev/null | LC_ALL=C awk -F '\t' \
      -v cutoff="${cutoff}" -v record_mode="${record_mode}" \
      -v target_group="${target_group}" -v limit="${limit}" '
        NF == 7 && length($1) == 19 &&
        $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ &&
        $1 >= cutoff &&
        (target_group == "" || $2 == target_group) &&
        (record_mode != "deleted" || $3 == "DELETE") {
          print
          count++
          if (count >= limit) exit 75
        }
      '
    local -a pipe_status=("${PIPESTATUS[@]}")
    [[ "${pipe_status[1]}" -eq 75 ]] && exit 0
    [[ "${pipe_status[1]}" -eq 0 && "${pipe_status[0]}" -eq 0 ]]
  )
}

collect_recent_history_to_file() {
  local cutoff="$1" record_mode="$2" target_group="$3" limit="$4" output="$5"
  local cutoff_day candidate part count=0 remaining
  : > "${output}" || return 1
  part="$(mktemp)" || return 1
  cutoff_day="${cutoff%% *}"

  HISTORY_READ_ERRORS=()
  HISTORY_FILES_SCANNED=0
  HISTORY_FILES_SKIPPED=0
  HISTORY_LIMIT_REACHED=0
  HISTORY_RESULT_COUNT=0
  collect_managed_history_files
  HISTORY_TOTAL_FILES="${#HISTORY_FILES[@]}"

  for candidate in "${HISTORY_FILES[@]}"; do
    if ! history_file_may_match_cutoff "${candidate}" "${cutoff_day}"; then
      HISTORY_FILES_SKIPPED=$((HISTORY_FILES_SKIPPED+1))
      continue
    fi
    remaining=$((limit-count))
    (( remaining > 0 )) || { HISTORY_LIMIT_REACHED=1; break; }
    : > "${part}"
    HISTORY_FILES_SCANNED=$((HISTORY_FILES_SCANNED+1))
    if history_extract_recent_from_file "${candidate}" "${cutoff}" "${record_mode}" "${target_group}" "${remaining}" > "${part}"; then
      cat -- "${part}" >> "${output}" || { rm -f "${part}"; return 1; }
    else
      HISTORY_READ_ERRORS+=("${candidate}")
    fi
    read -r count < <(wc -l < "${output}")
    if (( count >= limit )); then
      HISTORY_LIMIT_REACHED=1
      break
    fi
  done

  rm -f "${part}"
  HISTORY_RESULT_COUNT="${count}"
}

print_history_header() {
  local record_mode="$1"
  if [[ "${record_mode}" == "all" ]]; then
    echo "显示字段：时间、组、动作、IP、源域名、模式、目标"
  else
    echo "显示字段：时间、组、删除的 IP、源域名、模式、目标"
  fi
}

render_history_data_file() {
  local input="$1" record_mode="$2"
  local record_time group action ip source_domain mode metadata extra target shown=0

  while IFS=$'\t' read -r record_time group action ip source_domain mode metadata extra; do
    [[ -n "${record_time}" && -n "${group}" && -n "${action}" && -n "${ip}" ]] || continue
    [[ -z "${extra:-}" ]] || continue
    target="${metadata%%|*}"
    if [[ "${record_mode}" == "all" ]]; then
      printf '\n[%s] %s\n' "${record_time}" "${group}"
      printf '  动作：%s  IP：%s  模式：%s\n' "${action}" "${ip}" "${mode}"
    else
      printf '\n[%s] %s\n' "${record_time}" "${group}"
      printf '  删除的 IP：%s  模式：%s\n' "${ip}" "${mode}"
    fi
    printf '  源域名：%s\n  目标：%s\n' "${source_domain}" "${target}"
    shown=$((shown+1))
  done < "${input}"

  [[ "${shown}" -gt 0 ]] || echo "暂无符合条件的历史记录"
}

delete_managed_history_file() {
  local target="$1" kind
  kind="$(managed_history_file_kind "${target}" 2>/dev/null)" || return 1
  if [[ "${kind}" == "current" ]]; then
    : > "${target}" || return 1
    chmod 600 "${target}" 2>/dev/null || true
  else
    rm -- "${target}" 2>/dev/null || return 1
  fi
}

history_renderer_self_test() {
  local dir output result rendered rotated_old rotated_new unsafe_link rc=0
  local HISTORY_FILE
  dir="$(mktemp -d)" || return 1
  HISTORY_FILE="${dir}/cf-dns-sync-history.tsv"
  rotated_old="${HISTORY_FILE}-20260101"
  rotated_new="${HISTORY_FILE}-20260102.gz"
  unsafe_link="${HISTORY_FILE}.9"
  output="${dir}/output.tsv"

  printf '2026-01-01 03:04:05\ttest-group\tADD\t203.0.113.10\tsource.example.invalid\tALL_IPS\ttarget.example.invalid|self_test\n' > "${rotated_old}"
  printf '2026-01-02 03:04:05\ttest-group\tDELETE\t203.0.113.20\tsource.example.invalid\tALL_IPS\ttarget.example.invalid|self_test\n' | gzip -c > "${rotated_new}" || rc=1
  printf '2026-01-03 03:04:05\ttest-group\tADD\t203.0.113.30\tsource.example.invalid\tALL_IPS\ttarget.example.invalid|self_test\n' > "${HISTORY_FILE}"
  ln -s "${HISTORY_FILE}" "${unsafe_link}" || rc=1

  collect_recent_history_to_file '2026-01-02 00:00:00' all test-group 2 "${output}" || rc=1
  result="$(cat "${output}" 2>/dev/null)"
  [[ "${result}" == *$'203.0.113.30'* && "${result}" == *$'203.0.113.20'* ]] || rc=1
  [[ "${result}" != *$'203.0.113.10'* && "${HISTORY_TOTAL_FILES}" -eq 3 && "${HISTORY_FILES_SCANNED}" -eq 2 && "${HISTORY_LIMIT_REACHED}" -eq 1 ]] || rc=1

  collect_recent_history_to_file '2026-01-02 00:00:00' all test-group 10 "${output}" || rc=1
  [[ "${HISTORY_FILES_SKIPPED}" -eq 1 && "${HISTORY_RESULT_COUNT}" -eq 2 ]] || rc=1

  collect_recent_history_to_file '2026-01-01 00:00:00' deleted test-group 1 "${output}" || rc=1
  result="$(cat "${output}" 2>/dev/null)"
  [[ "${result}" == *$'203.0.113.20'* && "${result}" != *$'203.0.113.30'* ]] || rc=1
  rendered="$(render_history_data_file "${output}" deleted 2>/dev/null)"
  [[ "${rendered}" == *$'203.0.113.20'* ]] || rc=1
  delete_managed_history_file "${rotated_new}" || rc=1
  [[ ! -e "${rotated_new}" ]] || rc=1
  if delete_managed_history_file "${unsafe_link}" 2>/dev/null; then rc=1; fi
  [[ -L "${unsafe_link}" ]] || rc=1
  delete_managed_history_file "${HISTORY_FILE}" || rc=1
  [[ -f "${HISTORY_FILE}" && ! -s "${HISTORY_FILE}" ]] || rc=1

  rm -f -- "${rotated_old}" "${unsafe_link}" "${HISTORY_FILE}" "${output}"
  rmdir -- "${dir}" 2>/dev/null || rc=1
  return "${rc}"
}

render_history_table() {
  local days="$1" record_mode="$2" target_group="${3:-}" limit="${4:-200}"
  local cutoff output failed
  cutoff="$(date -d "${days} days ago" '+%F %T' 2>/dev/null)" || { echo "无法计算历史时间范围"; return 1; }
  output="$(mktemp)" || { echo "无法创建临时文件"; return 1; }

  echo "正在读取最新记录；达到 ${limit} 条后立即停止扫描后续轮转文件……"
  if ! collect_recent_history_to_file "${cutoff}" "${record_mode}" "${target_group}" "${limit}" "${output}"; then
    rm -f "${output}"
    echo "读取历史记录失败"
    return 1
  fi

  print_history_header "${record_mode}"
  render_history_data_file "${output}" "${record_mode}"
  rm -f "${output}"
  echo
  echo "已显示 ${HISTORY_RESULT_COUNT} 条（最新在前）；扫描文件 ${HISTORY_FILES_SCANNED}/${HISTORY_TOTAL_FILES}。"
  [[ "${HISTORY_FILES_SKIPPED}" -eq 0 ]] || echo "已按日期跳过 ${HISTORY_FILES_SKIPPED} 个确定早于查询范围的轮转文件。"
  [[ "${HISTORY_LIMIT_REACHED}" -eq 0 ]] || echo "已达到 ${limit} 条显示上限；可缩小组/类型范围，或在每日文件管理中选择具体日期。"
  for failed in "${HISTORY_READ_ERRORS[@]}"; do
    echo "警告：无法完整读取 ${failed##*/}，该文件的结果未显示。" >&2
  done
}

render_single_history_file() {
  local file="$1" limit="${2:-200}" output count
  managed_history_file_kind "${file}" >/dev/null 2>&1 || { echo "文件已不存在或不是受管历史文件"; return 1; }
  output="$(mktemp)" || { echo "无法创建临时文件"; return 1; }
  [[ "${file}" != *.gz ]] || echo "正在解压所选单日文件；不会读取其他日期的日志……"
  if ! history_extract_recent_from_file "${file}" '0000-00-00 00:00:00' all '' "${limit}" > "${output}"; then
    rm -f "${output}"
    echo "无法完整读取 ${file##*/}；未显示不完整结果。"
    return 1
  fi
  read -r count < <(wc -l < "${output}")
  print_history_header all
  render_history_data_file "${output}" all
  rm -f "${output}"
  echo
  echo "文件：${file##*/}；已显示 ${count} 条（最新在前，最多 ${limit} 条）。"
}

confirm_delete_history_file() {
  local target="$1" kind size identity current_identity confirm action rc=0
  kind="$(managed_history_file_kind "${target}" 2>/dev/null)" || { echo "文件已不存在或不是受管历史文件"; return 1; }
  size="$(stat -c '%s' "${target}" 2>/dev/null)" || { echo "无法读取文件大小"; return 1; }
  identity="$(stat -c '%d:%i' "${target}" 2>/dev/null)" || { echo "无法确认目标文件身份"; return 1; }
  if [[ "${kind}" == "current" ]]; then action="清空当前历史文件"; else action="删除轮转历史文件"; fi

  echo
  echo "操作：${action}"
  echo "目标：${target##*/}"
  echo "数量：1 个文件；大小：${size} 字节"
  echo "此操作不可撤销，但不会影响普通运行日志或故障转移日志。"
  read -rp "输入 DELETE 确认，其他输入取消: " confirm || return 1
  [[ "${confirm}" == "DELETE" ]] || { echo "已取消"; return 0; }

  if ! exec 8>"${HISTORY_LOCK_FILE}"; then
    echo "无法打开同步锁，本次未删除"
    return 1
  fi
  if ! flock -w 30 8; then
    echo "同步任务正在运行，等待30秒后仍未取得锁；本次未删除"
    exec 8>&-
    return 1
  fi
  current_identity="$(stat -c '%d:%i' "${target}" 2>/dev/null || true)"
  if [[ -z "${current_identity}" || "${current_identity}" != "${identity}" ]]; then
    echo "目标文件在确认期间已轮转、替换或消失；为避免误删，本次未操作"
    rc=1
  elif ! delete_managed_history_file "${target}"; then
    rc=1
  fi
  flock -u 8
  exec 8>&-

  if [[ "${rc}" -eq 0 ]]; then
    echo "已完成：${action}（${target##*/}）"
  else
    echo "操作失败；目标文件未被报告为已删除"
  fi
  return "${rc}"
}

history_files_menu() {
  local selection index file action kind size modified
  while true; do
    clear 2>/dev/null || true
    line
    color "1;36" "📂 浏览或删除每日 IP 历史文件"
    echo
    line
    collect_managed_history_files
    if [[ "${#HISTORY_FILES[@]}" -eq 0 ]]; then
      echo "暂无受管 IP 历史文件"
      pause_wait
      return
    fi

    for index in "${!HISTORY_FILES[@]}"; do
      file="${HISTORY_FILES[${index}]}"
      kind="$(managed_history_file_kind "${file}" 2>/dev/null)" || continue
      size="$(stat -c '%s' "${file}" 2>/dev/null || printf '?')"
      modified="$(stat -c '%y' "${file}" 2>/dev/null || printf '?')"
      [[ "${kind}" == "current" ]] && kind="当前" || kind="轮转"
      printf '[%d] %s\n' "$((index+1))" "${file##*/}"
      printf '  类型：%s  大小：%s 字节  修改时间：%s\n' "${kind}" "${size}" "${modified:0:19}"
    done
    echo
    echo "选择一个文件后，可查看其最新 200 条，或在二次确认后删除；当前文件执行安全清空。"
    read -rp "请输入文件序号，输入 0 返回: " selection || return
    [[ "${selection}" == "0" ]] && return
    if [[ ! "${selection}" =~ ^[1-9][0-9]{0,2}$ ]] || (( 10#${selection} > ${#HISTORY_FILES[@]} )); then
      echo "序号无效"
      pause_wait
      continue
    fi
    index=$((10#${selection}-1))
    file="${HISTORY_FILES[${index}]}"
    echo
    echo "1. 查看此文件最新 200 条"
    echo "2. 删除此文件（当前文件将被清空）"
    echo "0. 返回文件列表"
    read -rp "请选择: " action || return
    case "${action}" in
      1) render_single_history_file "${file}" 200; pause_wait ;;
      2) confirm_delete_history_file "${file}"; pause_wait ;;
      0) ;;
      *) echo "无效选择"; pause_wait ;;
    esac
  done
}

history_menu() {
  local days record_mode scope group="" time_choice mode_choice scope_choice limit_choice limit

  while true; do
    clear 2>/dev/null || true
    line
    color "1;36" "📜 查看或管理域名 IP 历史记录"
    echo
    line
    echo "1. 🕒 查看最近三天的历史"
    echo "2. 📅 查看最近一周的历史"
    echo "3. 🗓️  查看最近一个月的历史"
    echo "4. ✍️  自定义时间：查看多少天前到今天的历史"
    echo "5. 🧾 查看最近半年的历史"
    echo "6. 📂 浏览或删除每日历史文件"
    echo "0. ↩️  返回主菜单"
    echo "提示：查询默认只显示最新 200 条，并在达到上限后停止读取旧文件。"
    line
    if ! read -rp "请选择时间范围或管理功能: " time_choice; then
      return
    fi

    case "${time_choice}" in
      1) days=3 ;;
      2) days=7 ;;
      3) days=30 ;;
      4)
        read -rp "请输入天数，例如 10 表示最近10天: " days || return
        [[ "${days}" =~ ^[0-9]+$ && "${days}" -ge 1 ]] || { echo "天数无效"; pause_wait; continue; }
        ;;
      5) days=180 ;;
      6) history_files_menu; continue ;;
      0) return ;;
      *) echo "无效选择"; pause_wait; continue ;;
    esac

    echo
    echo "请选择记录类型："
    echo "1. 🔁 全部变更记录（新增 + 更新 + 删除）"
    echo "2. 🗑️  仅删除旧 IP 记录"
    read -rp "请选择 [1-2]: " mode_choice || return
    case "${mode_choice}" in
      1) record_mode="all" ;;
      2) record_mode="deleted" ;;
      *) echo "无效选择"; pause_wait; continue ;;
    esac

    echo
    echo "请选择查看范围："
    echo "1. 🌍 全部组"
    echo "2. 📦 单个组"
    read -rp "请选择 [1-2]: " scope_choice || return
    case "${scope_choice}" in
      1) scope="all"; group="" ;;
      2)
        echo
        select_group || { echo "序号无效"; pause_wait; continue; }
        scope="one"
        group="${CHOSEN_GROUP_NAME}"
        ;;
      *) echo "无效选择"; pause_wait; continue ;;
    esac

    echo
    echo "单次显示上限："
    echo "1. 100 条"
    echo "2. 200 条（默认）"
    echo "3. 500 条"
    echo "4. 1000 条"
    read -rp "请选择 [1-4，回车默认 200]: " limit_choice || return
    case "${limit_choice}" in
      1) limit=100 ;;
      ''|2) limit=200 ;;
      3) limit=500 ;;
      4) limit=1000 ;;
      *) echo "无效选择"; pause_wait; continue ;;
    esac

    echo
    echo "历史范围：最近 ${days} 天；记录类型：${record_mode}；查看范围：${scope}${group:+ / ${group}}；上限：${limit} 条"
    echo
    render_history_table "${days}" "${record_mode}" "${group}" "${limit}"
    pause_wait
  done
}

self_check() {
  local errors=0 warnings=0 group_count=0 enabled_count=0 failover_count=0 failover_enabled_count=0
  local line_no=0 row field_count name enabled interval token zone target ttl proxied mode sources_csv src_count key source_domain
  local fo_group fo_enabled fo_backup fo_ptarget fo_btarget fo_type fo_port fo_location fo_stable fo_fast fo_pf fo_bs fo_pr
  local primary_sources overlap worst_fast worst_stable group_worst theoretical_total=0 state_group state_role state_phase state_index
  local gp_usage_valid=0 gp_usage_invalid=0 gp_usage_summary
  declare -A seen_names=() seen_targets=() seen_fo=() seen_state=() group_enabled_map=()
  echo "🩺 cfdns v${APP_VERSION} 自检"
  line
  check_ok(){ printf '✅ %s\n' "$*"; }
  check_warn(){ warnings=$((warnings+1)); printf '⚠️  %s\n' "$*"; }
  check_fail(){ errors=$((errors+1)); printf '❌ %s\n' "$*"; }

  [[ "$(id -u)" -eq 0 ]] && check_ok "当前为 root" || check_fail "请使用 root 运行"
  for d in "${BASE_DIR}" "${VAR_DIR}" "${LOG_DIR}"; do [[ -d "${d}" ]] && check_ok "目录存在：${d}" || check_fail "目录缺失：${d}"; done
  for f in "${SETTINGS_FILE}" "${GROUPS_FILE}" "${FAILOVER_FILE}" "${LOG_FILE}" "${HISTORY_FILE}" "${FAILOVER_HISTORY_FILE}" "${FAILOVER_STATE_FILE}" "${GLOBALPING_USAGE_FILE}" /usr/local/bin/cfdns /usr/local/bin/cf-dns-sync.sh; do [[ -e "${f}" ]] && check_ok "文件存在：${f}" || check_fail "文件缺失：${f}"; done
  bash -n "${SETTINGS_FILE}" >/dev/null 2>&1 && check_ok "settings.conf 语法正常" || check_fail "settings.conf 语法异常"
  bash -n /usr/local/bin/cfdns >/dev/null 2>&1 && check_ok "管理脚本语法正常" || check_fail "管理脚本语法异常"
  bash -n /usr/local/bin/cf-dns-sync.sh >/dev/null 2>&1 && check_ok "同步脚本语法正常" || check_fail "同步脚本语法异常"
  grep -Fqx "APP_VERSION=\"${APP_VERSION}\"" /usr/local/bin/cfdns 2>/dev/null && check_ok "管理脚本版本为${APP_VERSION}" || check_fail "管理脚本版本与当前版本不一致"
  grep -Fqx "APP_VERSION=\"${APP_VERSION}\"" /usr/local/bin/cf-dns-sync.sh 2>/dev/null && check_ok "同步脚本版本为${APP_VERSION}" || check_fail "同步脚本版本与当前版本不一致"
  for cmd in curl jq dig flock logrotate zcat gzip tac awk sed grep comm mktemp paste cut tr date wc cmp systemctl tar install xargs stat sleep; do command -v "${cmd}" >/dev/null 2>&1 && check_ok "依赖：${cmd}" || check_fail "缺少依赖：${cmd}"; done

  case "${LOG_LEVEL}" in NONE|OFF|ERROR|INFO|DEBUG) check_ok "日志等级合法：${LOG_LEVEL}" ;; *) check_fail "日志等级非法：${LOG_LEVEL}" ;; esac
  [[ "${FORCE_RECONCILE_SEC}" =~ ^[0-9]+$ && "${FORCE_RECONCILE_SEC}" -ge 60 ]] && check_ok "强制校准周期：${FORCE_RECONCILE_SEC}s" || check_fail "FORCE_RECONCILE_SEC 必须>=60"
  [[ "${DNS_QUERY_TIMEOUT_SEC}" =~ ^[0-9]+$ && "${DNS_QUERY_TIMEOUT_SEC}" -ge 1 ]] && check_ok "DNS查询超时：${DNS_QUERY_TIMEOUT_SEC}s" || check_fail "DNS_QUERY_TIMEOUT_SEC 必须>=1"
  [[ "${GLOBALPING_MAX_TESTS_PER_HOUR}" =~ ^[0-9]+$ && "${GLOBALPING_MAX_TESTS_PER_HOUR}" -ge 1 ]] && check_ok "Globalping本机预算：${GLOBALPING_MAX_TESTS_PER_HOUR} tests/h" || check_fail "GLOBALPING_MAX_TESTS_PER_HOUR 非法"
  [[ "${GLOBALPING_MEASUREMENT_TIMEOUT_SEC}" =~ ^[0-9]+$ && "${GLOBALPING_MEASUREMENT_TIMEOUT_SEC}" -ge 5 && "${GLOBALPING_MEASUREMENT_TIMEOUT_SEC}" -le 30 ]] && check_ok "Globalping测量超时：${GLOBALPING_MEASUREMENT_TIMEOUT_SEC}s" || check_fail "GLOBALPING_MEASUREMENT_TIMEOUT_SEC 必须5~30"
  [[ "${GLOBALPING_POLL_MAX_SEC}" =~ ^[0-9]+$ && "${GLOBALPING_POLL_MAX_SEC}" -ge "${GLOBALPING_MEASUREMENT_TIMEOUT_SEC}" && "${GLOBALPING_POLL_MAX_SEC}" -le 60 ]] && check_ok "Globalping最长等待：${GLOBALPING_POLL_MAX_SEC}s" || check_fail "GLOBALPING_POLL_MAX_SEC 非法"
  if [[ -z "${GLOBALPING_API_TOKEN}" && "${GLOBALPING_MAX_TESTS_PER_HOUR}" -gt 250 ]]; then check_warn "匿名Globalping预算大于250 tests/h，建议设为240以内"; fi
  if gp_usage_summary="$(awk 'NF == 1 && $1 ~ /^[0-9]+$/ {ok++; next} NF {bad++} END{print ok+0, bad+0}' "${GLOBALPING_USAGE_FILE}" 2>/dev/null)"; then
    read -r gp_usage_valid gp_usage_invalid <<< "${gp_usage_summary}"
    [[ "${gp_usage_invalid}" -eq 0 ]] && check_ok "Globalping用量文件格式正常（${gp_usage_valid}条）" || check_fail "Globalping用量文件有${gp_usage_invalid}条非法记录"
  else
    check_fail "Globalping用量文件无法读取"
  fi
  if grep -Fq 'target:$target,limit:1,locations:' /usr/local/bin/cf-dns-sync.sh 2>/dev/null; then
    check_fail "Globalping请求同时设置全局limit和位置limit，API会拒绝"
  elif grep -Fq 'target:$target,locations:[{magic:$location,limit:1}]' /usr/local/bin/cf-dns-sync.sh 2>/dev/null; then
    check_ok "Globalping请求仅使用位置limit=1"
  else
    check_warn "无法确认Globalping单探针limit配置"
  fi

  [[ "$(stat -c '%a' "${LOG_DIR}" 2>/dev/null || true)" == 700 ]] && check_ok "日志目录权限为700" || check_warn "日志目录权限不是700"
  for f in "${LOG_FILE}" "${HISTORY_FILE}" "${FAILOVER_HISTORY_FILE}" "${SETTINGS_FILE}" "${GROUPS_FILE}" "${FAILOVER_FILE}" "${FAILOVER_STATE_FILE}" "${GLOBALPING_USAGE_FILE}"; do [[ "$(stat -c '%a' "${f}" 2>/dev/null || true)" == 600 ]] && check_ok "权限600：${f}" || check_warn "权限不是600：${f}"; done
  if legacy_log_family_exists_local "${LEGACY_LOG_FILE}" || legacy_log_family_exists_local "${LEGACY_HISTORY_FILE}"; then check_warn "检测到/var/log根目录旧版日志，一键修复可迁移"; else check_ok "旧版根目录日志已完成迁移"; fi

  while IFS= read -r row || [[ -n "${row}" ]]; do
    line_no=$((line_no+1)); [[ -z "${row}" || "${row}" =~ ^# ]] && continue
    group_count=$((group_count+1))
    split_tsv_line "${row}"
    field_count="${#TSV_FIELDS[@]}"
    if (( field_count != 10 )); then check_fail "groups.tsv第${line_no}行字段数量应为10，实际=${field_count}"; continue; fi
    name="${TSV_FIELDS[0]}"; enabled="${TSV_FIELDS[1]}"; interval="${TSV_FIELDS[2]}"; token="${TSV_FIELDS[3]}"
    zone="${TSV_FIELDS[4]}"; target="${TSV_FIELDS[5]}"; ttl="${TSV_FIELDS[6]}"; proxied="${TSV_FIELDS[7]}"
    mode="${TSV_FIELDS[8]}"; sources_csv="${TSV_FIELDS[9]}"
    valid_group_name_field "${name}" || { check_fail "groups.tsv第${line_no}行组名为空、过长或含不安全字符"; continue; }
    [[ "${enabled}" == true ]] && enabled_count=$((enabled_count+1))
    group_enabled_map["${name}"]="${enabled}"
    if [[ -n "${seen_names["${name}"]+x}" ]]; then check_fail "组名重复：${name}"; else seen_names["${name}"]=1; fi
    key="${zone,,}|${target,,}"
    if [[ -n "${seen_targets["${key}"]+x}" ]]; then check_fail "目标记录重复管理：${target}（${seen_targets["${key}"]} / ${name}）"; else seen_targets["${key}"]="${name}"; fi
    [[ "${enabled}" == true || "${enabled}" == false ]] || check_fail "组 ${name}: enabled非法"
    [[ "${interval}" =~ ^[0-9]+$ && "${interval}" -ge 5 ]] || check_fail "组 ${name}: 周期必须>=5秒"
    valid_api_token_field "${token}" || check_fail "组 ${name}: Token为空或格式错误"
    valid_zone_id "${zone}" || check_fail "组 ${name}: Zone ID格式错误"
    valid_domain "${target}" || check_fail "组 ${name}: 目标域名格式错误"
    valid_ttl "${ttl}" || check_fail "组 ${name}: TTL必须为1或60~86400"
    [[ "${proxied}" == false ]] || check_fail "组 ${name}: 仅支持proxied=false"
    [[ "${mode}" == ALL_IPS || "${mode}" == SINGLE_IP ]] || check_fail "组 ${name}: mode非法"
    src_count="$(count_sources_csv "${sources_csv:-}")"; [[ "${src_count}" -ge 1 && "${src_count}" -le 20 ]] || check_fail "组 ${name}: PRIMARY源域名数量=${src_count}，应为1~20"
    parse_sources_to_array "${sources_csv:-}"; for source_domain in "${SOURCES_ARRAY[@]}"; do valid_domain "${source_domain}" || check_fail "组 ${name}: PRIMARY源域名格式错误：${source_domain}"; done
  done < "${GROUPS_FILE}"
  [[ "${group_count}" -gt 0 ]] && check_ok "配置组数量：${group_count}" || check_warn "当前没有配置组"
  [[ "${enabled_count}" -gt 0 ]] && check_ok "启用组数量：${enabled_count}" || check_warn "当前没有启用组"

  line_no=0
  while IFS= read -r row || [[ -n "${row}" ]]; do
    line_no=$((line_no+1)); [[ -z "${row}" || "${row}" =~ ^# ]] && continue
    failover_count=$((failover_count+1))
    split_tsv_line "${row}"
    field_count="${#TSV_FIELDS[@]}"
    if (( field_count != 13 )); then check_fail "failover.tsv第${line_no}行字段数量应为13，实际=${field_count}"; continue; fi
    fo_group="${TSV_FIELDS[0]}"; fo_enabled="${TSV_FIELDS[1]}"; fo_backup="${TSV_FIELDS[2]}"
    fo_ptarget="${TSV_FIELDS[3]}"; fo_btarget="${TSV_FIELDS[4]}"; fo_type="${TSV_FIELDS[5]}"; fo_port="${TSV_FIELDS[6]}"
    fo_location="${TSV_FIELDS[7]}"; fo_stable="${TSV_FIELDS[8]}"; fo_fast="${TSV_FIELDS[9]}"
    fo_pf="${TSV_FIELDS[10]}"; fo_bs="${TSV_FIELDS[11]}"; fo_pr="${TSV_FIELDS[12]}"
    [[ -n "${fo_group}" ]] || { check_fail "failover.tsv第${line_no}行组名为空"; continue; }
    [[ "${fo_enabled}" == true ]] && failover_enabled_count=$((failover_enabled_count+1))
    if [[ -n "${seen_fo["${fo_group}"]+x}" ]]; then check_fail "故障转移组重复：${fo_group}"; else seen_fo["${fo_group}"]=1; fi
    [[ -n "${seen_names["${fo_group}"]+x}" ]] || check_fail "故障转移配置引用不存在的组：${fo_group}"
    [[ "${fo_enabled}" == true || "${fo_enabled}" == false ]] || check_fail "组 ${fo_group}: failover enabled非法"
    if [[ "${fo_enabled}" == true && "${group_enabled_map["${fo_group}"]:-missing}" != true ]]; then check_warn "组 ${fo_group}: 故障转移已启用，但主组状态为${group_enabled_map["${fo_group}"]:-missing}，自动Globalping检测不会运行"; fi
    primary_sources="$(get_group_primary_sources "${fo_group}" 2>/dev/null || true)"
    validate_sources_csv "${fo_backup}" || check_fail "组 ${fo_group}: BACKUP源域名必须为1~20个有效域名"
    overlap="$(csv_overlap_value "${primary_sources}" "${fo_backup}" || true)"; [[ -z "${overlap}" ]] || check_fail "组 ${fo_group}: PRIMARY/BACKUP重复域名=${overlap}"
    valid_health_target "${fo_ptarget}" || check_fail "组 ${fo_group}: PRIMARY检测目标格式错误"
    valid_health_target "${fo_btarget}" || check_fail "组 ${fo_group}: BACKUP检测目标格式错误"
    [[ "${fo_type}" == PING_ICMP || "${fo_type}" == PING_TCP ]] || check_fail "组 ${fo_group}: 检测类型非法"
    if [[ "${fo_type}" == PING_TCP ]]; then [[ "${fo_port}" =~ ^[0-9]+$ && "${fo_port}" -ge 1 && "${fo_port}" -le 65535 ]] || check_fail "组 ${fo_group}: TCP端口非法"; fi
    case "${fo_location,,}" in china|china+*|cn|cn+*) ;; *) check_fail "组 ${fo_group}: 位置必须是中国区（China/CN）" ;; esac
    [[ "${fo_stable}" =~ ^[0-9]+$ && "${fo_fast}" =~ ^[0-9]+$ && "${fo_stable}" -ge 60 && "${fo_fast}" -ge 60 && "${fo_stable}" -ge "${fo_fast}" ]] || check_fail "组 ${fo_group}: 稳定/快速周期非法"
    [[ "${fo_pf}" =~ ^[0-9]+$ && "${fo_bs}" =~ ^[0-9]+$ && "${fo_pr}" =~ ^[0-9]+$ && "${fo_pf}" -ge 1 && "${fo_bs}" -ge 1 && "${fo_pr}" -ge 1 ]] || check_fail "组 ${fo_group}: 阈值非法"
    if [[ "${fo_enabled}" == true && "${group_enabled_map["${fo_group}"]:-false}" == true && "${fo_fast}" =~ ^[0-9]+$ && "${fo_stable}" =~ ^[0-9]+$ && "${fo_fast}" -gt 0 && "${fo_stable}" -gt 0 ]]; then
      worst_fast=$(( (3600 + fo_fast - 1) / fo_fast )); worst_stable=$(( 2 * ((3600 + fo_stable - 1) / fo_stable) )); group_worst=${worst_fast}; (( worst_stable > group_worst )) && group_worst=${worst_stable}; theoretical_total=$((theoretical_total + group_worst))
    fi
  done < "${FAILOVER_FILE}"
  [[ "${failover_count}" -gt 0 ]] && check_ok "故障转移配置数量：${failover_count}（启用${failover_enabled_count}）" || check_ok "未配置故障转移；现有组继续按PRIMARY兼容运行"
  if (( theoretical_total > GLOBALPING_MAX_TESTS_PER_HOUR )); then check_warn "全部启用组理论最坏测试量约${theoretical_total}/h，高于本机预算${GLOBALPING_MAX_TESTS_PER_HOUR}/h；预算保护会跳过超额测试"; else check_ok "故障转移理论最坏测试量约${theoretical_total}/h，未超过本机预算"; fi
  if [[ -z "${GLOBALPING_API_TOKEN}" && "${theoretical_total}" -gt 250 ]]; then check_warn "匿名额度为250 tests/h，当前理论最坏值可能超额；建议增加周期、减少组或配置Token"; fi

  while IFS= read -r row || [[ -n "${row}" ]]; do
    [[ -z "${row}" ]] && continue
    split_tsv_line "${row}"
    field_count="${#TSV_FIELDS[@]}"
    if (( field_count != 12 )); then check_fail "failover-state.tsv 字段数量应为12，实际=${field_count}"; continue; fi
    state_group="${TSV_FIELDS[0]}"; state_role="${TSV_FIELDS[1]}"; state_phase="${TSV_FIELDS[2]}"
    [[ -n "${state_group}" ]] || { check_fail "failover-state.tsv 组名为空"; continue; }
    if [[ -n "${seen_state["${state_group}"]+x}" ]]; then check_fail "故障转移状态重复：${state_group}"; else seen_state["${state_group}"]=1; fi
    [[ -n "${seen_names["${state_group}"]+x}" ]] || check_warn "发现孤立故障转移状态：${state_group}"
    [[ "${state_role}" == PRIMARY || "${state_role}" == BACKUP ]] || check_fail "组 ${state_group}: 活动线路状态非法"
    case "${state_phase}" in PRIMARY_STABLE|PRIMARY_FAST|BACKUP_FAST|BACKUP_STABLE) ;; *) check_fail "组 ${state_group}: 故障转移阶段非法=${state_phase}" ;; esac
    for state_index in 3 4 5 6 7 10 11; do
      [[ "${TSV_FIELDS[${state_index}]}" =~ ^[0-9]+$ ]] || check_fail "组 ${state_group}: 故障转移状态第$((state_index+1))字段应为非负整数"
    done
  done < "${FAILOVER_STATE_FILE}"

  grep -Fq 'ExecStart=/usr/local/bin/cf-dns-sync.sh AUTO' /etc/systemd/system/cf-dns-sync.service 2>/dev/null && check_ok "service使用AUTO模式" || check_fail "service ExecStart不是AUTO模式"
  grep -Fq 'OnUnitActiveSec=5s' /etc/systemd/system/cf-dns-sync.timer 2>/dev/null && check_ok "timer基础调度为5秒" || check_fail "timer未配置5秒调度"
  systemctl is-active --quiet "${TIMER_NAME}" && check_ok "timer正在运行" || check_warn "timer未运行"
  systemctl is-failed --quiet "${SERVICE_NAME}" && check_warn "service处于failed，建议一键修复" || check_ok "service未处于failed"
  if command -v systemd-analyze >/dev/null 2>&1; then systemd-analyze verify /etc/systemd/system/cf-dns-sync.service /etc/systemd/system/cf-dns-sync.timer >/dev/null 2>&1 && check_ok "systemd单元校验正常" || check_fail "systemd单元校验失败"; fi
  if grep -Fq "${LOG_FILE} ${HISTORY_FILE} ${FAILOVER_HISTORY_FILE}" /etc/logrotate.d/cf-dns-sync 2>/dev/null; then check_ok "logrotate已包含三类专用日志"; else check_fail "logrotate未包含全部三类日志"; fi
  logrotate -d /etc/logrotate.d/cf-dns-sync >/dev/null 2>&1 && check_ok "logrotate配置正常" || check_fail "logrotate配置校验失败"
  [[ -f "${INSTALL_COPY}" ]] && check_ok "一键修复安装器副本存在" || check_warn "安装器副本不存在"
  history_renderer_self_test && check_ok "IP历史有界读取与删除自测正常" || check_fail "IP历史有界读取与删除自测失败"
  runtime_log_renderer_self_test && check_ok "跨轮转运行日志读取自测正常" || check_fail "跨轮转日志读取自测失败"

  local malformed_history=0 malformed_fo_history=0 raw
  raw="$(mktemp)" || { check_fail "无法创建IP历史自检临时文件"; raw=""; }
  if [[ -n "${raw}" ]]; then
    if collect_history_to_file "${raw}"; then
      malformed_history="$(awk -F '\t' 'NF && NF != 7 {bad++} END {print bad+0}' "${raw}")"
      [[ "${malformed_history}" -eq 0 ]] && check_ok "IP历史字段结构正常" || check_warn "IP历史有${malformed_history}条格式异常"
    else
      check_fail "IP历史日志族存在无法读取或损坏的文件"
    fi
    rm -f "${raw}"
  fi
  raw="$(mktemp)" || { check_fail "无法创建故障转移历史自检临时文件"; raw=""; }
  if [[ -n "${raw}" ]]; then
    if collect_log_family_to_file "${FAILOVER_HISTORY_FILE}" "${raw}"; then
      malformed_fo_history="$(awk -F '\t' 'NF && NF != 7 {bad++} END {print bad+0}' "${raw}")"
      [[ "${malformed_fo_history}" -eq 0 ]] && check_ok "故障转移历史字段结构正常" || check_warn "故障转移历史有${malformed_fo_history}条格式异常"
    else
      check_fail "故障转移历史日志族存在无法读取或损坏的文件"
    fi
    rm -f "${raw}"
  fi

  if command -v cfcname >/dev/null 2>&1 || [[ -f /etc/cfcname/config.json ]]; then
    check_warn "检测到cfcname；目录/服务名不冲突，但同一DNS名称不能同时由两套脚本管理。"
    if [[ -f /etc/cfcname/config.json ]]; then while IFS=$'\t' read -r name enabled interval token zone target ttl proxied mode sources_csv; do [[ -z "${name}" || "${name}" =~ ^# ]] && continue; grep -Fq "${target}" /etc/cfcname/config.json 2>/dev/null && check_warn "目标 ${target} 也出现在cfcname配置中"; done < "${GROUPS_FILE}"; fi
  fi
  line; echo "自检完成：errors=${errors}, warnings=${warnings}"; [[ "${errors}" -eq 0 ]]
}

one_key_repair() {
  echo "🧯 cfdns v${APP_VERSION} 一键修复"
  line
  [[ "$(id -u)" -eq 0 ]] || { echo "请使用 root 运行"; return 1; }

  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  if ! command -v dig >/dev/null 2>&1; then command -v apt-get >/dev/null 2>&1 && missing+=(dnsutils) || missing+=(bind-utils); fi
  command -v logrotate >/dev/null 2>&1 || missing+=(logrotate)
  command -v zcat >/dev/null 2>&1 || missing+=(gzip)
  command -v gzip >/dev/null 2>&1 || missing+=(gzip)
  command -v tac >/dev/null 2>&1 || missing+=(coreutils)
  command -v flock >/dev/null 2>&1 || missing+=(util-linux)
  command -v find >/dev/null 2>&1 || missing+=(findutils)
  command -v xargs >/dev/null 2>&1 || missing+=(findutils)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "补装缺失依赖：${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
      if command -v timeout >/dev/null 2>&1; then
        timeout 300 apt-get -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=2 update || true
        timeout 300 apt-get -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=2 install -y "${missing[@]}" || true
      else
        apt-get -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=2 update || true
        apt-get -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=2 install -y "${missing[@]}" || true
      fi
    elif command -v dnf >/dev/null 2>&1; then
      if command -v timeout >/dev/null 2>&1; then
        timeout 300 dnf --setopt=timeout=20 --setopt=retries=2 install -y "${missing[@]}" || true
      else
        dnf --setopt=timeout=20 --setopt=retries=2 install -y "${missing[@]}" || true
      fi
    elif command -v yum >/dev/null 2>&1; then
      if command -v timeout >/dev/null 2>&1; then
        timeout 300 yum --setopt=timeout=20 --setopt=retries=2 install -y "${missing[@]}" || true
      else
        yum --setopt=timeout=20 --setopt=retries=2 install -y "${missing[@]}" || true
      fi
    fi
  fi

  if [[ -f "${INSTALL_COPY}" ]]; then
    echo "使用本地完整安装器重建程序模块，保留现有配置和状态……"
    CFDNS_SKIP_DEPS=1 CFDNS_NO_START=1 bash "${INSTALL_COPY}" || { echo "完整模块重建失败"; return 1; }
  else
    echo "未找到 ${INSTALL_COPY}，仅修复目录、权限和 systemd 单元。"
  fi

  mkdir -p "${BASE_DIR}" "${VAR_DIR}" "${LOG_DIR}"
  chmod 700 "${BASE_DIR}" "${VAR_DIR}" "${LOG_DIR}" 2>/dev/null || true
  migrate_legacy_logs_local
  touch "${STATE_FILE}" "${RUNSTATE_FILE}" "${RECONCILE_FILE}" "${FAILOVER_STATE_FILE}" "${GLOBALPING_USAGE_FILE}" "${LOG_FILE}" "${HISTORY_FILE}" "${FAILOVER_HISTORY_FILE}"
  [[ -f "${FAILOVER_FILE}" ]] || cat > "${FAILOVER_FILE}" <<'TSV'
# group_name<TAB>enabled<TAB>backup_sources_csv<TAB>primary_check_target<TAB>backup_check_target<TAB>check_type<TAB>tcp_port<TAB>location<TAB>stable_interval_sec<TAB>fast_interval_sec<TAB>primary_fail_threshold<TAB>backup_success_threshold<TAB>primary_recovery_threshold
TSV
  chmod 600 "${STATE_FILE}" "${RUNSTATE_FILE}" "${RECONCILE_FILE}" "${FAILOVER_STATE_FILE}" "${GLOBALPING_USAGE_FILE}" "${LOG_FILE}" "${HISTORY_FILE}" "${FAILOVER_HISTORY_FILE}" "${SETTINGS_FILE}" "${GROUPS_FILE}" "${FAILOVER_FILE}" 2>/dev/null || true
  command -v restorecon >/dev/null 2>&1 && restorecon -RF "${LOG_DIR}" >/dev/null 2>&1 || true
  chmod +x /usr/local/bin/cfdns /usr/local/bin/cf-dns-sync.sh 2>/dev/null || true
  systemctl daemon-reload || { echo "一键修复失败：systemd daemon-reload 失败"; return 1; }
  systemctl reset-failed "${SERVICE_NAME}" "${TIMER_NAME}" 2>/dev/null || true
  systemctl enable --now "${TIMER_NAME}" || { echo "一键修复失败：${TIMER_NAME} 无法启用"; return 1; }
  /usr/local/bin/cf-dns-sync.sh ALL FORCE || { echo "一键修复失败：首次同步未成功，请查看项目日志"; return 1; }
  systemctl is-active --quiet "${TIMER_NAME}" || { echo "一键修复失败：${TIMER_NAME} 未处于 active"; return 1; }
  echo "一键修复操作已完成，开始最终自检。"
  if self_check; then
    echo "一键修复完成。"
  else
    echo "一键修复已执行，但最终自检仍有错误。"
    return 1
  fi
}


purge_project_log() {
  local base="$1" days="$2" kind="$3" cutoff stage_dir f raw filtered staged identity current_identity index=0
  local -a purge_files=() purge_stages=() purge_identities=() purge_actions=()
  cutoff="$(date -d "${days} days ago" '+%F %T')" || return 1
  stage_dir="$(mktemp -d "${LOG_DIR}/.purge.XXXXXX")" || { echo "无法创建日志清理暂存目录"; return 1; }
  collect_managed_log_files "${base}"

  # 先完整读取并暂存所有目标；任一文件损坏时，不改动整个日志族。
  for f in "${LOG_FILES[@]}"; do
    managed_log_file_kind "${base}" "${f}" >/dev/null 2>&1 || continue
    identity="$(stat -c '%d:%i' "${f}" 2>/dev/null)" || { echo "无法确认日志文件身份：${f}"; rm -rf "${stage_dir}"; return 1; }
    raw="${stage_dir}/raw-${index}"
    filtered="${stage_dir}/filtered-${index}"
    staged="${stage_dir}/staged-${index}"
    if [[ "${f}" == *.gz ]]; then
      gzip -cd -- "${f}" > "${raw}" 2>/dev/null || { echo "无法读取压缩日志，已中止且保留全部原文件：${f}"; rm -rf "${stage_dir}"; return 1; }
    else
      cat -- "${f}" > "${raw}" 2>/dev/null || { echo "无法读取日志，已中止且保留全部原文件：${f}"; rm -rf "${stage_dir}"; return 1; }
    fi
    if [[ "${kind}" == "runtime" ]]; then
      awk -v c="${cutoff}" '/^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]/{if(substr($0,2,19)>=c)print;next}{print}' "${raw}" > "${filtered}" || { rm -rf "${stage_dir}"; return 1; }
    else
      awk -F '\t' -v c="${cutoff}" '/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/{if(substr($0,1,19)>=c)print;next}{print}' "${raw}" > "${filtered}" || { rm -rf "${stage_dir}"; return 1; }
    fi
    if [[ "${f}" == *.gz ]]; then
      gzip -c -- "${filtered}" > "${staged}" || { rm -rf "${stage_dir}"; return 1; }
    else
      cp -- "${filtered}" "${staged}" || { rm -rf "${stage_dir}"; return 1; }
    fi
    chmod 600 "${staged}" || { rm -rf "${stage_dir}"; return 1; }
    purge_files+=("${f}")
    purge_stages+=("${staged}")
    purge_identities+=("${identity}")
    if [[ "${f}" != "${base}" && ! -s "${filtered}" ]]; then purge_actions+=(delete); else purge_actions+=(replace); fi
    index=$((index+1))
  done

  # 所有文件在真正修改前统一复核，避免确认期间的轮转或替换造成误操作。
  for index in "${!purge_files[@]}"; do
    current_identity="$(stat -c '%d:%i' "${purge_files[${index}]}" 2>/dev/null || true)"
    if [[ -z "${current_identity}" || "${current_identity}" != "${purge_identities[${index}]}" ]]; then
      echo "日志文件在清理期间已轮转、替换或消失；本次未修改任何文件。"
      rm -rf "${stage_dir}"
      return 1
    fi
  done

  for index in "${!purge_files[@]}"; do
    if [[ "${purge_actions[${index}]}" == delete ]]; then
      rm -- "${purge_files[${index}]}" || { rm -rf "${stage_dir}"; return 1; }
    else
      mv -f -- "${purge_stages[${index}]}" "${purge_files[${index}]}" || { rm -rf "${stage_dir}"; return 1; }
    fi
  done
  rm -rf "${stage_dir}"
}

clean_logs_menu() {
  local days scope choice rc=0
  while true; do
    clear 2>/dev/null || true; line; echo "🧹 清理 cfdns 项目日志"; line
    echo "1. 🗓️  清理7天前的日志"; echo "2. 📆 清理30天前的日志"; echo "0. ↩️ 返回"
    read -rp "请选择: " choice || return
    case "${choice}" in 1) days=7 ;; 2) days=30 ;; 0) return ;; *) echo "无效选择"; pause_wait; continue ;; esac
    echo "1. 📄 普通运行日志"; echo "2. 📜 IP变更历史"; echo "3. 🌏 故障转移历史"; echo "4. 🧹 三种项目日志全部清理"; echo "0. ↩️ 返回"
    read -rp "请选择清理范围: " scope || return
    case "${scope}" in 1|2|3|4) ;; 0) return ;; *) echo "无效选择"; pause_wait; continue ;; esac
    echo "将逐个清理所选日志文件，保留未过期内容和每日轮转边界；空的旧轮转文件会被删除。"
    read -rp "输入 DELETE 确认，其他输入取消: " confirm || return
    [[ "${confirm}" == "DELETE" ]] || { echo "已取消"; pause_wait; continue; }
    if ! exec 8>/run/cf-dns-sync.lock; then echo "无法打开同步锁，本次未清理"; pause_wait; continue; fi
    if ! flock -w 30 8; then echo "同步任务正在运行，等待30秒后仍未取得锁；本次未清理"; exec 8>&-; pause_wait; continue; fi
    rc=0
    case "${scope}" in
      1) purge_project_log "${LOG_FILE}" "${days}" runtime || rc=1 ;;
      2) purge_project_log "${HISTORY_FILE}" "${days}" history || rc=1 ;;
      3) purge_project_log "${FAILOVER_HISTORY_FILE}" "${days}" history || rc=1 ;;
      4) purge_project_log "${LOG_FILE}" "${days}" runtime || rc=1; purge_project_log "${HISTORY_FILE}" "${days}" history || rc=1; purge_project_log "${FAILOVER_HISTORY_FILE}" "${days}" history || rc=1 ;;
    esac
    flock -u 8
    exec 8>&-
    [[ "${rc}" -eq 0 ]] && echo "已清理${days}天前的所选项目文件日志，并保留每日轮转边界；未清理系统全局journal。" || echo "日志清理未完整完成；读取或预检失败的日志族保持不变。"
    pause_wait
  done
}

edit_raw_files() {
  echo
  echo "1. 📝 编辑 settings.conf（全局设置/Globalping Token）"
  echo "2. 🧩 编辑 groups.tsv（PRIMARY与Cloudflare组配置）"
  echo "3. 🌏 编辑 failover.tsv（BACKUP与故障转移配置）"
  echo "0. ↩️  返回"
  read -rp "请选择: " choice || return
  case "${choice}" in 1) ${EDITOR:-vi} "${SETTINGS_FILE}" ;; 2) ${EDITOR:-vi} "${GROUPS_FILE}" ;; 3) ${EDITOR:-vi} "${FAILOVER_FILE}" ;; 0) ;; *) echo "无效选择" ;; esac
}

uninstall_all() {
  read -rp "确认彻底卸载 cfdns？输入 yes 继续: " ans || return
  [[ "${ans}" == "yes" ]] || { echo "已取消"; return; }

  systemctl stop "${TIMER_NAME}" 2>/dev/null || true
  systemctl disable "${TIMER_NAME}" 2>/dev/null || true
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true

  rm -f /etc/systemd/system/cf-dns-sync.timer
  rm -f /etc/systemd/system/cf-dns-sync.service
  systemctl daemon-reload

  rm -f /usr/local/bin/cf-dns-sync.sh
  rm -f /usr/local/bin/cfdns
  rm -rf /etc/cf-dns-sync
  rm -f /etc/logrotate.d/cf-dns-sync
  rm -rf "${LOG_DIR}"
  rm -f "${LEGACY_LOG_FILE}" "${LEGACY_LOG_FILE}".* "${LEGACY_LOG_FILE}"-* 2>/dev/null || true
  rm -f "${LEGACY_HISTORY_FILE}" "${LEGACY_HISTORY_FILE}".* "${LEGACY_HISTORY_FILE}"-* 2>/dev/null || true
  rm -f /run/cf-dns-sync.lock
  rm -rf /var/lib/cf-dns-sync
  rm -rf /opt/cfdns

  echo "cfdns 已彻底卸载"
  echo "说明：未卸载系统依赖，不影响其它脚本或软件。"
  exit 0
}

menu() {
  run_init_wizard
  while true; do
    title
    echo "-- 组配置 --"
    printf ' %2d. %s\n' 1 "查看全部组" 2 "新增组" 3 "删除组" 4 "编辑组基础信息"
    printf ' %2d. %s\n' 5 "管理 PRIMARY 源域名" 6 "切换组启用状态" 7 "设置组检测周期" 8 "测试 Cloudflare API Token"
    printf ' %2d. %s\n' 9 "测试源域名解析" 10 "查看组当前解析 IP" 11 "组上移" 12 "组下移"
    echo
    echo "-- 服务与诊断 --"
    printf ' %2d. %s\n' 13 "设置日志等级" 14 "启动" 15 "停止" 16 "重启"
    printf ' %2d. %s\n' 17 "强制同步全部组" 18 "强制同步单个组" 19 "查看项目运行日志" 20 "实时查看项目日志"
    printf ' %2d. %s\n' 21 "查看单组运行日志" 22 "查看 service/timer 状态" 23 "查看依赖状态" 24 "脚本自检"
    printf ' %2d. %s\n' 25 "一键修复" 26 "查看各组上次检测时间"
    echo
    echo "-- 历史、故障转移与维护 --"
    printf ' %2d. %s\n' 27 "查看或删除域名 IP 历史" 28 "清理项目日志" 29 "编辑原始配置文件"
    printf ' %2d. %s\n' 30 "彻底卸载" 31 "Globalping 中国节点故障转移" 0 "退出"
    line
    read -rp "请选择: " choice || exit 0
    case "${choice}" in
      1) list_groups_table; pause_wait ;; 2) add_group; pause_wait ;; 3) delete_group; pause_wait ;;
      4) edit_group_basic; pause_wait ;; 5) manage_group_sources ;; 6) toggle_group_enabled; pause_wait ;;
      7) set_group_interval; pause_wait ;; 8) test_group_token; pause_wait ;; 9) test_group_sources_dns; pause_wait ;;
      10) view_group_current_ips; pause_wait ;; 11) move_group_up; pause_wait ;; 12) move_group_down; pause_wait ;;
      13) set_log_level; pause_wait ;; 14) start_sync; pause_wait ;; 15) stop_sync; pause_wait ;;
      16) restart_sync; pause_wait ;; 17) manual_run_all; pause_wait ;; 18) manual_run_one; pause_wait ;;
      19) show_logs ;; 20) follow_logs ;; 21) show_group_runtime_logs ;;
      22) show_status; pause_wait ;; 23) show_dep_status; pause_wait ;; 24) self_check; pause_wait ;;
      25) one_key_repair; pause_wait ;; 26) show_runstate; pause_wait ;; 27) history_menu ;;
      28) clean_logs_menu ;; 29) edit_raw_files ;; 30) uninstall_all ;; 31) failover_menu ;; 0) exit 0 ;;
      *) echo "无效选择"; sleep 1 ;;
    esac
  done
}


menu
CTL
  if ! bash -n "${tmp}"; then
    echo "生成的管理脚本语法校验失败，保留现有版本" >&2
    rm -f "${tmp}"
    return 1
  fi
  install -m 700 "${tmp}" "${BIN_CTL}"
  rm -f "${tmp}"
}

write_service() {
  local tmp
  tmp="$(mktemp /etc/systemd/system/.cf-dns-sync.service.XXXXXX)"
  cat > "${tmp}" <<'SERVICE'
[Unit]
Description=Cloudflare DNS Multi-Group Local Detector and Globalping Failover Controller
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cf-dns-sync.sh AUTO
User=root
Group=root
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
SERVICE
  install -m 644 "${tmp}" "${SERVICE_FILE}"
  rm -f "${tmp}"
}

write_timer() {
  local tmp
  tmp="$(mktemp /etc/systemd/system/.cf-dns-sync.timer.XXXXXX)"
  cat > "${tmp}" <<'TIMER'
[Unit]
Description=Run cfdns local source-IP detection every 5 seconds

[Timer]
OnBootSec=5s
OnUnitActiveSec=5s
AccuracySec=1s
Unit=cf-dns-sync.service

[Install]
WantedBy=timers.target
TIMER
  install -m 644 "${tmp}" "${TIMER_FILE}"
  rm -f "${tmp}"
}
write_logrotate() {
  local tmp
  tmp="$(mktemp /etc/logrotate.d/.cf-dns-sync.XXXXXX)"
  cat > "${tmp}" <<'ROTATE'
/var/log/cf-dns-sync/cf-dns-sync.log /var/log/cf-dns-sync/cf-dns-sync-history.tsv /var/log/cf-dns-sync/cf-dns-sync-failover.tsv {
    daily
    rotate 180
    maxage 180
    missingok
    notifempty
    compress
    delaycompress
    dateext
    create 600 root root
}
ROTATE
  install -m 644 "${tmp}" "${LOGROTATE_FILE}"
  rm -f "${tmp}"
}

validate_generated_installation() {
  bash -n "${BIN_SYNC}" || { echo "同步脚本语法校验失败" >&2; return 1; }
  bash -n "${BIN_CTL}" || { echo "管理脚本语法校验失败" >&2; return 1; }

  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "${SERVICE_FILE}" "${TIMER_FILE}" >/dev/null 2>&1 || {
      echo "systemd service/timer 校验失败" >&2
      return 1
    }
  fi

  logrotate -d "${LOGROTATE_FILE}" >/dev/null 2>&1 || {
    echo "logrotate 配置校验失败" >&2
    return 1
  }
}

backup_existing() {
  mkdir -p "${BACKUP_DIR}"
  local stamp archive
  stamp="$(date +%Y%m%d%H%M%S)"
  archive="${BACKUP_DIR}/cfdns-backup-${stamp}-$$.tar.gz"
  local rel_items=()
  [[ -d "${BASE_DIR}" ]] && rel_items+=("etc/cf-dns-sync")
  [[ -d "${VAR_DIR}" ]] && rel_items+=("var/lib/cf-dns-sync")
  [[ -f "${BIN_CTL}" ]] && rel_items+=("usr/local/bin/cfdns")
  [[ -f "${BIN_SYNC}" ]] && rel_items+=("usr/local/bin/cf-dns-sync.sh")
  [[ -f "${SERVICE_FILE}" ]] && rel_items+=("etc/systemd/system/cf-dns-sync.service")
  [[ -f "${TIMER_FILE}" ]] && rel_items+=("etc/systemd/system/cf-dns-sync.timer")
  [[ -f "${LOGROTATE_FILE}" ]] && rel_items+=("etc/logrotate.d/cf-dns-sync")
  [[ -f "${INSTALL_COPY}" ]] && rel_items+=("opt/cfdns/cfdns-installer.sh")
  if [[ "${#rel_items[@]}" -gt 0 ]]; then
    if ! tar -C / --exclude='var/lib/cf-dns-sync/backups' -czf "${archive}" "${rel_items[@]}" 2>/dev/null; then
      rm -f "${archive}"
      echo "升级备份创建失败，已停止覆盖现有安装。" >&2
      return 1
    fi
    chmod 600 "${archive}" || {
      rm -f "${archive}"
      echo "升级备份权限设置失败，已停止覆盖现有安装。" >&2
      return 1
    }
  fi
  find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'cfdns-backup-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR>10{print $2}' | xargs -r rm -f
}

store_installer_copy() {
  mkdir -p "${INSTALL_DIR}"
  if [[ -f "$0" ]] && grep -q 'cfdns v2.9 installer' "$0" 2>/dev/null; then
    if [[ -e "${INSTALL_COPY}" && "$0" -ef "${INSTALL_COPY}" ]]; then
      chmod 700 "${INSTALL_COPY}"
    else
      install -m 700 "$0" "${INSTALL_COPY}"
    fi
  fi
}

main() {
  [[ "$(id -u)" -eq 0 ]] || { echo "请使用 root 运行"; exit 1; }
  install_missing_deps
  mkdir -p "${BASE_DIR}" "${VAR_DIR}" "${BACKUP_DIR}" "${LOG_DIR}" /usr/local/bin /etc/systemd/system /etc/logrotate.d "${INSTALL_DIR}"
  chmod 700 "${BASE_DIR}" "${VAR_DIR}" "${LOG_DIR}" 2>/dev/null || true

  # 先验证已有设置，避免因损坏配置而停掉仍在工作的旧版本。
  if [[ -f "${SETTINGS_FILE}" ]]; then
    validate_settings_file
  fi

  if systemctl is-active --quiet "${APP_NAME}.timer" 2>/dev/null; then INSTALL_PREVIOUS_TIMER_ACTIVE=1; fi
  if systemctl is-enabled --quiet "${APP_NAME}.timer" 2>/dev/null; then INSTALL_PREVIOUS_TIMER_ENABLED=1; fi
  INSTALL_GUARD_ACTIVE=1
  trap restore_runtime_after_failed_install EXIT

  # 覆盖升级期间先停定时器，避免旧同步脚本继续向旧路径写日志或与迁移并发。
  if [[ -f "${TIMER_FILE}" ]] && ! systemctl stop "${APP_NAME}.timer"; then
    echo "无法停止现有 ${APP_NAME}.timer，已中止升级以避免并发覆盖；安装未完成。" >&2
    return 1
  fi
  if [[ -f "${SERVICE_FILE}" ]] && ! systemctl stop "${APP_NAME}.service"; then
    echo "无法停止现有 ${APP_NAME}.service，已中止升级以避免并发覆盖；安装未完成。" >&2
    return 1
  fi

  backup_existing
  write_settings
  validate_settings_file
  write_groups
  write_failover
  sed -i 's/\r$//' "${GROUPS_FILE}" "${FAILOVER_FILE}" 2>/dev/null || true
  write_sync_script
  write_ctl_script
  write_service
  write_timer
  write_logrotate
  validate_generated_installation

  # 将 v2.4 及更早版本散落在 /var/log 根目录的当前、轮转和压缩日志迁入专用目录。
  migrate_legacy_logs
  touch "${HISTORY_FILE}" "${FAILOVER_HISTORY_FILE}" "${RUNSTATE_FILE}" "${STATE_FILE}" "${VAR_DIR}/reconcile.tsv" "${FAILOVER_STATE_FILE}" "${GLOBALPING_USAGE_FILE}" "${LOG_FILE}"
  chmod 600 "${HISTORY_FILE}" "${FAILOVER_HISTORY_FILE}" "${RUNSTATE_FILE}" "${STATE_FILE}" "${VAR_DIR}/reconcile.tsv" "${FAILOVER_STATE_FILE}" "${GLOBALPING_USAGE_FILE}" "${LOG_FILE}" "${SETTINGS_FILE}" "${GROUPS_FILE}" "${FAILOVER_FILE}"
  chmod 700 "${LOG_DIR}" 2>/dev/null || true
  command -v restorecon >/dev/null 2>&1 && restorecon -RF "${LOG_DIR}" >/dev/null 2>&1 || true
  store_installer_copy
  systemctl daemon-reload || { echo "安装文件已写入，但 systemd daemon-reload 失败；安装未完成。"; return 1; }
  systemctl reset-failed "${APP_NAME}.service" "${APP_NAME}.timer" 2>/dev/null || true
  if [[ "${CFDNS_NO_START:-0}" != "1" ]]; then
    systemctl enable --now "${APP_NAME}.timer" || { echo "安装文件已写入，但 ${APP_NAME}.timer 启用失败；安装未完成。"; return 1; }
    systemctl start "${APP_NAME}.service" || { echo "安装文件已写入，但首次同步执行失败；安装未完成。"; return 1; }
    systemctl is-active --quiet "${APP_NAME}.timer" || { echo "安装文件已写入，但 ${APP_NAME}.timer 未处于 active；安装未完成。"; return 1; }
  fi
  echo
  if [[ "${CFDNS_NO_START:-0}" == "1" ]]; then
    echo "安装/升级文件写入完成: v${APP_VERSION}（按 CFDNS_NO_START=1 未启动）"
  else
    echo "安装/升级完成: v${APP_VERSION}"
  fi
  echo "管理命令: cfdns"
  echo "本机基础调度周期: 5 秒"
  echo "每组按照独立周期查询源域名；源IP未变化时不会调用Cloudflare API。"
  echo "Globalping故障转移为可选模块：现有源域名自动作为PRIMARY，未配置BACKUP的组行为不变。"
  echo "组配置: ${GROUPS_FILE}"
  echo "故障转移配置: ${FAILOVER_FILE}"
  echo "日志目录: ${LOG_DIR}"
  echo "升级备份: ${BACKUP_DIR}"
  echo "自检/一键修复: cfdns 菜单24/25；故障转移: 菜单31"
  if [[ "${CFDNS_NO_START:-0}" != "1" ]]; then
    systemctl status "${APP_NAME}.timer" --no-pager -l || true
  fi
  INSTALL_GUARD_ACTIVE=0
  trap - EXIT
}

main
