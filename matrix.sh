#!/usr/bin/env bash
# matrix.sh — SCM side of the custom-host trust matrix (run where airs-cli and the tenant credentials are).
#
#   bash matrix.sh scm-add  hosts.tsv     # add every scm/both host to the org egress allowlist (SCM trust list)
#   bash matrix.sh save     hosts.tsv     # create one tth-<cell>-<form> integration per row (+ tth-public); TSV of save results
#   bash matrix.sh wh-save  hosts.tsv     # per row (+ tth-wh-public): a webhook guardrail on <url>/webhook, a config that
#                                         # runs it and a service key (secret in $STATE); TSV of save results
#   bash matrix.sh env      hosts.tsv     # print the TRUSTED_CUSTOM_HOSTS additions: exact hosts for env/both, and
#                                         # wildcards / CIDRs for the wildcard cells (below)
#   bash matrix.sh probe-key              # a workspace service key (tth-probe) for probe.sh's integration rows, in $STATE
#   bash matrix.sh scm-del                # delete allowlist entries whose description is "$TAG"
#   bash matrix.sh edit                   # try a description edit and a base-URL edit on each saved tth-*-ip integration
#   bash matrix.sh cleanup                # delete every tth-* integration, and the tth-* keys, configs and guardrails in $STATE
#
# hosts.tsv comes from deploy.sh: cell form url host. Cells: none (no list), scm (SCM list only), env (env var only),
# both. Wildcard cells, each deployed in its own namespace: wsvc (env *.<ns>.svc), wns (env *.<ns>), wcidr (env
# <ip>/$CIDR_BITS for its ClusterIP and pod IP, default 32; SCM gets the exact IPs so its integrations save).
# Env: MGMT_CREDS_FILE (airs-cli tenant config JSON: mgmtClientId/Secret/TsgId), WS_ID (workspace UUID the probe's
# gateway key uses), PUBLIC_URL (control, default https://httpbin.org/anything), PUBLIC_WEBHOOK_URL (webhook control,
# default the same), TAG, CIDR_BITS, STATE (key secrets and ids, default ~/.local/state/aigw-private-hosts; never
# commit or copy it).
set -euo pipefail
: "${MGMT_CREDS_FILE:?set MGMT_CREDS_FILE (airs-cli tenant config JSON)}"
TSG=$(jq -r .mgmtTsgId "$MGMT_CREDS_FILE")
TAG=${TAG:-aigw-private-hosts}
PUBLIC_URL=${PUBLIC_URL:-https://httpbin.org/anything}
ALLOW=https://api.apps.paloaltonetworks.com/ai_gw/admin/v2/egress-allowlist
AI=(airs-cli --quiet aigateway integrations)
GW=(airs-cli --quiet aigateway)
STATE=${STATE:-$HOME/.local/state/aigw-private-hosts}

token() {  # SCM bearer token; stays in the caller's variable, never printed
  curl -s -X POST https://auth.apps.paloaltonetworks.com/oauth2/access_token \
    -u "$(jq -r .mgmtClientId "$MGMT_CREDS_FILE"):$(jq -r .mgmtClientSecret "$MGMT_CREDS_FILE")" \
    -d grant_type=client_credentials -d "scope=tsg_id:$TSG" | jq -r '.access_token // empty'
}
int_id() { "${AI[@]}" list --output json 2>/dev/null | jq -r --arg s "$1" '.[] | select(.slug == $s) | .id'; }

case ${1:-} in
  scm-add)
    tok=$(token)
    awk -F'\t' '$1 == "scm" || $1 == "both" || ($1 == "wcidr" && $2 ~ /-ip$/) {print $4}' "$2" | sort -u | while read -r h; do
      code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ALLOW" -H "Authorization: Bearer $tok" \
        -H 'Content-Type: application/json' -d "$(jq -nc --arg d "$h" --arg t "$TAG" '{domain: $d, description: $t}')")
      printf 'scm-add\t%s\t%s\n' "$h" "$code"
    done ;;
  scm-del)
    tok=$(token)
    curl -s "$ALLOW?page_size=100" -H "Authorization: Bearer $tok" | jq -r --arg t "$TAG" '.data[] | select(.description == $t) | "\(.id)\t\(.domain)"' |
      while IFS=$'\t' read -r id h; do
        printf 'scm-del\t%s\t%s\n' "$h" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$ALLOW/$id" -H "Authorization: Bearer $tok")"
      done ;;
  env)  # warns on stderr if a wcidr range also covers another cell's IP (that would confound the other cell's rows)
    awk -F'\t' -v bits="${CIDR_BITS:-32}" '
      function n(s,  a) { split(s, a, "."); return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
      function ip(x) { return sprintf("%d.%d.%d.%d", int(x / 16777216) % 256, int(x / 65536) % 256, int(x / 256) % 256, x % 256) }
      { h = $4
        if ($1 == "env" || $1 == "both") out[h] = 1
        else if (($1 == "wsvc" && $2 == "svc-short") || ($1 == "wns" && $2 == "svc-ns")) { sub(/^[^.]*\./, "", h); out["*." h] = 1 }
        else if ($1 == "wcidr" && $2 ~ /-ip$/) { size = 2 ^ (32 - bits); lo[++r] = int(n(h) / size) * size; out[ip(lo[r]) "/" bits] = 1 }
        else if (h ~ /^[0-9.]+$/) other[h] = $1 }
      END { for (h in other) for (i = 1; i <= r; i++) if (n(h) >= lo[i] && n(h) < lo[i] + size)
              print "matrix.sh env: a wcidr range covers " h " (cell " other[h] ")" > "/dev/stderr"
            for (h in out) print h }' "$2" | sort | paste -sd, - ;;
  probe-key)
    : "${WS_ID:?set WS_ID (workspace UUID)}"; mkdir -p "$STATE" && chmod 700 "$STATE"
    (umask 077; "${GW[@]}" api-keys service create --type workspace --workspace "$WS_ID" --organisation-id "$TSG" \
      --name tth-probe --scopes completions.write --secret-output "$STATE/tth-probe.key" --output json >/dev/null)
    jq -n --arg k "$(jq -r .id "$STATE/tth-probe.key")" '{key: $k}' > "$STATE/tth-probe.ids"
    echo "GW_KEY: jq -r .key $STATE/tth-probe.key" >&2 ;;
  save)
    : "${WS_ID:?set WS_ID (workspace UUID)}"
    { cat "$2"; printf 'public\tpublic\t%s\t-\n' "$PUBLIC_URL"; } | while IFS=$'\t' read -r cell form url _; do
      slug=tth-$cell${form:+-$form}; [ "$cell" = public ] && slug=tth-public
      out=$(echo dummy | "${AI[@]}" create --organisation-id "$TSG" --name "$slug" --slug "$slug" --description "$TAG" \
        --ai-provider open-ai --key-stdin --base-url "$url" --output json 2>&1 | tr -d '\n') || true
      id=$(int_id "$slug")
      if [ -n "$id" ]; then
        "${AI[@]}" workspaces set "$id" --workspace-binding "$WS_ID=true" --create-default-provider true \
          --default-provider-slug "$slug" --force --output json >/dev/null 2>&1 || true
        printf '%s\t%s\t%s\tsaved\t-\n' "$slug" "$cell" "$url"
      else
        printf '%s\t%s\t%s\trejected\t%s\n' "$slug" "$cell" "$url" "$(sed -E 's/.*(Error|Invalid)[: ]*//' <<<"$out" | cut -c1-120)"
      fi
    done ;;
  wh-save)
    : "${WS_ID:?set WS_ID (workspace UUID)}"; mkdir -p "$STATE" && chmod 700 "$STATE"
    ACTIONS='{"deny":true,"async":false,"on_success":{"feedback":{"value":1,"weight":1,"metadata":""}},
      "on_fail":{"feedback":{"value":-1,"weight":1,"metadata":""}}}'
    { awk -F'\t' -v OFS='\t' '{sub(/\/v1$/, "/webhook", $3); print}' "$2"
      printf 'public\tpublic\t%s\t-\n' "${PUBLIC_WEBHOOK_URL:-$PUBLIC_URL}"; } | while IFS=$'\t' read -r cell form url _; do
      slug=tth-wh-$cell-$form; [ "$cell" = public ] && slug=tth-wh-public
      checks=$(jq -cn --arg u "$url" '[{id: "default.webhook", parameters: {webhookURL: $u, timeout: 3000, failOnError: true}}]')
      if ! gr=$("${GW[@]}" guardrails create --workspace "$WS_ID" --name "$slug" --checks "$checks" --actions "$ACTIONS" --output json 2>&1); then
        printf '%s\t%s\t%s\trejected\t%s\n' "$slug" "$cell" "$url" "$(tr -d '\n' <<<"$gr" | sed -E 's/.*(Error|Invalid)[: ]*//' | cut -c1-120)"
        continue
      fi
      jq -n --arg gr "$(jq -r .id <<<"$gr")" '{guardrail: $gr}' > "$STATE/$slug.ids"
      # Upstream is never reached: the mock's webhook answers verdict false, and a refused URL fails closed.
      cfg=$("${GW[@]}" configs create --workspace "$WS_ID" --name "$slug" --set "config=$(jq -cn --arg g "$(jq -r .slug <<<"$gr")" \
        '{provider: "openai", retry: {attempts: 1}, input_guardrails: [$g]}')" --output json)
      jq --arg c "$(jq -r .id <<<"$cfg")" '. + {config: $c}' "$STATE/$slug.ids" > "$STATE/$slug.tmp" && mv "$STATE/$slug.tmp" "$STATE/$slug.ids"
      (umask 077; "${GW[@]}" api-keys service create --type workspace --workspace "$WS_ID" --organisation-id "$TSG" \
        --name "$slug" --scopes completions.write --set "defaults={\"config_id\":\"$(jq -r .id <<<"$cfg")\"}" \
        --secret-output "$STATE/$slug.key" --output json >/dev/null)
      jq --arg k "$(jq -r .id "$STATE/$slug.key")" '. + {key: $k}' "$STATE/$slug.ids" > "$STATE/$slug.tmp" && mv "$STATE/$slug.tmp" "$STATE/$slug.ids"
      printf '%s\t%s\t%s\tsaved\t-\n' "$slug" "$cell" "$url"
    done ;;
  edit)  # run after scm-del: does an integration whose SCM entry is gone still accept edits?
    "${AI[@]}" list --output json 2>/dev/null | jq -r '.[] | select(.slug | test("^tth-.*-ip$")) | "\(.id)\t\(.slug)"' |
      while IFS=$'\t' read -r id slug; do
        url=$("${AI[@]}" get "$id" --output json 2>/dev/null | jq -r '.configurations.custom_host // "-"')  # list omits configurations
        for kind in description base-url; do
          [ "$kind" = base-url ] && [ "$url" = - ] && { printf '%s\t%s\t-\tskipped\tno custom_host\n' "$slug" "$kind"; continue; }
          if [ "$kind" = description ]; then args=(--description "$TAG (edited)"); else args=(--base-url "$url"); fi
          if out=$("${AI[@]}" update "$id" "${args[@]}" --output json 2>&1); then
            printf '%s\t%s\t%s\tok\t-\n' "$slug" "$kind" "$url"
          else
            printf '%s\t%s\t%s\trefused\t%s\n' "$slug" "$kind" "$url" "$(tr -d '\n' <<<"$out" | sed -E 's/.*(Error|Invalid)[: ]*//' | cut -c1-120)"
          fi
        done
      done ;;
  cleanup)
    "${AI[@]}" list --output json 2>/dev/null | jq -r '.[] | select(.slug | startswith("tth-")) | "\(.id)\t\(.slug)"' |
      while IFS=$'\t' read -r id slug; do
        "${AI[@]}" delete "$id" --organisation-id "$TSG" --force >/dev/null 2>&1 && printf 'deleted\t%s\n' "$slug" || printf 'delete-failed\t%s\n' "$slug"
      done
    for f in "$STATE"/tth-*.ids; do
      [ -f "$f" ] || continue; slug=$(basename "$f" .ids); ok=1
      id=$(jq -r '.key // empty' "$f"); [ -z "$id" ] || "${GW[@]}" api-keys service delete "$id" --force >/dev/null 2>&1 || ok=
      id=$(jq -r '.config // empty' "$f"); [ -z "$id" ] || "${GW[@]}" configs delete "$id" --force >/dev/null 2>&1 || ok=
      id=$(jq -r '.guardrail // empty' "$f"); [ -z "$id" ] || "${GW[@]}" guardrails delete "$id" --force >/dev/null 2>&1 || ok=
      if [ -n "$ok" ]; then rm -f "$f"; shred -u "$STATE/$slug.key" 2>/dev/null || rm -f "$STATE/$slug.key"; printf 'deleted\t%s\n' "$slug"
      else printf 'delete-failed\t%s\n' "$slug"; fi
    done ;;
  *) sed -n '2,21p' "$0"; exit 1 ;;
esac
