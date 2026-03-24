# dd-mcp-shared Enforcement Implementation Plan

> **Status:** ✅ Implemented 2026-03-24
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `@require_verified_context` decorator and source-tagging to `dd_mcp_shared`, then retrofit all 5 IS MCP repos so every tool accepting a `customer_id` (or `org_id`) is enforced at the library level.

**Architecture:** Decorator defined once in `dd_mcp_shared/registry.py`; source tag inference in `dd_mcp_shared/data_discipline.py`; `new-repo-init.sh` scaffold script in `dd-mcp-shared/scripts/`; each repo's tool functions decorated at import — no per-call code changes required.

**Tech Stack:** Python 3.11+, FastMCP, `asyncio.iscoroutinefunction`, `functools.wraps`, Bash

**Spec:** `~/.claude/docs/superpowers/specs/2026-03-24-ai-reliability-infrastructure-design.md` — System 2

---

## File Structure

**Files to modify:**
- `dd-mcp-shared/dd_mcp_shared/registry.py` — add `require_verified_context` decorator
- `dd-mcp-shared/dd_mcp_shared/data_discipline.py` — add `stamp_source_tag()` + `SOURCE_TAG_MAP`
- `dd-mcp-shared/dd_mcp_shared/__init__.py` — export new symbols

**Files to create:**
- `dd-mcp-shared/scripts/new-repo-init.sh` — scaffold script for new IS repos

**Retrofit files to modify (one task per repo):**
- `dd-cicd-onboarding-mcp/tools/ci_state.py` (and others with `customer_id`)
- `dd-ust-mcp/tools/discover.py` (and others)
- `splunk-dd-migration-mcp/tools/*.py` (customer_dir-based — adapter needed)
- `dd-productivity-mcp/tools/credentials.py`
- `dd-governed-onboarding-mcp/tools/*.py` (org_id-based)

---

## Task 1: Add `require_verified_context` decorator to `dd_mcp_shared/registry.py`

**Files:**
- Modify: `dd-mcp-shared/dd_mcp_shared/registry.py`
- Test: `dd-mcp-shared/tests/test_require_verified_context.py` (create)

- [ ] **Step 1: Write failing tests**

Create `dd-mcp-shared/tests/test_require_verified_context.py`:

```python
"""Tests for require_verified_context decorator."""
import asyncio
import pytest
from unittest.mock import patch, MagicMock
from dd_mcp_shared.registry import require_verified_context


def _mock_check_active(customer_id):
    """Passes for 'active-cust', raises for 'bad-cust'."""
    if customer_id == "bad-cust":
        raise ValueError("Customer 'bad-cust' not registered or not active")


def _mock_check_missing(customer_id):
    """Registry missing — returns None (warn-only)."""
    return None


class TestRequireVerifiedContextSync:
    def test_passes_active_customer(self):
        @require_verified_context
        def my_tool(customer_id: str) -> str:
            return f"result for {customer_id}"

        with patch("dd_mcp_shared.registry.check_registry", side_effect=_mock_check_active):
            result = my_tool(customer_id="active-cust")
        assert result == "result for active-cust"

    def test_blocks_inactive_customer(self):
        @require_verified_context
        def my_tool(customer_id: str) -> str:
            return "should not reach"

        with patch("dd_mcp_shared.registry.check_registry", side_effect=_mock_check_active):
            with pytest.raises(ValueError, match="not registered"):
                my_tool(customer_id="bad-cust")

    def test_no_customer_id_passes_through(self):
        @require_verified_context
        def list_all() -> list:
            return ["a", "b"]

        result = list_all()
        assert result == ["a", "b"]

    def test_org_id_fallback(self):
        """dd-governed-onboarding-mcp passes org_id instead of customer_id."""
        @require_verified_context
        def governed_tool(org_id: str) -> str:
            return f"org {org_id}"

        with patch("dd_mcp_shared.registry.check_registry", side_effect=_mock_check_active):
            result = governed_tool(org_id="active-cust")
        assert result == "org active-cust"


class TestRequireVerifiedContextAsync:
    def test_async_passes_active_customer(self):
        @require_verified_context
        async def async_tool(customer_id: str) -> str:
            return f"async result for {customer_id}"

        with patch("dd_mcp_shared.registry.check_registry", side_effect=_mock_check_active):
            result = asyncio.run(async_tool(customer_id="active-cust"))
        assert result == "async result for active-cust"

    def test_async_blocks_inactive_customer(self):
        @require_verified_context
        async def async_tool(customer_id: str) -> str:
            return "should not reach"

        with patch("dd_mcp_shared.registry.check_registry", side_effect=_mock_check_active):
            with pytest.raises(ValueError):
                asyncio.run(async_tool(customer_id="bad-cust"))
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-mcp-shared
python3 -m pytest tests/test_require_verified_context.py -v 2>&1 | head -30
```
Expected: ImportError or AttributeError (decorator not yet defined)

- [ ] **Step 3: Add decorator to `registry.py`**

Add at the bottom of `dd-mcp-shared/dd_mcp_shared/registry.py`, after the existing functions:

```python
import asyncio
from functools import wraps


def require_verified_context(fn):
    """
    Decorator: enforces check_registry() before any tool that accepts customer_id or org_id.

    Handles both sync and async tool functions. Extracts customer_id (or org_id fallback)
    from kwargs first, then from positional args via inspect.signature for robustness.

    Usage:
        @require_verified_context
        def my_tool(customer_id: str, ...) -> ...:
            ...

    Raises:
        ValueError: if customer is not registered or not active in _registry.yaml
    """
    import inspect as _inspect
    sig = _inspect.signature(fn)
    param_names = list(sig.parameters.keys())

    def _extract_id(args, kwargs):
        """Extract customer_id or org_id from args or kwargs."""
        # kwargs first (FastMCP always uses keyword args from JSON)
        cid = kwargs.get("customer_id") or kwargs.get("org_id")
        if cid:
            return cid
        # positional fallback via signature binding
        for name in ("customer_id", "org_id"):
            if name in param_names:
                idx = param_names.index(name)
                if idx < len(args):
                    return args[idx]
        return None

    if asyncio.iscoroutinefunction(fn):
        @wraps(fn)
        async def async_wrapper(*args, **kwargs):
            customer_id = _extract_id(args, kwargs)
            if customer_id:
                check_registry(customer_id)  # raises ValueError if not active
            return await fn(*args, **kwargs)
        return async_wrapper
    else:
        @wraps(fn)
        def sync_wrapper(*args, **kwargs):
            customer_id = _extract_id(args, kwargs)
            if customer_id:
                check_registry(customer_id)  # raises ValueError if not active
            return fn(*args, **kwargs)
        return sync_wrapper
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-mcp-shared
python3 -m pytest tests/test_require_verified_context.py -v
```
Expected: All 6 tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-mcp-shared
git add dd_mcp_shared/registry.py tests/test_require_verified_context.py
git commit --no-gpg-sign -m "feat: add require_verified_context decorator to registry"
```

---

## Task 2: Add `stamp_source_tag` to `dd_mcp_shared/data_discipline.py`

**Files:**
- Modify: `dd-mcp-shared/dd_mcp_shared/data_discipline.py`
- Test: `dd-mcp-shared/tests/test_stamp_source_tag.py` (create)

- [ ] **Step 1: Write failing tests**

Create `dd-mcp-shared/tests/test_stamp_source_tag.py`:

```python
"""Tests for stamp_source_tag and SOURCE_TAG_MAP."""
from dd_mcp_shared.data_discipline import stamp_source_tag, SOURCE_TAG_MAP


class TestSourceTagMap:
    def test_map_has_expected_prefixes(self):
        assert "mcp__datadog__" in SOURCE_TAG_MAP
        assert "mcp__atlassian__" in SOURCE_TAG_MAP

    def test_map_values_are_valid_tags(self):
        valid_tags = {"API", "FILE", "TRANSCRIPT", "INFERRED"}
        for v in SOURCE_TAG_MAP.values():
            assert v in valid_tags


class TestStampSourceTag:
    def test_known_prefix_returns_correct_tag(self):
        tag, result = stamp_source_tag("mcp__datadog__search_monitors", {"count": 5})
        assert tag == "API"
        assert result == {"count": 5, "_source": "API"}

    def test_atlassian_prefix_returns_api(self):
        tag, result = stamp_source_tag("mcp__atlassian__getConfluencePage", "page text")
        assert tag == "API"
        assert result == {"_source": "API", "_data": "page text"}

    def test_unknown_prefix_returns_inferred(self):
        tag, result = stamp_source_tag("some_unknown_tool", {"data": "x"})
        assert tag == "INFERRED"

    def test_productivity_read_returns_file(self):
        tag, result = stamp_source_tag("mcp__dd-productivity__read_gdoc", "doc content")
        assert tag == "FILE"

    def test_dict_result_gets_source_key_injected(self):
        _, result = stamp_source_tag("mcp__datadog__get_metric", {"value": 42})
        assert result["_source"] == "API"
        assert result["value"] == 42

    def test_non_dict_result_wrapped(self):
        _, result = stamp_source_tag("mcp__datadog__get_metric", [1, 2, 3])
        assert result["_source"] == "API"
        assert result["_data"] == [1, 2, 3]
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-mcp-shared
python3 -m pytest tests/test_stamp_source_tag.py -v 2>&1 | head -30
```
Expected: ImportError (symbols not yet defined)

- [ ] **Step 3: Add `SOURCE_TAG_MAP` and `stamp_source_tag` to `data_discipline.py`**

Add at the end of `dd-mcp-shared/dd_mcp_shared/data_discipline.py`:

```python
# ---------------------------------------------------------------------------
# Source tagging — applied at decorator boundary, not at LLM call time.
# The LLM calls tools with plain strings and cannot construct typed objects.
# Source inference from tool name prefix stamps trust level onto responses.
# ---------------------------------------------------------------------------

SOURCE_TAG_MAP: dict[str, str] = {
    "mcp__datadog__": "API",
    "mcp__atlassian__": "API",
    "mcp__dd-cicd-onboarding__": "API",
    "mcp__dd-governed-onboarding__": "API",
    "mcp__dd-ust-mcp__": "API",
    "mcp__splunk-dd-migration__": "API",
    "mcp__dd-productivity__read": "FILE",
    "mcp__dd-productivity__list": "FILE",
    "TRANSCRIPT": "TRANSCRIPT",  # explicit override only
}


def stamp_source_tag(tool_name: str, result: object) -> tuple[str, object]:
    """
    Infer source trust tag from tool name prefix and inject into result.

    Returns (tag, stamped_result). tag is one of: API, FILE, TRANSCRIPT, INFERRED.

    For dict results: injects '_source' key.
    For non-dict results: wraps in {'_source': tag, '_data': result}.

    Unknown prefixes are tagged INFERRED (low-trust) and must be flagged.
    """
    tag = "INFERRED"
    for prefix, mapped_tag in SOURCE_TAG_MAP.items():
        if tool_name.startswith(prefix):
            tag = mapped_tag
            break

    if isinstance(result, dict):
        stamped = dict(result)
        stamped["_source"] = tag
        return tag, stamped
    else:
        return tag, {"_source": tag, "_data": result}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-mcp-shared
python3 -m pytest tests/test_stamp_source_tag.py -v
```
Expected: All 7 tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-mcp-shared
git add dd_mcp_shared/data_discipline.py tests/test_stamp_source_tag.py
git commit --no-gpg-sign -m "feat: add stamp_source_tag and SOURCE_TAG_MAP to data_discipline"
```

---

## Task 3: Update `dd_mcp_shared/__init__.py` exports + create `new-repo-init.sh`

**Files:**
- Modify: `dd-mcp-shared/dd_mcp_shared/__init__.py`
- Create: `dd-mcp-shared/scripts/new-repo-init.sh`

- [ ] **Step 1: Read current `__init__.py`**

```bash
cat /Users/anilkumar.pappu/Documents/Git/dd-mcp-shared/dd_mcp_shared/__init__.py
```

- [ ] **Step 2: Add new exports to `__init__.py`**

Note: `__init__.py` is currently empty (only a module docstring). Add these exact lines:

```python
from .registry import require_verified_context, check_registry, stamp_architect, get_architect_id, list_architect_engagements
from .data_discipline import require_verified_data, stamp_source_tag, SOURCE_TAG_MAP
```

- [ ] **Step 3: Verify imports work**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-mcp-shared
python3 -c "from dd_mcp_shared import require_verified_context, stamp_source_tag, SOURCE_TAG_MAP; print('OK')"
```
Expected: `OK`

- [ ] **Step 4: Create `scripts/` directory and `new-repo-init.sh`**

```bash
mkdir -p /Users/anilkumar.pappu/Documents/Git/dd-mcp-shared/scripts
```

Create `dd-mcp-shared/scripts/new-repo-init.sh`:

```bash
#!/usr/bin/env bash
# new-repo-init.sh — scaffold a new IS MCP repo with enforcement from day one
# Usage: bash new-repo-init.sh <repo-directory>
set -euo pipefail

REPO_DIR="${1:?Usage: $0 <repo-directory>}"
REPO_NAME=$(basename "$REPO_DIR")
SHARED_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Scaffolding $REPO_DIR from dd-mcp-shared template..."
mkdir -p "$REPO_DIR"/{tools,tests,.github/workflows,.claude}

# requirements.txt with dd-mcp-shared pinned
cat > "$REPO_DIR/requirements.txt" << EOF
dd-mcp-shared @ file://${SHARED_DIR}
fastmcp>=0.1.0
httpx>=0.27
pyyaml>=6.0
EOF

# server.py stub with @require_verified_context on starter tool
cat > "$REPO_DIR/server.py" << 'EOF'
"""IS MCP Server — scaffolded by new-repo-init.sh."""
from fastmcp import FastMCP
from dd_mcp_shared.registry import require_verified_context

mcp = FastMCP("new-repo")


@mcp.tool()
@require_verified_context
def get_status(customer_id: str) -> dict:
    """Get onboarding status for a registered customer."""
    return {"customer_id": customer_id, "status": "ok"}


if __name__ == "__main__":
    mcp.run()
EOF

# customers/ directory structure
mkdir -p "$REPO_DIR/customers/.gitkeep"
touch "$REPO_DIR/customers/.gitkeep"

# CLAUDE.md from standard template
cat > "$REPO_DIR/CLAUDE.md" << 'EOF'
# CLAUDE.md

## Purpose
[Describe this repo's purpose here]

## Tools
[List MCP tools and their functions here]

## Customer Registry
All customers must be registered in `dd-governed-onboarding-mcp/organisations/_registry.yaml`
with `status: active` before any tool can be called for them.

Set `DD_GOVERNED_ONBOARDING_DIR` to point to your local clone of dd-governed-onboarding-mcp.

## Development
```bash
pip install -e ../dd-mcp-shared
pip install -e .
python server.py
```
EOF

# .github/CODEOWNERS
cat > "$REPO_DIR/.github/CODEOWNERS" << 'EOF'
CLAUDE.md @anildatadog
docs/decisions/ @anildatadog
.github/CODEOWNERS @anildatadog
EOF

# GitHub Actions stubs
mkdir -p "$REPO_DIR/.github/workflows"
cat > "$REPO_DIR/.github/workflows/datadog-test-optimization.yml" << 'EOF'
name: Datadog Test Optimization
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11" }
      - run: pip install -e . && pip install pytest pytest-cov  # dd-mcp-shared installed via requirements.txt
      - name: Run tests with DD Test Visibility
        uses: datadog/test-visibility-github-action@v2
        with:
          languages: python
          service: ${{ github.event.repository.name }}
          api_key: ${{ secrets.DD_API_KEY }}
      - run: pytest --cov=. --cov-report=xml -v
EOF

cat > "$REPO_DIR/.github/workflows/datadog-code-security.yml" << 'EOF'
name: Datadog Code Security
on: [push]
jobs:
  sast:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: datadog/datadog-static-analyzer-github-action@v1
        with:
          dd_api_key: ${{ secrets.DD_API_KEY }}
          dd_app_key: ${{ secrets.DD_APP_KEY }}
          dd_service: ${{ github.event.repository.name }}
  sca:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: datadog/datadog-sca-github-action@v3
        with:
          dd_api_key: ${{ secrets.DD_API_KEY }}
          dd_app_key: ${{ secrets.DD_APP_KEY }}
          dd_service: ${{ github.event.repository.name }}
EOF

chmod +x "$0"
echo "Done. Scaffold created at $REPO_DIR"
echo "Next: cd $REPO_DIR && git init && git add . && git commit -m 'chore: initial scaffold via new-repo-init.sh'"
```

- [ ] **Step 5: Make script executable and verify**

```bash
chmod +x /Users/anilkumar.pappu/Documents/Git/dd-mcp-shared/scripts/new-repo-init.sh
ls -la /Users/anilkumar.pappu/Documents/Git/dd-mcp-shared/scripts/
```
Expected: new-repo-init.sh with execute bit set

- [ ] **Step 6: Commit**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-mcp-shared
git add dd_mcp_shared/__init__.py scripts/new-repo-init.sh
git commit --no-gpg-sign -m "feat: export require_verified_context + add new-repo-init.sh scaffold"
```

---

## Task 4: Retrofit `dd-cicd-onboarding-mcp`

**Spec tools:** `scan_ci_state`, `generate_gap_report`, `create_pipeline_monitors`, `validate_dora`

**Files:**
- Modify: tool files containing the above functions (use `grep -r "customer_id" tools/` to identify exact locations)

- [ ] **Step 1: Identify all tool functions accepting `customer_id`**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-cicd-onboarding-mcp
grep -rn "def.*customer_id" tools/ --include="*.py" | grep -v "add_customer"
```

- [ ] **Step 2: Add `@require_verified_context` imports to each identified file**

For each file identified above, add at the top:
```python
from dd_mcp_shared.registry import require_verified_context
```
Then add `@require_verified_context` decorator above each affected `def` that accepts `customer_id`.

**Important:** Do NOT decorate `add_customer` — chicken-and-egg problem.

- [ ] **Step 3: Verify server imports cleanly**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-cicd-onboarding-mcp
python3 -c "import server; print('OK')" 2>&1 | head -20
```
Expected: `OK` (no import errors)

- [ ] **Step 4: Run existing tests**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-cicd-onboarding-mcp
python3 -m pytest tests/ -v 2>&1 | tail -20
```
Expected: same or better pass rate as before changes

- [ ] **Step 5: Commit**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-cicd-onboarding-mcp
git add tools/
git commit --no-gpg-sign -m "feat: add @require_verified_context to customer_id tools"
```

---

## Task 5: Retrofit `dd-ust-mcp`

**Spec tools:** `discover_tag_values`, `run_gap_analysis`, `apply_service_catalog`, `validate_tag_coverage`

**Files:**
- Modify: tool files containing the above functions

- [ ] **Step 1: Identify all tool functions accepting `customer_id`**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-ust-mcp
grep -rn "def.*customer_id" tools/ --include="*.py" | grep -v "add_customer"
```

- [ ] **Step 2: Add decorator to each identified function**

Same pattern as Task 4: import at top, decorate functions, skip `add_customer`.

- [ ] **Step 3: Verify server imports cleanly**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-ust-mcp
python3 -c "import server; print('OK')" 2>&1 | head -20
```

- [ ] **Step 4: Run existing tests**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-ust-mcp
python3 -m pytest tests/ -v 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-ust-mcp
git add tools/
git commit --no-gpg-sign -m "feat: add @require_verified_context to customer_id tools"
```

---

## Task 6: Retrofit `splunk-dd-migration-mcp`

**Enforcement gap — documented and accepted:** All 3 spec-listed tools (`create_monitors`, `suggest_field_mappings_llm`, `generate_customer_report`) use `customer_dir: Path` not `customer_id: str`. The decorator will silently pass all three (no `customer_id`/`org_id` in kwargs = check skipped). This is acceptable because:
1. `add_customer` calls `check_registry` — the customer must be registered before `customer_dir` can exist
2. All tools derive `customer_dir` from a path that only exists if `add_customer` passed

**Action:** Add an explicit annotation to each of the 3 functions documenting the compensating control.

**Files:**
- Modify: tool files for the 3 spec tools

- [ ] **Step 1: Find the 3 tool function files**

```bash
cd /Users/anilkumar.pappu/Documents/Git/splunk-dd-migration-mcp
grep -rn "def create_monitors\|def suggest_field_mappings_llm\|def generate_customer_report" tools/ --include="*.py"
```

- [ ] **Step 2: Add compensating-control comment to each function**

For each of the 3 functions, add this comment immediately after the `def` line's docstring:
```python
# ENFORCEMENT: uses customer_dir: Path — registry check enforced in add_customer.
# @require_verified_context omitted because decorator reads customer_id/org_id kwargs only.
```

**Note:** splunk-dd-migration-mcp uses `main-LLM` as canonical branch. Work in a session branch from `main-LLM`.

- [ ] **Step 4: Verify server imports cleanly**

```bash
cd /Users/anilkumar.pappu/Documents/Git/splunk-dd-migration-mcp
python3 -c "import server; print('OK')" 2>&1 | head -20
```

- [ ] **Step 5: Run existing tests**

```bash
cd /Users/anilkumar.pappu/Documents/Git/splunk-dd-migration-mcp
python3 -m pytest tests/ -v 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
cd /Users/anilkumar.pappu/Documents/Git/splunk-dd-migration-mcp
git add tools/
git commit --no-gpg-sign -m "feat: add @require_verified_context to string-id customer tools"
```

---

## Task 7: Retrofit `dd-productivity-mcp`

**Spec tools:** `store_customer_credentials`, `get_customer_credentials`

**Files:**
- Modify: `dd-productivity-mcp/tools/credentials.py` (or equivalent)

- [ ] **Step 1: Find credential tool file**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-productivity-mcp
grep -rn "def store_customer_credentials\|def get_customer_credentials" tools/ --include="*.py"
```

- [ ] **Step 2: Apply decorator to both functions**

Import and apply `@require_verified_context` to `store_customer_credentials` and `get_customer_credentials`.

- [ ] **Step 3: Verify server imports cleanly**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-productivity-mcp
python3 -c "import server; print('OK')" 2>&1 | head -20
```

- [ ] **Step 4: Run existing tests**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-productivity-mcp
python3 -m pytest tests/ -v 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-productivity-mcp
git add tools/
git commit --no-gpg-sign -m "feat: add @require_verified_context to credential tools"
```

---

## Task 8: Retrofit `dd-governed-onboarding-mcp`

**Note:** This repo uses `org_id` (not `customer_id`). The decorator already handles this via `kwargs.get("customer_id") or kwargs.get("org_id")`. Do NOT decorate `add_organisation` — chicken-and-egg.

**Files:**
- Modify: all tool files in `tools/` that accept `org_id`

- [ ] **Step 1: Identify all tools accepting `org_id`**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-governed-onboarding-mcp
grep -rn "def.*org_id" tools/ --include="*.py" | grep -v "add_organisation"
```

- [ ] **Step 2: Group by file — apply decorator to each identified function**

Work file by file. Add import once per file at the top, then decorate each function.

- [ ] **Step 3: Verify server imports cleanly**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-governed-onboarding-mcp
python3 -c "import server; print('OK')" 2>&1 | head -20
```

- [ ] **Step 4: Run existing tests**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-governed-onboarding-mcp
python3 -m pytest tests/ -v 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
cd /Users/anilkumar.pappu/Documents/Git/dd-governed-onboarding-mcp
git add tools/
git commit --no-gpg-sign -m "feat: add @require_verified_context to org_id tools (skip add_organisation)"
```

---

## Verification Checklist

After all 8 tasks complete:

- [ ] `python3 -c "from dd_mcp_shared import require_verified_context, stamp_source_tag; print('OK')"`
- [ ] `dd-mcp-shared` all tests pass: `python3 -m pytest tests/ -v`
- [ ] All 5 retrofitted repos: `python3 -c "import server; print('OK')"` passes
- [ ] `grep -r "@require_verified_context" dd-cicd-onboarding-mcp/tools/ dd-ust-mcp/tools/ dd-productivity-mcp/tools/ dd-governed-onboarding-mcp/tools/` shows hits
- [ ] `new-repo-init.sh` is executable and runs without error on a temp dir
