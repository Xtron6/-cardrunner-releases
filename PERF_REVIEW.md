# CardRunner — Backend Performance Review

**Prepared for:** lead coder
**Scope:** ingest backend only (`CardRunner.sh`, `cardcopy.c`, Swift progress path in `ContentView.swift`). UI revamp is in progress separately; this review deliberately avoids UI structure and focuses on the ingest engine so the findings survive the redesign.
**Method:** full static read of the three files below. Findings are reasoned from how `find` traversal, process spawning, and SwiftUI state invalidation behave — **not yet benchmarked on a physical card.** Treat the severity ranking as a hypothesis to confirm with a profile before investing heavily in #1.

| File | Role |
|------|------|
| `CardRunner/CardRunner.sh` (~2,270 lines) | scan / filter / manifest / dest-grouping orchestration |
| `cardcopy/cardcopy.c` (v1.2.0, ~756 lines) | native copy engine |
| `CardRunner/ContentView.swift` (~14,000 lines) | progress parser + UI state |

---

## TL;DR

- **The copy engine is not the problem.** `cardcopy.c` copies exclusively via Apple's `fcopyfile()` (the fd-based entry to `copyfile()`), with `clonefile()` as a same-volume fast path that never fires for exFAT→APFS card ingest. No rsync, no `cp`, no `ditto`, no manual read/write copy loop. This matches the locked engine decision and needs no change.
- **All meaningful cost and scaling risk is in the pre-copy scan/build phase** (full-card `find` run 2–6×) and in the **rate of Swift→UI updates** on high-file-count cards.
- Two fixes carry ~90% of the value: **(1) single-pass card scan**, **(2) coalesced per-file UI updates**.

---

## Confirmed: copy engine is correct, leave it alone

Only data-copy call in the engine:

```c
// cardcopy.c:460
fcopyfile(src_fd, dest_fd, cstate, COPYFILE_DATA)
```

- `clonefile()` (cardcopy.c:378) is the APFS→APFS instant-clone shortcut; cards are exFAT, so it provably never triggers and falls through to `fcopyfile`.
- The `read()` at cardcopy.c:228 is **SHA-256 hashing only** (verify path), not data movement.
- `grep -niE "rsync|/bin/cp|ditto"` across shell + C returns nothing (the "FolderSync" log-label hits are unrelated).

The engine is also well-built beyond the copy call: 4 Hz throttled progress driven by `copyfile`'s real COPIED counter (not `st_size` polling), async overlapped SHA-256 on a serial queue, per-file `fsync` + one `F_FULLFSYNC` per invocation, atomic temp→rename with ENOENT backoff. **No speed concerns here.**

---

## Findings (ranked)

### 🔴 1. Card is fully scanned 2–6× before any byte copies — *high confidence, high impact*
In `run_ingest`'s build phase:

- `build_media_file_list` scans once (CardRunner.sh:1492).
- `skip_wrong_mode` runs a **second** full-card `find` purely to count opposite-type files for a log line (CardRunner.sh:1501–1519).
- Date-filter accounting **re-runs `build_media_file_list` with the filter disabled** — a **third** full scan — only to compute `skip_today_filter` for a log line (CardRunner.sh:1523–1548).
- Multi-date picker: `_append_files_for_date` runs **one full `find` per selected date** (CardRunner.sh:383–393). 5 dates → 5 scans + the accounting scan.

Each `find` carries ~20 OR'd `-iname` patterns (case-folding every entry). On a CFexpress card with thousands of files in deep camera trees, traversal is the dominant pre-copy latency, multiplied 3–6×. **None of the extra scans are needed for correctness** — they exist only to populate diagnostic skip counters.

**Recommendation:** Scan once. Replace the find-based scans **and** the separate python stat pass with a single `python3` `os.scandir`/`os.walk` traversal that emits `relpath|size|mtime|ext` for every file in one process. Partition in memory (zsh assoc arrays, already used elsewhere) into matched / wrong-mode / date-excluded / manifest-dup / dest-exists. Collapses 3–6 `find` scans + 1–2 python stat passes into one traversal. Biggest single win for speed and scalability.

### 🟠 2. Redundant `python3` spawns + dead code — *high confidence, low/med impact*
Each `python3 -` spawn is ~30–50 ms. Currently spawned for: build stat batch (CardRunner.sh:1567), `record_ingested_global` stat batch (:986), and `_ms_now` twice (:1828–1829).
- `sum_bytes_for_list` (CardRunner.sh:613) is **defined but never called — dead code, delete it.**
- Folding stat into the single traversal (#1) removes most spawns.
- For `_ms_now`, use zsh's `$EPOCHREALTIME` (`zmodload zsh/datetime`) — millisecond time, zero forks.

### 🟠 3. `PROGRESS_FILE` storms the main thread on many-file cards — *high confidence, high impact at scale*
`PROGRESS_FILE` contains `PROGRESS_`, so it's classed `isCritical` and **bypasses the 0.15 s background throttle** (ContentView.swift:9759–9764). Each one forces a `DispatchQueue.main.async` + mutate-copy-writeback of the `ActiveIngest` struct into `@State activeIngests` (ContentView.swift:10394, 10637), invalidating every SwiftUI view bound to it. A 2,000-photo card landing in seconds = ~2,000 main-thread hops + 2,000 full recomputes back-to-back. This is the "unnecessary rendering" risk.

**Recommendation:** Coalesce per-file UI state — accumulate completed-file count / current name in background vars, flush to `activeIngests` on the same 0.15 s cadence (or a timer). Exact data preserved; only publish rate is bounded.

### 🟡 4. `cardcopy` collision table is O(n²) — *high confidence, low impact now / scaling cliff later*
`claimed_contains` (cardcopy.c:74) is a linear `strcmp` scan called once per file in `reserve_final_name`. Sequential ingest of N files into one folder → O(N²). Negligible <1k files; grows quadratically past 10k. **Recommendation:** swap `g_claimed[]` for a hash set. Do this alongside wiring `--concurrency` in the revamp.

### 🟡 5. `record_ingested_global` re-reads the whole manifest per copy group — *high confidence, low/med impact*
Loads the (up-to-10k-line) manifest into an assoc array on every call (CardRunner.sh:971–975), once per destination group. Multi-day ingests re-parse it repeatedly. **Recommendation:** load the dedup set once before the group loop, pass it in, append in memory.

---

## Edge cases to harden (not perf, but found during review)

- **Filenames with newlines:** dest-grouping writes paths newline-delimited (CardRunner.sh:1879–1880) then reads line-by-line. exFAT permits `\n`; a manually-renamed clip could split/corrupt a group. Use NUL-delimiting (`print -rN` / `read -d ''`).
- **Reel filter regex injection:** `grep "^${_rf}/"` (CardRunner.sh:469) treats the reel name as a regex; a name with `.`/`*` mis-matches. Use `grep -F` (anchor handled separately) or fixed-string compare.
- Wrong-clock (Tier 0/1), mid-transfer unmount (DEST_VANISHED, exit 143/130), partial dirs, manifest-only-on-success: all handled correctly — no action.

---

## Suggested order of work

1. **Single-pass scan (#1)** — profile first to confirm magnitude, then implement. Largest win.
2. **Coalesce `PROGRESS_FILE` UI updates (#3)** — pairs naturally with the UI revamp.
3. **Delete dead `sum_bytes_for_list`; cut python spawns / use `$EPOCHREALTIME` (#2).**
4. **Hash-set the cardcopy claimed table (#4)** — bundle with `--concurrency` wiring.
5. **Manifest-load-once across groups (#5).**

**Do not touch the copy engine** (`fcopyfile`) — it is correct and fast; none of the above requires changing it.
