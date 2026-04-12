# Track B — Alternatives landscape

*Research date: 2026-04-12. Stars/releases captured via `gh` at that time.*

## TL;DR

- **Only two categories are real contenders for Start.io's Shipit + Teams use case:** (a) **manusa/containers `kubernetes-mcp-server`** as a cluster-access MCP tool plugged into the existing claude-agent-sdk workers, and (b) **HolmesGPT** as a parallel "SRE brain" for incident-style questions. Everything else is either a CLI personal-use tool, an unrelated enterprise platform, or overlaps with what Shipit already does.
- **Nothing in the OSS landscape currently implements `dot-ai`'s "informers → vector DB → MCP" loop for general cluster state.** k8sgpt has an operator but it runs diagnostic analyzers on a schedule, not a semantic store. That is the gap dot-ai targets and it has no direct competitor.
- **MCP is now table stakes.** k8sgpt, kubectl-ai, HolmesGPT, manusa, and Flux159 all speak MCP. This is a commodity layer — the differentiator is what sits behind it (watchers, analyzers, runbooks, or just kubectl pass-through).
- **kubectl-ai and Flux159 are developer-workstation tools.** Useful for individual engineers, not as the backbone of a chatops agent.
- **Kubiya is a commercial platform competitor to Shipit**, not a building block. Evaluating it means re-platforming, not augmenting.

## Comparison table

| Tool | Sync model | Freshness under load | Resource coverage | Where it runs | MCP | Multi-cluster | License | Production evidence | Maintainer |
|---|---|---|---|---|---|---|---|---|---|
| **vfarcic/dot-ai** | Dynamic discovery + Qdrant vector store; MCP queries | Pull on query; Qdrant cache | "ANY" CRD via discovery; deployment/governance focused | Local / MCP + Qdrant container | Native | Implied ("any cluster") | MIT | ~310 stars, **beta**; single-maintainer-driven | Viktor Farcic ([dot-ai](https://github.com/vfarcic/dot-ai)) |
| **k8sgpt** | On-demand analyzers; operator reconciles CRD on interval | Good for diagnostics, not for live state | 14 default + 18 optional analyzers, CRD-extensible via gRPC custom analyzers; no ArgoCD-app or Helm-release analyzer built-in | CLI + in-cluster operator | Native (`serve --mcp`) | No (single kubeconfig ctx) | Apache-2.0 | **7.6k stars**, v0.4.31 (2026-03); operator used at AWS/Bedrock case studies | k8sgpt-ai org ([k8sgpt](https://github.com/k8sgpt-ai/k8sgpt), [operator docs](https://docs.k8sgpt.ai/reference/operator/advanced-installation/)) |
| **kubectl-ai** | On-demand, stateless kubectl loop | N/A (no caching) | Whatever kubectl covers | CLI (+ optional web UI / MCP server) | Client + Server modes | Single context | Apache-2.0 | **7.4k stars**, v0.0.31 (2026-03); personal CLI | Google Cloud ([kubectl-ai](https://github.com/GoogleCloudPlatform/kubectl-ai)) |
| **HolmesGPT** | Agentic tool-calls at investigation time; read-only kubectl + Prometheus + logs | Very fresh (pulls live on demand); no staleness issue because no cache | Pods/events/logs + **ArgoCD** (status, history, manifests) + **Helm** (releases) + Prometheus/Grafana/Datadog + custom toolsets via MCP | CLI or in-cluster operator; also Robusta SaaS | Native MCP client + MCP integrations | Yes, via Robusta platform ("multi-cluster monitoring") | Apache-2.0 | **CNCF Sandbox** (Jan 2026); ~2.2k stars; Microsoft as major contributor; Robusta commercial backing | Robusta.dev ([holmesgpt](https://github.com/robusta-dev/holmesgpt), [CNCF blog](https://www.cncf.io/blog/2026/01/07/holmesgpt-agentic-troubleshooting-built-for-the-cloud-native-era/)) |
| **Kubiya** | Proprietary "Context Graph & Intelligence Layer" with "Real-time Sync" | Opaque | Native K8s + Terraform + GitHub + Jira + ServiceNow + clouds | SaaS or self-hosted containers | Not mentioned | Yes | Commercial (enterprise pricing, undisclosed) | Microsoft, Ford, Audi, VW cited; AWS Marketplace listed | Kubiya Inc. ([kubiya.ai](https://kubiya.ai), [AWS Marketplace](https://aws.amazon.com/marketplace/pp/prodview-cqi3hdrzknri4)) |
| **containers/kubernetes-mcp-server** (manusa) | Stateless, direct K8s API (not kubectl shell-out) | Pulls on every tool call; no cache | **Any CRD**, OpenShift Projects, Helm install/list/uninstall, Tekton, KubeVirt, Kiali | Binary / npm / PyPI / container | Native (stdio + SSE + HTTP) | **Yes, built-in, via kubeconfig contexts, all tools take `context` arg** | Apache-2.0 | **1.4k stars**, v0.0.60 (2026-04); Red Hat-recommended for OpenShift | Marc Nuri @ containers org / Red Hat ([containers/kubernetes-mcp-server](https://github.com/containers/kubernetes-mcp-server), [Red Hat Developer](https://developers.redhat.com/articles/2025/09/25/kubernetes-mcp-server-ai-powered-cluster-management)) |
| **Flux159/mcp-server-kubernetes** | Stateless kubectl shell-out + helm v3 on PATH | Pulls on tool call | kubectl surface + Helm | Local (Node/Bun) | Native (stdio, multi-client) | Multi-context switching in-session | MIT | ~1.4k stars, v3.5.0 (2026-04); desktop-centric | Flux159 (solo) ([Flux159/mcp-server-kubernetes](https://github.com/Flux159/mcp-server-kubernetes)) |
| **DIY: informers → queue → vector DB** | Push (watch events) | Best freshness; bounded by worker throughput | Whatever you embed (CRDs, ArgoCD Application, HelmRelease, Ingress→DNS) | In-cluster controller | You build the MCP wrapper | You design it | Yours | None — greenfield | You |

## dot-ai (reference only — covered in Track A)

The only OSS tool architecturally committed to "index cluster state into a vector store, serve over MCP". Qdrant + MCP server ([dot-ai](https://github.com/vfarcic/dot-ai)). `status-beta`, ~310 stars, one maintainer. Full analysis in `track-a-dot-ai.md`.

## k8sgpt

Most production-credible project here (7.6k stars, OpenSSF badge, AWS Bedrock docs — [k8sgpt](https://github.com/k8sgpt-ai/k8sgpt)). CLI (`k8sgpt analyze`) plus **k8sgpt-operator** which reconciles a `K8sGPT` CRD and publishes findings as Result CRDs ([operator docs](https://docs.k8sgpt.ai/reference/operator/advanced-installation/)). MCP via `serve --mcp`. Custom analyzers over gRPC let you add ArgoCD or HelmRelease checks ([tutorial](https://docs.k8sgpt.ai/tutorials/custom-analyzers/)), but none ship by default.

**What it is not:** a semantic index. It's an analyzer engine with LLM-written diagnoses — answers "what's broken?" not "what version of `foo-service` is running in ASH-PRD-1-29?"

**Fit:** Good adjunct for Shipit to call during incidents. Bad as the domain-context backbone.

## kubectl-ai

Google Cloud's stateless CLI agent (7.4k stars, Apache-2.0 — [kubectl-ai](https://github.com/GoogleCloudPlatform/kubectl-ai)): NL in, kubectl out. Supports Gemini/Vertex/OpenAI/Bedrock/Ollama; can also act as an MCP server.

**Fit:** Workstation tool. Unsuitable for a chatops backbone — no state, no multi-cluster, version `v0.0.31` is pre-1.0. Dismiss.

## HolmesGPT

**CNCF Sandbox (Jan 2026)** SRE agent from Robusta.dev, major Microsoft contributions ([CNCF blog](https://www.cncf.io/blog/2026/01/07/holmesgpt-agentic-troubleshooting-built-for-the-cloud-native-era/), [holmesgpt](https://github.com/robusta-dev/holmesgpt)). Core `ToolCallingLLM` loop dispatches read-only calls to K8s, Prometheus, Grafana, Datadog, **ArgoCD, Helm**, GitHub, then correlates and returns a diagnosis. Read-only, RBAC-aware, MCP-native client. Ships ArgoCD status/history/manifests and Helm release toolsets out of the box — the only tool here that does.

**Fit:** Strongest alternative for incident-response questions ("why is `agents-platform` degraded?"). Complements rather than replaces a state index: pull-at-question-time is fine for incidents, expensive for "current inventory" Qs.

## Kubiya

Enterprise "agentic engineering platform" — Slack/Teams-native, connects to K8s + Terraform + GitHub + Jira + ServiceNow with RBAC/SSO/audit + JIT privileges ([kubiya.ai](https://kubiya.ai), [docs](https://docs.kubiya.ai)).

**Fit:** *Replacement* for Shipit, not a component. Undisclosed enterprise pricing, opaque "Context Graph / Real-time Sync" with no published mechanism. Given Shipit Phase 2 is already LIVE, switching costs are prohibitive. Dismiss unless roadmap pivots away from owning the agent.

## mcp-server-kubernetes family

Two serious implementations, many hobby forks.

- **`containers/kubernetes-mcp-server`** (Marc Nuri / Red Hat, Apache-2.0, 1.4k stars, Go, direct K8s API). **Built-in multi-cluster** via kubeconfig contexts; every tool accepts `context`. Stdio + SSE + HTTP Streaming. Any-CRD CRUD; optional Helm/Tekton/KubeVirt/Kiali toolsets. Red Hat publishes a production hardening guide (dedicated SA, `--read-only`) ([Red Hat Developer](https://developers.redhat.com/articles/2025/09/25/kubernetes-mcp-server-ai-powered-cluster-management)). The serious choice.
- **`Flux159/mcp-server-kubernetes`** (MIT, 1.4k stars, TypeScript, shells out to kubectl + helm). Desktop-centric — no read-only SA story baked in.

Azure `mcp-kubernetes`, feiskyer, patrickdappollonio, giantswarm etc. are <100 stars. Skip.

**Fit:** `containers/kubernetes-mcp-server` is the right primitive for giving claude-agent-sdk workers live read access across all 3 OKE clusters. Downside: every question is an API round-trip — fine for point lookups, expensive for "what changed in the last hour" Qs that want a store.

## DIY patterns

1. **Informers → queue → vector DB.** client-go SharedInformerFactory (or controller-runtime) watches resources, pushes deltas through a queue into embeddings + Qdrant/Weaviate/pgvector, exposed via a custom MCP server. Freshness = milliseconds. This is what dot-ai partially does. Effort: weeks-to-months; ongoing work on schema, RBAC, deduping, TTLs.
2. **`kubectl get -o yaml` on cron → embedder.** Simple, stale by definition, no event semantics, breaks at scale. Acceptable as a 2-day spike; not production.

**Fit:** Option 1 is the serious alternative to adopting dot-ai — build exactly the resources Shipit cares about (Deployment, Rollout, ArgoCD Application, HelmRelease, SealedSecret, Ingress→ExternalDNS) in the existing Python/Redis/FastAPI stack.

## Which alternatives are real contenders for Start.io?

1. **`containers/kubernetes-mcp-server` (manusa)** — adopt as the read-only cluster-access MCP server. Satisfies "live state across 3 OKE clusters" for Shipit immediately. Complements, doesn't replace, any future vector-index layer.
2. **HolmesGPT** — adopt as the incident-investigation agent. CNCF Sandbox trajectory, ArgoCD/Helm toolsets built-in, read-only-by-design aligns with the "never mutate from kubectl" rule. Run as an operator or invoke via MCP from Shipit.
3. **DIY informers → Qdrant → MCP** — contender if Shipit needs "inventory", "diff over time", or "semantic search across manifests". Compare effort vs. dot-ai in Track D; dot-ai is basically this pattern pre-built but beta.

## Which should we dismiss and why?

- **kubectl-ai** — pre-1.0, stateless, single-cluster, desktop UX. No production story.
- **Kubiya** — replaces Shipit, enterprise pricing, opaque internals. Wrong direction given Phase 2 just shipped.
- **Flux159/mcp-server-kubernetes** — fine for laptops; weaker production story than containers/kubernetes-mcp-server. Pick one; pick manusa.
- **Every other `mcp kubernetes` repo on GitHub** — hobbyware (<100 stars, solo, sporadic commits). Not safe for OKE production.
- **k8sgpt as the domain-context spine** — wrong tool for the job. Keep it as a *diagnostic* adjunct if we want periodic AI-authored cluster health summaries, but don't build Shipit on top of its CRDs.

---

## Summary (~150 words)

The OSS landscape has converged on MCP as the AI-cluster interface, but diverged sharply on *what* sits behind MCP. For Start.io's Shipit agent, only two projects are real building blocks: **`containers/kubernetes-mcp-server`** (Red Hat-affiliated, Go, native K8s API, built-in multi-cluster via kubeconfig contexts, production-hardening guide) as the live-read primitive, and **HolmesGPT** (CNCF Sandbox, ArgoCD/Helm/Prometheus toolsets, read-only-by-design) as the incident-investigation brain. **k8sgpt** is a solid diagnostic adjunct but not a state index. **kubectl-ai** and **Flux159** are workstation tools. **Kubiya** is a Shipit replacement, not a component. **dot-ai** is the only OSS project architecturally matching the "informers → vector DB → MCP" pattern, but it's beta and single-maintainer — a DIY version tailored to Start.io's stack may be the better long-term answer; Track D should pick between adopting dot-ai vs. building it.
