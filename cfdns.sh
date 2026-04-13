cat > /root/install_cfdns_v1_5.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="cf-dns-sync"
BASE_DIR="/etc/${APP_NAME}"
VAR_DIR="/var/lib/${APP_NAME}"
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

  printf '%s\n' "${missing[@]}" | sed '/^$/d' | sort -u
}

install_missing_deps() {
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
    apt-get install -y ${pkgs}
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ${pkgs}
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ${pkgs}
  else
    echo "不支持的包管理器，请手动安装：${pkgs}"
    exit 1
  fi
}

write_settings() {
  if [[ ! -f "${SETTINGS_FILE}" ]]; then
    cat > "${SETTINGS_FILE}" <<'CFG'
# NONE / ERROR / INFO / DEBUG
LOG_LEVEL="INFO"
CFG
    chmod 600 "${SETTINGS_FILE}"
  fi
}

write_groups() {
  if [[ ! -f "${GROUPS_FILE}" ]]; then
    cat > "${GROUPS_FILE}" <<'TSV'
# group_name<TAB>api_token<TAB>zone_id<TAB>target_fqdn<TAB>ttl<TAB>proxied<TAB>mode<TAB>source_domains_csv
# 示例：
# group-a	please_fill_api_token	please_fill_zone_id	tiktokeu.example.com	60	false	ALL_IPS	src1.example.com,src2.example.com
TSV
    chmod 600 "${GROUPS_FILE}"
  fi
}

write_sync_script() {
  cat > "${BIN_SYNC}" <<'SYNC'
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/etc/cf-dns-sync"
VAR_DIR="/var/lib/cf-dns-sync"
SETTINGS_FILE="${BASE_DIR}/settings.conf"
GROUPS_FILE="${BASE_DIR}/groups.tsv"
LOG_FILE="/var/log/cf-dns-sync.log"
HISTORY_FILE="/var/log/cf-dns-sync-history.tsv"
STATE_FILE="${VAR_DIR}/state.tsv"
LOCK_FILE="/run/cf-dns-sync.lock"

mkdir -p "${VAR_DIR}"
touch "${HISTORY_FILE}"
chmod 600 "${HISTORY_FILE}"

[[ -f "${SETTINGS_FILE}" ]] || { echo "配置文件不存在: ${SETTINGS_FILE}"; exit 1; }
[[ -f "${GROUPS_FILE}" ]] || { echo "组配置不存在: ${GROUPS_FILE}"; exit 1; }

# shellcheck disable=SC1090
source "${SETTINGS_FILE}"

exec 9>"${LOCK_FILE}"
flock -n 9 || exit 0

TARGET_GROUP="${1:-ALL}"

timestamp() { date '+%F %T'; }

level_num() {
  case "$1" in
    NONE)  echo -1 ;;
    ERROR) echo 0 ;;
    INFO)  echo 1 ;;
    DEBUG) echo 2 ;;
    *)     echo 1 ;;
  esac
}

log() {
  local level="$1"; shift
  local msg="$*"
  local cur want
  cur="$(level_num "${LOG_LEVEL:-INFO}")"
  want="$(level_num "${level}")"

  [[ "${cur}" -lt 0 ]] && return 0

  if [[ "${want}" -le "${cur}" ]]; then
    touch "${LOG_FILE}"
    chmod 600 "${LOG_FILE}"
    echo "[$(timestamp)] [$level] $msg" >> "${LOG_FILE}"
    echo "[$(timestamp)] [$level] $msg" | systemd-cat -t cf-dns-sync
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log ERROR "缺少依赖命令: $1"
    exit 1
  }
}

for cmd in curl jq dig awk sed grep sort comm mktemp flock paste cut tr; do
  need_cmd "$cmd"
done

cf_api() {
  local method="$1"
  local token="$2"
  local endpoint="$3"
  local data="${4:-}"

  if [[ -n "${data}" ]]; then
    curl -sS -X "${method}" "https://api.cloudflare.com/client/v4${endpoint}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      --data "${data}"
  else
    curl -sS -X "${method}" "https://api.cloudflare.com/client/v4${endpoint}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json"
  fi
}

write_history() {
  local group_name="$1"
  local action="$2"
  local ip="$3"
  local domains="$4"
  local mode="$5"
  local target_fqdn="$6"
  local note="$7"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%F %T')" \
    "${group_name}" \
    "${action}" \
    "${ip}" \
    "${domains}" \
    "${mode}" \
    "${target_fqdn}|${note}" >> "${HISTORY_FILE}"
}

state_key() {
  local group_name="$1"
  local ip="$2"
  printf '%s\t%s' "${group_name}" "${ip}"
}

domains_by_ip_from_state() {
  local state_file="$1"
  local group_name="$2"
  local ip="$3"
  awk -F '\t' -v g="${group_name}" -v ip="${ip}" '$1==g && $3==ip {print $2}' "${state_file}" | paste -sd ',' -
}

save_group_state() {
  local full_state_file="$1"
  local group_name="$2"
  local map_file="$3"
  local tmp_new
  tmp_new="$(mktemp)"
  trap 'rm -f "$tmp_new"' RETURN

  if [[ -f "${full_state_file}" ]]; then
    awk -F '\t' -v g="${group_name}" '$1!=g' "${full_state_file}" > "${tmp_new}"
  else
    : > "${tmp_new}"
  fi

  awk -F '\t' -v g="${group_name}" '{print g "\t" $1 "\t" $2}' "${map_file}" >> "${tmp_new}"
  mv "${tmp_new}" "${full_state_file}"
  chmod 600 "${full_state_file}"
}

get_group_map() {
  local mode="$1"
  shift
  local domain ip picked

  for domain in "$@"; do
    [[ -n "${domain}" ]] || continue

    if [[ "${mode}" == "SINGLE_IP" ]]; then
      picked=""
      while IFS= read -r ip; do
        if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
          picked="${ip}"
          break
        fi
      done < <(dig +short A "${domain}" | sed '/^$/d')
      [[ -n "${picked}" ]] && printf '%s\t%s\n' "${domain}" "${picked}"
    else
      while IFS= read -r ip; do
        if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
          printf '%s\t%s\n' "${domain}" "${ip}"
        fi
      done < <(dig +short A "${domain}" | sed '/^$/d')
    fi
  done
}

create_cf_record() {
  local token="$1"
  local zone_id="$2"
  local target_fqdn="$3"
  local ttl="$4"
  local proxied="$5"
  local ip="$6"
  local payload

  payload="$(jq -nc \
    --arg type "A" \
    --arg name "${target_fqdn}" \
    --arg content "${ip}" \
    --argjson ttl "${ttl}" \
    --argjson proxied "${proxied}" \
    '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')"

  cf_api POST "${token}" "/zones/${zone_id}/dns_records" "${payload}" >/dev/null
}

delete_cf_record() {
  local token="$1"
  local zone_id="$2"
  local record_id="$3"
  cf_api DELETE "${token}" "/zones/${zone_id}/dns_records/${record_id}" >/dev/null
}

sync_one_group() {
  local group_name="$1"
  local api_token="$2"
  local zone_id="$3"
  local target_fqdn="$4"
  local ttl="$5"
  local proxied="$6"
  local mode="$7"
  local sources_csv="$8"

  local IFS=','
  read -r -a source_domains <<< "${sources_csv}"

  local source_count="${#source_domains[@]}"
  if [[ "${source_count}" -lt 1 || "${source_count}" -gt 10 ]]; then
    log ERROR "组 ${group_name}: 源域名数量必须为 1~10，当前 ${source_count}"
    return
  fi

  if [[ "${proxied}" != "false" ]]; then
    log ERROR "组 ${group_name}: 仅支持 DNS only，请将 proxied 设置为 false"
    return
  fi

  if [[ "${mode}" != "ALL_IPS" && "${mode}" != "SINGLE_IP" ]]; then
    log ERROR "组 ${group_name}: mode 仅支持 ALL_IPS / SINGLE_IP"
    return
  fi

  local map_file tmp_desired tmp_current tmp_to_add tmp_to_del tmp_old_state current_json old_domains new_domains old_ip new_ip rid
  map_file="$(mktemp)"
  tmp_desired="$(mktemp)"
  tmp_current="$(mktemp)"
  tmp_to_add="$(mktemp)"
  tmp_to_del="$(mktemp)"
  tmp_old_state="$(mktemp)"

  trap 'rm -f "$map_file" "$tmp_desired" "$tmp_current" "$tmp_to_add" "$tmp_to_del" "$tmp_old_state"' RETURN

  if [[ -f "${STATE_FILE}" ]]; then
    cp -f "${STATE_FILE}" "${tmp_old_state}"
  else
    : > "${tmp_old_state}"
  fi

  log DEBUG "开始同步组: ${group_name} -> ${target_fqdn}"

  get_group_map "${mode}" "${source_domains[@]}" | sort -u > "${map_file}"

  if [[ ! -s "${map_file}" ]]; then
    log ERROR "组 ${group_name}: 未查询到任何源 IPv4，跳过同步"
    return
  fi

  awk -F '\t' '{print $2}' "${map_file}" | sed '/^$/d' | sort -u > "${tmp_desired}"

  current_json="$(cf_api GET "${api_token}" "/zones/${zone_id}/dns_records?type=A&name=${target_fqdn}&per_page=100")"
  if [[ "$(echo "${current_json}" | jq -r '.success')" != "true" ]]; then
    log ERROR "组 ${group_name}: Cloudflare API 请求失败: $(echo "${current_json}" | jq -c '.')"
    return
  fi

  echo "${current_json}" | jq -r '.result[].content' | sed '/^$/d' | sort -u > "${tmp_current}" || true

  comm -23 "${tmp_desired}" "${tmp_current}" > "${tmp_to_add}" || true
  comm -13 "${tmp_desired}" "${tmp_current}" > "${tmp_to_del}" || true

  if [[ ! -s "${tmp_to_add}" && ! -s "${tmp_to_del}" ]]; then
    save_group_state "${STATE_FILE}" "${group_name}" "${map_file}"
    log INFO "组 ${group_name}: IP 无变化"
    return
  fi

  if [[ -s "${tmp_to_del}" ]]; then
    while IFS= read -r old_ip; do
      [[ -n "${old_ip}" ]] || continue
      old_domains="$(domains_by_ip_from_state "${tmp_old_state}" "${group_name}" "${old_ip}")"
      [[ -z "${old_domains}" ]] && old_domains="unknown"
      log INFO "组 ${group_name}: 删除旧 IP ${old_ip} 来源 ${old_domains}"
      write_history "${group_name}" "DELETE" "${old_ip}" "${old_domains}" "${mode}" "${target_fqdn}" "removed_from_cloudflare"

      echo "${current_json}" | jq -r --arg ip "${old_ip}" '.result[] | select(.content==$ip) | .id' | while IFS= read -r rid; do
        [[ -n "${rid}" ]] || continue
        delete_cf_record "${api_token}" "${zone_id}" "${rid}"
      done
    done < "${tmp_to_del}"
  fi

  if [[ -s "${tmp_to_add}" ]]; then
    while IFS= read -r new_ip; do
      [[ -n "${new_ip}" ]] || continue
      new_domains="$(awk -F '\t' -v ip="${new_ip}" '$2==ip{print $1}' "${map_file}" | paste -sd ',' -)"
      [[ -z "${new_domains}" ]] && new_domains="unknown"
      log INFO "组 ${group_name}: 新增 IP ${new_ip} 来源 ${new_domains}"
      create_cf_record "${api_token}" "${zone_id}" "${target_fqdn}" "${ttl}" "${proxied}" "${new_ip}"
      write_history "${group_name}" "ADD" "${new_ip}" "${new_domains}" "${mode}" "${target_fqdn}" "added_to_cloudflare"
    done < "${tmp_to_add}"
  fi

  save_group_state "${STATE_FILE}" "${group_name}" "${map_file}"
  log INFO "组 ${group_name}: 增量同步完成"
}

main() {
  local matched=0

  while IFS=$'\t' read -r group_name api_token zone_id target_fqdn ttl proxied mode sources_csv; do
    [[ -z "${group_name}" ]] && continue
    [[ "${group_name}" =~ ^# ]] && continue

    if [[ "${TARGET_GROUP}" != "ALL" && "${TARGET_GROUP}" != "${group_name}" ]]; then
      continue
    fi

    matched=1
    sync_one_group "${group_name}" "${api_token}" "${zone_id}" "${target_fqdn}" "${ttl}" "${proxied}" "${mode}" "${sources_csv}"
  done < "${GROUPS_FILE}"

  if [[ "${matched}" -eq 0 ]]; then
    log ERROR "未找到需要同步的组: ${TARGET_GROUP}"
    exit 1
  fi
}

main
SYNC
  chmod +x "${BIN_SYNC}"
}

write_ctl_script() {
  cat > "${BIN_CTL}" <<'CTL'
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="cf-dns-sync"
BASE_DIR="/etc/${APP_NAME}"
VAR_DIR="/var/lib/${APP_NAME}"
SETTINGS_FILE="${BASE_DIR}/settings.conf"
GROUPS_FILE="${BASE_DIR}/groups.tsv"
SERVICE_NAME="${APP_NAME}.service"
TIMER_NAME="${APP_NAME}.timer"
LOGROTATE_FILE="/etc/logrotate.d/${APP_NAME}"
HISTORY_FILE="/var/log/${APP_NAME}-history.tsv"

mkdir -p "${BASE_DIR}" "${VAR_DIR}"

[[ -f "${SETTINGS_FILE}" ]] || cat > "${SETTINGS_FILE}" <<'CFG'
LOG_LEVEL="INFO"
CFG

[[ -f "${GROUPS_FILE}" ]] || cat > "${GROUPS_FILE}" <<'TSV'
# group_name<TAB>api_token<TAB>zone_id<TAB>target_fqdn<TAB>ttl<TAB>proxied<TAB>mode<TAB>source_domains_csv
TSV

# shellcheck disable=SC1090
source "${SETTINGS_FILE}"

color() {
  local code="$1"; shift
  printf "\033[%sm%s\033[0m" "${code}" "$*"
}

line() {
  printf "%s\n" "============================================================"
}

title() {
  clear
  line
  color "1;36" "                    cfdns 管理菜单 v1.5"
  echo
  color "0;37" "            多组目标域名 / 多组源域名 / 多账号支持"
  line
}

pause_wait() {
  echo
  read -n 1 -s -r -p "按任意键继续..."
}

save_settings() {
  cat > "${SETTINGS_FILE}" <<CFG
LOG_LEVEL="${LOG_LEVEL}"
CFG
  chmod 600 "${SETTINGS_FILE}"
}

list_groups_table() {
  printf '%-4s %-16s %-30s %-10s %-8s %-10s %-6s\n' "序号" "组名" "目标域名" "模式" "TTL" "Proxy" "源数"
  printf '%-4s %-16s %-30s %-10s %-8s %-10s %-6s\n' "----" "----------------" "------------------------------" "----------" "--------" "----------" "------"

  local i=0 line group_name api_token zone_id target_fqdn ttl proxied mode sources_csv count
  while IFS=$'\t' read -r group_name api_token zone_id target_fqdn ttl proxied mode sources_csv; do
    [[ -z "${group_name}" ]] && continue
    [[ "${group_name}" =~ ^# ]] && continue
    i=$((i+1))
    count="$(awk -F',' '{print NF}' <<< "${sources_csv}")"
    printf '%-4s %-16s %-30s %-10s %-8s %-10s %-6s\n' "${i}" "${group_name}" "${target_fqdn}" "${mode}" "${ttl}" "${proxied}" "${count}"
  done < "${GROUPS_FILE}"

  [[ "${i}" -eq 0 ]] && echo "当前还没有任何组。"
}

group_line_by_index() {
  local wanted="$1"
  local i=0 group_name api_token zone_id target_fqdn ttl proxied mode sources_csv
  while IFS=$'\t' read -r group_name api_token zone_id target_fqdn ttl proxied mode sources_csv; do
    [[ -z "${group_name}" ]] && continue
    [[ "${group_name}" =~ ^# ]] && continue
    i=$((i+1))
    if [[ "${i}" -eq "${wanted}" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${group_name}" "${api_token}" "${zone_id}" "${target_fqdn}" "${ttl}" "${proxied}" "${mode}" "${sources_csv}"
      return 0
    fi
  done < "${GROUPS_FILE}"
  return 1
}

choose_group_index() {
  list_groups_table
  echo
  read -rp "请输入组序号: " idx
  [[ "${idx}" =~ ^[0-9]+$ ]] || return 1
  group_line_by_index "${idx}" >/dev/null
}

rewrite_groups_excluding() {
  local exclude_group="$1"
  awk -F '\t' -v g="${exclude_group}" '
    BEGIN{OFS="\t"}
    /^#/ {print; next}
    NF==0 {next}
    $1!=g {print}
  ' "${GROUPS_FILE}"
}

write_groups_content() {
  cat > "${GROUPS_FILE}"
  chmod 600 "${GROUPS_FILE}"
}

add_group() {
  echo
  color "1;33" "新增组（公开脚本模式）"
  echo
  read -rp "请输入组名（例如 group-a）: " group_name
  [[ -n "${group_name}" ]] || { echo "组名不能为空"; return; }

  if awk -F '\t' -v g="${group_name}" '$1==g{found=1} END{exit !found}' "${GROUPS_FILE}"; then
    echo "组名已存在"
    return
  fi

  read -rp "请输入 Cloudflare API Token: " api_token
  read -rp "请输入 Zone ID: " zone_id
  read -rp "请输入目标域名（例如 tiktokeu.example.com）: " target_fqdn
  read -rp "请输入 TTL（推荐 60）: " ttl

  echo "请选择解析模式："
  echo "1. ALL_IPS（全部IP模式）"
  echo "2. SINGLE_IP（单IP模式）"
  read -rp "请输入序号 [1-2]: " mode_choice
  case "${mode_choice}" in
    1) mode="ALL_IPS" ;;
    2) mode="SINGLE_IP" ;;
    *) echo "无效选择"; return ;;
  esac

  echo "本脚本固定推荐 DNS only"
  echo "1. false（关闭代理 / 灰云）"
  read -rp "请输入序号 [1]: " proxied_choice
  case "${proxied_choice}" in
    1|"") proxied="false" ;;
    *) echo "无效选择"; return ;;
  esac

  echo
  echo "请输入 1~10 个源域名，输入完成后直接回车结束："
  local sources=() one
  while true; do
    read -rp "源域名 ${#sources[@]}+1: " one
    [[ -z "${one}" ]] && break
    sources+=("${one}")
    if [[ "${#sources[@]}" -ge 10 ]]; then
      echo "已达到 10 个上限"
      break
    fi
  done

  if [[ "${#sources[@]}" -lt 1 ]]; then
    echo "至少需要 1 个源域名"
    return
  fi

  local sources_csv
  sources_csv="$(IFS=,; echo "${sources[*]}")"

  {
    grep '^#' "${GROUPS_FILE}" 2>/dev/null || true
    awk 'BEGIN{skip=1} !/^#/{skip=0} skip==0{print}' "${GROUPS_FILE}" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${group_name}" "${api_token}" "${zone_id}" "${target_fqdn}" "${ttl}" "${proxied}" "${mode}" "${sources_csv}"
  } > "${GROUPS_FILE}.tmp"

  mv "${GROUPS_FILE}.tmp" "${GROUPS_FILE}"
  chmod 600 "${GROUPS_FILE}"
  echo "组已添加：${group_name}"
}

delete_group() {
  echo
  if ! idx="$(choose_group_index)"; then
    echo "序号无效"
    return
  fi

  local line group_name
  line="$(group_line_by_index "${idx}")"
  group_name="$(cut -f1 <<< "${line}")"

  read -rp "确认删除组 ${group_name}？输入 yes 继续: " ans
  [[ "${ans}" == "yes" ]] || { echo "已取消"; return; }

  {
    grep '^#' "${GROUPS_FILE}" 2>/dev/null || true
    awk -F '\t' -v g="${group_name}" '!/^#/ && $1!=g {print}' "${GROUPS_FILE}"
  } > "${GROUPS_FILE}.tmp"
  mv "${GROUPS_FILE}.tmp" "${GROUPS_FILE}"
  chmod 600 "${GROUPS_FILE}"

  echo "已删除组：${group_name}"
}

manage_group_sources() {
  echo
  if ! idx="$(choose_group_index)"; then
    echo "序号无效"
    return
  fi

  local line group_name api_token zone_id target_fqdn ttl proxied mode sources_csv
  line="$(group_line_by_index "${idx}")"
  IFS=$'\t' read -r group_name api_token zone_id target_fqdn ttl proxied mode sources_csv <<< "${line}"

  local sources=()
  IFS=',' read -r -a sources <<< "${sources_csv}"

  while true; do
    clear
    line
    color "1;36" "源域名管理 - ${group_name}"
    echo
    line
    local i=0
    for s in "${sources[@]}"; do
      i=$((i+1))
      printf "%2d. %s\n" "${i}" "${s}"
    done
    [[ "${#sources[@]}" -eq 0 ]] && echo "当前无源域名"
    line
    echo "1. 添加源域名"
    echo "2. 删除源域名"
    echo "0. 返回上级"
    line
    read -rp "请选择: " choice

    case "${choice}" in
      1)
        if [[ "${#sources[@]}" -ge 10 ]]; then
          echo "最多只能配置 10 个源域名"
          pause_wait
          continue
        fi
        read -rp "请输入新的源域名: " new_domain
        [[ -n "${new_domain}" ]] || { echo "不能为空"; pause_wait; continue; }
        sources+=("${new_domain}")
        ;;
      2)
        if [[ "${#sources[@]}" -le 1 ]]; then
          echo "至少保留 1 个源域名"
          pause_wait
          continue
        fi
        read -rp "请输入要删除的序号: " del_idx
        if ! [[ "${del_idx}" =~ ^[0-9]+$ ]] || [[ "${del_idx}" -lt 1 || "${del_idx}" -gt "${#sources[@]}" ]]; then
          echo "序号无效"
          pause_wait
          continue
        fi
        unset 'sources[del_idx-1]'
        sources=("${sources[@]}")
        ;;
      0)
        break
        ;;
      *)
        echo "无效选择"
        pause_wait
        continue
        ;;
    esac

    local new_sources_csv
    new_sources_csv="$(IFS=,; echo "${sources[*]}")"

    {
      grep '^#' "${GROUPS_FILE}" 2>/dev/null || true
      awk -F '\t' -v g="${group_name}" -v OFS='\t' '
        !/^#/ && $1!=g {print}
      ' "${GROUPS_FILE}"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${group_name}" "${api_token}" "${zone_id}" "${target_fqdn}" "${ttl}" "${proxied}" "${mode}" "${new_sources_csv}"
    } > "${GROUPS_FILE}.tmp"

    mv "${GROUPS_FILE}.tmp" "${GROUPS_FILE}"
    chmod 600 "${GROUPS_FILE}"
  done
}

edit_group_basic() {
  echo
  if ! idx="$(choose_group_index)"; then
    echo "序号无效"
    return
  fi

  local line group_name api_token zone_id target_fqdn ttl proxied mode sources_csv
  line="$(group_line_by_index "${idx}")"
  IFS=$'\t' read -r group_name api_token zone_id target_fqdn ttl proxied mode sources_csv <<< "${line}"

  echo "当前组名: ${group_name}"
  read -rp "新组名（直接回车保持不变）: " new_group_name
  [[ -n "${new_group_name}" ]] && group_name="${new_group_name}"

  echo "当前目标域名: ${target_fqdn}"
  read -rp "新目标域名（回车不变）: " new_target
  [[ -n "${new_target}" ]] && target_fqdn="${new_target}"

  echo "当前 TTL: ${ttl}"
  read -rp "新 TTL（回车不变）: " new_ttl
  [[ -n "${new_ttl}" ]] && ttl="${new_ttl}"

  echo "当前 Zone ID: ${zone_id}"
  read -rp "新 Zone ID（回车不变）: " new_zone
  [[ -n "${new_zone}" ]] && zone_id="${new_zone}"

  echo "当前 API Token: 已隐藏"
  read -rp "新 API Token（回车不变）: " new_token
  [[ -n "${new_token}" ]] && api_token="${new_token}"

  echo "当前解析模式: ${mode}"
  echo "1. 保持不变"
  echo "2. ALL_IPS（全部IP模式）"
  echo "3. SINGLE_IP（单IP模式）"
  read -rp "请选择 [1-3]: " mode_choice
  case "${mode_choice}" in
    1|"") ;;
    2) mode="ALL_IPS" ;;
    3) mode="SINGLE_IP" ;;
    *) echo "无效选择"; return ;;
  esac

  {
    grep '^#' "${GROUPS_FILE}" 2>/dev/null || true
    awk -F '\t' -v g_old="$(cut -f1 <<< "${line}")" '!/^#/ && $1!=g_old {print}' "${GROUPS_FILE}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${group_name}" "${api_token}" "${zone_id}" "${target_fqdn}" "${ttl}" "${proxied}" "${mode}" "${sources_csv}"
  } > "${GROUPS_FILE}.tmp"

  mv "${GROUPS_FILE}.tmp" "${GROUPS_FILE}"
  chmod 600 "${GROUPS_FILE}"
  echo "组配置已更新"
}

set_log_level() {
  echo
  echo "请选择日志等级："
  echo "1. NONE（空日志）"
  echo "2. ERROR（仅错误）"
  echo "3. INFO（普通信息）"
  echo "4. DEBUG（调试详情）"
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
  systemctl restart "${TIMER_NAME}"
  systemctl restart "${SERVICE_NAME}" || true
  echo "已重启"
}

manual_run_all() {
  /usr/local/bin/cf-dns-sync.sh ALL
  echo "已执行全部组同步"
}

manual_run_one() {
  echo
  if ! idx="$(choose_group_index)"; then
    echo "序号无效"
    return
  fi
  local line group_name
  line="$(group_line_by_index "${idx}")"
  group_name="$(cut -f1 <<< "${line}")"
  /usr/local/bin/cf-dns-sync.sh "${group_name}"
  echo "已执行组同步：${group_name}"
}

show_logs() {
  if [[ "${LOG_LEVEL}" == "NONE" ]]; then
    echo "当前日志等级为 NONE，普通运行日志不输出"
    return
  fi
  journalctl -u "${SERVICE_NAME}" -n 100 --no-pager
}

follow_logs() {
  if [[ "${LOG_LEVEL}" == "NONE" ]]; then
    echo "当前日志等级为 NONE，普通运行日志不输出"
    return
  fi
  journalctl -u "${SERVICE_NAME}" -f
}

show_status() {
  systemctl status "${SERVICE_NAME}" --no-pager -l || true
  echo
  systemctl status "${TIMER_NAME}" --no-pager -l || true
  echo
  echo "LOG_LEVEL=${LOG_LEVEL}"
  echo "GROUPS_FILE=${GROUPS_FILE}"
}

show_dep_status() {
  printf '%-18s %-10s\n' "Command" "Status"
  printf '%-18s %-10s\n' "------------------" "----------"
  for cmd in curl jq dig flock logrotate zcat awk sed grep comm mktemp paste cut tr; do
    if command -v "${cmd}" >/dev/null 2>&1; then
      printf '%-18s %-10s\n' "${cmd}" "OK"
    else
      printf '%-18s %-10s\n' "${cmd}" "MISSING"
    fi
  done
}

render_history_table() {
  local mode="$1"
  local target_group="${2:-}"
  local cutoff now files
  now="$(date +%s)"
  cutoff=$((now - 180*24*3600))
  files=(/var/log/cf-dns-sync-history.tsv /var/log/cf-dns-sync-history.tsv.*)

  if [[ "${mode}" == "all" ]]; then
    printf '%-20s %-14s %-8s %-16s %-28s %-10s %-30s\n' "Time" "Group" "Action" "IP" "SourceDomain" "Mode" "Target"
    printf '%-20s %-14s %-8s %-16s %-28s %-10s %-30s\n' "--------------------" "--------------" "--------" "----------------" "----------------------------" "----------" "------------------------------"
  else
    printf '%-20s %-14s %-16s %-28s %-10s %-30s\n' "Time" "Group" "DeletedIP" "SourceDomain" "Mode" "Target"
    printf '%-20s %-14s %-16s %-28s %-10s %-30s\n' "--------------------" "--------------" "----------------" "----------------------------" "----------" "------------------------------"
  fi

  zcat -f "${files[@]}" 2>/dev/null | awk -F '\t' -v cutoff="${cutoff}" -v mode="${mode}" -v grp="${target_group}" '
    {
      cmd="date -d \"" $1 "\" +%s"
      cmd | getline ts
      close(cmd)
      if (ts < cutoff) next
      if (grp != "" && $2 != grp) next
      split($7, arr, "|")
      target=arr[1]
      if (mode == "deleted" && $3 != "DELETE") next

      if (mode == "all") {
        printf "%-20s %-14s %-8s %-16s %-28s %-10s %-30s\n", $1, $2, $3, $4, substr($5,1,28), $6, substr(target,1,30)
      } else {
        printf "%-20s %-14s %-16s %-28s %-10s %-30s\n", $1, $2, $4, substr($5,1,28), $6, substr(target,1,30)
      }
    }' | sort
}

show_history_all() {
  render_history_table "all"
}

show_deleted_all() {
  render_history_table "deleted"
}

show_history_one_group() {
  echo
  if ! idx="$(choose_group_index)"; then
    echo "序号无效"
    return
  fi
  local line group_name
  line="$(group_line_by_index "${idx}")"
  group_name="$(cut -f1 <<< "${line}")"
  render_history_table "all" "${group_name}"
}

show_deleted_one_group() {
  echo
  if ! idx="$(choose_group_index)"; then
    echo "序号无效"
    return
  fi
  local line group_name
  line="$(group_line_by_index "${idx}")"
  group_name="$(cut -f1 <<< "${line}")"
  render_history_table "deleted" "${group_name}"
}

edit_raw_files() {
  echo
  echo "1. 编辑 settings.conf（全局日志等级）"
  echo "2. 编辑 groups.tsv（所有组配置）"
  echo "0. 返回"
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

  echo "cfdns 已彻底卸载"
  echo "说明：未卸载系统依赖，不影响其它脚本或软件。"
  exit 0
}

menu() {
  while true; do
    title
    echo "  1.  查看全部组（List Groups / 查看组）"
    echo "  2.  新增组（Add Group / 新增组）"
    echo "  3.  删除组（Delete Group / 删除组）"
    echo "  4.  编辑组基础信息（Edit Group / 编辑组）"
    echo "  5.  管理组内源域名（Manage Sources / 源域名管理）"
    echo "  6.  设置日志等级（Log Level / 日志等级）"
    echo "  7.  启动（Start / 启动）"
    echo "  8.  停止（Stop / 停止）"
    echo "  9.  重启（Restart / 重启）"
    echo " 10.  手动同步全部组（Sync All / 全部同步）"
    echo " 11.  手动同步单个组（Sync One / 单组同步）"
    echo " 12.  查看最近日志（Logs / 最近日志）"
    echo " 13.  实时查看日志（Follow Logs / 实时日志）"
    echo " 14.  查看 service/timer 状态（Status / 状态）"
    echo " 15.  查看依赖状态（Dependencies / 依赖）"
    echo " 16.  查看半年内全部历史（History All / 全部历史）"
    echo " 17.  查看半年内全部删除记录（Deleted All / 全部删除）"
    echo " 18.  查看某一组历史（History One Group / 单组历史）"
    echo " 19.  查看某一组删除记录（Deleted One Group / 单组删除）"
    echo " 20.  编辑原始配置文件（Edit Raw Files / 原始配置）"
    echo " 21.  彻底卸载（Uninstall / 卸载）"
    echo "  0.  退出（Exit / 退出）"
    line
    read -rp "请选择: " choice

    case "${choice}" in
      1) list_groups_table; pause_wait ;;
      2) add_group; pause_wait ;;
      3) delete_group; pause_wait ;;
      4) edit_group_basic; pause_wait ;;
      5) manage_group_sources ;;
      6) set_log_level; pause_wait ;;
      7) start_sync; pause_wait ;;
      8) stop_sync; pause_wait ;;
      9) restart_sync; pause_wait ;;
      10) manual_run_all; pause_wait ;;
      11) manual_run_one; pause_wait ;;
      12) show_logs; pause_wait ;;
      13) follow_logs ;;
      14) show_status; pause_wait ;;
      15) show_dep_status; pause_wait ;;
      16) show_history_all; pause_wait ;;
      17) show_deleted_all; pause_wait ;;
      18) show_history_one_group; pause_wait ;;
      19) show_deleted_one_group; pause_wait ;;
      20) edit_raw_files ;;
      21) uninstall_all ;;
      0) exit 0 ;;
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
Description=Cloudflare DNS Multi-Group Incremental Sync Service
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cf-dns-sync.sh ALL
User=root
Group=root
SERVICE
}

write_timer() {
  cat > "${TIMER_FILE}" <<'TIMER'
[Unit]
Description=Run Cloudflare DNS Multi-Group Incremental Sync every minute

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=1s
Persistent=true
Unit=cf-dns-sync.service

[Install]
WantedBy=timers.target
TIMER
}

write_logrotate() {
  cat > "${LOGROTATE_FILE}" <<'ROTATE'
/var/log/cf-dns-sync.log /var/log/cf-dns-sync-history.tsv {
    monthly
    rotate 12
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 600 root root
}
ROTATE
  chmod 644 "${LOGROTATE_FILE}"
}

main() {
  install_missing_deps
  write_settings
  write_groups
  write_sync_script
  write_ctl_script
  write_service
  write_timer
  write_logrotate

  touch "${HISTORY_FILE}"
  chmod 600 "${HISTORY_FILE}"

  systemctl daemon-reload
  systemctl enable --now "${APP_NAME}.timer"
  systemctl start "${APP_NAME}.service" || true

  echo
  echo "安装/升级完成: v1.5"
  echo "管理命令: cfdns"
  echo "组配置文件: ${GROUPS_FILE}"
  echo "全局设置文件: ${SETTINGS_FILE}"
  echo "同步脚本: ${BIN_SYNC}"
  echo "日志轮转: ${LOGROTATE_FILE}"
  echo
  systemctl status "${APP_NAME}.timer" --no-pager -l || true
}

main "$@"
EOF

chmod +x /root/install_cfdns_v1_5.sh
bash /root/install_cfdns_v1_5.sh
