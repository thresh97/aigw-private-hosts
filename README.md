# aigw-private-hosts

Test which private hosts a hybrid Prisma AIRS AI Gateway will save and call, given its SSRF protection.

> **Not official. Not a product. No support. Use at your own risk.** A personal lab test tool, not affiliated with or
> endorsed by Palo Alto Networks or Portkey. MIT licensed; see [LICENSE](LICENSE).

## What is this?

A small test kit for the AI Gateway's SSRF protection. It shows which private (internal) LLM endpoints a hybrid
Prisma AIRS AI Gateway will actually connect to, and which of its two trust lists controls that:

- **The SCM org allowlist** ("private egress URLs"): set in Strata Cloud Manager, or through
  `GET/POST /ai_gw/admin/v2/egress-allowlist` and `DELETE …/{id}` on `api.apps.paloaltonetworks.com`.
- **The gateway env var `TRUSTED_CUSTOM_HOSTS`**: set on the hybrid gateway (data plane) deployment. Documented in
  [Custom hosts → Trusted custom hosts (allowlist)](https://portkey.ai/docs/product/ai-gateway/custom-hosts#trusted-custom-hosts-allowlist).

Background: [Custom hosts](https://portkey.ai/docs/product/ai-gateway/custom-hosts) covers how the gateway validates custom host URLs, what is blocked, and which
blocks can't be overridden. At the time of testing it doesn't mention the SCM org allowlist.

It deploys a mock LLM into the gateway's Kubernetes cluster, creates AI Gateway integrations that point at it by
every kind of private address (IP, cluster DNS, VPC DNS), and calls each one through the gateway. The mock's reply
names the address the gateway dialled, so every result is observed, not inferred.

## Why?

The SCM allowlist is new and lightly documented, and the gateway still has its own trust list. It isn't obvious which
one does what, so this kit tests every combination:

- Which custom hosts can be **saved** in an integration, with and without an SCM entry?
- Which ones does the gateway **call**, with and without a `TRUSTED_CUSTOM_HOSTS` entry?
- Which private address forms never work, whatever you configure?

## Summary

Tested on gateway 2.26.0 (2026-10-06) and 2.27.0 (2026-10-09), in two lab tenants; behaviour may change in later releases. Details are in
[Findings](#findings).

| | SCM org allowlist | `TRUSTED_CUSTOM_HOSTS` env var |
|---|---|---|
| **Where it's set** | SCM UI or the egress-allowlist API (per org) | Gateway deployment, e.g. Helm values (per gateway); needs a redeploy |
| **What it affects** | Whether an integration with a private custom host can be **saved** (or its base URL edited) | Whether the gateway will **call** a private custom host |
| **When it's checked** | Save time, in the control plane | Every request, in the gateway |
| **Effect on calls** | None: adding or removing entries doesn't change what the gateway calls | Decides it, apart from a built-in denylist |
| **Entry format** | One host per entry: exact host, IP literal or `*.wildcard` (no CIDR, port or scheme) | Comma-separated: exact hosts, IPs and `*.wildcards` |

In practice:

| To use a private… | SCM allowlist | `TRUSTED_CUSTOM_HOSTS` |
|---|---|---|
| IP address (pod, ClusterIP, VPC) | **required** (to save) | **required** (to call) |
| In-cluster service as `<svc>.<ns>.svc` or `<svc>.<ns>` | not needed | **required** |
| Private DNS name outside the gateway denylist (e.g. `.corp`, `.lan`) | **required** (to save) | **required** (to call)¹ |
| `*.svc.cluster.local`, `*.compute.internal`, `*.ec2.internal` | `cluster.local` saves without an entry; the others need one | **never works**: the gateway refuses these even when trusted |
| Public host | not needed | not needed |

¹ With an env entry, the gateway passed its trust check for `.corp`, `.lan` and `.internal` names but stopped at DNS
lookup (the test names don't exist), so no request was actually delivered for this row.

## What you need

- A Kubernetes cluster running the hybrid gateway, and a kube context that can create a namespace in it. Tested on
  EKS; on other clusters the AWS-only `vpc-dns` form is skipped (see [Future work](#future-work)).
- Access to change the gateway's `TRUSTED_CUSTOM_HOSTS` and redeploy it (step 5).
- [`airs-cli`](https://github.com/cdot65/prisma-airs-cli) (`npm i -g @cdot65/prisma-airs-cli`) and a tenant config
  JSON for an SCM service account (`mgmtClientId`, `mgmtClientSecret`, `mgmtTsgId`) that can manage AI Gateway
  integrations and the egress allowlist.
- A workspace, and a gateway API key or JWT for that workspace.
- `bash`, `curl`, `jq`.

Script variables:

| Variable | Used by | Required | Meaning |
|---|---|---|---|
| `KCTX` | `deploy.sh`, `teardown.sh` | yes | kube context of the gateway's cluster |
| `NS` | `deploy.sh`, `teardown.sh` | no (`aigw-mock`) | namespace for the mock |
| `CELLS` | `deploy.sh` | no (`none scm env both`) | which cells to deploy |
| `MGMT_CREDS_FILE` | `matrix.sh` | yes | path to the airs-cli tenant config JSON |
| `WS_ID` | `matrix.sh save` | yes | workspace UUID to bind the test integrations to |
| `TAG` | `matrix.sh` | no (`aigw-private-hosts`) | description put on allowlist entries; `scm-del` deletes only these |
| `PUBLIC_URL` | `matrix.sh save` | no (`https://httpbin.org/anything`) | public control endpoint |
| `GW_URL` | `probe.sh` | yes | gateway base URL, e.g. `https://<gateway>` |
| `GW_KEY` | `probe.sh` | yes | gateway API key or JWT for `WS_ID`'s workspace |

## Design

Four cells, each a one-pod Deployment plus a Service, in their own namespace (`aigw-mock`). The namespace must not be
covered by an existing env-var wildcard, such as one for the gateway's own namespace
(`*.<gateway-namespace>.svc.cluster.local`).

| Cell | SCM list | Env var |
|---|---|---|
| `none` | – | – |
| `scm` | ✓ | – |
| `env` | – | ✓ |
| `both` | ✓ | ✓ |

Every cell can be reached six ways, giving six host forms:

| Form | URL |
|---|---|
| `svc-ip` | `http://<ClusterIP>/v1` |
| `svc-fqdn` | `http://mock-<cell>.aigw-mock.svc.cluster.local/v1` |
| `svc-short` | `http://mock-<cell>.aigw-mock.svc/v1` |
| `svc-ns` | `http://mock-<cell>.aigw-mock/v1` (resolved through the gateway pod's DNS search path) |
| `pod-ip` | `http://<pod IP>:8080/v1` |
| `vpc-dns` | `http://ip-a-b-c-d.<region>.compute.internal:8080/v1` (AWS private DNS; `ip-a-b-c-d.ec2.internal` in us-east-1; AWS only) |

The mock listens on 8080 (Service port 80). Both ports are outside the gateway's
[blocked ports](https://portkey.ai/docs/product/ai-gateway/custom-hosts#blocked-ports), which apply even to trusted hosts.

Because each cell has its own addresses, a single gateway env-var state covers all four trust states. A public control
(`tth-public`, `https://httpbin.org/anything` by default) shows that the check only applies to private targets.

Each test target is a saved integration (`tth-<cell>-<form>`) bound to a workspace as a default provider. The probe calls
it as model `@<slug>/gpt-4o`. Saved integrations are used rather than the `x-portkey-custom-host` header because orgs
can block inline config, and because saving is where the SCM list is checked.

The mock (`server.py`, stdlib only) answers OpenAI `…/chat/completions` and Anthropic `…/messages`. Its reply text is
`mock cell=<cell> host=<Host>`, so the gateway's response shows which address it dialled. It logs one JSON line per
request, with header values masked; read them with `kubectl logs -n aigw-mock -l app=aigw-private-hosts-mock`.

## Run

| Step | Where | Command |
|---|---|---|
| 1. Deploy the mock | kubectl host | `KCTX=<ctx> bash deploy.sh > hosts.tsv` |
| 2. Add the SCM entries | airs-cli host | `MGMT_CREDS_FILE=<tenant json> bash matrix.sh scm-add hosts.tsv` |
| 3. Save the integrations | airs-cli host | `MGMT_CREDS_FILE=… WS_ID=<workspace uuid> bash matrix.sh save hosts.tsv > results/saved.tsv` |
| 4. Probe, env var unchanged | gateway client | `GW_URL=https://<gateway> GW_KEY=<key or JWT> bash probe.sh results/saved.tsv before-env >> results/probe.tsv` |
| 5. Add the env-var hosts | gateway deploy | `bash matrix.sh env hosts.tsv \| tee results/env.txt`, append that to `TRUSTED_CUSTOM_HOSTS` and redeploy the gateway. If you change the env var again later, save each value the same way (`results/env2.txt`, …) |
| 6. Probe again | gateway client | `… bash probe.sh results/saved.tsv after-env >> results/probe.tsv` |
| 7. Optional: remove the SCM entries, probe and edit again | both | `matrix.sh scm-del`, then `probe.sh … after-scm-del` and `matrix.sh edit > results/edit.tsv` |
| 8. Clean up | all | revert the env var and redeploy; `matrix.sh scm-del`; `matrix.sh cleanup`; `KCTX=<ctx> bash teardown.sh` |

The `matrix.sh save` output records whether SCM accepted each custom host, and the reason when it refused. In `probe.sh`
output, each row is `reached` (the mock answered), `refused` (the gateway returned "Invalid custom host") or `error`
(for example the gateway's DNS-rebinding block, or a name that doesn't resolve). `matrix.sh edit` output has one row
per integration and edit kind (`description`, or `base-url` re-set to the same URL): `ok`, or `refused` with the reason.

`matrix.sh` tags everything it creates: allowlist entries get the description `aigw-private-hosts` and integrations get
the `tth-` slug prefix. `scm-del` and `cleanup` delete only tagged objects.

Pod IPs change if a pod restarts, so keep the mock pods up between steps 1 and 8. The mock costs almost nothing to run:
four pods at 10m CPU / 32Mi each.

`hosts*.tsv` and `results/` hold tenant addresses and are gitignored.

The allowlist `GET` returns 20 entries per page by default. Pass `?page_size=100` (the largest value it accepts) to see
them all.

## Findings

Tested 2026-10-06 against gateway 2.26.0 and 2026-10-09 against 2.27.0, on EKS in two lab tenants, with the same
results. Everything below was observed through the API and the probe, except where marked *(image inspection)* or
*(2.26.0 only)*.

The control plane checks the SCM list when an integration is saved. The gateway checks only `TRUSTED_CUSTOM_HOSTS`,
when it is called. *(image inspection)* The bundled code in the 2.26.0 and 2.27.0 gateway images has no reference to
the egress allowlist; `TRUSTED_CUSTOM_HOSTS` is its only custom-host trust setting.

**Saving an integration (SCM control plane)**

| Custom host | Without an SCM entry | With an SCM entry |
|---|---|---|
| Public hostname or public IP | saved | – |
| Private IP (ClusterIP, pod IP), `127.0.0.1` | refused (AB01) | saved (exact IP only; a neighbouring IP is still refused) |
| `*.svc`, `*.svc.cluster.local`, `<svc>.<ns>` | saved | – |
| `*.compute.internal`, `*.ec2.internal`, other `.internal`, `.corp`, `.lan`, `localhost` | refused (AB01) | saved (exact or `*.` wildcard; `*.example.corp` also matched `example.corp`) |
| Edit the base URL of a saved private-IP integration (even unchanged) after its SCM entry is removed | refused (AB01) | – |
| Edit only the description of that integration | allowed | – |

What the SCM list itself accepts:
- Accepted: exact hosts, IP literals and `*.` wildcards, including very broad ones like `*.com` and `*.internal`.
- Refused: comma lists, CIDRs, a port (`host:port`), a scheme or URL, a bare `*`, `169.254.169.254`, `metadata.google.internal` and a `nip.io` name.

**Calling the integration (gateway)**

| Custom host | Not in env | In env |
|---|---|---|
| Public host | reached | – |
| Private IP | refused, "Invalid custom host" | **reached**, but only if SCM let it be saved first. Removing the SCM entry later doesn't affect calls. |
| `<svc>.<ns>.svc`, `<svc>.<ns>` | refused (DNS-rebinding block) | **reached** (exact entry) |
| `*.svc.cluster.local`, `*.compute.internal` | refused | **still refused**, with exact or wildcard entries |
| `*.ec2.internal` | refused | **still refused**, with a wildcard entry |
| Other private names (`.corp`, `.lan`, other `.internal`) | refused | passes the gateway check (the env wildcard works; the test names don't resolve) |
| `localhost`, `127.0.0.1` | refused | passes the gateway check, and the gateway connects to **its own** loopback (inside the gateway pod) |
| SCM entry only, any form | refused | – |

The "still refused" rows match the documented [blocked hostname suffixes](https://portkey.ai/docs/product/ai-gateway/custom-hosts#blocked-hostname-suffixes), which
include `cluster.local`, `compute.internal` and `ec2.internal` and "run **before** the trusted-host allowlist and cannot
be overridden". *(image inspection)* 2.27.0 has the same list. The other results also match the
[custom hosts docs](https://portkey.ai/docs/product/ai-gateway/custom-hosts):
- private IPs and internal TLDs (`.internal`, `.corp`, `.lan`) are blocked unless trusted;
- nip.io-style names and IMDS are always blocked.

The docs don't cover the SCM allowlist or the save-time check.

What this means:
- **Private IPs need both lists:** the SCM list so the integration can be saved, and `TRUSTED_CUSTOM_HOSTS` so the gateway will call it.
- **Use a name the gateway can trust.** In-cluster LLM upstreams should be addressed as `<svc>.<ns>.svc` or `<svc>.<ns>`, not `.svc.cluster.local`. Both save without an SCM entry and need only an env entry.
- **SCM accepts integrations that can never work.** It saves `.svc.cluster.local` hosts with no list entry, and `*.compute.internal` hosts once listed, but the gateway always refuses them.
- **Don't trust loopback.** `127.0.0.1` or `localhost` in `TRUSTED_CUSTOM_HOSTS` (plus an SCM entry) lets an integration reach whatever listens on the gateway pod's own loopback.
- **MCP is different.** *(2.26.0 only)* In the same deployment, MCP servers on `*.<gateway-namespace>.svc.cluster.local` work through the gateway's MCP endpoint with an env wildcard, so this denylist doesn't apply to the MCP path. Not tested further here.

## Future work

**AKS and GKE.** The kit itself is plain Kubernetes, but it has only been run on EKS. To cover the other two:

- **Cloud private-DNS form.** On AKS and GKE, pods have no per-pod VPC DNS name. The private DNS names belong to nodes
  (VMs), so a node-DNS form would replace `vpc-dns`:
  - AKS: `<vm>.internal.cloudapp.net`. `internal.cloudapp.net` is a documented
    [blocked hostname suffix](https://portkey.ai/docs/product/ai-gateway/custom-hosts#blocked-hostname-suffixes), so this is expected to be refused even when trusted.
  - GKE: `<vm>.<zone>.c.<project>.internal`. Only GCP's metadata names are blocked suffixes. Other `.internal` names
    fall under the [blocked internal TLDs](https://portkey.ai/docs/product/ai-gateway/custom-hosts#blocked-internal-tlds), which a `TRUSTED_CUSTOM_HOSTS` entry overrides,
    so this is expected to work with an env entry.

  The node would need to run something listening on a test port, for example a `hostPort` on the mock pod.
- **Pod IPs.** AKS with kubenet or CNI overlay gives pods overlay addresses (e.g. 10.244.x), not VNet addresses. They
  are still private, so the IP rows should behave the same, but this is unverified.
- **Cluster defaults that can hide results:**
  - default-deny NetworkPolicy (Calico, Cilium or Azure NPM) between the gateway and `aigw-mock`;
  - no Docker Hub access for the mock image (use a mirror);
  - GKE Autopilot raising resource requests (harmless).
