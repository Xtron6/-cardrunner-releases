# CardRunner — Session Handoff (2026-06-29)

**For:** the next coding agent / chat.
**Purpose:** continue the v3 UI rebuild + engine wiring without re-discovering everything.
**Repo root:** `/Users/xaviergallo/Documents/The Everything/DIY Apps/Apps/CardRunner`
**Owner:** Xavier Gallo. macOS SwiftUI app, **Mac-only**, direct-distribution (not App Store).

> Persistent project memory lives in
> `~/.claude/projects/-Users-xaviergallo-Documents-The-Everything-DIY-Apps-Apps-CardRunner/memory/`
> — read `MEMORY.md` + `cardrunner-roadmap.md` + `cardrunner-ui-patterns.md` first; they hold the locked decisions.

---

## 1. What CardRunner is
A macOS app that offloads footage from camera cards to drives, **fast and safely** — `cardcopy` (fcopyfile/clonefile) engine, SHA-256/MD5 verify, atomic `.cardrunner_partial`→rename, crash-safe. Promise: **never lose footage, never report a failed transfer as success.** Used by DITs / sports & event shooters under pressure.

Key files:
- `CardRunner/ContentView.swift` — ~15k lines, the **shipping** UI + all ingest logic. **Untouched-as-UI** this session except safe extractions/fixes below.
- `CardRunner/CardRunner.sh` — ~2.4k-line bash ingest engine (scan/filter/manifest/copy).
- `cardcopy/cardcopy.c` — native copy engine (v1.2.0). Bundled binary at `CardRunner/cardcopy`.
- `CardRunner/CardRunner.swift` — `@main`. Has a **temporary** `CR_V3_PREVIEW=1` launch flag (see §4).

---

## 2. Two worlds right now
1. **Shipping app** (`ContentView`): the real, working, footage-safe app. Still the default UI.
2. **v3 rebuild** (`CardRunner/V3/`): the new multicard "ring" UI from Xavier's Claude Design mockups, being built natively and wired to a real engine. Shown only via `CR_V3_PREVIEW=1`.

The plan is to finish v3, wire it to real ingest, validate on hardware, then cut over.

---

## 3. What happened this session (chronological)

### A. Bug fixes to the shipping engine (all done + verified)
- **CRITICAL `int` bug:** `CardRunner.sh` used zsh `int()` without `zmodload zsh/mathfunc` → every transfer aborted at "PHASE copying" with 0 files. **Fixed** (added `zmodload zsh/mathfunc`). This was breaking real shoots.
- **Stats inflation:** failed runs counted *planned* bytes/files. Now credit **actual** (`doneBytes`/`completedFiles`) on failure — `bytesTransferred`/`filesTransferred` in the termination handler.
- **Sparkline never animated during transfer:** inline `Timer.publish` was recreated every render → reset. Hoisted to a stable `sparklineTimer` + seeded history.
- **99% "frozen" pause explained + surfaced:** it's the `F_FULLFSYNC` durability flush. Added an `isFinalizing` state → "Finalizing… / Flushing to disk" instead of a stuck 99%.
- **Proxy/missing-file accounting:** proxy skips & vanished-source files were silently dropped (made `found ≠ new + skipped`). Added `skip_proxy`/`skip_missing` counters + `PROXY SKIPS`/`MISSING SOURCES` log lines + `SKIP_SUMMARY proxy=/missing=` + Swift parsing + a red breakdown row.
- **Broadcast-day footage-loss bug:** the scan date-filter compared raw mtime while routing applied the broadcast-hour shift → post-midnight clips of the selected day were silently excluded. **Fixed** (scan now applies the same shift; `CR_BCAST_HOUR` env → `broadcast_shift()` in the Python scanner).
- **Eject logging:** `diskutil eject` success is now logged with duration (was only logging failures) — explains the post-copy gap.
- **Card-detection heuristic:** APFS/>2TB were *hard* rejects, blinding the app to 4TB CFexpress / APFS SSD recorders. Now a definitive camera signature wins; APFS/>2TB only gate the weak Tier-4 catch-all.
- **Verification default:** `pref_verifyTransfer` now defaults **ON** (spot-check, ≤10-file MD5, negligible time). Full verify stays opt-in. (Decision: lightweight safety by default without the 2× full-verify hit.)

### B. The safety net (Phase 0 — done)
- **`smoke_test.sh`** (repo root): runs the REAL shell+cardcopy against synthetic cards, asserts files land + correct success/failure. **24 checks**, incl. the `int`-class catch, proxy accounting, broadcast-day regression, spot-check verify, and a **concurrent two-destination** run (proves the shell is parallel-safe). Wired as a **gate in `release.sh`** (`SKIP_SMOKE=1` to bypass).
- **Unit tests** `CardRunnerTests/CardRunnerTests.swift` — **24 tests**. Also gated in `release.sh` (`SKIP_TESTS=1`).
- **Extracted the footage-critical pure logic** out of `ContentView` (so it's testable + reusable):
  - `evaluateIngestOutcome(exitStatus:ingest:) -> IngestOutcome` — the authoritative success/failure gate ("never report success on failure"). 5 tests incl. *exit-0-but-COPY_ERROR → failure*.
  - `applyIngestProgressLine(_:to:)` — pure shell→Swift progress parser. View's `parseProgress` now delegates data to it + a `handleProgressLineUI`. 7 tests.
  - `canAdmitIngest(_:snapshot:)` + `SchedulerSnapshot` — destination-aware concurrent **scheduler** (parallel across different drives, sequential per drive). 6 tests. Wired into `ContentView`'s `startIngest`/`drainQueue` (Phase 2 core) behind `pref_maxConcurrentCards` (default 3) — **behavior-preserving** with single-dest config.

### C. The v3 design + native build
- Xavier iterated the design in Claude Design (multiple handoff zips in `~/Downloads/`). We scrapped a hand-built approximation and a WebView preview — **decision: Mac-only native Swift, no HTML/WebView.**
- Built the native v3 UI in `CardRunner/V3/`:
  - `V3Model.swift` — state machine / view-model (demo lifecycle + now the engine adapter, see §D).
  - `CardRunnerV3View.swift` — the dashboard (top bar, sources lanes, center ring, destinations, funnel connector lines, drag-to-route, settings/add-dest/folder sheets, toast, bottom bar). ~700 lines.
  - `V3SettingsView.swift` — full 14-section settings screen.
- Matched the design closely: DEFAULT DESTINATION dashed-amber box, brand wordmark in bundled `Tech Headlines Italic`, tagline "Plug a card — it copies, instantly & safely", ring "All safe to pull" + count + Open-in-Finder pill, real bottom bar (status + New project folder / Today only / Auto-eject / Add destination). The demo buttons are a dimmed **TESTING** strip (kept on purpose to drive the prototype without hardware).

### D. Engine extraction + binding (Steps 2 & 4 — done; built + tests green)
- **`IngestEngine.swift`** (Step 2): real `@MainActor ObservableObject` ingest pipeline. Detects drives + card mounts (`NSWorkspace`), runs the real `CardRunner.sh` via `Process` with the buffered line reader, and **reuses** `applyIngestProgressLine` / `evaluateIngestOutcome` / `canAdmitIngest` (no logic duplication). Auto-routes to default + auto-starts, scheduler queue/drain, split/mirror (mirror via shell `--secondary`), history, keeps finished cards as `.done` "safe to pull" until pulled (`pull(_:)`/`pullAll()`), `eject` via diskutil. **Card-detection here is a COMPACT heuristic — TODO: unify with `ContentView.volumeLooksLikeCardStatic`.**
- **Step 4 binding:** `V3Model` now owns the engine and mirrors its real state — real drives → destination tiles, real ingests → lanes (`ActiveIngest.phase`→`V3CardStatus`), Pull→`engine.pull`, settings→engine via `didSet`. Simulated test cards (`V3Card.realKey == nil`) coexist with real ones (`realKey` set).
- **Freeze bug fixed:** `syncFromEngine()` was writing back to engine `@Published` → `objectWillChange` → re-entered sync → infinite main-thread loop (beachball). Now **read-only from the engine**; settings flow engine-ward only via `didSet`. Also the sim tick now **skips real cards** (they have `sizeGB==0` → divide-by-zero).

---

## 4. How to build / run / test
```bash
cd "/Users/xaviergallo/Documents/The Everything/DIY Apps/Apps/CardRunner"

# Build
xcodebuild -project CardRunner.xcodeproj -scheme CardRunner -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

# Unit tests (24)
xcodebuild test -project CardRunner.xcodeproj -scheme CardRunner -destination 'platform=macOS' \
  -only-testing:CardRunnerTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Smoke test (24 — real shell+cardcopy end to end)
./smoke_test.sh

# Run the v3 preview (the new UI). Kill any existing instance first.
pkill -f "Debug/CardRunner.app" ; CR_V3_PREVIEW=1 \
  "/Users/xaviergallo/Library/Developer/Xcode/DerivedData/CardRunner-hbuwejbtuggdywgriapcyvzklrwt/Build/Products/Debug/CardRunner.app/Contents/MacOS/CardRunner"
```
- DerivedData hash `CardRunner-hbuwejbtuggdywgriapcyvzklrwt` has been stable; re-derive if it changes.
- **Do NOT screen-control / screenshot** unless asked — Xavier runs it himself and reports back. Verify via build + xcodebuild only.

---

## 5. Next steps (the roadmap)
1. **Step 5 — validate on real hardware (highest priority).** Plug a real card + drive, run with `CR_V3_PREVIEW=1`, watch a real transfer go through `IngestEngine`. The launch path is structurally real (reuses tested pure fns) but **has NOT been exercised on hardware** — expect to fix real-world issues (arg construction, drive paths, progress mapping, eject). Last reported state: freeze fixed, relaunch pending Xavier's test.
2. **Step 3 — per-card / N-way routing** (only net-new backend). Today real cards auto-route to the **default drive only**; the v3 drag-to-route to a *different* real drive isn't wired to the engine, and mirror is one `--secondary` (extend to N drives). Make each card carry its own destination.
3. **Cut over** ContentView → v3 once it moves real footage (flip the default; keep old reachable briefly; then retire the `CR_V3_PREVIEW` flag + `ContentView`).
4. **Polish:** unify the engine's compact card heuristic with `ContentView.volumeLooksLikeCardStatic`; DM Sans bold faces (only Regular is bundled — body type falls back to system; add bold .ttf to the project for fidelity); pixel polish per Xavier's eye.
5. **Still-open from the old audit** (`memory/audit-2026-06-25.md`): history/stats durability (UserDefaults-only, no atomic file mirror), `--latest N` is a no-op, manifest dedup on exFAT mtime, persist `volumeUUID` in checkpoints. Lower priority than the v3 cutover.

---

## 6. Hard constraints / locked decisions (do not violate)
- **Copy engine is `fcopyfile()` only** (clonefile APFS fast path). No rsync/cp/loops/fallback. Closed decision.
- **Mac-only native Swift.** No HTML/WebView UI. (Both were tried + scrapped.)
- **Keep the big center ring** — it's the app's identity ("armed & watching, plug in → instant auto-start"). Redesign *around* it.
- **Routing:** **split is default**, mirror is opt-in. A plugged card **auto-routes to the default destination and auto-starts** (the instant-ingest promise). "Waiting/blocked" exists ONLY when no default is configured → loud blocking state, never a quiet dead-end.
- **Pull/eject:** manual pull by default; auto-eject opt-in.
- **Footage safety:** never report success on failure (the `evaluateIngestOutcome` gate); card kept mounted on failure; manifest only written on confirmed success.
- **GSD workflow** rule in `CLAUDE.md` is NOT installed in this checkout — direct edits are authorized.

---

## 7. Key file map (v3)
| File | Role |
|---|---|
| `CardRunner/V3/IngestEngine.swift` | Real ingest pipeline (detection, scheduler, launch/parse/outcome, pull). Reuses the tested pure fns. |
| `CardRunner/V3/V3Model.swift` | View-model: simulated test cards + **adapter** mirroring `IngestEngine` real state. `syncFromEngine()` is **read-only from the engine** (don't write back — loop). |
| `CardRunner/V3/CardRunnerV3View.swift` | The dashboard view. Demo "TESTING" toolbar drives sim; bottom bar is the real design. |
| `CardRunner/V3/V3SettingsView.swift` | Full settings screen. |
| `CardRunner/CardRunner.swift` | `@main`; `CR_V3_PREVIEW=1` shows `CardRunnerV3View` (temporary). |
| `CardRunner/ContentView.swift` | Shipping app + the extracted pure fns (`evaluateIngestOutcome`, `applyIngestProgressLine`, `canAdmitIngest`, `SchedulerSnapshot`, `ActiveIngest`, `Volume`, `IngestHistoryEntry`). |
| `smoke_test.sh`, `CardRunnerTests/` | The test net (gates in `release.sh`). |

---

## 8. Known caveats
- v3 real-transfer path is **not hardware-tested** yet (Step 5).
- In v3, when **real drives are connected** the Add/Remove-destination buttons are effectively inert (drives auto-detect; `syncFromEngine` rebuilds `dests`). With **no real drive** connected, the demo dests + add/remove work (for testing). Fine for now; revisit during cutover.
- Real-card lane MB/s label uses the sim contention math (cosmetic); real per-card speed should come from `ActiveIngest.liveMBps`.
- Engine's compact card heuristic ≠ ContentView's full one (unify later).
