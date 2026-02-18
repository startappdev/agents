# Greptile Review Loop — Usage Examples

## Example 1: Standard PR Review Flow

You've just created a PR and want Greptile to review, fix issues, and merge:

```
User: /greptile-review-loop

Claude: I'll use the greptile-review-loop agent to run the autonomous review-fix loop.
[Spawns greptile-review-loop agent]

Agent detects:
  Repository: startappdev/my-app
  Branch: feature/add-auth → main
  PR: #42

Agent output:
  ## Greptile Review Loop — Final Report for PR #42

  **Repository**: startappdev/my-app
  **Branch**: feature/add-auth → main
  **Iterations**: 2 fix-review cycles completed
  **Final Status**: MERGED
  **Final Score**: 4/5

  ### Loop History:
  | Iteration | Action | Issues Found | Files Fixed | Commit |
  |-----------|--------|-------------|-------------|--------|
  | 1 | Fixed existing issues | 3 | 2 files | abc1234 |
  | 2 | Review clean | 0 | — | — |

  ### Result:
  - [MERGED] PR #42 merged with score 4/5 — branch deleted
```

## Example 2: No Open PR — Agent Creates One

You have local changes but haven't created a PR yet:

```
User: I pushed my changes, can you review them?

Claude: I'll use the greptile-review-loop agent to handle the review.
[Spawns greptile-review-loop agent]

Agent detects:
  No open PR for branch feature/update-api
  → Creates PR automatically via `gh pr create --fill`
  → PR #55 created
  → Waits for Greptile auto-review
  → Proceeds with review loop
```

## Example 3: Score Too Low — Hard Stop

Sometimes the code needs more work than automated fixes can handle:

```
Agent output:
  ## Greptile Review Loop — Final Report for PR #38

  **Repository**: startappdev/my-app
  **Branch**: feature/new-endpoint → main
  **Iterations**: 1 fix-review cycle completed
  **Final Status**: SCORE TOO LOW
  **Final Score**: 2/5

  ### Result:
  - [HARD STOP] Score too low (2/5) — review the PR manually
    and address architectural concerns before re-running
```

## Example 4: After Pushing Manual Fixes

You fixed some issues yourself and want to check if Greptile is satisfied:

```
User: I pushed fixes for the review comments, can you check if Greptile is happy?

Claude: I'll trigger a new Greptile review to verify the fixes.
[Spawns greptile-review-loop agent]

Agent:
  → Detects existing completed review with 0 unaddressed comments
  → Score is 4/5
  → Merges PR #47
```

## Example 5: Multiple Fix Iterations

Complex PRs may need several rounds:

```
Agent output:
  ## Greptile Review Loop — Final Report for PR #63

  **Repository**: startappdev/platform
  **Branch**: feature/billing-refactor → main
  **Iterations**: 3 fix-review cycles completed
  **Final Status**: MERGED
  **Final Score**: 5/5

  ### Loop History:
  | Iteration | Action | Issues Found | Files Fixed | Commit |
  |-----------|--------|-------------|-------------|--------|
  | 1 | Fixed initial issues | 8 | 5 files | a1b2c3d |
  | 2 | Fixed new issues | 3 | 2 files | e4f5g6h |
  | 3 | Review clean | 0 | — | — |

  ### Result:
  - [MERGED] PR #63 merged with score 5/5 — branch deleted
```
