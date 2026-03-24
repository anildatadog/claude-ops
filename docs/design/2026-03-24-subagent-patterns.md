# Subagent Patterns — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce task decomposition via a PreToolUse gate (blocks edits if 3+ files modified without an in_progress task) and inject a lightweight code review prompt at task completion.

**Architecture:** Two new hook scripts (`pretooluse-task-gate.sh`, `posttooluse-task-reviewer.sh`) + sentinel file `/tmp/claude-task-active-YYYYMMDD` that tracks whether a task is currently in_progress. The date suffix auto-expires the sentinel at midnight (same pattern as the Stop hook sentinel). The sentinel is written/deleted by `posttooluse-task-reviewer.sh` on `TaskUpdate` events (sentinel fires on `TaskUpdate → in_progress`; `TaskCreate` alone does **not** open the gate — always follow with `TaskUpdate {status: in_progress}`). On completion the reviewer script runs `git diff HEAD` and injects the output as context alongside the review prompt.

**Tech Stack:** bash, python3 (JSON parsing — already used in existing hooks), git, Claude Code hook system (`settings.json`).

---

## Files

| Action | Path | Purpose |
|--------|------|---------|
| Create | `~/.claude/scripts/pretooluse-task-gate.sh` | Counts modified+staged+untracked files; blocks if >2 and no sentinel |
| Create | `~/.claude/scripts/posttooluse-task-reviewer.sh` | Writes/deletes sentinel on TaskUpdate; injects diff + review prompt on completion |
| Modify | `~/.claude/settings.json` | Wire two new hooks: PreToolUse (Edit\|Write) + PostToolUse (TaskUpdate\|TaskCreate) |
| Modify | `~/.claude/settings.json` (SessionStart) | Clear stale sentinel at session start |
| Modify | `~/.claude/CLAUDE.md` | Add task gate rule to Execution Principles |

---

## Task 1: `pretooluse-task-gate.sh`

**Files:**
- Create: `~/.claude/scripts/pretooluse-task-gate.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# pretooluse-task-gate.sh — Claude Code PreToolUse hook
# Blocks Edit/Write if 3+ files modified in session and no task is in_progress.
# File count = staged + unstaged tracked changes + untracked files.
# Sentinel: /tmp/claude-task-active-YYYYMMDD (date-scoped, auto-expires at midnight)

SENTINEL="/tmp/claude-task-active-$(date +%Y%m%d)"
LOGFILE="${HOOK_LOG:-$HOME/.claude/hook-log.txt}"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)

log() { echo "$TIMESTAMP PRETOOLUSE $1" >> "$LOGFILE"; }

# Not a git repo → pass (e.g. editing ~/.claude files directly)
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -z "$GIT_ROOT" ]]; then
  log "PASS no_git_repo"
  exit 0
fi

# Count modified files: staged + unstaged tracked (excludes untracked)
MODIFIED=$(git status --porcelain 2>/dev/null | grep -v '^??' | wc -l | tr -d ' ')
# Count untracked files separately
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
TOTAL=$((MODIFIED + UNTRACKED))

# Threshold not reached → pass
if [[ "$TOTAL" -le 2 ]]; then
  log "PASS file_count:${TOTAL}"
  exit 0
fi

# Task is in_progress → pass
if [[ -f "$SENTINEL" ]]; then
  TASK=$(cat "$SENTINEL" 2>/dev/null || echo "unknown")
  log "PASS task_active:${TASK}"
  exit 0
fi

# Block
log "BLOCK no_task:file_count:${TOTAL}"
echo "BLOCKED: ${TOTAL} files modified with no active task." >&2
echo "Use TaskCreate to create a task, then TaskUpdate { status: in_progress } to open the gate." >&2
echo "Note: TaskCreate alone does NOT open the gate — TaskUpdate to in_progress is required." >&2
exit 2
```

- [ ] **Step 2: Make executable**

```bash
chmod +x ~/.claude/scripts/pretooluse-task-gate.sh
```

- [ ] **Step 3: Smoke-test — no git repo path**

```bash
cd /tmp && bash ~/.claude/scripts/pretooluse-task-gate.sh
echo "Exit: $?"
```
Expected: exit 0, no output.

- [ ] **Step 4: Smoke-test — clean repo (0 files modified)**

```bash
cd ~/Documents/Git/dd-mcp-shared && bash ~/.claude/scripts/pretooluse-task-gate.sh
echo "Exit: $?"
```
Expected: exit 0, `PASS file_count:0` in hook-log.txt.

- [ ] **Step 5: Smoke-test — sentinel present (gate passes despite >2 files)**

```bash
SENTINEL="/tmp/claude-task-active-$(date +%Y%m%d)"
echo "test-task" > "$SENTINEL"
cd ~/Documents/Git/dd-mcp-shared
# Create untracked files INSIDE the repo so git sees them
touch _t1 _t2 _t3
bash ~/.claude/scripts/pretooluse-task-gate.sh
echo "Exit: $?"
rm _t1 _t2 _t3 "$SENTINEL"
```
Expected: exit 0, `PASS task_active:test-task` in hook-log.txt.

- [ ] **Step 6: Smoke-test — gate blocks when >2 files and no sentinel**

```bash
cd ~/Documents/Git/dd-mcp-shared
touch _t1 _t2 _t3
bash ~/.claude/scripts/pretooluse-task-gate.sh
echo "Exit: $?"   # expected: 2
rm _t1 _t2 _t3
```
Expected: exit 2, BLOCKED message on stderr.

- [ ] **Step 7: Commit**

```bash
cd ~/.claude
git add scripts/pretooluse-task-gate.sh
git commit -m "feat: add PreToolUse task gate hook"
```

---

## Task 2: `posttooluse-task-reviewer.sh`

**Files:**
- Create: `~/.claude/scripts/posttooluse-task-reviewer.sh`

**Note on gate flow:** The sentinel is written on `TaskUpdate → in_progress`. `TaskCreate` alone does NOT write the sentinel — it creates the task in pending state. The required flow is always: `TaskCreate` → `TaskUpdate {status: in_progress}`. This is consistent with how Claude Code's task tools work and is the recommended pattern in global CLAUDE.md.

**Note on PostToolUse context injection:** PostToolUse hooks that exit 0 with stdout output inject that text into the Claude Code conversation as context. This is the same mechanism used by `posttooluse-hook.sh` for empty-result warnings. Task 6 Step 3 verifies this is working — if the reviewer prompt is not visible in Claude's response, the hook mechanism is broken and must be investigated before proceeding.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# posttooluse-task-reviewer.sh — Claude Code PostToolUse hook
# On TaskUpdate:
#   - in_progress → write /tmp/claude-task-active-YYYYMMDD sentinel
#   - completed/cancelled → delete sentinel; on completed, inject diff + review prompt
# Exit 0 always (context injection, not a block).
# Note: 'done' handled as alias for 'completed' — remove if TaskUpdate never returns 'done'.

SENTINEL="/tmp/claude-task-active-$(date +%Y%m%d)"
LOGFILE="${HOOK_LOG:-$HOME/.claude/hook-log.txt}"
TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)

log() { echo "$TIMESTAMP POSTTOOLUSE TASK $1" >> "$LOGFILE"; }

INPUT=$(cat)

TOOL=$(echo "$INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('tool_name', 'unknown'))
" 2>/dev/null)

# Only act on task tools
if [[ "$TOOL" != "TaskUpdate" && "$TOOL" != "TaskCreate" ]]; then
  exit 0
fi

# Extract status and title from tool_result (the returned task object)
STATUS=$(echo "$INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('tool_result', {})
if isinstance(r, dict):
    print(r.get('status', ''))
elif isinstance(r, str):
    import re
    m = re.search(r'\"status\":\s*\"([^\"]+)\"', r)
    print(m.group(1) if m else '')
" 2>/dev/null)

TITLE=$(echo "$INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('tool_result', {})
if isinstance(r, dict):
    print(r.get('title', r.get('name', 'unknown task')))
elif isinstance(r, str):
    import re
    m = re.search(r'\"title\":\s*\"([^\"]+)\"', r)
    print(m.group(1) if m else 'unknown task')
" 2>/dev/null)

case "$STATUS" in
  in_progress)
    echo "$TITLE" > "$SENTINEL"
    log "SENTINEL_WRITE:${TITLE}"
    ;;
  completed|done)
    # 'done' included as alias — verify against TaskUpdate API output if gate behaves unexpectedly
    rm -f "$SENTINEL"
    log "SENTINEL_DELETE:${TITLE}"
    # Capture git diff (first 200 lines — avoids context overflow on large diffs)
    DIFF=$(git diff HEAD 2>/dev/null | head -200)
    DIFF_LINES=$(echo "$DIFF" | wc -l | tr -d ' ')
    # Inject review context (exit 0 = PostToolUse context injection)
    echo ""
    echo "[Task Reviewer] Task '${TITLE}' just completed."
    echo "--- git diff HEAD (${DIFF_LINES} lines) ---"
    echo "$DIFF"
    echo "---"
    echo "Review the diff above and verify:"
    echo "1. Implementation matches the task description"
    echo "2. No obvious gaps: missing error handling, untested paths, incomplete implementation"
    echo "3. No unintended side-effects in unrelated files"
    echo "If issues found: use TaskUpdate to revert status to in_progress and fix before marking complete again."
    echo ""
    ;;
  cancelled)
    rm -f "$SENTINEL"
    log "SENTINEL_DELETE_CANCELLED:${TITLE}"
    ;;
  *)
    log "IGNORED_STATUS:${STATUS}:${TITLE}"
    ;;
esac

exit 0
```

- [ ] **Step 2: Make executable**

```bash
chmod +x ~/.claude/scripts/posttooluse-task-reviewer.sh
```

- [ ] **Step 3: Smoke-test — in_progress event**

```bash
SENTINEL="/tmp/claude-task-active-$(date +%Y%m%d)"
echo '{"tool_name":"TaskUpdate","tool_result":{"status":"in_progress","title":"Write tests"}}' \
  | bash ~/.claude/scripts/posttooluse-task-reviewer.sh
echo "Exit: $?  Sentinel: $(cat $SENTINEL 2>/dev/null || echo absent)"
```
Expected: exit 0, sentinel contains "Write tests".

- [ ] **Step 4: Smoke-test — completed event (includes diff)**

```bash
SENTINEL="/tmp/claude-task-active-$(date +%Y%m%d)"
echo '{"tool_name":"TaskUpdate","tool_result":{"status":"completed","title":"Write tests"}}' \
  | bash ~/.claude/scripts/posttooluse-task-reviewer.sh
echo "Exit: $?  Sentinel: $(cat $SENTINEL 2>/dev/null || echo absent)"
```
Expected: exit 0, sentinel absent, reviewer prompt + git diff printed to stdout.

- [ ] **Step 5: Smoke-test — non-task tool (passthrough)**

```bash
echo '{"tool_name":"Bash","tool_result":"ok"}' \
  | bash ~/.claude/scripts/posttooluse-task-reviewer.sh
echo "Exit: $?"
```
Expected: exit 0, no output.

- [ ] **Step 6: Commit**

```bash
cd ~/.claude
git add scripts/posttooluse-task-reviewer.sh
git commit -m "feat: add PostToolUse task reviewer hook"
```

---

## Task 3: Wire hooks in `settings.json`

**Files:**
- Modify: `~/.claude/settings.json`

Use `jq` for both changes to avoid manual JSON editing of the complex inline command string.

**Change A** — Add task gate as a second hook under the existing `PreToolUse` `Edit|Write` matcher:

- [ ] **Step 1: Apply Change A with jq**

```bash
jq '.hooks.PreToolUse[0].hooks += [{"type":"command","command":"bash /Users/anilkumar.pappu/.claude/scripts/pretooluse-task-gate.sh"}]' \
  ~/.claude/settings.json > /tmp/settings-new.json \
  && mv /tmp/settings-new.json ~/.claude/settings.json
```

- [ ] **Step 2: Validate Change A**

```bash
python3 -m json.tool ~/.claude/settings.json > /dev/null && echo "Valid JSON"
# Verify the new entry is present
python3 -c "
import json
d = json.load(open('/Users/anilkumar.pappu/.claude/settings.json'))
hooks = d['hooks']['PreToolUse'][0]['hooks']
print(f'PreToolUse Edit|Write hooks: {len(hooks)}')
for h in hooks: print(' -', h['command'][:80])
"
```
Expected: 2 hooks listed, second one ends with `pretooluse-task-gate.sh`.

**Change B** — Add new `PostToolUse` entry for task tools:

- [ ] **Step 3: Apply Change B with jq**

```bash
jq '.hooks.PostToolUse += [{"matcher":"TaskUpdate|TaskCreate","hooks":[{"type":"command","command":"bash /Users/anilkumar.pappu/.claude/scripts/posttooluse-task-reviewer.sh"}]}]' \
  ~/.claude/settings.json > /tmp/settings-new.json \
  && mv /tmp/settings-new.json ~/.claude/settings.json
```

- [ ] **Step 4: Validate Change B**

```bash
python3 -m json.tool ~/.claude/settings.json > /dev/null && echo "Valid JSON"
python3 -c "
import json
d = json.load(open('/Users/anilkumar.pappu/.claude/settings.json'))
entries = d['hooks']['PostToolUse']
print(f'PostToolUse entries: {len(entries)}')
for e in entries: print(' -', e.get('matcher','<no matcher>'))
"
```
Expected: 2 PostToolUse entries — `mcp__.*|Bash` and `TaskUpdate|TaskCreate`.

- [ ] **Step 5: Commit**

```bash
cd ~/.claude
git add settings.json
git commit -m "feat: wire task gate and reviewer hooks in settings.json"
```

---

## Task 4: Clear sentinel at SessionStart

**Files:**
- Modify: `~/.claude/settings.json` (SessionStart command)

The date-scoped sentinel (`/tmp/claude-task-active-YYYYMMDD`) auto-expires at midnight. However, sessions started on the same calendar day after a crash would inherit a stale same-day sentinel. The SessionStart hook clears it unconditionally so every session starts with no active task.

- [ ] **Step 1: Add sentinel cleanup to the start of the SessionStart command using jq**

```bash
CURRENT=$(python3 -c "
import json
d = json.load(open('/Users/anilkumar.pappu/.claude/settings.json'))
print(d['hooks']['SessionStart'][0]['hooks'][0]['command'])
")
NEW="bash -c 'rm -f /tmp/claude-task-active-\$(date +%Y%m%d); ${CURRENT#bash -c '}"
# Because the above string manipulation is fragile on the inline command,
# use jq to prepend to the command string instead:
jq '.hooks.SessionStart[0].hooks[0].command |= "bash -c '\''rm -f /tmp/claude-task-active-$(date +%Y%m%d); " + ltrimstr("bash -c '\''")' \
  ~/.claude/settings.json > /tmp/settings-new.json \
  && mv /tmp/settings-new.json ~/.claude/settings.json
```

> **If the jq command fails** (the inline command string quoting is complex): edit `settings.json` directly with the Edit tool. Find the SessionStart command string — it starts with `bash -c 'echo "--- Worktree Health ---"`. Change it to start with `bash -c 'rm -f /tmp/claude-task-active-$(date +%Y%m%d); echo "--- Worktree Health ---"`.

- [ ] **Step 2: Validate JSON**

```bash
python3 -m json.tool ~/.claude/settings.json > /dev/null && echo "Valid JSON"
python3 -c "
import json
d = json.load(open('/Users/anilkumar.pappu/.claude/settings.json'))
cmd = d['hooks']['SessionStart'][0]['hooks'][0]['command']
print('SessionStart starts with:', cmd[:80])
"
```
Expected: starts with `bash -c 'rm -f /tmp/claude-task-active-...`.

- [ ] **Step 3: Commit**

```bash
cd ~/.claude
git add settings.json
git commit -m "feat: clear task sentinel at session start"
```

---

## Task 5: Global CLAUDE.md — task gate rule

**Files:**
- Modify: `~/.claude/CLAUDE.md`

- [ ] **Step 1: Add rule to `## Execution Principles` section**

Find the `## Execution Principles` section. Add before `### Always reference Confluence...`:

```markdown
### Task gate — required for multi-file operations

Any operation touching 3+ files or 2+ external systems must have an `in_progress` task before the first Edit or Write. The PreToolUse hook enforces this.

Required flow:
1. `TaskCreate` — create the task (pending state; gate still closed)
2. `TaskUpdate { status: in_progress }` — opens the gate (sentinel written)
3. Do the work
4. `TaskUpdate { status: completed }` — closes gate + fires reviewer with git diff

Single-file edits (1–2 files) pass through without a task.
```

- [ ] **Step 2: Commit**

```bash
cd ~/.claude
git add CLAUDE.md
git commit -m "docs: add task gate rule to Execution Principles"
```

---

## Task 6: End-to-end integration test

**Test the full create → in_progress → modify → complete → re-gate lifecycle in one sequence.**

- [ ] **Step 1: Confirm clean state**

```bash
SENTINEL="/tmp/claude-task-active-$(date +%Y%m%d)"
ls "$SENTINEL" 2>/dev/null && echo "WARNING: stale sentinel present" || echo "Clean"
```
Expected: "Clean" (SessionStart should have cleared it).

- [ ] **Step 2: Verify gate blocks at >2 files**

```bash
cd ~/Documents/Git/dd-mcp-shared
touch _t1 _t2 _t3
bash ~/.claude/scripts/pretooluse-task-gate.sh 2>&1
echo "Exit: $?"
```
Expected: exit 2, BLOCKED message.

- [ ] **Step 3: Open the gate via TaskUpdate in_progress**

```bash
echo '{"tool_name":"TaskUpdate","tool_result":{"status":"in_progress","title":"Integration test"}}' \
  | bash ~/.claude/scripts/posttooluse-task-reviewer.sh
SENTINEL="/tmp/claude-task-active-$(date +%Y%m%d)"
echo "Sentinel: $(cat $SENTINEL 2>/dev/null || echo absent)"
```
Expected: sentinel contains "Integration test".

- [ ] **Step 4: Verify gate passes with sentinel present**

```bash
cd ~/Documents/Git/dd-mcp-shared
bash ~/.claude/scripts/pretooluse-task-gate.sh
echo "Exit: $?"
```
Expected: exit 0, `PASS task_active:Integration test` in hook-log.txt.

- [ ] **Step 5: Complete the task — verify reviewer fires and sentinel clears**

```bash
echo '{"tool_name":"TaskUpdate","tool_result":{"status":"completed","title":"Integration test"}}' \
  | bash ~/.claude/scripts/posttooluse-task-reviewer.sh
SENTINEL="/tmp/claude-task-active-$(date +%Y%m%d)"
echo "Sentinel: $(cat $SENTINEL 2>/dev/null || echo absent)"
```
Expected: sentinel absent, reviewer prompt + git diff printed to stdout.

- [ ] **Step 6: Verify gate blocks again after completion**

```bash
cd ~/Documents/Git/dd-mcp-shared
bash ~/.claude/scripts/pretooluse-task-gate.sh 2>&1
echo "Exit: $?"
```
Expected: exit 2 (sentinel gone, 3 files still present → blocked).

- [ ] **Step 7: Verify PostToolUse reviewer output is injected as context in a live session**

In a live Claude Code session: use `TaskUpdate {status: completed}` on any task. Confirm the reviewer prompt and git diff appear in Claude's response (not just in the hook log). If no reviewer prompt is visible, the PostToolUse stdout injection mechanism is not working — investigate before proceeding.

- [ ] **Step 8: Clean up test files**

```bash
cd ~/Documents/Git/dd-mcp-shared && rm -f _t1 _t2 _t3
```

- [ ] **Step 9: Update spec status**

```bash
sed -i '' 's/Systems 1, 2, 3 shipped; System 4 pending/Systems 1, 2, 3, 4 shipped/' \
  ~/.claude/docs/superpowers/specs/2026-03-24-ai-reliability-infrastructure-design.md
```

- [ ] **Step 10: Final commit**

```bash
cd ~/.claude
git add docs/superpowers/specs/2026-03-24-ai-reliability-infrastructure-design.md \
       docs/superpowers/plans/2026-03-24-subagent-patterns.md
git commit -m "docs: mark System 4 implemented, add subagent-patterns plan"
```
