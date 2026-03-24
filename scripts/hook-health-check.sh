#!/usr/bin/env bash
# hook-health-check.sh — verifies hooks are registered and surfaces prior warnings
# Called from worktree-health.sh at SessionStart

SETTINGS="$HOME/.claude/settings.json"
LOGFILE="$HOME/.claude/hook-log.txt"
ISSUES=0

# 1. Verify Stop hook is registered
if ! python3 -c "import json; d=json.load(open('$SETTINGS')); hooks=d.get('hooks',{}); stop=hooks.get('Stop',[]); exit(0 if stop else 1)" 2>/dev/null; then
  echo "⚠️  Hook health: Stop hook NOT registered in settings.json"
  ISSUES=$((ISSUES + 1))
fi

# 2. Verify PostToolUse hook is registered
if ! python3 -c "import json; d=json.load(open('$SETTINGS')); hooks=d.get('hooks',{}); ptu=hooks.get('PostToolUse',[]); exit(0 if ptu else 1)" 2>/dev/null; then
  echo "⚠️  Hook health: PostToolUse hook NOT registered in settings.json"
  ISSUES=$((ISSUES + 1))
fi

# 3. Check for anomalous Stop hook silence (zero blocks this week with git activity)
if [[ -f "$LOGFILE" ]]; then
  WEEK_AGO=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d 2>/dev/null)
  RECENT_BLOCKS=$(awk -v since="$WEEK_AGO" '$1 >= since && /STOP BLOCK/' "$LOGFILE" | wc -l | tr -d ' ')
  RECENT_ENTRIES=$(awk -v since="$WEEK_AGO" '$1 >= since' "$LOGFILE" | wc -l | tr -d ' ')
  if [[ "$RECENT_ENTRIES" -gt 10 && "$RECENT_BLOCKS" -eq 0 ]]; then
    echo "⚠️  Hook health: Stop hook had 0 blocks in 7 days with $RECENT_ENTRIES log entries — may not be firing correctly"
    ISSUES=$((ISSUES + 1))
  fi
fi

# 4. Surface warnings from previous session (yesterday's entries)
if [[ -f "$LOGFILE" ]]; then
  YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d 2>/dev/null)
  PREV_WARNINGS=$(grep "$YESTERDAY" "$LOGFILE" 2>/dev/null | grep "WARN\|BLOCK" | wc -l | tr -d ' ')
  if [[ "$PREV_WARNINGS" -gt 0 ]]; then
    echo "ℹ️  Hook health: $PREV_WARNINGS warning(s)/block(s) from previous session:"
    grep "$YESTERDAY" "$LOGFILE" | grep "WARN\|BLOCK" | sed 's/^/    /'
  fi
fi

[[ "$ISSUES" -eq 0 ]] && echo "✓ Hooks healthy"
