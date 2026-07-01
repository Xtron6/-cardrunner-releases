//
//  CardRunnerTests.swift
//  CardRunnerTests
//
//  Safety-critical regression tests. Focus: the persisted-data decoders that back the
//  app's "did we get that card?" promise and the crash-resume flow. A regression here
//  silently wipes user history/presets or misroutes a resumed ingest, so these guard
//  the resilience the production code relies on.
//

import Testing
import Foundation
@testable import CardRunner

private let enc = JSONEncoder()
private let dec = JSONDecoder()

/// Encode a value, drop one top-level key from its JSON, and return the trimmed data —
/// simulates a stored blob written by an older/newer build that lacks `key`.
private func encodedDropping<T: Encodable>(_ value: T, key: String) throws -> Data {
    let data = try enc.encode(value)
    var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    obj.removeValue(forKey: key)
    return try JSONSerialization.data(withJSONObject: obj)
}

struct CardRunnerTests {

    // MARK: - IngestCheckpoint (crash-resume, fix #3)

    @Test func checkpointRoundTripPreservesResumeArgs() throws {
        let cp = IngestCheckpoint(
            id: UUID(), cardPath: "/Volumes/CARD A", cardName: "CARD A",
            primaryPath: "/Volumes/SSD", projectName: "Shoot", subfolder: "",
            cardLabel: "Cam1", dateFormat: "%y%m%d", finderTagColor: "",
            mode: "video", secondaryPath: "", verifyEnabled: true, newFiles: 3,
            startedAt: Date(),
            resumeArgs: ["--card", "/Volumes/CARD A", "--date-override", "20260101",
                         "--reels", "A,B", "--reel-multi"]
        )
        let back = try dec.decode(IngestCheckpoint.self, from: try enc.encode(cp))
        // The exact routing flags MUST survive so a resumed ingest lands footage identically.
        #expect(back.resumeArgs == cp.resumeArgs)
        #expect(back.cardPath == "/Volumes/CARD A")
        #expect(back.verifyEnabled == true)
    }

    @Test func legacyCheckpointWithoutResumeArgsDecodes() throws {
        let cp = IngestCheckpoint(
            id: UUID(), cardPath: "/Volumes/CARD", cardName: "CARD",
            primaryPath: "/Volumes/SSD", projectName: "Shoot", subfolder: "",
            cardLabel: "", dateFormat: "%y%m%d", finderTagColor: "",
            mode: "video", secondaryPath: "", verifyEnabled: false, newFiles: 0,
            startedAt: Date(), resumeArgs: ["--card", "/Volumes/CARD"]
        )
        // A checkpoint written before resumeArgs existed lacks the key entirely.
        let legacy = try encodedDropping(cp, key: "resumeArgs")
        let back = try dec.decode(IngestCheckpoint.self, from: legacy)
        #expect(back.resumeArgs == nil)        // → resume falls back to per-field reconstruction
        #expect(back.projectName == "Shoot")   // everything else still intact
    }

    // MARK: - AllTimeStats (fix #5 — never zero lifetime counters on schema drift)

    @Test func allTimeStatsRoundTrip() throws {
        var s = AllTimeStats()
        s.totalCards = 12; s.totalFiles = 3400; s.totalMB = 512_000; s.peakMBps = 780
        let back = try dec.decode(AllTimeStats.self, from: try enc.encode(s))
        #expect(back.totalCards == 12)
        #expect(back.totalFiles == 3400)
        #expect(back.peakMBps == 780)
    }

    @Test func allTimeStatsSurvivesMissingFutureField() throws {
        var s = AllTimeStats()
        s.totalCards = 9; s.totalFiles = 1000; s.peakMBps = 600
        // A future build adds a field; this older blob lacks `peakMBps`. Must NOT throw
        // (which would zero the user's lifetime totals and trigger a bad log re-bootstrap).
        let trimmed = try encodedDropping(s, key: "peakMBps")
        let back = try dec.decode(AllTimeStats.self, from: trimmed)
        #expect(back.totalCards == 9)      // surviving fields preserved
        #expect(back.totalFiles == 1000)
        #expect(back.peakMBps == 0)        // missing field → default, not a wipe
    }

    // MARK: - IngestHistoryEntry (audit trail back-compat)

    @Test func historyEntryDecodesLegacyMissingNewerFields() throws {
        let e = IngestHistoryEntry(
            cardName: "CARD", status: "Completed", newFiles: 50, skippedFiles: 2,
            avgMBps: 600, durationSec: 8, destPath: "/Volumes/SSD/Shoot/260101",
            mediaLabel: "clips", totalBytesTransferred: 5_000_000_000,
            skipManifest: 1, skipDestExists: 1, skipTodayFilter: 0, skipWrongMode: 0
        )
        // Legacy entry written before the per-reason skip breakdown / mediaLabel existed.
        var data = try enc.encode(e)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for k in ["mediaLabel", "totalBytesTransferred", "skipManifest", "skipDestExists"] {
            obj.removeValue(forKey: k)
        }
        data = try JSONSerialization.data(withJSONObject: obj)
        let back = try dec.decode(IngestHistoryEntry.self, from: data)
        #expect(back.newFiles == 50)             // core audit fields intact
        #expect(back.destPath == "/Volumes/SSD/Shoot/260101")
        #expect(back.mediaLabel == "clips")      // missing optional → sensible default
        #expect(back.totalBytesTransferred == 0)
    }

    // MARK: - IngestPreset (never wipe a saved preset on schema change)

    @Test func presetSurvivesMissingField() throws {
        let p = IngestPreset(name: "Wedding", customDestPath: "/Volumes/SSD/Weddings")
        // Drop a field a future/older build might not write — decode must still succeed
        // and keep the destination path (losing it would misroute footage).
        let trimmed = try encodedDropping(p, key: "dualDestEnabled")
        let back = try dec.decode(IngestPreset.self, from: trimmed)
        #expect(back.name == "Wedding")
        #expect(back.customDestPath == "/Volumes/SSD/Weddings")
    }

    // MARK: - evaluateIngestOutcome (THE footage-safety gate — never report success on failure)

    /// Build an ActiveIngest with just the fields the outcome gate reads.
    /// doneBytes is computed (completedFilesBytes + currentIntraFileBytes), so we set
    /// completedFilesBytes to control it.
    private func ingest(copyError: Bool = false, newFiles: Int = 0,
                        plannedBytes: Int64 = 0, doneBytes: Int64 = 0,
                        completedFiles: Int = 0) -> ActiveIngest {
        var i = ActiveIngest(cardName: "CARD")
        i.hasCopyError = copyError
        i.newFiles = newFiles
        i.totalBytesNew = plannedBytes
        i.completedFilesBytes = doneBytes
        i.completedFiles = completedFiles
        return i
    }

    @Test func outcomeCleanSuccess() {
        let o = evaluateIngestOutcome(
            exitStatus: 0,
            ingest: ingest(newFiles: 5, plannedBytes: 1000, doneBytes: 1000, completedFiles: 5))
        #expect(o.didFail == false)
        #expect(o.status == .completed)
        #expect(o.bytesTransferred == 1000)   // planned == actual on a clean run
        #expect(o.filesTransferred == 5)
    }

    @Test func outcomeUpToDateWhenNoNewFiles() {
        let o = evaluateIngestOutcome(exitStatus: 0, ingest: ingest(newFiles: 0))
        #expect(o.didFail == false)
        #expect(o.status == .upToDate)
    }

    @Test func outcomeNonZeroExitIsFailure() {
        let o = evaluateIngestOutcome(
            exitStatus: 1,
            ingest: ingest(newFiles: 5, plannedBytes: 1000, doneBytes: 400, completedFiles: 2))
        #expect(o.didFail == true)
        #expect(o.status == .error)
        #expect(o.bytesTransferred == 400)    // credit ACTUAL copied, not planned 1000
        #expect(o.filesTransferred == 2)      // credit ACTUAL completed, not planned 5
    }

    /// The exact bug that shipped: the script can exit 0 while a COPY_ERROR / VERIFY_FAIL
    /// was parsed mid-stream. That MUST be a failure — never "Completed".
    @Test func outcomeCopyErrorIsFailureEvenOnZeroExit() {
        let o = evaluateIngestOutcome(
            exitStatus: 0,
            ingest: ingest(copyError: true, newFiles: 5, plannedBytes: 1000, doneBytes: 600, completedFiles: 3))
        #expect(o.didFail == true)
        #expect(o.status == .error)
        #expect(o.bytesTransferred == 600)
    }

    /// A run that died before any byte landed must report 0 transferred — not the plan.
    /// (This is the "47 GB transferred while 0 files copied" inflation we fixed.)
    @Test func outcomeFailedBeforeAnyByteCreditsZero() {
        let o = evaluateIngestOutcome(
            exitStatus: 1,
            ingest: ingest(newFiles: 78, plannedBytes: 25_000_000_000, doneBytes: 0, completedFiles: 0))
        #expect(o.didFail == true)
        #expect(o.bytesTransferred == 0)
        #expect(o.filesTransferred == 0)
    }

    // MARK: - applyIngestProgressLine (the shell→Swift protocol parser feeding the gate)

    private func feed(_ lines: [String]) -> ActiveIngest {
        var i = ActiveIngest(cardName: "CARD")
        for l in lines { applyIngestProgressLine(l, to: &i) }
        return i
    }

    @Test func parserReadsMetaCounts() {
        let i = feed(["PROGRESS_META media_total=120 new_files=40 bytes_new=2000 bytes_total=5000"])
        #expect(i.mediaTotal == 120)
        #expect(i.newFiles == 40)
        #expect(i.totalFiles == 40)
        #expect(i.totalBytesNew == 2000)
    }

    @Test func parserReadsSkipSummaryIncludingProxyAndMissing() {
        let i = feed(["SKIP_SUMMARY manifest=3 dest_exists=78 today_filter=0 wrong_mode=1 proxy=144 missing=2"])
        #expect(i.skipManifest == 3)
        #expect(i.skipDestExists == 78)
        #expect(i.skipWrongMode == 1)
        #expect(i.skipProxy == 144)
        #expect(i.skipMissing == 2)
    }

    @Test func parserCopyErrorSetsFailureFlag() {
        #expect(feed(["COPY_ERROR dest=/x exit=1"]).hasCopyError == true)
        #expect(feed(["VERIFY_FAIL file=a.mp4 dest=/x"]).hasCopyError == true)
        #expect(feed(["DEST_INSUFFICIENT need_kb=100 free_kb=10"]).hasCopyError == true)
    }

    @Test func parserPhaseFailedTripsFailureFlag() {
        let i = feed(["PHASE failed groups=1 verify=0"])
        #expect(i.phase == .failed)
        #expect(i.hasCopyError == true)   // PHASE failed must also trip the gate
    }

    @Test func parserFileAccountingCommitsOnNextFile() {
        // PROGRESS_FILE fires at file START, so the previous file commits when the next
        // begins; the final file is committed by the termination handler (not here).
        let i = feed([
            "PROGRESS_META new_files=2 bytes_new=200",
            "PROGRESS_FILE size=100 a.mp4",
            "PROGRESS_FILE size=100 b.mp4",
        ])
        #expect(i.completedFiles == 1)          // a.mp4 committed when b.mp4 started
        #expect(i.completedFilesBytes == 100)
        #expect(i.currentFileName == "b.mp4")
    }

    @Test func parserSummarySnapsToFullProgress() {
        let i = feed([
            "PROGRESS_META new_files=2 bytes_new=200",
            "PROGRESS_FILE size=100 a.mp4",
            "PROGRESS_SUMMARY avg_mb=100 duration_sec=2 new_files=2",
        ])
        #expect(i.doneBytes == 200)             // snapped to planned total on summary
        #expect(i.avgMBps == 100)
    }

    /// THE end-to-end safety property: even if the shell exits 0 and emits PHASE done,
    /// a COPY_ERROR seen mid-stream must make the whole transfer a failure. This is the
    /// exact regression that shipped — parser + gate must catch it together.
    @Test func parserPlusGateCatchMidStreamErrorDespiteCleanExit() {
        let i = feed([
            "PROGRESS_META media_total=5 new_files=5 bytes_new=1000",
            "PROGRESS_FILE size=200 a.mp4",
            "COPY_ERROR dest=/x exit=1",
            "PROGRESS_SUMMARY avg_mb=100 duration_sec=10 new_files=5",
            "PHASE done",
        ])
        #expect(i.hasCopyError == true)                              // parser registered it
        let o = evaluateIngestOutcome(exitStatus: 0, ingest: i)     // shell said exit 0
        #expect(o.didFail == true)                                  // ...still a failure
        #expect(o.status == .error)
    }

    // MARK: - canAdmitIngest (destination-aware concurrent scheduler, Phase 2)

    private func snap(_ running: [dev_t], demo: Bool = false, cap: Int = 3) -> SchedulerSnapshot {
        SchedulerSnapshot(runningDestDevices: running, demoActive: demo, maxConcurrent: cap)
    }

    @Test func schedulerAdmitsWhenIdle() {
        #expect(canAdmitIngest(candidateDestDevice: 10, snapshot: snap([])) == true)
    }

    @Test func schedulerNeverAdmitsDuringDemo() {
        #expect(canAdmitIngest(candidateDestDevice: 10, snapshot: snap([], demo: true)) == false)
    }

    /// The safety invariant: never two cards onto the SAME physical drive at once.
    @Test func schedulerBlocksSecondCardToSameDrive() {
        #expect(canAdmitIngest(candidateDestDevice: 10, snapshot: snap([10])) == false)
    }

    /// The new capability: cards to DIFFERENT drives run in parallel.
    @Test func schedulerAllowsParallelAcrossDifferentDrives() {
        #expect(canAdmitIngest(candidateDestDevice: 20, snapshot: snap([10])) == true)
    }

    @Test func schedulerRespectsConcurrencyCap() {
        #expect(canAdmitIngest(candidateDestDevice: 30, snapshot: snap([10, 20], cap: 2)) == false)
        #expect(canAdmitIngest(candidateDestDevice: 30, snapshot: snap([10, 20], cap: 3)) == true)
    }

    /// stat() failed (nil device) — can't dedupe by drive, but still admit under cap.
    @Test func schedulerAdmitsUnknownDeviceWhenUnderCap() {
        #expect(canAdmitIngest(candidateDestDevice: nil, snapshot: snap([10])) == true)
    }

    // MARK: - buildIngestArgs (N-way destination routing, Phase 2)

    /// Minimal config that mimics today's default single-destination ingest. Override the
    /// pieces a given test cares about; everything else stays at the "shipped default".
    private func cfg(useCustomDest: Bool = false,
                     destRoot: String = "/Volumes/SSD",
                     projectName: String = "Shoot",
                     secondaryPaths: [String] = [],
                     dateFilterMode: String = "all",
                     verifyTransfer: Bool = false,
                     finderTagEnabled: Bool = false,
                     ignoreManifest: Bool = false,
                     subfolder: String = "Default") -> IngestArgsConfig {
        IngestArgsConfig(
            scriptPath: "/app/CardRunner.sh", appVersion: "1.0", cardPath: "/Volumes/CARD",
            useCustomDest: useCustomDest, destRoot: destRoot,
            projectRoot: useCustomDest ? destRoot : "\(destRoot)/\(projectName)",
            projectName: projectName, selectedSubfolder: subfolder,
            useCustomCardName: false, customCardName: "", ignoreManifest: ignoreManifest,
            latestCount: 0, dryRun: false,
            wrongClockDate: nil, reelFilter: [], reelMulti: false, dateOverride: nil,
            dateFilterMode: dateFilterMode, dateFilterFrom: "", dateFilterTo: "",
            dateFilterSubMode: "single", autoEject: false, fullVerifyEnabled: false,
            verifyTransfer: verifyTransfer, transferReportEnabled: false,
            secondaryPaths: secondaryPaths, renameOnIngestEnabled: false, renameTemplate: "",
            winterOlympicsMode: false, olympicsCode: "", scaffoldEnabled: false,
            scaffoldFolderList: [], copyXML: false, importMode: "video", includeProxies: false,
            ingestOrder: "oldest", dateFolderFormat: "%y%m%d", broadcastDayFolders: false,
            dayStartHour: 4, finderTagEnabled: finderTagEnabled, finderTagColor: "green")
    }

    /// Pull every value that follows an occurrence of `flag` in the argv.
    private func values(of flag: String, in args: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == flag, i + 1 < args.count { out.append(args[i + 1]); i += 2 }
            else { i += 1 }
        }
        return out
    }

    /// (a) MIRROR: one `--secondary` is emitted per mirror target, in order.
    @Test func buildArgsEmitsOneSecondaryPerMirrorTarget() {
        let args = buildIngestArgs(cfg(secondaryPaths: ["/Volumes/Backup1", "/Volumes/Backup2", "/Volumes/Backup3"]))
        let secs = values(of: "--secondary", in: args)
        #expect(secs == ["/Volumes/Backup1", "/Volumes/Backup2", "/Volumes/Backup3"])
        #expect(args.filter { $0 == "--secondary" }.count == 3)
    }

    /// (b) nil→default resolution: with NO mirror targets the args are exactly today's
    /// single-destination argv — `--primary <root>` + `--project`, and NO `--secondary`.
    @Test func buildArgsDefaultSingleDestMatchesLegacy() {
        let args = buildIngestArgs(cfg(destRoot: "/Volumes/SSD", projectName: "Shoot",
                                       dateFilterMode: "today", verifyTransfer: true))
        #expect(values(of: "--primary", in: args) == ["/Volumes/SSD"])
        #expect(values(of: "--project", in: args) == ["Shoot"])
        #expect(args.contains("--today-only"))
        #expect(args.contains("--verify"))
        #expect(args.contains("--secondary") == false)   // no mirror → no secondary, ever
        #expect(args.contains("--dest-root") == false)    // SSD mode, not custom
    }

    /// (c) destinationIsOnCard filtering happens UPSTREAM of the builder, so a mirror target
    /// equal to the primary destination must already be excluded from `secondaryPaths` — the
    /// builder must never emit a `--secondary` that duplicates the primary `--primary` root.
    @Test func buildArgsNeverMirrorsToTheSourcePrimary() {
        // Caller is responsible for filtering; the builder simply emits what it's given.
        // This documents the contract: an EMPTY filtered list yields no --secondary, so a
        // mirror==source case (filtered to empty upstream) routes exactly like the default.
        let filtered: [String] = []   // primary == only candidate → filtered out upstream
        let args = buildIngestArgs(cfg(destRoot: "/Volumes/SSD", secondaryPaths: filtered))
        #expect(args.contains("--secondary") == false)
        #expect(values(of: "--primary", in: args) == ["/Volumes/SSD"])
    }

    /// Custom-folder destination uses `--dest-root` + a volume-root `--primary`, never `--project`.
    @Test func buildArgsCustomFolderUsesDestRoot() {
        let args = buildIngestArgs(cfg(useCustomDest: true, destRoot: "/Volumes/MySSD/Shoots/2026"))
        #expect(values(of: "--dest-root", in: args) == ["/Volumes/MySSD/Shoots/2026"])
        #expect(values(of: "--primary", in: args) == ["/Volumes/MySSD"])  // volume root, not the full path
        #expect(args.contains("--project") == false)
    }

    // MARK: - Destination model (migration + default resolution)

    @Test func destinationCodableRoundTrips() throws {
        let list = [
            Destination(path: "/Volumes/SSD", name: "SSD", isCustomFolder: false),
            Destination(path: "/Users/x/Footage", name: "Footage", isCustomFolder: true),
        ]
        let back = try dec.decode([Destination].self, from: try enc.encode(list))
        #expect(back == list)            // ids + fields survive a persistence round-trip
        #expect(back[1].isCustomFolder == true)
    }

    // MARK: - Failure-record clearing (footage safety — a success must only clear ITS OWN card)

    private func fr(_ name: String, uuid: String?, nick: String, proj: String) -> FailedIngestRecord {
        FailedIngestRecord(id: UUID(), cardName: name, volumeUUID: uuid, friendlyName: nick,
                           projectName: proj, failedAt: Date(), filesToCopy: 3, mbToCopy: 9, reason: "Error")
    }

    @Test func failureClearedBySameVolumeUUID() {
        let recs = [fr("Untitled", uuid: "UUID-A", nick: "", proj: "P")]
        let survive = failureRecordsSurviving(recs, afterSuccessOf: "Untitled", volumeUUID: "UUID-A", friendlyName: "", projectName: "P")
        #expect(survive.isEmpty)                         // exact same card → record cleared
    }

    @Test func failureKeptForDifferentVolumeUUID() {
        let recs = [fr("Untitled", uuid: "UUID-A", nick: "", proj: "P")]
        let survive = failureRecordsSurviving(recs, afterSuccessOf: "Untitled", volumeUUID: "UUID-B", friendlyName: "", projectName: "P")
        #expect(survive.count == 1)                      // different physical card → warning KEPT
    }

    @Test func failureKeptForFATCardSameNameNoNickname() {
        // The footage-safety bug: two un-nicknamed exFAT "Untitled" cards (no UUID) in one project.
        // A success of one must NEVER clear the other's "do not format" warning.
        let recs = [fr("Untitled", uuid: nil, nick: "", proj: "P")]
        let survive = failureRecordsSurviving(recs, afterSuccessOf: "Untitled", volumeUUID: nil, friendlyName: "", projectName: "P")
        #expect(survive.count == 1)                      // un-nicknamed, no UUID → KEPT (safe direction)
    }

    @Test func failureClearedWhenNameAndNicknameMatch() {
        let recs = [fr("Untitled", uuid: nil, nick: "Lucas", proj: "P")]
        let survive = failureRecordsSurviving(recs, afterSuccessOf: "Untitled", volumeUUID: nil, friendlyName: "Lucas", projectName: "P")
        #expect(survive.isEmpty)                         // same name + same nickname → cleared
    }

    @Test func failureKeptForDifferentProject() {
        let recs = [fr("Untitled", uuid: "UUID-A", nick: "", proj: "ProjectOne")]
        let survive = failureRecordsSurviving(recs, afterSuccessOf: "Untitled", volumeUUID: "UUID-A", friendlyName: "", projectName: "ProjectTwo")
        #expect(survive.count == 1)                      // different project → warning KEPT
    }

    // MARK: - Awaiting-card dedup (Auto-Ingest OFF "waiting to route" surfacing)
    // A detected card must surface as an awaiting lane unless it's already on screen.
    // Critical: two UUID-less same-named cards must BOTH surface (match path, not name).

    @Test func awaitingFreshCardSurfaces() {
        #expect(cardIsAlreadyTracked(cardPath: "/Volumes/Untitled", cardUUID: "U-A",
                                     awaitingPaths: [], activeUUIDs: [], activePaths: []) == false)
    }

    @Test func awaitingSuppressedWhenAlreadyParked() {
        #expect(cardIsAlreadyTracked(cardPath: "/Volumes/Untitled", cardUUID: "U-A",
                                     awaitingPaths: ["/Volumes/Untitled"], activeUUIDs: [], activePaths: []) == true)
    }

    @Test func awaitingSuppressedWhenLiveLaneSamePath() {
        #expect(cardIsAlreadyTracked(cardPath: "/Volumes/Untitled", cardUUID: nil,
                                     awaitingPaths: [], activeUUIDs: [], activePaths: ["/Volumes/Untitled"]) == true)
    }

    @Test func awaitingSuppressedWhenLiveLaneSameUUID() {
        // Same physical card (UUID) even if its mount path differs from the recorded one.
        #expect(cardIsAlreadyTracked(cardPath: "/Volumes/Untitled 1", cardUUID: "U-A",
                                     awaitingPaths: [], activeUUIDs: ["U-A"], activePaths: ["/Volumes/Untitled"]) == true)
    }

    /// The P1 fix: two DIFFERENT UUID-less "Untitled" cards mount at distinct paths.
    /// One is mid-ingest; the second must STILL surface (name collision must not hide it).
    @Test func awaitingTwoDistinctUUIDlessSameNameCardsBothSurface() {
        // Card 2 at a distinct path while card 1 ("/Volumes/Untitled") is a live lane.
        #expect(cardIsAlreadyTracked(cardPath: "/Volumes/Untitled 1", cardUUID: nil,
                                     awaitingPaths: [], activeUUIDs: [], activePaths: ["/Volumes/Untitled"]) == false)
    }

    /// A finished/pulled card is no longer in activeIngests, so re-inserting it re-surfaces.
    @Test func awaitingFinishedCardReSurfacesOnReinsert() {
        #expect(cardIsAlreadyTracked(cardPath: "/Volumes/Untitled", cardUUID: "U-A",
                                     awaitingPaths: [], activeUUIDs: [], activePaths: []) == false)
    }

    /// The custom-name-memory fix: a UUID-bearing card already parked is treated as tracked
    /// even if it remounts at a NEW path — so its lane (and the operator's typed name) is not
    /// torn down and re-prefilled by a re-scan.
    @Test func awaitingSameUUIDAtNewPathStaysTracked() {
        #expect(cardIsAlreadyTracked(cardPath: "/Volumes/Untitled 1", cardUUID: "U-A",
                                     awaitingPaths: ["/Volumes/Untitled"], awaitingUUIDs: ["U-A"],
                                     activeUUIDs: [], activePaths: []) == true)
    }

    /// A genuinely different UUID-less card at a distinct path is still fresh (not falsely deduped).
    @Test func awaitingDifferentUUIDlessCardStillSurfaces() {
        #expect(cardIsAlreadyTracked(cardPath: "/Volumes/Untitled 1", cardUUID: nil,
                                     awaitingPaths: ["/Volumes/Untitled"], awaitingUUIDs: [],
                                     activeUUIDs: [], activePaths: []) == false)
    }

    // MARK: - Per-card folder label (--cardlabel) resolution

    @Test func cardLabelPerCardOverridesGlobal() {
        // A name typed on the lane wins over the global custom-card-name pref.
        #expect(resolveCardLabel(perCard: "A006", globalEnabled: true, globalName: "GLOBAL") == "A006")
    }

    @Test func cardLabelPerCardTrimmed() {
        #expect(resolveCardLabel(perCard: "  A007 ", globalEnabled: false, globalName: "") == "A007")
    }

    @Test func cardLabelEmptyPerCardMeansNoSubfolder() {
        // An explicitly-cleared per-card name → no --cardlabel, even if the global toggle is on.
        #expect(resolveCardLabel(perCard: "   ", globalEnabled: true, globalName: "GLOBAL") == "")
    }

    @Test func cardLabelNilFallsBackToGlobalWhenEnabled() {
        #expect(resolveCardLabel(perCard: nil, globalEnabled: true, globalName: "GLOBAL") == "GLOBAL")
    }

    @Test func cardLabelNilWithGlobalDisabledIsEmpty() {
        #expect(resolveCardLabel(perCard: nil, globalEnabled: false, globalName: "GLOBAL") == "")
    }

    // MARK: - --ignore-manifest (deliberate re-ingest of an already-offloaded card)

    @Test func buildArgsEmitsIgnoreManifestWhenSet() {
        let args = buildIngestArgs(cfg(ignoreManifest: true))
        #expect(args.contains("--ignore-manifest"))
    }

    @Test func buildArgsOmitsIgnoreManifestByDefault() {
        let args = buildIngestArgs(cfg())
        #expect(!args.contains("--ignore-manifest"))
    }

    // MARK: - Per-destination project folder resolution

    @Test func projectFolderPerDestWins() {
        #expect(resolveProjectFolder(destProject: "NWSL_Columbus", globalProject: "GLOBAL") == "NWSL_Columbus")
    }

    @Test func projectFolderEmptyFallsBackToGlobal() {
        #expect(resolveProjectFolder(destProject: "", globalProject: "GLOBAL") == "GLOBAL")
        #expect(resolveProjectFolder(destProject: "   ", globalProject: "GLOBAL") == "GLOBAL")
    }

    @Test func projectFolderTrims() {
        #expect(resolveProjectFolder(destProject: "  Shoot A ", globalProject: "GLOBAL") == "Shoot A")
    }

    /// Migration: a Destination JSON persisted BEFORE the projectFolder/subfolder fields existed
    /// must decode cleanly with defaults (empty project → global fallback; subfolder → Default).
    @Test func destinationDecodesLegacyJSONWithDefaults() throws {
        let legacy = #"{"id":"00000000-0000-0000-0000-000000000001","path":"/Volumes/Gallo 8TB","name":"Gallo 8TB","isCustomFolder":false}"#
        let d = try JSONDecoder().decode(Destination.self, from: Data(legacy.utf8))
        #expect(d.projectFolder == "")          // empty → falls back to global project at ingest
        #expect(d.subfolder == "Default")       // Default → shell "clips"
        #expect(d.name == "Gallo 8TB")
    }

    @Test func destinationRoundTripsWithNewFields() throws {
        let d = Destination(path: "/Volumes/SSD", name: "SSD", isCustomFolder: false,
                            projectFolder: "260630_Show", subfolder: "footage")
        let back = try JSONDecoder().decode(Destination.self, from: JSONEncoder().encode(d))
        #expect(back.projectFolder == "260630_Show")
        #expect(back.subfolder == "footage")
    }

    /// The migration-subfolder chain end: a non-Default subfolder (seeded on the migrated
    /// destination from the global) must flow to --subfolder; Default omits it (→ shell "clips").
    @Test func buildArgsEmitsSubfolderWhenNonDefault() {
        #expect(buildIngestArgs(cfg(subfolder: "footage")).contains("--subfolder"))
        #expect(values(of: "--subfolder", in: buildIngestArgs(cfg(subfolder: "footage"))) == ["footage"])
    }

    @Test func buildArgsOmitsSubfolderForDefault() {
        #expect(!buildIngestArgs(cfg(subfolder: "Default")).contains("--subfolder"))
    }
}
