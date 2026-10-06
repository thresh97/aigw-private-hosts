# AGENTS.md

Guidance for coding agents running or changing this repo. Read README.md first: it explains what the kit tests and the
run order. Gateway-side validation rules are documented in
[Custom hosts](https://portkey.ai/docs/product/ai-gateway/custom-hosts).

## What running this touches

- **Kubernetes:** one namespace (`$NS`, default `aigw-mock`) in the gateway's cluster. `teardown.sh` deletes that
  namespace, so check that `NS` isn't a namespace anything else uses.
- **SCM tenant:**
  - org egress-allowlist entries, tagged with description `$TAG` (default `aigw-private-hosts`);
  - AI Gateway integrations with the `tth-` slug prefix, bound to `$WS_ID`.
- **Gateway:** step 5 changes `TRUSTED_CUSTOM_HOSTS` and redeploys the hybrid gateway. That's a change to a shared
  data plane, so get the operator's go-ahead first and revert it at cleanup.

## Rules

- **Secrets.**
  - Never print, log or commit the SCM client secret, bearer tokens, gateway keys or JWTs.
  - Keep tokens in shell variables.
  - The airs-cli tenant JSON (`MGMT_CREDS_FILE`) stays outside the repo.
- **Tenant data stays out of git.** `hosts*.tsv` and `results/` hold cluster IPs, hostnames and tenant results; they
  are gitignored. Don't add tenant IDs, workspace or org UUIDs, account numbers, gateway URLs or real IPs to tracked
  files. Use placeholders (`<gateway>`, `<workspace uuid>`).
- **Only touch tagged objects.**
  - `matrix.sh scm-del` deletes allowlist entries whose description is exactly `$TAG`.
  - `matrix.sh cleanup` deletes integrations whose slug starts with `tth-`.
  - Never delete untagged allowlist entries or other integrations. Other people's entries may be in the same org.
- **The allowlist API pages at 20 entries.** List it with `?page_size=100` (the largest value accepted), or you'll miss
  entries.
- **Keep the mock pods up for the whole run.** The pod-IP and VPC-DNS rows go stale if a pod restarts. If one does,
  re-run `deploy.sh`, `scm-add` and `save`.
- **Report what you observe.** A result is `reached` only if the mock's `mock cell=… host=…` reply came back. If a
  claim comes from reading gateway code, not from a probe, say so (the README marks these *image inspection*).

## Cleanup (always finish with this)

1. Revert `TRUSTED_CUSTOM_HOSTS` and redeploy the gateway.
2. `MGMT_CREDS_FILE=… bash matrix.sh scm-del`
3. `MGMT_CREDS_FILE=… bash matrix.sh cleanup`
4. `KCTX=<ctx> bash teardown.sh`

## Changing the code

- Shell scripts are bash with `set -euo pipefail`; `server.py` is stdlib-only Python. Keep it that way: no new
  dependencies.
- New host forms go in `deploy.sh` (one `cell form url host` row each) and in the README's form table.
- If you rerun the matrix against a new gateway version, add the version and date to the README's Findings section,
  not over the old results.
