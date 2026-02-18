# Claude Code Agents & Skills

A collection of Claude Code agents, commands, and hooks for automated code review workflows.

## What's Included

### Greptile Review Loop

An autonomous agent that runs Greptile code reviews on pull requests, fixes issues, and merges when the PR passes. It loops internally — detecting the PR, checking review status, spawning code-fixer agents, pushing fixes, and waiting for re-reviews — until the PR either passes or hits a hard stop.

**Usage:**
```
/greptile-review-loop
```

See [skills/greptile-review-loop/README.md](skills/greptile-review-loop/README.md) for full documentation.

### Team Review

Spawns a team of three parallel reviewer agents (security, performance, test coverage) to analyze all changes on the current branch and produce a unified review summary.

**Usage:**
```
/team-review
```

### Code Fixer

A supporting agent used by the greptile-review-loop. Handles precise, targeted fixes for individual files based on review feedback.

## Repository Structure

```
agents/
  greptile-review-loop.md   # Autonomous review-fix-merge agent
  code-fixer.md             # Per-file code fix agent
commands/
  greptile-review-loop/     # /greptile-review-loop slash command
  team-review/              # /team-review slash command
skills/
  greptile-review-loop/     # Docs, prereqs, examples
hooks/
  post-pr-greptile-hook.sh  # Post-PR reminder (optional)
install.sh                  # Interactive installer
```

## Installation

### Automatic (Recommended)

```bash
git clone https://github.com/startappdev/agents.git
cd agents
./install.sh
```

The installer will show available agents, commands, and hooks and let you select which to install.

### Manual

```bash
git clone https://github.com/startappdev/agents.git
cd agents

# Agents
cp agents/*.md ~/.claude/agents/

# Commands
cp -r commands/* ~/.claude/commands/

# Hook (optional)
cp hooks/post-pr-greptile-hook.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/post-pr-greptile-hook.sh
```

Restart Claude Code after installation.

## Prerequisites

- **Claude Code** CLI installed and configured
- **GitHub CLI (`gh`)** — authenticated (`gh auth status`)
- **Greptile GitHub App** — for greptile-review-loop ([install](https://app.greptile.com))
- **Greptile MCP Plugin** — for greptile-review-loop (`claude mcp list | grep greptile`)

## License

MIT License — see [LICENSE](LICENSE) for details.
