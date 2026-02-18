# Team Review

Spawn an agent team with three specialized reviewers to analyze all changes on the current branch. Each reviewer focuses on a different dimension: security, performance, and test coverage.

## Instructions

You MUST create a team and spawn three reviewer agents using the TeamCreate and Task tools. Do NOT perform the reviews yourself.

### Step 1: Determine the diff

Run this bash command to capture the changes to review:

```bash
git diff main...HEAD
```

If there is no diff (branch is clean or same as main), also check for uncommitted changes:

```bash
git diff
git diff --cached
```

If there are truly no changes at all, inform the user and stop.

### Step 2: Create the team

Use the TeamCreate tool:

```
TeamCreate(
  team_name: "code-review",
  description: "Three-reviewer team analyzing branch changes for security, performance, and test coverage"
)
```

### Step 3: Create tasks

Create three tasks using TaskCreate — one for each reviewer:

1. **Security Review** — subject: "Review changes for security implications"
2. **Performance Review** — subject: "Review changes for performance impact"
3. **Test Coverage Review** — subject: "Review changes for test coverage gaps"

### Step 4: Spawn three reviewer agents IN PARALLEL

Spawn all three agents in a single message using the Task tool. Each agent should be `general-purpose` type with `team_name: "code-review"`.

**Security Reviewer:**
```
Task(
  subagent_type: "general-purpose",
  name: "security-reviewer",
  team_name: "code-review",
  description: "Security review of changes",
  prompt: "You are a security reviewer. Your job is to review all code changes on this branch for security implications.

Run: git diff main...HEAD

Analyze every changed file for:
- Injection vulnerabilities (SQL, XSS, command injection, template injection)
- Authentication/authorization gaps or bypasses
- Sensitive data exposure (secrets, tokens, PII in logs or URLs)
- Insecure dependencies or unsafe API usage
- CSRF, SSRF, open redirect, or path traversal risks
- Unsafe deserialization or eval usage
- Missing input validation or sanitization at trust boundaries
- Hardcoded credentials or secrets

For each finding, report:
- File and line number
- Severity (Critical / High / Medium / Low)
- Description of the vulnerability
- Suggested fix

If no security issues are found, explicitly state that.

After completing your review, claim and complete your task in the task list, then send your findings to the team lead."
)
```

**Performance Reviewer:**
```
Task(
  subagent_type: "general-purpose",
  name: "performance-reviewer",
  team_name: "code-review",
  description: "Performance review of changes",
  prompt: "You are a performance reviewer. Your job is to review all code changes on this branch for performance impact.

Run: git diff main...HEAD

Analyze every changed file for:
- Unnecessary re-renders in React components (missing memoization, inline objects/functions in JSX)
- N+1 query patterns or redundant database calls
- Missing pagination or unbounded data fetching
- Large bundle impact (heavy imports that could be lazy-loaded or tree-shaken)
- Expensive computations in render paths (should be in useMemo/useCallback)
- Memory leaks (event listeners not cleaned up, subscriptions not unsubscribed)
- Blocking operations on the main thread
- Inefficient data structures or algorithms
- Missing indexes or slow query patterns in Convex functions

For each finding, report:
- File and line number
- Impact (High / Medium / Low)
- Description of the performance concern
- Suggested optimization

If no performance issues are found, explicitly state that.

After completing your review, claim and complete your task in the task list, then send your findings to the team lead."
)
```

**Test Coverage Reviewer:**
```
Task(
  subagent_type: "general-purpose",
  name: "test-reviewer",
  team_name: "code-review",
  description: "Test coverage review of changes",
  prompt: "You are a test coverage reviewer. Your job is to review all code changes on this branch and assess whether they have adequate test coverage.

Run: git diff main...HEAD

Then examine the test files in the project to understand existing test patterns:
- Find test files with: git ls-files '*.test.*' '*.spec.*'
- Understand the test framework and patterns used

For each changed file, assess:
- Does this file have corresponding tests? If not, should it?
- Are new functions/components covered by tests?
- Are edge cases and error paths tested?
- Are integration points tested (API calls, database queries, auth flows)?
- Are there changes to business logic without updated tests?
- Do existing tests still cover the modified behavior, or are they now stale?

For each finding, report:
- File that needs test coverage
- What specifically is untested
- Priority (High / Medium / Low) based on risk
- Suggested test cases to add

If test coverage is adequate, explicitly state that.

After completing your review, claim and complete your task in the task list, then send your findings to the team lead."
)
```

### Step 5: Collect and summarize results

Wait for all three reviewers to report back. Once all three have completed:

1. Compile their findings into a unified review summary
2. Group by severity/priority
3. Present to the user with clear sections:
   - **Security Findings** (with severity)
   - **Performance Findings** (with impact)
   - **Test Coverage Gaps** (with priority)
   - **Overall Assessment** — a brief verdict on whether the changes are ready to merge
4. Clean up the team with TeamDelete

## Usage

```
/team-review
```
