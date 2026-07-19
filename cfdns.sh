#!/usr/bin/env bash
set -euo pipefail

# cfdns v2.3 installer
# Cloudflare DNS multi-group A-record incremental sync tool

APP_NAME="cf-dns-sync"
APP_VERSION="2.3"
INSTALL_DIR="/opt/cfdns"
INSTALL_COPY="${INSTALL_DIR}/cfdns-installer.sh"
BASE_DIR="/etc/${APP_NAME}"
VAR_DIR="/var/lib/${APP_NAME}"
BACKUP_DIR="${VAR_DIR}/backups"
LOG_DIR="/var/log"

BIN_SYNC="/usr/local/bin/${APP_NAME}.sh"
BIN_CTL="/usr/local/bin/cfdns"

SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
TIMER_FILE="/etc/systemd/system/${APP_NAME}.timer"
LOGROTATE_FILE="/etc/logrotate.d/${APP_NAME}"

SETTINGS_FILE="${BASE_DIR}/settings.conf"
GROUPS_FILE="${BASE_DIR}/groups.tsv"
LOG_FILE="${LOG_DIR}/${APP_NAME}.log"
HISTORY_FILE="${LOG_DIR}/${APP_NAME}-history.tsv"
STATE_FILE="${VAR_DIR}/state.tsv"
RUNSTATE_FILE="${VAR_DIR}/runstate.tsv"
INIT_FLAG="${VAR_DIR}/.initialized"

mkdir -p "${BASE_DIR}" "${VAR_DIR}"

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

  printf '%s\n' "${missing[@]}" | sed '/^$/d' | sort -u
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
    apt-get update
    # shellcheck disable=SC2086
    apt-get install -y ${pkgs}
  elif command -v dnf >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    dnf install -y ${pkgs}
  elif command -v yum >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    yum install -y ${pkgs}
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
CFG
  else
    sed -i 's/\r$//' "${SETTINGS_FILE}" 2>/dev/null || true
    grep -q '^LOG_LEVEL=' "${SETTINGS_FILE}" || echo 'LOG_LEVEL="INFO"' >> "${SETTINGS_FILE}"
    grep -q '^FORCE_RECONCILE_SEC=' "${SETTINGS_FILE}" || echo 'FORCE_RECONCILE_SEC="3600"' >> "${SETTINGS_FILE}"
    grep -q '^DNS_SERVER=' "${SETTINGS_FILE}" || echo 'DNS_SERVER=""' >> "${SETTINGS_FILE}"
    grep -q '^DNS_QUERY_TIMEOUT_SEC=' "${SETTINGS_FILE}" || echo 'DNS_QUERY_TIMEOUT_SEC="2"' >> "${SETTINGS_FILE}"
  fi
  chmod 600 "${SETTINGS_FILE}"
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

write_sync_script() {
  cat > "${BIN_SYNC}" <<'SYNC'
#!/usr/bin/env bash
set -uo pipefail

APP_VERSION="2.3"
BASE_DIR="/etc/cf-dns-sync"
VAR_DIR="/var/lib/cf-dns-sync"
SETTINGS_FILE="${BASE_DIR}/settings.conf"
GROUPS_FILE="${BASE_DIR}/groups.tsv"
LOG_FILE="/var/log/cf-dns-sync.log"
HISTORY_FILE="/var/log/cf-dns-sync-history.tsv"
STATE_FILE="${VAR_DIR}/state.tsv"
RUNSTATE_FILE="${VAR_DIR}/runstate.tsv"
RECONCILE_FILE="${VAR_DIR}/reconcile.tsv"
LOCK_FILE="/run/cf-dns-sync.lock"

mkdir -p "${VAR_DIR}"
touch "${HISTORY_FILE}" "${RUNSTATE_FILE}" "${RECONCILE_FILE}" "${STATE_FILE}"
chmod 600 "${HISTORY_FILE}" "${RUNSTATE_FILE}" "${RECONCILE_FILE}" "${STATE_FILE}" 2>/dev/null || true

[[ -f "${SETTINGS_FILE}" ]] || { echo "配置文件不存在: ${SETTINGS_FILE}"; exit 1; }
[[ -f "${GROUPS_FILE}" ]] || { echo "组配置不存在: ${GROUPS_FILE}"; exit 1; }

# shellcheck disable=SC1090
source "${SETTINGS_FILE}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
FORCE_RECONCILE_SEC="${FORCE_RECONCILE_SEC:-3600}"
DNS_SERVER="${DNS_SERVER:-}"
DNS_QUERY_TIMEOUT_SEC="${DNS_QUERY_TIMEOUT_SEC:-2}"
[[ "${FORCE_RECONCILE_SEC}" =~ ^[0-9]+$ ]] && (( FORCE_RECONCILE_SEC >= 60 )) || FORCE_RECONCILE_SEC=3600
[[ "${DNS_QUERY_TIMEOUT_SEC}" =~ ^[0-9]+$ ]] && (( DNS_QUERY_TIMEOUT_SEC >= 1 )) || DNS_QUERY_TIMEOUT_SEC=2

RUN_MODE="${1:-AUTO}"
FORCE_FLAG="${2:-0}"
case "${RUN_MODE}" in
  AUTO) TARGET_GROUP="ALL" ;;
  ALL) TARGET_GROUP="ALL"; FORCE_FLAG="1" ;;
  *) TARGET_GROUP="${RUN_MODE}" ;;
esac
[[ "${FORCE_FLAG}" == "FORCE" ]] && FORCE_FLAG="1"

# 自动任务不等待锁；人工同步最多等待30秒，避免“实际未执行却提示成功”。
exec 9>"${LOCK_FILE}"
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

for cmd in curl jq dig awk sed grep sort comm mktemp flock paste cut tr date wc cmp; do
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

cf_api() {
  local method="$1" token="$2" endpoint="$3" data="${4:-}"
  local hdr body rc http_code retry_after raw
  hdr="$(mktemp)"; body="$(mktemp)"

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
    jq -nc --arg msg "curl failed rc=${rc}" --argjson status 0 \
      '{success:false,result:null,errors:[{message:$msg}],_http_status:$status,_retry_after:0}'
    return 0
  fi

  if ! jq -e . >/dev/null 2>&1 <<< "${raw}"; then
    jq -nc --arg msg "Cloudflare returned non-JSON response" --arg body "${raw:0:500}" \
      --argjson status "${http_code:-0}" --arg retry "${retry_after:-0}" \
      '{success:false,result:null,errors:[{message:$msg,body:$body}],_http_status:$status,_retry_after:($retry|tonumber? // 0)}'
    return 0
  fi

  jq --argjson status "${http_code:-0}" --arg retry "${retry_after:-0}" \
    '. + {_http_status:$status,_retry_after:($retry|tonumber? // 0)}' <<< "${raw}" 2>/dev/null || printf '%s\n' "${raw}"
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

  sort -u -o "${map_file}" "${map_file}"
  sort -u -o "${failed_file}" "${failed_file}"
}

get_table_value() {
  local file="$1" group="$2"
  awk -F '\t' -v g="${group}" '$1==g{v=$2} END{print v}' "${file}" 2>/dev/null
}

set_table_value() {
  local file="$1" group="$2" value="$3" tmp
  tmp="$(mktemp)"
  awk -F '\t' -v g="${group}" '$1!=g' "${file}" 2>/dev/null > "${tmp}" || true
  printf '%s\t%s\n' "${group}" "${value}" >> "${tmp}"
  mv "${tmp}" "${file}"
  chmod 600 "${file}" 2>/dev/null || true
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
  (( now - last >= interval ))
}

reconcile_due() {
  local group="$1" last now
  now="$(now_ts)"; last="$(get_group_last_reconcile "${group}")"
  [[ -z "${last}" ]] && return 0
  [[ "${FORCE_RECONCILE_SEC}" =~ ^[0-9]+$ ]] || FORCE_RECONCILE_SEC=3600
  (( now - last >= FORCE_RECONCILE_SEC ))
}

extract_group_state_map() {
  local group="$1" out="$2"
  awk -F '\t' -v g="${group}" '$1==g{print $2 "\t" $3}' "${STATE_FILE}" 2>/dev/null | sort -u > "${out}"
}

save_group_state() {
  local group="$1" map_file="$2" tmp
  tmp="$(mktemp)"
  awk -F '\t' -v g="${group}" '$1!=g' "${STATE_FILE}" 2>/dev/null > "${tmp}" || true
  awk -F '\t' -v g="${group}" '{print g "\t" $1 "\t" $2}' "${map_file}" >> "${tmp}"
  mv "${tmp}" "${STATE_FILE}"
  chmod 600 "${STATE_FILE}" 2>/dev/null || true
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

sync_one_group() {
  local group_name="$1" enabled="$2" interval_sec="$3" api_token="$4" zone_id="$5"
  local target_fqdn="$6" ttl="$7" proxied="$8" mode="$9" sources_csv="${10}"

  if [[ "${enabled}" != "true" ]]; then
    [[ "${TARGET_GROUP}" == "${group_name}" ]] && log INFO "组 ${group_name}: 已禁用，未执行"
    return 0
  fi

  if [[ "${RUN_MODE}" == "AUTO" ]] && ! should_run_group "${group_name}" "${interval_sec}"; then
    return 0
  fi

  if ! [[ "${interval_sec}" =~ ^[0-9]+$ ]] || (( interval_sec < 5 )); then
    log ERROR "组 ${group_name}: 检测周期必须是 >=5 秒的数字"
    return 0
  fi
  if ! [[ "${ttl}" =~ ^[0-9]+$ ]]; then
    log ERROR "组 ${group_name}: TTL 必须是数字"
    return 0
  fi
  if [[ -z "${api_token}" || -z "${zone_id}" || -z "${target_fqdn}" ]]; then
    log ERROR "组 ${group_name}: API Token、Zone ID 或目标域名为空"
    return 0
  fi
  if [[ "${proxied}" != "false" ]]; then
    log ERROR "组 ${group_name}: 当前版本仅支持 DNS only（proxied=false）"
    return 0
  fi
  if [[ "${mode}" != "ALL_IPS" && "${mode}" != "SINGLE_IP" ]]; then
    log ERROR "组 ${group_name}: 解析模式必须是 ALL_IPS 或 SINGLE_IP"
    return 0
  fi

  csv_to_sources_array "${sources_csv}"
  local source_count="${#SOURCES_ARRAY[@]}"
  if (( source_count < 1 || source_count > 20 )); then
    log ERROR "组 ${group_name}: 源域名数量必须为 1~20，当前=${source_count}"
    return 0
  fi

  local tmpdir map_file failed_domains old_map desired current_records current_unique to_add to_del
  tmpdir="$(mktemp -d)" || { log ERROR "组 ${group_name}: 无法创建临时目录"; return 0; }
  map_file="${tmpdir}/map"; failed_domains="${tmpdir}/failed_domains"
  old_map="${tmpdir}/old_map"; desired="${tmpdir}/desired"
  current_records="${tmpdir}/records"; current_unique="${tmpdir}/current"
  to_add="${tmpdir}/to_add"; to_del="${tmpdir}/to_del"

  log DEBUG "组 ${group_name}: 开始本机检测 -> ${target_fqdn}，周期=${interval_sec}s，源域名=${source_count}"
  build_group_map "${mode}" "${map_file}" "${failed_domains}" "${SOURCES_ARRAY[@]}"
  set_group_last_run "${group_name}" "$(now_ts)"

  # 任意一个源域名解析失败都停止本轮同步，防止把暂时解析失败误判成IP下线。
  if [[ -s "${failed_domains}" ]]; then
    log ERROR "组 ${group_name}: 以下源域名未解析到 IPv4：$(paste -sd ',' "${failed_domains}")；为防误删，未访问 Cloudflare"
    rm -rf "${tmpdir}"
    return 0
  fi

  if [[ ! -s "${map_file}" ]]; then
    log ERROR "组 ${group_name}: 未查询到任何源 IPv4；为防误删，未访问 Cloudflare"
    rm -rf "${tmpdir}"
    return 0
  fi

  awk -F '\t' '{print $2}' "${map_file}" | sort -u > "${desired}"
  extract_group_state_map "${group_name}" "${old_map}"

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

  local encoded current_json api_status retry_after
  encoded="$(urlencode "${target_fqdn}")"
  current_json="$(cf_api GET "${api_token}" "/zones/${zone_id}/dns_records?type=A&name=${encoded}&per_page=100")"
  if [[ "$(jq -r '.success // false' <<< "${current_json}")" != "true" ]]; then
    api_status="$(jq -r '._http_status // 0' <<< "${current_json}" 2>/dev/null || echo 0)"
    retry_after="$(jq -r '._retry_after // 0' <<< "${current_json}" 2>/dev/null || echo 0)"
    log ERROR "组 ${group_name}: Cloudflare API 查询失败，HTTP=${api_status}，retry-after=${retry_after}s，详情=$(jq -c '.errors' <<< "${current_json}" 2>/dev/null || echo unknown)"
    rm -rf "${tmpdir}"
    return 0
  fi

  jq -r '.result[]? | [.id,.content] | @tsv' <<< "${current_json}" > "${current_records}"
  cut -f2 "${current_records}" | sed '/^$/d' | sort -u > "${current_unique}"
  comm -23 "${desired}" "${current_unique}" > "${to_add}" || true
  comm -13 "${desired}" "${current_unique}" > "${to_del}" || true

  local op_failed=0 ip id domains first_id

  # 删除已不再需要的 IP；历史只在 API 删除成功后写入。
  while IFS=$'\t' read -r id ip; do
    [[ -n "${id}" && -n "${ip}" ]] || continue
    if grep -Fxq "${ip}" "${to_del}"; then
      domains="$(domains_by_ip_from_map "${old_map}" "${ip}")"
      [[ -n "${domains}" ]] || domains="unknown"
      if delete_cf_record "${api_token}" "${zone_id}" "${id}"; then
        write_history "${group_name}" DELETE "${ip}" "${domains}" "${mode}" "${target_fqdn}" removed_from_cloudflare
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
    while IFS=$'\t' read -r id _; do
      [[ -n "${first_id}" ]] || { first_id="${id}"; continue; }
      if delete_cf_record "${api_token}" "${zone_id}" "${id}"; then
        domains="$(domains_by_ip_from_map "${map_file}" "${ip}")"
        [[ -n "${domains}" ]] || domains="unknown"
        write_history "${group_name}" DELETE "${ip}" "${domains}" "${mode}" "${target_fqdn}" duplicate_record_cleanup
        log INFO "组 ${group_name}: 已清理重复 A 记录 ${ip}"
      else
        op_failed=1
      fi
    done < <(awk -F '\t' -v ip="${ip}" '$2==ip{print $1 "\t" $2}' "${current_records}")
  done < "${desired}"

  while IFS= read -r ip; do
    [[ -n "${ip}" ]] || continue
    domains="$(domains_by_ip_from_map "${map_file}" "${ip}")"
    [[ -n "${domains}" ]] || domains="unknown"
    if create_cf_record "${api_token}" "${zone_id}" "${target_fqdn}" "${ttl}" "${proxied}" "${ip}"; then
      write_history "${group_name}" ADD "${ip}" "${domains}" "${mode}" "${target_fqdn}" added_to_cloudflare
      log INFO "组 ${group_name}: 已新增 IP ${ip}"
    else
      op_failed=1
    fi
  done < "${to_add}"

  if (( op_failed == 0 )); then
    save_group_state "${group_name}" "${map_file}"
    set_group_last_reconcile "${group_name}" "$(now_ts)"
    if [[ ! -s "${to_add}" && ! -s "${to_del}" ]]; then
      log DEBUG "组 ${group_name}: Cloudflare 记录与源 IP 一致"
    else
      log INFO "组 ${group_name}: 增量同步完成"
    fi
  else
    log ERROR "组 ${group_name}: 本次存在 API 操作失败，未推进本地成功状态；下个检测周期会重新核对并重试"
  fi

  rm -rf "${tmpdir}"
  return 0
}

main() {
  local configured=0 matched=0 enabled_count=0
  local group_name enabled interval_sec api_token zone_id target_fqdn ttl proxied mode sources_csv extra

  while IFS=$'\t' read -r group_name enabled interval_sec api_token zone_id target_fqdn ttl proxied mode sources_csv extra; do
    [[ -z "${group_name}" || "${group_name}" =~ ^# ]] && continue
    configured=$((configured+1))
    [[ "${enabled}" == "true" ]] && enabled_count=$((enabled_count+1))
    if [[ "${TARGET_GROUP}" != "ALL" && "${TARGET_GROUP}" != "${group_name}" ]]; then
      continue
    fi
    matched=$((matched+1))
    sync_one_group "${group_name}" "${enabled}" "${interval_sec}" "${api_token}" "${zone_id}" \
      "${target_fqdn}" "${ttl}" "${proxied}" "${mode}" "${sources_csv}" || \
      log ERROR "组 ${group_name}: 出现未捕获异常，已隔离该组，不影响其它组"
  done < "${GROUPS_FILE}"

  if [[ "${TARGET_GROUP}" == "ALL" ]]; then
    [[ "${configured}" -eq 0 ]] && log DEBUG "当前没有配置组，跳过检测"
    [[ "${configured}" -gt 0 && "${enabled_count}" -eq 0 ]] && log DEBUG "当前没有启用组，跳过检测"
    exit 0
  fi

  if [[ "${matched}" -eq 0 ]]; then
    log ERROR "未找到需要同步的组: ${TARGET_GROUP}"
    exit 1
  fi
  exit 0
}

main

SYNC
  chmod +x "${BIN_SYNC}"
}

write_ctl_script() {
  cat > "${BIN_CTL}" <<'CTL'
#!/usr/bin/env bash
set -uo pipefail

APP_NAME="cf-dns-sync"
APP_VERSION="2.3"
BASE_DIR="/etc/${APP_NAME}"
VAR_DIR="/var/lib/${APP_NAME}"
SETTINGS_FILE="${BASE_DIR}/settings.conf"
GROUPS_FILE="${BASE_DIR}/groups.tsv"
SERVICE_NAME="${APP_NAME}.service"
TIMER_NAME="${APP_NAME}.timer"
LOG_FILE="/var/log/${APP_NAME}.log"
HISTORY_FILE="/var/log/${APP_NAME}-history.tsv"
STATE_FILE="${VAR_DIR}/state.tsv"
RUNSTATE_FILE="${VAR_DIR}/runstate.tsv"
RECONCILE_FILE="${VAR_DIR}/reconcile.tsv"
INSTALL_COPY="/opt/cfdns/cfdns-installer.sh"
INIT_FLAG="${VAR_DIR}/.initialized"

mkdir -p "${BASE_DIR}" "${VAR_DIR}"

[[ -f "${SETTINGS_FILE}" ]] || cat > "${SETTINGS_FILE}" <<'CFG'
LOG_LEVEL="INFO"
FORCE_RECONCILE_SEC="3600"
DNS_SERVER=""
DNS_QUERY_TIMEOUT_SEC="2"
CFG

[[ -f "${GROUPS_FILE}" ]] || cat > "${GROUPS_FILE}" <<'TSV'
# group_name<TAB>enabled<TAB>interval_sec<TAB>api_token<TAB>zone_id<TAB>target_fqdn<TAB>ttl<TAB>proxied<TAB>mode<TAB>source_domains_csv
TSV

# shellcheck disable=SC1090
source "${SETTINGS_FILE}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
FORCE_RECONCILE_SEC="${FORCE_RECONCILE_SEC:-3600}"
DNS_SERVER="${DNS_SERVER:-}"
DNS_QUERY_TIMEOUT_SEC="${DNS_QUERY_TIMEOUT_SEC:-2}"

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
  color "1;36" "                          🚀 cfdns 管理菜单 v2.3"
  echo
  color "0;37" "  5秒本机检测 / 安全DNS联动 / 历史查看修复 / 日志清理 / 自检修复 / 多组独立周期"
  line
}


pause_wait() {
  echo
  read -n 1 -s -r -p "按任意键继续..." || true
}

save_settings() {
  cat > "${SETTINGS_FILE}" <<CFG
LOG_LEVEL="${LOG_LEVEL}"
FORCE_RECONCILE_SEC="${FORCE_RECONCILE_SEC}"
DNS_SERVER="${DNS_SERVER}"
DNS_QUERY_TIMEOUT_SEC="${DNS_QUERY_TIMEOUT_SEC}"
CFG
  chmod 600 "${SETTINGS_FILE}"
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

save_groups_with_tmp() {
  local tmp="$1"
  mv "${tmp}" "${GROUPS_FILE}"
  chmod 600 "${GROUPS_FILE}"
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
    jq -nc --arg msg "curl failed rc=${rc}: ${resp}" '{success:false,errors:[{message:$msg}]}'
    return 0
  fi
  if ! jq -e . >/dev/null 2>&1 <<< "${resp}"; then
    jq -nc --arg msg "non-json response" --arg body "${resp:0:300}" '{success:false,errors:[{message:$msg,body:$body}]}'
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
    tmp="$(mktemp)"
    awk -F '	' -v g="${group}" '$1!=g' "${file}" > "${tmp}" || true
    mv "${tmp}" "${file}"
    chmod 600 "${file}" 2>/dev/null || true
  done
}

invalidate_group_sync_state() {
  remove_group_runtime_state "$1"
}

find_duplicate_target() {
  local zone="$1" target="$2" exclude_group="${3:-}"
  awk -F '	' -v z="${zone}" -v t="${target}" -v x="${exclude_group}" \
    '!/^#/ && NF>0 && $1!=x && $5==z && tolower($6)==tolower(t){print $1; exit}' "${GROUPS_FILE}"
}

list_groups_table() {
  printf '%-4s %-14s %-8s %-10s %-28s %-10s %-8s %-10s %-6s\n' "序号" "组名" "启用" "周期(s)" "目标域名" "模式" "TTL" "Proxy" "源数"
  printf '%-4s %-14s %-8s %-10s %-28s %-10s %-8s %-10s %-6s\n' "----" "--------------" "--------" "----------" "----------------------------" "----------" "--------" "----------" "------"

  local i=0 group_name enabled interval_sec api_token zone_id target_fqdn ttl proxied mode sources_csv count
  while IFS=$'	' read -r group_name enabled interval_sec api_token zone_id target_fqdn ttl proxied mode sources_csv; do
    [[ -z "${group_name}" ]] && continue
    [[ "${group_name}" =~ ^# ]] && continue
    i=$((i+1))
    count="$(count_sources_csv "${sources_csv}")"
    printf '%-4s %-14s %-8s %-10s %-28s %-10s %-8s %-10s %-6s\n' "${i}" "${group_name}" "${enabled}" "${interval_sec}" "${target_fqdn}" "${mode}" "${ttl}" "${proxied}" "${count}"
  done < "${GROUPS_FILE}"

  [[ "${i}" -eq 0 ]] && echo "当前还没有任何组。"
}

group_line_by_index() {
  local wanted="$1"
  local i=0 group_name enabled interval_sec api_token zone_id target_fqdn ttl proxied mode sources_csv
  while IFS=$'	' read -r group_name enabled interval_sec api_token zone_id target_fqdn ttl proxied mode sources_csv; do
    [[ -z "${group_name}" ]] && continue
    [[ "${group_name}" =~ ^# ]] && continue
    i=$((i+1))
    if [[ "${i}" -eq "${wanted}" ]]; then
      printf '%s	%s	%s	%s	%s	%s	%s	%s	%s	%s\n' \
        "${group_name}" "${enabled}" "${interval_sec}" "${api_token}" "${zone_id}" "${target_fqdn}" "${ttl}" "${proxied}" "${mode}" "${sources_csv}"
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
  read -rp "请输入组序号: " idx
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
  IFS=$'	' read -r GROUP_NAME GROUP_ENABLED GROUP_INTERVAL GROUP_API_TOKEN GROUP_ZONE_ID GROUP_TARGET_FQDN GROUP_TTL GROUP_PROXIED GROUP_MODE GROUP_SOURCES_CSV <<< "${line}"
}

save_group_line_replace() {
  local old_group_name="$1" new_line="$2" tmp
  tmp="$(mktemp)"
  awk -F '	' -v g="${old_group_name}" -v replacement="${new_line}" '
    BEGIN{done=0}
    /^#/ {print; next}
    NF==0 {next}
    $1==g && done==0 {print replacement; done=1; next}
    {print}
    END{if(done==0) print replacement}
  ' "${GROUPS_FILE}" > "${tmp}"
  save_groups_with_tmp "${tmp}"
}


build_group_line() {
  GROUP_SOURCES_CSV="$(normalize_sources_csv "${GROUP_SOURCES_CSV}")"
  printf '%s	%s	%s	%s	%s	%s	%s	%s	%s	%s' \
    "${GROUP_NAME}" "${GROUP_ENABLED}" "${GROUP_INTERVAL}" "${GROUP_API_TOKEN}" "${GROUP_ZONE_ID}" "${GROUP_TARGET_FQDN}" "${GROUP_TTL}" "${GROUP_PROXIED}" "${GROUP_MODE}" "${GROUP_SOURCES_CSV}"
}

activate_after_init() {
  local group_name="${1:-ALL}"
  systemctl daemon-reload || true
  systemctl reset-failed "${SERVICE_NAME}" "${TIMER_NAME}" 2>/dev/null || true
  systemctl enable --now "${TIMER_NAME}" >/dev/null 2>&1 || true
  /usr/local/bin/cf-dns-sync.sh "${group_name}" FORCE || true
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
  read -rp "请选择 [1-2]: " wizard_choice

  case "${wizard_choice}" in
    1) quick_add_first_group ;;
    2|"") ;;
    *) ;;
  esac

  touch "${INIT_FLAG}"
  chmod 600 "${INIT_FLAG}"
}

quick_add_first_group() {
  echo
  color "1;33" "🧱 创建第一个组"
  echo
  read -rp "组名（例如 group-a）: " group_name || return
  [[ -n "${group_name}" && "${group_name}" != *$'	'* ]] || { echo "组名不能为空且不能包含 TAB"; return; }
  if awk -F '	' -v g="${group_name}" '!/^#/ && $1==g{found=1} END{exit !found}' "${GROUPS_FILE}"; then
    echo "组名已存在"; return
  fi

  prompt_interval || return
  interval_sec="${SELECTED_INTERVAL}"
  read -rsp "Cloudflare API Token: " api_token || return; echo
  read -rp "Zone ID: " zone_id || return
  read -rp "目标域名（例如 tiktokeu.example.com）: " target_fqdn || return
  valid_domain "${target_fqdn}" || { echo "目标域名格式不正确"; return; }
  duplicate="$(find_duplicate_target "${zone_id}" "${target_fqdn}")"
  [[ -z "${duplicate}" ]] || { echo "目标域名已由组 ${duplicate} 管理，禁止重复管理"; return; }
  read -rp "TTL（推荐60）: " ttl || return
  [[ "${ttl}" =~ ^[0-9]+$ ]] || { echo "TTL 必须为数字"; return; }

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

  printf '%s	%s	%s	%s	%s	%s	%s	%s	%s	%s\n' \
    "${group_name}" true "${interval_sec}" "${api_token}" "${zone_id}" "${target_fqdn}" "${ttl}" false "${mode}" "${sources_csv}" >> "${GROUPS_FILE}"
  chmod 600 "${GROUPS_FILE}"
  invalidate_group_sync_state "${group_name}"
  activate_after_init "${group_name}"
  echo "初始化完成：已启用定时器并立即强制同步组 ${group_name}。"
}


move_group_up() {
  echo
  select_group || { echo "序号无效"; return; }
  [[ "${CHOSEN_INDEX}" -gt 1 ]] || { echo "该组已经在最上方"; return; }

  local tmp
  tmp="$(mktemp)"
  awk -v target="${CHOSEN_INDEX}" '
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
  ' "${GROUPS_FILE}" > "${tmp}"

  save_groups_with_tmp "${tmp}"
  echo "已上移"
}

move_group_down() {
  echo
  select_group || { echo "序号无效"; return; }

  local total
  total="$(get_group_count)"
  [[ "${CHOSEN_INDEX}" -lt "${total}" ]] || { echo "该组已经在最下方"; return; }

  local tmp
  tmp="$(mktemp)"
  awk -v target="${CHOSEN_INDEX}" '
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
  ' "${GROUPS_FILE}" > "${tmp}"

  save_groups_with_tmp "${tmp}"
  echo "已下移"
}

add_group() {
  echo
  color "1;33" "➕ 新增组（公开脚本模式）"
  echo
  read -rp "请输入组名（例如 group-a）: " group_name || return
  [[ -n "${group_name}" && "${group_name}" != *$'	'* ]] || { echo "组名不能为空且不能包含 TAB"; return; }
  if awk -F '	' -v g="${group_name}" '!/^#/ && $1==g{found=1} END{exit !found}' "${GROUPS_FILE}"; then echo "组名已存在"; return; fi

  echo "是否启用该组："
  echo "1. ✅ true（启用）"
  echo "2. ⛔ false（禁用）"
  read -rp "请选择 [1-2]: " enabled_choice || return
  case "${enabled_choice}" in 1|"") enabled=true ;; 2) enabled=false ;; *) echo "无效选择"; return ;; esac

  prompt_interval || return
  interval_sec="${SELECTED_INTERVAL}"
  read -rsp "请输入 Cloudflare API Token: " api_token || return; echo
  read -rp "请输入 Zone ID: " zone_id || return
  read -rp "请输入目标域名（例如 tiktokeu.example.com）: " target_fqdn || return
  valid_domain "${target_fqdn}" || { echo "目标域名格式不正确"; return; }
  duplicate="$(find_duplicate_target "${zone_id}" "${target_fqdn}")"
  [[ -z "${duplicate}" ]] || { echo "目标域名已由组 ${duplicate} 管理，禁止重复管理"; return; }
  read -rp "请输入 TTL（推荐 60）: " ttl || return
  [[ "${ttl}" =~ ^[0-9]+$ ]] || { echo "TTL 必须为数字"; return; }

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

  printf '%s	%s	%s	%s	%s	%s	%s	%s	%s	%s\n' \
    "${group_name}" "${enabled}" "${interval_sec}" "${api_token}" "${zone_id}" "${target_fqdn}" "${ttl}" "${proxied}" "${mode}" "${sources_csv}" >> "${GROUPS_FILE}"
  chmod 600 "${GROUPS_FILE}"
  invalidate_group_sync_state "${group_name}"
  systemctl enable --now "${TIMER_NAME}" >/dev/null 2>&1 || true
  echo "组已添加：${group_name}；最快会在下一个5秒调度周期检测。"
}


delete_group() {
  echo
  select_group || { echo "序号无效"; return; }
  local group_name="${CHOSEN_GROUP_NAME}" tmp
  echo "1. ✅ 确认删除"
  echo "2. ↩️  取消"
  read -rp "请选择 [1-2]: " ans || return
  [[ "${ans}" == "1" ]] || { echo "已取消"; return; }
  tmp="$(mktemp)"
  awk -F '	' -v g="${group_name}" '/^#/ || (NF>0 && $1!=g)' "${GROUPS_FILE}" > "${tmp}"
  save_groups_with_tmp "${tmp}"
  remove_group_runtime_state "${group_name}"
  echo "已删除组及其本地状态：${group_name}"
}


toggle_group_enabled() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}"
  if [[ "${GROUP_ENABLED}" == "true" ]]; then GROUP_ENABLED=false; else GROUP_ENABLED=true; fi
  save_group_line_replace "${CHOSEN_GROUP_NAME}" "$(build_group_line)"
  if [[ "${GROUP_ENABLED}" == "true" ]]; then
    invalidate_group_sync_state "${GROUP_NAME}"
    systemctl enable --now "${TIMER_NAME}" >/dev/null 2>&1 || true
  fi
  echo "组 ${GROUP_NAME} 已切换为 ${GROUP_ENABLED}"
}


set_group_interval() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}"
  echo "当前周期：${GROUP_INTERVAL} 秒"
  prompt_interval || return
  GROUP_INTERVAL="${SELECTED_INTERVAL}"
  save_group_line_replace "${CHOSEN_GROUP_NAME}" "$(build_group_line)"
  # 清除上次检查时间，使新周期立即生效。
  tmp="$(mktemp)"; awk -F '	' -v g="${GROUP_NAME}" '$1!=g' "${RUNSTATE_FILE}" 2>/dev/null > "${tmp}" || true; mv "${tmp}" "${RUNSTATE_FILE}"
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
  split_line_to_vars "${CHOSEN_LINE}"
  parse_sources_to_array "${GROUP_SOURCES_CSV}"

  while true; do
    clear 2>/dev/null || true
    line
    color "1;36" "🌐 源域名管理 - ${GROUP_NAME}"
    echo
    line
    local i=0
    for s in "${SOURCES_ARRAY[@]}"; do
      i=$((i+1))
      printf "%2d. %s\n" "${i}" "${s}"
    done
    [[ "${#SOURCES_ARRAY[@]}" -eq 0 ]] && echo "当前无源域名"
    line
    echo "1. ➕ 添加单个源域名"
    echo "2. 🗑️  删除单个源域名"
    echo "3. 📥 批量导入源域名（英文逗号分隔）"
    echo "4. 📤 导出当前源域名（英文逗号分隔）"
    echo "0. ↩️  返回上级"
    line
    if ! read -rp "请选择: " choice; then
      exit 0
    fi

    case "${choice}" in
      1)
        if [[ "${#SOURCES_ARRAY[@]}" -ge 20 ]]; then
          echo "最多只能配置 20 个源域名"
          pause_wait
          continue
        fi
        read -rp "请输入新的源域名: " new_domain
        new_domain="$(normalize_sources_csv "${new_domain}")"
        [[ -n "${new_domain}" ]] || { echo "不能为空"; pause_wait; continue; }
        if printf '%s\n' "${SOURCES_ARRAY[@]}" | grep -Fxq "${new_domain}"; then
          echo "该源域名已存在"
          pause_wait
          continue
        fi
        SOURCES_ARRAY+=("${new_domain}")
        ;;
      2)
        if [[ "${#SOURCES_ARRAY[@]}" -le 1 ]]; then
          echo "至少保留 1 个源域名"
          pause_wait
          continue
        fi
        read -rp "请输入要删除的序号: " del_idx
        if ! [[ "${del_idx}" =~ ^[0-9]+$ ]] || [[ "${del_idx}" -lt 1 || "${del_idx}" -gt "${#SOURCES_ARRAY[@]}" ]]; then
          echo "序号无效"
          pause_wait
          continue
        fi
        unset 'SOURCES_ARRAY[del_idx-1]'
        SOURCES_ARRAY=("${SOURCES_ARRAY[@]}")
        ;;
      3)
        read -rp "请输入源域名列表（英文逗号分隔，最多20个）: " import_csv
        import_csv="$(normalize_sources_csv "${import_csv}")"
        local import_count
        import_count="$(count_sources_csv "${import_csv}")"
        if [[ "${import_count}" -lt 1 || "${import_count}" -gt 20 ]]; then
          echo "导入后的源域名数量必须为 1~20"
          pause_wait
          continue
        fi
        parse_sources_to_array "${import_csv}"
        ;;
      4)
        echo "当前源域名导出结果："
        join_sources_array
        pause_wait
        continue
        ;;
      0) break ;;
      *) echo "无效选择"; pause_wait; continue ;;
    esac

    GROUP_SOURCES_CSV="$(join_sources_array)"
    save_group_line_replace "${CHOSEN_GROUP_NAME}" "$(build_group_line)"
    invalidate_group_sync_state "${GROUP_NAME}"
  done
}

edit_group_basic() {
  echo
  select_group || { echo "序号无效"; return; }
  local old_group_name="${CHOSEN_GROUP_NAME}" old_line="${CHOSEN_LINE}"
  split_line_to_vars "${CHOSEN_LINE}"

  echo "当前组名: ${GROUP_NAME}"
  read -rp "新组名（回车保持）: " new_group_name || return
  [[ -z "${new_group_name}" ]] || GROUP_NAME="${new_group_name}"
  [[ "${GROUP_NAME}" != *$'	'* ]] || { echo "组名不能包含 TAB"; return; }
  if [[ "${GROUP_NAME}" != "${old_group_name}" ]] && awk -F '	' -v g="${GROUP_NAME}" '!/^#/ && $1==g{found=1} END{exit !found}' "${GROUPS_FILE}"; then
    echo "新组名已经存在"; return
  fi

  echo "当前目标域名: ${GROUP_TARGET_FQDN}"
  read -rp "新目标域名（回车保持）: " new_target || return
  [[ -z "${new_target}" ]] || GROUP_TARGET_FQDN="${new_target}"
  valid_domain "${GROUP_TARGET_FQDN}" || { echo "目标域名格式不正确"; return; }

  echo "当前 TTL: ${GROUP_TTL}"
  read -rp "新 TTL（回车保持）: " new_ttl || return
  [[ -z "${new_ttl}" ]] || GROUP_TTL="${new_ttl}"
  [[ "${GROUP_TTL}" =~ ^[0-9]+$ ]] || { echo "TTL 必须为数字"; return; }

  echo "当前 Zone ID: ${GROUP_ZONE_ID}"
  read -rp "新 Zone ID（回车保持）: " new_zone || return
  [[ -z "${new_zone}" ]] || GROUP_ZONE_ID="${new_zone}"

  echo "当前 API Token: 已隐藏"
  read -rsp "新 API Token（回车保持）: " new_token || return; echo
  [[ -z "${new_token}" ]] || GROUP_API_TOKEN="${new_token}"

  duplicate="$(find_duplicate_target "${GROUP_ZONE_ID}" "${GROUP_TARGET_FQDN}" "${old_group_name}")"
  [[ -z "${duplicate}" ]] || { echo "目标域名已由组 ${duplicate} 管理，禁止重复管理"; return; }

  echo "当前解析模式: ${GROUP_MODE}"
  echo "1. ➖ 保持不变"
  echo "2. 🌐 ALL_IPS（全部IP模式）"
  echo "3. 🎯 SINGLE_IP（单IP模式）"
  read -rp "请选择 [1-3]: " mode_choice || return
  case "${mode_choice}" in 1|"") ;; 2) GROUP_MODE=ALL_IPS ;; 3) GROUP_MODE=SINGLE_IP ;; *) echo "无效选择"; return ;; esac

  new_line="$(build_group_line)"
  save_group_line_replace "${old_group_name}" "${new_line}"
  remove_group_runtime_state "${old_group_name}"
  [[ "${GROUP_NAME}" == "${old_group_name}" ]] || remove_group_runtime_state "${GROUP_NAME}"
  echo "组配置已原位更新，并已清除旧同步状态以触发重新校准。"
}


set_log_level() {
  echo
  echo "请选择日志等级："
  echo "1. 🔇 NONE（空日志）"
  echo "2. ❌ ERROR（仅错误）"
  echo "3. ℹ️  INFO（普通信息）"
  echo "4. 🐞 DEBUG（调试详情）"
  read -rp "请输入序号 [1-4]: " choice

  case "${choice}" in
    1) LOG_LEVEL="NONE" ;;
    2) LOG_LEVEL="ERROR" ;;
    3) LOG_LEVEL="INFO" ;;
    4) LOG_LEVEL="DEBUG" ;;
    *) echo "无效选择"; return ;;
  esac

  save_settings
  echo "日志等级已设置为 ${LOG_LEVEL}"
}

test_group_token() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}"
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
  split_line_to_vars "${CHOSEN_LINE}"
  parse_sources_to_array "${GROUP_SOURCES_CSV}"
  echo "测试组 ${GROUP_NAME} 的源域名解析情况"
  printf '%-4s %-45s %-8s %-6s %-60s\n' "序号" "源域名" "状态" "数量" "IPv4结果"
  printf '%-4s %-45s %-8s %-6s %-60s\n' "----" "---------------------------------------------" "--------" "------" "------------------------------------------------------------"
  local i=0 domain ips count joined
  for domain in "${SOURCES_ARRAY[@]}"; do
    i=$((i+1))
    ips="$(ui_resolve_domain_ipv4 "${domain}")"
    count="$(sed '/^$/d' <<< "${ips}" | wc -l | awk '{print $1}')"
    joined="$(paste -sd ',' <<< "${ips}")"
    if [[ "${count}" -gt 0 ]]; then
      printf '%-4s %-45s %-8s %-6s %-60s\n' "${i}" "${domain}" "正常" "${count}" "${joined:0:60}"
    else
      printf '%-4s %-45s %-8s %-6s %-60s\n' "${i}" "${domain}" "失败" 0 "-"
    fi
  done
}


view_group_current_ips() {
  echo
  select_group || { echo "序号无效"; return; }
  split_line_to_vars "${CHOSEN_LINE}"
  parse_sources_to_array "${GROUP_SOURCES_CSV}"
  local tmp_all i=0 domain ips selected count joined resp encoded
  tmp_all="$(mktemp)"; : > "${tmp_all}"

  echo "📡 当前组别解析 IP：${GROUP_NAME}"
  echo "目标域名: ${GROUP_TARGET_FQDN}"
  echo "解析模式: ${GROUP_MODE}"
  echo "DNS解析器: ${DNS_SERVER:-系统默认}"
  echo
  printf '%-4s %-45s %-6s %-60s\n' "序号" "源域名" "数量" "IPv4结果"
  printf '%-4s %-45s %-6s %-60s\n' "----" "---------------------------------------------" "------" "------------------------------------------------------------"
  for domain in "${SOURCES_ARRAY[@]}"; do
    i=$((i+1)); ips="$(ui_resolve_domain_ipv4 "${domain}")"
    if [[ "${GROUP_MODE}" == "SINGLE_IP" ]]; then
      selected="$(sed '/^$/d' <<< "${ips}" | head -n1)"
      [[ -n "${selected}" ]] && echo "${selected}" >> "${tmp_all}"
      count=$([[ -n "${selected}" ]] && echo 1 || echo 0); joined="${selected:-}"
    else
      sed '/^$/d' <<< "${ips}" >> "${tmp_all}"
      count="$(sed '/^$/d' <<< "${ips}" | wc -l | awk '{print $1}')"
      joined="$(paste -sd ',' <<< "${ips}")"
    fi
    [[ -n "${joined}" ]] || joined="-"
    printf '%-4s %-45s %-6s %-60s\n' "${i}" "${domain}" "${count}" "${joined:0:60}"
  done

  echo; echo "去重后将用于同步的 IPv4："
  sort -u "${tmp_all}" | sed '/^$/d' | nl -w2 -s'. '
  echo "总数: $(sort -u "${tmp_all}" | sed '/^$/d' | wc -l | awk '{print $1}')"

  echo; echo "Cloudflare 当前目标 A 记录："
  encoded="$(urlencode "${GROUP_TARGET_FQDN}")"
  resp="$(ui_cf_get "https://api.cloudflare.com/client/v4/zones/${GROUP_ZONE_ID}/dns_records?type=A&name=${encoded}&per_page=100" "${GROUP_API_TOKEN}")"
  if [[ "$(jq -r '.success // false' <<< "${resp}" 2>/dev/null)" == true ]]; then
    jq -r '.result[]?.content' <<< "${resp}" | sed '/^$/d' | sort -u | nl -w2 -s'. '
    echo "总数: $(jq -r '.result[]?.content' <<< "${resp}" | sed '/^$/d' | sort -u | wc -l | awk '{print $1}')"
  else
    echo "无法读取 Cloudflare 当前记录：$(jq -c '.errors // []' <<< "${resp}" 2>/dev/null || echo unknown)"
  fi
  rm -f "${tmp_all}"
}


start_sync() {
  systemctl enable --now "${TIMER_NAME}"
  systemctl start "${SERVICE_NAME}" || true
  echo "已启动"
}

stop_sync() {
  systemctl stop "${TIMER_NAME}" 2>/dev/null || true
  systemctl disable "${TIMER_NAME}" 2>/dev/null || true
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  echo "已停止"
}

restart_sync() {
  systemctl daemon-reload
  systemctl reset-failed "${SERVICE_NAME}" "${TIMER_NAME}" 2>/dev/null || true
  systemctl restart "${TIMER_NAME}"
  systemctl restart "${SERVICE_NAME}" || true
  echo "已重启"
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


show_logs() {
  if [[ ! -s "${LOG_FILE}" ]]; then echo "暂无项目运行日志"; return; fi
  tail -n 150 "${LOG_FILE}"
}


follow_logs() {
  touch "${LOG_FILE}"; chmod 600 "${LOG_FILE}" 2>/dev/null || true
  echo "按 Ctrl+C 退出实时日志"
  tail -n 50 -f "${LOG_FILE}"
}


show_group_runtime_logs() {
  echo
  select_group || { echo "序号无效"; return; }
  if [[ -f "${LOG_FILE}" ]]; then
    grep -F "组 ${CHOSEN_GROUP_NAME}:" "${LOG_FILE}" | tail -n 200 || echo "暂无该组运行日志"
  else
    echo "日志文件不存在"
  fi
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
}


show_dep_status() {
  printf '%-18s %-10s\n' "Command" "Status"
  printf '%-18s %-10s\n' "------------------" "----------"
  for cmd in curl jq dig flock logrotate zcat gzip awk sed grep comm mktemp paste cut tr date wc; do
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

  printf '%-16s %-20s\n' "组名" "上次执行时间"
  printf '%-16s %-20s\n' "----------------" "--------------------"
  tmp="$(mktemp)"
  sort -t $'\t' -k1,1 "${RUNSTATE_FILE}" > "${tmp}" 2>/dev/null || cp -f "${RUNSTATE_FILE}" "${tmp}"
  while IFS=$'\t' read -r group epoch _; do
    [[ -n "${group}" && "${epoch}" =~ ^[0-9]+$ ]] || continue
    readable="$(date -d "@${epoch}" '+%F %T' 2>/dev/null || true)"
    [[ -n "${readable}" ]] || continue
    printf '%-16s %-20s\n' "${group:0:16}" "${readable}"
    shown=$((shown+1))
  done < "${tmp}"
  rm -f "${tmp}"
  [[ "${shown}" -gt 0 ]] || echo "暂无有效的运行状态记录"
}

collect_history_to_file() {
  local output="$1" f
  : > "${output}"
  shopt -s nullglob
  local files=("${HISTORY_FILE}" "${HISTORY_FILE}".*)
  shopt -u nullglob

  for f in "${files[@]}"; do
    [[ -f "${f}" ]] || continue
    case "${f}" in
      *.gz) gzip -cd -- "${f}" >> "${output}" 2>/dev/null || true ;;
      *) cat -- "${f}" >> "${output}" 2>/dev/null || true ;;
    esac
  done
}

render_history_data_file() {
  local input="$1" cutoff="$2" record_mode="$3" target_group="${4:-}"
  local record_time group action ip source_domain mode metadata extra ts target shown=0

  while IFS=$'\t' read -r record_time group action ip source_domain mode metadata extra; do
    [[ -n "${record_time}" && -n "${group}" && -n "${action}" && -n "${ip}" ]] || continue
    [[ -z "${extra:-}" ]] || continue
    ts="$(date -d "${record_time}" +%s 2>/dev/null || true)"
    [[ "${ts}" =~ ^[0-9]+$ ]] || continue
    (( ts >= cutoff )) || continue
    [[ -z "${target_group}" || "${group}" == "${target_group}" ]] || continue
    [[ "${record_mode}" != "deleted" || "${action}" == "DELETE" ]] || continue
    target="${metadata%%|*}"

    if [[ "${record_mode}" == "all" ]]; then
      printf '%-20s %-14s %-8s %-16s %-28s %-10s %-30s\n' \
        "${record_time:0:20}" "${group:0:14}" "${action:0:8}" "${ip:0:16}" \
        "${source_domain:0:28}" "${mode:0:10}" "${target:0:30}"
    else
      printf '%-20s %-14s %-16s %-28s %-10s %-30s\n' \
        "${record_time:0:20}" "${group:0:14}" "${ip:0:16}" \
        "${source_domain:0:28}" "${mode:0:10}" "${target:0:30}"
    fi
    shown=$((shown+1))
  done < "${input}"

  [[ "${shown}" -gt 0 ]] || echo "暂无符合条件的历史记录"
}

history_renderer_self_test() {
  local tmp out
  tmp="$(mktemp)"
  printf '2026-01-02 03:04:05\ttest-group\tDELETE\t203.0.113.10\tsource.example.com\tALL_IPS\ttarget.example.com|self_test\n' > "${tmp}"
  out="$(render_history_data_file "${tmp}" 0 deleted test-group 2>&1)"
  rm -f "${tmp}"
  grep -Fq '203.0.113.10' <<< "${out}"
}

render_history_table() {
  local days="$1" record_mode="$2" target_group="${3:-}"
  local cutoff now raw sorted
  now="$(date +%s)"
  cutoff=$((now - days*24*3600))
  raw="$(mktemp)"
  sorted="$(mktemp)"

  collect_history_to_file "${raw}"
  LC_ALL=C sort -t $'\t' -k1,1 -k2,2 "${raw}" > "${sorted}" 2>/dev/null || cp -f "${raw}" "${sorted}"

  if [[ "${record_mode}" == "all" ]]; then
    printf '%-20s %-14s %-8s %-16s %-28s %-10s %-30s\n' \
      "Time" "Group" "Action" "IP" "SourceDomain" "Mode" "Target"
    printf '%-20s %-14s %-8s %-16s %-28s %-10s %-30s\n' \
      "--------------------" "--------------" "--------" "----------------" \
      "----------------------------" "----------" "------------------------------"
  else
    printf '%-20s %-14s %-16s %-28s %-10s %-30s\n' \
      "Time" "Group" "DeletedIP" "SourceDomain" "Mode" "Target"
    printf '%-20s %-14s %-16s %-28s %-10s %-30s\n' \
      "--------------------" "--------------" "----------------" \
      "----------------------------" "----------" "------------------------------"
  fi

  render_history_data_file "${sorted}" "${cutoff}" "${record_mode}" "${target_group}"
  rm -f "${raw}" "${sorted}"
}

history_menu() {
  local days record_mode scope group=""

  while true; do
    clear 2>/dev/null || true
    line
    color "1;36" "📜 查看域名 IP 历史记录"
    echo
    line
    echo "1. 🕒 查看最近三天的历史"
    echo "2. 📅 查看最近一周的历史"
    echo "3. 🗓️  查看最近一个月的历史"
    echo "4. ✍️  自定义时间：查看多少天前到今天的历史"
    echo "5. 🧾 查看最近半年的历史"
    echo "0. ↩️  返回主菜单"
    line
    if ! read -rp "请选择时间范围: " time_choice; then
      return
    fi

    case "${time_choice}" in
      1) days=3 ;;
      2) days=7 ;;
      3) days=30 ;;
      4)
        read -rp "请输入天数，例如 10 表示最近10天: " days
        [[ "${days}" =~ ^[0-9]+$ && "${days}" -ge 1 ]] || { echo "天数无效"; pause_wait; continue; }
        ;;
      5) days=180 ;;
      0) return ;;
      *) echo "无效选择"; pause_wait; continue ;;
    esac

    echo
    echo "请选择记录类型："
    echo "1. 🔁 全部变更记录（新增 + 删除）"
    echo "2. 🗑️  仅删除旧 IP 记录"
    read -rp "请选择 [1-2]: " mode_choice
    case "${mode_choice}" in
      1) record_mode="all" ;;
      2) record_mode="deleted" ;;
      *) echo "无效选择"; pause_wait; continue ;;
    esac

    echo
    echo "请选择查看范围："
    echo "1. 🌍 全部组"
    echo "2. 📦 单个组"
    read -rp "请选择 [1-2]: " scope_choice
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
    echo "历史范围：最近 ${days} 天；记录类型：${record_mode}；查看范围：${scope}${group:+ / ${group}}"
    echo
    render_history_table "${days}" "${record_mode}" "${group}"
    pause_wait
  done
}

self_check() {
  local errors=0 warnings=0 group_count=0 enabled_count=0
  local line_no=0 name enabled interval token zone target ttl proxied mode sources_csv extra src_count key duplicate source_domain
  declare -A seen_names=() seen_targets=()
  echo "🩺 cfdns v2.3 自检"
  line
  check_ok(){ printf '✅ %s\n' "$*"; }
  check_warn(){ warnings=$((warnings+1)); printf '⚠️  %s\n' "$*"; }
  check_fail(){ errors=$((errors+1)); printf '❌ %s\n' "$*"; }

  [[ "$(id -u)" -eq 0 ]] && check_ok "当前为 root" || check_fail "请使用 root 运行"
  for d in "${BASE_DIR}" "${VAR_DIR}"; do [[ -d "${d}" ]] && check_ok "目录存在：${d}" || check_fail "目录缺失：${d}"; done
  for f in "${SETTINGS_FILE}" "${GROUPS_FILE}" /usr/local/bin/cfdns /usr/local/bin/cf-dns-sync.sh; do [[ -e "${f}" ]] && check_ok "文件存在：${f}" || check_fail "文件缺失：${f}"; done
  bash -n /usr/local/bin/cfdns >/dev/null 2>&1 && check_ok "管理脚本语法正常" || check_fail "管理脚本语法异常"
  bash -n /usr/local/bin/cf-dns-sync.sh >/dev/null 2>&1 && check_ok "同步脚本语法正常" || check_fail "同步脚本语法异常"
  for cmd in curl jq dig flock logrotate zcat gzip awk sed grep comm mktemp paste cut tr date wc cmp systemctl tar install xargs; do command -v "${cmd}" >/dev/null 2>&1 && check_ok "依赖：${cmd}" || check_fail "缺少依赖：${cmd}"; done

  case "${LOG_LEVEL}" in NONE|OFF|ERROR|INFO|DEBUG) check_ok "日志等级合法：${LOG_LEVEL}" ;; *) check_fail "日志等级非法：${LOG_LEVEL}" ;; esac
  [[ "${FORCE_RECONCILE_SEC}" =~ ^[0-9]+$ && "${FORCE_RECONCILE_SEC}" -ge 60 ]] && check_ok "强制校准周期：${FORCE_RECONCILE_SEC}s" || check_fail "FORCE_RECONCILE_SEC 必须 >=60"
  [[ "${DNS_QUERY_TIMEOUT_SEC}" =~ ^[0-9]+$ && "${DNS_QUERY_TIMEOUT_SEC}" -ge 1 ]] && check_ok "DNS 查询超时：${DNS_QUERY_TIMEOUT_SEC}s" || check_fail "DNS_QUERY_TIMEOUT_SEC 必须 >=1"

  while IFS=$'	' read -r name enabled interval token zone target ttl proxied mode sources_csv extra; do
    line_no=$((line_no+1)); [[ -z "${name}" || "${name}" =~ ^# ]] && continue
    group_count=$((group_count+1)); [[ "${enabled}" == true ]] && enabled_count=$((enabled_count+1))
    [[ -z "${extra:-}" ]] || check_fail "groups.tsv 第${line_no}行字段过多"
    [[ -z "${seen_names[${name}]+x}" ]] || check_fail "组名重复：${name}"; seen_names["${name}"]=1
    key="${zone}|${target,,}"
    if [[ -n "${seen_targets[${key}]+x}" ]]; then check_fail "目标记录重复管理：${target}（组 ${seen_targets[${key}]} 与 ${name}）"; else seen_targets["${key}"]="${name}"; fi
    [[ "${enabled}" == true || "${enabled}" == false ]] || check_fail "组 ${name}: enabled 非法"
    [[ "${interval}" =~ ^[0-9]+$ && "${interval}" -ge 5 ]] || check_fail "组 ${name}: 周期必须 >=5 秒"
    [[ -n "${token}" ]] || check_fail "组 ${name}: Token 为空"
    [[ "${zone}" =~ ^[a-fA-F0-9]{32}$ ]] || check_warn "组 ${name}: Zone ID 格式可疑"
    valid_domain "${target}" || check_fail "组 ${name}: 目标域名格式错误"
    [[ "${ttl}" =~ ^[0-9]+$ ]] || check_fail "组 ${name}: TTL 非数字"
    [[ "${proxied}" == false ]] || check_fail "组 ${name}: 仅支持 proxied=false"
    [[ "${mode}" == ALL_IPS || "${mode}" == SINGLE_IP ]] || check_fail "组 ${name}: mode 非法"
    src_count="$(count_sources_csv "${sources_csv:-}")"; [[ "${src_count}" -ge 1 && "${src_count}" -le 20 ]] || check_fail "组 ${name}: 源域名数量=${src_count}，应为1~20"
    parse_sources_to_array "${sources_csv:-}"
    for source_domain in "${SOURCES_ARRAY[@]}"; do
      valid_domain "${source_domain}" || check_fail "组 ${name}: 源域名格式错误：${source_domain}"
    done
  done < "${GROUPS_FILE}"

  [[ "${group_count}" -gt 0 ]] && check_ok "配置组数量：${group_count}" || check_warn "当前没有配置组"
  [[ "${enabled_count}" -gt 0 ]] && check_ok "启用组数量：${enabled_count}" || check_warn "当前没有启用组"

  grep -Fq 'ExecStart=/usr/local/bin/cf-dns-sync.sh AUTO' /etc/systemd/system/cf-dns-sync.service 2>/dev/null && check_ok "service 使用 AUTO 本机检测模式" || check_fail "service ExecStart 不是 AUTO 模式"
  grep -Fq 'OnUnitActiveSec=5s' /etc/systemd/system/cf-dns-sync.timer 2>/dev/null && check_ok "timer 基础调度为5秒" || check_fail "timer 未配置5秒调度"
  systemctl is-active --quiet "${TIMER_NAME}" && check_ok "timer 正在运行" || check_warn "timer 未运行"
  systemctl is-failed --quiet "${SERVICE_NAME}" && check_warn "service 处于 failed，建议一键修复" || check_ok "service 未处于 failed"
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify /etc/systemd/system/cf-dns-sync.service /etc/systemd/system/cf-dns-sync.timer >/dev/null 2>&1 && check_ok "systemd 单元校验正常" || check_fail "systemd 单元校验失败"
  fi
  [[ -f "${INSTALL_COPY}" ]] && check_ok "一键修复安装器副本存在" || check_warn "安装器副本不存在；一键修复只能修复外围文件"
  history_renderer_self_test && check_ok "历史记录渲染自测正常" || check_fail "历史记录渲染自测失败"

  local malformed_history=0 history_raw history_line fields
  history_raw="$(mktemp)"
  collect_history_to_file "${history_raw}"
  while IFS= read -r history_line; do
    [[ -z "${history_line}" ]] && continue
    fields="$(awk -F '\t' '{print NF}' <<< "${history_line}")"
    [[ "${fields}" -eq 7 ]] || malformed_history=$((malformed_history+1))
  done < "${history_raw}"
  rm -f "${history_raw}"
  [[ "${malformed_history}" -eq 0 ]] && check_ok "历史日志字段结构正常" || check_warn "历史日志存在 ${malformed_history} 条格式异常记录；查看时会自动跳过"

  if command -v cfcname >/dev/null 2>&1 || [[ -f /etc/cfcname/config.json ]]; then
    check_warn "检测到 cfcname；服务名和目录不冲突，但同一 DNS 名称不能同时由两套脚本管理。"
    if [[ -f /etc/cfcname/config.json ]]; then
      while IFS=$'	' read -r name enabled interval token zone target ttl proxied mode sources_csv; do
        [[ -z "${name}" || "${name}" =~ ^# ]] && continue
        grep -Fq "${target}" /etc/cfcname/config.json 2>/dev/null && check_warn "目标 ${target} 也出现在 cfcname 配置中"
      done < "${GROUPS_FILE}"
    fi
  fi
  line
  echo "自检完成：errors=${errors}, warnings=${warnings}"
  [[ "${errors}" -eq 0 ]]
}


one_key_repair() {
  echo "🧯 cfdns v2.3 一键修复"
  line
  [[ "$(id -u)" -eq 0 ]] || { echo "请使用 root 运行"; return 1; }

  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  if ! command -v dig >/dev/null 2>&1; then command -v apt-get >/dev/null 2>&1 && missing+=(dnsutils) || missing+=(bind-utils); fi
  command -v logrotate >/dev/null 2>&1 || missing+=(logrotate)
  command -v zcat >/dev/null 2>&1 || missing+=(gzip)
  command -v gzip >/dev/null 2>&1 || missing+=(gzip)
  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "补装缺失依赖：${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then apt-get update || true; apt-get install -y "${missing[@]}" || true
    elif command -v dnf >/dev/null 2>&1; then dnf install -y "${missing[@]}" || true
    elif command -v yum >/dev/null 2>&1; then yum install -y "${missing[@]}" || true; fi
  fi

  if [[ -f "${INSTALL_COPY}" ]]; then
    echo "使用本地完整安装器重建程序模块，保留现有配置和状态……"
    CFDNS_SKIP_DEPS=1 CFDNS_NO_START=1 bash "${INSTALL_COPY}" || { echo "完整模块重建失败"; return 1; }
  else
    echo "未找到 ${INSTALL_COPY}，仅修复目录、权限和 systemd 单元。"
  fi

  mkdir -p "${BASE_DIR}" "${VAR_DIR}" /var/log
  chmod 700 "${BASE_DIR}" "${VAR_DIR}" 2>/dev/null || true
  touch "${STATE_FILE}" "${RUNSTATE_FILE}" "${RECONCILE_FILE}" "${LOG_FILE}" "${HISTORY_FILE}"
  chmod 600 "${STATE_FILE}" "${RUNSTATE_FILE}" "${RECONCILE_FILE}" "${LOG_FILE}" "${HISTORY_FILE}" "${SETTINGS_FILE}" "${GROUPS_FILE}" 2>/dev/null || true
  chmod +x /usr/local/bin/cfdns /usr/local/bin/cf-dns-sync.sh 2>/dev/null || true
  systemctl daemon-reload || true
  systemctl reset-failed "${SERVICE_NAME}" "${TIMER_NAME}" 2>/dev/null || true
  systemctl enable --now "${TIMER_NAME}" || true
  /usr/local/bin/cf-dns-sync.sh ALL FORCE || true
  echo "一键修复完成。"
  self_check || true
}


collect_log_family() {
  local base="$1"
  LOG_FAMILY=("${base}")
  shopt -s nullglob
  local f
  for f in "${base}".*; do LOG_FAMILY+=("${f}"); done
  shopt -u nullglob
}

purge_project_log() {
  local base="$1" days="$2" kind="$3" cutoff tmp combined
  cutoff="$(date -d "${days} days ago" '+%F %T')" || return 1
  tmp="$(mktemp)"
  combined="$(mktemp)"
  collect_log_family "${base}"
  if [[ "${#LOG_FAMILY[@]}" -gt 0 ]]; then
    zcat -f "${LOG_FAMILY[@]}" 2>/dev/null > "${combined}" || true
  fi

  if [[ "${kind}" == "runtime" ]]; then
    awk -v c="${cutoff}" '
      /^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]/ {
        if (substr($0,2,19) >= c) print
        next
      }
      {print}
    ' "${combined}" | LC_ALL=C sort > "${tmp}" || { rm -f "${tmp}" "${combined}"; return 1; }
  else
    awk -F '\t' -v c="${cutoff}" '
      /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/ {
        if (substr($0,1,19) >= c) print
        next
      }
      {print}
    ' "${combined}" | LC_ALL=C sort > "${tmp}" || { rm -f "${tmp}" "${combined}"; return 1; }
  fi

  # 先原子替换当前文件，成功后再删除轮转副本，避免清理中断造成日志丢失。
  install -m 600 "${tmp}" "${base}" || { rm -f "${tmp}" "${combined}"; return 1; }
  rm -f "${base}".* 2>/dev/null || true
  rm -f "${tmp}" "${combined}"
}

clean_logs_menu() {
  local days scope choice rc=0
  while true; do
    clear 2>/dev/null || true
    line
    echo "🧹 清理 cfdns 项目日志"
    line
    echo "1. 🗓️  清理 7 天前的日志"
    echo "2. 📆 清理 30 天前的日志"
    echo "0. ↩️  返回"
    read -rp "请选择: " choice || return
    case "${choice}" in 1) days=7 ;; 2) days=30 ;; 0) return ;; *) echo "无效选择"; pause_wait; continue ;; esac

    echo "1. 📄 普通运行日志"
    echo "2. 📜 IP 变更历史日志"
    echo "3. 🧹 两种项目日志全部清理"
    echo "0. ↩️  返回"
    read -rp "请选择清理范围: " scope || return

    exec 8>/run/cf-dns-sync.lock
    if ! flock -w 30 8; then
      echo "同步任务正在运行，等待30秒后仍未取得锁；本次未清理，避免与写日志并发"
      pause_wait
      continue
    fi

    rc=0
    case "${scope}" in
      1) purge_project_log "${LOG_FILE}" "${days}" runtime || rc=1 ;;
      2) purge_project_log "${HISTORY_FILE}" "${days}" history || rc=1 ;;
      3)
        purge_project_log "${LOG_FILE}" "${days}" runtime || rc=1
        purge_project_log "${HISTORY_FILE}" "${days}" history || rc=1
        ;;
      0) flock -u 8; continue ;;
      *) flock -u 8; echo "无效选择"; pause_wait; continue ;;
    esac
    flock -u 8

    if [[ "${rc}" -eq 0 ]]; then
      echo "已清理 ${days} 天前的 cfdns 项目文件日志。未清理系统全局 journal。"
    else
      echo "日志清理未完整完成，原日志已尽量保留；请运行自检并查看项目日志。"
    fi
    pause_wait
  done
}

edit_raw_files() {
  echo
  echo "1. 📝 编辑 settings.conf（全局日志等级）"
  echo "2. 🧩 编辑 groups.tsv（所有组配置）"
  echo "0. ↩️  返回"
  read -rp "请选择: " choice
  case "${choice}" in
    1) ${EDITOR:-vi} "${SETTINGS_FILE}" ;;
    2) ${EDITOR:-vi} "${GROUPS_FILE}" ;;
    0) ;;
    *) echo "无效选择" ;;
  esac
}

uninstall_all() {
  read -rp "确认彻底卸载 cfdns？输入 yes 继续: " ans
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
  rm -f /var/log/cf-dns-sync.log
  rm -f /var/log/cf-dns-sync-history.tsv
  rm -f /var/log/cf-dns-sync-history.tsv.*
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
    echo "  1.  📦 查看全部组（List Groups / 查看组）"
    echo "  2.  ➕ 新增组（Add Group / 新增组）"
    echo "  3.  🗑️  删除组（Delete Group / 删除组）"
    echo "  4.  📝 编辑组基础信息（Edit Group / 编辑组）"
    echo "  5.  🌐 管理组内源域名（Manage Sources / 源域名管理）"
    echo "  6.  🔘 切换组启用状态（Enable/Disable / 启用禁用）"
    echo "  7.  ⏱️  设置组检测周期（Set Interval / 最短5秒）"
    echo "  8.  🔑 测试组 API Token（Test Token / 测试令牌）"
    echo "  9.  🧪 测试组源域名解析（Test Sources DNS / 解析测试）"
    echo " 10.  📡 查看组别当前解析 IP（Current IPs / 当前IP）"
    echo " 11.  ⬆️  组上移（Move Up / 上移）"
    echo " 12.  ⬇️  组下移（Move Down / 下移）"
    echo " 13.  🔊 设置日志等级（Log Level / 日志等级）"
    echo " 14.  ▶️  启动（Start / 启动）"
    echo " 15.  ⏹️  停止（Stop / 停止）"
    echo " 16.  🔄 重启（Restart / 重启）"
    echo " 17.  🚀 手动强制同步全部组（Sync All / 全部同步）"
    echo " 18.  🎯 手动强制同步单个组（Sync One / 单组同步）"
    echo " 19.  📄 查看最近项目日志（Logs / 最近日志）"
    echo " 20.  👀 实时查看项目日志（Follow Logs / 实时日志）"
    echo " 21.  📌 查看单组运行日志（One Group Logs / 单组日志）"
    echo " 22.  🩺 查看 service/timer 状态（Status / 状态）"
    echo " 23.  🧰 查看依赖状态（Dependencies / 依赖）"
    echo " 24.  🔎 脚本自检（Self Check / 自检）"
    echo " 25.  🧯 一键修复（Repair / 修复）"
    echo " 26.  🕓 查看各组上次检测时间（Run State / 执行状态）"
    echo " 27.  📜 查看域名 IP 历史记录（History / 历史记录）"
    echo " 28.  🧹 清理项目日志（Clean Logs / 7天或30天）"
    echo " 29.  🛠️  编辑原始配置文件（Edit Raw Files / 原始配置）"
    echo " 30.  💣 彻底卸载（Uninstall / 卸载）"
    echo "  0.  🚪 退出（Exit / 退出）"
    line
    read -rp "请选择: " choice || exit 0
    case "${choice}" in
      1) list_groups_table; pause_wait ;; 2) add_group; pause_wait ;; 3) delete_group; pause_wait ;;
      4) edit_group_basic; pause_wait ;; 5) manage_group_sources ;; 6) toggle_group_enabled; pause_wait ;;
      7) set_group_interval; pause_wait ;; 8) test_group_token; pause_wait ;; 9) test_group_sources_dns; pause_wait ;;
      10) view_group_current_ips; pause_wait ;; 11) move_group_up; pause_wait ;; 12) move_group_down; pause_wait ;;
      13) set_log_level; pause_wait ;; 14) start_sync; pause_wait ;; 15) stop_sync; pause_wait ;;
      16) restart_sync; pause_wait ;; 17) manual_run_all; pause_wait ;; 18) manual_run_one; pause_wait ;;
      19) show_logs; pause_wait ;; 20) follow_logs ;; 21) show_group_runtime_logs; pause_wait ;;
      22) show_status; pause_wait ;; 23) show_dep_status; pause_wait ;; 24) self_check; pause_wait ;;
      25) one_key_repair; pause_wait ;; 26) show_runstate; pause_wait ;; 27) history_menu ;;
      28) clean_logs_menu ;; 29) edit_raw_files ;; 30) uninstall_all ;; 0) exit 0 ;;
      *) echo "无效选择"; sleep 1 ;;
    esac
  done
}


menu
CTL
  chmod +x "${BIN_CTL}"
}

write_service() {
  cat > "${SERVICE_FILE}" <<'SERVICE'
[Unit]
Description=Cloudflare DNS Multi-Group Local Change Detector
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
}
write_timer() {
  cat > "${TIMER_FILE}" <<'TIMER'
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
}
write_logrotate() {
  cat > "${LOGROTATE_FILE}" <<'ROTATE'
/var/log/cf-dns-sync.log /var/log/cf-dns-sync-history.tsv {
    daily
    rotate 180
    maxage 180
    missingok
    notifempty
    compress
    delaycompress
    dateext
    copytruncate
    create 600 root root
}
ROTATE
  chmod 644 "${LOGROTATE_FILE}"
}

backup_existing() {
  mkdir -p "${BACKUP_DIR}"
  local stamp archive
  stamp="$(date +%Y%m%d%H%M%S)"
  archive="${BACKUP_DIR}/cfdns-backup-${stamp}.tar.gz"
  local rel_items=()
  [[ -d "${BASE_DIR}" ]] && rel_items+=("etc/cf-dns-sync")
  [[ -d "${VAR_DIR}" ]] && rel_items+=("var/lib/cf-dns-sync")
  if [[ "${#rel_items[@]}" -gt 0 ]]; then
    tar -C / --exclude='var/lib/cf-dns-sync/backups' -czf "${archive}" "${rel_items[@]}" 2>/dev/null || true
  fi
  find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'cfdns-backup-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR>10{print $2}' | xargs -r rm -f
}

store_installer_copy() {
  mkdir -p "${INSTALL_DIR}"
  if [[ -f "$0" ]] && grep -q 'cfdns v2.3 installer' "$0" 2>/dev/null; then
    install -m 700 "$0" "${INSTALL_COPY}"
  fi
}

main() {
  [[ "$(id -u)" -eq 0 ]] || { echo "请使用 root 运行"; exit 1; }
  install_missing_deps
  mkdir -p "${BASE_DIR}" "${VAR_DIR}" "${BACKUP_DIR}"
  backup_existing
  write_settings
  write_groups
  sed -i 's/\r$//' "${GROUPS_FILE}" 2>/dev/null || true
  write_sync_script
  write_ctl_script
  write_service
  write_timer
  write_logrotate
  touch "${HISTORY_FILE}" "${RUNSTATE_FILE}" "${STATE_FILE}" "${VAR_DIR}/reconcile.tsv" "${LOG_FILE}"
  chmod 600 "${HISTORY_FILE}" "${RUNSTATE_FILE}" "${STATE_FILE}" "${VAR_DIR}/reconcile.tsv" "${LOG_FILE}" "${SETTINGS_FILE}" "${GROUPS_FILE}"
  store_installer_copy
  systemctl daemon-reload || true
  systemctl reset-failed "${APP_NAME}.service" "${APP_NAME}.timer" 2>/dev/null || true
  if [[ "${CFDNS_NO_START:-0}" != "1" ]]; then
    systemctl enable --now "${APP_NAME}.timer" || true
    systemctl start "${APP_NAME}.service" || true
  fi
  echo
  echo "安装/升级完成: v2.3"
  echo "管理命令: cfdns"
  echo "本机基础调度周期: 5 秒"
  echo "每组按照独立周期查询源域名；源 IP 未变化时不会调用 Cloudflare API。"
  echo "组配置: ${GROUPS_FILE}"
  echo "升级备份: ${BACKUP_DIR}"
  echo "自检/一键修复: cfdns 菜单 24 / 25"
  if [[ "${CFDNS_NO_START:-0}" != "1" ]]; then
    systemctl status "${APP_NAME}.timer" --no-pager -l || true
  fi
}

main
