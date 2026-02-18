#!/bin/bash
# post-pr-greptile-hook.sh
#
# Hook script that runs after Claude Code creates a PR.
# Notifies the user that Greptile will auto-review the PR.
#
# NOTE: Greptile automatically reviews new PRs via its GitHub app.
# This hook does NOT trigger a review — it only reminds the user
# to run /greptile-review-loop once the auto-review completes.
#
# Environment variables (set by Claude Code hooks):
#   CLAUDE_TOOL_INPUT  - JSON input to the tool
#   CLAUDE_TOOL_OUTPUT - Output from the tool (for PostToolUse)

set -euo pipefail

LOG_FILE="${HOME}/.claude/greptile-hook.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Check if the command was a PR creation
is_pr_creation() {
    local input="${CLAUDE_TOOL_INPUT:-}"
    local output="${CLAUDE_TOOL_OUTPUT:-}"

    if echo "$input" | grep -q "gh pr create"; then
        return 0
    fi

    if echo "$output" | grep -qE "github\.com/.*/pull/[0-9]+"; then
        return 0
    fi

    return 1
}

# Extract PR number from output
get_pr_number() {
    local output="${CLAUDE_TOOL_OUTPUT:-}"
    echo "$output" | grep -oE "https://github\.com/[^/]+/[^/]+/pull/[0-9]+" | head -1 | grep -oE "[0-9]+$"
}

main() {
    if ! is_pr_creation; then
        exit 0
    fi

    local pr_number
    pr_number=$(get_pr_number)

    if [ -z "$pr_number" ]; then
        log "PR created but could not extract PR number"
        exit 0
    fi

    log "PR #$pr_number created — Greptile will auto-review"

    cat << EOF

Greptile will automatically review PR #$pr_number (typically 2-5 minutes).

To monitor the review and fix any issues, run:
  /greptile-review-loop

EOF
}

main "$@"
