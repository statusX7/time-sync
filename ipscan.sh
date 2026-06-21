#!/usr/bin/env bash
# IP 国家/地区段查询管理脚本：中文菜单 + 参数模式 + 一主二备 API
# 依赖：bash 4+、curl、jq
set -euo pipefail

VERSION="2.1.0"
A=""; B=""; C=""; D=""; COUNTRY=""
OUT_DIR="results"
PROVIDERS="ipapi,countryis,ipwhois"
BATCH_SIZE=100
BATCH_SLEEP=5
SINGLE_SLEEP="1.10"
CONNECT_TIMEOUT=15
MAX_TIME=60
RETRIES=1
VERIFY_ALL=0
DRY_RUN=0
RESUME=0
VERBOSE=0
MAX_IPS=50000
MENU=0
IPAPI_FIELDS="status,message,query,country,countryCode,regionName,city,isp,org,as,proxy,hosting"

ALL_CSV=""; MATCHED_CSV=""; FAIL_LOG=""; IPS_FILE=""
TMP_DIR=""; TMP_BATCH=""; TMP_PAYLOAD=""; TMP_RESP=""; TMP_HEAD=""; TMP_NORM=""; TMP_KNOWN=""

die(){ echo "[错误] $*" >&2; exit 1; }
log(){ echo "$*"; }
dbg(){ [ "$VERBOSE" -eq 1 ] && echo "[调试] $*" >&2 || true; }
upper(){ printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
trim(){ printf '%s' "$1" | tr -d '[:space:]'; }
is_uint(){ [[ "$1" =~ ^[0-9]+$ ]]; }
is_num(){ [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
need(){ command -v "$1" >/dev/null 2>&1 || die "缺少依赖：$1"; }
need_val(){ [ -n "${2-}" ] && [[ "${2-}" != --* ]] || die "$1 缺少参数值"; }
valid_octet(){ is_uint "$1" && [ "$1" -ge 0 ] && [ "$1" -le 255 ]; }

usage(){ cat <<'EOF'
用法：
  ./ipscan.sh                         # 进入中文管理菜单
  ./ipscan.sh --menu                  # 进入中文管理菜单
  ./ipscan.sh --a 130 --b 1-255 --c 40 --d 38 --country SG
  ./ipscan.sh --a 124 --b 1-255 --c 250 --d 188 --country HK

IP 段支持：单值 124；范围 1-255；列表 1,2,3；通配符 '*'

参数：
  --a SPEC --b SPEC --c SPEC --d SPEC --country ISO2
  --out-dir DIR            默认 results
  --providers LIST         默认 ipapi,countryis,ipwhois
  --batch-size N           默认 100，最大 100
  --batch-sleep SEC        默认 5
  --single-sleep SEC       默认 1.10，ipwhois 单 IP 间隔
  --connect-timeout SEC    默认 15
  --timeout SEC            默认 60
  --retries N              默认 1
  --verify-all             三个 API 都查，用于交叉验证
  --resume                 跳过 all.csv 中已有 IP
  --dry-run                只生成 IP 列表，不联网查询
  --max-ips N              默认 50000，0 表示不限制
  -v, --verbose            调试输出
  -h, --help               帮助
EOF
}

parse_args(){
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --menu) MENU=1; shift ;;
      --a) need_val "$1" "${2-}"; A="$2"; shift 2 ;;
      --b) need_val "$1" "${2-}"; B="$2"; shift 2 ;;
      --c) need_val "$1" "${2-}"; C="$2"; shift 2 ;;
      --d) need_val "$1" "${2-}"; D="$2"; shift 2 ;;
      --country) need_val "$1" "${2-}"; COUNTRY="$(upper "$2")"; shift 2 ;;
      --out-dir) need_val "$1" "${2-}"; OUT_DIR="$2"; shift 2 ;;
      --providers) need_val "$1" "${2-}"; PROVIDERS="$(trim "$2")"; shift 2 ;;
      --batch-size) need_val "$1" "${2-}"; BATCH_SIZE="$2"; shift 2 ;;
      --batch-sleep) need_val "$1" "${2-}"; BATCH_SLEEP="$2"; shift 2 ;;
      --single-sleep) need_val "$1" "${2-}"; SINGLE_SLEEP="$2"; shift 2 ;;
      --connect-timeout) need_val "$1" "${2-}"; CONNECT_TIMEOUT="$2"; shift 2 ;;
      --timeout) need_val "$1" "${2-}"; MAX_TIME="$2"; shift 2 ;;
      --retries) need_val "$1" "${2-}"; RETRIES="$2"; shift 2 ;;
      --max-ips) need_val "$1" "${2-}"; MAX_IPS="$2"; shift 2 ;;
      --verify-all) VERIFY_ALL=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --resume) RESUME=1; shift ;;
      -v|--verbose) VERBOSE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --version) echo "$VERSION"; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
}

check_args(){
  [ -n "$A" ] || die "缺少 --a"
  [ -n "$B" ] || die "缺少 --b"
  [ -n "$C" ] || die "缺少 --c"
  [ -n "$D" ] || die "缺少 --d"
  [[ "$COUNTRY" =~ ^[A-Z]{2}$ ]] || die "--country 必须是两个字母，例如 SG、HK、US、JP"
  is_uint "$BATCH_SIZE" && [ "$BATCH_SIZE" -ge 1 ] && [ "$BATCH_SIZE" -le 100 ] || die "--batch-size 必须是 1-100"
  is_num "$BATCH_SLEEP" || die "--batch-sleep 必须是数字"
  is_num "$SINGLE_SLEEP" || die "--single-sleep 必须是数字"
  is_uint "$CONNECT_TIMEOUT" && [ "$CONNECT_TIMEOUT" -ge 1 ] || die "--connect-timeout 必须是正整数"
  is_uint "$MAX_TIME" && [ "$MAX_TIME" -ge 1 ] || die "--timeout 必须是正整数"
  is_uint "$RETRIES" || die "--retries 必须是非负整数"
  is_uint "$MAX_IPS" || die "--max-ips 必须是非负整数"
  local p
  IFS=',' read -r -a _ps <<< "$PROVIDERS"
  [ "${#_ps[@]}" -gt 0 ] || die "API 顺序不能为空"
  for p in "${_ps[@]}"; do
    p="$(trim "$p")"
    case "$p" in ipapi|countryis|ipwhois) ;; *) die "未知 API：$p" ;; esac
  done
}

expand_octet(){
  local spec part start end
  spec="$(trim "$1")"
  [ -n "$spec" ] || die "IP 段为空"
  if [ "$spec" = "*" ]; then seq 0 255; return; fi
  IFS=',' read -r -a parts <<< "$spec"
  for part in "${parts[@]}"; do
    part="$(trim "$part")"
    if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
      start="${part%-*}"; end="${part#*-}"
      valid_octet "$start" || die "非法 IP 段：$start"
      valid_octet "$end" || die "非法 IP 段：$end"
      [ "$start" -le "$end" ] || die "范围起点大于终点：$part"
      seq "$start" "$end"
    elif valid_octet "$part"; then
      echo "$part"
    else
      die "错误的 IP 段写法：$part"
    fi
  done
}

init_paths(){
  mkdir -p "$OUT_DIR"
  ALL_CSV="$OUT_DIR/all.csv"; MATCHED_CSV="$OUT_DIR/matched.csv"; FAIL_LOG="$OUT_DIR/failed.log"; IPS_FILE="$OUT_DIR/ips.txt"
  TMP_DIR="$(mktemp -d)"; TMP_BATCH="$TMP_DIR/batch.txt"; TMP_PAYLOAD="$TMP_DIR/payload.json"; TMP_RESP="$TMP_DIR/resp.json"; TMP_HEAD="$TMP_DIR/head.txt"; TMP_NORM="$TMP_DIR/norm.jsonl"; TMP_KNOWN="$TMP_DIR/known.txt"
  trap 'rm -rf "$TMP_DIR"' EXIT
  local header='ip,a,b,c,d,provider,status,country_code,country,region,city,isp,org,asn,proxy,hosting,message'
  if [ "$RESUME" -eq 0 ] || [ ! -f "$ALL_CSV" ]; then echo "$header" > "$ALL_CSV"; fi
  if [ "$RESUME" -eq 0 ] || [ ! -f "$MATCHED_CSV" ]; then echo "$header" > "$MATCHED_CSV"; fi
  [ "$RESUME" -eq 0 ] && : > "$FAIL_LOG" || touch "$FAIL_LOG"
}

gen_ips(){
  local a b c d total
  expand_octet "$A" > "$TMP_DIR/a.raw"; awk '!x[$0]++' "$TMP_DIR/a.raw" > "$TMP_DIR/a.txt"
  expand_octet "$B" > "$TMP_DIR/b.raw"; awk '!x[$0]++' "$TMP_DIR/b.raw" > "$TMP_DIR/b.txt"
  expand_octet "$C" > "$TMP_DIR/c.raw"; awk '!x[$0]++' "$TMP_DIR/c.raw" > "$TMP_DIR/c.txt"
  expand_octet "$D" > "$TMP_DIR/d.raw"; awk '!x[$0]++' "$TMP_DIR/d.raw" > "$TMP_DIR/d.txt"
  mapfile -t aa < "$TMP_DIR/a.txt"; mapfile -t bb < "$TMP_DIR/b.txt"; mapfile -t cc < "$TMP_DIR/c.txt"; mapfile -t dd < "$TMP_DIR/d.txt"
  total=$(( ${#aa[@]} * ${#bb[@]} * ${#cc[@]} * ${#dd[@]} ))
  if [ "$MAX_IPS" -ne 0 ] && [ "$total" -gt "$MAX_IPS" ]; then die "将生成 $total 个 IP，超过 --max-ips $MAX_IPS"; fi
  : > "$IPS_FILE"
  for a in "${aa[@]}"; do for b in "${bb[@]}"; do for c in "${cc[@]}"; do for d in "${dd[@]}"; do echo "$a.$b.$c.$d" >> "$IPS_FILE"; done; done; done; done
  if [ "$RESUME" -eq 1 ] && [ -f "$ALL_CSV" ]; then
    awk -F',' 'NR>1{gsub(/^"|"$/, "", $1); if($1!="") print $1}' "$ALL_CSV" > "$TMP_DIR/done.txt" || true
    if [ -s "$TMP_DIR/done.txt" ]; then grep -vxFf "$TMP_DIR/done.txt" "$IPS_FILE" > "$TMP_DIR/new.txt" || true; mv "$TMP_DIR/new.txt" "$IPS_FILE"; fi
  fi
}

append_csv(){
  local f="$1"
  local jqcsv='[(.ip//""),((.ip//"")|split(".")[0]//""),((.ip//"")|split(".")[1]//""),((.ip//"")|split(".")[2]//""),((.ip//"")|split(".")[3]//""),(.provider//""),(.status//""),(.country_code//""),(.country//""),(.region//""),(.city//""),(.isp//""),(.org//""),(.asn//""),((.proxy//"")|tostring),((.hosting//"")|tostring),(.message//"")]|@csv'
  jq -r "$jqcsv" "$f" >> "$ALL_CSV"
  jq -r --arg cc "$COUNTRY" "select((.country_code//\"\"|ascii_upcase)==\$cc)|$jqcsv" "$f" >> "$MATCHED_CSV"
}

make_payload(){ jq -R . "$TMP_BATCH" | jq -s . > "$TMP_PAYLOAD"; }

query_ipapi(){
  make_payload
  curl -sS -X POST -H 'Content-Type: application/json' --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" --data @"$TMP_PAYLOAD" -D "$TMP_HEAD" -o "$TMP_RESP" -w '%{http_code}' "http://ip-api.com/batch?fields=${IPAPI_FIELDS}"
}
norm_ipapi(){
  jq -c '.[]|{ip:(.query//""),provider:"ipapi",status:(.status//"fail"),country_code:((.countryCode//"")|ascii_upcase),country:(.country//""),region:(.regionName//""),city:(.city//""),isp:(.isp//""),org:(.org//""),asn:(.as//""),proxy:(.proxy//""),hosting:(.hosting//""),message:(.message//"")}' "$TMP_RESP" > "$TMP_NORM"
}
sleep_ipapi_if_needed(){
  local rl ttl
  rl="$(awk 'BEGIN{IGNORECASE=1}/^X-Rl:/{gsub("\r","",$2);print $2}' "$TMP_HEAD" | tail -n1 || true)"
  ttl="$(awk 'BEGIN{IGNORECASE=1}/^X-Ttl:/{gsub("\r","",$2);print $2}' "$TMP_HEAD" | tail -n1 || true)"
  if [ "${rl:-}" = "0" ] && is_uint "${ttl:-}" && [ "$ttl" -gt 0 ]; then log "  -> ip-api 限速等待 ${ttl}s"; sleep "$ttl"; fi
}

query_countryis(){
  make_payload
  curl -sS -X POST -H 'Content-Type: application/json' --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" --data @"$TMP_PAYLOAD" -D "$TMP_HEAD" -o "$TMP_RESP" -w '%{http_code}' 'https://api.country.is/?fields=city,subdivision,asn'
}
norm_countryis(){
  jq -c '
    def nasn: if (.asn|type)=="object" then (.asn.asn//.asn.number//.asn.id//"") else (.asn//"") end;
    def norg: if (.asn|type)=="object" then (.asn.name//.asn.org//.asn.organization//.asn.domain//"") else "" end;
    def nregion: if (.subdivision|type)=="object" then (.subdivision.name//.subdivision.code//"") else (.subdivision//"") end;
    def ncity: if (.city|type)=="object" then (.city.name//"") else (.city//"") end;
    def emit:{ip:(.ip//.query//.__ip_key//""),provider:"countryis",status:(if ((.country//.country_code//"")!="") then "success" else "fail" end),country_code:((.country_code//.country//"")|tostring|ascii_upcase),country:((.country_name//.country//"")|tostring),region:(nregion|tostring),city:(ncity|tostring),isp:"",org:(norg|tostring),asn:(nasn|tostring),proxy:"",hosting:"",message:(.error//.message//"")};
    if type=="array" then .[]|emit
    elif type=="object" and (has("ip") or has("country") or has("country_code")) then .|emit
    elif type=="object" and (has("error") or has("message")) then empty
    elif type=="object" then to_entries[]|(.key as $k|.value as $v|if ($v|type)=="object" then $v+{__ip_key:$k} else {ip:$k,country:$v,__ip_key:$k} end)|emit
    else empty end' "$TMP_RESP" > "$TMP_NORM"
}

query_ipwhois(){
  : > "$TMP_RESP"; : > "$TMP_HEAD"
  local ip code body head n=0 ok=0 retry total
  total="$(wc -l < "$TMP_BATCH" | tr -d ' ')"
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    n=$((n+1)); body="$TMP_DIR/ipwhois_$n.json"; head="$TMP_DIR/ipwhois_$n.head"
    dbg "ipwhois $n/$total $ip"
    code="$(curl -sS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" -D "$head" -o "$body" -w '%{http_code}' "https://ipwho.is/${ip}?fields=success,message,ip,country,country_code,region,city,connection,security" 2>>"$FAIL_LOG" || true)"
    if [ "$code" = "429" ]; then
      retry="$(awk 'BEGIN{IGNORECASE=1}/^Retry-After:/{gsub("\r","",$2);print $2}' "$head" | tail -n1 || true)"
      if is_uint "${retry:-}" && [ "$retry" -gt 0 ]; then echo "$(date '+%F %T') ipwhois 429，等待 ${retry}s" >> "$FAIL_LOG"; sleep "$retry"; fi
    fi
    if jq empty "$body" >/dev/null 2>&1; then cat "$body" >> "$TMP_RESP"; echo >> "$TMP_RESP"; [ "$code" = "200" ] && ok=$((ok+1)); else jq -cn --arg ip "$ip" --arg msg "ipwhois HTTP $code 或非 JSON" '{success:false,ip:$ip,message:$msg}' >> "$TMP_RESP"; fi
    sleep "$SINGLE_SLEEP"
  done < "$TMP_BATCH"
  [ "$ok" -gt 0 ] && echo 200 || echo 000
}
norm_ipwhois(){
  jq -c '{ip:(.ip//""),provider:"ipwhois",status:(if .success==true then "success" else "fail" end),country_code:((.country_code//"")|ascii_upcase),country:(.country//""),region:(.region//""),city:(.city//""),isp:(.connection.isp//""),org:(.connection.org//""),asn:((.connection.asn//"")|tostring),proxy:(.security.proxy//""),hosting:(.security.hosting//""),message:(.message//"")}' "$TMP_RESP" > "$TMP_NORM"
}

add_missing_rows(){
  local p="$1" ip
  jq -r 'select((.ip//"")!="")|.ip' "$TMP_NORM" | awk '!x[$0]++' > "$TMP_KNOWN"
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    grep -qxF "$ip" "$TMP_KNOWN" 2>/dev/null || jq -cn --arg ip "$ip" --arg p "$p" '{ip:$ip,provider:$p,status:"fail",country_code:"",country:"",region:"",city:"",isp:"",org:"",asn:"",proxy:"",hosting:"",message:"API 返回中缺少此 IP"}' >> "$TMP_NORM"
  done < "$TMP_BATCH"
}

run_provider_once(){
  local p="$1" code rows
  : > "$TMP_RESP"; : > "$TMP_HEAD"; : > "$TMP_NORM"
  case "$p" in
    ipapi) code="$(query_ipapi 2>>"$FAIL_LOG" || true)" ;;
    countryis) code="$(query_countryis 2>>"$FAIL_LOG" || true)" ;;
    ipwhois) code="$(query_ipwhois 2>>"$FAIL_LOG" || true)" ;;
    *) return 1 ;;
  esac
  [ "$p" = ipapi ] && sleep_ipapi_if_needed
  if [ "$code" != 200 ]; then echo "$(date '+%F %T') provider=$p HTTP=$code" >> "$FAIL_LOG"; [ -s "$TMP_RESP" ] && cat "$TMP_RESP" >> "$FAIL_LOG"; return 1; fi
  [ -s "$TMP_RESP" ] || { echo "$(date '+%F %T') provider=$p 返回空内容" >> "$FAIL_LOG"; return 1; }
  jq empty "$TMP_RESP" >/dev/null 2>&1 || { echo "$(date '+%F %T') provider=$p 返回非 JSON" >> "$FAIL_LOG"; cat "$TMP_RESP" >> "$FAIL_LOG" || true; return 1; }
  case "$p" in ipapi) norm_ipapi ;; countryis) norm_countryis ;; ipwhois) norm_ipwhois ;; esac
  [ -s "$TMP_NORM" ] || { echo "$(date '+%F %T') provider=$p 标准化为空" >> "$FAIL_LOG"; return 1; }
  add_missing_rows "$p"
  rows="$(jq -r 'select((.ip//"")!="")|.ip' "$TMP_NORM" | wc -l | tr -d ' ')"
  [ "$rows" != 0 ] || return 1
}

run_provider(){
  local p="$1" i=0 max=$((RETRIES+1))
  while [ "$i" -lt "$max" ]; do
    i=$((i+1))
    run_provider_once "$p" && return 0
    echo "$(date '+%F %T') provider=$p 第 $i 次失败" >> "$FAIL_LOG"
    [ "$i" -lt "$max" ] && sleep 2
  done
  return 1
}

append_failed_batch(){
  local ip msg="$1"
  : > "$TMP_NORM"
  while IFS= read -r ip; do [ -n "$ip" ] && jq -cn --arg ip "$ip" --arg msg "$msg" '{ip:$ip,provider:"none",status:"fail",country_code:"",country:"",region:"",city:"",isp:"",org:"",asn:"",proxy:"",hosting:"",message:$msg}' >> "$TMP_NORM"; done < "$TMP_BATCH"
  append_csv "$TMP_NORM"
}

process_one_batch(){
  local p hits ok=0
  IFS=',' read -r -a ps <<< "$PROVIDERS"
  if [ "$VERIFY_ALL" -eq 1 ]; then
    for p in "${ps[@]}"; do
      p="$(trim "$p")"; log "  -> 交叉验证 API：$p"
      if run_provider "$p"; then append_csv "$TMP_NORM"; ok=1; hits="$(jq -r --arg cc "$COUNTRY" 'select((.country_code//""|ascii_upcase)==$cc)|.ip' "$TMP_NORM" | wc -l | tr -d ' ')"; log "     成功：$p，命中 $COUNTRY：$hits"; else log "     失败：$p"; fi
    done
    [ "$ok" -eq 1 ] || append_failed_batch "全部 API 都失败"
  else
    for p in "${ps[@]}"; do
      p="$(trim "$p")"; log "  -> 尝试 API：$p"
      if run_provider "$p"; then append_csv "$TMP_NORM"; hits="$(jq -r --arg cc "$COUNTRY" 'select((.country_code//""|ascii_upcase)==$cc)|.ip' "$TMP_NORM" | wc -l | tr -d ' ')"; log "     成功：$p，命中 $COUNTRY：$hits"; return 0; fi
      log "     失败：$p，切换备用"
    done
    append_failed_batch "全部 API 都失败"
  fi
}

scan_batches(){
  local total cur=1 end batch=0 matched unique
  total="$(wc -l < "$IPS_FILE" | tr -d ' ')"
  log "目标国家/地区：$COUNTRY"
  log "IP 数量：$total"
  log "API 顺序：$PROVIDERS"
  log "输出目录：$OUT_DIR"
  [ "$DRY_RUN" -eq 1 ] && { log "dry-run：只生成 IP 列表：$IPS_FILE"; return 0; }
  [ "$total" -eq 0 ] && { log "没有需要查询的 IP"; return 0; }
  while [ "$cur" -le "$total" ]; do
    batch=$((batch+1)); end=$((cur+BATCH_SIZE-1)); [ "$end" -gt "$total" ] && end="$total"
    sed -n "${cur},${end}p" "$IPS_FILE" > "$TMP_BATCH"
    log "批次 #$batch：第 $cur 到 $end 个 IP"
    process_one_batch || true
    cur=$((end+1)); [ "$cur" -le "$total" ] && sleep "$BATCH_SLEEP"
  done
  matched="$(tail -n +2 "$MATCHED_CSV" | wc -l | tr -d ' ')"
  unique="$(tail -n +2 "$MATCHED_CSV" | cut -d',' -f1 | tr -d '"' | awk 'NF&&!x[$0]++' | wc -l | tr -d ' ')"
  log ""
  log "查询完成。全部结果：$ALL_CSV"
  log "命中结果：$MATCHED_CSV"
  log "失败日志：$FAIL_LOG"
  log "命中记录数：$matched；去重 IP 数：$unique"
  if [ "$unique" != 0 ]; then log "命中 IP："; tail -n +2 "$MATCHED_CSV" | cut -d',' -f1 | tr -d '"' | awk 'NF&&!x[$0]++'; fi
}

run_scan(){ check_args; need curl; need jq; init_paths; gen_ips; scan_batches; }

show_cfg(){ cat <<EOF

当前配置：
  输出目录：$OUT_DIR
  API 顺序：$PROVIDERS
  查询模式：$([ "$VERIFY_ALL" -eq 1 ] && echo "三 API 交叉验证" || echo "主 API 故障后切换备用")
  批量大小：$BATCH_SIZE
  批次间隔：$BATCH_SLEEP 秒
  ipwhois 单 IP 间隔：$SINGLE_SLEEP 秒
  最大 IP 数保护：$MAX_IPS
EOF
}
pause(){ printf '\n按回车继续...'; read -r _ || true; }
ask(){ local tip="$1" def="$2" v; printf '%s [%s]: ' "$tip" "$def" >&2; read -r v || true; [ -z "$(trim "${v:-}")" ] && echo "$def" || echo "$v"; }
menu_run(){ if ( run_scan ); then :; else echo "[错误] 本次查询失败，请检查输入或 failed.log" >&2; fi; }
custom_scan(){
  echo; echo "请输入 IP 四段：支持单值、范围、列表、*。"
  A="$(ask 'A 段' '124')"; B="$(ask 'B 段' '1-255')"; C="$(ask 'C 段' '250')"; D="$(ask 'D 段' '188')"; COUNTRY="$(upper "$(ask '目标国家/地区代码，例如 SG/HK/US/JP/TW' 'HK')")"
  echo "即将查询：${A}.${B}.${C}.${D}，目标：$COUNTRY"
  read -r -p '是否开始？[Y/n]: ' yn || true; yn="$(upper "${yn:-Y}")"
  [[ "$yn" == Y || "$yn" == YES ]] && menu_run || echo "已取消。"
  pause
}
quick_scan(){
  local cc="$1" da="$2" db="$3" dc="$4" dd="$5"
  A="$(ask 'A 段' "$da")"; B="$(ask 'B 段' "$db")"; C="$(ask 'C 段' "$dc")"; D="$(ask 'D 段' "$dd")"; COUNTRY="$cc"
  echo "即将查询：${A}.${B}.${C}.${D}，目标：$COUNTRY"
  read -r -p '是否开始？[Y/n]: ' yn || true; yn="$(upper "${yn:-Y}")"
  [[ "$yn" == Y || "$yn" == YES ]] && menu_run || echo "已取消。"
  pause
}
view_file(){ local f="$1" title="$2"; echo; echo "========== $title =========="; if [ -f "$f" ]; then sed -n '1,80p' "$f"; echo; echo "文件：$f（最多显示前 80 行）"; else echo "文件不存在：$f"; fi; pause; }
view_ips(){ local f="$OUT_DIR/matched.csv"; echo; echo "========== 命中 IP =========="; if [ -f "$f" ] && [ "$(wc -l < "$f" | tr -d ' ')" -gt 1 ]; then tail -n +2 "$f" | cut -d',' -f1 | tr -d '"' | awk 'NF&&!x[$0]++'; else echo "暂无命中结果"; fi; pause; }
clear_results(){ echo "当前输出目录：$OUT_DIR"; read -r -p '确认清空结果文件？[y/N]: ' yn || true; yn="$(upper "${yn:-N}")"; if [[ "$yn" == Y || "$yn" == YES ]]; then mkdir -p "$OUT_DIR"; rm -f "$OUT_DIR"/*.csv "$OUT_DIR"/*.txt "$OUT_DIR"/*.log 2>/dev/null || true; echo "已清空"; else echo "已取消"; fi; pause; }
set_providers(){ echo "可用：ipapi,countryis,ipwhois"; echo "当前：$PROVIDERS"; PROVIDERS="$(ask '新的 API 顺序' "$PROVIDERS")"; echo "已设置：$PROVIDERS"; pause; }
set_opts(){ OUT_DIR="$(ask '输出目录' "$OUT_DIR")"; BATCH_SIZE="$(ask '批量大小，最大 100' "$BATCH_SIZE")"; BATCH_SLEEP="$(ask '批次间隔秒数' "$BATCH_SLEEP")"; SINGLE_SLEEP="$(ask 'ipwhois 单 IP 间隔秒数' "$SINGLE_SLEEP")"; MAX_IPS="$(ask '最大 IP 数保护，0 表示不限制' "$MAX_IPS")"; RETRIES="$(ask 'API 失败重试次数' "$RETRIES")"; echo "已更新"; pause; }
toggle_verify(){ if [ "$VERIFY_ALL" -eq 1 ]; then VERIFY_ALL=0; echo "已切换：故障切换模式"; else VERIFY_ALL=1; echo "已切换：三 API 交叉验证模式"; fi; pause; }

menu_loop(){
  while true; do
    clear 2>/dev/null || true
    cat <<EOF
============================================================
              IP 国家/地区段查询管理脚本 v$VERSION
============================================================
  1. 自定义查询 IP 段
  2. 快速查询新加坡 SG，默认 130.1-255.40.38
  3. 快速查询香港 HK，默认 124.1-255.250.188
  4. 查看命中结果 matched.csv
  5. 只显示命中的 IP
  6. 查看全部结果 all.csv
  7. 查看失败日志 failed.log
  8. 设置 API 顺序（一主二备）
  9. 设置运行参数
 10. 开启/关闭三 API 交叉验证
 11. 查看当前配置
 12. 清空结果文件
  0. 退出
============================================================
EOF
    show_cfg
    read -r -p '请选择操作：' ch || true
    case "${ch:-}" in
      1) custom_scan ;;
      2) quick_scan SG 130 1-255 40 38 ;;
      3) quick_scan HK 124 1-255 250 188 ;;
      4) view_file "$OUT_DIR/matched.csv" '命中结果 matched.csv' ;;
      5) view_ips ;;
      6) view_file "$OUT_DIR/all.csv" '全部结果 all.csv' ;;
      7) view_file "$OUT_DIR/failed.log" '失败日志 failed.log' ;;
      8) set_providers ;;
      9) set_opts ;;
      10) toggle_verify ;;
      11) show_cfg; pause ;;
      12) clear_results ;;
      0) echo "已退出"; exit 0 ;;
      *) echo "无效选择"; pause ;;
    esac
  done
}

main(){
  [ "$#" -eq 0 ] && MENU=1
  parse_args "$@"
  if [ "$MENU" -eq 1 ]; then need curl; need jq; menu_loop; else run_scan; fi
}
main "$@"
