#!/usr/bin/env bash
# session-orient.sh — compact session orientation injected at SessionStart
# Writes to stdout (system-reminder) AND ~/.claude/pending-brief.md
# Claude presents pending-brief.md as first message per CLAUDE.md rule

GIT_DIR="$HOME/Documents/Git"
MEMORY_DIR="$HOME/.claude/projects/-Users-anilkumar-pappu-Documents-Git/memory"
PENDING="$HOME/.claude/pending-brief.md"

{
  echo "=== Session Orientation ==="
  echo "Date: $(date '+%Y-%m-%d %H:%M %Z')"
  echo "CWD:  $(pwd)"
  echo ""

  # --- Active worktrees ---
  echo "--- Worktrees ---"
  found_wt=0
  for repo in "$GIT_DIR"/*/; do
    [[ -d "$repo/.git" ]] || continue
    name=$(basename "$repo")
    while IFS= read -r line; do
      wt_path=$(echo "$line" | awk '{print $1}')
      wt_branch=$(echo "$line" | grep -oE '\[[^]]*\]' | tr -d '[]')
      [[ -z "$wt_branch" ]] && continue
      main_wt=$(git -C "$repo" worktree list 2>/dev/null | head -1 | awk '{print $1}')
      [[ "$wt_path" == "$main_wt" ]] && continue

      pr=$(gh pr list --repo "$(git -C "$wt_path" remote get-url origin 2>/dev/null)" \
        --head "$wt_branch" --json number,title --jq '.[0] | "#\(.number) \(.title)"' 2>/dev/null)
      if [[ -n "$pr" ]]; then
        echo "  $name [$wt_branch] — PR $pr"
      else
        commits=$(git -C "$wt_path" log "origin/main..HEAD" --oneline 2>/dev/null | wc -l | tr -d ' ')
        echo "  $name [$wt_branch] — $commits unpushed commit(s), no PR"
      fi
      found_wt=1
    done < <(git -C "$repo" worktree list 2>/dev/null | tail -n +2)
  done
  [[ $found_wt -eq 0 ]] && echo "  (none)"
  echo ""

  # --- Upcoming sessions from memory ---
  echo "--- Upcoming Sessions ---"
  if [[ -d "$MEMORY_DIR" ]]; then
    for mem in "$MEMORY_DIR"/*-session-log.md "$MEMORY_DIR"/*-engagement.md "$MEMORY_DIR"/*-cicd-progress.md; do
      [[ -f "$mem" ]] || continue
      customer=$(basename "$mem" | sed 's/-session-log\.md//' | sed 's/-engagement\.md//' | sed 's/-cicd-progress\.md//')
      next=$(grep -iE "next available slot|target date|Session [0-9]+ target" "$mem" 2>/dev/null | head -2 | sed 's/^[[:space:]]*//' | tr '\n' ' ')
      [[ -n "$next" ]] && echo "  [$customer] $next"
    done
  else
    echo "  (memory dir not found)"
  fi
  echo ""

  echo "--- Action Required ---"
  echo "Confirm working repo and session type (discussion / implementation)."
  echo "If implementation: check for open PRs above and resume or start a new worktree."
} | tee "$PENDING"
