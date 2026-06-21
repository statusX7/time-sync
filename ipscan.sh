#!/usr/bin/env bash
# ipscan.sh - IPv4 country/region scanner with 1 primary API + 2 fallbacks.
# Requires: bash 4+, curl, jq
set -euo pipefail

VERSION="1.1.0"
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
KEEP_TMP=0
VERBOSE=0
MAX_IPS=50000
IPAPI_FIELDS="status,message,query,country,countryCode,regionName,city,isp,org,as,proxy,hosting"

usage() {
  cat <<'EOF'
Usage:
  ./ipscan.sh --a 130 --b 1-255 --c 40 --d 38 --country SG
  ./ipscan.sh --a 124 --b 1-255 --c 250 --d 188 --country HK

Octet spec supports: single value, range, comma list, wildcard
  --a 124
  --b 1-255
  --c 136,137,250
  --d '*'

Required:
  --a SPEC --b SPEC --c SPEC --d SPEC --country ISO2

Options:
  --out-dir DIR          Default: results
  --providers LIST       Default: ipapi,countryis,ipwhois
  --batch-size N         Default: 100, max: 100
  --batch-sleep SEC      Default: 5
  --single-sleep SEC     Default: 1.10, for ipwhois fallback
  --connect-timeout SEC  Default: 15
  --timeout SEC          Default: 60
  --retries N            Default: 1
  --verify-all           Query all providers for cross-checking
  --resume               Skip IPs already present in all.csv
  --max-ips N            Default: 50000, 0 means unlimited
  --dry-run              Generate ips.txt only
  --keep-tmp             Keep temp files for debugging
  -v, --verbose          Debug output
  -h, --help             Show help

Output:
  results/ips.txt
  results/all.csv
  results/matched.csv
  results/failed.log
EOF
}

log(){ printf '%s\n' "$*"; }
err(){ printf '[error] %s\n' "$*" >&2; }
vlog(){ [ "$VERBOSE" -eq 1 ] && printf '[debug] %s\n' "$*" >&2 || true; }
upper(){ printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
trim(){ printf '%s' "$1" | tr -d '[:space:]'; }
is_uint(){ [[ "$1" =~ ^[0-9]+$ ]]; }

need_cmd(){
  command -v "$1" >/dev/null 2>&1 || { err "missing dependency: $1"; exit 1; }
}
need_val(){
  local opt="$1" val="${2-}"
  [ -n "$val" ] && [[ "$val" != --* ]] || { err "$opt missing value"; exit 1; }
}
valid_octet(){ is_uint "$1" && [ "$1" -ge 0 ] && [ "$1" -le 255 ]; }
positive_int(){ is_uint "$2" && [ "$2" -ge 1 ] || { err "$1 must be positive integer, got: $2"; exit 1; }; }

expand_octet(){
  local spec part start end
  local -a parts
  spec="$(trim "$1")"
  [ -n "$spec" ] || { err "empty octet spec"; return 1; }
  if [ "$spec" = "*" ]; then seq 0 255; return 0; fi
  IFS=',' read -r -a parts <<< "$spec"
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
      start="${part%-*}"; end="${part#*-}"
      valid_octet "$start" || { err "invalid octet: $start"; return 1; }
      valid_octet "$end" || { err "invalid octet: $end"; return 1; }
      [ "$start" -le "$end" ] || { err "range start > end: $part"; return 1; }
      seq "$start" "$end"
    elif is_uint "$part"; then
      valid_octet "$part" || { err "invalid octet: $part"; return 1; }
      printf '%s\n' "$part"
    else
      err "bad octet spec: $part"
      return 1
    fi
  done
}

parse_args(){
  while [ "$#" -gt 0 ]; do
    case "$1" in
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
      --keep-tmp) KEEP_TMP=1; shift ;;
      -v|--verbose) VERBOSE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --version) echo "$VERSION"; exit 0 ;;
      *) err "unknown arg: $1"; usage; exit 1 ;;
    esac
  done
}

validate_args(){
  [ -n "$A" ] || { err "missing --a"; exit 1; }
  [ -n "$B" ] || { err "missing --b"; exit 1; }
  [ -n "$C" ] || { err "missing --c"; exit 1; }
  [ -n "$D" ] || { err "missing --d"; exit 1; }
  [[ "$COUNTRY" =~ ^[A-Z]{2}$ ]] || { err "--country must be ISO2, e.g. SG/HK/US"; exit 1; }
  positive_int --batch-size "$BATCH_SIZE"
  [ "$BATCH_SIZE" -le 100 ] || { err "--batch-size max is 100"; exit 1; }
  positive_int --connect-timeout "$CONNECT_TIMEOUT"
  positive_int --timeout "$MAX_TIME"
  is_uint "$RETRIES" || { err "--retries must be non-negative integer"; exit 1; }
  is_uint "$MAX_IPS" || { err "--max-ips must be non-negative integer"; exit 1; }
  local p; IFS=',' read -r -a PROVIDER_ARR <<< "$PROVIDERS"
  [ "${#PROVIDER_ARR[@]}" -gt 0 ] || { err "empty --providers"; exit 1; }
  for p in "${PROVIDER_ARR[@]}"; do
    case "$p" in ipapi|countryis|ipwhois) ;; *) err "bad provider: $p"; exit 1 ;; esac
  done
}

init_paths(){
  mkdir -p "$OUT_DIR"
  ALL_CSV="$OUT_DIR/all.csv"
  MATCHED_CSV="$OUT_DIR/matched.csv"
  FAIL_LOG="$OUT_DIR/failed.log"
  IPS_FILE="$OUT_DIR/ips.txt"
  TMP_DIR="$(mktemp -d)"
  TMP_PAYLOAD="$TMP_DIR/payload.json"
  TMP_RESP="$TMP_DIR/response.json"
  TMP_HEADERS="$TMP_DIR/headers.txt"
  TMP_NORM="$TMP_DIR/normalized.jsonl"
  TMP_BATCH="$TMP_DIR/batch.txt"
  TMP_KNOWN="$TMP_DIR/known.txt"
  TMP_SKIP="$TMP_DIR/skip.txt"
  [ "$KEEP_TMP" -eq 1 ] && log "tmp: $TMP_DIR" || trap 'rm -rf "$TMP_DIR"' EXIT
  if [ ! -f "$ALL_CSV" ] || [ "$RESUME" -eq 0 ]; then
    echo 'ip,a,b,c,d,provider,status,country_code,country,region,city,isp,org,asn,proxy,hosting,message' > "$ALL_CSV"
  fi
  if [ ! -f "$MATCHED_CSV" ] || [ "$RESUME" -eq 0 ]; then
    echo 'ip,a,b,c,d,provider,status,country_code,country,region,city,isp,org,asn,proxy,hosting,message' > "$MATCHED_CSV"
  fi
  [ "$RESUME" -eq 0 ] && : > "$FAIL_LOG" || touch "$FAIL_LOG"
}

make_octet_file(){
  local spec="$1" name="$2" raw out
  raw="$TMP_DIR/$name.raw"
  out="$TMP_DIR/$name.list"
  expand_octet "$spec" > "$raw" || exit 1
  awk '!seen[$0]++' "$raw" > "$out"
  [ -s "$out" ] || { err "$name generated empty list"; exit 1; }
}

generate_ips(){
  local a b c d total
  local -a AL BL CL DL
  make_octet_file "$A" a; make_octet_file "$B" b; make_octet_file "$C" c; make_octet_file "$D" d
  mapfile -t AL < "$TMP_DIR/a.list"; mapfile -t BL < "$TMP_DIR/b.list"; mapfile -t CL < "$TMP_DIR/c.list"; mapfile -t DL < "$TMP_DIR/d.list"
  total=$((${#AL[@]} * ${#BL[@]} * ${#CL[@]} * ${#DL[@]}))
  if [ "$MAX_IPS" -ne 0 ] && [ "$total" -gt "$MAX_IPS" ]; then
    err "will generate $total IPs, exceeds --max-ips $MAX_IPS; narrow range or use --max-ips 0"
    exit 1
  fi
  : > "$IPS_FILE"
  for a in "${AL[@]}"; do for b in "${BL[@]}"; do for c in "${CL[@]}"; do for d in "${DL[@]}"; do
    printf '%s.%s.%s.%s\n' "$a" "$b" "$c" "$d" >> "$IPS_FILE"
  done; done; done; done
  if [ "$RESUME" -eq 1 ] && [ -f "$ALL_CSV" ]; then
    awk -F',' 'NR>1 {gsub(/^"|"$/, "", $1); if ($1 != "") print $1}' "$ALL_CSV" > "$TMP_SKIP" || true
    if [ -s "$TMP_SKIP" ]; then
      grep -vxFf "$TMP_SKIP" "$IPS_FILE" > "$TMP_DIR/ips_resume.txt" || true
      mv "$TMP_DIR/ips_resume.txt" "$IPS_FILE"
    fi
  fi
}

append_csv(){
  local f="$1"
  jq -r '
    [(.ip//""),((.ip//"")|split(".")[0]//""),((.ip//"")|split(".")[1]//""),((.ip//"")|split(".")[2]//""),((.ip//"")|split(".")[3]//""),(.provider//""),(.status//""),(.country_code//""),(.country//""),(.region//""),(.city//""),(.isp//""),(.org//""),(.asn//""),((.proxy//"")|tostring),((.hosting//"")|tostring),(.message//"")] | @csv
  ' "$f" >> "$ALL_CSV"
  jq -r --arg cc "$COUNTRY" '
    select((.country_code//""|ascii_upcase)==$cc) |
    [(.ip//""),((.ip//"")|split(".")[0]//""),((.ip//"")|split(".")[1]//""),((.ip//"")|split(".")[2]//""),((.ip//"")|split(".")[3]//""),(.provider//""),(.status//""),(.country_code//""),(.country//""),(.region//""),(.city//""),(.isp//""),(.org//""),(.asn//""),((.proxy//"")|tostring),((.hosting//"")|tostring),(.message//"")] | @csv
  ' "$f" >> "$MATCHED_CSV"
}

make_payload(){ jq -R . "$TMP_BATCH" | jq -s . > "$TMP_PAYLOAD"; }

provider_ipapi(){
  make_payload
  curl -sS -X POST -H 'Content-Type: application/json' \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    --data @"$TMP_PAYLOAD" -D "$TMP_HEADERS" -o "$TMP_RESP" -w '%{http_code}' \
    "http://ip-api.com/batch?fields=${IPAPI_FIELDS}"
}
normalize_ipapi(){
  jq -c '.[]|{ip:(.query//""),provider:"ipapi",status:(.status//"fail"),country_code:((.countryCode//"")|ascii_upcase),country:(.country//""),region:(.regionName//""),city:(.city//""),isp:(.isp//""),org:(.org//""),asn:(.as//""),proxy:(.proxy//""),hosting:(.hosting//""),message:(.message//"")}' "$TMP_RESP" > "$TMP_NORM"
}
maybe_ipapi_sleep(){
  local rl ttl
  rl="$(awk 'BEGIN{IGNORECASE=1}/^X-Rl:/{gsub("\r","",$2);print $2}' "$TMP_HEADERS" | tail -n1 || true)"
  ttl="$(awk 'BEGIN{IGNORECASE=1}/^X-Ttl:/{gsub("\r","",$2);print $2}' "$TMP_HEADERS" | tail -n1 || true)"
  if [ "${rl:-}" = "0" ] && is_uint "${ttl:-}" && [ "$ttl" -gt 0 ]; then log "  -> ip-api rate limit wait ${ttl}s"; sleep "$ttl"; fi
}

provider_countryis(){
  make_payload
  curl -sS -X POST -H 'Content-Type: application/json' \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    --data @"$TMP_PAYLOAD" -D "$TMP_HEADERS" -o "$TMP_RESP" -w '%{http_code}' \
    'https://api.country.is/?fields=city,subdivision,asn'
}
normalize_countryis(){
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
    else empty end
  ' "$TMP_RESP" > "$TMP_NORM"
}

provider_ipwhois(){
  : > "$TMP_RESP"; : > "$TMP_HEADERS"
  local ip code body head idx=0 good=0 retry total
  total="$(wc -l < "$TMP_BATCH" | tr -d ' ')"
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    idx=$((idx+1)); body="$TMP_DIR/ipwhois_$idx.json"; head="$TMP_DIR/ipwhois_$idx.headers"
    vlog "ipwhois $idx/$total $ip"
    code="$(curl -sS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
      -D "$head" -o "$body" -w '%{http_code}' \
      "https://ipwho.is/${ip}?fields=success,message,ip,country,country_code,region,city,connection,security" \
      2>>"$FAIL_LOG" || true)"
    if [ "$code" = "429" ]; then
      retry="$(awk 'BEGIN{IGNORECASE=1}/^Retry-After:/{gsub("\r","",$2);print $2}' "$head" | tail -n1 || true)"
      if is_uint "${retry:-}" && [ "$retry" -gt 0 ]; then echo "$(date '+%F %T') ipwhois 429 $ip wait ${retry}s" >> "$FAIL_LOG"; sleep "$retry"; fi
    fi
    if jq empty "$body" >/dev/null 2>&1; then
      cat "$body" >> "$TMP_RESP"; printf '\n' >> "$TMP_RESP"
      [ "$code" = "200" ] && good=$((good+1))
    else
      jq -cn --arg ip "$ip" --arg msg "ipwhois HTTP $code or invalid json" '{success:false,ip:$ip,message:$msg}' >> "$TMP_RESP"
    fi
    sleep "$SINGLE_SLEEP"
  done < "$TMP_BATCH"
  [ "$good" -gt 0 ] && printf '200' || printf '000'
}
normalize_ipwhois(){
  jq -c '{ip:(.ip//""),provider:"ipwhois",status:(if .success==true then "success" else "fail" end),country_code:((.country_code//"")|ascii_upcase),country:(.country//""),region:(.region//""),city:(.city//""),isp:(.connection.isp//""),org:(.connection.org//""),asn:((.connection.asn//"")|tostring),proxy:(.security.proxy//""),hosting:(.security.hosting//""),message:(.message//"")}' "$TMP_RESP" > "$TMP_NORM"
}

append_missing(){
  local provider="$1" ip
  jq -r 'select((.ip//"")!="")|.ip' "$TMP_NORM" | awk '!seen[$0]++' > "$TMP_KNOWN"
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    grep -qxF "$ip" "$TMP_KNOWN" || jq -cn --arg ip "$ip" --arg p "$provider" '{ip:$ip,provider:$p,status:"fail",country_code:"",country:"",region:"",city:"",isp:"",org:"",asn:"",proxy:"",hosting:"",message:"provider response missing this IP"}' >> "$TMP_NORM"
  done < "$TMP_BATCH"
}

run_provider_once(){
  local p="$1" code count
  : > "$TMP_RESP"; : > "$TMP_HEADERS"; : > "$TMP_NORM"
  case "$p" in
    ipapi) code="$(provider_ipapi 2>>"$FAIL_LOG" || true)" ;;
    countryis) code="$(provider_countryis 2>>"$FAIL_LOG" || true)" ;;
    ipwhois) code="$(provider_ipwhois 2>>"$FAIL_LOG" || true)" ;;
    *) return 1 ;;
  esac
  vlog "$p HTTP=$code"
  [ "$p" = ipapi ] && maybe_ipapi_sleep
  if [ "$code" != 200 ]; then
    echo "$(date '+%F %T') provider=$p HTTP=$code" >> "$FAIL_LOG"
    [ -s "$TMP_RESP" ] && { echo response: >> "$FAIL_LOG"; cat "$TMP_RESP" >> "$FAIL_LOG"; echo >> "$FAIL_LOG"; }
    return 1
  fi
  [ -s "$TMP_RESP" ] || { echo "$(date '+%F %T') provider=$p empty response" >> "$FAIL_LOG"; return 1; }
  jq empty "$TMP_RESP" >/dev/null 2>&1 || { echo "$(date '+%F %T') provider=$p invalid json" >> "$FAIL_LOG"; cat "$TMP_RESP" >> "$FAIL_LOG" || true; echo >> "$FAIL_LOG"; return 1; }
  case "$p" in ipapi) normalize_ipapi ;; countryis) normalize_countryis ;; ipwhois) normalize_ipwhois ;; esac
  [ -s "$TMP_NORM" ] || { echo "$(date '+%F %T') provider=$p normalized empty" >> "$FAIL_LOG"; return 1; }
  append_missing "$p"
  count="$(jq -r 'select((.ip//"")!="")|.ip' "$TMP_NORM" | wc -l | tr -d ' ')"
  [ "$count" != 0 ] || { echo "$(date '+%F %T') provider=$p zero normalized rows" >> "$FAIL_LOG"; return 1; }
}

run_provider(){
  local p="$1" n=0 max=$((RETRIES+1))
  while [ "$n" -lt "$max" ]; do
    n=$((n+1))
    run_provider_once "$p" && return 0
    echo "$(date '+%F %T') provider=$p attempt=$n failed" >> "$FAIL_LOG"
    [ "$n" -lt "$max" ] && sleep 2
  done
  return 1
}

append_failed_batch(){
  local msg="$1" ip
  : > "$TMP_NORM"
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    jq -cn --arg ip "$ip" --arg msg "$msg" '{ip:$ip,provider:"none",status:"fail",country_code:"",country:"",region:"",city:"",isp:"",org:"",asn:"",proxy:"",hosting:"",message:$msg}' >> "$TMP_NORM"
  done < "$TMP_BATCH"
  append_csv "$TMP_NORM"
}

process_failover(){
  local p hits
  IFS=',' read -r -a PROVIDER_ARR <<< "$PROVIDERS"
  for p in "${PROVIDER_ARR[@]}"; do
    log "  -> try API: $p"
    if run_provider "$p"; then
      append_csv "$TMP_NORM"
      hits="$(jq -r --arg cc "$COUNTRY" 'select((.country_code//""|ascii_upcase)==$cc)|.ip' "$TMP_NORM" | wc -l | tr -d ' ')"
      log "     ok: $p, hits=$hits $COUNTRY"
      return 0
    fi
    log "     failed: $p, switching"
  done
  append_failed_batch "all providers failed"
  return 1
}

process_verify_all(){
  local p ok=0 hits
  IFS=',' read -r -a PROVIDER_ARR <<< "$PROVIDERS"
  for p in "${PROVIDER_ARR[@]}"; do
    log "  -> verify API: $p"
    if run_provider "$p"; then
      append_csv "$TMP_NORM"; ok=1
      hits="$(jq -r --arg cc "$COUNTRY" 'select((.country_code//""|ascii_upcase)==$cc)|.ip' "$TMP_NORM" | wc -l | tr -d ' ')"
      log "     ok: $p, hits=$hits $COUNTRY"
    else
      log "     failed: $p"
    fi
  done
  [ "$ok" -eq 1 ] || { append_failed_batch "all providers failed in verify-all mode"; return 1; }
}

process_batches(){
  local total current=1 start end batch_no=0 matched_rows unique_hits
  total="$(wc -l < "$IPS_FILE" | tr -d ' ')"
  [ "$total" -gt 0 ] || { log "no IPs to query, maybe --resume skipped all"; return 0; }
  log "target country: $COUNTRY"
  log "IP count: $total"
  log "providers: $PROVIDERS"
  log "out dir: $OUT_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then log "dry-run: generated $IPS_FILE only"; return 0; fi
  while [ "$current" -le "$total" ]; do
    batch_no=$((batch_no+1)); start="$current"; end=$((current+BATCH_SIZE-1)); [ "$end" -gt "$total" ] && end="$total"
    sed -n "${start},${end}p" "$IPS_FILE" > "$TMP_BATCH"
    log "batch #$batch_no: $start-$end"
    [ "$VERIFY_ALL" -eq 1 ] && process_verify_all || process_failover || true
    current=$((end+1)); [ "$current" -le "$total" ] && sleep "$BATCH_SLEEP"
  done
  matched_rows="$(tail -n +2 "$MATCHED_CSV" | wc -l | tr -d ' ')"
  unique_hits="$(tail -n +2 "$MATCHED_CSV" | cut -d',' -f1 | tr -d '"' | awk 'NF&&!seen[$0]++' | wc -l | tr -d ' ')"
  log ""
  log "done"
  log "all: $ALL_CSV"
  log "matched: $MATCHED_CSV"
  log "failed log: $FAIL_LOG"
  log "matched rows: $matched_rows"
  log "unique matched IPs: $unique_hits"
  if [ "$unique_hits" != 0 ]; then
    log "matched IPs:"
    tail -n +2 "$MATCHED_CSV" | cut -d',' -f1 | tr -d '"' | awk 'NF&&!seen[$0]++'
  fi
}

main(){
  parse_args "$@"
  validate_args
  need_cmd curl; need_cmd jq
  init_paths
  generate_ips
  process_batches
}
main "$@"
