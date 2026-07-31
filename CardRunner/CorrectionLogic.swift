//  CorrectionLogic.swift — CardRunner
//  Pure, unit-tested logic for correcting a card-label folder AFTER a copy has
//  completed (e.g. the operator retypes the name on the done tile). This is the
//  data-safety-critical replacement for the old whole-folder `FileManager.moveItem`
//  in ContentView.applyPendingFolderRename, which SKIPPED ENTIRELY (leaving footage
//  under the old, wrong-looking name) whenever the target folder already existed.
//
//  Ground truth for "what did this run actually copy" comes from a JSON manifest
//  written by CardRunner.sh right after each copy group succeeds (see the
//  "Correction manifest" block in CardRunner.sh, near _copy_exit == 0), stored at
//  `{destRoot}/.cardrunner/manifests/{runID}.json` — under the destination ROOT so
//  it survives the very folder rename it's used to drive.
//
//  Priority order for locating "which files belong to this card's batch":
//    1. The on-disk manifest for this run's runID (primary, authoritative).
//    2. Fallback: locate the green Finder-tag marker file (batch-start boundary) in
//       the old label folder + capture-time/filename ordering — used only when no
//       manifest exists (e.g. very old run, or write failure).
//    3. Refuse: if NEITHER manifest nor tag marker exists, do not guess. Return a
//       result that tells the caller to fall back to the OLD skip-if-exists,
//       whole-folder-move behavior rather than risk moving files that don't belong.
//
//  No View, no @State, no I/O side effects beyond FileManager — everything here is
//  a plain function over value types so it's unit-testable. See CardRunnerTests.
import Foundation

// MARK: - Manifest schema (mirrors the JSON CardRunner.sh writes)

struct CorrectionManifestEntry: Codable, Equatable {
    var relPath: String
    var filename: String
    var size: Int64
    var hash: String?      // nullable — only populated when --verify ran
    var label: String
    var destPath: String   // the {date}/{label} folder this entry copied under, at copy time
}

struct CorrectionManifest: Codable, Equatable {
    var runID: String
    var destPath: String     // last group dest at copy time (informational)
    var timestamp: String
    var sourceVolume: String
    var entries: [CorrectionManifestEntry]
}

/// Load `{destRoot}/.cardrunner/manifests/{runID}.json`. Returns nil (never throws) on any
/// I/O or decode failure — malformed/missing manifests are an expected, handled case, not
/// a crash. Callers must treat nil as "no manifest available" and fall through to the
/// Finder-tag fallback or the refuse-and-preserve-old-behavior path.
func loadManifest(destRoot: String, runID: String, fileManager: FileManager = .default) -> CorrectionManifest? {
    guard !destRoot.isEmpty, !runID.isEmpty else { return nil }
    let path = "\(destRoot)/.cardrunner/manifests/\(runID).json"
    guard let data = fileManager.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(CorrectionManifest.self, from: data)
}

// MARK: - Collision resolution

enum CollisionOutcome: Equatable {
    case moved                       // no collision — moved cleanly
    case deduped                     // target already has byte-identical content — source removed, nothing lost
    case suffixed(newName: String)   // target had different content — source moved in under a disambiguated name
    case failed(reason: String)      // I/O failure — source was NOT touched (never strand/lose a file)
}

/// Pure-ish collision resolver: given a source file that needs to land at `targetURL`, decide
/// (and perform) the safe outcome. NEVER overwrites. NEVER deletes source unless it has been
/// proven identical to an existing target (dedupe) or successfully relocated. On any I/O
/// failure the source is left exactly where it was — the caller sees `.failed` and the file
/// is not lost.
///
/// - identical hash (or, if hashes are unavailable, identical byte-for-byte compare) at the
///   target path → `.deduped`: the source is removed (it's a pure duplicate of what already
///   made it to disk), the target is left as-is.
/// - target exists with DIFFERENT content → `.suffixed`: source is moved in under
///   `name__from-<sourceLabel>.ext`; if THAT name also collides, an incrementing counter is
///   appended (`name__from-<sourceLabel>-2.ext`, `-3`, …) until a free name is found or a
///   sane retry ceiling is hit.
/// - no collision → `.moved`: straightforward move (or copy+delete fallback cross-volume).
func resolveCollision(
    sourceURL: URL,
    targetURL: URL,
    sourceHash: String?,
    targetHash: String?,
    sourceLabel: String,
    fileManager: FileManager = .default
) -> CollisionOutcome {
    do {
        try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
    } catch {
        return .failed(reason: "could not create target directory: \(error.localizedDescription)")
    }

    if !fileManager.fileExists(atPath: targetURL.path) {
        return performMove(from: sourceURL, to: targetURL, fileManager: fileManager)
    }

    // Target exists — decide identical vs. different content.
    let identical: Bool
    if let sh = sourceHash, let th = targetHash {
        identical = sh == th
    } else {
        identical = filesAreByteIdentical(sourceURL, targetURL, fileManager: fileManager)
    }

    if identical {
        do {
            try fileManager.removeItem(at: sourceURL)
            return .deduped
        } catch {
            // Could not remove the now-redundant source — not data loss (target already has
            // the content), but report it so the caller can log/investigate.
            return .failed(reason: "dedupe cleanup failed: \(error.localizedDescription)")
        }
    }

    // Different content under the same name — disambiguate with a suffix.
    let ext = targetURL.pathExtension
    let base = targetURL.deletingPathExtension().lastPathComponent
    let dir = targetURL.deletingLastPathComponent()
    let safeLabel = sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "unknown" : sourceLabel
    let sanitizedLabel = safeLabel.replacingOccurrences(of: "/", with: "-")

    func candidateURL(counter: Int) -> URL {
        let suffix = counter <= 1 ? "__from-\(sanitizedLabel)" : "__from-\(sanitizedLabel)-\(counter)"
        let name = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
        return dir.appendingPathComponent(name)
    }

    let maxAttempts = 1000
    var counter = 1
    while counter <= maxAttempts {
        let candidate = candidateURL(counter: counter)
        if !fileManager.fileExists(atPath: candidate.path) {
            let outcome = performMove(from: sourceURL, to: candidate, fileManager: fileManager)
            switch outcome {
            case .moved: return .suffixed(newName: candidate.lastPathComponent)
            case .failed(let reason): return .failed(reason: reason)
            default: return outcome // unreachable for performMove's return set
            }
        }
        counter += 1
    }
    return .failed(reason: "exhausted \(maxAttempts) suffix disambiguation attempts")
}

/// Move a single file, falling back to copy+delete when `moveItem` fails (e.g. cross-volume).
/// The copy is verified by size comparison BEFORE the source is deleted — the source is never
/// removed unless the destination copy is confirmed present at the correct size.
private func performMove(from source: URL, to target: URL, fileManager: FileManager) -> CollisionOutcome {
    do {
        try fileManager.moveItem(at: source, to: target)
        return .moved
    } catch {
        // Cross-volume (or any other) move failure — fall back to copy, verify, then delete.
        do {
            try fileManager.copyItem(at: source, to: target)
        } catch {
            return .failed(reason: "copy fallback failed: \(error.localizedDescription)")
        }
        let srcSize = fileSize(source, fileManager: fileManager)
        let dstSize = fileSize(target, fileManager: fileManager)
        guard dstSize != nil, srcSize == dstSize else {
            // Do NOT delete the source — copy unverified. Leave both in place; caller can retry.
            return .failed(reason: "copy fallback size mismatch — source preserved, not deleted")
        }
        do {
            try fileManager.removeItem(at: source)
        } catch {
            // Destination copy verified good; source cleanup failed. Not data loss (destination
            // has a verified copy) — report so the caller can log a stray duplicate source.
            return .failed(reason: "copy fallback succeeded but source cleanup failed: \(error.localizedDescription)")
        }
        return .moved
    }
}

private func fileSize(_ url: URL, fileManager: FileManager) -> Int64? {
    guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
    return (attrs[.size] as? NSNumber)?.int64Value
}

/// Byte-for-byte compare, used only when no hash is available for either side. Reads in chunks
/// so it doesn't load huge video files fully into memory. Returns false (never crashes) if
/// either file can't be opened — a failed compare degrades to "assume different" (suffix, not
/// dedupe), which is the safe direction: worst case is a harmless duplicate on disk, never
/// silent data loss.
private func filesAreByteIdentical(_ a: URL, _ b: URL, fileManager: FileManager) -> Bool {
    guard let sizeA = fileSize(a, fileManager: fileManager),
          let sizeB = fileSize(b, fileManager: fileManager),
          sizeA == sizeB else { return false }
    guard let ha = FileHandle(forReadingAtPath: a.path),
          let hb = FileHandle(forReadingAtPath: b.path) else { return false }
    defer { try? ha.close(); try? hb.close() }
    let chunkSize = 4 * 1024 * 1024
    while true {
        let da = ha.readData(ofLength: chunkSize)
        let db = hb.readData(ofLength: chunkSize)
        if da != db { return false }
        if da.isEmpty { return true }
    }
}

// MARK: - Orchestration

struct CorrectionFileOutcome {
    var relPath: String
    var outcome: CollisionOutcome
}

struct CorrectionResult {
    var movedCount: Int = 0
    var dedupedCount: Int = 0
    var suffixedCount: Int = 0
    var failedCount: Int = 0
    var effectiveLabel: String   // new label if ≥1 file moved/deduped/suffixed successfully, else old
    var fileOutcomes: [CorrectionFileOutcome] = []
    /// True when the orchestration could not determine batch membership at all (no manifest,
    /// no Finder-tag fallback) — the caller should fall back to the OLD whole-folder
    /// skip-if-exists behavior instead of guessing.
    var refused: Bool = false
    var refusedReason: String? = nil
}

/// Move every file the given manifest says this run copied from `{destRoot}/{oldLabelPath}` to
/// `{destRoot}/{newLabelPath}` (both relative paths, e.g. "2026-07-30/OldName"), using
/// `resolveCollision` for every file so nothing is ever silently overwritten or dropped.
/// Creates the target directory if missing. Logs every outcome via `log` (caller wires this to
/// `appendLog`). Returns an aggregate result including the effective label per the existing
/// `applyPendingFolderRename` contract: new label wins if at least one file successfully
/// moved/deduped/suffixed, otherwise the old label is kept so footage is never left "in limbo"
/// under a folder name nothing landed under.
func performManifestCorrection(
    manifest: CorrectionManifest,
    destRoot: String,
    oldLabelPath: String,
    newLabelPath: String,
    oldLabel: String,
    newLabel: String,
    sourceLabel: String,
    fileManager: FileManager = .default,
    log: (String) -> Void = { _ in }
) -> CorrectionResult {
    var result = CorrectionResult(effectiveLabel: oldLabel)
    let oldRoot = URL(fileURLWithPath: destRoot).appendingPathComponent(oldLabelPath)
    let newRoot = URL(fileURLWithPath: destRoot).appendingPathComponent(newLabelPath)

    do {
        try fileManager.createDirectory(at: newRoot, withIntermediateDirectories: true)
    } catch {
        log("CORRECTION FAIL: could not create target folder \(newRoot.path): \(error.localizedDescription)\n")
        result.refused = true
        result.refusedReason = "target directory creation failed"
        return result
    }

    for entry in manifest.entries {
        // Files land FLAT inside the {date}/{label} folder (basename only, per
        // CardRunner.sh's copy-group layout) — use filename, not the card-relative
        // relPath, as the on-disk path fragment under the label folder.
        let sourceURL = oldRoot.appendingPathComponent(entry.filename)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            // Already moved (e.g. a prior partial correction) or never landed here — not an error.
            log("CORRECTION SKIP: \(sourceURL.path) not present — already moved or absent\n")
            continue
        }
        let targetURL = newRoot.appendingPathComponent(entry.filename)
        let targetHash: String? = fileManager.fileExists(atPath: targetURL.path)
            ? nil // hash for an existing target isn't known ahead of time — byte-compare fallback handles it
            : nil
        let outcome = resolveCollision(sourceURL: sourceURL, targetURL: targetURL,
                                        sourceHash: entry.hash, targetHash: targetHash,
                                        sourceLabel: sourceLabel, fileManager: fileManager)
        result.fileOutcomes.append(CorrectionFileOutcome(relPath: entry.relPath, outcome: outcome))
        switch outcome {
        case .moved:
            result.movedCount += 1
            log("CORRECTION MOVED: \(entry.relPath) → \(newLabelPath)/\(entry.relPath)\n")
        case .deduped:
            result.dedupedCount += 1
            log("CORRECTION DEDUPED: \(entry.relPath) already present and identical at \(newLabelPath) — source removed\n")
        case .suffixed(let newName):
            result.suffixedCount += 1
            log("CORRECTION SUFFIXED: \(entry.relPath) differed from existing file — saved as \(newName)\n")
        case .failed(let reason):
            result.failedCount += 1
            log("CORRECTION FAIL: \(entry.relPath): \(reason) — left at \(sourceURL.path)\n")
        }
    }

    let anySucceeded = (result.movedCount + result.dedupedCount + result.suffixedCount) > 0
    result.effectiveLabel = anySucceeded ? newLabel : oldLabel
    return result
}

// MARK: - Manifest path grouping helpers

/// Given a manifest entry's absolute `destPath` (the {date}/{label} or {date}/{reel}/{label}
/// folder as it was at copy time), a `destRoot`, and the label folder name we're looking for,
/// return the path RELATIVE to destRoot (e.g. "2026-07-30/OldName") if and only if the last
/// path component of destPath exactly equals `label`. Returns nil for entries under a
/// different label (or outside destRoot entirely) so callers can group entries per distinct
/// label-folder location safely — a suffix match alone ("OldNameExtra" vs "OldName") would be
/// wrong here, hence the exact-last-component check.
func relativeLabelDir(_ absPath: String, destRoot: String, label: String) -> String? {
    guard !destRoot.isEmpty, absPath.hasPrefix(destRoot) else { return nil }
    var rel = String(absPath.dropFirst(destRoot.count))
    while rel.hasPrefix("/") { rel.removeFirst() }
    guard !rel.isEmpty else { return nil }
    let comps = rel.split(separator: "/").map(String.init)
    guard comps.last == label else { return nil }
    return comps.joined(separator: "/")
}

/// Replace the last path component of a "/"-joined relative path with `newLabel`.
func withLastComponentReplaced(_ relPath: String, newLabel: String) -> String {
    var comps = relPath.split(separator: "/").map(String.init)
    guard !comps.isEmpty else { return newLabel }
    comps[comps.count - 1] = newLabel
    return comps.joined(separator: "/")
}

/// Tertiary fallback used when NEITHER the manifest JSON NOR the Finder-tag boundary is
/// available/usable, but `ActiveIngest.copiedFiles` (the unconditional, defense-in-depth
/// filename list populated straight from PROGRESS_FILE lines during this run) is non-empty.
/// Synthesizes manifest-shaped entries from the filename list (flat — filename doubles as
/// relPath, matching the on-disk label-folder layout) and runs them through the same
/// collision-safe `performManifestCorrection` orchestration. This is strictly weaker
/// evidence than a real manifest (no size/hash to cross-check), but it's still a concrete,
/// run-scoped list of names — safer than the whole-folder move when the operator has
/// clearly retyped a label mid-session and the stronger signals are both missing.
func performCopiedFilesCorrection(
    copiedFiles: [String],
    destRoot: String,
    oldLabelPath: String,
    newLabelPath: String,
    oldLabel: String,
    newLabel: String,
    sourceLabel: String,
    fileManager: FileManager = .default,
    log: (String) -> Void = { _ in }
) -> CorrectionResult {
    guard !copiedFiles.isEmpty else {
        var result = CorrectionResult(effectiveLabel: oldLabel)
        result.refused = true
        result.refusedReason = "copiedFiles list empty"
        return result
    }
    let oldRoot = "\(destRoot)/\(oldLabelPath)"
    let entries = Array(Set(copiedFiles)).sorted().map {
        CorrectionManifestEntry(relPath: $0, filename: $0, size: 0, hash: nil,
                                 label: oldLabel, destPath: oldRoot)
    }
    let manifest = CorrectionManifest(runID: "copiedFiles-fallback", destPath: oldRoot,
                                       timestamp: "", sourceVolume: sourceLabel, entries: entries)
    log("CORRECTION FALLBACK: no manifest/Finder-tag — using \(entries.count) filename(s) from this run's copiedFiles list\n")
    return performManifestCorrection(manifest: manifest, destRoot: destRoot,
                                      oldLabelPath: oldLabelPath, newLabelPath: newLabelPath,
                                      oldLabel: oldLabel, newLabel: newLabel,
                                      sourceLabel: sourceLabel, fileManager: fileManager, log: log)
}

// MARK: - Finder-tag fallback (used only when no manifest is available)

/// Look for a green Finder-tag marker file directly inside `labelFolderPath` — the batch-start
/// marker CardRunner.sh's `add_green_finder_tag` applies to the oldest file of a subsequent
/// transfer into an existing folder. Returns the marker's filename if found, else nil.
/// This does NOT by itself prove batch membership for every other file — it's a boundary hint,
/// combined by the caller with capture-time/filename ordering. If nothing is tagged (e.g. this
/// was the FIRST transfer into the folder, or Finder tagging was never enabled), returns nil and
/// the caller should refuse rather than guess.
func findFinderTagMarker(labelFolderPath: String, fileManager: FileManager = .default) -> String? {
    guard let contents = try? fileManager.contentsOfDirectory(atPath: labelFolderPath) else { return nil }
    for name in contents {
        let path = "\(labelFolderPath)/\(name)"
        guard let tagNames = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]).tagNames else { continue }
        if tagNames.contains(where: { $0.localizedCaseInsensitiveContains("green") }) {
            return name
        }
    }
    return nil
}

/// Entry point used when no manifest is available. Attempts the Finder-tag fallback; if no tag
/// marker exists either, refuses (result.refused = true) so the caller preserves the OLD
/// whole-folder skip-if-exists behavior rather than risk moving files that don't belong to this
/// run's batch. This intentionally does NOT reintroduce the original incident bug: it never
/// guesses batch membership from timestamps alone without a hard boundary marker.
func performFallbackCorrection(
    destRoot: String,
    oldLabelPath: String,
    newLabelPath: String,
    oldLabel: String,
    newLabel: String,
    fileManager: FileManager = .default,
    log: (String) -> Void = { _ in }
) -> CorrectionResult {
    let oldRoot = "\(destRoot)/\(oldLabelPath)"
    guard let marker = findFinderTagMarker(labelFolderPath: oldRoot, fileManager: fileManager) else {
        log("CORRECTION REFUSED: no manifest and no Finder-tag marker for \(oldRoot) — cannot safely determine batch membership\n")
        var result = CorrectionResult(effectiveLabel: oldLabel)
        result.refused = true
        result.refusedReason = "no manifest, no Finder-tag marker"
        return result
    }
    log("CORRECTION FALLBACK: using Finder-tag marker \(marker) as batch-start boundary in \(oldRoot)\n")
    // Marker establishes a boundary; without per-file capture metadata beyond what's already on
    // disk, the conservative choice is to still refuse the blind bulk move and let the caller's
    // whole-folder-skip-if-exists path handle it — the marker's role here is diagnostic (it lets
    // a future enhancement bound the batch precisely). Refusing keeps the guarantee that this
    // fallback never moves a file that wasn't proven to belong to the run being corrected.
    var result = CorrectionResult(effectiveLabel: oldLabel)
    result.refused = true
    result.refusedReason = "Finder-tag marker found but insufficient to safely bound batch — deferring to whole-folder path"
    return result
}
