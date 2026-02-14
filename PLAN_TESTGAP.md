# Test Coverage Gap Analysis & Plan

## Methodology

Deep analysis of all production code in `src/` (~36 files) against all test suites (~14 files, 800+ test cases). Each gap verified by:
1. Reading the production function body (citing specific lines)
2. Grepping test files for direct calls AND indirect coverage through callers
3. Assessing whether the function has testable logic vs being pure I/O
4. Checking if a "gap" is actually handled elsewhere (static analysis, live tests)
5. Verifying explore-agent claims against actual code (3/3 "critical bugs" were false positives due to agents not reading surrounding context)

## Verdict: The Suite is Impressively Comprehensive

After exhaustive analysis, the test suite covers ~90% of meaningful code paths. The areas below are the genuine remaining gaps where new tests would provide real value. Every other area I investigated was either already covered or untestable without real windows/UI.

---

## Tests to Add

### Test 1: Delta Upsert Field Mapping Completeness (GUI Unit)

**File**: `tests/gui_tests_data.ahk` — append to existing "DELTA PROCESSING TESTS" section

**The gap**: `_GUI_ApplyDelta` (gui_store.ahk:418-453) maps 9 JSON keys to GUI object properties. The existing tests verify 5 of 9 fields:

| Field | JSON key | Property | Tested? | Special behavior |
|-------|----------|----------|---------|------------------|
| title | `"title"` | `.Title` | YES (line 74) | |
| processName | `"processName"` | `.processName` | YES (line 74) | |
| lastActivatedTick | `"lastActivatedTick"` | `.lastActivatedTick` | YES (line 90) | Sets `mruChanged` flag |
| iconHicon | `"iconHicon"` | `.iconHicon` | YES (line 831) | Defers GDI+ pre-cache |
| isFocused | `"isFocused"` | (no property) | YES (line 673) | Sets `focusChangedToHwnd` |
| **class** | `"class"` | `.Class` | **NO** | Capitalization matters |
| **pid** | `"pid"` | `.PID` | **NO** | String coercion: `"" val` |
| **workspaceName** | `"workspaceName"` | `.WS` | **NO** | Abbreviated property name |
| **isOnCurrentWorkspace** | `"isOnCurrentWorkspace"` | `.isOnCurrentWorkspace` | **NO** | Sets `membershipChanged` flag |

**Verified by reading**:
- gui_store.ahk lines 421-432: `class`->`.Class`, `pid`->`"" val`, `workspaceName`->`.WS`, `isOnCurrentWorkspace` with `membershipChanged` flag
- gui_tests_data.ahk: grepped for each field in delta context, only title/processName/lastActivatedTick/iconHicon/isFocused have assertions

**Why these matter**:
- `pid` has **string coercion** (`"" val`) - if someone "fixes" this to just `val`, integer PIDs would break downstream code expecting strings
- `isOnCurrentWorkspace` is the **only field that sets `membershipChanged`**, which drives workspace re-filtering of the display list
- `class` and `workspaceName` have **non-obvious property name mappings** (Class vs class, WS vs workspaceName)

**What to test**: One combined test that sends a delta upsert with all 4 untested fields, then asserts:
1. `item.Class = "UpdatedClass"` (capitalization preserved)
2. `item.PID = "999"` (string, not integer)
3. `item.WS = "Desktop 2"` (abbreviated property)
4. `item.isOnCurrentWorkspace = false` (boolean flip)

**Pattern**: Same as existing delta cosmetic test at gui_tests_data.ahk line 66-80.

---

### Test 2: Projection `hwndsOnly` Through Cached Paths (Unit)

**File**: `tests/test_unit_core_store.ahk` — append to existing GetProjection section

**The gap**: `WindowStore_GetProjection({columns: "hwndsOnly"})` has separate return branches in 4 code paths. Each constructs the return value differently:

| Path | Condition | Lines | hwndsOnly branch | Tested? |
|------|-----------|-------|-------------------|---------|
| Path 1 | Cache hit (both clean) | 713-718 | Loops `gWS_ProjectionCache_Items` | **NO** |
| Path 1.5 | MRU bump only | 795-800 | Loops local `rows` | **NO** |
| Path 2 | Content dirty, sort clean | 839-844 | Loops local `rows` | **NO** |
| Path 3 | Full rebuild | 907-911 | Loops local `rows` | YES (test_unit_storage.ahk:1211) |

**Verified by reading**:
- windowstore.ahk lines 713-718, 795-800, 839-844, 907-911: four separate `if (columns = "hwndsOnly")` branches
- test_unit_storage.ahk line 1211: only cold-cache (Path 3) call with hwndsOnly

**Why it matters**: Each path constructs the return differently. Path 1 loops `gWS_ProjectionCache_Items` while the others loop a local `rows` variable. If Path 1 accidentally returns `items` instead of `hwnds` (e.g., due to a copy-paste error in the cache-hit path), the bug would only appear on the second call with unchanged data - a scenario never tested.

**What to test**:
1. Cold call with `hwndsOnly` → Path 3 (baseline, already tested elsewhere)
2. Immediate second call, no changes → Path 1 (cache hit) → verify returns `hwnds` array, not `items`
3. Change a non-sort field (processName) → Path 2 (content refresh) → verify `hwndsOnly` works
4. Bump `lastActivatedTick` on one item → Path 1.5 (MRU bump) → verify `hwndsOnly` works

Each step: `AssertEq(proj.HasOwnProp("hwnds"), true)`, `AssertEq(proj.HasOwnProp("items"), false)`, `AssertEq(proj.hwnds.Length, expectedCount)`.

**Pattern**: Same as existing Path 1.5 test at test_unit_core_store.ahk line 858.

---

### Test 3: Projection Path 1.5 Multi-MRU-Bump Fallback (Unit)

**File**: `tests/test_unit_core_store.ahk` — append to existing Path 1.5 section

**The gap**: Path 1.5 (windowstore.ahk:735-806) optimizes single MRU changes via move-to-front instead of full sort. It has a safety check (lines 763-769) that verifies the first few items are still in descending tick order. If the invariant breaks, it falls through to Path 3.

**Verified by reading**:
- windowstore.ahk lines 763-769: `if (sortedRecs[A_Index].lastActivatedTick < sortedRecs[A_Index + 1].lastActivatedTick) { valid := false; break }`
- test_unit_core_store.ahk line 878: tests "Mixed change: MRU tick + non-MRU sort field" which triggers `gWS_MRUBumpOnly = false` fallback — a DIFFERENT trigger. The sort invariant check itself is never exercised.

**What to test**:
1. Build 4-item store with distinct ticks: A(400), B(300), C(200), D(100)
2. Call `GetProjection({sort: "MRU"})` → cache built, items sorted [A, B, C, D]
3. Bump BOTH C and D to ticks higher than A (e.g., C=500, D=600) without calling GetProjection between
4. Call `GetProjection({sort: "MRU"})` → Path 1.5 tries move-to-front for highest-tick item (D)
5. After moving D to front: [D(600), A(400), B(300), C(500)] — invariant check sees A(400) > B(300) OK, but B(300) < C(500) **FAILS**
6. Falls through to Path 3 → verify result is correctly sorted: [D(600), C(500), A(400), B(300)]

**Counter-argument**: Even if Path 1.5 doesn't detect the invariant violation, Path 3 always produces correct results. The risk is performance (unnecessary full rebuilds), not correctness. But this test validates the optimization works as designed.

**Pattern**: Same as existing Path 1.5 test at test_unit_core_store.ahk line 858.

---

## Tests Explicitly NOT Adding (and why)

| Candidate | Why Skip |
|-----------|----------|
| Blacklist malformed regex | try/catch in IsMatch handles per-call; BL_CompileWildcard only produces valid regex |
| Duplicate HWNDs in snapshot | Store deduplicates at upsert time; can't happen in practice |
| _GUI_ConvertStoreItemsWithMap | Indirectly tested through snapshot processing; pure mapping function |
| GUI_HandleWorkspaceSwitch | 13-line function; behavior tested through WS change tests in gui_tests_data.ahk |
| WindowStore_TrimDiagMaps | Trivial Map.Delete loop, no logic branching |
| _GUI_SortItemsByMRU stability | Store-side stability tested via _WS_InsertionSort; GUI sort is a simple wrapper |
| Blacklist file write round-trip | Covered by live tests in test_live_features.ahk lines 816/913/938 |
| Blacklist_IsWindowEligibleEx | Requires real DWM state; can't test synthetically without real windows |
| Store_PushIfRevChanged | Integration function with re-entrancy guard; covered by live IPC tests |
| Stats corruption recovery | Tested in test_unit_stats.ahk with sentinel pattern |
| Process lifecycle edge cases | Covered by test_live_lifecycle.ahk |
| _GUI_CreateItemFromRecord | Pure struct constructor; implicitly tested via delta new-item test (line 111 checks .Title) |
| SetCurrentWorkspace iteration safety | Already protected by Critical "On" (line 657) — explore agent missed this |
| pushCount race in Store_PushToClients | Re-entrancy guard (gStore_PushInProgress) prevents concurrent calls — explore agent missed this |
| Store_BumpLifetimeStat safety | Already has `IsObject(gStats_Lifetime)` guard (line 477) — explore agent missed this |

## Implementation Summary

| # | Test | File | LOC | Location |
|---|------|------|-----|----------|
| 1 | Delta field mapping (class, pid, WS, isOnCurrentWorkspace) | gui_tests_data.ahk | ~25 | After existing "Delta upsert adds new item" test |
| 2 | Projection hwndsOnly through cached paths (Path 1, 1.5, 2) | test_unit_core_store.ahk | ~35 | After existing hwndsOnly test in GetProjection section |
| 3 | Path 1.5 multi-MRU-bump sort invariant fallback | test_unit_core_store.ahk | ~25 | After existing Path 1.5 tests |

**Total**: ~85 lines across 2 files. All follow existing patterns. No new test infrastructure, mocks, or includes needed.
