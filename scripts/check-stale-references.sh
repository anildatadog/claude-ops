#!/bin/bash
# Checks memory files with "check every N weeks/days" notes and flags any that are overdue.
# Reads last-checked date from the file itself (looks for "as of YYYY-MM-DD" pattern).

MEMORY_DIR="$HOME/.claude/projects/-Users-anilkumar-pappu-Documents-Git/memory"
TODAY=$(date +%Y-%m-%d)
TODAY_EPOCH=$(date -j -f "%Y-%m-%d" "$TODAY" "+%s" 2>/dev/null || date -d "$TODAY" "+%s")

check_file() {
  local file="$1"
  local interval_days="$2"
  local label="$3"

  # Extract last-checked date (looks for "as of YYYY-MM-DD")
  local last_checked
  last_checked=$(grep -oE 'as of [0-9]{4}-[0-9]{2}-[0-9]{2}' "$file" 2>/dev/null | tail -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')

  if [[ -z "$last_checked" ]]; then
    return
  fi

  local last_epoch
  last_epoch=$(date -j -f "%Y-%m-%d" "$last_checked" "+%s" 2>/dev/null || date -d "$last_checked" "+%s")
  local days_since=$(( (TODAY_EPOCH - last_epoch) / 86400 ))

  if (( days_since >= interval_days )); then
    echo "⏰  STALE REFERENCE: $label (last checked $last_checked — ${days_since}d ago, interval ${interval_days}d)"
  fi
}

check_file "$MEMORY_DIR/reference_llmobs_api.md" 14 "LLMObs query API — check dd-trace-py + GTMSEH FAQ for updates"
