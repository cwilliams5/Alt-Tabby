# query_profile.py - Speedscope profile analyzer for Alt-Tabby
#
# Parses speedscope JSON exports from Alt-Tabby's built-in profiler and
# produces human-readable performance summaries. Designed for use by both
# humans and AI agents investigating performance.
#
# The profiler (@profile annotations in AHK source) emits speedscope-format
# JSON via Profiler.Export(). This tool reads that JSON and computes:
#   - Per-function call counts, total/self/avg/max times
#   - Caller-callee relationships (who triggers each function)
#   - Timeline traces for specific time windows
#   - Reentrancy detection (nested calls to the same function)
#
# Usage:
#   python tools/query_profile.py <file>                     Summary table (sorted by total time)
#   python tools/query_profile.py <file> --callers           Who calls each function (repaint trigger analysis)
#   python tools/query_profile.py <file> --timeline 3.0 7.0  Event timeline for a time window (seconds)
#   python tools/query_profile.py <file> --function <name>   Deep dive on one function (callers + per-call list)
#   python tools/query_profile.py <file> --reentrant         Find functions that are called while already on the stack
#
# Input:  Speedscope JSON (typically release/recorder/profile_*.speedscope.json)
#         Handles UTF-8 BOM (AHK's FileAppend writes BOM by default).
#
# Output: Plain text tables to stdout. Designed to be compact enough for
#         AI agent context windows while still being useful to humans.
#
# Examples:
#   # Quick overview after a profiling session
#   python tools/query_profile.py release/recorder/profile_20260221_203727.speedscope.json
#
#   # Investigate why GUI_Repaint fires too often during workspace switches
#   python tools/query_profile.py <file> --callers --function GUI_Repaint
#
#   # Trace exactly what happens during a burst of workspace switches
#   python tools/query_profile.py <file> --timeline 3.0 7.0
#
#   # Find reentrancy bugs (functions calling themselves via message pump)
#   python tools/query_profile.py <file> --reentrant

import json
import sys
import argparse
from collections import defaultdict


def load_speedscope(path):
    """Load speedscope JSON, handling UTF-8 BOM."""
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:3] == b"\xef\xbb\xbf":
        raw = raw[3:]
    return json.loads(raw)


def build_call_data(frames, events):
    """Process events into per-function stats and caller relationships.

    Returns:
        func_stats: {frame_idx: {calls, total_us, max_us, min_us}}
        func_self:  {frame_idx: total_self_us}
        func_total: {frame_idx: total_us}
        call_log:   {frame_idx: [(start_us, dur_us, parent_name)]}
    """
    func_stats = defaultdict(
        lambda: {"calls": 0, "total_us": 0, "max_us": 0, "min_us": float("inf")}
    )
    func_self = defaultdict(int)
    func_total = defaultdict(int)
    call_log = defaultdict(list)

    stack = []  # (frame_idx, start_time, child_time_accumulated)

    for ev in events:
        t = ev["at"]
        frame = ev["frame"]
        typ = ev["type"]

        if typ == "O":
            stack.append((frame, t, 0))
        elif typ == "C":
            if stack and stack[-1][0] == frame:
                fr, start, child_time = stack.pop()
                dur = t - start
                self_time = dur - child_time

                s = func_stats[fr]
                s["calls"] += 1
                s["total_us"] += dur
                s["max_us"] = max(s["max_us"], dur)
                s["min_us"] = min(s["min_us"], dur)

                func_self[fr] += self_time
                func_total[fr] += dur

                # Add child time to parent
                if stack:
                    parent = stack[-1]
                    stack[-1] = (parent[0], parent[1], parent[2] + dur)

                # Record caller
                parent_name = frames[stack[-1][0]]["name"] if stack else "(top-level)"
                call_log[fr].append((start, dur, parent_name))

    return func_stats, func_self, func_total, call_log


def cmd_summary(frames, profile, func_stats, func_self, func_total):
    """Print summary table sorted by total time."""
    session_us = profile["endValue"] - profile["startValue"]
    print(f"Session: {session_us / 1_000_000:.1f}s")
    print(
        f"Profiled CPU: {sum(func_self.values()) / 1_000_000:.2f}s "
        f"({sum(func_self.values()) / session_us * 100:.1f}%)"
    )
    print()
    print(
        f"{'Function':<35} {'Calls':>6} {'Total ms':>10} {'Self ms':>10} "
        f"{'Avg ms':>10} {'Max ms':>10}"
    )
    print("-" * 87)

    ranked = sorted(func_stats.keys(), key=lambda f: func_total.get(f, 0), reverse=True)
    for fi in ranked:
        s = func_stats[fi]
        name = frames[fi]["name"]
        total_ms = func_total.get(fi, 0) / 1000
        self_ms = func_self.get(fi, 0) / 1000
        avg_ms = (s["total_us"] / s["calls"] / 1000) if s["calls"] else 0
        max_ms = s["max_us"] / 1000
        print(
            f"{name:<35} {s['calls']:>6} {total_ms:>10.2f} {self_ms:>10.2f} "
            f"{avg_ms:>10.2f} {max_ms:>10.2f}"
        )


def cmd_callers(frames, func_stats, func_total, call_log):
    """Print caller breakdown for each function."""
    ranked = sorted(func_stats.keys(), key=lambda f: func_total.get(f, 0), reverse=True)
    for fi in ranked:
        name = frames[fi]["name"]
        calls = call_log[fi]
        if not calls:
            continue

        # Group by caller
        by_caller = defaultdict(lambda: {"count": 0, "total_us": 0})
        for _, dur, parent in calls:
            c = by_caller[parent]
            c["count"] += 1
            c["total_us"] += dur

        print(f"\n{name} ({len(calls)} calls, {func_total[fi] / 1000:.1f}ms total)")
        for caller, info in sorted(by_caller.items(), key=lambda x: x[1]["total_us"], reverse=True):
            print(
                f"  <- {caller:<40} {info['count']:>4} calls  "
                f"{info['total_us'] / 1000:>8.1f}ms"
            )


def cmd_timeline(frames, events, t_start, t_end):
    """Print event timeline for a time window."""
    start_us = t_start * 1_000_000
    end_us = t_end * 1_000_000

    stack = []
    print(f"Timeline: {t_start:.1f}s - {t_end:.1f}s")
    print(f"{'t(s)':>8} {'Type':>5}  {'':>5}  Function")
    print("-" * 70)

    for ev in events:
        t = ev["at"]
        frame = ev["frame"]
        typ = ev["type"]

        if start_us <= t <= end_us:
            depth = len(stack)
            name = frames[frame]["name"]
            if typ == "O":
                print(f"{t / 1_000_000:>8.4f} {'OPEN':>5}  {depth:>5}  {'  ' * depth}{name}")
            elif typ == "C":
                print(f"{t / 1_000_000:>8.4f} {'CLOSE':>5}  {depth:>5}  {'  ' * depth}{name}")

        if typ == "O":
            stack.append((frame, t))
        elif typ == "C":
            if stack and stack[-1][0] == frame:
                stack.pop()


def cmd_function(frames, func_stats, func_self, func_total, call_log, name):
    """Deep dive on a single function."""
    # Find frame index by name
    fi = None
    for i, f in enumerate(frames):
        if f["name"] == name:
            fi = i
            break
    if fi is None:
        print(f"Function '{name}' not found in profile.")
        print("Available:", ", ".join(f["name"] for f in frames))
        return

    s = func_stats[fi]
    total_ms = func_total.get(fi, 0) / 1000
    self_ms = func_self.get(fi, 0) / 1000
    calls = call_log[fi]

    print(f"=== {name} ===")
    print(f"  Calls: {s['calls']}")
    print(f"  Total: {total_ms:.1f}ms  Self: {self_ms:.1f}ms")
    print(f"  Avg: {total_ms / s['calls']:.2f}ms  Max: {s['max_us'] / 1000:.2f}ms  Min: {s['min_us'] / 1000:.3f}ms")

    # Callers
    by_caller = defaultdict(lambda: {"count": 0, "total_us": 0})
    for _, dur, parent in calls:
        c = by_caller[parent]
        c["count"] += 1
        c["total_us"] += dur
    print(f"\n  Callers:")
    for caller, info in sorted(by_caller.items(), key=lambda x: x[1]["total_us"], reverse=True):
        print(f"    <- {caller:<38} {info['count']:>4} calls  {info['total_us'] / 1000:>8.1f}ms")

    # Individual calls (top 15 by duration)
    sorted_calls = sorted(calls, key=lambda x: x[1], reverse=True)
    print(f"\n  Top calls (by duration):")
    print(f"    {'t(s)':>8} {'ms':>8}  Called by")
    for start, dur, parent in sorted_calls[:15]:
        print(f"    {start / 1_000_000:>8.3f} {dur / 1000:>8.1f}  {parent}")


def cmd_reentrant(frames, events):
    """Find functions called while already on the stack (reentrancy)."""
    stack_set = defaultdict(int)  # frame_idx -> depth count
    reentrant = defaultdict(int)  # frame_idx -> reentrant call count
    reentrant_examples = defaultdict(list)  # frame_idx -> [(time, parent)]

    stack = []
    for ev in events:
        t = ev["at"]
        frame = ev["frame"]
        typ = ev["type"]

        if typ == "O":
            if stack_set[frame] > 0:
                reentrant[frame] += 1
                parent_name = frames[stack[-1][0]]["name"] if stack else "(top-level)"
                if len(reentrant_examples[frame]) < 5:
                    reentrant_examples[frame].append((t, parent_name))
            stack_set[frame] += 1
            stack.append((frame, t))
        elif typ == "C":
            if stack and stack[-1][0] == frame:
                stack.pop()
                stack_set[frame] -= 1

    if not reentrant:
        print("No reentrant calls detected.")
        return

    print(f"{'Function':<35} {'Reentrant calls':>15}")
    print("-" * 55)
    for fi, count in sorted(reentrant.items(), key=lambda x: x[1], reverse=True):
        name = frames[fi]["name"]
        print(f"{name:<35} {count:>15}")
        for t, parent in reentrant_examples[fi]:
            print(f"  e.g. t={t / 1_000_000:.3f}s via {parent}")


def main():
    parser = argparse.ArgumentParser(
        description="Analyze Alt-Tabby speedscope profile exports"
    )
    parser.add_argument("file", help="Path to speedscope JSON file")
    parser.add_argument("--callers", action="store_true", help="Show caller breakdown per function")
    parser.add_argument(
        "--timeline", nargs=2, type=float, metavar=("START", "END"),
        help="Show event timeline for time window (seconds)"
    )
    parser.add_argument("--function", type=str, help="Deep dive on a specific function")
    parser.add_argument("--reentrant", action="store_true", help="Find reentrant (nested) calls")

    args = parser.parse_args()
    data = load_speedscope(args.file)

    frames = data["shared"]["frames"]
    profile = data["profiles"][0]
    events = profile["events"]

    func_stats, func_self, func_total, call_log = build_call_data(frames, events)

    if args.timeline:
        cmd_timeline(frames, events, args.timeline[0], args.timeline[1])
    elif args.function:
        cmd_function(frames, func_stats, func_self, func_total, call_log, args.function)
    elif args.callers:
        cmd_callers(frames, func_stats, func_total, call_log)
    elif args.reentrant:
        cmd_reentrant(frames, events)
    else:
        cmd_summary(frames, profile, func_stats, func_self, func_total)


if __name__ == "__main__":
    main()
