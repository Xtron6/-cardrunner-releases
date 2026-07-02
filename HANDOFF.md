# CardRunner — Session Handoff

**For:** the next coding agent / chat (context reset).
**Owner:** Xavier Gallo (maxmcfin@gmail.com). macOS SwiftUI app, **Mac-only**, direct-distribution (Sparkle, not App Store).
**Repo root:** `/Users/xaviergallo/Documents/The Everything/DIY Apps/Apps/CardRunner`
**Branch:** `nway-rebuild` (ALL work lives here; `main` is the original stub — do NOT branch off main).
**Latest commit:** `dbd449b`. Build (Debug+Release) + **40 smoke** green, tree clean. The original §1 punch-list AND a follow-on UX/feature batch are **RESOLVED**; final reviewers certified **PRODUCTION-READY** (no P0/P1). **68 unit + 40 smoke green** (the CLI unit host was intermittently wedged with "runner hung before establishing connection" — a `pkill testmanagerd` + ~14s settle then re-run cleared it; see [[cardrunner-unit-host-wedge]]).

**★ FOLLOW-ON UX/FEATURE BATCH (2026-07-02, `c260e50`→`dbd449b`, all reviewer-verified no P0/P1):** cards vertically centered on the ring (biased up); **New project folder** now lands at the SSD/**drive root** (+ "Change…" folder-picker override) AND becomes a routing **destination + default** (toggle `pref_newProjectSetsDefault`); name prefill = today's date in the settings format ending `_`; **reusable `.v3EditableField`** blue-glow (Add-dest Name, New-project Folder name, dest NAME hover pill, scaffold fields); color swatches hover grow+glow + selected checkmark; **F** opens the LIVE transfer folder (`v3LiveTransferFolder` — resolves the in-flight lane's routed dest, since `ActiveIngest.destPath` is empty until completion); **Enter** commits the single-purpose sheets (Add/Edit dest, Date range) via opt-in `.defaultAction` — NOT New Project (scaffold inline-field conflict); **every modal grows+fades in** (`v3PresentModal` wraps opens in withAnimation so `v3ModuleTransition` runs); Ingest History stats pinned top; **reimagined scaffold editor** `V3ScaffoldFolderEditor` (shared Settings + New-project — indented list, inline rename w/ blue glow, per-row +subfolder, cascade delete, add-root, per-project include checkmarks; structural edits update the GLOBAL template, checkmarks are project-local; fixed the old commit that clobbered the global scaffold list). DEV spawners: kept in Release behind the secret ⌥-click-version unlock (`22941a7`).

> Persistent project memory: `~/.claude/projects/-Users-xaviergallo-Documents-The-Everything-DIY-Apps-Apps-CardRunner/memory/`
> Read `MEMORY.md` (index) → `cardrunner-roadmap.md` (full chronology + locked decisions, newest entries first) → this file (fast snapshot) → `UI-future.md` (repo root; design North Star).

---

## 0. WHAT THE APP IS (30-second history)
CardRunner is a **camera-card offload tool** for video/photo shooters: plug an SD/CFexpress card and it copies footage to your SSD(s) **instantly and safely** — verified, never losing footage, never reporting a failed transfer as success. Core promise: *"armed and watching; auto-starts the instant a card is plugged in."*

- **Engine (unchanged, battle-tested):** `CardRunner.sh` (~2.5k-line zsh) drives `cardcopy` (native C, fcopyfile/clonefile — no rsync/cp fallback). Scan/filter, source-keyed **manifest** (never re-copy a card's clips), atomic-partial + inline verify, N-way `--secondary` mirror, broadcast-day date filtering, project scaffolding, Finder tags, rename templates, `--subfolder`, `--cardlabel`, `--ignore-manifest`.
- **The v3 node-dashboard IS the app** — the ONLY UI now (legacy fully deleted). Center **ring** (identity + aggregate progress), source **lanes** left, **destinations** right, glowing **funnel** connectors between. Per-card routing, drag-to-route, editable per-card folder names, safe-to-pull panel.

---

## 1. ★ CURRENT STATE — PUNCH-LIST RESOLVED, PRODUCTION-READY (pending Xavier's hardware/unit sign-off)

**The entire §1 punch-list is DONE** (5 commits on `2df488b` → `fedea5d`), delivered by a 3-agent team (planner + reviewer + lead) and certified **PRODUCTION-READY by 3 independent final reviewer passes** (footage-safety lens, release-readiness lens, holistic lens) — no P0/P1. See the roadmap memory top entry for the full blow-by-blow.

### What shipped
- **P1-1** funnel core-burn: gate narrowed to `v3FunnelFlowing` (in-flight phases only) at ~`12186`. (Auditor note: real failures are always removed from `activeIngests`, so this was DEV-fixture-reachable-only — fix still correct.)
- **P1-2/3** DEV fake-fixtures: Xavier WANTS the spawners in the shipped build, so they stay compiled into Release but are hidden behind a **secret unlock** — ⌥-click the version number in Settings ▸ About (`v3ToggleDevUnlock`) toggles `debugMode`; there is NO visible "Debug mode" toggle any more, so a normal user can't reach the DEV bar. (Superseded the initial `#if DEBUG` compile-out, commit `22941a7`.) `v3DevClearFakeCards` resets `v3PendingCelebration`. Fakes remain footage-safe (tagged `/dev/cardrunner-fake/`, never call the shell). **Release build is still a must-pass gate** and is green.
- **P1-4** Winter Olympics RE-EXPOSED: "BROADCAST — WINTER OLYMPICS" section in `v3SettingsNaming` (toggle + uppercased/trimmed day-code field).
- **P1-5** `menuOpenDestination` (⌘⇧O + the ring's "Open in Finder" — same notification, a 3rd site the old list missed) → `defaultDestination?.path`; new `v3LaneDestName(_:)` for per-lane "→ Drive" labels. `v3DestRoot`/`v3DestDrivePath` kept (they back the legacy no-dest golden box).
- **P2:** `--latest` pruned (shell flag kept for back-compat); `SettingsTab` deep-link bug fixed (writers → `v3SettingsCat`) then enum deleted; dead `.failed` %-overlay branch removed. (`updateCurrentPreset` was already gone.)
- **UI sweep (restrained, "ship 1-3"):** Reduce Motion now honored (`v3Anim`/`v3ModuleTransition` + hover/swoosh/module/pop gates); log-panel **jump-to-tail + edge-fade** (North Star #1, event-driven); typography unified (97 DM Sans + 1 DM Mono → SF).

### ⚠️ Still Xavier's to validate (automated review + smoke can't cover these)
1. **68/68 unit tests via Xcode ⌘U** — the CLI host was environmentally wedged this session (runner-hung ×7, never a named failure). Logic core barely touched (only the `--latest` field).
2. **Funnel calm-after-failure (P1-1)** — trigger a real failed transfer; confirm via Activity Monitor the funnel Canvas stops redrawing (no pegged core), the red connector stays a static frame, and the failure strip surfaces.
3. **Secret DEV unlock** — in Settings ▸ About, ⌥-click the version number; confirm the DEV bar (+Card/Copy/Done/Fail/Clear + Show-Log + Dry-Run) appears and ⌥-clicking again (or "Hide developer tools") hides it. Confirm a normal click does nothing and there's no visible Debug-mode toggle.
4. **Winter Olympics (P1-4)** — toggle on, set a day code, run a real ingest; confirm competition-day folders + `--olympics-code` reaches the engine (support bundle reports it).
5. **⌘⇧O + multi-dest readout (P1-5)** — with 2+ destinations and a non-default default, ⌘⇧O opens the *default* dest and each lane's "→ Drive" names its *own* routed dest.
6. **Reduce Motion** — enable it in System Settings ▸ Accessibility; UI still reads reactive (glow/brightness) without motion travel.

### Deferred (NOT queued — per UI-future.md restraint + Xavier's standing calls)
- North-Star polish follow-ups: origin-aware blur-in module transitions; golden-box gradient sweep; edge-fade on History/Settings; expandable settings rail; **proximity scaling** (the one item that can regress core-burn).
- **Monolith split Stage 1b + 2** (see §3) — ContentView ~14.2k lines; Xavier said "stop for now".
- Orphaned `DMSans-Regular.ttf` bundled asset (has a pbxproj ref → remove via Xcode drag-to-trash, not CLI).

---

## 2. ★ WORKING PROCESS — READ THIS
### 2a. Build / run / test — Xavier runs via Xcode ⌘R
**Xavier drives Xcode: ⌘R to build + live-preview** (stable dev signing → Full Disk Access + keychain persist; the old ad-hoc-resign churn is GONE — do NOT reinstate the Desktop-copy refresh). **Your job:** make changes, then compile-check + run tests to keep green. Do NOT copy/sign a Desktop app.

```bash
cd "/Users/xaviergallo/Documents/The Everything/DIY Apps/Apps/CardRunner"

# Build (verify compilation)
xcodebuild -project CardRunner.xcodeproj -scheme CardRunner -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -iE 'error:|BUILD SUCCEEDED|BUILD FAILED'

# Unit tests (68). MUST skip the UITests target — its runner hangs headless.
xcodebuild test -project CardRunner.xcodeproj -scheme CardRunner -destination 'platform=macOS' \
  -only-testing:CardRunnerTests -skip-testing:CardRunnerUITests \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -iE 'TEST SUCCEEDED|TEST FAILED'

# Smoke test (40) — real shell + cardcopy against synthetic cards. The footage-safety gate.
./smoke_test.sh
```
⚠️ **Flaky unit-test host:** the FIRST `xcodebuild test` after a build sometimes reports `TEST FAILED` "runner hung before establishing connection" — ENVIRONMENTAL, re-run. A REAL failure names the test (grep `recorded an issue`). Smoke is the real footage-safety gate.

### 2b. The agent review loop (Xavier's REQUIRED mode)
Lead coder (you, in-context) implements; a **persistent reviewer sub-agent** (`general-purpose`, read-only, reviews the `git diff` by absolute path) checks it. It returns P0/P1/P2; fix P0 (footage-safety) first; loop until "no P0/P1" before/right-after commit. For design-heavy tasks it does an ASSESS/plan FIRST, Xavier aligns, then you code. This loop has caught a real footage-safety/regression bug in nearly every batch — **keep using it.** (Agent IDs don't survive a chat reset — spawn a fresh reviewer and brief it from this doc + the roadmap memory.)

### 2c. DEV tooling for hardware-free UI testing (built this session)
The **DEV bar** (Settings▸About▸Developer → Debug Mode ON) has fake-fixture spawners so you can preview the whole UI with NO card: **+Card** (waiting gold tile), **+Copy** (in-progress lane, %-on-line + COPYING/FLUSHING/VERIFYING), **+Done** (safe-to-pull), **+Fail** (failed lane), **Clear** (removes only fakes). Clicking **Start** on a fake card runs a **simulated transfer** (copying→flushing→done) — display-only, never touches the shell/real state. All fakes are tagged `sourcePath = "/dev/cardrunner-fake/…"`. (See P1 #2/#3 for the release-gating decision.)

---

## 3. Architecture — v3 on the proven engine (legacy removed)
`ContentView.swift` (~14.2k lines) is ONE giant `struct ContentView: View` holding ALL engine logic AND the v3 UI. The pure logic core was extracted (monolith split Stage 1a).

- **`ContentView.body`** = a single v3 ZStack: `appWiringHost` + `bodyV3` + `licenseAndWelcomeOverlays` + onboarding + a global focus-resign gesture. No more dual-body / `CR_LEGACY_UI` flag / `isLegacyUI` (all deleted). Recovery tag `legacy-ui-archive-8db09b7` has the full pre-deletion tree.
- **`appWiringHost`** = zero-size shared host carrying ALL load-bearing NON-visual wiring: `mountAndEngineWiring` (didMount/didUnmount detection + engine onChange), `bootAndLifecycleWiring` (launch boot, FDA re-probe, autoIngest/importMode, license routing), `engineSheetsAndAlerts` (setup/preset/support/resume sheets + ingest/tier0/manifest alerts + date/reel pickers), `menuNotificationHandlers` (menu bus), `presetSyncWiring` (ingestOrder/finderTagEnabled active-preset sync). Detection/timers/sheets live HERE, not in any visual view.
- **`bodyV3`** (an `extension ContentView` — must stay same file; reads `private @State`). Pure presentation. Key views: `v3AwaitingLane` (waiting gold tile), `v3Lane` (active/copying lane), `v3DonePile` (safe-to-pull panel), `v3Ring` (center ring + funnel), `v3DrawFunnel` (Canvas connectors), `v3Sources`/`v3Destinations`, `v3SettingsView` (icon-rail + `V3SettingsCat` tabs).
- **`IngestLogic.swift` / `IngestModels.swift`** = the pure, unit-tested footage-safety core (see §4), extracted from ContentView. `buildIngestArgs` is the SINGLE shell-arg choke-point.
- **Reusable UI:** `.swooshSelection(...)` (liquid matched-geometry selection pill — settings rail + segmented tabs + onboarding), `.v3GlowCard(tint:…)` (tinted fill + static outer glow), `.v3Hover(...)`.

**Remaining monolith split (deferred, Xavier said "stop for now"):** *Stage 1b* — extract self-contained top-level view structs (LicenseGateView, SetupWizardView, OnboardingView, V3 components, etc.) → flip their `private`→`internal`; LANDMINES: shared `private` helpers like `Color(hex:)` must flip in a PREP commit first; grep LicenseManager.swift/CardRunner.swift for name collisions. *Stage 2* — split `struct ContentView` across extension files → REQUIRES flipping its `private @State`/`private func`→`internal`; stored property wrappers MUST stay in the primary struct (extensions can't add stored props); sequence flip-access-only(green) → move-methods-per-file(green).

**Routing model:** PER-CARD only. Folder `{drive}/{project}/{subfolder|clips}/{date}/{cardlabel}/` — project+subfolder per-DESTINATION, cardlabel per-CARD. Destinations are a persisted LIST (`pref_destinationsJSON`); default resolved by ID (`defaultDestIDString`), never array index. `--project` uses the RESOLVED per-dest project (fixed this session — was global `projectName`, which drifted). A legacy single-dest fallback branch in `startIngest` fires only when the destinations list is empty (still load-bearing — do not delete).

---

## 4. Footage-safety core (the most important thing) — now in `IngestLogic.swift`
Promise: **never lose footage, never report a failed transfer as success, never let the operator think a failed card is safe to format.**
- `evaluateIngestOutcome(exitStatus:ingest:)` = the SINGLE authoritative success/failure gate.
- `FailedIngestRecord` (persisted, has `volumeUUID`) = the "DO NOT FORMAT" warning; a failure ALWAYS writes one. `failureRecordsSurviving()` decides what a success clears (UUID match, or name+non-empty-nickname; NEVER name-alone). Surfaced by `v3FailureStrip` + failure-first ring. Green/all-done is IMPOSSIBLE while any failure exists (`v3AllDone` requires `failedIngestRecords.isEmpty && v3FailedCount == 0`).
- **Dry Run** = simulation, copies NOTHING; loud `v3DryRunBanner`.
- **Manifest** (`~/Library/Application Support/CardRunner/manifests/{uuid}.tsv`) is SOURCE-keyed + destination-agnostic. `--ignore-manifest` deliberately re-copies.
- Completion celebration only fires on a REAL successful batch (`v3PendingCelebration` set only when `newFiles>0 && !dryRun`; consumed by `v3MaybeCelebrate` guarding `!v3HasFailures/!dryRun`). Onboarding demo + DEV fakes are isolated from real ingest state.
- ⚠️ When touching ANY of this, run the smoke test + the `failure*`/`outcome*`/`buildArgs*` unit tests. Verify detection + failure surfacing on hardware after UI-host changes.

---

## 5. What's been delivered (this overhaul, newest → older; all reviewer-verified)
- **Mid-transfer redesign:** per-lane `%` rides on the connector line (colored to match), top-right box is a live status capsule (COPYING/FLUSHING/VERIFYING), detail line shows "Transferring N of M · MB/s", **glowing neon funnel lines** (layered strokes, no blur — cheap at 20fps). (`fa78f6a`, `0e0d65b`, `54b1e4a`)
- **Waiting-card + safe-to-pull redesign** to match the dream: amber glow tile (`.v3GlowCard`), neutral SD chip, inline icon·name·CHOOSE-DEST row, "Name the folder, then Start"; the "N cards safe to pull" panel is a tappable green review card (expands to per-card Pull rows) + separate "All" eject. (`b8c8e9f`, `a21ae96`)
- **Liquid "swoosh" selection indicator** (`.swooshSelection`) on the settings rail + SSD/Custom + Date-range/Single-day + onboarding SSD/Custom tabs. (`b49b5a2`, `e7c28f2`)
- **Production-hardening:** tier-0 "Ingest all" date-filter loop fixed (`bf8adab`); project-routing display-vs-copy drift fixed (`4953587`); legacy `ssdProjectMap` cluster pruned.
- **Monolith split Stage 1a:** logic core → `IngestModels.swift` + `IngestLogic.swift` (`c771d44`).
- **Legacy UI fully removed:** P1 wiring→host (`8db09b7`), P2 delete visual layout + flag (`fa02dac`).
- **DEV fake-fixture tooling** (§2c).
- Earlier: onboarding ported+restyled to v3, completion celebration, destination redesign, N-way per-card routing, Tiers 1-3.

---

## 6. Hard-won gotchas (do not re-debug)
- **No always-on `TimelineView(.animation)`** — it once burned a core and starved the ingest pipe. The funnel Canvas is gated + 20fps-capped; glows are STATIC shadows / layered strokes (never animated). **← P1 #1 is a violation to fix.** Respect Reduce Motion.
- **Footage-safety STATUS must stay CALM** — never animate the active ring / "SAFE TO PULL" / failure strip.
- **Codable migration:** synthesized Codable THROWS on missing keys — a new field on a persisted struct needs a `decodeIfPresent ?? default` decoder (Destination/IngestPreset/IngestHistoryEntry all do this; keep the pattern + the migration unit test).
- **`bodyV3` reads `private @State`** → must stay in the same file as ContentView until the Stage-2 access-flip.
- **Moving code out of ContentView.swift:** use a COLUMN-0-CLOSER extraction (top-level decls close with `}`/`]` at column 0); a `{[`/`}]`-depth counter miscuts on brackets inside string literals. Commit each extraction as its own green checkpoint.
- **Xcode 16 synchronized groups** — new `.swift` files in `CardRunner/` auto-include; no `.pbxproj` edit needed.
- **DEV fakes** are tagged `/dev/cardrunner-fake/`; they never call the shell/startIngest. Keep that invariant.

---

## 7. File map
| File | Role |
|---|---|
| `CardRunner/ContentView.swift` | ~14.2k lines — engine methods + `appWiringHost` + `bodyV3` (all v3 views) + v3 Settings + onboarding + V3 components + DEV fixtures. |
| `CardRunner/IngestModels.swift` | Pure ingest/data value types (Volume, Destination, AwaitingCard, ActiveIngest, IngestOutcome, FailedIngestRecord, QueuedIngest, …). |
| `CardRunner/IngestLogic.swift` | Pure footage-safety logic core: `evaluateIngestOutcome`, `buildIngestArgs`, `applyIngestProgressLine`, `canAdmitIngest`, `failureRecordsSurviving`, `deriveDestName`, … Unit-tested. |
| `CardRunner/CardRunner.sh` | ~2.5k-line zsh ingest engine (the flag surface). |
| `cardcopy/cardcopy.c` + `CardRunner/cardcopy` | native copy engine (fcopyfile/clonefile). |
| `CardRunner/CardRunner.swift` | `@main`; `CardRunnerCommands` (menu + keyboard shortcuts). Debug menu gated to `CR_V3_PREVIEW=1`. |
| `CardRunner/LicenseManager.swift` | licensing. |
| `CardRunnerTests/CardRunnerTests.swift` | 68 unit tests (Swift Testing + XCTest). |
| `smoke_test.sh` | 40 checks, real shell+cardcopy. Gated in `release.sh`. |
| `UI-future.md` (repo root) | Design North Star (scrollbar, transitions, gradient borders, expandable rail, proximity scaling) — NOT queued. |
| `CardRunner/*.ttf/.otf` | `SairaItalic-ExtraBoldItalic` (wordmark/headlines), `DMSans-Regular`, `Tech Headlines Italic` (only in the not-yet-restyled engine sheets). |

---

## 8. Locked decisions (do not violate)
- Copy engine is `fcopyfile()`/clonefile only. No rsync/cp/fallback.
- Mac-only native Swift. No HTML/WebView UI. Dark-only. Keep the big center ring (app identity).
- Routing: **per-card only** (split/mirror removed). Plug → auto-route to default + auto-start when Auto-Ingest ON. Default resolves by ID; dest order is display-only.
- Manual pull default; auto-eject opt-in. Footage safety > convenience.
- Every footage-touching change goes through the lead+reviewer loop before commit. Don't screen-control the running app — Xavier validates via Xcode ⌘R.
- CARDRUNNER wordmark = Saira ExtraBold Italic. Destination auto-name = date-stripped + camelCase/acronym spacing.
- v3 modules: rounded-22 glass, dismiss on outside-click + Escape. Settings toggles = `MiniPillToggle`. Every control uses `.v3Hover()`. Selection sliders use `.swooshSelection`. Active/waiting tiles use `.v3GlowCard`.
- Workflow: Xavier runs via **Xcode ⌘R**; agent compile-checks + runs tests, does NOT copy/sign a Desktop app.
