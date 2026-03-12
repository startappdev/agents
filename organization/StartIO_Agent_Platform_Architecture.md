# Start.io — Organizational AI Agent Platform

**Technical Architecture & Implementation Plan**

Built on Anthropic Claude Agent SDK
Version 1.0 | March 2026
Prepared for: Engineering & Product Leadership

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Technology Stack](#2-technology-stack)
3. [System Architecture](#3-system-architecture)
4. [Knowledge Repository Structure](#4-knowledge-repository-structure)
5. [MCP Server Integrations](#5-mcp-server-integrations)
6. [Agent Definitions & Specializations](#6-agent-definitions--specializations)
7. [Microsoft Teams Integration](#7-microsoft-teams-integration)
8. [Security & Governance](#8-security--governance)
9. [Hooks & Lifecycle Control](#9-hooks--lifecycle-control)
10. [Implementation Plan](#10-implementation-plan)
11. [Cost Model](#11-cost-model)
12. [Claude Code Planning Prompt](#12-claude-code-planning-prompt)

---

## 1. Executive Summary

This document defines the architecture for an internal AI agent platform at Start.io, powered by the Anthropic Claude Agent SDK. The platform will deploy server-side agents that deeply understand our company domain, infrastructure, data structures, teams, roadmap, and Jira workflows. Agents will operate in sandboxed containers, pulling organization-specific skills and hooks from a central repository, and integrating with Microsoft Teams for safe, contextual communication with employees.

The system replaces the current model of individual laptop-based Claude sessions with a centralized, scalable, and secure agent infrastructure that any team member can invoke through Teams or internal APIs.

### Key Objective

Build a fleet of domain-aware AI agents that run on infrastructure (not laptops), understand Start.io context deeply, execute complex multi-step tasks autonomously, and communicate with employees through Microsoft Teams.

### 1.1 Core Capabilities

| Capability | Description |
|---|---|
| **Domain Intelligence** | Agents loaded with company context (CLAUDE.md) covering infra, data models, teams, and conventions |
| **Task Execution** | Autonomous multi-step workflows: PRD generation, code reviews, incident triage, onboarding |
| **System Integration** | MCP servers connecting Jira, Confluence, databases, internal APIs, GitHub |
| **Communication** | Microsoft Teams bot for natural-language interaction with employees |
| **Security** | Sandboxed containers with credential proxy, audit logging, and permission boundaries |

---

## 2. Technology Stack

The platform is built entirely on Anthropic's production-grade primitives. No custom LLM orchestration frameworks are needed.

| Component | Technology | Purpose |
|---|---|---|
| Agent Runtime | Claude Agent SDK (Python) | Core agent loop, tool execution, session management |
| LLM Models | Claude Sonnet 4.5 / Opus 4.6 | Sonnet for routine tasks, Opus for complex reasoning |
| Tool Protocol | Model Context Protocol (MCP) | Standardized integration with external systems |
| Containerization | Docker + gVisor | Sandboxed execution with kernel-level isolation |
| Orchestration | Kubernetes / AWS ECS | Container lifecycle, scaling, health monitoring |
| Message Broker | AWS SQS / RabbitMQ | Task queue between Teams bot and agent containers |
| Session Store | Redis / DynamoDB | Conversation state persistence for multi-turn sessions |
| Teams Integration | Azure Bot Framework SDK | Microsoft Teams bot with Claude Agent SDK bridge |
| Knowledge Repo | Git (GitHub / GitLab) | Central CLAUDE.md, skills, hooks, agent definitions |
| Monitoring | Datadog / CloudWatch | Token usage, latency, error rates, audit logs |
| Credential Mgmt | HashiCorp Vault / AWS SM | Secrets injection via proxy outside sandbox |

### Why Claude Agent SDK?

The Agent SDK provides the same agent loop, tools, and context management that powers Claude Code, but fully programmable and server-deployable. It supports headless execution, MCP integration, subagent orchestration, streaming output, session resumption, and hooks for custom behavior. No need for LangChain, CrewAI, or custom orchestration layers.

---

## 3. System Architecture

### 3.1 High-Level Architecture

The system follows a three-tier architecture: Communication Layer (Teams), Orchestration Layer (Agent Router + Task Queue), and Execution Layer (Sandboxed Agent Containers).

```
                     COMMUNICATION LAYER
  +-----------+     +------------------+     +------------+
  |  MS Teams |---->| Azure Bot Service|---->| API Gateway|
  |  (Users)  |<----| (Webhook)        |<----| (REST/WS)  |
  +-----------+     +------------------+     +------------+
                                                    |
                    ORCHESTRATION LAYER              |
  +------------------+     +------------------+     |
  |   Agent Router   |<----|   Task Queue     |<----+
  |  (Route + Auth)  |     |  (SQS/RabbitMQ)  |
  +------------------+     +------------------+
           |
           v            EXECUTION LAYER
  +--------------------------------------------------+
  |              Kubernetes / ECS Cluster             |
  |  +------------+  +------------+  +------------+  |
  |  | Agent Pod  |  | Agent Pod  |  | Agent Pod  |  |
  |  | (Sandbox)  |  | (Sandbox)  |  | (Sandbox)  |  |
  |  +-----+------+  +-----+------+  +-----+------+  |
  |        |                |                |        |
  |  +-----v----------------v----------------v-----+  |
  |  |           MCP Server Sidecar Layer          |  |
  |  |  [Jira] [Confluence] [GitHub] [DB] [Slack]  |  |
  |  +---------------------------------------------+  |
  +--------------------------------------------------+
           |
  +--------v---------+     +------------------+
  | Knowledge Repo    |     | Credential Proxy |
  | (Git: CLAUDE.md,  |     | (Vault/Secrets   |
  |  Skills, Hooks)   |     |  Manager)        |
  +-------------------+     +------------------+
```

### 3.2 Request Lifecycle

When an employee sends a message in Teams, the following sequence executes:

1. **User Message**: Employee types a request in the Teams channel or DM (e.g., "What's the status of RNS-1234?")
2. **Bot Service**: Azure Bot Framework receives the webhook, authenticates the user, and extracts the message payload
3. **Agent Router**: Determines which agent type to invoke (Jira specialist, infra expert, general), checks rate limits, and enqueues the task
4. **Container Spin-Up**: An ephemeral container starts, clones the knowledge repo (CLAUDE.md + skills + hooks), and initializes the Claude Agent SDK
5. **Agent Execution**: The agent processes the request using its tools and MCP servers, potentially spawning subagents for parallel work
6. **Response**: Results stream back through the queue to the Teams bot, which posts the formatted response to the user
7. **Teardown**: Container is destroyed. Session ID is stored in Redis for potential follow-up conversations

### 3.3 Container Architecture (Per Agent Pod)

Each agent runs in an isolated container with the following structure:

```
  +------------------------------------------+
  |           Agent Container (gVisor)        |
  |                                           |
  |  /workspace/          (read-only mount)   |
  |    CLAUDE.md           company context     |
  |    .claude/skills/     reusable skills     |
  |    .claude/agents/     subagent defs       |
  |    .claude/hooks/      lifecycle hooks     |
  |                                           |
  |  /tmp/                 (writable tmpfs)    |
  |    scratch space for agent work            |
  |                                           |
  |  Claude Agent SDK Process                 |
  |    +-- MCP Client (connects to sidecars)  |
  |    +-- Tool Executor (Bash, Read, Edit)   |
  |    +-- Subagent Spawner                   |
  |                                           |
  |  Credential Proxy Socket (read-only)      |
  +------------------------------------------+
```

---

## 4. Knowledge Repository Structure

The knowledge repository is a Git repo that serves as the single source of truth for all agent behavior. Every agent container clones this repo at startup.

```
  startio-agent-knowledge/
  |
  +-- CLAUDE.md                    # Master company context
  +-- .claude/
  |   +-- settings.json            # Global agent settings
  |   +-- skills/
  |   |   +-- rns-prd-workflow/     # PRD generation skill
  |   |   +-- jira-analyst/         # Jira query + analysis
  |   |   +-- infra-diagnostics/    # Infrastructure checks
  |   |   +-- onboarding-guide/     # New employee helper
  |   |   +-- code-reviewer/        # Code review standards
  |   |   +-- incident-triage/      # Incident response
  |   +-- agents/
  |   |   +-- jira-specialist.md    # Subagent: Jira expert
  |   |   +-- infra-expert.md       # Subagent: Infra expert
  |   |   +-- data-analyst.md       # Subagent: Data/SQL
  |   |   +-- security-reviewer.md  # Subagent: Security
  |   +-- hooks/
  |       +-- audit-logger.js       # Log all agent actions
  |       +-- pii-filter.js         # Strip PII from output
  |       +-- cost-guard.js         # Token budget enforcer
  +-- mcp-configs/
  |   +-- jira.json                 # Jira MCP server config
  |   +-- confluence.json           # Confluence MCP config
  |   +-- github.json               # GitHub MCP config
  |   +-- postgres.json             # Database MCP config
  +-- docker/
      +-- Dockerfile                # Agent container image
      +-- entrypoint.sh             # Startup script
```

### 4.1 CLAUDE.md Structure

The CLAUDE.md file is the agent's organizational brain. It should contain:

| Section | Contents | Update Frequency |
|---|---|---|
| Company Overview | Mission, products, business model, key metrics | Quarterly |
| Team Structure | Teams, leads, responsibilities, org chart | Monthly |
| Technical Architecture | Services, databases, APIs, deployment topology | Monthly |
| Data Models | Key entities, schemas, relationships | On change |
| Coding Conventions | Language standards, PR process, testing requirements | On change |
| Roadmap | Current quarter OKRs, active initiatives, priorities | Bi-weekly |
| Jira Conventions | Board structure, ticket types, workflow states, labels | On change |
| Access & Permissions | What the agent CAN and CANNOT do (safety boundaries) | On change |

---

## 5. MCP Server Integrations

Model Context Protocol (MCP) servers are the standard way to connect agents to external systems. Each MCP server runs as a sidecar process alongside the agent container.

### 5.1 Priority Integrations

| Integration | MCP Server | Capabilities | Priority |
|---|---|---|---|
| Jira | @atlassian/jira-mcp | Read/create/update tickets, search, transitions, comments | P0 - Phase 1 |
| Confluence | @atlassian/confluence-mcp | Read/create pages, search docs, update content | P0 - Phase 1 |
| GitHub | @github/mcp-server | PRs, issues, code search, reviews, actions status | P0 - Phase 1 |
| PostgreSQL | Custom MCP | Read-only queries against production replicas | P1 - Phase 2 |
| Internal APIs | Custom MCP | Service health, deployments, feature flags | P1 - Phase 2 |
| Slack | @slack/mcp-server | Channel history, search, notifications | P2 - Phase 3 |
| Microsoft Teams | Custom MCP | Message posting, channel management | P0 - Phase 1 |
| Datadog | Custom MCP | Metrics, alerts, dashboards | P2 - Phase 3 |

### 5.2 MCP Configuration Example

Each MCP server is configured in a JSON file that the agent container loads at startup:

```json
// mcp-configs/jira.json
{
  "mcpServers": {
    "jira": {
      "type": "stdio",
      "command": "npx",
      "args": ["@atlassian/jira-mcp-server"],
      "env": {
        "JIRA_HOST": "${JIRA_HOST}",
        "JIRA_API_TOKEN": "${JIRA_TOKEN}",
        "JIRA_USER_EMAIL": "${JIRA_EMAIL}"
      }
    }
  }
}
```

> **Credential Security**: Environment variables (`${JIRA_TOKEN}`, etc.) are injected by the Credential Proxy at runtime. The agent container never has direct access to raw secrets. The proxy intercepts API calls and injects auth headers.

---

## 6. Agent Definitions & Specializations

The platform uses a parent-subagent architecture. A general-purpose Router Agent receives all requests and delegates to specialized subagents based on the task type.

### 6.1 Agent Roster

| Agent | Model | Tools | Use Cases |
|---|---|---|---|
| Router Agent (Parent) | Sonnet 4.5 | Agent, Read | Classify requests, delegate to subagents, synthesize results |
| Jira Specialist | Sonnet 4.5 | Jira MCP, Confluence MCP | Ticket status, sprint reports, PRD generation, backlog analysis |
| Infrastructure Expert | Sonnet 4.5 | Bash, DB MCP, Datadog MCP | Service health, deployment status, incident triage |
| Code Reviewer | Opus 4.6 | GitHub MCP, Read, Grep | PR reviews, security analysis, architecture feedback |
| Data Analyst | Sonnet 4.5 | DB MCP (read-only), Bash | SQL queries, data exploration, metric computation |
| Onboarding Guide | Sonnet 4.5 | Confluence MCP, Read | Answer new-hire questions, explain systems and processes |

### 6.2 Subagent Definition Example

Subagents are defined as Markdown files in `.claude/agents/`:

```markdown
# .claude/agents/jira-specialist.md
---
name: jira-specialist
description: Expert at Jira operations for Start.io RNS board
tools: jira_mcp, confluence_mcp, Read
model: sonnet
---

You are a Jira specialist for Start.io. You have deep knowledge of:
- The RNS board structure and workflow states
- How initiatives break down into epics and stories
- Sprint planning conventions and velocity tracking
- PRD generation from requirements (use rns-prd-workflow skill)

When asked about ticket status, always provide:
1. Current state and assignee
2. Blockers or dependencies
3. Related tickets in the same epic
4. Sprint context and timeline
```

### 6.3 Agent SDK Implementation

The Router Agent is implemented using the Claude Agent SDK in Python:

```python
# agent_router.py
from claude_agent_sdk import query, ClaudeAgentOptions, AgentDefinition

async def handle_request(user_message, session_id=None):
    options = ClaudeAgentOptions(
        model="claude-sonnet-4-5-20250514",
        allowed_tools=["Agent", "Read"],
        system_prompt=open("CLAUDE.md").read(),
        resume=session_id,
        mcp_servers=load_mcp_configs(),
        agents={
            "jira": load_agent_def("jira-specialist"),
            "infra": load_agent_def("infra-expert"),
            "code": load_agent_def("code-reviewer"),
            "data": load_agent_def("data-analyst"),
        },
        hooks={
            "on_tool_call": audit_logger,
            "on_response": pii_filter,
        }
    )

    result = ""
    async for msg in query(prompt=user_message, options=options):
        if hasattr(msg, "text"):
            result += msg.text
    return result
```

---

## 7. Microsoft Teams Integration

The Teams integration serves as the primary user interface for the agent platform. Employees interact with agents through direct messages or channel mentions, just like chatting with a colleague.

### 7.1 Architecture

```
  +-------------------+     +--------------------+
  | Microsoft Teams   |     | Azure Bot Service  |
  | @StartAgent help  |---->| (Webhook endpoint) |
  |                   |<----|                     |
  +-------------------+     +---------+----------+
                                      |
                            +---------v----------+
                            | Teams Bot Service   |
                            | (Azure Function)    |
                            |                     |
                            | - Auth middleware    |
                            | - Rate limiter      |
                            | - Session manager   |
                            | - Response formatter|
                            +---------+----------+
                                      |
                            +---------v----------+
                            | Agent Task Queue   |
                            | (SQS / RabbitMQ)   |
                            +---------+----------+
                                      |
                            +---------v----------+
                            | Claude Agent SDK   |
                            | (Ephemeral Pod)    |
                            +--------------------+
```

### 7.2 Interaction Patterns

| Pattern | Trigger | Example |
|---|---|---|
| Direct Message | DM to @StartAgent | "What's the status of RNS-1234?" |
| Channel Mention | @StartAgent in channel | "@StartAgent summarize this sprint's progress" |
| Proactive Alert | Scheduled agent task | Daily standup summary posted to #engineering |
| Threaded Follow-up | Reply in existing thread | "Can you also check the related PRs?" |
| Approval Flow | Agent asks for confirmation | "I found 3 conflicts. Should I create tickets?" |

### 7.3 Session Management

Multi-turn conversations are supported through session persistence:

- Each Teams thread maps to a Claude Agent SDK session ID
- Session state is stored in Redis with a 24-hour TTL
- Follow-up messages in the same thread resume the existing session
- New threads create fresh sessions with full company context
- Session resumption uses the SDK's built-in `resume` parameter

> **Safety Boundary**: Agents can READ data from integrated systems but require explicit user confirmation in the Teams thread before WRITING (creating tickets, posting to channels, modifying configurations). This mirrors the approval flow pattern used in Claude's desktop application.

---

## 8. Security & Governance

### 8.1 Defense in Depth

| Layer | Mechanism | Implementation |
|---|---|---|
| Container Isolation | gVisor kernel-level sandbox | Docker `--runtime=runsc` with dropped capabilities |
| Network Controls | Allowlisted egress only | Agent can only reach MCP sidecars and credential proxy |
| Credential Isolation | Proxy pattern | Agent never sees raw tokens; proxy injects headers |
| Filesystem | Read-only workspace + tmpfs scratch | Knowledge repo mounted read-only; `/tmp` writable |
| Permission Boundaries | Tool-level allow/deny lists | Each agent type has explicit tool permissions |
| PII Protection | Output filter hook | `pii-filter.js` strips sensitive data before responses |
| Audit Trail | Action logging hook | Every tool call logged with timestamp, user, and context |
| Cost Controls | Token budget hook | `cost-guard.js` enforces per-request and daily limits |
| User Auth | Azure AD integration | Teams bot validates user identity via SSO |
| Rate Limiting | Per-user throttle | Prevents abuse; configurable per team/role |

### 8.2 Permission Matrix

Each agent type has explicit tool permissions defined in the Agent SDK configuration:

| Agent | Read (Jira/Confluence/DB) | Write (Create/Update) | Execute (Bash/Deploy) | Approve (Human-in-loop) |
|---|---|---|---|---|
| Router Agent | No (delegates) | No | No | N/A |
| Jira Specialist | Yes | Yes (with approval) | No | Required for writes |
| Infra Expert | Yes | No | Read-only commands | Required for actions |
| Code Reviewer | Yes | Comment on PRs | No | Auto for comments |
| Data Analyst | Yes (read replicas) | No | SELECT queries only | N/A |

---

## 9. Hooks & Lifecycle Control

Hooks intercept the agent at key lifecycle points, enabling audit logging, cost control, PII filtering, and custom behavior without modifying agent logic.

### 9.1 Hook Types

| Hook | Trigger Point | Purpose | Example |
|---|---|---|---|
| `on_tool_call` | Before any tool executes | Audit logging, permission checks | Log every Jira query to audit trail |
| `on_tool_result` | After tool returns | PII filtering, data sanitization | Strip email addresses from DB results |
| `on_response` | Before response sent to user | Output formatting, safety checks | Ensure no internal URLs leak to users |
| `on_error` | When tool execution fails | Error handling, alerting | Notify #ops channel on repeated failures |
| `on_session_start` | Container initialization | Context loading, auth validation | Load latest CLAUDE.md from Git |
| `on_session_end` | Before container teardown | Cleanup, metric reporting | Report token usage to cost dashboard |

### 9.2 Audit Logger Hook Example

```python
# hooks/audit_logger.py
import json, datetime
from typing import Any

async def audit_logger(tool_name: str, args: dict, context: Any):
    """Log every tool invocation for compliance and debugging."""
    log_entry = {
        "timestamp": datetime.datetime.utcnow().isoformat(),
        "user": context.user_id,
        "team": context.team,
        "agent": context.agent_name,
        "tool": tool_name,
        "args_summary": summarize_args(args),  # Never log raw secrets
        "session_id": context.session_id,
    }
    await write_to_audit_log(json.dumps(log_entry))
    return True  # Allow tool execution to proceed
```

---

## 10. Implementation Plan

> **Planning Approach**: This plan is designed to be taken directly into Claude Code for detailed implementation planning. Each phase produces a working, testable deliverable. Ship each phase before starting the next.

### Phase 1: Foundation (Weeks 1-3)

**Goal**: A single agent running headless that understands Start.io and can query Jira.

| Task | Owner | Deliverable |
|---|---|---|
| Set up Claude Agent SDK (Python) in a Docker container | Platform Eng | Working container image |
| Create CLAUDE.md with company context (infra, teams, data models) | Engineering + Product | CLAUDE.md in Git repo |
| Configure Jira MCP server with Start.io RNS board access | Platform Eng | jira.json MCP config |
| Configure Confluence MCP server | Platform Eng | confluence.json MCP config |
| Port rns-prd-workflow skill to server-compatible format | Platform Eng | Skill in .claude/skills/ |
| Implement audit-logger hook | Platform Eng | hooks/audit_logger.py |
| Test headless execution via CLI | Platform Eng | Passing integration tests |

### Phase 2: Multi-Agent & Integrations (Weeks 4-6)

**Goal**: Specialized subagents with MCP connections to core systems.

| Task | Owner | Deliverable |
|---|---|---|
| Define Jira Specialist subagent | Platform Eng | jira-specialist.md |
| Define Infrastructure Expert subagent | Platform Eng + DevOps | infra-expert.md |
| Define Code Reviewer subagent | Platform Eng | code-reviewer.md |
| Implement Router Agent with delegation logic | Platform Eng | agent_router.py |
| Configure GitHub MCP server | Platform Eng | github.json config |
| Configure PostgreSQL MCP (read-only replicas) | Platform Eng + DBA | postgres.json config |
| Implement PII filter and cost guard hooks | Platform Eng + Security | hooks/pii_filter.py, cost_guard.py |
| Set up container orchestration (K8s/ECS) | DevOps | Deployment manifests |
| Implement credential proxy | Security + DevOps | Proxy service + Vault config |

### Phase 3: Teams Integration (Weeks 7-9)

**Goal**: Employees can chat with agents through Microsoft Teams.

| Task | Owner | Deliverable |
|---|---|---|
| Register Azure Bot in Teams admin | IT + Platform Eng | Bot registration |
| Build Teams bot service (Azure Functions) | Platform Eng | Bot webhook handler |
| Implement session management (Redis) | Platform Eng | Session store + resume logic |
| Build task queue (SQS/RabbitMQ) | Platform Eng | Queue service |
| Implement response formatter (Teams Adaptive Cards) | Platform Eng | Formatted rich responses |
| Implement approval flow for write operations | Platform Eng | Confirmation cards in Teams |
| User acceptance testing with pilot team | Product + Eng | Feedback report |

### Phase 4: Production Hardening (Weeks 10-12)

**Goal**: Production-grade reliability, monitoring, and governance.

| Task | Owner | Deliverable |
|---|---|---|
| Set up monitoring dashboard (Datadog/CloudWatch) | DevOps | Monitoring dashboard |
| Implement rate limiting per user/team | Platform Eng | Rate limiter middleware |
| Add proactive agent tasks (daily standups, sprint alerts) | Platform Eng + Product | Scheduled agent tasks |
| Security audit of container isolation and network controls | Security | Audit report |
| Performance optimization (prompt caching, model routing) | Platform Eng | Latency benchmarks |
| Documentation and runbooks | Platform Eng | Operations playbook |
| Organization-wide rollout | Product + IT | Rollout plan + training |

---

## 11. Cost Model

### 11.1 Token Cost Estimates

Costs are based on current Anthropic API pricing. The Agent SDK uses the same API billing.

| Model | Input (per 1M tokens) | Output (per 1M tokens) | Typical Use |
|---|---|---|---|
| Claude Sonnet 4.5 | $3.00 | $15.00 | Routine tasks: Jira queries, status checks, summaries |
| Claude Opus 4.6 | $15.00 | $75.00 | Complex tasks: code review, architecture analysis, PRDs |
| Claude Haiku 4.5 | $0.80 | $4.00 | Simple routing, classification, formatting |

### 11.2 Monthly Projections

Based on a team of 50 engineers with moderate daily usage:

| Scenario | Daily Requests | Avg Tokens/Req | Primary Model | Est. Monthly Cost |
|---|---|---|---|---|
| Conservative | 100 requests/day | ~8K tokens | Sonnet 4.5 | $500-800 |
| Moderate | 300 requests/day | ~12K tokens | Sonnet 4.5 + Opus | $2,000-3,500 |
| Heavy | 600 requests/day | ~15K tokens | Mixed | $5,000-8,000 |

> **Cost Optimization Strategies**: Use Haiku 4.5 for routing and classification. Use prompt caching for repeated CLAUDE.md loads (up to 90% reduction on cached input). Use Batch API for non-urgent tasks (50% discount). The cost-guard hook enforces per-request and daily budgets.

---

## 12. Claude Code Planning Prompt

Use the following prompt directly in Claude Code to begin implementation planning. Copy this into a Claude Code session with Plan mode enabled.

```
/plan

I am building an internal AI agent platform for Start.io using the
Anthropic Claude Agent SDK (Python). The platform will:

1. Run server-side agents in Docker containers with gVisor isolation
2. Use a Git-based knowledge repository with CLAUDE.md, skills, hooks,
   and subagent definitions
3. Connect to Jira, Confluence, GitHub, and PostgreSQL via MCP servers
4. Integrate with Microsoft Teams as the primary user interface
5. Use a parent Router Agent that delegates to specialized subagents
   (Jira Specialist, Infra Expert, Code Reviewer, Data Analyst)

For Phase 1, I need to:
- Set up a Python project with claude-agent-sdk
- Create the knowledge repo structure (CLAUDE.md, .claude/skills,
  .claude/agents, .claude/hooks)
- Configure Jira and Confluence MCP servers
- Build a Docker container that clones the knowledge repo at startup
- Implement the audit-logger hook
- Create the Jira Specialist subagent definition
- Test headless execution with: "What is the status of RNS-1234?"

Please create a detailed implementation plan with file structure,
dependencies, configuration files, and a working prototype.
Start with the project scaffolding.
```

### 12.1 Key Reference Documentation

- **Agent SDK**: platform.claude.com/docs/en/agent-sdk/overview
- **Hosting**: platform.claude.com/docs/en/agent-sdk/hosting
- **Security**: platform.claude.com/docs/en/agent-sdk/secure-deployment
- **Subagents**: code.claude.com/docs/en/sub-agents.md
- **MCP**: code.claude.com/docs/en/mcp.md
- **Hooks**: code.claude.com/docs/en/hooks.md
- **Headless Mode**: code.claude.com/docs/en/headless.md

---

*End of Document*
