---
name: review-tool-speed
description: Review query tools for runtime optimization opportunities
user-invocable: true
disable-model-invocation: true
---
Enter planning mode. Investigate query tool runtime and find optimization opportunities.

The query tools (`query_*.ps1` in project root) are critical for keeping context bloat down and getting programmatic answers.

1. Investigate each query tool for potential optimizations to decrease runtime. Optimizations must be **internal only** — no change to output, function, or contract of the tool.
2. For each recommendation, include an analysis statement explaining why it's internal-only and doesn't change the tool's job or contract.
3. Consider: caching, pipeline vs loop, regex precompilation, redundant file reads, shared parsing, startup overhead, etc.

Research the query tools deeply. Write a plan for all optimizations found. Ignore any existing plans — create a fresh one.
