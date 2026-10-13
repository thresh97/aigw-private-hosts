#!/usr/bin/env bash
# probe.sh — gateway side: one request per saved tth-* target (run anywhere that can reach the gateway).
#   GW_URL=https://<gateway> GW_KEY=<gateway key or JWT> bash probe.sh saved.tsv [label] >> results/probe.tsv
# saved.tsv is matrix.sh save or wh-save output (slug cell url saved|rejected note); rejected rows are skipped.
# Integration rows (tth-<cell>-<form>): a chat completion as model @<slug>/gpt-4o with GW_KEY.
# Webhook rows (tth-wh-*): a chat completion with the row's own key (from matrix.sh wh-save, in $STATE), whose config
# runs the webhook guardrail; GW_KEY isn't needed for these.
# Every request carries x-portkey-trace-id aigw-private-hosts-<label>-<slug>.
# stdout: label slug cell url http_code verdict detail
#   verdict: reached (the mock or the public control answered) | refused (gateway "Invalid custom host", or for a
#   webhook "rejected by SSRF policy") | error
set -euo pipefail
: "${GW_URL:?set GW_URL (gateway base URL)}"; label=${2:-run}
STATE=${STATE:-$HOME/.local/state/aigw-private-hosts}
while IFS=$'\t' read -r slug cell url state _; do
  [ "$state" = saved ] || continue
  if [[ $slug == tth-wh-* ]]; then key=$(jq -r .key "$STATE/$slug.key"); model=gpt-4o
  else key=${GW_KEY:?set GW_KEY}; model=@$slug/gpt-4o; fi
  out=$(curl -sS -m 30 -w '\n%{http_code}' "$GW_URL/v1/chat/completions" -H 'Content-Type: application/json' \
    -H "x-portkey-trace-id: aigw-private-hosts-$label-$slug" -H @<(printf 'x-portkey-api-key: %s\n' "$key") \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" 2>&1) || true
  code=${out##*$'\n'}; body=$(tr -d '\n' <<<"${out%$'\n'*}")
  case $body in
    *"mock cell="*) verdict=reached; detail=$(grep -o 'mock cell=[^"]*' <<<"$body" | head -1) ;;
    *httpbin.org*) verdict=reached; detail=public ;;
    *"Invalid custom host"*) verdict=refused; detail="Invalid custom host" ;;
    *"rejected by SSRF policy"*) verdict=refused; detail=$(grep -o 'Webhook error: [^"]*' <<<"$body" | head -1) ;;
    *) verdict=error  # the body can be plain text (e.g. "Message: fetch failed Cause: DnsRebindingBlockedError ...")
       detail=$(jq -r '(.hook_results.before_request_hooks // [])[0].checks[0].data.explanation? // .error.message? // empty' \
         <<<"$body" 2>/dev/null | head -1 || true); [ -n "$detail" ] || detail=$(cut -c1-160 <<<"$body") ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$slug" "$cell" "$url" "$code" "$verdict" "$detail"
done < "$1"
