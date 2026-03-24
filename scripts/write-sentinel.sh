#!/usr/bin/env bash
# write-sentinel.sh — call after verification-before-completion passes
# Writes the current git status hash to a date-scoped sentinel file.
# The Stop hook reads this to allow the session to end.

SENTINEL="/tmp/claude-verified-$(date +%Y%m%d)"
CHANGES=$(git status --porcelain 2>/dev/null)
HASH=$(printf '%s' "$CHANGES" | shasum -a 256 | cut -d' ' -f1)
echo "$HASH" > "$SENTINEL"
echo "Sentinel written: $SENTINEL (hash: ${HASH:0:8}...)"
