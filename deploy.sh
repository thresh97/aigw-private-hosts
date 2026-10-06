#!/usr/bin/env bash
# deploy.sh — deploy the mock cells and print their addresses (run wherever kubectl can reach the gateway cluster).
#   KCTX=<context> [NS=aigw-mock] [CELLS="none scm env both"] bash deploy.sh > hosts.tsv
# stdout: one TSV line per cell and host form: cell form url host   (logs go to stderr). vpc-dns is emitted on AWS only.
# The namespace must not be covered by an existing TRUSTED_CUSTOM_HOSTS wildcard (e.g. *.<gateway-namespace>.svc.cluster.local).
set -euo pipefail
cd "$(dirname "$0")"
: "${KCTX:?set KCTX to the kube context}"
NS=${NS:-aigw-mock}; CELLS=${CELLS:-none scm env both}
K=(kubectl --context "$KCTX")

"${K[@]}" create namespace "$NS" --dry-run=client -o yaml | "${K[@]}" apply -f - >&2
"${K[@]}" -n "$NS" create configmap aigw-private-hosts-mock --from-file=server.py --dry-run=client -o yaml | "${K[@]}" apply -f - >&2
for c in $CELLS; do sed -e "s/__CELL__/$c/g" -e "s/__NS__/$NS/g" k8s/cell.yaml | "${K[@]}" apply -f - >&2; done
for c in $CELLS; do "${K[@]}" -n "$NS" rollout status "deploy/mock-$c" --timeout=180s >&2; done

region=$("${K[@]}" get nodes -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/region}')
provider=$("${K[@]}" get nodes -o jsonpath='{.items[0].spec.providerID}'); provider=${provider%%://*}
[ "$provider" = aws ] || echo "deploy.sh: provider '$provider' is not aws; skipping the vpc-dns form (AKS/GKE: see README Future work)" >&2
for c in $CELLS; do
  svc_ip=$("${K[@]}" -n "$NS" get svc "mock-$c" -o jsonpath='{.spec.clusterIP}')
  pod_ip=$("${K[@]}" -n "$NS" get pod -l "cell=$c" -o jsonpath='{.items[0].status.podIP}')
  vpc_dns="ip-${pod_ip//./-}.$region.compute.internal"; [ "$region" = us-east-1 ] && vpc_dns="ip-${pod_ip//./-}.ec2.internal"
  printf '%s\t%s\t%s\t%s\n' \
    "$c" svc-ip "http://$svc_ip/v1" "$svc_ip" \
    "$c" svc-fqdn "http://mock-$c.$NS.svc.cluster.local/v1" "mock-$c.$NS.svc.cluster.local" \
    "$c" svc-short "http://mock-$c.$NS.svc/v1" "mock-$c.$NS.svc" \
    "$c" svc-ns "http://mock-$c.$NS/v1" "mock-$c.$NS" \
    "$c" pod-ip "http://$pod_ip:8080/v1" "$pod_ip"
  if [ "$provider" = aws ]; then printf '%s\t%s\t%s\t%s\n' "$c" vpc-dns "http://$vpc_dns:8080/v1" "$vpc_dns"; fi
done
