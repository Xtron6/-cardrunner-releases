# CardRunner — Session Handoff

**For:** the next coding agent / chat (context is filling up).
**Owner:** Xavier Gallo (maxmcfin@gmail.com). macOS SwiftUI app, **Mac-only**, direct-distribution (Sparkle, not App Store).
**Repo root:** `/Users/xaviergallo/Documents/The Everything/DIY Apps/Apps/CardRunner`
**Branch:** `nway-rebuild` (ALL work lives here; `main` is the original stub — do NOT branch off main).
**Latest commit:** `dda08df`. Build + **~62 unit** + **37 smoke** all green.

> Persistent project memory: `~/.claude/projects/-Users-xaviergallo-Documents-The-Everything-DIY-Apps-Apps-CardRunner/memory/`
> Read `MEMORY.md` + `cardrunner-roadmap.md` first — they hold the full chronology + locked decisions. This file is the fast snapshot.

---

## 0. WHAT THE APP IS (30-second history)

CardRunner is a **camera-card offload tool** for video/photo shooters: plug an SD/CFexpress card, and it copies the footage to your SSD(s) **instantly and safely** — verified, never losing footage, never reporting a failed transfer as success. The core promise: *"armed and watching; auto-starts the instant a card is plugged in."*

- **The engine is unchanged and battle-tested:** `CardRunner.sh` (~2.5k-line zsh) drives `cardcopy` (native C, fcopyfile/clonefile — no rsync/cp fallback). It handles scan/filter, a source-keyed **manifest** (never re-copy the same card's clips), atomic-partial + inline verify, N-way `--secondary` mirror, broadcast-day date filtering, project scaffolding, Finder tags, rename templates.
- **The UI was rebuilt** into the "v3" node-based dashboard (the big center **ring** = app identity + live progress; source **lanes** on the left; **destinations** on the right; funnel connectors between). v3 is now the **default app face**; the legacy UI is an escape hatch (`CR_LEGACY_UI=1`).
- **Proven on real hardware:** a 26-clip / 17.7 GB ingest at 227 MB/s, Status=OK.

Tiers 1–3 (history/stats, keyboard+menu wiring, footage-safety completion chain, N-way per-card routing, and a large batch of v3 parity/polish) are **complete and reviewer-verified**. See §6 for the recent feature list.

---

## 1. ★ ACTIVE WORK — Destination selection/refinement redesign (IN PROGRESS)

This is the live task. Design-first: a reviewer sub-agent proposed the design, Xavier aligned on the decisions, then coding.

**Problem being solved:** v3's destination handling was incomplete. (1) BUG: the "Add destination" SSD tab showed "No drives available" because the sole SSD was already the default destination (filtered out of the "unused drives" list). (2) A `Destination` was just a drive path — it had **lost the old per-drive project folder + subfolder**, so per-card routing only routed the *drive*, not the project structure. (3) No way to edit a destination after creating it.

**Xavier's locked decisions:** per-destination project/subfolder = YES; **allow the same drive twice** with different projects; **edit by clicking the tile**. Auto-derive the destination NAME from the project folder = **CLEANED RAW** (strip leading date token like `260626_`, no camelCase spacing), editable.

**STAGE A — COMMITTED (`f632071`), reviewer-verified behavior-preserving.** The engine core:
- `Destination` grew `projectFolder: String = ""` + `subfolder: String = "Default"`, with a **custom Codable decoder** (`try decodeIfPresent ?? default`) — synthesized Codable throws `keyNotFound` on old JSON and would have **WIPED the saved destinations list** (caught by a migration unit test).
- Pure `resolveProjectFolder(destProject:globalProject:)` — per-dest wins, empty → global fallback. `startIngest` now resolves the ROUTED destination's project/subfolder (new `resolvedSubfolder` threaded into `buildIngestArgs`). Empty-project refusal preserved.
- Migration is behavior-preserving: `migrateLegacyDestinations` seeds the migrated SSD dest's `subfolder` from the global (subfolder has no runtime fallback). Checkpoint + notification use the resolved subfolder.

**STAGE B — COMMITTED (`dda08df`), reviewer-verified production-ready.** The Add-destination UI:
- Fix the "No drives available" bug: the Add-dest SSD Drive menu now lists `v3AllDrives` (ALL mounted drives). Removed `v3UnusedDrives`/`v3AddDriveDestination`.
- SSD tab: Drive + **Project folder** (type new or pick existing via `v3ProjectFolders`) + **Subfolder** (`v3Subfolders`) + **Destination name** (auto-derived, editable) + **live path preview** (`v3AddPreview`).
- Pure `deriveDestName(fromProject:)` (cleaned-raw), wired via `v3SetAddProject`; `v3AddNameEdited` flag stops it stomping a typed name. 5 tests.
- `v3CommitAddDest` writes the fields + `mkdir`s `{drive}/{project}` (guarded vs `/`+`..`, idempotent — no footage touched); allows same drive twice.
- `v3AddIsDuplicate()` blocks an identical drive+resolvedProject+subfolder leaf (amber inline error); same drive + different project OK.
- Tiles show `v3DestPathLabel(d)` = `{project} / {subfolder}` so same-drive dests are distinguishable.

**NEXT-CHAT TODO for this task (P1):**
1. **The click-tile per-destination editor:** clicking a `v3DestTile` opens a per-destination module to edit its project folder / subfolder (drive shown, not re-picked). Lock while `runningCount > 0` (like `v3MakeDefault`). Reuse the Stage-B SSD-tab fields. *Without this, mis-setting a project means Remove + re-Add.*
2. **Fold in the reviewer's Stage-B P2 while building the editor:** `v3AddIsDuplicate` + `v3DestPathLabel` should normalize an explicit subfolder literally named `"clips"` to be equivalent to `"Default"` (the shell maps Default→clips), so two dests (one Default, one explicit "clips") on the same drive+project aren't treated as distinct. Narrow, non-corrupting, but close it in the editor.
3. Possible polish: a "New project folder…" affordance with scaffold/color (currently you just type the project name and it's `mkdir`'d on commit); camelCase-spacing name option (deferred — Xavier wants cleaned-raw on real folder names first).

---

## 2. How to build / run / test

```bash
cd "/Users/xaviergallo/Documents/The Everything/DIY Apps/Apps/CardRunner"

# Build (Debug, no signing)
xcodebuild -project CardRunner.xcodeproj -scheme CardRunner -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -iE 'error:|BUILD SUCCEEDED|BUILD FAILED'

# Unit tests (~62). MUST skip the UITests target — its runner hangs headless.
xcodebuild test -project CardRunner.xcodeproj -scheme CardRunner -destination 'platform=macOS' \
  -only-testing:CardRunnerTests -skip-testing:CardRunnerUITests \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -iE 'TEST SUCCEEDED|TEST FAILED'

# Smoke test (37) — runs the REAL shell + cardcopy against synthetic cards. The footage-safety gate.
./smoke_test.sh
```

⚠️ **FLAKY UNIT-TEST HOST:** the FIRST `xcodebuild test` after a build often reports `** TEST FAILED **` with *"The test runner hung before establishing connection."* — this is an ENVIRONMENTAL degraded-session issue (handoff §7 of old doc), **not a code failure**. Re-run; it passes. If it keeps failing, capture full output and grep for `recorded an issue`/`XCTAssert` — a REAL failure names the failing test. The **smoke test is the footage-safety gate** and runs via `/bin/zsh` directly (not the xctest host), so it's reliable.

**Running the real app (Xavier does this; do NOT screen-control unless asked):** after building, refresh + ad-hoc sign the Desktop app so it launches from Finder as a real foreground GUI:
```bash
SRC="/Users/xaviergallo/Library/Developer/Xcode/DerivedData/CardRunner-hbuwejbtuggdywgriapcyvzklrwt/Build/Products/Debug/CardRunner.app"
DST="$HOME/Desktop/CardRunner.app"
pkill -9 -f "MacOS/CardRunner"; rm -rf "$DST"; cp -R "$SRC" "$DST"
codesign --force --deep --sign - "$DST"; xattr -dr com.apple.quarantine "$DST"
```
Xavier **double-clicks `~/Desktop/CardRunner.app`** (never launch from a terminal — see §7). DerivedData hash `CardRunner-hbuwejbtuggdywgriapcyvzklrwt` has been stable; re-derive if it changes.

**Launch flags:** none for v3 (default). `CR_LEGACY_UI=1` = old UI escape hatch. `CR_V3_DEMO=1` = pure-sim demo.

---

## 3. Architecture — the graft (v3 UI on the proven engine)

`ContentView.swift` (~17k lines) is ONE giant `struct ContentView: View` holding ALL engine logic AND the UI. We did NOT extract a controller.

- **`ContentView.body`**: `if CR_LEGACY_UI { legacyBody } else { ZStack { legacyBody.opacity(0).allowsHitTesting(false); bodyV3 } }`. The **legacy body stays mounted-invisible** so its proven wiring keeps running: card detection (`didMount → scanForNewCardsAndIngest`), the 30-s fallback scan loop, timers, menu-notification handlers, and `.sheet`/`.alert` modifiers (which float OVER v3).
- **`bodyV3`** (an `extension ContentView` at the END of the file — must be same file; reads `private @State`). Pure presentation over the real `@State`; actions via direct `@State` mutation or the **menu-notification bus**.
- **Gotcha:** any legacy *inline overlay* (not a `.sheet`/`.alert`) renders INVISIBLY under v3. If a menu command "does nothing," it's almost always this — render a v3 equivalent, gate the legacy copy behind `isLegacyUI`.
- **Top-level PURE, unit-tested fns** (footage-safety + logic core): `buildIngestArgs`, `evaluateIngestOutcome`, `applyIngestProgressLine`, `canAdmitIngest`, `failureRecordsSurviving`, `cardIsAlreadyTracked`, `resolveCardLabel`, `resolveProjectFolder`, `deriveDestName`.

**Routing model (current):** PER-CARD only (split/mirror mode was removed). Each card copies to its routed/default destination. Folder layout: `{drive}/{project}/{subfolder|clips}/{date}/{cardlabel}/` — where **project+subfolder are per-DESTINATION** (Stage A) and **cardlabel is per-CARD** (the editable lane name). The legacy dual-dest path (`dualDestEnabled`/`secondaryPath`, no-Destination-list users) still emits one `--secondary` and is untouched.

---

## 4. Footage-safety core (the most important thing)

Promise: **never lose footage, never report a failed transfer as success, never let the operator think a failed card is safe to format.**
- `evaluateIngestOutcome(exitStatus:ingest:)` = the SINGLE authoritative success/failure gate (`didFail = exitStatus != 0 || hasCopyError`).
- `FailedIngestRecord` (persisted, has `volumeUUID`) = the "DO NOT FORMAT" warning; a failure ALWAYS writes one (mid-copy, early-abort `newFiles==0`, cancel, or process-launch failure). `failureRecordsSurviving()` decides what a success clears (UUID match, or name+non-empty-nickname; NEVER name-alone). Surfaced by `v3FailureStrip` + failure-first ring. `v3AllDone`/green-ring is IMPOSSIBLE while any failure exists.
- **Dry Run** = simulation, copies NOTHING; a loud persistent `v3DryRunBanner` fires whenever `dryRun==true` so a simulated "done" lane is never mistaken for real footage.
- **The manifest** (`~/Library/Application Support/CardRunner/manifests/{uuid}.tsv`) is SOURCE-keyed (`rel|size|mtime`) and destination-agnostic — it prevents re-copying a card's clips even to a new folder. `--ignore-manifest` (surfaced via the "Re-ingest all N" button in the "Already up to date" prompt) deliberately re-copies; it can only add files (the dest-exists check still prevents in-place overwrite).
- ⚠️ When touching ANY of this, run the smoke test + the `failure*`/`outcome*` unit tests.

---

## 5. The agent review loop (Xavier's REQUIRED working mode)

Lead coder (you, in-context) implements; a **persistent reviewer sub-agent** (`general-purpose`, read-only, reviews the working-tree `git diff` by absolute path — NOT a worktree) checks it. Resume the SAME reviewer via SendMessage each round. It returns prioritized P0/P1/P2; fix P0 (footage-safety) first; re-verify (build + unit + smoke); loop until "production-ready" BEFORE committing. For design-heavy tasks, the reviewer does an ASSESS/BRAINSTORM pass FIRST, Xavier aligns on decisions, then the lead codes. This loop has caught a real footage-safety or migration bug in nearly every batch — **keep using it.** Refresh the Desktop app after each commit so Xavier can validate on hardware.

---

## 6. What's been delivered (the good stuff — recent commits, newest first)

- `dda08df` **Destination selection UI (Stage B)** — all-drives list (fixes "No drives available"), project/subfolder pickers, cleaned-raw auto-name, live preview, duplicate-leaf guard, tile disambiguation.
- `f632071` **Per-destination project/subfolder** — model + resolution (Stage A of the active task).
- `239b897` **Custom-card-name UX** — focus feedback, green-✓ confirm (Enter locks, never starts), real memory (persists per-UUID; survives re-scan by identity), Esc-revert, live path preview. Reviewer-verified.
- `b2a6704` **Debug mode in v3** — a DEV strip (gated on the Settings debug toggle): Run UI Demo (`runDemoIngest` — full simulated ingest driving the real lanes/ring), Show Log, Log Files, Dry Run.
- `1ef18ef` **Settings redesign (Stage 1)** — icon-rail layout, all settings migrated (reviewer-verified parity) + **subtle gloss sheen** (occasional skewed brand-tinted sweep, KeyframeAnimator one-shot, idle between passes). *(Stage 2 = restyle the embedded Presets/Shortcuts/About flows.)*
- `cbfc136` / `9dd029b` **Top logo** — larger SD-card mark + **Saira ExtraBold Italic** wordmark (bundled static cut, OFL) + tagline "a smoother ingest workflow for creators", centered on the ring.
- `df2ee9e` **Removed light mode** — dark-only (useLightMode is a constant false; toggle + ⌘⇧D gone).
- `8aaa338` **Re-ingest (ignore manifest)** — button in the "Already up to date" prompt.
- `822c734` Drag-to-link a card no longer auto-starts (waits for Start).
- **Tier 3 batch:** FDA banner in v3, off-main free-space (dead-NAS freeze), same-source ingest guard, custom date range, photo mixed-card hint, max-concurrent control, removed split/mirror (→ per-card routing), preset quick-switch, dry-run reachable+guarded, honest dual-dest toggle.
- **Per-card folder name** (`--cardlabel`, editable on awaiting + copying lanes, safe rename-at-completion).
- **Card detection fix** — the app kept watching for cards when Auto-Ingest is OFF (+ re-surface).

---

## 7. Hard-won gotchas (do not re-debug these)

- **Launch from Finder, not a terminal.** Terminal launch hits SIGTTIN (fixed: ingest shell `standardInput = FileHandle.nullDevice`) and App-Nap suspension (fixed: `ProcessInfo.beginActivity(.userInitiated)` per ingest).
- **No always-on `TimelineView(.animation)`** — it once burned a whole core (funnel at 120fps) and starved the ingest pipe. The gloss sheen uses a timer-triggered `KeyframeAnimator` one-shot (idle between passes) precisely to avoid this.
- **Flaky unit-test host** — see §2. Re-run; smoke is the real gate.
- **Codable migration:** synthesized Codable THROWS on missing keys — adding a field to a persisted struct needs a custom `decodeIfPresent ?? default` decoder or it wipes saved data (bit us on `Destination`; there's a migration unit test now — keep that pattern).
- **Don't `defaults write` while the app runs** — it flushes @AppStorage on quit and clobbers your write.
- **Off-main volume/free-space I/O** — a wedged NAS froze launch; free-space is now cached + probed off-main. Keep FS reads off the render/main path.

---

## 8. Open items / what's next

1. **Finish the destination redesign** (§1) — commit Stage B after review; then P1 = the click-tile per-destination editor.
2. **Settings Stage 2** — restyle the embedded Presets / Shortcuts / About flows to match the new icon-rail look (they work, but wear old styling). Restore the scaffold per-row edit + subfolder field + rename-template live preview simplified in Stage 1.
3. Lower-priority: remove now-dead legacy popovers; restyle the engine-triggered sheets (resume / wrong-clock / setup wizard / support bundle) still visually legacy; history/stats UserDefaults durability.

---

## 9. File map

| File | Role |
|---|---|
| `CardRunner/ContentView.swift` | EVERYTHING — engine + legacy UI + `bodyV3` + v3 Settings + all v3 sheets/lanes/tiles. Top-level pure fns listed in §3. |
| `CardRunner/CardRunner.sh` | ~2.5k-line zsh ingest engine (scan/filter/manifest/copy/N-way mirror/`--ignore-manifest`/`--subfolder`/`--cardlabel`). |
| `cardcopy/cardcopy.c` + `CardRunner/cardcopy` | native copy engine (fcopyfile/clonefile). |
| `CardRunner/CardRunner.swift` | `@main`; `CardRunnerCommands` (menu + keyboard shortcuts). |
| `CardRunner/Assets.xcassets/CardRunnerLogo.imageset` | the purple SD-card logo. `CardRunner/Saira-ExtraBoldItalic.ttf` + `Saira-OFL.txt` = bundled wordmark font. `Tech Headlines Italic.otf`, `DMSans-Regular.ttf` also bundled (ATSApplicationFontsPath="."). |
| `CardRunnerTests/CardRunnerTests.swift` | ~62 unit tests (Swift Testing + XCTest). |
| `smoke_test.sh` | 37 checks, real shell+cardcopy. Gated in `release.sh`. |

---

## 10. Locked decisions (do not violate)
- Copy engine is `fcopyfile()`/clonefile only. No rsync/cp/fallback.
- Mac-only native Swift. No HTML/WebView UI (tried + scrapped).
- Keep the big center ring (app identity). App is **dark-only** (light mode removed).
- Routing: **per-card only** (split/mirror removed). Plug a card → auto-route to default + auto-start (instant-ingest promise) when Auto-Ingest is ON. "Waiting/blocked" only when no destination configured.
- Manual pull default; auto-eject opt-in. Footage safety > convenience.
- Every footage-touching change goes through the lead+reviewer loop before commit. Don't screen-control the running app unless Xavier asks — he validates on hardware.
- CARDRUNNER wordmark = Saira ExtraBold Italic. Destination auto-name = cleaned-raw (date-stripped, no camelCase).
