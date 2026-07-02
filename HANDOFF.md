# CardRunner — Session Handoff

**For:** the next coding agent / chat (context reset).
**Owner:** Xavier Gallo (maxmcfin@gmail.com). macOS SwiftUI app, **Mac-only**, direct-distribution (Sparkle, not App Store).
**Repo root:** `/Users/xaviergallo/Documents/The Everything/DIY Apps/Apps/CardRunner`
**Branch:** `nway-rebuild` (ALL work lives here; `main` is the original stub — do NOT branch off main).
**Latest commit:** `54b1e4a`. Build + **68 unit** + **40 smoke** all green, tree clean.

> Persistent project memory: `~/.claude/projects/-Users-xaviergallo-Documents-The-Everything-DIY-Apps-Apps-CardRunner/memory/`
> Read `MEMORY.md` (index) → `cardrunner-roadmap.md` (full chronology + locked decisions, newest entries first) → this file (fast snapshot) → `UI-future.md` (repo root; design North Star).

---

## 0. WHAT THE APP IS (30-second history)
CardRunner is a **camera-card offload tool** for video/photo shooters: plug an SD/CFexpress card and it copies footage to your SSD(s) **instantly and safely** — verified, never losing footage, never reporting a failed transfer as success. Core promise: *"armed and watching; auto-starts the instant a card is plugged in."*

- **Engine (unchanged, battle-tested):** `CardRunner.sh` (~2.5k-line zsh) drives `cardcopy` (native C, fcopyfile/clonefile — no rsync/cp fallback). Scan/filter, source-keyed **manifest** (never re-copy a card's clips), atomic-partial + inline verify, N-way `--secondary` mirror, broadcast-day date filtering, project scaffolding, Finder tags, rename templates, `--subfolder`, `--cardlabel`, `--ignore-manifest`.
- **The v3 node-dashboard IS the app** — the ONLY UI now (legacy fully deleted). Center **ring** (identity + aggregate progress), source **lanes** left, **destinations** right, glowing **funnel** connectors between. Per-card routing, drag-to-route, editable per-card folder names, safe-to-pull panel.

---

## 1. ★ CURRENT STATE + PUNCH-LIST (the next tasks)

**The big overhaul is DONE and green:** legacy UI fully removed, v3 is the only face, footage-safety logic core extracted, and the mid-transfer / waiting-card / safe-to-pull UI redesigned to match Xavier's "dream" Claude-Design mockups. A full 3-agent audit (this session) found **no P0 / no footage-safety gaps**. Remaining items, prioritized:

### P1 — should fix / decide
1. **Funnel animates forever after a failure — core-burn (a real regression to fix).** `ContentView.swift` ~`12122`: the funnel-animation gate is `if runningCount > 0 || dragLine != nil || !v3ActiveLanes.isEmpty`. `v3ActiveLanes` includes `.failed` lanes (they linger in `activeIngests`), so after any failed transfer the 20fps `TimelineView` Canvas never stops → burns a core with nothing flowing (the exact thing the code is paranoid about). **Fix:** gate on IN-FLIGHT phases only — `v3ActiveLanes.contains { [.copying,.finalizing,.verifying,.scanning,.building].contains($0.phase) }` — so fake + real copies still animate but a purely-`.failed` residue doesn't. (The `|| !v3ActiveLanes.isEmpty` clause was added so DEV fake copying lanes animate; preserve that, just exclude failed/idle.)
2. **DEV fake-fixtures ship in RELEASE.** The DEV bar spawners (`+Card/Copy/Done/Fail/Clear`) + `v3DevSimulateIngest` are gated only by the *user-flippable* `debugMode` `@AppStorage` (Settings▸About▸Developer), NOT `#if DEBUG`. Footage-safe, but a release user could spawn phantom cards (they mutate `v3FailedCount`/`v3AllDone`/ring). **Decision for Xavier:** wrap them in `#if DEBUG`, or keep as "advanced, at your own risk."
3. **Stale celebration from the fake sim (cheap).** `v3DevSimulateIngest` sets `v3PendingCelebration=true`; if other lanes are active it isn't consumed and can fire later on a real batch. Fix: reset `v3PendingCelebration=false` in `v3DevClearFakeCards`, and/or don't arm it when non-fake lanes exist. Bundle with #2.
4. **Winter Olympics mode + code: UNREACHABLE.** Full engine feature (`CardRunner.sh:2448-2449`), plumbing + `@AppStorage("winterOlympicsMode")`/`pref_olympicsCode` (`ContentView.swift:1592-93`) + `buildIngestArgs` emission intact, but the ONLY UI died with the deleted legacy ProTools tab — now only settable via `defaults write`. **Decision:** re-expose a v3 toggle (Settings▸Naming or a "Pro" section) or delete the dead plumbing.
5. **`⌘⇧O` + destination readout use the LEGACY field.** `menuOpenDestination` (~`4418`) and `v3DestRoot` (~`12030`) read `selectedPrimary`/`primarySSDPath`, not the v3 `defaultDestination` — can open the wrong/no folder for a multi-destination user. (Copy path is correct; this is just the readout/Open-in-Finder.)

### P2 — cleanup / cosmetic
- Prune `--latest N` (intentionally dropped, but `latestCount` field + arg branch remain: `IngestLogic.swift:51`).
- Delete dead `updateCurrentPreset()` (0 callers) and the dead old `SettingsTab` enum (`ContentView.swift:217`).
- Dead `.failed` branch in the %-overlay (`~12160`, only rendered for copying/finalizing/verifying).
- **Restyle the 4 engine-triggered sheets to v3** (reel picker, resume, wrong-clock, About tab still use legacy `DM Sans` — functional, visually legacy). Known-open North-Star item.
- **Monolith split Stage 1b + 2** (see §3) — ContentView is still ~14.2k lines in one struct.

*(Optional/North-Star, not queued: the `UI-future.md` polish batch; a general Reduce-Motion pass.)*

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
