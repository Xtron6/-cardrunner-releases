# CardRunner — Session Handoff

**For:** the next coding agent / chat (context reset).
**Owner:** Xavier Gallo (maxmcfin@gmail.com). macOS SwiftUI app, **Mac-only**, direct-distribution (Sparkle, not App Store).
**Repo root:** `/Users/xaviergallo/Documents/The Everything/DIY Apps/Apps/CardRunner`
**Branch:** `nway-rebuild` (ALL work lives here; `main` is the original stub — do NOT branch off main).
**Latest commit:** `4953587`. Build + **68 unit** + **40 smoke** all green. (Legacy UI fully removed + logic core extracted + production-hardening pass — see §1.)

> Persistent project memory: `~/.claude/projects/-Users-xaviergallo-Documents-The-Everything-DIY-Apps-Apps-CardRunner/memory/`
> Read `MEMORY.md` (index) → `cardrunner-roadmap.md` (full chronology + locked decisions) → this file (fast snapshot) → `UI-future.md` (repo root; design North Star for later). The roadmap memory is the deepest record; skim its newest entries first.

---

## 0. WHAT THE APP IS (30-second history)

CardRunner is a **camera-card offload tool** for video/photo shooters: plug an SD/CFexpress card and it copies footage to your SSD(s) **instantly and safely** — verified, never losing footage, never reporting a failed transfer as success. Core promise: *"armed and watching; auto-starts the instant a card is plugged in."*

- **Engine (unchanged, battle-tested):** `CardRunner.sh` (~2.5k-line zsh) drives `cardcopy` (native C, fcopyfile/clonefile — no rsync/cp fallback). Scan/filter, source-keyed **manifest** (never re-copy a card's clips), atomic-partial + inline verify, N-way `--secondary` mirror, broadcast-day date filtering, project scaffolding, Finder tags, rename templates, `--subfolder`, `--cardlabel`, `--ignore-manifest`.
- **The v3 UI** is now the REAL app face: the node-based dashboard (center **ring** = identity + live progress; source **lanes** left; **destinations** right; funnel connectors between). Fully polished across many batches (liquid-glass, hover on every control, reorder-drag, completion celebration, onboarding).
- Proven on real hardware: 26-clip / 17.7 GB ingest at 227 MB/s, Status=OK.

---

## 1. ★ STATE + NEXT TASK — Legacy UI is GONE; monolith split started

**DONE this session (all on `nway-rebuild`, reviewer-verified, build+67 unit+40 smoke green throughout):**
- **Legacy UI FULLY REMOVED (2-phase migrate-then-delete).** P1 `8db09b7`: extracted ALL load-bearing wiring (card detection `didMount→scanForNewCardsAndIngest`, 30-s timers, menu bus, engine `.sheet`/`.alert`, license routing, preset-sync) out of the invisible legacy body into a shared **`appWiringHost`** mounted by `body`. P2 `fa02dac`: deleted the entire legacy visual layout + the `CR_LEGACY_UI` flag + `isLegacyUI`. **v3 is now the ONLY face.** Recovery: git tag **`legacy-ui-archive-8db09b7`** holds the full pre-deletion tree. Xavier validated detection/routing on hardware between phases. Reviewer caught 2 real bugs pre-commit (P1 preset-sync would revert v3 edits; P1 History/Log hotkeys became no-ops — both fixed).
- **Monolith split Stage 1a `c771d44`:** extracted the pure footage-safety logic core into **`IngestModels.swift`** (16 value types) + **`IngestLogic.swift`** (evaluateIngestOutcome/buildIngestArgs/applyIngestProgressLine/etc.). `ContentView.swift` 18,379 → **13,900** lines this session.

**★ NEXT (Xavier said "stop the split here for now" — resume when he wants):** continue the **monolith split**:
- **Stage 1b** — extract self-contained top-level UI component structs (V3 components, LicenseGateView, SetupWizardView, OnboardingView+helpers, particle/AnimationPreviewWidget, NewProjectPopover, MiniPillToggle, SparklineView, …) → flip `private`→`internal`. ~3–4k more lines out. LANDMINES (reviewer-vetted): shared `private` helpers like `Color(hex:)` must flip to internal in a PREP commit first; grep LicenseManager.swift/CardRunner.swift for name collisions; watch for a "self-contained" view capturing a ContentView method/private-state via closure.
- **Stage 2** — split `struct ContentView` itself across extension files → REQUIRES flipping its `private @State`/`private func`→`internal`. Stored property wrappers (@State/@AppStorage/@Namespace/@FocusState) MUST stay in the primary struct; only methods/computed vars move. Sequence: flip-access-only(green) → move-methods-per-file(green).
Full stage plan + landmines are in the roadmap memory. Extraction tool: `extract.py` (session scratchpad) — uses a COLUMN-0-CLOSER heuristic (combined `{[`/`}]` depth miscuts on brackets-in-strings — learned the hard way).

**Other deferred follow-ups:** v3 SSD dest with empty `projectFolder` falls back to global `projectName` on the footage path — ensure v3 Add/Edit-Dest always writes a non-empty projectFolder. Also (optional, not queued): Reduce-Motion pass; the `UI-future.md` polish batch.

**REVIEWER LOOP:** the persistent reviewer this session is agentId **`a42de25c083165fe4`** (has full context of the legacy removal + split). Resume it via SendMessage each round. (The old `a8671aecd45cdbc6a` was a prior-session process — dead.)

---

## 2. ★ WORKING PROCESS — READ THIS (changed this session)

### 2a. Build / run / test — Xavier now runs via Xcode (NEW)
**Xavier drives Xcode: he hits ⌘R to build + live-preview.** Do NOT resume the old "copy to Desktop + ad-hoc re-sign" refresh — we stopped it this session. Reasons: Xcode signs with a **stable dev identity**, so Full Disk Access + keychain permissions PERSIST (the ad-hoc re-sign each refresh changed the cdhash → macOS re-asked for FDA and re-prompted for the Mac password every launch — that churn is GONE with Xcode Run). The old SIGTTIN/App-Nap reasons for needing a Finder-launched app were fixed in code long ago, so Xcode Run works cleanly.

**Your job as the agent:** make code changes, then **compile-check + run tests** to keep green. Do NOT copy/sign the Desktop app anymore.

```bash
cd "/Users/xaviergallo/Documents/The Everything/DIY Apps/Apps/CardRunner"

# Build (Debug, no signing) — to VERIFY compilation
xcodebuild -project CardRunner.xcodeproj -scheme CardRunner -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -iE 'error:|BUILD SUCCEEDED|BUILD FAILED'

# Unit tests (67). MUST skip the UITests target — its runner hangs headless.
xcodebuild test -project CardRunner.xcodeproj -scheme CardRunner -destination 'platform=macOS' \
  -only-testing:CardRunnerTests -skip-testing:CardRunnerUITests \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -iE 'TEST SUCCEEDED|TEST FAILED'

# Smoke test (40) — runs the REAL shell + cardcopy against synthetic cards. The footage-safety gate.
./smoke_test.sh
```
⚠️ **FLAKY UNIT-TEST HOST:** the FIRST `xcodebuild test` after a build sometimes reports `** TEST FAILED **` with *"The test runner hung before establishing connection"* — an ENVIRONMENTAL degraded-session issue, NOT a code failure. Re-run; it passes. A REAL failure names the test (grep `recorded an issue`). The **smoke test is the real footage-safety gate** (runs via `/bin/zsh` directly).

### 2b. The agent review loop (Xavier's REQUIRED working mode)
Lead coder (you, in-context) implements; a **persistent reviewer sub-agent** (`general-purpose`, read-only, reviews the working-tree/committed `git diff` by absolute path) checks it. **Resume the SAME reviewer** via SendMessage each round: agentId **`a8671aecd45cdbc6a`** (has full session context). It returns prioritized P0/P1/P2; fix P0 (footage-safety) first; re-verify; loop until "no P0/P1" BEFORE (or right after) committing. For design-heavy tasks it does an **ASSESS/BRAINSTORM plan FIRST**, Xavier aligns on decisions, then the lead codes. This loop has caught a real footage-safety or migration bug in nearly every batch — **keep using it.** Commit in checkpoints; keep build+tests green.

**Xcode launch note for the agent:** DerivedData path (if you ever need the built app) is `~/Library/Developer/Xcode/DerivedData/CardRunner-hbuwejbtuggdywgriapcyvzklrwt/Build/Products/Debug/CardRunner.app` — but you shouldn't need it now that Xavier runs via Xcode.

---

## 3. Architecture — v3 UI on the proven engine (legacy removed)

`ContentView.swift` (~13.9k lines) is ONE giant `struct ContentView: View` holding ALL engine logic AND the UI. No separate controller. (Monolith split in progress — the pure logic core now lives in `IngestModels.swift`/`IngestLogic.swift`; see §1.)

- **`ContentView.body`:** now a single v3 ZStack — `ZStack { appWiringHost; bodyV3; licenseAndWelcomeOverlays; if showOnboarding { OnboardingView(...).zIndex(1000) } }.simultaneousGesture(focus-resign)`. NO more dual-body / `CR_LEGACY_UI` flag / `isLegacyUI` (all removed).
- **`appWiringHost`** = the shared, zero-size wiring host that carries ALL load-bearing NON-visual wiring: `mountAndEngineWiring` (didMount/didUnmount card detection + engine onChange), `bootAndLifecycleWiring` (launch boot, FDA re-probe, autoIngest/importMode, teardown, license.justActivated, shortcuts-help), `engineSheetsAndAlerts` (setup/preset/support/resume sheets + ingest/tier0/manifest alerts + date/reel pickers), `menuNotificationHandlers` (menu bus), `presetSyncWiring` (ingestOrder/finderTagEnabled active-preset sync). **This is where detection/timers/sheets/menu-bus live now** — not in any visual view.
- **`bodyV3`** (an `extension ContentView` at the END of the file — must be same file; reads `private @State`). Pure presentation over real `@State`; actions via direct `@State` mutation or the **menu-notification bus**.
- **Keyboard shortcuts:** the local monitor (`setupShortcutMonitor`→`handleShortcutAction`) routes History/Log to `showV3History`/`showV3Log` (mirrors the menu bus). Menu items in `CardRunner.swift` carry ⌘⇧H/⌘⇧G; the monitor's defaults are bare H/L — distinct, no collision.
- **Top-level PURE, unit-tested fns** (footage-safety + logic core — NOW in `IngestLogic.swift`): `buildIngestArgs`, `evaluateIngestOutcome`, `applyIngestProgressLine`, `canAdmitIngest`, `failureRecordsSurviving`, `cardIsAlreadyTracked`, `resolveCardLabel`, `resolveProjectFolder`, `deriveDestName` (+ `splitCamelCase`).

**Routing model:** PER-CARD only (split/mirror removed). Folder layout `{drive}/{project}/{subfolder|clips}/{date}/{cardlabel}/` — project+subfolder are per-**DESTINATION**, cardlabel per-**CARD**. Destinations are a persisted **LIST** (`pref_destinationsJSON`); default resolved by **ID** (`defaultDestIDString`), never by array index (so tile reordering is display-only + safe).

---

## 4. Footage-safety core (the most important thing)

Promise: **never lose footage, never report a failed transfer as success, never let the operator think a failed card is safe to format.**
- `evaluateIngestOutcome(exitStatus:ingest:)` = the SINGLE authoritative success/failure gate.
- `FailedIngestRecord` (persisted, has `volumeUUID`) = the "DO NOT FORMAT" warning; a failure ALWAYS writes one. `failureRecordsSurviving()` decides what a success clears (UUID match, or name+non-empty-nickname; NEVER name-alone). Surfaced by `v3FailureStrip` + failure-first ring. Green/all-done is IMPOSSIBLE while any failure exists.
- **Dry Run** = simulation, copies NOTHING; loud persistent `v3DryRunBanner`.
- **Manifest** (`~/Library/Application Support/CardRunner/manifests/{uuid}.tsv`) is SOURCE-keyed + destination-agnostic. `--ignore-manifest` deliberately re-copies (dest-exists check still prevents in-place overwrite).
- **Completion celebration** only fires on a REAL successful batch (`v3PendingCelebration` set only when `newFiles>0 && !dryRun`; `v3MaybeCelebrate` guards `!v3HasFailures/!dryRun`). NEVER on failure/dry-run/empty/launch. The onboarding DEMO is fully isolated (`runDemoIngest(fromOnboarding:)` touches ZERO real ingest state).
- ⚠️ When touching ANY of this, run the smoke test + the `failure*`/`outcome*` unit tests. When touching §1 (legacy removal), re-verify detection + failure surfacing on hardware.

---

## 5. What's been delivered (recent → older; all reviewer-verified no P0/P1)

- **Onboarding** ported to v3 + Stage-2 restyle (Saira headlines/system body, v3 palette+bg, editable scaffold list, compact toggle, "hello" page = DM Sans italic + v3 bg, 940pt centered column). **Footage-adjacent fix:** the onboarding demo no longer starts/cancels a REAL ingest. Screen-2 kept as the simple picker. Seeds the v3 default destination on complete via `migrateLegacyDestinations` when empty.
- **Funnel node lines color-coded** per lane (`v3LineColor` palette) — overlapping card→dest lines are traceable; a failed lane stays RED.
- **Completion celebration** (v3): one-shot neon burst on the ring, 6 styles (same rawValues, zero migration), Settings has a live "Play preview". No core-burn; reduce-motion honored.
- **UI polish batches 1-4:** name auto-spacing (camelCase/acronym, no connector-peel — it mangled real words); subfolder picker (real folders, keep "Default" sentinel → byte-identical args); project dropdown-only; always-visible amber routing line; center console single auto-ingest toggle; **liquid-glass** foundation (`.v3Hover()` on every control, `MiniPillToggle`, rounded modules, Escape+click-outside, `V3CloseButton` red-X); **dynamic drag** to reorder destinations + make-default gold pop; tile delete swipe-away; custom liquid-glass date dropdown; hover glows on top-bar (gear/history/preset).
- **Destination redesign** (Stages A-C): per-destination project/subfolder model + click-tile editor.
- Tiers 1-3 (history/stats, keyboard+menu wiring, footage-safety completion chain, N-way per-card routing) — complete.

---

## 6. Hard-won gotchas (do not re-debug)

- **Xcode Run is the workflow now** (§2a) — stable signing fixes FDA/keychain re-prompts. Don't reinstate the Desktop-copy refresh.
- **No always-on `TimelineView(.animation)`** — it once burned a whole core and starved the ingest pipe. Use one-shot `withAnimation` + delayed clear (like the sheen/celebration) or event-driven `.onHover`. Respect Reduce Motion.
- **Footage-safety STATUS must stay CALM** — never animate the active ring / "SAFE TO PULL" badge / failure strip (motion on status reads as instability). Decorate idle/ambient only.
- **Codable migration:** synthesized Codable THROWS on missing keys — adding a field to a persisted struct needs a custom `decodeIfPresent ?? default` decoder or it wipes saved data (bit us on `Destination`; there's a migration unit test — keep the pattern).
- **Flaky unit-test host** — re-run; smoke is the real gate.
- **`bodyV3` reads `private @State`** → must stay in the same file as ContentView (until the Stage-2 access-flip in §1).
- **Detection/timers/sheets/menu-bus now live in `appWiringHost`** (§3), not in any visual view. The legacy body is GONE (recover via tag `legacy-ui-archive-8db09b7`).
- **Moving code out of ContentView.swift:** use the column-0-closer extraction (top-level decls close with `}`/`]` at column 0); a `{[`/`}]`-depth counter miscuts on brackets inside string literals. Commit each extraction as its own green checkpoint (a first-attempt miscut corrupted the file mid-session).

---

## 7. File map

| File | Role |
|---|---|
| `CardRunner/ContentView.swift` | ~13.9k lines — engine methods + `appWiringHost` (§3) + `bodyV3` + v3 Settings + v3 sheets/lanes/tiles + onboarding (`OnboardingView`/`WelcomeCelebrationView`) + V3 components. NO legacy UI (removed). |
| `CardRunner/IngestModels.swift` | Pure ingest/data value types (Volume, Destination, ActiveIngest, IngestOutcome, FailedIngestRecord, …). Extracted Stage 1a. |
| `CardRunner/IngestLogic.swift` | Pure footage-safety logic core (evaluateIngestOutcome, buildIngestArgs, applyIngestProgressLine, canAdmitIngest, failureRecordsSurviving, deriveDestName, …). Extracted Stage 1a. Unit-tested. |
| `CardRunner/CardRunner.sh` | ~2.5k-line zsh ingest engine. |
| `cardcopy/cardcopy.c` + `CardRunner/cardcopy` | native copy engine (fcopyfile/clonefile). |
| `CardRunner/CardRunner.swift` | `@main`; `CardRunnerCommands` (menu + keyboard shortcuts). |
| `CardRunnerTests/CardRunnerTests.swift` | 67 unit tests (Swift Testing + XCTest). |
| `smoke_test.sh` | 40 checks, real shell+cardcopy. Gated in `release.sh`. |
| `UI-future.md` (repo root) | Design North Star for later polish (scrollbar, transitions, gradient borders, expandable rail, proximity scaling) — NOT queued. |
| `CardRunner/*.ttf/.otf` | `SairaItalic-ExtraBoldItalic` (wordmark + onboarding headlines), `DMSans-Regular`, `Tech Headlines Italic` (legacy only). ATSApplicationFontsPath=".". |

---

## 8. Locked decisions (do not violate)
- Copy engine is `fcopyfile()`/clonefile only. No rsync/cp/fallback.
- Mac-only native Swift. No HTML/WebView UI (tried + scrapped).
- Keep the big center ring (app identity). App is **dark-only** (light mode removed).
- Routing: **per-card only** (split/mirror removed). Plug a card → auto-route to default + auto-start when Auto-Ingest ON. Default resolves by **ID**; destination order is display-only.
- Manual pull default; auto-eject opt-in. Footage safety > convenience.
- Every footage-touching change goes through the lead+reviewer loop before commit. Don't screen-control the running app unless Xavier asks — he validates via Xcode Run.
- CARDRUNNER wordmark = Saira ExtraBold Italic. Destination auto-name = date-stripped + camelCase/acronym spacing (connectors lowercase, first word capitalized, ALL-CAPS acronyms preserved, NO connector un-gluing).
- v3 modules: rounded 22 glass, dismiss on outside-click + Escape (`v3ModalOverlay` + hidden `.cancelAction`). Settings toggles = `MiniPillToggle` (ON = brand blue→purple). Every control uses `.v3Hover()`.
- **Workflow (this session):** Xavier runs via **Xcode ⌘R**; agent compile-checks + runs tests but does NOT copy/sign the Desktop app.
