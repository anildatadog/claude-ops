#!/usr/bin/env bash
# stop-hook.sh — Claude Code Stop hook
# Blocks session end if git has changes and verification sentinel is absent/stale.

SENTINEL="/tmp/claude-verified-$(date +%Y%m%d)"
LOGFILE="${HOOK_LOG:-$HOME/.claude/hook-log.txt}"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)

log() { echo "$TIMESTAMP STOP $1" >> "$LOGFILE"; }

# Cache git status once to avoid TOCTOU
CHANGES=$(git status --porcelain 2>/dev/null)

# No git repo or no changes → pass
if [[ -z "$CHANGES" ]]; then
  log "PASS no_changes"
  exit 0
fi

# No sentinel → block
if [[ ! -f "$SENTINEL" ]]; then
  log "BLOCK no_sentinel"
  echo "BLOCKED: No sentinel for today — either verification has not been run, or yesterday's sentinel expired at midnight." >&2
  echo "Run superpowers:verification-before-completion, then ~/.claude/scripts/write-sentinel.sh" >&2
  exit 2
fi

# Compare hashes
STORED=$(cat "$SENTINEL")
CURRENT=$(printf '%s' "$CHANGES" | shasum -a 256 | cut -d' ' -f1)

if [[ "$STORED" == "$CURRENT" ]]; then
  log "PASS hash_match"
  exit 0
else
  log "BLOCK hash_mismatch"
  echo "BLOCKED: Tree changed since last verification." >&2
  echo "Re-run superpowers:verification-before-completion, then ~/.claude/scripts/write-sentinel.sh" >&2
  exit 2
fi
