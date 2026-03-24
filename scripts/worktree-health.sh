#!/usr/bin/env bash
# Worktree health check — scans all repos in ~/Documents/Git
# Prints warnings for: stale worktrees, main worktree on non-main branch,
# uncommitted changes in any worktree.

GIT_DIR=~/Documents/Git
ISSUES=0

check_repo() {
  local repo="$1"
  local name=$(basename "$repo")
  local main_wt=$(git -C "$repo" worktree list 2>/dev/null | head -1 | awk '{print $1}')

  while IFS= read -r line; do
    local wt_path=$(echo "$line" | awk '{print $1}')
    local wt_branch=$(echo "$line" | grep -oE '\[[^]]*\]' | tr -d '[]')

    # Skip bare/detached worktrees
    [[ -z "$wt_branch" ]] && continue

    # Uncommitted changes
    local dirty=$(git -C "$wt_path" status --porcelain 2>/dev/null | grep -v '^??')
    if [[ -n "$dirty" ]]; then
      echo "⚠️  $name [$wt_branch] — uncommitted changes in $wt_path"
      ISSUES=$((ISSUES + 1))
    fi

    # Main worktree on a non-main branch with unmerged commits
    # Per-repo override: .claude/main-branch file declares canonical main (e.g. "main-LLM")
    local canonical_main="main"
    [[ -f "$repo/.claude/main-branch" ]] && canonical_main=$(cat "$repo/.claude/main-branch" | tr -d '[:space:]')
    if [[ "$wt_path" == "$main_wt" && "$wt_branch" != "$canonical_main" && "$wt_branch" != "main" && "$wt_branch" != "master" ]]; then
      local unmerged=$(git -C "$wt_path" log "origin/${canonical_main}..HEAD" --oneline 2>/dev/null | wc -l | tr -d ' ')
      if [[ "$unmerged" -gt 0 ]]; then
        echo "⚠️  $name — main worktree on [$wt_branch] with $unmerged unmerged commit(s) — run end-session"
        ISSUES=$((ISSUES + 1))
      fi
    fi

    # Remote branch deleted (stale worktree)
    if git -C "$wt_path" branch -vv 2>/dev/null | grep -E "\[gone\]" | grep -q "$wt_branch"; then
      echo "⚠️  $name [$wt_branch] — remote branch deleted (stale worktree)"
      ISSUES=$((ISSUES + 1))
    fi

  done < <(git -C "$repo" worktree list 2>/dev/null)
}

for repo in "$GIT_DIR"/*/; do
  [[ -d "$repo/.git" ]] || continue
  check_repo "$repo"
done

if [[ "$ISSUES" -eq 0 ]]; then
  echo "✓ All worktrees healthy"
else
  echo ""
  echo "  Run 'end-session' in each affected repo to clean up."
fi

echo ""
echo "--- Hook Health ---"
~/.claude/scripts/hook-health-check.sh
