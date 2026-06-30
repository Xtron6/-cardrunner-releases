# CardRunner — Session Handoff (2026-06-30)

**For:** the next coding agent / chat (context is filling up).
**Owner:** Xavier Gallo. macOS SwiftUI app, **Mac-only**, direct-distribution (Sparkle, not App Store).
**Repo root:** `/Users/xaviergallo/Documents/The Everything/DIY Apps/Apps/CardRunner`
**Branch:** `nway-rebuild` (all work lives here; `main` is the original "Initial Commit" stub — do NOT branch off main).

> Persistent project memory: `~/.claude/projects/-Users-xaviergallo-Documents-The-Everything-DIY-Apps-Apps-CardRunner/memory/`
> Read `MEMORY.md` + `cardrunner-roadmap.md` first — they hold the full chronology + locked decisions. This file is the fast snapshot.

---

## 1. TL;DR — where things are

**The v3 node UI IS the app now.** The redesign is no longer a preview flag — `ContentView.body` renders `bodyV3` by **default**. It runs as a real Finder-launched `.app`, drives the **real, unchanged copy engine** (`cardcopy` + `CardRunner.sh`), and has been proven on hardware (26-clip / 17.7 GB ingest at 227 MB/s, Status=OK).

- **Tier 1 — COMPLETE, production-ready** (reviewer-verified): history+stats, date-filter menu, verify menu, per-card naming.
- **Tier 2 — COMPLETE, production-ready** (reviewer-verified "ship it"): all keyboard/menu wiring surfaced in v3, Photo/Video toggle, v3 Activity Log, and a hardened **completion-feedback / failure-record footage-safety chain**.
- **Latest commit:** `a73dc48` on `nway-rebuild`. Build + **33 unit** + **31 smoke** all green.

---

## 2. How to build / run / test

```bash
cd "/Users/xaviergallo/Documents/The Everything/DIY Apps/Apps/CardRunner"

# Build (Debug, no signing)
xcodebuild -project CardRunner.xcodeproj -scheme CardRunner -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -iE 'error:|BUILD SUCCEEDED|BUILD FAILED'

# Unit tests (33). MUST skip the UITests target — its runner hangs headless.
xcodebuild test -project CardRunner.xcodeproj -scheme CardRunner -destination 'platform=macOS' \
  -only-testing:CardRunnerTests -skip-testing:CardRunnerUITests \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -iE 'TEST SUCCEEDED|TEST FAILED'

# Smoke test (31) — runs the REAL shell + cardcopy against synthetic cards. The footage-safety gate.
./smoke_test.sh
```

**Running the real app (Xavier does this; do NOT screen-control unless asked):**
- Build, then **refresh the Desktop app and ad-hoc sign it** so it launches from Finder as a real foreground GUI app:
  ```bash
  SRC="/Users/xaviergallo/Library/Developer/Xcode/DerivedData/CardRunner-hbuwejbtuggdywgriapcyvzklrwt/Build/Products/Debug/CardRunner.app"
  DST="$HOME/Desktop/CardRunner.app"
  pkill -9 -f "MacOS/CardRunner"; rm -rf "$DST"; cp -R "$SRC" "$DST"
  codesign --force --deep --sign - "$DST"; xattr -dr com.apple.quarantine "$DST"
  ```
- Xavier **double-clicks `~/Desktop/CardRunner.app`**. DO NOT launch from a terminal — see gotchas §7.
- DerivedData hash `CardRunner-hbuwejbtuggdywgriapcyvzklrwt` has been stable; re-derive if it changes.

**Launch flags:** none needed for the v3 app. `CR_LEGACY_UI=1` = old UI escape hatch. `CR_V3_DEMO=1` = pure-sim demo (`CardRunnerV3View`, no engine — for design preview only).

---

## 3. Architecture — the graft (how the new UI sits on the proven engine)

`ContentView.swift` (~15.8k lines) is ONE giant `struct ContentView: View` holding ALL engine logic (`@State activeIngests: [UUID: ActiveIngest]`, `startIngest`, detection, `parseProgress`, history, presets) AND the UI. We did NOT extract a controller; instead:

- **`ContentView.body`**: `if CR_LEGACY_UI { legacyBody } else { ZStack { legacyBody.opacity(0).allowsHitTesting(false); bodyV3 } }`. The **legacy body stays mounted but invisible** so all its proven wiring keeps running: card detection (`didMount → scanForNewCardsAndIngest`), timers, the menu-notification handlers, and `.sheet`/`.alert` modifiers (which present OVER v3 from the window layer).
- **`bodyV3`** is an `extension ContentView` appended at the END of `ContentView.swift` (must be same file — it reads `private @State`). Pure presentation over the real `@State`; actions via direct `@State` mutation or the **menu-notification bus**.
- **Gotcha pattern:** any legacy *inline overlay* (not a `.sheet`/`.alert`) renders INVISIBLY under v3. We hit this with Settings, History, and Log — each fixed by rendering a v3 equivalent and gating the legacy copy behind `isLegacyUI`. **If a menu command "does nothing," this is almost always why.**
- **Menu/keyboard:** `CardRunnerCommands` (CardRunner.swift) posts NotificationCenter messages; `menuNotificationHandlers` (`.onReceive` on the always-mounted legacy body) handle them. So shortcuts fire regardless of which face is visible.

---

## 4. N-way destination routing (the big backend feature, DONE)

**Shell (`CardRunner.sh`):** `SECONDARY_ROOT` → `SECONDARY_ROOTS=()` (repeated `--secondary`). Mirror block is a per-dest loop; each mirror is safety-equivalent (atomic partial + inline verify). A failing mirror → `_failed_secondaries` → non-zero exit (`PHASE failed … mirror=N`), blocks auto-eject, and WITHHOLDS the manifest (deferred `record_ingested_global`, gated on primary AND all mirrors OK). **Also fixed a pre-existing bug: a failing mirror used to report success.** Single-dest path is byte-identical.

**Swift (`ContentView.swift`):** `struct Destination {id, path, name, isCustomFolder}` + persisted list (`pref_destinationsJSON` / `pref_defaultDestID` / `pref_routingMirror`), migrated from legacy `primarySSDPath`/`secondaryPath`/`customDestPath`. Per-card `destinationID`. **Pure `buildIngestArgs(_:)` (top-level, unit-tested)** — legacy single-dest args are byte-identical; mirror fan-out emits N `--secondary`, filtered to never mirror onto the primary or source card. `AwaitingCard` + `awaitingCards` = the "waiting to route" state; `startAwaiting`/`routeAwaiting` are the engine entry points the drag-node calls. SPLIT parallelism is free (each card already runs its own process w/ own dest device key).

---

## 5. Footage-safety core (the most important thing — hardened over 3 review rounds)

The promise: **never lose footage, never report a failed transfer as success, never let the operator think a failed card is safe to format.**

- **`evaluateIngestOutcome(exitStatus:ingest:)`** (top-level, unit-tested) is the SINGLE authoritative success/failure gate. `didFail = exitStatus != 0 || hasCopyError`.
- **`FailedIngestRecord`** (now has `volumeUUID`) is the PERSISTENT "do not format" warning (UserDefaults, survives relaunch). A failure ALWAYS writes one — mid-copy, early-abort (`newFiles==0`), cancel, OR even when `cardcopy` never launches (the `process.run()` catch).
- **`failureRecordsSurviving(...)`** (top-level, **unit-tested**, 5 tests) decides which records a success clears: ONLY on matching volume UUID, or (no UUID — FAT/exFAT camera cards) matching name AND a non-empty nickname. **NEVER on volume-name alone** (camera cards share "Untitled"/"NO NAME"). When in doubt, KEEP the record (operator dismisses manually).
- **v3 surfacing:** `v3FailureStrip` (top of Sources) renders the records with "DO NOT FORMAT" + dismiss; `v3RingCenter`/`v3RingStroke` check failure FIRST (keyed off `v3HasFailures = v3FailedCount>0 || !failedIngestRecords.isEmpty`) → "N need(s) attention · Do not format the card(s)".
- **`v3AllDone`** is gated on `failedIngestRecords.isEmpty && v3FailedCount == 0` → "All safe to pull" / green ring is IMPOSSIBLE while any failure exists, under any lane-cleanup order.
- ⚠️ When touching ANY of this, run the smoke test + the `failure*` unit tests. This is the area that has bitten us repeatedly.

---

## 6. The agent review loop (Xavier's preferred working mode)

Lead coder (you, in-context) implements; then spawn a **reviewer sub-agent** (`general-purpose`, read-only, NOT a worktree — review the main tree by absolute path / `git diff <range>`). It returns prioritized P0/P1/P2 findings; fix P0 (footage-safety) first; re-verify (build + unit + smoke); **resume the same reviewer via SendMessage (its `agentId`)** to confirm. Loop until it says production-ready. This caught every footage-safety bug in Tier 2 — keep using it.
**Worktree caveat:** isolated-worktree agents need the code to be COMMITTED first (they branch from a commit; uncommitted work is invisible to them). Two early worktree agents died this way before we committed the checkpoint.

---

## 7. Hard-won gotchas (do not re-debug these)

- **Launch from Finder, not a terminal.** Terminal-launched debug builds hit: (a) **SIGTTIN** — the ingest shell inherited the tty as stdin and got stopped on its first `read`. FIXED with `process.standardInput = FileHandle.nullDevice`. (b) **App Nap** Mach-suspended the ingest shell when the app was backgrounded → copy froze at 0%, `SIGCONT`-immune. FIXED with `ProcessInfo.beginActivity(.userInitiated)` per ingest (`ingestActivities`, ended on termination).
- **Funnel animation** used `TimelineView(.animation)` at 120fps forever → burned a whole core (327 CPU-min) → starved the ingest pipe. FIXED: 20fps and only while copying/dragging; static when idle.
- **A wedged SMB/NAS share** (`/Volumes/Projects`) froze launch — the volume scan does synchronous `contentsOfDirectory` on the MAIN thread. Environmental, but a real robustness gap → **off-main-thread volume scan is a TODO** (a flaky NAS shouldn't freeze the app on set).
- **UITests runner hangs headless** — always pass `-skip-testing:CardRunnerUITests`. The unit-test host can also hang in a degraded session (separate from the code); it cleared on its own after MCP reconnects.
- **Don't `defaults write` while the app runs** — it flushes @AppStorage on quit and clobbers your write. (We hit this turning off a leftover `pref_dryRun`.)

---

## 8. What's next (Tier 3 / open items)

- **New-design Settings screen.** The gear opens the EXACT original `settingsSheet` overlay — fully functional but visually the OLD design. This is the last visual seam. **Needs a mockup from Xavier** (no design exists yet).
- **Off-main-thread volume scan** (so a dead NAS can't freeze launch) — see §7.
- **Per-destination routing role.** The Add-destination sheet's "Additional vs Backup" wording implies per-drive roles, but the model is a single global `routingMirror` bool. Adding a Backup only ENABLES mirror (guarded to idle). Reconcile the model with the UI wording for true per-destination roles.
- **Photo-mode mixed-card hint** — mode is global; mixed photo/video cards in one session skip mismatched files (safe, counted in `skipWrongMode`), but a UI hint would help.
- Lower-priority from the old audit (`memory/audit-2026-06-25.md`): history/stats durability (UserDefaults-only), `--latest N` no-op, manifest exFAT-mtime key.
- **7-day failure-record expiry** (`loadFailedRecords`) — records auto-vanish after 7 days even un-acknowledged. Reviewer deemed it an acceptable retention window; revisit only if Xavier wants longer.

---

## 9. File map

| File | Role |
|---|---|
| `CardRunner/ContentView.swift` | EVERYTHING — engine + legacy UI + `bodyV3` (at end). Top-level pure fns: `buildIngestArgs`, `evaluateIngestOutcome`, `applyIngestProgressLine`, `canAdmitIngest`, `failureRecordsSurviving`. |
| `CardRunner/CardRunner.sh` | ~2.5k-line zsh ingest engine (scan/filter/manifest/copy/N-way mirror). |
| `cardcopy/cardcopy.c` + `CardRunner/cardcopy` | native copy engine (fcopyfile/clonefile, v1.2.0). |
| `CardRunner/CardRunner.swift` | `@main`; `CardRunnerCommands` (menu + keyboard shortcuts); launches `ContentView()` or `CardRunnerV3View()` (CR_V3_DEMO). |
| `CardRunner/V3/CardRunnerV3View.swift` + `V3Model.swift` | pure-SIM demo (CR_V3_DEMO) — design preview only, no engine. `V3SettingsView.swift`/`IngestEngine.swift` are TOMBSTONED (empty). |
| `CardRunnerTests/CardRunnerTests.swift` | 33 unit tests (Swift Testing + XCTest). |
| `smoke_test.sh` | 31 checks, real shell+cardcopy. Gated in `release.sh`. |

---

## 10. Commit history on `nway-rebuild` (recent)

```
a73dc48 Tier 2: close FAT-card failure-masking + launch-failure leak (+ regression tests)
f7d0cea Tier 2: close two failure-masking paths in the persistence layer (footage safety)
f7018ee Tier 2 review fixes: P0 persistent failure visibility, P1 dead shortcut + log banners
fbd60c3 Tier 2 (1/2): wire menu/keyboard into v3 — history, log, photo/video
4af0a6c Tier 1 P2 polish: lock-routing hint
0a1b3be Tier 1 review fixes: P0 history-status + routing-flip, P1 rename guard
0d74a26 Tier 1 in v3: history+stats, date-filter menu, verify menu, per-card naming
4410d60 Wire the gear to the real Settings panel in v3
4dd6700 Add v3-design Add-destination + New-project-folder sheets
f95074d Make the v3 node UI the default app face (CR_LEGACY_UI escapes to legacy)
2fdfa7b Fix transfer stalls: App-Nap suppression + funnel CPU runaway
a40b9b9 Fix: detach ingest shell from inherited terminal (SIGTTIN stop)
adf9e75 Phase 2: N-way per-card destination routing (Swift)
8561030 Checkpoint: CardRunner v3 node UI + shell N-way mirror (pre Phase-2 Swift)
```

## 11. Locked decisions (do not violate)
- Copy engine is `fcopyfile()`/clonefile only. No rsync/cp/fallback.
- Mac-only native Swift. No HTML/WebView UI (tried + scrapped).
- Keep the big center ring (app identity). v3 is dark-only (no light mode — ⇧⌘D is legacy-only).
- Routing: split is default, mirror opt-in. Plug a card → auto-route to default + auto-start (instant-ingest promise). "Blocked/waiting" only when no destination configured.
- Manual pull default; auto-eject opt-in. Footage safety > convenience.
- Don't screen-control / screenshot the running app unless Xavier asks — he runs it and reports back; verify via build + unit + smoke.
</content>
</invoke>
