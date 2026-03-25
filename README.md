# claude-ops

Claude Code reliability infrastructure — four systems built in response to four real failure modes.

## The Story

I use Claude Code as my daily driver for customer engineering work — multiple live engagements running in parallel. The setup is deliberate: every session gets its own git worktree so branches never bleed into each other. Day branches (`dev/YYYY-MM-DD`) group the work. Session branches feed into them. Claude Code sessions map 1:1 to worktrees — no context switching, no accidental cross-session edits.

That structure gave me confidence in the *isolation*. What it didn't give me was confidence in the *AI*.

**First: Claude would claim work was done before it was.** Tests "passing", changes verified — then I'd check and nothing had actually run. So I built a Stop hook that hashes `git status --porcelain` at verification time and blocks session end if the tree changes afterward. No sentinel = no close. Wrong hash = re-verify.

**That worked. Then I noticed context contamination.** Facts from one customer engagement bleeding into reasoning about another. Wrong org IDs, wrong environments. So I built a shared Python library with `@require_verified_context` — a decorator that blocks any MCP tool from running against an unregistered customer, with every fact stamped with a trust tag at the response boundary.

**With contamination solved, the next gap was between sessions.** Wake up, start a session, no idea what was blocked yesterday. So I added a SessionStart hook: daily morning brief auto-generated at session start — open tasks, RAG status, worktree health, last session's hook warnings.

**The last one took longest to see: scope drift.** Long sessions would sprawl across files with no clear ownership. So I added a PreToolUse hook that blocks Edit/Write if 3+ files are modified without an active task, and a PostToolUse hook that injects a git diff review prompt the moment a task completes.

Each system came from a real failure. This repo is the result.

---

## Architecture Diagrams

Visual reference: **[anildatadog.github.io/claude-ops/diagrams.html](https://anildatadog.github.io/claude-ops/diagrams.html)** — four diagrams: git workflow, reliability stack, hook lifecycle, data flow.

---

## The Four Systems

### System 1: Verification Gates (`stop-hook.sh`, `write-sentinel.sh`)

A Stop hook that hashes `git status --porcelain` at verification time and blocks session end if the tree changes afterward.

```
Stop fires
  → sentinel absent? → BLOCKED: run verification first
  → sentinel present → compare stored hash vs current git status hash
  → match → pass
  → mismatch → BLOCKED: tree changed since verification
```

The sentinel is date-scoped (`/tmp/claude-verified-YYYYMMDD`) — resets daily. Every calendar day begins unverified. Forces at least one verification pass before closing.

**Usage:** After `superpowers:verification-before-completion` passes, run `write-sentinel.sh` to write the sentinel. Session end is blocked until this happens.

---

### System 2: Empty Result Detection (`posttooluse-hook.sh`)

PostToolUse hook that detects when MCP tools return empty/null results and emits a throttled warning — once per tool+result-type per session.

```
Tool returns null / [] / {} / ""
  → warn once: "mcp__datadog__search returned empty_array"
  → throttle: same tool+result-type suppressed for rest of session
  → silent tool failures surface immediately instead of causing confusion later
```

---

### System 3: Autonomous Morning Briefs (`session-brief.sh`, `memory-health.sh`)

SessionStart hook generates a morning brief once per day:
- Worktree health (uncommitted work, stale branches)
- Project RAG status from memory files
- Previous session's hook warnings
- Issue tracker snapshot (if Jira/Linear MCP configured)

Weekly memory health check (Mondays) flags:
- Index entries not updated in 30+ days
- Stop hook silence anomalies
- Repos on disk not in the inventory

---

### System 4: Task Decomposition Enforcement (`pretooluse-task-gate.sh`, `posttooluse-task-reviewer.sh`)

PreToolUse gate blocks Edit/Write when 3+ files are modified without an active task.

```
Edit/Write fires
  → ≤2 files modified → pass
  → 3+ files + task in_progress → pass
  → 3+ files + no task → BLOCKED: create a task first
```

PostToolUse hook fires a git diff review prompt when a task completes:

```
TaskUpdate { status: completed } fires
  → delete sentinel
  → capture git diff HEAD (200 lines)
  → inject: "[Task Reviewer] Task X just completed. Review the diff above..."
```

Sentinel: `/tmp/claude-task-active-YYYYMMDD` (date-scoped, cleared at SessionStart).

---

## Installation

```bash
# 1. Clone this repo
git clone https://github.com/anildatadog/claude-ops.git
cd claude-ops

# 2. Copy scripts to ~/.claude/scripts/
mkdir -p ~/.claude/scripts
cp scripts/*.sh ~/.claude/scripts/
chmod +x ~/.claude/scripts/*.sh

# 3. Copy hook configuration
# Merge config/settings-template.json into your ~/.claude/settings.json
# (See config/settings-template.json for the hook definitions)

# 4. Create the briefs directory
mkdir -p ~/.claude/briefs
```

### Configure `session-brief.sh`

Set `CLAUDE_MEMORY_DIR` to point at your project memory directory, or let it auto-detect:

```bash
# Auto-detect (finds first memory/ dir under ~/.claude/projects/)
bash ~/.claude/scripts/session-brief.sh

# Or set explicitly
export CLAUDE_MEMORY_DIR="$HOME/.claude/projects/my-project/memory"
```

---

## File Reference

| Script | Hook type | Purpose |
|--------|-----------|---------|
| `stop-hook.sh` | Stop | Blocks session end without verification sentinel |
| `write-sentinel.sh` | Manual | Writes git-status hash after verification passes |
| `posttooluse-hook.sh` | PostToolUse | Detects empty/null tool results |
| `pretooluse-task-gate.sh` | PreToolUse | Blocks edits without active task at 3+ files |
| `posttooluse-task-reviewer.sh` | PostToolUse | Manages task sentinel + injects diff review |
| `session-brief.sh` | SessionStart (via hook) | Daily morning brief generator |
| `memory-health.sh` | SessionStart (via hook, Mondays) | Weekly memory hygiene check |
| `worktree-health.sh` | SessionStart | Scans for stale worktrees and uncommitted work |
| `hook-health-check.sh` | SessionStart | Verifies hooks are registered and firing |
| `end-session.sh` | Manual | Merges session branch, cleans up worktree |

---

## Design Documents

- [`docs/design/2026-03-24-ai-reliability-infrastructure-design.md`](docs/design/2026-03-24-ai-reliability-infrastructure-design.md) — Full four-system architecture spec
- [`docs/design/2026-03-24-hook-infrastructure.md`](docs/design/2026-03-24-hook-infrastructure.md) — Hook system implementation plan
- [`docs/design/2026-03-24-subagent-patterns.md`](docs/design/2026-03-24-subagent-patterns.md) — Task decomposition implementation plan

---

## Hook Log Format

All hooks append to `~/.claude/hook-log.txt`:

```
2026-03-24T08:32:11 STOP PASS hash_match
2026-03-24T09:14:02 STOP BLOCK no_sentinel
2026-03-24T09:16:45 POSTTOOLUSE WARN empty_result:mcp__datadog__search_monitors
2026-03-24T10:01:33 PRETOOLUSE BLOCK no_task:file_count:5
2026-03-24T10:03:12 POSTTOOLUSE TASK SENTINEL_WRITE:Implement feature X
2026-03-24T10:44:01 POSTTOOLUSE TASK SENTINEL_DELETE:Implement feature X
```

---

## Requirements

- Claude Code (claude.ai/claude-code)
- macOS or Linux
- bash 3.2+
- git
- python3 (for JSON parsing in hooks)
- gh CLI (for worktree-health.sh PR checks)

---

## License

MIT
