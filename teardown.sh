#!/usr/bin/env bash
# teardown.sh — delete the mock namespace and everything in it.   KCTX=<context> [NS=aigw-mock] bash teardown.sh
set -euo pipefail
: "${KCTX:?set KCTX to the kube context}"
kubectl --context "$KCTX" delete namespace "${NS:-aigw-mock}" --wait=true
