# Static Analysis Gap Analysis — Plan

## Executive Summary

After deep review of all 27 existing sub-checks (7 standalone + 6 batches of 2-6 sub-checks) and ~30 production files, I found **3 high-value gaps** that would prevent whole classes of bugs, plus **1 medium-value** addition. Each is justified with real production examples and calibrated against what already exists.

---

## Proposed New Checks

### 1. `check_test_assertions` — Test Quality Verification (New sub-check in `check_batch_tests.ps1`)

**What it catches:** Three classes of test quality issues that have already caused real problems (commit 1372e72 fixed 5 of these):

**1a. Assertion-free test functions:** Test functions that execute production code but never assert anything. These pass unconditionally and provide zero regression protection. Detected by finding functions matching `Test*()` or `RunTests_*()` that contain no `Assert*`, `Log("FAIL`, or pass/fail tracking calls.

**1b. Always-pass branches:** The exact pattern from commit 1372e72 — conditional branches where both if/else paths produce PASS. Detected by finding `if/else` blocks where both branches contain `Log("PASS` or increment a pass counter without any `Log("FAIL` or `Assert*` on either path.

**1c. Constants in assertions:** `AssertEq(true, true)`, `AssertEq(1, 1)`, etc. — assertions where both operands are literals. These compile-time truths test nothing.

**Why existing checks don't cover this:**
- `check_batch_tests.ps1` currently has `test_globals` (naming conventions) and `test_functions` (organization) — neither examines assertion quality
- The pre-gate blocks on static analysis failures but can't detect tests that pass vacuously

**Algorithm:**
1. Parse test files to extract test function bodies (reuse `BT_CountBraces` depth tracking already in `check_batch_tests.ps1`)
2. For each test function body:
   - Count assertion calls (`AssertEq`, `AssertTrue`, `AssertFalse`, `AssertNeq`, `Log("FAIL`, `Log("PASS`)
   - Flag functions with 0 assertions (after excluding setup/helper functions by naming convention — functions named `*Setup*`, `*Helper*`, `*Mock*`, `*Reset*`, `*Init*`, `*Cleanup*`)
   - Flag constant-vs-constant assertions via regex: `Assert\w+\(\s*(true|false|0|1|"[^"]*")\s*,\s*(true|false|0|1|"[^"]*")\s*\)`
3. For always-pass detection: find `if/else` blocks within test functions where both branches contain only pass indicators and no fail indicators

**Suppression:** `; lint-ignore: test-assertions`

**Placement:** **Add as sub-check 3 in `check_batch_tests.ps1`**. Already has the test file cache, brace counting, and function parsing infrastructure. Adds ~80-100ms to batch (~170→270ms, still well under the check_warn.ps1 bottleneck).

**Justification:** Highest ROI. Already had 5 real bugs caught manually in the most recent test quality commit. Automates what was a manual audit. Prevents the entire class of "test that can never fail."

---

### 2. `check_dead_functions` — Dead Code Detection (Standalone)

**What it catches:** Functions defined in `src/` (not `lib/`) that are never called or referenced anywhere in the codebase (src/ or tests/). In AHK v2 with `#Include`, dead functions compile silently, bloat the binary, and accumulate maintenance debt. More importantly, dead code often indicates an incomplete refactor — where a function was replaced but the old version was never removed.

**Why existing checks don't cover this:**
- `check_function_visibility.ps1` only checks that `_`-prefixed functions aren't called cross-file — it doesn't detect functions called by *nobody*
- `check_globals.ps1` checks variable *references*, not function *references*
- `check_batch_simple.ps1 → duplicate_functions` catches dups but not orphans

**Algorithm:**
1. Pass 1: Collect all function definitions in src/ (name, file, line) — same regex pattern as `check_function_visibility.ps1`: `^\s*(?:static\s+)?(\w+)\s*\(`
2. Pass 2: For each function name, search all .ahk files (src/ + tests/) for references:
   - Direct calls: `FuncName(`
   - Indirect refs: function name as bare word argument (SetTimer, OnEvent, OnMessage, Sort callbacks, `.Bind(`)
   - String refs: `"FuncName"` (rare but possible with `HasMethod()`)
3. Exclude self-references (definition line itself)
4. Exclude known entry-point patterns: `*_OnExit*`, `*_OnError*`, main process entry functions, functions registered in code_patterns check table
5. Report functions with 0 external references

**Suppression:** `; lint-ignore: dead-function`

**Placement:** **Standalone**. Needs to scan all src/ + tests/ files (different scope from any existing batch — no current batch reads both src/ and tests/). ~200-300ms estimated. Not worth batching since it has a unique file scope.

**Justification:** Medium-high ROI. Catches incomplete refactors automatically. As the codebase grows, dead code accumulates silently. This check keeps the surface area honest.

---

### 3. `check_settimer_signatures` — Timer/Event Callback Parameter Validation (New sub-check in `check_batch_guards.ps1`)

**What it catches:** `SetTimer` callbacks with wrong parameter counts, and `OnMessage` callbacks with wrong signatures. In AHK v2:
- `SetTimer` callbacks must accept 0 parameters (or use variadic `*`)
- `OnMessage` callbacks must accept 4 parameters (wParam, lParam, msg, hwnd) or use variadic

A callback defined as `MyFunc(param)` will throw at runtime when called by the timer. This is particularly dangerous because:
- The error only manifests when the timer fires (not at registration time)
- In production, timers often fire during async operations where errors are hard to trace
- Refactoring a function to add a required parameter silently breaks any SetTimer using it

**Algorithm:**
1. Find all `SetTimer(callbackRef` calls in src/ files — extract the callback function name
2. Skip anonymous callbacks (`(*) =>`, closures), `.Bind()` references (binding handles param translation), and deregistrations (`SetTimer(ref, 0)`)
3. For each named callback, find its function definition in the file cache
4. Parse the parameter list from the definition
5. Flag if: has required parameters (no default value) AND count > 0 AND no variadic `*`
6. Similarly for `OnMessage(msgNum, callbackRef)`: flag if callback has < 1 or > 4 required params without variadic

**Suppression:** `; lint-ignore: callback-signature`

**Placement:** **Add as sub-check 6 in `check_batch_guards.ps1`**. The guards batch already checks callback-related patterns (`callback_critical` validates `Critical "On"` in callbacks). Same file cache, complementary concern. Adds ~70-90ms to batch (~320→410ms, still under bottleneck).

**Justification:** Prevents a runtime crash class that is invisible at compile time and registration time — only manifests when the timer fires. Low false-positive rate since the parameter count rules are well-defined by AHK v2.

---

### 4. `check_map_dot_access` — Map Property Access Safety (New sub-check in `check_batch_patterns.ps1`)

**What it catches:** `.property` access on variables known to be Maps (store records, IPC payloads). In AHK v2, `map.key` on a Map object throws a `MethodError` because Maps use `["key"]` indexing. Plain Objects use `.key`. The CLAUDE.md explicitly states: *"Store expects Map records from producers: use rec["key"] not rec.key"*.

This rule is enforced by documentation but not by static analysis. A single `.property` access on a Map either throws at runtime or, if the Map has a `Default` property set, silently returns the default instead of the actual value.

**Algorithm:**
1. Build a set of "known Map variable names" from context:
   - Loop variables iterating over known Map-containing arrays: `for _, item in gGUI_LiveItems`, `for _, rec in items` (inside store functions)
   - Variables assigned from `cJSON.Parse()`, `JSON.Parse()` results
   - Function parameters in store files named `rec`, `record`, `msg`, `payload`
   - The `PROJECTION_FIELDS` members accessed on item variables
2. For identified Map variables, flag `.property` access that isn't a known method:
   - Allowed: `.Has(`, `.Get(`, `.Delete(`, `.Set(`, `.Count`, `.Default`, `.__Class`, `.Capacity`, `.Clone(`
   - Flagged: `.title`, `.class`, `.hwnd`, `.processName`, etc. (known store field names accessed with dot)
3. Use PROJECTION_FIELDS from `check_projection_fields.ps1` as the known field name set
4. Skip `lib/` files

**Suppression:** `; lint-ignore: map-dot-access`

**Placement:** **Add as sub-check 5 in `check_batch_patterns.ps1`**. Shares the same file cache and clean-line helpers. Pattern-matching nature fits this batch. Adds ~60-80ms to batch (~315→395ms, still under bottleneck).

**Justification:** Enforces an existing documented rule that would otherwise rely on developer memory. Lower priority because the current codebase appears to follow this convention already (the rule was established early), but the check prevents regression — especially from new contributors or AI agents that might not internalize the Map vs Object distinction.

---

## What I Investigated But Rejected

| Candidate | Why Rejected |
|-----------|-------------|
| **DllCall error checking** | Too many false positives. Many DllCalls intentionally ignore errors (`IsWindow`, `GetWindowText`, `ShowWindow`). Would need a per-API allowlist that's fragile to maintain. The codebase already checks HRESULTs where they matter (DWM calls). |
| **IPC schema validation** | Would require understanding JSON structure from string-building code — essentially a partial interpreter. The `code_patterns` table already verifies key structural invariants. Cost/benefit unfavorable. |
| **Unused globals** | `check_globals.ps1` already catches undeclared usage. Unused *declarations* are low-harm (no runtime effect) and would generate noise for forward-declared globals that are assigned later in init sequences. |
| **Include order deps** | Analysis shows the codebase uses a clean DAG pattern (shared → globals → modules). No circular risks detected. A checker would be complex with near-zero yield. |
| **Silent catch blocks** | Many catch blocks intentionally log only when diagnostic flags are enabled — this is by design (see `keyboard-hooks.md` rule on keeping Critical during render). A checker would need a whitelist of "intentionally silent" patterns that's larger than the actual check. |
| **Function parameter count at call sites** | AHK v2's variadic and optional parameter handling makes general call-site validation extremely complex. The narrow case (SetTimer/OnMessage callbacks with known signatures) is covered by check #3 above. |
| **String vs Number comparisons** | AHK v2 handles coercion well in practice. The codebase uses `StrCompare()` where lexicographic order matters. A checker would generate mostly false positives on legitimate numeric comparisons. |

---

## Implementation Order

1. **check_test_assertions** (sub-check in `check_batch_tests.ps1`) — Highest ROI. Already had 5 real bugs in most recent commit. Prevents the class of "test that can never fail."
2. **check_dead_functions** (standalone `check_dead_functions.ps1`) — Medium-high ROI. Catches incomplete refactors. Keeps codebase surface area honest.
3. **check_settimer_signatures** (sub-check in `check_batch_guards.ps1`) — Prevents a runtime crash class invisible until the timer fires.
4. **check_map_dot_access** (sub-check in `check_batch_patterns.ps1`) — Enforces existing CLAUDE.md rule. Lowest priority because convention is already followed, but prevents regression.

## Estimated Impact on Pre-Gate Time

Current pre-gate: ~3-3.5s wall-clock (bottleneck: `check_warn.ps1` at ~600-1000ms)

| Addition | Location | Added Time | New Batch Total |
|----------|----------|-----------|-----------------|
| check_test_assertions | batch_tests | +80ms | ~250ms |
| check_dead_functions | standalone (parallel) | +250ms | 250ms |
| check_settimer_signatures | batch_guards | +70ms | ~390ms |
| check_map_dot_access | batch_patterns | +60ms | ~375ms |

**Net wall-clock impact: +0ms** — all additions run in parallel, none exceed the existing `check_warn.ps1` bottleneck (~600-1000ms). The pre-gate remains bottlenecked on the same check as before.
