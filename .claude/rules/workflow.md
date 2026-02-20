# Workflow

## GitHub Issues for Non-Trivial Work

When the approved plan involves multi-file changes, new features, or investigation-driven fixes: create a GitHub issue before implementation. Simple fixes (typos, one-liners, obvious bugs) go straight to PR.

**Issue content** — distill the plan to:
- Problem/goal (one sentence)
- Action items (only the surviving TODOs)
- Key decisions (non-obvious choices, one line each)

Omit investigation notes, rejected candidates, and false positives. PR references `Closes #N`.

## Worktree Agents

All file edits and new files must stay within your worktree. Never modify files in the main checkout or other worktrees.
Live tests (`--live`) are worktree-safe: scoped process kills, isolated pipes/mutexes, worktree-prefixed logs.
