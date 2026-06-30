#!/usr/bin/env bash
set -u

VERSION="1.2.1"
TIMEOUT=12
CONNECT_TIMEOUT=6
JSON_OUTPUT=0
GEO_OUTPUT=1
NO_COLOR="${NO_COLOR:-}"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

usage() {
  cat <<'USAGE'
AI Unlock Checker

Usage:
  bash ai-unlock-checker.sh [options]

Options:
  --json                  Output machine-readable JSON
  --timeout SECONDS       Total timeout for each service, default: 12
  --connect-timeout SEC   Connection timeout for each service, default: 6
  --no-geo                Do not query public IP geolocation
  --no-color              Disable terminal colors
  -h, --help              Show help
  -v, --version           Show version

Examples:
  bash ai-unlock-checker.sh
  bash ai-unlock-checker.sh --json
  bash ai-unlock-checker.sh --timeout 20
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      JSON_OUTPUT=1
      ;;
    --timeout)
      shift
      TIMEOUT="${1:-}"
      ;;
    --connect-timeout)
      shift
      CONNECT_TIMEOUT="${1:-}"
      ;;
    --no-geo)
      GEO_OUTPUT=0
      ;;
    --no-color)
      NO_COLOR=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -v|--version)
      echo "$VERSION"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

case "$TIMEOUT" in
  ''|*[!0-9]*)
    echo "--timeout must be a positive integer." >&2
    exit 2
    ;;
esac

case "$CONNECT_TIMEOUT" in
  ''|*[!0-9]*)
    echo "--connect-timeout must be a positive integer." >&2
    exit 2
    ;;
esac

if [ -t 1 ] && [ -z "$NO_COLOR" ] && [ "$JSON_OUTPUT" -eq 0 ]; then
  C_RESET="$(printf '\033[0m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_RED="$(printf '\033[31m')"
  C_BLUE="$(printf '\033[34m')"
  C_DIM="$(printf '\033[2m')"
else
  C_RESET=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_BLUE=""
  C_DIM=""
fi

SERVICES=$(cat <<'SERVICES_EOF'
OpenAI API|https://api.openai.com/v1/models|401
ChatGPT Web|https://chatgpt.com/|200,302
Claude Web|https://claude.ai/|200,302
Anthropic API|https://api.anthropic.com/v1/models|401
Gemini Web|https://gemini.google.com/|200,302
Google AI API|https://generativelanguage.googleapis.com/v1beta/models|403
Google AI Studio|https://aistudio.google.com/|200,302
Microsoft Copilot|https://copilot.microsoft.com/|200,302
Perplexity|https://www.perplexity.ai/|200,302
Grok|https://grok.com/|200,302
Meta AI|https://www.meta.ai/|200,302
DeepSeek Chat|https://chat.deepseek.com/|200,302
DeepSeek API|https://api.deepseek.com/models|401
Mistral Le Chat|https://chat.mistral.ai/chat|200,302
Mistral API|https://api.mistral.ai/v1/models|401
Poe|https://poe.com/|200,302
Hugging Face Chat|https://huggingface.co/chat/|200,302
SERVICES_EOF
)

SUMMARY_SERVICES=$(cat <<'SUMMARY_SERVICES_EOF'
OpenAI|OpenAI API
ChatGPT|ChatGPT Web
Claude|Claude Web
Anthropic API|Anthropic API
Gemini|Gemini Web
Google AI API|Google AI API
Google AI Studio|Google AI Studio
Copilot|Microsoft Copilot
Perplexity|Perplexity
Grok|Grok
Meta AI|Meta AI
DeepSeek|DeepSeek Chat
DeepSeek API|DeepSeek API
Mistral|Mistral Le Chat
Mistral API|Mistral API
Poe|Poe
Hugging Face|Hugging Face Chat
SUMMARY_SERVICES_EOF
)

json_escape() {
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      gsub(/\r/, "\\r")
      if (NR > 1) {
        printf "\\n"
      }
      printf "%s", $0
    }
  '
}

json_number_or_null() {
  case "$1" in
    ''|*[!0-9.]*)
      printf 'null'
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

json_http_code() {
  case "$1" in
    ''|000|*[!0-9]*)
      printf '0'
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

json_string_or_null() {
  if [ -n "$1" ]; then
    printf '"%s"' "$(json_escape "$1")"
  else
    printf 'null'
  fi
}

json_flat_string() {
  local key="$1"
  sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 | sed 's/\\"/"/g; s#\\/#/#g'
}

json_flat_number() {
  local key="$1"
  sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -n 1
}

contains_status() {
  local list="$1"
  local status="$2"
  case ",$list," in
    *,"$status",*) return 0 ;;
    *) return 1 ;;
  esac
}

lower_file_sample() {
  local file="$1"
  if [ -f "$file" ]; then
    LC_ALL=C tr '[:upper:]' '[:lower:]' < "$file" | head -c 20000
  fi
}

has_geo_block() {
  local text="$1"
  case "$text" in
    *"unsupported country"*|*"unsupported region"*|*"country, region, or territory not supported"*|*"not available in your country"*|*"not available in your region"*|*"unavailable in your country"*|*"unavailable in your region"*|*"service is not available"*|*"region is not supported"*|*"location is not supported"*|*"restricted location"*|*"blocked in your country"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

has_cloudflare_challenge() {
  local text="$1"
  case "$text" in
    *"cf-mitigated: challenge"*|*"challenge-platform"*|*"just a moment"*|*"attention required"*|*"checking if the site connection is secure"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

status_color() {
  case "$1" in
    UNLOCKED) printf '%s' "$C_GREEN" ;;
    REACHABLE) printf '%s' "$C_BLUE" ;;
    LOCKED) printf '%s' "$C_RED" ;;
    FAILED) printf '%s' "$C_RED" ;;
    *) printf '%s' "$C_YELLOW" ;;
  esac
}

summary_status_text() {
  case "$1" in
    UNLOCKED) printf '解锁' ;;
    *) printf '不解锁' ;;
  esac
}

summary_status_color() {
  case "$1" in
    UNLOCKED) printf '%s' "$C_GREEN" ;;
    *) printf '%s' "$C_RED" ;;
  esac
}

probe_ip() {
  local ip
  ip="$(curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" https://api.ipify.org 2>/dev/null || true)"
  if [ -n "$ip" ]; then
    printf '%s' "$ip"
  else
    printf 'unknown'
  fi
}

probe_geo_ipapi() {
  local ip="$1"
  local body country region city asn org timezone

  body="$(curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" "https://ipapi.co/${ip}/json/" 2>/dev/null || true)"
  [ -n "$body" ] || return 1

  country="$(printf '%s' "$body" | json_flat_string "country_name")"
  region="$(printf '%s' "$body" | json_flat_string "region")"
  city="$(printf '%s' "$body" | json_flat_string "city")"
  asn="$(printf '%s' "$body" | json_flat_string "asn")"
  org="$(printf '%s' "$body" | json_flat_string "org")"
  timezone="$(printf '%s' "$body" | json_flat_string "timezone")"

  [ -n "$country$region$city$asn$org" ] || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$country" "$region" "$city" "$asn" "$org" "$timezone"
}

probe_geo_ipwhois() {
  local ip="$1"
  local body country region city asn org timezone

  body="$(curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" "https://ipwho.is/${ip}" 2>/dev/null || true)"
  [ -n "$body" ] || return 1

  country="$(printf '%s' "$body" | json_flat_string "country")"
  region="$(printf '%s' "$body" | json_flat_string "region")"
  city="$(printf '%s' "$body" | json_flat_string "city")"
  asn="$(printf '%s' "$body" | json_flat_number "asn")"
  org="$(printf '%s' "$body" | json_flat_string "org")"
  timezone="$(printf '%s' "$body" | json_flat_string "id")"

  if [ -n "$asn" ]; then
    asn="AS${asn}"
  fi

  [ -n "$country$region$city$asn$org" ] || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$country" "$region" "$city" "$asn" "$org" "$timezone"
}

probe_geo() {
  local ip="$1"

  if [ "$GEO_OUTPUT" -eq 0 ] || [ -z "$ip" ] || [ "$ip" = "unknown" ]; then
    printf '\t\t\t\t\t'
    return 0
  fi

  probe_geo_ipapi "$ip" || probe_geo_ipwhois "$ip" || printf '\t\t\t\t\t'
}

trim_text() {
  printf '%s' "$1" | awk '{$1=$1; print}'
}

location_has_part() {
  local out="$1"
  local part="$2"
  local old_ifs item

  old_ifs="$IFS"
  IFS='/'
  for item in $out; do
    item="$(trim_text "$item")"
    if [ "$item" = "$part" ]; then
      IFS="$old_ifs"
      return 0
    fi
  done
  IFS="$old_ifs"
  return 1
}

append_location_part() {
  local out="$1"
  local part

  part="$(trim_text "$2")"
  if [ -z "$part" ] || location_has_part "$out" "$part"; then
    printf '%s' "$out"
    return 0
  fi

  printf '%s' "${out}${out:+ / }${part}"
}

format_geo_location() {
  local country="$1"
  local region="$2"
  local city="$3"
  local out=""

  out="$(append_location_part "$out" "$country")"
  out="$(append_location_part "$out" "$region")"
  out="$(append_location_part "$out" "$city")"
  [ -n "$out" ] || out="unknown"
  printf '%s' "$out"
}

format_geo_asn() {
  local asn="$1"
  local org="$2"
  local out=""

  [ -n "$asn" ] && out="$asn"
  [ -n "$org" ] && out="${out}${out:+ }${org}"
  [ -n "$out" ] || out="unknown"
  printf '%s' "$out"
}

result_for_service() {
  local results_file="$1"
  local service="$2"
  awk -F'\t' -v service="$service" '$1 == service { print; exit }' "$results_file"
}

print_summary_table() {
  local results_file="$1"
  local location="$2"
  local display service line verdict status color reset

  printf '解锁摘要:\n'
  printf '%-18s %-8s %s\n' "AI 服务" "状态" "地区"
  printf '%-18s %-8s %s\n' "------------------" "--------" "------------------------------"

  while IFS='|' read -r display service; do
    [ -n "$display" ] || continue
    line="$(result_for_service "$results_file" "$service")"
    verdict="$(printf '%s' "$line" | awk -F'\t' '{print $2}')"
    [ -n "$verdict" ] || verdict="FAILED"
    status="$(summary_status_text "$verdict")"
    color="$(summary_status_color "$verdict")"
    reset="$C_RESET"
    printf '%-18s %s%-8s%s %s\n' "$display" "$color" "$status" "$reset" "$location"
  done <<EOF
$SUMMARY_SERVICES
EOF
}

probe_service() {
  local name="$1"
  local url="$2"
  local expected="$3"
  local headers body curl_out curl_code http_code remote_ip time_total effective_url all_text verdict reason

  headers="$(mktemp)"
  body="$(mktemp)"

  curl_out="$(
    curl -L -sS \
      -A "$UA" \
      -H "Accept: text/html,application/json,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
      -H "Accept-Language: en-US,en;q=0.9" \
      --connect-timeout "$CONNECT_TIMEOUT" \
      --max-time "$TIMEOUT" \
      --compressed \
      -D "$headers" \
      -o "$body" \
      -w '%{http_code}|%{remote_ip}|%{time_total}|%{url_effective}' \
      "$url" 2>"$body.err"
  )"
  curl_code=$?

  http_code="$(printf '%s' "$curl_out" | awk -F'|' '{print $1}')"
  remote_ip="$(printf '%s' "$curl_out" | awk -F'|' '{print $2}')"
  time_total="$(printf '%s' "$curl_out" | awk -F'|' '{print $3}')"
  effective_url="$(printf '%s' "$curl_out" | cut -d'|' -f4-)"
  [ -n "$http_code" ] || http_code="000"
  [ -n "$remote_ip" ] || remote_ip="-"
  [ -n "$time_total" ] || time_total="-"

  all_text="$(lower_file_sample "$headers"; printf '\n'; lower_file_sample "$body"; printf '\n'; lower_file_sample "$body.err")"

  if [ "$curl_code" -ne 0 ]; then
    verdict="FAILED"
    reason="$(cat "$body.err" 2>/dev/null | head -n 1)"
    [ -n "$reason" ] || reason="curl exit code $curl_code"
  elif [ "$http_code" = "000" ]; then
    verdict="FAILED"
    reason="no HTTP response"
  elif [ "$http_code" = "451" ] || has_geo_block "$all_text"; then
    verdict="LOCKED"
    reason="region or location restriction detected"
  elif has_cloudflare_challenge "$all_text"; then
    verdict="REACHABLE"
    reason="reachable, but browser challenge was returned"
  elif contains_status "$expected" "$http_code"; then
    verdict="UNLOCKED"
    reason="expected HTTP $http_code"
  elif [ "$http_code" -ge 200 ] && [ "$http_code" -lt 500 ]; then
    verdict="REACHABLE"
    reason="HTTP $http_code, no region block detected"
  else
    verdict="FAILED"
    reason="unexpected HTTP $http_code"
  fi

  rm -f "$headers" "$body" "$body.err"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$verdict" "$http_code" "$time_total" "$remote_ip" "$reason" "$effective_url"
}

run_table() {
  local public_ip geo country region city asn org timezone location results_file line name verdict code seconds remote_ip reason effective_url color reset
  public_ip="$(probe_ip)"
  geo="$(probe_geo "$public_ip")"
  country="$(printf '%s' "$geo" | awk -F'\t' '{print $1}')"
  region="$(printf '%s' "$geo" | awk -F'\t' '{print $2}')"
  city="$(printf '%s' "$geo" | awk -F'\t' '{print $3}')"
  asn="$(printf '%s' "$geo" | awk -F'\t' '{print $4}')"
  org="$(printf '%s' "$geo" | awk -F'\t' '{print $5}')"
  timezone="$(printf '%s' "$geo" | awk -F'\t' '{print $6}')"
  location="$(format_geo_location "$country" "$region" "$city")"
  results_file="$(mktemp)"

  printf '%sAI Unlock Checker%s v%s\n' "$C_GREEN" "$C_RESET" "$VERSION"
  printf 'Public IP: %s%s%s\n' "$C_DIM" "$public_ip" "$C_RESET"
  if [ "$GEO_OUTPUT" -eq 1 ]; then
    printf 'IP Geo: %s%s%s\n' "$C_DIM" "$location" "$C_RESET"
    printf 'ASN: %s%s%s\n' "$C_DIM" "$(format_geo_asn "$asn" "$org")" "$C_RESET"
    if [ -n "$timezone" ]; then
      printf 'Timezone: %s%s%s\n' "$C_DIM" "$timezone" "$C_RESET"
    fi
  fi
  printf 'Timeout: %ss, Connect timeout: %ss\n\n' "$TIMEOUT" "$CONNECT_TIMEOUT"

  while IFS='|' read -r name url expected; do
    [ -n "$name" ] || continue
    probe_service "$name" "$url" "$expected" >> "$results_file"
  done <<EOF
$SERVICES
EOF

  print_summary_table "$results_file" "$location"
  printf '\n'
  printf '%-20s %-10s %-6s %-8s %-16s %s\n' "Service" "Result" "HTTP" "Time" "Remote IP" "Note"
  printf '%-20s %-10s %-6s %-8s %-16s %s\n' "--------------------" "----------" "------" "--------" "----------------" "------------------------------"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="$(printf '%s' "$line" | awk -F'\t' '{print $1}')"
    verdict="$(printf '%s' "$line" | awk -F'\t' '{print $2}')"
    code="$(printf '%s' "$line" | awk -F'\t' '{print $3}')"
    seconds="$(printf '%s' "$line" | awk -F'\t' '{print $4}')"
    remote_ip="$(printf '%s' "$line" | awk -F'\t' '{print $5}')"
    reason="$(printf '%s' "$line" | awk -F'\t' '{print $6}')"
    color="$(status_color "$verdict")"
    reset="$C_RESET"
    printf '%-20s %s%-10s%s %-6s %-8s %-16s %s\n' "$name" "$color" "$verdict" "$reset" "$code" "$seconds" "$remote_ip" "$reason"
  done < "$results_file"

  printf '\n%sLegend:%s UNLOCKED=expected response, REACHABLE=network OK but login/browser challenge may apply, LOCKED=region block detected, FAILED=timeout/network/server error.\n' "$C_DIM" "$C_RESET"
  printf '%sSummary:%s Only UNLOCKED is shown as 解锁. REACHABLE, LOCKED, and FAILED are shown as 不解锁 in the Chinese summary.\n' "$C_DIM" "$C_RESET"
  if [ "$GEO_OUTPUT" -eq 1 ]; then
    printf '%sNote:%s IP Geo is a third-party reference for the server exit IP. AI providers may judge region differently by account, payment, risk score, ASN, and browser state.\n' "$C_DIM" "$C_RESET"
  fi
  rm -f "$results_file"
}

run_json() {
  local public_ip geo country region city asn org timezone location results_file first line name verdict code seconds remote_ip reason effective_url url expected code_json seconds_json display service status
  public_ip="$(probe_ip)"
  geo="$(probe_geo "$public_ip")"
  country="$(printf '%s' "$geo" | awk -F'\t' '{print $1}')"
  region="$(printf '%s' "$geo" | awk -F'\t' '{print $2}')"
  city="$(printf '%s' "$geo" | awk -F'\t' '{print $3}')"
  asn="$(printf '%s' "$geo" | awk -F'\t' '{print $4}')"
  org="$(printf '%s' "$geo" | awk -F'\t' '{print $5}')"
  timezone="$(printf '%s' "$geo" | awk -F'\t' '{print $6}')"
  location="$(format_geo_location "$country" "$region" "$city")"
  results_file="$(mktemp)"

  while IFS='|' read -r name url expected; do
    [ -n "$name" ] || continue
    probe_service "$name" "$url" "$expected" >> "$results_file"
  done <<EOF
$SERVICES
EOF

  printf '{\n'
  printf '  "tool": "ai-unlock-checker",\n'
  printf '  "version": "%s",\n' "$(json_escape "$VERSION")"
  printf '  "public_ip": "%s",\n' "$(json_escape "$public_ip")"
  printf '  "geo": {"country":%s,"region":%s,"city":%s,"asn":%s,"org":%s,"timezone":%s,"note":"third-party IP geolocation reference, not provider unlock decision"},\n' \
    "$(json_string_or_null "$country")" \
    "$(json_string_or_null "$region")" \
    "$(json_string_or_null "$city")" \
    "$(json_string_or_null "$asn")" \
    "$(json_string_or_null "$org")" \
    "$(json_string_or_null "$timezone")"
  printf '  "timeout_seconds": %s,\n' "$TIMEOUT"
  printf '  "connect_timeout_seconds": %s,\n' "$CONNECT_TIMEOUT"
  printf '  "summary": [\n'
  first=1
  while IFS='|' read -r display service; do
    [ -n "$display" ] || continue
    line="$(result_for_service "$results_file" "$service")"
    verdict="$(printf '%s' "$line" | awk -F'\t' '{print $2}')"
    [ -n "$verdict" ] || verdict="FAILED"
    status="$(summary_status_text "$verdict")"
    if [ "$first" -eq 0 ]; then
      printf ',\n'
    fi
    first=0
    printf '    {"provider":"%s","status":"%s","region":"%s","source_service":"%s","source_result":"%s"}' \
      "$(json_escape "$display")" \
      "$(json_escape "$status")" \
      "$(json_escape "$location")" \
      "$(json_escape "$service")" \
      "$(json_escape "$verdict")"
  done <<EOF
$SUMMARY_SERVICES
EOF
  printf '\n  ],\n'
  printf '  "results": [\n'
  first=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="$(printf '%s' "$line" | awk -F'\t' '{print $1}')"
    verdict="$(printf '%s' "$line" | awk -F'\t' '{print $2}')"
    code="$(printf '%s' "$line" | awk -F'\t' '{print $3}')"
    seconds="$(printf '%s' "$line" | awk -F'\t' '{print $4}')"
    remote_ip="$(printf '%s' "$line" | awk -F'\t' '{print $5}')"
    reason="$(printf '%s' "$line" | awk -F'\t' '{print $6}')"
    effective_url="$(printf '%s' "$line" | awk -F'\t' '{print $7}')"
    code_json="$(json_http_code "$code")"
    seconds_json="$(json_number_or_null "$seconds")"
    if [ "$first" -eq 0 ]; then
      printf ',\n'
    fi
    first=0
    printf '    {"service":"%s","result":"%s","http_code":%s,"time_seconds":%s,"remote_ip":"%s","reason":"%s","url":"%s","effective_url":"%s"}' \
      "$(json_escape "$name")" \
      "$(json_escape "$verdict")" \
      "$code_json" \
      "$seconds_json" \
      "$(json_escape "$remote_ip")" \
      "$(json_escape "$reason")" \
      "$(json_escape "$url")" \
      "$(json_escape "$effective_url")"
  done < "$results_file"
  printf '\n  ]\n'
  printf '}\n'
  rm -f "$results_file"
}

if [ "$JSON_OUTPUT" -eq 1 ]; then
  run_json
else
  run_table
fi
