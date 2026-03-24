#!/usr/bin/env bash
# posttooluse-hook.sh — Claude Code PostToolUse hook
# Detects empty/null tool results and emits a throttled warning.
# Throttle key: <tool_name>:<result_type> — warns once per key per session date.

LOGFILE="${HOOK_LOG:-$HOME/.claude/hook-log.txt}"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)
TODAY=$(date +%Y-%m-%d)

# Read tool call input from stdin
INPUT=$(cat)
TOOL=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_name','unknown'))" 2>/dev/null)

# Detect result type
RESULT_TYPE=$(echo "$INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('tool_result')
if r is None: print('null')
elif r == []: print('empty_array')
elif r == {}: print('empty_object')
elif isinstance(r, str) and r.strip() == '': print('empty_string')
else: print('ok')
" 2>/dev/null)

# Parse error or unknown input → exit silently
[[ -z "$RESULT_TYPE" ]] && exit 0

# Non-empty → pass silently
[[ "$RESULT_TYPE" == "ok" ]] && exit 0

THROTTLE_KEY="${TOOL}:${RESULT_TYPE}"

# Check throttle: already warned today for this key?
if grep -q "POSTTOOLUSE WARN ${THROTTLE_KEY}" "$LOGFILE" 2>/dev/null; then
  if grep "POSTTOOLUSE WARN ${THROTTLE_KEY}" "$LOGFILE" | grep -q "$TODAY"; then
    exit 0  # already warned today, suppress
  fi
fi

# Log and emit warning
echo "$TIMESTAMP POSTTOOLUSE WARN ${THROTTLE_KEY}" >> "$LOGFILE"
echo "WARNING: ${TOOL} returned ${RESULT_TYPE}. Verify environment before proceeding."
exit 0
