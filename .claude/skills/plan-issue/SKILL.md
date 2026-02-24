---
name: plan-issue
description: Create a GitHub issue from an approved plan before implementation
user-invocable: true
disable-model-invocation: true
---
Create a GitHub issue from the approved plan. Distill — do not dump the full plan.

**Issue content:**
- **Title**: short imperative summary (under 70 chars)
- **Body**:
  - Problem/goal (one sentence)
  - Action items (only the surviving TODOs, as a checklist)
  - Key decisions (non-obvious choices, one line each)

Omit rejected candidates, false positives, and exploration steps. Include investigation notes section only if of high documentation value or if it is needed context for coding agent. 

After creating the issue, report the issue number and URL. The subsequent PR must reference `Closes #N`.

Then create a new worktree using the EnterWorktree tool and proceed with executing the plan inside it.