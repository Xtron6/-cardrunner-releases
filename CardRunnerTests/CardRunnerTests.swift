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

    private func snap(_ running: [dev_t], demo: Bool = false, cap: Int = 3,
                      tiers: [dev_t: DriveTier] = [:]) -> SchedulerSnapshot {
        SchedulerSnapshot(runningDestDevices: running, demoActive: demo, maxConcurrent: cap,
                          destDriveTiers: tiers)
    }

    @Test func schedulerAdmitsWhenIdle() {
        #expect(canAdmitIngest(candidateDestDevice: 10, snapshot: snap([])) == true)
    }

    @Test func schedulerNeverAdmitsDuringDemo() {
        #expect(canAdmitIngest(candidateDestDevice: 10, snapshot: snap([], demo: true)) == false)
    }

    /// Slow drives (HDD / USB 2) stay sequential — parallel writes split seek bandwidth.
    @Test func schedulerBlocksSecondCardToSlowDrive() {
        #expect(canAdmitIngest(candidateDestDevice: 10, snapshot: snap([10], tiers: [10: .slow])) == false)
    }

    /// Fast SSDs allow same-drive parallel — write bandwidth handles two streams fine.
    @Test func schedulerAllowsSecondCardToFastDrive() {
        #expect(canAdmitIngest(candidateDestDevice: 10, snapshot: snap([10], tiers: [10: .fast])) == true)
        #expect(canAdmitIngest(candidateDestDevice: 10, snapshot: snap([10], tiers: [10: .medium])) == true)
    }

    /// Unknown drive tier defaults to .fast (pro audience uses fast SSDs; HDD user can set cap=1).
    @Test func schedulerAllowsSecondCardToUnknownDrive() {
        #expect(canAdmitIngest(candidateDestDevice: 10, snapshot: snap([10])) == true)
    }

    /// Cards to DIFFERENT drives always run in parallel regardless of tier.
    @Test func schedulerAllowsParallelAcrossDifferentDrives() {
        #expect(canAdmitIngest(candidateDestDevice: 20, snapshot: snap([10])) == true)
    }

    @Test func schedulerRespectsConcurrencyCap() {
        #expect(canAdmitIngest(candidateDestDevice: 30, snapshot: snap([10, 20], cap: 2)) == false)
        #expect(canAdmitIngest(candidateDestDevice: 30, snapshot: snap([10, 20], cap: 3)) == true)
    }

    /// Same-drive parallel counts toward the cap: 3 cards to 1 fast SSD, cap=3 → 3rd admitted, 4th blocked.
    @Test func schedulerSameDriveParallelRespectsCapFastDrive() {
        let tiers: [dev_t: DriveTier] = [10: .fast]
        #expect(canAdmitIngest(candidateDestDevice: 10, snapshot: snap([10, 10], cap: 3, tiers: tiers)) == true)
        #expect(canAdmitIngest(candidateDestDevice: 10, snapshot: snap([10, 10, 10], cap: 3, tiers: tiers)) == false)
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
            dryRun: false,
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

    /// tier-0 "Ingest all N clips" bypasses the date filter by running with dateFilterMode
    /// "all" — the builder must then emit NO date-filtering flag, so every clip is eligible
    /// (otherwise the same filter re-excludes everything and the prompt loops). Locks the
    /// guarantee the tier-0 bypass relies on.
    @Test func buildArgsAllDatesEmitsNoDateFilter() {
        let args = buildIngestArgs(cfg(destRoot: "/Volumes/SSD", projectName: "Shoot",
                                       dateFilterMode: "all"))
        #expect(args.contains("--today-only") == false)
        #expect(args.contains("--date-from") == false)
        #expect(args.contains("--dates") == false)
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

    // MARK: - detectCardMode (per-card content sniff)

    @Test func detectCardModeVideoOnly() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("clip.mov").path, contents: nil)
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("clip2.mp4").path, contents: nil)
        #expect(detectCardMode(at: tmp.path, globalFallback: "video") == "video")
        try! FileManager.default.removeItem(at: tmp)
    }

    @Test func detectCardModePhotoOnly() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("IMG_001.JPG").path, contents: nil)
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("IMG_002.CR3").path, contents: nil)
        #expect(detectCardMode(at: tmp.path, globalFallback: "video") == "photo")
        try! FileManager.default.removeItem(at: tmp)
    }

    @Test func detectCardModeMixedVideoWins() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for i in 0..<6 { FileManager.default.createFile(atPath: tmp.appendingPathComponent("clip\(i).mov").path, contents: nil) }
        for i in 0..<4 { FileManager.default.createFile(atPath: tmp.appendingPathComponent("img\(i).jpg").path, contents: nil) }
        #expect(detectCardMode(at: tmp.path, globalFallback: "video") == "video")
        try! FileManager.default.removeItem(at: tmp)
    }

    @Test func detectCardModeEmptyCardUsesGlobalFallback() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        #expect(detectCardMode(at: tmp.path, globalFallback: "photo") == "photo")
        try! FileManager.default.removeItem(at: tmp)
    }

    @Test func detectCardModePhotoWinsWhenMajority() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("a.mov").path, contents: nil)
        for i in 0..<9 { FileManager.default.createFile(atPath: tmp.appendingPathComponent("p\(i).arw").path, contents: nil) }
        #expect(detectCardMode(at: tmp.path, globalFallback: "video") == "photo")
        try! FileManager.default.removeItem(at: tmp)
    }

    @Test func detectCardModeM4ROOTStructure() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let m4root = tmp.appendingPathComponent("M4ROOT/CLIP", isDirectory: true)
        try FileManager.default.createDirectory(at: m4root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: m4root.appendingPathComponent("clip001.mxf").path, contents: nil)
        FileManager.default.createFile(atPath: m4root.appendingPathComponent("clip002.mxf").path, contents: nil)
        #expect(detectCardMode(at: tmp.path, globalFallback: "video") == "video")
        try FileManager.default.removeItem(at: tmp)
    }

    @Test func detectCardModeTHMBNLFilesExcluded() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let thmbnl = tmp.appendingPathComponent("THMBNL", isDirectory: true)
        try FileManager.default.createDirectory(at: thmbnl, withIntermediateDirectories: true)
        // Only "photos" are thumbnails — real content is video. THMBNL must be skipped.
        for i in 0..<10 { FileManager.default.createFile(atPath: thmbnl.appendingPathComponent("thumb\(i).jpg").path, contents: nil) }
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("clip.mxf").path, contents: nil)
        #expect(detectCardMode(at: tmp.path, globalFallback: "video") == "video")
        try FileManager.default.removeItem(at: tmp)
    }

    // MARK: - deriveDestName (auto destination naming — date-strip + camelCase/acronym/connector spacing)

    @Test func deriveDestSplitsCamelKeepsAcronymAndGluedConnector() {
        // Strip date, camelCase-split, keep HOKA verbatim. A lowercase-GLUED connector stays glued
        // ("Festivalof") — we no longer un-glue it, because that mangled real words (see below).
        #expect(deriveDestName(fromProject: "260603_HOKAFestivalofMiles") == "HOKA Festivalof Miles")
    }
    @Test func deriveDestCapitalizedConnectorSplitsAndLowercases() {
        // A Capital-cased connector IS a camelCase boundary → splits and lowercases cleanly.
        #expect(deriveDestName(fromProject: "FestivalOfMiles") == "Festival of Miles")
    }
    @Test func deriveDestPreservesAcronymRuns() {
        // All-caps runs (NWSL) are preserved as-is; the rest is spaced + Title-Cased.
        #expect(deriveDestName(fromProject: "260626_NWSLColumbusGame") == "NWSL Columbus Game")
    }
    @Test func deriveDestDoesNotSplitRealWordsEndingInConnectorLetters() {
        // The regression Xavier hit: these must NOT be split by a connector heuristic.
        #expect(deriveDestName(fromProject: "260730_TorontoTennis") == "Toronto Tennis")
        #expect(deriveDestName(fromProject: "260515_Conor Daly Doc_Year 2") == "Conor Daly Doc Year 2")
        #expect(deriveDestName(fromProject: "WaterproofCase") == "Waterproof Case")
    }
    @Test func deriveDestStripsYYYYMMDDPrefix() {
        #expect(deriveDestName(fromProject: "20260626_Foo") == "Foo")
    }
    @Test func deriveDestStripsISODatePrefix() {
        #expect(deriveDestName(fromProject: "2026-06-26_Bar") == "Bar")
    }
    @Test func deriveDestSpacesCamelAndLoneCap() {
        // "BRoll" → "B Roll" (acronym-end boundary); "Steadicam" stays one word.
        #expect(deriveDestName(fromProject: "SteadicamBRoll") == "Steadicam B Roll")
    }
    @Test func deriveDestFirstWordCapitalizedEvenIfConnector() {
        // A connector is lowercased only when it isn't the first word.
        #expect(deriveDestName(fromProject: "theBigGame") == "The Big Game")
    }
    @Test func deriveDestLowercasesInteriorConnector() {
        #expect(deriveDestName(fromProject: "soundOfMusic") == "Sound of Music")
    }
    @Test func deriveDestSplitsOnUnderscoresAndHyphens() {
        #expect(deriveDestName(fromProject: "260626_columbus-game_broll") == "Columbus Game Broll")
    }
    @Test func deriveDestDateOnlyFallsBackToRaw() {
        // Stripping would leave nothing → keep the raw folder name rather than an empty name.
        #expect(deriveDestName(fromProject: "260626_") == "260626_")
    }

    // MARK: - MHLWriter (ASC MHL sidecar generation)

    @Test func mhlWriterGeneratesValidXML() {
        let entry = MHLHashEntry(
            relativePath: "clips/260729/A001.mxf",
            sha256Hex: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
            fileSize: 1_073_741_824,
            modificationDate: Date(timeIntervalSince1970: 1722200000)
        )
        let xml = MHLWriter.generateXML(entries: [entry])
        #expect(xml.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        // Conformant ASC MHL v1.1 — version string matches the v1.1 body (<file>, not <path>).
        #expect(xml.contains("<hashlist version=\"1.1\">"))
        #expect(!xml.contains("version=\"2.0\""))
        #expect(xml.contains("<file>clips/260729/A001.mxf</file>"))
        #expect(xml.contains("<sha256>a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2</sha256>"))
        #expect(xml.contains("<size>1073741824</size>"))
        #expect(xml.contains("<creatorinfo>"))
        #expect(xml.contains("<name>CardRunner</name>"))
        #expect(xml.contains("</hashlist>"))
    }

    @Test func mhlWriterEscapesSpecialChars() {
        let entry = MHLHashEntry(
            relativePath: "clips/A&B <C> \"D\".mxf",
            sha256Hex: "abcd1234",
            fileSize: 100,
            modificationDate: Date()
        )
        let xml = MHLWriter.generateXML(entries: [entry])
        #expect(xml.contains("A&amp;B &lt;C&gt; &quot;D&quot;.mxf"))
        #expect(!xml.contains("A&B"))  // raw & must not appear
    }

    @Test func mhlWriterEmptyEntriesGeneratesValidXML() {
        let xml = MHLWriter.generateXML(entries: [])
        #expect(xml.contains("<hashlist version=\"1.1\">"))
        #expect(xml.contains("</hashlist>"))
        #expect(!xml.contains("<hash>"))
    }

    @Test func mhlWriterSingleFileRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let entry = MHLHashEntry(
            relativePath: "test.mxf",
            sha256Hex: "deadbeef",
            fileSize: 42,
            modificationDate: Date()
        )
        let url = try MHLWriter.writeMHL(entries: [entry], to: tmp, cardName: "TestCard")
        #expect(url.pathExtension == "mhl")
        #expect(url.path.contains("ASC_MHL"))
        #expect(url.lastPathComponent.hasPrefix("TestCard_"))
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("<sha256>deadbeef</sha256>"))
        try FileManager.default.removeItem(at: tmp)
    }

    // MARK: - VerificationTier truth table

    @Test func tierNoneWhenFailed() {
        let t = determineVerificationTier(
            verifyEnabled: true, fullVerifyEnabled: true, mhlEnabled: true,
            mhlWritten: true, newFiles: 5, verifyCheckedCount: 5, didFail: true)
        #expect(t == nil)
    }

    @Test func tierNoneWhenNoFiles() {
        let t = determineVerificationTier(
            verifyEnabled: true, fullVerifyEnabled: true, mhlEnabled: false,
            mhlWritten: false, newFiles: 0, verifyCheckedCount: 0, didFail: false)
        #expect(t == nil)
    }

    @Test func tierSizeCheckedWhenNoVerify() {
        let t = determineVerificationTier(
            verifyEnabled: false, fullVerifyEnabled: false, mhlEnabled: false,
            mhlWritten: false, newFiles: 5, verifyCheckedCount: 0, didFail: false)
        #expect(t == .sizeChecked)
    }

    @Test func tierSpotVerifiedWhenVerifyOnly() {
        let t = determineVerificationTier(
            verifyEnabled: true, fullVerifyEnabled: false, mhlEnabled: false,
            mhlWritten: false, newFiles: 5, verifyCheckedCount: 3, didFail: false)
        #expect(t == .spotVerified(count: 3))
    }

    @Test func tierFullyVerifiedWhenFullVerify() {
        let t = determineVerificationTier(
            verifyEnabled: true, fullVerifyEnabled: true, mhlEnabled: false,
            mhlWritten: false, newFiles: 5, verifyCheckedCount: 5, didFail: false)
        #expect(t == .fullyVerified)
    }

    @Test func tierSealedWhenFullVerifyPlusMHL() {
        let t = determineVerificationTier(
            verifyEnabled: true, fullVerifyEnabled: true, mhlEnabled: true,
            mhlWritten: true, newFiles: 5, verifyCheckedCount: 5, didFail: false)
        #expect(t == .sealed)
    }

    @Test func tierFullyVerifiedWhenMHLEnabledButNotWritten() {
        // MHL enabled but write failed → degrade to fullyVerified, not sealed
        let t = determineVerificationTier(
            verifyEnabled: true, fullVerifyEnabled: true, mhlEnabled: true,
            mhlWritten: false, newFiles: 5, verifyCheckedCount: 5, didFail: false)
        #expect(t == .fullyVerified)
    }

    @Test func tierMHLEnabledForcesFullVerifyPath() {
        // mhlEnabled ON + fullVerifyEnabled OFF → still goes through full-verify path
        let t = determineVerificationTier(
            verifyEnabled: false, fullVerifyEnabled: false, mhlEnabled: true,
            mhlWritten: true, newFiles: 5, verifyCheckedCount: 0, didFail: false)
        #expect(t == .sealed)
    }

    // MARK: - buildIngestArgs with mhlEnabled

    @Test func buildArgsMHLEnabledForcesFullVerify() {
        var c = cfg()
        c.mhlEnabled = true
        c.fullVerifyEnabled = false
        c.verifyTransfer = false
        let args = buildIngestArgs(c)
        #expect(args.contains("--full-verify"))
        #expect(!args.contains("--verify"))
    }

    @Test func buildArgsMHLEnabledWithVerifyStillForcesFullVerify() {
        // mhlEnabled ON + verifyTransfer ON → --full-verify wins, no --verify
        var c = cfg(verifyTransfer: true)
        c.mhlEnabled = true
        let args = buildIngestArgs(c)
        #expect(args.contains("--full-verify"))
        #expect(!args.contains("--verify"))
    }

    // MARK: - VERIFY_OK parser accumulates full hashes

    @Test func parserAccumulatesFullHashFromVerifyOK() {
        let i = feed([
            "VERIFY_OK clip001.mxf a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
            "VERIFY_OK clip002.mxf deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
        ])
        #expect(i.verifyHashes.count == 2)
        #expect(i.verifyHashes["clip001.mxf"] == "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
        #expect(i.verifyHashes["clip002.mxf"] == "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
    }

    @Test func parserAccumulatesHashFromTaggedVerifyOK() {
        let i = feed(["VERIFY_OK id=3 clip.mxf abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234"])
        #expect(i.verifyHashes["clip.mxf"] == "abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234")
    }

    // MARK: - VerificationTier persistence

    @Test func verificationTierRoundTrips() {
        #expect(VerificationTier.fromStorage("sizeChecked") == .sizeChecked)
        #expect(VerificationTier.fromStorage("fullyVerified") == .fullyVerified)
        #expect(VerificationTier.fromStorage("sealed") == .sealed)
        #expect(VerificationTier.fromStorage("spotVerified:7") == .spotVerified(count: 7))
        #expect(VerificationTier.fromStorage("unknown") == .sizeChecked)  // safe default
    }

    @Test func historyEntryDecodesLegacyWithoutTier() throws {
        let e = IngestHistoryEntry(
            cardName: "CARD", status: "Completed", newFiles: 10, skippedFiles: 0,
            avgMBps: 500, durationSec: 5, destPath: "/Volumes/SSD/Shoot/260101")
        let data = try enc.encode(e)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "verificationTierRaw")
        let trimmed = try JSONSerialization.data(withJSONObject: obj)
        let back = try dec.decode(IngestHistoryEntry.self, from: trimmed)
        #expect(back.verificationTier == .sizeChecked)  // missing → safe default
    }

    // MARK: - CorrectionLogic — manifest round-trip

    @Test func correctionManifestRoundTrips() throws {
        let manifest = CorrectionManifest(
            runID: "corr-20260730120000-123",
            destPath: "/Volumes/SSD/Shoot/260730/OldLabel",
            timestamp: "2026-07-30T12:00:00Z",
            sourceVolume: "ABCD-1234",
            entries: [
                CorrectionManifestEntry(relPath: "DCIM/100MEDIA/A001.MP4", filename: "A001.MP4",
                                         size: 1024, hash: "deadbeef", label: "OldLabel",
                                         destPath: "/Volumes/SSD/Shoot/260730/OldLabel")
            ])
        let data = try JSONEncoder().encode(manifest)
        let back = try JSONDecoder().decode(CorrectionManifest.self, from: data)
        #expect(back == manifest)
    }

    @Test func correctionManifestLoadReturnsNilWhenMissing() {
        let tmp = NSTemporaryDirectory() + "cr_corr_missing_\(UUID().uuidString)"
        let result = loadManifest(destRoot: tmp, runID: "does-not-exist")
        #expect(result == nil)
    }

    @Test func correctionManifestLoadReturnsNilWhenMalformed() throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "cr_corr_malformed_\(UUID().uuidString)"
        let dir = root + "/.cardrunner/manifests"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/badrun.json"
        try "{ this is not valid json".write(toFile: path, atomically: true, encoding: .utf8)
        let result = loadManifest(destRoot: root, runID: "badrun")
        #expect(result == nil)
        try? fm.removeItem(atPath: root)
    }

    @Test func correctionManifestLoadRoundTripsFromDisk() throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "cr_corr_disk_\(UUID().uuidString)"
        let dir = root + "/.cardrunner/manifests"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let manifest = CorrectionManifest(runID: "run1", destPath: "\(root)/260730/Label",
                                           timestamp: "2026-07-30T12:00:00Z", sourceVolume: "vol",
                                           entries: [])
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: URL(fileURLWithPath: dir + "/run1.json"))
        let back = loadManifest(destRoot: root, runID: "run1")
        #expect(back?.runID == "run1")
        try? fm.removeItem(atPath: root)
    }

    // MARK: - CorrectionLogic — collision resolution

    private func makeTempDir() -> String {
        let path = NSTemporaryDirectory() + "cr_corr_test_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func collisionResolvesToMovedWhenNoTarget() throws {
        let fm = FileManager.default
        let dir = makeTempDir()
        defer { try? fm.removeItem(atPath: dir) }
        let src = URL(fileURLWithPath: dir).appendingPathComponent("src/a.mov")
        try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "hello".write(to: src, atomically: true, encoding: .utf8)
        let dst = URL(fileURLWithPath: dir).appendingPathComponent("dst/a.mov")
        let outcome = resolveCollision(sourceURL: src, targetURL: dst, sourceHash: nil, targetHash: nil,
                                        sourceLabel: "Card1", fileManager: fm)
        #expect(outcome == .moved)
        #expect(fm.fileExists(atPath: dst.path))
        #expect(!fm.fileExists(atPath: src.path))
    }

    @Test func collisionDedupesOnIdenticalHash() throws {
        let fm = FileManager.default
        let dir = makeTempDir()
        defer { try? fm.removeItem(atPath: dir) }
        let src = URL(fileURLWithPath: dir).appendingPathComponent("src/a.mov")
        let dst = URL(fileURLWithPath: dir).appendingPathComponent("dst/a.mov")
        try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "same content".write(to: src, atomically: true, encoding: .utf8)
        try "same content".write(to: dst, atomically: true, encoding: .utf8)
        let outcome = resolveCollision(sourceURL: src, targetURL: dst,
                                        sourceHash: "hash1", targetHash: "hash1",
                                        sourceLabel: "Card1", fileManager: fm)
        #expect(outcome == .deduped)
        #expect(!fm.fileExists(atPath: src.path))       // source cleaned up
        #expect(fm.fileExists(atPath: dst.path))         // target untouched
    }

    @Test func collisionDedupesOnByteCompareWhenNoHash() throws {
        let fm = FileManager.default
        let dir = makeTempDir()
        defer { try? fm.removeItem(atPath: dir) }
        let src = URL(fileURLWithPath: dir).appendingPathComponent("src/a.mov")
        let dst = URL(fileURLWithPath: dir).appendingPathComponent("dst/a.mov")
        try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "identical bytes here".write(to: src, atomically: true, encoding: .utf8)
        try "identical bytes here".write(to: dst, atomically: true, encoding: .utf8)
        let outcome = resolveCollision(sourceURL: src, targetURL: dst, sourceHash: nil, targetHash: nil,
                                        sourceLabel: "Card1", fileManager: fm)
        #expect(outcome == .deduped)
    }

    @Test func collisionSuffixesOnDifferingContent() throws {
        let fm = FileManager.default
        let dir = makeTempDir()
        defer { try? fm.removeItem(atPath: dir) }
        let src = URL(fileURLWithPath: dir).appendingPathComponent("src/a.mov")
        let dst = URL(fileURLWithPath: dir).appendingPathComponent("dst/a.mov")
        try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "source content".write(to: src, atomically: true, encoding: .utf8)
        try "different target content".write(to: dst, atomically: true, encoding: .utf8)
        let outcome = resolveCollision(sourceURL: src, targetURL: dst, sourceHash: "h1", targetHash: "h2",
                                        sourceLabel: "Card1", fileManager: fm)
        guard case .suffixed(let newName) = outcome else {
            Issue.record("expected .suffixed, got \(outcome)"); return
        }
        #expect(newName == "a__from-Card1.mov")
        #expect(fm.fileExists(atPath: dst.deletingLastPathComponent().appendingPathComponent(newName).path))
        #expect(!fm.fileExists(atPath: src.path))
        #expect(fm.fileExists(atPath: dst.path))  // original target untouched
    }

    @Test func collisionSuffixDisambiguatesOnRepeatCollision() throws {
        let fm = FileManager.default
        let dir = makeTempDir()
        defer { try? fm.removeItem(atPath: dir) }
        let dstDir = URL(fileURLWithPath: dir).appendingPathComponent("dst")
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let dst = dstDir.appendingPathComponent("a.mov")
        try "target".write(to: dst, atomically: true, encoding: .utf8)
        // Pre-occupy the first suffix candidate so the resolver must go to -2.
        try "already here".write(to: dstDir.appendingPathComponent("a__from-Card1.mov"),
                                  atomically: true, encoding: .utf8)

        let src = URL(fileURLWithPath: dir).appendingPathComponent("src/a.mov")
        try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "new source content".write(to: src, atomically: true, encoding: .utf8)

        let outcome = resolveCollision(sourceURL: src, targetURL: dst, sourceHash: "hA", targetHash: "hB",
                                        sourceLabel: "Card1", fileManager: fm)
        guard case .suffixed(let newName) = outcome else {
            Issue.record("expected .suffixed, got \(outcome)"); return
        }
        #expect(newName == "a__from-Card1-2.mov")
    }

    @Test func collisionIOFailureDoesNotStrandOrCrash() throws {
        let fm = FileManager.default
        let dir = makeTempDir()
        defer { try? fm.removeItem(atPath: dir) }
        // Source doesn't exist — moveItem/copyItem will fail. Must return .failed, not throw/crash.
        let src = URL(fileURLWithPath: dir).appendingPathComponent("nonexistent/a.mov")
        let dst = URL(fileURLWithPath: dir).appendingPathComponent("dst/a.mov")
        let outcome = resolveCollision(sourceURL: src, targetURL: dst, sourceHash: nil, targetHash: nil,
                                        sourceLabel: "Card1", fileManager: fm)
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)"); return
        }
    }

    // MARK: - CorrectionLogic — manifest reflects actual on-disk name (collision-rename /
    // RENAME_TEMPLATE drift). CardRunner.sh now records entry.filename via _rename_map
    // AFTER apply_rename_group runs, so it should be the REAL on-disk name, not the
    // pre-rename source basename. This test proves the Swift side correctly finds and
    // moves a file when the manifest entry's filename is the renamed one (simulating what
    // the shell now writes for a collision-renamed or template-renamed file) — and, by
    // contrast, demonstrates the failure mode if a manifest ever regresses to recording
    // the pre-rename name.

    @Test func manifestWithRenamedFilenameIsFoundAndMoved() throws {
        let fm = FileManager.default
        let root = makeTempDir()
        defer { try? fm.removeItem(atPath: root) }
        let oldDir = "\(root)/260730/OldLabel"
        try fm.createDirectory(atPath: oldDir, withIntermediateDirectories: true)
        // On disk, cardcopy/apply_rename_group already renamed the collided/templated file —
        // only the RENAMED name exists, the original source basename does not.
        try "renamed content".write(toFile: "\(oldDir)/A001__dup2.MP4", atomically: true, encoding: .utf8)

        let manifest = CorrectionManifest(
            runID: "run1", destPath: oldDir, timestamp: "t", sourceVolume: "Card1",
            entries: [
                // filename correctly reflects the on-disk (post-rename) name, as the
                // fixed CardRunner.sh now records via _rename_map.
                CorrectionManifestEntry(relPath: "DCIM/100MEDIA/A001.MP4", filename: "A001__dup2.MP4",
                                         size: 5, hash: nil, label: "OldLabel", destPath: oldDir)
            ])
        let result = performManifestCorrection(
            manifest: manifest, destRoot: root,
            oldLabelPath: "260730/OldLabel", newLabelPath: "260730/NewLabel",
            oldLabel: "OldLabel", newLabel: "NewLabel", sourceLabel: "Card1", fileManager: fm
        )
        #expect(result.movedCount == 1)
        #expect(result.effectiveLabel == "NewLabel")
        #expect(fm.fileExists(atPath: "\(root)/260730/NewLabel/A001__dup2.MP4"))
    }

    @Test func manifestWithStalePreRenameFilenameIsSkippedNotFailed() throws {
        // Guards the failure mode the fix addresses: if a manifest entry's filename is the
        // PRE-rename source basename (what CardRunner.sh used to write) while the actual
        // on-disk file has already been renamed, performManifestCorrection must not find
        // it — it's silently skipped (file "already moved or absent"), never counted as a
        // hard failure, and the aggregate correctly reports 0 successes so the caller
        // (ContentView.applyPendingFolderRename) falls through to the whole-folder fallback
        // instead of reporting success with the new label.
        let fm = FileManager.default
        let root = makeTempDir()
        defer { try? fm.removeItem(atPath: root) }
        let oldDir = "\(root)/260730/OldLabel"
        try fm.createDirectory(atPath: oldDir, withIntermediateDirectories: true)
        try "renamed content".write(toFile: "\(oldDir)/A001__dup2.MP4", atomically: true, encoding: .utf8)

        let manifest = CorrectionManifest(
            runID: "run1", destPath: oldDir, timestamp: "t", sourceVolume: "Card1",
            entries: [
                // Stale: pre-rename basename — does not exist on disk.
                CorrectionManifestEntry(relPath: "DCIM/100MEDIA/A001.MP4", filename: "A001.MP4",
                                         size: 5, hash: nil, label: "OldLabel", destPath: oldDir)
            ])
        let result = performManifestCorrection(
            manifest: manifest, destRoot: root,
            oldLabelPath: "260730/OldLabel", newLabelPath: "260730/NewLabel",
            oldLabel: "OldLabel", newLabel: "NewLabel", sourceLabel: "Card1", fileManager: fm
        )
        #expect(result.movedCount == 0)
        #expect(result.failedCount == 0)   // skip, not a hard failure
        #expect(result.effectiveLabel == "OldLabel")   // caller must fall through to whole-folder fallback
        // The renamed file must still be exactly where it was — never touched or lost.
        #expect(fm.fileExists(atPath: "\(oldDir)/A001__dup2.MP4"))
    }

    // MARK: - CorrectionLogic — orchestration aggregate counts

    @Test func orchestrationAggregatesCountsAcrossMixedOutcomes() throws {
        let fm = FileManager.default
        let root = makeTempDir()
        defer { try? fm.removeItem(atPath: root) }
        let oldDir = "\(root)/260730/OldLabel"
        let newDir = "\(root)/260730/NewLabel"
        try fm.createDirectory(atPath: oldDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: newDir, withIntermediateDirectories: true)

        // f1.mov: clean move (no target).
        try "f1".write(toFile: "\(oldDir)/f1.mov", atomically: true, encoding: .utf8)
        // f2.mov: dedupe (identical content already at target).
        try "f2-content".write(toFile: "\(oldDir)/f2.mov", atomically: true, encoding: .utf8)
        try "f2-content".write(toFile: "\(newDir)/f2.mov", atomically: true, encoding: .utf8)
        // f3.mov: suffix (different content at target).
        try "f3-source".write(toFile: "\(oldDir)/f3.mov", atomically: true, encoding: .utf8)
        try "f3-target".write(toFile: "\(newDir)/f3.mov", atomically: true, encoding: .utf8)
        // f4.mov: referenced in manifest but missing on disk — should be skipped, not failed.

        let manifest = CorrectionManifest(
            runID: "run1", destPath: oldDir, timestamp: "t", sourceVolume: "Card1",
            entries: [
                CorrectionManifestEntry(relPath: "f1.mov", filename: "f1.mov", size: 2, hash: nil, label: "OldLabel", destPath: oldDir),
                CorrectionManifestEntry(relPath: "f2.mov", filename: "f2.mov", size: 10, hash: nil, label: "OldLabel", destPath: oldDir),
                CorrectionManifestEntry(relPath: "f3.mov", filename: "f3.mov", size: 9, hash: nil, label: "OldLabel", destPath: oldDir),
                CorrectionManifestEntry(relPath: "f4.mov", filename: "f4.mov", size: 5, hash: nil, label: "OldLabel", destPath: oldDir),
            ])

        let result = performManifestCorrection(
            manifest: manifest, destRoot: root,
            oldLabelPath: "260730/OldLabel", newLabelPath: "260730/NewLabel",
            oldLabel: "OldLabel", newLabel: "NewLabel", sourceLabel: "Card1", fileManager: fm
        )

        #expect(result.movedCount == 1)
        #expect(result.dedupedCount == 1)
        #expect(result.suffixedCount == 1)
        #expect(result.failedCount == 0)   // missing entry is skipped, not counted as failed
        #expect(result.effectiveLabel == "NewLabel")
        #expect(fm.fileExists(atPath: "\(newDir)/f1.mov"))
        #expect(!fm.fileExists(atPath: "\(oldDir)/f1.mov"))
    }

    @Test func orchestrationKeepsOldLabelWhenNothingSucceeds() throws {
        let fm = FileManager.default
        let root = makeTempDir()
        defer { try? fm.removeItem(atPath: root) }
        // No source files exist on disk at all — every entry is a skip, nothing moves.
        let manifest = CorrectionManifest(
            runID: "run1", destPath: "\(root)/260730/OldLabel", timestamp: "t", sourceVolume: "Card1",
            entries: [
                CorrectionManifestEntry(relPath: "ghost.mov", filename: "ghost.mov", size: 1, hash: nil,
                                         label: "OldLabel", destPath: "\(root)/260730/OldLabel")
            ])
        let result = performManifestCorrection(
            manifest: manifest, destRoot: root,
            oldLabelPath: "260730/OldLabel", newLabelPath: "260730/NewLabel",
            oldLabel: "OldLabel", newLabel: "NewLabel", sourceLabel: "Card1", fileManager: fm
        )
        #expect(result.effectiveLabel == "OldLabel")
        #expect(result.movedCount == 0)
    }

    @Test func relativeLabelDirMatchesExactLastComponentOnly() {
        let root = "/Volumes/SSD/Shoot"
        #expect(relativeLabelDir("/Volumes/SSD/Shoot/260730/OldLabel", destRoot: root, label: "OldLabel") == "260730/OldLabel")
        #expect(relativeLabelDir("/Volumes/SSD/Shoot/260730/ReelA/OldLabel", destRoot: root, label: "OldLabel") == "260730/ReelA/OldLabel")
        // Suffix match on a longer name must NOT count as a match.
        #expect(relativeLabelDir("/Volumes/SSD/Shoot/260730/OldLabelExtra", destRoot: root, label: "OldLabel") == nil)
        #expect(relativeLabelDir("/Other/Path/260730/OldLabel", destRoot: root, label: "OldLabel") == nil)
    }

    @Test func withLastComponentReplacedSwapsOnlyFinalSegment() {
        #expect(withLastComponentReplaced("260730/OldLabel", newLabel: "NewLabel") == "260730/NewLabel")
        #expect(withLastComponentReplaced("260730/ReelA/OldLabel", newLabel: "NewLabel") == "260730/ReelA/NewLabel")
    }

    // MARK: - CorrectionLogic — Finder-tag fallback refuses rather than guesses

    @Test func fallbackRefusesWhenNoManifestAndNoTagMarker() throws {
        let fm = FileManager.default
        let root = makeTempDir()
        defer { try? fm.removeItem(atPath: root) }
        let oldDir = "\(root)/260730/OldLabel"
        try fm.createDirectory(atPath: oldDir, withIntermediateDirectories: true)
        try "f1".write(toFile: "\(oldDir)/f1.mov", atomically: true, encoding: .utf8)  // untagged

        let result = performFallbackCorrection(
            destRoot: root, oldLabelPath: "260730/OldLabel", newLabelPath: "260730/NewLabel",
            oldLabel: "OldLabel", newLabel: "NewLabel", fileManager: fm
        )
        #expect(result.refused == true)
        #expect(result.effectiveLabel == "OldLabel")
        // Refusing must never touch the file.
        #expect(fm.fileExists(atPath: "\(oldDir)/f1.mov"))
    }

    // MARK: - Protocol-line parser extraction (handleProgressLineUI hardening)

    // --- crCeilKBToGB / parseDestInsufficient (KB → GB ceiling boundaries) ---

    @Test func ceilKBToGBBoundaries() {
        #expect(crCeilKBToGB(0) == 0)
        #expect(crCeilKBToGB(1) == 1)                 // 1 byte-worth over zero → 1 GB
        #expect(crCeilKBToGB(1048576) == 1)           // exactly 1 GiB → 1
        #expect(crCeilKBToGB(1048577) == 2)           // 1 KiB over 1 GiB → 2
        #expect(crCeilKBToGB(2097152) == 2)           // exactly 2 GiB → 2
        #expect(crCeilKBToGB(-5) == 0)                // garbage/negative → 0
    }

    @Test func destInsufficientParsesNeedAndFree() {
        let r = parseDestInsufficient("DEST_INSUFFICIENT need_kb=2097153 free_kb=1048576")
        #expect(r?.needGB == 3)   // ceil(2097153) = 3
        #expect(r?.freeGB == 1)   // exactly 1 GiB
    }

    @Test func destInsufficientFloorsNeedAtOneButFreeAtZero() {
        // need_kb present but tiny → floored to 1; free_kb=0 → 0.
        let r = parseDestInsufficient("DEST_INSUFFICIENT need_kb=1 free_kb=0")
        #expect(r?.needGB == 1)
        #expect(r?.freeGB == 0)
    }

    @Test func destInsufficientMissingNeedStaysZero() {
        // Missing need_kb keeps needGB at 0 (NOT floored to 1) — preserves original behavior.
        let r = parseDestInsufficient("DEST_INSUFFICIENT free_kb=1048577")
        #expect(r?.needGB == 0)
        #expect(r?.freeGB == 2)
    }

    @Test func destInsufficientEmptyFields() {
        let r = parseDestInsufficient("DEST_INSUFFICIENT")
        #expect(r?.needGB == 0)
        #expect(r?.freeGB == 0)
    }

    @Test func destInsufficientRejectsWrongPrefix() {
        #expect(parseDestInsufficient("DEST_FREE gb=10") == nil)
    }

    // --- parseVerifyFail (three shapes + malformed) ---

    @Test func verifyFailFileFormWins() {
        #expect(parseVerifyFail("VERIFY_FAIL file=A001.mov extra") == .named("A001.mov"))
    }

    @Test func verifyFailFilePrecedesFailedCount() {
        // Both present: file= takes priority (matches original branch order).
        #expect(parseVerifyFail("VERIFY_FAIL failed=3 file=clip.mov") == .named("clip.mov"))
    }

    @Test func verifyFailCountForm() {
        #expect(parseVerifyFail("VERIFY_FAIL failed=4") == .count(4))
    }

    @Test func verifyFailBareFallbackForm() {
        #expect(parseVerifyFail("VERIFY_FAIL B002.mxf") == .named("B002.mxf"))
    }

    @Test func verifyFailBarePrefixOnly() {
        // "VERIFY_FAIL " with nothing after → fallback drops prefix, first token is "".
        #expect(parseVerifyFail("VERIFY_FAIL ") == .named(""))
    }

    @Test func verifyFailRejectsWrongPrefix() {
        #expect(parseVerifyFail("VERIFY_PASS checked=3") == nil)
    }

    // --- parseVerifyRecovered / parseVerifyQuarantine (file-scoped recovery) ---

    @Test func verifyRecoveredParsesFileName() {
        #expect(parseVerifyRecovered("VERIFY_RECOVERED file=A001.mov") == "A001.mov")
    }

    @Test func verifyRecoveredRejectsWrongPrefix() {
        #expect(parseVerifyRecovered("VERIFY_QUARANTINE file=A001.mov") == nil)
        #expect(parseVerifyRecovered("VERIFY_FAIL file=A001.mov") == nil)
    }

    @Test func verifyQuarantineParsesFileName() {
        #expect(parseVerifyQuarantine("VERIFY_QUARANTINE file=B002.mxf") == "B002.mxf")
    }

    @Test func verifyQuarantineRejectsWrongPrefix() {
        #expect(parseVerifyQuarantine("VERIFY_RECOVERED file=B002.mxf") == nil)
    }

    // --- applyIngestProgressLine: recovery vs quarantine semantics ---

    @Test func recoveredIncrementsCountAndDoesNotTripCopyError() {
        let i = feed(["VERIFY_RECOVERED file=A001.mov"])
        #expect(i.recoveredFiles == 1)
        #expect(i.quarantinedFiles == 0)
        #expect(i.hasCopyError == false)
    }

    @Test func quarantineIncrementsCountAndTripsCopyError() {
        let i = feed(["VERIFY_QUARANTINE file=B002.mxf"])
        #expect(i.quarantinedFiles == 1)
        #expect(i.recoveredFiles == 0)
        #expect(i.hasCopyError == true)
    }

    @Test func recoveryCountsAccumulateAcrossLines() {
        let i = feed([
            "VERIFY_RECOVERED file=A001.mov",
            "VERIFY_RECOVERED file=A002.mov",
            "VERIFY_QUARANTINE file=B002.mxf",
        ])
        #expect(i.recoveredFiles == 2)
        #expect(i.quarantinedFiles == 1)
        // Any quarantine trips the footage-safety failure flag.
        #expect(i.hasCopyError == true)
    }

    @Test func recoveredOnlyRunPassesWithoutCopyError() {
        // Mirrors a shell run where every mismatch recovered: VERIFY_PASS summary,
        // recovered files counted, and NO copy error → auto-eject stays allowed.
        let i = feed([
            "VERIFY_RECOVERED file=A001.mov",
            "VERIFY_PASS checked=20 recovered=1",
        ])
        #expect(i.recoveredFiles == 1)
        #expect(i.hasCopyError == false)
    }

    @Test func quarantineRunFailsViaSummary() {
        // A run with a quarantine: the summary VERIFY_FAIL also trips the gate.
        let i = feed([
            "VERIFY_QUARANTINE file=B002.mxf",
            "VERIFY_FAIL checked=20 failed=1 recovered=0",
        ])
        #expect(i.quarantinedFiles == 1)
        #expect(i.hasCopyError == true)
    }

    // --- parseCollisionRenamed (field splitting) ---

    @Test func collisionRenamedTwoFields() {
        let r = parseCollisionRenamed("COLLISION_RENAMED orig.mov orig_1.mov")
        #expect(r?.original == "orig.mov")
        #expect(r?.renamed == "orig_1.mov")
    }

    @Test func collisionRenamedExtraFieldsIgnored() {
        let r = parseCollisionRenamed("COLLISION_RENAMED a.mov a_1.mov trailing junk")
        #expect(r?.original == "a.mov")
        #expect(r?.renamed == "a_1.mov")
    }

    @Test func collisionRenamedMissingSecondFieldReturnsNil() {
        #expect(parseCollisionRenamed("COLLISION_RENAMED onlyone.mov") == nil)
    }

    @Test func collisionRenamedRejectsWrongPrefix() {
        #expect(parseCollisionRenamed("COLLISION_SKIP a b") == nil)
    }

    // --- parseVerifyOK (id stripping + hash prefix) ---

    @Test func verifyOKNameAndHashPrefix() {
        let v = parseVerifyOK("VERIFY_OK clip.mov 0123456789abcdef")
        #expect(v?.name == "clip.mov")
        #expect(v?.hash == "01234567")   // first 8 chars
        #expect(v?.id == nil)
    }

    @Test func verifyOKStripsIdPrefix() {
        let v = parseVerifyOK("VERIFY_OK id=7 shot.mxf deadbeefcafe")
        #expect(v?.id == "7")
        #expect(v?.name == "shot.mxf")
        #expect(v?.hash == "deadbeef")
    }

    @Test func verifyOKMissingHash() {
        let v = parseVerifyOK("VERIFY_OK lonely.mov")
        #expect(v?.name == "lonely.mov")
        #expect(v?.hash == "")
    }

    @Test func verifyOKShortHashNotPadded() {
        let v = parseVerifyOK("VERIFY_OK x.mov ab")
        #expect(v?.hash == "ab")
    }

    @Test func verifyOKEmptyBodyDefaultsName() {
        // "VERIFY_OK " with a trailing space splits to [""] → empty name (matches original).
        let v = parseVerifyOK("VERIFY_OK ")
        #expect(v?.name == "")
        #expect(v?.hash == "")
        // The "file" fallback only fires when the component list is truly empty.
        let v2 = parseVerifyOK("VERIFY_OK")   // no trailing space → nil (prefix requires it)
        #expect(v2 == nil)
    }

    @Test func verifyOKRejectsWrongPrefix() {
        #expect(parseVerifyOK("VERIFY_PASS checked=1") == nil)
    }

    // --- classifySecondaryError (reason= classification) ---

    @Test func secondaryErrorCopyFailedExtractsExit() {
        #expect(classifySecondaryError("SECONDARY_ERROR reason=copy_failed exit=23")
                == .copyFailed(exit: "23"))
    }

    @Test func secondaryErrorNotMounted() {
        #expect(classifySecondaryError("SECONDARY_ERROR reason=not_mounted dest=/Volumes/B")
                == .notMounted)
    }

    @Test func secondaryErrorGenericFallback() {
        #expect(classifySecondaryError("SECONDARY_ERROR reason=weird") == .generic)
    }

    @Test func secondaryErrorCopyFailedMissingExitTakesWholeLine() {
        // No exit= token: original math takes components.last (the whole line), trimmed.
        let line = "SECONDARY_ERROR reason=copy_failed"
        #expect(classifySecondaryError(line) == .copyFailed(exit: line))
    }

    @Test func secondaryErrorRejectsWrongPrefix() {
        #expect(classifySecondaryError("SECONDARY_PROGRESS dest=/Volumes/B") == nil)
    }

    // MARK: - MHLWriter — ASC MHL v1.1 conformance (golden round-trip)

    @Test func mhlWriterEmitsWellFormedConformantV11() throws {
        let entries = [
            MHLHashEntry(
                relativePath: "A001_C001/clip & take <1>.mov",
                sha256Hex: "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789",
                fileSize: 123456789,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            MHLHashEntry(
                relativePath: "A001_C002/clip.mxf",
                sha256Hex: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
                fileSize: 42,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_500)
            ),
        ]

        let xml = MHLWriter.generateXML(entries: entries, creatorInfo: "CardRunner", version: "1.9.0")

        // Version string must match the v1.1 body structure — never a mislabeled v2.0.
        #expect(xml.contains("<hashlist version=\"1.1\">"))
        #expect(!xml.contains("version=\"2.0\""))

        // Required v1.1 creatorinfo + per-file elements.
        #expect(xml.contains("<creatorinfo>"))
        #expect(xml.contains("<tool>CardRunner 1.9.0</tool>"))
        #expect(xml.contains("<hostname>"))
        #expect(xml.contains("<file>A001_C002/clip.mxf</file>"))
        #expect(xml.contains("<size>123456789</size>"))
        #expect(xml.contains("<lastmodificationdate>"))
        #expect(xml.contains("<hashdate>"))
        // Hash must be lowercased hex.
        #expect(xml.contains("<sha256>abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789</sha256>"))

        // Special characters must be XML-escaped in the path.
        #expect(xml.contains("clip &amp; take &lt;1&gt;.mov"))
        #expect(!xml.contains("clip & take <1>.mov"))

        // Must parse back as well-formed XML with no error.
        let data = try #require(xml.data(using: .utf8))
        let parser = XMLParser(data: data)
        let delegate = MHLParseChecker()
        parser.delegate = delegate
        let ok = parser.parse()
        #expect(ok)
        #expect(parser.parserError == nil)
        // Confirm the tree carries both file entries and the root element.
        #expect(delegate.elementCounts["hashlist"] == 1)
        #expect(delegate.elementCounts["hash"] == 2)
        #expect(delegate.elementCounts["file"] == 2)
        #expect(delegate.elementCounts["sha256"] == 2)
    }

    // MARK: - ReportGenerator (offload report export)

    private func makeEntry(card: String, files: Int, bytes: Int64, mbps: Int,
                           durationSec: Int, tier: String = "fullyVerified",
                           dest: String = "/Volumes/T7/Proj/clips") -> IngestHistoryEntry {
        IngestHistoryEntry(cardName: card, status: "Completed", newFiles: files,
                           skippedFiles: 0, avgMBps: mbps, durationSec: durationSec,
                           destPath: dest, mediaLabel: "clips",
                           totalBytesTransferred: bytes, verificationTierRaw: tier)
    }

    @Test func csvHasHeaderPlusOneRowPerEntry() {
        let entries = [
            makeEntry(card: "A001", files: 12, bytes: 5_000_000_000, mbps: 480, durationSec: 65),
            makeEntry(card: "B002", files: 30, bytes: 20_000_000_000, mbps: 620, durationSec: 200)
        ]
        let csv = ReportGenerator.generateCSV(entries: entries)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.count == 3)                       // header + 2 rows
        #expect(lines[0] == ReportGenerator.csvHeader)
        #expect(lines[1].contains("A001"))
        #expect(lines[2].contains("B002"))
        // Verification label surfaced verbatim.
        #expect(lines[1].contains("VERIFIED"))
    }

    @Test func csvEscapesCommasAndQuotes() {
        let e = makeEntry(card: "Cam \"A\", Card 1", files: 1, bytes: 1_073_741_824,
                          mbps: 100, durationSec: 10)
        let csv = ReportGenerator.generateCSV(entries: [e])
        let row = csv.split(separator: "\n").map(String.init)[1]
        // The card field must be quoted, with the embedded quote doubled.
        #expect(row.contains("\"Cam \"\"A\"\", Card 1\""))
        // The row still splits into exactly 9 logical columns despite the embedded comma —
        // verify the escaped field kept the comma inside the quotes (no stray column break).
        #expect(ReportGenerator.csvEscape("Cam \"A\", Card 1") == "\"Cam \"\"A\"\", Card 1\"")
    }

    @Test func emptyEntriesProducesHeaderOnlyCSV() {
        let csv = ReportGenerator.generateCSV(entries: [])
        #expect(csv == ReportGenerator.csvHeader + "\n")
    }

    // MARK: Speed columns (Lane 4 — TIER2-MERGE: peakMBps will come from entry field)

    @Test func reportCSVIncludesSpeedColumns() {
        // CSV header must include Peak MB/s column.
        #expect(ReportGenerator.csvHeader.contains("Peak MB/s"))
        // A row with a non-zero peak (simulated via a subclass/wrapper once Lane 1 merges;
        // for now we verify the column slot exists via the header split).
        let e = makeEntry(card: "A001", files: 12, bytes: 5_000_000_000, mbps: 631, durationSec: 65)
        let csv = ReportGenerator.generateCSV(entries: [e])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.count == 2)
        // Header must have 11 columns (9 original + Peak MB/s + Hardware).
        let headerCols = lines[0].split(separator: ",", omittingEmptySubsequences: false)
        #expect(headerCols.count == 11)
        // Data row must also have 11 columns.
        let dataCols = lines[1].split(separator: ",", omittingEmptySubsequences: false)
        #expect(dataCols.count == 11)
    }

    @Test func reportCSVOmitsPeakWhenZero() {
        // When peakMBps == 0 (not available), the Peak MB/s column must be empty string, not "0".
        // TIER2-MERGE: once Lane 1 adds peakMBps to IngestHistoryEntry, pass peakMBps: 0 explicitly.
        let e = makeEntry(card: "A001", files: 5, bytes: 1_073_741_824, mbps: 400, durationSec: 30)
        let csv = ReportGenerator.generateCSV(entries: [e])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.count == 2)
        let row = lines[1]
        // The Peak MB/s column (index 9) must be empty — ends with two trailing commas or comma-empty.
        // We check: the string "0" is NOT the peak column by verifying it doesn't end with ",0,"
        // and the row ends with ",," (both peak and hardware are empty).
        #expect(row.hasSuffix(",,"), "Peak column should be empty when peakMBps is 0; row: \(row)")
    }

    @Test func hardwarePathFormatsCorrectly() {
        // "USB" + "10Gb/s" + "Thunderbolt" + "40Gb/s" + "SSD" → "USB 10Gb/s→TB 40Gb/s SSD"
        let result = ReportGenerator.formatHardwarePath(
            sourceProtocol: "USB", sourceLink: "10Gb/s",
            destProtocol: "Thunderbolt", destLink: "40Gb/s",
            destMedia: "SSD"
        )
        #expect(result == "USB 10Gb/s → TB 40Gb/s SSD")
    }

    @Test func summaryTotalsAreCorrect() {
        // 5 GiB and 20 GiB exactly (bytes are GiB multiples).
        let entries = [
            makeEntry(card: "A", files: 10, bytes: 5 * 1_073_741_824, mbps: 400, durationSec: 100),
            makeEntry(card: "B", files: 15, bytes: 20 * 1_073_741_824, mbps: 600, durationSec: 300)
        ]
        let t = ReportGenerator.totals(for: entries)
        #expect(t.cards == 2)
        #expect(t.files == 25)
        #expect(abs(t.gib - 25.0) < 0.0001)
        #expect(t.durationSec == 400)
        // Duration-weighted avg: (400*100 + 600*300) / 400 = 550.
        #expect(t.sessionAvgMBps == 550)

        let summary = ReportGenerator.generateSummary(entries: entries, title: "Test Report")
        #expect(summary.contains("Cards: 2"))
        #expect(summary.contains("Files: 25"))
        #expect(summary.contains("25.00 GB"))
        #expect(summary.contains("550 MB/s"))
    }
}

// MARK: - Actionable notification action → Notification.Name mapping

@Suite("Notification actions")
struct NotificationActionTests {
    @Test("Reveal maps to Open Destination")
    func revealMapsToOpenDestination() {
        #expect(notificationName(forActionIdentifier: NotificationAction.reveal) == .menuOpenDestination)
    }

    @Test("Eject maps to Eject Card")
    func ejectMapsToEjectCard() {
        #expect(notificationName(forActionIdentifier: NotificationAction.eject) == .menuEjectCard)
    }

    @Test("Retry maps to Start Ingest")
    func retryMapsToStartIngest() {
        #expect(notificationName(forActionIdentifier: NotificationAction.retry) == .menuStartIngest)
    }

    @Test("Unknown/default identifiers map to nil")
    func unknownMapsToNil() {
        #expect(notificationName(forActionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier") == nil)
        #expect(notificationName(forActionIdentifier: "") == nil)
    }
}

// MARK: - locateManifest: walk-up manifest discovery (footage-misrouting bug fix)

@Suite("locateManifest walk-up")
struct LocateManifestTests {
    /// Standardize a path for robust comparison across macOS temp-dir symlinks
    /// (e.g. /var → /private/var).
    private func std(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func writeManifest(atRoot root: String, runID: String) throws {
        let dir = "\(root)/.cardrunner/manifests"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let manifest = CorrectionManifest(
            runID: runID,
            destPath: "\(root)/260730_TorontoTennis/clips/260801/xavier",
            timestamp: "2026-08-01T13:25:37Z",
            sourceVolume: "CardVol",
            entries: [
                CorrectionManifestEntry(relPath: "A001.mov", filename: "A001.mov", size: 100,
                                        hash: nil, label: "xavier",
                                        destPath: "\(root)/260730_TorontoTennis/clips/260801/xavier")
            ]
        )
        let data = try JSONEncoder().encode(manifest)
        FileManager.default.createFile(atPath: "\(dir)/\(runID).json", contents: data)
    }

    @Test("Finds manifest at an ancestor when starting from a deep descendant")
    func findsManifestAtAncestor() throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "cr-locate-\(UUID().uuidString)"
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        let runID = "corr-20260801132537-50532"
        try writeManifest(atRoot: root, runID: runID)

        // Deep descendant path — need not exist on disk; deletingLastPathComponent works regardless.
        let startDir = "\(root)/a/b/c"
        let located = locateManifest(startDir: startDir, runID: runID)
        #expect(located != nil)
        #expect(located?.manifest.runID == runID)
        #expect(located.map { std($0.root) } == std(root))
    }

    @Test("Returns nil when no manifest exists up the tree")
    func nilWhenNoManifest() throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "cr-locate-none-\(UUID().uuidString)"
        try fm.createDirectory(atPath: "\(root)/a/b/c", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        let located = locateManifest(startDir: "\(root)/a/b/c", runID: "corr-missing")
        #expect(located == nil)
    }

    @Test("Finds a manifest sitting exactly at startDir (zero walk-up)")
    func findsAtStartDir() throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "cr-locate-zero-\(UUID().uuidString)"
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        let runID = "corr-zero"
        try writeManifest(atRoot: root, runID: runID)

        let located = locateManifest(startDir: root, runID: runID)
        #expect(located != nil)
        #expect(located.map { std($0.root) } == std(root))
    }
}

/// Minimal XMLParser delegate that tallies element occurrences to prove well-formedness.
private final class MHLParseChecker: NSObject, XMLParserDelegate {
    var elementCounts: [String: Int] = [:]
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        elementCounts[elementName, default: 0] += 1
    }
}

// MARK: - Throughput diagnostics (peak / sustained)

@Suite("Throughput diagnostics")
struct ThroughputDiagnosticsTests {

    // ── sustainedMBps ────────────────────────────────────────────────
    @Test("Empty input returns 0")
    func sustainedEmpty() {
        #expect(sustainedMBps([]) == 0)
    }

    @Test("All-zero input returns 0")
    func sustainedAllZero() {
        #expect(sustainedMBps([0, 0, 0]) == 0)
    }

    @Test("All-equal samples return that value")
    func sustainedFlat() {
        #expect(sustainedMBps([120, 120, 120, 120]) == 120)
    }

    @Test("Ramp-up profile returns the plateau, not the leading low values")
    func sustainedIgnoresRampUp() {
        // Leading zeros + low ramp, then a stable ~200 MB/s plateau.
        let samples: [Double] = [0, 0, 5, 20, 60,
                                 200, 205, 198, 202, 199, 201, 200, 203, 197, 200]
        let s = sustainedMBps(samples)
        #expect(s >= 195 && s <= 205)
    }

    @Test("A single spike among a stable plateau does not blow up the result")
    func sustainedRobustToSpike() {
        let samples: [Double] = [150, 152, 149, 151, 150, 900, 150, 148, 151, 150]
        let s = sustainedMBps(samples)
        #expect(s >= 148 && s <= 153)   // median ignores the lone 900 spike
    }

    // ── updatedPeakMBps ──────────────────────────────────────────────
    @Test("Peak rises with a larger sample and ignores smaller / non-positive ones")
    func peakTracksMax() {
        var peak = 0
        peak = updatedPeakMBps(current: peak, sample: 100.4)   // rounds to 100
        #expect(peak == 100)
        peak = updatedPeakMBps(current: peak, sample: 80)      // smaller — no change
        #expect(peak == 100)
        peak = updatedPeakMBps(current: peak, sample: 255.6)   // rounds up to 256
        #expect(peak == 256)
        peak = updatedPeakMBps(current: peak, sample: 0)       // non-positive — no change
        #expect(peak == 256)
    }

    // ── appendDecimatingSample ───────────────────────────────────────
    @Test("Sample array is capped by decimation")
    func sampleArrayIsCapped() {
        var samples: [Double] = []
        for i in 0..<2000 { appendDecimatingSample(Double(i), to: &samples, cap: 600) }
        #expect(samples.count <= 600)
        #expect(!samples.isEmpty)
    }

    // MARK: - IngestHistoryEntry speed-diagnostic fields

    /// Round-trip: encode an entry with speed + hardware fields; decode and verify all survive.
    @Test func historyEntryRoundTripsSpeedFields() throws {
        let entry = IngestHistoryEntry(
            cardName: "CARD_A", status: "Completed",
            newFiles: 42, skippedFiles: 3,
            avgMBps: 320, durationSec: 90, destPath: "/Volumes/SSD/Project",
            peakMBps: 480, sustainedMBps: 410,
            sourceProtocol: "USB", sourceLink: "10Gb/s",
            destProtocol: "Thunderbolt", destLink: "40Gb/s", destMedia: "SSD"
        )
        let data = try enc.encode(entry)
        let decoded = try dec.decode(IngestHistoryEntry.self, from: data)
        #expect(decoded.peakMBps      == 480)
        #expect(decoded.sustainedMBps == 410)
        #expect(decoded.sourceProtocol == "USB")
        #expect(decoded.sourceLink     == "10Gb/s")
        #expect(decoded.destProtocol   == "Thunderbolt")
        #expect(decoded.destLink       == "40Gb/s")
        #expect(decoded.destMedia      == "SSD")
    }

    /// Legacy compat: a JSON blob without speed fields must decode to safe defaults (0 / "").
    @Test func historyEntryDecodesLegacyMissingFields() throws {
        let legacy = IngestHistoryEntry(
            cardName: "CARD_B", status: "Completed",
            newFiles: 10, skippedFiles: 0,
            avgMBps: 200, durationSec: 30, destPath: "/Volumes/SSD/Old"
        )
        // Drop all speed/hardware keys to simulate an entry written by an older build.
        var json = try #require(try JSONSerialization.jsonObject(with: enc.encode(legacy)) as? [String: Any])
        for key in ["peakMBps", "sustainedMBps", "sourceProtocol", "sourceLink",
                    "destProtocol", "destLink", "destMedia"] {
            json.removeValue(forKey: key)
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try dec.decode(IngestHistoryEntry.self, from: data)
        #expect(decoded.peakMBps       == 0)
        #expect(decoded.sustainedMBps  == 0)
        #expect(decoded.sourceProtocol == "")
        #expect(decoded.sourceLink     == "")
        #expect(decoded.destProtocol   == "")
        #expect(decoded.destLink       == "")
        #expect(decoded.destMedia      == "")
    }

    /// parseHardwareFields extracts USB source and SSD destination correctly.
    @Test func parseHardwareFieldsExtractsUSB() {
        let line = "2026-08-01 12:00:00 | ID=abc | Status=OK | Card=CARD_A | SourceProtocol=USB | SourceLink=10Gb/s | DestProtocol=Thunderbolt | DestLink=40Gb/s | DestMedia=SSD"
        let hw = parseHardwareFields(from: line)
        #expect(hw.srcProto == "USB")
        #expect(hw.srcLink  == "10Gb/s")
        #expect(hw.dstProto == "Thunderbolt")
        #expect(hw.dstLink  == "40Gb/s")
        #expect(hw.dstMedia == "SSD")
    }

    /// parseHardwareFields maps "unknown" values to empty strings.
    @Test func parseHardwareFieldsMapsUnknownToEmpty() {
        let line = "2026-08-01 12:00:00 | ID=xyz | Status=OK | Card=CARD_B | SourceProtocol=unknown | SourceLink=unknown | DestProtocol=unknown | DestLink=unknown | DestMedia=unknown"
        let hw = parseHardwareFields(from: line)
        #expect(hw.srcProto == "")
        #expect(hw.srcLink  == "")
        #expect(hw.dstProto == "")
        #expect(hw.dstLink  == "")
        #expect(hw.dstMedia == "")
    }

    /// sustainedMBps from a realistic sample set matches the expected median-of-core value.
    @Test func historyEntrySustainedMBpsFromSamples() {
        // Simulate: ramp (low), plateau, tail dropout
        let samples: [Double] = [50, 80, 100, 390, 400, 410, 405, 395, 0, 20, 380]
        let result = sustainedMBps(samples)
        // Positive samples: [50,80,100,390,400,410,405,395,20,380]
        // Median of positives ≈ 387.5 → threshold = 96.875
        // Core (≥ threshold): [100,390,400,410,405,395,380] → sorted median = 395
        #expect(result == 395)
    }
}

// MARK: - Bottleneck descriptor tests

@Suite("Bottleneck descriptor")
struct BottleneckDescriptorTests {

    @Test("Link parsing: 10Gb/s → 1250 MB/s, 40Gb/s → 5000 MB/s")
    func bottleneckLinkParsingGbps() {
        #expect(parseLinkMBps("10Gb/s") == 1250)
        #expect(parseLinkMBps("40Gb/s") == 5000)
        #expect(parseLinkMBps("5Gb/s")  == 625)
        #expect(parseLinkMBps("20Gb/s") == 2500)
    }

    @Test("Returns nil when both links are unknown")
    func bottleneckReturnsNilForUnknown() {
        let result = bottleneckDescriptor(sourceLink: "unknown", destLink: "unknown",
                                          avgMBps: 500, peakMBps: 600)
        #expect(result == nil)
    }

    @Test("Detects reader-limited when peak is near source cap")
    func bottleneckDetectsReaderLimit() {
        let result = bottleneckDescriptor(sourceLink: "10Gb/s", destLink: "40Gb/s",
                                          avgMBps: 1000, peakMBps: 1150)
        #expect(result?.hasPrefix("Reader-limited") == true)
    }

    @Test("Detects drive-limited when peak is near dest cap and well below source cap")
    func bottleneckDetectsDriveLimit() {
        let result = bottleneckDescriptor(sourceLink: "40Gb/s", destLink: "5Gb/s",
                                          avgMBps: 500, peakMBps: 580)
        #expect(result?.hasPrefix("Drive-limited") == true)
    }

    @Test("Detects below-expected when peak is far below both theoretical maxes")
    func bottleneckDetectsBelowExpected() {
        let result = bottleneckDescriptor(sourceLink: "10Gb/s", destLink: "5Gb/s",
                                          avgMBps: 80, peakMBps: 100)
        #expect(result?.contains("Below expected") == true)
    }

    @Test("Returns nil when peak is in an inconclusive middle range")
    func bottleneckInconclusiveReturnsNil() {
        let result = bottleneckDescriptor(sourceLink: "10Gb/s", destLink: "40Gb/s",
                                          avgMBps: 800, peakMBps: 900)
        #expect(result == nil)
    }
}
