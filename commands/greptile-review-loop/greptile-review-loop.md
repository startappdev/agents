# Greptile Review Loop

Autonomous review-fix loop: detects the latest open PR, checks review status, fixes issues, waits for auto-reviews, and merges when score >= 4/5. Works across any repository.

## Instructions

You MUST use the Task tool to spawn the `greptile-review-loop` agent. Do NOT execute these steps yourself.

**IMPORTANT**: Spawn the agent using the Task tool like this:

```
Task(
  subagent_type: "greptile-review-loop",
  description: "Greptile review-fix loop",
  prompt: "Run the full autonomous Greptile review-fix loop for the current PR.

CRITICAL RULES:
1. Auto-detect the repo and latest open PR. Do NOT ask the user for PR numbers.
2. If NO open PR exists: create one automatically (create branch if on main, stage+commit changes, push, gh pr create). Then proceed.
3. Check if a Greptile review is in-progress — if so, WAIT for it to complete.
4. If a completed review exists with comments, DO NOT trigger a new review. Fix existing unaddressed comments first.
5. If NO review exists at all (zero in-progress, zero completed), trigger the first review.
6. After fixing issues and pushing, WAIT 2 minutes for Greptile to auto-trigger a review. Only manually trigger if no auto-review starts.
7. Loop: check comments → fix → push → wait for review → repeat until clean.
8. When zero unaddressed comments remain AND score >= 4/5, MERGE the PR.
9. NEVER merge if score is 3/5 or lower.
10. NEVER trigger a review if one is in-progress or if a completed review already exists (except as 2-min fallback after push).
11. Spawn one code-fixer agent per file for parallel fixes."
)
```

## What the Agent Does

The agent runs an **autonomous loop** — it does NOT return between iterations:

```
DETECT latest open PR
  → No open PR? CREATE one (branch if needed, commit, push, gh pr create)
CHECK review status:
  → In-progress review? WAIT for completion → CHECK COMMENTS
  → Completed review exists? CHECK COMMENTS (do NOT trigger new review)
  → No reviews at all? TRIGGER first review → WAIT → CHECK COMMENTS
CHECK COMMENTS:
  → Unaddressed issues? FIX (spawn code-fixers) → COMMIT → PUSH
    → WAIT 2 min for auto-review → trigger if needed → WAIT → CHECK COMMENTS
  → Zero issues? CHECK SCORE
    → Score >= 4/5? MERGE PR → DONE
    → Score <= 3/5? HARD STOP (do not merge)
```

### Hard Stops (agent exits the loop):
- **MERGED**: Zero issues, score >= 4/5 — PR merged and branch deleted
- **SCORE TOO LOW**: Score is 3/5 or lower — cannot merge
- **NOTHING TO PR**: No changes or commits to create a PR from
- **FIXES FAILED**: TypeScript compilation fails after code-fixer ran
- **REVIEW TIMEOUT**: Review didn't complete within 10 minutes
- **MAX ITERATIONS**: 5 fix-review cycles completed without passing (safety valve)

## After the Agent Returns

The agent returns a **final report** with loop history. Based on the final status:

- **MERGED**: PR is clean and has been merged
- **SCORE TOO LOW**: Score is 3/5 or lower — review the PR manually
- **NOTHING TO PR**: No changes exist to create a PR — make changes first
- **FIXES FAILED**: Investigate tsc errors manually, then run again
- **REVIEW TIMEOUT**: Check if Greptile is responsive, then run again
- **MAX ITERATIONS**: Review remaining issues manually or run again

## Usage

After creating a PR or pushing fixes:
```
/greptile-review-loop
```
