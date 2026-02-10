# Benchmark Results — Native Code Optimization Candidates

**Machine**: IVORY / Intel 12th Gen (Alder Lake) / AHK v2 x64
**Date**: 2026-02-09

---

## T1-A: IPC UTF-8 Encoding

| Size | Current (2-pass) | 1-Pass | Raw StrPut | Obj Alloc |
|------|------------------|--------|------------|-----------|
| 100B | 1.4us | 1.1us | 0.8us | 0.8us |
| 500B | 1.4us | 1.2us | 0.9us | — |
| 1KB | 1.4us | 1.3us | 1.0us | — |
| 5KB | 2.3us | 2.0us | 1.6us | — |
| 10KB | 3.6us | 2.9us | 2.7us | — |
| 32KB | 9.2us | 11.9us* | 8.2us | — |
| 64KB | 16.2us | 17.0us* | 16.4us | — |
| 1KB unicode | 1.8us | 1.5us | 1.2us | — |

*32KB/64KB 1-pass shows higher p95 spikes (cache effects at large sizes).

### Analysis

- **Two-pass vs one-pass**: ~0.3us savings at small sizes (100B-5KB). Negligible.
- **Object allocation**: ~0.3-0.4us overhead per call (the `{ buf:, len: }` wrapper).
- **StrPut itself**: Dominates at large sizes (linear in string length). Already calls native Win32 `WideCharToMultiByte` under the hood.

### Verdict: NO-GO for native MCode

StrPut is already a thin wrapper around Win32's `WideCharToMultiByte`. The overhead is <1us for typical IPC messages (<5KB). The object allocation costs 0.3us. A native replacement would save at most ~0.5us per call — not worth the MCode complexity.

**Quick win instead**: Switch production to single-pass StrPut pattern (skip length measurement). Saves one string scan. ~0.3us per call, zero complexity.

---

## T1-B: Icon Alpha Channel Scanning

| Icon Size | Pixels | AHK Worst (all 0) | AHK Mid | AHK Mask Apply | Native memcmp | Native memcpy | **AHK/Native Ratio** |
|-----------|--------|-------------------|---------|----------------|---------------|---------------|----------------------|
| 16x16 | 256 | 25us | 13us | 58us | 1.0us | 0.9us | **25x** |
| 32x32 | 1024 | 96us | 48us | 229us | 1.1us | 0.9us | **87x** |
| 48x48 | 2304 | 216us | 106us | 513us | 1.1us | 1.0us | **196x** |
| 64x64 | 4096 | 381us | 189us | 908us | 1.3us | 1.2us | **293x** |
| 128x128 | 16384 | 1515us | 748us | 3631us | 2.7us | 2.0us | **561x** |
| 256x256 | 65536 | 6087us | 2976us | 14626us | 8.3us | 4.7us | **733x** |

### Analysis

**This is the cJSON moment.** Confirmed with head-to-head DLL benchmark (all tests PASS for correctness):

#### Head-to-Head: AHK vs Native C DLL (compiled, measured)

| Icon Size | AHK Scan (worst) | Native Scan | **Speedup** | AHK Scan+Mask | Native Scan+Mask | **Speedup** |
|-----------|------------------|-------------|-------------|---------------|------------------|-------------|
| 16x16 | 54us | 4.4us | **12x** | 82us | 4.7us | **17x** |
| 32x32 | 94us | 4.5us | **21x** | 326us | 5.0us | **65x** |
| 48x48 | 213us | 4.4us | **49x** | 728us | 5.7us | **128x** |
| 64x64 | 375us | 4.9us | **77x** | 1285us | 6.4us | **201x** |
| 128x128 | 1495us | 5.9us | **252x** | 5201us | 12.7us | **409x** |
| 256x256 | 5990us | 10.5us | **572x** | 20535us | 37.6us | **546x** |

**Best case (first pixel has alpha)**: AHK wins (0.9us vs 4.1us) — DllCall overhead exceeds the trivial early exit. This is fine: most icons have alpha, so the common path is cheap either way. The native version pays off on the uncommon-but-expensive path.

**Real-world impact**: Icons without alpha (old Win32 apps, certain system tray icons) cost 5.2ms per 128x128 icon in AHK. With native: 12.7us. The icon pump batches 2-5 icons per tick — native eliminates this as a bottleneck entirely.

### Verdict: **GO — Confirmed. 250-550x speedup measured.**

- C prototype: `temp/native_src/icon_alpha.c` (compiled, tested, 100 LOC)
- DLL: `temp/native_src/icon_alpha.dll` (103KB, no dependencies)
- All correctness tests PASS (AHK and native produce identical mask results)
- Next: embed as MCode using cJSON pattern, integrate into `gui_gdip.ahk`

---

## T2-A: Projection Transform (_WS_ToItem)

| Windows | Batch Cost | Per-Item |
|---------|-----------|----------|
| 10 | 18us | 1.8us |
| 30 | 52us | 1.7us |
| 50 | 102us | 2.0us |
| 100 | 219us | 2.2us |
| 200 | 418us | 2.1us |

**Breakdown per item**:
- Object construction (14 fields): 1.6us
- Property reads (14 reads): 1.4us
- Dynamic `%field%` reads (14 reads): 2.9us (hardcoding saves 1.5us)

### Analysis

- ~2us per item, dominated by object literal construction (1.6us) + property reads (1.4us).
- For typical 30-window scenario: 52us total. For extreme 100-window: 219us.
- Native would need to bridge AHK objects → C structs → AHK objects. The bridging overhead would likely eat most of the savings.
- The hardcoded field pattern already avoids dynamic `%field%` resolution (saves ~1us/item).

### Verdict: NO-GO

2us/item is fast enough. 52us for 30 windows is negligible in the pipeline. The AHK→C→AHK object bridging would add complexity with minimal payoff. The hardcoded field optimization already captures the easy win.

---

## T2-B: IPC Line Parsing

| Messages | Msg Size | Full Parse | InStr Only | SubStr Only | fn.Call |
|----------|----------|-----------|------------|-------------|--------|
| 5 | 100B | 4.5us | 2.2us | 2.4us | 1.4us |
| 20 | 100B | 13.6us | 6.1us | 6.1us | 3.2us |
| 50 | 100B | 35.9us | 12.2us | 13.5us | 6.7us |
| 5 | 1KB | 7.1us | 3.7us | 3.2us | 1.4us |
| 20 | 1KB | 80.3us | 11.9us | 7.8us | 3.2us |
| 50 | 1KB | 281us | 41.0us | 18.2us | 6.7us |

### Analysis

- Full parse ≈ InStr + SubStr + fn.Call + overhead. The breakdown is roughly equal between scanning and extraction.
- At typical IPC volumes (5-10 messages per read, 100-500B each): ~5-10us per parse call. Fast.
- Larger buffers (50x1KB = 50KB): 281us. This is the burst case during projection pushes.
- The callback dispatch (`fn.Call`) is surprisingly cheap: 0.13-0.29us per call at scale.
- `InStr` uses native `wcsstr` internally. `SubStr` is a native string slice. Both are already native C under the hood.

### Verdict: NO-GO

InStr and SubStr are already backed by native C string operations in AHK v2's runtime. A native line splitter would avoid the interpreter dispatch loop, but the savings are small (maybe 2x at best) on operations that are already 5-10us for typical workloads. Not worth the MCode complexity.

---

## T2-C: Projection Diffing (BuildDelta)

| Windows | 0% Changed | 10% Changed | 50% Changed | 100% Changed |
|---------|-----------|-------------|-------------|--------------|
| 10 | 44us | 41us | 39us | 17us |
| 30 | 120us | 120us | 79us | 46us |
| 50 | 189us | 186us | 139us | 78us |
| 100 | 385us | 360us | 258us | 148us |

**Breakdown**:
- Map construction (100 items): 18-20us (reuse pattern saves ~2us)
- Field comparison (14 fields, identical): 3.4us per pair
- Field comparison (14 fields, diff at field 1): 1.2us (early break)
- ObjOwnPropCount: 0.5us (negligible)

### Analysis

- 0% changed (no-diff) is actually the **slowest** because every window compares all 14 fields without early break.
- 100% changed is fastest because field 1 (title) differs immediately → early break on every comparison.
- For typical scenario (30 windows, 10% changed): 120us. Acceptable.
- The dynamic `%field%` comparison loop is the main cost: ~3.4us per identical pair × 30 windows = ~100us.
- Sparse mode adds ~10% overhead (building partial objects) but is change-rate-independent.

### Verdict: NO-GO (borderline)

120-385us depending on window count. The dynamic `%field%` property access per comparison is the bottleneck, but moving to native would require flattening AHK objects into C structs — significant bridging complexity. If window counts regularly exceed 100, revisit. For typical 30-50 window usage, not worth it.

**Potential AHK-side optimization**: For the "0% changed" hot case, add a cheap revision check before field-by-field comparison (already partially done via dirty tracking).

---

## Summary Decision Matrix

| Target | Current Cost | Native Potential | Speedup | Complexity | Decision |
|--------|-------------|-----------------|---------|-----------|----------|
| **T1-A: UTF-8 Encode** | 1-3us typical | ~1us | 1.5-2x | Low | **NO-GO** (already native under the hood) |
| **T1-B: Alpha Scan** | 1500us @ 128x128 | ~3us | **500x** | Low (~50 LOC C) | **GO** |
| **T1-B: Mask Apply** | 3600us @ 128x128 | ~3us | **1200x** | Low (same function) | **GO** |
| **T2-A: ToItem** | 2us/item | ~0.5us | 4x | High (object bridging) | **NO-GO** |
| **T2-B: Line Parse** | 5-10us typical | ~3us | 2x | Medium | **NO-GO** (already native under AHK) |
| **T2-C: Delta Diff** | 120us @ 30win | ~20us | 6x | High (object bridging) | **NO-GO** (borderline) |

---

## Next Steps

1. **T1-B: Write C prototype** for combined alpha scan + mask application
   - Input: `pixels` buffer ptr, `maskPixels` buffer ptr (nullable), pixel count
   - Output: modified `pixels` buffer (alpha bytes set), return value = hasAlpha
   - Compile to MCode, embed using cJSON pattern
   - Benchmark native vs AHK on real icon data

2. **T1-A: Quick AHK optimization** — switch to single-pass StrPut in production `_IPC_StrToUtf8`
   - Saves ~0.3us per call, zero risk, one-line change

3. **T2-C: Monitor** — if window counts grow past 100, revisit native diffing
