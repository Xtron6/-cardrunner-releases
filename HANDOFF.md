# CardRunner — Session Handoff

**For:** the next coding agent / chat (context reset).
**Owner:** Xavier Gallo (maxmcfin@gmail.com). macOS SwiftUI app, **Mac-only**, direct-distribution (Sparkle, not App Store).
**Repo root:** `/Users/xaviergallo/Documents/The Everything/DIY Apps/Apps/CardRunner`
**Branch:** `nway-rebuild` (ALL work lives here; `main` is the original stub — do NOT branch off main).
**Latest commit:** `4252616` ("Bump to 1.8.0 (build 21)"). Working tree CLEAN (only the untracked `CardRunner-1.8.0.dmg` build artifact).

**🚢 SHIPPED — CardRunner 1.8.0 (build 21) released via Sparkle on 2026-07-02.** The whole `nway-rebuild` line (footage-confidence A–F + 6 hardware fixes + Swift-6 cleanup + VoiceOver) is now LIVE to users. Release pipeline: `./release.sh 1.8.0 "<pipe-separated notes>"` → smoke 40/40 + unit 68/68 + Release archive → DMG → **notarize → staple → EdDSA sign_update → appcast publish**. NOTE for next release: Apple pushed an updated **Developer Program License Agreement** (~June/WWDC) that 403-blocked notarization until the Account Holder accepted it at developer.apple.com/account — if notarization 403s "a required agreement is missing or has expired", that's the fix (not a code/credentials issue; `xcrun notarytool history --keychain-profile CardRunner-Notary` still works, proving it's the legal gate). Next version must bump `CURRENT_PROJECT_VERSION` above **21**. Hardware happy-path (new footage copies clean → VERIFIED → safe-to-pull) was validated by Xavier before ship. Still-deferred, NON-blocking: column-scroll P1 (design-sensitive, align w/ Xavier first), airtight-VERIFIED-badge P2 (chip `task_e836910d`).

**6th hardware finding → FIXED (`a844972`, reviewer no P0/P1):** the last vanish micro-gap — on the auto-ingest path a detected card was routed DIRECTLY, so it had no UI representation during the ~0.5–1s async scan and "appeared late" as a copying lane. New `routeKeepingVisible(_:destination:)` parks the card + flags it "Starting…" in one synchronous block (single render, no pop-in), then routes; `startIngest` hands off to the live lane atomically. Both auto-ingest detection sites + `drainAwaiting` (no longer removes up-front) use it. Now a card is visible continuously from detection → Starting… → copying → done. **5th hardware finding → FIXED (`0025697`, reviewer no P0/P1):** with Auto-Ingest ON, a 0-new run (wrong-mode / up-to-date / manifest-skip) removed its scanning lane and (per the newFiles>0 gate) made no `.done` tile → a still-mounted card VANISHED from SOURCES while its prompt sat there, reappearing only on the prompt's blue button. Fix: on a 0-new `!didFail` completion, re-park the still-mounted card via `enqueueAwaiting([card])` so a mounted card is ALWAYS visible; the lane-removal + re-park run in the SAME synchronous completion block (no await between) → atomic lane→awaiting transition, no vanish frame. Reviewer-confirmed: atomic, no re-route loop (seenCardPaths), no double-representation, footage-safe. **4th hardware finding → FIXED (`f3b3faa`, reviewer no P0/P1):** pressing Start removed the card from `awaitingCards` up-front, but the live lane isn't created until `startIngest` runs AFTER an async analyze/scan (sleeps ~0.5–1s) → during the gap the card was in NEITHER list and visibly VANISHED then respawned. Now the awaiting lane stays VISIBLE ("Scanning card…/Starting…" spinner, Start suppressed) through the scan and is handed off to the live lane ATOMICALLY at lane creation: new `v3StartingPaths: Set<String>` (re-entry guard), `startAwaiting` no longer removes up-front, `routeCardsForIngest` clears the guard on every outcome via a `defer`, `startIngest` removes the awaiting card by path exactly when `activeIngests[processID]` is created. Invariant: card shown exactly once, never in neither list. (Known P2, non-blocking: a same-drive-queued card can briefly show both queued + a startable Start button — self-healing, deduped.) **3rd hardware finding → FIXED (`d3fc257`, reviewer no P0/P1):** a 0-new-files run (already up-to-date / manifest-skip / wrong-mode / already-at-destination) still added the card to the green "safe to pull" pile, so every re-scan of the SAME physical card stacked another completion tile ("2 cards safe to pull" for one card that transferred nothing). Fix: the pile-retention guard is now `if !didFail && newFiles > 0` — a card joins the pile ONLY when it actually copied footage this run; 0-new runs still show their "Already up to date" alert but create no tile. (`newFiles==0 && !didFail` provably = zero footage moved, so this can't hide a real copy.) **2nd hardware finding → FIXED (`2a5ab73`, reviewer no P0/P1):** with **Auto-Eject ON**, the shell ejects the card around completion so the card-unmount races PAST the `.done` tile insert → the safe-to-pull tile lingers with a dead "Pull" button (card already gone). Fix: the done tile shows **"Pull"** (eject) only while the card is still mounted; if already gone it shows **"Dismiss"** (`v3DismissDoneCard` — removes the UI tile only, footage already verified-copied); the pile's "All" button (`v3PullAllDone`) ejects mounted + clears already-gone tiles and relabels to **"Clear"** when nothing's left to eject. `v3LaneBottom` now takes the lane id. The footage-confidence batch (A–F) is CERTIFIED PRODUCTION-READY (final reviewer no P0/P1 vs code AND shell; Debug+Release green; smoke 40/40). **✅ Unit tests confirmed 68/68 green via Xcode ⌘U** (closes the long-standing CLI-host-flaky validation gap). **Swift-6 warnings cleared** (`nonisolated` on the pure model types + 2 trivial fixes) — ⌘U is now warning-clean.

**★ FIRST REAL-HARDWARE FINDING → FIXED (`6e4bf0f`, reviewer no P0/P1):** Xavier hardware-tested in **Photo mode** with a **Fuji X100V** card of **video** clips. The engine did the RIGHT thing (matched=0 wrong_mode=3, nothing copied, nothing lost, card kept mounted) but the app said **"Already up to date"** — a footage-CONFIDENCE trap (user could pull the card thinking they're safe). Fix: a 0-new run whose only skip reason is wrong-mode now shows **"Nothing copied — wrong mode"** + one-tap **"Switch to Video/Photo & copy"** (flips `importMode`, re-ingests the still-mounted card); date-picker empty state is mode-aware; re-insert guards on the wrong-mode + manifest-reingest buttons. NOT a camera/date bug — Fuji dates parsed fine (`date_excluded=0`); the shell early-returns on 0-new BEFORE auto-eject so 0-copied runs keep the card mounted. **Immediate user workaround if seen again: flip the mode toggle Photo↔Video.** Remaining NON-blocking: column-scroll P1 (align w/ Xavier first), airtight-VERIFIED-badge P2 (chip `task_e836910d`).

**★ FOLLOW-ON UX/FEATURE BATCH (2026-07-02, `c260e50`→`dbd449b`, all reviewer-verified no P0/P1):** cards vertically centered on the ring (biased up); **New project folder** now lands at the SSD/**drive root** (+ "Change…" folder-picker override) AND becomes a routing **destination + default** (toggle `pref_newProjectSetsDefault`); name prefill = today's date in the settings format ending `_`; **reusable `.v3EditableField`** blue-glow (Add-dest Name, New-project Folder name, dest NAME hover pill, scaffold fields); color swatches hover grow+glow + selected checkmark; **F** opens the LIVE transfer folder (`v3LiveTransferFolder` — resolves the in-flight lane's routed dest, since `ActiveIngest.destPath` is empty until completion); **Enter** commits the single-purpose sheets (Add/Edit dest, Date range) via opt-in `.defaultAction` — NOT New Project (scaffold inline-field conflict); **every modal grows+fades in** (`v3PresentModal` wraps opens in withAnimation so `v3ModuleTransition` runs); Ingest History stats pinned top; **reimagined scaffold editor** `V3ScaffoldFolderEditor` (shared Settings + New-project — indented list, inline rename w/ blue glow, per-row +subfolder, cascade delete, add-root, per-project include checkmarks; structural edits update the GLOBAL template, checkmarks are project-local; fixed the old commit that clobbered the global scaffold list). DEV spawners: kept in Release behind the secret ⌥-click-version unlock (`22941a7`).

> Persistent project memory: `~/.claude/projects/-Users-xaviergallo-Documents-The-Everything-DIY-Apps-Apps-CardRunner/memory/`
> Read `MEMORY.md` (index) → `cardrunner-roadmap.md` (full chronology + locked decisions, newest entries first) → this file (fast snapshot) → `UI-future.md` (repo root; design North Star).

---

## 0. WHAT THE APP IS (30-second history)
CardRunner is a **camera-card offload tool** for video/photo shooters: plug an SD/CFexpress card and it copies footage to your SSD(s) **instantly and safely** — verified, never losing footage, never reporting a failed transfer as success. Core promise: *"armed and watching; auto-starts the instant a card is plugged in."*

- **Engine (unchanged, battle-tested):** `CardRunner.sh` (~2.5k-line zsh) drives `cardcopy` (native C, fcopyfile/clonefile — no rsync/cp fallback). Scan/filter, source-keyed **manifest** (never re-copy a card's clips), atomic-partial + inline verify, N-way `--secondary` mirror, broadcast-day date filtering, project scaffolding, Finder tags, rename templates, `--subfolder`, `--cardlabel`, `--ignore-manifest`.
- **The v3 node-dashboard IS the app** — the ONLY UI now (legacy fully deleted). Center **ring** (identity + aggregate progress), source **lanes** left, **destinations** right, glowing **funnel** connectors between. Per-card routing, drag-to-route, editable per-card folder names, safe-to-pull panel.

---

## 1. ★★ RESUME HERE (2026-07-02, mid-batch) — footage-confidence + flaws work

**ACTIVE GOAL (session Stop-hook, still in force):** *"run 2 agents (one reviewer, you = lead coder) in parallel to knock out all these fixes and confidence boosts. Work in a loop, fix then review, until production ready."* Plus Xavier's **#4 decision (DONE):** a completed card shows the celebration burst then **lives in the green "safe to pull" pile until the user ejects/pulls it** (card finishes → sits there ready for eject). Continue the fix→review loop until production-ready, then the hook auto-clears.

**FIRST THING: commit the uncommitted Batch D** (build-green, working tree, ContentView only). Suggested message:
```
Parity/polish: history detail, modal exclusion, reduce-motion, dead-code
- Ingest History rows show WHERE footage landed (dest breadcrumb) + a "Reveal"
  button (Finder) when the drive's mounted, and a skip-reason breakdown
  (v3HistoryDestLabel / v3SkipBreakdown) — data was already stored, just unshown.
- Only ONE modal open at a time: v3PresentModal closes any other before opening
  (History + Log could stack → two scrims + two Escape handlers).
- Awaiting-lane name-pill animations now respect Reduce Motion (v3Anim).
- Deleted 3 dead legacy folder-creation paths (createNewProjectFolder /
  applyCustomFolderColor / createCustomDestSubfolder) + 6 orphaned @State.
```

**WHERE THINGS STAND — a 3-agent AUDIT (footage-safety confidence · old-vs-new parity · general flaws) drove this batch.** Core finding: *the engine is trustworthy (real per-file SHA-256 verify on by default, single authoritative fail-gate, green impossible while any failure exists, card kept mounted on fail, pre-flight space check) — the gap was that the app COMPUTED a rich trustworthy result and SHOWED almost none of it.* Batches so far:

- **A — Completed cards live in the safe-to-pull pile** (`13e3cb6`, reviewer no-P0). Real completed cards were `removeValue`'d on completion so the per-card pile / "All safe to pull" ring / celebration were effectively DEV-only (`v3AllDone` already required `!activeIngests.isEmpty` — design INTENDED retention). Now: on `!didFail`, re-insert as `phase=.done` (`verified = verifyTransfer && newFiles>0`, `liveMBps=0`); `didUnmount` clears the tile by `sourcePath` when the card leaves; per-card `v3PullCard` ejects that card. **Ripple fix:** new `v3ActiveWork = activeIngests.filter{ $0.phase != .done }` backs the live aggregates (doneBytes/totalBytesNew/…/currentFileName/scheduler `runningDestDevices`/`v3AnyActive`/`v3CombinedMBps`/ring "engine running" count); `v3AllDone` gained `awaitingCards.isEmpty`. Done tile shows "✓ VERIFIED" badge + "N files · duration · avg MB/s" + collision-rename notice. New `ActiveIngest.verified`.
- **B — Surfaced computed-but-hidden signals** (`849a6f3`): low-disk warning on the copying lane (`ing.lowDiskWarning`); N-way **mirror confirmation** on the done tile ("→ primary + N mirrors ✓ all landed" — a `.done` card means all mirrors landed; new `ActiveIngest.mirrorCount`).
- **C — Silent errors + card-vanish** (`d8c6851`): the v3 UI had NO status bar so recoverable errors set `statusText` and were never shown. New `v3ShowToast(_:)` + a floating amber notice banner (pinned top, auto-dismiss). `startAwaiting` now guards `v3HasUsableDestination` → a card with no destination stays PARKED + toast instead of vanishing; the custom-dest-not-found / ingest-launch bails now toast.
- **D — parity/polish** (`bfd6436`, reviewer-clear): Ingest History rows show WHERE footage landed (dest breadcrumb) + "Reveal" (Finder) + skip-reason breakdown (`v3HistoryDestLabel`/`v3SkipBreakdown`); one-modal-at-a-time (`v3PresentModal` closes any other before opening); awaiting name-pill anims respect Reduce Motion; deleted 3 dead legacy folder-creation paths + 6 orphaned @State.
- **E — closed the reviewer's 2 residual silent-drop P1s + re-surfaced hidden signals** (`e67ea24`, reviewer-clear, Debug+Release green + smoke 40/40). A reviewer pass on C+D found the "card can't vanish without feedback" guarantee STILL had two holes: an awaiting card was consumed silently when the saved primary was UNMOUNTED or the project name was empty. Fix: `v3HasUsableDestination` now delegates to a reason-returning **`v3DestinationBlockReason`** that mirrors `routeCardsForIngest`'s resolution branches EXACTLY (SSD dest → resolvable project; legacy-primary → `selectedPrimary != nil` i.e. actually mounted, not just a non-empty saved path, + a project); `startAwaiting` keeps the card PARKED and toasts the specific reason; belt-and-suspenders `v3ShowToast` at the 3 routing bails for the guard-less auto-ingest/`drainAwaiting` path. Also shipped the parity/polish backlog: **B4/B5** live combined-speed `SparklineView` mounted below the ring (active copies only; plain Canvas, no TimelineView → no core-burn) + session "peak · avg MB/s" in the ring center (`v3SessionPeakMBps`/`v3SessionAvgMBps`); **B8** rename-template live preview under Settings ▸ Naming; **B9** "Report an Issue…" now in Settings ▸ About; **P2 unmounted-dest** OFFLINE badge on a dest whose drive ejected/folder moved (`v3DestOffline` = free-space cache `== "—"`, no new statting).

- **F — VoiceOver accessibility pass** (`74462db`): file had ZERO `.accessibilityLabel`s (icon-only buttons announced raw SF Symbol names). Labelled all 13 zero-text controls (`V3CloseButton`/`V3TileRemoveButton` structs, the 4 sheet-dismiss X's, preset edit/delete, scaffold rename/delete, clear-card-name, onboarding remove-folder, toast dismiss) + primary nav (gear→"Settings", clock→"Ingest history", settings-rail categories + `.isSelected` trait) + the ambiguous "All" eject ("Eject all cards that are safe to pull"). Footage-safety controls already had text labels ("Pull", review panel); remaining `.help()`-backed controls announce their tooltip. Purely additive — no logic touched.

**✅ CERTIFIED PRODUCTION-READY (2026-07-02, HEAD `74462db`).** A final holistic reviewer verified the whole batch (`fedea5d..HEAD`) against BOTH the SwiftUI code and the shell — **no P0/P1.** Footage-safety invariants confirmed: `.done` retention is failure-gated (`if !didFail`), `runningCount` decrements BEFORE the `.done` re-insert, `v3AllDone`/"All safe to pull" is unreachable while any lane is copying/finalizing/verifying or any failure/record exists (the added `awaitingCards.isEmpty` guard is a correct tightening), mirror-confirmation + ✓VERIFIED badge are truthful (shell emits `PHASE failed` non-zero on any mirror/verify failure → `.done` unreachable on failure), `didUnmount` cleanup is `.done`+sourcePath-scoped, `v3PullCard` is `!isBusy`-guarded, no core-burn/retain-cycle/main-thread-mutation regressions. Debug+Release build green, smoke 40/40.

**REMAINING (all NON-blocking — post-production-ready polish):**
- **Column scroll for many-card overflow** (auditor P1) — DEFERRED, design-sensitive: touches funnel anchors / `destFrames` / centering spacers; `SmoothScrollView` at ~9923. Rare (funnel caps at 6-8). The one item that can regress the ring/funnel geometry → **align with Xavier before touching.**
- **Airtight VERIFIED badge** (reviewer P2, spawned as a task chip `task_e836910d`): the badge reads live `@AppStorage verifyTransfer` at completion, not a per-ingest snapshot from launch — a mid-transfer toggle could mislabel the reassurance (NOT a safety hole; failed verify still can't reach `.done`). Snapshot `verifyTransfer` into `ActiveIngest` at launch.
- verify-wording ("spot-checked" vs actual SHA-256 — LOW; `statusText` isn't shown in v3 anymore except via the toast).

**⚠️ STILL XAVIER'S TO VALIDATE (automated review + smoke can't cover):** run **68/68 unit tests via Xcode ⌘U** (the CLI host is environmentally flaky — hand this to Xavier; logic core barely touched this batch), plus a hardware pass of the new signals on a REAL card: a completed card sits in the green pile until ejected; ✓VERIFIED + "N files·duration·MB/s" reconciliation; mirror-confirmation with a 2nd drive; low-disk + OFFLINE badges; a no-destination/unmounted-primary card PARKS + toasts instead of vanishing; VoiceOver reads the icon buttons.

**The three full audit reports (footage-safety-confidence, parity, general-flaws) were consumed live in this chat — their findings are captured above; re-run fresh audit agents if you want the raw detail.** All the audit's HIGH-impact items are DONE (A/B/C); what remains is MEDIUM/LOW polish.

---

## 1b. Prior state — original punch-list + follow-on UX batch (both RESOLVED, production-ready)

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
