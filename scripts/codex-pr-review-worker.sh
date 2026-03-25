#!/usr/bin/env bash
# codex-pr-review-worker.sh — background worker
# Fetches PR diff, calls OpenAI GPT-4o, posts review as PR comment.
# Called by codex-pr-review.sh with PR URL as $1.
#
# Configuration (set in your shell profile or Claude Code env):
#   OPENAI_API_KEY        — direct API key (takes precedence)
#   CODEX_OPENAI_OP_REF   — 1Password reference, e.g. "op://Vault/Item/field"
#   CODEX_OP_ACCOUNT      — 1Password account shorthand (optional, e.g. "mycompany")

set -euo pipefail

LOGFILE="${HOOK_LOG:-$HOME/.claude/hook-log.txt}"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)
log() { echo "$TIMESTAMP codex-pr-review-worker $1" >> "$LOGFILE"; }

PR_URL="${1:-}"
if [[ -z "$PR_URL" ]]; then
    log "ERROR: No PR URL provided"
    exit 1
fi

REPO=$(echo "$PR_URL" | sed -E 's|https://github\.com/([a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+)/pull/[0-9]+|\1|')
PR_NUMBER=$(echo "$PR_URL" | sed -E 's|.*pull/([0-9]+).*|\1|')

log "INFO: Reviewing PR #$PR_NUMBER in $REPO"

# Fetch diff (cap at 2000 lines to stay within token budget)
DIFF_FILE=$(mktemp /tmp/codex-diff-XXXXXX)
gh pr diff "$PR_NUMBER" --repo "$REPO" 2>/dev/null | head -2000 > "$DIFF_FILE"

if [[ ! -s "$DIFF_FILE" ]]; then
    log "WARN: Empty diff for PR #$PR_NUMBER — skipping"
    rm -f "$DIFF_FILE"
    exit 0
fi

REVIEW_FILE=$(mktemp /tmp/codex-review-XXXXXX)

# Write the review script to a temp file so we can run it via either
# a plain python3 call or through 'op run' for 1Password injection.
PY_FILE=$(mktemp /tmp/codex-py-XXXXXX.py)
cat > "$PY_FILE" << 'PYEOF'
import os, json, sys, urllib.request, urllib.error

diff_path, out_path = sys.argv[1], sys.argv[2]

with open(diff_path) as f:
    diff = f.read()

api_key = os.environ.get("OPENAI_API_KEY", "")
if not api_key:
    print("ERROR: OPENAI_API_KEY not set", file=sys.stderr)
    sys.exit(1)

payload = {
    "model": "gpt-4o",
    "messages": [
        {
            "role": "system",
            "content": (
                "You are a senior software engineer doing a concise code review. "
                "Focus only on real bugs, security issues, and significant correctness problems. "
                "Skip style issues, formatting, and minor nitpicks. "
                "Be direct. If there are issues, list them with severity (High/Medium). "
                "If no real issues exist, say 'No significant issues found.' "
                "Keep the review under 300 words."
            ),
        },
        {
            "role": "user",
            "content": f"Review this PR diff:\n\n```diff\n{diff}\n```",
        },
    ],
    "max_tokens": 600,
    "temperature": 0.2,
}

req = urllib.request.Request(
    "https://api.openai.com/v1/chat/completions",
    data=json.dumps(payload).encode(),
    headers={
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    },
)

try:
    with urllib.request.urlopen(req, timeout=90) as r:
        result = json.loads(r.read())
        review = result["choices"][0]["message"]["content"]
        with open(out_path, "w") as f:
            f.write(review)
except urllib.error.HTTPError as e:
    print(f"OpenAI API error: {e.code} {e.read().decode()}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

# Run the script — direct key takes precedence over 1Password
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    python3 "$PY_FILE" "$DIFF_FILE" "$REVIEW_FILE"
elif [[ -n "${CODEX_OPENAI_OP_REF:-}" ]]; then
    ENV_FILE=$(mktemp /tmp/codex-env-XXXXXX)
    printf 'OPENAI_API_KEY=%s\n' "$CODEX_OPENAI_OP_REF" > "$ENV_FILE"
    OP_ACCOUNT_ARG=()
    [[ -n "${CODEX_OP_ACCOUNT:-}" ]] && OP_ACCOUNT_ARG=(--account "$CODEX_OP_ACCOUNT")
    op run "${OP_ACCOUNT_ARG[@]}" --env-file="$ENV_FILE" -- python3 "$PY_FILE" "$DIFF_FILE" "$REVIEW_FILE"
    rm -f "$ENV_FILE"
else
    log "ERROR: Set OPENAI_API_KEY or CODEX_OPENAI_OP_REF to enable Codex review"
    rm -f "$DIFF_FILE" "$REVIEW_FILE" "$PY_FILE"
    exit 0
fi

rm -f "$DIFF_FILE" "$PY_FILE"

if [[ ! -s "$REVIEW_FILE" ]]; then
    log "WARN: No review generated for PR #$PR_NUMBER"
    rm -f "$REVIEW_FILE"
    exit 0
fi

REVIEW=$(cat "$REVIEW_FILE")
rm -f "$REVIEW_FILE"

gh pr comment "$PR_NUMBER" --repo "$REPO" --body "### Codex Review

${REVIEW}

---
🤖 Generated with [OpenAI GPT-4o](https://platform.openai.com) via Claude Code hook" 2>> "$LOGFILE"

log "INFO: Review posted to PR #$PR_NUMBER in $REPO"
