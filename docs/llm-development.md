# Building Alt-Tabby with Claude Code

Alt-Tabby is a 41,000-line AHK v2 codebase built primarily by [Claude Code](https://claude.ai/claude-code) as the hands-on-keyboard coder, with a human (me) directing architecture, recognizing failure patterns, and reviewing output. This page documents the specific systems we built to make that work.

For a generalized, project-agnostic version of the lessons learned, see [Making my unteachable AI build its own cage](making-my-unteachable-ai-build-its-own-cage.md).

## Contents

- [The Core Problem](#the-core-problem) — why session amnesia requires mechanical guardrails, not longer instructions
- [The Guardrail System](#the-guardrail-system) — 86-check static analysis pre-gate, ownership manifest, function visibility
- [Query Tools](#query-tools) — 17 semantic search tools that return answers in ~40 tokens instead of ~4,800
- [Skills System](#skills-system) — 58 reusable workflows with context-budget-aware auto-discovery
- [MCP Server Management](#mcp-server-management) — toggle-on-demand pattern for external tool integrations
- [The Feedback Loop](#the-feedback-loop) — bug → check → fix cycle that makes mistake classes mechanically impossible
- [What to Watch For](#what-to-watch-for) — the AI modifying its own guardrails
- [Repeated Invocation](#repeated-invocation) — why running the same review skill 10 times beats running it once
- [Project Structure](#project-structure) — file layout of checks, query tools, and manifest
- [By the Numbers](#by-the-numbers)

---

## The Core Problem

Every Claude Code session starts from zero. The AI doesn't remember the bug it introduced yesterday, the architectural decision from last week, or the scoping rule it violated in every session for a month. The natural response — writing longer instructions — doesn't scale. Instructions consume context tokens, and context is the binding constraint on session productivity.

Our response was to build systems that make mistakes mechanically impossible rather than trying to teach the AI not to make them.

---

## The Guardrail System

### Static Analysis Pre-Gate

Every test run begins with a pre-gate ([`static_analysis.ps1`](../tests/static_analysis.ps1)) that runs **86 static analysis checks** in parallel (~8 seconds). If any check fails, the entire test suite is blocked — unit, GUI, and live integration tests alike.

Checks are auto-discovered: drop a `tests/check_*.ps1` file into the test directory and it's enforced on the next run. No registration.

The checks catch classes of bugs that survive AHK's compiler, survive the test suite, and only manifest at runtime — often as silent misbehavior:

**What the checks catch:**

| Category | Examples |
|----------|---------|
| **Scoping** | Missing `global` declarations inside functions (AHK silently creates a local instead) |
| **Concurrency** | `Critical "Off"` leaking from callees into callers, destroying atomicity |
| **Visibility** | Cross-file calls to `_Private()` functions |
| **Ownership** | Unauthorized cross-file mutations of global variables |
| **Lifecycle** | Unmatched `SetTimer`/kill, unbalanced `Critical "On"`/`"Off"` |
| **Correctness** | Undefined function calls, wrong parameter counts, dead code |
| **Patterns** | AHK v1-isms, unsafe string comparisons, missing log guards |
| **Rendering** | COM calls inside Critical sections (STA pump reentrancy) |
| **Tests** | Test globals shadowing production, WMI usage (breaks CI) |

Related checks are bundled into 8 batch scripts that share PowerShell startup costs, plus 2 standalone scripts. Total check code: **12,700 lines**.

**Pre-gate output:**
```
--- Pre-Gate: Syntax Check + Static Analysis (Parallel) ---
  Syntax: 13/13 passed [PASS]
  Running 86 static analysis check(s) in parallel...
  Static analysis: all 86 checks passed (8.1s)
```

### Ownership Manifest

[`ownership.manifest`](../ownership.manifest) is a flat file listing every global variable that's mutated by more than one source file:

```
cfg: launcher_tray, config_loader, setup_utils
gGUI_DisplayItems: gui_data, gui_state
gGUI_LiveItems: gui_activation, gui_data
gGUI_Sel: gui_data, gui_input, gui_state
```

If a global isn't listed, only the declaring file may mutate it — enforced mechanically. If it is listed, all authorized writers are enumerated. The pre-gate validates the manifest against actual code and auto-removes stale entries.

This turns "did this refactoring accidentally introduce cross-module coupling?" from a code review question into a gate that passes or fails.

### Function Visibility

Functions prefixed with `_` are private to their declaring file. Any file may call unprefixed functions. This convention is enforced by static analysis — the AI can't call `_SomeInternalHelper()` from another file, even if it seems convenient.

---

## Query Tools

17 PowerShell scripts that return semantic answers to common questions, organized into three categories: data-flow analysis, code structure, and domain inventories. The key insight: when the AI reads a 1,000-line file to find a 5-line answer, it burns ~1,200 tokens. A query tool returns the same answer for ~40 tokens.

**Data flow & ownership:**

| Tool | What it answers |
|------|----------------|
| [`query_global_ownership.ps1`](../tools/query_global_ownership.ps1) | Who declares, writes, and reads a global variable |
| [`query_callchain.ps1`](../tools/query_callchain.ps1) | Call graph from a function (forward or reverse, to N depth) |
| [`query_impact.ps1`](../tools/query_impact.ps1) | Blast radius: callers + globals written + readers of those globals |
| [`query_mutations.ps1`](../tools/query_mutations.ps1) | Detailed global mutation analysis with guard conditions |
| [`query_state.ps1`](../tools/query_state.ps1) | State machine branches (state × event → behavior) |

**Code structure:**

| Tool | What it answers |
|------|----------------|
| [`query_function.ps1`](../tools/query_function.ps1) | Full function body without loading the file |
| [`query_function_visibility.ps1`](../tools/query_function_visibility.ps1) | Where a function is defined, public/private, all callers |
| [`query_interface.ps1`](../tools/query_interface.ps1) | File's public API: exported functions and globals |
| [`query_includes.ps1`](../tools/query_includes.ps1) | `#Include` dependency tree |
| [`query_visibility.ps1`](../tools/query_visibility.ps1) | Functions with 0–1 external callers (inlining candidates) |

**Domain inventories:**

| Tool | What it answers |
|------|----------------|
| [`query_config.ps1`](../tools/query_config.ps1) | Config registry search by keyword, section, consumer, type |
| [`query_ipc.ps1`](../tools/query_ipc.ps1) | IPC message constants: who sends and handles each |
| [`query_timers.ps1`](../tools/query_timers.ps1) | SetTimer inventory: callback, interval, file, line |
| [`query_messages.ps1`](../tools/query_messages.ps1) | Windows message handlers and senders |
| [`query_shader.ps1`](../tools/query_shader.ps1) | Shader metadata: category, compute pipeline, textures |
| [`query_events.ps1`](../tools/query_events.ps1) | Flight recorder event definitions + emitter locations |
| [`query_instrumentation.ps1`](../tools/query_instrumentation.ps1) | Profiler coverage map |

**Example output:**
```
> query_global_ownership.ps1 gGUI_LiveItems

gGUI_LiveItems
  declared: src/gui/gui_main.ahk:91
  writers:  gui_activation (1), gui_data (1), gui_state (2)
  readers:  gui_data, gui_paint, gui_state
  manifest: line 3
```

Same information the AI would get by reading 4 source files. 40 tokens instead of 4,800. Correct every time because it scans the entire codebase, not a guess about which files to check.

Total query tool code: **6,100 lines** plus a shared helper library.

---

## Skills System

Claude Code "skills" are markdown files that define reusable workflows. Each skill loads its full instructions only when invoked — the system prompt just sees the name and description. The project has [58 skills](../.claude/skills/) covering:

**Review skills** — domain-specific code review workflows that know what to look for:
- [`/review-ownership-manifest`](../.claude/skills/review-ownership-manifest) — audit cross-file coupling against the manifest
- [`/review-test-coverage`](../.claude/skills/review-test-coverage) — identify untested production code paths
- [`/review-reentrancy`](../.claude/skills/review-reentrancy) — find COM STA message pump reentrancy hazards
- [`/review-paint`](../.claude/skills/review-paint) — audit the rendering pipeline for resource leaks and race conditions
- [`/review-criticals`](../.claude/skills/review-criticals) — verify Critical "On"/"Off" pairing across all code paths
- [`/review-race-conditions`](../.claude/skills/review-race-conditions) — find check-then-act patterns missing atomicity
- Plus 32 more review skills for D3D, latency, dead code, resource leaks, shaders, professionalism, etc.

**Workflow skills** — multi-step processes with domain knowledge baked in:
- [`/shader-convert`](../.claude/skills/shader-convert) — convert Shadertoy shaders to Alt-Tabby's HLSL format (with optional Playwright scraping)
- [`/release`](../.claude/skills/release) — build, tag, and package a release
- [`/profile`](../.claude/skills/profile) — run the profiler, capture flamecharts, analyze bottlenecks

**By category:** 38 review, 12 workflow, 3 shader, 5 analysis/investigation.

### Context Budget Discovery

We discovered that skill descriptions loaded into every session were silently consuming context. Of 58 skills, only 2 benefit from auto-discovery. The other 56 use `disable-model-invocation: true` in their frontmatter — they only load when explicitly invoked with `/skillname`. A static analysis check ([`check_skill_frontmatter.ps1`](../tests/check_skill_frontmatter.ps1)) enforces that new skills declare their discovery preference and blocks unapproved auto-discovery additions.

---

## MCP Server Management

The same context budget problem applies to MCP (Model Context Protocol) servers. Each connected MCP server adds its tool definitions to every session's context — whether or not you use them.

Alt-Tabby uses [Playwright MCP](https://github.com/anthropics/mcp-playwright) for scraping Shadertoy shaders, but only during shader conversion work. Loading Playwright's tool definitions into every session wastes context in the 95% of sessions that don't touch shaders.

The solution: [`toggle-playwright-mcp.ps1`](../tools/toggle-playwright-mcp.ps1) — a script that adds or removes the Playwright MCP server entry from Claude Code's config file (`~/.claude.json`):

```powershell
# Check current state
powershell -File tools/toggle-playwright-mcp.ps1 status

# Enable before shader work
powershell -File tools/toggle-playwright-mcp.ps1 on
# (restart Claude Code)

# Disable after shader work
powershell -File tools/toggle-playwright-mcp.ps1 off
```

The skill that needs Playwright ([`/shader-convert`](../.claude/skills/shader-convert)) knows about this lifecycle. When invoked in Shadertoy scraping mode, it checks for the `mcp__playwright__browser_navigate` tool. If missing, it stops and tells the user to enable the MCP and restart. After conversion completes, it reminds the user to disable it.

This is the same pattern as skills: context is a budget, and anything that loads into every session must justify its presence. MCPs that serve specific workflows should be toggled on-demand, not left running.

---

## The Feedback Loop

The system that produces guardrails follows a consistent pattern:

1. Human and AI work together
2. A bug happens
3. The human recognizes the **class** of bug (not just the instance)
4. The human tells the AI: "write a check to catch this pattern FIRST, then fix the bug"
5. The AI writes both
6. That class of mistake is mechanically impossible, forever, across all future sessions

"Write a check first" is critical discipline. If the bug is fixed first, the check never gets written. By forcing check-before-fix, the bug serves as proof that the check works.

The new check usually catches additional instances already in the codebase. The check pays for itself before the session ends.

---

## What to Watch For

The AI is good at recognizing when a check needs updating. Usually it's right — conventions change, checks get stale. But occasionally, when a check catches a legitimate bug, the AI modifies the check to accommodate the error instead of fixing the code. A function missing `Critical "Off"` on a return path becomes a "baseline exemption" instead of a fix.

Modifications to the guardrail system itself are a primary review point. If the AI touches a static check or the ownership manifest without being asked, treat it like a developer modifying CI to make failing tests pass.

---

## Repeated Invocation

Review skills benefit from being run multiple times. A single clean pass doesn't mean clean — convergence after N passes does.

Two mechanisms explain why:

**Attention saturation.** When the AI finds issues early in a review pass, those findings consume context and attention. There's a pull toward synthesis and wrap-up rather than continued scrutiny. The found issues become attractors — the AI pattern-matches on what it's already found rather than staying open to structurally different problems. Radiologists call this "satisfaction of search": finding one tumor makes you statistically less likely to find the second one on the same scan.

**Path diversity.** LLM sampling means each run takes a different path through the search space. Which file gets read first, which function looks suspicious, which pattern gets grepped — these are soft decisions influenced by sampling, and they cascade. Reading file A first means file B is approached with A's patterns primed. Next run, starting with file C means seeing file B through completely different eyes. This isn't coin-flip randomness — it's exploring different branches of a search tree.

The two effects compound. Each run has decent but incomplete coverage, and the coverage gaps are partially independent across runs. Run 1 finds issues A, B, C. Run 2 finds B, D, E. Run 3 finds A, E, F. You converge on full coverage through repetition in a way that a single "try harder" prompt can't replicate — because the bottleneck isn't effort, it's the path through the search space.

**In practice:** `/review-race-conditions` took ~10 runs before consistently returning "none found" — each early run surfaced patterns the previous ones missed. `/review-shaders-open` has been run 20+ times and still finds new items, because it's generative rather than convergent. The convergent reviews (finite bug space, clear right/wrong) are where repeated invocation matters most: any single "none found" carries far less confidence than 10 runs agreeing.

---

## Project Structure

```
tests/
  static_analysis.ps1          # Pre-gate orchestrator (parallel execution)
  check_batch_directives.ps1   # 12 sub-checks: compiler directives, reachability, include chains
  check_batch_functions.ps1    #  5 sub-checks: arity, dead code, undefined calls, globals
  check_batch_guards.ps1       # 10 sub-checks: Critical sections, callbacks, rendering
  check_batch_guards_b.ps1     #  9 sub-checks: theme, logging, events, mutations
  check_batch_patterns.ps1     # 17 sub-checks: code patterns, logging, mutations
  check_batch_simple.ps1       #  6 sub-checks: dead globals, timer lifecycle, dead locals
  check_batch_simple_b.ps1     # 15 sub-checks: config registry, IPC, encoding, coverage
  check_batch_tests.ps1        #  8 sub-checks: test validation, config coverage
  check_warn.ps1               # AHK VarUnset warning detection
  check_skill_frontmatter.ps1  # Skill auto-discovery whitelist enforcement

tools/
  query_global_ownership.ps1   # Global variable ownership (also enforces manifest)
  query_function_visibility.ps1 # Function visibility (also enforces _ prefix)
  query_callchain.ps1          # Forward/reverse call graphs
  query_function.ps1           # Extract function bodies
  query_impact.ps1             # Blast radius analysis
  query_config.ps1             # Config registry search
  ... (17 query tools total)
  _query_helpers.ps1           # Shared parsing infrastructure

ownership.manifest             # Cross-file mutation contracts
```

---

## By the Numbers

| Metric | Value |
|--------|-------|
| AHK source code | ~41,000 lines |
| Static analysis checks | 86 (in 12 bundles: 8 batch + 2 standalone + 2 dual-duty query tools) |
| Query tools | 17 |
| Tooling code | ~42,000 lines |
| Pre-gate execution time | ~8 seconds |
| Check code | 12,900 lines |
| Query tool code | 6,300 lines |
| Test code (AHK) | 12,700 lines across 25 files |
| Skills | 58 (2 auto-discoverable, 56 manual-invoke) |
| Ownership manifest entries | 12 cross-file globals |

---

## Further Reading

- [Making my unteachable AI build its own cage](making-my-unteachable-ai-build-its-own-cage.md) — the generalized article on AI-assisted development lessons, not specific to Alt-Tabby or Claude Code
- [What AutoHotkey Can Do](what-autohotkey-can-do.md) — the technical showcase of what we built with the language
