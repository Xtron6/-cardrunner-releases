//  IngestLogic.swift — CardRunner
//  Pure, unit-tested footage-safety logic core extracted from ContentView.swift
//  (monolith split, Stage 1a). Free functions over IngestModels value types — no
//  ContentView coupling, no UI, no I/O: the authoritative success/failure gate
//  (evaluateIngestOutcome), arg builder (buildIngestArgs), progress parser
//  (applyIngestProgressLine), scheduler admission, failure-record survival, and
//  name/label/project resolution. See CardRunnerTests.
import Foundation

/// Build the exact CardRunner.sh argument vector for one ingest. Pure & deterministic so
/// the routing contract is unit-testable. CRITICAL invariant: with `secondaryPaths` empty
/// and a destination that resolves identically to the legacy config, this emits the SAME
/// args the app shipped with — so an untouched single-destination user ingests exactly as before.
func buildIngestArgs(_ c: IngestArgsConfig) -> [String] {
    var args: [String] = []
    args.append(c.scriptPath)
    args.append(contentsOf: ["--app-version", "v\(c.appVersion)"])
    args.append(contentsOf: ["--card", c.cardPath])

    if c.useCustomDest {
        args.append(contentsOf: ["--dest-root", c.destRoot])
        let urlComponents = URL(fileURLWithPath: c.destRoot).pathComponents
        let volumeRoot: String
        if urlComponents.count >= 3 && urlComponents[1] == "Volumes" {
            volumeRoot = "/" + urlComponents[1] + "/" + urlComponents[2]
        } else {
            volumeRoot = c.destRoot
        }
        args.append(contentsOf: ["--primary", volumeRoot])
    } else {
        let trimmedProject = c.projectName.trimmingCharacters(in: .whitespaces)
        args.append(contentsOf: ["--primary", c.destRoot])
        args.append(contentsOf: ["--project", trimmedProject])
    }

    if c.selectedSubfolder != "Default" {
        args.append(contentsOf: ["--subfolder", c.selectedSubfolder])
    }

    if c.useCustomCardName {
        let trimmedLabel = c.customCardName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLabel.isEmpty {
            args.append(contentsOf: ["--cardlabel", trimmedLabel])
        }
    }

    if c.ignoreManifest {
        args.append("--ignore-manifest")
    }

    if c.dryRun {
        args.append("--dry-run")
    }

    if let wcd = c.wrongClockDate {
        args += ["--date-override", wcd]
    }

    if !c.reelFilter.isEmpty {
        args += ["--reels", c.reelFilter.joined(separator: ",")]
        if c.reelMulti {
            args.append("--reel-multi")
        }
    }

    if let override = c.dateOverride {
        if override.contains(",") {
            args += ["--dates", override]
        } else {
            args += ["--date-from", override]
        }
    } else if c.wrongClockDate == nil {
        switch c.dateFilterMode {
        case "today":
            args.append("--today-only")
        case "yesterday":
            let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd"
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            args += ["--date-from", fmt.string(from: yesterday)]
        case "custom":
            if !c.dateFilterFrom.isEmpty {
                args += ["--date-from", c.dateFilterFrom]
                if c.dateFilterSubMode == "range" && !c.dateFilterTo.isEmpty {
                    args += ["--date-to", c.dateFilterTo]
                }
            }
        default: break
        }
    }

    if c.autoEject {
        args.append("--auto-eject")
    }

    if c.mhlEnabled || c.fullVerifyEnabled {
        // MHL requires inline SHA-256 from cardcopy → force --full-verify.
        args.append("--full-verify")
    } else if c.verifyTransfer {
        args.append("--verify")
    }

    if c.transferReportEnabled {
        args.append("--transfer-report")
    }

    // N-way mirror: one --secondary per mirror target (already filtered upstream to
    // exclude the primary dest and any path that lands on the source card).
    for sec in c.secondaryPaths {
        args.append(contentsOf: ["--secondary", sec])
    }

    if c.renameOnIngestEnabled {
        let tmpl = c.renameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tmpl.isEmpty {
            args.append(contentsOf: ["--rename-template", tmpl])
        }
    }

    if c.winterOlympicsMode {
        args.append("--winter-olympics")
        let trimmedCode = c.olympicsCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCode.isEmpty {
            args.append(contentsOf: ["--olympics-code", trimmedCode])
        }
    }

    if c.scaffoldEnabled {
        let pipeSeparated = c.scaffoldFolderList.joined(separator: "|")
        if !pipeSeparated.isEmpty {
            args.append(contentsOf: ["--scaffold", pipeSeparated])
        }
    }

    if c.copyXML && c.importMode != "photo" {
        args.append("--include-xml")
    }

    if c.includeProxies {
        args.append("--include-proxies")
    }

    if c.importMode == "photo" {
        args.append(contentsOf: ["--mode", "photo"])
    } else {
        args.append(contentsOf: ["--mode", "video"])
    }

    if c.ingestOrder == "newest" {
        args.append(contentsOf: ["--sort-order", "newest"])
    }

    if c.dateFolderFormat != "%y%m%d" {
        args.append(contentsOf: ["--date-format", c.dateFolderFormat])
    }

    if c.broadcastDayFolders {
        args.append(contentsOf: ["--broadcast-day-hour", "\(c.dayStartHour)"])
    }

    if c.finderTagEnabled {
        args.append(contentsOf: ["--finder-tag-color", c.finderTagColor])
    }

    return args
}

/// FOOTAGE-SAFETY (pure, unit-tested): which failure records SURVIVE when a card succeeds.
/// A record is cleared ONLY on positive same-card identity:
///   • matching volume UUID (APFS/HFS+ cards), OR
///   • when no UUID (FAT/exFAT camera cards, which share default names like "Untitled"),
///     a matching volume name AND a non-empty matching nickname.
/// It is NEVER cleared on a volume-name match alone — otherwise a successful un-nicknamed card
/// would wipe a DIFFERENT un-nicknamed card's "do not format" warning. When in doubt, KEEP the
/// record (the operator can dismiss it manually). Records in other projects always survive.
func failureRecordsSurviving(_ records: [FailedIngestRecord],
                             afterSuccessOf cardName: String, volumeUUID: String?,
                             friendlyName: String, projectName: String) -> [FailedIngestRecord] {
    let pn = projectName.trimmingCharacters(in: .whitespaces).lowercased()
    let cn = cardName.trimmingCharacters(in: .whitespaces).lowercased()
    let nick = friendlyName.trimmingCharacters(in: .whitespaces).lowercased()
    return records.filter { rec in
        guard rec.projectName.lowercased() == pn else { return true }          // different project → survives
        if let u = volumeUUID, let ru = rec.volumeUUID { return ru != u }      // same UUID → cleared
        guard !nick.isEmpty else { return true }                              // no UUID + un-nicknamed → keep
        return !(rec.cardName.lowercased() == cn && rec.friendlyName.lowercased() == nick)
    }
}

/// Pure success/failure evaluation. `exitStatus` is the process termination status.
func evaluateIngestOutcome(exitStatus: Int32, ingest: ActiveIngest) -> IngestOutcome {
    let didFail = (exitStatus != 0) || ingest.hasCopyError
    let status: IngestOutcome.Status
    if didFail {
        status = .error
    } else if ingest.newFiles == 0 {
        status = .upToDate
    } else {
        status = .completed
    }
    return IngestOutcome(
        didFail: didFail,
        status: status,
        bytesTransferred: didFail ? ingest.doneBytes : ingest.totalBytesNew,
        filesTransferred: didFail ? ingest.completedFiles : ingest.newFiles
    )
}

/// Extract the first integer token following `range` (e.g. after "new_files=").
func crExtractInt(from string: String, after range: Range<String.Index>) -> Int {
    let valuePart = string[range.upperBound...]
    let token = valuePart.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""
    return Int(token) ?? 0
}

func crExtractInt64(from string: String, after range: Range<String.Index>) -> Int64 {
    let valuePart = string[range.upperBound...]
    let token = valuePart.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""
    return Int64(token) ?? 0
}

/// Pure data-layer parser for ONE line of the shell→Swift progress protocol.
/// Applies only state mutations to the ActiveIngest — NO UI, sounds, or logging — so the
/// counting and error-flag logic that feeds the success gate (evaluateIngestOutcome) and
/// the session/lifetime stats can be unit-tested in isolation. The View's parseProgress
/// calls this for the data, then layers UI reactions on top (see handleProgressLineUI).
/// MUST stay in sync with the protocol emitted by CardRunner.sh / cardcopy.
func applyIngestProgressLine(_ line: String, to ingest: inout ActiveIngest) {
    if line.hasPrefix("PROGRESS_META") {
        if let r = line.range(of: "media_total=") { ingest.mediaTotal = crExtractInt(from: line, after: r) }
        if let r = line.range(of: "bytes_total=") { ingest.cardBytesTotal = crExtractInt64(from: line, after: r) }
        if let r = line.range(of: "new_files=") {
            let nNew = crExtractInt(from: line, after: r)
            ingest.newFiles       = nNew
            ingest.totalFiles     = nNew > 0 ? nNew : 1
            ingest.completedFiles = 0
        }
        if let r = line.range(of: "bytes_new=") {
            let nBytesNew = crExtractInt64(from: line, after: r)
            ingest.totalBytesNew = nBytesNew > 0
                ? nBytesNew
                : (ingest.cardBytesTotal > 0 ? ingest.cardBytesTotal : 0)
            ingest.completedFilesBytes   = 0
            ingest.currentFileSize       = 0
            ingest.currentIntraFileBytes = 0
        }

    } else if line.hasPrefix("PROGRESS_FILE ") {
        // Fires when cardcopy STARTS a file — commit the previous one first.
        if ingest.currentFileSize > 0 { ingest.completedFiles += 1 }
        ingest.completedFilesBytes   += ingest.currentFileSize
        ingest.currentIntraFileBytes  = 0
        var work = line.replacingOccurrences(of: "PROGRESS_FILE ", with: "")
        var sizeValue: Int64 = 0
        if let sizeRange = work.range(of: "size=") {
            let afterSize = work[sizeRange.upperBound...]
            let parts = afterSize.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if let sizeToken = parts.first { sizeValue = Int64(sizeToken) ?? 0 }
            work = parts.count > 1 ? String(parts[1]) : ""
        }
        ingest.currentFileSize = sizeValue
        if !work.isEmpty {
            let fname = (work as NSString).lastPathComponent
            ingest.currentFileName = fname
            // Unconditional (NOT gated on --verify) — defense-in-depth fallback list for
            // correction if the on-disk manifest JSON is missing. PROGRESS_FILE fires on
            // file START, not completion-confirmed, but the correction path re-verifies
            // existence/size on disk before moving anything, so an optimistic entry here
            // is harmless.
            ingest.copiedFiles.append(fname)
        }

    } else if line.hasPrefix("RUN_ID ") {
        let id = line.dropFirst("RUN_ID ".count).trimmingCharacters(in: .whitespaces)
        if !id.isEmpty { ingest.runID = id }

    } else if line.hasPrefix("PROGRESS_SUMMARY") {
        if let r = line.range(of: "avg_mb=") { ingest.avgMBps = crExtractInt(from: line, after: r) }
        if let r = line.range(of: "duration_sec=") { ingest.durationSec = crExtractInt(from: line, after: r) }
        // Snap to 100% — cardcopy finished; the last buffer may have flushed silently.
        if ingest.totalBytesNew > 0 {
            ingest.completedFilesBytes   = ingest.totalBytesNew
            ingest.currentFileSize       = 0
            ingest.currentIntraFileBytes = 0
        } else if ingest.totalFiles > 0 {
            ingest.completedFiles = ingest.totalFiles
        }

    } else if line.hasPrefix("SKIP_SUMMARY") {
        if let r = line.range(of: "manifest=")     { ingest.skipManifest    = crExtractInt(from: line, after: r) }
        if let r = line.range(of: "dest_exists=")  { ingest.skipDestExists  = crExtractInt(from: line, after: r) }
        if let r = line.range(of: "today_filter=") { ingest.skipTodayFilter = crExtractInt(from: line, after: r) }
        if let r = line.range(of: "wrong_mode=")   { ingest.skipWrongMode   = crExtractInt(from: line, after: r) }
        if let r = line.range(of: "proxy=")        { ingest.skipProxy       = crExtractInt(from: line, after: r) }
        if let r = line.range(of: "missing=")      { ingest.skipMissing     = crExtractInt(from: line, after: r) }

    } else if line.hasPrefix("FOLDERSYNC_START ") {
        // Shell emits "FOLDERSYNC_START dest=<full/path> mode=<mode>" at the start of each copy
        // group. This path includes the date + card-label subfolder — much more specific than the
        // PROGRESS_DEST clips root. Use it so F / Reveal land in the exact folder being populated.
        if let destRange = line.range(of: "dest=") {
            let afterDest = String(line[destRange.upperBound...])
            let path = afterDest.components(separatedBy: " mode=").first ?? afterDest
            if !path.isEmpty { ingest.destPath = path }
        }

    } else if line.hasPrefix("OPEN_TARGET ") {
        // Authoritative F / Reveal target computed by the shell: the exact clips
        // folder for a single-folder (single-day) offload, or the parent that holds
        // every date folder for a multi-day run. Overwrites any earlier path so
        // "open what I just offloaded" lands where the operator expects.
        let p = line.replacingOccurrences(of: "OPEN_TARGET ", with: "")
        if !p.isEmpty { ingest.destPath = p }

    } else if line.hasPrefix("PROGRESS_DEST ") {
        // Fallback: clips-root path emitted at end. Only use when a more specific
        // path (OPEN_TARGET / FOLDERSYNC_START) never set destPath (e.g. 0-new-file runs).
        let p = line.replacingOccurrences(of: "PROGRESS_DEST ", with: "")
        if ingest.destPath.isEmpty { ingest.destPath = p }

    } else if line.hasPrefix("VERIFY_PROGRESS") {
        if let rc = line.range(of: "current="), let rt = line.range(of: "total=") {
            ingest.verifyChecked = crExtractInt(from: line, after: rc)
            ingest.verifyTotal   = crExtractInt(from: line, after: rt)
        }

    } else if line.hasPrefix("VERIFY_RECOVERED") {
        // A file mismatched but was re-copied and now matches — treat as a pass.
        // Must NOT trip hasCopyError; footage is intact.
        if parseVerifyRecovered(line) != nil { ingest.recoveredFiles += 1 }

    } else if line.hasPrefix("VERIFY_QUARANTINE") {
        // A file still mismatched after re-copy — unrecoverable, real footage-safety
        // failure. Trips hasCopyError so eject is blocked and the run reads as failed.
        if parseVerifyQuarantine(line) != nil {
            ingest.quarantinedFiles += 1
            ingest.hasCopyError = true
        }

    } else if line.hasPrefix("VERIFY_PASS") {
        ingest.verifyChecked = ingest.verifyTotal

    } else if line.hasPrefix("VERIFY_FAIL") {
        ingest.hasCopyError = true

    } else if line.hasPrefix("RSYNC_ERROR") || line.hasPrefix("COPY_ERROR") {
        ingest.hasCopyError = true

    } else if line.hasPrefix("DEST_FREE gb=") {
        let gbStr = line.replacingOccurrences(of: "DEST_FREE gb=", with: "").trimmingCharacters(in: .whitespaces)
        if let gb = Double(gbStr) { ingest.destFreeGB = gb }

    } else if line.hasPrefix("DEST_INSUFFICIENT") {
        ingest.hasCopyError = true

    } else if line.hasPrefix("COLLISION_RENAMED ") {
        let parts = line.dropFirst("COLLISION_RENAMED ".count).components(separatedBy: " ")
        if parts.count >= 2 {
            ingest.collisionRenames.append((original: parts[0], renamed: parts[1]))
        }

    } else if line.hasPrefix("PHASE ") {
        let token = line.dropFirst("PHASE ".count)
            .split(separator: " ", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let newPhase = IngestPhase(rawValue: token) ?? .idle
        ingest.phase = newPhase
        // Authoritative failure signal from the shell — trips the gate even if the
        // non-zero exit were somehow missed.
        if newPhase == .failed { ingest.hasCopyError = true }

    } else if line.hasPrefix("VERIFY_OK ") {
        // Accumulate the FULL SHA-256 hash from cardcopy's inline verification.
        // Format: "VERIFY_OK <filename> <sha256hex>" or "VERIFY_OK id=N <filename> <sha256hex>"
        let payload = String(line.dropFirst("VERIFY_OK ".count))
        var parts = payload.components(separatedBy: " ")
        // Strip optional "id=N" prefix (tagged mode for parallel secondary copies).
        if let first = parts.first, first.hasPrefix("id=") { parts.removeFirst() }
        if parts.count >= 2 {
            let filename = parts[0]
            let fullHash = parts[1]   // FULL SHA-256, not truncated
            ingest.verifyHashes[filename] = fullHash
        }

    } else if line.hasPrefix("EJECT_FAILED") || line.hasPrefix("EJECT_SKIPPED") {
        // Post-copy eject failure/skip — the copy already succeeded, so this must NOT
        // trip hasCopyError. Tracked separately so the UI can nudge the user to eject manually.
        ingest.ejectFailed = true

    } else if line.hasPrefix("VERIFY_SKIP")
           || line.hasPrefix("SECONDARY_PROGRESS dest=") || line.hasPrefix("SECONDARY_ERROR")
           || line.hasPrefix("TRANSFER_REPORT path=") {
        // UI/log only — no ingest state.

    } else {
        // cardcopy polling-thread line: "  80904192  30%  154.21MB/s  0:00:01"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[1].hasSuffix("%") {
            let byteStr = parts[0].replacingOccurrences(of: ",", with: "")
            if let intraBytes = Int64(byteStr) { ingest.currentIntraFileBytes = intraBytes }
            if parts.count >= 3 {
                let speedToken = String(parts[2])
                if speedToken.hasSuffix("MB/s"), let val = Double(speedToken.dropLast(4)), val > 0 {
                    ingest.liveMBps = val
                } else if speedToken.hasSuffix("GB/s"), let val = Double(speedToken.dropLast(4)), val > 0 {
                    ingest.liveMBps = val * 1024.0
                } else if speedToken.hasSuffix("kB/s"), let val = Double(speedToken.dropLast(4)), val > 0 {
                    ingest.liveMBps = val / 1024.0
                }
            }
        }
    }
}

// MARK: - Pure protocol-line parsers (UI-layer, side-effect-free)
//
// These extract the small typed facts out of the safety-critical cardcopy protocol lines
// so the parsing can be unit-tested in isolation. The View's handleProgressLineUI calls
// these, then applies its side effects (appendLog / statusText / AudioEngine / alerts).
// MUST stay in sync with the protocol emitted by CardRunner.sh / cardcopy.

/// KB → GB with ceiling rounding: `ceil(kb / 1048576)`. Matches the historic
/// `(kb + 1048575) / 1048576` integer math exactly (1 KiB..1 GiB → 1, etc.).
func crCeilKBToGB(_ kb: Int) -> Int {
    if kb <= 0 { return 0 }
    return (kb + 1048575) / 1048576
}

/// Parse `DEST_INSUFFICIENT ... need_kb=<n> free_kb=<n>` into GB figures.
/// Preserves the original flooring behavior: a missing `need_kb` yields 0 (not 1);
/// a present `need_kb` is floored at 1 GB; `free_kb` is floored at 0.
func parseDestInsufficient(_ line: String) -> (needGB: Int, freeGB: Int)? {
    guard line.hasPrefix("DEST_INSUFFICIENT") else { return nil }
    var needGB = 0
    var freeGB = 0
    if let r = line.range(of: "need_kb=") {
        needGB = max(1, crCeilKBToGB(crExtractInt(from: line, after: r)))
    }
    if let r = line.range(of: "free_kb=") {
        freeGB = max(0, crCeilKBToGB(crExtractInt(from: line, after: r)))
    }
    return (needGB, freeGB)
}

/// Result of parsing a `VERIFY_FAIL` line — either a named failed file or a failure count.
enum VerifyFailInfo: Equatable {
    case named(String)   // filename from `file=<name>` or the bare fallback token
    case count(Int)      // aggregate `failed=<n>` mismatch count
}

/// Parse a `VERIFY_FAIL` line. Three shapes, in priority order:
///  1. `... file=<name> ...`     → .named(name)   (name = token after file=, up to a space)
///  2. `... failed=<n> ...`      → .count(n)
///  3. `VERIFY_FAIL <name> ...`  → .named(name)   (first token after the prefix)
func parseVerifyFail(_ line: String) -> VerifyFailInfo? {
    guard line.hasPrefix("VERIFY_FAIL") else { return nil }
    if line.contains("file=") {
        let failName = line.components(separatedBy: "file=").last?
            .components(separatedBy: " ").first ?? "unknown"
        return .named(failName)
    } else if let r = line.range(of: "failed=") {
        return .count(crExtractInt(from: line, after: r))
    } else {
        let failName = String(line.dropFirst("VERIFY_FAIL ".count)
            .components(separatedBy: " ").first ?? "unknown")
        return .named(failName)
    }
}

/// Parse a `VERIFY_RECOVERED file=<name>` line → the recovered file's name.
/// A recovered file mismatched on first checksum but was re-copied and now matches;
/// it is a pass, not a failure. Returns nil for non-matching lines.
func parseVerifyRecovered(_ line: String) -> String? {
    guard line.hasPrefix("VERIFY_RECOVERED") else { return nil }
    if line.contains("file=") {
        return line.components(separatedBy: "file=").last?
            .components(separatedBy: " ").first ?? "unknown"
    }
    return "unknown"
}

/// Parse a `VERIFY_QUARANTINE file=<name>` line → the quarantined file's name.
/// A quarantined file still mismatched after a re-copy attempt — an unrecoverable
/// failure. Returns nil for non-matching lines.
func parseVerifyQuarantine(_ line: String) -> String? {
    guard line.hasPrefix("VERIFY_QUARANTINE") else { return nil }
    if line.contains("file=") {
        return line.components(separatedBy: "file=").last?
            .components(separatedBy: " ").first ?? "unknown"
    }
    return "unknown"
}

/// Parse `COLLISION_RENAMED <original> <renamed>` into its two filenames.
/// Returns nil when fewer than two space-separated fields are present.
func parseCollisionRenamed(_ line: String) -> (original: String, renamed: String)? {
    guard line.hasPrefix("COLLISION_RENAMED ") else { return nil }
    let parts = line.dropFirst("COLLISION_RENAMED ".count).components(separatedBy: " ")
    guard parts.count >= 2 else { return nil }
    return (parts[0], parts[1])
}

/// Parse `VERIFY_OK [id=<n>] <name> [<hash> ...]`. Strips an optional leading `id=` token,
/// returns the filename, the first 8 chars of the hash (empty when absent), and the raw id.
func parseVerifyOK(_ line: String) -> (name: String, hash: String, id: String?)? {
    guard line.hasPrefix("VERIFY_OK ") else { return nil }
    var vParts = line.dropFirst("VERIFY_OK ".count).components(separatedBy: " ")
    var id: String? = nil
    if let first = vParts.first, first.hasPrefix("id=") {
        id = String(first.dropFirst("id=".count))
        vParts.removeFirst()
    }
    let name = vParts.first ?? "file"
    let hash = vParts.count > 1 ? String(vParts[1].prefix(8)) : ""
    return (name, hash, id)
}

/// Classification of a `SECONDARY_ERROR` line by its `reason=` field.
enum SecondaryErrorKind: Equatable {
    case copyFailed(exit: String)   // reason=copy_failed — exit token (trimmed) or leftover
    case notMounted                 // reason=not_mounted
    case generic                    // any other/absent reason
}

/// Classify a `SECONDARY_ERROR` line. For copy_failed, the exit value is everything after
/// `exit=` (trimmed); when no `exit=` is present this is the whole line (matching the
/// original `components(separatedBy:).last ?? "?"` behavior, which never yields "?").
func classifySecondaryError(_ line: String) -> SecondaryErrorKind? {
    guard line.hasPrefix("SECONDARY_ERROR") else { return nil }
    if line.contains("reason=copy_failed") {
        let exitCode = (line.components(separatedBy: "exit=").last ?? "?")
            .trimmingCharacters(in: .whitespaces)
        return .copyFailed(exit: exitCode)
    } else if line.contains("reason=not_mounted") {
        return .notMounted
    } else {
        return .generic
    }
}

/// Decide whether a card whose destination lives on `candidateDestDevice` may START NOW
/// (true) or must QUEUE (false). The scheduler is DESTINATION-AWARE: it parallelizes across
/// separate physical drives and — when the drive tier is `.fast` or `.medium` (any SSD) —
/// also allows same-drive parallel up to `maxConcurrent`. Slow drives (HDD / USB 2) stay
/// sequential because their seek/bandwidth ceiling makes parallel writes slower, not faster.
/// Default tier is `.fast` (unknown drives treated as fast) because the target audience uses
/// professional SSDs; a HDD user who hits contention can drop maxConcurrentCards to 1.
func canAdmitIngest(candidateDestDevice: dev_t?, snapshot: SchedulerSnapshot) -> Bool {
    if snapshot.demoActive { return false }
    if snapshot.runningDestDevices.count >= max(1, snapshot.maxConcurrent) { return false }
    if let dev = candidateDestDevice, snapshot.runningDestDevices.contains(dev) {
        // Same physical drive — allow parallel unless the drive is slow (HDD / USB 2).
        let tier = snapshot.destDriveTiers[dev] ?? .fast
        if !tier.allowsSameDriveParallel { return false }
    }
    return true
}

/// Probe the physical drive tier for a volume path by running `diskutil info`.
/// Returns `.fast` (NVMe/PCIe/Apple Fabric SSD), `.medium` (USB 3 SSD), or `.slow` (HDD / USB 2).
/// Runs on a background thread; a 3-second serial-gate timeout terminates the process and returns
/// `.fast` so a hung NAS mount never blocks the GCD thread indefinitely.
/// Defaults to `.fast` on any error — the pro audience overwhelmingly uses fast SSDs.
func probeDriveTier(at volumePath: String) async -> DriveTier {
    await withCheckedContinuation { continuation in
        let gate = DispatchQueue(label: "dev.cardrunner.drivetier", qos: .utility)
        var resumed = false
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["info", volumePath]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = Pipe()

        // Serialised finish — only the first caller (normal path or timeout) wins.
        func finish(_ tier: DriveTier) {
            gate.async {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: tier)
            }
        }

        // 3-second safety net: kill the process and unblock if diskutil hangs (e.g. slow NAS).
        gate.asyncAfter(deadline: .now() + 3) {
            guard !resumed else { return }
            proc.terminate()
            resumed = true
            continuation.resume(returning: .fast)
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                try proc.run()
                proc.waitUntilExit()
                let data   = outPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                finish(parseDriveTier(from: output))
            } catch {
                finish(.fast)
            }
        }
    }
}

private func parseDriveTier(from diskutilOutput: String) -> DriveTier {
    var isSolidState = false
    var protocol_    = ""
    for line in diskutilOutput.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("solid state:") {
            isSolidState = t.hasSuffix("yes")
        } else if t.hasPrefix("protocol:") {
            protocol_ = t.components(separatedBy: ":").dropFirst()
                .joined(separator: ":").trimmingCharacters(in: .whitespaces)
        }
    }
    guard isSolidState else { return .slow }                             // spinning disk
    if protocol_.contains("pci") || protocol_.contains("apple fabric") { return .fast }  // NVMe / internal
    return .medium                                                        // USB 3.x SSD
}

/// Pure decision: is a detected card ALREADY tracked on screen — either parked as a
/// "waiting to route" entry or represented by a live ingest lane — so the Auto-Ingest-OFF
/// scan must NOT park a duplicate? Identity rules (in order):
///   • already parked at this mount path → tracked
///   • a live lane copies from this exact mount path → tracked (handles UUID-less
///     exFAT/FAT cards: two different "Untitled" cards mount at distinct paths, so each
///     still surfaces — we match the PATH, never the bare name)
///   • a live lane has the same source volume UUID → tracked (belt-and-suspenders)
/// Otherwise the card is fresh-to-the-UI and should be parked. Never starts a copy.
func cardIsAlreadyTracked(cardPath: String,
                          cardUUID: String?,
                          awaitingPaths: Set<String>,
                          awaitingUUIDs: Set<String> = [],
                          activeUUIDs: Set<String>,
                          activePaths: Set<String>) -> Bool {
    if awaitingPaths.contains(cardPath) { return true }
    if let u = cardUUID, awaitingUUIDs.contains(u) { return true }   // same card, mount path shuffled
    if activePaths.contains(cardPath)   { return true }
    if let u = cardUUID, activeUUIDs.contains(u) { return true }
    return false
}

/// Pure: resolve the effective per-card folder label (--cardlabel) for an ingest.
/// A per-card name typed on the lane (perCard, non-nil) overrides the global custom-card-name
/// pref; nil means "no per-card name, use the global setting". The result is trimmed — empty
/// means NO per-card subfolder (footage lands directly under the date). Used for both the
/// emitted --cardlabel and the lane's display name so they never diverge.
func resolveCardLabel(perCard: String?, globalEnabled: Bool, globalName: String) -> String {
    let candidate = perCard ?? (globalEnabled ? globalName : "")
    return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Pure: resolve the effective project-folder name for a routed SSD destination. A per-destination
/// projectFolder wins; empty falls back to the GLOBAL project name (migration-safe — an upgraded
/// destination with no per-dest project lands footage exactly where it did before). Trimmed; an
/// empty result means "no project set" and the caller must refuse the ingest ("Project name required").
func resolveProjectFolder(destProject: String, globalProject: String) -> String {
    let d = destProject.trimmingCharacters(in: .whitespacesAndNewlines)
    return d.isEmpty ? globalProject.trimmingCharacters(in: .whitespacesAndNewlines) : d
}

/// Lightweight per-card media-type detector. Reuses the same scan-root logic as
/// `scanCardDatesSync` (M4ROOT/XDROOT/DCIM detection), then does a top-2-level walk from the
/// effective media directory, stopping at 500 files total. Returns "video" if video-extension
/// files match or outnumber photo-extension files, "photo" if photos are the clear majority,
/// or `globalFallback` when the card is empty or genuinely ambiguous. Extension sets are
/// identical to scanCardDatesSync.
///
/// For Sony cards M4ROOT is used as the effective scan root so that a 2-level walk reaches the
/// clip files (M4ROOT/CLIP/*.MXF), rather than starting from the card root where files are 3+
/// levels deep. This keeps the scan fast without a full recursive walk.
///
/// Majority wins: whichever type has more matching files; ties go to video (equal-count mixed
/// cards are more likely video shoots).
nonisolated func detectCardMode(at cardPath: String, globalFallback: String) -> String {
    let fm      = FileManager.default
    let cardURL = URL(fileURLWithPath: cardPath)

    // ── Same findDir helper used in scanCardDatesSync / analyzeCardSync ───────
    func findDir(_ name: String, under root: URL, maxDepth: Int) -> URL? {
        guard let contents = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for item in contents {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            if item.lastPathComponent.uppercased() == name { return item }
            if maxDepth > 1, let found = findDir(name, under: item, maxDepth: maxDepth - 1) {
                return found
            }
        }
        return nil
    }

    // ── Resolve effective media root — drill into M4ROOT/XDROOT/DCIM so that
    // the top-2-level walk reaches files (M4ROOT/CLIP/*.MXF = 2 levels). ──────
    let scanRoot: URL
    if let m4 = findDir("M4ROOT", under: cardURL, maxDepth: 5) {
        scanRoot = m4
    } else if let xd = findDir("XDROOT", under: cardURL, maxDepth: 5) {
        scanRoot = xd
    } else if let dcim = findDir("DCIM", under: cardURL, maxDepth: 4) {
        scanRoot = dcim
    } else {
        scanRoot = cardURL
    }

    // ── Extension sets — identical to scanCardDatesSync ───────────────────────
    let photoExts: Set<String> = [
        "jpg","jpeg","png","tif","tiff","heic","heif",
        "dng","cr2","cr3","nef","arw","raf","rw2","orf","sr2"
    ]
    let videoExts: Set<String> = [
        "mp4","mov","mxf","crm","r3d","braw","ari","arx","mts","m2ts"
    ]

    // ── Top-2-level walk from effective scan root, stop at 500 files ─────────
    var videoCount = 0
    var photoCount = 0
    var filesSeen  = 0

    guard let level1Items = try? fm.contentsOfDirectory(
        at: scanRoot, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return globalFallback }

    outer: for item1 in level1Items {
        if item1.path.contains("/THMBNL/") { continue }
        let isDir1 = (try? item1.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDir1 {
            guard let level2Items = try? fm.contentsOfDirectory(
                at: item1, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for item2 in level2Items {
                guard filesSeen < 500 else { break outer }
                if item2.path.contains("/THMBNL/") { continue }
                let isDir2 = (try? item2.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir2 { continue }
                let ext = item2.pathExtension.lowercased()
                if videoExts.contains(ext) { videoCount += 1 }
                else if photoExts.contains(ext) { photoCount += 1 }
                filesSeen += 1
            }
        } else {
            guard filesSeen < 500 else { break }
            let ext = item1.pathExtension.lowercased()
            if videoExts.contains(ext) { videoCount += 1 }
            else if photoExts.contains(ext) { photoCount += 1 }
            filesSeen += 1
        }
    }

    // Majority wins: whichever type has more matching files determines the mode.
    // Ties go to video (equal counts on a mixed card — treat as video).
    // Empty card (no recognised extensions) → defer to caller's globalFallback.
    if videoCount >= photoCount && videoCount > 0 { return "video" }
    if photoCount > 0 { return "photo" }
    return globalFallback
}

/// Pure function: determine the verification tier for a completed ingest.
/// Returns nil when no badge should be shown (didFail or no files).
/// Rules:
///   didFail / newFiles==0     → nil (no badge)
///   no verify at all          → .sizeChecked
///   spot-check (--verify)     → .spotVerified(N)
///   full verify (--full-verify) → .fullyVerified
///   full verify + MHL written → .sealed
func determineVerificationTier(
    verifyEnabled: Bool,       // --verify was on (spot-check)
    fullVerifyEnabled: Bool,   // --full-verify was on (inline SHA-256)
    mhlEnabled: Bool,
    mhlWritten: Bool,
    newFiles: Int,
    verifyCheckedCount: Int,   // number of files spot-checked (from verifyChecked)
    didFail: Bool
) -> VerificationTier? {
    guard !didFail, newFiles > 0 else { return nil }

    if fullVerifyEnabled || mhlEnabled {
        // Full verify was in effect (mhlEnabled forces it)
        if mhlWritten { return .sealed }
        return .fullyVerified
    }
    if verifyEnabled {
        return .spotVerified(count: verifyCheckedCount)
    }
    return .sizeChecked
}

/// Common short connector words kept lowercase in a derived title (except when first). Only members
/// with ≥2 letters are used to un-glue a trailing connector (see `deriveDestName`), so single-letter
/// "a" can't shred an acronym like "HOKA" into "Hok a".
private let kDestNameConnectors: Set<String> = [
    "a", "an", "and", "the", "of", "or", "nor", "but", "for", "to", "at", "by",
    "in", "on", "vs", "via", "per", "with", "from", "into", "onto", "off"
]

/// Split a chunk on camelCase / acronym boundaries: "HOKAFestival" → ["HOKA", "Festival"],
/// "SteadicamBRoll" → ["Steadicam", "B", "Roll"]. Digits stay attached to their word.
private func splitCamelCase(_ str: String) -> [String] {
    let chars = Array(str)
    guard !chars.isEmpty else { return [] }
    var words: [String] = []
    var cur = String(chars[0])
    for i in 1..<chars.count {
        let prev = chars[i - 1], c = chars[i]
        // Boundary before an uppercase that follows a lowercase (aA), OR the last uppercase of an
        // ACRONYM run that is followed by a lowercase (…A|Bc — the A ends the acronym, B starts a word).
        let boundary = (c.isUppercase && prev.isLowercase)
            || (c.isUppercase && prev.isUppercase && i + 1 < chars.count && chars[i + 1].isLowercase)
        if boundary { words.append(cur); cur = String(c) } else { cur.append(c) }
    }
    words.append(cur)
    return words
}

/// Derive a nicely-spaced destination NAME from a project folder name (Xavier's call, replaces the old
/// "cleaned raw"): strip a leading date token (YYMMDD_, YYYYMMDD_, YYYY-MM-DD_/-), split on separators +
/// camelCase/acronym boundaries, then Title-Case every word EXCEPT (a) lowercase connectors and (b)
/// ALL-CAPS acronym runs, which are PRESERVED as-is (NWSL, HOKA — Xavier's call). The first word is
/// always capitalized. "260626_NWSLColumbusGame" → "NWSL Columbus Game"; "260730_TorontoTennis" →
/// "Toronto Tennis"; a Capital-cased connector splits cleanly, so "FestivalOfMiles" → "Festival of
/// Miles". We deliberately do NOT un-glue a lowercase-glued connector ("Festivalof" stays "Festivalof")
/// — that heuristic mangled real words ("Conor"→"Co nor", "Toronto"→"Tor onto", "Waterproof"→"Waterpro
/// of") and can't be told apart from a real word ending in those letters. Falls back to the raw name if
/// stripping leaves nothing. Editable in the UI, so a user can always override the guess.
func deriveDestName(fromProject project: String) -> String {
    let raw = project.trimmingCharacters(in: .whitespacesAndNewlines)
    var s = raw
    for pat in ["^\\d{6}_", "^\\d{8}_", "^\\d{4}-\\d{2}-\\d{2}[_-]?"] {
        if let r = s.range(of: pat, options: .regularExpression) { s.removeSubrange(r); break }
    }
    // Separators → camelCase/acronym split → flat word list.
    let words = s.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" })
        .map(String.init).flatMap(splitCamelCase)
    guard !words.isEmpty else { return raw }

    let titled = words.enumerated().map { (i, w) -> String in
        let lower = w.lowercased()
        if i > 0 && kDestNameConnectors.contains(lower) { return lower }
        // Preserve an all-caps acronym run (HOKA, NWSL) verbatim; otherwise Title-Case the word.
        if w.count >= 2 && w == w.uppercased() && w != lower { return w }
        return w.prefix(1).uppercased() + w.dropFirst().lowercased()
    }.joined(separator: " ")
    return titled.isEmpty ? raw : titled
}
