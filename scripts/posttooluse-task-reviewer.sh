#!/usr/bin/env bash
# posttooluse-task-reviewer.sh — Claude Code PostToolUse hook
# On TaskUpdate:
#   - in_progress → write /tmp/claude-task-active-YYYYMMDD sentinel
#   - completed/cancelled → delete sentinel; on completed, inject diff + review prompt
# Exit 0 always (context injection, not a block).
# Note: 'done' handled as alias for 'completed' — remove if TaskUpdate never returns 'done'.

SENTINEL="/tmp/claude-task-active-$(date +%Y%m%d)"
LOGFILE="${HOOK_LOG:-$HOME/.claude/hook-log.txt}"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)

log() { echo "$TIMESTAMP POSTTOOLUSE TASK $1" >> "$LOGFILE"; }

INPUT=$(cat)

TOOL=$(echo "$INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('tool_name', 'unknown'))
" 2>/dev/null)

# Only act on task tools
if [[ "$TOOL" != "TaskUpdate" && "$TOOL" != "TaskCreate" ]]; then
  exit 0
fi

# Extract status and title from tool_result (the returned task object)
STATUS=$(echo "$INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('tool_result')
if r is None or not isinstance(r, (dict, str)):
    print(''); sys.exit(0)
if isinstance(r, dict):
    print(r.get('status', ''))
else:
    import re
    m = re.search(r'\"status\":\s*\"([^\"]+)\"', r)
    print(m.group(1) if m else '')
" 2>/dev/null)

TITLE=$(echo "$INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('tool_result')
if r is None or not isinstance(r, (dict, str)):
    print('unknown task'); sys.exit(0)
if isinstance(r, dict):
    print(r.get('title', r.get('name', 'unknown task')))
else:
    import re
    m = re.search(r'\"title\":\s*\"([^\"]+)\"', r)
    print(m.group(1) if m else 'unknown task')
" 2>/dev/null)

case "$STATUS" in
  in_progress)
    echo "$TITLE" > "$SENTINEL"
    log "SENTINEL_WRITE:${TITLE}"
    ;;
  completed|done)
    # 'done' included as alias — verify against TaskUpdate API output if gate behaves unexpectedly
    rm -f "$SENTINEL"
    log "SENTINEL_DELETE:${TITLE}"
    # Capture git diff (first 200 lines — avoids context overflow on large diffs)
    DIFF=$(git diff HEAD 2>/dev/null | head -200)
    DIFF_LINES=$(printf '%s' "$DIFF" | wc -l | tr -d ' ')
    # Inject review context (exit 0 = PostToolUse context injection)
    echo ""
    echo "[Task Reviewer] Task '${TITLE}' just completed."
    echo "--- git diff HEAD (${DIFF_LINES} lines) ---"
    echo "$DIFF"
    echo "---"
    echo "Review the diff above and verify:"
    echo "1. Implementation matches the task description"
    echo "2. No obvious gaps: missing error handling, untested paths, incomplete implementation"
    echo "3. No unintended side-effects in unrelated files"
    echo "If issues found: use TaskUpdate to revert status to in_progress and fix before marking complete again."
    echo ""
    ;;
  cancelled)
    rm -f "$SENTINEL"
    log "SENTINEL_DELETE_CANCELLED:${TITLE}"
    ;;
  *)
    log "IGNORED_STATUS:${STATUS}:${TITLE}"
    ;;
esac

exit 0
