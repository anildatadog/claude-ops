#!/usr/bin/env bash
# memory-health.sh — weekly memory health check
# Output: ~/.claude/briefs/memory-health-YYYY-MM-DD.md
# Called by: SessionStart hook (fires once per week on Mondays)
#
# Configuration:
#   CLAUDE_MEMORY_DIR — path to your project memory directory
#   CLAUDE_GIT_DIR    — path to your git repos directory (default: ~/Documents/Git)
set -euo pipefail

BRIEFS_DIR="$HOME/.claude/briefs"

if [[ -n "${CLAUDE_MEMORY_DIR:-}" ]]; then
    MEMORY_DIR="$CLAUDE_MEMORY_DIR"
else
    MEMORY_DIR=$(find "$HOME/.claude/projects" -maxdepth 2 -type d -name memory 2>/dev/null | head -1)
fi

GIT_DIR="${CLAUDE_GIT_DIR:-$HOME/Documents/Git}"
DATE=$(date +%Y-%m-%d)
OUTPUT="$BRIEFS_DIR/memory-health-$DATE.md"
HOOK_LOG="$HOME/.claude/hook-log.txt"
NOW_EPOCH=$(date +%s)
THIRTY_DAYS_SECS=$((30 * 24 * 3600))

mkdir -p "$BRIEFS_DIR"

cat > "$OUTPUT" << EOF
# Memory Health Check — $DATE

---

## Stale Index Entries (not updated in 30+ days)

EOF

# Check confluence-gdrive-index.md (or any index file) for stale timestamps
INDEX_FILE="${MEMORY_DIR}/confluence-gdrive-index.md"
if [[ -f "$INDEX_FILE" ]]; then
    echo "### $(basename $INDEX_FILE)" >> "$OUTPUT"
    while IFS= read -r line; do
        if echo "$line" | grep -qE "[0-9]{4}-[0-9]{2}-[0-9]{2}"; then
            entry_date=$(echo "$line" | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}" | tail -1)
            if [[ -n "$entry_date" ]]; then
                entry_epoch=$(date -j -f "%Y-%m-%d" "$entry_date" +%s 2>/dev/null \
                           || date -d "$entry_date" +%s 2>/dev/null || echo 0)
                age=$(( NOW_EPOCH - entry_epoch ))
                if (( age > THIRTY_DAYS_SECS )); then
                    echo "⚠️  STALE ($entry_date): $line" >> "$OUTPUT"
                fi
            fi
        fi
    done < "$INDEX_FILE"
    echo "" >> "$OUTPUT"
fi

echo "---" >> "$OUTPUT"
echo "" >> "$OUTPUT"
echo "## Hook Health — Stop Hook Silence Check" >> "$OUTPUT"
echo "" >> "$OUTPUT"

if [[ -f "$HOOK_LOG" ]]; then
    STOP_ENTRIES=$(grep -c "STOP" "$HOOK_LOG" 2>/dev/null || echo 0)
    STOP_BLOCKS=$(grep "STOP BLOCK" "$HOOK_LOG" 2>/dev/null | wc -l | tr -d ' ')
    TOTAL_ENTRIES=$(wc -l < "$HOOK_LOG" | tr -d ' ')

    echo "Total hook log entries: $TOTAL_ENTRIES" >> "$OUTPUT"
    echo "STOP entries: $STOP_ENTRIES" >> "$OUTPUT"
    echo "STOP BLOCK entries: $STOP_BLOCKS" >> "$OUTPUT"
    echo "" >> "$OUTPUT"

    if (( TOTAL_ENTRIES > 10 && STOP_BLOCKS == 0 )); then
        echo "⚠️  ANOMALY: >10 hook entries but zero STOP BLOCKs — Stop hook may not be firing" >> "$OUTPUT"
        echo "Check: is stop-hook.sh registered in ~/.claude/settings.json?" >> "$OUTPUT"
    else
        echo "✅ Stop hook appears healthy" >> "$OUTPUT"
    fi
else
    echo "⚠️  hook-log.txt not found" >> "$OUTPUT"
fi

echo "" >> "$OUTPUT"
echo "---" >> "$OUTPUT"
echo "" >> "$OUTPUT"
echo "## Repo Inventory Cross-Reference" >> "$OUTPUT"
echo "" >> "$OUTPUT"

REPO_INVENTORY="${MEMORY_DIR}/repo_inventory.md"
if [[ -f "$REPO_INVENTORY" ]]; then
    INVENTORY_REPOS=$(grep -oE "Documents/Git/[a-zA-Z0-9_-]+" "$REPO_INVENTORY" \
                    | sed 's|Documents/Git/||' | sort -u)
    ACTUAL_DIRS=$(ls -d "$GIT_DIR"/*/ 2>/dev/null | xargs -I{} basename {} | sort -u)

    echo "### In inventory but not on disk" >> "$OUTPUT"
    while IFS= read -r repo; do
        [[ -n "$repo" ]] || continue
        echo "$ACTUAL_DIRS" | grep -qx "$repo" || echo "⚠️  MISSING: $repo" >> "$OUTPUT"
    done <<< "$INVENTORY_REPOS"

    echo "" >> "$OUTPUT"
    echo "### On disk but not in inventory" >> "$OUTPUT"
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        grep -q "$dir" "$REPO_INVENTORY" || echo "⚠️  NOT INVENTORIED: $dir" >> "$OUTPUT"
    done <<< "$ACTUAL_DIRS"
else
    echo "(repo_inventory.md not found — create one to enable cross-reference)" >> "$OUTPUT"
fi

echo "" >> "$OUTPUT"
echo "$OUTPUT"
