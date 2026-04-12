# K8s Domain Context for ShipIt — Research Summary

Research date: 2026-04-12. Four parallel tracks completed. Full reports:
- [Track A — dot-ai deep dive](track-a-dot-ai.md)
- [Track B — Alternatives landscape](track-b-landscape.md)
- [Track C — Vector store + embedding choice](track-c-vector-store.md)
- [Track D — Integration + multi-cluster design](track-d-integration.md)

**Note:** Track C recommended Voyage AI `voyage-3.5` for embeddings. That was reconsidered after review (vendor risk after MongoDB acquisition, aggressive model deprecation cadence, benchmark mismatch for short K8s-metadata docs). Final decision in this SUMMARY: **OpenAI `text-embedding-3-small` direct** for stability, low-churn, and proven 2-year track record with no deprecations pending.

## TL;DR

- **Build it, don't buy it.** The only OSS project matching the target architecture (informers → vector DB → MCP) is `vfarcic/dot-ai` — it's `status: beta`, single-maintainer, single-cluster-only, and its default RBAC is cluster-admin. We adopt its *shape* but not the dependency.
- **Two-phase path.** **Phase 0 (days):** drop in `containers/kubernetes-mcp-server` (Red Hat, Apache-2.0, multi-cluster native via kubeconfig contexts) so ShipIt gets live cluster reads *today* with zero custom code. **Phase 1 (~2–3 weeks):** ship a lean, Start.io-specific indexer + Qdrant + MCP service per the Track D design.
- **Vector DB: Qdrant self-hosted** on OKE prod (1.15+, 3-replica StatefulSet, hybrid search). **Embeddings: OpenAI `text-embedding-3-small` direct** (Anthropic has no first-party embedding model as of April 2026). 1536-dim default; benchmark 768-dim via the `dimensions` param in Phase 1. $0.02/M real-time, $0.01/M batch. NL-derived summaries per object, K8s metadata as payload. **Cost OOM: ~$25–30/mo** (Qdrant pod dominates; embeddings <$1/mo).
- **Federation: per-cluster in-cluster indexer + central DB with `cluster` label.** Sidesteps the private-endpoint / VPN problem entirely (indexer is already inside the cluster; only outbound TLS needed). Single query path across clusters. Adding a cluster = one ArgoCD app.
- **Freshness target: p50 < 5 s, p99 < 30 s** event → vector upsert, with a 30-min synthetic full-resync. Graceful degradation via `stale=true` flag + authoritative `k8s_get_object` / `k8s_list` fallback.
- **Scope v1:** Deployments/StatefulSets/DaemonSets/CronJobs, Services/Ingress, ConfigMaps (names only — no values by default), Namespaces, ArgoCD `Application` + `ApplicationSet`, Helm releases (metadata), SealedSecrets (status only). Argo Rollouts, HPA/PDB, external-dns → v1.1.

## Recommended architecture

```
 ┌──── OKE A (prod, private API) ────┐   ┌──── OKE B (staging) ────┐   ┌──── OKE C ────┐
 │  k8s-context-indexer (RO SA)      │   │  indexer                │   │  indexer      │
 │    ↓ redact + serialize           │   │    ↓                    │   │    ↓          │
 │    ↓ outbound TLS                 │   │    ↓ outbound TLS       │   │    ↓          │
 └───────┬───────────────────────────┘   └──────┬──────────────────┘   └──────┬────────┘
         └──────────────────────────────────────┴─────────────────────────────┘
                                                │
                                                ▼
 ┌─────────────────── agents-platform namespace (OKE prod) ────────────────────┐
 │                                                                             │
 │   Redis Streams ──▶ embedder pool ──(Voyage)──▶ Qdrant (NL summaries +      │
 │   per-cluster key                              │   metadata payload,        │
 │                                                │   cluster label)           │
 │                                                └──────▲────────────┬───────┘
 │                                                       │ query      │        │
 │   Managed Agent session ─mTLS─▶ k8s-context-mcp ──────┘            │        │
 │    (--mcp-config .mcp-kubernetes.json)    │                        │        │
 │                                           └── live kubectl proxy ──┘        │
 │                                              (authoritative reads)          │
 └─────────────────────────────────────────────────────────────────────────────┘
```

## MCP surface (v1)

Single endpoint, one entry in `.mcp-kubernetes.json`:

| Tool | Purpose | Data path |
|---|---|---|
| `k8s_semantic_query(query, cluster?, kind?, namespace?, limit)` | Workhorse. Vector + BM25 + payload filter. Returns `stale` flag. | Qdrant |
| `k8s_get_object(cluster, kind, namespace, name)` | Authoritative live read — use before any write-producing action. | kube API (via indexer proxy) |
| `k8s_list(cluster, kind, namespace?, label_selector?)` | Authoritative enumeration. | kube API |
| `k8s_relations(...)` **v1.1** | Derived joins: ownerRefs → ArgoCD app → Helm release → GitHub repo. | Qdrant + synthetic docs |

Semantic queries always stamp `stale=true` when the back-pressure rule triggers (embedder queue > 5000 or last upsert > 2 min). The agent's system prompt tells it to prefer authoritative tools in that mode.

## What we tested vs. dismissed

**Real contenders:**
- `containers/kubernetes-mcp-server` (manusa) — **adopt now** as live-read primitive. Apache-2.0, Red Hat–backed, Go, native K8s API (not kubectl shell-out), multi-cluster via kubeconfig contexts, Red Hat production hardening guide. Good enough to unblock ShipIt for simple queries while we build the vector layer.
- **HolmesGPT** (CNCF Sandbox, Jan 2026) — **adopt later as incident adjunct.** Read-only, RBAC-aware, ArgoCD + Helm + Prometheus toolsets out of the box, major Microsoft contributions. Not a state index; it's an agentic SRE brain. Runs alongside — doesn't replace — the domain-context index.
- **DIY informers → Qdrant → MCP** (Track B, recommended over dot-ai) — **the Phase 1 build.** Tailored to our exact scope (ArgoCD + Helm + ingress + SealedSecret), reuses the existing FastAPI + Redis + claude-agent-sdk stack, avoids single-maintainer beta dependency.

**Dismissed:**
- **dot-ai** — right shape, wrong maturity. Beta, 310 stars, single maintainer, default RBAC is cluster-admin, no multi-cluster, no Helm-values sync, ArgoCD labels are stripped from embedding text. Pilot-worthy as a reference; not worth adopting.
- **k8sgpt** — diagnostic analyzer engine, not a state index. Keep as a separate incident tool if we want scheduled AI-authored cluster health reports.
- **kubectl-ai** — workstation CLI, pre-1.0, stateless, no multi-cluster. Wrong shape.
- **Kubiya** — enterprise ChatOps platform; a ShipIt replacement, not a component. Wrong direction.
- **Flux159/mcp-server-kubernetes** — desktop-centric; weaker production story than manusa. Pick one, pick manusa.

## Phased plan

### Phase 0 — live reads today (days)
- Add `containers/kubernetes-mcp-server` to the Managed Agent session's `mcp-config` with kubeconfig contexts for all OKE clusters.
- Dedicated read-only ServiceAccount per cluster.
- Agent can immediately answer "is deployment X healthy", "list pods in namespace Y across clusters", etc.
- No new infra. No vector DB. Foundation to learn *which* queries actually matter before building the index.

### Phase 1 — v1 indexer + vector layer (~2–3 weeks)
- **Indexer:** Go, client-go shared informers, read-only SA, per-cluster. Outbound TLS to central Redis stream. New subchart `charts/k8s-context-indexer` in `startappdev/helm`, one ArgoCD `Application` per cluster.
- **Embedder pool:** new role on the existing claude-agent-sdk worker image; consumes Redis stream, computes NL summaries, embeds via OpenAI `text-embedding-3-small` (direct API), upserts to Qdrant.
- **Qdrant:** 3-replica StatefulSet in `agents-platform` namespace on prod, ClusterIP access, OCI Object Storage snapshots for DR.
- **MCP server:** FastAPI + SSE (same transport as mcp-atlassian), mTLS from Managed Agent, exposes `k8s_semantic_query` / `k8s_get_object` / `k8s_list`.
- **Scope:** the v1 resources listed above. Redaction of Secret/SealedSecret bodies is hard-coded.

### Phase 1.5 — ArgoCD + Helm synthetic docs
- Index `Application`/`ApplicationSet` (gives repo↔cluster mapping for free).
- Index Helm release metadata (one synthetic doc per release; source = `helm list -Ao json` inside indexer, or narrow SA over Helm's release-storage Secrets — see open questions).
- Add `k8s_relations` tool.

### Phase 2 — incident tooling
- Evaluate HolmesGPT as a companion agent for incident triage. Read-only, MCP-native, ArgoCD/Helm toolsets already present. Runs alongside ShipIt — doesn't replace it.

## Key open questions

1. **Helm release source.** `helm list -Ao json` (simple, needs release-storage read) vs. indexing `Secret`s of type `helm.sh/release.v1` (more invasive RBAC exception since we otherwise ban Secret reads). Track D Q2.
2. **ConfigMap values.** Default = names only. Opt-in per-namespace annotation (`agents.start.io/index-values=true`) if teams want searchable config. Track D Q1.
3. **Freshness SLO.** Is p99 < 30 s good enough for the "did my deploy land?" question, or do we push it to < 5 s (doable, costs more front-loading in authoritative tools)? Track D Q4.
4. **OpenAI egress allowlist.** Allowlist `api.openai.com` from prod OKE (same egress class as Anthropic's Claude API, which is already permitted). If EU data residency becomes a requirement later, Azure OpenAI is the same model with regional deployment — a config swap, no code change.
5. **Qdrant HA + DR.** 3 replicas + scheduled OCI Object Storage snapshots via the chart's `snapshotPersistence` flag. Cron needs designing. Track C Q4.
6. **OCI-ASH-PRD-1-29 private API.** Indexer lives inside the cluster (no issue). But the MCP server's `k8s_get_object` live-read proxy needs to reach each cluster's API. Option A: proxy requests back through the indexer pod. Option B: each cluster runs its own MCP shard. Leaning A for simpler agent config.
7. **RBAC for v1 resource list.** Concrete ClusterRole to draft — explicitly no `secrets.core` verbs. Draft before Phase 1 kickoff.

## Recommendation

Ship Phase 0 (manusa MCP server attached to the Managed Agent session) **this week** — it's one config change and gives ShipIt useful cluster awareness immediately. Use the 1–2 weeks of Phase 0 operation to observe which queries the agent actually needs, then write the Phase 1 spec with empirical data on scope / freshness / RBAC. Treat `vfarcic/dot-ai` as reading material, not a dependency.

---

**Next step:** if this direction is approved, transition to `writing-plans` to produce a Phase 1 implementation plan (helm chart scaffolding, RBAC, indexer Go service, embedder worker role, Qdrant deployment, MCP server + tool contracts, tests, rollout).
