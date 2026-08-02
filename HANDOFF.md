# CardRunner — Handoff & Next Steps
_Last updated: 2026-08-02 · Current release: 1.8.2 (build 24)_

**Owner:** Xavier Gallo · macOS SwiftUI app, Mac-only, direct-distribution (Sparkle, not App Store)
**Repo:** `/Users/xaviergallo/Documents/The Everything/DIY Apps/Apps/CardRunner`
**GitHub:** https://github.com/Xtron6/-cardrunner-releases

---

## Current State

App is clean, shipped, and stable. 205 tests pass, 0 failures. 1.8.2 is live to users via Sparkle.

---

## What Shipped This Session (1.8.2)

### Slack Live Progress
- Replaced fire-and-forget webhook with **bot token approach** (`xoxb-...` + channel ID)
- Posts a message when a card transfer starts, edits it in place every 10% of progress
- Final edit on completion: ✅ done / ⚠️ failed
- Per-lane sessions keyed by UUID — concurrent ingests each get their own Slack message, no aliasing
- Settings: two fields (bot token + channel ID) with helper text pointing to api.slack.com
- **User setup:** api.slack.com → Create App → add `chat:write` scope → install → copy token (~3 min)
- iMessage = easy (just a phone number); Slack = power users who create their own Slack app. Intentional product split — don't collapse them.

### iMessage / AFK Remote Alerts
- iMessage fires when a card finishes and Mac has been idle ≥ threshold (default 2 min)
- **AFK toggle** in top bar (opposite the preset control) — guarantees a text on every finished card, bypassing idle detection entirely
- AFK is session-scoped (resets on relaunch — intentional, "stepping away right now" not persistent)
- Tapping AFK with no destination shows an **inline popover** explaining what's needed + direct link to Remote Alerts settings
- AFK button matches gear/history hover style: cyan glow, border, 1.05× scale, same spring animation

### Verify Progress %
- "Verifying checksums…" now shows e.g. `Verifying checksums… 34%` live
- Pure UI change — data was already flowing via `verifyChecked`/`verifyTotal` on `ActiveIngest`
- Shows 1–99% only (no "0%" flash at start, no "100%" at end)

### Report an Issue Freeze Fix
- `generateSupportBundle()` was blocking the main thread (reads 7 days of logs + up to 3 crash `.ips` files)
- Fixed: dispatched to background queue, settings closes instantly, mini spinner shows, sheet opens when ready

### Tier 2 Speed Diagnostics (shipped in 1.8.1 build 23)
- Live hardware path display: source/dest protocol + link speed + media type
- Peak MB/s shown on live tile and in history
- Bottleneck analysis: reader-limited / drive-limited / below-expected / verify-slowed
- CSV export extended to 11 columns (Peak MB/s, Hardware path)

---

## Next Steps (Priority Order)

### 1. Performance Fixes — Ready to Build, No Design Needed

**HIGH — Log read on main thread after every ingest**
- Location: `ContentView.swift` ~line 7684
- What: after every transfer, reads the entire day's log file synchronously on main thread (`String(contentsOf: logPath)`) to extract hardware fields
- Fix: move log read into the background portion of the termination handler before the `DispatchQueue.main.async` hop, pass result in
- Impact: removes a blocking main-thread disk read after every single card transfer

**HIGH — `refreshDestinations()` blocks main thread on mount/unmount**
- Location: `ContentView.swift` ~line 5581
- What: called on every volume mount/unmount; does `fm.contentsOfDirectory(at: /Volumes)` + per-volume `fileExists` + `reconcileDestinations()` all synchronously on main thread
- Fix: wrap in `DispatchQueue.global` + hop back to main for state writes
- Impact: a wedged NAS or slow drive at mount time currently blocks the entire UI

**MED — DateFormatter allocations on every render pass**
- Location 1: `ContentView.swift` ~line 2413 (`predictedDestPreview`) — new `DateFormatter` on every render during active transfers (~4×/sec)
- Location 2: `IngestModels.swift` ~line 182 (`CardDateInfo.displayDate`) — two new `DateFormatter` instances per date picker row per render
- Fix: make them `static let` at type or module level
- Impact: removes repeated expensive locale/calendar/timezone lookups during active transfers

### 2. Wishlist (Parked)

**Slack Ring Widget**
- Render the CardRunner progress ring as PNG via `ImageRenderer`, upload to Slack via `files.getUploadURLExternal`, attach to live-updating message — ring swaps out each tick
- **Why parked:** 3 API calls per tick (render + upload + update). Text-based live updates shipped first.
- **When to revisit:** after Slack bot is stable and used in real shoots

### 3. Longer-Term Engineering

**Monolith split (Stage 1b/2)**
- `ContentView.swift` still ~15k lines. Stage 1a done (extracted `IngestModels.swift` + `IngestLogic.swift`)
- Stage 1b: extract self-contained top-level UI structs (~3–4k more lines out)
- Stage 2: split `struct ContentView` across extension files
- Landmines: shared `private` helpers must flip to `internal` in a prep commit first; `@State`/`@AppStorage` stored properties must stay in the primary struct body

**Column scroll for many-card overflow**
- 5+ simultaneous cards overflows the source lane column with no scroll
- Design-sensitive (touches funnel geometry, ring alignment, destFrames anchors) — align on design before touching

**Airtight VERIFIED badge**
- Snapshot `verifyTransfer` state per-ingest at launch so verified cards show the badge correctly after relaunch
- Low priority / low frequency

---

## Architecture Reference

**Card detection:**
- Fires on `NSWorkspace.didMountNotification` (same event Finder uses) + 600ms filesystem settle delay
- Hardware mount time (1–3s USB/SD enumeration) is the real latency — nothing to optimize there
- 30s fallback scan loop catches edge cases (cards mounted before app launched, missed notifications)
- We are as fast as it's possible to be

**Presets:**
- Valuable for DITs switching between shows mid-day (saves mode, verify, scaffold, date filter, destination override in one tap)
- Top-bar menu only appears when presets exist — zero clutter for users with none
- Keep as-is

**iMessage vs Slack:**
- iMessage: zero config, any phone number, fire-and-forget (start + completion messages)
- Slack: bot token setup (~3 min), live-updating single message per card
- Do not collapse them — the split is intentional and correct

**AFK session-scope:**
- `@State`, not `@AppStorage` — intentional. "I'm stepping away right now" should not stay armed after relaunch silently.

---

## Test Suite

205 tests, 0 failures. Swift Testing framework (`@Test` / `#expect`) — NOT XCTest.

Notable suites:
- `RemoteAlertsTests` — gating logic, composite gate, message formatting
- `SlackFormatterTests` — start/progress/finish text (verified, unverified, failed, singular file)
- `BottleneckTests` — parseLinkMBps, bottleneckDescriptor
- Tier 2 speed/hardware field parsing

---

## Release Process

```bash
# 1. Bump CURRENT_PROJECT_VERSION and MARKETING_VERSION in project.pbxproj
# 2. Commit and push
git add CardRunner.xcodeproj/project.pbxproj
git commit -m "Bump version to X.Y.Z build N"
git pull origin main --no-rebase && git push origin main

# 3. Cut the release (notarize → sign → appcast → DMG → GitHub release)
./release.sh X.Y.Z "Release notes here"
```

Sparkle auto-updates all existing users on next app launch.

---

## Performance Findings — Full Detail

From automated investigation (2026-08-02):

| # | Severity | Location | Issue |
|---|----------|----------|-------|
| 1 | HIGH | ContentView.swift ~7684 | `String(contentsOf:)` log read on main thread after every ingest |
| 2 | HIGH | ContentView.swift ~5581 | `refreshDestinations()` does `contentsOfDirectory` + `fileExists` on main thread |
| 3 | MED | ContentView.swift ~2413 | `predictedDestPreview` allocates new `DateFormatter` every render pass |
| 4 | MED | IngestModels.swift ~182 | `CardDateInfo.displayDate` allocates two `DateFormatter` per row per render |
| 5 | MED | ContentView.swift ~4866 | `seenCardPaths.filter { fileExists }` on main thread in unmount handler |
| 6 | LOW | ContentView.swift ~2005 | `completionAnim` UserDefaults wrapper — negligible |
| 7–9 | OK | Various | Timers and shell sleeps are intentional and correctly structured |

Items 1, 2, 3, 4 are the ones worth fixing. Item 5 is low-frequency and low-impact. Items 6–9 leave as-is.
