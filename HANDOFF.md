# CardRunner — Session Handoff
**Date:** 2026-08-06  
**Branch:** main  
**Last commit:** a8ac448

---

## What Was Shipped This Session (10 commits)

### Performance
**`8092687` — Main-thread blocking**
- Log reads after each ingest moved off main thread
- `refreshDestinations()` filesystem scan moved to `DispatchQueue.global()` + generation counter (prevents stale results from rapid mount/unmount races)
- `DateFormatter` allocations promoted to `static let`

**`7974264` — Unmount: filesystem I/O off main thread**
- `revalidateCustomDest()` and `updateSSDInfo()` both did synchronous `fileExists` / `attributesOfFileSystem` on the main thread inside the unmount notification handler → potential UI freeze during drive removal
- Both moved to `Task.detached(.utility)` with stale-result guards
- `didUnmountNotification` now also terminates active ingests whose `sourcePath` matches the gone volume — when a card is physically pulled mid-copy, `cardcopy` was blocking on I/O until kernel timeout; now terminates immediately via `proc.isRunning` guard

### Multi-Shooter Integrity
**`9db8860` — Multi-card name crossing**
- Root cause: shared `@AppStorage` global used as a per-card value; concurrent mounts overwrote it
- Fix: names resolved per-UUID from `knownCardNicknames`; auto-labels can never be learned as a shooter name; per-ingest snapshot at termination

**`17406aa` — Batch 1 production fixes**
- **Verify %:** `VERIFY_PROGRESS` now emitted in spot-check AND full-verify modes (was full-verify only)
- **AFK-only alerts:** `shouldDeliverRemoteAlert` reduced to `hasDestination && afkMode`; idle/away gate and its dead Settings controls removed
- **CARD_HHMM:** fixed same-day collision — fallback was using date suffix (`CARD_0802` for every card same day); now uses resolution-time `CARD_HHmm` with atomic uniqueness check
- **Bottleneck copy:** "Below expected — check connection" → "Speed below expected for this link"
- **Open in Finder / F key:** unified through `finderRevealPath()`; walks to nearest existing ancestor; works after eject

### Transfer Control
**`cea1421` — Auto-ingest OFF no longer cancels in-flight transfer**
- `onChange(of: autoIngest)` OFF branch was calling `cancelAllIngests()` — killed any running copy
- The "max moody error — only a few clips" was this bug
- Fix: OFF branch no longer cancels; only Stop Transfer can abort a running ingest

**`a5f7728` — Destinations no longer deleted on drive unmount**
- `reconcileDestinations()` permanently removed saved destinations whose drive was temporarily absent
- Root cause of "Toronto Tennis vanished, Gallo 8TB became default"
- Fix: function deleted entirely; unmounted destinations persist in config

### Auto-Label Feature
**`8ea6c75` — Smart auto-label for unknown cards**
- Unknown cards get a smart subfolder: file prefix scan (e.g. `FV7A_XXXX.MP4` → `FV7A/`), fallback to `CARD_HHmm`, or land in date folder
- Eject clears the global card name so it can't bleed to the next card

### Date Picker
**`a84a600` — Date picker when today-filter excludes all footage**
- Old: binary "Ingest everything?" alert
- New: shows a date picker — "footage found on other days, choose what to ingest"
- Also triggers when no filter is set and footage spans multiple days

### Verification
**`1caa109` — Resume verify: run checksum pass when no new files to copy**
- When interrupted during verify phase (after copy completed), resume found `new_count == 0` and exited early with `Status=NoNewFiles` — no verify ever ran, checkpoint deleted, card silently cleared
- Fix: `new_count == 0` path now runs `verify_transfer` against `list_all` if `VERIFY=yes`
- Pass → `PHASE done`, checkpoint deleted. Fail → `PHASE failed`, checkpoint kept, `FailedIngestRecord` written
- `AUTO_EJECT` forces a spot-check on resume (never eject without sampling)

### UI Cleanup
**`a8ac448` — Remove per-card sparkline from ingest tile**
- Mini waveform on each card tile was redundant with the full-UI speed graph
- MB/s + peak + file count remain on tile; aggregate graph in main UI unaffected

---

## Open Items

### #3 — Auto-label typed rename not applying after ingest finishes — **FIXED (two separate bugs)**

**Bug 3a — Wrong base path (fixed Aug 6 morning):**
- `OPEN_TARGET` emits the full label-folder path for single-destination runs, overwriting `destPath`. `applyPendingFolderRename` scanned for date dirs *inside* that label folder (video files), found nothing, silently no-oped.
- Fix: Added `clipsRoot` field to `ActiveIngest` from `PROGRESS_DEST`; termination handler and `v3CommitActiveRename` now pass `clipsRoot` as the rename base. 2 tests added.

**Bug 3b — No-label cards: footage flat in date folder (fixed Aug 6 evening, confirmed by live log):**
- When `hasSubs = false` (first/only card of the day), auto-label assigns `cardLabel = ""` — no per-card subfolder created. Operator types "xavier" → `pendingRename = "xavier"` captured. `applyPendingFolderRename` guards on `!oldT.isEmpty` → silent no-op. Also: `v3CommitActiveRename` was clearing `pendingRename` when `cardLabel == ""` + Enter pressed during copy, making the termination handler a dead code path for that scenario.
- Fix: New `moveFilesIntoSubfolder(dateFolder:newLabel:files:)` function. Termination handler now has a no-label branch: when `cardLabel == ""` + `copiedFiles` non-empty + `destPath ≠ clipsRoot` → creates subfolder, moves verified files into it, saves nickname. Multi-day guard: skips when `destPath == clipsRoot`. `v3CommitActiveRename` empty-label branch: still-copying keeps `pendingRename` and updates `friendlyName`; done path calls `moveFilesIntoSubfolder` immediately.
- `RENAME_APPLIED` log now only fires after confirmed file movement.
- Tests: 3 new discriminator tests; 207 total pass.

**Bug 3c — Empty old-label folder left on disk after has-label rename (fixed Aug 6):**
- After `applyPendingFolderRename` moves files via the per-file manifest correction path (`CORRECTION MOVED`), the source directory tree (`260806/test/PRIVATE/M4ROOT/CLIP/`) is left fully empty on disk.
- Fix: New `removeEmptyLabelDirs(under:oldLabel:)` helper. After a successful has-label rename, it walks every date dir under `clipsRoot`, finds the old-label directory, verifies it contains no files, and removes it (recursively, picking up empty subdir trees). Only removes when zero files remain — logs `RENAME_CLEANUP_SKIP` if any files are present.

**Bug 3d — Per-UUID card nickname not updated after has-label rename (fixed Aug 6):**
- When `applyPendingFolderRename` renamed `test → xavier`, the nickname for that card UUID was never updated. The `labelIsOperatorGiven` block after the rename saved `friendlyName = "test"` only when the operator set the label in the awaiting lane — not when the label came from a stored nickname. So the next insert re-resolved "test" from `knownCardNicknames`, creating an infinite rename loop.
- Fix: Termination handler now captures the return value of `applyPendingFolderRename`. When `effective == newLabel` (rename succeeded), it saves `knownCardNicknames[uuid] = effective` immediately. `RENAME_APPLIED` log is also now conditional (was always emitted, even on failure — pre-existing false positive).

### cardcopy Rename Failure (Aug 5 — watch only)
- Two occurrences on XG_FX card: `rename failed .cardrunner_partial/XG_FX3_3964.MP4 → destination: No such file or directory (after 6 attempts)`
- CardRunner handled correctly (manifest not updated, files retried)
- Suspected flaky card reader or connection; not a code bug
- **Watch:** if it recurs on future shoots, the reader hardware may need replacing

### Release — Not Yet Pushed
- All 10 commits are local on `main`
- Remote: `https://github.com/Xtron6/-cardrunner-releases`
- No appcast.xml update yet for this build

---

## Log Health (Aug 1–6 Review)
- **60 OK / 18 NoNewFiles / 7 PartialError / 3 MirrorFail (smoke tests) / 1 VerifyFail**
- All PartialErrors: 4 user-cancelled, 2 cardcopy rename failures (watched above), 1 pre-fix auto-ingest-off bug
- VerifyFail: empty src checksum (card pulled during verify) — safety system blocked eject correctly
- Speeds healthy: 114–747 MB/s to Gallo 8TB
- Auto-label `CARD_HHmm` firing correctly for no-today-footage cards

---

## Architecture Notes
- `CardRunner/ContentView.swift` — ~15k line monolith; all UI + Swift ingest logic
- `CardRunner/IngestLogic.swift` — pure functions: label resolution, bottleneck, file prefix extraction
- `CardRunner/IngestModels.swift` — `ActiveIngest` struct (added `labelIsOperatorGiven`)
- `CardRunner/RemoteNotify.swift` — Slack + iMessage; AFK-only gating
- `CardRunner/CardRunner.sh` — shell engine; `cardcopy` binary does the actual copy + verify
- Tests: Swift Testing framework (`@Test` / `#expect`), 205 unit tests in `CardRunnerTests/CardRunnerTests.swift`
- **Never run XCUITest targets** — use `-only-testing:CardRunnerTests` always
- **Always clean build** (`⇧⌘K` + `⌘B`) after shell script changes — Xcode won't re-bundle `CardRunner.sh` without it
