#!/usr/bin/env bash
set -u

VERSION="1.0.0"
TIMEOUT=12
CONNECT_TIMEOUT=6
JSON_OUTPUT=0
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

probe_ip() {
  local ip
  ip="$(curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$TIMEOUT" https://api.ipify.org 2>/dev/null || true)"
  if [ -n "$ip" ]; then
    printf '%s' "$ip"
  else
    printf 'unknown'
  fi
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
  local public_ip line name verdict code seconds remote_ip reason effective_url color reset
  public_ip="$(probe_ip)"

  printf '%sAI Unlock Checker%s v%s\n' "$C_GREEN" "$C_RESET" "$VERSION"
  printf 'Public IP: %s%s%s\n' "$C_DIM" "$public_ip" "$C_RESET"
  printf 'Timeout: %ss, Connect timeout: %ss\n\n' "$TIMEOUT" "$CONNECT_TIMEOUT"
  printf '%-20s %-10s %-6s %-8s %-16s %s\n' "Service" "Result" "HTTP" "Time" "Remote IP" "Note"
  printf '%-20s %-10s %-6s %-8s %-16s %s\n' "--------------------" "----------" "------" "--------" "----------------" "------------------------------"

  while IFS='|' read -r name url expected; do
    [ -n "$name" ] || continue
    line="$(probe_service "$name" "$url" "$expected")"
    name="$(printf '%s' "$line" | awk -F'\t' '{print $1}')"
    verdict="$(printf '%s' "$line" | awk -F'\t' '{print $2}')"
    code="$(printf '%s' "$line" | awk -F'\t' '{print $3}')"
    seconds="$(printf '%s' "$line" | awk -F'\t' '{print $4}')"
    remote_ip="$(printf '%s' "$line" | awk -F'\t' '{print $5}')"
    reason="$(printf '%s' "$line" | awk -F'\t' '{print $6}')"
    color="$(status_color "$verdict")"
    reset="$C_RESET"
    printf '%-20s %s%-10s%s %-6s %-8s %-16s %s\n' "$name" "$color" "$verdict" "$reset" "$code" "$seconds" "$remote_ip" "$reason"
  done <<EOF
$SERVICES
EOF

  printf '\n%sLegend:%s UNLOCKED=expected response, REACHABLE=network OK but login/browser challenge may apply, LOCKED=region block detected, FAILED=timeout/network/server error.\n' "$C_DIM" "$C_RESET"
}

run_json() {
  local public_ip first line name verdict code seconds remote_ip reason effective_url url expected code_json seconds_json
  public_ip="$(probe_ip)"
  printf '{\n'
  printf '  "tool": "ai-unlock-checker",\n'
  printf '  "version": "%s",\n' "$(json_escape "$VERSION")"
  printf '  "public_ip": "%s",\n' "$(json_escape "$public_ip")"
  printf '  "timeout_seconds": %s,\n' "$TIMEOUT"
  printf '  "connect_timeout_seconds": %s,\n' "$CONNECT_TIMEOUT"
  printf '  "results": [\n'
  first=1
  while IFS='|' read -r name url expected; do
    [ -n "$name" ] || continue
    line="$(probe_service "$name" "$url" "$expected")"
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
  done <<EOF
$SERVICES
EOF
  printf '\n  ]\n'
  printf '}\n'
}

if [ "$JSON_OUTPUT" -eq 1 ]; then
  run_json
else
  run_table
fi
