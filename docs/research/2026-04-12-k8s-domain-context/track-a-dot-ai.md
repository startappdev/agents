# Track A — dot-ai deep dive

Research date: 2026-04-12. Target: `vfarcic/dot-ai` v1.15.2 + `vfarcic/dot-ai-controller` v0.48.1. Primary sources: GitHub repos, [devopstoolkit.ai docs](https://devopstoolkit.ai/docs/ai-engine/), Viktor Farcic's blog post [Why Kubernetes Querying Is Broken and How I Fixed It](https://devopstoolkit.live/kubernetes/why-kubernetes-querying-is-broken-and-how-i-fixed-it/), and [YouTube deep-dive uUdbQkq5c4k](https://youtu.be/uUdbQkq5c4k).

## TL;DR
- dot-ai is a **two-piece system**: a TypeScript MCP server (`@vfarcic/dot-ai`, 310 stars, MIT, status `beta`) plus a Go Kubernetes controller (`dot-ai-controller`, 48 stars). The controller watches the K8s API via dynamic informers and pushes resource metadata into **Qdrant**; the MCP server serves natural-language queries over it.
- Only **labels + select annotations + Kind/apiVersion/name/namespace/timestamps** are synced to Qdrant. Status and spec are **never** synced — they're fetched fresh from the K8s API when a query needs them.
- Freshness is well-specified: default **10 s debounce window** for live changes, **60 min periodic full resync** for drift. Both are tunable (1–300 s, 1–1440 min) via `ResourceSyncConfig` CRD.
- **Single-cluster by design today**: multi-cluster is on the roadmap but not shipped. Scale-out requires one controller + one MCP + one Qdrant per cluster; fan-out must be built by the caller.
- **RBAC is wide open by default** — the Helm chart grants `*/*` on verbs `get,list,watch,create,update,patch,delete` (see [`charts/templates/clusterrole.yaml`](https://github.com/vfarcic/dot-ai/blob/main/charts/templates/clusterrole.yaml)). Fine for the product's "deploy anything" feature, unacceptable for Start.io's read-only query use case without a fork.

## Architecture

Two processes, one data store:

```
┌───────────────────┐   watch/discover    ┌──────────────────┐
│  dot-ai-controller │ ───────────────── │  Kubernetes API  │
│  (Go, informers)  │                    └──────────────────┘
└────────┬──────────┘
         │ HTTP POST /api/v1/resources/sync
         │ (upserts + deletes, batched every 10s)
         ▼
┌───────────────────┐    HTTP MCP        ┌──────────────────┐
│  dot-ai MCP server │ ─────────────────▶│ Qdrant (StatefulSet) │
│  (TypeScript)     │    embed + upsert  │  collection: "resources" │
│  port 3456        │                    └──────────────────┘
└────────┬──────────┘
         │ MCP (HTTP+SSE) + REST Gateway
         ▼
   MCP client (Claude Code, Cursor, your agent)
```

**Sync path** (`internal/controller/resourcesync_controller.go`): the controller uses `k8s.io/client-go/discovery` to enumerate every GVR in the cluster, then creates a `dynamicinformer` for each one. It additionally watches `CustomResourceDefinitions` so new CRDs get informers without restart. Change events flow into a buffered channel (10 000 entries) and a `DebounceBuffer` (`resourcesync_debounce.go`) that deduplicates by resource ID using last-state-wins over a configurable window. High-volume/noisy resources are explicitly excluded: **Events, Leases, EndpointSlices**, and the `kubectl.kubernetes.io/last-applied-configuration` annotation ([resource-sync-guide](https://github.com/vfarcic/dot-ai-controller/blob/main/docs/resource-sync-guide.md#what-gets-synced)).

**Storage**: The MCP server's `ResourceVectorService` ([`src/core/resource-vector-service.ts`](https://github.com/vfarcic/dot-ai/blob/main/src/core/resource-vector-service.ts)) builds an embedding text like `"Deployment silly-demo namespace: default apiVersion: apps/v1 labels: team=platform app=silly-demo"` — deliberately excluding noisy standard labels (`app.kubernetes.io/*`, `helm.sh/*`, `kubernetes.io/*`). Embeddings go into Qdrant collection `resources` keyed by hash of `namespace/apiVersion/kind/name`.

**Embeddings**: default is an in-cluster [HuggingFace TEI](https://github.com/huggingface/text-embeddings-inference) pod running **`sentence-transformers/all-MiniLM-L6-v2`** (384-dim, ~256 MiB RAM, amd64-only — ARM issue [huggingface/text-embeddings-inference#769](https://github.com/huggingface/text-embeddings-inference/issues/769)). Cloud alternatives via Vercel AI SDK ([`src/core/embedding-service.ts`](https://github.com/vfarcic/dot-ai/blob/main/src/core/embedding-service.ts)): OpenAI `text-embedding-3-small` (1536), Google `gemini-embedding-001` (768), Bedrock `amazon.titan-embed-text-v2:0` (1024). Anthropic is explicitly not supported for embeddings. Switching dimensions triggers a re-embed via `POST /api/v1/embeddings/migrate`.

**AI orchestration**: query tool (`src/tools/query.ts`) runs an **agentic tool loop** inside the MCP server. The LLM picks from `search_capabilities` (Qdrant semantic search), `query_resources` (Qdrant inventory filters), `search_resources`, and a `kubectl` shell-out for live state. Claude Sonnet/Haiku, GPT-5, Gemini, Kimi, Bedrock, and OpenAI-compatible endpoints (Ollama/vLLM/LocalAI) are all configurable ([deployment.md](https://github.com/vfarcic/dot-ai/blob/main/docs/ai-engine/setup/deployment.md)).

## MCP surface (tools exposed)

Exported from [`src/tools/index.ts`](https://github.com/vfarcic/dot-ai/blob/main/src/tools/index.ts):

| Tool | Purpose |
|------|---------|
| `query` | Natural-language cluster Q&A (the tool we care about). Input: `{intent: string}`. Output: summary + toolsUsed + optional `visualizationUrl`. |
| `recommend` | AI picks resource kinds for a deployment intent. |
| `chooseSolution`, `answerQuestion`, `generateManifests`, `deployManifests` | Interactive deploy workflow. |
| `organizationalData` (a.k.a. `manageOrgData`) | CRUD for capabilities / patterns / policies in Qdrant. |
| `remediate` | AI root-cause + fix. |
| `projectSetup`, `manageKnowledge`, `impactAnalysis`, `version` | Repo bootstrap, doc ingestion, blast-radius, status. |

There is **no separate `search_resources` MCP tool** — resource discovery is an internal tool the `query` agent calls. That matters: integrators who want a stable "give me all Deployments owned by ArgoCD app X" RPC would get it either through `query` (LLM-mediated, non-deterministic) or the REST gateway (`/api/v1/resources/sync` is the ingest endpoint; query endpoints live under `/api/v1/tools/...`).

## Deployment + RBAC

One Helm chart: `oci://ghcr.io/vfarcic/dot-ai/charts/dot-ai`. The Quick Start installs **MCP server + embedded Qdrant StatefulSet + TEI embeddings pod + optional Dex IdP + Ingress/Gateway**. Controller is a **separate** chart `oci://ghcr.io/vfarcic/dot-ai-controller/charts/dot-ai-controller` — you install both, then apply a `ResourceSyncConfig` and `CapabilityScanConfig` CR to kick off ingest.

**RBAC** — the killer. From [`charts/templates/clusterrole.yaml`](https://github.com/vfarcic/dot-ai/blob/main/charts/templates/clusterrole.yaml):

```yaml
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["create", "update", "patch", "delete"]
```

This is cluster-admin in all but name. Needed because `recommend` + `deployManifests` actually apply resources. For a read-only query deployment, this chart has to be **forked** to strip the write verbs; that's a one-line change but it violates the "Only `kubectl get`" Start.io rule.

The MCP-to-controller auth model: the controller POSTs to MCP with a bearer token from a Secret (`mcpAuthSecretRef`), either the shared static `DOT_AI_AUTH_TOKEN` or per-user OAuth via Dex. OAuth-mode users can be gated with tool-level RBAC using a virtual API group `dot-ai.devopstoolkit.ai` and `SubjectAccessReview` ([`src/core/rbac/check-access.ts`](https://github.com/vfarcic/dot-ai/blob/main/src/core/rbac/check-access.ts)), off by default.

## Multi-cluster story

**Not supported.** Evidence:
- PRD #291 (the query-tool PRD) lists "Multi-cluster support" under **Out of Scope**.
- PRD #216 for the capability-scan controller lists "Multi-Cluster: Watch multiple clusters from single controller instance" as a **Phase 2 future item**.
- PRD #287 (resource-sync endpoint): "Multi-cluster support (single cluster only)".
- The controller's informers use `rest.InClusterConfig()` — one kubeconfig per pod.
- The "Multi-Cluster Management" snippet in [`.claude/skills/dot-ai-changelog-fragment/SKILL.md`](https://github.com/vfarcic/dot-ai/blob/main/.claude/skills/dot-ai-changelog-fragment/SKILL.md) is a **template example**, not a shipped feature (confirmed: `devopstoolkit.ai/docs/mcp/setup/multi-cluster-setup` does not exist).

**Implication for Start.io**: to cover `OCI-ASH-PRD-1-29` plus the upcoming OKE clusters, you'd run **one (controller + MCP + Qdrant) stack per cluster**, then either (a) have ShipIt configure N MCP servers and fan out queries, or (b) put a thin aggregator in front — the user's `claude --mcp-config .mcp-kubernetes.json --strict-mcp-config` hint is exactly pattern (a), listing N `dot-ai` entries with per-cluster URLs.

## Freshness / sync lag

Documented and tunable ([`ResourceSyncConfig`](https://github.com/vfarcic/dot-ai-controller/blob/main/api/v1alpha1/resourcesyncconfig_types.go)):

| Setting | Default | Range | Effect |
|---|---|---|---|
| `debounceWindowSeconds` | 10 | 1–300 | Batches informer events; same resource edited 5× in 10 s = 1 upsert. |
| `resyncIntervalMinutes` | 60 | 1–1440 | Full cluster walk to heal missed events / dropped informer connections. |

So **typical label/metadata change shows up in Qdrant in ≤10 s**, worst-case bounded by the resync interval. Because spec/status are not cached, status-ish queries ("Is my-postgres healthy?") stay real-time regardless of debounce — the agent does a live `kubectl describe` after semantic resolution. This is actually the right design: avoids the usual "stale cache fought the live cluster and lost" pattern.

Not documented: behavior under informer reconnect storms, or how the 10 000-entry change queue behaves during a full `kubectl apply -R` of a 50-microservice repo. Would need a load test.

## Production readiness

- Project badge: **`status: beta`**. License MIT. Active: last push 2026-04-12 (day of this report).
- Adoption: 310 stars, 62 forks, 22 open issues, 7 subscribers on the main repo; 48 stars on the controller. Published as `@vfarcic/dot-ai` on npm. [PulseMCP](https://www.pulsemcp.com/servers/vfarcic-dot-ai) reports ~1.7 k weekly visitors, rank #739 — **demo-to-pre-production scale**, no known enterprise logo.
- Primarily driven by Viktor Farcic (Upbound/Crossplane advocate, DevOps Toolkit channel). 7 subscribers and single-maintainer bus factor is a real risk for a platform dependency.
- Qdrant is embedded as a StatefulSet in the chart — fine for dev, not HA out of the box (1 replica default). Production Qdrant is [a separate operator](https://github.com/qdrant/qdrant-operator) or Qdrant Cloud.
- Tests exist (Vitest unit + integration suites; Go controller has 65 k-line test file for the resource-sync controller). CI uses Renovate, OpenSSF Scorecard.
- Telemetry is enabled by default ("anonymous usage analytics") — must be opted out for a prod internal deployment.

Verdict: **viable pre-production for a pilot**; not a product you'd bet a tier-1 SLO on without a fork and an internal maintainer.

## Fit for Start.io

Positives:
- The **data model maps cleanly** to what ShipIt actually needs: "which ArgoCD app owns service X?", "find ingresses with class `oci-nlb`", "list Helm releases labeled `team=ads`" all work because labels + annotations are the exact metadata synced.
- Deploys as standard Helm + CRDs — matches the helm / argo-cd repo pattern already in use (Phase 1 complete per memory).
- MCP-over-HTTP with bearer token matches the `claude --mcp-config .mcp-kubernetes.json --strict-mcp-config` usage the user hinted at. ShipIt (claude-agent-sdk worker) can load it as a first-class MCP client alongside mcp-atlassian.
- REST gateway gives the FastAPI gateway an escape hatch if the agent-mediated path ever feels too LLM-loose.

Frictions:
- **RBAC fork required.** The stock ClusterRole is a non-starter for prod. Strip write verbs, test that `query` and semantic search still work (they will — the query path only uses `get/list`).
- **Per-cluster footprint**: Qdrant StatefulSet + TEI pod + MCP deployment + controller deployment **per cluster**. Not huge (~1 CPU + 1 GiB steady), but 3 clusters × 4 pods × HA = real money.
- **No multi-cluster federation**: ShipIt would need a small MCP aggregator, or the agent would have to know to call `dot-ai-ash`, `dot-ai-fra`, `dot-ai-jfk` per question. Feasible but extra code.
- **OAuth/SSO is via Dex**, not the Teams/Entra identity Start.io already uses for ShipIt. Static bearer tokens work fine for bot-to-MCP, so this is mostly a non-issue unless you want per-user audit.
- **Architecture mismatch**: dot-ai assumes the MCP server is the "primary" and controllers push to it. ShipIt's architecture (FastAPI gateway → Redis queue → workers) would wrap dot-ai as an *external* MCP dependency, which is fine, but it means you can't reuse the dot-ai UI/Web paths without additional ingress.
- **Vector DB lock-in**: Everything assumes Qdrant. Swapping to a managed service (Pinecone, pgvector on OCI) would be a fork-level change.

## Trade-offs

| Gain | Cost |
|---|---|
| Controller-based sync is event-driven + debounced, not poll-based | Single-cluster only today |
| Semantic search over labels/annotations solves "find by concept" | Status/spec not cached — every "is it healthy" call hits K8s API (which is arguably correct) |
| Pluggable LLM + embedding providers (Anthropic, Google, Bedrock, Ollama) | Embedding dim changes require full re-embed |
| Agentic query loop can mix vector + live data | LLM decides tool use — non-deterministic latency; no "raw SQL" escape for deterministic queries |
| Helm-native install, SSE-friendly ingress config included | Default RBAC is cluster-admin-wide |
| Open MIT, TypeScript + Go, approachable codebase | Single-maintainer project, beta status, 310 stars |

## Open questions

1. **Sync lag under pressure** — load-test with a rolling deploy of 200 resources. Does the 10 000-buffer hold? *Not documented, needs empirical verification.*
2. **Qdrant HA** — the embedded StatefulSet is 1-replica. What's Viktor's recommendation for multi-node Qdrant? *Not documented; would need to adopt external Qdrant cluster or Cloud.*
3. **Multi-cluster ETA** — is PRD #216 Phase 2 on anyone's roadmap? *Not in ROADMAP.md's short/medium/long-term sections.*
4. **Churn on Start.io resource counts** — Start.io has how many resources per cluster? If >10 k, does the initial resync fit in one HTTP POST? *Not documented; the controller streams, but payload size caps unclear.*
5. **ArgoCD app ownership** — dot-ai syncs labels/annotations only. ArgoCD's `app.kubernetes.io/instance` label is stripped by the `app.kubernetes.io/*` filter in `buildEmbeddingText`. That's a **real problem** for Start.io's "what Argo app owns this?" question; would need a controller patch to keep `argocd.argoproj.io/*` labels in the semantic text. *Needs verification on actual payload — labels are stored in Qdrant payload even if not in embedding text, so filtering-by-label may still work via `query_resources` inventory path.*
6. **Helm values visibility** — dot-ai does not sync `helm.sh/chart` label metadata into embedding text, and Helm values are not synced at all. Start.io's "what Helm values drove this deployment" need is **not covered** by dot-ai out of the box.

## Recommendation: **Pilot, don't adopt**

dot-ai is the right *shape* — controller-watches-K8s → Qdrant → MCP-with-agentic-tool-loop is exactly the design Start.io needs, and it's the only OSS project in this space with a working demo video and a coherent codebase today. But:

1. **Not prod-ready as-is**: beta status, single-maintainer, RBAC fork required, no multi-cluster, no Helm-values sync, and the Argo-ownership label filter is a minor-but-real miss.
2. **Start.io's questions exceed dot-ai's data model.** "What services run where" ✓, "what ArgoCD app owns them" △ (needs label filter fix), "what ingress/DNS map to them" ✓, "what Helm values drove deployment" ✗ (not synced).

**Suggested path**: stand up one instance against a dev OKE cluster for 2 weeks, measure sync lag on realistic workload, test the five or six queries ShipIt actually needs to answer, and decide between (a) **forking** (RBAC lockdown + Helm-values sync + multi-cluster aggregator — maybe 2 engineer-weeks), (b) **using it as reference** and building a lean Start.io-specific controller-to-Qdrant pipeline targeted at Start.io's exact questions, or (c) **shelving** if the pilot reveals the agentic query loop is too loose for bot-automated workflows. Given the gaps above and the single-maintainer risk, my lean is toward (b): steal the architecture, skip the dependency.
