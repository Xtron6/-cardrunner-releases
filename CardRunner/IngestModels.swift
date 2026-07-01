//  IngestModels.swift — CardRunner
//  Pure ingest/data models extracted from ContentView.swift (monolith split,
//  Stage 1a). Value types only — no ContentView coupling, no UI.
import Foundation

struct Volume: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    var cameraModel: String = "Camera"
    var volumeUUID: String? = nil   // set at detection time; persists through ingest lifecycle
}

/// A user-facing footage destination in the N-way routing model.
///
/// A destination is either a *mounted drive* (`isCustomFolder == false`, `path` is the
/// volume root such as `/Volumes/Samsung T7`, footage lands under `<path>/<project>/…`)
/// or a *custom folder* (`isCustomFolder == true`, `path` is an explicit directory the
/// user picked, footage lands directly under `<path>/<date>/…`). `id` is stable across
/// launches so per-card routing (`QueuedIngest.destinationID`, `AwaitingCard.destinationID`)
/// and the default-destination preference can reference it.
struct Destination: Identifiable, Hashable, Codable {
    var id = UUID()
    var path: String
    var name: String
    var isCustomFolder: Bool
    // Per-destination project structure (SSD destinations). Empty projectFolder → fall back to the
    // global projectName (migration-safe: an upgraded user's footage lands exactly where it did
    // before). Ignored for custom-folder destinations (the path IS the project root).
    var projectFolder: String = ""
    var subfolder: String = "Default"   // "Default" → the shell's "clips" (matches buildIngestArgs)

    init(id: UUID = UUID(), path: String, name: String, isCustomFolder: Bool,
         projectFolder: String = "", subfolder: String = "Default") {
        self.id = id; self.path = path; self.name = name; self.isCustomFolder = isCustomFolder
        self.projectFolder = projectFolder; self.subfolder = subfolder
    }

    enum CodingKeys: String, CodingKey { case id, path, name, isCustomFolder, projectFolder, subfolder }

    // Custom decoder so Destinations persisted BEFORE projectFolder/subfolder existed still load
    // (synthesized Codable throws keyNotFound on missing keys — that would wipe the saved list).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = (try? c.decode(UUID.self,   forKey: .id)) ?? UUID()
        path           = try  c.decode(String.self,  forKey: .path)
        name           = try  c.decode(String.self,  forKey: .name)
        isCustomFolder = (try? c.decode(Bool.self,   forKey: .isCustomFolder)) ?? false
        projectFolder  = (try c.decodeIfPresent(String.self, forKey: .projectFolder)) ?? ""
        subfolder      = (try c.decodeIfPresent(String.self, forKey: .subfolder)) ?? "Default"
    }
}

/// A card detected while Auto-Ingest is OFF: it is parked "waiting to route" until the
/// user drags its node onto a destination (or presses Start). `destinationID` is the
/// drive the user has chosen for it (nil = use the default). Mirrors the demo's
/// `.awaiting` card state.
struct AwaitingCard: Identifiable, Hashable {
    let id = UUID()
    let card: Volume
    var destinationID: UUID? = nil
    var customName: String = ""   // per-card folder name (--cardlabel). Empty = no per-card subfolder.
    var userEdited: Bool = false  // the operator typed here — protects the edit from re-scan/prefill
}

/// Everything the shell-arg builder needs, captured as plain values so the builder is a
/// pure function (no `@State`, no MainActor) and can be unit-tested in isolation.
///
/// `destRoot` / `projectRoot` are the resolved destination for THIS card. `secondaryPaths`
/// is the N-way mirror list — one `--secondary <path>` is emitted per entry (already filtered
/// to exclude the primary destination and any path on the source card). When `useCustomDest`
/// is true the builder emits `--dest-root`+`--primary <volumeRoot>`; otherwise `--primary`+`--project`.
struct IngestArgsConfig {
    var scriptPath: String
    var appVersion: String
    var cardPath: String
    var useCustomDest: Bool
    var destRoot: String
    var projectRoot: String       // used only to derive the custom-mode --primary volume root
    var projectName: String
    var selectedSubfolder: String
    var useCustomCardName: Bool
    var customCardName: String
    var ignoreManifest: Bool = false   // --ignore-manifest: re-copy even if already in the card manifest
    var latestCount: Int
    var dryRun: Bool
    var wrongClockDate: String?
    var reelFilter: [String]
    var reelMulti: Bool
    var dateOverride: String?
    var dateFilterMode: String
    var dateFilterFrom: String
    var dateFilterTo: String
    var dateFilterSubMode: String
    var autoEject: Bool
    var fullVerifyEnabled: Bool
    var verifyTransfer: Bool
    var transferReportEnabled: Bool
    var secondaryPaths: [String]
    var renameOnIngestEnabled: Bool
    var renameTemplate: String
    var winterOlympicsMode: Bool
    var olympicsCode: String
    var scaffoldEnabled: Bool
    var scaffoldFolderList: [String]
    var copyXML: Bool
    var importMode: String
    var includeProxies: Bool
    var ingestOrder: String
    var dateFolderFormat: String
    var broadcastDayFolders: Bool
    var dayStartHour: Int
    var finderTagEnabled: Bool
    var finderTagColor: String
}

/// One distinct capture-date found on a card during pre-ingest scanning.
struct CardDateInfo: Identifiable {
    var id: String { yyyymmdd }
    let yyyymmdd: String    // e.g. "20260529"
    let fileCount: Int
    let totalBytes: Int64
    let isToday: Bool

    var displayDate: String {
        let parse = DateFormatter(); parse.dateFormat = "yyyyMMdd"
        guard let d = parse.date(from: yyyymmdd) else { return yyyymmdd }
        let fmt = DateFormatter(); fmt.dateStyle = .long; fmt.timeStyle = .none
        return fmt.string(from: d)
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

/// Top-level capture folder (reel) found on a camera card during wrong-clock analysis.
struct ReelInfo: Identifiable {
    let id: UUID = UUID()
    let folderName: String      // top-level folder name (relative to card/scan root)
    let folderPath: String      // absolute path
    let fileCount: Int
    let totalBytes: Int64
    let distinctDates: Set<String>  // YYYYMMDD strings from file mtimes in this reel

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

/// Full card analysis: date groups + reel structure + wrong-clock detection result.
struct CardAnalysis {
    let dates: [CardDateInfo]
    let reels: [ReelInfo]
    let hasImplausibleDates: Bool

    /// Tier-1 wrong-clock fires when: implausible dates + ≥2 reels + dates can't distinguish sessions.
    var isWrongClock: Bool {
        guard hasImplausibleDates, reels.count >= 2 else { return false }
        let allDates = Set(reels.flatMap { $0.distinctDates })
        return allDates.count < reels.count
    }
}

/// A card waiting in the sequential ingest queue, optionally bound to a specific
/// capture date (when the user chose individual dates in the picker).
struct QueuedIngest {
    let card: Volume
    /// YYYYMMDD to pass as --date-from, or nil to use the current dateFilterMode.
    let dateOverride: String?
    /// When set, pass as --date-override (wrong-clock: use real ingest date for dest folder).
    let wrongClockDate: String?
    /// Top-level reel folder names to filter ingest to (empty = no filter).
    let reelFilter: [String]
    /// When true and reelFilter has 2+ entries, insert reel name as dest subfolder.
    let reelMulti: Bool
    /// Which `Destination` this card is routed to (nil = use the default destination).
    /// Carried through the queue so per-card routing survives the wait for a free drive.
    let destinationID: UUID?
    /// When true, ingest EVERYTHING regardless of the current date filter (the tier-0
    /// "Ingest all N clips" choice). Carried through the queue so the bypass survives a
    /// wait for a free drive instead of re-applying the filter and re-prompting.
    let ignoreDateFilter: Bool

    init(card: Volume, dateOverride: String?,
         wrongClockDate: String? = nil, reelFilter: [String] = [], reelMulti: Bool = false,
         destinationID: UUID? = nil, ignoreDateFilter: Bool = false) {
        self.card = card
        self.dateOverride = dateOverride
        self.wrongClockDate = wrongClockDate
        self.reelFilter = reelFilter
        self.reelMulti = reelMulti
        self.destinationID = destinationID
        self.ignoreDateFilter = ignoreDateFilter
    }
}

// MARK: - Crash Recovery Checkpoint
/// Written to disk just before a transfer starts.  Deleted on clean process exit.
/// If the app or Mac dies mid-transfer the file persists and is offered as a
/// resume prompt on next launch.
struct IngestCheckpoint: Identifiable, Codable {
    let id: UUID
    let cardPath: String
    let cardName: String
    let primaryPath: String
    let projectName: String
    let subfolder: String       // empty = use "clips" default
    let cardLabel: String       // empty = no per-card subfolder
    let dateFormat: String
    let finderTagColor: String  // empty = tag disabled
    let mode: String            // "video" | "photo"
    let secondaryPath: String   // empty = no secondary
    let verifyEnabled: Bool
    let newFiles: Int           // best-effort at write time; may be 0 if crash was early
    let startedAt: Date
    // Full resolved shell argument list (everything after the script path) captured at
    // launch, so resume replays the EXACT job — including date-override/wrong-clock,
    // reel filter, Olympics mode, broadcast-day hour, rename template, date filters, etc.
    // Optional so old checkpoints written before this field still decode (→ nil → the
    // legacy per-field reconstruction path in resumeFromCheckpoint is used).
    let resumeArgs: [String]?
}

struct IngestHistoryEntry: Identifiable, Codable {
    let id: UUID
    let cardName: String
    let status: String
    let newFiles: Int
    let skippedFiles: Int
    let avgMBps: Int
    let durationSec: Int
    let destPath: String
    let timestamp: Date
    // Skip breakdown — added later; default 0 for backward compat with stored entries
    let skipManifest: Int
    let skipDestExists: Int
    let skipTodayFilter: Int
    let skipWrongMode: Int
    let skipProxy: Int        // proxy/sub clips excluded (proxy copy disabled)
    let skipMissing: Int      // matched at scan but gone at copy time (NOT copied)
    /// The media label ("clips" or "photos") at the time of transfer — frozen so
    /// it never changes when the user later flips the Video/Photo toggle.
    let mediaLabel: String
    /// Actual bytes transferred (from totalBytesNew). 0 = not available, fall back
    /// to the avgMBps × durationSec approximation for display purposes.
    let totalBytesTransferred: Int64

    var totalSkipped: Int { skipManifest + skipDestExists + skipTodayFilter + skipWrongMode }

    init(cardName: String, status: String, newFiles: Int, skippedFiles: Int,
         avgMBps: Int, durationSec: Int, destPath: String,
         mediaLabel: String = "clips",
         totalBytesTransferred: Int64 = 0,
         skipManifest: Int = 0, skipDestExists: Int = 0,
         skipTodayFilter: Int = 0, skipWrongMode: Int = 0,
         skipProxy: Int = 0, skipMissing: Int = 0) {
        self.id                    = UUID()
        self.cardName              = cardName
        self.status                = status
        self.newFiles              = newFiles
        self.skippedFiles          = skippedFiles
        self.avgMBps               = avgMBps
        self.durationSec           = durationSec
        self.destPath              = destPath
        self.timestamp             = Date()
        self.mediaLabel            = mediaLabel
        self.totalBytesTransferred = totalBytesTransferred
        self.skipManifest          = skipManifest
        self.skipDestExists        = skipDestExists
        self.skipTodayFilter       = skipTodayFilter
        self.skipWrongMode         = skipWrongMode
        self.skipProxy             = skipProxy
        self.skipMissing           = skipMissing
    }

    // Custom decoder so old stored entries (without newer fields) still load cleanly
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(UUID.self,   forKey: .id)
        cardName     = try c.decode(String.self, forKey: .cardName)
        status       = try c.decode(String.self, forKey: .status)
        newFiles     = try c.decode(Int.self,    forKey: .newFiles)
        skippedFiles = try c.decode(Int.self,    forKey: .skippedFiles)
        avgMBps      = try c.decode(Int.self,    forKey: .avgMBps)
        durationSec  = try c.decode(Int.self,    forKey: .durationSec)
        destPath     = try c.decode(String.self, forKey: .destPath)
        timestamp    = try c.decode(Date.self,   forKey: .timestamp)
        mediaLabel             = try c.decodeIfPresent(String.self,  forKey: .mediaLabel)             ?? "clips"
        totalBytesTransferred  = try c.decodeIfPresent(Int64.self,   forKey: .totalBytesTransferred)  ?? 0
        skipManifest           = try c.decodeIfPresent(Int.self,     forKey: .skipManifest)           ?? 0
        skipDestExists         = try c.decodeIfPresent(Int.self,     forKey: .skipDestExists)         ?? 0
        skipTodayFilter        = try c.decodeIfPresent(Int.self,     forKey: .skipTodayFilter)        ?? 0
        skipWrongMode          = try c.decodeIfPresent(Int.self,     forKey: .skipWrongMode)          ?? 0
        skipProxy              = try c.decodeIfPresent(Int.self,     forKey: .skipProxy)              ?? 0
        skipMissing            = try c.decodeIfPresent(Int.self,     forKey: .skipMissing)            ?? 0
    }
}

struct AllTimeStats: Codable {
    var totalCards: Int = 0
    var totalFiles: Int = 0
    var totalMB: Double = 0        // megabytes (raw from log NewMB or byte count ÷ 1 048 576)
    var totalDurationSec: Int = 0
    var peakMBps: Int = 0
    var firstIngestDate: Date? = nil
    var bootstrappedFromLogs: Bool = false  // set true after one-time log parse

    init() {}

    // Resilient decode: every field is optional-with-default so adding a new field in a
    // future build never throws and zeroes the user's lifetime counters (which would then
    // be wrongly re-bootstrapped from already-pruned logs). encode(to:) stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalCards           = (try? c.decode(Int.self,    forKey: .totalCards))           ?? 0
        totalFiles           = (try? c.decode(Int.self,    forKey: .totalFiles))           ?? 0
        totalMB              = (try? c.decode(Double.self, forKey: .totalMB))              ?? 0
        totalDurationSec     = (try? c.decode(Int.self,    forKey: .totalDurationSec))     ?? 0
        peakMBps             = (try? c.decode(Int.self,    forKey: .peakMBps))             ?? 0
        firstIngestDate      =  try? c.decode(Date.self,   forKey: .firstIngestDate)
        bootstrappedFromLogs = (try? c.decode(Bool.self,   forKey: .bootstrappedFromLogs)) ?? false
    }
}

// MARK: - Failed Ingest Record
struct FailedIngestRecord: Codable, Identifiable {
    let id: UUID
    let cardName: String       // volume name e.g. "Untitled"
    var volumeUUID: String? = nil  // physical card identity — so a success only clears THIS card's record
    let friendlyName: String   // card label e.g. "Lucas"
    let projectName: String    // e.g. "20260515_Conor Daly Doc"
    let failedAt: Date
    let filesToCopy: Int
    let mbToCopy: Int
    let reason: String         // "Cancelled" or "Error"
}

enum IngestPhase: String {
    case idle       = "idle"
    case scanning   = "scanning"
    case building   = "building"
    case copying    = "copying"
    case verifying  = "verifying"
    case finalizing = "finalizing"
    case done       = "done"
    case failed     = "failed"

    var displayText: String {
        switch self {
        case .idle:       return "Starting…"
        case .scanning:   return "Scanning card…"
        case .building:   return "Building file list…"
        case .copying:    return "Copying…"
        case .verifying:  return "Verifying…"
        case .finalizing: return "Finalizing…"
        case .done:       return "Pull your card \u{2713}"
        case .failed:     return "Transfer failed — card kept mounted"
        }
    }
}

struct ActiveIngest {
    var cardName: String = ""
    var volumeUUID: String? = nil    // source card's volume UUID — lets a lane persist a nickname
    var sourcePath: String = ""      // source card's mount path — distinguishes two same-named UUID-less cards
    var runMode: String = "video"    // import mode this ingest actually ran in — for the mixed-card hint
    var cardLabel: String = ""       // the --cardlabel this card copied under (the per-card folder name)
    var pendingRename: String? = nil // a new folder name typed DURING transfer — applied at completion
    var destinationID: UUID? = nil   // the routed destination — lets a re-ingest target the same drive
    var cameraModel: String = "Camera"
    var projectRoot: String = ""     // primary.path/projectName — used for partial cleanup on cancel
    var ingestStartTime: Date = Date()

    // File counters
    var totalFiles: Int = 0
    var completedFiles: Int = 0
    var mediaTotal: Int = 0          // all media on card (for skipped calc)
    var newFiles: Int = 0            // new files to copy (from PROGRESS_META)

    // Byte tracking
    var totalBytesNew: Int64 = 0
    var completedFilesBytes: Int64 = 0
    var currentFileSize: Int64 = 0
    var currentIntraFileBytes: Int64 = 0
    var cardBytesTotal: Int64 = 0    // fallback when bytes_new unavailable

    // Current file display
    var currentFileName: String = ""

    // Live speed (MB/s) parsed from cardcopy polling-thread progress lines
    var liveMBps: Double = 0

    // Current ingest phase — drives the status capsule text
    var phase: IngestPhase = .idle

    // Summary (populated by PROGRESS_SUMMARY / PROGRESS_DEST)
    var avgMBps: Int = 0
    var durationSec: Int = 0
    var destPath: String = ""

    // Full-verify progress (populated by VERIFY_PROGRESS)
    var verifyTotal: Int = 0
    var verifyChecked: Int = 0
    var isVerifying: Bool { verifyTotal > 0 && verifyChecked < verifyTotal }

    var doneBytes: Int64 { completedFilesBytes + currentIntraFileBytes }

    // Skip accounting (populated by SKIP_SUMMARY)
    var skipManifest: Int = 0    // already copied in a previous ingest
    var skipDestExists: Int = 0  // already present at destination
    var skipTodayFilter: Int = 0 // older than today (--today-only active)
    var skipWrongMode: Int = 0   // wrong file type for current mode
    var skipProxy: Int = 0       // proxy/sub clips excluded (proxy copy disabled)
    var skipMissing: Int = 0     // matched at scan but missing at copy time (NOT copied)
    var totalSkipped: Int { skipManifest + skipDestExists + skipTodayFilter + skipWrongMode + skipProxy + skipMissing }

    // Failure tracking
    var hasCopyError: Bool = false
    var friendlyName: String = ""   // card label / shooter name, stored so termination handler can access it

    // Collision renames — populated when cardcopy auto-renames a file to avoid overwriting a
    // distinct clip that shares the same basename (GoPro/Canon chaptered DCIM, dual-slot Sony, etc.)
    var collisionRenames: [(original: String, renamed: String)] = []

    // Disk space tracking
    var destFreeGB: Double = 0
    var lowDiskWarning: Bool = false

    // Physical-volume device id (st_dev) of this ingest's destination — used by the
    // destination-aware scheduler to keep two cards off the same drive at once. 0 = unknown.
    var destDeviceID: dev_t = 0
}

/// The authoritative result of a finished ingest. This is the single most important
/// footage-safety decision in the app: deciding whether a transfer SUCCEEDED.
/// It is a pure function of the process exit status + the parsed ActiveIngest state —
/// no View, no @State, no UI — specifically so it can be unit-tested. The rule that
/// must never regress: a transfer is a failure if the script exited non-zero OR any
/// copy/verify error line was parsed (hasCopyError). Success is NEVER inferred from
/// free-text status. See CardRunnerTests for the locked behavior matrix.
struct IngestOutcome: Equatable {
    enum Status: String { case completed = "Completed", upToDate = "Up to date", error = "Error" }
    let didFail: Bool
    let status: Status
    /// Bytes to credit to history/stats. On a clean run doneBytes == totalBytesNew
    /// (PROGRESS_SUMMARY forces it), so this matches planned. On a FAILED run we use
    /// doneBytes (actually-copied — 0 if nothing landed) so failures never inflate stats.
    let bytesTransferred: Int64
    /// Files to credit — actual completed count on failure, planned new count on success.
    let filesTransferred: Int
}

/// State the admission decision needs, kept free of View/@State so it's unit-testable.
struct SchedulerSnapshot {
    /// Physical-volume device IDs (st_dev) of ingests currently running — one per card.
    let runningDestDevices: [dev_t]
    /// True while the onboarding demo holds the engine.
    let demoActive: Bool
    /// pref_maxConcurrentCards — hard ceiling on simultaneous ingests.
    let maxConcurrent: Int
}
