#!/usr/bin/env bash
# probe.sh — gateway side: one chat completion per saved tth-* provider (run anywhere that can reach the gateway).
#   GW_URL=https://<gateway> GW_KEY=<gateway key or JWT> bash probe.sh saved.tsv [label] >> results/probe.tsv
# saved.tsv is matrix.sh save output (slug cell url saved|rejected note); rejected rows are skipped.
# stdout: label slug cell url http_code verdict detail
#   verdict: reached (the mock or the public control answered) | refused (gateway "Invalid custom host") | error
set -euo pipefail
: "${GW_URL:?set GW_URL (gateway base URL)}"; : "${GW_KEY:?set GW_KEY}"; label=${2:-run}
while IFS=$'\t' read -r slug cell url state _; do
  [ "$state" = saved ] || continue
  out=$(curl -sS -m 30 -w '\n%{http_code}' "$GW_URL/v1/chat/completions" -H "x-portkey-api-key: $GW_KEY" \
    -H 'Content-Type: application/json' -d "{\"model\":\"@$slug/gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" 2>&1) || true
  code=${out##*$'\n'}; body=$(tr -d '\n' <<<"${out%$'\n'*}")
  case $body in
    *"mock cell="*) verdict=reached; detail=$(grep -o 'mock cell=[^"]*' <<<"$body" | head -1) ;;
    *httpbin.org*) verdict=reached; detail=public ;;
    *"Invalid custom host"*) verdict=refused; detail="Invalid custom host" ;;
    *) verdict=error; detail=$(cut -c1-160 <<<"$body") ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$slug" "$cell" "$url" "$code" "$verdict" "$detail"
done < "$1"
