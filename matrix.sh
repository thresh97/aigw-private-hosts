#!/usr/bin/env bash
# matrix.sh — SCM side of the custom-host trust matrix (run where airs-cli and the tenant credentials are).
#
#   bash matrix.sh scm-add  hosts.tsv     # add every scm/both host to the org egress allowlist (SCM trust list)
#   bash matrix.sh save     hosts.tsv     # create one tth-<cell>-<form> integration per row (+ tth-public); TSV of save results
#   bash matrix.sh env      hosts.tsv     # print the TRUSTED_CUSTOM_HOSTS additions for the env/both cells
#   bash matrix.sh scm-del                # delete allowlist entries whose description is "$TAG"
#   bash matrix.sh cleanup                # delete every tth-* integration
#
# hosts.tsv comes from deploy.sh: cell form url host. Cells: none (no list), scm (SCM list only), env (env var only),
# both. Env: MGMT_CREDS_FILE (airs-cli tenant config JSON: mgmtClientId/Secret/TsgId), WS_ID (workspace UUID the
# probe's gateway key uses), PUBLIC_URL (control, default https://httpbin.org/anything), TAG.
set -euo pipefail
: "${MGMT_CREDS_FILE:?set MGMT_CREDS_FILE (airs-cli tenant config JSON)}"
TSG=$(jq -r .mgmtTsgId "$MGMT_CREDS_FILE")
TAG=${TAG:-aigw-private-hosts}
PUBLIC_URL=${PUBLIC_URL:-https://httpbin.org/anything}
ALLOW=https://api.apps.paloaltonetworks.com/ai_gw/admin/v2/egress-allowlist
AI=(airs-cli --quiet aigateway integrations)

token() {  # SCM bearer token; stays in the caller's variable, never printed
  curl -s -X POST https://auth.apps.paloaltonetworks.com/oauth2/access_token \
    -u "$(jq -r .mgmtClientId "$MGMT_CREDS_FILE"):$(jq -r .mgmtClientSecret "$MGMT_CREDS_FILE")" \
    -d grant_type=client_credentials -d "scope=tsg_id:$TSG" | jq -r '.access_token // empty'
}
int_id() { "${AI[@]}" list --output json 2>/dev/null | jq -r --arg s "$1" '.[] | select(.slug == $s) | .id'; }

case ${1:-} in
  scm-add)
    tok=$(token)
    awk -F'\t' '$1 == "scm" || $1 == "both" {print $4}' "$2" | sort -u | while read -r h; do
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
  env)
    awk -F'\t' '$1 == "env" || $1 == "both" {print $4}' "$2" | sort -u | paste -sd, - ;;
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
  cleanup)
    "${AI[@]}" list --output json 2>/dev/null | jq -r '.[] | select(.slug | startswith("tth-")) | "\(.id)\t\(.slug)"' |
      while IFS=$'\t' read -r id slug; do
        "${AI[@]}" delete "$id" --organisation-id "$TSG" --force >/dev/null 2>&1 && printf 'deleted\t%s\n' "$slug" || printf 'delete-failed\t%s\n' "$slug"
      done ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
