# AI Reliability Infrastructure — Design Spec

**Date:** 2026-03-24
**Status:** ✅ Implemented (2026-03-24) — Systems 1, 2, 3, 4 shipped
**Scope:** Global (~/.claude) + all current and future IS MCP repos
**Problem:** Four known AI failure modes: session drift, unverified outputs, context contamination, no autonomous activity between sessions

---

## Overview

Four systems, built in sequence:

1. **Hook Infrastructure** — `~/.claude/settings.json` (global, no per-repo setup)
2. **Tool Enforcement** — `dd-mcp-shared` + retrofit to all MCP repos
3. **Cron Agents** — daily morning brief + weekly memory health check
4. **Subagent Patterns** — task decomposition enforced via hooks

Each system compensates for a specific failure mode and applies globally — to all current repos and all future repos automatically.

---

## System 1: Hook Infrastructure

**Failure mode addressed:** Confident wrong claims, silent failures
**Location:** `~/.claude/settings.json` — applies to every repo, zero per-repo setup

### Stop hook — mandatory verification gate

The sentinel stores the `git status --porcelain` hash at the time verification completes:
```
/tmp/claude-verified-YYYYMMDD  ← contains: sha256 of "git status --porcelain" output at verification time
```

Stop hook logic:
```
Stop fires
  → sentinel absent? → block: "run verification-before-completion first"
  → sentinel present → read stored hash
  → compute current git status hash
  → hashes match? → pass (tree unchanged since verification)
  → hashes differ? → block: "changes since last verification — re-verify"
```

`verification-before-completion` skill writes sentinel (with current git status hash) on completion.

This eliminates the race condition: the sentinel is tied to the exact git tree state at verification time, not just the calendar date. If you make one more change after verifying, the hash changes and the hook re-blocks. Date-scoped filename resets daily as an intentional process control — every calendar day begins unverified, forcing at least one verification pass per day. This is desirable: a clean day's work should be verified before closing, not carried over from yesterday's sentinel.

### PostToolUse hook — silent result detection

Fires after MCP tool calls and Bash. Detects empty/null/zero-count results. Emits a single warning per occurrence (exit 0 — context injection, not a block).

**Throttle:** Hook checks `~/.claude/hook-log.txt` — if the same tool+result-type combination has already emitted a warning in this session, skip. Throttle key is `<tool_name>:<result_type>` (e.g., `mcp__datadog__search_monitors:empty_array`). Different empty result types from the same tool (null vs empty_array vs zero_count) each emit once. Prevents context bloat without hiding distinct failure modes.

### Hook health log

Every hook appends one line to `~/.claude/hook-log.txt` (append-only, no rotation, no truncation).
All hooks use `echo >> ~/.claude/hook-log.txt` — safe for concurrent writes at second-level timestamp granularity.
Log format:
```
2026-03-24T08:32:11 STOP PASS hash_match
2026-03-24T09:14:02 STOP BLOCK no_sentinel
2026-03-24T09:16:45 POSTTOOLUSE WARN empty_result:mcp__datadog__search_datadog_monitors
```

### SessionStart extension

Extend `worktree-health.sh` (already runs at SessionStart). Add as final step:
1. Verify Stop hook and PostToolUse hook are present in `settings.json`
2. Read `hook-log.txt` for previous session (entries before today's session start time)
3. Flag: if Stop hook had zero blocks in a week with active git history → "Stop hook may not be firing"
4. Surface any warnings from previous session

Ordering is explicit: SessionStart runs worktree-health.sh → health check reads prior session log → session begins. No timing ambiguity.

---

## System 2: dd-mcp-shared Enforcement

**Failure mode addressed:** Customer context contamination, stale facts
**Location:** `dd-mcp-shared`; retrofit to all MCP repos; inherited by all future repos

### `@require_verified_context` decorator

Applied to every tool function that accepts a `customer_id`. Calls `check_registry()` before any API call. No valid registration = no execution. Raises, does not warn.

```python
def require_verified_context(fn):
    @wraps(fn)
    async def wrapper(*args, **kwargs):
        customer_id = kwargs.get("customer_id")
        if customer_id:
            check_registry(customer_id)  # raises ValueError if not active
        return await fn(*args, **kwargs)
    return wrapper
```

### Source tagging — decorator-level, not LLM-level

The LLM calls tools with plain strings. It cannot construct typed objects. Source tagging is therefore applied at the **decorator boundary**, not at the call site:

```python
SOURCE_TAG_MAP = {
    "mcp__datadog__": "API",
    "mcp__atlassian__": "API",
    "mcp__dd-productivity__read": "FILE",
    "TRANSCRIPT": "TRANSCRIPT",  # explicit override only
}
```

The decorator infers source from the calling tool's name prefix and stamps tool responses with the appropriate tag. Untagged responses from unknown tool prefixes are flagged as `INFERRED` (low-trust). The LLM sees the tag in the response; no marshaling required at call time.

This replaces the Pydantic `CustomerFact` model from the draft. Pydantic enforcement at the LLM call boundary is not implementable — the LLM passes strings, not typed objects. Enforcement at the response boundary is implementable and achieves the same goal.

### Retrofit scope

| Repo | Tools needing `@require_verified_context` |
|---|---|
| `dd-cicd-onboarding-mcp` | `scan_ci_state`, `generate_gap_report`, `create_pipeline_monitors`, `validate_dora` |
| `dd-governed-onboarding-mcp` | All tools accepting `customer_id` — scoped during Phase 2 implementation via `grep -r "customer_id" tools/` |
| `dd-ust-mcp` | `discover_tag_values`, `run_gap_analysis`, `apply_service_catalog`, `validate_tag_coverage` |
| `splunk-dd-migration-mcp` | `create_monitors`, `suggest_field_mappings_llm`, `generate_customer_report` |
| `dd-productivity-mcp` | `store_customer_credentials`, `get_customer_credentials` |

`dd-governed-onboarding-mcp` scope is resolved during Phase 2 via grep — not pre-enumerated here to avoid stale counts.

### `new-repo-init.sh`

Script in `dd-mcp-shared/scripts/`. Run once on any new IS MCP repo. Produces:
- `requirements.txt` with `dd-mcp-shared` pinned
- `server.py` stub with `@require_verified_context` on starter tool
- `customers/` directory structure
- `CLAUDE.md` from standard template
- `.github/CODEOWNERS`
- GitHub Actions stubs: `datadog-test-optimization.yml`, `datadog-code-security.yml`

---

## System 3: Cron Agents

**Failure mode addressed:** No activity between sessions, stale Jira, missed blockers
**Location:** `CronCreate` jobs; output to `~/.claude/briefs/`

### Credential access for cron jobs
Cron agents use stored tokens — not interactive auth. Specifically:
- Jira: Atlassian MCP server uses pre-configured tokens (already set up for interactive use; cron agents call the same MCP tools)
- Memory files: local reads, no auth
- Git: local reads, no auth
- **No 1Password unlocking required.** Cron jobs do not call `op run` or `gcloud auth`.

If MCP server is not running when cron fires → job logs "MCP unavailable, Jira section skipped" and continues with local-only brief.

### Job 1: Morning brief (daily 08:00)

Reads:
- Jira (via Atlassian MCP): open tasks assigned to Anil, comments awaiting response, overdue items
- `memory/fca-session-log.md`, `memory/fca-cicd-progress.md`, `memory/fca-ust-progress.md` — RAG status and blockers
- `~/.claude/scripts/worktree-health.sh` output — unmerged session branches

Output: `~/.claude/briefs/YYYY-MM-DD-HHmmss.md` (timestamp-scoped — idempotent if cron fires twice).

SessionStart hook reads the **latest** brief file for today (`ls -t ~/.claude/briefs/YYYY-MM-DD-*.md | head -1`) and prepends it to session context automatically. If no brief exists for today (cron hasn't run yet), SessionStart skips silently.

**Constraints:** Read-only. No writes to Jira, Confluence, Slack, or any external system.

### Job 2: Memory health check (weekly Monday 08:00)

Reads:
- `memory/confluence-gdrive-index.md` — flags entries not updated in 30+ days
- `memory/repo_inventory.md` — cross-references against recent git commits
- `hook-log.txt` — flags if Stop hook has zero blocks over the past week with active git history

Output: `~/.claude/briefs/memory-health-YYYY-MM-DD.md`

**Constraints:** Read-only. Flags only — no automatic fixes.

---

## System 4: Subagent Patterns

**Failure mode addressed:** Session drift in long multi-step operations
**Location:** `~/.claude/settings.json` hook extension + global `CLAUDE.md`

### PreToolUse extension — task gate

Before any Edit or Write:
- Count files modified in this session branch since worktree checkout: `git diff --name-only HEAD`
- If count > 2 AND no task is currently `in_progress` → block
- Single-file edits pass through without triggering the gate
- "In progress task" = a task created via `TaskCreate` with status `in_progress` — local tool, not Jira

The count resets to 0 each time a new `TaskCreate` task is started (via PostToolUse on TaskCreate hook).

### PostTaskComplete — lightweight reviewer

When `TaskUpdate` sets status to `completed`, a PostToolUse hook fires a reviewer subagent:
- Input: task subject + description + `git diff HEAD` since task started
- Fresh context, no attachment to the work
- If reviewer flags an issue: task status reverted to `in_progress`, issue surfaced before proceeding

Tasks use the built-in `TaskCreate`/`TaskUpdate` tools — not Jira. Jira tasks are for engagement tracking; session tasks are ephemeral and local.

### Global CLAUDE.md addition

Add to `## Execution Principles`:
> Any operation touching 3+ files or 2+ external systems must have an `in_progress` task (via `TaskCreate`) before the first Edit or Write. The PreToolUse hook enforces this.

---

## Sequencing (corrected)

| Phase | System | Dependency | Can parallel? |
|---|---|---|---|
| 1 | Hook infrastructure | None | — |
| 2 | dd-mcp-shared enforcement | Phase 1 | Yes — parallel with Phase 3 |
| 3 | Cron agents | Phase 1 | Yes — parallel with Phase 2 |
| 4 | Subagent patterns | Phase 3 (task tool clarified) | After Phase 3 |

Phase 4 follows Phase 3 because task management (TaskCreate as local tool vs Jira) must be clarified first. Phases 2 and 3 are genuinely independent and can run in parallel.

---

## What This Does Not Fix

- **Credential access**: 1Password/gcloud interactive auth dependency remains
- **Customer calls and relationships**: no engineering solution
- **Internal Datadog org context**: no engineering solution
- **Output correctness ceiling**: hooks raise the floor; the reviewer agent catches obvious gaps; subtle domain errors still require human judgment

---

## Future Repo Inheritance

| Mechanism | Coverage |
|---|---|
| `~/.claude/settings.json` hooks | All repos — zero per-repo setup |
| `@require_verified_context` decorator | All repos importing `dd-mcp-shared` |
| `new-repo-init.sh` | New repos scaffolded with enforcement from day one |
| Global `CLAUDE.md` task gate rule | All repos — inherited automatically |
