#!/usr/bin/env bash
# codex-pr-review.sh — PostToolUse hook
# Detects when a Bash call creates a GitHub PR and spawns a background review worker.
# Exits immediately so Claude Code is not blocked waiting for the OpenAI API call.

LOGFILE="${HOOK_LOG:-$HOME/.claude/hook-log.txt}"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)
log() { echo "$TIMESTAMP POSTTOOLUSE codex-pr-review $1" >> "$LOGFILE"; }

# Parse bash output from hook stdin
INPUT=$(cat)
BASH_OUTPUT=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('output', ''))
except Exception:
    pass
" 2>/dev/null)

# Look for a GitHub PR URL in the output
PR_URL=$(echo "$BASH_OUTPUT" | grep -oE 'https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/pull/[0-9]+' | head -1)
if [[ -z "$PR_URL" ]]; then
    exit 0
fi

log "INFO: PR URL detected: $PR_URL — spawning background review"

# Spawn background worker and exit immediately
nohup bash "$HOME/.claude/scripts/codex-pr-review-worker.sh" "$PR_URL" >> "$LOGFILE" 2>&1 &

exit 0
