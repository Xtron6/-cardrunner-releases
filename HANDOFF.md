# CardRunner — Session Handoff (2026-06-30, Tier 3)

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
- **Tier 3 — LARGELY COMPLETE, production-ready** (8 reviewer-verified commits; full chronology in `cardrunner-roadmap.md`). Highlights: fixed card detection when Auto-Ingest is OFF; FDA banner in v3; off-main free-space (dead-NAS freeze); same-source double-start guard; custom date range; photo mixed-card hint; max-concurrent control; **removed split/mirror → per-card routing only** (Xavier's call); preset quick-switch; dry-run reachable + safety banner; and the **per-card editable folder name** (`--cardlabel`) on every lane, editable mid-transfer with a footage-safe rename-at-completion. Only cosmetic seams remain (see §8).
- **Latest commit:** `9166f55` on `nway-rebuild`. Build + **44 unit** + **31 smoke** all green.

---

## 2. How to build / run / test

```bash
cd "/Users/xaviergallo/Documents/The Everything/DIY Apps/Apps/CardRunner"

# Build (Debug, no signing)
xcodebuild -project CardRunner.xcodeproj -scheme CardRunner -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -iE 'error:|BUILD SUCCEEDED|BUILD FAILED'

# Unit tests (44). MUST skip the UITests target — its runner hangs headless.
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

## 4. Destination routing — PER-CARD ONLY (Tier 3 simplified the model)

**Tier 3 change (Xavier's call):** the global Split/Mirror MODE and Additional/Backup roles were REMOVED. Each card copies only to the destination it's routed to (drag the node / cycle) or the default. There is no "mirror every card to all drives" mode anymore. `pref_routingMirror` and the v3RoutingToggle/v3JoinCard UI are gone.

**Shell (`CardRunner.sh`, unchanged):** still supports N-way `--secondary` (repeated). Each mirror is safety-equivalent (atomic partial + inline verify); a failing mirror → `_failed_secondaries` → non-zero exit, blocks auto-eject, WITHHOLDS the manifest. The Swift v3 flow just no longer EMITS extra `--secondary` (mirrorTargets is always empty for dest-list users). The **legacy dual-dest** path (`dualDestEnabled`/`secondaryPath`, Settings → Pro Tools, only for no-Destination-list users) still emits one `--secondary` and is untouched — but its toggle is now disabled when a Destination list exists (it would be inert).

**Swift (`ContentView.swift`):** `struct Destination {id, path, name, isCustomFolder}` + persisted list (`pref_destinationsJSON` / `pref_defaultDestID`), migrated from legacy `primarySSDPath`/`secondaryPath`/`customDestPath`. **Pure `buildIngestArgs(_:)` (top-level, unit-tested)** — legacy single-dest args byte-identical; `--secondary` still emitted when `mirrorTargets` is passed (legacy dual-dest + future per-card backup). `AwaitingCard` (now carries `customName` = the per-card `--cardlabel`) + `awaitingCards` = the "waiting to route" state; `startAwaiting`/`routeAwaiting` are the engine entry points the drag-node calls.

**Per-card folder name (`--cardlabel`, Tier 3):** each lane has an editable folder-name pill. Pre-filled per card; becomes `{project}/{date}/{name}/`. Plumbed via single-use `pendingCardLabels[card.path]` (consumed at commit, cleared on eject) → pure `resolveCardLabel`. Editable DURING transfer too — the folder is renamed at COMPLETION (`applyPendingFolderRename`, conflict-safe, post-process-exit; a live rename would split footage). Manifest dedups on SOURCE identity, so a renamed dest folder never breaks re-ingest.

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

## 8. What's next (Tier 3 tail — all COSMETIC, mostly Xavier-blocked)

The functional/footage-safety Tier 3 work is DONE (§1). What remains is visual polish:

- **New-design Settings screen.** The gear opens the EXACT original `settingsSheet` overlay — fully functional + every setting reachable, but visually the OLD design. This is the last real visual seam. **Needs a mockup from Xavier** (no design exists yet).
- **Restyle the engine-triggered sheets** — resume / wrong-clock / reel-picker / setup-wizard / support-bundle still render with the legacy look (they float over v3 from the window layer and work fine; only the styling is old).
- **Remove redundant legacy popovers** — the old new-project / custom-dest popovers (`~7825`/`7881`) are superseded by the v3 sheets and only render in the invisible legacy body. Dead under v3; safe to delete.

**RESOLVED in Tier 3 (was on this list):** off-main volume scan (done — free-space is now cached/off-main); per-destination routing role (resolved by REMOVING split/mirror → per-card only); photo-mode mixed-card hint (done); `--latest N` (dropped per Xavier); 7-day failure expiry (Xavier chose: keep 7 days). The dead ⌘⇧D was already gated to `isLegacyUI` (not a real gap).

**Reviewer P2s consciously deferred:** per-card subfolder prefill changes folder depth for the manual flow (deliberate — matches the design; clear the field for a flat card); stale `destination_path` column in the transfer-report CSV after a mid-transfer rename (cosmetic point-in-time record).

---

## 9. File map

| File | Role |
|---|---|
| `CardRunner/ContentView.swift` | EVERYTHING — engine + legacy UI + `bodyV3` (at end). Top-level pure fns: `buildIngestArgs`, `evaluateIngestOutcome`, `applyIngestProgressLine`, `canAdmitIngest`, `failureRecordsSurviving`, `cardIsAlreadyTracked` (awaiting dedup), `resolveCardLabel` (per-card `--cardlabel`). v3 free-space is cached + probed off-main (`refreshFreeSpaceCache`); per-card folder rename is `applyPendingFolderRename` (conflict-safe, post-exit). |
| `CardRunner/CardRunner.sh` | ~2.5k-line zsh ingest engine (scan/filter/manifest/copy/N-way mirror). |
| `cardcopy/cardcopy.c` + `CardRunner/cardcopy` | native copy engine (fcopyfile/clonefile, v1.2.0). |
| `CardRunner/CardRunner.swift` | `@main`; `CardRunnerCommands` (menu + keyboard shortcuts); launches `ContentView()` or `CardRunnerV3View()` (CR_V3_DEMO). |
| `CardRunner/V3/CardRunnerV3View.swift` + `V3Model.swift` | pure-SIM demo (CR_V3_DEMO) — design preview only, no engine. `V3SettingsView.swift`/`IngestEngine.swift` are TOMBSTONED (empty). |
| `CardRunnerTests/CardRunnerTests.swift` | 44 unit tests (Swift Testing + XCTest). |
| `smoke_test.sh` | 31 checks, real shell+cardcopy. Gated in `release.sh`. |

---

## 10. Commit history on `nway-rebuild` (recent)

```
9166f55 Per-card folder name editable during transfer + safe rename, Stage 2
6c95187 Per-card editable folder name on awaiting lanes (--cardlabel), Stage 1
6b3ea12 Tier 3: preset quick-switch, dry-run reachable+guarded, honest dual-dest toggle
7713ed5 Tier 3: remove split/mirror routing — per-card routing only
fa0dc29 Tier 3: custom date range, mixed-card hint, max-concurrent control
502586b Tier 3: FDA banner in v3, off-main free-space, same-source ingest guard
a9996a1 Fix card detection while Auto-Ingest is OFF (keep watching + re-surface)
611741b Handoff doc: current state (v3 is the app, Tier 1+2 production-ready)
a73dc48 Tier 2: close FAT-card failure-masking + launch-failure leak (+ regression tests)
f7d0cea Tier 2: close two failure-masking paths in the persistence layer (footage safety)
f7018ee Tier 2 review fixes: P0 persistent failure visibility, P1 dead shortcut + log banners
fbd60c3 Tier 2 (1/2): wire menu/keyboard into v3 — history, log, photo/video
0d74a26 Tier 1 in v3: history+stats, date-filter menu, verify menu, per-card naming
f95074d Make the v3 node UI the default app face (CR_LEGACY_UI escapes to legacy)
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
