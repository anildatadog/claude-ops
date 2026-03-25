#!/usr/bin/env bash
# end-session.sh — merge all unmerged session/* branches across active repos into their dev/YYYY-MM-DD branch
#
# Usage: end-session      (via shell alias)
#
# For each repo in ~/Documents/Git/:
#   - Finds session/* branches not yet merged to their dev/YYYY-MM-DD branch
#   - Creates a PR if one doesn't exist
#   - Merges it
#   - Reports what was done

set -euo pipefail

REPOS_DIR="$HOME/Documents/Git"
TODAY=$(date -u +%Y-%m-%d)
DEV_BRANCH="dev/$TODAY"

# Repos to check — add/remove as needed
REPOS=(
  "splunk-dd-migration-mcp"
  "dd-cicd-onboarding-mcp"
  "dd-ust-mcp"
  "dd-governed-onboarding-mcp"
)

echo ""
echo "=== end-session: merging session branches → $DEV_BRANCH ==="
echo ""

any_work=false

for repo in "${REPOS[@]}"; do
  repo_path="$REPOS_DIR/$repo"

  if [[ ! -d "$repo_path/.git" ]]; then
    continue
  fi

  # Get list of remote session/* branches not yet merged into dev/today
  cd "$repo_path"
  git fetch --quiet --all 2>/dev/null || true

  # Check if dev/today exists on remote
  if ! git ls-remote --exit-code origin "refs/heads/$DEV_BRANCH" &>/dev/null; then
    echo "[$repo] No $DEV_BRANCH on remote — skipping"
    continue
  fi

  # Derive owner/repo from git remote (works for any GitHub account)
  remote_url=$(git remote get-url origin 2>/dev/null || echo "")
  gh_repo=$(echo "$remote_url" | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|')
  if [[ -z "$gh_repo" || "$gh_repo" == "$remote_url" ]]; then
    echo "[$repo] Could not determine GitHub repo from remote — skipping"
    continue
  fi

  # Find session branches ahead of dev/today
  unmerged=()
  while IFS= read -r branch; do
    branch="${branch#  remotes/origin/}"
    # Skip if already merged into dev/today
    ahead=$(git rev-list --count "origin/$DEV_BRANCH..origin/$branch" 2>/dev/null || echo 0)
    if [[ "$ahead" -gt 0 ]]; then
      unmerged+=("$branch")
    fi
  done < <(git branch -r | grep "origin/session/" || true)

  if [[ ${#unmerged[@]} -eq 0 ]]; then
    echo "[$repo] Nothing to merge"
    continue
  fi

  any_work=true
  for branch in "${unmerged[@]}"; do
    echo ""
    echo "[$repo] $branch → $DEV_BRANCH"

    # Check if PR already exists
    existing_pr=$(gh pr list --repo "$gh_repo" --head "$branch" --base "$DEV_BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")

    if [[ -z "$existing_pr" ]]; then
      # Create PR
      pr_url=$(gh pr create \
        --repo "$gh_repo" \
        --head "$branch" \
        --base "$DEV_BRANCH" \
        --title "$(echo "$branch" | sed 's|session/[0-9-]*-||')" \
        --body "Auto-created by end-session script." \
        2>/dev/null)
      pr_num=$(gh pr list --repo "$gh_repo" --head "$branch" --base "$DEV_BRANCH" --json number --jq '.[0].number')
      echo "  Created PR #$pr_num"
    else
      pr_num="$existing_pr"
      echo "  Found existing PR #$pr_num"
    fi

    # Merge
    gh pr merge "$pr_num" --repo "$gh_repo" --merge --delete-branch 2>/dev/null && \
      echo "  Merged PR #$pr_num" || \
      echo "  Merge failed for PR #$pr_num — check GitHub"
  done
done

echo ""
if [[ "$any_work" == false ]]; then
  echo "All repos clean. Nothing to merge."
fi
echo "=== done ==="
echo ""
echo "dev/$TODAY will auto-merge to main at 23:55 UTC via GitHub Actions."
echo ""
