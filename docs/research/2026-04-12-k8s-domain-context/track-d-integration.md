# Track D — Integration + multi-cluster design

## TL;DR

- **Per-cluster indexer, central vector DB.** Each OKE cluster runs a read-only Go informer that streams change events to a regional Redis stream; a central embedder fleet consumes, embeds, and upserts into a shared vector store with `cluster` as a mandatory label. Simpler tenancy, single query path, cheap federation.
- **Domain v1 = the stuff DevOps asks about daily**: core workloads (Deployment / StatefulSet / DaemonSet / Pod summary), Service / Ingress, ConfigMap (redacted), ArgoCD `Application`, Helm release metadata, SealedSecret status, Namespace. Argo Rollouts, NodePools, BlockVolumes, external-dns records deferred to v1.1.
- **Two-layer query surface**: semantic (`k8s_semantic_query`) for fuzzy discovery, authoritative (`k8s_get_object`, `k8s_list`) for live reads that bypass the index. Agent is trained to use live reads before any write-producing action (PR, rollout).
- **Sync lag target**: p50 < 5 s, p99 < 30 s from kube API event to vector upsert. Full periodic resync every 30 min.
- **Network topology**: indexer runs *inside* each cluster (avoids the private-endpoint problem entirely); only outbound TLS to the central Redis + vector DB is needed. MCP server is a new pod in the existing `agents-platform` namespace on the prod cluster, reachable by the Managed Agent session over a public ingress with mTLS.
- **Lives in agents-platform chart** as a new subchart `k8s-context-indexer` + `k8s-context-mcp`; indexers get their own ArgoCD app per cluster so non-prod clusters can adopt independently.
- **Back-pressure rule**: when the embedder queue > N or last successful upsert > 2 min old, the MCP server stamps every semantic result with `stale=true` and the agent's system prompt tells it to fall back to authoritative tools.

## Scope of "domain" (v1 / later)

**v1 — must ship:**

| Resource | Why |
|---|---|
| Deployment, StatefulSet, DaemonSet, CronJob | "where does X run", "what version" |
| Service, Ingress | "who owns stapp.me" |
| ConfigMap (metadata + key names, **no values by default**) | join target for Deployments |
| Namespace | tenancy boundary |
| ArgoCD `Application`, `ApplicationSet` | repo ↔ cluster mapping comes free |
| Helm release (via `helm list -Ao json` shipped as synthetic docs) | version & chart origin |
| SealedSecret (metadata, sealed-status only) | "did the secret sync" is a top question |

**v1.1 — fast follow:**

- Argo Rollouts (`Rollout`, `AnalysisRun`) — needed once canary adoption widens
- HPA, PDB, ServiceMonitor — low churn, useful for incident response
- external-dns annotations → DNS record synthetic docs (authoritative DNS source is elsewhere; we index what's *declared*, not what's resolved)

**Later / not indexed:**

- Secret bodies — never. Names only.
- Node, NodePool, BlockVolume — OCI state belongs to a separate OCI MCP (already exists: `oracle-oci-api-mcp-server`)
- Pod-level events / logs — volume too high; use `kubectl logs` via a separate tool
- CRDs we don't own — opt-in list per cluster

## End-to-end architecture

```
 ┌──────────────────────── OKE cluster A (prod, private API) ─────────────────────────┐
 │                                                                                    │
 │  ┌──────────────────┐   watch       ┌─────────────────┐    redact +                │
 │  │ kube-apiserver   │ ◀──────────── │ k8s-context-    │    serialize               │
 │  │                  │               │  indexer (SA:   │──────────────┐             │
 │  └──────────────────┘               │  ro, all ns)    │              │             │
 │                                     └─────────────────┘              │             │
 │                                                                      ▼             │
 │                                                           ┌────────────────────┐   │
 │                                                           │  outbound TLS only │   │
 │                                                           └─────────┬──────────┘   │
 └─────────────────────────────────────────────────────────────────────┼──────────────┘
                                                                       │
 ┌──────────────── OKE cluster B (staging) ──────┐                     │
 │   k8s-context-indexer (same image, diff SA)   │────outbound TLS─────┤
 └───────────────────────────────────────────────┘                     │
                                                                       ▼
 ┌────────────────── agents-platform cluster (prod) ─────────────────────────────────┐
 │                                                                                   │
 │     ┌─────────────────┐     XADD     ┌────────────────┐   upsert   ┌───────────┐  │
 │     │ Redis Streams   │ ◀──────────  │ embedder pool  │──────────▶│ vector DB │  │
 │     │ (change events) │              │ (claude-sdk    │            │ (pgvector │  │
 │     │ per-cluster key │──── XREAD ──▶│  workers)      │            │ or Qdrant │  │
 │     └─────────────────┘              └────────────────┘            │ Track C)  │  │
 │                                                                    └─────┬─────┘  │
 │                                                                          │        │
 │                                   ┌──────────────────┐     queries       │        │
 │  Managed Agent session ──mTLS───▶ │ k8s-context-mcp  │ ──────────────────┘        │
 │  (attaches via mcp-config)        │  FastAPI + SSE   │                            │
 │                                   │  tool endpoints  │──── kubectl proxy ──┐      │
 │                                   └──────────────────┘  (for authoritative │      │
 │                                            │             live reads)       │      │
 │                                            └───────────────────────────────┘      │
 │                                                                                   │
 └───────────────────────────────────────────────────────────────────────────────────┘
```

## Sync pipeline (per cluster)

1. **Informer process** (Go, client-go shared informer factory). One process per cluster, watches the v1 resource list above via `metadata.k8s.io/v1` and typed clients for CRDs. Informers coalesce resync storms — we publish only on genuine resource-version change.
2. **Redaction step** before publish: strip `.data` from ConfigMaps (keep key names), strip everything but `.status` and object metadata from SealedSecrets, strip `.spec.template.spec.containers[].env` values that look secret-ish (regex against key name — `*_KEY`, `*_TOKEN`, `*_PASSWORD`). Paranoid but cheap.
3. **Publish** as a single JSON event to `k8s:events:{cluster}` Redis stream. Event shape: `{cluster, kind, apiVersion, namespace, name, resourceVersion, op: add|update|delete, doc: <redacted>}`. Stream MAXLEN ~500k.
4. **Embedder workers** are `claude-agent-sdk` consumers (we already run that pool for the main agent platform — same pattern, different queue). Each worker:
   - Reads a batch
   - Computes a canonical text representation (`kind/namespace/name + key labels + summary fields`) — embedding input is stable so update churn doesn't churn vectors
   - Upserts to vector DB keyed by `(cluster, uid)`; `resourceVersion` stored as metadata
5. **Periodic full resync**: every 30 min the indexer does a `List` for each kind and emits synthetic "reconcile" events — the embedder dedupes on `resourceVersion`. Catches missed events after informer disconnects.
6. **Target lag**: event→upsert p50 < 5 s, p99 < 30 s. Watch→embed is the hot path; only the embedder model call is variable.

## Multi-cluster federation — decision

**Chosen: Option 1 — one indexer *inside* each cluster, one central vector DB, `cluster` label on every document.**

Rationale:

- **No VPN / private endpoint problem.** Prod's kube API at `172.26.67.152:6443` is private. If the indexer lived centrally (Option 2) we'd need a bastion or to expose the API — both bad. In-cluster indexer needs only *outbound* TLS, which every cluster already has.
- **One query path.** Option 3 (federated vector stores + query proxy) multiplies failure modes: each cluster needs its own DB, scatter-gather on query, and ranking across shards is ugly. A single pgvector or Qdrant with a `cluster` filter on every index trivially supports "which cluster runs foo" in one query.
- **Tenancy via labels** — adding a cluster = deploy the indexer chart + it starts streaming. Removing = scale to zero + bulk delete by `cluster` label.
- **Cost** — one DB, one embedder pool. The write volume from 3 clusters (~50k objects each, update rate bounded by informer coalescing) is well inside a single pgvector instance.

Cons we accept: central DB is a single failure domain (mitigated: agent falls back to authoritative `k8s_get_object` / `k8s_list` when MCP reports `stale=true`), and the central embedder is a choke point (mitigated: HPA on queue depth).

## MCP surface

Served by a FastAPI service `k8s-context-mcp` exposing MCP over SSE (same transport mcp-atlassian uses). Tools in v1:

- **`k8s_semantic_query(query, cluster?, kind?, namespace?, limit=10) -> [{cluster, kind, namespace, name, score, snippet, resourceVersion, stale}]`** — the workhorse. Vector search with filters pushed down to the DB. Always returns `stale` flag.
- **`k8s_get_object(cluster, kind, namespace, name) -> {full redacted object}`** — authoritative live read via the indexer's kubeconfig (or a thin proxy). Bypasses vector store. Used before any write-producing action.
- **`k8s_list(cluster, kind, namespace?, label_selector?) -> [{name, namespace, labels}]`** — authoritative `kubectl get` equivalent, paginated. Used when the agent needs a complete enumeration (e.g. "list all Ingresses in cluster X").

v1.1 nice-to-have:

- **`k8s_relations(cluster, kind, ns, name) -> {owners, owned, depends_on, argocd_app, helm_release, github_repo}`** — derived join. Lands once we're confident in ArgoCD / Helm synthetic docs.
- **`k8s_diff_vs_git(argocd_app) -> {...}`** — "what's drifted" — thin wrapper over ArgoCD's own diff, but surfaced as a tool.

Agent attaches via `--mcp-config .mcp-kubernetes.json --strict-mcp-config` with a single entry pointing at `https://agents.internal.start.io/k8s-context/mcp`.

## Security + networking

- **Indexer ServiceAccount per cluster**: `ClusterRole` with `get,list,watch` on the v1 resource list. No `secrets.core` verbs. Separate SA per indexer instance; bound via `ClusterRoleBinding` in that cluster only.
- **Outbound auth**: indexer reads a Redis password from a SealedSecret in its own namespace; vector DB creds live only on the central embedder, not the indexer, so a compromised cluster can't corrupt the index (it can only poison its own stream, which the embedder can quarantine by cluster label).
- **MCP server → vector DB**: in-cluster service DNS + password from SealedSecret.
- **Agent → MCP server**: mTLS. The Managed Agent session presents a client cert issued by our internal CA; MCP server verifies + checks the cert's subject against an allowlist. Same pattern mcp-atlassian uses today.
- **Private API**: handled by putting the indexer inside the cluster — agent never needs to reach `172.26.67.152` directly.

## Failure modes

- **Informer falls behind / etcd compaction**: client-go returns `410 Gone`; informer relists automatically. The 30-min synthetic-resync pass covers any gap larger than the informer's own recovery. Metric: `informer_last_successful_sync_seconds`.
- **Vector DB down**: embedder backs off, stream grows (bounded by MAXLEN). MCP server's `/healthz` probes the DB and, on failure, sets a process-wide `stale_since` timestamp; every `k8s_semantic_query` response includes `stale=true` and a header telling the agent to prefer authoritative tools. If `stale_since > 15 min`, semantic queries return 503 to force the fallback.
- **Embedder lag**: HPA scales on `redis_stream_pending > 5000`. If still climbing, circuit-breaks to "metadata-only" mode (skip embedding, index keyword-only) so at least filter queries work.
- **Cluster added**: deploy the indexer chart to that cluster, register its name in the MCP server's known-cluster list (ConfigMap), done. Backfill kicks off on first connect.
- **Cluster removed**: scale indexer to zero, run a one-shot job to `DELETE FROM vectors WHERE cluster='X'`.

## Relationship to agents-platform

- **Indexer**: new subchart `charts/k8s-context-indexer` in `startappdev/helm`. One ArgoCD `Application` per cluster under `ash-cni-devops-apps/k8s-context-indexer-{cluster}.yaml`. Non-prod clusters can onboard independently.
- **Embedder + MCP server**: live in the existing `agents-platform` namespace on prod. Same Redis instance (new stream keys), same observability stack, same SealedSecret conventions. Reuses the claude-agent-sdk worker pattern — `docker-shipit-worker` image gets a new `ROLE=k8s-embedder` path.
- **Vector DB**: new stateful component (pgvector most likely — Track C decides). Added to the `agents-platform` chart as an optional dependency so dev envs can skip it.

No new cluster. Respects the MEMORY.md rule: all changes flow through `agents-platform` / `helm` / `argo-cd` PRs. No direct `kubectl apply`.

## Open questions

1. **Do we index ConfigMap *values* at all?** Useful for "find the configmap that mentions kafka-prod" but leaks config accidentally. Default no; opt-in per-namespace annotation (`agents.start.io/index-values=true`).
2. **Helm release source**: shell out to `helm list -Ao json` from inside the indexer, or read Helm's own secret-backed release objects (kind: `Secret`, type `helm.sh/release.v1`, and we skip Secret bodies…)? Secret-based needs a narrow RBAC exception.
3. **MCP server — one process or one per cluster?** One central process is simpler and matches Option 1. If blast radius becomes a concern, we shard *later* by cluster label.
4. **Freshness SLO for production changes**: is 30 s p99 good enough for the "did my deploy land" question, or do we want < 5 s (would require pushing authoritative lookups to the front of every such query — doable, design supports it)?
5. **ArgoCD `Application` already knows the source repo — do we still need a separate GitHub↔cluster synthetic doc layer?** Probably no for v1; ArgoCD is the source of truth.

---

## Summary (~200 words)

**Federation decision.** One read-only informer inside each OKE cluster, streaming redacted change events outbound over TLS to a shared Redis stream on the agents-platform cluster; a central embedder pool upserts into a single vector store with a mandatory `cluster` label on every document. This sidesteps the private-API-endpoint problem entirely (no VPN, no bastion), gives us a single query path (one filter pushdown, no scatter-gather), and makes onboarding a cluster a pure GitOps action — new `Application` in `startappdev/argo-cd`, indexer spins up, backfill happens automatically. The central DB is a single failure domain, but back-pressure signalling plus authoritative fallback tools make degradation graceful rather than fatal.

**MCP surface.** Two layers. `k8s_semantic_query` is the default — vector search with cluster / kind / namespace filters, always returning a `stale` flag so the agent can decide whether to trust it. `k8s_get_object` and `k8s_list` hit the live kube API through the indexer's kubeconfig and are the authoritative path for anything that precedes a write (PR, rollout, approval). `k8s_relations` lands in v1.1 once ArgoCD and Helm synthetic docs stabilize. The agent attaches via `--mcp-config .mcp-kubernetes.json --strict-mcp-config`, one endpoint, mTLS.
