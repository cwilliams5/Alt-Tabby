---
name: profile
description: Analyze a speedscope profile from Alt-Tabby's built-in profiler
---

Analyze a profiling session captured by Alt-Tabby's `--profile` build.

## File Resolution

Resolve the profile file using the argument (if any):

1. **No argument**: Use `release/recorder/`, pick the newest `profile_*.speedscope.json`
2. **Directory path**: Use that directory, pick the newest `profile_*.speedscope.json`
3. **Exact filename** (no path separators): Search `release/recorder/` for a matching file
4. **Full path**: Use as-is

Use `ls -t <dir>/profile_*.speedscope.json | head -1` to find the newest file. Confirm the resolved file path to the user before analyzing.

## Analysis Steps

Run these via `python tools/query_profile.py <file>`:

1. **Summary** (no flags) — always run first. Show the table to the user.
2. **Reentrancy check** (`--reentrant`) — always run. Flag any reentrant calls as potential bugs.
3. **Deep dive** — based on the summary, pick the top 2-3 functions by total time and run `--function <name>` on each. Focus on:
   - Unexpected caller chains (who is triggering this function and should they be?)
   - High call counts relative to session activity
   - Large max vs avg gaps (outliers worth investigating)

## Reporting

Present findings as:
- **Session overview**: duration, CPU%, key activity counts (switches, Alt-Tab cycles, etc.)
- **Hot spots**: top functions with actionable observations
- **Anomalies**: reentrancy, outlier calls, unexpected callers
- **Comparison**: if the user mentions a previous profile or a fix being tested, compare before/after metrics

Keep it concise — tables over prose. The user knows the codebase.
