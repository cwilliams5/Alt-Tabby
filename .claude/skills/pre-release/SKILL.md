---
name: pre-release
description: Pre-flight checklist — run high-signal review skills before a release
user_invocable: true
---

Run the curated pre-release review checklist. Each review enters planning mode and produces findings. Stop and report after each tier — the user decides whether to proceed to the next tier or address findings first.

## Tier 1 — Correctness (bugs that ship to users)

Run these first. Any findings here are release-blockers:

1. **`/review-race-conditions`** — New races = crashes or data corruption in the wild
2. **`/review-resource-leaks`** — Leaks degrade the user's system over time
3. **`/review-option-interaction`** — Broken install/update/admin path = users stranded

**After Tier 1:** Report findings. If any exist, ask the user: address now or proceed to Tier 2?

## Tier 2 — Hygiene (things that rot if not caught)

4. **`/review-debug`** — Ungated log writes or accidentally-enabled diagnostics ship to users

**After Tier 2:** Report findings. Ask the user: address now or proceed to release?

## Execution

For each skill in order:
1. Invoke the skill (it enters planning mode and produces a plan)
2. Summarize findings concisely — count of issues by severity
3. If zero findings, note it and move to the next skill
4. After completing a tier, present the tier summary and pause for user decision

## Reporting

After all skills have run, present a release readiness summary:

| Skill | Findings | Severity |
|-------|----------|----------|
| review-race-conditions | 0 | — |
| review-resource-leaks | 2 | 1 high, 1 low |
| review-option-interaction | 0 | — |
| review-debug | 1 | medium (ungated log) |

**Release recommendation:** Proceed / Address N issues first

The user makes the final call. This skill surfaces information — it does not block releases.
