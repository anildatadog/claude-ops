# Hook Infrastructure Implementation Plan

> **Status:** ✅ Implemented 2026-03-24
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four global Claude Code hooks to `~/.claude/settings.json` that enforce verification before stopping, detect silent tool failures, log all hook decisions, and surface hook health at session start — applying automatically to all repos now and in the future.

**Architecture:** Hook logic lives in standalone scripts under `~/.claude/scripts/` so each hook is independently testable. `settings.json` calls scripts rather than embedding inline bash. The Stop hook uses a git-status-hash sentinel to prevent re-blocking after verification. The PostToolUse hook throttles warnings by tool+result-type key. `worktree-health.sh` is extended to verify hooks are registered and surface prior-session warnings.

**Tech Stack:** Bash, Python 3 (stdlib only — json/sha256), Claude Code hooks (PreToolUse/PostToolUse/Stop/SessionStart), `~/.claude/settings.json`

**This is Plan 1 of 4.** Plans 2 (dd-mcp-shared enforcement), 3 (cron agents), and 4 (subagent patterns) follow after this ships.

**Spec:** `~/.claude/docs/superpowers/specs/2026-03-24-ai-reliability-infrastructure-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `~/.claude/scripts/write-sentinel.sh` | Create | Writes git-status-hash sentinel; called after verification passes |
| `~/.claude/scripts/stop-hook.sh` | Create | Stop hook logic: checks sentinel, compares hash, logs decision |
| `~/.claude/scripts/posttooluse-hook.sh` | Create | PostToolUse hook: detects empty results, throttles warnings, logs |
| `~/.claude/scripts/hook-health-check.sh` | Create | Reads hook-log.txt, verifies hooks registered, surfaces warnings |
| `~/.claude/scripts/worktree-health.sh` | Modify | Add hook health check as final step (after existing loop) |
| `~/.claude/settings.json` | Modify | Wire Stop hook, PostToolUse hook; extend SessionStart |
| `~/.claude/CLAUDE.md` | Modify | Add sentinel-write rule after verification-before-completion |
| `~/.claude/tests/test-hooks.sh` | Create | Integration tests: verify each hook fires correctly |

---

## Task 1: write-sentinel.sh

**Files:**
- Create: `~/.claude/scripts/write-sentinel.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# write-sentinel.sh — call after verification-before-completion passes
# Writes the current git status hash to a date-scoped sentinel file.
# The Stop hook reads this to allow the session to end.

SENTINEL="/tmp/claude-verified-$(date +%Y%m%d)"
HASH=$(git status --porcelain 2>/dev/null | sha256sum | cut -d' ' -f1)
echo "$HASH" > "$SENTINEL"
echo "Sentinel written: $SENTINEL (hash: ${HASH:0:8}...)"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x ~/.claude/scripts/write-sentinel.sh
```

- [ ] **Step 3: Verify manually**

```bash
cd /tmp && git init test-sentinel-repo && cd test-sentinel-repo
touch testfile && ~/.claude/scripts/write-sentinel.sh
SENTINEL="/tmp/claude-verified-$(date +%Y%m%d)"
cat "$SENTINEL"  # should print a sha256 hash
rm -rf /tmp/test-sentinel-repo && rm -f "$SENTINEL"
```

Expected output: a 64-character hex hash.

- [ ] **Step 4: Commit**

```bash
cd ~/.claude
git add scripts/write-sentinel.sh
git commit -m "feat(hooks): add write-sentinel script for verification gate"
```

---

## Task 2: stop-hook.sh

**Files:**
- Create: `~/.claude/scripts/stop-hook.sh`

- [ ] **Step 1: Write failing test first**

```bash
cat > /tmp/test-stop-hook.sh << 'EOF'
#!/usr/bin/env bash
set -e

SCRIPT="$HOME/.claude/scripts/stop-hook.sh"
SENTINEL="/tmp/claude-verified-$(date +%Y%m%d)"
LOGFILE="/tmp/test-hook-log.txt"
rm -f "$SENTINEL" "$LOGFILE"

# Setup: temp git repo with a change
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git init -q && git config user.email "test@test.com" && git config user.name "Test"
touch initial && git add . && git commit -q -m "init"
touch newfile  # unstaged change = dirty tree

# Test 1: no sentinel → should block (exit 2)
HOOK_LOG="$LOGFILE" output=$("$SCRIPT" 2>&1); code=$?
[[ $code -eq 2 ]] || { echo "FAIL Test1: expected exit 2, got $code"; exit 1; }
echo "PASS Test1: no sentinel → exit 2"

# Test 2: write sentinel with matching hash → should pass (exit 0)
git status --porcelain | sha256sum | cut -d' ' -f1 > "$SENTINEL"
HOOK_LOG="$LOGFILE" output=$("$SCRIPT" 2>&1); code=$?
[[ $code -eq 0 ]] || { echo "FAIL Test2: expected exit 0, got $code"; exit 1; }
echo "PASS Test2: sentinel + matching hash → exit 0"

# Test 3: change tree after sentinel written → should block again (exit 2)
touch anotherfile
HOOK_LOG="$LOGFILE" output=$("$SCRIPT" 2>&1); code=$?
[[ $code -eq 2 ]] || { echo "FAIL Test3: expected exit 2, got $code"; exit 1; }
echo "PASS Test3: hash mismatch → exit 2"

# Test 4: no git repo, no changes → should pass (exit 0)
TMPDIR2=$(mktemp -d) && cd "$TMPDIR2"
HOOK_LOG="$LOGFILE" output=$("$SCRIPT" 2>&1); code=$?
[[ $code -eq 0 ]] || { echo "FAIL Test4: expected exit 0 (no git), got $code"; exit 1; }
echo "PASS Test4: no git repo → exit 0"

# Cleanup
rm -rf "$TMPDIR" "$TMPDIR2" "$SENTINEL" "$LOGFILE"
echo "ALL TESTS PASSED"
EOF
chmod +x /tmp/test-stop-hook.sh
```

- [ ] **Step 2: Run test — expect failure (script doesn't exist yet)**

```bash
/tmp/test-stop-hook.sh 2>&1 | head -5
```

Expected: error about missing script or permission denied.

- [ ] **Step 3: Write stop-hook.sh**

```bash
cat > ~/.claude/scripts/stop-hook.sh << 'EOF'
#!/usr/bin/env bash
# stop-hook.sh — Claude Code Stop hook
# Blocks session end if git has changes and verification sentinel is absent/stale.

SENTINEL="/tmp/claude-verified-$(date +%Y%m%d)"
LOGFILE="${HOOK_LOG:-$HOME/.claude/hook-log.txt}"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)

log() { echo "$TIMESTAMP STOP $1" >> "$LOGFILE"; }

# No git repo or no changes → pass
CHANGES=$(git status --porcelain 2>/dev/null)
if [[ -z "$CHANGES" ]]; then
  log "PASS no_changes"
  exit 0
fi

# No sentinel → block
if [[ ! -f "$SENTINEL" ]]; then
  log "BLOCK no_sentinel"
  echo "BLOCKED: Changes present but verification not run."
  echo "Run superpowers:verification-before-completion, then ~/.claude/scripts/write-sentinel.sh"
  exit 2
fi

# Compare hashes
STORED=$(cat "$SENTINEL")
CURRENT=$(git status --porcelain 2>/dev/null | sha256sum | cut -d' ' -f1)

if [[ "$STORED" == "$CURRENT" ]]; then
  log "PASS hash_match"
  exit 0
else
  log "BLOCK hash_mismatch"
  echo "BLOCKED: Tree changed since last verification."
  echo "Re-run superpowers:verification-before-completion, then ~/.claude/scripts/write-sentinel.sh"
  exit 2
fi
EOF
chmod +x ~/.claude/scripts/stop-hook.sh
```

- [ ] **Step 4: Run test — expect all pass**

```bash
/tmp/test-stop-hook.sh
```

Expected: `ALL TESTS PASSED`

- [ ] **Step 5: Commit**

```bash
cd ~/.claude
git add scripts/stop-hook.sh
git commit -m "feat(hooks): add stop hook with hash-based sentinel verification gate"
```

---

## Task 3: posttooluse-hook.sh

**Files:**
- Create: `~/.claude/scripts/posttooluse-hook.sh`

- [ ] **Step 1: Write failing test first**

```bash
cat > /tmp/test-posttooluse-hook.sh << 'EOF'
#!/usr/bin/env bash
set -e

SCRIPT="$HOME/.claude/scripts/posttooluse-hook.sh"
LOGFILE="/tmp/test-posttooluse-log.txt"
rm -f "$LOGFILE"

run_hook() {
  echo "$1" | HOOK_LOG="$LOGFILE" "$SCRIPT" 2>&1
  return ${PIPESTATUS[1]}
}

# Test 1: non-empty result → pass silently (exit 0, no output)
INPUT='{"tool_name":"mcp__datadog__search_monitors","tool_result":[{"id":1}]}'
output=$(run_hook "$INPUT"); code=$?
[[ $code -eq 0 ]] || { echo "FAIL Test1: expected exit 0, got $code"; exit 1; }
[[ -z "$output" ]] || { echo "FAIL Test1: expected no output, got: $output"; exit 1; }
echo "PASS Test1: non-empty result → silent pass"

# Test 2: null result → warn (exit 0, output warning)
INPUT='{"tool_name":"mcp__datadog__search_monitors","tool_result":null}'
output=$(run_hook "$INPUT"); code=$?
[[ $code -eq 0 ]] || { echo "FAIL Test2: expected exit 0, got $code"; exit 1; }
echo "$output" | grep -q "WARNING" || { echo "FAIL Test2: expected WARNING in output"; exit 1; }
echo "PASS Test2: null result → warning emitted"

# Test 3: same tool+result_type again → throttled (no second warning)
INPUT='{"tool_name":"mcp__datadog__search_monitors","tool_result":null}'
output=$(run_hook "$INPUT"); code=$?
[[ -z "$output" ]] || { echo "FAIL Test3: expected throttled (no output), got: $output"; exit 1; }
echo "PASS Test3: duplicate tool+type → throttled"

# Test 4: same tool, different result type → new warning
INPUT='{"tool_name":"mcp__datadog__search_monitors","tool_result":[]}'
output=$(run_hook "$INPUT"); code=$?
echo "$output" | grep -q "WARNING" || { echo "FAIL Test4: expected WARNING for new result type"; exit 1; }
echo "PASS Test4: same tool, different result type → new warning"

rm -f "$LOGFILE"
echo "ALL TESTS PASSED"
EOF
chmod +x /tmp/test-posttooluse-hook.sh
```

- [ ] **Step 2: Run test — expect failure**

```bash
/tmp/test-posttooluse-hook.sh 2>&1 | head -5
```

Expected: error about missing script.

- [ ] **Step 3: Write posttooluse-hook.sh**

```bash
cat > ~/.claude/scripts/posttooluse-hook.sh << 'EOF'
#!/usr/bin/env bash
# posttooluse-hook.sh — Claude Code PostToolUse hook
# Detects empty/null tool results and emits a throttled warning.
# Throttle key: <tool_name>:<result_type> — warns once per key per session date.

LOGFILE="${HOOK_LOG:-$HOME/.claude/hook-log.txt}"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)
TODAY=$(date +%Y-%m-%d)

# Read tool call input from stdin
INPUT=$(cat)
TOOL=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_name','unknown'))" 2>/dev/null)
RESULT=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(repr(d.get('tool_result','')))" 2>/dev/null)

# Detect result type
RESULT_TYPE=$(echo "$INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('tool_result')
if r is None: print('null')
elif r == []: print('empty_array')
elif r == {}: print('empty_object')
elif isinstance(r, str) and r.strip() == '': print('empty_string')
else: print('ok')
" 2>/dev/null)

# Non-empty → pass silently
[[ "$RESULT_TYPE" == "ok" ]] && exit 0

THROTTLE_KEY="${TOOL}:${RESULT_TYPE}"

# Check throttle: already warned today for this key?
if grep -q "POSTTOOLUSE WARN ${THROTTLE_KEY}" "$LOGFILE" 2>/dev/null; then
  if grep "POSTTOOLUSE WARN ${THROTTLE_KEY}" "$LOGFILE" | grep -q "$TODAY"; then
    exit 0  # already warned today, suppress
  fi
fi

# Log and emit warning
echo "$TIMESTAMP POSTTOOLUSE WARN ${THROTTLE_KEY}" >> "$LOGFILE"
echo "WARNING: ${TOOL} returned ${RESULT_TYPE}. Verify environment before proceeding."
exit 0
EOF
chmod +x ~/.claude/scripts/posttooluse-hook.sh
```

- [ ] **Step 4: Run test — expect all pass**

```bash
/tmp/test-posttooluse-hook.sh
```

Expected: `ALL TESTS PASSED`

- [ ] **Step 5: Commit**

```bash
cd ~/.claude
git add scripts/posttooluse-hook.sh
git commit -m "feat(hooks): add posttooluse hook with throttled empty-result detection"
```

---

## Task 4: hook-health-check.sh

**Files:**
- Create: `~/.claude/scripts/hook-health-check.sh`

- [ ] **Step 1: Write the script**

```bash
cat > ~/.claude/scripts/hook-health-check.sh << 'EOF'
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

# 4. Surface warnings from previous session (last 24h, non-today entries)
if [[ -f "$LOGFILE" ]]; then
  YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d 2>/dev/null)
  PREV_WARNINGS=$(grep "$YESTERDAY" "$LOGFILE" | grep "WARN\|BLOCK" | wc -l | tr -d ' ')
  if [[ "$PREV_WARNINGS" -gt 0 ]]; then
    echo "ℹ️  Hook health: $PREV_WARNINGS warning(s)/block(s) from previous session:"
    grep "$YESTERDAY" "$LOGFILE" | grep "WARN\|BLOCK" | sed 's/^/    /'
  fi
fi

[[ "$ISSUES" -eq 0 ]] && echo "✓ Hooks healthy"
EOF
chmod +x ~/.claude/scripts/hook-health-check.sh
```

- [ ] **Step 2: Test manually**

```bash
~/.claude/scripts/hook-health-check.sh
```

Expected before wiring: "Hook health: Stop hook NOT registered" and "PostToolUse hook NOT registered". This is correct — hooks aren't in settings.json yet.

- [ ] **Step 3: Commit**

```bash
cd ~/.claude
git add scripts/hook-health-check.sh
git commit -m "feat(hooks): add hook-health-check script for SessionStart verification"
```

---

## Task 5: Extend worktree-health.sh

**Files:**
- Modify: `~/.claude/scripts/worktree-health.sh` (append after line 59)

- [ ] **Step 1: Add hook health check call at end of script**

Append to `worktree-health.sh`, replacing the final block:

```bash
# Replace the final 3 lines (the ISSUES -eq 0 check) with this:
if [[ "$ISSUES" -eq 0 ]]; then
  echo "✓ All worktrees healthy"
else
  echo ""
  echo "  Run 'end-session' in each affected repo to clean up."
fi

echo ""
echo "--- Hook Health ---"
~/.claude/scripts/hook-health-check.sh
```

- [ ] **Step 2: Run worktree-health.sh to verify both sections output**

```bash
~/.claude/scripts/worktree-health.sh
```

Expected: existing worktree output followed by "--- Hook Health ---" section.

- [ ] **Step 3: Commit**

```bash
cd ~/.claude
git add scripts/worktree-health.sh
git commit -m "feat(hooks): extend worktree-health to surface hook registration and prior warnings"
```

---

## Task 6: Wire hooks in settings.json

**Files:**
- Modify: `~/.claude/settings.json`

- [ ] **Step 1: Read current settings.json to understand exact structure**

```bash
cat ~/.claude/settings.json
```

Note the exact JSON structure before modifying.

- [ ] **Step 2: Add Stop and PostToolUse hooks via Python (safe JSON edit)**

```bash
python3 << 'PYEOF'
import json

path = "/Users/anilkumar.pappu/.claude/settings.json"
with open(path) as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})

# Stop hook
hooks["Stop"] = [{
    "hooks": [{
        "type": "command",
        "command": "bash ~/.claude/scripts/stop-hook.sh"
    }]
}]

# PostToolUse hook — all MCP tools and Bash
hooks.setdefault("PostToolUse", []).append({
    "matcher": "mcp__.*|Bash",
    "hooks": [{
        "type": "command",
        "command": "bash ~/.claude/scripts/posttooluse-hook.sh"
    }]
})

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("settings.json updated")
PYEOF
```

- [ ] **Step 3: Verify settings.json is valid JSON with expected keys**

```bash
python3 -c "
import json
d = json.load(open('/Users/anilkumar.pappu/.claude/settings.json'))
hooks = d.get('hooks', {})
assert 'Stop' in hooks, 'Stop hook missing'
assert 'PostToolUse' in hooks, 'PostToolUse hook missing'
assert 'SessionStart' in hooks, 'SessionStart hook missing'
print('settings.json valid — Stop, PostToolUse, SessionStart all present')
"
```

- [ ] **Step 4: Run hook-health-check.sh — both hooks should now show as registered**

```bash
~/.claude/scripts/hook-health-check.sh
```

Expected: "✓ Hooks healthy" (or "0 blocks" warning if log is empty/new — that's fine).

- [ ] **Step 5: Commit**

```bash
cd ~/.claude
git add settings.json
git commit -m "feat(hooks): wire stop and posttooluse hooks in settings.json"
```

---

## Task 7: Update global CLAUDE.md

**Files:**
- Modify: `~/.claude/CLAUDE.md`

Add to the `## Execution Principles` section:

- [ ] **Step 1: Add sentinel-write rule**

Find the `## Execution Principles` section in `~/.claude/CLAUDE.md` and add:

```markdown
### Verification gate — write sentinel after verification passes
After `superpowers:verification-before-completion` completes with all checks passing, immediately run:
```bash
~/.claude/scripts/write-sentinel.sh
```
This writes the sentinel that allows the session to end cleanly. The Stop hook blocks the session until this sentinel is present and matches the current git state. Do not skip this step.
```

- [ ] **Step 2: Verify CLAUDE.md looks correct**

```bash
grep -A 8 "Verification gate" ~/.claude/CLAUDE.md
```

Expected: the new rule is present.

- [ ] **Step 3: Commit**

```bash
cd ~/.claude
git add CLAUDE.md
git commit -m "docs: add sentinel-write rule to execution principles"
```

---

## Task 8: End-to-end integration test

**Files:**
- Create: `~/.claude/tests/test-hooks.sh`

- [ ] **Step 1: Write integration test**

```bash
mkdir -p ~/.claude/tests
cat > ~/.claude/tests/test-hooks.sh << 'EOF'
#!/usr/bin/env bash
# Integration test: verifies the full Stop hook + sentinel flow
set -e

PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Setup
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
git init -q
git config user.email "test@test.com" && git config user.name "Test"
touch initial && git add . && git commit -q -m "init"
SENTINEL="/tmp/claude-verified-$(date +%Y%m%d)"
LOGFILE="/tmp/test-integration-log.txt"
rm -f "$SENTINEL" "$LOGFILE"
export HOOK_LOG="$LOGFILE"

# Test: stop with changes, no sentinel → exit 2
touch dirty_file
code=$(~/.claude/scripts/stop-hook.sh > /dev/null 2>&1; echo $?)
[[ "$code" -eq 2 ]] && ok "stop blocks with no sentinel" || fail "stop should block with no sentinel (got $code)"

# Test: write sentinel → stop passes
~/.claude/scripts/write-sentinel.sh > /dev/null
code=$(~/.claude/scripts/stop-hook.sh > /dev/null 2>&1; echo $?)
[[ "$code" -eq 0 ]] && ok "stop passes after sentinel written" || fail "stop should pass after sentinel (got $code)"

# Test: modify tree after sentinel → stop blocks again
touch another_dirty_file
code=$(~/.claude/scripts/stop-hook.sh > /dev/null 2>&1; echo $?)
[[ "$code" -eq 2 ]] && ok "stop re-blocks after tree change" || fail "stop should re-block after tree change (got $code)"

# Test: hook health check sees hooks registered
output=$(~/.claude/scripts/hook-health-check.sh 2>&1)
echo "$output" | grep -q "Hooks healthy\|0 blocks" && ok "hook-health-check passes after wiring" || fail "hook-health-check failed: $output"

# Test: log file was written
[[ -f "$LOGFILE" ]] && ok "hook log file created" || fail "hook log file missing"
grep -q "STOP" "$LOGFILE" && ok "stop hook wrote to log" || fail "stop hook did not write to log"

# Cleanup
rm -rf "$TMPDIR" "$SENTINEL" "$LOGFILE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
EOF
chmod +x ~/.claude/tests/test-hooks.sh
```

- [ ] **Step 2: Run integration test**

```bash
~/.claude/tests/test-hooks.sh
```

Expected: `Results: 6 passed, 0 failed`

- [ ] **Step 3: Commit**

```bash
cd ~/.claude
git add tests/test-hooks.sh
git commit -m "test(hooks): add integration tests for stop hook and sentinel flow"
```

---

## Verification Checklist

Before marking this plan complete:

- [ ] `~/.claude/scripts/write-sentinel.sh` exists and is executable
- [ ] `~/.claude/scripts/stop-hook.sh` exists, passes all unit tests
- [ ] `~/.claude/scripts/posttooluse-hook.sh` exists, passes all unit tests
- [ ] `~/.claude/scripts/hook-health-check.sh` exists and reports correctly
- [ ] `~/.claude/scripts/worktree-health.sh` shows "--- Hook Health ---" section
- [ ] `~/.claude/settings.json` has `Stop` and `PostToolUse` keys in `hooks`
- [ ] `~/.claude/CLAUDE.md` has sentinel-write rule in Execution Principles
- [ ] `~/.claude/tests/test-hooks.sh` passes (6/6)
- [ ] `~/.claude/hook-log.txt` is created on next session start

---

## What Comes Next

After this plan ships, Plans 2 and 3 can run in parallel:
- **Plan 2:** dd-mcp-shared `@require_verified_context` decorator + retrofit
- **Plan 3:** Cron agents (morning brief + memory health check)
- **Plan 4:** Subagent patterns (follows Plan 3)
