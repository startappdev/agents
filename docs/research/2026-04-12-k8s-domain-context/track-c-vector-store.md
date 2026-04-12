# Track C — Vector store + embedding choice

## TL;DR
- **Vector store: Qdrant self-hosted on OKE prod** via the official Helm chart ([qdrant/qdrant-helm](https://github.com/qdrant/qdrant-helm)). Best filter performance, native hybrid search (dense + sparse via named vectors since v1.9 / BM25 IDF since v1.15), and it is the same store [dot-ai](https://github.com/vfarcic/dot-ai) uses for its K8s semantic layer — so we inherit a validated pattern.
- **Embedding model: Voyage AI `voyage-3.5` as default, `voyage-code-3` for CRDs / Helm / YAML blobs**. Voyage is [Anthropic's officially recommended provider](https://platform.claude.com/docs/en/build-with-claude/embeddings) (Anthropic ships no first-party embedding model as of April 2026). 200M free tokens per account covers the entire backfill.
- **What to embed: natural-language derivation per object, with structured metadata as filters.** Do NOT embed raw YAML. Embed a 2–4 sentence NL summary ("Deployment `payments-api` runs 3 replicas of `registry/payments:1.4.2` in namespace `payments` on cluster `OCI-ASH-PRD-1-29`, exposed via Service `payments` and Ingress `payments.start.io` (class `nginx-ms`), owned by ArgoCD Application `payments-prd`"). Store labels, namespace, kind, cluster, owner-refs as payload fields for hybrid filter queries.
- **Hybrid search is required**, not optional. Operators ask things like `label app.kubernetes.io/part-of=checkout AND "auth rate-limit"`. Qdrant handles it natively; pgvector needs tsvector glue.
- **Cost order-of-magnitude: under $40/mo** total (compute + embeddings) at 3 clusters × 20k objects with daily churn. Dominated by Qdrant pod (~$25/mo on OKE) — embeddings are effectively free.

## Vector store comparison

| Store | Hybrid (vec+BM25) | Metadata filter perf | OKE deploy | Ops burden | Fit |
|---|---|---|---|---|---|
| **Qdrant** | Native (named vectors + sparse, v1.9+) | Best-in-class filter pushdown ([Qdrant benchmarks](https://qdrant.tech/benchmarks/)) | Official Helm chart | Low–Med | **Primary choice** |
| pgvector / pgvectorscale | Via tsvector + RRF (manual) | Good up to ~10M; pgvectorscale hits 471 QPS@50M ([Supabase/Timescale bench](https://www.timescale.com/blog/pgvector-vs-pinecone)) | Via CloudNativePG | Low (if PG already exists) | Fallback if we want one DB |
| Weaviate | Native (BlockMax WAND + RSF) | Good; schema-heavy | Helm chart | Med (Go, multi-node) | Viable but heavier than Qdrant |
| Chroma | Basic | Weak filter pushdown | Single-node only in practice | Low | Prototype only |
| Milvus | Native (Sparse-BM25 2.5+) | Great at 100M+ | Heavy (etcd, pulsar/kafka, minio) | High | Overkill at 50k objects |
| Pinecone | Proprietary sparse | Good | SaaS only | None | $50/mo minimum + egress from OCI; no data-locality |

Qdrant's filter performance is the [main differentiator](https://dev.to/kencho/vector-database-performance-compared-pgvector-vs-pinecone-vs-qdrant-vs-weaviate-2ne6): K8s queries are filter-heavy ("kind=Deployment AND cluster=prd-1 AND namespace IN (...)"), and that's exactly where Qdrant wins.

## Embedding model comparison

| Model | $/1M tok | Dim | Code/structured quality | Host |
|---|---|---|---|---|
| **voyage-3.5** | $0.06 | 1024 | +8.3% over OAI-v3-large on MTEB ([Voyage blog](https://blog.voyageai.com/2025/01/07/voyage-3-large/)) | SaaS |
| **voyage-code-3** | $0.18 | 1024 | +13.8% over OAI-v3-large on 238 code datasets | SaaS |
| voyage-3.5-lite | $0.02 | 512 | Still beats OAI-v3-small | SaaS |
| OpenAI text-embedding-3-large | $0.13 | 3072 | Baseline | SaaS |
| OpenAI text-embedding-3-small | $0.02 | 1536 | Weak on code | SaaS |
| Anthropic | — | — | **No first-party embedding model** — docs redirect to Voyage | — |
| BGE-M3 (local) | free / GPU | 1024 | 72% retrieval accuracy, best open multi-lingual ([BentoML guide](https://www.bentoml.com/blog/a-guide-to-open-source-embedding-models)) | Self-host, needs A10G+ |
| nomic-embed-text-v2 | free / CPU | 768 | 86% top-5, runs on CPU ([Nomic](https://www.nomic.ai/blog/posts/nomic-embed-text-v2)) | Self-host, CPU-OK |

**Pick voyage-3.5**: Anthropic-endorsed, cheap, best general-purpose quality, no GPU. Escalate to `voyage-code-3` only for CRD spec blobs and raw Helm values where code-aware retrieval helps.

## What to embed (full object vs. NL derivation)

Embed a **natural-language derivation** per object, not raw YAML. Rationale:

1. **Semantic signal density.** YAML is ~80% syntax tokens (`apiVersion`, `spec`, `containers`, indentation). An NL summary keeps only the tokens an operator queries against. [RAG best practices](https://unstructured.io/insights/rag-systems-best-practices-unstructured-data-pipeline) call this "contextual enrichment" — attach a doc-level summary to each chunk.
2. **Cross-cluster generalization.** NL form normalizes quirks ("replicas: 3" vs. `Rollout.spec.replicas: 3`) so a query like "services with only one replica in prod" hits the same embedding shape across Deployments, StatefulSets, and Rollouts.
3. **Structured fields → payload, not vector.** Cluster, namespace, kind, labels, annotations, `ownerReferences`, `metadata.name` go into Qdrant's payload as indexed filter fields. This is exactly [dot-ai's pattern](https://github.com/vfarcic/dot-ai): Qdrant for semantic matching + structured metadata for filtering + Kyverno for enforcement.

**Chunking:** one vector per top-level object. Don't shard a Deployment into pieces — it's already atomic. Ingress + its backing Services get cross-linked via payload fields so "show me all services behind `*.start.io`" resolves via filter, not vector similarity.

Alternative (rejected): embed the full JSON. Bloats tokens 4–5x, measurably degrades recall on operator-style queries, and makes filter-only queries ("list all ArgoCD Apps in namespace X") unnecessarily go through vector search.

## Hybrid search (vector + metadata filter)

Required. Operational queries split cleanly:

- **Pure filter** (50% of queries): "list all Ingresses with class `nginx-ms`" → Qdrant scroll with payload filter, no vector at all.
- **Pure semantic** (10%): "which service handles user login" → dense only.
- **Hybrid** (40%): "auth-related services in cluster prd-1 with >1 replica" → sparse BM25 ("auth") + dense (semantic) + payload filter (cluster, replicas).

Qdrant's [named vectors + sparse vectors](https://qdrant.tech/articles/sparse-vectors/) plus server-side IDF (v1.15.2+) make this a single round-trip. pgvector can do this too but requires hand-rolling RRF over `tsvector` and a vector column — more moving parts.

## Deployment topology for Start.io

**Run Qdrant in-cluster on OKE prod (`OCI-ASH-PRD-1-29`), single namespace (`agents-platform`), 3 replicas, StatefulSet via Helm chart.**

- **In-cluster wins on latency + data locality.** Gateway → Qdrant is a ClusterIP hop (~1 ms). SaaS (Pinecone, Qdrant Cloud) means egress from OCI + 20–80 ms round-trip. [OCI egress is $0.0085/GB after 10TB](https://www.oracle.com/cloud/price-list/) — small but non-zero, and the latency hit matters for agent latency budgets.
- **OCI has no true managed vector DB.** Oracle's [Autonomous AI Vector Database](https://blogs.oracle.com/database/) (limited availability March 2026) is an extension of Autonomous DB — not a fit for a Python+FastAPI stack, and heavy license implications. OCI Database with PostgreSQL supports pgvector and is a reasonable plan-B if we want an OCI-managed path.
- **Sync from informers → Redis → embedder worker → Qdrant upsert**, reusing the existing FastAPI+Redis+claude-agent-sdk pipeline. Informers in each of 3 clusters publish to a shared Redis on prd-1 via VPN/peering.
- **Don't co-locate per-cluster.** One central Qdrant, cluster stamped as payload. Cross-cluster queries are the whole point.

## Cost estimate (OOM — 3 clusters × ~20k objects, daily churn)

| Item | Volume | Unit | Monthly |
|---|---|---|---|
| Steady state objects | 60k | — | — |
| Avg tokens per NL summary | ~150 | — | — |
| Backfill embeddings | 60k × 150 = 9M tok | covered by 200M free tier | **$0** |
| Churn (assume 20% daily re-embed) | 12k × 150 × 30 = 54M tok/mo | $0.06/M (voyage-3.5), still under free tier annually | **$0–$3** |
| Qdrant pod (3× VM.Standard.E4.Flex 2OCPU/16GB) | — | ~$25/mo on OCI ([OCI flex compute](https://www.oracle.com/cloud/compute/pricing/)) | **$25** |
| Storage (60k × 1024-dim × 4B + payload ≈ 1 GB) | 1 GB | block volume $0.0255/GB/mo | **<$1** |
| **Total** | | | **~$25–30/mo** |

Compare: Pinecone Standard = $50/mo minimum **before** reads/writes. Qdrant Cloud = ~$45/mo for comparable node. Self-hosted on OKE we already own is the clear winner.

## Recommendation

**Qdrant 1.15+ self-hosted on OKE prod, 3-replica StatefulSet in `agents-platform` namespace, accessed via ClusterIP from the FastAPI gateway. Embed with Voyage AI `voyage-3.5` (code-3 for CRD/Helm blobs only). Store NL-derived summaries as vectors with K8s metadata (cluster, kind, namespace, labels, ownerRefs) as indexed payload. Hybrid search (dense + sparse BM25 + payload filter) from day one.** Ship the Helm chart into `startappdev/helm` as a new `charts/qdrant/` or bundle inside `agents-platform` values.

This mirrors what [dot-ai](https://github.com/vfarcic/dot-ai) already validated in production for a near-identical problem (semantic discovery of K8s capabilities), and keeps the whole system on infrastructure we already run.

## Open questions

1. **Embedding provider egress?** Voyage is SaaS — do we need an allowlist / VPC endpoint story, or is OKE → api.voyageai.com acceptable? (Same question Anthropic already has answered for Claude API.)
2. **Informer vs. polling.** Do we run `client-go` informers per cluster, or piggyback on an existing tool (kube-state-metrics, steampipe)? Affects sync-lag SLO.
3. **Reranker?** Voyage also ships `rerank-2` — worth evaluating on top 50 vs. top 10 for complex cross-cluster queries.
4. **Backup/DR for Qdrant.** Snapshot to OCI Object Storage via the [qdrant-helm snapshotPersistence flag](https://github.com/qdrant/qdrant-helm/blob/main/charts/qdrant/README.md) — needs a scheduled CronJob.
5. **Do we ever need to share this index cross-tenant / with customers?** If yes, revisit Qdrant Cloud managed or multi-tenant collection design.

---

Sources:
- [Qdrant benchmarks](https://qdrant.tech/benchmarks/) · [qdrant/qdrant-helm](https://github.com/qdrant/qdrant-helm) · [Qdrant sparse vectors](https://qdrant.tech/articles/sparse-vectors/)
- [pgvector vs Pinecone vs Qdrant vs Weaviate bench](https://dev.to/kencho/vector-database-performance-compared-pgvector-vs-pinecone-vs-qdrant-vs-weaviate-2ne6)
- [Voyage AI pricing](https://docs.voyageai.com/docs/pricing) · [voyage-3.5 release](https://www.mongodb.com/company/blog/product-release-announcements/introducing-voyage-3-5-voyage-3-5-lite-improved-quality-new-retrieval-frontier) · [voyage-3-large](https://blog.voyageai.com/2025/01/07/voyage-3-large/)
- [Anthropic embeddings docs — recommends Voyage](https://platform.claude.com/docs/en/build-with-claude/embeddings)
- [OpenAI embedding pricing](https://platform.openai.com/docs/models/text-embedding-3-large)
- [Pinecone serverless pricing 2026](https://ranksquire.com/2026/03/04/vector-database-pricing-comparison-2026/)
- [vfarcic/dot-ai](https://github.com/vfarcic/dot-ai) · [dot-ai deep dive](https://skywork.ai/skypage/en/dot-ai-kubernetes-deep-dive/1977934697939783680)
- [Open-source embedding model bench (BentoML)](https://www.bentoml.com/blog/a-guide-to-open-source-embedding-models)
- [Oracle Autonomous AI Vector Database](https://blogs.oracle.com/database/building-scalable-vector-search-with-oracle-globally-distributed-database)
- [RAG production best practices (Unstructured)](https://unstructured.io/insights/rag-systems-best-practices-unstructured-data-pipeline)
