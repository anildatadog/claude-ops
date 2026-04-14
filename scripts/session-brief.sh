#!/usr/bin/env bash
# session-brief.sh — generate a morning brief from local memory files
# Output: ~/.claude/briefs/YYYY-MM-DD-HHmmss.md
# Called by: SessionStart hook (fires once per day via timestamp guard)
# Also callable manually: bash ~/.claude/scripts/session-brief.sh
#
# Configuration:
#   CLAUDE_MEMORY_DIR — path to your project memory directory
#                       default: auto-detected from ~/.claude/projects/*/memory
set -euo pipefail

BRIEFS_DIR="$HOME/.claude/briefs"

# Resolve memory directory — override via env var or auto-detect
if [[ -n "${CLAUDE_MEMORY_DIR:-}" ]]; then
    MEMORY_DIR="$CLAUDE_MEMORY_DIR"
else
    MEMORY_DIR=$(find "$HOME/.claude/projects" -maxdepth 2 -type d -name memory 2>/dev/null | head -1)
fi

TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)
DATE=$(date +%Y-%m-%d)
BRIEF_FILE="$BRIEFS_DIR/${DATE}-$(date +%H%M%S).md"

mkdir -p "$BRIEFS_DIR"

cat > "$BRIEF_FILE" << EOF
# Morning Brief — $DATE

Generated: $TIMESTAMP

---

## Worktree Health

EOF

bash "$HOME/.claude/scripts/worktree-health.sh" 2>/dev/null >> "$BRIEF_FILE" \
  || echo "(worktree-health.sh unavailable)" >> "$BRIEF_FILE"

echo "" >> "$BRIEF_FILE"
echo "---" >> "$BRIEF_FILE"
echo "" >> "$BRIEF_FILE"
echo "## Project RAG Status" >> "$BRIEF_FILE"
echo "" >> "$BRIEF_FILE"

if [[ -n "$MEMORY_DIR" && -d "$MEMORY_DIR" ]]; then
    for mem_file in "$MEMORY_DIR"/*.md; do
        [[ -f "$mem_file" ]] || continue
        if grep -qiE "🔴|🟡|🟢|blocker|blocked|pending|waiting|RAG" "$mem_file" 2>/dev/null; then
            fname=$(basename "$mem_file")
            echo "### $fname" >> "$BRIEF_FILE"
            grep -iE "🔴|🟡|🟢|blocker|blocked|pending|waiting|status:" "$mem_file" | head -20 >> "$BRIEF_FILE" || true
            echo "" >> "$BRIEF_FILE"
        fi
    done
else
    echo "(memory directory not found — set CLAUDE_MEMORY_DIR env var)" >> "$BRIEF_FILE"
fi

echo "---" >> "$BRIEF_FILE"
echo "" >> "$BRIEF_FILE"
echo "## Hook Health (previous session)" >> "$BRIEF_FILE"
echo "" >> "$BRIEF_FILE"

HOOK_LOG="$HOME/.claude/hook-log.txt"
if [[ -f "$HOOK_LOG" ]]; then
    YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d 2>/dev/null)
    PREV_ENTRIES=$(grep "^$YESTERDAY" "$HOOK_LOG" 2>/dev/null | tail -20 || true)
    if [[ -n "$PREV_ENTRIES" ]]; then
        echo '```' >> "$BRIEF_FILE"
        echo "$PREV_ENTRIES" >> "$BRIEF_FILE"
        echo '```' >> "$BRIEF_FILE"
    else
        echo "(No hook entries for $YESTERDAY)" >> "$BRIEF_FILE"
    fi
else
    echo "(hook-log.txt not found)" >> "$BRIEF_FILE"
fi

echo "" >> "$BRIEF_FILE"
echo "---" >> "$BRIEF_FILE"
echo "" >> "$BRIEF_FILE"
echo "## Issue Tracker" >> "$BRIEF_FILE"
echo "" >> "$BRIEF_FILE"
echo "_Populated by Claude agent if Jira/Linear MCP is configured_" >> "$BRIEF_FILE"
echo "" >> "$BRIEF_FILE"

echo "$BRIEF_FILE"

cat "$BRIEF_FILE"
