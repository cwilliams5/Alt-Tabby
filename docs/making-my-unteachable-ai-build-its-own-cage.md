# Making my unteachable AI build its own cage

### Engineering lessons from building a 50,000-line codebase with an AI that forgets everything, every session

---

## The Problem Nobody Talks About

After about a week, I stopped being impressed by what the AI could write and started being frustrated by what it couldn't remember. Every session is day one. It doesn't remember the bug it introduced yesterday. It doesn't remember the architectural decision you spent an hour discussing. It doesn't remember that `global` declarations inside functions are mandatory in AHK v2, despite causing that exact error in every single session for weeks.

**Your AI collaborator is stateless.** Most of the discourse around AI coding assistants (prompting techniques, model selection, benchmark scores) doesn't touch this. It's the fundamental problem, and everything else in this article is a response to it.

The natural response is to write more instructions. Longer system prompts. More detailed project documentation. "Please remember to always declare globals inside functions." You're essentially writing documentation for a reader with amnesia, and you're doing it every morning.

This doesn't work. Not because the AI can't follow instructions, it can, most of the time. It fails because "most of the time" isn't good enough when you're building production software, and because every instruction you write consumes the AI's most precious resource in a way that compounds over the course of a session.

After one month of evaluating Claude Code in my off hours by building a real application with it as the primary coder (an Alt-Tab replacement for Windows with keyboard hooks, IPC, GDI+ rendering, and a tiling window manager integration), I stopped trying to teach it. I started building systems that make its mistakes mechanically impossible.

This is what I learned.

---

## I. The Verification Cost Framework

A friend recently proposed their local fire department could use AI to choose where to build its next station, analyzing historical call data, demographics, and traffic patterns. It sounded reasonable. I pushed back hard.

Not because AI can't analyze data, it can. The problem is what happens when it's wrong. There's no compiler for "this neighborhood's risk profile was subtly misweighted." The output looks equally plausible either way. The feedback loop is measured in years, and the blast radius is measured in millions of dollars and human lives.

Compare that to using AI to write a utility function. Static analysis catches type errors. Tests catch behavioral errors. The compiler catches syntax. Three layers of mechanical verification, feedback in seconds. If the AI is wrong, you know immediately and it costs nothing.

The standard automation calculus (time to automate versus time saved) needs a third axis when AI is involved: **the cost of being wrong.**

The framework:

| Factor | Good for AI | Dangerous for AI |
|--------|------------|-----------------|
| **Verification cost** | Low (automated, mechanical) | High (requires domain expertise) |
| **Feedback loop** | Seconds to minutes | Weeks to years |
| **Cost of being wrong** | A failed test run | Acted on with confidence |
| **Human role** | Decision-maker with better info | Rubber-stamping AI conclusions |

The sweet spot is using AI where verification is cheap, feedback is fast, and the human remains the decision-maker. The moment the AI is generating the conclusion instead of supporting yours, you've crossed a line that no amount of "but it's 95% accurate" justifies. You don't know which 5% you're in.

Code lives in the sweet spot. So the question isn't whether AI can write code. It's what limits it once verification is cheap. The answer surprised me.

---

## II. Protect the Context Window

Most people think the constraint on AI coding assistants is capability ("can the model do this?") The real constraint, the one that governs everything else in your workflow design, is **context window lifespan.**

Every token of context the AI consumes brings it closer to compaction, the point where the system compresses earlier parts of the conversation to make room for new content. Compaction is where the AI loses the thread. You can watch it happen in real-time: the model that was confidently navigating your architecture ten minutes ago starts asking questions it already answered, re-reading files it already analyzed, and making mistakes it was explicitly warned about at the start of the session.

I watched this happen repeatedly before I fully understood what was actually going on. The AI wasn't getting dumber. It was losing context. And I was accelerating that loss by giving it work that required it to read entire files to understand a single function, by writing long rules it had to re-read every session, and by letting it grep through directories when I could have given it a targeted answer.

The design principle that fell out of this observation:

**Never put recurring knowledge in the context window. Put it anywhere else.**

This sounds simple. Its implications restructured my entire workflow:

| Knowledge type | Bad (eats context every session) | Good (preserves context) |
|---|---|---|
| Coding rules | Paragraphs in the system prompt | Static analysis checks that block bad code |
| Codebase understanding | Reading entire source files | Query tools that return targeted answers |
| Architectural decisions | Long explanatory comments | Ownership manifests enforced mechanically |
| Past mistakes | Rules explaining what not to do | Pre-gate checks that make it impossible |

The query tools are the purest expression of this principle. When the AI needs to understand who reads and writes a global variable, it can either read multiple source files (often dumping thousands of lines into context) or call a query tool that returns 5 lines of semantic information:

```
gGUI_ToggleBase
  declared: src/gui/gui_main.ahk:84
  writers:  gui_state (2 fn writes)
  readers:  gui_data, gui_state, gui_workspace
  manifest: line 51
```

Same answer. One costs 1,200 tokens. The other costs 40. Multiply that across dozens of lookups in a session (because the AI is looking things up constantly) and you've bought yourself hours of effective working time before degradation hits.

Once I started treating context as the scarce resource rather than capability, every other design decision followed naturally.

### The Leak in Your Own Tooling

The context conservation principle applies to the AI's own instruction loading, not just your source code.

Claude Code has "skills" - markdown files that define reusable workflows. A skill for releasing a build. A skill for reviewing race conditions. A skill for explaining architecture. Each skill moves domain-specific knowledge out of the always-loaded system prompt and into an on-demand file. The skill body only loads when you invoke it. In theory.

I didn't write the skills. I told the AI to write them, and I lightly edited. I had paragraphs of release packaging instructions in the project prompt — loaded every session, costing tokens whether I was shipping a build or debugging a keyboard hook. "Move this to a skill," I said. "It should only load when I type `/release`." The AI wrote the skill, I deleted the section from the prompt, and the context savings were... nothing.

By default, every skill's name and description are loaded into context every session so the AI can decide when to auto-invoke them. Anthropic's documentation buries this in a passing note: *"In a regular session, skill descriptions are loaded into context so Claude knows what's available."* Mountains of articles online explain how to write great skills. None of them mention that every skill you create silently adds to your context budget, every session, whether you use it or not.

I had 44 skills. That's 44 descriptions loaded into every session. The release workflow I'd carefully extracted from the system prompt was right back in context — not the full instructions, but the description, alongside 43 others. I'd added a layer of indirection and still bloated context.

I didn't find the fix. I told the AI to research its own documentation for a solution. It found a frontmatter flag (`disable-model-invocation: true`) that removes a skill from the AI's awareness entirely. The AI can't auto-invoke it, but you can still trigger it manually with `/release`. In my case, of 44 skills, only 2 genuinely benefit from auto-discovery — the rest are workflows I invoke deliberately. The other 42 were polluting context for no reason.

The session where this happened is the article's thesis in miniature. I told the AI to build skills to save context. The skills leaked context. I told the AI to research its own documentation and find the fix. It did. The AI built a cage, the cage had a hole, and I told the AI to patch its own hole. (And then I told it to write a static check to make sure the hole stays patched - but we haven't gotten to checks yet.)

---

## III. Don't Write Rules, Write Checks

This is a direct consequence of protecting the context window, and it's the core design philosophy of the entire system.

A rule lives in the system prompt. It costs context every session, regardless of its applicability to that session's work. It's read by the AI, interpreted probabilistically, and followed... most of the time. Compliance degrades further as the session gets longer and compaction discards earlier context.

A check lives on disk. It costs zero context until it fires. It runs mechanically. It either passes or fails. There is no "most of the time."

Here's a concrete example. AHK v2 has a scoping rule: global variables declared at file scope are not automatically accessible inside functions. You must explicitly declare them with `global VariableName` inside each function that uses them. Miss this, and the function silently creates a local variable instead, leading to bugs that can be difficult to diagnose.

I wrote this rule in the project instructions. Clearly, with examples. The AI ignored it about half the time. Not out of malice; it would read the rule, understand it, and then forget it was relevant when deep in a complex refactoring session. The rule was correct but unenforceable.

So I had the AI build a static analysis check: `check_globals.ps1`. It scans every function in the codebase, identifies which file-scope globals are referenced, and verifies that a `global` declaration exists. It runs in the pre-gate before any tests execute. If it fails, the entire test suite is blocked.

The rule was ignored about half the time. The check has a 100% catch rate. It has never missed. It cannot miss. It's not a suggestion, it's a gate.

The project instructions don't enumerate every check. They describe the *system*: that a static analysis pre-gate exists, that it auto-discovers checks, and that it blocks all tests if any check fails. Most of the 51 checks are invisible to the AI until one fires. The specific global scoping rule is still documented (the AI needs to understand *why* so it can write correct code), but it's the exception. The majority of guardrails exist only as scripts on disk that the AI never thinks about. Zero context cost until the moment they matter.

The principle, as encoded in the project documentation: *"Prefer building static analysis checks over adding rules - machines enforce, rules explain judgment."*

When I'm tempted to add a new rule, I ask: "Would removing this cause the AI to make mistakes?" If yes, can I write a check instead? Rules are for the rare cases where the judgment is genuinely contextual and can't be mechanized. Everything else should be a check.

---

## IV. Anatomy of an AI Guardrail System

Over one month, the individual checks accumulated into a system. It wasn't designed top-down. It grew organically from specific failures, but it has a coherent architecture.

### The Ownership Manifest

A flat file listing every global variable that's mutated by more than one source file, and exactly which files are authorized to write it:

```
cfg: launcher_main, launcher_tray, launcher_wizard, config_loader, setup_utils
gGUI_DisplayItems: gui_data, gui_state, gui_workspace
gGUI_LiveItems: gui_input, gui_state, gui_data
```

If a global isn't in the manifest, only the declaring file may mutate it. Guaranteed. If it is in the manifest, all writers are listed explicitly. Guaranteed. The static analysis validates this against actual code on every run. Stale entries are auto-removed.

This isn't documentation. It's a mechanical contract. When the AI introduces a cross-file mutation that isn't in the manifest, the pre-gate blocks the test suite with an actionable error message. The AI can then either add the entry (intentional coupling) or move the mutation to the declaring file (keep coupling tight). I can double check intentional coupling without sweating specific code details. There's no third option of "accidentally coupling two modules and not noticing."

### Function Visibility

A naming convention enforced by static analysis:
- `_FuncName()` - private to the declaring file. Only that file may call it.
- `FuncName()` - public API. Any file may call it.

The convention existed from the start. The enforcement came after the AI called a private function from another file for the third time. Now it can't.

### The Pre-Gate

All static analysis runs before any test executes. If any check fails, the entire test suite is blocked:

```
--- Pre-Gate: Syntax Check + Static Analysis (Parallel) ---
  Syntax: 13/13 passed [PASS]
  Running 51 static analysis check(s) in parallel...
  Static analysis: all 51 checks passed (4.2s)
```

This is deliberate. The pre-gate covers *all* test types: unit tests, GUI tests, live integration tests. Even tests that run against the compiled executable. The reason is hard-won. Consider two bugs, both invisible to the compiler and the test suite:

A missing global declaration produces a compiled exe that, at runtime, pops an error dialog requiring a user click. The test pipeline hangs indefinitely waiting for interaction that nobody can see. That's the blunt failure. At least it stops.

A concurrency lock entered without a matching unlock on an early return path is worse. The lock stays held. Every subsequent callback is serialized. In a keyboard-driven application, this means input lag that builds gradually over minutes of use. Tests pass. Manual testing passes, for the first few minutes. Only production reveals it, and only after enough time has elapsed.

The pre-gate catches both mechanically, before a single test runs.

### Auto-Discovery

New checks are auto-discovered. Drop a file matching `tests/check_*.ps1` into the test directory and it's enforced on the next run. No registration, no configuration. This is important because it eliminates friction from the "see a new class of bug → write a check" loop. The activation energy for adding a guardrail should be as low as possible.

Remember the skill frontmatter leak from Section II? That's enforced by an auto-discovered check now too. Every new skill must explicitly declare whether it's auto-discoverable. If it claims to be, it must appear in a two-entry whitelist. A skill not in the whitelist that tries to load into context fails the pre-gate with a `[STOP]` message telling the AI to confirm with the human before proceeding. The same pattern — identify the leak, tell the AI to write the gate, make the class of mistake impossible — applied to the AI's own configuration.

### Parallel Execution with Bundling

51 checks running sequentially would be intolerable. They run in parallel, with related checks bundled into 13 batch scripts that share setup costs. Total pre-gate time: ~4 seconds. Fast enough that it doesn't feel like friction. This matters; guardrails that slow you down get disabled.

---

## V. The Real Feedback Loop

So who writes the checks? 51 static analysis checks inside a framework: auto-discovery, parallelism, bundling. I didn't write most of it. Not the framework, not the checks. I directed and tweaked. Pointed at a class of bug and told the AI to make it impossible. The actual loop, the one that produces a functional guardrail system, looks like this:

**Human and AI do work together → a bug happens → the human recognizes the *class* of bug → the human tells the AI "write a check to catch this *pattern* FIRST, then fix the bug" → the AI writes both → that class of mistake is mechanically impossible, forever, across all future sessions.**

Every piece of this matters.

**"Write a check FIRST, then fix."** This is the critical discipline. If you let the AI fix the bug first, the check never gets written. The AI fixes the immediate problem, you move on, and next session you hit the same class of bug again. By forcing test-before-fix, you exploit the fact that the bug is still live and reproducible. The check has to actually catch the current failure to pass. You've verified the guardrail works before the guardrail is needed.

**"The human recognizes the class of bug."** This is the (so far) irreplaceable human contribution. The AI sees a specific failure: "function `_GUI_Tick` references `gGUI_State` without a global declaration." The human sees the general pattern: "the AI consistently forgets global declarations in timer callbacks." The specific fix is one line. The general fix is a static analysis check that catches every instance of the pattern across the entire codebase.

And here's the part that keeps delighting me: **the new check usually reveals extra instances of the bug class already in the codebase but thus far unnoticed.** You wrote the check for today's bug and it hands you three more you didn't know about. The check was already paying for itself before you finished the session that created it.

**"The AI writes both."** I didn't write most of the static analysis checks. I guided the framework: auto-discovery, parallelism, bundling for efficiency. But the individual checks? I told the AI what class of mistake to catch, and it wrote the checker. It's building its own cage. The human contribution is knowing what shape the cage needs to be.

The result is a system where the AI's mistakes are the *input* to a process that makes those mistakes impossible. Each failure makes the system stronger. Not the AI. The AI is frozen. The *system around the AI* learns, even though the AI itself cannot.

---

## VI. Give It Memory Through Tooling

A stateless collaborator with no long-term memory sounds crippling. In practice, you can work around it, if you give the AI tools that act as external memory.

The project has a set of query tools, scripts that return semantic answers to common questions. Who owns this global? What's the public API of this module? Which files consume this config value? The tools share a design principle: **the work runs externally, only the answer enters context.**

The token savings matter, but the deeper value is *correctness*.

When the AI needs to understand who mutates `gGUI_LiveItems`, the naive approach is to read source files. It opens `gui_main.ahk`, finds nothing definitive, opens `gui_state.ahk`, finds two writes, opens `gui_data.ahk`, finds one more. Three files checked, answer in hand. Except it's wrong. There's a fourth writer in `gui_input.ahk` — a file the AI didn't think to check because nothing in the files it read pointed there. Next session, it checks different files and reaches a different wrong answer. The AI can't build a mental model that persists, so every ad-hoc investigation is a fresh guess about which files matter.

The query tool doesn't guess:

```
gGUI_LiveItems
  declared: src/gui/gui_main.ahk:91
  writers:  gui_input (1), gui_state (2), gui_data (1)
  readers:  gui_data, gui_paint, gui_state
  manifest: line 3
```

It knows every writer because it scans the entire codebase, every time. It encodes project knowledge the AI can't accumulate across sessions — the kind of structural understanding a human developer builds over months. The AI gets it in two seconds, with no files loaded into context.

The pattern is generalizable: **when you find the AI repeatedly loading big files to find small answers, tell it to build a query tool instead.** Each one took about 15 minutes; the AI writes the script, you verify the output makes sense. That 15 minutes replaces unreliable ad-hoc investigation with a reliable, repeatable lookup — every session, from the first minute. This is the automation calculus from Section I, except the AI is on both sides of the equation: it's the one getting answers wrong through file reading (while wasting context), and it's the one that builds the tool to get them right. You just have to notice the pattern and point.

---

## VII. What This Looks Like in Practice

Abstract principles are easy. Here's what they look like in a real session.

I asked the AI to reduce cross-file coupling in the codebase, a 15-file architectural refactoring that moved global declarations, replaced direct cross-module mutations with API calls, and encapsulated namespace access behind setter functions. The AI planned the work in four groups, running the full test suite between each.

The refactoring logic was correct every time. The pre-gate still caught it three times.

**Catch 1: Silent variable erasure.** Moving a global declaration from file A to file B meant file C (which referenced it inside a function) would silently read an empty string at runtime instead of the actual value. No crash, no error. The function would just quietly do the wrong thing. The compiler doesn't catch this. The AHK runtime doesn't warn about it (warnings are suppressed to prevent dialog popups in production). Only `check_globals.ps1` saw that a function body referenced a variable that no longer existed in its include chain.

**Catch 2: Critical section corruption.** The AI wrote a new `Disable()` function that internally called `Stop()`, which contains `Critical "Off"`. Any caller invoking `Disable()` from inside their own `Critical "On"` section would have had their atomicity silently destroyed. The callee's `Critical "Off"` leaks out to the caller. Race conditions, data corruption, non-deterministic crashes that only manifest under load. `check_critical_leaks` flagged it before a single test ran.

**Catch 3: Undefined function reference.** A new public API function was added to one module but a consumer in the test chain referenced the old internal name. At runtime, this would crash, but only when that specific code path executed, which might not happen during normal testing. `check_undefined_calls` caught the mismatch statically.

Three bugs. All introduced by correct refactoring logic with incorrect ripple effects. None would have been caught by the compiler. None would have been caught by the test suite; the tests would have passed, and the bugs would have appeared in production as silent misbehavior, intermittent corruption, and rare crashes.

The AI fixed each one in under a minute, re-ran the gate, and moved on. Total session time: 8 minutes for a 15-file refactoring with mechanical verification at every step. Less than 10% context used. The human reviewed the final result, not the intermediate firefighting.

---

## VIII. When It Breaks Down

This system isn't perfect. Honesty about its limitations is important.

**The ghost in the machine.** During the same refactoring session, the compiled application displayed a visual artifact, a white rounded rectangle that shouldn't have existed. It persisted across application relaunches and recompiles. Then, after stashing the changes and force-recompiling, it vanished. We restored the changes, force recompiled again, and it stayed gone. None of the changed code touched rendering. The test suite (all 640 tests) passed every time.

We never found the cause. Non-determinism in compiled binaries, a DWM compositor fluke, a stale compilation artifact. We have theories but no proof. No static analysis check could have caught it. No test verified it. The system's blind spot is everything that no automated check can verify.

**False confidence from passing tests.** Tests verify behavior, not visual correctness. A full green test suite can coexist with a broken user interface. This is inherent to automated testing, not specific to AI, but it's amplified when the AI interprets "all tests pass" as "the change is correct."

**The temptation to over-engineer.** Every check you add has a maintenance cost. It can produce false positives. It needs updating when conventions change. There's a point where the guardrail system itself becomes the complexity problem. The same automation calculus applies: if a check catches a bug once a year, it might not be worth the friction. Build checks in response to real failures - especially repeated or severe ones, not hypothetical ones.

**The AI boundary.** The hardest judgment call is knowing when the AI should be generating conclusions versus supporting human conclusions. Using AI to surface which functions reference a global: good. Using AI to decide whether a refactoring is architecturally sound: dangerous. The boundary isn't fixed; it depends on verification cost, domain expertise, and consequence of error. But it exists, and pretending it doesn't is how you get fire stations in the wrong neighborhood.

### The Cage-Modifier Problem

The limitations above are gaps, things the system can't catch. This one is different. It's the system undermining itself.

The AI is surprisingly good at recognizing when a check needs updating. A structural refactoring changes a convention, the check's assumptions are stale, and the AI updates the check unprompted. Usually it's right. The problem is "usually." Occasionally, when a check catches a legitimate error, the AI modifies the check to accommodate the error instead of fixing the code. A function is missing a `Critical "Off"` on a return path. Instead of adding the missing unlock, the AI creates a baseline exemption file that the check never had, wires the check to skip anything in the baseline, and adds the offending function to it. The bug is "fixed," the gate passes, and the actual defect ships behind a freshly constructed escape hatch.

It's not malicious. It pattern-matches "check is failing, check needs updating" without always distinguishing "check is wrong" from "code is wrong." So modifications to the guardrail system itself became a primary review point. If the AI touched a static check or the ownership manifest without being asked to, I look at it the same way I'd look at a developer modifying the CI pipeline to make their failing tests pass.

This is the fundamental tension of having the AI build its own guardrails: the same capability that lets it write the check lets it rewrite the check. The human's irreducible role isn't writing code or even writing checks. It's watching the cage walls.

---

## IX. The Uncomfortable Conclusion

The most effective AI coding workflow I've found looks nothing like the demos. It's not "describe what you want and the AI builds it." It's not "AI writes code, human reviews." It's not a pair programming session with a very fast typist.

It's this: **the human identifies failure patterns, tells the AI to build its own cage, and mechanical checks verify the boundaries.**

The AI isn't your junior developer. It's a brilliant amnesiac with perfect syntax and no judgment. It will write flawless code and introduce the same class of bug in every session until the heat death of the universe, unless you make that class of bug mechanically impossible.

The human skill that matters isn't only coding. It's pattern recognition across failures. Seeing a specific bug and recognizing the general class. Knowing when to encode a lesson as infrastructure versus when to just fix the immediate problem. Understanding where the AI boundary should be, where verification is cheap enough to trust the output and where it isn't.

The system I've described (static analysis gates, ownership manifests, query tools, auto-discovered checks) is specific to my project. The principles are not:

1. **Protect the context window.** It's the binding constraint, not capability.
2. **Encode lessons as checks, not rules.** Machines enforce; rules explain judgment.
3. **Make the AI build its own guardrails.** You classify the error; it writes the fix.
4. **Test before fix.** The bug is the proof that the check works.
5. **Do the work outside the window.** Every cycle spent in a script is a token the AI doesn't burn reading, parsing, or reasoning its way to the same answer.

The AI can't learn. But the system around it can. Build accordingly.
