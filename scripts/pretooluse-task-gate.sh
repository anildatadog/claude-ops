#!/usr/bin/env bash
# pretooluse-task-gate.sh — Claude Code PreToolUse hook
# Blocks Edit/Write if 3+ files modified in session and no task is in_progress.
# File count = staged + unstaged tracked changes + untracked files.
# Sentinel: /tmp/claude-task-active-YYYYMMDD (date-scoped, auto-expires at midnight)

SENTINEL="/tmp/claude-task-active-$(date +%Y%m%d)"
LOGFILE="${HOOK_LOG:-$HOME/.claude/hook-log.txt}"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)

log() { echo "$TIMESTAMP PRETOOLUSE $1" >> "$LOGFILE"; }

# Not a git repo → pass (e.g. editing ~/.claude files directly)
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -z "$GIT_ROOT" ]]; then
  log "PASS no_git_repo"
  exit 0
fi

# Count all changed files: staged + unstaged tracked + untracked (matches stop-hook.sh pattern)
# Hook only fires for Edit|Write — tool filtering is handled by settings.json matcher
TOTAL=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')

# Threshold not reached → pass
if [[ "$TOTAL" -le 2 ]]; then
  log "PASS file_count:${TOTAL}"
  exit 0
fi

# Task is in_progress → pass
if [[ -f "$SENTINEL" ]]; then
  TASK=$(cat "$SENTINEL" 2>/dev/null || echo "unknown")
  log "PASS task_active:${TASK}"
  exit 0
fi

# Block
log "BLOCK no_task:file_count:${TOTAL}"
echo "BLOCKED: ${TOTAL} files modified with no active task." >&2
echo "Use TaskCreate to create a task, then TaskUpdate { status: in_progress } to open the gate." >&2
echo "Note: TaskCreate alone does NOT open the gate — TaskUpdate to in_progress is required." >&2
exit 2
