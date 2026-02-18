# Greptile Review Loop Skill

An autonomous Claude Code agent that runs Greptile code reviews on pull requests, fixes issues, and merges when the PR passes. It loops internally — detecting the PR, checking review status, spawning code-fixer agents, pushing fixes, and waiting for re-reviews — until the PR either passes or hits a hard stop.

## Prerequisites

### Required

1. **Greptile GitHub App** — Install the [Greptile](https://app.greptile.com) GitHub app on your repository so it can post review comments.

2. **Greptile MCP Plugin** — The agent uses Greptile MCP tools to read reviews and comments:
   ```bash
   # Verify the Greptile MCP is configured
   claude mcp list | grep greptile
   ```
   If not installed, add it via the Greptile plugin for Claude Code.

3. **GitHub CLI (`gh`)** — Used for PR creation, commenting, and merging:
   ```bash
   gh auth status   # Verify authenticated
   ```

### Optional

4. **Post-PR Hook** — Automatically reminds you to run the review loop after creating a PR. See [Hook Setup](#hook-setup) below.

## Installation

### Automatic (Recommended)

```bash
git clone https://github.com/startappdev/agents.git
cd agents
./install.sh
```

The installer will offer to install agents, commands, and hooks interactively.

### Manual

```bash
# Agent definition (required)
cp agents/greptile-review-loop.md ~/.claude/agents/

# Slash command (required)
cp -r commands/greptile-review-loop ~/.claude/commands/

# Post-PR hook (optional)
cp hooks/post-pr-greptile-hook.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/post-pr-greptile-hook.sh
```

Restart Claude Code after installation.

## Usage

### Slash Command

After creating a PR or pushing fixes:
```
/greptile-review-loop
```

Claude will spawn the `greptile-review-loop` agent via the Task tool. The agent auto-detects the repo and latest open PR.

### Direct Task Invocation

You can also invoke the agent directly from any Claude Code session:
```
Task(
  subagent_type: "greptile-review-loop",
  description: "Greptile review-fix loop",
  prompt: "Run the full autonomous Greptile review-fix loop for the current PR."
)
```

## How It Works

The agent runs an autonomous loop:

```
DETECT latest open PR (or create one if none exists)
  |
CHECK review status
  ├── In-progress review? → WAIT for completion
  ├── Completed review?   → CHECK COMMENTS
  └── No reviews?         → TRIGGER first review → WAIT
  |
CHECK COMMENTS
  ├── Unaddressed issues? → FIX (spawn code-fixer agents)
  │                          → COMMIT → PUSH
  │                          → WAIT for auto-review (2 min)
  │                          → Loop back to CHECK COMMENTS
  └── Zero issues? → CHECK SCORE
                      ├── Score >= 4/5 → MERGE PR → DONE
                      └── Score <= 3/5 → HARD STOP
```

### Key Behaviors

- **Auto-detects** the repository, default branch, and latest open PR
- **Creates a PR** if none exists (branches from main, commits changes, pushes)
- **Spawns one code-fixer agent per file** for parallel fixes
- **Waits for auto-reviews** — Greptile auto-reviews PR updates, so the agent waits 2 minutes before manually triggering
- **Never merges** if the score is 3/5 or lower

### Hard Stops

| Condition | Meaning |
|-----------|---------|
| **MERGED** | Score >= 4/5, zero issues — PR merged successfully |
| **SCORE TOO LOW** | Score 3/5 or lower — manual review needed |
| **NOTHING TO PR** | No changes or commits to create a PR from |
| **FIXES FAILED** | TypeScript compilation fails after code-fixer ran |
| **REVIEW TIMEOUT** | Review didn't complete within 10 minutes |
| **MAX ITERATIONS** | 5 fix-review cycles (safety valve) |

## Hook Setup

The optional post-PR hook reminds you to run `/greptile-review-loop` after creating a PR.

Add this to your Claude Code `settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/post-pr-greptile-hook.sh"
          }
        ]
      }
    ]
  }
}
```

The hook detects `gh pr create` commands and prints a reminder with the PR number.

## Files Included

| File | Install Location | Purpose |
|------|-----------------|---------|
| `agents/greptile-review-loop.md` | `~/.claude/agents/` | Agent definition (tools, model, full instructions) |
| `commands/greptile-review-loop/greptile-review-loop.md` | `~/.claude/commands/` | Slash command (`/greptile-review-loop`) |
| `hooks/post-pr-greptile-hook.sh` | `~/.claude/hooks/` | Post-PR reminder hook (optional) |

## Troubleshooting

### Greptile MCP Not Found
```bash
# Check if Greptile MCP is configured
claude mcp list | grep greptile
```
Install the Greptile plugin for Claude Code if missing.

### Review Never Triggers
- Verify the Greptile GitHub app is installed on your repository
- Check that the PR is in an organization/repo that Greptile monitors
- Try manually commenting `@greptileai please review` on the PR

### Code-Fixer Agents Fail
- The agent spawns `code-fixer` subagents — ensure you have the `code-fixer` agent type available
- Check that `bunx tsc --noEmit` passes in your repo before running the loop

### Score Stuck at 3/5
The agent will not merge at 3/5 or below. Review the Greptile comments manually and address any systemic issues before re-running.

## License

This skill is part of [startappdev/agents](https://github.com/startappdev/agents) and is licensed under the MIT License.
