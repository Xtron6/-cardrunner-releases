import Cocoa
import SwiftUI
import Foundation
import Combine
import UserNotifications
import Sparkle
import Sentry

class AppDelegate: NSObject, NSApplicationDelegate {

    lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let window = NSApplication.shared.windows.first {
            // Always transparent so SwiftUI materials (vibrancy) work on all versions
            window.isOpaque = false
            window.backgroundColor = .clear
            if #available(macOS 26, *) {
                // Tahoe: fully custom chrome — hide title and titlebar
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
            } else {
                // Sonoma/Sequoia: keep title visible but make titlebar transparent
                // so the dark gradient fills the full window top-to-bottom in dark mode.
                // In light mode the material shows through the transparent titlebar cleanly.
                window.titlebarAppearsTransparent = true
            }
        }

        // ── Sentry crash + performance reporting ─────────────────────────
        SentrySDK.start { options in
            options.dsn = "https://2b8f6524bafee5953c3c12e7247716a6@o4511207618248704.ingest.us.sentry.io/4511207623426048"
            options.debug = false

            // Crashes, hangs, slow/frozen frames
            options.enableCrashHandler       = true
            options.enableAppHangTracking    = true
            options.appHangTimeoutInterval   = 5     // flag hangs > 5 s

            // Performance tracing — samples 20 % of app sessions.
            // Shows slow startup, long file-copy operations, and UI lag
            // as transactions in the Sentry Performance dashboard.
            options.tracesSampleRate        = 0.2

            // CPU profiling — attached to sampled transactions.
            // Gives flame graphs for slow ingest runs.
            // Note: profilesSampleRate is deprecated in newer Sentry SDKs.
            // Profiling is enabled via tracesSampleRate; update to SentryProfilesSampler when upgrading SDK.

            // Automatic breadcrumbs for every NSNotification and network
            // request — great for reconstructing what led to a crash.
            options.enableAutoBreadcrumbTracking = true
            options.enableNetworkTracking        = true

            // Release tracking — maps crashes to the exact build
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
            options.releaseName = "cardrunner@\(v)+\(b)"

            #if DEBUG
            options.environment = "development"
            #else
            options.environment = "production"
            #endif
        }

        // Tag useful dimensions that appear on every Sentry event
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        SentrySDK.configureScope { scope in
            scope.setTag(value: "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)", key: "macos_version")
            scope.setTag(value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?", key: "app_version")
            // Machine arch — helps distinguish Apple Silicon vs Intel crashes
            #if arch(arm64)
            scope.setTag(value: "arm64", key: "cpu_arch")
            #else
            scope.setTag(value: "x86_64", key: "cpu_arch")
            #endif
        }

        // Minimum macOS version guard — show a friendly alert and quit if too old.
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion < 14 {
            let alert = NSAlert()
            alert.messageText = "macOS 14 or later required"
            alert.informativeText = "CardRunner requires macOS 14 Sonoma or later. Please update your Mac in System Settings > General > Software Update."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
        }

        // Check for updates silently in the background on every launch.
        // Without this, Sparkle only checks on its 24-hour schedule — meaning
        // a user who opens the app the day after a release won't see the update
        // until the next day. This fires immediately, shows nothing if up-to-date,
        // and presents the standard Sparkle sheet if a new version is available.
        updaterController.updater.checkForUpdatesInBackground()

        // Scan all mounted volumes for abandoned .cardrunner_partial directories.
        // These are left behind if cardcopy was interrupted mid-transfer (crash,
        // force-quit, power loss). We surface them so the operator can decide —
        // never silently delete, never silently leave them to confuse a future ingest.
        scanForPartialTransfers()

        // Register with Launch Services so Spotlight indexes the app immediately
        // after a fresh install.  This is a no-op on subsequent launches.
        registerWithSpotlight()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Partial transfer recovery

    /// Scans all mounted /Volumes for .cardrunner_partial directories left behind
    /// by an interrupted cardcopy run. Surfaces a non-dismissible alert so the
    /// operator can clean up — partial files must never silently confuse a future ingest.
    private func scanForPartialTransfers() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var found: [URL] = []

            // Check /Volumes/* (external drives) and the user's home directory
            let searchRoots: [URL] = {
                var roots: [URL] = []
                if let vols = try? fm.contentsOfDirectory(
                    at: URL(fileURLWithPath: "/Volumes"),
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: .skipsHiddenFiles) {
                    roots.append(contentsOf: vols)
                }
                return roots
            }()

            for root in searchRoots {
                // Shallow-ish search: look two levels deep for .cardrunner_partial dirs
                // (Volumes/Drive/Project/Footage/Date/Camera/.cardrunner_partial)
                guard let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsPackageDescendants]) else { continue }

                for case let url as URL in enumerator {
                    if url.lastPathComponent == ".cardrunner_partial" {
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                            // Only report if it actually contains files
                            let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                            if !contents.isEmpty { found.append(url) }
                        }
                        enumerator.skipDescendants()
                    }
                    // Don't recurse deeper than necessary — stop at depth 8
                    if url.pathComponents.count > root.pathComponents.count + 8 {
                        enumerator.skipDescendants()
                    }
                }
            }

            guard !found.isEmpty else { return }

            DispatchQueue.main.async {
                let paths = found.map { $0.deletingLastPathComponent().lastPathComponent
                    + "/" + $0.lastPathComponent }.joined(separator: "\n")
                let alert = NSAlert()
                alert.messageText = "Incomplete transfers found"
                alert.informativeText =
                    "CardRunner found \(found.count) partial transfer folder\(found.count == 1 ? "" : "s") " +
                    "from a previous interrupted session:\n\n\(paths)\n\n" +
                    "These contain incomplete files. Clean them up before ingesting again."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Delete Partial Files")
                alert.addButton(withTitle: "Show in Finder")
                alert.addButton(withTitle: "Ignore")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    for url in found { try? fm.removeItem(at: url) }
                } else if response == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting(found)
                }
            }
        }
    }

    // MARK: - Spotlight registration

    /// Forces immediate Spotlight indexing on first launch / fresh install.
    /// Without this, a freshly installed .app can take minutes or hours to
    /// appear in CMD+Space because mds hasn't scanned it yet.
    private func registerWithSpotlight() {
        guard let bundlePath = Bundle.main.bundlePath as String? else { return }
        let lsregister = "/System/Library/Frameworks/CoreServices.framework" +
                         "/Frameworks/LaunchServices.framework/Support/lsregister"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: lsregister)
        task.arguments = ["-f", bundlePath]
        try? task.run()
    }
}
struct CardRunnerTheme {
    static let bgBase     = Color(hex: "#03164a")   // richer deep navy
    static let neonBlue   = Color(hex: "#0dcff5")   // brighter electric cyan-blue
    static let neonPurple = Color(hex: "#d44dff")   // slightly punchier magenta-violet
    static let glass      = Color.white.opacity(0.07)
    static let border     = Color.white.opacity(0.20)
    // Deeper, higher-contrast variants for light mode
    static let neonBlueDark   = Color(hex: "#0077A8")
    static let neonPurpleDark = Color(hex: "#7B2FBF")
}

// MARK: - Models

// MARK: - Glass visual-effect host view

/// Wraps NSVisualEffectView so SwiftUI can use system-native blur/frosted-glass materials.
private struct VisualEffectBlur: NSViewRepresentable {
    var material:     NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state:        NSVisualEffectView.State        = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material     = material
        v.blendingMode = blendingMode
        v.state        = state
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material     = material
        v.blendingMode = blendingMode
        v.state        = state
    }
}

// MARK: - Ingest Preset

struct IngestPreset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String

    // ── General tab ──────────────────────────────────────────────────────────
    var importMode: String
    var dateFolderFormat: String
    var ingestOrder: String = "oldest"  // "oldest" | "newest"
    var todayOnly: Bool                    // legacy — kept for JSON back-compat
    /// "all" | "today" | "yesterday" | "custom"
    var dateFilterMode: String = "today"
    /// YYYYMMDD lower-bound when dateFilterMode == "custom"
    var dateFilterFrom: String = ""
    /// YYYYMMDD upper-bound (range mode); empty = single date / no upper bound
    var dateFilterTo: String = ""
    /// "single" | "range"
    var dateFilterSubMode: String = "single"
    var selectedSubfolder: String
    var useCustomCardName: Bool
    var customCardName: String
    var finderTagEnabled: Bool
    var finderTagColor: String
    var completionAnimationRaw: String
    var dayStartHour: Int
    var broadcastDayFolders: Bool

    // ── Destination override ─────────────────────────────────────────────────
    var useCustomDest: Bool = false
    var customDestPath: String = ""

    // ── Advanced tab ─────────────────────────────────────────────────────────
    var autoEject: Bool
    var copyXML: Bool
    var verifyTransfer: Bool
    var includeProxies: Bool

    // ── Pro Tools tab ────────────────────────────────────────────────────────
    var dualDestEnabled: Bool
    var fullVerifyEnabled: Bool
    var transferReportEnabled: Bool
    var renameOnIngestEnabled: Bool
    var renameTemplate: String

    // ── Project Scaffold ─────────────────────────────────────────────────────
    var scaffoldEnabled: Bool   = false
    var scaffoldFolders: String = ""   // "\n"-separated; empty = use global default

    // ── Resilient Codable decoder ─────────────────────────────────────────────
    // Every field uses try? + fallback so that adding new fields in a future
    // version NEVER silently breaks decoding of older saved presets.
    // (Synthesised init(from:) would throw on any missing key, wiping all presets.)
    enum CodingKeys: String, CodingKey {
        case id, name, importMode, dateFolderFormat, ingestOrder, todayOnly
        case dateFilterMode, dateFilterFrom, dateFilterTo, dateFilterSubMode
        case selectedSubfolder, useCustomCardName, customCardName
        case finderTagEnabled, finderTagColor, completionAnimationRaw
        case dayStartHour, broadcastDayFolders
        case useCustomDest, customDestPath
        case autoEject, copyXML, verifyTransfer, includeProxies
        case dualDestEnabled, fullVerifyEnabled, transferReportEnabled
        case renameOnIngestEnabled, renameTemplate
        case scaffoldEnabled, scaffoldFolders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                   = (try? c.decode(UUID.self,   forKey: .id))                   ?? UUID()
        name                 = (try? c.decode(String.self, forKey: .name))                 ?? "Unnamed"
        importMode           = (try? c.decode(String.self, forKey: .importMode))           ?? "video"
        dateFolderFormat     = (try? c.decode(String.self, forKey: .dateFolderFormat))     ?? "%y%m%d"
        ingestOrder          = (try? c.decode(String.self, forKey: .ingestOrder))          ?? "oldest"
        todayOnly            = (try? c.decode(Bool.self,   forKey: .todayOnly))            ?? true
        selectedSubfolder    = (try? c.decode(String.self, forKey: .selectedSubfolder))    ?? "Default"
        useCustomCardName    = (try? c.decode(Bool.self,   forKey: .useCustomCardName))    ?? false
        customCardName       = (try? c.decode(String.self, forKey: .customCardName))       ?? ""
        finderTagEnabled     = (try? c.decode(Bool.self,   forKey: .finderTagEnabled))     ?? false
        finderTagColor       = (try? c.decode(String.self, forKey: .finderTagColor))       ?? "green"
        completionAnimationRaw = (try? c.decode(String.self, forKey: .completionAnimationRaw)) ?? "confetti"
        dayStartHour         = (try? c.decode(Int.self,    forKey: .dayStartHour))         ?? 4
        broadcastDayFolders  = (try? c.decode(Bool.self,   forKey: .broadcastDayFolders))  ?? false
        useCustomDest        = (try? c.decode(Bool.self,   forKey: .useCustomDest))        ?? false
        customDestPath       = (try? c.decode(String.self, forKey: .customDestPath))       ?? ""
        autoEject            = (try? c.decode(Bool.self,   forKey: .autoEject))            ?? false
        copyXML              = (try? c.decode(Bool.self,   forKey: .copyXML))              ?? false
        verifyTransfer       = (try? c.decode(Bool.self,   forKey: .verifyTransfer))       ?? false
        includeProxies       = (try? c.decode(Bool.self,   forKey: .includeProxies))       ?? false
        dualDestEnabled      = (try? c.decode(Bool.self,   forKey: .dualDestEnabled))      ?? false
        fullVerifyEnabled    = (try? c.decode(Bool.self,   forKey: .fullVerifyEnabled))    ?? false
        transferReportEnabled = (try? c.decode(Bool.self,  forKey: .transferReportEnabled)) ?? false
        renameOnIngestEnabled = (try? c.decode(Bool.self,  forKey: .renameOnIngestEnabled)) ?? false
        renameTemplate       = (try? c.decode(String.self, forKey: .renameTemplate))       ?? ""
        scaffoldEnabled      = (try? c.decode(Bool.self,   forKey: .scaffoldEnabled))      ?? false
        scaffoldFolders      = (try? c.decode(String.self, forKey: .scaffoldFolders))      ?? ""
        // Migrate old presets: if dateFilterMode absent, derive from todayOnly
        dateFilterMode       = (try? c.decode(String.self, forKey: .dateFilterMode))
                                ?? (todayOnly ? "today" : "all")
        dateFilterFrom       = (try? c.decode(String.self, forKey: .dateFilterFrom))       ?? ""
        dateFilterTo         = (try? c.decode(String.self, forKey: .dateFilterTo))         ?? ""
        dateFilterSubMode    = (try? c.decode(String.self, forKey: .dateFilterSubMode))    ?? "single"
    }

    // Regular (non-Codable) init used when creating presets from app state.
    // Keep parameter order in sync with the struct's stored properties.
    init(
        id:                    UUID   = UUID(),
        name:                  String,
        importMode:            String = "video",
        dateFolderFormat:      String = "%y%m%d",
        ingestOrder:           String = "oldest",
        todayOnly:             Bool   = true,
        dateFilterMode:        String = "today",
        dateFilterFrom:        String = "",
        dateFilterTo:          String = "",
        dateFilterSubMode:     String = "single",
        selectedSubfolder:     String = "Default",
        useCustomCardName:     Bool   = false,
        customCardName:        String = "",
        finderTagEnabled:      Bool   = false,
        finderTagColor:        String = "green",
        completionAnimationRaw:String = "confetti",
        dayStartHour:          Int    = 4,
        broadcastDayFolders:   Bool   = false,
        useCustomDest:         Bool   = false,
        customDestPath:        String = "",
        autoEject:             Bool   = false,
        copyXML:               Bool   = false,
        verifyTransfer:        Bool   = false,
        includeProxies:        Bool   = false,
        dualDestEnabled:       Bool   = false,
        fullVerifyEnabled:     Bool   = false,
        transferReportEnabled: Bool   = false,
        renameOnIngestEnabled: Bool   = false,
        renameTemplate:        String = "",
        scaffoldEnabled:       Bool   = false,
        scaffoldFolders:       String = ""
    ) {
        self.id                    = id
        self.name                  = name
        self.importMode            = importMode
        self.dateFolderFormat      = dateFolderFormat
        self.ingestOrder           = ingestOrder
        self.todayOnly             = todayOnly
        self.dateFilterMode        = dateFilterMode
        self.dateFilterFrom        = dateFilterFrom
        self.dateFilterTo          = dateFilterTo
        self.dateFilterSubMode     = dateFilterSubMode
        self.selectedSubfolder     = selectedSubfolder
        self.useCustomCardName     = useCustomCardName
        self.customCardName        = customCardName
        self.finderTagEnabled      = finderTagEnabled
        self.finderTagColor        = finderTagColor
        self.completionAnimationRaw = completionAnimationRaw
        self.dayStartHour          = dayStartHour
        self.broadcastDayFolders   = broadcastDayFolders
        self.useCustomDest         = useCustomDest
        self.customDestPath        = customDestPath
        self.autoEject             = autoEject
        self.copyXML               = copyXML
        self.verifyTransfer        = verifyTransfer
        self.includeProxies        = includeProxies
        self.dualDestEnabled       = dualDestEnabled
        self.fullVerifyEnabled     = fullVerifyEnabled
        self.transferReportEnabled = transferReportEnabled
        self.renameOnIngestEnabled = renameOnIngestEnabled
        self.renameTemplate        = renameTemplate
        self.scaffoldEnabled       = scaffoldEnabled
        self.scaffoldFolders       = scaffoldFolders
    }
}

enum CompletionAnimation: String, CaseIterable {
    case none           = "none"
    case confetti       = "confetti"
    case pixelFireworks = "pixelFireworks"
    case fizzySoda      = "fizzySoda"
    case retroSparkle   = "retroSparkle"
    case victory        = "victory"

    var label: String {
        switch self {
        case .none:           return "None"
        case .confetti:       return "Confetti"
        case .pixelFireworks: return "Pixel Fireworks"
        case .fizzySoda:      return "Fizzy Soda"
        case .retroSparkle:   return "Retro Sparkle"
        case .victory:        return "Victory"
        }
    }

    var emoji: String {
        switch self {
        case .none:           return "—"
        case .confetti:       return "🎊"
        case .pixelFireworks: return "🎆"
        case .fizzySoda:      return "🫧"
        case .retroSparkle:   return "✦"
        case .victory:        return "🏆"
        }
    }

    var previewDescription: String {
        switch self {
        case .none:           return "No animation plays when a transfer completes."
        case .confetti:       return "Colorful confetti bursts from the ring center."
        case .pixelFireworks: return "8-bit starbursts shoot outward from the circle and fade."
        case .fizzySoda:      return "Purple bubbles drift upward and dissolve around the ring."
        case .retroSparkle:   return "Pixel crosses twinkle in and out around the circle."
        case .victory:        return "All three animations play simultaneously."
        }
    }
}

/// One piece of confetti — position/rotation/color baked in at trigger time.
private struct ConfettiPiece: Identifiable {
    let id: Int
    let color: Color
    let xTarget: CGFloat    // offset from burst origin
    let yTarget: CGFloat
    let rotate: Double
    let w: CGFloat
    let h: CGFloat
    let delay: Double
}

// MARK: - Inline Animation Particle Types

/// One 8-ray pixel firework burst positioned at the ring perimeter.
private struct VictoryFirework: Identifiable {
    let id = UUID()
    let spawnAngle: Double   // radians around ring
    let color: Color
    let rayLength: CGFloat   // length of each of the 8 pixel rays
    let delay: Double        // stagger (0–0.21 s)
}

/// One tiny pixel square scattered after a firework burst, falling with gravity.
private struct PixelSpark: Identifiable {
    let id = UUID()
    let originX: CGFloat     // burst-point x from ring center
    let originY: CGFloat     // burst-point y from ring center
    let targetX: CGFloat     // travel delta x (from origin)
    let targetY: CGFloat     // travel delta y — includes gravity bias
    let color: Color
    let size: CGFloat        // square side, 2–5 px
    let delay: Double
    let duration: Double
}

/// One bubble orb rising from the bottom half of the ring with wobble.
private struct VictoryBubble: Identifiable {
    let id = UUID()
    let startX: CGFloat      // x at spawn (ring bottom perimeter)
    let startY: CGFloat      // y at spawn (positive = below center)
    let endY: CGFloat        // y at peak (negative = above center)
    let size: CGFloat        // diameter 4–14 px
    let opacity: Double      // 0.60–0.80
    let wobbleAmp: CGFloat   // horizontal oscillation amplitude
    let wobblePeriod: Double // one wobble half-cycle duration
    let riseDuration: Double
    let delay: Double        // stagger start, 0–1.5 s
    let popsEarly: Bool      // fades at ~45 % of rise
    let color: Color
}

/// One pixel plus/cross shape that appears, holds, then disappears outside the ring.
private struct VictorySparkle: Identifiable {
    let id = UUID()
    let x: CGFloat           // offset from ring center (always outside ring edge)
    let y: CGFloat
    let size: CGFloat        // 6–18 px
    let color: Color
    let isPlus: Bool         // true = +, false = ✦-style (45°-rotated bars)
    let rotated45: Bool      // overall 45° rotation for variety
    let appearDelay: Double  // when it scales in, 0–2.5 s spread
    let holdDuration: Double // visible hold, 0.10–0.30 s
}

// MARK: - Pixel Starburst Helper

/// 8 thin rectangular rays radiating from center — the pixel-art firework shape.
private struct PixelStarburst: View {
    let rayLength: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { ray in
                Rectangle()
                    .frame(width: 2, height: rayLength)
                    .offset(y: -(rayLength / 2 + 2))
                    .rotationEffect(.degrees(Double(ray) * 45))
            }
        }
        .foregroundStyle(color)
    }
}

// MARK: - Fizzy Soda Bubble View

/// Self-contained bubble that rises, wobbles, highlights, and fades on its own lifecycle.
private struct FizzySodaBubbleView: View {
    let b: VictoryBubble

    @State private var yPos:    CGFloat
    @State private var xWobble: CGFloat = 0
    @State private var opacity: Double
    @State private var scale:   CGFloat = 1.0

    init(b: VictoryBubble) {
        self.b  = b
        _yPos   = State(initialValue: b.startY)
        _opacity = State(initialValue: b.opacity)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(b.color)
                .frame(width: b.size, height: b.size)
            // Inner highlight — small white dot offset toward top-left
            Circle()
                .fill(.white.opacity(0.55))
                .frame(width: b.size * 0.28, height: b.size * 0.28)
                .offset(x: -b.size * 0.18, y: -b.size * 0.18)
        }
        .scaleEffect(scale)
        .offset(x: b.startX + xWobble, y: yPos)
        .opacity(opacity)
        .onAppear {
            // Vertical rise
            withAnimation(.easeOut(duration: b.riseDuration).delay(b.delay)) {
                yPos = b.endY
            }
            // Horizontal sine-wave wobble (repeats for the full rise duration)
            let wobbleReps = max(2, Int(ceil(b.riseDuration / b.wobblePeriod)))
            withAnimation(
                .easeInOut(duration: b.wobblePeriod)
                    .repeatCount(wobbleReps, autoreverses: true)
                    .delay(b.delay)
            ) {
                xWobble = b.wobbleAmp
            }
            // Fade + shrink (earlier for pop-early bubbles)
            let fadeStart  = b.delay + (b.popsEarly ? b.riseDuration * 0.42 : b.riseDuration * 0.62)
            let fadeDur    = b.popsEarly ? 0.22 : 0.55
            withAnimation(.easeIn(duration: fadeDur).delay(fadeStart)) {
                opacity = 0
                scale   = b.popsEarly ? 0.0 : 0.55
            }
        }
    }
}

// MARK: - Retro Sparkle Shape View

/// Self-contained sparkle that scales in, holds, then scales out with its own timing.
private struct RetroSparkleShapeView: View {
    let sp: VictorySparkle
    @State private var scale: CGFloat = 0

    var body: some View {
        Group {
            if sp.isPlus {
                // Plus sign (+)
                ZStack {
                    Rectangle().frame(width: sp.size,        height: sp.size * 0.22)
                    Rectangle().frame(width: sp.size * 0.22, height: sp.size)
                }
            } else {
                // 4-pointed cross (✦) — two bars at 45 °
                ZStack {
                    Rectangle().frame(width: sp.size,        height: sp.size * 0.22)
                        .rotationEffect(.degrees(45))
                    Rectangle().frame(width: sp.size * 0.22, height: sp.size)
                        .rotationEffect(.degrees(45))
                }
            }
        }
        .foregroundStyle(sp.color)
        .rotationEffect(.degrees(sp.rotated45 ? 45 : 0))
        .offset(x: sp.x, y: sp.y)
        .scaleEffect(scale)
        .onAppear {
            // Scale in (80 ms)
            withAnimation(.easeOut(duration: 0.08).delay(sp.appearDelay)) {
                scale = 1.0
            }
            // Scale out (70 ms) after hold
            withAnimation(.easeIn(duration: 0.07)
                .delay(sp.appearDelay + 0.08 + sp.holdDuration)) {
                scale = 0.0
            }
        }
    }
}

// MARK: - Animation Preview Widget

/// Universal live-preview card shown inside Settings for every animation option.
/// The mini ring runs the selected animation once at 60 % scale, then stops.
private struct AnimationPreviewWidget: View {
    let animationType: CompletionAnimation
    let useLightMode: Bool

    // ── Pixel Fireworks two-phase state ───────────────────────────────────────
    @State private var previewFireworks:  [VictoryFirework] = []
    @State private var previewSparks:     [PixelSpark]      = []
    @State private var fwShooting:        Bool              = false
    @State private var fwFading:          Bool              = false
    @State private var sparksFalling:     Bool              = false

    // ── Fizzy Soda / Retro Sparkle (onAppear-managed) ────────────────────────
    @State private var previewBubbles:   [VictoryBubble]  = []
    @State private var previewSparkles:  [VictorySparkle] = []

    // ── Confetti ──────────────────────────────────────────────────────────────
    @State private var confettiPieces:  [ConfettiPiece] = []
    @State private var confettiActive:  Bool            = false

    @State private var previewing: Bool = false

    // Preview renders at 60 % of the full-size ring (115 pt → 69 pt radius)
    private let previewScale: CGFloat = 0.60

    // ── Colour palettes ───────────────────────────────────────────────────────
    private static let fwColors: [Color] = [
        Color(hex: "#FF2D78"), Color(hex: "#00F5FF"), Color(hex: "#FFE600"),
    ]
    private static let sparkColor: [Color] = [
        Color(hex: "#FF2D78"), Color(hex: "#00F5FF"), Color(hex: "#FFE600"),
    ]
    private static let bubbleColors: [Color] = [
        Color(hex: "#9B5FE3").opacity(0.70),
        Color(hex: "#C9A7F5").opacity(0.65),
        Color(hex: "#5B8DEF").opacity(0.72),
    ]
    private static let sparkleColors: [Color] = [
        .white, Color(hex: "#BF5FFF"), Color(hex: "#FF8FD4"),
    ]
    private static let confColors: [Color] = [
        Color(hex: "#FF3B30"), Color(hex: "#FF9500"), Color(hex: "#FFCC02"),
        Color(hex: "#34C759"), Color(hex: "#00C7BE"), Color(hex: "#007AFF"),
        Color(hex: "#AF52DE"), Color(hex: "#FF2D55"),
    ]

    // ── Particle factories (scaled — mirrors the real ContentView generators) ──
    // All counts, sizes, scatter distances, and rise heights are proportional
    // to the live animation so the preview is a faithful miniature.

    private func makePreviewFireworks() -> [VictoryFirework] {
        // Real: 18 fireworks, full 360°, rays 13–23 px
        let ringR: CGFloat = 115 * previewScale
        var result: [VictoryFirework] = []
        for i in 0..<14 {
            let base: Double   = Double(i) / 14.0 * 2.0 * Double.pi
            let jitter: Double = Double(i * 17 % 29) * 0.07 - 0.06
            let rLen: CGFloat  = CGFloat(13 + (i * 7) % 11) * previewScale
            result.append(VictoryFirework(
                spawnAngle: base + jitter,
                color:      Self.fwColors[i % Self.fwColors.count],
                rayLength:  rLen,
                delay:      Double(i % 6) * 0.055
            ))
        }
        _ = ringR
        return result
    }

    private func makePreviewSparks(from fws: [VictoryFirework]) -> [PixelSpark] {
        // Real: 10 sparks per burst, scatter 28–109 pt, gravity 14–48 pt
        let ringR: CGFloat = 115 * previewScale
        var result: [PixelSpark] = []
        for fw in fws {
            let bx = CGFloat(cos(fw.spawnAngle)) * ringR
            let by = CGFloat(sin(fw.spawnAngle)) * ringR
            for j in 0..<8 {
                let sAngle    = fw.spawnAngle + Double(j) * (2.0 * Double.pi / 8.0) + Double.pi / 16.0
                let dist: CGFloat = CGFloat(28 + j * 9) * previewScale
                let bxTgt = CGFloat(cos(sAngle)) * dist
                let byTgt = CGFloat(sin(sAngle)) * dist + CGFloat(14 + j * 4) * previewScale
                result.append(PixelSpark(
                    originX:  bx,
                    originY:  by,
                    targetX:  bxTgt,
                    targetY:  byTgt,
                    color:    Self.sparkColor[j % Self.sparkColor.count],
                    size:     CGFloat(2 + j % 4) * previewScale,
                    delay:    fw.delay + 0.05 + Double(j) * 0.018,
                    duration: 0.75 + Double(j % 4) * 0.12
                ))
            }
        }
        return result
    }

    private func makePreviewBubbles() -> [VictoryBubble] {
        // Real: 32 bubbles, full 360° ring, rise 140–230 pt above spawn
        let ringR: CGFloat = 115 * previewScale
        var result: [VictoryBubble] = []
        for i in 0..<18 {
            let angle    = Double(i) / 18.0 * 2.0 * Double.pi + Double(i * 7 % 13) * 0.04
            let startX   = CGFloat(cos(angle)) * ringR
            let startY   = CGFloat(sin(angle)) * ringR
            let sz: CGFloat    = CGFloat(6 + (i * 11) % 17) * previewScale
            let opac: Double   = 0.65 + Double(i % 5) * 0.06
            let wAmp: CGFloat  = CGFloat(8 + i % 14) * previewScale
            let wPer: Double   = 0.20 + Double(i % 4) * 0.08
            let rDur: Double   = 1.5 + Double(i % 6) * 0.22 + Double(i * 11 % 9) * 0.07
            let dly: Double    = Double(i) / 18.0 * 2.0 + Double(i * 7 % 11) * 0.05
            let endY: CGFloat  = startY - CGFloat(140 + (i * 9) % 90) * previewScale
            result.append(VictoryBubble(
                startX: startX, startY: startY, endY: endY,
                size: sz, opacity: opac,
                wobbleAmp: wAmp, wobblePeriod: wPer,
                riseDuration: rDur, delay: dly,
                popsEarly: (i % 5 == 2),
                color: Self.bubbleColors[i % Self.bubbleColors.count]
            ))
        }
        return result
    }

    private func makePreviewSparkles() -> [VictorySparkle] {
        // Real: 54 sparkles, full 360° ring, radii 130–230 pt, sizes 8–24 px
        let ringR: CGFloat = 115 * previewScale
        var angles: [Double] = []
        for i in 0..<10 { angles.append(-Double.pi/2 + (Double(i)-4.5) * Double.pi/11 + Double(i*7%11)*0.04) }
        for i in 0..<4  { angles.append(Double.pi   + (Double(i)-1.5) * Double.pi/9  + Double(i*11%9)*0.03) }
        for i in 0..<4  { angles.append(0           + (Double(i)-1.5) * Double.pi/9  + Double(i*13%9)*0.03) }
        for i in 0..<4  { angles.append(Double.pi/2 + (Double(i)-1.5) * Double.pi/9  + Double(i*9%8)*0.04)  }
        for i in 0..<6  { angles.append(Double(i) / 6.0 * 2.0 * Double.pi + 0.31) }
        var result: [VictorySparkle] = []
        for (idx, angle) in angles.enumerated() {
            let r = ringR + CGFloat(15 + (idx * 9) % 100) * previewScale
            result.append(VictorySparkle(
                x:            CGFloat(cos(angle)) * r,
                y:            CGFloat(sin(angle)) * r,
                size:         CGFloat(8 + (idx * 7) % 17) * previewScale,
                color:        Self.sparkleColors[idx % Self.sparkleColors.count],
                isPlus:       (idx % 2 == 0),
                rotated45:    (idx % 3 == 0),
                appearDelay:  Double(idx) / Double(angles.count) * 2.8 + Double(idx*7%12)*0.04,
                holdDuration: 0.12 + Double(idx * 11 % 22) * 0.01
            ))
        }
        return result
    }

    private func makeConfetti() -> [ConfettiPiece] {
        var result: [ConfettiPiece] = []
        for i in 0..<30 {
            let angle = Double(i) / 30.0 * 2 * .pi + Double(i % 5) * 0.22
            let dist  = CGFloat(50 + (i * 13) % 80) * previewScale
            let xT    = CGFloat(cos(angle)) * dist
            let yT    = CGFloat(sin(angle)) * dist * 0.6 + CGFloat(30 + (i * 11) % 50) * previewScale
            result.append(ConfettiPiece(
                id: i,
                color:   Self.confColors[i % Self.confColors.count],
                xTarget: xT, yTarget: yT,
                rotate:  Double(i * 43 % 720),
                w: CGFloat(4 + i % 6) * previewScale,
                h: CGFloat(2 + i % 4) * previewScale,
                delay: Double(i % 8) * 0.03
            ))
        }
        return result
    }

    // ── Reset helper ──────────────────────────────────────────────────────────
    private func resetPreview() {
        previewFireworks = []; previewSparks = []
        previewBubbles = []; previewSparkles = []
        confettiPieces = []
        fwShooting = false; fwFading = false; sparksFalling = false
        confettiActive = false
    }

    // ── Preview trigger ───────────────────────────────────────────────────────
    private func triggerPreview() {
        guard !previewing else { return }
        previewing = true
        resetPreview()

        switch animationType {
        case .none:
            previewing = false
            return

        case .confetti:
            confettiPieces = makeConfetti()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000)
                confettiActive = true
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                resetPreview()
                previewing = false
            }

        case .pixelFireworks:
            let fws = makePreviewFireworks()
            previewFireworks = fws
            previewSparks    = makePreviewSparks(from: fws)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000)
                fwShooting = true
                try? await Task.sleep(nanoseconds: 350_000_000)   // matches real 350 ms
                fwFading = true; sparksFalling = true
                try? await Task.sleep(nanoseconds: 2_700_000_000) // matches real 2.7 s tail
                resetPreview()
                previewing = false
            }

        case .fizzySoda:
            previewBubbles = makePreviewBubbles()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_200_000_000) // matches real 5.2 s
                resetPreview()
                previewing = false
            }

        case .retroSparkle:
            previewSparkles = makePreviewSparkles()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_200_000_000) // matches real sparkle duration
                resetPreview()
                previewing = false
            }

        case .victory:
            let fws = makePreviewFireworks()
            previewFireworks = fws
            previewSparks    = makePreviewSparks(from: fws)
            previewBubbles   = makePreviewBubbles()
            previewSparkles  = makePreviewSparkles()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000)
                fwShooting = true
                try? await Task.sleep(nanoseconds: 350_000_000)   // matches real 350 ms
                fwFading = true; sparksFalling = true
                try? await Task.sleep(nanoseconds: 5_500_000_000) // matches real 5.5 s
                resetPreview()
                previewing = false
            }
        }
    }

    // ── Body ──────────────────────────────────────────────────────────────────
    var body: some View {
        HStack(spacing: 14) {
            // ── Mini ring (130×130 container) ──────────────────────────────
            ZStack {
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                useLightMode ? CardRunnerTheme.neonBlueDark   : CardRunnerTheme.neonBlue,
                                useLightMode ? CardRunnerTheme.neonPurpleDark : CardRunnerTheme.neonPurple
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 4
                    )
                    .frame(width: 110, height: 110)

                VStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(LinearGradient(
                            colors: [Color(hex: "#34D399"), Color(hex: "#10B981")],
                            startPoint: .top, endPoint: .bottom
                        ))
                    Text("Complete")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(useLightMode ? Color(hex: "#0F1923") : .white)
                }

                // ── Inline particle overlay ────────────────────────────────
                if !previewFireworks.isEmpty || !previewSparks.isEmpty
                    || !previewBubbles.isEmpty || !previewSparkles.isEmpty
                    || !confettiPieces.isEmpty {

                    let ringR: CGFloat = 115 * previewScale

                    ZStack {
                        // Pixel Fireworks — two-phase shoot + fade
                        ForEach(previewFireworks) { fw in
                            let ca = CGFloat(cos(fw.spawnAngle))
                            let sa = CGFloat(sin(fw.spawnAngle))
                            PixelStarburst(rayLength: fw.rayLength, color: fw.color)
                                .offset(
                                    x: fwShooting ? ca * (ringR + 90 * previewScale) : ca * ringR,
                                    y: fwShooting ? sa * (ringR + 90 * previewScale) : sa * ringR
                                )
                                .opacity(fwFading ? 0.0 : 1.0)
                                .animation(.easeOut(duration: 0.50).delay(fw.delay),        value: fwShooting)
                                .animation(.easeOut(duration: 0.25).delay(fw.delay + 0.35), value: fwFading)
                        }

                        // Pixel Sparks — scatter with gravity
                        ForEach(previewSparks) { sp in
                            Rectangle()
                                .fill(sp.color)
                                .frame(width: sp.size, height: sp.size)
                                .offset(
                                    x: sparksFalling ? sp.originX + sp.targetX : sp.originX,
                                    y: sparksFalling ? sp.originY + sp.targetY : sp.originY
                                )
                                .opacity(sparksFalling ? 0.0 : 1.0)
                                .animation(.easeOut(duration: sp.duration).delay(sp.delay), value: sparksFalling)
                        }

                        // Fizzy Soda — self-managed bubble views
                        ForEach(previewBubbles) { b in FizzySodaBubbleView(b: b) }

                        // Retro Sparkle — self-managed sparkle views
                        ForEach(previewSparkles) { sp in RetroSparkleShapeView(sp: sp) }

                        // Confetti (offset-based, bounded to ring)
                        ForEach(confettiPieces) { piece in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(piece.color)
                                .frame(width: piece.w, height: piece.h)
                                .rotationEffect(.degrees(confettiActive ? piece.rotate : 0))
                                .offset(
                                    x: confettiActive ? piece.xTarget : 0,
                                    y: confettiActive ? piece.yTarget : 0
                                )
                                .opacity(confettiActive ? 0.0 : 1.0)
                                .animation(.easeOut(duration: 1.0).delay(piece.delay), value: confettiActive)
                        }
                    }
                    .frame(width: 130, height: 130)
                    .clipped()
                    .allowsHitTesting(false)
                }
            }
            .frame(width: 130, height: 130)
            .clipped()

            // ── Label + description + button ───────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text(animationType.label)
                    .font(.system(size:12).weight(.semibold))
                    .foregroundStyle(useLightMode ? Color(hex: "#0F1923") : .white)
                Text(animationType.previewDescription)
                    .font(.system(size:10))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if animationType != .none {
                    Button { triggerPreview() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: previewing ? "stop.circle" : "play.circle.fill")
                                .font(.system(size: 11))
                            Text(previewing ? "Playing…" : "▶  Preview")
                                .font(.system(size:11).weight(.medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(
                            previewing ? Color.orange.opacity(0.18) : Color.accentColor.opacity(0.18)
                        ))
                        .foregroundStyle(previewing ? Color.orange : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(previewing)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(useLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(useLightMode ? Color.black.opacity(0.08) : Color.white.opacity(0.10), lineWidth: 1))
        )
    }
}

// MARK: - Shortcut System

/// Reference wrapper so NSEvent closures can read the latest value without a stale value-type capture.
private final class Ref<T> {
    var value: T
    init(_ v: T) { value = v }
}

struct RecordedShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlags: UInt   // NSEvent.ModifierFlags rawValue, masked to relevant modifiers

    static let none = RecordedShortcut(keyCode: 65535, modifierFlags: 0)
    var isNone: Bool { keyCode == 65535 }

    var displayString: String {
        if isNone { return "—" }
        var parts: [String] = []
        let m = NSEvent.ModifierFlags(rawValue: modifierFlags)
        if m.contains(.control) { parts.append("⌃") }
        if m.contains(.option)  { parts.append("⌥") }
        if m.contains(.shift)   { parts.append("⇧") }
        if m.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyLabel(for: keyCode))
        return parts.joined(separator: " + ")
    }

    static func keyLabel(for code: UInt16) -> String {
        switch code {
        case 0:  return "A";  case 1:  return "S";  case 2:  return "D";  case 3:  return "F"
        case 4:  return "H";  case 5:  return "G";  case 6:  return "Z";  case 7:  return "X"
        case 8:  return "C";  case 9:  return "V";  case 11: return "B";  case 12: return "Q"
        case 13: return "W";  case 14: return "E";  case 15: return "R";  case 16: return "Y"
        case 17: return "T";  case 31: return "O";  case 32: return "U";  case 34: return "I"
        case 35: return "P";  case 37: return "L";  case 38: return "J";  case 40: return "K"
        case 45: return "N";  case 46: return "M"
        case 18: return "1";  case 19: return "2";  case 20: return "3";  case 21: return "4"
        case 22: return "6";  case 23: return "5";  case 25: return "9";  case 26: return "7"
        case 28: return "8";  case 29: return "0"
        case 43: return ",";  case 44: return "/";  case 47: return "."
        case 36: return "↩";  case 48: return "⇥";  case 49: return "Space"
        case 51: return "⌫";  case 53: return "⎋"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        default: return "[\(code)]"
        }
    }
}

enum ShortcutAction: String, CaseIterable {
    case toggleAutoIngest = "toggleAutoIngest"
    case stopTransfer     = "stopTransfer"
    case switchToVideo    = "switchToVideo"
    case switchToPhoto    = "switchToPhoto"
    case openSettings     = "openSettings"
    case openLog          = "openLog"
    case openHistory      = "openHistory"
    case openInFinder     = "openInFinder"
    // Preset slots 1–6 (⌘1 … ⌘6 by default)
    case switchPreset1    = "switchPreset1"
    case switchPreset2    = "switchPreset2"
    case switchPreset3    = "switchPreset3"
    case switchPreset4    = "switchPreset4"
    case switchPreset5    = "switchPreset5"
    case switchPreset6    = "switchPreset6"

    var label: String {
        switch self {
        case .toggleAutoIngest: return "Toggle Auto Ingest"
        case .stopTransfer:     return "Stop Transfer"
        case .switchToVideo:    return "Switch to Video Mode"
        case .switchToPhoto:    return "Switch to Photo Mode"
        case .openSettings:     return "Open Settings"
        case .openLog:          return "Toggle Log Panel"
        case .openHistory:      return "Toggle History Panel"
        case .openInFinder:     return "Open Last Destination in Finder"
        case .switchPreset1:    return "Switch to Preset 1"
        case .switchPreset2:    return "Switch to Preset 2"
        case .switchPreset3:    return "Switch to Preset 3"
        case .switchPreset4:    return "Switch to Preset 4"
        case .switchPreset5:    return "Switch to Preset 5"
        case .switchPreset6:    return "Switch to Preset 6"
        }
    }

    var section: String {
        switch self {
        case .toggleAutoIngest, .stopTransfer:              return "Ingest"
        case .switchToVideo, .switchToPhoto, .openSettings: return "Navigation"
        case .openLog, .openHistory, .openInFinder:         return "Panels"
        case .switchPreset1, .switchPreset2, .switchPreset3,
             .switchPreset4, .switchPreset5, .switchPreset6: return "Presets"
        }
    }

    var defaultShortcut: RecordedShortcut {
        let cmd = NSEvent.ModifierFlags.command.rawValue
        switch self {
        case .toggleAutoIngest: return RecordedShortcut(keyCode: 49,  modifierFlags: 0)    // Space
        case .stopTransfer:     return RecordedShortcut(keyCode: 7,   modifierFlags: 0)    // X
        case .switchToVideo:    return RecordedShortcut(keyCode: 123, modifierFlags: 0)    // ←
        case .switchToPhoto:    return RecordedShortcut(keyCode: 124, modifierFlags: 0)    // →
        case .openSettings:     return RecordedShortcut(keyCode: 43,  modifierFlags: cmd)  // ⌘,
        case .openLog:          return RecordedShortcut(keyCode: 37,  modifierFlags: 0)    // L
        case .openHistory:      return RecordedShortcut(keyCode: 4,   modifierFlags: 0)    // H
        case .openInFinder:     return RecordedShortcut(keyCode: 3,   modifierFlags: 0)    // F
        case .switchPreset1:    return RecordedShortcut(keyCode: 18,  modifierFlags: cmd)  // ⌘1
        case .switchPreset2:    return RecordedShortcut(keyCode: 19,  modifierFlags: cmd)  // ⌘2
        case .switchPreset3:    return RecordedShortcut(keyCode: 20,  modifierFlags: cmd)  // ⌘3
        case .switchPreset4:    return RecordedShortcut(keyCode: 21,  modifierFlags: cmd)  // ⌘4
        case .switchPreset5:    return RecordedShortcut(keyCode: 23,  modifierFlags: cmd)  // ⌘5
        case .switchPreset6:    return RecordedShortcut(keyCode: 22,  modifierFlags: cmd)  // ⌘6
        }
    }
}

/// Inspect a card's folder structure and return the most likely camera brand/model.
nonisolated func detectCameraModel(at path: String) -> String {
    let fm  = FileManager.default
    let url = URL(fileURLWithPath: path)
    func exists(_ rel: String) -> Bool { fm.fileExists(atPath: url.appendingPathComponent(rel).path) }
    let root = (try? fm.contentsOfDirectory(atPath: path)) ?? []

    // ── Sony ────────────────────────────────────────────────────────────────
    if exists("PRIVATE/M4ROOT")  { return "Sony" }          // FX3, FX6, FX9, Venice, Alpha (PRIVATE layout)
    if exists("M4ROOT")          { return "Sony" }          // FX6/FX9/Venice/Type-A (M4ROOT at card root)
    if exists("AVF_INFO")        { return "Sony" }          // Sony Pro companion folder (Venice/FX9/FX6)
    if exists("BPAV")            { return "Sony XDCAM" }    // PMW / PDW series
    if exists("XDROOT")          { return "Sony XDCAM" }    // XDCAM EX

    // ── RED ─────────────────────────────────────────────────────────────────
    if root.contains(where: { $0.hasSuffix(".RDM") })       { return "RED" }

    // ── Blackmagic ──────────────────────────────────────────────────────────
    if exists("Blackmagic RAW")  { return "Blackmagic" }
    if root.contains(where: { $0.lowercased().hasSuffix(".braw") }) { return "Blackmagic" }

    // ── ARRI ────────────────────────────────────────────────────────────────
    if exists("ARRI")            { return "ARRI" }

    // ── Canon Cinema (C70, C300, C500) ──────────────────────────────────────
    if exists("MXF")             { return "Canon Cinema" }

    // ── Panasonic (VariCam, AU-EVA) ─────────────────────────────────────────
    if exists("CONTENTS")        { return "Panasonic" }

    // ── AVCHD (Sony/Panasonic consumer) ─────────────────────────────────────
    if exists("AVCHD") || exists("PRIVATE/AVCHD") { return "AVCHD" }

    // ── DCIM-based cameras ───────────────────────────────────────────────────
    let dcimPath = url.appendingPathComponent("DCIM").path
    if let dcim = try? fm.contentsOfDirectory(atPath: dcimPath) {
        let up = dcim.map { $0.uppercased() }
        if up.contains(where: { $0.hasPrefix("DJI") })                          { return "DJI" }
        if up.contains(where: { $0.contains("GOPRO") || $0.contains("GOPR") })  { return "GoPro" }
        if exists("MISC/NIKON") || exists("MISC/THM")                           { return "Nikon" }
        if exists("MISC")                                                         { return "Canon" }
        // Generic DCIM fallback (Fuji, Olympus, etc.)
        return "Camera"
    }

    return "Camera"
}

// MARK: - Lenient array decoding

/// Wrapper that decodes its element leniently — a failed element becomes nil instead
/// of throwing, so an array of these never fails wholesale on one corrupt/legacy row.
private struct LenientDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - All-Time Stats

// MARK: - Ingest Phase

// MARK: - Per-Ingest State

// MARK: - Ingest Outcome (pure, testable)

// MARK: - Progress protocol parsing (pure, testable)

// MARK: - Concurrent scheduler (pure, testable)

/// Media file extensions used to auto-pick the subfolder that already holds footage when a project
/// has no "clips" folder (destination subfolder picker). Lowercase, no dot.
let kFootageExtensions: Set<String> = [
    "mov", "mp4", "m4v", "mxf", "avi", "braw", "r3d", "ari", "arri", "dpx", "mts", "m2ts", "avchd",
    "arw", "cr2", "cr3", "nef", "dng", "raf", "rw2", "orf", "srw", "gpr",
    "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff",
    "wav", "aif", "aiff"
]

/// Animatable state for the v3 gloss sheen sweep (KeyframeAnimator drives x + opacity).
struct V3SheenState { var x: CGFloat = 0; var opacity: Double = 0 }

/// Reusable tactile hover for any interactive control — a subtle spring scale + optional brighten +
/// optional colored glow, applied on `.onHover`. Event-driven (fires only on hover enter/exit), so no
/// always-on render cost. Each use carries its own `@State`, so buttons track hover independently.
/// The single idiom behind the app's "every control reacts" feel. Color-shift hovers (X→red,
/// Add-button→cyan) are handled inline where the CONTENT's foreground must change.
struct V3HoverModifier: ViewModifier {
    var scale: CGFloat
    var glow: Color?
    var brighten: Bool
    var enabled: Bool
    @State private var hovering = false
    // Reduce Motion: suppress the tactile SCALE bounce (the motion part) and swap the spring for a
    // quick ease. Brightness + glow are opacity, not motion, so they stay — the control still reads
    // as reacting, it just doesn't move. (UI-future.md: respect Reduce Motion.)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var active: Bool { hovering && enabled }
    func body(content: Content) -> some View {
        content
            .brightness(active && brighten ? 0.06 : 0)
            .scaleEffect(active && !reduceMotion ? scale : 1)
            .shadow(color: (glow ?? .clear).opacity(active ? 0.5 : 0), radius: 12)
            .animation(reduceMotion ? .easeInOut(duration: 0.12)
                                    : .spring(response: 0.3, dampingFraction: 0.65), value: active)
            .onHover { hovering = $0 }
    }
}
extension View {
    /// Tactile hover (scale + optional glow/brighten). Use `.contentShape(Rectangle())` on the label
    /// first when the control needs a bigger hit target than its visible content. Pass `enabled: false`
    /// for a disabled control so it doesn't bounce/glow while being unclickable.
    func v3Hover(scale: CGFloat = 1.03, glow: Color? = nil, brighten: Bool = true, enabled: Bool = true) -> some View {
        modifier(V3HoverModifier(scale: scale, glow: glow, brighten: brighten, enabled: enabled))
    }

    /// "Active card" surface: tinted fill + colored border + a soft STATIC outer glow, so a
    /// waiting/done tile reads as hot/alive. Reusable across tiles (amber for waiting, green for
    /// safe-to-pull, etc.). Static shadow ONLY — never animate it (see the no-always-on-
    /// TimelineView core-burn rule). Do NOT `.clipShape` after this — clipping kills the glow.
    func v3GlowCard(tint: Color, radius: CGFloat = 18,
                    fill: Double = 0.04, border: Double = 0.5,
                    glow: Double = 0.28, glowRadius: CGFloat = 22) -> some View {
        self
            .background(tint.opacity(fill), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(tint.opacity(border), lineWidth: 1.5))
            .shadow(color: tint.opacity(glow), radius: glowRadius, y: 0)
    }
}

/// One celebration particle — target offset from the ring center, look baked in at fire time.
private struct V3Particle: Identifiable {
    let id = UUID()
    var dx: CGFloat        // end x offset from ring center
    var dy: CGFloat        // end y offset
    var size: CGFloat
    var color: Color
    var rotate: Double
    var anchored: Bool     // true = sits at (dx,dy) and twinkles out; false = flies out from center
}

/// The v3 transfer-completion celebration — a ONE-SHOT neon burst anchored to the ring. Fired by a
/// `trigger` bump; self-clears after ~1.1s. NO always-on TimelineView (the core-burn gotcha) — it uses
/// a single `withAnimation` + a delayed clear, exactly like the sheen. Honors Reduce Motion. The six
/// `CompletionAnimation` rawValues are preserved (zero migration); each renders a fresh v3 neon look.
struct V3CompletionOverlay: View {
    let center: CGPoint
    let radius: CGFloat
    let style: CompletionAnimation
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var particles: [V3Particle] = []
    @State private var active = false      // drives particle travel + fade
    @State private var ringPulse = false   // expanding shockwave rings
    @State private var glow = false        // gold "all safe" ring glow (victory)

    private var neon: [Color] {
        [Color(hex: "#0dcff5"), Color(hex: "#7c3aed"), Color(hex: "#d946ef"), Color(hex: "#34d399")]
    }

    var body: some View {
        ZStack {
            if ringPulse {
                Circle().stroke(Color(hex: "#0dcff5"), lineWidth: 3).frame(width: radius * 2, height: radius * 2)
                    .scaleEffect(active ? 1.9 : 0.92).opacity(active ? 0 : 0.9)
                Circle().stroke(Color(hex: "#d946ef"), lineWidth: 2).frame(width: radius * 2, height: radius * 2)
                    .scaleEffect(active ? 2.35 : 0.92).opacity(active ? 0 : 0.65)
            }
            if glow {
                Circle().stroke(Color(hex: "#fbbf24"), lineWidth: 12).frame(width: radius * 2, height: radius * 2)
                    .blur(radius: 16).scaleEffect(active ? 1.18 : 1.0).opacity(active ? 0 : 0.85)
            }
            ForEach(particles) { p in
                particleShape(p)
                    .offset(x: p.anchored ? p.dx : (active ? p.dx : 0),
                            y: p.anchored ? p.dy : (active ? p.dy : 0))
                    .rotationEffect(.degrees(active ? p.rotate : 0))
                    .scaleEffect(p.anchored ? (active ? 0.2 : 1.0) : 1.0)
                    .opacity(active ? 0 : 1)
            }
        }
        .position(center)
        .onChange(of: trigger) { _, _ in fire() }
    }

    @ViewBuilder private func particleShape(_ p: V3Particle) -> some View {
        switch style {
        case .fizzySoda:
            Circle().fill(p.color.opacity(0.28))
                .overlay(Circle().strokeBorder(p.color.opacity(0.75), lineWidth: 1))
                .frame(width: p.size, height: p.size)
        case .retroSparkle:
            Image(systemName: "sparkle").font(.system(size: p.size)).foregroundStyle(p.color)
                .shadow(color: p.color.opacity(0.8), radius: 4)
        case .pixelFireworks:
            Capsule().fill(p.color).frame(width: 2.5, height: p.size)       // thin radial sparks
        default:
            RoundedRectangle(cornerRadius: 1.5).fill(p.color).frame(width: p.size, height: p.size * 2)
                .shadow(color: p.color.opacity(0.6), radius: 3)             // neon glass-shard confetti
        }
    }

    private func fire() {
        guard style != .none else { return }
        active = false
        if reduceMotion {                        // minimal: one gentle ring pulse, no flying particles
            particles = []; glow = false; ringPulse = true
            withAnimation(.easeOut(duration: 0.8)) { active = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { ringPulse = false; active = false }
            return
        }
        ringPulse = (style == .pixelFireworks || style == .victory)
        glow = (style == .victory)
        particles = makeParticles()
        withAnimation(.easeOut(duration: 1.0)) { active = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            particles = []; ringPulse = false; glow = false; active = false
        }
    }

    private func makeParticles() -> [V3Particle] {
        switch style {
        case .none:           return []
        case .pixelFireworks: return radial(count: 16, spark: true)
        case .confetti:       return radial(count: 36, spark: false)
        case .victory:        return radial(count: 30, spark: false)
        case .fizzySoda:      return bubbles(count: 14)
        case .retroSparkle:   return ringSparkles(count: 16)
        }
    }

    /// Shards/sparks flying out from the ring center (with a little downward gravity for confetti).
    private func radial(count: Int, spark: Bool) -> [V3Particle] {
        (0..<count).map { i in
            let ang = spark ? (Double(i) / Double(count)) * 2 * .pi
                            : Double.random(in: 0..<(2 * .pi))
            let dist = radius * CGFloat.random(in: 1.15...2.15)
            let grav: CGFloat = spark ? 0 : CGFloat.random(in: 10...40)
            return V3Particle(dx: cos(ang) * dist, dy: sin(ang) * dist + grav,
                              size: spark ? CGFloat.random(in: 14...24) : CGFloat.random(in: 5...9),
                              color: neon.randomElement()!, rotate: Double.random(in: -220...220), anchored: false)
        }
    }

    /// Translucent bubbles rising up around the ring.
    private func bubbles(count: Int) -> [V3Particle] {
        (0..<count).map { _ in
            V3Particle(dx: CGFloat.random(in: -radius...radius), dy: -CGFloat.random(in: radius...radius * 2),
                       size: CGFloat.random(in: 6...16),
                       color: [Color(hex: "#7c3aed"), Color(hex: "#0dcff5")].randomElement()!,
                       rotate: 0, anchored: false)
        }
    }

    /// Neon sparkles that appear ON the ring circumference and twinkle out.
    private func ringSparkles(count: Int) -> [V3Particle] {
        (0..<count).map { i in
            let ang = (Double(i) / Double(count)) * 2 * .pi + Double.random(in: -0.15...0.15)
            let r = radius * CGFloat.random(in: 0.92...1.08)
            return V3Particle(dx: cos(ang) * r, dy: sin(ang) * r,
                              size: CGFloat.random(in: 12...20), color: neon.randomElement()!,
                              rotate: 0, anchored: true)
        }
    }
}

/// The destination-tile remove control — a dim "minus" that becomes a RED "X" on hover (destructive
/// affordance), matching the module close X. Its own hover `@State`.
struct V3TileRemoveButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: hovering ? "xmark.circle.fill" : "minus")
                .font(.system(size: hovering ? 15 : 12, weight: .bold))
                .foregroundStyle(hovering ? Color(hex: "#f87171") : .white.opacity(0.4))
                .scaleEffect(hovering ? 1.12 : 1)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: hovering)
        .onHover { hovering = $0 }
        .help("Remove this destination")
    }
}

/// The module close "X" — turns RED on hover (destructive affordance), then runs the module's own
/// close transition on click. A dedicated struct so it can hold its own hover `@State`.
struct V3CloseButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                .foregroundStyle(hovering ? Color(hex: "#f87171") : .white.opacity(0.6))
                .frame(width: 30, height: 30)
                .background((hovering ? Color(hex: "#f87171").opacity(0.16) : .white.opacity(0.05)), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(hovering ? Color(hex: "#f87171").opacity(0.55) : .white.opacity(0.10)))
                .scaleEffect(hovering ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - v3 Settings categories (icon-rail redesign)

/// The left icon-rail categories for the redesigned v3 Settings screen. Every legacy setting
/// is migrated into exactly one of these (Presets / Shortcuts / About embed the existing flows).
enum V3SettingsCat: String, CaseIterable, Identifiable {
    case general, verify, naming, files, performance, presets, shortcuts, about
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general:     return "slider.horizontal.3"
        case .verify:      return "checkmark.shield"
        case .naming:      return "tag"
        case .files:       return "doc.on.doc"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .presets:     return "square.stack.3d.up"
        case .shortcuts:   return "keyboard"
        case .about:       return "info.circle"
        }
    }
    var title: String {
        switch self {
        case .general:     return "General"
        case .verify:      return "Verify & Safety"
        case .naming:      return "Naming & Folders"
        case .files:       return "Files & Copy"
        case .performance: return "Performance"
        case .presets:     return "Presets"
        case .shortcuts:   return "Shortcuts"
        case .about:       return "About"
        }
    }
    var subtitle: String {
        switch self {
        case .general:     return "Sounds, ordering, and session behavior"
        case .verify:      return "Checksums, ejection, and reports"
        case .naming:      return "Folder names, tags, and scaffolding"
        case .files:       return "What gets copied and backed up"
        case .performance: return "Throughput and concurrency"
        case .presets:     return "Saved setups for different shoots"
        case .shortcuts:   return "Keyboard shortcuts"
        case .about:       return "Version, license, and developer tools"
        }
    }
}

// MARK: - Main View

struct ContentView: View {

    // Accessibility: honor the system "Reduce Motion" setting across the v3 UI. Decorative springs
    // (module open/close, settings swoosh, tile pops, banner slides) route through `v3Anim(_:)` so
    // they collapse to a quick cross-fade — the load-bearing status (ring %, funnel) is already calm.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Wrap a decorative animation so it degrades under Reduce Motion. Returns a fast ease (a gentle
    /// cross-fade, no bounce/scale travel) when the setting is on, else the supplied animation.
    private func v3Anim(_ a: Animation) -> Animation { reduceMotion ? .easeInOut(duration: 0.12) : a }
    /// Module (settings / add / edit / history / log) enter-exit. Scale-in normally; plain
    /// cross-fade (no scale travel) under Reduce Motion.
    private var v3ModuleTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .center))
    }

    // Theme base — mode-aware so icons/buttons stay readable in both modes
    private var accentBlue:   Color { useLightMode ? Color(hex: "#2472A4") : Color(hex: "#3DC8F5") }
    private var accentPurple: Color { useLightMode ? CardRunnerTheme.neonPurpleDark : CardRunnerTheme.neonPurple }
    /// Onboarding-matching violet — used for destination-mode UI (toggle, drive icon, action buttons)
    private var accentViolet: Color { useLightMode ? Color(hex: "#6D3BBF") : Color(hex: "#9B5FFF") }

    // Light mode was REMOVED — the app is dark-only. This stays as a constant `false` so the
    // many `useLightMode ? light : dark` color branches resolve to dark, and any previously
    // saved pref_useLightMode=true is ignored. No toggle / shortcut sets it any more.
    private var useLightMode: Bool { false }
    @AppStorage("pref_importMode") private var importMode: String = "video"
    @AppStorage("pref_ingestOrder") private var ingestOrder: String = "oldest"

    private var isVideoMode:  Bool   { importMode != "photo" }
    /// "clips" in video mode, "photos" in photo mode — used in ring labels and queue rows.
    private var mediaLabel:   String { isVideoMode ? "clips" : "photos" }

    /// Human-readable label for the custom date filter (e.g. "Apr 17, 2026").
    private var formattedDateFilterFrom: String {
        let parse = DateFormatter(); parse.dateFormat = "yyyyMMdd"
        guard let d = parse.date(from: dateFilterFrom) else { return "Choose a date" }
        let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .none
        return fmt.string(from: d)
    }

    /// true on Sonoma / Sequoia (macOS 14 & 15); false on Tahoe (macOS 26+).
    /// Drives the entire visual pivot: glass+dark → native materials+system colors.
    private var isLegacyOS: Bool {
        if #available(macOS 26, *) { return false }
        return true
    }

    private var bgColor: Color {
        // Legacy dark: gradient is the bg, so bgColor used in sub-views matches it
        if isLegacyOS && useLightMode { return Color.clear }
        return useLightMode ? Color(hex: "#CDD5E0") : Color(hex: "#05101e")
    }

    private var panelColor: Color {
        // Legacy light: system card color. Legacy dark: same as Tahoe dark.
        if isLegacyOS && useLightMode { return Color(nsColor: .controlBackgroundColor).opacity(0.8) }
        return useLightMode ? Color.white.opacity(0.92) : Color.white.opacity(0.055)
    }

    private var borderStroke: Color {
        if isLegacyOS && useLightMode { return Color(nsColor: .separatorColor) }
        return useLightMode ? Color(hex: "#9AA5B8") : Color.white.opacity(0.13)
    }

    private var textPrimary: Color {
        if isLegacyOS && useLightMode { return Color(nsColor: .labelColor) }
        return useLightMode ? Color(hex: "#0F1923") : Color.white
    }
    private var textSecondary: Color {
        if isLegacyOS && useLightMode { return Color(nsColor: .secondaryLabelColor) }
        return useLightMode ? Color(hex: "#374151") : Color.white.opacity(0.78)
    }
    private var textMuted: Color {
        if isLegacyOS && useLightMode { return Color(nsColor: .tertiaryLabelColor) }
        return useLightMode ? Color(hex: "#6B7280") : Color.white.opacity(0.50)
    }

    // Volumes & project
    @State private var isShowingSettings = false
    @State private var isShowingSupportBundle = false
    @State private var supportBundleText = ""
    @State private var lastIngestSummary: IngestHistoryEntry? = nil
    @State private var showSkipDetail: Bool = false

    // Editable shortcuts
    @AppStorage("pref_customShortcutsJSON") private var customShortcutsJSON: String = "{}"
    @State private var recordingAction: ShortcutAction? = nil
    @State private var shortcutMonitorToken: Any? = nil
    @State private var recordingRef  = Ref<ShortcutAction?>(nil)
    @State private var shortcutsRef  = Ref<[String: RecordedShortcut]>([:])

    // Pro Tools feature flags (all off by default)
    @AppStorage("pref_dualDestEnabled")       private var dualDestEnabled: Bool = false
    @AppStorage("pref_fullVerifyEnabled")     private var fullVerifyEnabled: Bool = false
    @AppStorage("pref_transferReportEnabled") private var transferReportEnabled: Bool = false
    @AppStorage("pref_renameOnIngest")        private var renameOnIngestEnabled: Bool = false
    @AppStorage("pref_renameTemplate")        private var renameTemplate: String = "{cardname}_{original}"
    @AppStorage("winterOlympicsMode") private var winterOlympicsMode: Bool = false
    @AppStorage("pref_olympicsCode") private var olympicsCode: String = "TUWE"
    @AppStorage("copyXML") private var copyXML: Bool = false
    @AppStorage("pref_lastVideoCopyXML") private var lastVideoCopyXML: Bool = true
    @State private var availableDestinations: [Volume] = []
    @State private var availableProjects: [String] = []
    @State private var availableSubfolders: [String] = []

    @State private var selectedPrimary: Volume?
    @State private var selectedSecondary: Volume?
    @AppStorage("pref_secondaryPath") private var secondaryPath: String = ""
    @AppStorage("pref_projectName") private var projectName: String = ""
    @AppStorage("pref_selectedSubfolder") private var selectedSubfolder: String = "Default"
    @AppStorage("pref_dateFolderFormat") private var dateFolderFormat: String = "%y%m%d"
    @AppStorage("pref_finderTagEnabled") private var finderTagEnabled: Bool = true
    @AppStorage("pref_finderTagColor") private var finderTagColor: String = "green"

    // Controls
    @State private var showIngestAlert: Bool = false
    @State private var ingestAlertTitle: String = ""
    @State private var ingestAlertMessage: String = ""
    @AppStorage("pref_dryRun") private var dryRun: Bool = false
    @State private var autoIngest: Bool = false
    @AppStorage("pref_useCustomCardName") private var useCustomCardName: Bool = false
    @AppStorage("pref_customCardName") private var customCardName: String = ""
    @AppStorage("pref_todayOnly")       private var todayOnly: Bool   = true  // legacy, kept for migration
    @AppStorage("pref_dateFilterMode")    private var dateFilterMode:    String = "today" // "all"|"today"|"custom"
    @AppStorage("pref_dateFilterFrom")    private var dateFilterFrom:    String = ""       // YYYYMMDD lower bound
    @AppStorage("pref_dateFilterTo")      private var dateFilterTo:      String = ""       // YYYYMMDD upper bound (range)
    @AppStorage("pref_dateFilterSubMode") private var dateFilterSubMode: String = "single" // "single"|"range"
    @State private var showDatePopover: Bool = false
    @State private var showDateToPopover: Bool = false
    @State private var dateToTextFieldStr: String = ""
    @FocusState private var dateToFieldFocused: Bool
    @State private var showPresetDatePopover: Bool = false
    /// Intermediate buffer so the date TextField doesn't reformat on every keystroke.
    @State private var dateTextFieldStr: String = ""
    @FocusState private var dateFieldFocused: Bool
    @AppStorage("pref_autoEject") private var autoEject: Bool = false

    // v3 free-space labels are probed OFF the main thread and cached here so a slow/
    // sleeping/wedged drive can never stall a render. Renders read the cache; lifecycle
    // events (appear / mount / unmount / 30-s loop / add-dest sheet) refresh it.
    @State private var v3FreeSpaceCache: [String: String] = [:]

    // v3 design sheets — Add destination / New project folder
    @State private var showV3AddDest = false
    @State private var v3AddIsSSD = true
    @State private var v3AddDrivePath = ""
    @State private var v3AddCustomPath = ""
    @State private var v3AddProject = ""        // per-destination project folder (SSD tab)
    @State private var v3AddSubfolder = "Default"
    @State private var v3AddName = ""           // destination display name (auto-derived, editable)
    @State private var v3AddNameEdited = false  // don't stomp a name the user typed
    @State private var v3AddError = ""          // duplicate-leaf / validation message
    // v3 per-destination EDITOR (click a tile) — reuses the Add sheet's project/subfolder/name fields.
    @State private var showV3EditDest = false
    @State private var v3EditDestID: UUID? = nil   // which destination is being edited
    @State private var v3EditProject = ""
    @State private var v3EditSubfolder = "Default"
    @State private var v3EditName = ""
    @State private var v3EditNameEdited = true  // an existing dest already has a chosen name — don't auto-stomp it
    @State private var v3EditError = ""
    @State private var v3SettingsCat: V3SettingsCat = .general   // selected icon-rail category
    @State private var v3NewScaffold: String = ""                // add-folder field in the v3 scaffold editor
    @FocusState private var editingAwaitingID: UUID?             // which awaiting lane's name field is live
    @FocusState private var editingActiveID: UUID?              // which active lane's name field is live
    @FocusState private var v3NameFocused: Bool                 // Add/Edit destination-name field focus
    @State private var v3PreEditName: String = ""               // value captured on focus-gain, for Esc-revert
    @State private var v3SheenTrigger = 0                        // bump to fire one gloss sweep
    // Stable timer (a fresh Timer.publish in onReceive would resubscribe every body eval).
    private let v3SheenTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    @State private var showV3DateRange = false
    @State private var v3RangeFrom = Date()
    @State private var v3RangeTo = Date()
    @State private var v3RangeSingleDay = false
    @State private var showV3History = false
    @State private var showV3Log = false
    @State private var showV3NewProject = false
    @State private var v3ProjName = ""
    @State private var v3ProjColorIndex = 4          // default green
    @State private var v3ProjScaffoldOn: [String: Bool] = [:]
    @State private var v3ProjParent = ""             // parent dir the new project folder is created in (drive root by default)
    @State private var v3ProjParentOverridden = false // true once the user picks a custom parent via "Change…"

    // New project folder sheet
    @State private var showNewProjectSheet: Bool = false
    @State private var newProjectName: String = ""

    // Log & status
    @State private var logText: String = ""
    @AppStorage("pref_showLog") private var showLog: Bool = false
    @State private var statusText: String = "Auto ingest is off"
    @State private var runningCount: Int = 0
    @State private var seenCardPaths: Set<String> = []
    @State private var seenCardUUIDs: Set<String> = []   // UUID-keyed dedup — survives remount (O6)
    // Cache volumeLooksLikeCard results so the expensive filesystem scan only
    // runs once per volume per mount cycle, not every 2 seconds.
    @State private var volumeCardCache: [String: Bool] = [:]
    // Track active ingest processes so we can cancel them
    @State private var activeProcesses: [UUID: Process] = [:]
    // IDs explicitly cancelled by the user — used in the termination handler instead of
    // relying on terminationReason (.uncaughtSignal), which is unreliable when the shell
    // script has a TERM trap (trap causes a clean exit, not a signal-kill exit).
    @State private var cancelledProcessIDs: Set<UUID> = []
    // Cards waiting to be processed — sequential queue
    @State private var cardQueue: [QueuedIngest] = []
    @AppStorage("showDryRunToggle") private var showDryRunToggle: Bool = false
    @AppStorage("pref_debugMode")   private var debugMode: Bool = false

    // ── Project Scaffold ──────────────────────────────────────────────────────
    @AppStorage("pref_scaffoldEnabled")    private var scaffoldEnabled:    Bool   = false
    @AppStorage("pref_scaffoldFoldersRaw") private var scaffoldFoldersRaw: String = "Footage\nAudio\nGraphics\nExports\nAssets\nDocuments"
    @AppStorage("pref_scaffoldHintShown")  private var scaffoldHintShown:  Bool   = false
    @State private var newScaffoldFolder:            String = ""
    @State private var newScaffoldSubfolder:         String = ""   // optional subfolder for the "Add" row
    @State private var presetNewScaffoldFolder:      String = ""
    @State private var presetNewScaffoldSubfolder:   String = ""   // optional subfolder for the preset "Add" row
    @State private var editingScaffoldIndex:         Int?   = nil
    @State private var editingScaffoldText:          String = ""
    @State private var editingPresetScaffoldIndex:   Int?   = nil
    @State private var editingPresetScaffoldText:    String = ""
    @AppStorage("pref_includeProxies") private var includeProxies: Bool = false
    // Spot-check verification defaults ON: a "never lose footage" tool should
    // checksum-confirm by default, and a ≤10-file MD5 spot-check costs negligible time
    // while catching gross corruption (bad reader/controller). Full verify
    // (pref_fullVerifyEnabled) stays opt-in — it ~doubles transfer time. Users who
    // previously set this key keep their choice; only fresh installs pick up the new default.
    @AppStorage("pref_verifyTransfer") private var verifyTransfer: Bool = true
    // Max simultaneous ingests. The scheduler only ever runs cards in parallel when they
    // target DIFFERENT physical drives, so even at >1 the "many cards → one SSD" case stays
    // sequential. Default 3 enables multi-drive parallelism without risking single-drive contention.
    @AppStorage("pref_maxConcurrentCards") private var maxConcurrentCards: Int = 3
    // Per-ingest progress — one entry per active card, keyed by process UUID
    @State private var activeIngests: [UUID: ActiveIngest] = [:]
    /// Per-ingest App-Nap suppression tokens. macOS App Nap suspends a backgrounded app's
    /// helper processes (the ingest shell gets Mach-task-suspended → cardcopy never runs and
    /// the transfer hangs at 0%). beginActivity(.userInitiated) tells the OS this is important
    /// work; the token is held for the life of each ingest and released on termination.
    @State private var ingestActivities: [UUID: NSObjectProtocol] = [:]

    // Failed ingest records — persisted across restarts
    @State private var failedIngestRecords: [FailedIngestRecord] = []
    private let failedRecordsKey = "pref_failedIngestRecords"

    // SSD info
    @State private var primaryFreeBytes: Int64 = 0
    @State private var primaryTotalBytes: Int64 = 0

    // Last completed ingest summary (shown in the progress panel after an ingest finishes)
    @State private var lastNewFiles: Int = 0
    @State private var lastAvgMBps: Int = 0
    @State private var lastDurationSec: Int = 0
    @State private var lastDestPath: String = ""
    @State private var lastMediaLabel: String = "clips"  // frozen at transfer time
    @State private var lastReportPath: String = ""
    @State private var lastCollisionRenames: [(original: String, renamed: String)] = []
    @State private var destPathHovered: Bool = false
    @State private var expandedHistoryEntryID: UUID? = nil

    // Completion animation
    @AppStorage("pref_completionAnimation") private var completionAnimationRaw: String = CompletionAnimation.none.rawValue
    private var completionAnim: CompletionAnimation { CompletionAnimation(rawValue: completionAnimationRaw) ?? .none }

    // Shared gate

    // Completion confidence state — shown in the ring after a successful ingest
    @State private var showCompletionState: Bool = false

    // Confetti state (full-screen overlay)
    @State private var confettiActive: Bool = false

    // ── Inline ring particle state ────────────────────────────────────────────
    // Pixel Fireworks — two-phase (shoot then fade) + pixel spark scatter
    @State private var sparksFalling:     Bool              = false
    // Fizzy Soda — bubbles manage their own lifecycle via onAppear
    // Retro Sparkle — sparkles manage their own lifecycle via onAppear

    @Namespace private var modeToggleNS
    @Namespace private var ingestToggleNS
    @Namespace private var destToggleNS
    @Namespace private var statsToggleNS
    @Namespace private var v3AddDestSegNS   // liquid swoosh: SSD ↔ Custom Folder segment
    @Namespace private var v3DateSegNS      // liquid swoosh: Date range ↔ Single day segment
    // Hover tracking for destination tab + folder button
    @State private var destTabHovered: Bool? = nil   // nil=none, false=SSD, true=Custom
    @State private var customDestBtnHovered: Bool  = false

    // New project folder inside custom dest
    @State private var showCustomDestNewFolder:  Bool   = false
    @State private var customDestNewFolderName:  String = ""
    @State private var newProjectFolderColor:    Int    = 0   // Finder label: 0=none,2=green,3=purple,4=blue,5=yellow,6=red,7=orange
    @State private var customDestFolderColor:    Int    = 0

    // History
    @State private var historyEntries: [IngestHistoryEntry] = []

    // Multi-date ingest picker (shown when "Today only" is OFF and a card has multiple distinct dates)
    @State private var showDatePickerSheet: Bool = false
    @State private var datePickerCards: [Volume] = []       // card(s) pending date selection
    @State private var datePickerDates: [CardDateInfo] = [] // distinct dates found on card, newest-first
    @State private var datePickerSelected: Set<String> = [] // YYYYMMDD strings the user has checked
    @State private var datePickerScanning: Bool = false     // true while background retry scan is running

    // Reel picker sheet state (Tier-1 wrong-clock detection)
    @State private var showReelPickerSheet: Bool = false
    @State private var reelPickerCard: Volume? = nil
    @State private var reelPickerReels: [ReelInfo] = []
    @State private var reelPickerSelected: Set<String> = []
    @State private var reelPickerDateOverride: String = ""  // YYYYMMDD of real ingest date (today)

    // Tier-0 prompt: date filter excluded all un-ingested clips — offer "Ingest all"
    @State private var showTier0Prompt: Bool = false
    @State private var tier0Card: Volume? = nil
    @State private var tier0SkippedCount: Int = 0
    // "Already up to date" → offer Re-ingest when the MANIFEST is what blocked the copy.
    @State private var showManifestReingest: Bool = false
    @State private var manifestReingestCard: Volume? = nil
    @State private var manifestReingestDestID: UUID? = nil
    @State private var manifestReingestCount: Int = 0

    // Card nickname memory — UUID → human label persisted across sessions
    @State private var knownCardNicknames: [String: String] = [:]
    @State private var currentCardIsKnown: Bool   = false  // true → known card, show name badge
    @State private var currentCardInserted: Bool  = false  // true → any card is present (known or new)
    @State private var currentCardMatchedName: String = "" // the nickname that was auto-filled
    @State private var currentInsertedCardUUID: String? = nil  // UUID of physically-present card; lets the name field save immediately on type
    @State private var cardNameIsFromMemory: Bool = false       // true when the field was filled by applyNicknameIfKnown (not a preset or user type)
    @State private var skipNextNicknameSave: Bool = false       // blocks ONE onChange save — set before any programmatic write to customCardName
    @State private var lastAutoFilledUUID: String? = nil        // UUID we last auto-filled the name field for — prevents re-stomping on periodic re-scans (lets renames stick)

    // All-time stats
    @State private var allTimeStats: AllTimeStats = AllTimeStats()
    @State private var showingAllTimeStats: Bool = false

    // Crash recovery — populated on launch if stale checkpoints are found
    @State private var pendingCheckpoints: [IngestCheckpoint] = []
    @State private var showResumeSheet: Bool = false

    @AppStorage("pref_setupVersion")        private var setupVersion: Int = 0
    private let currentSetupVersion = 1
    /// Persisted flag — true once the user has completed (or been skipped past) onboarding.
    @AppStorage("pref_onboardingCompleted") private var onboardingCompleted: Bool = false

    @ObservedObject private var license = LicenseManager.shared

    @State private var showSetupWizard:   Bool   = false
    @State private var fdaGranted:        Bool   = true
    @State private var scanTask:          Task<Void, Never>? = nil
    @State private var showWelcomeOverlay: Bool  = false
    @State private var showOnboarding:    Bool   = false
    /// Updated by runDemoIngest so OnboardingView's Screen 3 can mirror demo progress.
    @State private var onboardingDemoStatus: String = ""
    @State private var demoTask: Task<Void, Never>? = nil

    // Presets
    @State private var presets: [IngestPreset] = []
    @State private var activePresetID: UUID? = nil
    @State private var showPresetPopover: Bool = false
    @State private var showSavePresetSheet: Bool = false
    @State private var newPresetName: String = ""
    @State private var editingPresetID: UUID? = nil
    // Preset editor modal
    @State private var showPresetEditor: Bool = false
    @State private var presetEditorIsNew: Bool = true
    @State private var presetEditorDraft: IngestPreset = IngestPreset(
        name: "", importMode: "video", dateFolderFormat: "%y%m%d",
        todayOnly: true, dateFilterMode: "today", dateFilterFrom: "", selectedSubfolder: "Default",
        useCustomCardName: false, customCardName: "",
        finderTagEnabled: false, finderTagColor: "green",
        completionAnimationRaw: "none", dayStartHour: 4,
        broadcastDayFolders: false,
        useCustomDest: false, customDestPath: "",
        autoEject: false,
        copyXML: false, verifyTransfer: false, includeProxies: false,
        dualDestEnabled: false, fullVerifyEnabled: false,
        transferReportEnabled: false, renameOnIngestEnabled: false,
        renameTemplate: "{cardname}_{original}"
    )

    // Settings sheet animation state
    @Namespace private var settingsTabNS
    @State private var hoveredPresetID: UUID? = nil
    @State private var prevTabIndex: Int = 0

    // Persisted SSD selection path
    @AppStorage("pref_primarySSDPath") private var primarySSDPath: String = ""

    // Custom destination — bypasses SSD+Project picker entirely
    @AppStorage("pref_useCustomDest")  private var useCustomDest:  Bool   = false
    @AppStorage("pref_customDestPath") private var customDestPath: String = ""

    // ── N-way destination routing (Phase 2) ─────────────────────────────────────
    // The persisted list of destinations footage can be routed to, the default one,
    // and the routing policy (mirror = every card copies to every drive; split =
    // each card lands on its own chosen drive). `destinations` is the live working
    // copy loaded from `destinationsJSON`; mutations go through `saveDestinations()`.
    @AppStorage("pref_destinationsJSON") private var destinationsJSON: String = "[]"
    @AppStorage("pref_defaultDestID")    private var defaultDestIDString: String = ""
    /// false = SPLIT (per-card routing), true = MIRROR (every card → every drive).
    @State private var destinations: [Destination] = []
    /// Cards detected while Auto-Ingest is OFF, parked waiting to be routed.
    @State private var awaitingCards: [AwaitingCard] = []
    // Per-card folder names (--cardlabel) entered on a lane, keyed by source mount path.
    // Read by startIngest at launch; survives the async analysis/picker chain.
    @State private var pendingCardLabels: [String: String] = [:]
    // Drag-to-link node UI state (bodyV3) — ported from the demo.
    @State private var destFrames: [UUID: CGRect] = [:]
    @State private var dragLine: DragLine? = nil
    @State private var dragOverDest: UUID? = nil
    @State private var v3HoveredDestID: UUID? = nil   // destination tile under the cursor (hover bounce)
    @State private var v3AddDestHovered = false       // Add-destination button hover (glow)
    @State private var v3HoveredNameID: UUID? = nil   // source-lane card-name field under the cursor (glow)
    @State private var v3DoneExpanded: Bool = false   // "N safe to pull" panel: tapped-open to review done cards
    @State private var v3LogAtBottom: Bool = true     // Activity-log: is the live tail on-screen? (drives follow + jump-to-tail)
    @State private var v3FakeCardSeq = 5              // DEV: sequence for spawned fake test cards (A006, A007…)
    @State private var v3HoveredRailCat: V3SettingsCat? = nil   // settings rail icon under the cursor (blue glow)
    @State private var v3GearHovered = false          // top-bar settings gear hover (blue glow)
    @State private var v3HistHovered = false          // top-bar history button hover (blue glow)
    // Dynamic drag of a destination tile onto the default box (make-default swap).
    @State private var v3DraggingDestID: UUID? = nil  // the tile being dragged
    @State private var v3DragOffset: CGSize = .zero    // follows the cursor
    @State private var v3DragRotation: Double = 0      // tilts with horizontal velocity
    @State private var v3DefaultPop = false            // golden pop burst on the default box on drop
    @State private var v3ReorderFrom: Int? = nil        // dragged tile's sibling index at drag start
    @State private var v3ReorderTo: Int? = nil          // live target sibling index during a reorder
    @State private var v3DragRowPitch: CGFloat = 96     // tile height + spacing (the make-room gap size)
    @State private var v3DragSettling: UUID? = nil      // keeps the just-dropped tile on top through its glide
    @State private var v3ShowDateMenu = false          // custom liquid-glass date-filter dropdown
    @State private var v3CelebrationTrigger = 0        // bump to fire the v3 completion celebration (one-shot)
    @State private var v3SettingsPreviewTrigger = 0    // bump to play the celebration in the Settings preview box
    @State private var v3PendingCelebration = false    // a real copy completed this batch → celebrate when the ring goes green
    /// Cached result of the directory-existence check for customDestPath.
    /// Updated whenever customDestPath changes and on launch — avoids calling
    /// FileManager synchronously inside canIngest on every SwiftUI render pass.
    @State private var customDestIsValid: Bool = false

    // Drives the gentle opacity pulse on the "Finalizing…" ring text during the
    // end-of-transfer flush. Toggled true while isFinalizing holds (see onChange).
    @State private var finalizePulse = false
    // Live speed sparkline — rolling 60-second window, sampled once per second
    @State private var speedHistory: [Double] = []
    private let kSpeedHistoryMax = 60
    // Stable timer instance — created ONCE for the lifetime of the view, NOT inline in
    // .onReceive(). An inline `Timer.publish(...).autoconnect()` is rebuilt on every body
    // evaluation; since copy progress mutates state ~4×/sec, onReceive kept resubscribing
    // to a fresh publisher and the 1-second countdown was perpetually reset — so the
    // sparkline never sampled until updates paused (end of transfer). A stored publisher
    // ticks reliably every second regardless of how often the body re-renders.
    private let sparklineTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // MARK: - Aggregated progress (across all active ingests)

    private var doneBytes: Int64 {
        activeIngests.values.reduce(0) { $0 + $1.doneBytes }
    }
    private var totalBytesNew: Int64 {
        activeIngests.values.reduce(0) { $0 + $1.totalBytesNew }
    }
    private var totalFiles: Int {
        activeIngests.values.reduce(0) { $0 + $1.totalFiles }
    }
    private var completedFiles: Int {
        activeIngests.values.reduce(0) { $0 + $1.completedFiles }
    }
    private var mediaTotal: Int {
        activeIngests.values.reduce(0) { $0 + $1.mediaTotal }
    }
    private var cardBytesTotal: Int64 {
        activeIngests.values.reduce(0) { $0 + $1.cardBytesTotal }
    }
    private var currentFileName: String {
        activeIngests.values.first(where: { !$0.currentFileName.isEmpty })?.currentFileName ?? ""
    }
    private var verifyProgressText: String? {
        guard let ingest = activeIngests.values.first(where: { $0.isVerifying }) else { return nil }
        return "Verifying \(ingest.verifyChecked)/\(ingest.verifyTotal) files…"
    }
    private var currentCardName: String {
        switch activeIngests.count {
        case 0: return ""
        case 1: return activeIngests.values.first?.cardName ?? ""
        default: return "\(activeIngests.count) cards"
        }
    }
    private var currentCameraModel: String {
        activeIngests.values.first?.cameraModel ?? "Camera"
    }
    private var ingestStartTime: Date? {
        // Use the earliest start time so ETA / MB/s cover the full multi-card session.
        activeIngests.values.map { $0.ingestStartTime }.min()
    }

    // Sum of live MB/s across all active ingests (usually just one card at a time)
    private var currentLiveMBps: Double {
        activeIngests.values.reduce(0.0) { $0 + $1.liveMBps }
    }

    // MARK: - Session summary
    // "Today" = a configurable broadcast-day window (default 4am → 4am).
    // Late-night sports shoots that run past midnight stay in the same session
    // rather than being silently split across two calendar days.
    @AppStorage("pref_dayStartHour") private var dayStartHour: Int = 4
    @AppStorage("pref_broadcastDayFolders") private var broadcastDayFolders: Bool = false

    /// Start of the current broadcast-day window, e.g. "today 4:00am"
    /// (or "yesterday 4:00am" if the clock hasn't reached today's cutoff yet).
    private var currentDayWindowStart: Date {
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = dayStartHour
        comps.minute = 0; comps.second = 0
        guard let todayCutoff = cal.date(from: comps) else { return now }
        return now >= todayCutoff
            ? todayCutoff
            : cal.date(byAdding: .day, value: -1, to: todayCutoff) ?? todayCutoff
    }

    private var todayEntries: [IngestHistoryEntry] {
        let windowStart = currentDayWindowStart
        return historyEntries.filter { $0.timestamp >= windowStart && $0.newFiles > 0 }
    }
    /// All history entries within the current session window (including errors / 0-file runs).
    /// Uses the same broadcast-day cutoff as the stats ring so history resets at the same moment.
    private var sessionHistoryEntries: [IngestHistoryEntry] {
        historyEntries.filter { $0.timestamp >= currentDayWindowStart }
    }
    private var sessionCardCount: Int { todayEntries.count }
    // GB transferred: uses actual byte count when available, falls back to
    // avgMBps × durationSec / 1024 approximation for older history entries.
    private var sessionTotalGB: Double {
        todayEntries.reduce(0.0) {
            if $1.totalBytesTransferred > 0 {
                return $0 + Double($1.totalBytesTransferred) / 1_073_741_824.0
            }
            return $0 + Double($1.avgMBps) * Double($1.durationSec) / 1024.0
        }
    }
    private var sessionAvgMBps: Double {
        // Weighted average by duration so a single burst-speed card doesn't
        // skew the session number.  total_MB / total_seconds gives the same
        // result as (sum of bytes transferred) / (sum of seconds).
        let valid = todayEntries.filter { $0.avgMBps > 0 && $0.durationSec > 0 }
        guard !valid.isEmpty else { return 0 }
        let totalMB  = valid.reduce(0.0) { $0 + Double($1.avgMBps) * Double($1.durationSec) }
        let totalSec = valid.reduce(0)   { $0 + $1.durationSec }
        guard totalSec > 0 else { return 0 }
        return totalMB / Double(totalSec)
    }

    // MARK: - All-time computed helpers

    private var allTimeDataString: String {
        let gb = allTimeStats.totalMB / 1024.0
        let tb = gb / 1024.0
        if tb >= 1.0 { return String(format: "%.2f TB", tb) }
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", allTimeStats.totalMB)
    }

    private var allTimeDurationString: String {
        let hrs  = allTimeStats.totalDurationSec / 3600
        let mins = (allTimeStats.totalDurationSec % 3600) / 60
        if hrs > 0 { return "\(hrs)h \(mins)m" }
        return "\(mins)m"
    }

    private var allTimeSinceString: String {
        guard let date = allTimeStats.firstIngestDate else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy"
        return "since \(fmt.string(from: date))"
    }

    private var allTimeFootnote: String {
        var parts: [String] = []
        if allTimeStats.totalFiles > 0 {
            parts.append("\(allTimeStats.totalFiles.formatted()) files")
        }
        if allTimeStats.totalDurationSec > 60 {
            parts.append(allTimeDurationString + " transferring")
        }
        if !allTimeSinceString.isEmpty { parts.append(allTimeSinceString) }
        return parts.joined(separator: " · ")
    }

    private var totalProgress: Double {
        // Always byte-based — never falls back to file count.
        // PROGRESS_META bytes_new= arrives within the first second of a transfer,
        // so the ring shows 0% briefly then tracks actual bytes written.
        guard totalBytesNew > 0 else { return 0 }
        let raw = min(1.0, Double(doneBytes) / Double(totalBytesNew))
        // Hold at 99% while the process is still running so the ring never
        // flashes 100% before the termination handler confirms completion.
        return runningCount > 0 ? min(raw, 0.99) : raw
    }

    private var isDone: Bool {
        if totalBytesNew > 0 { return doneBytes >= totalBytesNew }
        return runningCount == 0
    }

    /// True during the post-copy "finalizing" window: every byte has been handed to
    /// the OS but the process is still running the F_FULLFSYNC durability flush (the
    /// drive committing its write-back cache to physical storage), plus any eject/
    /// summary work. No progress lines flow during this window, so without surfacing it
    /// the bar would sit frozen at 99% and look hung. We detect it two ways: the shell's
    /// explicit finalizing/verifying phase, OR the silent flush window where all bytes
    /// are in but the shell's PHASE marker hasn't arrived yet (phase still .copying).
    private var isFinalizing: Bool {
        guard runningCount > 0, totalBytesNew > 0 else { return false }
        let phaseSaysFinal = activeIngests.values.contains {
            $0.phase == .finalizing || $0.phase == .verifying
        }
        return phaseSaysFinal || Double(doneBytes) / Double(totalBytesNew) >= 0.999
    }


    // Free-space thresholds (bytes)
    private let kSpaceWarnBytes:  Int64 = 50 * 1_073_741_824   // 50 GB  → orange warning
    private let kSpaceCritBytes:  Int64 = 20 * 1_073_741_824   // 20 GB  → red, ingest blocked

    /// `nil` = fine, `"warn"` = orange (50 GB left), `"crit"` = red (20 GB left)
    private var ssdSpaceLevel: String? {
        guard primaryTotalBytes > 0 else { return nil }
        if primaryFreeBytes < kSpaceCritBytes { return "crit" }
        if primaryFreeBytes < kSpaceWarnBytes { return "warn" }
        return nil
    }

    private var canIngest: Bool {
        if useCustomDest {
            // Use cached result — avoids synchronous FileManager I/O on every render.
            return customDestIsValid
        }
        return selectedPrimary != nil
            && !projectName.trimmingCharacters(in: .whitespaces).isEmpty
            && ssdSpaceLevel != "crit"
    }

    /// Human-readable destination preview shown inside the ring during copy.
    /// Example: "MYSSD › ProjectX › 260413 › A001"
    private var predictedDestPreview: String {
        let df = DateFormatter()
        df.dateFormat = strftimeToICU(dateFolderFormat)
        let dateStr = df.string(from: Date())

        if useCustomDest {
            guard !customDestPath.isEmpty else { return "" }
            // Show last 2 path components of the custom folder as the base
            let url = URL(fileURLWithPath: customDestPath)
            let base = url.pathComponents.suffix(2).joined(separator: "/")
            var parts = [base]
            if selectedSubfolder != "Default" && !selectedSubfolder.isEmpty {
                parts.append(selectedSubfolder)
            }
            parts.append(dateStr)
            let label = useCustomCardName
                ? customCardName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !label.isEmpty { parts.append(label) }
            return parts.joined(separator: " \u{203A} ")
        }

        guard let primary = selectedPrimary else { return "" }
        let proj = projectName.trimmingCharacters(in: .whitespaces)
        guard !proj.isEmpty else { return "" }

        var parts = [primary.name, proj]
        if selectedSubfolder != "Default" && !selectedSubfolder.isEmpty {
            parts.append(selectedSubfolder)
        }
        parts.append(dateStr)
        let label = useCustomCardName
            ? customCardName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if !label.isEmpty { parts.append(label) }
        return parts.joined(separator: " \u{203A} ")
    }

    private var statusColor: Color {
        // Hard error state — always red
        if statusText.lowercased().contains("error") { return .red }

        // Phase-driven colors when an ingest is active
        if let phase = activeIngests.values.first?.phase {
            switch phase {
            case .scanning, .building:  return Color(hex: "#F59E0B")  // amber — preparing
            case .copying:              return .green                   // green — transferring
            case .verifying:            return Color(hex: "#60A5FA")   // blue — verifying
            case .finalizing:           return Color(hex: "#A78BFA")   // purple — wrapping up
            case .done:                 return .green                   // green — safe
            case .failed:               return .red                     // red — copy/verify failed
            case .idle:                 break
            }
        }

        // Auto ingest ON but no active ingest — pulsing green dot
        if autoIngest || runningCount > 0 { return .green }

        // Auto ingest OFF
        return .red.opacity(0.8)
    }

    // MARK: - Body

    /// Finish the first-launch onboarding (shared by the legacy + v3 presentations). The one
    /// footage-safety-relevant line: seed the v3 Destination LIST from the drive/folder+project the
    /// user just chose (onboarding wrote the SAME legacy @AppStorage keys migrateLegacyDestinations
    /// reads). Without it the v3 list stays empty until relaunch and a card plugged in right after
    /// onboarding would have NO configured destination. Guarded on `destinations.isEmpty` so a
    /// returning user hitting "Preview onboarding" can never clobber their existing destinations.
    private func completeOnboarding() {
        withAnimation(.easeInOut(duration: 0.55)) { showOnboarding = false }
        onboardingCompleted = true
        onboardingDemoStatus = ""
        if destinations.isEmpty { migrateLegacyDestinations() }
        refreshDestinations()
    }

    var body: some View {
        // v3 is the ONLY face now — the legacy visual layout has been removed
        // (recoverable at git tag `legacy-ui-archive-8db09b7`). `appWiringHost`
        // carries ALL load-bearing wiring (card detection via didMount →
        // scanForNewCardsAndIngest, timers, menu handlers, engine sheets/alerts,
        // license routing); bodyV3 is pure presentation over the same @State.
        ZStack {
            appWiringHost   // detection/timers/sheets/menu bus — the wiring
            bodyV3
            licenseAndWelcomeOverlays
            // First-launch onboarding — the top-most surface, above all v3 chrome/modals/settings.
            if showOnboarding {
                OnboardingView(
                    runDemo:    { runDemoIngest(fromOnboarding: true) },
                    demoStatus: $onboardingDemoStatus,
                    onComplete: { completeOnboarding() }
                )
                .transition(.opacity)
                .zIndex(1000)
            }
        }
        // Clicking anywhere outside a text field resigns focus so keyboard
        // shortcuts (especially Space) work immediately without an extra click.
        .simultaneousGesture(
            TapGesture().onEnded { NSApp.keyWindow?.makeFirstResponder(nil) }
        )
    }

    // MARK: - Completion Animations

    // ── 1. Confetti Burst ────────────────────────────────────────────────────

    private static let confettiColors: [Color] = [
        Color(hex: "#FF3B30"), Color(hex: "#FF9500"), Color(hex: "#FFCC02"),
        Color(hex: "#34C759"), Color(hex: "#00C7BE"), Color(hex: "#007AFF"),
        Color(hex: "#AF52DE"), Color(hex: "#FF2D55"),
    ]

    // ── 3. Inline ring particle animations ───────────────────────────────────
    // Pixel Fireworks, Fizzy Soda, and Retro Sparkle render inside the ring ZStack.
    // Victory triggers all three simultaneously.

    // Colour palettes ─────────────────────────────────────────────────────────
    private static let fwColors: [Color] = [
        Color(hex: "#FF2D78"),  // hot pink
        Color(hex: "#00F5FF"),  // electric cyan
        Color(hex: "#FFE600"),  // bright yellow
        Color(hex: "#FF6B00"),  // orange
        Color(hex: "#00FF9E"),  // neon green
        Color(hex: "#C44BFF"),  // violet
    ]
    private static let sparkColor: [Color] = [
        Color(hex: "#FF2D78"), Color(hex: "#00F5FF"), Color(hex: "#FFE600"),
        Color(hex: "#FF6B00"), Color(hex: "#00FF9E"), Color(hex: "#C44BFF"),
    ]
    private static let bubbleColors: [Color] = [
        Color(hex: "#9B5FE3").opacity(0.82),  // deep purple
        Color(hex: "#C9A7F5").opacity(0.78),  // soft lavender
        Color(hex: "#5B8DEF").opacity(0.80),  // muted blue
        Color(hex: "#CF50FA").opacity(0.75),  // bright magenta
        Color(hex: "#8BE0FF").opacity(0.78),  // sky blue
    ]
    private static let sparkleColors: [Color] = [
        .white,
        Color(hex: "#BF5FFF"),  // bright purple
        Color(hex: "#FF8FD4"),  // soft pink
        Color(hex: "#FFE600"),  // yellow
        Color(hex: "#00F5FF"),  // cyan
        Color(hex: "#FF2D78"),  // hot pink
    ]

    // Particle factories ──────────────────────────────────────────────────────

    // Inline particle layer (rendered inside ring ZStack) ─────────────────────

    // Trigger functions ───────────────────────────────────────────────────────

    // ── Shared dispatcher ────────────────────────────────────────────────────

    /// Starts a repeating fallback loop that rescans /Volumes every 30 seconds.
    /// Primary card detection is event-driven (didMountNotification + an immediate
    /// one-shot scan at launch / toggle-on) — this loop only catches edge cases
    /// like cards mounted before the app launched or missed notifications.
    /// Always sleeps first so callers control the immediate check themselves.
    private func startAutoScanLoop() {
        scanTask?.cancel()
        scanTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 s fallback interval
                guard !Task.isCancelled else { return }
                await self.scanForNewCardsAndIngestBackground()
                await MainActor.run { self.refreshFreeSpaceCache() }  // keep free-space labels current
            }
        }
    }

    /// Thin wrapper called by the 30-second fallback loop.
    /// All detection logic lives in scanForNewCardsAndIngest() — routing
    /// through that single path ensures UUID lookup, nickname recognition,
    /// autoIngest gating, and statusText updates are never missed.
    nonisolated private func scanForNewCardsAndIngestBackground() async {
        await MainActor.run { self.scanForNewCardsAndIngest() }
    }

    /// Runs a blocking FS probe with a hard timeout. Returns false if the volume
    /// doesn't respond within `seconds` — prevents a sluggish drive from hanging.
    nonisolated private func withVolumeTimeout(seconds: Double, probe: @escaping () -> Bool) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { probe() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// Detects whether a mounted volume is a camera card.
    ///
    /// Strategy: structure-only detection — zero file-content enumeration.
    /// Every camera uses a fixed, known folder layout. We check for those
    /// signatures using fileExists (a single kernel stat call per path, ~0.1ms).
    /// Never reads file contents, never recurses into subdirectories.
    /// Safe to call from any thread (nonisolated).
    nonisolated private func volumeLooksLikeCardStatic(
        _ url: URL,
        primaryPath: String?,
        secondaryPath: String,
        importMode: String
    ) -> Bool {
        let fm  = FileManager.default
        let root = url.path

        // ── Hard exclusions ───────────────────────────────────────────────────

        // Never confuse a destination SSD with a source card
        if let pp = primaryPath, root == pp            { return false }
        if !secondaryPath.isEmpty, root == secondaryPath { return false }

        // APFS and >2 TB are strong "storage drive, not a card" signals — but they are
        // NO LONGER hard rejects here. Modern kit ships APFS-formatted SSD recorders and
        // 4 TB+ CFexpress cards; rejecting on filesystem/size alone made CardRunner blind
        // to legitimate media. Instead we compute the flag now and use it ONLY to gate the
        // weak Tier-4 "any media file" catch-all further down. A definitive camera
        // signature (Tier 1/2/3) still returns true regardless of filesystem or size.
        let isAPFS = ((try? url.resourceValues(forKeys: [.volumeTypeNameKey]))?
            .volumeTypeName?.lowercased().contains("apfs")) ?? false
        let isOver2TB: Bool = {
            guard let attrs = try? fm.attributesOfFileSystem(forPath: root),
                  let sizeNum = attrs[.systemSize] as? NSNumber else { return false }
            return sizeNum.int64Value > 2_000_000_000_000
        }()
        let looksLikeStorage = isAPFS || isOver2TB

        // ── Convenience ───────────────────────────────────────────────────────
        func dir(_ rel: String) -> Bool {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.appendingPathComponent(rel).path, isDirectory: &isDir)
            return isDir.boolValue
        }

        // ── Tier 1: Professional cinema — structure is always at root ─────────
        // Zero ambiguity: no storage drive would ever have these folders.

        if dir("PRIVATE/M4ROOT")      { return true }   // Sony FX3/FX6/FX9/Venice/Alpha (PRIVATE layout)
        if dir("M4ROOT")              { return true }   // Sony FX6/FX9/Venice/Type-A (M4ROOT at card root)
        if dir("AVF_INFO")            { return true }   // Sony Pro (Venice/FX9/FX6) companion folder
        if dir("BPAV")                { return true }   // Sony XDCAM PMW / PDW
        if dir("XDROOT")              { return true }   // Sony XDCAM EX
        if dir("PRIVATE/AVCHD/BDMV") { return true }   // Sony / Panasonic AVCHD
        if dir("AVCHD/BDMV")         { return true }   // AVCHD variant
        if dir("Blackmagic RAW")      { return true }   // Blackmagic BRAW
        if dir("ARRI")                { return true }   // ARRI ALEXA / AMIRA / Mini
        if dir("MXF")                 { return true }   // Canon Cinema C70/C300/C500/C200 (root MXF folder)
        if dir("PRIVATE/CLIPS")       { return true }   // Canon Cinema (some recording modes / firmware)
        if dir("HDRMOVIE")            { return true }   // Sony HXR-NX / some Alpha-series video layouts
        // Canon R5C (XF-AVC) and Panasonic VariCam / AU-EVA1 / P2:
        // Canon R5C creates CONTENTS/CLIPS001, CLIPS002 … (numbered — exact "CLIPS" match misses these).
        // We check for CONTENTS at root, then look inside for any CLIP* or VIDEO subfolder.
        if dir("CONTENTS"),
           let contentItems = try? fm.contentsOfDirectory(
               atPath: url.appendingPathComponent("CONTENTS").path),
           contentItems.contains(where: {
               let l = $0.lowercased()
               return l.hasPrefix("clip") || l == "video"
           }) { return true }

        // ── Tier 2: DCIM at root ──────────────────────────────────────────────
        // Covers: Canon/Nikon/Fuji/Sony-Alpha/Olympus/Pentax/Lumix mirrorless,
        //         GoPro, DJI (most models), iPhone, generic stills cameras.
        if dir("DCIM") { return true }

        // ── Tier 3: Root directory scan — O(n) but directory names only ───────
        // Handles two patterns without touching file contents:
        //   a) DCIM nested one level deep (some DJI & older cameras)
        //   b) Signature file extensions at root (.RDM = RED, .braw = Blackmagic)
        //
        // We read the root directory listing once (names only, no stat per file)
        // and cap at 60 entries — a camera card's root never has more than ~10.
        if let rootItems = try? fm.contentsOfDirectory(atPath: root) {
            for item in rootItems.prefix(60) {
                let lower = item.lowercased()

                // Skip system / hidden entries
                if lower.hasPrefix(".")                          { continue }
                if lower == "system volume information"          { continue }
                if lower == "found.000" || lower == "recycler"  { continue }

                // RED: .RDM container folders at root  e.g. A001_C002.RDM
                if lower.hasSuffix(".rdm")  { return true }

                // Loose cinema files at root — some cameras/recorders write flat
                if lower.hasSuffix(".braw") { return true }   // Blackmagic RAW
                if lower.hasSuffix(".mxf")  { return true }   // Canon, Panasonic, Sony pro
                if lower.hasSuffix(".r3d")  { return true }   // RED RAW
                if lower.hasSuffix(".ari")  { return true }   // ARRI RAW
                if lower.hasSuffix(".arx")  { return true }   // ARRI extended
                if lower.hasSuffix(".crm")  { return true }   // Canon Cinema RAW Light
                if lower.hasSuffix(".insv") { return true }   // Insta360
                if lower.hasSuffix(".cine") { return true }   // Phantom high-speed cameras

                // DCIM nested one level deep — DJI_FLY/DCIM, CARD/DCIM, etc.
                // Only check subdirectories, not files.
                if dir("\(item)/DCIM")      { return true }
            }
        }

        // No definitive camera signature matched. Now apply the storage guard: a
        // volume that looks like storage (APFS or >2 TB) and carries no camera
        // structure must NOT be treated as a card just because a stray clip lives on
        // it — otherwise a working drive (e.g. the editor's scratch SSD) would trigger
        // auto-ingest. A genuine APFS recorder / 4 TB CFexpress card already returned
        // true above via its Tier 1/2/3 signature, so this never rejects real media.
        if looksLikeStorage { return false }

        // ── Tier 4: bounded deep scan — catches ANY folder structure ──────────
        // The last-resort catch-all. If no known signature matched, walk the
        // volume (depth- and count-capped) for ANY media file — video OR photo.
        // This guarantees a card with footage in an unusual/nested layout (odd
        // Blackmagic, Canon, Nikon, or unknown-camera structures, or plain
        // .mp4/.mov buried in a non-DCIM folder) is still recognized and ingested.
        // Cheap here: storage-like (APFS / >2 TB) volumes were rejected just above,
        // so only small removable media reaches this point, and we return on the
        // FIRST media file found. The result is cached per volume by the caller.
        if volumeContainsMediaFile(root, maxDepth: 4, maxDirs: 400) {
            return true
        }

        // ── Genuinely no media anywhere — not a card ──────────────────────────
        return false
    }

    /// Bounded breadth-first walk that returns true as soon as ONE media file
    /// (video or photo, by extension) is found. Depth- and directory-count-capped
    /// so it stays cheap even on an oddly-structured volume. Names-only listing +
    /// one stat per entry; no file contents are read. Safe to call nonisolated.
    nonisolated private func volumeContainsMediaFile(_ root: String,
                                                     maxDepth: Int,
                                                     maxDirs: Int) -> Bool {
        // Same extension set the shell scanner accepts — keep these in sync.
        let mediaExts: Set<String> = [
            // video
            "mp4","mov","mxf","crm","r3d","braw","ari","arx","mts","m2ts",
            "avi","mkv","dng","cdng","raw","mpg","mpeg","ts","m2v",
            "insv","360","lrv","cine","mp",
            // photo
            "jpg","jpeg","png","tif","tiff","heic","heif","cr2","cr3","nef",
            "arw","raf","rw2","orf","sr2","3fr","fff","iiq","mos","rwl",
            "mrw","nrw","pef","srw","dcr","kdc"
        ]
        let fm = FileManager.default
        var queue: [(path: String, depth: Int)] = [(root, 0)]
        var dirsVisited = 0

        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            dirsVisited += 1
            if dirsVisited > maxDirs { return false }   // bound worst-case cost

            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items {
                if item.hasPrefix(".") { continue }     // skip hidden / sidecar / system
                let full = dir + "/" + item
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if depth < maxDepth { queue.append((full, depth + 1)) }
                } else if mediaExts.contains((item as NSString).pathExtension.lowercased()) {
                    return true                         // found media — it's a card
                }
            }
        }
        return false
    }

    /// Stops the repeating card-scan loop.
    private func stopAutoScanLoop() {
        scanTask?.cancel()
        scanTask = nil
    }

    /// Terminates all active ingest processes and removes any partial files cardcopy
    /// left in .cardrunner_partial staging dirs, guaranteeing no incomplete file
    /// ever sits at a real destination path.
    private func cancelAllIngests() {
        // Cancel demo task if running
        if let demo = demoTask {
            demo.cancel()
            demoTask = nil
            activeIngests.removeAll()
            runningCount = 0
            statusText = "Transfer cancelled"
            return
        }

        for (id, process) in activeProcesses {
            cancelledProcessIDs.insert(id)   // mark before terminate so the handler sees it
            if process.isRunning { process.terminate() }
        }
        // Partial-dir cleanup is deferred to the terminationHandler's wasCancelled branch
        // so it fires only after the copy process has actually exited, preventing a
        // delete-under-write race with cardcopy still writing into .cardrunner_partial/.

        statusText = "Transfer cancelled"
    }

    /// Recursively finds and deletes all .cardrunner_partial directories under `root`.
    private func cleanupPartialDirs(in root: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        task.arguments = [root, "-type", "d", "-name", ".cardrunner_partial",
                          "-exec", "rm", "-rf", "{}", "+"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        try? task.run()
        // Fire-and-forget — cleanup finishes in the background while the UI resets.
    }

    // MARK: - Resume Sheet

    private var resumeSheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(hex: "#F59E0B"))
                Text("Interrupted Transfer")
                    .font(.system(size:16).weight(.bold))
                    .foregroundStyle(textPrimary)
                Spacer()
                Button {
                    // Discard all pending checkpoints — same as tapping Discard
                    // on each row individually. Just hiding the sheet (the old
                    // behaviour) caused it to re-appear on every app launch until
                    // the user explicitly clicked Discard.
                    for cp in pendingCheckpoints { discardCheckpoint(cp) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider().opacity(0.3)

            // One card per interrupted ingest
            SmoothScrollView {
                VStack(spacing: 12) {
                    ForEach(pendingCheckpoints) { cp in
                        ResumeCheckpointRow(
                            checkpoint: cp,
                            cardMounted: FileManager.default.fileExists(atPath: cp.cardPath),
                            ssdMounted: availableDestinations.contains(where: { $0.path == cp.primaryPath }),
                            textPrimary: textPrimary,
                            textSecondary: textSecondary,
                            textMuted: textMuted,
                            onResume: { resumeFromCheckpoint(cp) },
                            onDiscard: { discardCheckpoint(cp) }
                        )
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 480)
        .background(bgColor.ignoresSafeArea())
    }

    // MARK: - Date Picker Sheet

    /// Multi-select sheet shown when "Today only" is OFF and the card contains
    /// files from two or more distinct capture dates.
    private var datePickerSheet: some View {
        let allSelected = datePickerDates.allSatisfy { datePickerSelected.contains($0.yyyymmdd) }

        return VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────────
            HStack(alignment: .center) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accentBlue)
                Text("Choose dates to ingest")
                    .font(.system(size:16).weight(.bold))
                    .foregroundStyle(textPrimary)
                Spacer()
                Button {
                    showDatePickerSheet = false
                    datePickerScanning = false
                    datePickerCards = []; datePickerDates = []; datePickerSelected = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider().opacity(0.3)

            if datePickerScanning {
                // ── Scanning in progress — card was pre-mounted, retrying ─────
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(accentBlue)
                    Text("Scanning card for dates…")
                        .font(.system(size:13).weight(.semibold))
                        .foregroundStyle(textPrimary)
                    Text("The card was already mounted. This usually takes a few seconds.")
                        .font(.system(size:11))
                        .foregroundStyle(textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .padding(.horizontal, 24)
            } else if datePickerDates.isEmpty {
                // ── Scan fallback — truly couldn't read dates from card ────────
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(Color(hex: "#F59E0B"))
                    Text("Couldn't read dates from this card.")
                        .font(.system(size:13).weight(.semibold))
                        .foregroundStyle(textPrimary)
                    Text("The card may still be initialising. Try scanning again, or tap \u{201C}Ingest all\u{201D} to copy everything.")
                        .font(.system(size:11))
                        .foregroundStyle(textMuted)
                        .multilineTextAlignment(.center)
                    Button {
                        retryDateScan()
                    } label: {
                        Label("Scan again", systemImage: "arrow.clockwise")
                            .font(.system(size:12).weight(.semibold))
                            .foregroundStyle(accentBlue)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .padding(.horizontal, 24)
            } else {
                // ── Select all / deselect all ─────────────────────────────────
                HStack {
                    Text(allSelected ? "Deselect all" : "Select all")
                        .font(.system(size:11).weight(.medium))
                        .foregroundStyle(accentBlue)
                        .onTapGesture {
                            if allSelected {
                                datePickerSelected = []
                            } else {
                                datePickerSelected = Set(datePickerDates.map { $0.yyyymmdd })
                            }
                        }
                    Spacer()
                    Text("\(datePickerDates.count) date\(datePickerDates.count == 1 ? "" : "s") found")
                        .font(.system(size:11))
                        .foregroundStyle(textMuted)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)

                Divider().opacity(0.15)

                // ── Date rows ─────────────────────────────────────────────────
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(datePickerDates) { info in
                            let isChecked = datePickerSelected.contains(info.yyyymmdd)
                            Button {
                                if isChecked {
                                    datePickerSelected.remove(info.yyyymmdd)
                                } else {
                                    datePickerSelected.insert(info.yyyymmdd)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    // Checkbox
                                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(isChecked ? accentBlue : textMuted)

                                    // Date label
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(info.displayDate)
                                                .font(.system(size:13).weight(.semibold))
                                                .foregroundStyle(textPrimary)
                                            if info.isToday {
                                                Text("today")
                                                    .font(.system(size:10).weight(.medium))
                                                    .foregroundStyle(accentBlue)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Capsule().fill(accentBlue.opacity(0.15)))
                                            }
                                        }
                                        Text("\(info.fileCount) file\(info.fileCount == 1 ? "" : "s") · \(info.displaySize)")
                                            .font(.system(size:11))
                                            .foregroundStyle(textMuted)
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider().opacity(0.10).padding(.horizontal, 24)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            Divider().opacity(0.3)

            // ── Action buttons ────────────────────────────────────────────────
            HStack(spacing: 12) {
                Button("Cancel") {
                    showDatePickerSheet = false
                    datePickerScanning = false
                    datePickerCards = []; datePickerDates = []; datePickerSelected = []
                }
                .buttonStyle(.plain)
                .font(.system(size:13).weight(.medium))
                .foregroundStyle(textMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))

                Spacer()

                Button {
                    let cards    = datePickerCards
                    // Sort newest-first so the shell sees them in a predictable order
                    let selected = datePickerSelected.sorted().reversed()
                    let isEmpty  = datePickerDates.isEmpty
                    showDatePickerSheet = false
                    datePickerScanning = false
                    datePickerCards = []; datePickerDates = []; datePickerSelected = []

                    for card in cards {
                        if isEmpty {
                            // Scan failed — ingest everything with no date filter
                            startIngest(for: card)
                        } else if selected.count == 1 {
                            // Single date — use --date-from (existing behaviour)
                            startIngest(for: card, dateOverride: selected.first)
                        } else {
                            // Multiple dates — pass as one comma-joined --dates arg
                            // so the shell produces a single combined file list and
                            // one continuous copy pass instead of N separate transfers.
                            startIngest(for: card, dateOverride: selected.joined(separator: ","))
                        }
                    }
                } label: {
                    let label = datePickerDates.isEmpty
                        ? "Ingest all"
                        : "Ingest \(datePickerSelected.count) date\(datePickerSelected.count == 1 ? "" : "s")"
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(label)
                    }
                    .font(.system(size:13).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill((!datePickerDates.isEmpty && datePickerSelected.isEmpty)
                                  ? Color.white.opacity(0.15) : accentBlue)
                    )
                }
                .buttonStyle(.plain)
                .disabled(datePickerScanning || (!datePickerDates.isEmpty && datePickerSelected.isEmpty))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 440)
        .background(bgColor.ignoresSafeArea())
    }

    // MARK: - Reel Picker Sheet

    /// Shown when Tier-1 wrong-clock detection fires: the camera's RTC was bad,
    /// dates are implausible, and multiple reels can't be separated by date alone.
    private var reelPickerSheet: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────────
            HStack(alignment: .center) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(hex: "#F59E0B"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wrong camera clock detected")
                        .font(.system(size:15).weight(.bold))
                        .foregroundStyle(textPrimary)
                    Text("Select which reels to ingest — files will land in today's folder")
                        .font(.system(size:11))
                        .foregroundStyle(textMuted)
                }
                Spacer()
                Button {
                    showReelPickerSheet = false
                    reelPickerCard = nil; reelPickerReels = []; reelPickerSelected = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider().opacity(0.3)

            // ── Select all / deselect all ─────────────────────────────────────
            HStack {
                let allReelsSel = reelPickerReels.allSatisfy { reelPickerSelected.contains($0.folderName) }
                Text(allReelsSel ? "Deselect all" : "Select all")
                    .font(.system(size:11).weight(.medium))
                    .foregroundStyle(accentBlue)
                    .onTapGesture {
                        if allReelsSel {
                            reelPickerSelected = []
                        } else {
                            reelPickerSelected = Set(reelPickerReels.map { $0.folderName })
                        }
                    }
                Spacer()
                Text("\(reelPickerReels.count) reel\(reelPickerReels.count == 1 ? "" : "s") found")
                    .font(.system(size:11))
                    .foregroundStyle(textMuted)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)

            Divider().opacity(0.15)

            // ── Reel rows ─────────────────────────────────────────────────────
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(reelPickerReels) { reel in
                        let isChecked = reelPickerSelected.contains(reel.folderName)
                        Button {
                            if isChecked {
                                reelPickerSelected.remove(reel.folderName)
                            } else {
                                reelPickerSelected.insert(reel.folderName)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(isChecked ? accentBlue : textMuted)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reel.folderName)
                                        .font(.system(size:13).weight(.semibold))
                                        .foregroundStyle(textPrimary)
                                    Text("\(reel.fileCount) file\(reel.fileCount == 1 ? "" : "s") · \(reel.displaySize)")
                                        .font(.system(size:11))
                                        .foregroundStyle(textMuted)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider().opacity(0.10).padding(.horizontal, 24)
                    }
                }
            }
            .frame(maxHeight: 300)

            Divider().opacity(0.3)

            // ── Action buttons ────────────────────────────────────────────────
            HStack(spacing: 12) {
                Button("Cancel") {
                    showReelPickerSheet = false
                    reelPickerCard = nil; reelPickerReels = []; reelPickerSelected = []
                }
                .buttonStyle(.plain)
                .font(.system(size:13).weight(.medium))
                .foregroundStyle(textMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))

                Spacer()

                Button {
                    guard let card = reelPickerCard else { return }
                    let selected = Array(reelPickerSelected)
                    let dateOverride = reelPickerDateOverride
                    let multi = selected.count > 1
                    showReelPickerSheet = false
                    reelPickerCard = nil; reelPickerReels = []; reelPickerSelected = []
                    startIngest(for: card, wrongClockDate: dateOverride,
                                reelFilter: selected, reelMulti: multi)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Ingest \(reelPickerSelected.count) reel\(reelPickerSelected.count == 1 ? "" : "s")")
                    }
                    .font(.system(size:13).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(reelPickerSelected.isEmpty ? Color.white.opacity(0.15) : accentBlue)
                    )
                }
                .buttonStyle(.plain)
                .disabled(reelPickerSelected.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 440)
        .background(bgColor.ignoresSafeArea())
    }

    // MARK: - Preset Editor Sheet

    private var presetEditorSheet: some View {
        let draft       = $presetEditorDraft
        let trimmedName = presetEditorDraft.name.trimmingCharacters(in: .whitespaces)
        let isDuplicate = presets.contains {
            $0.name.lowercased() == trimmedName.lowercased() &&
            (!presetEditorIsNew ? $0.id != presetEditorDraft.id : true)
        }
        let canSave     = !trimmedName.isEmpty && !isDuplicate && presets.count < 6

        let dateFormats: [(label: String, format: String)] = {
            let df = DateFormatter()
            func sample(_ fmt: String, _ display: String) -> (label: String, format: String) {
                df.dateFormat = strftimeToICU(fmt)
                return (df.string(from: Date()) + "  (\(display))", fmt)
            }
            return [
                sample("%y%m%d",   "YYMMDD"),
                sample("%Y%m%d",   "YYYYMMDD"),
                sample("%Y-%m-%d", "YYYY-MM-DD"),
                sample("%y.%m.%d", "YY.MM.DD"),
                sample("%A",       "Day of week"),
            ]
        }()

        return VStack(spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            HStack {
                Text(presetEditorIsNew ? "New Preset" : "Edit Preset")
                    .font(.title2.bold())
                Spacer()
                Button("Cancel") { showPresetEditor = false }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // ── Form ──────────────────────────────────────────────────────
            SmoothScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Color.clear.frame(height: 4) // top breathing room

                    // Name
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Preset Name")
                            .font(.system(size:12).weight(.semibold))
                            .foregroundStyle(textPrimary.opacity(0.7))
                        TextField("e.g. Run & Gun, Studio, B-cam", text: draft.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size:13))
                        if isDuplicate {
                            Label("A preset with this name already exists.", systemImage: "exclamationmark.circle")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }

                    Divider().opacity(0.4)

                    // Import mode
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Import Mode")
                            .font(.system(size:12).weight(.semibold))
                            .foregroundStyle(textPrimary.opacity(0.7))
                        HStack(spacing: 8) {
                            ForEach([("Video", "video"), ("Photo", "photo")], id: \.1) { label, val in
                                let sel = presetEditorDraft.importMode == val
                                Button { draft.importMode.wrappedValue = val } label: {
                                    Text(label)
                                        .font(.system(size:12).weight(.medium))
                                        .padding(.horizontal, 14).padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 8)
                                            .fill(sel ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.06))
                                            .overlay(RoundedRectangle(cornerRadius: 8)
                                                .stroke(sel ? Color.accentColor.opacity(0.7) : borderStroke.opacity(0.5), lineWidth: 1)))
                                        .foregroundStyle(sel ? Color.accentColor : textPrimary)
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                    }

                    Divider().opacity(0.4)

                    // Ingest order
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ingest Order")
                            .font(.system(size:12).weight(.semibold))
                            .foregroundStyle(textPrimary.opacity(0.7))
                        Text("Newest first lets editors start on the latest footage immediately.")
                            .font(.caption).foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            ForEach([("Oldest first", "oldest"), ("Newest first", "newest")], id: \.1) { label, val in
                                let sel = presetEditorDraft.ingestOrder == val
                                Button { draft.ingestOrder.wrappedValue = val } label: {
                                    Text(label)
                                        .font(.system(size:12).weight(.medium))
                                        .padding(.horizontal, 14).padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 8)
                                            .fill(sel ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.06))
                                            .overlay(RoundedRectangle(cornerRadius: 8)
                                                .stroke(sel ? Color.accentColor.opacity(0.7) : borderStroke.opacity(0.5), lineWidth: 1)))
                                        .foregroundStyle(sel ? Color.accentColor : textPrimary)
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                    }

                    Divider().opacity(0.4)

                    // Date format
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Date Folder Format")
                            .font(.system(size:12).weight(.semibold))
                            .foregroundStyle(textPrimary.opacity(0.7))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(dateFormats, id: \.format) { option in
                                let sel = presetEditorDraft.dateFolderFormat == option.format
                                let fill: Color = sel ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.06)
                                let stroke: Color = sel ? Color.accentColor.opacity(0.7) : borderStroke.opacity(0.5)
                                Button { draft.dateFolderFormat.wrappedValue = option.format } label: {
                                    Text(option.label)
                                        .font(.system(size:11).weight(.medium))
                                        .lineLimit(1).minimumScaleFactor(0.85)
                                        .frame(maxWidth: .infinity)
                                        .padding(.horizontal, 10).padding(.vertical, 7)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(fill)
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(stroke, lineWidth: 1)))
                                        .foregroundStyle(sel ? Color.accentColor : textPrimary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Divider().opacity(0.4)

                    // Destination override
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(accentPurple.opacity(0.85))
                            Text("Destination")
                                .font(.system(size:12).weight(.semibold))
                                .foregroundStyle(textPrimary.opacity(0.7))
                            InfoPopover("By default presets use your selected SSD + project folder. Enable Custom Folder to lock this preset to a specific path on your Mac (Desktop, NAS, any folder). The date-folder structure is still created inside that folder.")
                        }

                        // Mode toggle — full-area clickable tabs
                        HStack(spacing: 0) {
                            ForEach([("SSD + Project", false), ("Custom Folder", true)], id: \.0) { label, isCustom in
                                let selected = draft.useCustomDest.wrappedValue == isCustom
                                Button { draft.useCustomDest.wrappedValue = isCustom } label: {
                                    Text(label)
                                        .font(.system(size:11).weight(.medium))
                                        .lineLimit(1)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .frame(maxWidth: .infinity)
                                        .foregroundStyle(selected ? Color.white : textSecondary)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(selected ? accentViolet : Color.clear)
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(3)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(useLightMode ? Color.black.opacity(0.07) : Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(borderStroke, lineWidth: 1)))

                        if draft.useCustomDest.wrappedValue {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    if draft.customDestPath.wrappedValue.isEmpty {
                                        Text("No folder chosen")
                                            .font(.system(size:11))
                                            .foregroundStyle(textMuted)
                                    } else {
                                        Text(URL(fileURLWithPath: draft.customDestPath.wrappedValue).lastPathComponent)
                                            .font(.system(size:11).weight(.semibold))
                                            .foregroundStyle(textPrimary)
                                            .lineLimit(1)
                                        Text(draft.customDestPath.wrappedValue)
                                            .font(.system(size: 9))
                                            .foregroundStyle(textMuted)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                Spacer()
                                Button {
                                    let panel = NSOpenPanel()
                                    panel.title = "Choose destination folder"
                                    panel.message = "CardRunner will create date-folders inside this folder."
                                    panel.prompt = "Use as Destination"
                                    panel.canChooseFiles = false
                                    panel.canChooseDirectories = true
                                    panel.canCreateDirectories = true
                                    panel.allowsMultipleSelection = false
                                    if !draft.customDestPath.wrappedValue.isEmpty {
                                        panel.directoryURL = URL(fileURLWithPath: draft.customDestPath.wrappedValue)
                                    } else {
                                        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
                                    }
                                    panel.begin { response in
                                        if response == .OK, let url = panel.url {
                                            DispatchQueue.main.async {
                                                draft.customDestPath.wrappedValue = url.path
                                            }
                                        }
                                    }
                                } label: {
                                    Text(draft.customDestPath.wrappedValue.isEmpty ? "Choose…" : "Change…")
                                        .font(.system(size:11).weight(.medium))
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(Capsule()
                                            .fill(accentViolet.opacity(0.15))
                                            .overlay(Capsule().stroke(accentViolet.opacity(0.35), lineWidth: 1)))
                                        .foregroundStyle(accentViolet)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(useLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.04))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderStroke, lineWidth: 1)))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: draft.useCustomDest.wrappedValue)

                    Divider().opacity(0.4)

                    // Transfer options
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Transfer Options")
                            .font(.system(size:12).weight(.semibold))
                            .foregroundStyle(textPrimary.opacity(0.7))

                        // Today only toggle
                        let todayOnlyPresetBinding = Binding<Bool>(
                            get: { draft.dateFilterMode.wrappedValue == "today" },
                            set: { draft.dateFilterMode.wrappedValue = $0 ? "today" : "all" }
                        )
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Today only")
                                    .font(.system(size:11).weight(.medium))
                                    .foregroundStyle(textPrimary)
                                Text(draft.dateFilterMode.wrappedValue == "today"
                                     ? "Only today's files are ingested."
                                     : "All files ingested — confirm before start.")
                                    .font(.system(size:9))
                                    .foregroundStyle(textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            MiniPillToggle(isOn: todayOnlyPresetBinding, onColor: accentBlue)
                        }
                        // ── Custom card name ──────────────────────────────────
                        presetToggleRow("Custom card name / label", "tag", binding: draft.useCustomCardName,
                            info: "Creates a named subfolder inside the date folder — useful when ingesting from a specific rig (Steadicam, Drone, B-Cam). Leave the field empty to skip the subfolder.",
                            onColor: accentBlue)

                        if presetEditorDraft.useCustomCardName {
                            HStack(spacing: 8) {
                                Image(systemName: "tag")
                                    .font(.system(size: 11))
                                    .foregroundStyle(accentBlue.opacity(0.7))
                                TextField("e.g. Steadicam, Drone, B-Cam  (leave empty to omit)", text: draft.customCardName)
                                    .textFieldStyle(.plain)
                                    .font(.system(size:11))
                                    .foregroundStyle(textPrimary)
                                if !presetEditorDraft.customCardName.isEmpty {
                                    Button {
                                        draft.customCardName.wrappedValue = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(textMuted.opacity(0.5))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(useLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.06))
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(accentBlue.opacity(0.25), lineWidth: 1))
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        presetToggleRow("Auto eject after transfer", "eject.fill", binding: draft.autoEject,
                            info: "After a successful ingest the card is safely ejected so it's ready to reformat in-camera.",
                            onColor: accentBlue)
                        presetToggleRow("Verify transfer (checksum)", "checkmark.shield", binding: draft.verifyTransfer,
                            info: "Spot-checks up to 10 random files with MD5 after every ingest. Any mismatch is flagged immediately.",
                            onColor: accentBlue)
                        presetToggleRow("Copy XML sidecar files", "doc.plaintext", binding: draft.copyXML,
                            info: "Any .xml files found alongside your video clips on the card are copied to the same destination folder.",
                            onColor: accentBlue)
                        presetToggleRow("Include in-camera proxies", "film.stack", binding: draft.includeProxies,
                            info: "Copies low-res proxy files into a Proxies/ subfolder next to your main clips. Supports Sony S03 and cameras that store proxies in a Proxy or Sub folder.",
                            onColor: accentBlue)
                    }

                    Divider().opacity(0.4)

                    // Pro Tools
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pro Tools")
                            .font(.system(size:12).weight(.semibold))
                            .foregroundStyle(textPrimary.opacity(0.7))

                        presetToggleRow("Dual-destination backup", "externaldrive.fill", binding: draft.dualDestEnabled,
                            info: "Copies every file to both your primary SSD and a second drive in the same pass. Both copies come directly from the card — not a copy of a copy. Configure the secondary drive in Pro Tools settings.",
                            onColor: accentPurple)

                        presetToggleRow("Rename on ingest", "pencil", binding: draft.renameOnIngestEnabled,
                            info: "Files are renamed as they land using a template. Tokens: {cardname} = card label or volume name, {original} = original filename. Extension is always preserved.",
                            onColor: accentBlue)

                        if presetEditorDraft.renameOnIngestEnabled {
                            HStack(spacing: 8) {
                                TextField("{cardname}_{original}", text: draft.renameTemplate)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                Button("Reset") { draft.renameTemplate.wrappedValue = "{cardname}_{original}" }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                            let preview = renameTemplatePreview(presetEditorDraft.renameTemplate)
                            HStack(spacing: 6) {
                                Image(systemName: "eye").font(.caption2).foregroundStyle(.secondary)
                                Text(preview)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(preview.hasPrefix("⚠") ? .orange : accentBlue)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: presetEditorDraft.renameOnIngestEnabled)

                    Divider().opacity(0.4)

                    // Finder tag
                    VStack(alignment: .leading, spacing: 10) {
                        presetToggleRow("Finder marker tag on new batches", "tag.fill", binding: draft.finderTagEnabled,
                            info: "Tags the first clip of each subsequent transfer so you can instantly spot where a new batch starts in Finder.",
                            onColor: .orange)
                        if presetEditorDraft.finderTagEnabled {
                            let tagColors: [(color: Color, value: String)] = [
                                (.red,                    "red"),
                                (.orange,                 "orange"),
                                (Color(hex: "#FFCC00"),   "yellow"),
                                (.green,                  "green"),
                                (Color(hex: "#007AFF"),   "blue"),
                                (Color(hex: "#BF5FFF"),   "purple"),
                                (Color(hex: "#8E8E93"),   "gray"),
                            ]
                            HStack(spacing: 10) {
                                ForEach(tagColors, id: \.value) { option in
                                    let sel = presetEditorDraft.finderTagColor == option.value
                                    Button { draft.finderTagColor.wrappedValue = option.value } label: {
                                        Circle()
                                            .fill(option.color)
                                            .frame(width: 24, height: 24)
                                            .overlay(Circle().stroke(Color.white.opacity(sel ? 0.9 : 0), lineWidth: 2).padding(2))
                                            .overlay(Circle().stroke(option.color.opacity(sel ? 1 : 0), lineWidth: 2))
                                            .shadow(color: sel ? option.color.opacity(0.5) : .clear, radius: 4)
                                    }
                                    .buttonStyle(.plain)
                                    .animation(.easeInOut(duration: 0.15), value: presetEditorDraft.finderTagColor)
                                }
                                Spacer()
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: presetEditorDraft.finderTagEnabled)

                    Divider().opacity(0.4)

                    // ── Project Scaffold ──────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 11))
                                .foregroundStyle(accentBlue)
                            Text("Project Scaffold")
                                .font(.system(size:12).weight(.semibold))
                                .foregroundStyle(textPrimary.opacity(0.7))
                            InfoPopover("Folders automatically created in each project when this preset is active. Leave blank to use the global default set in Advanced settings.")
                            Spacer()
                            MiniPillToggle(isOn: Binding(
                                get: { presetEditorDraft.scaffoldEnabled },
                                set: { draft.scaffoldEnabled.wrappedValue = $0 }
                            ), onColor: accentBlue)
                        }

                        if presetEditorDraft.scaffoldEnabled {
                            let presetFolders: [String] = {
                                let raw = presetEditorDraft.scaffoldFolders.isEmpty
                                    ? scaffoldFoldersRaw
                                    : presetEditorDraft.scaffoldFolders
                                return raw.components(separatedBy: "\n")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }
                            }()
                            let isUsingGlobal = presetEditorDraft.scaffoldFolders.isEmpty

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(isUsingGlobal ? "Using global default" : "Custom folders for this preset")
                                        .font(.system(size:10))
                                        .foregroundStyle(textMuted)
                                    Spacer()
                                    if !isUsingGlobal {
                                        Button("Reset to global") {
                                            draft.scaffoldFolders.wrappedValue = ""
                                            presetNewScaffoldFolder = ""
                                        }
                                        .font(.system(size:10))
                                        .foregroundStyle(textMuted)
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.bottom, 2)

                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(presetFolders.indices, id: \.self) { i in
                                        HStack(spacing: 6) {
                                            Image(systemName: editingPresetScaffoldIndex == i ? "pencil" : "folder")
                                                .font(.system(size: 10))
                                                .foregroundStyle(editingPresetScaffoldIndex == i ? accentBlue : accentBlue.opacity(0.8))

                                            if editingPresetScaffoldIndex == i {
                                                // Edit mode: single field with full path (e.g. "Footage/A-Camera")
                                                TextField("", text: $editingPresetScaffoldText)
                                                    .textFieldStyle(.plain)
                                                    .font(.system(size:11))
                                                    .foregroundStyle(textPrimary)
                                                    .onSubmit {
                                                        let trimmed = editingPresetScaffoldText.trimmingCharacters(in: .whitespaces)
                                                        if !trimmed.isEmpty {
                                                            var list = presetFolders; list[i] = trimmed
                                                            draft.scaffoldFolders.wrappedValue = list.joined(separator: "\n")
                                                        }
                                                        editingPresetScaffoldIndex = nil
                                                    }
                                                Button("Save") {
                                                    let trimmed = editingPresetScaffoldText.trimmingCharacters(in: .whitespaces)
                                                    if !trimmed.isEmpty {
                                                        var list = presetFolders; list[i] = trimmed
                                                        draft.scaffoldFolders.wrappedValue = list.joined(separator: "\n")
                                                    }
                                                    editingPresetScaffoldIndex = nil
                                                }
                                                .font(.system(size:10).weight(.semibold))
                                                .foregroundStyle(accentBlue)
                                                .buttonStyle(.plain)
                                            } else {
                                                // Display mode: show "Folder / subfolder" with distinct styles
                                                let parts = presetFolders[i].components(separatedBy: "/")
                                                HStack(spacing: 2) {
                                                    Text(parts[0])
                                                        .font(.system(size:11))
                                                        .foregroundStyle(textPrimary)
                                                    if parts.count > 1 {
                                                        Text("/ \(parts[1...].joined(separator: "/"))")
                                                            .font(.system(size:11))
                                                            .foregroundStyle(textMuted)
                                                    }
                                                }
                                                Spacer()
                                                // Edit
                                                Button {
                                                    editingPresetScaffoldText  = presetFolders[i]
                                                    editingPresetScaffoldIndex = i
                                                } label: {
                                                    Image(systemName: "pencil")
                                                        .font(.system(size: 9))
                                                        .foregroundStyle(textMuted.opacity(0.6))
                                                }
                                                .buttonStyle(.plain)
                                                // Delete
                                                Button {
                                                    var list = presetFolders
                                                    list.remove(at: i)
                                                    draft.scaffoldFolders.wrappedValue = list.joined(separator: "\n")
                                                } label: {
                                                    Image(systemName: "xmark")
                                                        .font(.system(size: 9, weight: .semibold))
                                                        .foregroundStyle(textMuted.opacity(0.6))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .background(RoundedRectangle(cornerRadius: 6)
                                            .fill(editingPresetScaffoldIndex == i
                                                  ? (useLightMode ? accentBlue.opacity(0.06) : accentBlue.opacity(0.12))
                                                  : (useLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.05))))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(editingPresetScaffoldIndex == i ? accentBlue.opacity(0.3) : Color.clear, lineWidth: 1)
                                        )
                                        .animation(.easeInOut(duration: 0.15), value: editingPresetScaffoldIndex)
                                    }

                                    // Add folder row — folder name + optional subfolder
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(accentBlue)
                                        TextField("Folder", text: $presetNewScaffoldFolder)
                                            .textFieldStyle(.plain)
                                            .font(.system(size:11))
                                            .foregroundStyle(textPrimary)
                                            .onSubmit {
                                                var t = presetNewScaffoldFolder.trimmingCharacters(in: .whitespaces)
                                                let sub = presetNewScaffoldSubfolder.trimmingCharacters(in: .whitespaces)
                                                if !sub.isEmpty { t = "\(t)/\(sub)" }
                                                guard !t.isEmpty, !presetFolders.contains(t) else { return }
                                                draft.scaffoldFolders.wrappedValue = (presetFolders + [t]).joined(separator: "\n")
                                                presetNewScaffoldFolder    = ""
                                                presetNewScaffoldSubfolder = ""
                                            }
                                        Text("/")
                                            .font(.system(size:11))
                                            .foregroundStyle(textMuted.opacity(presetNewScaffoldFolder.isEmpty ? 0.35 : 0.7))
                                        TextField("subfolder (opt.)", text: $presetNewScaffoldSubfolder)
                                            .textFieldStyle(.plain)
                                            .font(.system(size:11))
                                            .foregroundStyle(textPrimary)
                                            .onSubmit {
                                                var t = presetNewScaffoldFolder.trimmingCharacters(in: .whitespaces)
                                                let sub = presetNewScaffoldSubfolder.trimmingCharacters(in: .whitespaces)
                                                if !sub.isEmpty { t = "\(t)/\(sub)" }
                                                guard !t.isEmpty, !presetFolders.contains(t) else { return }
                                                draft.scaffoldFolders.wrappedValue = (presetFolders + [t]).joined(separator: "\n")
                                                presetNewScaffoldFolder    = ""
                                                presetNewScaffoldSubfolder = ""
                                            }
                                            .disabled(presetNewScaffoldFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                                        if !presetNewScaffoldFolder.isEmpty {
                                            Button("Add") {
                                                var t = presetNewScaffoldFolder.trimmingCharacters(in: .whitespaces)
                                                let sub = presetNewScaffoldSubfolder.trimmingCharacters(in: .whitespaces)
                                                if !sub.isEmpty { t = "\(t)/\(sub)" }
                                                guard !t.isEmpty, !presetFolders.contains(t) else { return }
                                                draft.scaffoldFolders.wrappedValue = (presetFolders + [t]).joined(separator: "\n")
                                                presetNewScaffoldFolder    = ""
                                                presetNewScaffoldSubfolder = ""
                                            }
                                            .font(.system(size:10).weight(.medium))
                                            .foregroundStyle(accentBlue)
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 6)
                                        .fill(useLightMode ? Color.black.opacity(0.03) : Color.white.opacity(0.04))
                                        .overlay(RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(borderStroke, lineWidth: 1)))
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: presetEditorDraft.scaffoldEnabled)

                    Color.clear.frame(height: 4) // bottom breathing room
                }
                .padding(24)
            }

            Divider()

            // ── Footer ─────────────────────────────────────────────────────
            HStack {
                Spacer()
                Button("Cancel") { showPresetEditor = false }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button(presetEditorIsNew ? "Create Preset" : "Save Changes") {
                    commitPresetDraft()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 580)
        .preferredColorScheme(useLightMode ? .light : .dark)
    }

    @ViewBuilder
    private func presetToggleRow(_ label: String, _ icon: String, binding: Binding<Bool>,
                                  info: String? = nil, onColor: Color = CardRunnerTheme.neonBlue) -> some View {
        HStack(spacing: 6) {
            Label(label, systemImage: icon)
                .font(.system(size:12))
                .foregroundStyle(textPrimary)
            if let info { InfoPopover(info) }
            Spacer()
            MiniPillToggle(isOn: binding, onColor: onColor)
        }
    }

    private func openPresetEditor(preset: IngestPreset? = nil) {
        if let existing = preset {
            presetEditorDraft = existing
            presetEditorIsNew = false
        } else {
            // Pre-fill with current app settings so "capture current state" flow still works
            presetEditorDraft = IngestPreset(
                name: "",
                importMode: importMode, dateFolderFormat: dateFolderFormat,
                ingestOrder: ingestOrder,
                todayOnly: dateFilterMode == "today",
                dateFilterMode: dateFilterMode, dateFilterFrom: dateFilterFrom,
                selectedSubfolder: selectedSubfolder,
                useCustomCardName: useCustomCardName, customCardName: customCardName,
                finderTagEnabled: finderTagEnabled, finderTagColor: finderTagColor,
                completionAnimationRaw: completionAnimationRaw, dayStartHour: dayStartHour,
                broadcastDayFolders: broadcastDayFolders,
                useCustomDest: useCustomDest, customDestPath: customDestPath,
                autoEject: autoEject, copyXML: copyXML,
                verifyTransfer: verifyTransfer, includeProxies: includeProxies,
                dualDestEnabled: dualDestEnabled, fullVerifyEnabled: fullVerifyEnabled,
                transferReportEnabled: transferReportEnabled,
                renameOnIngestEnabled: renameOnIngestEnabled, renameTemplate: renameTemplate
            )
            presetEditorIsNew = true
        }
        isShowingSettings = false   // close settings so we don't stack sheets
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            showPresetEditor = true
        }
    }

    private func commitPresetDraft() {
        let trimmed = presetEditorDraft.name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        presetEditorDraft.name = trimmed

        if presetEditorIsNew {
            guard presets.count < 6 else { return }
            presets.append(presetEditorDraft)
            activePresetID = presetEditorDraft.id
        } else {
            if let idx = presets.firstIndex(where: { $0.id == presetEditorDraft.id }) {
                presets[idx] = presetEditorDraft
            }
        }
        savePresets()
        showPresetEditor = false
    }

    @State private var showDeactivateConfirm = false
    @State private var deactivateError: String? = nil

    // MARK: - Support Bundle

    private var appVersionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?.?.?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func generateSupportBundle() -> String {
        var lines: [String] = []
        let divider = String(repeating: "─", count: 48)

        // ── App & system ──────────────────────────────────────
        lines.append("CardRunner Support Bundle")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append(divider)
        lines.append("App Version : \(appVersionString)")
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS       : \(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)")
        lines.append("Mac Model   : \(macModelIdentifier())")
        lines.append("")

        // ── Settings summary ──────────────────────────────────
        lines.append("── Settings ──")
        lines.append("Mode              : \(importMode)")
        // Destination mode — critical for narrowing down SSD vs custom-folder crashes
        if useCustomDest {
            let destLabel = customDestPath.isEmpty ? "(no folder chosen)" : customDestPath
            lines.append("Destination Mode  : Custom Folder → \(destLabel)")
        } else {
            let ssdLabel  = selectedPrimary?.name ?? "(none)"
            let projLabel = projectName.isEmpty ? "(none)" : projectName
            lines.append("Destination Mode  : SSD → \(ssdLabel) / \(projLabel)")
        }
        lines.append("Project           : \(projectName.isEmpty ? "(none)" : projectName)")
        lines.append("Subfolder         : \(selectedSubfolder)")
        lines.append("Date Format       : \(dateFolderFormat)")
        lines.append("Primary SSD       : \(selectedPrimary?.name ?? "(none)")")
        lines.append("Dual Dest         : \(dualDestEnabled ? "enabled – \(secondaryPath.isEmpty ? "no path" : secondaryPath)" : "off")")
        lines.append("Verify            : \(fullVerifyEnabled ? "full" : (dualDestEnabled ? "spot" : "off"))")
        lines.append("Auto Eject        : \(UserDefaults.standard.bool(forKey: "pref_autoEject") ? "on" : "off")")
        lines.append("Dry Run           : \(dryRun ? "YES ⚠️" : "off")")
        lines.append("Broadcast Day     : \(broadcastDayFolders ? "on (cutoff \(dayStartHour)am)" : "off")")
        lines.append("Session Resets At : \(dayStartHour == 0 ? "midnight" : "\(dayStartHour)am")")
        lines.append("Import Mode       : \(importMode)")
        lines.append("Olympics Mode     : \(winterOlympicsMode ? "on (\(olympicsCode))" : "off")")
        lines.append("")

        // ── Recent log (last 7 days, newest first) ───────────
        lines.append("── Recent Log (last 7 days) ──")
        let logDir = "\(NSHomeDirectory())/Library/Logs/CardRunner"
        // Collect daily log files from today back 7 days
        var logLines: [String] = []
        let cal = Calendar.current
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyyMMdd"
        for daysBack in 0...6 {
            guard let day = cal.date(byAdding: .day, value: -daysBack, to: Date()) else { continue }
            let fname = "cardrunner_\(dateFmt.string(from: day)).log"
            let fpath = "\(logDir)/\(fname)"
            if let raw = try? String(contentsOfFile: fpath, encoding: .utf8) {
                let dayLines = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
                if !dayLines.isEmpty {
                    logLines.append("── \(fname) ──")
                    logLines.append(contentsOf: dayLines)
                }
            }
        }
        // Fall back to legacy cardrunner.log if no daily files found
        if logLines.isEmpty {
            let legacyPath = "\(logDir)/cardrunner.log"
            if let raw = try? String(contentsOfFile: legacyPath, encoding: .utf8) {
                logLines = raw.components(separatedBy: "\n").suffix(80).filter { !$0.isEmpty }
            }
        }
        if logLines.isEmpty {
            lines.append("(no log files found in \(logDir))")
        } else {
            lines.append(contentsOf: logLines)
        }
        lines.append("")

        // ── Crash logs ────────────────────────────────────────
        lines.append("── Crash Logs ──")
        let crashLogs = recentCrashLogs(maxCount: 3)
        if crashLogs.isEmpty {
            lines.append("No CardRunner crash logs found — great sign.")
        } else {
            for crash in crashLogs {
                lines.append(divider)
                lines.append("Crash: \(crash.name)  [\(crash.date)]")
                lines.append(divider)
                // Include up to 120 lines — enough for the exception/thread info
                // without blowing up the bundle with megabytes of binary frames.
                let crashLines = crash.content.components(separatedBy: "\n")
                lines.append(contentsOf: crashLines.prefix(120))
                if crashLines.count > 120 {
                    lines.append("… (\(crashLines.count - 120) more lines truncated)")
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private struct CrashEntry {
        let name: String
        let date: String
        let content: String
    }

    /// Returns up to `maxCount` most-recent CardRunner crash reports from
    /// ~/Library/Logs/DiagnosticReports, sorted newest-first.
    private func recentCrashLogs(maxCount: Int) -> [CrashEntry] {
        let diagDir = "\(NSHomeDirectory())/Library/Logs/DiagnosticReports"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: diagDir) else { return [] }

        // macOS Monterey+ writes .ips; older macOS writes .crash
        let candidates = files
            .filter { $0.hasPrefix("CardRunner") && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash")) }
            .map { (name: $0, path: "\(diagDir)/\($0)") }
            .compactMap { entry -> (name: String, path: String, mtime: Date)? in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: entry.path),
                      let mtime = attrs[.modificationDate] as? Date else { return nil }
                return (entry.name, entry.path, mtime)
            }
            .sorted { $0.mtime > $1.mtime }
            .prefix(maxCount)

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        return candidates.compactMap { entry in
            guard let content = try? String(contentsOfFile: entry.path, encoding: .utf8) else { return nil }
            return CrashEntry(name: entry.name, date: df.string(from: entry.mtime), content: content)
        }
    }

    private func macModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private func sendFeedbackToSentry(via channel: String) {
        SentrySDK.capture(message: "User reported issue via \(channel)") { scope in
            scope.setLevel(.info)
            scope.setTag(value: channel,          key: "feedback_channel")
            scope.setTag(value: appVersionString, key: "app_version")
            // Attach the full support bundle so it's readable right in the Sentry event
            scope.setExtra(value: supportBundleText, key: "support_bundle")
        }
    }

    private var supportBundleSheet: some View {
        VStack(spacing: 0) {

            // Header
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "ladybug.fill")
                    .font(.title3)
                    .foregroundStyle(accentBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Report an Issue")
                        .font(.headline)
                    Text("Copy the bundle below and paste it into your support message.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { isShowingSupportBundle = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider()

            // Bundle preview
            SmoothScrollView {
                Text(supportBundleText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .padding(.top, 14)

            Divider()
                .padding(.top, 14)

            // Action buttons
            HStack(spacing: 12) {
                Spacer()

                // Email button
                Button {
                    // Copy bundle to clipboard so they can paste it into the email
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(supportBundleText, forType: .string)

                    let subject = "CardRunner Issue – v\(appVersionString)"
                    let body = """
                        Hi,

                        Something went wrong — here's what happened:
                        [Describe the issue here]

                        Steps to reproduce (if known):
                        1.
                        2.

                        -- Support bundle (paste from clipboard below this line) --
                        """
                    // Build the mailto URL with proper encoding
                    var components = URLComponents()
                    components.scheme = "mailto"
                    components.path   = "xavigallo@gmail.com"
                    components.queryItems = [
                        URLQueryItem(name: "subject", value: subject),
                        URLQueryItem(name: "body",    value: body),
                    ]
                    if let url = components.url {
                        NSWorkspace.shared.open(url)
                    }
                    // Mirror to Sentry
                    sendFeedbackToSentry(via: "email")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope.fill")
                            .font(.caption)
                        Text("Email Support")
                            .font(.system(size:12).weight(.semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(borderStroke.opacity(0.5), lineWidth: 1))
                    )
                    .foregroundStyle(textPrimary)
                }
                .buttonStyle(.plain)

                // Copy button
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(supportBundleText, forType: .string)
                    // Also send to Sentry so both channels land in one place
                    sendFeedbackToSentry(via: "copy")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.caption)
                        Text("Copy Bundle")
                            .font(.system(size:12).weight(.semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(
                                colors: [accentBlue, accentPurple],
                                startPoint: .leading, endPoint: .trailing))
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 480)
        .background(bgColor.ignoresSafeArea())
    }

    // MARK: Settings — About tab
    private var settingsAboutTab: some View {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?.?.?"
        let accentBlue   = Color(hex: "#4F8EF7")

        return VStack(spacing: 0) {
            Spacer().frame(height: 10)

            // ── App icon + name ───────────────────────────────────────────
            VStack(spacing: 6) {
                if let nsImg = NSApplication.shared.applicationIconImage {
                    Image(nsImage: nsImg)
                        .resizable()
                        .frame(width: 66, height: 66)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                }

                Text("CardRunner")
                    .font(.system(size:20).bold())
                    .foregroundStyle(.white)

                Text("A smoother ingest workflow for creators")
                    .font(.system(size:11))
                    .foregroundStyle(Color.white.opacity(0.45))
            }

            Spacer().frame(height: 12)

            // ── Info card ─────────────────────────────────────────────────
            VStack(spacing: 0) {

                // Version + update button
                VStack(spacing: 8) {
                    Text("CardRunner \(shortVersion)")
                        .font(.system(size:13).weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.7))
                        // Secret developer unlock: ⌥-click the version number. There is NO visible
                        // toggle, so a normal user never reveals the DEV bar / fake-fixture spawners.
                        .gesture(TapGesture().modifiers(.option).onEnded { v3ToggleDevUnlock() })
                    if debugMode {
                        Text("Developer tools unlocked · ⌥-click version to hide")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(v3Purple.opacity(0.75))
                    }

                    Button {
                        (NSApp.delegate as? AppDelegate)?.updaterController.checkForUpdates(nil)
                    } label: {
                        Text("Check for Updates")
                            .font(.system(size:12).weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.8))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.09))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.white.opacity(0.13), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 10)

                Divider().opacity(0.35).padding(.horizontal, 20)

                // ── License section ───────────────────────────────────────
                VStack(spacing: 5) {
                    if license.isLicensed {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                            Text("Licensed")
                                .font(.system(size:12).weight(.semibold))
                                .foregroundStyle(Color.white.opacity(0.85))
                        }
                        if let email = license.customerEmail {
                            Text("Registered to: \(email)")
                                .font(.system(size:11))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                        Text(license.maskedKey())
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.3))

                        if case .grace(let days) = license.status {
                            Text("Offline — \(days) day\(days == 1 ? "" : "s") remaining")
                                .font(.system(size:10))
                                .foregroundStyle(.orange.opacity(0.85))
                        }

                        Button("Deactivate on this Mac") {
                            showDeactivateConfirm = true
                        }
                        .font(.system(size:11))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.white.opacity(0.35))
                        .padding(.top, 1)
                        if let err = deactivateError {
                            Text(err).font(.caption2).foregroundStyle(.red)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.seal.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                            Text("Not activated")
                                .font(.system(size:12).weight(.semibold))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { isShowingSettings = false }
                        } label: {
                            Text("Enter license key…")
                                .font(.system(size:11).weight(.medium))
                                .foregroundStyle(accentBlue)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 10)

                Divider().opacity(0.35).padding(.horizontal, 20)

                // ── Links ─────────────────────────────────────────────────
                VStack(spacing: 6) {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://www.xaviergallo.com/cardrunner")!)
                    } label: {
                        Text("xaviergallo.com/cardrunner")
                            .font(.system(size:12).weight(.medium))
                            .foregroundStyle(accentBlue)
                    }
                    .buttonStyle(.plain)

                    // License Terms + Privacy Policy on one line
                    HStack(spacing: 10) {
                        Button {
                            NSWorkspace.shared.open(URL(string: "https://www.xaviergallo.com/cardrunner-license")!)
                        } label: {
                            Text("License Terms")
                                .font(.system(size:12).weight(.medium))
                                .foregroundStyle(accentBlue)
                        }
                        .buttonStyle(.plain)

                        Text("·")
                            .font(.system(size:12))
                            .foregroundStyle(Color.white.opacity(0.25))

                        Button {
                            NSWorkspace.shared.open(URL(string: "https://www.xaviergallo.com/cardrunner-privacy-policy")!)
                        } label: {
                            Text("Privacy Policy")
                                .font(.system(size:12).weight(.medium))
                                .foregroundStyle(accentBlue)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 10)

                Divider().opacity(0.35).padding(.horizontal, 20)

                // Copyright
                Text("© 2025–2026 Xavier Gallo / XG Creative LLC")
                    .font(.system(size:11))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .padding(.vertical, 9)
            }
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
            )

            Spacer().frame(height: 10)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    // MARK: Settings — Shortcuts tab
    private var settingsShortcutsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text("Click a shortcut badge to record a new key combination. Press Delete to clear, Escape to cancel.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reset All") {
                    customShortcutsJSON = "{}"
                    shortcutsRef.value  = [:]
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
            .padding(.bottom, 16)

            let grouped  = Dictionary(grouping: ShortcutAction.allCases, by: \.section)
            let sections = ["Ingest", "Navigation", "Panels", "Presets"]

            ForEach(sections, id: \.self) { section in
                if let actions = grouped[section] {
                    Text(section.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    ForEach(actions, id: \.rawValue) { action in
                        ShortcutRecorderRow(
                            label: action.label,
                            shortcut: currentShortcut(for: action),
                            isRecording: recordingAction == action,
                            onTap: {
                                if recordingAction == action {
                                    recordingAction = nil; recordingRef.value = nil
                                } else {
                                    recordingAction = action; recordingRef.value = action
                                }
                            },
                            onClear: { setShortcut(.none, for: action) }
                        )
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    // MARK: - Header subviews

    // MARK: - Preset UI

    private func presetSubtitle(_ preset: IngestPreset) -> String {
        let mode  = preset.importMode == "photo" ? "Photo" : "Video"
        let dates: String = preset.dateFilterMode == "today" ? "Today only" : "All dates"
        var extras: [String] = []
        if preset.dualDestEnabled     { extras.append("Dual dest") }
        if preset.fullVerifyEnabled   { extras.append("Full verify") }
        if preset.autoEject           { extras.append("Auto eject") }
        let suffix = extras.isEmpty ? "" : " · " + extras.joined(separator: ", ")
        return "\(mode) · \(dates)\(suffix)"
    }

    // MARK: Settings — Presets tab
    private var settingsPresetsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Presets let you save your settings for different shoot types — switch in seconds from one to another.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if presets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 28))
                        .foregroundStyle(textMuted.opacity(0.5))
                    Text("No presets yet")
                        .font(.system(size:13).weight(.medium))
                        .foregroundStyle(textMuted)
                    Text("Tap \"New Preset…\" to create one — you can customize all options right in the editor.")
                        .font(.system(size:11))
                        .foregroundStyle(textMuted.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                VStack(spacing: 0) {
                    ForEach($presets) { $preset in
                        presetManageRow(preset: $preset)
                        if preset.id != presets.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(useLightMode ? 0.6 : 0.04))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderStroke, lineWidth: 1))
                )
            }

            // Add preset button — hidden once the 6-preset limit is reached
            let atLimit = presets.count >= 6
            Button {
                openPresetEditor()
            } label: {
                Label(
                    atLimit ? "6 preset limit reached" : "New Preset…",
                    systemImage: atLimit ? "lock.circle" : "plus.circle"
                )
                .font(.system(size:11))
                .foregroundStyle(atLimit ? textMuted.opacity(0.5) : accentBlue)
            }
            .buttonStyle(.plain)
            .disabled(atLimit)
        }
    }

    @ViewBuilder
    private func presetManageRow(preset: Binding<IngestPreset>) -> some View {
        let isActive  = activePresetID == preset.wrappedValue.id
        let isHovered = hoveredPresetID == preset.wrappedValue.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Active indicator
                Circle()
                    .fill(isActive ? accentBlue : (isHovered ? accentBlue.opacity(0.35) : Color.clear))
                    .overlay(Circle().stroke(isActive ? accentBlue : (isHovered ? accentBlue.opacity(0.5) : borderStroke), lineWidth: 1.5))
                    .frame(width: 8, height: 8)
                    .animation(.easeInOut(duration: 0.14), value: isHovered)

                // Preset name — tapping applies it
                Button {
                    applyPreset(preset.wrappedValue)
                } label: {
                    Text(preset.wrappedValue.name)
                        .font(.system(size:12).weight(.medium))
                        .foregroundStyle(isActive ? accentBlue : textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Action buttons
                HStack(spacing: 4) {
                    // Apply
                    Button {
                        applyPreset(preset.wrappedValue)
                    } label: {
                        Text(isActive ? "Active" : "Apply")
                            .font(.system(size:10).weight(.medium))
                            .foregroundStyle(isActive ? accentBlue : textMuted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(isActive ? accentBlue.opacity(0.15) : Color.white.opacity(0.06))
                                    .overlay(Capsule().stroke(isActive ? accentBlue.opacity(0.4) : borderStroke, lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)

                    // Edit — opens full preset editor modal
                    Button {
                        openPresetEditor(preset: preset.wrappedValue)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundStyle(textMuted)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)

                    // Delete
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            if activePresetID == preset.wrappedValue.id { activePresetID = nil }
                            presets.removeAll { $0.id == preset.wrappedValue.id }
                            savePresets()
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.red.opacity(0.6))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Expanded details — show when this preset is active
            if isActive {
                Divider().padding(.leading, 12)
                let p = preset.wrappedValue
                VStack(alignment: .leading, spacing: 6) {
                    // Row 1 — core shoot settings
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            presetDetailChip(p.importMode == "photo" ? "Photo" : "Video",
                                             icon: p.importMode == "photo" ? "photo" : "video")
                            presetDetailChip(p.dateFilterMode == "today" ? "Today only" : "All dates", icon: "calendar")
                            presetDetailChip(p.dateFolderFormat, icon: "folder")
                            if p.useCustomCardName && !p.customCardName.isEmpty {
                                presetDetailChip(p.customCardName, icon: "tag")
                            }
                            if p.autoEject           { presetDetailChip("Auto eject",    icon: "eject") }
                            if p.includeProxies      { presetDetailChip("Proxies",       icon: "square.stack") }
                            if p.copyXML             { presetDetailChip("XML sidecars",  icon: "doc.text") }
                        }
                    }
                    // Row 2 — verify / pro tools flags (only if any are on)
                    let proChips: [(String, String)] = [
                        p.dualDestEnabled      ? ("Dual dest",      "externaldrive.badge.plus") : nil,
                        p.fullVerifyEnabled    ? ("Full verify",    "checkmark.shield") : nil,
                        p.verifyTransfer       ? ("Spot-check",     "checkmark.circle") : nil,
                        p.transferReportEnabled ? ("Report CSV",    "chart.bar.doc.horizontal") : nil,
                        p.renameOnIngestEnabled ? ("Rename: \(p.renameTemplate)", "pencil") : nil,
                    ].compactMap { $0 }
                    if !proChips.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(proChips, id: \.0) { label, icon in
                                    presetDetailChip(label, icon: icon)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered && !isActive
                      ? Color.white.opacity(useLightMode ? 0.45 : 0.04)
                      : Color.clear)
                .animation(.easeInOut(duration: 0.14), value: isHovered)
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isActive)
        .onChange(of: preset.wrappedValue.name) { savePresets() }
        .onHover { over in
            withAnimation(.easeInOut(duration: 0.14)) {
                hoveredPresetID = over ? preset.wrappedValue.id : nil
            }
        }
    }

    private func presetDetailChip(_ label: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(label)
                .font(.system(size:10))
        }
        .foregroundStyle(textMuted)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.white.opacity(useLightMode ? 0.3 : 0.07))
                .overlay(Capsule().stroke(borderStroke, lineWidth: 1))
        )
    }

    // MARK: - Menu bar notification handlers
    // Applied as an invisible .background so we don't blow the type-checker
    // with an already-long modifier chain on the root ZStack.
    private var menuNotificationHandlers: some View {
        let spring  = Animation.spring(response: 0.32, dampingFraction: 0.62)
        let spring2 = Animation.spring(response: 0.38, dampingFraction: 0.78)
        return Color.clear
            // File → Settings…  (⌘,)
            .onReceive(NotificationCenter.default.publisher(for: .menuOpenSettings)) { _ in
                v3SettingsCat = .general
                isShowingSettings = true
            }
            // File → Start Ingest  (⌘↩)
            .onReceive(NotificationCenter.default.publisher(for: .menuStartIngest)) { _ in
                guard canIngest else { return }
                if !autoIngest { withAnimation(spring) { autoIngest = true } }
                scanForNewCardsAndIngest(forceRescan: true)
            }
            // File → Stop Transfer  (⌘.)
            .onReceive(NotificationCenter.default.publisher(for: .menuStopTransfer)) { _ in
                guard runningCount > 0 else { return }
                withAnimation(spring) { autoIngest = false }
                cancelAllIngests()
            }
            // File → Open Destination in Finder  (⌘⇧O). Also fired by the ring's "Open in Finder"
            // button once a batch is done. Opens the RESOLVED v3 default destination — per-card
            // copies land under whichever destination they're routed to, and the "Open Destination"
            // intent is the default root. Falls back to the legacy primary only for a user with no
            // Destination list (P1-5: was reading the legacy `selectedPrimary`, wrong for multi-dest).
            .onReceive(NotificationCenter.default.publisher(for: .menuOpenDestination)) { _ in
                if let p = defaultDestination?.path ?? selectedPrimary?.path, !p.isEmpty {
                    NSWorkspace.shared.open(URL(fileURLWithPath: p))
                }
            }
            // File → Open Last Ingested Folder  (⌘⇧L)
            .onReceive(NotificationCenter.default.publisher(for: .menuOpenLastFolder)) { _ in
                let dest = finderDestPath
                guard !dest.isEmpty else { return }
                NSWorkspace.shared.open(URL(fileURLWithPath: dest))
            }
            // File → Eject Card  (⌘⇧E)
            // Guard against ejecting the source card out from under an in-flight
            // cardcopy process — a raw eject mid-transfer causes a "device busy"
            // error at best and a torn read at worst (E5).
            .onReceive(NotificationCenter.default.publisher(for: .menuEjectCard)) { _ in
                guard !isBusy else {
                    statusText = "Transfer in progress — stop the transfer before ejecting."
                    return
                }
                for path in seenCardPaths where FileManager.default.fileExists(atPath: path) {
                    try? NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
                }
            }
            // View → Toggle Auto Ingest  (⌘⌥A)
            .onReceive(NotificationCenter.default.publisher(for: .menuToggleAutoIngest)) { _ in
                withAnimation(spring) { autoIngest.toggle() }
            }
            // View → Video Mode  (⌘1)
            .onReceive(NotificationCenter.default.publisher(for: .menuVideoMode)) { _ in
                withAnimation(spring) { importMode = "video" }
                AudioEngine.shared.modeSwitch()
            }
            // View → Photo Mode  (⌘2)
            .onReceive(NotificationCenter.default.publisher(for: .menuPhotoMode)) { _ in
                withAnimation(spring) { importMode = "photo" }
                AudioEngine.shared.modeSwitch()
            }
            // View → Show History  (⌘⇧H) — route to the v3 history sheet. Ignored while
            // Settings is open so a module can't render BEHIND the settings scrim (which would also
            // put two Escape/.cancelAction handlers on screen at once).
            .onReceive(NotificationCenter.default.publisher(for: .menuToggleHistory)) { _ in
                if !isShowingSettings { showV3History.toggle() }
            }
            // View → Show Log  (⌘⇧G)
            .onReceive(NotificationCenter.default.publisher(for: .menuToggleLog)) { _ in
                if !isShowingSettings { showV3Log.toggle() }
            }
            // Help → Report an Issue…
            .onReceive(NotificationCenter.default.publisher(for: .menuReportIssue)) { _ in
                supportBundleText = generateSupportBundle()
                isShowingSupportBundle = true
            }
            // Help → View Log Files
            .onReceive(NotificationCenter.default.publisher(for: .menuViewLogFiles)) { _ in
                NSWorkspace.shared.open(logsDirectoryURL)
            }
    }

    // ── Shared wiring host ────────────────────────────────────────────────────
    // The load-bearing, NON-visual wiring (card detection, timers, engine
    // onChange handlers) lifted OUT of the old legacy visual tree (now deleted).
    // `appWiringHost` is mounted by `body`, so every handler here fires exactly
    // once. Zero-size Color.clear: presents/receives fine while contributing no
    // layout. History: recovery tag `legacy-ui-archive-8db09b7`.
    // NOTE: this block was previously buried inside projectSection (rendered only
    // under the legacy UI) — see §1 of HANDOFF.md.

    /// Volume mount/unmount detection + engine-state onChange heartbeat.
    /// Formerly inline in `projectSection`. The didMount handler is the PRIMARY
    /// card-detection trigger (600 ms post-mount scan).
    private var mountAndEngineWiring: some View {
        Color.clear
            .onReceive(NotificationCenter.Publisher(
                center: NSWorkspace.shared.notificationCenter,
                name: NSWorkspace.didMountNotification)) { _ in
                volumeCardCache = [:]
                refreshDestinations()
                refreshFreeSpaceCache()  // a new drive changes available capacity tiles
                cleanupOrphanPartialDirs()
                revalidateCustomDest()   // a newly mounted volume may satisfy a stale path
                // Primary card detection path: fire a scan ~0.6 s after mount so the
                // filesystem has fully settled. This replaces the 2-second poll as the
                // main trigger — response is near-instant instead of up to 2 s late.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    scanForNewCardsAndIngest()
                }
            }
            .onReceive(NotificationCenter.Publisher(
                center: NSWorkspace.shared.notificationCenter,
                name: NSWorkspace.didUnmountNotification)) { note in
                volumeCardCache = [:]
                if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    seenCardPaths.remove(url.path)
                } else {
                    seenCardPaths = seenCardPaths.filter { FileManager.default.fileExists(atPath: $0) }
                }
                // Clear the card badge when the card is pulled
                currentCardIsKnown      = false
                currentCardInserted     = false
                currentCardMatchedName  = ""
                currentInsertedCardUUID = nil
                cardNameIsFromMemory    = false
                lastAutoFilledUUID      = nil   // re-inserting the same card should re-fill its name
                refreshDestinations()
                if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    v3FreeSpaceCache.removeValue(forKey: url.path)   // drop the ejected drive's stale label
                    pendingCardLabels.removeValue(forKey: url.path)  // a name set but never Started leaves with the card
                }
                refreshFreeSpaceCache()
                revalidateCustomDest()   // drive holding custom dest may have been ejected
            }
            // Kick / stop the "Finalizing…" pulse as the flush window opens and closes.
            .onChange(of: isFinalizing) { _, now in
                finalizePulse = now
            }
            // Refresh free-space labels when a transfer finishes (capacity just dropped) and
            // when the add-destination picker opens (so unused-drive rows show real numbers).
            .onChange(of: runningCount) { _, now in
                if now == 0 { refreshFreeSpaceCache() }
            }
            .onChange(of: showV3AddDest) { _, now in
                if now { refreshFreeSpaceCache() }
            }
            // 1-second heartbeat for sparkline (stable timer — see sparklineTimer decl)
            .onReceive(sparklineTimer) { _ in
                guard runningCount > 0 else {
                    // Ingest finished — fade the chart out by appending zeros,
                    // then clear once all samples have decayed.
                    if !speedHistory.isEmpty {
                        speedHistory.append(0)
                        if speedHistory.allSatisfy({ $0 == 0 }) { speedHistory = [] }
                        if speedHistory.count > kSpeedHistoryMax { speedHistory.removeFirst() }
                    }
                    return
                }
                // Gate: only record once we've seen actual I/O (live speed > 0) OR
                // the ingest is in a known copy/verify phase.  This prevents zeros
                // from the scan/build phase polluting the sparkline window, while
                // still recording even if a PHASE line arrives slightly late.
                let hasLiveSpeed = currentLiveMBps > 0
                let inCopyPhase = activeIngests.values.contains {
                    switch $0.phase {
                    case .copying, .verifying, .finalizing, .done: return true
                    default: return false
                    }
                }
                guard inCopyPhase || hasLiveSpeed else { return }

                // cardcopy's polling thread emits a "0  0%  0.00kB/s" line at the
                // start of every new file, which can momentarily set liveMBps to 0
                // right as the timer fires. Use the last non-zero speed so the graph
                // never dips to baseline just because a file boundary happened to
                // coincide with the 1-second tick.
                let sample: Double = currentLiveMBps > 0
                    ? currentLiveMBps
                    : (speedHistory.last(where: { $0 > 0 }) ?? 0)
                // Only append if we have a real data point — don't pad with zeros
                // while waiting for the first byte from cardcopy.
                if sample > 0 || !speedHistory.isEmpty {
                    speedHistory.append(sample)
                    if speedHistory.count > kSpeedHistoryMax { speedHistory.removeFirst() }
                }
            }
            .onChange(of: customDestPath) { revalidateCustomDest(); updateSSDInfo() }
            .frame(width: 0, height: 0)
    }

    /// Launch boot sequence + app-lifecycle handlers. Formerly chained on the
    /// legacy main-content VStack. The onAppear ordering is load-bearing:
    /// checkForStaleCheckpoints() MUST precede cleanupOrphanPartialDirs() so the
    /// orphan sweep can protect resumable .cardrunner_partial staging.
    private var bootAndLifecycleWiring: some View {
        Color.clear
            .onAppear {
                // Check license first — blocks the UI until resolved
                Task { await license.checkOnLaunch() }

                // Refresh SSD list + restore previous selection on launch.
                // NOTE: orphan-partial cleanup is deliberately deferred until AFTER
                // checkForStaleCheckpoints() below, so the sweep can skip any drive that
                // has a resumable checkpoint (its .cardrunner_partial staging is exactly
                // what a resume needs — deleting it first defeats/races the resume).
                loadDestinations()
                refreshDestinations()
                loadHistory()
                loadFailedRecords()
                loadAllTimeStats()
                bootstrapAllTimeStatsFromLogs()
                // Validate persisted custom dest path — the folder may have been
                // deleted or the drive unmounted since the last session.
                revalidateCustomDest()
                // One-time migration: if pref_dateFilterMode was never written
                // (user upgrading from an older build), seed it from the old todayOnly flag.
                if UserDefaults.standard.string(forKey: "pref_dateFilterMode") == nil {
                    dateFilterMode = todayOnly ? "today" : "all"
                }
                loadPresets()
                loadCardNicknames()
                // Check for transfers that were interrupted by a crash. Must run BEFORE
                // the orphan-partial sweep so pendingCheckpoints is populated and the
                // sweep can protect resumable staging dirs.
                checkForStaleCheckpoints()
                cleanupOrphanPartialDirs()

                // Show setup wizard if user hasn’t completed the current version
                if setupVersion < currentSetupVersion {
                    showSetupWizard = true
                }

                // Onboarding: existing users (setupVersion > 0) auto-complete silently.
                // New licensed users see the full flow. Users without a license wait
                // until activation fires via onChange(of: license.justActivated).
                if !onboardingCompleted {
                    if setupVersion > 0 {
                        onboardingCompleted = true          // skip for existing installs
                    } else if license.status == .licensed {
                        showOnboarding = true               // licensed on launch (rare edge-case)
                    }
                    // else: LicenseGateView shows; onboarding triggers after activation
                }

                // One-time launch scan — catches cards that were already inserted
                // before the app opened (mount notification already fired and was missed).
                // Short delay lets refreshDestinations() and loadCardNicknames() settle
                // so UUID lookup and nickname auto-fill work correctly on the first check.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000) // 800 ms
                    scanForNewCardsAndIngest()
                }

                // Keep the 30-s fallback scan running for the whole app lifetime — the
                // app is "armed and watching" even with Auto-Ingest OFF (it just parks
                // detected cards as "waiting to route" instead of auto-starting them).
                // Without this, a missed mount notification leaves a plugged card invisible.
                startAutoScanLoop()
                refreshFreeSpaceCache()   // seed v3 drive free-space labels off-main

                setupShortcutMonitor()
                checkFDA()   // always probe — banner must show even after wizard is dismissed
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                checkFDA()   // re-probe every time user switches back (may have just granted in Settings)
            }
            .onChange(of: autoIngest) {
                if autoIngest {
                    AudioEngine.shared.autoIngestEnabled()
                    statusText = "Searching for cards…"
                    // Scan loop already runs for the whole app lifetime (started in onAppear).
                    // Start any cards that were parked "waiting to route" while Auto-Ingest was off.
                    drainAwaiting()
                    scanForNewCardsAndIngest(forceRescan: true)
                } else {
                    AudioEngine.shared.autoIngestDisabled()
                    // NOTE: do NOT stop the scan loop here — detection must keep running
                    // so plugged cards still surface as "waiting to route" while OFF.
                    // (Card routing/auto-start is already gated on autoIngest in the scan.)
                    if runningCount > 0 {
                        cancelAllIngests()
                    }
                    if runningCount == 0 {
                        statusText = "Waiting for cards…"
                    }
                }
            }
            .onChange(of: importMode) {
                if importMode == "photo" {
                    lastVideoCopyXML = copyXML
                    copyXML = false
                } else {
                    copyXML = lastVideoCopyXML
                }
            }
            .onDisappear {
                stopAutoScanLoop()
                teardownShortcutMonitor()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showShortcutsHelp)) { _ in
                v3SettingsCat = .shortcuts
                isShowingSettings = true
            }
            // Post-activation routing: a brand-new user gets the full onboarding
            // (which opens on WelcomeCelebrationView); a returning re-activation
            // just gets the welcome celebration. Pure state-flag setter — safe on
            // the host. The overlays it triggers are rendered by
            // `licenseAndWelcomeOverlays` / OnboardingView in `body`.
            .onChange(of: license.justActivated) {
                if license.justActivated {
                    if onboardingCompleted {
                        showWelcomeOverlay = true
                    } else {
                        showOnboarding = true
                    }
                }
            }
            .frame(width: 0, height: 0)
    }

    /// License gate + returning-user welcome celebration. Rendered as a VISIBLE
    /// ZStack sibling in `body` (it can't live on the zero-size wiring host).
    /// Previously these were children of the legacy ZStack, so under v3 they
    /// rendered at opacity 0 — the license gate never actually blocked the v3
    /// face. Mounting here fixed that latent gap.
    @ViewBuilder
    private var licenseAndWelcomeOverlays: some View {
        // ── License gate ─────────────────────────────────────────────────
        // Show for both .unlicensed (never had a key) and .revoked (key
        // rejected by server — store migration, refund, wrong product).
        // NOT shown during .checking to prevent a flash on every launch.
        if license.status == .unlicensed || license.status == .revoked {
            LicenseGateView()
                .transition(.opacity)
                .zIndex(90)
        }
        // ── Welcome celebration — shown for returning users re-activating ──
        // (New first-time users get WelcomeCelebrationView as page 0 of
        //  OnboardingView instead.)
        if showWelcomeOverlay {
            WelcomeCelebrationView {
                showWelcomeOverlay = false
                license.clearJustActivated()
            }
            .transition(.opacity)
            .zIndex(50)
        }
    }

    /// Engine-triggered modal surfaces (setup wizard, preset editor, support
    /// bundle, crash-resume sheet, ingest/tier0/manifest alerts, date/reel
    /// pickers). Formerly chained on the legacy main-content VStack. Presented
    /// from a zero-size host — sheets/alerts anchor to the window, not the view.
    private var engineSheetsAndAlerts: some View {
        Color.clear
            .sheet(isPresented: $showSetupWizard) {
                SetupWizardView(
                    setupVersion: $setupVersion,
                    currentSetupVersion: currentSetupVersion,
                    isPresented: $showSetupWizard
                )
            }
            .sheet(isPresented: $showPresetEditor) {
                presetEditorSheet
            }
            .sheet(isPresented: $isShowingSupportBundle) {
                supportBundleSheet
            }
            .sheet(isPresented: $showResumeSheet) {
                resumeSheet
            }
            .alert(ingestAlertTitle, isPresented: $showIngestAlert) {
                Button("OK") { showIngestAlert = false }
            } message: {
                Text(ingestAlertMessage)
            }
            .alert("No clips match current date filter", isPresented: $showTier0Prompt) {
                Button("Cancel", role: .cancel) { tier0Card = nil }
                Button("Ingest all \(tier0SkippedCount) clip\(tier0SkippedCount == 1 ? "" : "s")") {
                    if let card = tier0Card {
                        tier0Card = nil
                        // Ingest everything on the card regardless of the date filter — otherwise
                        // the same filter re-excludes all clips and this prompt loops.
                        startIngest(for: card, ignoreDateFilter: true)
                    }
                }
            } message: {
                Text("All \(tier0SkippedCount) clip\(tier0SkippedCount == 1 ? "" : "s") on this card were excluded by the current date filter. Ingest everything?")
            }
            .alert("Already up to date", isPresented: $showManifestReingest) {
                Button("OK", role: .cancel) { manifestReingestCard = nil }
                Button("Re-ingest all \(manifestReingestCount)") {
                    if let card = manifestReingestCard {
                        let dest = manifestReingestDestID.flatMap { id in destinations.first(where: { $0.id == id }) }
                        manifestReingestCard = nil
                        startIngest(for: card, destination: dest, ignoreManifest: true)
                    }
                }
            } message: {
                Text("No new files — all \(manifestReingestCount) clip\(manifestReingestCount == 1 ? "" : "s") were already copied from this card on a previous transfer. Re-ingest copies them again to the chosen destination (your earlier copy is untouched).")
            }
            .sheet(isPresented: $showDatePickerSheet) {
                datePickerSheet
            }
            .sheet(isPresented: $showReelPickerSheet) {
                reelPickerSheet
            }
            .frame(width: 0, height: 0)
    }

    /// Keep the active preset in sync when ingestOrder / finderTagEnabled change,
    /// so applyPreset() doesn't later silently revert a change. Formerly the
    /// legacy settings rows' own .onChange handlers — but v3 ALSO mutates both
    /// values (the v3 Ingest-Order row; finderTagEnabled via v3CommitNewProject),
    /// and updateCurrentPreset() has no call sites, so this sync must run
    /// independent of the legacy tree or v3 preset edits get lost on next
    /// applyPreset(). Observes the @AppStorage values, so it fires regardless of
    /// which face changed them. See HANDOFF §1.
    private var presetSyncWiring: some View {
        Color.clear
            .onChange(of: ingestOrder) { _, newVal in
                // Keep active preset in sync so applyPreset() doesn't revert it.
                if let id = activePresetID,
                   let idx = presets.firstIndex(where: { $0.id == id }) {
                    presets[idx].ingestOrder = newVal
                    savePresets()
                }
            }
            .onChange(of: finderTagEnabled) { _, newVal in
                // Keep active preset in sync so applyPreset() doesn't revert it.
                if let id = activePresetID,
                   let idx = presets.firstIndex(where: { $0.id == id }) {
                    presets[idx].finderTagEnabled = newVal
                    savePresets()
                }
            }
            .frame(width: 0, height: 0)
    }

    /// Single mount point for all non-visual wiring, mounted by both body
    /// branches. Grows as wiring is migrated off the legacy tree (see HANDOFF §1).
    private var appWiringHost: some View {
        ZStack {
            mountAndEngineWiring
            bootAndLifecycleWiring
            engineSheetsAndAlerts
            menuNotificationHandlers
            presetSyncWiring
        }
    }

    // Live average transfer speed based on bytes copied so far
    private var currentMBps: Int {
        guard let start = ingestStartTime, runningCount > 0 else {
            return 0
        }

        let elapsed = Date().timeIntervalSince(start)
        if elapsed <= 0 { return 0 }

        let mbTransferred = Double(doneBytes) / 1_048_576.0 // bytes → MB
        return Int(mbTransferred / elapsed)                 // MB/s
    }
    // ETA string helper — uses a rolling 20-second speed window so the estimate
    // doesn't get dragged down by the idle scan/build phase at the start of a
    // transfer.  Falls back to cumulative average until there's enough history.
    private var etaString: String {
        guard runningCount > 0 else { return "ETA: —" }

        // Bytes-based ETA (preferred — most accurate)
        if totalBytesNew > 1 && doneBytes > 0 && doneBytes < totalBytesNew {
            let remainingBytes = Double(totalBytesNew - doneBytes)

            // Rolling window: last 20 non-zero 1-second MB/s samples (≈ last 20 s).
            // Using recent speed rather than cumulative average prevents the "dead"
            // scan phase from inflating the estimate or causing it to tick upward.
            let windowSamples = speedHistory.suffix(20).filter { $0 > 0 }
            let speedMBps: Double
            if windowSamples.count >= 3 {
                // Enough history: use rolling average of recent samples
                speedMBps = windowSamples.reduce(0, +) / Double(windowSamples.count)
            } else if let start = ingestStartTime {
                // Not enough history yet: cumulative average (bytes → MB)
                let elapsed = Date().timeIntervalSince(start)
                speedMBps = elapsed > 0 ? (Double(doneBytes) / elapsed / 1_048_576.0) : 0
            } else {
                return "ETA: —"
            }

            guard speedMBps > 0 else { return "ETA: —" }
            let remainingSec = Int(remainingBytes / (speedMBps * 1_048_576.0))
            return "ETA: " + formatDuration(remainingSec)
        }

        // Fallback: file-count ETA (when byte totals aren't available)
        if let start = ingestStartTime,
           totalFiles > 0, completedFiles > 0, completedFiles < totalFiles {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= 1 {
                let remainingFiles = totalFiles - completedFiles
                let avgPerFile = elapsed / Double(completedFiles)
                let remainingSec = Int(Double(remainingFiles) * avgPerFile)
                return "ETA: " + formatDuration(remainingSec)
            }
        }

        return "ETA: —"
    }

    private var transferSummaryString: String {
        // Prefer "bytes_new" (new bytes) if we have it; otherwise fall back to total card bytes.
        let totalBytes: Int64
        if totalBytesNew > 0 {
            totalBytes = totalBytesNew
        } else if cardBytesTotal > 0 {
            totalBytes = cardBytesTotal
        } else {
            return ""
        }

        // Clamp doneBytes so we don't show "over 100%"
        let clampedDone = min(doneBytes, totalBytes)

        let doneGB = Double(clampedDone) / 1_073_741_824.0
        let totalGB = Double(totalBytes) / 1_073_741_824.0

        return String(format: "%.1f / %.1f GB", doneGB, totalGB)
    }

    // ── Center-panel history — full-width, below the active zone ─────────────
    //
    // Sizing rules:
    //   • Empty state  — fixed minimum height so the section feels intentional.
    //   • 1–5 rows     — frame height = exact content height (hugs rows).
    //   • 6+ rows      — frame height capped at 5 rows; always-visible overlay
    //                    scroller with a light knob for the dark background.
    //
    // Row height constant: 11 pt text + 12 pt vertical padding + hairline leading ≈ 28 pt.
    // Divider: 1 pt. Five-row cap: 5 × 28 + 4 × 1 = 144 pt.
    private static let historyRowH: CGFloat    = 28
    private static let historyDivH: CGFloat    =  1
    private static let historyMaxRows: Int     =  5
    private static let historyEmptyMinH: CGFloat = 68

    private func historyCard(title: String,
                             status: String,
                             newFiles: Int,
                             skipped: Int,
                             avgMBps: Int,
                             durationSec: Int,
                             destPath: String,
                             reportPath: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(textPrimary)
                Spacer()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status == "Error" ? .red : .green.opacity(0.9))
            }

            Text("New files: \(newFiles)   •   Skipped: \(skipped)")
                .font(.caption)
                .foregroundStyle(textPrimary.opacity(0.85))

            Text("Avg speed: \(avgMBps) MB/s   •   Duration: \(formatDuration(durationSec))")
                .font(.caption)
                .foregroundStyle(textSecondary)

            if !destPath.isEmpty {
                HStack(spacing: 6) {
                    Text("Saved to:")
                        .font(.caption2)
                        .foregroundStyle(textMuted)
                    Text(destPath)
                        .font(.caption2)
                        .foregroundStyle(textPrimary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Open in Finder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: destPath))
                        HapticEngine.shared.success()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accentBlue)
                    .font(.caption2)
                }
            }
            if !reportPath.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(textMuted)
                    Text((reportPath as NSString).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(textPrimary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Open Report") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: reportPath))
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(useLightMode ? Color.black.opacity(0.03) : Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderStroke, lineWidth: 1))
    }

    // MARK: - Project Scaffold Helpers

    private var scaffoldFolderList: [String] {
        scaffoldFoldersRaw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func addScaffoldFolder() {
        var t = newScaffoldFolder.trimmingCharacters(in: .whitespaces)
        let sub = newScaffoldSubfolder.trimmingCharacters(in: .whitespaces)
        if !sub.isEmpty { t = "\(t)/\(sub)" }
        guard !t.isEmpty, !scaffoldFolderList.contains(t) else { return }
        scaffoldFoldersRaw = (scaffoldFolderList + [t]).joined(separator: "\n")
        newScaffoldFolder    = ""
        newScaffoldSubfolder = ""
    }

    private func removeScaffoldFolder(at index: Int) {
        var list = scaffoldFolderList
        guard index < list.count else { return }
        list.remove(at: index)
        scaffoldFoldersRaw = list.joined(separator: "\n")
    }

    private func renameScaffoldFolder(at index: Int, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var list = scaffoldFolderList
        guard index < list.count else { return }
        list[index] = trimmed
        scaffoldFoldersRaw = list.joined(separator: "\n")
    }

    /// Create scaffold folders at `projectURL`. Uses global settings unless `overrideRaw` is given.
    private func applyScaffold(to projectURL: URL, overrideRaw: String? = nil) {
        guard scaffoldEnabled else { return }
        let raw = overrideRaw ?? scaffoldFoldersRaw
        let folders = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !folders.isEmpty else { return }
        let fm = FileManager.default
        for folder in folders {
            let url = projectURL.appendingPathComponent(folder, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }

    // MARK: - Helpers

    private func checkFDA() {
        fdaGranted = SetupWizardView.probeFDA()
    }

    /// Best destination path to open in Finder.
    /// During an active transfer: the folder currently being written to.
    /// After completion (or before destPath is known): the last completed folder.
    private var finderDestPath: String {
        if runningCount > 0,
           let activePath = activeIngests.values.first(where: { !$0.destPath.isEmpty })?.destPath {
            return activePath
        }
        return lastDestPath
    }

    // MARK: - Skip Summary Row

    /// Re-checks whether `customDestPath` still exists as a directory and updates
    /// the `customDestIsValid` cache. Safe to call any time — does no I/O when path is empty.
    private func revalidateCustomDest() {
        guard !customDestPath.isEmpty else {
            customDestIsValid = false
            return
        }
        var isDir: ObjCBool = false
        customDestIsValid = FileManager.default.fileExists(atPath: customDestPath, isDirectory: &isDir)
                            && isDir.boolValue
    }

    private func updateSSDInfo() {
        let probePath: String
        if useCustomDest, !customDestPath.isEmpty {
            probePath = customDestPath
        } else if let primary = selectedPrimary {
            probePath = primary.path
        } else {
            primaryFreeBytes = 0
            primaryTotalBytes = 0
            return
        }
        let fm = FileManager.default
        do {
            let attrs = try fm.attributesOfFileSystem(forPath: probePath)
            if let free = attrs[.systemFreeSize] as? NSNumber,
               let total = attrs[.systemSize] as? NSNumber {
                primaryFreeBytes = free.int64Value
                primaryTotalBytes = total.int64Value
            }
        } catch {
            primaryFreeBytes = 0
            primaryTotalBytes = 0
        }
    }

    // MARK: - N-way destination routing model (Phase 2)

    /// The default destination — the golden box; where the first/unrouted card lands.
    /// Resolved from the saved `defaultDestID`, falling back to the first destination.
    /// nil only when no destinations are configured at all.
    var defaultDestination: Destination? {
        if let did = UUID(uuidString: defaultDestIDString),
           let match = destinations.first(where: { $0.id == did }) {
            return match
        }
        return destinations.first
    }

    /// Decode the persisted destination list into the live `destinations` @State.
    /// Runs migration the first time (empty list) so existing single-/dual-dest users
    /// keep their exact configuration. Idempotent — safe to call on every launch.
    private func loadDestinations() {
        if let data = destinationsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([Destination].self, from: data) {
            destinations = decoded
        } else {
            destinations = []
        }
        if destinations.isEmpty {
            migrateLegacyDestinations()
        }
        // Ensure a valid default is always selected when destinations exist.
        if defaultDestination == nil { defaultDestIDString = "" }
        else if UUID(uuidString: defaultDestIDString) == nil
                || !destinations.contains(where: { $0.id.uuidString == defaultDestIDString }) {
            defaultDestIDString = destinations.first?.id.uuidString ?? ""
        }
    }

    /// Persist the current `destinations` list to `destinationsJSON`.
    private func saveDestinations() {
        if let data = try? JSONEncoder().encode(destinations),
           let str = String(data: data, encoding: .utf8) {
            destinationsJSON = str
        }
    }

    /// Seed the destination list from the legacy single-/dual-dest preferences so a user
    /// who upgrades into Phase 2 keeps the *exact* destination they were already using.
    ///   • custom folder  → one custom Destination (path = customDestPath)
    ///   • else primary SSD → one drive Destination (+ secondary drive when dualDest was on)
    private func migrateLegacyDestinations() {
        var migrated: [Destination] = []
        if useCustomDest, !customDestPath.isEmpty {
            migrated.append(Destination(
                path: customDestPath,
                name: URL(fileURLWithPath: customDestPath).lastPathComponent,
                isCustomFolder: true))
        } else if !primarySSDPath.isEmpty {
            // Seed the migrated SSD destination's subfolder from the current GLOBAL subfolder so an
            // upgraded user who set a non-Default subfolder keeps landing footage in {project}/{that}/
            // — subfolder has no runtime fallback (unlike projectFolder), so it must be seeded here.
            migrated.append(Destination(
                path: primarySSDPath,
                name: URL(fileURLWithPath: primarySSDPath).lastPathComponent,
                isCustomFolder: false, subfolder: selectedSubfolder))
            if dualDestEnabled, !secondaryPath.isEmpty {
                migrated.append(Destination(
                    path: secondaryPath,
                    name: URL(fileURLWithPath: secondaryPath).lastPathComponent,
                    isCustomFolder: false, subfolder: selectedSubfolder))
            }
        }
        destinations = migrated
        defaultDestIDString = migrated.first?.id.uuidString ?? ""
        saveDestinations()
    }

    /// Reconcile the persisted destination list against what's currently mounted:
    /// drop drive destinations whose volume is no longer present (custom folders are
    /// kept regardless, since they may live on the internal disk or a remount-later
    /// drive). Does NOT auto-add every mounted drive — destinations are added explicitly.
    private func reconcileDestinations() {
        let fm = FileManager.default
        var kept: [Destination] = []
        for d in destinations {
            if d.isCustomFolder { kept.append(d); continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue {
                kept.append(d)
            }
        }
        if kept.count != destinations.count {
            destinations = kept
            if defaultDestination == nil { defaultDestIDString = destinations.first?.id.uuidString ?? "" }
            saveDestinations()
        }
    }

    /// Resolve the on-disk root and the per-card project root for a destination.
    /// Custom folders write directly under their path; drives nest under the project name.
    private func resolvedPaths(for dest: Destination) -> (destRoot: String, projectRoot: String) {
        if dest.isCustomFolder {
            return (dest.path, dest.path)
        }
        let trimmedProject = projectName.trimmingCharacters(in: .whitespaces)
        return (dest.path, trimmedProject.isEmpty ? dest.path : "\(dest.path)/\(trimmedProject)")
    }

    private func refreshDestinations() {
        let fm = FileManager.default
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)

        guard let contents = try? fm.contentsOfDirectory(at: volumesURL,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else {
            return
        }

        var dests: [Volume] = []

        for url in contents {
            let name = url.lastPathComponent
            let path = url.path
            let lower = name.lowercased()

            // Skip obvious system volumes
            if ["preboot", "recovery", "vm", "update"].contains(lower) { continue }
            if lower.contains("macintosh hd") { continue }

            // Treat any camera card (including CFexpress) as a source, not a destination.
            // Use the shared cache so volumeLooksLikeCard's filesystem enumeration only
            // runs once per volume per mount cycle across both this function and the scan loop.
            let isCard: Bool
            if let cached = volumeCardCache[path] {
                isCard = cached
            } else {
                isCard = volumeLooksLikeCard(url)
                volumeCardCache[path] = isCard
            }
            if isCard { continue }

            dests.append(Volume(name: name, path: path))
        }

        availableDestinations = dests

        if let prev = selectedPrimary {
            // Keep current selection if still mounted; otherwise try saved pref, then first available
            selectedPrimary = dests.first(where: { $0.path == prev.path })
                ?? dests.first(where: { $0.path == primarySSDPath })
                ?? dests.first
        } else {
            // On launch (selectedPrimary is nil): restore from saved pref first, then fall back
            selectedPrimary = dests.first(where: { $0.path == primarySSDPath })
                ?? dests.first
        }
        // Only persist the path when the saved drive was actually found — don't clobber the
        // preference with a fallback drive while the preferred SSD happens to be unmounted.
        if let sel = selectedPrimary, sel.path == primarySSDPath || primarySSDPath.isEmpty {
            primarySSDPath = sel.path
        }

        // Restore secondary selection if it's still mounted
        if !secondaryPath.isEmpty {
            selectedSecondary = dests.first(where: { $0.path == secondaryPath })
        }

        refreshProjectFolders()
        updateSSDInfo()
        reconcileDestinations()
    }

    /// Scans every mounted destination volume for `.cardrunner_partial` dirs
    /// left behind by a crash or force-quit and removes them.  Delegates to the
    /// existing `cleanupPartialDirs(in:)` which uses `find` — fire-and-forget,
    /// safe to call on launch before any ingest has started.
    private func cleanupOrphanPartialDirs() {
        // Never delete a partial dir on a drive that hosts a resumable checkpoint —
        // that staging is what resume re-uses. Skip those volumes; clean the rest.
        let protectedVolumes = Set(pendingCheckpoints.map { $0.primaryPath })
        for dest in availableDestinations where !protectedVolumes.contains(dest.path) {
            cleanupPartialDirs(in: dest.path)
        }
    }

    private func restorePrimarySelectionFromPrefs() {
        guard !primarySSDPath.isEmpty else { return }
        if let match = availableDestinations.first(where: { $0.path == primarySSDPath }) {
            selectedPrimary = match
        }
    }

    // MARK: - Card nickname memory

    private var cardNicknamesFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CardRunner")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("card_nicknames.json")
    }

    private func loadCardNicknames() {
        guard let data = try? Data(contentsOf: cardNicknamesFileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        knownCardNicknames = dict
    }

    private func persistCardNicknames() {
        guard let data = try? JSONEncoder().encode(knownCardNicknames) else { return }
        try? data.write(to: cardNicknamesFileURL, options: .atomic)
    }

    /// Returns the Volume UUID for a mounted path by running `diskutil info`.
    /// Blocks the calling thread — invoke only from a background thread.
    nonisolated private func getVolumeUUIDSync(atPath path: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["info", path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()   // discard stderr
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8) else { return nil }
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            // diskutil prints "   Volume UUID:              XXXXXXXX-…"
            if t.lowercased().hasPrefix("volume uuid:") {
                let value = String(t.dropFirst("Volume UUID:".count))
                    .trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    // (Removed: saveProjectForCurrentSSD / restoreProjectForCurrentSSD + the legacy
    //  pref_ssdProjectMap. The v3 per-destination `projectFolder` is now the single source
    //  of truth for project routing; the legacy SSD→project auto-restore was redundant and
    //  could override the current project from a now-frozen map on drive mount.)

    private func refreshProjectFolders() {
        availableProjects = []

        guard let primary = selectedPrimary else {
            projectName = ""
            return
        }

        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: primary.path, isDirectory: true)

        guard let contents = try? fm.contentsOfDirectory(at: rootURL,
                                                         includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else {
            // Can't read drive (e.g. no FDA yet) — don't wipe a manually-set project name.
            return
        }

        var folders: [String] = []

        for url in contents {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                folders.append(url.lastPathComponent)
            }
        }

        folders.sort()
        availableProjects = folders

        // Only auto-select an existing folder when the project name is blank.
        // If the user has already typed a name (e.g. from onboarding), keep it
        // even if that folder doesn't exist yet — it will be created on ingest.
        if projectName.trimmingCharacters(in: .whitespaces).isEmpty {
            projectName = folders.first ?? ""
        }

        refreshSubfolders()
    }

    private func refreshSubfolders() {
        availableSubfolders = []

        guard let primary = selectedPrimary, !projectName.isEmpty else {
            selectedSubfolder = "Default"
            return
        }

        let fm = FileManager.default
        let projectPath = primary.path + "/" + projectName
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)

        guard let contents = try? fm.contentsOfDirectory(at: projectURL,
                                                         includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else {
            selectedSubfolder = "Default"
            return
        }

        var subs: [String] = []

        for url in contents {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                subs.append(url.lastPathComponent)
            }
        }

        subs.sort()
        availableSubfolders = subs

        if !subs.contains(selectedSubfolder) {
            selectedSubfolder = "Default"
        }
    }

    // Allow both auto-ingest polling and manual \"search\" with a forced rescan.
    // All filesystem work runs off the main thread; state is mutated back on MainActor.
    private func scanForNewCardsAndIngest(forceRescan: Bool = false) {
        // No early-return guard on autoIngest here.
        // Card detection + nickname recognition always run — they're passive reads.
        // Only ingest routing (routeCardsForIngest) is gated on autoIngest below.

        // When using a custom destination, exclude that volume root from card
        // detection so the drive it lives on is never auto-ingested as a card source.
        let primaryPath: String?
        if useCustomDest && !customDestPath.isEmpty {
            let comps = URL(fileURLWithPath: customDestPath).pathComponents
            primaryPath = comps.count >= 3 && comps[1] == "Volumes" ? "/Volumes/\(comps[2])" : nil
        } else {
            primaryPath = selectedPrimary?.path
        }
        let secPath = secondaryPath
        let cache   = volumeCardCache
        let mode    = importMode
        let force   = forceRescan
        // Capture nickname dict before background hop so we can check it without MainActor
        let capturedNicknames = knownCardNicknames

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return }

            var newCache = cache
            var detectedCards: [Volume] = []

            for name in names {
                let path = "/Volumes/\(name)"
                let url  = URL(fileURLWithPath: path, isDirectory: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let lower = name.lowercased()
                if lower == "macintosh hd" || lower.hasPrefix("macintosh hd") { continue }

                let isCard: Bool
                if let cached = newCache[path] {
                    isCard = cached
                } else {
                    isCard = await self.withVolumeTimeout(seconds: 1.5) {
                        self.volumeLooksLikeCardStatic(url, primaryPath: primaryPath, secondaryPath: secPath, importMode: mode)
                    }
                    newCache[path] = isCard
                }
                if isCard {
                    let camera = detectCameraModel(at: path)
                    // Look up Volume UUID while still on the background thread
                    let uuid = self.getVolumeUUIDSync(atPath: path)
                    detectedCards.append(Volume(name: name, path: path, cameraModel: camera, volumeUUID: uuid))
                }
            }

            // Snapshot as let so Swift Concurrency is happy with captures
            let finalCache = newCache
            let finalCards = detectedCards

            await MainActor.run {
                self.volumeCardCache = finalCache

                if force {
                    if finalCards.isEmpty {
                        self.statusText = "No cards detected."
                    } else {
                        // Always apply nickname / badge recognition on forced rescans.
                        self.applyNicknameIfKnown(from: finalCards, nicknames: capturedNicknames)
                        if self.autoIngest {
                            for card in finalCards {
                            self.seenCardPaths.insert(card.path)
                            if let uuid = card.volumeUUID { self.seenCardUUIDs.insert(uuid) }
                        }
                            self.routeCardsForIngest(finalCards)
                        } else {
                            // Auto-Ingest OFF — park every detected card "waiting to route".
                            self.enqueueAwaiting(finalCards)
                            let label = self.currentCardMatchedName.isEmpty
                                ? "Card ready"
                                : "\(self.currentCardMatchedName) ready"
                            self.statusText = "\(label) — start transfer when you're ready"
                        }
                    }
                    return
                }

                let currentPaths = Set(finalCards.map { $0.path })
                let currentUUIDs = Set(finalCards.compactMap { $0.volumeUUID })
                self.seenCardPaths = self.seenCardPaths.intersection(currentPaths)
                self.seenCardUUIDs = self.seenCardUUIDs.intersection(currentUUIDs)
                self.cardQueue.removeAll { !currentPaths.contains($0.card.path) }
                // Drop awaiting cards that have been PHYSICALLY removed — but key on identity
                // (UUID when present, else path). A UUID-bearing card that merely remounts at a new
                // path (classic for "Untitled" cards) is NOT gone, so its lane (and the operator's
                // typed name) is preserved instead of being torn down and re-prefilled.
                self.awaitingCards.removeAll { aw in
                    if let u = aw.card.volumeUUID { return !currentUUIDs.contains(u) }
                    return !currentPaths.contains(aw.card.path)
                }

                var newCards: [Volume] = []
                for card in finalCards {
                    // Prefer UUID-keyed dedup: cards like Untitled / NO NAME often share
                    // mount paths but have stable UUIDs across eject/reinsert cycles.
                    // Fall back to path when UUID is nil (exFAT / FAT32 cards). (O6)
                    let alreadySeen = card.volumeUUID.map { self.seenCardUUIDs.contains($0) }
                        ?? self.seenCardPaths.contains(card.path)
                    if alreadySeen { continue }
                    // Only mark as "seen" when Auto Ingest is on so that a card
                    // detected while Auto Ingest is off stays "fresh" and will be
                    // picked up automatically if the user later enables Auto Ingest.
                    if self.autoIngest {
                        self.seenCardPaths.insert(card.path)
                        if let uuid = card.volumeUUID { self.seenCardUUIDs.insert(uuid) }
                    }
                    newCards.append(card)
                }

                if self.autoIngest {
                    // Auto Ingest on — route NEW (unseen) cards to the ingest flow.
                    if !newCards.isEmpty {
                        self.applyNicknameIfKnown(from: newCards, nicknames: capturedNicknames)
                        self.routeCardsForIngest(newCards)
                    }
                } else {
                    // Auto Ingest off — park EVERY currently-detected card "waiting to route",
                    // independent of seen-dedup. A card the app already handled this session
                    // (manually Started, or auto-ingested before Auto-Ingest was switched off)
                    // must re-appear when re-inserted, so the operator can run it again.
                    // enqueueAwaiting skips cards already parked or already shown as a
                    // live lane (a finished lane is removed from activeIngests, so a pulled-
                    // and-reinserted card correctly re-surfaces). seen* is left untouched so flipping
                    // Auto-Ingest on later still picks these up.
                    self.applyNicknameIfKnown(from: finalCards, nicknames: capturedNicknames)
                    let before = self.awaitingCards.count
                    self.enqueueAwaiting(finalCards)
                    if self.awaitingCards.count > before {
                        let label = self.currentCardMatchedName.isEmpty
                            ? "Card ready"
                            : "\(self.currentCardMatchedName) ready"
                        self.statusText = "\(label) — start transfer when you're ready"
                    }
                }

                if finalCards.isEmpty && self.runningCount == 0 {
                    self.currentCardIsKnown      = false
                    self.currentCardInserted     = false
                    self.currentCardMatchedName  = ""
                    self.currentInsertedCardUUID = nil
                    self.cardNameIsFromMemory    = false
                    self.awaitingCards.removeAll()
                    self.statusText = self.autoIngest ? "Searching for cards…" : "Waiting for cards…"
                }
            }
        }
    }

    /// Apply a per-card folder rename AFTER a copy completes (never mid-copy — the shell caches
    /// dest paths, so a live rename would split footage). Renames every {destPath}/{date}/{old}
    /// directory to {date}/{new}. CONFLICT-SAFE: skips (and logs) when the target already exists
    /// or the source is missing — it never merges, overwrites, or deletes. The manifest dedups on
    /// SOURCE identity, so a renamed dest folder doesn't break re-ingest. Returns the name actually
    /// in effect (new if at least one folder moved, else old — footage is never left in limbo).
    @MainActor @discardableResult
    private func applyPendingFolderRename(destPath: String, oldLabel: String, newLabel: String) -> String {
        let fm = FileManager.default
        let oldT = oldLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let newT = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only rename an EXISTING label folder to a new, valid, non-empty, different name.
        guard !destPath.isEmpty, !oldT.isEmpty, !newT.isEmpty, newT != oldT,
              !newT.contains("/"), newT != ".", newT != ".." else { return oldLabel }
        var movedAny = false
        // Conflict-safe move of {parent}/{oldT} → {parent}/{newT}. Never overwrites/merges/deletes.
        func tryRename(in parent: String) {
            let src = "\(parent)/\(oldT)", dst = "\(parent)/\(newT)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue else { return }
            if fm.fileExists(atPath: dst) {
                appendLog("RENAME SKIP: \(dst) already exists — kept folder \(oldT)\n"); return
            }
            do { try fm.moveItem(atPath: src, toPath: dst); movedAny = true
                 appendLog("Renamed card folder \(oldT) → \(newT)\n") }
            catch { appendLog("RENAME FAIL: \(src) → \(newT): \(error.localizedDescription) — kept \(oldT)\n") }
        }
        // Cover the label folder wherever the engine nests it: {date}/{label} (flat/custom),
        // and {date}/{reel|lane}/{label} (reel-multi / olympics). One extra shallow listing per
        // date dir — both passes are conflict-safe, so a label that isn't there is simply skipped.
        let dateDirs = (try? fm.contentsOfDirectory(atPath: destPath)) ?? []
        for d in dateDirs {
            let dateDir = "\(destPath)/\(d)"
            var dIsDir: ObjCBool = false
            guard fm.fileExists(atPath: dateDir, isDirectory: &dIsDir), dIsDir.boolValue else { continue }
            tryRename(in: dateDir)
            for s in (try? fm.contentsOfDirectory(atPath: dateDir)) ?? [] {
                let subDir = "\(dateDir)/\(s)"
                var sIsDir: ObjCBool = false
                guard fm.fileExists(atPath: subDir, isDirectory: &sIsDir), sIsDir.boolValue else { continue }
                tryRename(in: subDir)
            }
        }
        return movedAny ? newT : oldLabel
    }

    /// Auto-fill the card label field when we recognise a card's UUID.
    /// Only fills if the field is currently empty or the toggle is off — never stomps
    /// a label the user has already typed or one applied by a preset.
    private func applyNicknameIfKnown(from cards: [Volume], nicknames: [String: String]) {
        currentCardInserted = true   // a card is physically present regardless of recognition

        // Store the UUID so the name field can save on every keystroke.
        currentInsertedCardUUID = cards.first(where: { $0.volumeUUID != nil })?.volumeUUID ?? nil

        var foundNickname: String? = nil
        var foundUUID:     String? = nil
        for card in cards {
            if let uuid = card.volumeUUID, let stored = nicknames[uuid] {
                foundNickname = stored
                foundUUID     = uuid
                break   // take the first recognised card
            }
        }
        if let nickname = foundNickname {
            currentCardIsKnown     = true
            currentCardMatchedName = nickname
            // Fill the field with the remembered name whenever a DIFFERENT card is
            // recognised than the one we last auto-filled. This updates the field on a
            // genuine new insert — even over stale text left from a previous card or
            // preset — which is what the operator expects ("recognised card → its name").
            // It does NOT re-stomp on the periodic re-scan of a card that's just
            // sitting there, so renaming a known card still works: the user's
            // keystrokes persist via onChange (which also updates the stored nickname),
            // and the matching UUID guard below leaves their edit untouched.
            if foundUUID != lastAutoFilledUUID {
                skipNextNicknameSave = true   // programmatic write — don't re-save to UUID store
                useCustomCardName = true
                customCardName    = nickname
                lastAutoFilledUUID = foundUUID
            }
            cardNameIsFromMemory = true
        } else {
            // Unknown card. If the field currently shows a name that was auto-filled
            // from a previous card's memory, clear it — we don't want Card A's name
            // to accidentally be stamped onto Card B. If the name came from a preset
            // or the user explicitly typed it, leave it alone.
            if cardNameIsFromMemory {
                skipNextNicknameSave = true   // don't treat the clear as a user keystroke
                useCustomCardName = false
                customCardName    = ""
            }
            cardNameIsFromMemory   = false
            currentCardIsKnown     = false
            currentCardMatchedName = ""
            lastAutoFilledUUID     = nil
        }
    }

    private func isVideoPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".mp4") ||
               lower.hasSuffix(".mov") ||
               lower.hasSuffix(".mxf") ||
               lower.hasSuffix(".crm") ||
               lower.hasSuffix(".r3d")
    }

    private func isPhotoPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".jpg") ||
               lower.hasSuffix(".jpeg") ||
               lower.hasSuffix(".png") ||
               lower.hasSuffix(".tif") ||
               lower.hasSuffix(".tiff") ||
               lower.hasSuffix(".heic") ||
               lower.hasSuffix(".heif") ||
               lower.hasSuffix(".dng") ||
               lower.hasSuffix(".cr2") ||
               lower.hasSuffix(".cr3") ||
               lower.hasSuffix(".nef") ||
               lower.hasSuffix(".arw") ||
               lower.hasSuffix(".raf") ||
               lower.hasSuffix(".rw2") ||
               lower.hasSuffix(".orf") ||
               lower.hasSuffix(".sr2")
    }

    private func isMediaPathForCurrentMode(_ path: String) -> Bool {
        if importMode == "photo" {
            return isPhotoPath(path)
        } else {
            return isVideoPath(path)
        }
    }

    /// Scan a card's media files and return distinct capture dates, sorted newest-first.
    ///
    /// Mirrors the logic of CardRunner.sh's `detect_src_dir` to choose the scan root:
    ///   • Sony/CFexpress (M4ROOT / XDROOT present)  → card root
    ///   • Generic stills (DCIM folder found)         → card root / DCIM
    ///   • Fallback                                   → card root
    ///
    /// Files in thumbnail folders (THMBNL) are skipped.  Only recognised media
    /// extensions are counted (same list as the shell build_media_file_list helpers).
    ///
    /// Uses `DispatchQueue.global` + `withCheckedContinuation` instead of
    /// `Task.detached` so that `NSDirectoryEnumerator` iteration works correctly
    /// (its `makeIterator` is unavailable in Swift structured-concurrency contexts).
    nonisolated private func scanCardDates(at cardPath: String, mode: String) async -> [CardDateInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.scanCardDatesSync(cardPath: cardPath, importMode: mode))
            }
        }
    }

    /// Synchronous implementation of the card-date scanner; called from a GCD queue.
    /// `importMode` is `"photo"` or `"video"` — only files matching that mode are counted
    /// so the picker never shows dates that would produce "no new files" for the current mode.
    nonisolated private static func scanCardDatesSync(cardPath: String, importMode: String) -> [CardDateInfo] {
        let fm      = FileManager.default
        let cardURL = URL(fileURLWithPath: cardPath)

        // ── Determine scan root (mirrors detect_src_dir in CardRunner.sh) ─────
        var scanRoot = cardPath

        // 1. Sony/CFexpress: look for M4ROOT or XDROOT within 5 directory levels.
        //    We walk only directory entries; stop recursing past depth 5.
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

        if findDir("M4ROOT", under: cardURL, maxDepth: 5) != nil ||
           findDir("XDROOT", under: cardURL, maxDepth: 5) != nil {
            // Sony/CFexpress — scan from card root (already set)
        } else if let dcimURL = findDir("DCIM", under: cardURL, maxDepth: 4) {
            // Generic stills layout — narrow the scan to DCIM subtree
            scanRoot = dcimURL.path
        }
        // else: fallback → whole card root

        // ── Media extensions filtered by import mode ─────────────────────────
        // Only count files that would actually be ingested in the current mode
        // so the picker never surfaces dates whose files are all the wrong type.
        let photoExts: Set<String> = [
            "jpg","jpeg","png","tif","tiff","heic","heif",
            "dng","cr2","cr3","nef","arw","raf","rw2","orf","sr2"
        ]
        let videoExts: Set<String> = [
            "mp4","mov","mxf","crm","r3d","braw","ari","arx","mts","m2ts"
        ]
        let mediaExts: Set<String> = importMode == "photo" ? photoExts : videoExts

        // ── Enumerate files and group by modification date ────────────────────
        var groups: [String: (count: Int, bytes: Int64)] = [:]

        let todayStr: String = {
            let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd"
            return fmt.string(from: Date())
        }()
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyyMMdd"

        // Use a plain enumerator with NO pre-fetched resource keys — we'll call
        // attributesOfItem(atPath:) per file instead.  URL resource values for
        // isRegularFile / fileSize / contentModificationDate are unreliable on
        // exFAT/FAT32 camera cards and can come back nil, killing the guard.
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: scanRoot),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        while let rawURL = enumerator.nextObject() as? URL {
            // Skip thumbnail folders
            if rawURL.path.contains("/THMBNL/") { continue }

            // Only recognised media extensions (case-insensitive)
            let ext = rawURL.pathExtension.lowercased()
            guard mediaExts.contains(ext) else { continue }

            // attributesOfItem maps straight to stat(2) — works on every macOS
            // filesystem including exFAT, FAT32, and UDF camera cards.
            guard let attrs = try? fm.attributesOfItem(atPath: rawURL.path),
                  (attrs[.type] as? FileAttributeType) != .typeDirectory,
                  let mtime = attrs[.modificationDate] as? Date else { continue }

            let size = (attrs[.size] as? Int).map { Int64($0) } ?? 0
            let ds   = dateFmt.string(from: mtime)
            let prev = groups[ds] ?? (0, 0)
            groups[ds] = (prev.count + 1, prev.bytes + size)
        }

        // ── Build sorted result (newest-first) ────────────────────────────────
        return groups
            .map { yyyymmdd, stats in
                CardDateInfo(
                    yyyymmdd:   yyyymmdd,
                    fileCount:  stats.count,
                    totalBytes: stats.bytes,
                    isToday:    yyyymmdd == todayStr
                )
            }
            .sorted { $0.yyyymmdd > $1.yyyymmdd }
    }

    // MARK: - Wrong-clock analysis

    nonisolated private func analyzeCard(at cardPath: String, mode: String) async -> CardAnalysis {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.analyzeCardSync(cardPath: cardPath, importMode: mode))
            }
        }
    }

    /// Scans the card for date groups AND reel (top-level folder) structure.
    /// Returns full `CardAnalysis` including wrong-clock detection.
    nonisolated private static func analyzeCardSync(cardPath: String, importMode: String) -> CardAnalysis {
        let fm      = FileManager.default
        let cardURL = URL(fileURLWithPath: cardPath)

        // ── Determine scan root (same logic as scanCardDatesSync) ─────────────
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

        var scanRoot = cardPath
        if findDir("M4ROOT", under: cardURL, maxDepth: 5) != nil ||
           findDir("XDROOT", under: cardURL, maxDepth: 5) != nil {
            // Sony/CFexpress — scan from card root
        } else if let dcimURL = findDir("DCIM", under: cardURL, maxDepth: 4) {
            scanRoot = dcimURL.path
        }

        // ── Media extensions by mode ──────────────────────────────────────────
        let photoExts: Set<String> = [
            "jpg","jpeg","png","tif","tiff","heic","heif",
            "dng","cr2","cr3","nef","arw","raf","rw2","orf","sr2"
        ]
        let videoExts: Set<String> = [
            "mp4","mov","mxf","crm","r3d","braw","ari","arx","mts","m2ts"
        ]
        let mediaExts: Set<String> = importMode == "photo" ? photoExts : videoExts

        // ── Date formatter ────────────────────────────────────────────────────
        let todayStr: String = {
            let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd"
            return fmt.string(from: Date())
        }()
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyyMMdd"

        // ── Implausibility: years too old, future, or near known reset epochs ─
        let cal = Calendar.current
        let currentYear = cal.component(.year, from: Date())
        let nowTS = Date().timeIntervalSinceReferenceDate
        // Known camera reset epochs — dead RTC battery causes files to land here
        let resetEpochs: [Date] = [(1970,1,1),(1980,1,1),(2000,1,1),(2010,1,1),
                                    (2011,1,1),(2012,1,1),(2013,1,1)].compactMap { y, m, d in
            var c = DateComponents(); c.year = y; c.month = m; c.day = d
            return cal.date(from: c)
        }
        func isImplausible(_ date: Date) -> Bool {
            let y = cal.component(.year, from: date)
            if y < currentYear - 3 { return true }
            if date.timeIntervalSinceReferenceDate > nowTS + 2 * 86400 { return true }
            for epoch in resetEpochs where abs(date.timeIntervalSince(epoch)) < 7 * 86400 { return true }
            return false
        }

        // ── Enumerate and group by date AND by top-level folder ───────────────
        var dateGroups: [String: (count: Int, bytes: Int64)] = [:]
        var reelGroups: [String: (count: Int, bytes: Int64, dates: Set<String>)] = [:]
        var hasImplausible = false

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: scanRoot),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return CardAnalysis(dates: [], reels: [], hasImplausibleDates: false)
        }

        while let rawURL = enumerator.nextObject() as? URL {
            if rawURL.path.contains("/THMBNL/") { continue }
            let ext = rawURL.pathExtension.lowercased()
            guard mediaExts.contains(ext) else { continue }

            guard let attrs = try? fm.attributesOfItem(atPath: rawURL.path),
                  (attrs[.type] as? FileAttributeType) != .typeDirectory,
                  let mtime = attrs[.modificationDate] as? Date else { continue }

            let size = (attrs[.size] as? Int).map { Int64($0) } ?? 0
            let ds   = dateFmt.string(from: mtime)

            // Date groups
            let prev = dateGroups[ds] ?? (0, 0)
            dateGroups[ds] = (prev.count + 1, prev.bytes + size)

            // Implausibility check
            if !hasImplausible && isImplausible(mtime) { hasImplausible = true }

            // Reel: first path component relative to scanRoot
            let filePath = rawURL.path
            guard filePath.hasPrefix(scanRoot + "/") else { continue }
            let rel = String(filePath.dropFirst(scanRoot.count + 1))
            guard let slashIdx = rel.firstIndex(of: "/") else { continue }  // skip files directly at scanRoot
            let reelName = String(rel[rel.startIndex..<slashIdx])
            guard !reelName.isEmpty else { continue }

            var r = reelGroups[reelName] ?? (0, 0, [])
            r.count += 1
            r.bytes += size
            r.dates.insert(ds)
            reelGroups[reelName] = r
        }

        // ── Build results ─────────────────────────────────────────────────────
        let dates = dateGroups
            .map { yyyymmdd, stats in
                CardDateInfo(yyyymmdd: yyyymmdd, fileCount: stats.count,
                             totalBytes: stats.bytes, isToday: yyyymmdd == todayStr)
            }
            .sorted { $0.yyyymmdd > $1.yyyymmdd }

        let reels = reelGroups
            .map { name, stats in
                ReelInfo(folderName: name, folderPath: "\(scanRoot)/\(name)",
                         fileCount: stats.count, totalBytes: stats.bytes,
                         distinctDates: stats.dates)
            }
            .sorted { $0.folderName > $1.folderName }  // newest/highest name first

        return CardAnalysis(dates: dates, reels: reels, hasImplausibleDates: hasImplausible)
    }

    private func volumeLooksLikeCard(_ url: URL) -> Bool {
        // When using a custom destination, exclude that volume root so the
        // drive the custom folder lives on is never treated as a card source.
        let pp: String?
        if useCustomDest && !customDestPath.isEmpty {
            let comps = URL(fileURLWithPath: customDestPath).pathComponents
            pp = comps.count >= 3 && comps[1] == "Volumes" ? "/Volumes/\(comps[2])" : nil
        } else {
            pp = selectedPrimary?.path
        }
        return volumeLooksLikeCardStatic(
            url,
            primaryPath:   pp,
            secondaryPath: secondaryPath,
            importMode:    importMode
        )
    }
    // MARK: - Ingest

    /// Single entry point for routing a batch of newly-detected cards.
    ///
    /// • "Today only" ON  → `startIngest` immediately; shell applies `--today-only`.
    /// • "Today only" OFF → scan the card's media files for distinct capture dates,
    ///   then branch:
    ///     – 1 date  → `startIngest` with that date as `--date-from` (no prompt)
    ///     – 0 dates → show the picker in fallback mode (scan couldn't read dates)
    // Single predicate for "is an ingest or demo running?".
    // Gates startIngest so the demo (demoTask != nil) and a real ingest can't both launch —
    // the old activeProcesses.isEmpty check missed the demo path entirely (O4).
    private var isBusy: Bool { runningCount > 0 || demoTask != nil }

    // Stable card identity: prefer volumeUUID (persists across remount with a new path)
    // and fall back to path only when UUID is nil (exFAT / some FAT32 cards). (O6)
    private func cardIdentifier(for card: Volume) -> String {
        card.volumeUUID ?? card.path
    }

    ///     – 2+ dates → show the multi-select date picker
    ///
    // MARK: - Awaiting cards (Auto-Ingest OFF — "waiting to route")

    /// Park newly-detected cards in the "waiting to route" list (dedup by mount path).
    /// Each card starts with no chosen destination (nil = use default until the user
    /// drags its node onto a drive or presses Start).
    @MainActor private func enqueueAwaiting(_ cards: [Volume]) {
        // Snapshot what's already on screen so a card never shows as both an awaiting
        // entry and a live lane. Active lanes are matched by source PATH (so two distinct
        // UUID-less "Untitled" cards mounted at different paths each still surface) plus
        // source UUID as a backstop. See cardIsAlreadyTracked.
        var awaitingPaths = Set(awaitingCards.map { $0.card.path })
        var awaitingUUIDs = Set(awaitingCards.compactMap { $0.card.volumeUUID })
        let activeUUIDs   = Set(activeIngests.values.compactMap { $0.volumeUUID })
        let activePaths   = Set(activeIngests.values.map { $0.sourcePath }.filter { !$0.isEmpty })
        for card in cards {
            // Dedup on UUID-or-path: an existing lane (with the operator's typed name) is
            // NEVER re-created just because a UUID-bearing card's mount path shuffled.
            if cardIsAlreadyTracked(cardPath: card.path, cardUUID: card.volumeUUID,
                                    awaitingPaths: awaitingPaths, awaitingUUIDs: awaitingUUIDs,
                                    activeUUIDs: activeUUIDs, activePaths: activePaths) { continue }
            // Pre-fill the per-card folder name with this card's saved nickname (if any) or its
            // volume name, so each lane shows an editable folder name out of the box.
            let prefill = card.volumeUUID.flatMap { knownCardNicknames[$0] } ?? card.name
            awaitingCards.append(AwaitingCard(card: card, customName: prefill))
            awaitingPaths.insert(card.path)
            if let u = card.volumeUUID { awaitingUUIDs.insert(u) }
        }
    }

    /// Press "Start" on a waiting card — routes it to its chosen destination (or the
    /// default) and begins the lifecycle. Marks the card seen so the auto-scan loop
    /// won't re-park it.
    @MainActor private func startAwaiting(_ awaitingID: UUID) {
        guard let item = awaitingCards.first(where: { $0.id == awaitingID }) else { return }
        let dest = item.destinationID.flatMap { id in destinations.first(where: { $0.id == id }) }
        seenCardPaths.insert(item.card.path)
        if let uuid = item.card.volumeUUID { seenCardUUIDs.insert(uuid) }
        pendingCardLabels[item.card.path] = item.customName.trimmingCharacters(in: .whitespacesAndNewlines)
        awaitingCards.removeAll { $0.id == awaitingID }
        routeCardsForIngest([item.card], destination: dest)
    }

    /// Drag-drop a waiting card's node onto a destination: bind it to that drive AND
    /// start it immediately (mirrors the demo's `route(_:to:)`).
    @MainActor private func routeAwaiting(_ awaitingID: UUID, to destID: UUID) {
        // LINK only — bind the card to this destination but do NOT start. The card waits for
        // the operator to press Start (there's a Start button on the lane). Inaction = stays
        // parked. (Auto-Ingest ON routes + starts automatically via routeCardsForIngest; this
        // drag gesture is the Auto-Ingest-OFF "choose where it'll go, then I'll start it" path.)
        guard let idx = awaitingCards.firstIndex(where: { $0.id == awaitingID }) else { return }
        awaitingCards[idx].destinationID = destID
    }

    /// When Auto-Ingest flips ON, start every parked card on its chosen (or default) drive.
    @MainActor private func drainAwaiting() {
        let parked = awaitingCards
        awaitingCards.removeAll()
        for item in parked {
            let dest = item.destinationID.flatMap { id in destinations.first(where: { $0.id == id }) }
            seenCardPaths.insert(item.card.path)
            if let uuid = item.card.volumeUUID { seenCardUUIDs.insert(uuid) }
            pendingCardLabels[item.card.path] = item.customName.trimmingCharacters(in: .whitespacesAndNewlines)
            routeCardsForIngest([item.card], destination: dest)
        }
    }

    /// Called from every scan path (auto-ingest loop, 30-s fallback loop, force-rescan)
    /// so the behaviour is consistent regardless of how a card is detected.
    @MainActor private func routeCardsForIngest(_ cards: [Volume], destination: Destination? = nil) {
        guard !cards.isEmpty else { return }

        // Capture mode on the main actor before entering the unstructured task
        let currentMode = importMode
        let currentDateMode = dateFilterMode

        // Always scan first — even for today-only — so we can detect wrong-clock cameras
        // before deciding whether to start ingest or show a picker.
        Task {
            for card in cards {
                // ── Guard: if any picker is already open, queue this card ─────
                let anySheetOpen = await MainActor.run {
                    self.showDatePickerSheet || self.showReelPickerSheet
                }
                if anySheetOpen {
                    await MainActor.run {
                        if !self.cardQueue.contains(where: { $0.card.path == card.path && $0.dateOverride == nil }) {
                            self.cardQueue.append(QueuedIngest(card: card, dateOverride: nil))
                        }
                    }
                    continue
                }

                // ── Phase 1: full card analysis (dates + reel structure + wrong-clock) ─
                // Two attempts with a short gap to handle pre-mounted cards where the
                // exFAT driver hasn't fully initialised yet.
                var analysis = await self.analyzeCard(at: card.path, mode: currentMode)
                if analysis.dates.isEmpty && analysis.reels.isEmpty {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500 ms
                    analysis = await self.analyzeCard(at: card.path, mode: currentMode)
                }

                // ── Tier 1: Wrong-clock detection → reel picker ───────────────
                if analysis.isWrongClock {
                    let todayStr: String = {
                        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd"
                        return fmt.string(from: Date())
                    }()
                    // Pre-select best-guess reel: largest + highest folder name
                    let bestReel = analysis.reels.max { a, b in
                        a.totalBytes != b.totalBytes
                            ? a.totalBytes < b.totalBytes
                            : a.folderName < b.folderName
                    }
                    await MainActor.run {
                        self.reelPickerCard        = card
                        self.reelPickerReels        = analysis.reels
                        self.reelPickerSelected    = bestReel.map { [$0.folderName] } ?? []
                        self.reelPickerDateOverride = todayStr
                        self.showReelPickerSheet    = true
                    }
                    continue  // reel picker handles the rest
                }

                // ── Today-only mode: ingest immediately; shell handles date filter ─
                if currentDateMode == "today" {
                    await MainActor.run { self.startIngest(for: card, destination: destination) }
                    continue
                }

                let dates = analysis.dates

                if !dates.isEmpty {
                    // Dates found — handle without loading state
                    await MainActor.run {
                        if dates.count == 1 {
                            self.startIngest(for: card, dateOverride: dates[0].yyyymmdd, destination: destination)
                        } else {
                            let todayMatches = dates.filter { $0.isToday }.map { $0.yyyymmdd }
                            self.datePickerCards    = [card]
                            self.datePickerDates    = dates
                            self.datePickerSelected = todayMatches.isEmpty
                                ? Set(dates.map { $0.yyyymmdd })
                                : Set(todayMatches)
                            self.showDatePickerSheet = true
                        }
                    }
                    continue
                }

                // ── Phase 2: nothing found yet — show date picker in scanning state ─
                await MainActor.run {
                    self.datePickerCards    = [card]
                    self.datePickerDates    = []
                    self.datePickerSelected = []
                    self.datePickerScanning = true
                    self.showDatePickerSheet = true
                }

                // Phase 2 retry loop
                var retryDates: [CardDateInfo] = []
                var retries = 0
                while retryDates.isEmpty && retries < 30 {
                    let stillOpen = await MainActor.run { self.showDatePickerSheet }
                    guard stillOpen else { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    retryDates = await self.scanCardDates(at: card.path, mode: currentMode)
                    retries += 1
                }

                // ── Phase 3: update sheet with results ────────────────────────
                await MainActor.run {
                    self.datePickerScanning = false
                    guard self.showDatePickerSheet else { return }
                    if retryDates.count == 1 {
                        self.showDatePickerSheet = false
                        self.datePickerCards = []; self.datePickerDates = []; self.datePickerSelected = []
                        self.startIngest(for: card, dateOverride: retryDates[0].yyyymmdd)
                    } else {
                        let todayMatches = retryDates.filter { $0.isToday }.map { $0.yyyymmdd }
                        self.datePickerDates    = retryDates
                        self.datePickerSelected = retryDates.isEmpty ? [] :
                            (todayMatches.isEmpty
                                ? Set(retryDates.map { $0.yyyymmdd })
                                : Set(todayMatches))
                    }
                }
            }
        }
    }

    /// Re-runs the date scan from the warning state inside the sheet.
    /// Called when the user taps "Scan again" after the automatic retries gave up.
    /// Puts the sheet back into scanning state and tries for another 30 seconds.
    @MainActor private func retryDateScan() {
        guard let card = datePickerCards.first else { return }
        let mode = importMode
        datePickerScanning = true
        datePickerDates    = []
        datePickerSelected = []
        Task {
            // Same two-attempt pattern as Phase 1, with 500 ms gap.
            var dates = await self.scanCardDates(at: card.path, mode: mode)
            if dates.isEmpty {
                try? await Task.sleep(nanoseconds: 500_000_000)
                dates = await self.scanCardDates(at: card.path, mode: mode)
            }
            var retries = 0
            while dates.isEmpty && retries < 30 {
                let stillOpen = await MainActor.run { self.showDatePickerSheet }
                guard stillOpen else {
                    // Sheet was cancelled — clear the scanning flag so the next
                    // time the sheet opens it doesn't start in a frozen spinner state.
                    await MainActor.run { self.datePickerScanning = false }
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 s between attempts
                dates = await self.scanCardDates(at: card.path, mode: mode)
                retries += 1
            }
            await MainActor.run {
                self.datePickerScanning = false
                guard self.showDatePickerSheet else { return }
                if dates.count == 1 {
                    self.showDatePickerSheet = false
                    self.datePickerCards = []; self.datePickerDates = []; self.datePickerSelected = []
                    self.startIngest(for: card, dateOverride: dates[0].yyyymmdd)
                } else {
                    let todayMatches = dates.filter { $0.isToday }.map { $0.yyyymmdd }
                    self.datePickerDates    = dates
                    self.datePickerSelected = dates.isEmpty ? [] :
                        (todayMatches.isEmpty ? Set(dates.map { $0.yyyymmdd }) : Set(todayMatches))
                }
            }
        }
    }

    /// The volume device id (st_dev) for a path, or nil if it can't be stat'd. Two
    /// paths on the same mounted volume share st_dev — used to refuse copying a card
    /// onto its own volume (which could fill or overlap the source footage).
    private func volumeDeviceID(of path: String) -> dev_t? {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_dev : nil
    }

    /// True when `destPath` resolves to the same physical volume as the source card.
    private func destinationIsOnCard(card: Volume, destPath: String) -> Bool {
        guard let cardDev = volumeDeviceID(of: card.path),
              let destDev = volumeDeviceID(of: destPath) else { return false }
        return cardDev == destDev
    }

    /// Append a card to the queue unless an equivalent entry is already waiting.
    private func enqueueIfNew(card: Volume, dateOverride: String?,
                             wrongClockDate: String?, reelFilter: [String], reelMulti: Bool,
                             destinationID: UUID? = nil, ignoreDateFilter: Bool = false) {
        if !cardQueue.contains(where: {
            cardIdentifier(for: $0.card) == cardIdentifier(for: card)
                && $0.dateOverride == dateOverride
        }) {
            cardQueue.append(QueuedIngest(card: card, dateOverride: dateOverride,
                                          wrongClockDate: wrongClockDate,
                                          reelFilter: reelFilter, reelMulti: reelMulti,
                                          destinationID: destinationID,
                                          ignoreDateFilter: ignoreDateFilter))
        }
    }

    /// The physical volume a new ingest would write to under the current destination config.
    /// With N-way routing, a queued item may carry its own `destinationID`; resolve that
    /// when present, else the default destination, else the legacy custom/primary prefs.
    private func currentDestRootForScheduling(destinationID: UUID? = nil) -> String? {
        if let did = destinationID, let d = destinations.first(where: { $0.id == did }) {
            return d.path.isEmpty ? nil : d.path
        }
        if let d = defaultDestination { return d.path.isEmpty ? nil : d.path }
        if useCustomDest { return customDestPath.isEmpty ? nil : customDestPath }
        return selectedPrimary?.path
    }

    /// Snapshot of live scheduler state for the pure admission decision.
    private func currentSchedulerSnapshot() -> SchedulerSnapshot {
        SchedulerSnapshot(
            runningDestDevices: activeIngests.values.compactMap { $0.destDeviceID != 0 ? $0.destDeviceID : nil },
            demoActive: demoTask != nil,
            maxConcurrent: maxConcurrentCards)
    }

    /// Admit as many queued cards as the destination-aware scheduler currently allows.
    /// Called whenever a slot frees up. Cards whose target drive is free start immediately
    /// (parallel with other drives); cards waiting on a busy drive stay queued. The safety
    /// counter bounds the loop so a re-queue can never spin it.
    private func drainQueue() {
        var safety = cardQueue.count + 1
        while safety > 0, !cardQueue.isEmpty, demoTask == nil,
              runningCount < max(1, maxConcurrentCards) {
            safety -= 1
            // SPLIT parallelism: don't stall on a head-of-line item whose drive is busy.
            // Scan for the FIRST queued item whose destination drive is currently free and
            // start that one; items bound for a busy drive stay queued (don't break early).
            let snapshot = currentSchedulerSnapshot()
            guard let idx = cardQueue.firstIndex(where: { item in
                let dev = volumeDeviceID(of: currentDestRootForScheduling(destinationID: item.destinationID) ?? "")
                return canAdmitIngest(candidateDestDevice: dev, snapshot: snapshot)
            }) else { break }   // nothing admissible right now
            let item = cardQueue.remove(at: idx)
            let dest = item.destinationID.flatMap { id in destinations.first(where: { $0.id == id }) }
            startIngest(for: item.card, dateOverride: item.dateOverride,
                        wrongClockDate: item.wrongClockDate,
                        reelFilter: item.reelFilter, reelMulti: item.reelMulti,
                        destination: dest,
                        ignoreDateFilter: item.ignoreDateFilter)
        }
    }

    private func startIngest(for card: Volume, dateOverride: String? = nil,
                              wrongClockDate: String? = nil,
                              reelFilter: [String] = [], reelMulti: Bool = false,
                              destination: Destination? = nil,
                              mirrorTargets: [Destination] = [],
                              ignoreManifest: Bool = false,
                              ignoreDateFilter: Bool = false) {
        // Per-card folder name set on the lane (awaiting field), keyed by source path so it
        // survives the async analysis/picker detours without threading through every call site.
        // Resolve once: a per-card label overrides the global custom-card-name pref.
        let perCardLabel: String? = pendingCardLabels[card.path]
        let effectiveCardLabel = resolveCardLabel(perCard: perCardLabel,
                                                  globalEnabled: useCustomCardName, globalName: customCardName)
        // The onboarding demo owns the engine exclusively — queue real cards behind it.
        if demoTask != nil {
            enqueueIfNew(card: card, dateOverride: dateOverride,
                         wrongClockDate: wrongClockDate, reelFilter: reelFilter, reelMulti: reelMulti,
                         destinationID: destination?.id, ignoreDateFilter: ignoreDateFilter)
            return
        }

        // ── Guard: never start a SECOND in-flight ingest for a card already being copied.
        // Two routing paths can race to start the same source — e.g. on the Auto-Ingest
        // ON-flip, drainAwaiting() routes the parked card and the immediately-following
        // forceRescan tries to route it again. A duplicate launch would run two cardcopy
        // processes against one card and corrupt progress/footage accounting. Match on
        // source volume UUID, falling back to mount PATH for UUID-less exFAT/FAT cards
        // (never the bare name — two "Untitled" cards mount at distinct paths). A .done/
        // .failed lane does NOT block, so a deliberate re-run of a finished card still works.
        let inFlight: Set<IngestPhase> = [.idle, .scanning, .building, .copying, .verifying, .finalizing]
        let alreadyIngesting = activeIngests.values.contains { ing in
            guard inFlight.contains(ing.phase) else { return false }
            if let u = card.volumeUUID, let iu = ing.volumeUUID { return u == iu }
            return !card.path.isEmpty && ing.sourcePath == card.path
        }
        if alreadyIngesting {
            appendLog("Skipped duplicate ingest start for \(card.name) — already copying.\n")
            return
        }

        // ── Resolve the destination for THIS card ──────────────────────────────────
        // Explicit per-card destination wins; otherwise the configured default. When NO
        // destination is configured at all (untouched fresh-list user), fall back to the
        // legacy custom-dest / primary-SSD prefs so behavior is byte-identical to before.
        let resolvedDestRoot: String
        let resolvedProjectRoot: String
        let useCustomDestForThisCard: Bool
        let resolvedSubfolder: String   // per-destination subfolder (SSD), else global/Default
        // The project folder NAME actually passed to the shell as --project. MUST be the
        // resolved per-destination value (same as resolvedProjectRoot's leaf), NOT the raw
        // global projectName — otherwise footage lands under a different folder than the UI
        // shows for a destination whose projectFolder differs from the global project.
        let resolvedProjectName: String
        if let dest = destination ?? defaultDestination {
            if dest.isCustomFolder {
                var isDestDir: ObjCBool = false
                guard !dest.path.isEmpty,
                      FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDestDir),
                      isDestDir.boolValue else {
                    statusText = "Custom destination folder not found."
                    return
                }
                useCustomDestForThisCard = true
                resolvedDestRoot    = dest.path
                resolvedProjectRoot = dest.path
                resolvedProjectName = ""          // custom mode emits --dest-root, no --project
                resolvedSubfolder   = "Default"   // custom mode ignores subfolder (footage → dest/date)
            } else {
                // Per-destination project folder wins; empty falls back to the global project.
                let trimmedProject = resolveProjectFolder(destProject: dest.projectFolder, globalProject: projectName)
                guard !trimmedProject.isEmpty else {
                    statusText = "Project name required."
                    return
                }
                useCustomDestForThisCard = false
                resolvedDestRoot    = dest.path
                resolvedProjectRoot = "\(dest.path)/\(trimmedProject)"
                resolvedProjectName = trimmedProject   // shell --project = the per-dest project
                resolvedSubfolder   = dest.subfolder.isEmpty ? "Default" : dest.subfolder
            }
        } else if useCustomDest {
            // Legacy fallback — no Destination list configured. Custom folder.
            var isDestDir: ObjCBool = false
            guard !customDestPath.isEmpty,
                  FileManager.default.fileExists(atPath: customDestPath, isDirectory: &isDestDir),
                  isDestDir.boolValue else {
                statusText = "Custom destination folder not found."
                return
            }
            useCustomDestForThisCard = true
            resolvedDestRoot    = customDestPath
            resolvedProjectRoot = customDestPath
            resolvedProjectName = ""          // custom mode emits --dest-root, no --project
            resolvedSubfolder   = "Default"
        } else {
            // Legacy fallback — primary SSD + project.
            guard let primary = selectedPrimary else {
                statusText = "Select a primary SSD."
                return
            }
            let trimmedProject = projectName.trimmingCharacters(in: .whitespaces)
            guard !trimmedProject.isEmpty else {
                statusText = "Project name required."
                return
            }
            useCustomDestForThisCard = false
            resolvedDestRoot    = primary.path   // passed as --primary to shell
            resolvedProjectRoot = "\(primary.path)/\(trimmedProject)"
            resolvedProjectName = trimmedProject   // shell --project = the resolved project
            resolvedSubfolder   = selectedSubfolder   // legacy global subfolder
        }

        // Safety gate: never copy a card onto its own volume. If the destination
        // resolves to the same physical volume as the source card, the copy could
        // fill the card or overlap the source files. Refuse before launching.
        if destinationIsOnCard(card: card, destPath: resolvedDestRoot) {
            statusText = "Destination is on the source card — choose a different drive."
            ingestAlertTitle   = "Destination is the source card"
            ingestAlertMessage = "The chosen destination is on \(card.name) itself. Pick a separate drive so footage isn't copied onto the card it came from."
            showIngestAlert    = true
            return
        }

        // Destination-aware concurrency gate: start now only if a slot is free and no other
        // ingest is already writing to this physical volume; otherwise queue. Cards bound for
        // DIFFERENT drives run in parallel; cards to the SAME drive stay sequential (today's
        // behavior). Computed here because it needs the resolved destination above.
        let candidateDestDevice = volumeDeviceID(of: resolvedDestRoot)
        if !canAdmitIngest(candidateDestDevice: candidateDestDevice, snapshot: currentSchedulerSnapshot()) {
            enqueueIfNew(card: card, dateOverride: dateOverride,
                         wrongClockDate: wrongClockDate, reelFilter: reelFilter, reelMulti: reelMulti,
                         destinationID: destination?.id, ignoreDateFilter: ignoreDateFilter)
            return
        }

        // ── N-way mirror targets ───────────────────────────────────────────────────
        // Per-card routing: a card copies ONLY to its routed destination (or the default).
        // Any explicitly-passed `mirrorTargets` are still honored (reserved for an optional
        // future per-card backup), but there is no global "mirror every card to all drives".
        // Targets that land on the source card or duplicate the primary destination are skipped.
        // When the destination list is empty (legacy), fall back to the dual-dest secondary.
        let resolvedDest = destination ?? defaultDestination
        var mirrorPaths: [String] = []
        if resolvedDest != nil {
            let candidates: [Destination] = mirrorTargets
            for m in candidates {
                let (mRoot, _) = resolvedPaths(for: m)
                if mRoot == resolvedDestRoot { continue }
                if destinationIsOnCard(card: card, destPath: mRoot) { continue }
                if mirrorPaths.contains(mRoot) { continue }
                mirrorPaths.append(mRoot)
            }
        } else if dualDestEnabled, let secondary = selectedSecondary,
                  !destinationIsOnCard(card: card, destPath: secondary.path) {
            // Legacy single-/dual-dest fallback (no Destination list configured).
            mirrorPaths.append(secondary.path)
        }

        guard let scriptPath = Bundle.main.path(forResource: "CardRunner", ofType: "sh") else {
            statusText = "Could not find CardRunner.sh in app bundle."
            return
        }

        // Allocate a unique ID for this ingest
        let processID = UUID()
        activeIngests[processID] = ActiveIngest(
            cardName: card.name,
            cameraModel: card.cameraModel,
            projectRoot: resolvedProjectRoot
        )
        // Lane display + the folder this card copied under (same resolved value as --cardlabel).
        // cardLabel is retained so a during-transfer rename knows the original folder name.
        activeIngests[processID]?.friendlyName = effectiveCardLabel
        activeIngests[processID]?.cardLabel = effectiveCardLabel
        // Single-use: consume the per-card label now that THIS ingest has committed (past all
        // early-return guards). Prevents a stale entry from shadowing the global pref for a
        // DIFFERENT card later mounted at the same path (e.g. two "Untitled" cards).
        pendingCardLabels.removeValue(forKey: card.path)
        activeIngests[processID]?.volumeUUID = card.volumeUUID
        activeIngests[processID]?.sourcePath = card.path
        activeIngests[processID]?.runMode = importMode
        activeIngests[processID]?.destinationID = (destination ?? defaultDestination)?.id
        // Record the destination volume so the scheduler keeps the next card off this drive.
        activeIngests[processID]?.destDeviceID = candidateDestDevice ?? 0

        // Clear stale summary card
        lastNewFiles        = 0
        lastAvgMBps         = 0
        lastDurationSec     = 0
        lastDestPath        = ""
        lastReportPath      = ""
        showCompletionState = false

        // Pass the real app version so it appears correctly in log files.
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        // Build the exact CardRunner.sh argv via the pure, unit-tested builder. Per-card
        // routing + N-way mirror are folded in via destRoot / secondaryPaths; everything
        // else is the same configuration the legacy inline builder produced.
        let args = buildIngestArgs(IngestArgsConfig(
            scriptPath: scriptPath,
            appVersion: appVersion,
            cardPath: card.path,
            useCustomDest: useCustomDestForThisCard,
            destRoot: resolvedDestRoot,
            projectRoot: resolvedProjectRoot,
            projectName: resolvedProjectName,   // resolved per-dest project — NOT the raw global
            selectedSubfolder: resolvedSubfolder,   // per-destination subfolder (SSD) — see resolution above
            // Per-card folder name (--cardlabel): see resolveCardLabel. Empty → no --cardlabel.
            useCustomCardName: !effectiveCardLabel.isEmpty,
            customCardName: effectiveCardLabel,
            ignoreManifest: ignoreManifest,
            dryRun: dryRun,
            wrongClockDate: wrongClockDate,
            reelFilter: reelFilter,
            reelMulti: reelMulti,
            dateOverride: dateOverride,
            // tier-0 "Ingest all" bypasses the current filter for this run (else it would
            // re-apply the same filter, exclude everything again, and re-prompt in a loop).
            dateFilterMode: ignoreDateFilter ? "all" : dateFilterMode,
            dateFilterFrom: dateFilterFrom,
            dateFilterTo: dateFilterTo,
            dateFilterSubMode: dateFilterSubMode,
            autoEject: autoEject,
            fullVerifyEnabled: fullVerifyEnabled,
            verifyTransfer: verifyTransfer,
            transferReportEnabled: transferReportEnabled,
            secondaryPaths: mirrorPaths,
            renameOnIngestEnabled: renameOnIngestEnabled,
            renameTemplate: renameTemplate,
            winterOlympicsMode: winterOlympicsMode,
            olympicsCode: olympicsCode,
            scaffoldEnabled: scaffoldEnabled,
            scaffoldFolderList: scaffoldFolderList,
            copyXML: copyXML,
            importMode: importMode,
            includeProxies: includeProxies,
            ingestOrder: ingestOrder,
            dateFolderFormat: dateFolderFormat,
            broadcastDayFolders: broadcastDayFolders,
            dayStartHour: dayStartHour,
            finderTagEnabled: finderTagEnabled,
            finderTagColor: finderTagColor))

        appendLog("=== Starting ingest for card: \(card.name) ===\n")   // banner always written (v3 log has no showLog flag)
        statusText = "Ingesting \(card.name)…"
        runningCount += 1
        // Seed the sparkline immediately so the Canvas (which needs ≥2 points) has data
        // the moment copying starts, instead of waiting for the 1-second timer to build up
        // a window. Two near-zero points give the line something to draw from; real
        // samples replace them within the first couple of seconds.
        if speedHistory.isEmpty { speedHistory = [0, 0] }
        AudioEngine.shared.cardDetected()
        AudioEngine.shared.transferStarted()
        HapticEngine.shared.start()

        // Sentry breadcrumb — appears in the timeline on any subsequent crash
        SentrySDK.addBreadcrumb({
            let bc = Breadcrumb(level: .info, category: "ingest")
            bc.message = "Ingest started: \(card.name)"
            bc.data = ["card": card.name, "project": projectName,
                       "primary": selectedPrimary?.name ?? "none",
                       "dual_dest": dualDestEnabled]
            return bc
        }())
        // Update Sentry scope so every event shows current card/project
        SentrySDK.configureScope { scope in
            scope.setTag(value: card.name,    key: "current_card")
            scope.setTag(value: projectName,  key: "project")
        }
        let startDateStr: String = {
            let f = DateFormatter()
            f.dateFormat = strftimeToICU(dateFolderFormat)
            return f.string(from: Date())
        }()
        // Derive readable path info for notifications and checkpoint (works in both modes)
        let checkpointPrimaryPath: String
        let checkpointProjectName: String
        if useCustomDestForThisCard {
            checkpointPrimaryPath = resolvedProjectRoot
            checkpointProjectName = URL(fileURLWithPath: resolvedProjectRoot).lastPathComponent
        } else {
            checkpointPrimaryPath = resolvedDestRoot
            checkpointProjectName = resolvedProjectName   // match the resolved per-dest project
        }

        let startSub = (resolvedSubfolder == "Default" || resolvedSubfolder.isEmpty) ? "clips" : resolvedSubfolder
        let startRelPath = "\(checkpointProjectName)/\(startSub)/\(startDateStr)"
        notifyIfBackgrounded(title: "Transfer started", body: "Transferring files to \(startRelPath)")

        // Write crash-recovery checkpoint BEFORE launching the process.
        // It will be deleted in the termination handler on clean exit.
        let checkpoint = IngestCheckpoint(
            id:               processID,
            cardPath:         card.path,
            cardName:         card.name,
            primaryPath:      checkpointPrimaryPath,
            projectName:      checkpointProjectName,
            subfolder:        resolvedSubfolder == "Default" ? "" : resolvedSubfolder,   // per-destination
            cardLabel:        effectiveCardLabel,   // the per-card label this ingest actually ran with
            dateFormat:       dateFolderFormat,
            finderTagColor:   finderTagEnabled ? finderTagColor : "",
            mode:             importMode,
            // First mirror target (if any) — the crash-recovery cleanup keys off this path.
            secondaryPath:    mirrorPaths.first ?? "",
            verifyEnabled:    verifyTransfer || fullVerifyEnabled,
            newFiles:         0,
            startedAt:        Date(),
            // Capture the full arg list (minus the script path, re-derived on resume)
            // so a resumed ingest routes footage identically to the original run.
            resumeArgs:       Array(args.dropFirst())
        )
        saveCheckpoint(checkpoint)

        launchIngestProcess(card: card, processID: processID,
                            args: args, checkpointID: processID)
    }

    // MARK: - Demo ingest (no card or SSD required)

    /// Simulates a complete ingest entirely in Swift — no shell script, no card, no SSD.
    /// Exercises every UI state: scan → queued → copying → verify → completion panel → history.
    private func runDemoIngest(fromOnboarding: Bool = false) {
        guard runningCount == 0 else { return }  // don't stack on top of a real ingest

        let demoCard = Volume(name: "DEMO_A7IV", path: "/Volumes/DEMO_A7IV", cameraModel: "Sony A7 IV")
        // Mirror status into onboarding Screen 3 if it's currently visible
        onboardingDemoStatus = "Copying \(mediaLabel) from DEMO_A7IV…"
        let processID = UUID()

        // Fake totals: 47 clips, 12.3 GB
        let totalFiles  = 47
        let totalBytes: Int64 = 13_200_000_000   // ~12.3 GB
        let fakeDestPath = (selectedPrimary?.path ?? "/Volumes/SSD") + "/" +
                           (projectName.isEmpty ? "DemoProject" : projectName) + "/clips"

        var ingest = ActiveIngest(cardName: demoCard.name)
        ingest.cameraModel    = "Sony A7 IV"
        ingest.totalFiles     = totalFiles
        ingest.mediaTotal     = totalFiles
        ingest.newFiles       = totalFiles
        ingest.totalBytesNew  = totalBytes
        ingest.phase          = .copying
        ingest.destPath       = fakeDestPath

        activeIngests[processID] = ingest
        runningCount = 1
        statusText   = "Copying from DEMO_A7IV…"

        // Turn on auto-ingest visually so the ring lights up — but NEVER for the ONBOARDING demo:
        // flipping the real `autoIngest` fires onChange → drainAwaiting + scan, which would START a
        // real parked card, and the demo's end would then CANCEL it (the "Transfer stopped …
        // Untitled not ingested" alert). The onboarding demo must never touch real ingest state.
        let wasAutoIngest = autoIngest
        if !fromOnboarding { autoIngest = true }

        demoTask = Task { @MainActor in
            let stepCount = 60          // ~6 seconds at 100ms ticks
            let mbps: Double = 95       // fake 95 MB/s

            for step in 1...stepCount {
                if Task.isCancelled {
                    self.demoTask = nil; self.activeIngests.removeAll()
                    self.runningCount = 0; self.autoIngest = wasAutoIngest
                    AudioEngine.shared.transferCancelled(); return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                if Task.isCancelled {
                    self.demoTask = nil; self.activeIngests.removeAll()
                    self.runningCount = 0; self.autoIngest = wasAutoIngest
                    AudioEngine.shared.transferCancelled(); return
                }

                var ing = self.activeIngests[processID] ?? ingest
                let progress = Double(step) / Double(stepCount)
                ing.completedFilesBytes = Int64(Double(totalBytes) * progress)
                ing.completedFiles      = Int(Double(totalFiles) * progress)
                ing.currentFileName     = "A7IV_\(String(format: "%04d", ing.completedFiles + 1)).MP4"
                ing.liveMBps            = mbps + Double.random(in: -8...8)
                ing.phase               = .copying
                self.activeIngests[processID] = ing

                // Feed the sparkline
                self.speedHistory.append(ing.liveMBps)
                if self.speedHistory.count > kSpeedHistoryMax { self.speedHistory.removeFirst() }
            }
            self.demoTask = nil

            // ── Completion ──────────────────────────────────────────────────
            self.runningCount        = 0
            self.autoIngest          = wasAutoIngest
            self.lastNewFiles        = totalFiles
            self.lastAvgMBps         = Int(mbps)
            self.lastDurationSec     = 6
            self.lastDestPath        = fakeDestPath
            self.lastMediaLabel      = self.mediaLabel
            self.showCompletionState = true
            self.activeIngests.removeValue(forKey: processID)
            self.statusText = wasAutoIngest ? "Searching for cards…" : "Waiting for cards…"

            // Demo ingest is purely visual — do NOT save to historyEntries or
            // call saveHistory().  Saving a fake entry would inflate session GB
            // stats for real users (and stack up on repeated onboarding runs).
            self.onboardingDemoStatus = "Transfer complete. \(totalFiles) \(self.mediaLabel) · 6s · \(Int(mbps)) MB/s avg"
            self.v3CelebrationTrigger += 1   // preview the v3 celebration (Run UI Demo → pick a style → watch)
            AudioEngine.shared.transferComplete()
            // Demo released the engine — start any real cards queued behind it. NOT during onboarding:
            // the onboarding demo must stay fully isolated (no real ingest may start).
            if !fromOnboarding { self.drainQueue() }
        }
    }

    /// Shared process-launch infrastructure used by both startIngest and resumeFromCheckpoint.
    /// Sets up pipes, progress parsing, and the termination handler, then runs the script.
    private func launchIngestProcess(card: Volume, processID: UUID,
                                     args: [String], checkpointID: UUID) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe
        // Detach the ingest shell from any inherited controlling terminal. When the app is
        // launched FROM a terminal (e.g. a dev run passing CR_V3_PREVIEW), the child shell
        // would otherwise inherit that tty as stdin; the first `read` in a background process
        // group then triggers SIGTTIN and the shell STOPS (state T) — cardcopy never runs and
        // the transfer hangs at 0%. /dev/null stdin makes this impossible regardless of launch.
        process.standardInput  = FileHandle.nullDevice

        // stderr handler — log only, never parsed as progress data.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            DispatchQueue.main.async {
                if self.showLog {
                    self.appendLog("[err] \(text)")
                }
            }
        }

        // Buffered line reader. `availableData` arrives on arbitrary byte boundaries,
        // so a protocol line (or even the word "PROGRESS_META") can straddle two reads.
        // We accumulate bytes and only ever hand COMPLETE lines to the parser. Splitting
        // on the newline byte (0x0A) is UTF-8-safe — newline is never part of a multibyte
        // sequence. Lines carrying terminal state or a failure signal are flushed
        // immediately and are NEVER dropped; the high-frequency progress lines ride a
        // 0.15s coalescing throttle, but throttled lines are RETAINED in `pending` and
        // flushed on the next tick rather than discarded. Foundation fires a single
        // pipe's handler serially, so these captured vars need no lock.
        var lineResidual = Data()
        var pending      = ""
        var bgLastDispatch: Date = .distantPast

        // Lines that must reach the parser immediately and must never be throttled away
        // (terminal phase, copy/verify failures, space/unmount aborts, summary/meta/dest).
        func mustFlush(_ line: Substring) -> Bool {
            return line.contains("PROGRESS_META")
                || line.contains("PROGRESS_SUMMARY")
                || line.contains("PROGRESS_DEST")
                || line.hasPrefix("PHASE ")
                || line.hasPrefix("COPY_ERROR")
                || line.hasPrefix("RSYNC_ERROR")
                || line.hasPrefix("VERIFY_FAIL")
                || line.hasPrefix("SECONDARY_ERROR")
                || line.hasPrefix("DEST_INSUFFICIENT")
                || line.hasPrefix("DEST_VANISHED")
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            lineResidual.append(data)

            // Carve out all complete lines (up to & including the last newline) and keep
            // the trailing partial in `lineResidual` for the next read.
            guard let lastNL = lineResidual.lastIndex(of: 0x0A) else { return }
            let completeData = lineResidual.subdata(in: lineResidual.startIndex..<lineResidual.index(after: lastNL))
            lineResidual = lineResidual.subdata(in: lineResidual.index(after: lastNL)..<lineResidual.endIndex)
            guard let completeStr = String(data: completeData, encoding: .utf8), !completeStr.isEmpty else { return }

            var forceNow = false
            for line in completeStr.split(separator: "\n", omittingEmptySubsequences: true) {
                if mustFlush(line) { forceNow = true; break }
            }
            pending += completeStr

            if !forceNow {
                let now = Date()
                guard now.timeIntervalSince(bgLastDispatch) >= 0.15 else { return }   // keep buffering; flush next tick
            }
            bgLastDispatch = Date()
            let flush = pending
            pending = ""

            DispatchQueue.main.async {
                self.parseProgress(from: flush, processID: processID)
                DockProgress.update(self.totalProgress)

                // Only grow the in-app log string when the Log panel is visible.
                if self.showLog {
                    self.appendLog(flush)
                }
            }
        }

        process.terminationHandler = { proc in
            // Stop reading from both pipes before touching any shared state.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            // Final drain: pull any bytes still buffered in the pipe and flush the
            // residual + any throttled-but-unflushed lines, so a terminal line
            // (PHASE failed / VERIFY_FAIL / PROGRESS_SUMMARY) that landed in the last
            // read is parsed BEFORE the success-determination block below runs. Both
            // dispatches target the main queue, so FIFO ordering guarantees the parse
            // is applied first.
            let tail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if !tail.isEmpty { lineResidual.append(tail) }
            if let leftover = String(data: lineResidual, encoding: .utf8), !leftover.isEmpty {
                pending += leftover
            }
            lineResidual = Data()
            if !pending.isEmpty {
                let finalFlush = pending
                pending = ""
                DispatchQueue.main.async {
                    self.parseProgress(from: finalFlush, processID: processID)
                }
            }

            // Capture thread-safe values from the exited process here on the termination
            // thread. All @State access (cancelledProcessIDs, deleteCheckpoint, etc.) must
            // happen on main — reading them here is a data race.
            let exitStatus = proc.terminationStatus
            let signalled  = (proc.terminationReason == .uncaughtSignal)

            DispatchQueue.main.async {
                // cancelledProcessIDs is @State — only safe on main.
                // process.terminate() sends SIGTERM; the shell's TERM trap exits normally,
                // so terminationReason is .exit, not .uncaughtSignal — use our own set.
                let wasCancelled = self.cancelledProcessIDs.contains(processID) || signalled
                // Delete the checkpoint on any clean exit or user-cancel.
                // The checkpoint persists only for app/Mac crashes (resume on relaunch).
                if exitStatus == 0 || wasCancelled {
                    self.deleteCheckpoint(id: checkpointID)
                }
                self.activeProcesses.removeValue(forKey: processID)
                self.runningCount = max(0, self.runningCount - 1)
                // Release the App-Nap suppression token for this ingest.
                if let act = self.ingestActivities.removeValue(forKey: processID) {
                    ProcessInfo.processInfo.endActivity(act)
                }

                if wasCancelled {
                    self.cancelledProcessIDs.remove(processID)   // consumed — clean up
                    // Process has exited — safe to wipe its staging dir now.
                    // (cancelAllIngests deferred this to avoid a delete-under-write race.)
                    if let root = self.activeIngests[processID]?.projectRoot, !root.isEmpty {
                        self.cleanupPartialDirs(in: root)
                    }
                    // Save a failure record so the UI shows a persistent "not ingested" warning
                    if let ing = self.activeIngests[processID], ing.newFiles > 0 || ing.totalBytesNew > 0 {
                        let mb = Int(Double(ing.totalBytesNew) / 1_048_576)
                        let rec = FailedIngestRecord(
                            id: UUID(), cardName: card.name,
                            volumeUUID: card.volumeUUID,
                            friendlyName: ing.friendlyName,
                            projectName: self.projectName,
                            failedAt: Date(),
                            filesToCopy: ing.newFiles,
                            mbToCopy: mb > 0 ? mb : 0,
                            reason: "Cancelled"
                        )
                        self.saveFailedRecord(rec)
                    }
                    // Transfer was killed by the user — discard partial state,
                    // skip history entry and alert, just reset the UI cleanly.
                    self.activeIngests.removeValue(forKey: processID)
                    // Stopping halts the whole session. Don't SILENTLY drop other queued
                    // cards — those represent pending footage the operator may have already
                    // pulled. Clear the queue but tell them exactly which cards were not
                    // ingested so they can re-insert them.
                    let droppedNames = self.cardQueue.map { $0.card.name }
                    self.cardQueue.removeAll()
                    // Never surface an ingest alert while the onboarding walkthrough is up (the demo is
                    // now fully isolated, so this shouldn't fire during onboarding — belt-and-suspenders).
                    if !droppedNames.isEmpty && !self.showOnboarding {
                        let list = droppedNames.joined(separator: ", ")
                        self.ingestAlertTitle   = "Transfer stopped"
                        self.ingestAlertMessage = "\(droppedNames.count) queued card\(droppedNames.count == 1 ? "" : "s") were not ingested: \(list). Re-insert to ingest."
                        self.showIngestAlert    = true
                    }
                    AudioEngine.shared.transferCancelled()
                    if self.runningCount == 0 {
                        DockProgress.clear()
                        self.statusText = self.autoIngest ? "Searching for cards…" : "Waiting for cards…"
                    }
                    return
                }
                self.appendLog("=== Finished ingest for card: \(card.name) ===\n\n")   // always written (v3 log)

                // Pull this ingest's record, commit the last in-flight file, then remove it
                // so the aggregate computed properties automatically exclude it.
                var ingest = self.activeIngests.removeValue(forKey: processID) ?? ActiveIngest(cardName: card.name)
                if ingest.currentFileSize > 0 { ingest.completedFiles += 1 }
                ingest.completedFilesBytes += ingest.currentFileSize
                ingest.currentFileSize = 0
                ingest.currentIntraFileBytes = 0

                // Fallback: if the script didn't emit PROGRESS_SUMMARY, compute duration/speed here.
                var durationSec = ingest.durationSec
                if durationSec == 0 {
                    durationSec = max(1, Int(Date().timeIntervalSince(ingest.ingestStartTime)))
                }
                var avgMBps = ingest.avgMBps
                if avgMBps == 0, durationSec > 0, ingest.doneBytes > 0 {
                    // Fallback fires only when PROGRESS_SUMMARY never arrived (a failed or
                    // aborted run). Base the speed on bytes ACTUALLY copied (doneBytes),
                    // never the planned total — otherwise a run that copied nothing reports
                    // a bogus average computed from bytes that never moved.
                    let mb = Double(ingest.doneBytes) / 1_048_576.0
                    avgMBps = max(0, Int(mb / Double(durationSec)))
                }

                let newFiles  = ingest.newFiles
                let skipped   = max(ingest.mediaTotal - newFiles, 0)
                let destPath  = ingest.destPath

                // Update the shared "Last ingest summary" state for the UI panel.
                self.lastNewFiles        = newFiles
                self.lastAvgMBps         = avgMBps
                self.lastDurationSec     = durationSec
                self.lastDestPath        = destPath
                self.lastMediaLabel      = self.mediaLabel
                self.lastCollisionRenames = ingest.collisionRenames

                // Authoritative failure gate — now a pure, unit-tested function
                // (evaluateIngestOutcome). The rule it enforces: a transfer is a failure
                // if the script exited non-zero (PHASE failed → return 1) OR any copy/verify
                // error line was parsed (hasCopyError). Success is NEVER inferred from
                // free-text status. This is the single source of truth for the completion
                // ring, sound, status, and history.
                let outcome = evaluateIngestOutcome(exitStatus: exitStatus, ingest: ingest)
                let didFail          = outcome.didFail
                let bytesTransferred = outcome.bytesTransferred
                let filesTransferred = outcome.filesTransferred
                let statusString     = outcome.status.rawValue

                // Show the green next-step confidence panel ONLY on a real, clean copy.
                if newFiles > 0 && !didFail { self.showCompletionState = true }

                // Update failed ingest records based on outcome
                // Record a failure WHENEVER the outcome failed — even with newFiles==0 (an early
                // crash / mount-loss before any file copied is MORE dangerous, not less). Without
                // this the persistent "do not format" warning would never appear for abort failures.
                if didFail {
                    let mb = Int(Double(ingest.totalBytesNew) / 1_048_576)
                    let rec = FailedIngestRecord(
                        id: UUID(), cardName: card.name,
                        volumeUUID: card.volumeUUID,
                        friendlyName: ingest.friendlyName,
                        projectName: self.projectName,
                        failedAt: Date(),
                        filesToCopy: newFiles,
                        mbToCopy: mb > 0 ? mb : 0,
                        reason: "Error"
                    )
                    self.saveFailedRecord(rec)
                } else if statusString == "Completed" {
                    // Apply a folder rename the operator typed DURING the copy (safety valve).
                    // Done here — after the process has fully exited and released all handles —
                    // so it can never split an in-progress copy. Conflict-safe; footage already
                    // verified before this point.
                    if let newLabel = ingest.pendingRename {
                        // The lane entry was already removed at completion (10966), so there's
                        // nothing to update in activeIngests here — the rename operates on the
                        // verified folder on disk via the local `ingest` snapshot.
                        self.applyPendingFolderRename(destPath: ingest.destPath,
                                                      oldLabel: ingest.cardLabel, newLabel: newLabel)
                    }
                    self.clearFailedRecords(cardName: card.name, volumeUUID: card.volumeUUID,
                                            friendlyName: ingest.friendlyName, projectName: self.projectName)
                    // Persist card nickname: if the operator labelled this card, remember the
                    // UUID → label mapping so future inserts auto-fill the field.
                    if self.useCustomCardName, let uuid = card.volumeUUID {
                        let nickname = self.customCardName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !nickname.isEmpty {
                            self.knownCardNicknames[uuid] = nickname
                            self.persistCardNicknames()
                        }
                    }
                }

                // Sentry breadcrumb — ingest outcome
                SentrySDK.addBreadcrumb({
                    let bc = Breadcrumb(
                        level: statusString == "Error" ? .error : .info,
                        category: "ingest"
                    )
                    bc.message = "Ingest finished: \(card.name) — \(statusString)"
                    bc.data = ["new_files": newFiles, "avg_mbps": avgMBps,
                               "duration_sec": durationSec, "exit_code": exitStatus]
                    return bc
                }())
                if statusString == "Error" {
                    SentrySDK.capture(message: "Ingest error: \(card.name)") { scope in
                        scope.setLevel(.error)
                        scope.setTag(value: card.name,   key: "card")
                        scope.setTag(value: projectName, key: "project")
                        scope.setExtra(value: self.statusText, key: "status_text")
                        scope.setExtra(value: exitStatus, key: "exit_code")
                    }
                }

                let entry = IngestHistoryEntry(
                    cardName: card.name,
                    status: statusString,
                    newFiles: newFiles,
                    skippedFiles: skipped,
                    avgMBps: avgMBps,
                    durationSec: durationSec,
                    destPath: destPath,
                    mediaLabel:            self.mediaLabel,
                    totalBytesTransferred: bytesTransferred,
                    skipManifest:          ingest.skipManifest,
                    skipDestExists:        ingest.skipDestExists,
                    skipTodayFilter:       ingest.skipTodayFilter,
                    skipWrongMode:         ingest.skipWrongMode,
                    skipProxy:             ingest.skipProxy,
                    skipMissing:           ingest.skipMissing
                )
                self.historyEntries.insert(entry, at: 0)
                self.saveHistory()   // saveHistory trims to 24 h window
                self.lastIngestSummary = entry

                // Accumulate into all-time stats (uses actual byte count if available,
                // falls back to avgMBps × durationSec approximation)
                let newMB = bytesTransferred > 0
                    ? Double(bytesTransferred) / 1_048_576.0
                    : Double(avgMBps) * Double(durationSec)
                self.accumulateAllTimeStats(newFiles: filesTransferred, newMB: newMB,
                                            durationSec: durationSec, avgMBps: avgMBps)

                // Popup / notification for this specific card
                // Build a clean relative destination string for notifications / alerts
                let relDest: String = {
                    guard !destPath.isEmpty else { return "your destination folder" }
                    if let primary = self.selectedPrimary,
                       destPath.hasPrefix(primary.path) {
                        return String(destPath.dropFirst(primary.path.count).drop(while: { $0 == "/" }))
                    }
                    // Fallback: last 3 path components
                    let parts = destPath.split(separator: "/")
                    return parts.suffix(3).joined(separator: "/")
                }()

                // Build a human-readable skip explanation for alerts + notifications
                let skipSummaryLine: String = {
                    var parts: [String] = []
                    if ingest.skipManifest    > 0 { parts.append("\(ingest.skipManifest) already copied") }
                    if ingest.skipDestExists  > 0 { parts.append("\(ingest.skipDestExists) already at destination") }
                    if ingest.skipTodayFilter > 0 { parts.append("\(ingest.skipTodayFilter) filtered by today-only") }
                    if ingest.skipWrongMode   > 0 { parts.append("\(ingest.skipWrongMode) wrong mode (\(importMode == "video" ? "photo" : "video") files)") }
                    if ingest.skipProxy       > 0 { parts.append("\(ingest.skipProxy) proxy/sub files") }
                    if ingest.skipMissing     > 0 { parts.append("\(ingest.skipMissing) missing at copy time — NOT copied") }
                    guard !parts.isEmpty else { return "" }
                    return "\(ingest.totalSkipped) skipped: " + parts.joined(separator: ", ")
                }()

                if didFail {
                    // Copy or verify failed. Never play the success sound or completion
                    // flash, and tell the operator explicitly NOT to format the card —
                    // the shell kept it mounted so a re-insert will retry the missing files.
                    AudioEngine.shared.verifyFailed()
                    let failBody = "\(card.name) was NOT fully copied/verified. The card was kept mounted — re-insert it to retry. Do not format the card."
                    if NSApplication.shared.isActive {
                        self.ingestAlertTitle   = "Transfer failed — footage not confirmed"
                        self.ingestAlertMessage = failBody
                        self.showIngestAlert    = true
                    } else {
                        self.notifyIfBackgrounded(title: "Transfer failed — do not format card", body: failBody)
                    }
                } else if newFiles == 0 {
                    AudioEngine.shared.upToDate()
                    // Tier 0: date filter excluded ALL clips and none were previously ingested
                    // — show a prompt instead of silently claiming the card is "up to date".
                    let allFilteredByDate = ingest.skipTodayFilter > 0
                        && ingest.skipManifest == 0 && ingest.skipDestExists == 0
                    if allFilteredByDate && NSApplication.shared.isActive {
                        self.tier0Card          = card
                        self.tier0SkippedCount  = ingest.skipTodayFilter
                        self.showTier0Prompt    = true
                    } else if ingest.skipManifest > 0 && NSApplication.shared.isActive {
                        // The MANIFEST blocked the copy (this card's files were already offloaded
                        // on a previous run). Offer a deliberate re-ingest to THIS destination.
                        self.manifestReingestCard   = card
                        self.manifestReingestDestID = ingest.destinationID
                        self.manifestReingestCount  = ingest.skipManifest
                        self.showManifestReingest   = true
                    } else {
                        let alertBody = skipSummaryLine.isEmpty
                            ? "No new files found on \(card.name)."
                            : "No new files — \(skipSummaryLine)."
                        if NSApplication.shared.isActive {
                            self.ingestAlertTitle   = "Already up to date"
                            self.ingestAlertMessage = alertBody
                            self.showIngestAlert    = true
                        } else {
                            self.notifyIfBackgrounded(title: "Already up to date", body: alertBody)
                        }
                    }
                } else {
                    AudioEngine.shared.transferComplete()
                    // Legacy UI plays its own (invisible-under-v3) flash; v3 celebrates ONCE per batch
                    // when the ring goes green (see v3MaybeCelebrate) — mark that a real copy landed.
                    // NOT under dry-run: "pending" means REAL footage landed, and a dry-run copies
                    // nothing, so it must never arm the celebration (airtight, not just fire-time-guarded).
                    if !self.dryRun { self.v3PendingCelebration = true }
                    let alertBody: String = {
                        var msg = "Copied \(newFiles) file\(newFiles == 1 ? "" : "s") → \(relDest)"
                        if !skipSummaryLine.isEmpty { msg += "\n\(skipSummaryLine)" }
                        return msg
                    }()
                    let notifBody: String = {
                        var msg = "Copied \(newFiles) files → \(relDest)"
                        if !skipSummaryLine.isEmpty { msg += " · \(skipSummaryLine)" }
                        return msg
                    }()
                    if NSApplication.shared.isActive {
                        self.ingestAlertTitle   = "Transfer complete"
                        self.ingestAlertMessage = alertBody
                        self.showIngestAlert    = true
                    } else {
                        self.notifyIfBackgrounded(title: "Transfer complete ✓", body: notifBody)
                    }
                }

                // A slot just freed — admit any queued cards the scheduler now allows
                // (cards to free drives start in parallel; same-drive cards stay sequential).
                self.drainQueue()

                if self.runningCount == 0 {
                    DockProgress.clear()
                    if self.cardQueue.isEmpty {
                        HapticEngine.shared.success()
                        // "Safe to eject" was set by PHASE done — hold it for 3 seconds
                        // before resetting to idle so the operator has time to read it.
                        let idleText = self.autoIngest ? "Searching for cards…" : "Waiting for cards…"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            // Only reset if no new ingest started during the delay
                            if self.runningCount == 0 {
                                self.statusText = idleText
                            }
                        }
                    }
                }
            }
        }

        do {
            try process.run()
            activeProcesses[processID] = process
            // Keep macOS from App-Napping (and Mach-suspending) this ingest while it runs.
            ingestActivities[processID] = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "CardRunner ingest: \(card.name)")
        } catch {
            appendLog("❌ Failed to run script for card \(card.name): \(error.localizedDescription)\n")
            statusText = "Error starting ingest."
            runningCount = max(0, runningCount - 1)
            // Capture the per-card folder name before discarding the lane, so the "do not
            // format" record shows the same name the operator typed.
            let laneLabel = activeIngests[processID]?.friendlyName ?? ""
            activeIngests.removeValue(forKey: processID)   // clean up the orphaned entry
            HapticEngine.shared.error()

            let entry = IngestHistoryEntry(
                cardName: card.name,
                status: "Error",
                newFiles: 0,
                skippedFiles: 0,
                avgMBps: 0,
                durationSec: 0,
                destPath: "",
                mediaLabel: self.mediaLabel
            )
            historyEntries.insert(entry, at: 0)
            saveHistory()   // saveHistory trims to 24 h window

            // Footage safety: cardcopy failed to even launch → nothing was copied. Leave a
            // PERSISTENT "do not format" record (not just a transient history row), so the v3
            // failure strip / ring warn the operator that this card was NOT offloaded.
            let failRec = FailedIngestRecord(
                id: UUID(), cardName: card.name, volumeUUID: card.volumeUUID,
                friendlyName: laneLabel,
                projectName: self.projectName, failedAt: Date(),
                filesToCopy: 0, mbToCopy: 0, reason: "Error")
            saveFailedRecord(failRec)

            // Drain the queue — without this, cards queued behind this one sit
            // stranded until the next mount event when process.run() fails (O2).
            drainQueue()
        }
    }

    // MARK: - New Project Folder
    private func showCustomDestPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose destination folder"
        panel.message = "CardRunner will place date-folders directly inside this folder."
        panel.prompt = "Use as Destination"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // Start in the custom path's parent if set, otherwise home
        if !customDestPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: customDestPath, isDirectory: true)
        } else {
            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        panel.begin { response in
            if response == .OK, let url = panel.url {
                DispatchQueue.main.async {
                    self.customDestPath = url.path
                    self.revalidateCustomDest()
                    self.updateSSDInfo()
                }
            }
        }
    }

    private func showNewProjectFolderPanel() {
        guard let primary = selectedPrimary else {
            statusText = "Select a primary SSD first."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "New project folder"
        panel.message = "Create or choose a folder in the root of your primary SSD to use as this project."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: primary.path, isDirectory: true)

        panel.begin { response in
            if response == .OK, let url = panel.url {
                DispatchQueue.main.async {
                    self.projectName = url.lastPathComponent
                    self.applyScaffold(to: url)
                    self.refreshProjectFolders()
                    self.refreshSubfolders()
                }
            }
        }
    }

    private func createNewProjectFolder() {
        guard let primary = selectedPrimary else { return }
        let trimmedName = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let fm = FileManager.default
        let newFolderURL = URL(fileURLWithPath: primary.path).appendingPathComponent(trimmedName, isDirectory: true)
        do {
            try fm.createDirectory(at: newFolderURL, withIntermediateDirectories: true, attributes: nil)
            if newProjectFolderColor != 0 {
                applyCustomFolderColor(to: newFolderURL, labelIndex: newProjectFolderColor)
            }
            applyScaffold(to: newFolderURL)
            refreshProjectFolders()
            projectName = trimmedName
            refreshSubfolders()
            showNewProjectSheet = false
        } catch {
            statusText = "Error creating folder"
        }
    }

    /// Writes com.apple.metadata:_kMDItemUserTags in the exact binary-plist format
    /// that macOS "Customize Folder" uses — "ColorName\nLabelIndex".
    /// This changes the actual folder icon tint in Finder (Sonoma+), not just the dot label.
    private func applyCustomFolderColor(to url: URL, labelIndex: Int) {
        let nameForIndex: [Int: String] = [
            1: "Gray", 2: "Green", 3: "Purple",
            4: "Blue", 5: "Yellow", 6: "Red", 7: "Orange"
        ]
        guard let colorName = nameForIndex[labelIndex] else { return }
        let tagString = "\(colorName)\n\(labelIndex)"
        guard let plistData = try? PropertyListSerialization.data(
            fromPropertyList: [tagString] as NSArray,
            format: .binary,
            options: 0
        ) else { return }
        // setxattr is a POSIX syscall — no dependency on Finder being open.
        plistData.withUnsafeBytes { ptr in
            _ = setxattr(url.path, "com.apple.metadata:_kMDItemUserTags",
                         ptr.baseAddress!, plistData.count, 0, 0)
        }
    }

    /// Creates a new subfolder inside the current custom destination, applies scaffold,
    /// then sets that new subfolder as the active custom destination.
    private func createCustomDestSubfolder() {
        let trimmedName = customDestNewFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !customDestPath.isEmpty else { return }
        let fm = FileManager.default
        let parentURL = URL(fileURLWithPath: customDestPath, isDirectory: true)
        let newFolderURL = parentURL.appendingPathComponent(trimmedName, isDirectory: true)
        do {
            try fm.createDirectory(at: newFolderURL, withIntermediateDirectories: true, attributes: nil)
            if customDestFolderColor != 0 {
                try? (newFolderURL as NSURL).setResourceValue(customDestFolderColor, forKey: .labelNumberKey)
            }
            applyScaffold(to: newFolderURL)
            customDestPath = newFolderURL.path
            revalidateCustomDest()
            showCustomDestNewFolder = false
        } catch {
            statusText = "Error creating folder"
        }
    }

    // Counter so we only run the O(n) truncation every 100 appends instead of
    // every single cardcopy progress line — prevents main thread lag on large ingests.
    @State private var logAppendCount: Int = 0

    // MARK: - Rename Template Preview

    private func renameTemplatePreview(_ template: String) -> String {
        let tmpl = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tmpl.isEmpty else { return "⚠ Template is empty" }
        var preview = tmpl
        preview = preview.replacingOccurrences(of: "{cardname}", with: "CardA")
        preview = preview.replacingOccurrences(of: "{original}", with: "MVI_0001")
        return preview + ".mp4"
    }

    // MARK: - Shortcut Handling

    private var customShortcuts: [String: RecordedShortcut] {
        guard let data = customShortcutsJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: RecordedShortcut].self, from: data)
        else { return [:] }
        return dict
    }

    private func currentShortcut(for action: ShortcutAction) -> RecordedShortcut {
        customShortcuts[action.rawValue] ?? action.defaultShortcut
    }

    private func setShortcut(_ shortcut: RecordedShortcut, for action: ShortcutAction) {
        var dict = customShortcuts
        if shortcut.isNone { dict.removeValue(forKey: action.rawValue) }
        else               { dict[action.rawValue] = shortcut }
        guard let data = try? JSONEncoder().encode(dict),
              let str  = String(data: data, encoding: .utf8) else { return }
        customShortcutsJSON = str
        shortcutsRef.value  = dict
    }

    private func handleShortcutAction(_ action: ShortcutAction) {
        switch action {
        case .toggleAutoIngest:
            if runningCount == 0 { autoIngest.toggle() }
        case .stopTransfer:
            if runningCount > 0 { cancelAllIngests() }
        case .switchToVideo:
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { importMode = "video" }
            AudioEngine.shared.modeSwitch()
        case .switchToPhoto:
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { importMode = "photo" }
            AudioEngine.shared.modeSwitch()
        case .openSettings:
            isShowingSettings = true
        case .openLog:
            // Route to the v3 log sheet, mirroring the menu handler (menuToggleLog).
            if !isShowingSettings { showV3Log.toggle() }
        case .openHistory:
            // Route to the v3 history sheet, mirroring the menu handler (menuToggleHistory).
            if !isShowingSettings { showV3History.toggle() }
        case .openInFinder:
            let dest = finderDestPath
            if !dest.isEmpty {
                NSWorkspace.shared.open(URL(fileURLWithPath: dest))
            }
        case .switchPreset1: applyPresetSlot(0)
        case .switchPreset2: applyPresetSlot(1)
        case .switchPreset3: applyPresetSlot(2)
        case .switchPreset4: applyPresetSlot(3)
        case .switchPreset5: applyPresetSlot(4)
        case .switchPreset6: applyPresetSlot(5)
        }
    }

    /// Applies the preset at the given 0-based index, or clears to No Preset if out of range.
    private func applyPresetSlot(_ index: Int) {
        guard index < presets.count else { return }
        applyPreset(presets[index])
    }

    /// Returns the ShortcutAction for a given 0-based preset index (used for badge display).
    private func presetSlotAction(_ index: Int) -> ShortcutAction {
        switch index {
        case 0: return .switchPreset1
        case 1: return .switchPreset2
        case 2: return .switchPreset3
        case 3: return .switchPreset4
        case 4: return .switchPreset5
        default: return .switchPreset6
        }
    }

    private func setupShortcutMonitor() {
        shortcutsRef.value = customShortcuts
        let rRef = recordingRef
        let sRef = shortcutsRef
        shortcutMonitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let mods = event.modifierFlags.intersection(relevant)

            // Recording mode — capture next key combo as new shortcut
            if let recording = rRef.value {
                if event.keyCode == 53 {  // Escape — cancel
                    DispatchQueue.main.async { self.recordingAction = nil; rRef.value = nil }
                    return nil
                }
                if event.keyCode == 51 || event.keyCode == 117 { // Delete / Fwd Delete — clear
                    DispatchQueue.main.async {
                        self.setShortcut(.none, for: recording)
                        self.recordingAction = nil; rRef.value = nil
                    }
                    return nil
                }
                // Ignore bare modifier key presses
                let modifierKeyCodes: Set<UInt16> = [54,55,56,57,58,59,60,61,62,63]
                guard !modifierKeyCodes.contains(event.keyCode) else { return nil }
                let sc = RecordedShortcut(keyCode: event.keyCode, modifierFlags: mods.rawValue)
                DispatchQueue.main.async {
                    self.setShortcut(sc, for: recording)
                    self.recordingAction = nil; rRef.value = nil
                }
                return nil
            }

            // Don't steal from focused text fields
            if NSApp.keyWindow?.firstResponder is NSText { return event }

            // Execute matching shortcut
            for action in ShortcutAction.allCases {
                let sc = sRef.value[action.rawValue] ?? action.defaultShortcut
                if sc.isNone { continue }
                let scMods = NSEvent.ModifierFlags(rawValue: sc.modifierFlags).intersection(relevant)
                if event.keyCode == sc.keyCode && mods == scMods {
                    DispatchQueue.main.async { self.handleShortcutAction(action) }
                    return nil
                }
            }
            return event
        }
    }

    private func teardownShortcutMonitor() {
        if let token = shortcutMonitorToken {
            NSEvent.removeMonitor(token)
            shortcutMonitorToken = nil
        }
    }

    private func appendLog(_ t: String) {
        logText.append(t)
        logAppendCount += 1

        let maxChars = 50_000
        if logAppendCount % 100 == 0, logText.count > maxChars {
            let startIndex = logText.index(logText.endIndex, offsetBy: -maxChars)
            logText = String(logText[startIndex...])
        }
    }

    // MARK: - PROGRESS_* Parsing

    private func parseProgress(from chunk: String, processID: UUID) {
        // Read the ingest record, apply all mutations, then write it back in one shot.
        // This keeps multi-card state isolated: each process only updates its own entry.
        guard var ingest = activeIngests[processID] else { return }

        let lines = chunk.split(whereSeparator: \.isNewline)

        for rawLine in lines {
            let line = String(rawLine)
            // DATA: single source of truth — pure, unit-tested (applyIngestProgressLine).
            applyIngestProgressLine(line, to: &ingest)
            // UI: sounds, status text, alerts, and logging layered on top.
            handleProgressLineUI(line, ingest: &ingest)
        }

        activeIngests[processID] = ingest
    }

    /// UI-only reactions to a progress line — sounds, status text, alerts, logging.
    /// All ingest STATE mutations live in the pure applyIngestProgressLine(...); this runs
    /// AFTER the data pass, so it reads the already-updated `ingest`. (checkDiskSpace is the
    /// one exception — it derives the low-disk warning from the just-updated free space.)
    private func handleProgressLineUI(_ line: String, ingest: inout ActiveIngest) {
        if line.hasPrefix("PROGRESS_META") {
            if let r = line.range(of: "bytes_new=") {
                let nBytesNew = extractInt64(from: line, after: r)
                if nBytesNew <= 0 && ingest.newFiles == 0 {
                    statusText = "Up to date (no new files)"
                }
                checkDiskSpace(ingest: &ingest)
            }

        } else if line.hasPrefix("VERIFY_PASS") {
            AudioEngine.shared.verifyPassed()
            if let r = line.range(of: "checked=") {
                let n = extractInt(from: line, after: r)
                appendLog("✅ Verify passed — \(n) file(s) checksummed OK\n")
            }

        } else if line.hasPrefix("VERIFY_FAIL") {
            AudioEngine.shared.verifyFailed()
            if line.contains("file=") {
                let failName = line.components(separatedBy: "file=").last?
                    .components(separatedBy: " ").first ?? "unknown"
                appendLog("❌ CHECKSUM MISMATCH: \(failName) — destination file may be corrupt\n")
                DispatchQueue.main.async { self.statusText = "⚠️ Checksum failed — \(failName)" }
            } else if let r = line.range(of: "failed=") {
                let n = extractInt(from: line, after: r)
                appendLog("⚠️ Verify FAILED — \(n) file(s) had checksum mismatches\n")
                DispatchQueue.main.async { self.statusText = "⚠️ Checksum failed — \(n) file(s)" }
            } else {
                let failName = String(line.dropFirst("VERIFY_FAIL ".count)
                    .components(separatedBy: " ").first ?? "unknown")
                appendLog("❌ CHECKSUM MISMATCH: \(failName) — destination file may be corrupt\n")
                DispatchQueue.main.async { self.statusText = "⚠️ Checksum failed — \(failName)" }
            }

        } else if line.hasPrefix("VERIFY_SKIP") {
            appendLog("— Verify skipped (no files sampled)\n")

        } else if line.hasPrefix("SECONDARY_PROGRESS dest=") {
            let dest = line.replacingOccurrences(of: "SECONDARY_PROGRESS dest=", with: "")
            appendLog("🔁 Secondary copy → \((dest as NSString).lastPathComponent)\n")

        } else if line.hasPrefix("RSYNC_ERROR") || line.hasPrefix("COPY_ERROR") {
            appendLog("⚠️ Copy error — files will retry on next ingest\n")

        } else if line.hasPrefix("DEST_FREE gb=") {
            let gbStr = line.replacingOccurrences(of: "DEST_FREE gb=", with: "").trimmingCharacters(in: .whitespaces)
            if Double(gbStr) != nil { checkDiskSpace(ingest: &ingest) }

        } else if line.hasPrefix("DEST_INSUFFICIENT") {
            // Pre-flight space check failed — surface a friendly message (E1).
            var needGB = 0
            var freeGB = 0
            if let r = line.range(of: "need_kb=") {
                let kb = extractInt(from: line, after: r)
                needGB = max(1, (kb + 1048575) / 1048576)
            }
            if let r = line.range(of: "free_kb=") {
                let kb = extractInt(from: line, after: r)
                freeGB = max(0, (kb + 1048575) / 1048576)
            }
            let driveName: String = {
                guard !ingest.destPath.isEmpty else { return "destination" }
                let comps = URL(fileURLWithPath: ingest.destPath).pathComponents
                return comps.dropFirst().first ?? "destination"
            }()
            let msg = "Not enough space on \(driveName) — needs \(needGB) GB, only \(freeGB) GB free."
            appendLog("❌ \(msg)\n")
            DispatchQueue.main.async {
                self.ingestAlertTitle   = "Not enough space"
                self.ingestAlertMessage = msg
                self.showIngestAlert    = true
            }

        } else if line.hasPrefix("COLLISION_RENAMED ") {
            let parts = line.dropFirst("COLLISION_RENAMED ".count).components(separatedBy: " ")
            if parts.count >= 2 {
                appendLog("⚠️ Duplicate filename: \(parts[0]) → saved as \(parts[1])\n")
            }

        } else if line.hasPrefix("VERIFY_OK ") {
            let parts = line.dropFirst("VERIFY_OK ".count).components(separatedBy: " ")
            let verifyName = parts.first ?? "file"
            let verifyHash = parts.count > 1 ? String(parts[1].prefix(8)) : ""
            appendLog("✓ Verified \(verifyName) [\(verifyHash)…]\n")

        } else if line.hasPrefix("SECONDARY_ERROR") {
            let secondaryMsg: String
            if line.contains("reason=copy_failed") {
                let exitCode = line.components(separatedBy: "exit=").last ?? "?"
                secondaryMsg = "⚠️ Secondary copy failed (exit \(exitCode.trimmingCharacters(in: .whitespaces))) — primary copy is intact"
            } else if line.contains("reason=not_mounted") {
                secondaryMsg = "⚠️ Secondary drive not mounted — secondary copy skipped"
            } else {
                secondaryMsg = "⚠️ Secondary copy error — primary copy is intact"
            }
            appendLog("\(secondaryMsg)\n")
            AudioEngine.shared.verifyFailed()

        } else if line.hasPrefix("TRANSFER_REPORT path=") {
            let path = line.replacingOccurrences(of: "TRANSFER_REPORT path=", with: "")
            DispatchQueue.main.async { self.lastReportPath = path }
            appendLog("📄 Transfer report saved: \(path)\n")

        } else if line.hasPrefix("PHASE ") {
            let newPhase  = ingest.phase   // already set by the data pass
            let cardLabel = ingest.cardName.isEmpty ? "card" : ingest.cardName
            let phaseDisplay: String
            if newPhase == .failed {
                phaseDisplay = "Transfer failed — \(cardLabel) kept mounted, re-insert to retry"
            } else if newPhase == .copying && ingest.totalFiles > 0 {
                phaseDisplay = "Copying \(ingest.totalFiles) file\(ingest.totalFiles == 1 ? "" : "s") — \(cardLabel)"
            } else if newPhase == .done {
                if fullVerifyEnabled {
                    phaseDisplay = "Verified & safe to eject \(cardLabel) ✓"
                } else if verifyTransfer {
                    phaseDisplay = "Copied & spot-checked — safe to eject \(cardLabel) ✓"
                } else {
                    phaseDisplay = "Safe to eject \(cardLabel) ✓"
                }
            } else {
                phaseDisplay = "\(newPhase.displayText) \(cardLabel)"
            }
            DispatchQueue.main.async { self.statusText = phaseDisplay }
        }
    }

    private func extractInt(from string: String, after range: Range<String.Index>) -> Int {
        let valuePart = string[range.upperBound...]
        let token = valuePart.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""
        return Int(token) ?? 0
    }

    private func extractInt64(from string: String, after range: Range<String.Index>) -> Int64 {
        let valuePart = string[range.upperBound...]
        let token = valuePart.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""
        return Int64(token) ?? 0
    }

    /// Sends a macOS banner notification only when the app is not the active frontmost window.
    private func notifyIfBackgrounded(title: String, body: String) {
        guard !NSApplication.shared.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Crash Recovery Helpers

    private var checkpointDirectory: URL {
        let fallback = FileManager.default.temporaryDirectory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first ?? fallback
        return appSupport.appendingPathComponent("CardRunner/checkpoints")
    }

    private func saveCheckpoint(_ cp: IngestCheckpoint) {
        let fm = FileManager.default
        try? fm.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
        let url = checkpointDirectory.appendingPathComponent("\(cp.id.uuidString).checkpoint")
        if let data = try? JSONEncoder().encode(cp) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func deleteCheckpoint(id: UUID) {
        let url = checkpointDirectory.appendingPathComponent("\(id.uuidString).checkpoint")
        try? FileManager.default.removeItem(at: url)
    }

    /// Scans the checkpoint directory and surfaces any stale (un-deleted) checkpoints
    /// as resume prompts.  Called on launch after destinations are refreshed.
    private func checkForStaleCheckpoints() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: checkpointDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        let checkpoints: [IngestCheckpoint] = files
            .filter { $0.pathExtension == "checkpoint" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let cp   = try? JSONDecoder().decode(IngestCheckpoint.self, from: data)
                else { return nil }
                return cp
            }
            .sorted { $0.startedAt > $1.startedAt }   // newest first

        guard !checkpoints.isEmpty else { return }
        pendingCheckpoints = checkpoints
        showResumeSheet    = true
    }

    /// Re-launch an interrupted ingest from its saved checkpoint.
    private func resumeFromCheckpoint(_ cp: IngestCheckpoint) {
        showResumeSheet = false

        guard let scriptPath = Bundle.main.path(forResource: "CardRunner", ofType: "sh") else {
            appendLog("❌ Resume failed: CardRunner.sh not found in bundle.\n")
            return
        }

        // Check primary SSD is mounted
        guard let primary = availableDestinations.first(where: { $0.path == cp.primaryPath }) else {
            statusText = "Resume: connect \"\((cp.primaryPath as NSString).lastPathComponent)\" to continue"
            return
        }

        // Check card is mounted — scan /Volumes directly
        guard FileManager.default.fileExists(atPath: cp.cardPath) else {
            statusText = "Resume: insert card \"\(cp.cardName)\" to continue"
            return
        }
        let cardVolume = Volume(name: cp.cardName, path: cp.cardPath,
                                cameraModel: detectCameraModel(at: cp.cardPath))

        // Same safety gate as startIngest: refuse to resume onto the source card's
        // own volume (e.g. a re-inserted card that now mounts where the dest used to be).
        if destinationIsOnCard(card: cardVolume, destPath: cp.primaryPath) {
            statusText = "Resume blocked: destination is on the source card."
            ingestAlertTitle   = "Destination is the source card"
            ingestAlertMessage = "The saved destination for \(cp.cardName) resolves to the card itself. Connect the correct destination drive and try again."
            showIngestAlert    = true
            return
        }

        // Block if another transfer is already running (use isBusy — covers demo too)
        if isBusy {
            cardQueue.append(QueuedIngest(card: cardVolume, dateOverride: nil))
            return
        }

        let processID = UUID()
        activeIngests[processID] = ActiveIngest(
            cardName: cp.cardName,
            cameraModel: cardVolume.cameraModel,
            projectRoot: "\(primary.path)/\(cp.projectName)"
        )
        activeIngests[processID]?.sourcePath = cp.cardPath
        activeIngests[processID]?.runMode = cp.mode
        lastNewFiles = 0; lastAvgMBps = 0; lastDurationSec = 0
        lastDestPath = ""; lastReportPath = ""
        showCompletionState = false

        var args: [String]
        if let saved = cp.resumeArgs, !saved.isEmpty {
            // Preferred path: replay the exact arg list captured at the original launch,
            // so date-override/wrong-clock, reel filter, Olympics mode, broadcast-day
            // hour, rename template and date filters are all preserved on resume.
            args = [scriptPath] + saved
        } else {
            // Legacy checkpoint (written before resumeArgs existed) — reconstruct from
            // the individual fields. Routing-specific flags can't be recovered here.
            args = [scriptPath]
            args += ["--card",    cp.cardPath]
            args += ["--primary", cp.primaryPath]
            args += ["--project", cp.projectName]
            if !cp.subfolder.isEmpty  { args += ["--subfolder", cp.subfolder] }
            if !cp.cardLabel.isEmpty  { args += ["--cardlabel", cp.cardLabel] }
            if cp.dateFormat != "%y%m%d" { args += ["--date-format", cp.dateFormat] }
            if !cp.finderTagColor.isEmpty { args += ["--finder-tag-color", cp.finderTagColor] }
            if cp.mode == "photo"     { args += ["--mode", "photo"] }
            if !cp.secondaryPath.isEmpty { args += ["--secondary", cp.secondaryPath] }
            if cp.verifyEnabled       { args += ["--verify"] }
        }

        appendLog("=== Resuming interrupted ingest: \(cp.cardName) → \(cp.projectName) ===\n")
        statusText = "Resuming \(cp.cardName)…"
        runningCount += 1
        AudioEngine.shared.transferStarted()
        HapticEngine.shared.start()

        // Launch using the original checkpoint ID so its file gets deleted on clean exit
        launchIngestProcess(card: cardVolume, processID: processID,
                            args: args, checkpointID: cp.id)
    }

    /// Discard a stale checkpoint without resuming — cleans up orphan partial dirs.
    private func discardCheckpoint(_ cp: IngestCheckpoint) {
        deleteCheckpoint(id: cp.id)
        // Scope cleanup to THIS checkpoint's own project folder, not the whole volume,
        // so discarding one stale checkpoint can't delete another transfer's staging.
        let scope = cp.projectName.isEmpty ? cp.primaryPath : "\(cp.primaryPath)/\(cp.projectName)"
        cleanupPartialDirs(in: scope)
        pendingCheckpoints.removeAll { $0.id == cp.id }
        if pendingCheckpoints.isEmpty { showResumeSheet = false }
        appendLog("🗑 Discarded interrupted ingest checkpoint for \(cp.cardName).\n")
    }

    // MARK: - Failed ingest record persistence

    private func loadFailedRecords() {
        guard let data = UserDefaults.standard.data(forKey: failedRecordsKey) else { return }
        // Element-wise decode so one bad record doesn't drop every "not ingested" warning.
        let records = lenientDecodeArray(FailedIngestRecord.self, from: data)
        // Only keep records from the last 7 days
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        failedIngestRecords = records.filter { $0.failedAt > cutoff }
    }

    private func saveFailedRecord(_ record: FailedIngestRecord) {
        var records = failedIngestRecords
        records.insert(record, at: 0)
        records = Array(records.prefix(20))  // keep at most 20
        failedIngestRecords = records
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: failedRecordsKey)
        }
    }

    /// Clear a failure record ONLY for the SAME physical card that just succeeded — never on an
    /// empty nickname alone. Previously this matched on `friendlyName == friendlyName`, and since
    /// most cards are un-nicknamed (`friendlyName == ""`), a success of one un-nicknamed card would
    /// wipe a DIFFERENT un-nicknamed card's failure record in the same project — masking a real
    /// failure. Now we require the card's volume UUID to match (exact identity), falling back to
    /// the volume name (+ nickname if one is set) when no UUID is available.
    private func clearFailedRecords(cardName: String, volumeUUID: String?, friendlyName: String, projectName: String) {
        let before = failedIngestRecords.count
        failedIngestRecords = failureRecordsSurviving(
            failedIngestRecords, afterSuccessOf: cardName, volumeUUID: volumeUUID,
            friendlyName: friendlyName, projectName: projectName)
        if failedIngestRecords.count != before {
            if let data = try? JSONEncoder().encode(failedIngestRecords) {
                UserDefaults.standard.set(data, forKey: failedRecordsKey)
            }
        }
    }

    private func dismissFailedRecord(id: UUID) {
        failedIngestRecords.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(failedIngestRecords) {
            UserDefaults.standard.set(data, forKey: failedRecordsKey)
        }
    }

    private func relativeTimeString(from date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }

    // MARK: - Disk space check

    private func checkDiskSpace(ingest: inout ActiveIngest) {
        guard ingest.destFreeGB > 0, ingest.totalBytesNew > 0 else { return }
        let neededGB = Double(ingest.totalBytesNew) / 1_073_741_824.0
        // Warn if free space is less than 1.2× what we need (< 20% headroom)
        ingest.lowDiskWarning = ingest.destFreeGB < neededGB * 1.2
    }

    private func saveHistory() {
        // Keep anything within the current broadcast-day session window so history
        // resets at exactly the same moment as the session stats ring.
        let cutoff = currentDayWindowStart
        let recent = historyEntries.filter { $0.timestamp >= cutoff }
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: "pref_ingestHistory")
        }
    }

    /// Decodes a JSON array element-by-element, skipping any element that fails to
    /// decode rather than throwing away the entire array. Used for persisted audit data
    /// (history, failed records) so one corrupt or legacy-schema row never wipes the
    /// whole store — which would break the app's "did we get that card?" promise.
    private func lenientDecodeArray<T: Decodable>(_ type: T.Type, from data: Data) -> [T] {
        guard let wrapped = try? JSONDecoder().decode([LenientDecodable<T>].self, from: data) else { return [] }
        return wrapped.compactMap { $0.value }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: "pref_ingestHistory") else { return }
        // Element-wise decode: a single corrupt/legacy entry skips itself instead of
        // discarding the entire history.
        let entries = lenientDecodeArray(IngestHistoryEntry.self, from: data)
        // Same cutoff — discard anything older than the current session window on load.
        let cutoff = currentDayWindowStart
        historyEntries = entries.filter { $0.timestamp >= cutoff }
    }

    // MARK: - All-time stats persistence

    private func saveAllTimeStats() {
        if let data = try? JSONEncoder().encode(allTimeStats) {
            UserDefaults.standard.set(data, forKey: "pref_allTimeStats")
        }
    }

    private func loadAllTimeStats() {
        guard let data = UserDefaults.standard.data(forKey: "pref_allTimeStats"),
              let stats = try? JSONDecoder().decode(AllTimeStats.self, from: data)
        else { return }
        allTimeStats = stats
    }

    /// One-time log parse that seeds all-time stats from existing log files.
    /// Runs async on a background thread so it never blocks the UI.
    private func bootstrapAllTimeStatsFromLogs() {
        guard !allTimeStats.bootstrappedFromLogs else { return }
        // Construct on the main actor (where we already are) to satisfy Swift 6 isolation.
        var stats = AllTimeStats()
        stats.bootstrappedFromLogs = true
        Task.detached(priority: .utility) {
            let logDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/CardRunner")

            let isoFmt = DateFormatter()
            isoFmt.locale = Locale(identifier: "en_US_POSIX")
            isoFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

            if let logFiles = try? FileManager.default.contentsOfDirectory(
                at: logDir, includingPropertiesForKeys: nil
            ) {
                for fileURL in logFiles where fileURL.pathExtension == "log" {
                    guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                    for line in contents.components(separatedBy: "\n") {
                        guard line.contains("Status=OK") else { continue }
                        var fields: [String: String] = [:]
                        for part in line.components(separatedBy: " | ") {
                            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                            if kv.count == 2 {
                                fields[kv[0].trimmingCharacters(in: .whitespaces)] =
                                    kv[1].trimmingCharacters(in: .whitespaces)
                            }
                        }
                        guard let nf  = Int(fields["NewFiles"]     ?? ""), nf > 0,
                              let nb  = Double(fields["NewMB"]      ?? ""),
                              let dur = Int(fields["DurationSec"]   ?? ""),
                              let spd = Int(fields["AvgMBps"]       ?? "") else { continue }

                        stats.totalCards       += 1
                        stats.totalFiles       += nf
                        stats.totalMB          += nb
                        stats.totalDurationSec += dur
                        stats.peakMBps          = max(stats.peakMBps, spd)

                        let dateStr = String(line.prefix(19))
                        if let date = isoFmt.date(from: dateStr) {
                            if stats.firstIngestDate == nil || date < stats.firstIngestDate! {
                                stats.firstIngestDate = date
                            }
                        }
                    }
                }
            }

            // Copy to a `let` so the Swift 6 concurrency checker sees an immutable
            // capture rather than a reference to the mutated `var` above.
            let finalStats = stats
            await MainActor.run {
                self.allTimeStats = finalStats
                self.saveAllTimeStats()
            }
        }
    }

    /// Called once per successful ingest to keep all-time stats current.
    private func accumulateAllTimeStats(newFiles: Int, newMB: Double,
                                        durationSec: Int, avgMBps: Int) {
        guard newFiles > 0 else { return }
        allTimeStats.totalCards       += 1
        allTimeStats.totalFiles       += newFiles
        allTimeStats.totalMB          += newMB
        allTimeStats.totalDurationSec += durationSec
        allTimeStats.peakMBps          = max(allTimeStats.peakMBps, avgMBps)
        if allTimeStats.firstIngestDate == nil { allTimeStats.firstIngestDate = Date() }
        saveAllTimeStats()
    }

    // MARK: - Preset functions

    // MARK: - Preset persistence helpers

    /// JSON file in Application Support — survives Xcode reinstalls, sandbox resets,
    /// and app updates. UserDefaults is kept in sync as a secondary backup.
    private var presetsFileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CardRunner", isDirectory: true)
        return dir.appendingPathComponent("presets.json")
    }

    private func savePresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }

        // Primary: file in ~/Library/Application Support/CardRunner/presets.json
        let url = presetsFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)

        // Secondary mirror: UserDefaults (fast reads, but can be wiped by sandbox resets)
        UserDefaults.standard.set(data, forKey: "pref_ingestPresets")

        if let id = activePresetID {
            UserDefaults.standard.set(id.uuidString, forKey: "pref_activePresetID")
        } else {
            UserDefaults.standard.removeObject(forKey: "pref_activePresetID")
        }
    }

    private func loadPresets() {
        // Try file-based store first — it's the durable source of truth.
        // Fall back to UserDefaults for users upgrading from older builds that
        // only wrote to UserDefaults.
        let fileData = try? Data(contentsOf: presetsFileURL)
        let udData   = UserDefaults.standard.data(forKey: "pref_ingestPresets")
        guard let data = fileData ?? udData,
              let saved = try? JSONDecoder().decode([IngestPreset].self, from: data)
        else { return }

        presets = saved

        // Back-fill whichever store was missing so both are in sync going forward.
        if fileData == nil {
            let url = presetsFileURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        if udData == nil {
            UserDefaults.standard.set(data, forKey: "pref_ingestPresets")
        }

        if let idStr = UserDefaults.standard.string(forKey: "pref_activePresetID"),
           let id = UUID(uuidString: idStr),
           saved.contains(where: { $0.id == id }) {
            activePresetID = id
        }
    }

    private func applyPreset(_ preset: IngestPreset) {
        // General
        importMode               = preset.importMode
        dateFolderFormat         = preset.dateFolderFormat
        ingestOrder              = preset.ingestOrder
        todayOnly                = preset.todayOnly          // keep legacy in sync
        dateFilterMode           = preset.dateFilterMode
        dateFilterFrom           = preset.dateFilterFrom
        selectedSubfolder        = preset.selectedSubfolder
        // Card name: only overwrite if the preset has a name saved.
        // If the preset's name is blank, leave whatever the user already typed —
        // switching presets should never silently clear a name they set manually.
        // Suppress the onChange so the preset value isn't saved to the card's UUID store —
        // preset names are static labels, not per-card nicknames.
        if preset.useCustomCardName && !preset.customCardName.isEmpty {
            skipNextNicknameSave = true
            cardNameIsFromMemory = false  // it's a preset name now, not from memory
            useCustomCardName = true
            customCardName    = preset.customCardName
        } else if preset.useCustomCardName && preset.customCardName.isEmpty {
            // Preset has the toggle on but no name — enable the field, keep existing text
            useCustomCardName = true
        } else {
            // Preset has toggle off — turn off the toggle but leave the name text intact
            // so if they re-enable it their previous text is still there
            useCustomCardName = false
        }
        finderTagEnabled         = preset.finderTagEnabled
        finderTagColor           = preset.finderTagColor
        completionAnimationRaw   = preset.completionAnimationRaw
        dayStartHour             = preset.dayStartHour
        broadcastDayFolders      = preset.broadcastDayFolders
        // Destination
        useCustomDest            = preset.useCustomDest
        customDestPath           = preset.customDestPath
        // Advanced
        autoEject                = preset.autoEject
        copyXML                  = preset.copyXML
        verifyTransfer           = preset.verifyTransfer
        includeProxies           = preset.includeProxies
        // Pro Tools
        dualDestEnabled          = preset.dualDestEnabled
        fullVerifyEnabled        = preset.fullVerifyEnabled
        transferReportEnabled    = preset.transferReportEnabled
        renameOnIngestEnabled    = preset.renameOnIngestEnabled
        renameTemplate           = preset.renameTemplate
        // Scaffold
        scaffoldEnabled          = preset.scaffoldEnabled
        if !preset.scaffoldFolders.isEmpty { scaffoldFoldersRaw = preset.scaffoldFolders }
        activePresetID           = preset.id
        updateSSDInfo()
        savePresets()
    }

    private func saveCurrentAsPreset(name: String) {
        guard presets.count < 6 else { return }
        guard !presets.contains(where: { $0.name.lowercased() == name.lowercased() }) else { return }
        let preset = IngestPreset(
            name:                  name,
            // General
            importMode:            importMode,
            dateFolderFormat:      dateFolderFormat,
            ingestOrder:           ingestOrder,
            todayOnly:             dateFilterMode == "today",
            dateFilterMode:        dateFilterMode,
            dateFilterFrom:        dateFilterFrom,
            selectedSubfolder:     selectedSubfolder,
            useCustomCardName:     useCustomCardName,
            customCardName:        customCardName,
            finderTagEnabled:      finderTagEnabled,
            finderTagColor:        finderTagColor,
            completionAnimationRaw: completionAnimationRaw,
            dayStartHour:          dayStartHour,
            broadcastDayFolders:   broadcastDayFolders,
            // Destination
            useCustomDest:         useCustomDest,
            customDestPath:        customDestPath,
            // Advanced
            autoEject:             autoEject,
            copyXML:               copyXML,
            verifyTransfer:        verifyTransfer,
            includeProxies:        includeProxies,
            // Pro Tools
            dualDestEnabled:       dualDestEnabled,
            fullVerifyEnabled:     fullVerifyEnabled,
            transferReportEnabled: transferReportEnabled,
            renameOnIngestEnabled: renameOnIngestEnabled,
            renameTemplate:        renameTemplate,
            // Scaffold
            scaffoldEnabled:       scaffoldEnabled,
            scaffoldFolders:       scaffoldFoldersRaw
        )
        presets.append(preset)
        activePresetID = preset.id
        savePresets()
    }

    private func formatDuration(_ s: Int) -> String {
        guard s > 0 else { return "0s" }
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%02dh:%02dm:%02ds", h, m, sec) }
        return String(format: "%02dm:%02ds", m, sec)
    }

    /// Converts a strftime-style format string (used by the shell script and stored in
    /// @AppStorage) into a DateFormatter-compatible ICU pattern.
    /// Add new tokens here — they will automatically propagate to all previews.
    private func strftimeToICU(_ fmt: String) -> String {
        fmt
            .replacingOccurrences(of: "%A", with: "EEEE")   // Monday … Sunday
            .replacingOccurrences(of: "%Y", with: "yyyy")
            .replacingOccurrences(of: "%y", with: "yy")
            .replacingOccurrences(of: "%m", with: "MM")
            .replacingOccurrences(of: "%d", with: "dd")
    }

    private func exampleDateCode() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = strftimeToICU(dateFolderFormat)
        return formatter.string(from: Date())
    }

    /// Returns today's date in the chosen folder format followed by "_",
    /// ready to pre-fill the New Project Folder name field.
    /// e.g. "260517_" or "Sunday_" depending on the date format setting.
    private func todayDatePrefix() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = strftimeToICU(dateFolderFormat)
        return formatter.string(from: Date()) + "_"
    }

    private var logsDirectoryURL: URL {
        let fm = FileManager.default
        if let base = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let dir = base.appendingPathComponent("Logs/CardRunner", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let fallback = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/CardRunner", isDirectory: true)
        try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
}

// MARK: - Mini Pill Toggle

// MARK: - Welcome Celebration (first activation)
// Apple "hello" inspired: write-on reveal → shimmer → crossfade to welcome text → fade out

private struct WelcomeCelebrationView: View {
    var onComplete: (() -> Void)? = nil
    /// How long to hold on "Welcome to CardRunner" before fading out.
    /// Default 2.8 s for normal license-activation flow; pass 1.5 s for onboarding.
    var holdDuration: Double = 2.8

    // ── Animation state ──────────────────────────────────────────────────────
    @State private var bgOpacity:       Double   = 0
    @State private var helloReveal:     Bool     = false   // drives write-on mask width
    @State private var helloOpacity:    Double   = 0
    @State private var shimmerOffset:   CGFloat  = -1.0    // -1…2 normalised across text width
    @State private var shimmerOpacity:  Double   = 0
    @State private var welcomeOpacity:  Double   = 0
    @State private var welcomeOffset:   CGFloat  = 18
    @State private var subtitleOpacity: Double   = 0
    @State private var globalOpacity:   Double   = 1

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ── Background — deep navy with radial depth glow ─────────────
                ZStack {
                    // v3 background — matches the main UI's purple-black gradient + glows.
                    LinearGradient(
                        colors: [Color(hex: "#0c0822"), Color(hex: "#080615"), Color(hex: "#050310")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    RadialGradient(
                        colors: [Color(hex: "#7c3aed").opacity(0.20), .clear],
                        center: UnitPoint(x: 0.22, y: 0.08),
                        startRadius: 0,
                        endRadius: geo.size.width * 0.7
                    )
                    RadialGradient(
                        colors: [Color(hex: "#0dcff5").opacity(0.13), .clear],
                        center: UnitPoint(x: 0.84, y: 0.92),
                        startRadius: 0,
                        endRadius: geo.size.width * 0.55
                    )
                }
                .ignoresSafeArea()
                .opacity(bgOpacity)
                .animation(.easeInOut(duration: 0.5), value: bgOpacity)

                // ── "hello." — SF italic, write-on left-to-right ────────
                Text("hello.")
                    .font(.system(size:82).italic())
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, Color(hex: "#c8e8ff")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color(hex: "#0eb0e9").opacity(0.45), radius: 24)
                    // Write-on mask: a left-anchored rectangle that expands to full width
                    .mask {
                        GeometryReader { tg in
                            Rectangle()
                                .frame(width: helloReveal ? tg.size.width : 0,
                                       height: tg.size.height)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .animation(.easeInOut(duration: 2.7).delay(0.30), value: helloReveal)
                        }
                    }
                    // Shimmer sweep on top of the write-on
                    .overlay {
                        GeometryReader { tg in
                            LinearGradient(
                                stops: [
                                    .init(color: .clear,                         location: 0),
                                    .init(color: .white.opacity(0.0),            location: shimmerOffset - 0.15),
                                    .init(color: .white.opacity(0.55),           location: shimmerOffset),
                                    .init(color: .white.opacity(0.0),            location: shimmerOffset + 0.15),
                                    .init(color: .clear,                         location: 1),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: tg.size.width, height: tg.size.height)
                            .opacity(shimmerOpacity)
                        }
                    }
                    .blendMode(.normal)
                    .opacity(helloOpacity)
                    .animation(.easeInOut(duration: 0.9), value: helloOpacity)

                // ── "Welcome to CardRunner" + subtitle ───────────────────────
                VStack(spacing: 10) {
                    Text("Welcome to CardRunner")
                        .font(.custom("SairaItalic-ExtraBoldItalic", size: 30))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, Color(hex: "#b8d8ff")],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color(hex: "#0eb0e9").opacity(0.6), radius: 18)

                    Text("A smoother ingest workflow for creators")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.55))
                        .opacity(subtitleOpacity)
                        .animation(.easeInOut(duration: 1.0), value: subtitleOpacity)
                }
                .opacity(welcomeOpacity)
                .offset(y: welcomeOffset)
                .animation(.spring(response: 1.1, dampingFraction: 0.72), value: welcomeOpacity)
                .animation(.spring(response: 1.1, dampingFraction: 0.72), value: welcomeOffset)
            }
        }
        .opacity(globalOpacity)
        .animation(.easeInOut(duration: 1.4), value: globalOpacity)
        .onAppear { runSequence() }
    }

    private func runSequence() {
        // Run sleeps on a background thread to avoid QoS priority inversion.
        // All UI mutations are dispatched back to @MainActor explicitly.
        Task {
            // Activation chime
            await MainActor.run { AudioEngine.shared.licenseActivated() }

            // 0 — bg fades in
            await MainActor.run { withAnimation(.easeInOut(duration: 0.7)) { bgOpacity = 1 } }
            try? await Task.sleep(nanoseconds: 600_000_000)

            // 1 — "hello." reveals left-to-right (mask + opacity)
            await MainActor.run { helloOpacity = 1; helloReveal = true }
            try? await Task.sleep(nanoseconds: 3_300_000_000)

            // 2 — shimmer sweep across the text
            await MainActor.run {
                shimmerOpacity = 1
                withAnimation(.easeInOut(duration: 1.5)) { shimmerOffset = 1.2 }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { shimmerOpacity = 0 }

            // 3 — "hello." fades out
            try? await Task.sleep(nanoseconds: 400_000_000)
            await MainActor.run { helloOpacity = 0 }
            try? await Task.sleep(nanoseconds: 900_000_000)

            // 4 — "Welcome to CardRunner" rises up
            await MainActor.run {
                welcomeOffset  = 18
                welcomeOpacity = 1
                withAnimation(.spring(response: 1.1, dampingFraction: 0.72)) { welcomeOffset = 0 }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            // 5 — subtitle fades in
            await MainActor.run { withAnimation(.easeInOut(duration: 1.0)) { subtitleOpacity = 1 } }
            try? await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))

            // 6 — everything fades out, ContentView takes over
            await MainActor.run { globalOpacity = 0 }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run { onComplete?() }
        }
    }
}

// MARK: - Onboarding Flow (first-launch walkthrough)

/// Fade-in + gentle rise reveal used for onboarding headlines and body copy.
private struct OnboardingReveal: View {
    let text: String
    let font: Font
    var delay: Double = 0.2
    var foreground: AnyShapeStyle = AnyShapeStyle(Color.white)
    var shadowColor: Color = .clear
    var shadowRadius: CGFloat = 0
    var alignment: TextAlignment = .center

    @State private var shown = false

    init(_ text: String, font: Font, delay: Double = 0.2,
         foreground: AnyShapeStyle = AnyShapeStyle(Color.white),
         shadowColor: Color = .clear, shadowRadius: CGFloat = 0,
         alignment: TextAlignment = .center) {
        self.text         = text
        self.font         = font
        self.delay        = delay
        self.foreground   = foreground
        self.shadowColor  = shadowColor
        self.shadowRadius = shadowRadius
        self.alignment    = alignment
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(foreground)
            .multilineTextAlignment(alignment)
            .shadow(color: shadowColor, radius: shadowRadius)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .animation(.spring(response: 0.80, dampingFraction: 0.72).delay(delay), value: shown)
            .onAppear { shown = true }
    }
}

/// A filled capsule button used throughout onboarding screens.
private struct OnboardingButton: View {
    let title: String
    let color: Color
    let action: () -> Void
    @State private var hovered = false

    init(_ title: String, color: Color, action: @escaping () -> Void) {
        self.title  = title
        self.color  = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 32).padding(.vertical, 14)
                .background(
                    Capsule()
                        // v3 brand gradient CTA (cyan→purple→magenta), like the main-UI primary buttons.
                        .fill(LinearGradient(
                            colors: [Color(hex: "#0dcff5"), Color(hex: "#7c3aed"), Color(hex: "#d946ef")],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .shadow(color: Color(hex: "#7c3aed").opacity(hovered ? 0.55 : 0.3),
                                radius: hovered ? 20 : 12, x: 0, y: 6)
                )
                .scaleEffect(hovered ? 1.035 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.65), value: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A single mounted volume available as an offload destination in the onboarding picker.
private struct OnboardingVolume: Identifiable, Equatable {
    let id   = UUID()
    let name: String
    let path: String
    var freeGB: Double = 0
    static func == (l: OnboardingVolume, r: OnboardingVolume) -> Bool { l.path == r.path }
    var freeLabel: String {
        freeGB >= 1000 ? String(format: "%.1f TB free", freeGB / 1000)
                       : String(format: "%.0f GB free", freeGB)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
private struct OnboardingView: View {

    // ── Interface ─────────────────────────────────────────────────────────────
    var runDemo:    () -> Void
    @Binding var demoStatus: String   // "" → "Copying…" → "Transfer complete…"
    var onComplete: () -> Void

    // ── Page state ────────────────────────────────────────────────────────────
    @State private var page: Int = 0

    // ── Screen 1 illustration ─────────────────────────────────────────────────
    @State private var illustrationVisible = false
    @State private var iconPulse           = false
    @State private var arrowPulse          = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // ── Screen 2 ──────────────────────────────────────────────────────────────
    @AppStorage("pref_primarySSDPath")  private var savedDrivePath:  String = ""
    @AppStorage("pref_projectName")     private var savedProject:    String = ""
    @AppStorage("pref_useCustomDest")   private var ob2UseCustomDest: Bool   = false
    @AppStorage("pref_customDestPath")  private var ob2CustomDestPath: String = ""
    @AppStorage("pref_dateFolderFormat") private var ob2DateFormat:  String = "%y%m%d"
    @Namespace private var obDestSegNS   // liquid swoosh: SSD ↔ Custom Folder segment
    @State private var availableVolumes: [OnboardingVolume] = []
    @State private var selectedVolume:   OnboardingVolume?  = nil
    @State private var projectInput:     String             = ""
    @State private var showSkipNote:     Bool               = false

    // ── Screen 3 — Scaffold ───────────────────────────────────────────────────
    @AppStorage("pref_scaffoldEnabled")    private var ob3ScaffoldOn:  Bool   = false
    @AppStorage("pref_scaffoldFoldersRaw") private var ob3FoldersRaw: String = "Footage\nAudio\nGraphics\nExports\nAssets\nDocuments"
    @State private var ob3NewFolder: String = ""   // add-folder field on the editable scaffold list

    // ── Screen 4 — Live demo ──────────────────────────────────────────────────
    @State private var demoStarted:  Bool   = false
    @State private var modalOpacity: Double = 1.0

    // ── Dismiss ───────────────────────────────────────────────────────────────
    @State private var globalOpacity: Double = 1.0

    // ── Palette ───────────────────────────────────────────────────────────────
    // v3 brand palette — matches the main UI so the onboarding→app handoff is seamless.
    private let purple = Color(hex: "#7c3aed")
    private let blue   = Color(hex: "#0dcff5")
    private let muted  = Color.white.opacity(0.50)
    private let bgGrad = LinearGradient(
        colors: [Color(hex: "#0c0822"), Color(hex: "#080615"), Color(hex: "#050310")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // ─────────────────────────────────────────────────────────────────────────
    var body: some View {
        ZStack {
            // Background: fully opaque dark for pages 0–2, semi-transparent on page 3
            // so the real app UI glows through behind the modal card.
            Group {
                if page < 4 {
                    bgGrad
                    GeometryReader { g in
                        // Match v3Background's radial glows (purple top-left, cyan bottom-right).
                        RadialGradient(colors: [Color(hex: "#7c3aed").opacity(0.20), .clear],
                                       center: UnitPoint(x: 0.22, y: 0.08),
                                       startRadius: 0, endRadius: g.size.width * 0.70)
                        RadialGradient(colors: [Color(hex: "#0dcff5").opacity(0.13), .clear],
                                       center: UnitPoint(x: 0.84, y: 0.92),
                                       startRadius: 0, endRadius: g.size.width * 0.55)
                    }
                } else {
                    Color.black.opacity(0.22)
                }
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.55), value: page)

            // ── Page 0: existing Welcome celebration ──────────────────────
            if page == 0 {
                WelcomeCelebrationView(onComplete: { withAnimation(.easeInOut(duration: 0.42)) { page = 1 } },
                                       holdDuration: 1.5)
            }

            // ── Pages 1–3 ─────────────────────────────────────────────────
            // Constrain the content to a centered column so it doesn't sprawl edge-to-edge on a wide
            // window (bigger effective left/right padding, tighter center UI).
            if page == 1 { screen1.id("ob1").frame(maxWidth: 940).transition(pageSlide) }
            if page == 2 { screen2.id("ob2").frame(maxWidth: 940).transition(pageSlide) }
            if page == 3 { screen3.id("ob3").frame(maxWidth: 940).transition(pageSlide) }
            if page == 4 { screen4.id("ob4").frame(maxWidth: 940).transition(pageSlide) }
        }
        .animation(.easeInOut(duration: 0.46), value: page)
        .opacity(globalOpacity)
        .animation(.easeInOut(duration: 1.10), value: globalOpacity)
        .ignoresSafeArea()
    }

    private let pageSlide = AnyTransition.asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal:   .move(edge: .leading).combined(with: .opacity)
    )

    // ── Shared small logo mark at the top of screens 1–3 ─────────────────────
    private var logoMark: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(LinearGradient(
                colors: [blue, purple],
                startPoint: .top, endPoint: .bottom
            ))
            .padding(10)
            .background(Circle().fill(Color.white.opacity(0.07))
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1)))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Screen 1 — What this is
    // ─────────────────────────────────────────────────────────────────────────
    private var screen1: some View {
        VStack(spacing: 0) {
            logoMark.padding(.top, 44)

            Spacer()

            // Headline
            OnboardingReveal(
                "Your card just landed.\nLet's get it home.",
                font: .custom("SairaItalic-ExtraBoldItalic", size: 28),
                delay: 0.20,
                foreground: AnyShapeStyle(LinearGradient(
                    colors: [.white, Color(hex: "#b8d8ff")],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )),
                shadowColor: Color(hex: "#0eb0e9").opacity(0.50),
                shadowRadius: 18
            )
            .padding(.horizontal, 56)

            // Body copy
            OnboardingReveal(
                "CardRunner watches for camera cards and moves\nyour footage to the right place — automatically.\nNo dragging. No folders. No forgetting.",
                font: .system(size: 14),
                delay: 0.85,
                foreground: AnyShapeStyle(Color.white.opacity(0.52))
            )
            .padding(.horizontal, 56)
            .padding(.top, 18)

            // ── Animated illustration ──────────────────────────────────────
            flowIllustration
                .padding(.top, 46)
                .padding(.bottom, 54)
                .opacity(illustrationVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.8).delay(1.5), value: illustrationVisible)
                .onAppear {
                    illustrationVisible = true
                    guard !reduceMotion else { return }   // honor Reduce Motion — no perpetual pulse
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                            iconPulse = true
                        }
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                            arrowPulse = true
                        }
                    }
                }

            Spacer()

            OnboardingButton("Got it  →", color: purple) {
                loadVolumes()
                withAnimation(.easeInOut(duration: 0.46)) { page = 2 }
            }
            .padding(.bottom, 52)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var flowIllustration: some View {
        HStack(spacing: 16) {
            flowIcon("sdcard.fill",        "Card",        Color(hex: "#00F5FF"), delay: 0.0)
            flowArrow
            flowIcon("bolt.fill",          "CardRunner",  purple,                delay: 0.1)
            flowArrow
            flowIcon("externaldrive.fill", "Your Drive",  Color(hex: "#C9A7F5"), delay: 0.2)
        }
    }

    private func flowIcon(_ symbol: String, _ label: String, _ color: Color, delay: Double) -> some View {
        VStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .overlay(Circle().stroke(color.opacity(iconPulse ? 0.45 : 0.22), lineWidth: 1))
                    .frame(width: 58, height: 58)
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(color.opacity(iconPulse ? 1.0 : 0.78))
            }
            .scaleEffect(iconPulse ? 1.06 : 1.0)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(muted)
        }
        .frame(width: 88)
    }

    private var flowArrow: some View {
        VStack(spacing: 0) {
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(Color.white.opacity(arrowPulse ? 0.55 : 0.18))
        }
        .frame(width: 28)
        .offset(y: -10) // align with icon centre
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Screen 2 — Set destination
    // ─────────────────────────────────────────────────────────────────────────
    private var screen2: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                logoMark.padding(.top, 44)

                OnboardingReveal(
                    "Where should your\nfootage land?",
                    font: .custom("SairaItalic-ExtraBoldItalic", size: 26),
                    delay: 0.18,
                    foreground: AnyShapeStyle(LinearGradient(
                        colors: [.white, Color(hex: "#b8d8ff")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )),
                    shadowColor: Color(hex: "#0eb0e9").opacity(0.42),
                    shadowRadius: 14
                )
                .padding(.horizontal, 52)
                .padding(.top, 22)

                OnboardingReveal(
                    "Choose an SSD or pick any folder on your Mac.\nYou can always change this in Settings.",
                    font: .system(size: 13),
                    delay: 0.80,
                    foreground: AnyShapeStyle(Color.white.opacity(0.50))
                )
                .padding(.horizontal, 52)
                .padding(.top, 14)

                // ── SSD / Custom Folder toggle ─────────────────────────────
                HStack(spacing: 0) {
                    ob2PillTab(label: "SSD", isActive: !ob2UseCustomDest) {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { ob2UseCustomDest = false }
                    }
                    ob2PillTab(label: "Custom Folder", isActive: ob2UseCustomDest) {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { ob2UseCustomDest = true }
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.10), lineWidth: 1)))
                .padding(.horizontal, 44)
                .padding(.top, 28)

                // ── Mode-specific content ──────────────────────────────────
                if !ob2UseCustomDest {
                    // SSD mode: drive list + project folder
                    VStack(spacing: 8) {
                        if availableVolumes.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "externaldrive.badge.questionmark")
                                    .font(.system(size: 28))
                                    .foregroundStyle(Color.white.opacity(0.25))
                                Text("No external drives found.\nConnect your SSD and tap Refresh.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.white.opacity(0.35))
                                    .multilineTextAlignment(.center)
                                Button {
                                    loadVolumes()
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                                        Text("Refresh").font(.system(size: 12).weight(.medium))
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 8)
                                    .background(Capsule().fill(Color.white.opacity(0.09))
                                        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1)))
                                    .foregroundStyle(Color.white.opacity(0.60))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 28)
                        } else {
                            ForEach(availableVolumes) { vol in driveRow(vol) }
                        }
                    }
                    .padding(.horizontal, 44)
                    .padding(.top, 18)

                    // Project folder name
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Project folder name")
                            .font(.system(size: 11).weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.48))

                        HStack(spacing: 0) {
                            TextField("e.g. MyProject_2026", text: $projectInput)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(.white)

                            Divider()
                                .frame(height: 16)
                                .background(Color.white.opacity(0.15))
                                .padding(.horizontal, 10)

                            Button {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles       = false
                                panel.canChooseDirectories = true
                                panel.allowsMultipleSelection = false
                                panel.prompt  = "Choose"
                                panel.message = "Choose an existing project folder on your SSD."
                                if let vol = selectedVolume {
                                    panel.directoryURL = URL(fileURLWithPath: vol.path, isDirectory: true)
                                }
                                if panel.runModal() == .OK, let url = panel.url {
                                    projectInput = url.lastPathComponent
                                }
                            } label: {
                                Text("Browse…")
                                    .font(.system(size: 11).weight(.medium))
                                    .foregroundStyle(Color(hex: "#9B5FFF").opacity(0.9))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.06))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1))
                        )
                    }
                    .padding(.horizontal, 44)
                    .padding(.top, 18)

                } else {
                    // Custom Folder mode: choose button + path display
                    VStack(spacing: 14) {
                        Button {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles       = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.prompt = "Choose Folder"
                            panel.message = "Select the folder where CardRunner will ingest footage."
                            if panel.runModal() == .OK, let url = panel.url {
                                ob2CustomDestPath = url.path
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 14))
                                Text("Choose folder…")
                                    .font(.system(size: 13).weight(.medium))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22).padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white.opacity(0.08))
                                    .overlay(RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.16), lineWidth: 1))
                            )
                        }
                        .buttonStyle(.plain)

                        if !ob2CustomDestPath.isEmpty {
                            HStack(spacing: 7) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color(hex: "#0eb0e9"))
                                    .font(.system(size: 12))
                                Text(ob2CustomDestPath)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.white.opacity(0.55))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, 44)
                    .padding(.top, 24)
                }

                // ── Date folder info note ──────────────────────────────────
                let exampleDate: String = {
                    let f = DateFormatter()
                    f.dateFormat = ob2DateFormat
                        .replacingOccurrences(of: "%A", with: "EEEE")
                        .replacingOccurrences(of: "%Y", with: "yyyy")
                        .replacingOccurrences(of: "%y", with: "yy")
                        .replacingOccurrences(of: "%m", with: "MM")
                        .replacingOccurrences(of: "%d", with: "dd")
                    return f.string(from: Date())
                }()

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "#0eb0e9").opacity(0.70))
                        .padding(.top, 1)
                    Text("Your footage will land in a date folder — e.g. \(Text("`\(exampleDate)`").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(hex: "#0eb0e9").opacity(0.85))). The format is customizable in Settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.38))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 44)
                .padding(.top, 20)

                // Skip note
                if showSkipNote {
                    Text("You can set this up in the app anytime.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.30))
                        .padding(.top, 14)
                        .transition(.opacity)
                }

                Spacer().frame(height: 38)

                // ── Buttons ────────────────────────────────────────────────
                HStack(spacing: 16) {
                    Button {
                        withAnimation { showSkipNote = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            withAnimation(.easeInOut(duration: 0.46)) { page = 3 }
                        }
                    } label: {
                        Text("Skip for now")
                            .font(.system(size: 13).weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.38))
                            .padding(.horizontal, 24).padding(.vertical, 13)
                            .background(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    OnboardingButton("Next  →", color: purple) {
                        commitScreen2()
                        withAnimation(.easeInOut(duration: 0.46)) { page = 3 }
                    }
                }
                .padding(.bottom, 52)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { projectInput = "" }
    }

    @ViewBuilder
    private func ob2PillTab(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12).weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .white : Color.white.opacity(0.42))
                .padding(.horizontal, 20).padding(.vertical, 9)
                // Liquid swoosh: the purple pill flows (and morphs width) left↔right between tabs.
                .swooshSelection(isActive, in: obDestSegNS, groupID: "obDestSeg",
                                 fill: AnyShapeStyle(purple.opacity(0.85)), cornerRadius: 9,
                                 glow: purple.opacity(0.5), axis: .horizontal)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func driveRow(_ vol: OnboardingVolume) -> some View {
        let isSelected = selectedVolume?.path == vol.path
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 18))
                .foregroundStyle(isSelected ? purple : Color.white.opacity(0.42))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(vol.name)
                    .font(.system(size: 13).weight(.semibold))
                    .foregroundStyle(isSelected ? .white : Color.white.opacity(0.72))
                if vol.freeGB > 0 {
                    Text(vol.freeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(purple)
                    .font(.system(size: 16))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? purple.opacity(0.16) : Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? purple.opacity(0.52) : Color.white.opacity(0.09), lineWidth: 1))
        )
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.17)) { selectedVolume = vol } }
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }

    private func loadVolumes() {
        let fm  = FileManager.default
        let url = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(at: url,
                                                      includingPropertiesForKeys: nil,
                                                      options: .skipsHiddenFiles) else { return }
        let skip = ["preboot", "recovery", "vm", "update"]
        var vols: [OnboardingVolume] = []
        for item in items {
            let name  = item.lastPathComponent
            let path  = item.path
            let lower = name.lowercased()
            guard !skip.contains(lower), !lower.contains("macintosh hd") else { continue }
            // Skip obvious camera card layouts
            if fm.fileExists(atPath: item.appendingPathComponent("DCIM").path)      { continue }
            if fm.fileExists(atPath: item.appendingPathComponent("PRIVATE").path)   { continue }
            if fm.fileExists(atPath: item.appendingPathComponent("BPAV").path)      { continue }
            var free: Double = 0
            if let attrs = try? fm.attributesOfFileSystem(forPath: path),
               let bytes  = attrs[.systemFreeSize] as? Int64 {
                free = Double(bytes) / 1_073_741_824
            }
            vols.append(OnboardingVolume(name: name, path: path, freeGB: free))
        }
        availableVolumes = vols
        selectedVolume   = vols.first(where: { $0.path == savedDrivePath }) ?? vols.first
    }

    private func commitScreen2() {
        if ob2UseCustomDest {
            if !ob2CustomDestPath.isEmpty { /* ob2CustomDestPath already @AppStorage-bound */ }
        } else {
            if let vol = selectedVolume { savedDrivePath = vol.path }
        }
        // Persist the dest mode itself
        // (ob2UseCustomDest is @AppStorage so it's already written)
        if !projectInput.isEmpty { savedProject = projectInput }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Screen 3 — Project scaffold (editable — writes the SHARED scaffold list)
    // ─────────────────────────────────────────────────────────────────────────
    /// Parse/mutate the shared `ob3FoldersRaw` (= the app-wide `pref_scaffoldFoldersRaw`), so onboarding
    /// edits persist to the app + Settings identically. Dedupe on add (matches the app's addScaffoldFolder).
    private func ob3FolderList() -> [String] {
        ob3FoldersRaw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private func ob3AddFolder() {
        let n = ob3NewFolder.trimmingCharacters(in: .whitespaces)
        ob3NewFolder = ""
        // Allow a nested subpath ("Footage/A-Camera") for parity with the Settings editor, but never a
        // path-escape (.. or a leading /). The shell independently rejects escapes too (defense in depth).
        guard !n.isEmpty, !n.contains(".."), !n.hasPrefix("/") else { return }
        var list = ob3FolderList()
        guard !list.contains(where: { $0.lowercased() == n.lowercased() }) else { return }
        list.append(n)
        ob3FoldersRaw = list.joined(separator: "\n")
    }
    private func ob3RemoveFolder(at idx: Int) {
        var list = ob3FolderList()
        guard list.indices.contains(idx) else { return }
        list.remove(at: idx)
        ob3FoldersRaw = list.joined(separator: "\n")
    }

    private var screen3: some View {
        let folders = ob3FolderList()

        return VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                logoMark

                // Badge
                Text("Project scaffold")
                    .font(.system(size: 11).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(purple.opacity(0.88)))

                // Headline
                OnboardingReveal(
                    "Folders, ready before\nyou even hit ingest.",
                    font: .custom("SairaItalic-ExtraBoldItalic", size: 26),
                    delay: 0.15,
                    foreground: AnyShapeStyle(LinearGradient(
                        colors: [.white, Color(hex: "#c4b5fd")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )),
                    shadowColor: purple.opacity(0.35),
                    shadowRadius: 10
                )

                // Sub-headline
                OnboardingReveal(
                    "Every new project auto-creates these folders\non your destination drive.",
                    font: .system(size: 13),
                    delay: 0.55,
                    foreground: AnyShapeStyle(Color.white.opacity(0.50))
                )
                .multilineTextAlignment(.center)

                // ── Editable folder list ─────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(purple)
                        Text("{date}_Project Name").font(.system(size: 12).weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                        Spacer()
                    }
                    .padding(.bottom, 2)

                    ForEach(Array(folders.enumerated()), id: \.offset) { idx, folder in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(Color(hex: "#60a5fa").opacity(0.85))
                            Text(folder).font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
                            Spacer()
                            Button { ob3RemoveFolder(at: idx) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.3))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).v3Hover(scale: 1.15)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.05)))
                    }

                    // Add-folder row
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(purple)
                        TextField("Add a folder…", text: $ob3NewFolder).textFieldStyle(.plain)
                            .font(.system(size: 13)).foregroundStyle(.white).onSubmit { ob3AddFolder() }
                        Button { ob3AddFolder() } label: {
                            Text("Add").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Capsule().fill(purple.opacity(0.9))).contentShape(Capsule())
                        }.buttonStyle(.plain).v3Hover().disabled(ob3NewFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                .padding(16).frame(width: 460)
                .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08))))

                // ── Enable toggle (compact, proportional — was an oversized full-width banner) ──
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable project scaffold").font(.system(size: 13).weight(.medium)).foregroundStyle(.white)
                        Text("Customise anytime in Settings.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                    MiniPillToggle(isOn: $ob3ScaffoldOn)
                }
                .padding(.horizontal, 16).padding(.vertical, 12).frame(width: 460)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08))))

                // ── CTAs ─────────────────────────────────────────────────
                OnboardingButton("Next  →", color: purple) {
                    withAnimation(.easeInOut(duration: 0.46)) { page = 4 }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.46)) { page = 4 }
                } label: {
                    Text("Skip")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.28))
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 52)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Default scaffold ON for new users seeing this screen for the first time
            if !ob3ScaffoldOn { ob3ScaffoldOn = true }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Screen 4 — Live simulation
    // ─────────────────────────────────────────────────────────────────────────
    private var screen4: some View {
        let isDone    = demoStatus.hasPrefix("Transfer complete")
        let isRunning = demoStarted && !isDone

        return ZStack {
            VStack(spacing: 0) {
                Spacer()

                // ── Glassmorphic modal card ────────────────────────────────
                VStack(spacing: 22) {
                    // Purple pill badge
                    Text("See it in action")
                        .font(.system(size: 11).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(purple.opacity(0.88)))

                    // Headline
                    OnboardingReveal(
                        "Watch what happens\nwhen a card comes in.",
                        font: .custom("SairaItalic-ExtraBoldItalic", size: 24),
                        delay: 0.22,
                        foreground: AnyShapeStyle(LinearGradient(
                            colors: [.white, Color(hex: "#b8d8ff")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )),
                        shadowColor: Color(hex: "#0eb0e9").opacity(0.40),
                        shadowRadius: 12
                    )

                    if !demoStarted {
                        OnboardingReveal(
                            "We'll run a quick demo so you know\nexactly what to expect.",
                            font: .system(size: 13),
                            delay: 0.85,
                            foreground: AnyShapeStyle(Color.white.opacity(0.50))
                        )
                    }

                    // Play button
                    if !demoStarted {
                        Button {
                            demoStarted = true
                            withAnimation(.easeInOut(duration: 0.38)) { modalOpacity = 0.0 }
                            runDemo()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(
                                        colors: [purple, blue],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ))
                                    .frame(width: 70, height: 70)
                                    .shadow(color: purple.opacity(0.50), radius: 16, x: 0, y: 6)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.white)
                                    .offset(x: 3)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }

                    // Status text
                    if !demoStatus.isEmpty {
                        Text(demoStatus)
                            .font(.system(size: 12))
                            .foregroundStyle(isDone
                                ? Color(hex: "#34D399")
                                : Color.white.opacity(0.60))
                            .multilineTextAlignment(.center)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Completion message
                    if isDone {
                        OnboardingReveal(
                            "That's it. Every card, every time.",
                            font: .system(size: 14).weight(.medium),
                            delay: 0.20,
                            foreground: AnyShapeStyle(Color.white.opacity(0.78))
                        )
                        .transition(.opacity)
                    }

                    // CTA
                    if isDone || demoStarted {
                        OnboardingButton("Start using CardRunner  →", color: purple) {
                            globalOpacity = 0
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { onComplete() }
                        }
                        .disabled(isRunning)
                        .opacity(isRunning ? 0.35 : 1.0)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Skip link (before demo starts)
                    if !demoStarted {
                        Button {
                            globalOpacity = 0
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { onComplete() }
                        } label: {
                            Text("Skip demo")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.28))
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 52).padding(.vertical, 46)
                .background(
                    // v3 module surface (#0c0822, radius 22) + a brand gradient edge.
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(hex: "#0c0822").opacity(0.94))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(LinearGradient(
                                    colors: [blue.opacity(0.5), purple.opacity(0.5), Color(hex: "#d946ef").opacity(0.4)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ), lineWidth: 1.5)
                        )
                        .shadow(color: .black.opacity(0.55), radius: 34, x: 0, y: 18)
                )
                .opacity(modalOpacity)
                .animation(.easeInOut(duration: 0.48), value: modalOpacity)
                .onChange(of: isDone) {
                    if isDone { withAnimation(.easeInOut(duration: 0.48)) { modalOpacity = 1.0 } }
                }

                Spacer()
            }
            .padding(.horizontal, 80)
        }
        .animation(.easeInOut(duration: 0.40), value: demoStarted)
        .animation(.easeInOut(duration: 0.40), value: isDone)
    }
}

// MARK: - Buy Link (hover + pointer cursor)

private struct BuyLink: View {
    @State private var hovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "https://xaviergallo.lemonsqueezy.com/checkout")!)
        } label: {
            Text("Buy CardRunner →")
                .font(.system(size:13).weight(.semibold))
                .foregroundStyle(Color(hex: "#0eb0e9").opacity(hovered ? 1.0 : 0.85))
                .underline(hovered)
                .scaleEffect(hovered ? 1.03 : 1.0)
                .animation(.easeInOut(duration: 0.12), value: hovered)
        }
        .buttonStyle(.plain)
        .onHover { over in
            withAnimation(.easeInOut(duration: 0.12)) { hovered = over }
            if over {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Popover Row (hover-aware menu row)

// MARK: - New Project Popover

private struct FolderColorSwatch: Identifiable {
    let id:      Int    // Finder label number
    let color:   Color
    let name:    String
}

private let kFolderColorSwatches: [FolderColorSwatch] = [
    .init(id: 0, color: Color(white: 0.55).opacity(0.35), name: "None"),
    .init(id: 6, color: Color(red: 0.96, green: 0.29, blue: 0.27),  name: "Red"),
    .init(id: 7, color: Color(red: 1.00, green: 0.62, blue: 0.04),  name: "Orange"),
    .init(id: 5, color: Color(red: 0.98, green: 0.84, blue: 0.07),  name: "Yellow"),
    .init(id: 2, color: Color(red: 0.27, green: 0.80, blue: 0.38),  name: "Green"),
    .init(id: 4, color: Color(red: 0.22, green: 0.56, blue: 0.99),  name: "Blue"),
    .init(id: 3, color: Color(red: 0.68, green: 0.36, blue: 0.97),  name: "Purple"),
    .init(id: 1, color: Color(white: 0.60),                          name: "Gray"),
]

private struct NewProjectPopover: View {
    @Binding var name:        String
    @Binding var folderColor: Int
    @Binding var isPresented: Bool
    let primaryName:     String
    let scaffoldEnabled: Bool
    let scaffoldFolders: [String]
    @Binding var hintShown: Bool
    let useLightMode:    Bool
    let onCreate:        () -> Void
    let onOpenSettings:  () -> Void

    @FocusState private var nameFocused: Bool

    private var bg:      Color { useLightMode ? Color(hex: "#E8EDF4") : Color(hex: "#0d1e36") }
    private var surface: Color { useLightMode ? Color.white.opacity(0.85) : Color.white.opacity(0.07) }
    private var textPrimary:   Color { useLightMode ? Color(hex: "#0f1b2d") : .white }
    private var textSecondary: Color { useLightMode ? Color(hex: "#6B7A92") : Color(hex: "#7A8EA8") }
    private var accent:        Color { Color(hex: "#2563EB") }
    private var amber:         Color { Color(hex: "#F59E0B") }

    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 3) {
                Text("New Project Folder")
                    .font(.system(size:13).weight(.semibold))
                    .foregroundStyle(textPrimary)
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 10))
                    Text("\(primaryName)/")
                        .font(.system(size:11))
                }
                .foregroundStyle(textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().opacity(0.25)

            // ── Name field ──────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Folder name")
                    .font(.system(size:10).weight(.medium))
                    .foregroundStyle(textSecondary)
                    .textCase(.uppercase)
                    .kerning(0.5)

                TextField("e.g. ClientShoot", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size:13))
                    .foregroundStyle(textPrimary)
                    .focused($nameFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(surface)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(nameFocused ? accent.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .onSubmit { if canCreate { onCreate() } }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // ── Folder color ─────────────────────────────────────────────────
            Divider().opacity(0.25)

            VStack(alignment: .leading, spacing: 7) {
                Text("Folder color")
                    .font(.system(size:10).weight(.medium))
                    .foregroundStyle(textSecondary)
                    .textCase(.uppercase)
                    .kerning(0.5)

                HStack(spacing: 7) {
                    ForEach(kFolderColorSwatches) { swatch in
                        Button {
                            folderColor = swatch.id
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(swatch.color)
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                folderColor == swatch.id
                                                    ? Color.white.opacity(0.9)
                                                    : Color.white.opacity(0.18),
                                                lineWidth: folderColor == swatch.id ? 2 : 1
                                            )
                                    )
                                if folderColor == swatch.id && swatch.id != 0 {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                                if folderColor == swatch.id && swatch.id == 0 {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Color(white: 0.55))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help(swatch.name)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // ── Scaffold preview ────────────────────────────────────────────
            if scaffoldEnabled && !scaffoldFolders.isEmpty {
                Divider().opacity(0.25)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 10))
                        Text("Scaffold folders will be created inside")
                            .font(.system(size:10).weight(.medium))
                    }
                    .foregroundStyle(accent.opacity(0.9))

                    let displayed = scaffoldFolders.prefix(8)
                    FlowLayout(spacing: 4) {
                        ForEach(Array(displayed.enumerated()), id: \.offset) { _, folder in
                            Text(folder)
                                .font(.system(size:10).weight(.medium))
                                .foregroundStyle(textSecondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(surface)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        if scaffoldFolders.count > 8 {
                            Text("+\(scaffoldFolders.count - 8) more")
                                .font(.system(size:10))
                                .foregroundStyle(textSecondary.opacity(0.6))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            // ── First-time hint ─────────────────────────────────────────────
            if !hintShown {
                Divider().opacity(0.25)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(amber)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("You can customise which folders get auto-created on every new project — enable scaffold and edit your list in Settings.")
                            .font(.system(size:10))
                            .foregroundStyle(textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Open Settings → Advanced") {
                            hintShown = true
                            onOpenSettings()
                        }
                        .font(.system(size:10).weight(.semibold))
                        .foregroundStyle(accent)
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Button {
                        hintShown = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(textSecondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(amber.opacity(0.07))
            }

            Divider().opacity(0.25)

            // ── Buttons ─────────────────────────────────────────────────────
            HStack(spacing: 8) {
                Button("Cancel") {
                    isPresented = false
                }
                .font(.system(size:12))
                .foregroundStyle(textSecondary)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(surface)
                .clipShape(RoundedRectangle(cornerRadius: 7))

                Button("Create Folder") {
                    onCreate()
                }
                .font(.system(size:12).weight(.semibold))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(canCreate ? accent : accent.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .disabled(!canCreate)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 300)
        .background(bg)
        .preferredColorScheme(useLightMode ? .light : .dark)
        .onAppear { nameFocused = true }
    }
}

// Minimal flow layout for tag chips
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? 240
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > containerWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: containerWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A menu row that highlights softly on hover before the user clicks.
private struct PopoverRow<Content: View>: View {
    let isActive: Bool
    let useLightMode: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovered
                              ? Color.white.opacity(useLightMode ? 0.5 : 0.07)
                              : Color.clear)
                        .animation(.easeInOut(duration: 0.12), value: hovered)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over in
            withAnimation(.easeInOut(duration: 0.12)) { hovered = over }
        }
    }
}

// MARK: - SmoothScrollView
/// Drop-in vertical ScrollView that delegates to NSScrollView directly,
/// giving AppKit-quality momentum scrolling — elastic bounce at edges,
/// silky deceleration, GPU-composited rendering (copiesOnScroll = false).
///
/// - `showsIndicators`: whether to attach a vertical scroller at all.
/// - `alwaysShowScroller`: when `true`, the scroller knob stays visible without hover
///   and is tinted for dark backgrounds. Ignored when `showsIndicators` is false.
private struct SmoothScrollView<Content: View>: NSViewRepresentable {
    var showsIndicators: Bool    = true
    var alwaysShowScroller: Bool = false
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground              = false
        scroll.hasVerticalScroller          = showsIndicators
        scroll.hasHorizontalScroller        = false
        scroll.autohidesScrollers           = showsIndicators ? !alwaysShowScroller : true
        scroll.usesPredominantAxisScrolling = false
        scroll.horizontalScrollElasticity   = .none
        scroll.verticalScrollElasticity     = .allowed   // rubber-band at top/bottom

        // Dark-UI scroller: light knob + overlay style so it floats over content
        // without stealing layout width.
        if alwaysShowScroller {
            scroll.scrollerStyle = .overlay
            scroll.verticalScroller?.knobStyle = .light
        }

        let clip = NSClipView()
        clip.drawsBackground = false
        scroll.contentView   = clip

        let host = NSHostingView(rootView: content())
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host

        // Pin width to the clip so vertical-only scrolling works correctly.
        NSLayoutConstraint.activate([
            host.leadingAnchor .constraint(equalTo: clip.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            host.topAnchor     .constraint(equalTo: clip.topAnchor),
        ])

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let host = scroll.documentView as? NSHostingView<Content> else { return }
        host.rootView = content()

        // Keep scroller visibility in sync when the caller's state changes
        // (e.g. history grows past the 5-row threshold).
        scroll.hasVerticalScroller = showsIndicators
        scroll.autohidesScrollers  = showsIndicators ? !alwaysShowScroller : true
        if alwaysShowScroller {
            scroll.scrollerStyle = .overlay
            scroll.verticalScroller?.knobStyle = .light
        }

        // Tell Auto Layout the hosting view's intrinsic height may have changed so
        // the scroll view recalculates its document area on the next layout pass.
        // Without this, fast content additions (e.g. new history rows) can leave the
        // scroll indicator misaligned or make the view temporarily unscrollable.
        host.invalidateIntrinsicContentSize()
    }
}

/// A white orb that slides inside a coloured track — no text, easy to tap,
/// same underdamped spring as the Video/Photo and Dark/Light pill controls.
private struct MiniPillToggle: View {
    @Binding var isOn: Bool
    /// Track gradient start colour when ON. Blends into neonPurple at the right end.
    var onColor: Color = CardRunnerTheme.neonBlue

    @Environment(\.colorScheme) private var colorScheme

    private let spring   = Animation.spring(response: 0.32, dampingFraction: 0.62)
    private let trackW:  CGFloat = 52
    private let trackH:  CGFloat = 30
    private let orbSize: CGFloat = 24

    private var isLight: Bool { colorScheme == .light }
    private var trackEndColor: Color { isLight ? CardRunnerTheme.neonPurpleDark : CardRunnerTheme.neonPurple }

    /// How far the orb travels from centre to each end (leaves a 2 pt gap at the edge).
    private var travel: CGFloat { (trackW - orbSize) / 2 - 2 }

    var body: some View {
        ZStack {
            // ── Track ─────────────────────────────────────────────────────
            Capsule(style: .continuous)
                .fill(
                    isOn
                        ? AnyShapeStyle(LinearGradient(
                            colors: [onColor.opacity(0.90),
                                     trackEndColor.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing))
                        : AnyShapeStyle(isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.10))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isOn ? onColor.opacity(0.55) : (isLight ? Color.black.opacity(0.20) : Color.white.opacity(0.14)),
                            lineWidth: 1
                        )
                )
                .shadow(color: isOn ? onColor.opacity(0.45) : .clear, radius: 7, y: 2)
                .frame(width: trackW, height: trackH)
                .animation(spring, value: isOn)

            // ── Orb ───────────────────────────────────────────────────────
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white, Color.white.opacity(0.88)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: orbSize, height: orbSize)
                .shadow(color: .black.opacity(isOn ? 0.16 : 0.28), radius: 2, x: 0, y: 1)
                .shadow(color: isOn ? onColor.opacity(0.38) : .clear, radius: 5)
                .offset(x: isOn ? travel : -travel)
                .animation(spring, value: isOn)
        }
        .frame(width: trackW, height: trackH)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(spring) { isOn.toggle() }
        }
    }
}

// MARK: - Toggle Style

struct ColoredSwitchToggleStyle: ToggleStyle {
    var onColor: Color = .green
    var offColor: Color = .gray

    // Same spring as the video/photo pill for a consistent feel across the whole UI
    private let spring = Animation.spring(response: 0.32, dampingFraction: 0.62)

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()

            ZStack {
                // ── Track ──────────────────────────────────────────────────
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: configuration.isOn
                                ? [onColor.opacity(0.95),
                                   CardRunnerTheme.neonPurple.opacity(0.75)]
                                : [offColor.opacity(0.45),
                                   offColor.opacity(0.30)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 26)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                configuration.isOn
                                    ? onColor.opacity(0.55)
                                    : Color.white.opacity(0.12),
                                lineWidth: 1
                            )
                    )
                    // Outer glow when ON — matches the neon pill aesthetic
                    .shadow(
                        color: configuration.isOn ? onColor.opacity(0.50) : .clear,
                        radius: 7, y: 2
                    )
                    .animation(spring, value: configuration.isOn)

                // ── Knob ───────────────────────────────────────────────────
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white, Color.white.opacity(0.88)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 20, height: 20)
                    .shadow(
                        color: Color.black.opacity(configuration.isOn ? 0.18 : 0.28),
                        radius: 2, x: 0, y: 1
                    )
                    // Subtle colour echo under the knob when ON
                    .shadow(
                        color: configuration.isOn ? onColor.opacity(0.40) : .clear,
                        radius: 5, y: 0
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 0.75))
                    .offset(x: configuration.isOn ? 10 : -10)
                    .animation(spring, value: configuration.isOn)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(spring) { configuration.isOn.toggle() }
            }
        }
    }
}

// MARK: - GroupBox Style

// MARK: - Sparkline

/// A filled area chart showing rolling MB/s speed during an active ingest.
// MARK: - Resume Checkpoint Row

private struct ResumeCheckpointRow: View {
    let checkpoint: IngestCheckpoint
    let cardMounted: Bool
    let ssdMounted: Bool
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let onResume: () -> Void
    let onDiscard: () -> Void

    private var canResume: Bool { cardMounted && ssdMounted }

    private var timeAgo: String {
        let elapsed = Date().timeIntervalSince(checkpoint.startedAt)
        if elapsed < 3600  { return "\(Int(elapsed / 60)) min ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600)) hr ago" }
        return "\(Int(elapsed / 86400)) days ago"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Card + project info
            HStack(spacing: 12) {
                Image(systemName: "sdcard.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color(hex: "#0eb0e9"))

                VStack(alignment: .leading, spacing: 3) {
                    Text(checkpoint.cardName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(textPrimary)
                    Text("→ \(checkpoint.projectName)")
                        .font(.caption)
                        .foregroundStyle(textSecondary)
                    Text("Started \(timeAgo)  ·  \(checkpoint.mode) mode")
                        .font(.caption2)
                        .foregroundStyle(textMuted)
                }
                Spacer()
            }

            // Mount status badges
            HStack(spacing: 8) {
                Label(cardMounted ? "Card mounted" : "Card not found",
                      systemImage: cardMounted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(cardMounted ? Color.green : Color(hex: "#F59E0B"))

                Label(ssdMounted ? "SSD mounted" : "SSD not found",
                      systemImage: ssdMounted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(ssdMounted ? Color.green : Color(hex: "#F59E0B"))
            }

            // Action buttons
            HStack(spacing: 10) {
                Button(action: onResume) {
                    Label(canResume ? "Resume Transfer" : "Insert Card to Resume",
                          systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(canResume ? Color(hex: "#0eb0e9") : Color(hex: "#F59E0B"))
                .disabled(!canResume)

                Button(action: onDiscard) {
                    Label("Discard", systemImage: "trash")
                        .font(.caption.weight(.medium))
                        .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .foregroundStyle(Color.red.opacity(0.85))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        )
    }
}

struct SparklineView: View {
    let samples: [Double]       // MB/s values, oldest first
    let currentMBps: Double     // displayed as live readout
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.0f", currentMBps))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                Text("MB/s")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(color.opacity(0.7))
                Spacer()
                Text("live speed")
                    .font(.system(size: 9))
                    .foregroundStyle(color.opacity(0.45))
            }

            Canvas { ctx, size in
                guard samples.count >= 2 else { return }
                let maxVal = max(samples.max() ?? 1.0, 1.0)
                let w = size.width
                let h = size.height
                let step = w / CGFloat(samples.count - 1)

                // Build the line path
                var linePath = Path()
                for (i, val) in samples.enumerated() {
                    let x = CGFloat(i) * step
                    let y = h - CGFloat(val / maxVal) * h * 0.9  // 0.9 leaves a little headroom
                    if i == 0 { linePath.move(to: CGPoint(x: x, y: y)) }
                    else       { linePath.addLine(to: CGPoint(x: x, y: y)) }
                }

                // Filled area under the line
                var fillPath = linePath
                let lastX = CGFloat(samples.count - 1) * step
                fillPath.addLine(to: CGPoint(x: lastX, y: h))
                fillPath.addLine(to: CGPoint(x: 0,     y: h))
                fillPath.closeSubpath()
                ctx.fill(fillPath, with: .color(color.opacity(0.15)))

                // Line on top
                ctx.stroke(linePath, with: .color(color.opacity(0.85)), lineWidth: 1.5)
            }
            .frame(height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

struct CardRunnerGroupBoxStyle: GroupBoxStyle {
    let border: Color
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            fill.opacity(1.0),
                            fill.opacity(0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    CardRunnerTheme.neonBlue.opacity(0.28),
                                    CardRunnerTheme.neonPurple.opacity(0.28)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.7
                        )
                )
                .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 10)
        )
    }
}
extension View {
    /// Applies Apple's Liquid Glass effect when available, and falls back to the
    /// original view on older macOS versions.
    @ViewBuilder
    func optionalGlassEffect() -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular)
        } else {
            self
        }
        #else
        if #available(iOS 18.0, *) {
            self.glassEffect(.regular)
        } else {
            self
        }
        #endif
    }

    /// Sliding "swoosh" selection background — a single matched-geometry pill that lives in
    /// the CURRENTLY-selected item's slot. When `isSelected` flips inside a `withAnimation`,
    /// SwiftUI interpolates the pill's frame from the old slot to the new one, so it flies
    /// (swooshes) between them instead of just appearing. As it travels it deforms — elongating
    /// along the travel `axis`, thinning across it, and rounding toward a capsule — then settles
    /// back into the pill, so it reads like liquid flowing rather than a rigid box sliding.
    ///
    /// Reusable across any selection group (settings rail, segmented toggles, tab bars):
    /// apply to EVERY item in the group with the SAME `namespace` + `groupID` (one groupID
    /// per independent selector), and drive the selection change inside
    /// `withAnimation(.spring(...))`. Pass the brand fill as `AnyShapeStyle(...)`. Use
    /// `axis: .horizontal` for left/right selectors so the stretch follows the motion.
    func swooshSelection(_ isSelected: Bool,
                         in namespace: Namespace.ID,
                         groupID: String,
                         fill: AnyShapeStyle,
                         cornerRadius: CGFloat = 13,
                         glow: Color? = nil,
                         glowRadius: CGFloat = 12,
                         axis: Axis = .vertical) -> some View {
        modifier(SwooshSelectionModifier(isSelected: isSelected, namespace: namespace,
                                         groupID: groupID, fill: fill, cornerRadius: cornerRadius,
                                         glow: glow, glowRadius: glowRadius, axis: axis))
    }
}

/// Backs `View.swooshSelection` — a matched-geometry pill with a one-shot liquid "smear" as it
/// travels. The stretch is a self-contained pulse (0 → peak → 0) triggered when this item becomes
/// selected; it decays with an under-damped spring so the pill wobbles into shape like a droplet.
private struct SwooshSelectionModifier: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID
    let groupID: String
    let fill: AnyShapeStyle
    let cornerRadius: CGFloat
    let glow: Color?
    let glowRadius: CGFloat
    let axis: Axis
    /// 0 = settled pill · 1 = mid-flight liquid smear.
    @State private var smear: CGFloat = 0
    // Reduce Motion: skip the squash-and-stretch flourish (the pill still repositions, it just
    // doesn't distort). UI-future.md: respect Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.background {
            if isSelected {
                RoundedRectangle(cornerRadius: cornerRadius + smear * 10, style: .continuous)
                    .fill(fill)
                    .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : glowRadius + smear * 8)
                    // Elongate along the travel axis, thin across it — squash-and-stretch = liquid.
                    .scaleEffect(x: axis == .horizontal ? 1 + smear * 0.5 : 1 - smear * 0.22,
                                 y: axis == .horizontal ? 1 - smear * 0.22 : 1 + smear * 0.5,
                                 anchor: .center)
                    .matchedGeometryEffect(id: groupID, in: namespace)
                    .onAppear { pulse() }
            }
        }
        .onChange(of: isSelected) { _, now in if now { pulse() } }
    }

    /// One-shot: ramp into the smear fast as the pill departs, then let it wobble back to shape
    /// over the travel. No always-on animation (see the TimelineView core-burn gotcha).
    private func pulse() {
        guard !reduceMotion else { smear = 0; return }   // no liquid distortion under Reduce Motion
        withAnimation(.easeOut(duration: 0.14)) { smear = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.55)) { smear = 0 }
        }
    }
}
// MARK: - Shimmer Bar

struct ShimmerBar: View {
    @State private var phase: CGFloat = -0.6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.1))

                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.0),
                                Color.white.opacity(0.45),
                                Color.white.opacity(0.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: geo.size.width * phase)
                    .animation(
                        .linear(duration: 1.4)
                            .repeatForever(autoreverses: false),
                        value: phase
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .onAppear {
                phase = 1.2
            }
        }
    }
}
// MARK: - Shortcuts Help View

// MARK: - Shortcut Recorder Row

private struct ShortcutRecorderRow: View {
    let label: String
    let shortcut: RecordedShortcut
    let isRecording: Bool
    let onTap: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack {
            Text(label)
                .font(.body)
            Spacer()
            if !shortcut.isNone && !isRecording {
                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
            Button(action: onTap) {
                Text(isRecording ? "Press keys…" : shortcut.displayString)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .foregroundStyle(isRecording ? .white : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isRecording
                                ? CardRunnerTheme.neonBlue.opacity(0.7)
                                : Color.secondary.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(isRecording ? CardRunnerTheme.neonBlue : .clear,
                                                  lineWidth: 1.5)
                            )
                    )
                    .animation(.easeInOut(duration: 0.15), value: isRecording)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Card Queue Row

/// Small ⓘ button that reveals a detail popover on tap.
private struct InfoPopover: View {
    let text: String
    @State private var show = false
    init(_ text: String) { self.text = text }
    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(width: 300)
        }
    }
}

/// A standard toggle row used throughout the Settings sheet.
private struct SettingsRow: View {
    @Binding var toggle: Bool
    let title: String
    let detail: String          // short subtitle, always visible
    var icon: String? = nil     // SF Symbol shown to the left of the title
    var info: String? = nil     // longer explanation shown in ⓘ popover
    var badge: String? = nil
    var onChange: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor.opacity(0.75))
                        .frame(width: 16)
                }
                Toggle(title, isOn: $toggle)
                    .font(.body)
                    .onChange(of: toggle) { onChange?() }
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                if let info {
                    InfoPopover(info)
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CardQueueRow: View {
    let name: String
    let subtitle: String
    let progress: Double?      // nil = queued, non-nil = actively copying
    let textPrimary: Color
    let textSecondary: Color
    var clipInfo: String? = nil  // e.g. "47 clips  ·  12 new"
    var finalizing: Bool = false // end-of-transfer F_FULLFSYNC flush in progress

    @State private var pulse = false
    @Environment(\.colorScheme) private var colorScheme
    private var isLight: Bool { colorScheme == .light }
    private var rowAccentBlue:   Color { isLight ? CardRunnerTheme.neonBlueDark   : CardRunnerTheme.neonBlue }
    private var rowAccentPurple: Color { isLight ? CardRunnerTheme.neonPurpleDark : CardRunnerTheme.neonPurple }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sdcard.fill")
                .font(.system(size: 26))
                .foregroundStyle(
                    progress != nil ? rowAccentBlue : Color.secondary.opacity(0.6)
                )
                .shadow(
                    color: progress != nil ? rowAccentBlue.opacity(0.5) : .clear,
                    radius: 8
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(textPrimary)

                if let fraction = progress {
                    // While flushing, the data is fully copied (bar full) — pulse it so it
                    // reads as "committing", not stuck at 99%.
                    let barFraction = finalizing ? 1.0 : min(max(fraction, 0), 1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(
                                        colors: [rowAccentBlue, rowAccentPurple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * CGFloat(barFraction), height: 4)
                                .opacity(finalizing && pulse ? 0.4 : 1.0)
                                .animation(.easeInOut(duration: 0.18), value: barFraction)
                        }
                    }
                    .frame(height: 4)
                    // Clip count badge beneath the progress bar
                    if let info = clipInfo {
                        Text(info)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(textSecondary.opacity(0.7))
                    }
                } else {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(textSecondary)
                }
            }

            Spacer()

            if let fraction = progress {
                Text(finalizing ? "Finalizing…" : "\(Int(fraction * 100))%")
                    .font(.system(size: 11, design: .monospaced).weight(.medium))
                    .foregroundStyle(textSecondary)
            }
        }
        .onChange(of: finalizing) { _, now in
            // Start/stop the perpetual flush pulse.
            withAnimation(now ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true) : .default) {
                pulse = now
            }
        }
        .onAppear {
            if finalizing {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulse = true }
            }
        }
    }
}

// MARK: - Dock Progress Bar

private final class DockProgressView: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Base: app icon
        NSApp.applicationIconImage?.draw(in: bounds)

        let barH = max(6, bounds.height * 0.07)
        let trackRect = CGRect(x: 0, y: 0, width: bounds.width, height: barH)

        // Dark track
        NSColor(white: 0, alpha: 0.7).setFill()
        trackRect.fill()

        // White fill — clamp so it never overflows
        let fillW = bounds.width * CGFloat(min(max(fraction, 0), 1))
        if fillW > 0 {
            CGRect(x: 0, y: 0, width: fillW, height: barH).fill()  // inherits white
            NSColor.white.setFill()
            CGRect(x: 0, y: 0, width: fillW, height: barH).fill()
        }
    }
}

enum DockProgress {
    private static let view = DockProgressView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))

    static func update(_ fraction: Double) {
        if NSApp.dockTile.contentView == nil {
            NSApp.dockTile.contentView = view
        }
        view.fraction = fraction
        NSApp.dockTile.display()
    }

    static func clear() {
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

// MARK: - License Gate View

struct LicenseGateView: View {
    @ObservedObject private var license = LicenseManager.shared
    @State private var keyInput: String = ""
    @State private var isActivating: Bool = false
    @State private var errorMessage: String? = nil
    @State private var activateHovered: Bool = false

    private var useLightMode: Bool { false }   // light mode removed — dark-only

    private var bgColor: Color { useLightMode ? Color(hex: "#F4F6FD") : Color(hex: "#090f1e") }
    private var textPrimary: Color { useLightMode ? .black : .white }
    private var textSecondary: Color { useLightMode ? Color.black.opacity(0.6) : Color.white.opacity(0.6) }
    private var fieldBg: Color { useLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.07) }
    private var borderColor: Color { useLightMode ? Color.black.opacity(0.12) : Color.white.opacity(0.12) }
    private var canActivate: Bool { !isActivating && !keyInput.trimmingCharacters(in: .whitespaces).isEmpty }
    private var activateBtnColor: Color {
        if !canActivate { return Color(hex: "#0eb0e9").opacity(0.45) }
        if activateHovered {
            if #available(macOS 15.0, *) {
                return Color(hex: "#0eb0e9").mix(with: .white, by: 0.1)
            } else {
                return Color(hex: "#26B8EB") // pre-computed: #0eb0e9 + 10 % white
            }
        }
        return Color(hex: "#0eb0e9")
    }

    var body: some View {
        ZStack {
            // Background — matches the app's own bg
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo + title
                VStack(spacing: 16) {
                    Image("CardRunnerLogo")
                        .resizable()
                        .renderingMode(.original)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 62)
                        .shadow(color: Color(hex: "#0eb0e9").opacity(0.5), radius: 16)

                    Text("CardRunner")
                        .font(.custom("Tech Headlines Italic", size: 28))
                        .foregroundStyle(textPrimary)

                    Text("A smoother ingest workflow for creators")
                        .font(.system(size:14))
                        .foregroundStyle(textSecondary)
                }

                Spacer().frame(height: 40)

                // Key entry card
                VStack(alignment: .leading, spacing: 12) {

                    // Revoked / migration banner — only shown when a previous key was rejected
                    if license.isRevoked {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color(hex: "#F59E0B"))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Your license key needs to be updated")
                                    .font(.system(size:12).weight(.semibold))
                                    .foregroundStyle(textPrimary)
                                Text("We've moved our store. Please enter the new key from your purchase email or dashboard.")
                                    .font(.system(size:11))
                                    .foregroundStyle(textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color(hex: "#F59E0B").opacity(0.09))
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .stroke(Color(hex: "#F59E0B").opacity(0.3), lineWidth: 1))
                        )
                    }

                    Text("LICENSE KEY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(textSecondary.opacity(0.7))
                        .kerning(1.2)

                    HStack(spacing: 0) {
                        TextField("XXXX-XXXX-XXXX-XXXX", text: $keyInput)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(textPrimary)
                            .textFieldStyle(.plain)
                            .onChange(of: keyInput) {
                                keyInput = keyInput.uppercased()
                                errorMessage = nil
                            }
                            .onSubmit { activateKey() }

                        if keyInput.isEmpty {
                            Button {
                                if let str = NSPasteboard.general.string(forType: .string) {
                                    keyInput = str.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                                    errorMessage = nil
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.on.clipboard")
                                        .font(.system(size: 11))
                                    Text("Paste")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(Color(hex: "#0eb0e9"))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color(hex: "#0eb0e9").opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(fieldBg)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
                    )

                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(action: activateKey) {
                        HStack {
                            if isActivating {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Text(isActivating ? "Activating…" : "Activate CardRunner")
                                .font(.system(size:14).weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(activateBtnColor)
                                .shadow(
                                    color: activateHovered && canActivate
                                        ? Color(hex: "#0eb0e9").opacity(0.55)
                                        : .clear,
                                    radius: 12, y: 4
                                )
                        )
                        .scaleEffect(activateHovered && canActivate ? 1.015 : 1.0)
                        .animation(.easeInOut(duration: 0.14), value: activateHovered)
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canActivate)
                    .onHover { over in
                        withAnimation(.easeInOut(duration: 0.14)) { activateHovered = over }
                        if over && canActivate { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(useLightMode ? Color.white.opacity(0.7) : Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderColor, lineWidth: 1))
                )
                .frame(maxWidth: 380)

                Spacer().frame(height: 24)

                // Buy link
                HStack(spacing: 4) {
                    Text("Don't have a license?")
                        .font(.system(size:13))
                        .foregroundStyle(textSecondary)
                    BuyLink()
                }

                Spacer()
            }
            .padding(.horizontal, 48)

        }
    }

    private func activateKey() {
        guard !isActivating else { return }
        isActivating = true
        errorMessage = nil
        Task {
            let err = await license.activate(key: keyInput)
            isActivating = false
            if let err { errorMessage = err }
            // On success, LicenseManager sets justActivated = true,
            // which ContentView observes and shows WelcomeCelebrationView.
        }
    }
}

// MARK: - Audio Engine

final class AudioEngine {
    static let shared = AudioEngine()
    private init() {}

    // Per-name cache of our own NSSound copies.
    // NSSound(named:) returns a shared AppKit-managed instance — calling
    // .play() on it while it's already playing produces the AppKit
    // "Already playing" error and silently drops the request.
    // By keeping our own copies we can stop-and-restart freely, so every
    // UI interaction gets audio feedback no matter how fast the user taps.
    private var cache: [String: NSSound] = [:]

    // Debounce stamp for transferComplete — prevents double-trigger in edge cases
    // (e.g. termination handler + leftover pipe dispatch racing on main queue).
    private var lastCompletionFire: Date = .distantPast

    // Card plugged in / detected
    func cardDetected()      { play("Tink") }
    // Transfer process kicks off
    func transferStarted()   { play("Pop") }
    // All files copied successfully — two-tone rising chime
    func transferComplete() {
        // Debounce: swallow any duplicate calls within 1 second.
        let now = Date()
        guard now.timeIntervalSince(lastCompletionFire) > 1.0 else { return }
        lastCompletionFire = now
        playSequence(["Hero", "Glass"], delays: [0, 0.38])
    }
    // Card already fully up to date
    func upToDate()          { play("Purr") }
    // Checksum spot-check passed
    func verifyPassed()      { play("Ping") }
    // Checksum mismatch found
    func verifyFailed()      { play("Basso") }
    // Transfer killed by user
    func transferCancelled() { play("Funk") }
    // Auto ingest switched on
    func autoIngestEnabled()  { play("Blow") }
    // Auto ingest switched off
    func autoIngestDisabled() { play("Glass") }
    // License key accepted — first activation chime
    func licenseActivated()   { play("Glass") }
    // Video / Photo mode switched
    func modeSwitch()         { play("Bottle") }

    /// Plays a sequence of sounds with per-sound delays (in seconds).
    ///
    /// Delayed notes use a HIGH-PRIORITY BACKGROUND timer rather than
    /// DispatchQueue.main.asyncAfter.  After a large transfer the main queue
    /// can have a significant backlog of pending UI updates still draining,
    /// which causes asyncAfter to fire late — making the Hero→Glass chord
    /// land at the wrong offset and sound like a stuttering echo.
    /// The background timer fires precisely at the requested delay, then
    /// hops back to main only for the final NSSound call (which is fast).
    private func playSequence(_ names: [String], delays: [TimeInterval]) {
        for (name, delay) in zip(names, delays) {
            if delay == 0 {
                play(name)
            } else {
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + delay) { [weak self] in
                    DispatchQueue.main.async { self?.play(name) }
                }
            }
        }
    }

    private func play(_ named: String) {
        // Lazily build a private copy the first time we see this name.
        // .copy() gives us an independent instance so stop/play never
        // conflicts with other callers or AppKit's shared sound pool.
        let sound: NSSound
        if let cached = cache[named] {
            sound = cached
        } else {
            guard let original = NSSound(named: named),
                  let copy     = original.copy() as? NSSound else { return }
            cache[named] = copy
            sound = copy
        }

        // Stop → rewind → play so rapid re-triggers always produce audio.
        if sound.isPlaying { sound.stop() }
        sound.currentTime = 0
        sound.play()
    }
}

// MARK: - Haptic Engine

final class HapticEngine {
    static let shared = HapticEngine()
    private init() {}

    func start() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }

    func success() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }

    func error() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255,
                            (int >> 8) * 17,
                            (int >> 4 & 0xF) * 17,
                            (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255,
                            int >> 16,
                            int >> 8 & 0xFF,
                            int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24,
                            int >> 16 & 0xFF,
                            int >> 8 & 0xFF,
                            int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red: Double(r) / 255.0,
                  green: Double(g) / 255.0,
                  blue: Double(b) / 255.0,
                  opacity: Double(a) / 255.0)
    }
}

// MARK: - Setup Wizard View

struct SetupWizardView: View {
    @Binding var setupVersion: Int
    let currentSetupVersion: Int
    @Binding var isPresented: Bool

    @State private var fdaState:    FDAState   = .unknown
    @State private var notifState:  NotifState = .unknown
    @State private var hasOpenedFDA: Bool      = false   // gates "Restart app" button

    enum FDAState   { case unknown, granted, denied }
    enum NotifState { case unknown, granted, denied }

    // True when CardRunner.app is inside /Applications (or a sub-folder of it)
    private var isInApplicationsFolder: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications")
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    CardRunnerTheme.neonBlue.opacity(0.6),
                                    CardRunnerTheme.neonPurple.opacity(0.6)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.55), radius: 26, x: 0, y: 16)

            VStack(alignment: .leading, spacing: 20) {
                // Title
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome to CardRunner")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Complete these one-time steps before your first ingest.")
                        .font(.system(size: 14))
                        .foregroundColor(Color.white.opacity(0.78))
                }

                // ── Step 1: Move to Applications (only if needed) ──────────
                if !isInApplicationsFolder {
                    stepCard {
                        HStack(spacing: 8) {
                            Text("1. Move to Applications")
                                .font(.headline).foregroundColor(.white)
                            Spacer()
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.orange)
                        }

                        Text("CardRunner is running from \"\(Bundle.main.bundlePath)\". Move it to your Applications folder first — macOS only registers apps for Full Disk Access when they live there.")
                            .font(.caption)
                            .foregroundColor(Color.white.opacity(0.78))

                        HStack(spacing: 10) {
                            // Reveal the .app in Finder so the user can drag it
                            Button(action: {
                                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                            }) {
                                Text("Show in Finder")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 18).padding(.vertical, 8)
                                    .background(Capsule().fill(LinearGradient(
                                        colors: [CardRunnerTheme.neonBlue, CardRunnerTheme.neonPurple],
                                        startPoint: .leading, endPoint: .trailing)))
                                    .foregroundColor(.white)
                            }
                            .buttonStyle(.plain)

                            // Open the Applications folder so they can drag into it
                            Button(action: {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                            }) {
                                Text("Open Applications Folder")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 18).padding(.vertical, 8)
                                    .background(Capsule().fill(Color.white.opacity(0.1)))
                                    .foregroundColor(.white)
                            }
                            .buttonStyle(.plain)
                        }

                        Text("Drag CardRunner from the Finder window into the Applications folder, then reopen it from there.")
                            .font(.caption2)
                            .foregroundColor(.orange.opacity(0.9))
                    }
                }

                // ── Step 2: Full Disk Access ───────────────────────────────
                let fdaStep = isInApplicationsFolder ? "1" : "2"
                stepCard {
                    HStack(spacing: 8) {
                        Text("\(fdaStep). Full Disk Access")
                            .font(.headline).foregroundColor(.white)
                        Spacer()
                        statusBadge(for: fdaState)
                    }
                    Text("CardRunner needs Full Disk Access to read SD/CFexpress cards and write to your SSDs. Without it, no files can be transferred.")
                        .font(.caption).foregroundColor(Color.white.opacity(0.78))

                    if !isInApplicationsFolder && fdaState != .granted {
                        Text("⚠ Move the app to Applications first — it won't appear in the FDA list until it does.")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }

                    HStack(spacing: 10) {
                        Button(action: {
                            hasOpenedFDA = true
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            Text("Open Full Disk Access")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(Capsule().fill(LinearGradient(
                                    colors: [CardRunnerTheme.neonBlue, CardRunnerTheme.neonPurple],
                                    startPoint: .leading, endPoint: .trailing)))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(!isInApplicationsFolder)
                        .opacity(isInApplicationsFolder ? 1 : 0.4)

                        Button("Check again") { recheckFDA() }
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.55))
                            .buttonStyle(.plain)

                        // Only show "Restart app" after the user has actually
                        // visited FDA settings — not on the very first render.
                        if hasOpenedFDA && fdaState == .denied {
                            Button("Restart app") { restartApp() }
                                .font(.system(size: 12))
                                .foregroundColor(Color.orange.opacity(0.85))
                                .buttonStyle(.plain)
                        }
                    }

                    if hasOpenedFDA && fdaState == .denied {
                        Text("After toggling access, tap \"Restart app\" — macOS requires a relaunch.")
                            .font(.caption2).foregroundColor(.orange)
                    } else if fdaState == .granted {
                        Text("Full Disk Access confirmed ✓")
                            .font(.caption2).foregroundColor(CardRunnerTheme.neonBlue)
                    }
                }

                // ── Step 3: Notifications ─────────────────────────────────
                let notifStep = isInApplicationsFolder ? "2" : "3"
                stepCard {
                    HStack(spacing: 8) {
                        Text("\(notifStep). Enable Notifications")
                            .font(.headline).foregroundColor(.white)
                        Spacer()
                        statusBadge(for: notifState)
                    }
                    Text("CardRunner can send a banner when a card is detected or an ingest finishes — useful when running in the background.")
                        .font(.caption).foregroundColor(Color.white.opacity(0.78))

                    if notifState != .granted {
                        Button(action: {
                            if notifState == .denied {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                    NSWorkspace.shared.open(url)
                                }
                            } else {
                                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                                    DispatchQueue.main.async {
                                        notifState = granted ? .granted : .denied
                                    }
                                }
                            }
                        }) {
                            Text(notifState == .denied ? "Open Notification Settings" : "Enable Notifications")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(Capsule().fill(LinearGradient(
                                    colors: [CardRunnerTheme.neonBlue, CardRunnerTheme.neonPurple],
                                    startPoint: .leading, endPoint: .trailing)))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    if notifState == .denied {
                        Text("Notifications denied. Open Notification Settings to enable them.")
                            .font(.caption2).foregroundColor(.orange)
                    }
                }
                .onAppear { recheckNotifications() }

                Spacer()

                // ── Footer ─────────────────────────────────────────────────
                HStack {
                    if !isInApplicationsFolder {
                        Text("⚠ Move the app to Applications before continuing.")
                            .font(.caption2)
                            .foregroundColor(.orange.opacity(0.85))
                    } else if fdaState != .granted {
                        Text("⚠ Full Disk Access is required to use CardRunner.")
                            .font(.caption2)
                            .foregroundColor(.orange.opacity(0.85))
                    }
                    Spacer()
                    Button(action: {
                        setupVersion = currentSetupVersion
                        isPresented = false
                    }) {
                        Text(fdaState == .granted ? "Get started →" : "Continue anyway")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 22).padding(.vertical, 8)
                            .background(Capsule().fill(LinearGradient(
                                colors: [CardRunnerTheme.neonPurple, CardRunnerTheme.neonBlue],
                                startPoint: .leading, endPoint: .trailing)))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 440)
        .onAppear {
            recheckFDA()
            recheckNotifications()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-probe every time the user switches back (they may have just moved the app)
            recheckFDA()
        }
    }

    // MARK: - Helpers

    private func recheckFDA() {
        fdaState = Self.probeFDA() ? .granted : .denied
    }

    private func restartApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
            NSApp.terminate(nil)
        }
    }

    /// Tries several paths to detect FDA reliably across macOS 14–26.
    ///
    /// Tier 1 — TCC database files (reliable on macOS 12–14, may fail on 15+):
    ///   Apple tightened access to TCC.db on Sequoia even for FDA-granted apps,
    ///   so a false-negative here doesn't mean FDA is missing.
    ///
    /// Tier 2 — Protected user directories (reliable on macOS 15+):
    ///   ~/Library/Safari, ~/Library/Mail, and ~/Library/Messages are consistently
    ///   FDA-gated: listing them succeeds with FDA and fails without, regardless of
    ///   whether any files are inside.
    static func probeFDA() -> Bool {
        let fm   = FileManager.default
        let home = NSHomeDirectory()

        // ── Tier 1: TCC database (macOS 12–14) ─────────────────────────────────
        let tccPaths = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/private/var/db/TCC/TCC.db",
        ]
        for path in tccPaths {
            if (try? Data(contentsOf: URL(fileURLWithPath: path))) != nil { return true }
            if fm.isReadableFile(atPath: path) { return true }
        }
        if (try? fm.contentsOfDirectory(atPath: "/Library/Application Support/com.apple.TCC/")) != nil {
            return true
        }

        // ── Tier 2: Protected user directories (macOS 15+ / Sequoia) ───────────
        // FDA is required to list these — the directory exists on every Mac even
        // if the user has never opened the app, so an empty listing still means FDA.
        let protectedDirs = [
            home + "/Library/Safari",
            home + "/Library/Mail",
            home + "/Library/Messages",
        ]
        for dir in protectedDirs {
            if (try? fm.contentsOfDirectory(atPath: dir)) != nil { return true }
        }

        return false
    }

    private func recheckNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional: notifState = .granted
                case .denied:                   notifState = .denied
                default:                        notifState = .unknown
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for state: FDAState) -> some View {
        switch state {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundColor(CardRunnerTheme.neonBlue)
        case .denied:
            Image(systemName: "xmark.circle.fill").foregroundColor(.red.opacity(0.8))
        case .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private func statusBadge(for state: NotifState) -> some View {
        switch state {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundColor(CardRunnerTheme.neonBlue)
        case .denied:
            Image(systemName: "xmark.circle.fill").foregroundColor(.red.opacity(0.8))
        case .unknown:
            EmptyView()
        }
    }

    private func stepCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
    }
}


struct SetupWizardView_Previews: PreviewProvider {
    static var previews: some View {
        SetupWizardView(
            setupVersion: .constant(0),
            currentSetupVersion: 1,
            isPresented: .constant(true)
        )
        .frame(minWidth: 520, minHeight: 360)
    }
}

// MARK: - v3 dashboard (the new face over the real engine)
//
// `bodyV3` renders the v3 "ring" design while reading ContentView's REAL @State
// (activeIngests / runningCount / autoIngest / statusText / destination prefs) and driving
// REAL actions through the existing menu-notification bus. No engine logic lives here — the
// shared `appWiringHost` (detection / timers / engine sheets+alerts / menu bus) does all the
// wiring. This is purely presentation.

extension ContentView {

    // Palette (from the Claude Design v3 source)
    private var v3Cyan: Color  { Color(hex: "#0dcff5") }
    private var v3Purple: Color { Color(hex: "#a855f7") }
    private var v3Mag: Color   { Color(hex: "#ff5cdd") }
    private var v3Green: Color { Color(hex: "#34d399") }
    private var v3Amber: Color { Color(hex: "#fbbf24") }
    private var v3Red: Color   { Color(hex: "#f87171") }
    private var v3Brand: LinearGradient {
        LinearGradient(colors: [v3Cyan, v3Purple, v3Mag], startPoint: .leading, endPoint: .trailing)
    }

    private func v3Post(_ n: Notification.Name) { NotificationCenter.default.post(name: n, object: nil) }

    /// Direct "choose where footage lands" picker. Sets the REAL custom-destination prefs that
    /// `startIngest` reads; the legacy `.onChange(of: customDestPath)` revalidates automatically.
    /// Footage then lands in <chosen folder>/<date>/… on the next (and current-queued) ingest.
    private func v3ChooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "Choose where footage from cards should land"
        if !customDestPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: customDestPath)
        } else if !primarySSDPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: primarySSDPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            customDestPath = url.path
            useCustomDest = true
        }
    }

    // MARK: N-way destination actions (bodyV3)

    /// Add a *custom folder* destination via the open panel.
    private func v3AddFolderDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "Choose a folder to add as a destination"
        if panel.runModal() == .OK, let url = panel.url {
            // Skip exact-duplicate paths.
            guard !destinations.contains(where: { $0.path == url.path }) else { return }
            let d = Destination(path: url.path, name: url.lastPathComponent, isCustomFolder: true)
            destinations.append(d)
            if defaultDestination == nil { defaultDestIDString = d.id.uuidString }
            saveDestinations()
        }
    }


    /// Remove a destination (never the last one). Reassigns the default if needed.
    private func v3RemoveDestination(_ id: UUID) {
        guard destinations.count > 1 else { return }
        destinations.removeAll { $0.id == id }
        awaitingCards = awaitingCards.map { aw in
            var a = aw; if a.destinationID == id { a.destinationID = nil }; return a
        }
        if defaultDestIDString == id.uuidString {
            defaultDestIDString = destinations.first?.id.uuidString ?? ""
        }
        saveDestinations()
    }

    /// Make a destination the default (golden box). Locked while a transfer is running so a
    /// card mid-flight can't have its routing reinterpreted.
    @discardableResult private func v3MakeDefault(_ id: UUID) -> Bool {
        guard runningCount == 0, destinations.contains(where: { $0.id == id }) else { return false }
        defaultDestIDString = id.uuidString
        return true
    }

    /// True when at least one card is parked waiting to route and nothing is actively copying.
    private var v3WaitingToRoute: Bool { !awaitingCards.isEmpty && !v3AnyActive }

    /// Free-space label for a destination tile.
    private func v3DestFree(_ d: Destination) -> String { v3FreeSpace(d.path) }

    /// Project / subfolder summary for a destination tile — the disambiguator when the same physical
    /// drive backs more than one destination. Reflects the fallback (empty project → global project).
    private func v3DestPathLabel(_ d: Destination) -> String {
        if d.isCustomFolder { return "Custom folder" }
        let proj = resolveProjectFolder(destProject: d.projectFolder, globalProject: projectName)
        guard !proj.isEmpty else { return "No project set" }
        let sub = (d.subfolder.isEmpty || d.subfolder == "Default") ? "clips" : d.subfolder
        return "\(proj) / \(sub)"
    }

    // MARK: - v3 sheets: Add destination / New project folder

    /// Finder-tag palette for the New-Project color row (index 0 = none).
    private var v3TagColors: [(name: String, tag: String, color: Color)] {
        [("none", "", Color.white.opacity(0.06)),
         ("red", "Red", Color(hex: "#f87171")), ("orange", "Orange", Color(hex: "#fb923c")),
         ("yellow", "Yellow", Color(hex: "#fbbf24")), ("green", "Green", Color(hex: "#34d399")),
         ("blue", "Blue", Color(hex: "#5b8def")), ("purple", "Purple", Color(hex: "#c084fc")),
         ("gray", "Gray", Color(hex: "#9ca3af"))]
    }

    private func v3OpenAddDest(ssd: Bool) {
        v3AddIsSSD = ssd
        v3AddDrivePath = v3AllDrives.first?.path ?? ""
        v3AddCustomPath = ""
        v3AddProject = ""
        v3AddSubfolder = "Default"
        v3AddName = ""
        v3AddNameEdited = false
        v3AddError = ""
        showV3AddDest = true
    }

    private func v3OpenNewProject() {
        let fmt = DateFormatter(); fmt.dateFormat = "yyMMdd"
        v3ProjName = projectName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "\(fmt.string(from: Date()))_" : projectName
        v3ProjColorIndex = v3TagColors.firstIndex { $0.name == finderTagColor && finderTagEnabled } ?? 4
        v3ProjScaffoldOn = Dictionary(uniqueKeysWithValues: scaffoldFolderList.map { ($0, true) })
        // Default the new folder to the SSD/drive ROOT of the default destination (e.g. a "Brooks PR"
        // project default → /Volumes/Gallo 8TB), NOT inside the project subfolder. "Change…" overrides.
        v3ProjParent = v3ProjDefaultParent
        v3ProjParentOverridden = false
        showV3NewProject = true
    }

    private func v3PickCustomFolderForAdd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"; panel.message = "Choose a folder on this Mac"
        if panel.runModal() == .OK, let url = panel.url { v3AddCustomPath = url.path }
    }

    /// The volume/drive root for a destination path — `/Volumes/Gallo 8TB/BrooksPR/clips` →
    /// `/Volumes/Gallo 8TB`. A no-op when the path is already a volume root. For an internal-disk
    /// path (not under /Volumes) there's no SSD root, so fall back to the path's own PARENT rather
    /// than dumping a project at "/". Used to default a new project folder to the SSD root.
    private func v3VolumeRoot(of path: String) -> String {
        let parts = URL(fileURLWithPath: path).pathComponents
        if parts.count >= 3, parts[1] == "Volumes" { return "/Volumes/\(parts[2])" }
        let parent = (path as NSString).deletingLastPathComponent
        return (parent.isEmpty || parent == "/") ? path : parent
    }

    /// The parent the new project folder will be created in, resolved from the default destination.
    private var v3ProjDefaultParent: String { v3VolumeRoot(of: defaultDestination?.path ?? primarySSDPath) }

    /// "Change…" override: pick a custom parent folder via the macOS Finder panel (pre-pointed at the
    /// current parent). Sets v3ProjParent + marks it overridden so a "Reset to drive root" appears.
    private func v3PickProjectParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Create here"; panel.message = "Choose where to create the new project folder"
        if !v3ProjParent.isEmpty { panel.directoryURL = URL(fileURLWithPath: v3ProjParent) }
        if panel.runModal() == .OK, let url = panel.url {
            v3ProjParent = url.path
            v3ProjParentOverridden = true
        }
    }

    /// ALL mounted destination drives (not filtered by already-used — Xavier allows the same drive
    /// twice with different projects). Fixes the "No drives available" bug (was v3UnusedDrives).
    private var v3AllDrives: [Volume] { availableDestinations }

    /// Top-level project folders on a drive (for the Add-destination project picker).
    private func v3ProjectFolders(on drivePath: String) -> [String] {
        guard !drivePath.isEmpty else { return [] }
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: drivePath, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Existing subfolders inside {drive}/{project} (for the subfolder picker; "Default" is always offered).
    private func v3Subfolders(drive: String, project: String) -> [String] {
        guard !drive.isEmpty, !project.isEmpty else { return [] }
        let fm = FileManager.default
        let p = (drive as NSString).appendingPathComponent(project)
        let contents = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: p, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// First existing subfolder (shallow) that already contains a media file — used to auto-pick the
    /// footage subfolder when there's no "clips". Read-only scan; never creates or moves anything.
    private func v3SubfolderWithFootage(drive: String, project: String, subs: [String]) -> String? {
        let base = ((drive as NSString).appendingPathComponent(project)) as NSString
        let fm = FileManager.default
        for sub in subs {
            let items = (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent(sub))) ?? []
            if items.contains(where: { kFootageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
                return sub
            }
        }
        return nil
    }

    /// Resolve the DEFAULT subfolder target for a freshly-picked project (Add / new-project only —
    /// NEVER on Edit, which must keep the destination's stored value so footage can't relocate).
    /// Returns the canonical "Default" sentinel (→ shell's `clips` dir) when a `clips` folder exists
    /// or nothing else looks like footage; otherwise the literal footage-bearing subfolder.
    private func v3ResolveSubfolderTarget(drive: String, project: String) -> String {
        let subs = v3Subfolders(drive: drive, project: project)
        if subs.contains(where: { $0.lowercased() == "clips" }) { return "Default" }
        if let footage = v3SubfolderWithFootage(drive: drive, project: project, subs: subs) { return footage }
        return "Default"
    }

    /// Live `{drive}/{project}/{sub}/{date}/{card}` preview — shared by the Add and Edit sheets.
    private func v3PathPreview(drivePath: String, project: String, subfolder: String) -> String {
        let drive = v3AllDrives.first { $0.path == drivePath }?.name
            ?? (drivePath.isEmpty ? "drive" : URL(fileURLWithPath: drivePath).lastPathComponent)
        let proj = project.trimmingCharacters(in: .whitespaces)
        let sub  = (subfolder == "Default" || subfolder.isEmpty) ? "clips" : subfolder
        return proj.isEmpty ? "Pick a project folder" : "\(drive) / \(proj) / \(sub) / {date} / {card}"
    }

    /// Set the project on the Add-destination form and auto-derive the name (unless the user edited it).
    private func v3SetAddProject(_ p: String) {
        v3AddProject = p
        v3AddSubfolder = "Default"
        v3AddError = ""
        if !v3AddNameEdited { v3AddName = deriveDestName(fromProject: p) }
    }

    private func v3AddFieldLabel(_ title: String, sub: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                if let sub { Text(sub).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)) }
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
        }
        .padding(14).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.10)))
    }

    /// Project-folder + subfolder + destination-name fields, shared by the Add and Edit sheets so both
    /// pickers behave identically. `drivePath` is fixed by the caller (chosen in Add, locked in Edit);
    /// this group never re-picks the drive. The project is a DROPDOWN of existing folders only (no
    /// free typing — new folders are created via "New project folder"); picking one auto-picks the
    /// footage subfolder and auto-derives the name until the user edits it.
    @ViewBuilder
    private func v3DestFieldGroup(drivePath: String,
                                  project: Binding<String>, subfolder: Binding<String>,
                                  name: Binding<String>, nameEdited: Binding<Bool>,
                                  error: Binding<String>) -> some View {
        v3SheetLabel("Project folder")
        v3ProjectPicker(drivePath: drivePath, project: project, subfolder: subfolder,
                        name: name, nameEdited: nameEdited, error: error)

        v3SheetLabel("Subfolder")
        v3SubfolderPicker(drivePath: drivePath, project: project, subfolder: subfolder)

        v3SheetLabel("Destination name")
        // Only mark the name "edited" when the text ACTUALLY changes — a focus event that re-submits
        // the same value must not flip nameEdited and suppress the auto-derive on the next project pick.
        TextField("Name", text: Binding(get: { name.wrappedValue },
                                        set: { if $0 != name.wrappedValue { nameEdited.wrappedValue = true }; name.wrappedValue = $0 }))
            .textFieldStyle(.plain).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .focused($v3NameFocused).onSubmit { v3NameFocused = false }
            .padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(v3NameFocused ? v3Cyan.opacity(0.6) : .white.opacity(0.10)))

        Text(v3PathPreview(drivePath: drivePath, project: project.wrappedValue, subfolder: subfolder.wrappedValue))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(v3Cyan.opacity(0.85)).lineLimit(1).truncationMode(.middle)
    }

    /// Project folder = a DROPDOWN of existing folders on the drive (no free text). Picking one
    /// auto-picks the footage subfolder + auto-derives the name (until the user edits it). A stored
    /// project that no longer exists on disk (Edit of a moved/reformatted drive) is shown as a
    /// selected "(not found)" entry so editing never silently blanks it.
    private func v3ProjectPicker(drivePath: String, project: Binding<String>, subfolder: Binding<String>,
                                 name: Binding<String>, nameEdited: Binding<Bool>, error: Binding<String>) -> some View {
        let folders = v3ProjectFolders(on: drivePath)
        let cur = project.wrappedValue.trimmingCharacters(in: .whitespaces)
        let missing = !cur.isEmpty && !folders.contains(cur)
        return VStack(alignment: .leading, spacing: 6) {
            Menu {
                if missing {
                    Button { } label: { Label("\(cur) (not found)", systemImage: "checkmark") }.disabled(true)
                }
                ForEach(folders, id: \.self) { f in
                    Button {
                        // Resign the name field FIRST so a focused TextField re-reads its binding.
                        v3NameFocused = false
                        project.wrappedValue = f
                        subfolder.wrappedValue = v3ResolveSubfolderTarget(drive: drivePath, project: f)
                        error.wrappedValue = ""
                        // Picking a project ALWAYS replaces the name with the derived one (Xavier's call) —
                        // delete-and-replace whatever was typed/blank; nameEdited resets so it's clean.
                        name.wrappedValue = deriveDestName(fromProject: f)
                        nameEdited.wrappedValue = false
                    } label: {
                        if f == cur { Label(f, systemImage: "checkmark") } else { Text(f) }
                    }
                }
                if folders.isEmpty && !missing {
                    Button("No project folders on this drive") { }.disabled(true)
                }
            } label: {
                v3AddFieldLabel(cur.isEmpty ? "Choose a project folder"
                                            : (missing ? "\(cur) (not found)" : cur), sub: nil)
            }.menuStyle(.borderlessButton)
            if folders.isEmpty {
                Label("No project folders here yet — create one with “New project folder”.", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    /// Subfolder picker: real folders on disk, with the target highlighted (checkmark). The "clips"
    /// row maps to the canonical "Default" sentinel (→ shell's `clips` dir) so the common path emits
    /// byte-identical ingest args; any other row stores its literal name.
    private func v3SubfolderPicker(drivePath: String, project: Binding<String>, subfolder: Binding<String>) -> some View {
        let subs = v3Subfolders(drive: drivePath, project: project.wrappedValue)
        let curSub = subfolder.wrappedValue
        let clipsSelected = curSub == "Default" || curSub.lowercased() == "clips"
        return Menu {
            Button { subfolder.wrappedValue = "Default" } label: {
                if clipsSelected { Label("clips", systemImage: "checkmark") } else { Text("clips") }
            }
            ForEach(subs.filter { $0.lowercased() != "clips" }, id: \.self) { s in
                Button { subfolder.wrappedValue = s } label: {
                    if curSub == s { Label(s, systemImage: "checkmark") } else { Text(s) }
                }
            }
        } label: {
            v3AddFieldLabel(clipsSelected ? "clips" : curSub, sub: nil)
        }.menuStyle(.borderlessButton)
    }

    /// Open the per-destination editor for an SSD destination (click a tile). The drive is fixed —
    /// only the project/subfolder/name are editable. Locked while a transfer runs (like Make Default),
    /// and skipped for custom-folder destinations (their path IS the project root, nothing to edit).
    private func v3OpenEditDest(_ d: Destination) {
        guard runningCount == 0, !d.isCustomFolder else { return }
        v3EditDestID = d.id
        v3EditProject = d.projectFolder
        v3EditSubfolder = d.subfolder.isEmpty ? "Default" : d.subfolder
        v3EditName = d.name
        v3EditNameEdited = true
        v3EditError = ""
        refreshFreeSpaceCache()
        showV3EditDest = true
    }

    /// Save the destination editor. Mutates the existing `Destination` in place (never re-routes an
    /// in-flight card — guarded on `runningCount == 0`) and mkdir's the project folder so it shows in
    /// Finder (mkdir only, no footage touched — same guards as Add).
    private func v3CommitEditDest() {
        guard runningCount == 0, let id = v3EditDestID,
              let idx = destinations.firstIndex(where: { $0.id == id }) else { showV3EditDest = false; return }
        let drivePath = destinations[idx].path
        let proj = v3EditProject.trimmingCharacters(in: .whitespaces)
        let typed = v3EditName.trimmingCharacters(in: .whitespaces)
        let driveName = v3AllDrives.first { $0.path == drivePath }?.name ?? destinations[idx].name
        let name = !typed.isEmpty ? typed : (proj.isEmpty ? driveName : deriveDestName(fromProject: proj))
        destinations[idx].projectFolder = proj
        // Normalize a literal "clips" (e.g. legacy data) back to the "Default" sentinel so the common
        // path keeps emitting byte-identical ingest args (no redundant --subfolder clips).
        destinations[idx].subfolder = v3CanonSubfolder(v3EditSubfolder)
        destinations[idx].name = name
        if !proj.isEmpty, !proj.contains("/"), !proj.contains("..") {
            try? FileManager.default.createDirectory(
                atPath: (drivePath as NSString).appendingPathComponent(proj), withIntermediateDirectories: true)
        }
        saveDestinations()
        showV3EditDest = false
    }

    /// Canonical subfolder key. The shell maps the "Default" subfolder to a literal `clips` directory,
    /// so a destination whose subfolder is explicitly "clips" lands in the SAME tree as one using
    /// Default. Collapse them to one key so the two aren't treated as distinct footage trees.
    private func v3CanonSubfolder(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return (t.isEmpty || t == "Default" || t.lowercased() == "clips") ? "Default" : t
    }

    /// True if a drive+project+subfolder would land in the SAME footage tree as an existing SSD
    /// destination (same resolved project + canonical subfolder on the same drive). `excluding` skips
    /// the destination being edited so saving an unchanged edit isn't flagged as a self-duplicate.
    /// Same drive with a DIFFERENT project is allowed.
    private func v3DestLeafConflicts(drivePath: String, project: String, subfolder: String, excluding id: UUID?) -> Bool {
        let proj = project.trimmingCharacters(in: .whitespaces)
        let resolvedNew = proj.isEmpty ? projectName.trimmingCharacters(in: .whitespaces) : proj
        let subNew = v3CanonSubfolder(subfolder)
        return destinations.contains { d in
            d.id != id && !d.isCustomFolder && d.path == drivePath
                && resolveProjectFolder(destProject: d.projectFolder, globalProject: projectName) == resolvedNew
                && v3CanonSubfolder(d.subfolder) == subNew
        }
    }

    /// True if the Add-destination form would duplicate an existing destination's leaf.
    private func v3AddIsDuplicate() -> Bool {
        v3DestLeafConflicts(drivePath: v3AddDrivePath, project: v3AddProject, subfolder: v3AddSubfolder, excluding: nil)
    }

    private func v3CommitAddDest() {
        // Adding a destination just appends a routing target; it never reinterprets routing for
        // in-flight cards. Cards are routed per-card (drag node / cycle) or fall to the default.
        let dest: Destination
        if v3AddIsSSD {
            guard let vol = v3AllDrives.first(where: { $0.path == v3AddDrivePath }) else { showV3AddDest = false; return }
            let proj = v3AddProject.trimmingCharacters(in: .whitespaces)
            let typed = v3AddName.trimmingCharacters(in: .whitespaces)
            let name  = !typed.isEmpty ? typed : (proj.isEmpty ? vol.name : deriveDestName(fromProject: proj))
            dest = Destination(path: vol.path, name: name, isCustomFolder: false,
                               projectFolder: proj, subfolder: v3CanonSubfolder(v3AddSubfolder))
            // Create the project folder on the drive now so it shows in Finder (mkdir only — no
            // footage touched). Guard against path-injection in the folder name.
            if !proj.isEmpty, !proj.contains("/"), !proj.contains("..") {
                try? FileManager.default.createDirectory(
                    atPath: (vol.path as NSString).appendingPathComponent(proj), withIntermediateDirectories: true)
            }
        } else {
            guard !v3AddCustomPath.isEmpty, !destinations.contains(where: { $0.path == v3AddCustomPath }) else {
                showV3AddDest = false; return
            }
            dest = Destination(path: v3AddCustomPath,
                               name: URL(fileURLWithPath: v3AddCustomPath).lastPathComponent, isCustomFolder: true)
        }
        destinations.append(dest)
        if defaultDestination == nil { defaultDestIDString = dest.id.uuidString }
        saveDestinations()
        refreshFreeSpaceCache()
        showV3AddDest = false
    }

    private func v3CommitNewProject() {
        let name = v3ProjName.trimmingCharacters(in: .whitespaces)
        // Guard the folder NAME against path traversal (mirrors the Add-destination guard) — the
        // name becomes a single folder component, never a nested/relative path.
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { return }
        projectName = name
        let enabled = scaffoldFolderList.filter { v3ProjScaffoldOn[$0] ?? true }
        scaffoldFoldersRaw = enabled.joined(separator: "\n")
        scaffoldEnabled = !enabled.isEmpty
        finderTagEnabled = v3ProjColorIndex != 0
        if v3ProjColorIndex != 0 { finderTagColor = v3TagColors[v3ProjColorIndex].name }
        // Create the project folder + scaffold at the resolved PARENT (the SSD/drive root by default,
        // or a custom folder if the user hit "Change…") so it shows in Finder. Purely a mkdir — this
        // does NOT create or switch a routing Destination.
        let base = v3ProjParent.isEmpty ? v3ProjDefaultParent : v3ProjParent
        if !base.isEmpty {
            let fm = FileManager.default
            let root = (base as NSString).appendingPathComponent(name)
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            for f in enabled where !f.contains("..") {
                try? fm.createDirectory(atPath: (root as NSString).appendingPathComponent(f), withIntermediateDirectories: true)
            }
            if v3ProjColorIndex != 0 {
                let url = URL(fileURLWithPath: root)
                try? (url as NSURL).setResourceValue([v3TagColors[v3ProjColorIndex].tag], forKey: .tagNamesKey)
            }
        }
        showV3NewProject = false
    }

    // MARK: Add-destination sheet

    private var v3AddDestSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add destination").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                Spacer(); v3SheetClose { showV3AddDest = false }
            }
            v3SheetLabel("DESTINATION")
            v3Segment(left: ("externaldrive", "SSD"), right: ("folder", "Custom Folder"),
                      leftSelected: v3AddIsSSD, in: v3AddDestSegNS, group: "addDestSeg") { picked in
                // Spring the module's height between the tall SSD tab and the short Custom tab
                // instead of an abrupt big↔small jump.
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { v3AddIsSSD = picked }
            }
            if v3AddIsSSD {
                v3SheetLabel("Drive")
                Menu {
                    // ALL mounted drives (the same drive can be added again with a different project).
                    ForEach(v3AllDrives, id: \.path) { vol in
                        Button("\(vol.name) — \(v3FreeSpace(vol.path))") {
                            v3AddDrivePath = vol.path; v3SetAddProject("")
                        }
                    }
                } label: {
                    v3AddFieldLabel(v3AllDrives.first { $0.path == v3AddDrivePath }?.name ?? "Choose a drive",
                                    sub: v3AddDrivePath.isEmpty ? nil : v3FreeSpace(v3AddDrivePath))
                }.menuStyle(.borderlessButton)

                v3DestFieldGroup(drivePath: v3AddDrivePath,
                                 project: $v3AddProject, subfolder: $v3AddSubfolder,
                                 name: $v3AddName, nameEdited: $v3AddNameEdited, error: $v3AddError)
            } else {
                v3SheetLabel("Folder path")
                Button { v3PickCustomFolderForAdd() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(.white.opacity(0.5))
                        Text(v3AddCustomPath.isEmpty ? "Choose a folder on this Mac…" : v3AddCustomPath)
                            .foregroundStyle(v3AddCustomPath.isEmpty ? .white.opacity(0.5) : .white)
                            .lineLimit(1).truncationMode(.head)
                        Spacer()
                    }
                    .font(.system(size: 14)).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.18),
                             style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .contentShape(Rectangle())   // whole dashed box is clickable, not just the text
                }.buttonStyle(.plain).v3Hover(scale: 1.02, glow: v3Cyan)
            }
            if !v3AddError.isEmpty {
                Label(v3AddError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(v3Amber)
            } else {
                Text("Cards route to whichever destination you pick (drag a card's node onto a drive, or use the default).")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                v3SheetCancel { showV3AddDest = false }
                v3SheetPrimary("Add destination", icon: "plus",
                               enabled: v3AddIsSSD ? !v3AddDrivePath.isEmpty : !v3AddCustomPath.isEmpty) {
                    if v3AddIsSSD && v3AddIsDuplicate() {
                        v3AddError = "That drive + project + subfolder is already a destination."
                    } else { v3CommitAddDest() }
                }
            }
            .padding(.top, 4)
        }
        .padding(26).frame(width: 460)
        .frame(minHeight: 0)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: v3AddIsSSD)  // smooth height resize
        .background(Color(hex: "#0c0822")).preferredColorScheme(.dark)
        // Tap anywhere on the card (outside a control) to leave the name field — the modal's
        // outside-tap dismisses the whole sheet, so this is the only "click out of the field" path.
        .onTapGesture { v3NameFocused = false }
    }

    // MARK: Edit-destination sheet (click a tile)

    private var v3EditDestSheet: some View {
        let dest = v3EditDestID.flatMap { id in destinations.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit destination").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                Spacer(); v3SheetClose { showV3EditDest = false }
            }
            if let dest {
                // Drive is fixed for an existing destination — shown read-only (edit where footage lands
                // on it, not which drive). Locked in the UI too if a transfer starts while the sheet is open.
                v3SheetLabel("Drive")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v3AllDrives.first { $0.path == dest.path }?.name
                             ?? URL(fileURLWithPath: dest.path).lastPathComponent)
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        Text(v3FreeSpace(dest.path)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.3))
                        .help("The drive can't be changed here — remove and re-add to move a destination to a different drive.")
                }
                .padding(14).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.10)))

                v3DestFieldGroup(drivePath: dest.path,
                                 project: $v3EditProject, subfolder: $v3EditSubfolder,
                                 name: $v3EditName, nameEdited: $v3EditNameEdited, error: $v3EditError)

                if !v3EditError.isEmpty {
                    Label(v3EditError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(v3Amber)
                } else if runningCount > 0 {
                    Label("A transfer is running — save is locked until it finishes.", systemImage: "lock.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(v3Amber)
                } else {
                    Text("Editing changes where FUTURE cards to this destination land. Cards already copying are unaffected.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    v3SheetCancel { showV3EditDest = false }
                    v3SheetPrimary("Save changes", icon: "checkmark", enabled: runningCount == 0) {
                        if v3DestLeafConflicts(drivePath: dest.path, project: v3EditProject,
                                               subfolder: v3EditSubfolder, excluding: v3EditDestID) {
                            v3EditError = "Another destination already uses that project + subfolder on this drive."
                        } else { v3CommitEditDest() }
                    }
                }
                .padding(.top, 4)
            } else {
                Text("This destination is no longer available.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                v3SheetCancel { showV3EditDest = false }
            }
        }
        .padding(26).frame(width: 460)
        .background(Color(hex: "#0c0822")).preferredColorScheme(.dark)
        .onTapGesture { v3NameFocused = false }   // click out of the name field (see Add sheet)
    }

    // MARK: New-project-folder sheet

    private var v3NewProjectSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Project Folder").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    // Shows EXACTLY where the folder will land: the SSD/drive root by default, or a
                    // custom parent once "Change…" is used. Fixes the old readout that only named the
                    // destination and hid the fact the folder was nesting inside a project subfolder.
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        Text((v3ProjParent.isEmpty ? "—" : (v3ProjParent as NSString).lastPathComponent)
                             + (v3ProjParentOverridden ? "" : "  (drive root)"))
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
                        Button("Change…") { v3PickProjectParent() }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(v3Cyan).v3Hover(scale: 1.04)
                        if v3ProjParentOverridden {
                            Button("Reset") { v3ProjParent = v3ProjDefaultParent; v3ProjParentOverridden = false }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                                .help("Back to the drive root")
                        }
                    }
                }
                Spacer(); v3SheetClose { showV3NewProject = false }
            }
            v3SheetLabel("FOLDER NAME")
            TextField("Project name", text: $v3ProjName)
                .textFieldStyle(.plain).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(v3Purple.opacity(0.5)))
            Text("Auto-filled with today's date — add a shoot name (e.g. 260629_NWSL).")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            v3SheetLabel("FOLDER COLOR")
            HStack(spacing: 10) {
                ForEach(Array(v3TagColors.enumerated()), id: \.offset) { i, c in
                    ZStack {
                        Circle().fill(i == 0 ? AnyShapeStyle(.white.opacity(0.06)) : AnyShapeStyle(c.color))
                            .frame(width: 30, height: 30)
                        if i == 0 { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.5)) }
                    }
                    .overlay(Circle().strokeBorder(.white, lineWidth: v3ProjColorIndex == i ? 2 : 0))
                    .contentShape(Circle()).onTapGesture { v3ProjColorIndex = i }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2").font(.system(size: 11)).foregroundStyle(v3Purple)
                Text("Scaffold folders created inside").font(.system(size: 12, weight: .semibold)).foregroundStyle(v3Purple)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(scaffoldFolderList, id: \.self) { f in
                    let on = v3ProjScaffoldOn[f] ?? true
                    Button { v3ProjScaffoldOn[f] = !on } label: {
                        HStack(spacing: 6) {
                            Image(systemName: on ? "checkmark" : "plus").font(.system(size: 10, weight: .bold))
                            Text(f).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        }
                        .foregroundStyle(on ? .white : .white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background((on ? v3Purple.opacity(0.18) : Color.white.opacity(0.03)), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(on ? v3Purple.opacity(0.5) : .white.opacity(0.08)))
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 12) {
                v3SheetCancel { showV3NewProject = false }
                v3SheetPrimary("Create Folder", icon: "folder.badge.plus",
                               enabled: !v3ProjName.trimmingCharacters(in: .whitespaces).isEmpty) { v3CommitNewProject() }
            }
            .padding(.top, 4)
        }
        .padding(26).frame(width: 460)
        .background(Color(hex: "#0c0822")).preferredColorScheme(.dark)
    }

    // MARK: Sheet building blocks

    private func v3SheetLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.4))
    }
    private func v3SheetClose(_ act: @escaping () -> Void) -> some View { V3CloseButton(action: act) }
    private func v3Segment(left: (String, String), right: (String, String),
                           leftSelected: Bool, in namespace: Namespace.ID, group: String,
                           _ pick: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 0) {
            v3SegmentHalf(left.0, left.1, selected: leftSelected, in: namespace, group: group) { pick(true) }
            v3SegmentHalf(right.0, right.1, selected: !leftSelected, in: namespace, group: group) { pick(false) }
        }
        .padding(4).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }
    private func v3SegmentHalf(_ icon: String, _ title: String, selected: Bool,
                               in namespace: Namespace.ID, group: String,
                               _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 8) { Image(systemName: icon); Text(title).font(.system(size: 14, weight: .semibold)) }
                .foregroundStyle(selected ? .white : .white.opacity(0.6))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                // Liquid swoosh: the brand pill flows left↔right between the two halves on select.
                .swooshSelection(selected, in: namespace, groupID: group,
                                 fill: AnyShapeStyle(v3Brand), cornerRadius: 9,
                                 glow: v3Purple.opacity(0.5), axis: .horizontal)
                .contentShape(Rectangle())   // whole half is clickable, not just the text
        }.buttonStyle(.plain)
        .v3Hover(scale: 1.0)                  // brighten on hover; no scale inside the fixed track
    }
    private func v3SheetCancel(_ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text("Cancel").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.10)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).v3Hover()
    }
    private func v3SheetPrimary(_ title: String, icon: String, enabled: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 8) { Image(systemName: icon); Text(title).font(.system(size: 14, weight: .bold)) }
                .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(v3Brand, in: RoundedRectangle(cornerRadius: 11))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).v3Hover(glow: v3Purple, enabled: enabled)
    }

    // MARK: Ingest-history sheet

    private var v3HistorySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Ingest History").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                Spacer(); v3SheetClose { showV3History = false }
            }
            HStack(spacing: 12) {
                v3StatCard("CARDS", "\(allTimeStats.totalCards)", "sdcard")
                v3StatCard("FILES", allTimeStats.totalFiles.formatted(), "doc.on.doc")
                v3StatCard("TRANSFERRED", v3HumanMB(allTimeStats.totalMB), "externaldrive")
            }
            v3SheetLabel("RECENT INGESTS")
            if historyEntries.isEmpty {
                Text("No ingests recorded yet.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 8) { ForEach(historyEntries.prefix(80)) { v3HistoryRow($0) } }
                }.frame(maxHeight: 360)
            }
        }
        .padding(26).frame(width: 580, height: 560)
        .background(Color(hex: "#0c0822")).preferredColorScheme(.dark)
    }

    private func v3StatCard(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(v3Cyan)
                Text(label).font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(.white.opacity(0.45))
            }
            Text(value).font(.system(size: 18, weight: .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }

    private func v3HistoryRow(_ e: IngestHistoryEntry) -> some View {
        // Footage-safety: the stored status vocabulary is "Completed" / "Error" (plus mirror/
        // verify/cancel variants). A failed transfer must NEVER read as a green success here.
        let s = e.status.lowercased()
        let failed = s.contains("error") || s.contains("fail") || s.contains("cancel")
        let neutral = !failed && e.newFiles == 0          // nothing new — already up to date
        let col: Color = failed ? v3Red : (neutral ? .white.opacity(0.5) : v3Green)
        let icon = failed ? "exclamationmark.triangle.fill" : (neutral ? "minus.circle" : "checkmark.circle.fill")
        return HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(col)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.cardName.isEmpty ? "Card" : e.cardName).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text("\(e.newFiles) \(e.mediaLabel) · \(e.avgMBps) MB/s · \(v3Duration(e.durationSec)) · \(v3RelDate(e.timestamp))")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer()
            Text(e.status).font(.system(size: 10, weight: .bold)).foregroundStyle(col)
                .padding(.horizontal, 8).padding(.vertical, 3).background(col.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 11))
    }

    private func v3HumanMB(_ mb: Double) -> String {
        if mb >= 1_048_576 { return String(format: "%.1f TB", mb / 1_048_576) }
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
    private func v3Duration(_ sec: Int) -> String {
        if sec >= 3600 { return "\(sec / 3600)h \((sec % 3600) / 60)m" }
        if sec >= 60 { return "\(sec / 60)m \(sec % 60)s" }
        return "\(sec)s"
    }
    private func v3RelDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    // MARK: Activity-log sheet

    private var v3LogSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Activity Log").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Button { NSWorkspace.shared.open(logsDirectoryURL) } label: {
                    HStack(spacing: 6) { Image(systemName: "folder"); Text("Log files") }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.white.opacity(0.05), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                }.buttonStyle(.plain).help("Reveal log files in Finder")
                v3SheetClose { showV3Log = false }
            }
            ScrollViewReader { proxy in
                GeometryReader { outer in
                    ScrollView {
                        Text(logText.isEmpty ? "No activity yet this session." : logText)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            .id("v3logbottom")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: V3LogTailKey.self,
                                    value: g.frame(in: .named("v3logscroll")).maxY)
                            })
                    }
                    .coordinateSpace(name: "v3logscroll")
                    .onPreferenceChange(V3LogTailKey.self) { tailMaxY in
                        // Tail marker within a few pt of the viewport bottom → the live tail is on-screen.
                        let atBottom = tailMaxY <= outer.size.height + 6
                        if v3LogAtBottom != atBottom { v3LogAtBottom = atBottom }
                    }
                    // Follow the live log ONLY while already pinned to the tail — never yank the operator
                    // back down while they're reading history above during a transfer.
                    .onChange(of: logText) { _, _ in
                        if v3LogAtBottom { proxy.scrollTo("v3logbottom", anchor: .bottom) }
                    }
                    .onAppear { proxy.scrollTo("v3logbottom", anchor: .bottom) }
                    // Bottom edge cue: content dissolves into shadow when there's more log below the fold.
                    .overlay(alignment: .bottom) {
                        if !v3LogAtBottom {
                            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                                .frame(height: 44).allowsHitTesting(false)
                        }
                    }
                    // Jump-to-tail — appears only when scrolled up; snaps to the live tail under stress.
                    .overlay(alignment: .bottomTrailing) {
                        if !v3LogAtBottom {
                            Button {
                                withAnimation(v3Anim(.easeOut(duration: 0.2))) { proxy.scrollTo("v3logbottom", anchor: .bottom) }
                                v3LogAtBottom = true
                            } label: {
                                HStack(spacing: 5) { Image(systemName: "chevron.down"); Text("Jump to latest") }
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(v3Cyan.opacity(0.9), in: Capsule())
                                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                            }.buttonStyle(.plain).v3Hover(scale: 1.05).padding(10).transition(.opacity)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12).background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
        }
        .padding(26).frame(width: 640, height: 560)
        .background(Color(hex: "#0c0822")).preferredColorScheme(.dark)
    }

    // MARK: Derived (all from real state)

    /// Live transfers, oldest first (stable lane order).
    private var v3Lanes: [(id: UUID, ing: ActiveIngest)] {
        activeIngests.sorted { $0.value.ingestStartTime < $1.value.ingestStartTime }
            .map { (id: $0.key, ing: $0.value) }
    }
    private var v3AnyActive: Bool { runningCount > 0 || !activeIngests.isEmpty }
    private var v3AggregatePct: Double {
        totalBytesNew > 0 ? min(100, Double(doneBytes) / Double(totalBytesNew) * 100) : 0
    }
    private var v3FailedCount: Int { activeIngests.values.filter { $0.phase == .failed }.count }
    /// Persistent failure presence — `failedIngestRecords` survives lane cleanup AND app relaunch.
    /// The ring/strip key off this so a failure stays visible after the transient alert is dismissed.
    private var v3HasFailures: Bool { v3FailedCount > 0 || !failedIngestRecords.isEmpty }
    private var v3AttentionCount: Int { max(v3FailedCount, failedIngestRecords.count) }
    private var v3DoneCount: Int { activeIngests.values.filter { $0.phase == .done }.count }
    private var v3CopyingCount: Int { activeIngests.values.filter { [.copying, .scanning, .building].contains($0.phase) }.count }
    private var v3FinalizingCount: Int { activeIngests.values.filter { [.finalizing, .verifying].contains($0.phase) }.count }
    // "All safe to pull" must be IMPOSSIBLE while any failure exists (transient .failed lane
    // OR a persistent failure record), and a .failed lane must never satisfy "done".
    private var v3AllDone: Bool {
        failedIngestRecords.isEmpty && v3FailedCount == 0 && !activeIngests.isEmpty
            && runningCount == 0 && activeIngests.values.allSatisfy { $0.phase == .done }
    }

    /// Fire the completion celebration exactly once per successful batch, when the ring goes green.
    /// Guarded so it never plays on failure, dry-run, an already-done relaunch, or when the user
    /// picked "None". Consumes the pending flag so it can't re-fire.
    private func v3MaybeCelebrate() {
        guard v3PendingCelebration, v3AllDone, !v3HasFailures, !dryRun, completionAnim != .none else { return }
        v3PendingCelebration = false
        v3CelebrationTrigger += 1
    }

    private func v3LanePct(_ ing: ActiveIngest) -> Double {
        ing.totalBytesNew > 0 ? min(100, Double(ing.doneBytes) / Double(ing.totalBytesNew) * 100) : 0
    }
    // The live per-card status shown in the lane's top-right capsule (the % moved onto the
    // funnel line). Word matches the design (COPYING / FLUSHING / VERIFYING).
    private func v3Status(_ ing: ActiveIngest) -> (String, Color) {
        switch ing.phase {
        case .copying:                    return ("COPYING", v3Cyan)
        case .scanning, .building, .idle: return ("STARTING", v3Cyan)
        case .finalizing:                 return ("FLUSHING", v3Amber)
        case .verifying:                  return ("VERIFYING", v3Green)
        case .done:                       return ("SAFE", v3Green)
        case .failed:                     return ("FAILED", v3Red)
        }
    }

    /// The destination root footage is currently routed to (for the readout / Open-in-Finder).
    private var v3DestRoot: String {
        if useCustomDest, !customDestPath.isEmpty { return customDestPath }
        if !primarySSDPath.isEmpty {
            return projectName.isEmpty ? primarySSDPath : "\(primarySSDPath)/\(projectName)"
        }
        return ""
    }

    private var v3CombinedMBps: Double { activeIngests.values.reduce(0) { $0 + $1.liveMBps } }
    private var v3ActiveLanes: [(id: UUID, ing: ActiveIngest)] { v3Lanes.filter { $0.ing.phase != .done } }
    private var v3DoneLanes: [(id: UUID, ing: ActiveIngest)] { v3Lanes.filter { $0.ing.phase == .done } }

    /// The physical volume that holds the destination (for the drive tile: name + free space).
    private var v3DestDrivePath: String {
        let root = v3DestRoot.isEmpty ? primarySSDPath : v3DestRoot
        let parts = URL(fileURLWithPath: root).pathComponents
        if parts.count >= 3, parts[1] == "Volumes" { return "/Volumes/\(parts[2])" }
        return root
    }
    private var v3DestDriveName: String {
        let p = v3DestDrivePath
        if p == "/" || p.isEmpty { return "Macintosh HD" }
        return URL(fileURLWithPath: p).lastPathComponent
    }
    /// Per-lane "→ destination" name for the in-flight status label. Resolves each lane's OWN
    /// routed destination — `ing.destinationID` → its friendly name, else the drive parsed from
    /// `ing.destPath` — so a multi-destination user sees where THAT card is actually going, not a
    /// single global legacy readout (P1-5). Pure lookup, never mutates, never crashes on a stale ID.
    private func v3LaneDestName(_ ing: ActiveIngest) -> String {
        if let id = ing.destinationID,
           let d = destinations.first(where: { $0.id == id }), !d.name.isEmpty {
            return d.name
        }
        let p = ing.destPath
        if !p.isEmpty {
            let parts = URL(fileURLWithPath: p).pathComponents
            if parts.count >= 3, parts[1] == "Volumes" { return parts[2] }
            let last = URL(fileURLWithPath: p).lastPathComponent
            if !last.isEmpty, last != "/" { return last }
        }
        return defaultDestination?.name ?? v3DestDriveName
    }
    /// Render-safe free-space label: a PURE read of the off-main cache (never touches the
    /// filesystem on the main thread). Shows "…" until the first background probe lands.
    private func v3FreeSpace(_ path: String) -> String {
        v3FreeSpaceCache[path] ?? "…"
    }

    /// The actual volume probe — runs only on a background thread (see refreshFreeSpaceCache).
    nonisolated private static func freeSpaceLabel(forPath path: String) -> String {
        if let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let b = v.volumeAvailableCapacity {
            return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) + " free"
        }
        return "—"
    }

    /// Probe every volume the v3 UI shows free space for, OFF the main thread, then publish
    /// to v3FreeSpaceCache. Called from lifecycle events — never from a render path (mutating
    /// @State during body evaluation is illegal in SwiftUI). A wedged drive only delays a
    /// cache update; it can no longer freeze the UI.
    @MainActor private func refreshFreeSpaceCache(extra: [String] = []) {
        var paths = Set(destinations.map { $0.path })
        paths.insert(v3DestDrivePath)
        if !primarySSDPath.isEmpty { paths.insert(primarySSDPath) }
        for v in v3AllDrives { paths.insert(v.path) }
        for p in extra { paths.insert(p) }
        let wanted = paths.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return }
        Task.detached(priority: .utility) {
            var results: [String: String] = [:]
            for p in wanted { results[p] = Self.freeSpaceLabel(forPath: p) }
            await MainActor.run { for (k, v) in results { self.v3FreeSpaceCache[k] = v } }
        }
    }
    private func v3SpeedText(_ mbps: Double) -> String {
        mbps >= 1000 ? String(format: "%.2f GB/s", mbps / 1000) : String(format: "%.0f MB/s", mbps)
    }

    // MARK: Body

    var bodyV3: some View {
        ZStack {
            v3Background
            VStack(spacing: 18) {
                v3TopBar.zIndex(1)
                // Full-Disk-Access gate — without it NO card can be read and NO file copied.
                // checkFDA() re-probes on every didBecomeActive, so returning from System
                // Settings clears this automatically. Highest-priority blocker → top of stage.
                if !fdaGranted { v3FDABanner.zIndex(1) }
                // DRY RUN is a simulation — NO files are copied. Loud banner so the operator
                // never mistakes a dry run for a real transfer (a card would NOT be safe to pull).
                if dryRun { v3DryRunBanner.zIndex(1) }
                // Developer tools (Run Demo / log / dry-run) — only when Debug Mode is on.
                if debugMode { v3DebugStrip.zIndex(1) }
                v3Stage
                v3BottomBar
            }
            .padding(26)

            // Subtle iridescent gloss sweep — a feathered, skewed band that drifts across the
            // stage every ~20 s. Idle between passes (KeyframeAnimator one-shot, timer-triggered)
            // so there's no always-on render cost. Non-interactive; sits above content, below modals.
            v3Sheen.allowsHitTesting(false).zIndex(2)

            // The redesigned v3 Settings screen (icon rail + migrated settings). Tapping the
            // dimmed backdrop closes it. (The old legacy settingsSheet has been removed.)
            if isShowingSettings {
                let closeSettings = { withAnimation(.easeInOut(duration: 0.18)) { isShowingSettings = false } }
                Color.black.opacity(0.5).ignoresSafeArea()
                    .onTapGesture(perform: closeSettings)
                    .transition(.opacity).zIndex(80)
                v3SettingsView
                    .shadow(color: .black.opacity(0.55), radius: 40, y: 14)
                    .transition(v3ModuleTransition)
                    // Robust Escape-to-close (onExitCommand needs first-responder focus, which the
                    // overlay lacks — the hidden .cancelAction button works regardless).
                    .background(Button("", action: closeSettings).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true))
                    .onExitCommand(perform: closeSettings)
                    .zIndex(81)
            }

            // v3 modules — centered cards over a dimmed scrim (dismiss on outside-click + Escape).
            v3ModalOverlay($showV3AddDest) { v3AddDestSheet }
            v3ModalOverlay($showV3EditDest) { v3EditDestSheet }
            v3ModalOverlay($showV3NewProject) { v3NewProjectSheet }
            v3ModalOverlay($showV3History) { v3HistorySheet }
            v3ModalOverlay($showV3Log) { v3LogSheet }
            v3ModalOverlay($showV3DateRange) { v3DateRangeSheet }
        }
        .frame(minWidth: 1200, minHeight: 780)
        .preferredColorScheme(.dark)
        .onReceive(v3SheenTimer) { _ in v3SheenTrigger += 1 }   // fire one gloss sweep, ~every 20 s
        // Celebrate ONCE when the whole transfer finishes (ring goes green). Both onChanges cover the
        // ordering: the last card may set `pending` and flip `v3AllDone` in either order.
        .onChange(of: v3AllDone) { _, done in
            if done { v3MaybeCelebrate() } else { v3PendingCelebration = false }
        }
        .onChange(of: v3PendingCelebration) { _, pend in if pend && v3AllDone { v3MaybeCelebrate() } }
        // Focus move: commit the lane we LEFT (only if the operator actually edited it — Esc
        // resets userEdited so a cancelled edit doesn't persist), and capture the ENTERED lane's
        // current value so Esc can restore it. Never starts a copy.
        .onChange(of: editingAwaitingID) { old, new in
            if let old, awaitingCards.first(where: { $0.id == old })?.userEdited == true { persistAwaitingName(old) }
            if let new, let aw = awaitingCards.first(where: { $0.id == new }) { v3PreEditName = aw.customName }
        }
        .onChange(of: editingActiveID) { old, new in
            if let old, activeIngests[old]?.pendingRename != nil { v3CommitActiveRename(old) }
            if let new { v3PreEditName = activeIngests[new]?.pendingRename ?? "" }
        }
    }

    /// A centered modal card over a dimmed scrim — the same pattern as the v3 Settings overlay, so
    /// every v3 module dismisses on an OUTSIDE CLICK and on Escape (`.onExitCommand`), not just via its
    /// own close button. Outside-tap = Cancel semantics: it only flips the presenting flag, so any
    /// in-progress form state (Add/Edit) is abandoned, never committed (commits live in the explicit
    /// commit fns). Sits above content/Sheen (zIndex 60+), below the Settings overlay (80).
    @ViewBuilder
    private func v3ModalOverlay<Content: View>(_ isPresented: Binding<Bool>,
                                               @ViewBuilder _ content: () -> Content) -> some View {
        if isPresented.wrappedValue {
            let dismiss = { withAnimation(.easeInOut(duration: 0.18)) { isPresented.wrappedValue = false } }
            Color.black.opacity(0.5).ignoresSafeArea()
                .onTapGesture(perform: dismiss)
                .transition(.opacity).zIndex(60)
            content()
                // Rounded glass corners for EVERY module (folded in here so all six get it for free).
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.55), radius: 40, y: 14)
                // Escape to dismiss — a hidden .cancelAction button is robust regardless of first
                // responder (unlike .onExitCommand, which needs focus). Modules are conditionally
                // rendered so only the open one's shortcut is live (no dup-cancelAction).
                .background(Button("", action: dismiss).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true))
                .transition(v3ModuleTransition)
                .onExitCommand(perform: dismiss)
                .zIndex(61)
        }
    }

    /// Neon connectors: drag-link cursor line, each active lane → ring and ring → destinations while
    /// copying (animated), PLUS a STATIC amber line from every waiting-to-route card → its chosen (or
    /// default) destination so the operator can see where each parked card will land even at idle. The
    /// awaiting lines render in the idle static Canvas frame too (this fn runs in both branches) — they
    /// never widen the animated 20fps branch, so a parked linked card costs one static frame, not a loop.
    private func v3DrawFunnel(_ ctx: inout GraphicsContext, rects: [String: CGRect], phase: CGFloat) {
        // Live drag-to-link line follows the cursor from the node to the drop point.
        if let dl = dragLine {
            var p = Path(); p.move(to: dl.from)
            p.addCurve(to: dl.to,
                       control1: CGPoint(x: (dl.from.x + dl.to.x)/2, y: dl.from.y),
                       control2: CGPoint(x: (dl.from.x + dl.to.x)/2, y: dl.to.y))
            ctx.stroke(p, with: .color(v3Cyan.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 6]))
            ctx.fill(Path(ellipseIn: CGRect(x: dl.to.x - 5, y: dl.to.y - 5, width: 10, height: 10)),
                     with: .color(v3Cyan))
        }
        guard let ring = rects["ring"] else { return }
        let rc = CGPoint(x: ring.midX, y: ring.midY)
        let rad = ring.width / 2
        let leftPort = CGPoint(x: rc.x - rad, y: rc.y)
        let rightPort = CGPoint(x: rc.x + rad, y: rc.y)

        // Curve helper (S-curve between two horizontal ports).
        func curve(_ from: CGPoint, _ to: CGPoint) -> Path {
            var p = Path(); p.move(to: from)
            p.addCurve(to: to,
                       control1: CGPoint(x: (from.x + to.x) / 2, y: from.y),
                       control2: CGPoint(x: (from.x + to.x) / 2, y: to.y))
            return p
        }

        // Active flow (animated), capped at 6 lanes to avoid clutter. Each lane gets its OWN hue from
        // the app palette so overlapping/crossing lines are distinguishable (a failed lane stays RED —
        // safety status is never recolored).
        if v3ActiveLanes.count <= 6 {
            // Neon glow WITHOUT a blur filter — layered strokes are cheap enough for the 20 fps
            // active redraw, so the glow can never starve the copy pipe (unlike a per-frame blur):
            // a wide translucent halo → a mid band → a bright solid core → a moving highlight for
            // the live "flow" feel. Gives the crisscrossing lines a glowing neon read.
            let flow = StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 12], dashPhase: -phase)
            func glowLine(_ p: Path, _ col: Color) {
                ctx.stroke(p, with: .color(col.opacity(0.16)), style: StrokeStyle(lineWidth: 9,   lineCap: .round))
                ctx.stroke(p, with: .color(col.opacity(0.45)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                ctx.stroke(p, with: .color(col),               style: StrokeStyle(lineWidth: 2,   lineCap: .round))
                ctx.stroke(p, with: .color(.white.opacity(0.5)), style: flow)
            }
            for (i, item) in v3ActiveLanes.enumerated() {
                guard let lr = rects["lane-\(item.id)"] else { continue }
                let col: Color = item.ing.phase == .failed ? v3Red : v3LineColor(i)
                glowLine(curve(CGPoint(x: lr.maxX, y: lr.midY), leftPort), col)
            }
            if !v3ActiveLanes.isEmpty {
                let destKeys: [String] = ["dest-default"] + destinations
                    .filter { $0.id != defaultDestination?.id }.map { "dest-\($0.id)" }
                let col = v3FailedCount > 0 ? v3Amber : v3AllDone ? v3Green : v3Cyan
                for key in destKeys {
                    guard let dr = rects[key] else { continue }
                    glowLine(curve(rightPort, CGPoint(x: dr.minX, y: dr.midY)), col)
                }
            }
        }

        // Waiting-to-route cards: STATIC amber line lane → ring → chosen (or default) destination.
        // Capped at 8 lines to avoid clutter (each parked lane still shows its "→ Drive" text label);
        // beyond 8 parked cards the routing is read from the lane labels rather than the connectors.
        // Each parked card's route gets its OWN hue (was all amber → indistinguishable when the lines
        // cross/merge). Both segments + the destination dot share the card's color so you can trace it.
        let staticDash = StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 7])
        for (i, aw) in awaitingCards.prefix(8).enumerated() {
            guard let lr = rects["lane-\(aw.id)"],
                  let destID = aw.destinationID ?? defaultDestination?.id else { continue }
            let destKey = destID == defaultDestination?.id ? "dest-default" : "dest-\(destID)"
            guard let dr = rects[destKey] else { continue }
            let to = CGPoint(x: dr.minX, y: dr.midY)
            let col = v3LineColor(i)
            ctx.stroke(curve(CGPoint(x: lr.maxX, y: lr.midY), leftPort), with: .color(col.opacity(0.65)), style: staticDash)
            ctx.stroke(curve(rightPort, to), with: .color(col.opacity(0.65)), style: staticDash)
            ctx.fill(Path(ellipseIn: CGRect(x: to.x - 3.5, y: to.y - 3.5, width: 7, height: 7)),
                     with: .color(col.opacity(0.9)))
        }
    }

    /// A per-lane hue from the app palette — cycles so adjacent/overlapping funnel lines are
    /// distinguishable. All members stay within the CardRunner neon hue family.
    private func v3LineColor(_ i: Int) -> Color {
        let palette: [Color] = [v3Cyan, v3Purple, v3Mag, Color(hex: "#5b8def"),
                                v3Green, Color(hex: "#f472b6"), Color(hex: "#2dd4bf"), Color(hex: "#a78bfa")]
        return palette[((i % palette.count) + palette.count) % palette.count]
    }

    private var v3Background: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#0c0822"), Color(hex: "#080615"), Color(hex: "#050310")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(hex: "#7c3aed").opacity(0.20), .clear], center: .init(x: 0.22, y: 0.08), startRadius: 0, endRadius: 760)
            RadialGradient(colors: [Color(hex: "#0dcff5").opacity(0.13), .clear], center: .init(x: 0.84, y: 0.92), startRadius: 0, endRadius: 640)
        }
        .ignoresSafeArea()
        // Click empty space to leave (and COMMIT, via the editingID onChange) an in-progress lane-name
        // edit — same as pressing ✓. This sits at the very BACK of the ZStack, so interactive content
        // and drag gestures on top consume their own events; only a tap on bare canvas reaches here.
        .contentShape(Rectangle())
        .onTapGesture { editingAwaitingID = nil; editingActiveID = nil }
    }

    // MARK: Top bar
    private var v3ActivePresetName: String {
        if let id = activePresetID, let p = presets.first(where: { $0.id == id }) { return p.name }
        return "Preset"
    }
    /// The CardRunner logo lockup (SD-card mark + wordmark + tagline). Kept as one unit so it
    /// can be centered on the true window center — i.e. aligned with the Active-Zone ring below.
    // ════════════════════════════════════════════════════════════════════════
    // MARK: - v3 Settings screen (icon-rail redesign)
    // Migrates every legacy setting into the new look. Presets / Shortcuts / About
    // embed the existing functional flows (restyle is a Stage-2 follow-up).
    // ════════════════════════════════════════════════════════════════════════

    var v3SettingsView: some View {
        HStack(spacing: 0) {
            v3SettingsRail
            v3SettingsContent
        }
        .frame(width: 1000, height: 700)
        .background(Color(hex: "#0d0a1a"))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .preferredColorScheme(.dark)
    }

    private var v3SettingsRail: some View {
        VStack(spacing: 8) {
            // Brand mark (top)
            Image("CardRunnerLogo").resizable().aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
                .padding(.bottom, 10)
            ForEach(V3SettingsCat.allCases.filter { $0 != .about }) { cat in
                v3SettingsRailIcon(cat)
            }
            Spacer()
            v3SettingsRailIcon(.about)   // info icon pinned to the bottom
        }
        .padding(.vertical, 22)
        .frame(width: 78)
        .background(Color.white.opacity(0.02))
        .overlay(Rectangle().frame(width: 1).foregroundStyle(.white.opacity(0.06)), alignment: .trailing)
    }

    private func v3SettingsRailIcon(_ cat: V3SettingsCat) -> some View {
        let selected = v3SettingsCat == cat
        let hovered = v3HoveredRailCat == cat
        return Button {
            // Spring drives the matched-geometry pill so it SWOOSHES from the old tab to this one.
            withAnimation(v3Anim(.spring(response: 0.38, dampingFraction: 0.72))) { v3SettingsCat = cat }
        } label: {
            Image(systemName: cat.icon)
                .font(.system(size: 17, weight: .medium))
                // Unselected icon turns light-blue on hover (extra "clickable" cue beyond the scale).
                .foregroundStyle(selected ? .white : (hovered ? v3Cyan : .white.opacity(0.4)))
                .frame(width: 44, height: 44)
                // Hover highlight (non-selected only) — sits behind the icon, separate from the swoosh.
                .background {
                    if hovered && !selected {
                        RoundedRectangle(cornerRadius: 13, style: .continuous).fill(v3Cyan.opacity(0.10))
                    }
                }
                // The sliding purple "swoosh": one matched pill flies between tabs on selection.
                .swooshSelection(selected, in: settingsTabNS, groupID: "settingsRail",
                                 fill: AnyShapeStyle(v3Brand.opacity(0.95)),
                                 cornerRadius: 13, glow: v3Purple.opacity(0.55))
                // Leading cyan accent travels with the pill (matched to the same swoosh).
                .overlay(alignment: .leading) {
                    if selected {
                        Capsule().fill(v3Cyan).frame(width: 3, height: 20).offset(x: -19)
                            .matchedGeometryEffect(id: "settingsRailAccent", in: settingsTabNS)
                    }
                }
                .shadow(color: v3Cyan.opacity(hovered && !selected ? 0.55 : 0), radius: 10)
                .scaleEffect(hovered ? 1.08 : 1)
                // Larger cell so the whole rail row is clickable, not just the 44pt icon.
                .frame(width: 58, height: 50)
                .contentShape(RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: hovered)
        .onHover { v3HoveredRailCat = $0 ? cat : (v3HoveredRailCat == cat ? nil : v3HoveredRailCat) }
        .help(cat.title)
    }

    private var v3SettingsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(v3SettingsCat.title).font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                    Text(v3SettingsCat.subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                // Same red-on-hover close as the modules (was a plain X — the reported gap).
                V3CloseButton { withAnimation(.easeInOut(duration: 0.18)) { isShowingSettings = false } }
            }
            .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 18)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    v3SettingsCatBody
                }
                .padding(.horizontal, 32).padding(.vertical, 26)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var v3SettingsCatBody: some View {
        switch v3SettingsCat {
        case .general:     v3SettingsGeneral
        case .verify:      v3SettingsVerify
        case .naming:      v3SettingsNaming
        case .files:       v3SettingsFiles
        case .performance: v3SettingsPerformance
        case .presets:     v3SettingsEmbed { settingsPresetsTab }
        case .shortcuts:   v3SettingsEmbed { settingsShortcutsTab }
        case .about:       v3SettingsAbout
        }
    }

    // ── Reusable rows ────────────────────────────────────────────────────────
    private func v3SettingsSection<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.35))
            VStack(spacing: 0) { content() }
                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.06)))
        }
    }

    private func v3SettingDivider() -> some View {
        Divider().opacity(0.4).padding(.leading, 18)
    }

    private func v3ToggleRow(_ title: String, _ subtitle: String, _ isOn: Binding<Bool>,
                             enabled: Bool = true, onChange: ((Bool) -> Void)? = nil) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(enabled ? .white : .white.opacity(0.4))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(enabled ? 0.45 : 0.25))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // Liquid-glass switch — ON = brand blue→purple, OFF = gray (MiniPillToggle's default onColor
            // blends neonBlue→neonPurple). Reused from the legacy UI so there's one toggle look.
            MiniPillToggle(isOn: isOn)
                .disabled(!enabled).opacity(enabled ? 1 : 0.4)
                .onChange(of: isOn.wrappedValue) { _, now in onChange?(now) }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func v3MenuRow(_ title: String, _ subtitle: String, current: String,
                           options: [(String, String)], _ onSelect: @escaping (String) -> Void) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Menu {
                ForEach(options, id: \.1) { opt in
                    Button { onSelect(opt.1) } label: {
                        if opt.1 == current { Label(opt.0, systemImage: "checkmark") } else { Text(opt.0) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(options.first { $0.1 == current }?.0 ?? current).font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }
                .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7)
                .background(.white.opacity(0.06), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.10)))
            }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func v3SliderRow(_ title: String, _ subtitle: String, value: Binding<Double>,
                             range: ClosedRange<Double>, step: Double, valueLabel: String) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Slider(value: value, in: range, step: step).frame(width: 220).tint(v3Cyan)
            Text(valueLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(v3Cyan).frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    /// Embed a legacy settings tab inside the new chrome (functional now; restyle later).
    private func v3SettingsEmbed<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A contained preview of the selected completion animation, right in Settings — a mini ring + a
    /// "Play preview" button so styles can be sampled without running an ingest. (The real celebration
    /// renders behind the Settings overlay, so it can't be previewed on the live ring while Settings
    /// is open — hence this self-contained playground.)
    @ViewBuilder private var v3CompletionPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { v3SettingsPreviewTrigger += 1 } label: {
                HStack(spacing: 6) { Image(systemName: "play.fill"); Text("Play preview") }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(completionAnim == .none ? AnyShapeStyle(.white.opacity(0.06)) : AnyShapeStyle(v3Brand), in: Capsule())
                    .contentShape(Capsule())
            }.buttonStyle(.plain).disabled(completionAnim == .none).v3Hover(glow: v3Purple, enabled: completionAnim != .none)

            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 8).frame(width: 120, height: 120)
                if completionAnim == .none {
                    Text("No animation").font(.system(size: 11)).foregroundStyle(.white.opacity(0.3))
                }
                V3CompletionOverlay(center: CGPoint(x: 175, y: 105), radius: 60,
                                    style: completionAnim, trigger: v3SettingsPreviewTrigger)
            }
            .frame(width: 350, height: 210)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 18).padding(.top, 4)
    }

    // ── Category bodies ──────────────────────────────────────────────────────
    private var v3SettingsGeneral: some View {
        VStack(alignment: .leading, spacing: 26) {
            v3SettingsSection("FEEDBACK") {
                v3MenuRow("Completion animation", "Plays on the ring when a transfer finishes.",
                          current: completionAnimationRaw,
                          options: CompletionAnimation.allCases.map { ($0.label, $0.rawValue) }) { completionAnimationRaw = $0 }
                v3CompletionPreview
            }
            v3SettingsSection("INGEST") {
                v3MenuRow("Ingest order", "Order files are dispatched to the destination.",
                          current: ingestOrder, options: [("Oldest first", "oldest"), ("Newest first", "newest")]) { ingestOrder = $0 }
            }
            v3SettingsSection("SESSION") {
                v3MenuRow("Session resets at", "When \u{201C}Today\u{201D}\u{2019}s summary rolls over.",
                          current: String(dayStartHour),
                          options: [("12 am", "0"), ("2 am", "2"), ("4 am", "4"), ("6 am", "6")]) { dayStartHour = Int($0) ?? 4 }
                v3SettingDivider()
                v3ToggleRow("Broadcast-day folder routing",
                            "Clips shot between midnight and your day-start hour file under the previous calendar day.",
                            $broadcastDayFolders)
            }
        }
    }

    private var v3SettingsVerify: some View {
        v3SettingsSection("VERIFICATION & SAFETY") {
            v3ToggleRow("Verify transfer (spot-check)", "Checksum a random sample of up to 10 files after each ingest.", $verifyTransfer)
            v3SettingDivider()
            v3ToggleRow("Full checksum verification", "MD5 every file on source and destination. Slower, exhaustive.", $fullVerifyEnabled)
            v3SettingDivider()
            v3ToggleRow("Auto-eject after ingest", "Safely eject the card once every byte is confirmed.", $autoEject)
            v3SettingDivider()
            v3ToggleRow("Transfer report (CSV)", "Write a per-ingest CSV to TransferReports/ on the destination.", $transferReportEnabled)
        }
    }

    private var v3SettingsNaming: some View {
        VStack(alignment: .leading, spacing: 26) {
            v3SettingsSection("FOLDERS") {
                v3MenuRow("Folder date format", "How each date folder is named during ingest.",
                          current: dateFolderFormat,
                          options: [("260630 (yymmdd)", "%y%m%d"), ("20260630 (yyyymmdd)", "%Y%m%d"),
                                    ("2026-06-30", "%Y-%m-%d"), ("26.06.30", "%y.%m.%d"), ("Tuesday", "%A")]) { dateFolderFormat = $0 }
            }
            v3SettingsSection("TRANSFER MARKER TAG") {
                v3ToggleRow("Tag the first clip of each batch", "Adds a Finder color tag so you can spot where a new card's footage begins.", $finderTagEnabled)
                if finderTagEnabled {
                    v3SettingDivider()
                    v3FinderTagSwatches.padding(.horizontal, 18).padding(.vertical, 12)
                }
            }
            v3SettingsSection("RENAME ON INGEST") {
                v3ToggleRow("Rename files on ingest", "Apply a naming template as files are copied.", $renameOnIngestEnabled)
                if renameOnIngestEnabled {
                    v3SettingDivider()
                    HStack(spacing: 10) {
                        TextField("{cardname}_{original}", text: $renameTemplate)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        Button("Reset") { renameTemplate = "{cardname}_{original}" }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(v3Cyan)
                    }.padding(.horizontal, 18).padding(.vertical, 12)
                }
            }
            v3SettingsSection("PROJECT SCAFFOLD") {
                v3ToggleRow("Create companion folders", "Make a standard folder set inside every new project.", $scaffoldEnabled)
                if scaffoldEnabled {
                    v3SettingDivider()
                    v3ScaffoldEditor.padding(.horizontal, 18).padding(.vertical, 12)
                }
            }
            // Broadcast day-folder structure (competition-day roots keyed by a short code, e.g.
            // TUWE / CURL). The engine feature is complete end-to-end; this restores the only
            // missing piece — the toggle that died with the deleted legacy Pro Tools tab (P1-4).
            v3SettingsSection("BROADCAST — WINTER OLYMPICS") {
                v3ToggleRow("Olympics day-folder structure",
                            "Organize footage into competition-day folders instead of plain dates. For broadcast day workflows.",
                            $winterOlympicsMode)
                if winterOlympicsMode {
                    v3SettingDivider()
                    HStack(spacing: 10) {
                        Text("Day code").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                        TextField("TUWE", text: Binding(
                            get: { olympicsCode },
                            // Uppercase + strip spaces so the folder segment is clean; the arg
                            // emitter (IngestLogic) trims and skips an empty code, so a blank field
                            // simply omits --olympics-code rather than emitting a bare flag.
                            set: { olympicsCode = $0.uppercased().filter { !$0.isWhitespace } }))
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white)
                            .frame(maxWidth: 120)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        Button("Reset") { olympicsCode = "TUWE" }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(v3Cyan)
                        Spacer()
                    }.padding(.horizontal, 18).padding(.vertical, 12)
                }
            }
        }
    }

    private var v3SettingsFiles: some View {
        VStack(alignment: .leading, spacing: 26) {
            v3SettingsSection("EXTRA FILES") {
                v3ToggleRow("Copy in-camera proxies", "Include low-res proxy files in a Proxies/ subfolder.", $includeProxies)
                v3SettingDivider()
                v3ToggleRow("Copy XML sidecars", "Copy .xml sidecar files alongside video clips. No effect in photo mode.", $copyXML)
            }
            let perCardRouting = defaultDestination != nil
            v3SettingsSection("BACKUP") {
                v3ToggleRow("Dual-destination backup",
                            perCardRouting ? "Inactive — you're using per-card routing. Route each card to the drive you want."
                                           : "Copy every file to a second drive in the same pass. Never one copy.",
                            $dualDestEnabled, enabled: !perCardRouting)
                if dualDestEnabled && !perCardRouting {
                    v3SettingDivider()
                    HStack(spacing: 12) {
                        Text("Secondary SSD").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                        Picker("", selection: $selectedSecondary) {
                            Text("— none —").tag(Optional<Volume>.none)
                            ForEach(availableDestinations.filter { $0.path != selectedPrimary?.path }) { vol in
                                Text(vol.name).tag(Optional(vol))
                            }
                        }.labelsHidden().onChange(of: selectedSecondary) { secondaryPath = selectedSecondary?.path ?? "" }
                        Spacer()
                    }.padding(.horizontal, 18).padding(.vertical, 12)
                }
            }
        }
    }

    private var v3SettingsPerformance: some View {
        v3SettingsSection("THROUGHPUT") {
            v3SliderRow("Concurrent copies", "How many cards transfer at once (across different drives).",
                        value: Binding(get: { Double(maxConcurrentCards) }, set: { maxConcurrentCards = Int($0) }),
                        range: 1...8, step: 1, valueLabel: "\(maxConcurrentCards) cop\(maxConcurrentCards == 1 ? "y" : "ies")")
        }
    }

    private var v3SettingsAbout: some View {
        VStack(alignment: .leading, spacing: 26) {
            v3SettingsEmbed { settingsAboutTab }
            // DEVELOPER tools are hidden — there is NO visible toggle. Unlock with the secret
            // ⌥-click on the version number in the About card above (v3ToggleDevUnlock). A normal
            // user never sees this section; when unlocked it exposes the Dry-Run controls, the
            // onboarding tools, and the main-screen DEV bar (Show Log / fake-fixture spawners).
            if debugMode {
                v3SettingsSection("DEVELOPER") {
                    v3ToggleRow("Show Dry-Run toggle", "Expose a simulate-only switch.", $showDryRunToggle) { now in
                        if !now { dryRun = false }
                    }
                    if showDryRunToggle {
                        v3SettingDivider()
                        v3ToggleRow("Dry Run — simulate (no files copied)", "Evaluate and log an ingest without copying or ejecting.", $dryRun)
                    }
                    v3SettingDivider()
                    HStack(spacing: 12) {
                        Button("Reset onboarding") { onboardingCompleted = false }
                            .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(v3Cyan)
                        Button("Preview onboarding now") {
                            isShowingSettings = false; showOnboarding = true
                        }.buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(v3Cyan)
                        Spacer()
                        // Explicit lock affordance (in addition to ⌥-clicking the version again).
                        Button("Hide developer tools") { v3ToggleDevUnlock() }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                            .help("Re-hide the developer tools")
                    }.padding(.horizontal, 18).padding(.vertical, 13)
                }
            }
        }
    }

    /// Secret developer-tools unlock. Toggled by ⌥-clicking the version number in Settings ▸ About
    /// (and the "Hide developer tools" button) — deliberately NOT a visible switch, so a normal user
    /// never stumbles on the fake-fixture spawners. Preserves the legacy cleanup contract: locking
    /// clears the dry-run / log surfaces so a simulate-only state can't get stranded behind a hidden
    /// control. The fake fixtures remain footage-safe regardless (tagged /dev/cardrunner-fake/).
    private func v3ToggleDevUnlock() {
        withAnimation(v3Anim(.easeInOut(duration: 0.2))) { debugMode.toggle() }
        if debugMode { showDryRunToggle = true }
        else { showDryRunToggle = false; dryRun = false; showLog = false }
        AudioEngine.shared.modeSwitch()   // faint audible confirmation of the state flip
    }

    // Finder-tag color swatch picker (7 colors), rebuilt for the new look.
    private var v3FinderTagSwatches: some View {
        HStack(spacing: 12) {
            ForEach(v3TagColors, id: \.tag) { c in
                Circle().fill(c.color).frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(.white, lineWidth: finderTagColor == c.tag ? 2.5 : 0))
                    .overlay(finderTagColor == c.tag ? Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) : nil)
                    .onTapGesture { finderTagColor = c.tag }
            }
            Spacer()
        }
    }

    // Simple scaffold folder-list editor (add / delete) for the new look.
    private var v3ScaffoldEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(scaffoldFolderList.enumerated()), id: \.offset) { idx, folder in
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Text(folder).font(.system(size: 13)).foregroundStyle(.white)
                    Spacer()
                    Button {
                        var list = scaffoldFolderList; list.remove(at: idx); scaffoldFoldersRaw = list.joined(separator: "\n")
                    } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)) }
                        .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(v3Cyan)
                TextField("Add folder…", text: $v3NewScaffold)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.white)
                    .onSubmit {
                        let n = v3NewScaffold.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty else { return }
                        var list = scaffoldFolderList; list.append(n); scaffoldFoldersRaw = list.joined(separator: "\n"); v3NewScaffold = ""
                    }
                Button("Reset") { scaffoldFoldersRaw = "Footage\nAudio\nGraphics\nExports\nAssets\nDocuments" }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    /// Developer tools strip — visible only when Debug Mode is on (Settings ▸ About ▸ Developer).
    /// Brings the old UI's debug surface into v3: Run UI Demo (a full simulated ingest that drives
    /// the real lanes/ring), Show Log, Log Files, and a Dry-Run toggle. Idle/inert otherwise.
    private var v3DebugStrip: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "ladybug.fill").font(.system(size: 12))
                Text("DEV").font(.system(size: 11, weight: .bold)).tracking(1)
            }.foregroundStyle(v3Purple)
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 18)

            // Guard: the demo flips Auto-Ingest on, which would drain any PARKED real cards into
            // the queue and auto-start them when the demo finishes. Block it while cards are
            // awaiting (or a real ingest is running) so a dev can't kick off real copies by accident.
            let demoBlocked = runningCount != 0 || !awaitingCards.isEmpty
            Button { runDemoIngest() } label: {
                Label("Run UI Demo", systemImage: "play.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(demoBlocked ? .white.opacity(0.3) : v3Cyan)
                .disabled(demoBlocked).v3Hover(scale: 1.05, enabled: !demoBlocked)
                .help(awaitingCards.isEmpty ? "Simulate a full ingest (no card needed) — exercises every lane/ring state"
                                            : "Unavailable while cards are waiting to route — the demo would auto-start them")

            Button { showV3Log = true } label: {
                Label("Show Log", systemImage: "doc.plaintext").font(.system(size: 12, weight: .semibold)).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.8)).v3Hover(scale: 1.05)

            Button { NSWorkspace.shared.open(logsDirectoryURL) } label: {
                Label("Log Files", systemImage: "folder").font(.system(size: 12, weight: .semibold)).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.8)).v3Hover(scale: 1.05)

            // Fake-fixture spawners. They inject phantom cards/lanes that mutate v3FailedCount /
            // v3AllDone / the ring, so they must never be reachable by a normal user — the entire
            // DEV bar is hidden behind a SECRET unlock (⌥-click the version in Settings ▸ About),
            // not any visible toggle. (P1-2 resolved by obscurity, not compile-out — Xavier wants
            // these in the shipped build.) All fakes are tagged /dev/cardrunner-fake/ → footage-safe.
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 18)

            // Spawn fake fixtures to exercise the UI with no hardware: +Card = a waiting gold
            // tile, +Done = a "safe to pull" card, +Fail = a failed lane. Clear removes ONLY
            // the fakes (never a real detected card or real ingest).
            Button { v3DevAddFakeCard() } label: {
                Label("Card", systemImage: "plus.rectangle.on.rectangle")
                    .font(.system(size: 12, weight: .semibold)).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(v3Amber).v3Hover(scale: 1.05)
                .help("Add a fake waiting card (gold tile)")
            Button { v3DevAddFakeLane([.copying, .copying, .finalizing, .verifying][v3FakeCardSeq % 4]) } label: {
                Label("Copy", systemImage: "arrow.down.circle").font(.system(size: 12, weight: .semibold)).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(v3Cyan).v3Hover(scale: 1.05)
                .help("Add a fake in-progress lane (%-on-line + COPYING/FLUSHING/VERIFYING)")
            Button { v3DevAddFakeLane(.done) } label: {
                Label("Done", systemImage: "checkmark.circle").font(.system(size: 12, weight: .semibold)).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(v3Green).v3Hover(scale: 1.05)
                .help("Add a fake finished card (safe-to-pull panel)")
            Button { v3DevAddFakeLane(.failed) } label: {
                Label("Fail", systemImage: "xmark.octagon").font(.system(size: 12, weight: .semibold)).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(v3Red).v3Hover(scale: 1.05)
                .help("Add a fake failed lane (failure UI)")

            if v3HasFakeFixtures {
                Button { v3DevClearFakeCards() } label: {
                    Label("Clear", systemImage: "xmark.circle")
                        .font(.system(size: 12, weight: .semibold)).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.55)).v3Hover(scale: 1.05)
                    .help("Remove the fake test fixtures")
            }

            Spacer()

            HStack(spacing: 7) {
                Text("Dry Run").font(.system(size: 12, weight: .semibold)).foregroundStyle(dryRun ? v3Amber : .white.opacity(0.6))
                MiniPillToggle(isOn: $dryRun, onColor: .orange)
            }
            Text("Turn off in Settings").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(v3Purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(v3Purple.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
        .padding(.horizontal, 2)
    }

    // DEV fake fixtures (see v3DebugStrip). Exercise the UI states with no hardware. All are tagged
    // with the /dev/cardrunner-fake/ marker so Clear removes ONLY them and they never call the shell.
    // Reachable in Release ONLY via the secret ⌥-click unlock (Settings ▸ About version), not a toggle.
    private static let v3FakePrefix = "/dev/cardrunner-fake/"

    /// A "waiting to route" card → the gold waiting tile.
    private func v3DevAddFakeCard() {
        v3FakeCardSeq += 1
        let name = String(format: "A%03d", v3FakeCardSeq)
        let vol = Volume(name: name, path: Self.v3FakePrefix + name, cameraModel: "Sony")
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            awaitingCards.append(AwaitingCard(card: vol, customName: name))
        }
    }
    /// A lane in an arbitrary phase → exercises the copying %-on-line + status capsule, the
    /// safe-to-pull panel (.done), or the failed-lane UI (.failed).
    private func v3DevAddFakeLane(_ phase: IngestPhase) {
        v3FakeCardSeq += 1
        let name = String(format: "A%03d", v3FakeCardSeq)
        var ing = ActiveIngest()
        ing.cardName = name; ing.friendlyName = name; ing.cameraModel = "Sony"
        ing.sourcePath = Self.v3FakePrefix + name; ing.runMode = importMode
        ing.destPath = defaultDestination?.path ?? "/Volumes/Gallo 8TB"
        ing.newFiles = 50; ing.totalFiles = 50; ing.avgMBps = 227; ing.durationSec = 78
        ing.totalBytesNew = 1000
        // Vary the progress so stacked in-progress lanes show DIFFERENT % on their lines.
        let pct = phase == .copying ? [97, 27, 55, 42, 88, 73][v3FakeCardSeq % 6] : 100
        ing.completedFilesBytes = Int64(1000 * pct / 100)
        ing.completedFiles = 50 * pct / 100
        ing.liveMBps = phase == .copying ? 333 : 0
        ing.phase = phase
        ing.hasCopyError = (phase == .failed)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            activeIngests[UUID()] = ing
        }
    }
    private var v3HasFakeFixtures: Bool {
        awaitingCards.contains { $0.card.path.hasPrefix(Self.v3FakePrefix) }
            || activeIngests.values.contains { $0.sourcePath.hasPrefix(Self.v3FakePrefix) }
    }
    /// Removes ONLY the fake test fixtures (never a real detected card or real ingest).
    private func v3DevClearFakeCards() {
        withAnimation(.easeInOut(duration: 0.2)) {
            awaitingCards.removeAll { $0.card.path.hasPrefix(Self.v3FakePrefix) }
            for key in activeIngests.filter({ $0.value.sourcePath.hasPrefix(Self.v3FakePrefix) }).map(\.key) {
                activeIngests.removeValue(forKey: key)
            }
        }
        // P1-3: a fake sim arms v3PendingCelebration; clearing the fakes before it's consumed
        // must NOT leave a primed burst that later fires on a real batch. Disarm it here.
        v3PendingCelebration = false
        v3FakeCardSeq = 5
    }
    /// DEV preview: a fake card's Start runs a SIMULATED transfer — copying (ramps ~5s) →
    /// flushing → done (safe to pull) — so the full lifecycle can be previewed with no hardware.
    /// Never runs the shell / touches real ingest state; the lane is tagged fake so Clear wipes it.
    private func v3DevSimulateIngest(_ aw: AwaitingCard) {
        let name = aw.customName.isEmpty ? aw.card.name : aw.customName
        let procID = UUID()
        var ing = ActiveIngest()
        ing.cardName = name; ing.friendlyName = name; ing.cameraModel = aw.card.cameraModel
        ing.sourcePath = aw.card.path          // keeps the /dev/cardrunner-fake/ marker → Clear removes it
        ing.runMode = importMode
        ing.destPath = defaultDestination?.path ?? "/Volumes/Gallo 8TB"
        ing.newFiles = 50; ing.totalFiles = 50
        ing.totalBytesNew = 1_000_000_000      // 1 GB fake payload
        ing.liveMBps = 200
        ing.phase = .copying
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            awaitingCards.removeAll { $0.id == aw.id }
            activeIngests[procID] = ing
        }
        Task { @MainActor in
            let steps = 50
            for s in 1...steps {                                  // ~5s copy ramp (100ms × 50)
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard activeIngests[procID] != nil else { return } // Clear/cancel stops the sim
                activeIngests[procID]?.completedFilesBytes = Int64(Double(ing.totalBytesNew) * Double(s) / Double(steps))
                activeIngests[procID]?.completedFiles = Int(Double(ing.newFiles) * Double(s) / Double(steps))
            }
            guard activeIngests[procID] != nil else { return }
            activeIngests[procID]?.phase = .finalizing            // brief flush beat
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard activeIngests[procID] != nil else { return }
            if !dryRun { v3PendingCelebration = true }            // preview the completion burst (mirrors real)
            withAnimation(.easeInOut(duration: 0.3)) {
                activeIngests[procID]?.phase = .done
                activeIngests[procID]?.liveMBps = 0
            }
        }
    }

    /// Subtle iridescent gloss sweep. A wide, feathered, -13°-skewed band drifts across the
    /// stage over ~7 s, opacity easing in/out so it never pops. Fired occasionally by v3SheenTimer
    /// (idle between passes — a KeyframeAnimator one-shot, NOT an always-on TimelineView, so there
    /// is no continuous render cost). Brand-tinted (cyan→white→magenta) for a faint holographic read.
    private var v3Sheen: some View {
        GeometryReader { geo in
            let sweep = geo.size.width + 640
            Rectangle()
                .fill(LinearGradient(stops: [
                    .init(color: .clear,                location: 0.00),
                    .init(color: v3Cyan.opacity(0.03),  location: 0.30),
                    .init(color: .white.opacity(0.055), location: 0.50),   // softer, lower-contrast core
                    .init(color: v3Mag.opacity(0.03),   location: 0.70),
                    .init(color: .clear,                location: 1.00),
                ], startPoint: .leading, endPoint: .trailing))
                .frame(width: 560, height: geo.size.height * 1.8)          // wider band, more real estate
                .blur(radius: 26)                                          // more feather
                .rotationEffect(.degrees(-13))
                .frame(width: geo.size.width, height: geo.size.height)
                .keyframeAnimator(initialValue: V3SheenState(), trigger: v3SheenTrigger) { content, v in
                    content.offset(x: -sweep / 2 + v.x * sweep).opacity(v.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.x) { LinearKeyframe(1.0, duration: 7.0) }
                    KeyframeTrack(\.opacity) {
                        CubicKeyframe(1.0, duration: 1.6)    // ease in
                        LinearKeyframe(1.0, duration: 3.8)   // hold
                        CubicKeyframe(0.0, duration: 1.6)    // ease out
                    }
                }
                .blendMode(.screen)
        }
    }

    private var v3LogoLockup: some View {
        HStack(spacing: 12) {
            Image("CardRunnerLogo")
                .resizable().renderingMode(.original).aspectRatio(contentMode: .fit)
                .frame(width: 84, height: 84)
                .shadow(color: v3Purple.opacity(0.45), radius: 16)
            VStack(alignment: .leading, spacing: 2) {
                // Saira ExtraBold Italic (weight 800) — bundled static cut, PostScript name below.
                Text("CARDRUNNER").font(.custom("SairaItalic-ExtraBoldItalic", size: 30)).foregroundStyle(v3Brand)
                Text("a smoother ingest workflow for creators")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var v3TopBar: some View {
        // ZStack so the logo lockup sits at the TRUE window center (overlapping the edge
        // controls' row) — that lines it up with the ring, regardless of the left button cluster.
        ZStack {
            v3LogoLockup
            HStack(spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { isShowingSettings = true } } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(v3GearHovered ? v3Cyan : .white.opacity(0.7)).frame(width: 32, height: 32)
                    .background(.white.opacity(v3GearHovered ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(v3GearHovered ? v3Cyan.opacity(0.5) : .white.opacity(0.10)))
                    .shadow(color: v3Cyan.opacity(v3GearHovered ? 0.5 : 0), radius: 10)   // blue "clickable" glow
                    .scaleEffect(v3GearHovered ? 1.08 : 1)
            }.buttonStyle(.plain)
                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: v3GearHovered)
                .onHover { v3GearHovered = $0 }.help("Settings")
            Button { showV3History = true } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(v3HistHovered ? v3Cyan : .white.opacity(0.7)).frame(width: 32, height: 32)
                    .background(.white.opacity(v3HistHovered ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(v3HistHovered ? v3Cyan.opacity(0.5) : .white.opacity(0.10)))
                    .shadow(color: v3Cyan.opacity(v3HistHovered ? 0.5 : 0), radius: 10)   // same blue glow as the gear
                    .scaleEffect(v3HistHovered ? 1.08 : 1)
            }.buttonStyle(.plain)
                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: v3HistHovered)
                .onHover { v3HistHovered = $0 }.help("Ingest history & stats")
            // Preset quick-switch — one tap applies a saved preset (mode, verify, naming,
            // subfolder, scaffold, etc.). Only shown when presets exist. applyPreset() sets
            // activePresetID and every backing pref the engine reads.
            if !presets.isEmpty {
                Menu {
                    ForEach(presets) { p in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { applyPreset(p) }
                            AudioEngine.shared.modeSwitch()
                        } label: {
                            if activePresetID == p.id { Label(p.name, systemImage: "checkmark") }
                            else { Text(p.name) }
                        }
                    }
                    Divider()
                    Button("Edit presets…") {
                        v3SettingsCat = .presets
                        withAnimation(.easeInOut(duration: 0.18)) { isShowingSettings = true }
                    }
                } label: {
                    HStack(spacing: 6) { Image(systemName: "rectangle.stack.fill"); Text(v3ActivePresetName) }
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(.white.opacity(0.05), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                        .contentShape(Capsule())
                }.menuStyle(.borderlessButton).fixedSize().v3Hover(glow: v3Cyan).help("Switch ingest preset")
            }
            // Video / Photo mode (also ⌘1 / ⌘2). Photo mode changes what cardcopy ingests.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { importMode = (importMode == "photo" ? "video" : "photo") }
                AudioEngine.shared.modeSwitch()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: importMode == "photo" ? "camera.fill" : "video.fill")
                    Text(importMode == "photo" ? "Photo" : "Video")
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 32)
                .background(.white.opacity(0.05), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            }.buttonStyle(.plain).help("Video / Photo mode (⌘1 / ⌘2)")
            Spacer()
            // Auto-ingest toggle lives ONLY in the center console now (Xavier's call — it used to
            // appear here, below the ring, AND in the footer). See v3Ring.
            }
        }
    }

    // MARK: Sources (real lanes + awaiting "drag to route" lanes)
    /// The central stage: source lanes · ring · destinations, with the funnel-connector Canvas
    /// background + the celebration and per-lane-% overlays. Extracted from `bodyV3` into its own
    /// computed property so the parent view expression stays within the Swift type-checker's
    /// inference budget (the columns' new center-alignment frames pushed the inline body over it).
    private var v3Stage: some View {
        HStack(alignment: .top, spacing: 24) {
            // Each column fills the FULL stage height so its balanced top/bottom Spacers can
            // center the content group on the ring's vertical center (was top-pinned → cards
            // piled down from the top). The ring already had balanced spacers.
            v3Sources.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            v3Ring.frame(width: 360)   // ring VStack already fills height via its balanced spacers
            v3Destinations.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
        .coordinateSpace(name: "stage")
        .backgroundPreferenceValue(V3AnchorKey.self) { anchors in
            GeometryReader { geo in
                let rects = anchors.mapValues { geo[$0] }
                // Animate the flowing connectors ONLY while there's real flow (copying or
                // a drag), and cap the rate at 20 fps — NOT display refresh — so the Canvas
                // can never peg a core. When idle, draw ONE static frame (no redraw loop).
                // The previous TimelineView(.animation) ran at 120 fps forever and burned
                // a whole core, starving the ingest pipe.
                // Gate on IN-FLIGHT phases only: a purely-`.failed` (or idle) lane residue
                // must NOT keep the Canvas redrawing — otherwise a lingering failed lane
                // (today only reachable via the DEV fake fixtures) pegs a core with nothing
                // flowing. Real + fake copying lanes still animate; failed/idle don't.
                let v3FunnelFlowing = v3ActiveLanes.contains {
                    [.scanning, .building, .copying, .finalizing, .verifying].contains($0.ing.phase)
                }
                if runningCount > 0 || dragLine != nil || v3FunnelFlowing {
                    TimelineView(.periodic(from: Date(), by: 1.0 / 20.0)) { tl in
                        Canvas { ctx, _ in
                            let phase = CGFloat(tl.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: 0.7)) / 0.7 * 14
                            v3DrawFunnel(&ctx, rects: rects, phase: phase)
                        }
                    }
                } else {
                    Canvas { ctx, _ in v3DrawFunnel(&ctx, rects: rects, phase: 0) }
                }
            }
            // The funnel Canvas is the background of the central columns, so this catches taps
            // on the empty central stage too — click there to leave (and commit) a lane-name
            // edit. It sits BEHIND the lanes/tiles/ring/dots, so their taps + drags win.
            .contentShape(Rectangle())
            .onTapGesture { editingAwaitingID = nil; editingActiveID = nil }
        }
        // Completion celebration — a one-shot neon burst anchored to the ring, above the
        // columns. Non-interactive; driven by v3CelebrationTrigger + the selected style.
        .overlayPreferenceValue(V3AnchorKey.self) { anchors in
            GeometryReader { geo in
                if let r = anchors["ring"].map({ geo[$0] }) {
                    V3CompletionOverlay(center: CGPoint(x: r.midX, y: r.midY),
                                        radius: r.width / 2,
                                        style: completionAnim,
                                        trigger: v3CelebrationTrigger)
                }
            }
            .allowsHitTesting(false)
        }
        // Per-lane % riding at the START of each connector line, OUTSIDE the card — colored
        // to match that lane's funnel line (state-driven text, not an animation → no core burn).
        .overlayPreferenceValue(V3AnchorKey.self) { anchors in
            GeometryReader { geo in
                ForEach(Array(v3ActiveLanes.enumerated()), id: \.element.id) { i, item in
                    if [.copying, .finalizing, .verifying].contains(item.ing.phase),
                       let r = anchors["lane-\(item.id)"].map({ geo[$0] }) {
                        // The guard above already excludes `.failed`, so this line is always
                        // an in-flight lane — colour it to match its funnel connector.
                        let col: Color = v3LineColor(i)
                        Text("\(Int(v3LanePct(item.ing)))%")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(col)
                            .shadow(color: col.opacity(0.5), radius: 6)
                            .position(x: r.maxX + 42, y: r.midY - 8)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var v3Sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Balanced with the trailing Spacer below → the whole group (header + cards) centers
            // vertically on the ring; 1 card sits centered, N grow symmetrically up/down.
            Spacer(minLength: 0)
            // Persistent failure warnings — survive lane cleanup AND app relaunch, so an operator
            // is never told a failed card is safe to format. Dismiss only when acknowledged.
            if !failedIngestRecords.isEmpty { v3FailureStrip }
            Text("SOURCES").font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.4))
            if v3Lanes.isEmpty && awaitingCards.isEmpty {
                Text(autoIngest ? "Waiting for a card…" : "Auto-ingest is off — plug a card to route it")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                    .frame(width: 360, alignment: .leading).padding(.vertical, 8)
            }
            // Awaiting cards first — they're what the user acts on (drag node → drive, or Start).
            ForEach(awaitingCards) { aw in v3AwaitingLane(aw) }
            ForEach(v3ActiveLanes, id: \.id) { item in v3Lane(item.id, item.ing) }
            if !v3DoneLanes.isEmpty {
                v3DonePile
                // "Tap to review" reveals the individual done cards, each with its own Pull button
                // (the existing v3Lane .done rows — reused, not duplicated).
                if v3DoneExpanded {
                    ForEach(v3DoneLanes, id: \.id) { item in v3Lane(item.id, item.ing) }
                }
            }
            Spacer(minLength: 0)
            // Top-bias: lift the centered group so the cards align with the RING, which itself sits
            // a little above stage-center because the auto-ingest pill hangs below it in the middle
            // column. Fixed nudge (≈half of this) toward the top. One number — tune to taste.
            Color.clear.frame(height: 170)
        }
    }

    /// Full-Disk-Access blocker banner (v3). Without FDA the app cannot read cards or write
    /// drives, so this is a hard gate, not a nicety. "Grant Access" opens the Privacy pane;
    /// the existing checkFDA() on didBecomeActive clears it when the user returns having granted.
    private var v3FDABanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.system(size: 18)).foregroundStyle(v3Red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access required")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(v3Red)
                Text("CardRunner can't read cards or write to drives without it — no footage can be copied.")
                    .font(.system(size: 11)).foregroundStyle(v3Red.opacity(0.8))
            }
            Spacer()
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Grant Access →")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(v3Red, in: Capsule())
            }.buttonStyle(.plain).help("Open System Settings ▸ Privacy & Security ▸ Full Disk Access")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(v3Red.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(v3Red.opacity(0.45)))
        .padding(.horizontal, 2)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Dry-Run banner — a dry run SIMULATES an ingest and copies NOTHING. Loud, persistent
    /// warning so an operator never reads a "done" lane as real footage on disk. One tap turns it off.
    private var v3DryRunBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.rays").font(.system(size: 18)).foregroundStyle(v3Amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("DRY RUN — nothing is being copied")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(v3Amber)
                Text("Ingests are simulated: folders are logged but no files land on disk and cards are not ejected.")
                    .font(.system(size: 11)).foregroundStyle(v3Amber.opacity(0.8))
            }
            Spacer()
            Button { dryRun = false } label: {
                Text("Turn off")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(v3Amber, in: Capsule())
            }.buttonStyle(.plain).help("Turn off Dry Run and copy for real")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(v3Amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(v3Amber.opacity(0.45)))
        .padding(.horizontal, 2)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Persistent "ingest failed — do not format" strip. One row per FailedIngestRecord, with a
    /// dismiss button. Survives lane cleanup and app relaunch (the records are persisted).
    private var v3FailureStrip: some View {
        VStack(spacing: 8) {
            ForEach(failedIngestRecords) { rec in
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(v3Amber)
                    VStack(alignment: .leading, spacing: 2) {
                        let name = rec.friendlyName.isEmpty ? rec.cardName : rec.friendlyName
                        Text("\(name) — \(rec.reason == "Cancelled" ? "ingest cancelled" : "ingest error") · DO NOT FORMAT")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(v3Amber).lineLimit(1)
                        Text(rec.filesToCopy > 0
                             ? "\(rec.filesToCopy) files not copied · \(relativeTimeString(from: rec.failedAt))"
                             : "Transfer did not complete · \(relativeTimeString(from: rec.failedAt))")
                            .font(.system(size: 10)).foregroundStyle(v3Amber.opacity(0.75))
                    }
                    Spacer()
                    Button { dismissFailedRecord(id: rec.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(v3Amber.opacity(0.7))
                            .frame(width: 22, height: 22).background(v3Amber.opacity(0.12), in: Circle())
                    }.buttonStyle(.plain).help("Dismiss — only after you've confirmed the footage is safe")
                }
                .padding(12).frame(width: 360)
                .background(v3Amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(v3Amber.opacity(0.45)))
            }
        }
    }

    private func v3Lane(_ id: UUID, _ ing: ActiveIngest) -> some View {
        let (badge, col) = v3Status(ing)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sdcard").font(.system(size: 17)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, height: 40).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    // Editable FOLDER NAME — same pill as the awaiting lane. Editing DURING the
                    // copy is a safety valve: the rename is applied when the card finishes (the
                    // copy can't be safely renamed live), so footage still lands and gets the
                    // corrected name. For a card with no per-card folder, this persists a nickname.
                    let editing = (editingActiveID == id)
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(editing ? v3Cyan : col.opacity(0.85))
                        TextField("Folder name", text: v3ActiveNameBinding(id))
                            .textFieldStyle(.plain).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .frame(minWidth: 60).fixedSize()
                            .focused($editingActiveID, equals: id)
                            .onSubmit { v3CommitActiveRename(id); editingActiveID = nil }   // Enter LOCKS (applies at completion)
                            .onExitCommand { activeIngests[id]?.pendingRename = nil; editingActiveID = nil }  // Esc reverts
                        if editing {
                            Button { v3CommitActiveRename(id); editingActiveID = nil } label: {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(v3Green)
                            }.buttonStyle(.plain).help("Lock in this folder name (applied when the copy finishes)")
                        } else {
                            Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(editing ? v3Cyan.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                        editing ? AnyShapeStyle(v3Cyan) : AnyShapeStyle(.white.opacity(0.18)),
                        style: StrokeStyle(lineWidth: editing ? 1.5 : 1, dash: editing ? [] : [4, 3])))
                    .shadow(color: editing ? v3Cyan.opacity(0.4) : .clear, radius: editing ? 6 : 0)
                    .animation(.easeInOut(duration: 0.12), value: editing)
                    .help("Edit the folder name — applied when this card finishes copying")
                    HStack(spacing: 5) {
                        Text(ing.cameraModel.isEmpty ? "Camera" : ing.cameraModel)
                        Text("·  → \(v3LaneDestName(ing))").foregroundStyle(.white.opacity(0.35))
                    }
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                // Live per-card status capsule (COPYING / FLUSHING / VERIFYING) — the same
                // top-right slot the awaiting card uses for CHOOSE DEST. The % lives on the line.
                Text(badge).font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(col)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(col.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(col.opacity(0.5)))
            }
            v3LaneBottom(ing)
        }
        .padding(14).frame(width: 360)
        .background(.white.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(
            ing.phase == .failed ? v3Red.opacity(0.4) : .white.opacity(0.10)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .anchorPreference(key: V3AnchorKey.self, value: .bounds) { ["lane-\(id)": $0] }
    }

    /// A lane's display name — the saved nickname for this card if any, else its volume name.
    private func v3LaneName(_ ing: ActiveIngest) -> String {
        if let u = ing.volumeUUID, let nick = knownCardNicknames[u], !nick.isEmpty { return nick }
        return ing.cardName.isEmpty ? "Card" : ing.cardName
    }

    /// Two-way binding into an active ingest's editable folder name (by processID). Typing sets
    /// a pendingRename; the get shows the pending name, else the folder label, else the lane name.
    private func v3ActiveNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: {
                guard let ing = self.activeIngests[id] else { return "" }
                if let p = ing.pendingRename { return p }
                return ing.cardLabel.isEmpty ? self.v3LaneName(ing) : ing.cardLabel
            },
            set: { newVal in self.activeIngests[id]?.pendingRename = newVal }
        )
    }

    /// Commit a folder-name edit made on an ACTIVE lane.
    /// - Folder-labeled card still copying → leave pendingRename; the termination handler renames
    ///   the folder safely once the process exits (never mid-copy — that would split footage).
    /// - Folder-labeled card already .done (process exited) → rename the folder now.
    /// - Card with no per-card folder → persist the edit as a nickname so the display sticks.
    private func v3CommitActiveRename(_ id: UUID) {
        guard let ing = activeIngests[id] else { return }
        let newName = (ing.pendingRename ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { activeIngests[id]?.pendingRename = nil; return }
        if !ing.cardLabel.isEmpty {
            if ing.phase == .done {
                let applied = applyPendingFolderRename(destPath: ing.destPath,
                                                       oldLabel: ing.cardLabel, newLabel: newName)
                activeIngests[id]?.cardLabel = applied
                activeIngests[id]?.friendlyName = applied
                activeIngests[id]?.pendingRename = nil
            }
            // else still copying → keep pendingRename; termination handler applies it.
        } else {
            // No folder to rename — persist as a nickname so the display sticks.
            activeIngests[id]?.friendlyName = newName
            if let uuid = ing.volumeUUID { knownCardNicknames[uuid] = newName; persistCardNicknames() }
            activeIngests[id]?.pendingRename = nil
        }
    }


    /// Two-way binding into an awaiting card's editable per-card folder name (by id).
    private func v3AwaitingNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.awaitingCards.first(where: { $0.id == id })?.customName ?? "" },
            set: { newVal in
                if let idx = self.awaitingCards.firstIndex(where: { $0.id == id }) {
                    self.awaitingCards[idx].customName = newVal
                    self.awaitingCards[idx].userEdited = true   // protect this edit from re-scan/prefill
                }
            }
        )
    }

    /// Persist an awaiting card's name — trims it and (for UUID-bearing cards) saves it as the
    /// card's nickname so a re-insert prefills the name the operator last confirmed. Does NOT
    /// start the transfer and does NOT change focus (safe to call on click-away).
    private func persistAwaitingName(_ id: UUID) {
        guard let idx = awaitingCards.firstIndex(where: { $0.id == id }) else { return }
        let name = awaitingCards[idx].customName.trimmingCharacters(in: .whitespacesAndNewlines)
        awaitingCards[idx].customName = name
        if let uuid = awaitingCards[idx].card.volumeUUID {
            if name.isEmpty { knownCardNicknames.removeValue(forKey: uuid) }
            else            { knownCardNicknames[uuid] = name }
            persistCardNicknames()
        }
    }

    /// Confirm/lock the name (green check or Enter): persist it and drop focus. Never starts a copy.
    private func commitAwaitingName(_ id: UUID) {
        persistAwaitingName(id)
        if editingAwaitingID == id { editingAwaitingID = nil }
    }

    /// Live preview of the folder the footage will land in, shown while editing the name.
    private func v3FolderPreview(_ aw: AwaitingCard) -> String {
        let dest = v3AwaitingDestName(aw)
        let name = aw.customName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Lands in  \(dest)/…/  (no name folder)" : "Lands in  \(dest)/…/\(name)/"
    }

    /// The destination name an awaiting card would land on (its chosen drive, or the default).
    private func v3AwaitingDestName(_ aw: AwaitingCard) -> String {
        if let id = aw.destinationID, let d = destinations.first(where: { $0.id == id }) { return d.name }
        return defaultDestination?.name ?? "default"
    }

    /// Cycle an awaiting card through the available destinations without starting it.
    private func v3CycleAwaitingDest(_ awaitingID: UUID) {
        guard !destinations.isEmpty,
              let idx = awaitingCards.firstIndex(where: { $0.id == awaitingID }) else { return }
        let cur = awaitingCards[idx].destinationID ?? defaultDestination?.id
        let di = destinations.firstIndex { $0.id == cur } ?? -1
        awaitingCards[idx].destinationID = destinations[(di + 1) % destinations.count].id
    }

    /// A card detected with Auto-Ingest OFF — parked "waiting to route". Faithful port of the
    /// demo's awaiting lane: route label + CHOOSE-DEST cycle + "Drag node · or Start", with the
    /// amber draggable node on the trailing edge that links + starts on drop.
    private func v3AwaitingLane(_ aw: AwaitingCard) -> some View {
        let editing = (editingAwaitingID == aw.id)
        return VStack(alignment: .leading, spacing: 8) {
            // TOP ROW — icon · editable name pill · CHOOSE DEST, all inline. This row never
            // shifts (the edit-time path preview lives BELOW it, in the gap).
            HStack(spacing: 10) {
                Image(systemName: "sdcard").font(.system(size: 17)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, height: 40).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                // Editable per-card FOLDER NAME (--cardlabel). Idle = dashed amber pill (reads as
                // "editable"); focused = solid cyan + fill + glow (reads as "typing now") with a
                // green ✓ to lock it in. Enter/✓/click-away COMMIT the name (persist, no copy);
                // Start is the only thing that begins the transfer.
                let hovered = (v3HoveredNameID == aw.id)
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(editing ? v3Cyan : v3Amber.opacity(0.85))
                    TextField("Folder name", text: v3AwaitingNameBinding(aw.id))
                        .textFieldStyle(.plain).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(minWidth: 70).fixedSize()
                        .focused($editingAwaitingID, equals: aw.id)
                        .onSubmit { commitAwaitingName(aw.id) }        // Enter LOCKS the name (never starts)
                        .onExitCommand {                               // Esc reverts to the pre-edit value
                            if let idx = awaitingCards.firstIndex(where: { $0.id == aw.id }) {
                                awaitingCards[idx].customName = v3PreEditName
                                awaitingCards[idx].userEdited = false
                            }
                            editingAwaitingID = nil
                        }
                    if editing {
                        Button { commitAwaitingName(aw.id) } label: {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(v3Green)
                        }.buttonStyle(.plain).help("Lock in this folder name")
                    } else {
                        Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(editing ? v3Cyan.opacity(0.10) : (hovered ? v3Cyan.opacity(0.05) : Color.clear), in: RoundedRectangle(cornerRadius: 9))
                // editing = solid cyan glow; hover = a softer cyan glow signalling "click to edit";
                // idle = the dashed amber outline.
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(
                    editing ? AnyShapeStyle(v3Cyan)
                            : (hovered ? AnyShapeStyle(v3Cyan.opacity(0.6)) : AnyShapeStyle(v3Amber.opacity(0.5))),
                    style: StrokeStyle(lineWidth: (editing || hovered) ? 1.5 : 1, dash: (editing || hovered) ? [] : [4, 3])))
                .shadow(color: editing ? v3Cyan.opacity(0.4) : (hovered ? v3Cyan.opacity(0.3) : .clear), radius: (editing || hovered) ? 6 : 0)
                .animation(.easeInOut(duration: 0.14), value: editing)
                .animation(.easeInOut(duration: 0.14), value: hovered)
                .onHover { v3HoveredNameID = $0 ? aw.id : (v3HoveredNameID == aw.id ? nil : v3HoveredNameID) }
                Spacer()
                Button { v3CycleAwaitingDest(aw.id) } label: {
                    Text(aw.destinationID == nil ? "CHOOSE DEST" : "→ \(v3AwaitingDestName(aw))")
                        .font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(v3Amber)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(v3Amber.opacity(0.55)))
                }.buttonStyle(.plain)
                .help("Tap to cycle drives, or drag the node onto a drive")
            }
            // Live path preview — sits in the gap UNDER the top row WHILE editing, so the
            // icon/name/CHOOSE-DEST row never moves. Shows exactly where footage will land.
            if editing {
                Text(v3FolderPreview(aw)).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(v3Cyan.opacity(0.85)).lineLimit(1).truncationMode(.head)
            }
            HStack(spacing: 7) {
                Text("Name the folder, then Start")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(v3Amber.opacity(0.9))
                Spacer()
                Button {
                    // Remember the typed name for next time even without an explicit ✓/Enter —
                    // must run while the card is still in awaitingCards (startAwaiting removes it).
                    persistAwaitingName(aw.id)
                    editingAwaitingID = nil
                    // A fake card (spawned only via the secret DEV unlock) has no real footage, so
                    // run a SIMULATED transfer end-to-end instead of the shell (which would just
                    // report "no footage on this card"). Real cards always start a real ingest.
                    if aw.card.path.hasPrefix(Self.v3FakePrefix) { v3DevSimulateIngest(aw) }
                    else { startAwaiting(aw.id) }
                } label: {
                    Text("Start").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 18).padding(.vertical, 6)
                        .background(v3Green, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }.buttonStyle(.plain).v3Hover(scale: 1.06, glow: v3Green).help("Start now using \(v3AwaitingDestName(aw))")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12).frame(width: 360)
        .v3GlowCard(tint: v3Amber, radius: 18, fill: 0.04, border: 0.55, glow: 0.28, glowRadius: 22)
        .overlay(alignment: .trailing) { v3RouteDot(aw) }
        .anchorPreference(key: V3AnchorKey.self, value: .bounds) { ["lane-\(aw.id)": $0] }
    }

    /// The draggable amber NODE on a waiting card. Drag it onto a destination tile to LINK
    /// the card to that drive AND start it (routeAwaiting). Ports the demo's routeDot gesture.
    private func v3RouteDot(_ aw: AwaitingCard) -> some View {
        Circle().fill(v3Amber).frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 2))
            .shadow(color: v3Amber.opacity(0.8), radius: 8)
            .offset(x: 9)
            // Grab area is larger than the 18pt dot so the node isn't finicky to pick up.
            .contentShape(Circle().inset(by: -12))
            .help("Drag onto a destination to route this card there (then press Start)")
            .gesture(
                DragGesture(coordinateSpace: .named("stage"))
                    .onChanged { v in
                        dragLine = DragLine(from: v.startLocation, to: v.location)
                        dragOverDest = destFrames.first { $0.value.contains(v.location) }?.key
                    }
                    .onEnded { v in
                        if let did = destFrames.first(where: { $0.value.contains(v.location) })?.key {
                            routeAwaiting(aw.id, to: did)
                        }
                        dragLine = nil; dragOverDest = nil
                    }
            )
    }

    /// "N cards safe to pull" panel — a tappable green review card (tap to reveal the done cards,
    /// each with its own Pull button) + a separate footage-safe "eject All" square. The design's
    /// confidence-builder: a finished card lands here instead of just vanishing.
    private var v3DonePile: some View {
        HStack(spacing: 10) {
            // (A) The whole panel is ONE tappable button → toggle the review disclosure.
            Button {
                withAnimation(v3Anim(.easeInOut(duration: 0.18))) { v3DoneExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Text("\(v3DoneLanes.count)")
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 46, height: 46)
                        .background(v3Green.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(v3DoneLanes.count) card\(v3DoneLanes.count == 1 ? "" : "s") safe to pull")
                            .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        Text("Tap to review · or Pull all")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 8)
                    Image(systemName: v3DoneExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(v3Green)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .v3GlowCard(tint: v3Green, radius: 16, fill: 0.09, border: 0.3, glow: 0.20, glowRadius: 18)

            // (B) Separate footage-safe "eject ALL" (posts .menuEjectCard → guarded on !isBusy,
            //     loops every mounted card). Outside the tappable review panel.
            Button { v3Post(.menuEjectCard) } label: {
                VStack(spacing: 3) {
                    Image(systemName: "eject.fill").font(.system(size: 16)).foregroundStyle(v3Green)
                    Text("All").font(.system(size: 11, weight: .bold)).foregroundStyle(v3Green)
                }
                .frame(width: 64, height: 78)
                .background(v3Green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(v3Green.opacity(0.4)))
            }.buttonStyle(.plain).v3Hover(scale: 1.05, glow: v3Green)
            .help("Eject all cards that are safe to pull")
        }
        .frame(width: 360)
    }

    @ViewBuilder private func v3LaneBottom(_ ing: ActiveIngest) -> some View {
        switch ing.phase {
        case .copying, .scanning, .building, .idle:
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.10)).frame(height: 4)
                        Capsule().fill(v3Brand).frame(width: g.size.width * CGFloat(v3LanePct(ing) / 100), height: 4)
                    }
                }.frame(height: 4)
                // Granular per-card progress: which file of how many + live speed.
                Text(ing.newFiles > 0
                     ? "Transferring \(min(ing.completedFiles + 1, ing.newFiles)) of \(ing.newFiles)  ·  \(String(format: "%.0f", max(0, ing.liveMBps))) MB/s"
                     : String(format: "%.0f MB/s", max(0, ing.liveMBps)))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            }
        case .finalizing:
            HStack(spacing: 7) { ProgressView().controlSize(.small)
                Text("Flushing to disk — keep card inserted").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)) }
        case .verifying:
            HStack(spacing: 7) { ProgressView().controlSize(.small).tint(v3Green)
                Text("Verifying checksums…").font(.system(size: 11)).foregroundStyle(v3Green.opacity(0.9)) }
        case .done:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(v3Green)
                    Text("SAFE TO PULL").font(.system(size: 12, weight: .bold)).foregroundStyle(v3Green)
                    Spacer()
                    Button { v3Post(.menuEjectCard) } label: {
                        HStack(spacing: 4) { Image(systemName: "eject.fill").font(.system(size: 9)); Text("Pull").font(.system(size: 11, weight: .semibold)) }
                            .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.white.opacity(0.06), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                    }.buttonStyle(.plain)
                }
                if ing.skipWrongMode > 0 { v3MixedModeHint(ing.skipWrongMode, runMode: ing.runMode) }
            }
        case .failed:
            Text("Transfer failed — card kept mounted, re-insert to retry")
                .font(.system(size: 11)).foregroundStyle(v3Red)
        }
    }

    /// Mixed-card hint — shown only when the engine actually skipped wrong-mode files on a
    /// card (skipWrongMode > 0). Mode is global, so a card holding both stills + video copies
    /// only the current mode's files; the rest are SKIPPED (never deleted). Tells the operator
    /// how to grab them: switch mode (⌘1/⌘2) and re-insert — the card re-surfaces to re-run.
    private func v3MixedModeHint(_ n: Int, runMode: String) -> some View {
        let otherKind = runMode == "photo" ? "video" : "photo"
        return HStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 10)).foregroundStyle(v3Amber)
            Text("\(n) \(otherKind) file\(n == 1 ? "" : "s") skipped — switch to \(otherKind.capitalized) mode & re-insert to copy them")
                .font(.system(size: 10)).foregroundStyle(v3Amber.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(v3Amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Ring (real aggregate)
    private var v3Ring: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke(.white.opacity(0.06), lineWidth: 16)
                Circle().trim(from: 0, to: v3AggregatePct / 100)
                    .stroke(v3RingStroke, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90)).animation(.easeInOut(duration: 0.2), value: v3AggregatePct)
                v3RingCenter
            }
            .frame(width: 320, height: 320)
            .anchorPreference(key: V3AnchorKey.self, value: .bounds) { ["ring": $0] }
            // The ONE auto-ingest toggle (used to also live in the top bar + footer). The redundant
            // "N waiting — drag…" strip is gone: v3RingCenter's waiting state already says it.
            v3AutoIngestToggle
            if v3DestRoot.isEmpty && v3AnyActive {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text("No destination — choose a folder to start").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(v3Amber).padding(.horizontal, 16).padding(.vertical, 10)
                .background(v3Amber.opacity(0.12), in: Capsule()).overlay(Capsule().strokeBorder(v3Amber.opacity(0.4)))
            }
            Spacer(minLength: 0)
        }
    }

    /// The single auto-ingest toggle — the one and only place auto-ingest is shown/toggled (it used to
    /// also appear in the top-right pill and the footer). Green = armed, amber = off. Tappable anytime.
    private var v3AutoIngestToggle: some View {
        HStack(spacing: 8) {
            Circle().fill(autoIngest ? v3Green : v3Amber).frame(width: 8, height: 8)
            Text(runningCount > 0 ? "Engine running · Auto-Ingest \(autoIngest ? "On" : "Off")"
                                  : "Auto-Ingest \(autoIngest ? "On" : "Off")")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Image(systemName: autoIngest ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 11)).foregroundStyle(autoIngest ? v3Green : v3Amber.opacity(0.85))
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background((autoIngest ? v3Green : v3Amber).opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder((autoIngest ? v3Green : v3Amber).opacity(0.45)))
        .contentShape(Capsule())
        .onTapGesture { autoIngest.toggle() }
        .v3Hover(scale: 1.04)
        .help("Toggle Auto-Ingest — when On, a plugged card auto-routes to the default and starts")
    }
    private var v3RingStroke: AnyShapeStyle {
        if v3HasFailures { return AnyShapeStyle(v3Amber) }   // persistent — survives lane cleanup
        if v3WaitingToRoute { return AnyShapeStyle(v3Amber) }
        if v3AllDone { return AnyShapeStyle(v3Green) }
        return AnyShapeStyle(v3Brand)
    }
    @ViewBuilder private var v3RingCenter: some View {
        // Failure is checked FIRST and keyed off the PERSISTENT record, so a failed card never
        // gets masked by "Ready for cards" / "All safe to pull" once its lane is cleaned up.
        if v3HasFailures {
            VStack(spacing: 6) {
                Text("\(v3AttentionCount)").font(.system(size: 40, weight: .bold)).foregroundStyle(v3Amber)
                Text("need\(v3AttentionCount == 1 ? "s" : "") attention").font(.system(size: 13, weight: .semibold)).foregroundStyle(v3Amber)
                Text("Do not format the card(s)").font(.system(size: 11)).foregroundStyle(v3Amber.opacity(0.8))
            }
        } else if v3WaitingToRoute {
            VStack(spacing: 6) {
                Text("\(awaitingCards.count)").font(.system(size: 48, weight: .bold)).foregroundStyle(v3Amber)
                Text("card\(awaitingCards.count == 1 ? "" : "s") waiting to route")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                Text("Drag each to a destination to start").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }.frame(width: 220)
        } else if !v3AnyActive {
            VStack(spacing: 6) {
                Text("Ready for cards").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                // Auto-ingest state is shown by the toggle right below the ring — no echo here.
                Text("Plug a card to begin").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
        } else if v3AllDone {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle").font(.system(size: 34)).foregroundStyle(v3Green)
                Text("All safe to pull").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                Text("\(v3DoneCount) card\(v3DoneCount == 1 ? "" : "s") ready").font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                // Open in Finder lives INSIDE the ring, and ONLY once a transfer is done (Xavier's call).
                Button { v3Post(.menuOpenDestination) } label: {
                    HStack(spacing: 6) { Image(systemName: "folder"); Text("Open in Finder") }
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(v3Green)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(v3Green.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(v3Green.opacity(0.35)))
                }.buttonStyle(.plain).padding(.top, 4)
            }
        } else {
            VStack(spacing: 6) {
                Text("\(Int(v3AggregatePct))%").font(.system(size: 56, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("\(activeIngests.count) card\(activeIngests.count == 1 ? "" : "s") · engine running")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                Text("\(v3SpeedText(v3CombinedMBps)) combined")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                if !v3Summary.isEmpty {
                    Text(v3Summary).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).multilineTextAlignment(.center)
                }
            }.frame(width: 220)
        }
    }
    private var v3Summary: String {
        var p: [String] = []
        if v3CopyingCount > 0 { p.append("\(v3CopyingCount) copying") }
        if v3FinalizingCount > 0 { p.append("\(v3FinalizingCount) finalizing") }
        if v3DoneCount > 0 { p.append("\(v3DoneCount) ready") }
        return p.joined(separator: " · ")
    }

    // MARK: Destinations — golden DEFAULT box + a tile per other destination (N-way routing)
    private var v3Destinations: some View {
        VStack(alignment: .trailing, spacing: 14) {
            // Balanced with the trailing Spacer → centers the destinations group on the ring.
            Spacer(minLength: 0)
            HStack {
                Text("DESTINATIONS").font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.4))
                Spacer()
            }
            .frame(width: 348)
            if let def = defaultDestination {
                v3DefaultDestBox(def)
                ForEach(destinations.filter { $0.id != def.id }) { d in v3DestTile(d) }
            } else {
                v3LegacyDefaultDestBox   // no Destination list yet — legacy folder picker box
            }
            v3AddDestinationMenu
            Spacer(minLength: 0)
            Color.clear.frame(height: 170)   // match v3Sources top-bias so both columns align with the ring
        }
        // Reset net: a make-default drag resets its transform only in .onEnded, but that may never
        // arrive if a transfer starts mid-drag (the gesture is runningCount-gated off) or the list
        // reorders. Snap any lifted tile back so it can't strand at zIndex 100.
        .onChange(of: runningCount) { _, now in if now > 0 { v3ResetDestDrag() } }
        .onChange(of: destinations.count) { _, _ in v3ResetDestDrag() }
    }

    /// Clear the make-default drag transform (see the reset net on v3Destinations).
    private func v3ResetDestDrag() {
        guard v3DraggingDestID != nil else { return }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.97)) {
            v3DragOffset = .zero; v3DragRotation = 0
            v3DraggingDestID = nil
            v3ReorderFrom = nil; v3ReorderTo = nil
        }
        dragOverDest = nil
    }

    /// The golden DEFAULT box, bound to a real `Destination`. Doubles as a drop target:
    /// drop a tile's handle here to make it the default; drop an awaiting card's node to
    /// route+start it to the default.
    private func v3DefaultDestBox(_ d: Destination) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(v3Amber)
                    Text("DEFAULT DESTINATION").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(v3Amber)
                }
                Spacer()
                Text("Auto-routes the first card").font(.system(size: 10)).foregroundStyle(v3Amber.opacity(0.7))
            }
            v3DestTileBody(d, isDefault: true)
        }
        .padding(12).frame(width: 348)
        .background((dragOverDest == d.id ? v3Cyan : v3Amber).opacity(dragOverDest == d.id ? 0.10 : 0.04),
                    in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(
            dragOverDest == d.id ? v3Cyan.opacity(0.7) : v3Amber.opacity(0.5),
            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .contentShape(Rectangle())
        .onTapGesture { if runningCount == 0 && !d.isCustomFolder { v3OpenEditDest(d) } }
        .anchorPreference(key: V3AnchorKey.self, value: .bounds) { ["dest-default": $0] }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { destFrames[d.id] = g.frame(in: .named("stage")) }
                .onChange(of: g.frame(in: .named("stage"))) { _, f in destFrames[d.id] = f }
        })
        // Golden POP when a tile is dropped in to become the default (v3DestDragGesture sets v3DefaultPop).
        .shadow(color: v3Amber.opacity(v3DefaultPop ? 0.9 : 0), radius: v3DefaultPop ? 28 : 0)
        .scaleEffect(v3DefaultPop ? 1.05 : 1.0)
        .animation(.spring(response: 0.26, dampingFraction: 0.45), value: v3DefaultPop)
        // Hover bounce — applied after the anchor/destFrames reads so geometry stays un-scaled.
        .scaleEffect(v3HoveredDestID == d.id ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: v3HoveredDestID)
        .onHover { hovering in v3HoveredDestID = hovering ? d.id : (v3HoveredDestID == d.id ? nil : v3HoveredDestID) }
    }

    /// A non-default destination tile (drop target for routing; drag handle to swap default).
    private func v3DestTile(_ d: Destination) -> some View {
        v3DestTileBody(d, isDefault: false)
            .padding(14).frame(width: 324, alignment: .leading)
            .background(.white.opacity(dragOverDest == d.id ? 0.09 : 0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
                dragOverDest == d.id ? v3Cyan.opacity(0.7) : .white.opacity(0.10)))
            .contentShape(Rectangle())
            .onTapGesture { if runningCount == 0 && !d.isCustomFolder { v3OpenEditDest(d) } }
            .anchorPreference(key: V3AnchorKey.self, value: .bounds) { ["dest-\(d.id)": $0] }
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { destFrames[d.id] = g.frame(in: .named("stage")) }
                    .onChange(of: g.frame(in: .named("stage"))) { _, f in destFrames[d.id] = f }
            })
            // Hover bounce (subtle) signals the tile is clickable — suppressed while ANY tile is being
            // dragged (so tiles sliding under the cursor during a reorder don't flicker their bounce).
            // Applied AFTER the anchor/destFrames reads above so routing-line geometry + drop hit-testing
            // use the un-scaled/un-rotated resting frame.
            .scaleEffect(v3HoveredDestID == d.id && v3DraggingDestID == nil ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: v3HoveredDestID)
            .onHover { hovering in v3HoveredDestID = hovering ? d.id : (v3HoveredDestID == d.id ? nil : v3HoveredDestID) }
            // Dynamic drag → drop on the default box = make default; drag among tiles = reorder (see
            // v3DestDragGesture). The transforms are applied AFTER the anchor/destFrames reads above.
            // The lift + tilt animate on drag start/end + velocity; the offset below does NOT (it must
            // track the cursor 1:1).
            .scaleEffect(v3DraggingDestID == d.id ? 1.06 : 1.0)
            .rotationEffect(.degrees(v3DraggingDestID == d.id ? v3DragRotation : 0))
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: v3DraggingDestID)
            .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.8), value: v3DragRotation)
            // A SIBLING slides to make room as the dragged tile crosses it. The gap is animated by the
            // explicit withAnimation in the gesture's onChanged (and reset in onEnded) — NOT by an
            // .animation(value:) here, so the release spring is the sole driver on drop (no fighting).
            .offset(y: v3DraggingDestID != nil && v3DraggingDestID != d.id ? v3ReorderShift(for: d) : 0)
            // The DRAGGED tile follows the cursor EXACTLY — plain translation, applied last and with NO
            // per-frame animation, so it never trails or springs behind the mouse.
            .offset(v3DraggingDestID == d.id ? v3DragOffset : .zero)
            // Stay on top through the drag AND the ~0.35s release glide (zIndex isn't animatable, so a
            // straight drop would let the tile duck behind a neighbour mid-glide).
            .zIndex(v3DraggingDestID == d.id || v3DragSettling == d.id ? 100 : 0)
            .if(runningCount == 0) { $0.gesture(v3DestDragGesture(d)) }
            // Swipe-away when removed (#7): shrink + slide out; siblings close up (withAnimation on remove).
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.9)),
                removal: .scale(scale: 0.85).combined(with: .opacity).combined(with: .move(edge: .trailing))))
    }

    /// Custom drag for a destination tile — TWO modes chosen by where the cursor is:
    ///  • over the DEFAULT box  → make-default (gold pop on release).
    ///  • among the tile column → REORDER. The dragged tile follows the cursor 1:1 via plain
    ///    translation (the array is NOT mutated during the drag, so its resting frame is stable and it
    ///    never jumps or trails). The *other* tiles slide to make room via `v3ReorderShift`. The array
    ///    is reordered ONCE, on release, inside a single spring. `minimumDistance: 8` lets a plain
    ///    click still fall through to the edit tap.
    private func v3DestDragGesture(_ d: Destination) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("stage"))
            .onChanged { v in
                if v3DraggingDestID != d.id {                    // first frame — capture start state
                    v3DraggingDestID = d.id
                    v3ReorderFrom = v3SiblingIndex(d.id)
                    v3ReorderTo = v3ReorderFrom
                    v3DragRowPitch = (destFrames[d.id]?.height ?? 90) + 14
                }
                v3DragOffset = v.translation                    // 1:1 cursor tracking (no animation)
                v3DragRotation = max(-14, min(14, v.velocity.width * 0.012))

                // The make-room gap is animated ONLY here (explicit withAnimation), so on release the
                // single release-spring drives everything — no second .animation(value:) fighting it.
                let newTo: Int?
                if let defID = defaultDestination?.id, let f = destFrames[defID], f.contains(v.location) {
                    dragOverDest = defID                        // make-default mode (highlight golden box)
                    newTo = v3ReorderFrom                       // no make-room gap while over the default box
                } else {
                    dragOverDest = nil
                    newTo = v3ReorderTargetIndex(dragged: d.id, translationY: v.translation.height)
                }
                if newTo != v3ReorderTo {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.96)) { v3ReorderTo = newTo }
                }
            }
            .onEnded { v in
                let overDefault = (defaultDestination?.id).flatMap { destFrames[$0] }?.contains(v.location) ?? false
                var reordered = false
                if overDefault, defaultDestination?.id != d.id, v3MakeDefault(d.id) {
                    AudioEngine.shared.modeSwitch()
                    if !reduceMotion {                       // skip the decorative pop burst under Reduce Motion
                        v3DefaultPop = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            withAnimation(.easeOut(duration: 0.25)) { v3DefaultPop = false }
                        }
                    }
                } else if let from = v3ReorderFrom, let to = v3ReorderTo, to != from {
                    reordered = true
                }
                // Keep this tile on top through the (now slower) glide (zIndex isn't animatable).
                v3DragSettling = d.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                    if v3DragSettling == d.id { v3DragSettling = nil }
                }
                // Commit the reorder (if any) AND settle the tile in ONE spring: the array move + the
                // offset/gap reset animate together, so the tile glides from the cursor into its slot.
                // Slow + near-critically-damped = a gentle, gradual ease-in with no bounce or skyrocket.
                withAnimation(.spring(response: 0.6, dampingFraction: 0.97)) {
                    if reordered, let from = v3ReorderFrom, let to = v3ReorderTo {
                        v3CommitReorder(dragged: d.id, from: from, to: to)
                    }
                    v3DraggingDestID = nil
                    v3DragOffset = .zero
                    v3DragRotation = 0
                    v3ReorderFrom = nil
                    v3ReorderTo = nil
                }
                if reordered { saveDestinations() }
                dragOverDest = nil
            }
    }

    /// The dragged tile's target index among its siblings, from how far its center has moved past the
    /// resting midpoints of the others. Reads only STABLE resting frames (the array isn't mutated
    /// during the drag), so it can't jitter against animating rows.
    private func v3ReorderTargetIndex(dragged id: UUID, translationY: CGFloat) -> Int? {
        guard let defID = defaultDestination?.id, let from = v3ReorderFrom else { return v3ReorderFrom }
        let sibs = destinations.filter { $0.id != defID }
        let centerY = (destFrames[id]?.midY ?? 0) + translationY
        var to = from
        for (i, s) in sibs.enumerated() where s.id != id {
            guard let f = destFrames[s.id] else { continue }
            if i < from && centerY < f.midY { to = min(to, i) }
            if i > from && centerY > f.midY { to = max(to, i) }
        }
        return to
    }

    /// The make-room vertical shift for a NON-dragged sibling while a reorder is previewing: siblings
    /// between the dragged tile's origin and its current target slide by one row-pitch to open the gap.
    private func v3ReorderShift(for d: Destination) -> CGFloat {
        guard let from = v3ReorderFrom, let to = v3ReorderTo, to != from,
              let idx = v3SiblingIndex(d.id) else { return 0 }
        if to > from { return (idx > from && idx <= to) ? -v3DragRowPitch : 0 }   // dragged going down
        return (idx >= to && idx < from) ? v3DragRowPitch : 0                       // dragged going up
    }

    /// Index of a destination among the NON-default tiles (the display order), or nil for the default.
    private func v3SiblingIndex(_ id: UUID) -> Int? {
        let defID = defaultDestination?.id
        return destinations.filter { $0.id != defID }.firstIndex { $0.id == id }
    }

    /// Move a sibling from → to in the display order and persist. Order is display-only (default +
    /// routing resolve by ID), so this can't perturb routing. Default kept at array index 0.
    private func v3CommitReorder(dragged id: UUID, from: Int, to: Int) {
        guard let defID = defaultDestination?.id else { return }
        var sibs = destinations.filter { $0.id != defID }
        guard from >= 0, from < sibs.count else { return }
        let item = sibs.remove(at: from)
        sibs.insert(item, at: min(max(0, to), sibs.count))
        let def = destinations.first { $0.id == defID }
        destinations = (def.map { [$0] } ?? []) + sibs
    }

    /// Shared tile contents (icon, name, free space, role/route line, remove control).
    private func v3DestTileBody(_ d: Destination, isDefault: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: d.isCustomFolder ? "folder.fill" : "externaldrive.fill")
                .font(.system(size: 18)).foregroundStyle(v3Purple)
                .frame(width: 38, height: 38).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(d.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    if isDefault {
                        Text("DEFAULT").font(.system(size: 9, weight: .bold)).foregroundStyle(v3Amber)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(v3Amber.opacity(0.14), in: Capsule())
                    }
                }
                Text(v3DestFree(d)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                // Project / subfolder — the disambiguator when the same drive is used more than once.
                Text(v3DestPathLabel(d)).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(v3Cyan.opacity(0.7)).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            // Edit affordance — the whole tile is clickable to edit its project/subfolder (SSD dests only).
            if runningCount == 0 && !d.isCustomFolder {
                Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(.white.opacity(0.3))
                    .help("Click the tile to edit its project & subfolder")
            }
            if runningCount > 0 && isDefault {
                Text(v3SpeedText(v3CombinedMBps)).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(v3Cyan)
            }
            if !isDefault {
                Image(systemName: runningCount == 0 ? "line.3.horizontal" : "lock.fill")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.25))
                    .help(runningCount == 0 ? "Drag onto the default box to make this the default"
                                            : "Locked while a transfer is running")
                if destinations.count > 1 {
                    // Hover → red X; click → spring the tile out (the .transition on v3DestTile).
                    V3TileRemoveButton {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { v3RemoveDestination(d.id) }
                    }
                }
            }
        }
    }


    /// "Add destination" — opens the design sheet (SSD drive or custom folder + split/mirror).
    private var v3AddDestinationMenu: some View {
        Button { v3OpenAddDest(ssd: true) } label: {
            HStack(spacing: 6) { Image(systemName: "plus"); Text("Add destination") }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(v3AddDestHovered ? v3Cyan : .white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(width: 324, alignment: .center)
                .background(.white.opacity(v3AddDestHovered ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(v3AddDestHovered ? v3Cyan.opacity(0.7) : .white.opacity(0.12)))
                // Blue glow on hover signals a clickable button.
                .shadow(color: v3Cyan.opacity(v3AddDestHovered ? 0.5 : 0), radius: 12)
                .scaleEffect(v3AddDestHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: v3AddDestHovered)
        .onHover { v3AddDestHovered = $0 }
    }

    /// Legacy fallback box — shown only when NO Destination list is configured yet (untouched
    /// pre-Phase-2 user). Opens the original folder picker; the migration seeds the list on first launch.
    private var v3LegacyDefaultDestBox: some View {
        let unset = v3DestRoot.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(v3Amber)
                    Text("DEFAULT DESTINATION").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(v3Amber)
                }
                Spacer()
                Text(unset ? "Choose a folder to start" : "Auto-routes the first card")
                    .font(.system(size: 10, weight: unset ? .bold : .regular)).foregroundStyle(v3Amber.opacity(unset ? 1 : 0.7))
            }
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill").font(.system(size: 18)).foregroundStyle(v3Purple)
                    .frame(width: 38, height: 38).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(unset ? "No destination" : v3DestDriveName)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(unset ? v3Amber : .white)
                    Text(unset ? "Open the picker to choose a drive & folder" : v3FreeSpace(v3DestDrivePath))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }
            Button { v3ChooseDestination() } label: {
                HStack(spacing: 6) { Image(systemName: "folder.badge.gearshape"); Text(unset ? "Choose a folder…" : "Change destination") }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(unset ? v3Amber : .white.opacity(0.75))
            }.buttonStyle(.plain)
        }
        .padding(14).frame(width: 348, alignment: .leading)
        .background((unset ? v3Amber : Color.white).opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(v3Amber.opacity(unset ? 0.55 : 0.4),
                 style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .anchorPreference(key: V3AnchorKey.self, value: .bounds) { ["dest-default": $0] }
    }

    // MARK: Bottom bar (real toggles)
    private var v3BottomStatus: String {
        // No auto-ingest mention here — it lives only in the center-console toggle now. The default
        // destination NAME is shown in the destinations column, so it's not repeated here either.
        let lead = v3Summary.isEmpty ? "Ready" : v3Summary
        let speed = runningCount > 0 ? "  ·  \(v3SpeedText(v3CombinedMBps)) combined" : ""
        if defaultDestination != nil {
            return "\(lead)\(speed)   ·   \(destinations.count) destination\(destinations.count == 1 ? "" : "s")"
        }
        let dest = v3DestRoot.isEmpty ? "no destination" : "1 destination"
        return "\(lead)\(speed)  ·  \(dest)"
    }
    private var v3BottomBar: some View {
        HStack(spacing: 10) {
            Text(v3BottomStatus).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            Spacer()
            if runningCount > 0 {
                v3Chip("Stop", "stop.circle", v3Red) { v3Post(.menuStopTransfer) }
            }
            v3Chip("New project folder", "folder.badge.plus", v3Purple) { v3OpenNewProject() }
            // Date filter — a custom liquid-glass dropdown (native Menu can't be restyled).
            v3DateDropdown
            // Verify moved fully into Settings (Xavier's call); Add-folder removed as redundant with the
            // destinations column's "Add destination". Bottom bar keeps only New project / dates / eject.
            v3Chip("Auto-eject  \(autoEject ? "On" : "Off")", "eject", autoEject ? v3Green : .white.opacity(0.6)) { autoEject.toggle() }
        }
    }
    /// Custom liquid-glass date-filter dropdown (the native macOS Menu can't be restyled). Opens a
    /// rounded dark card via `.popover`, dismisses on selection or outside-click.
    private var v3DateDropdown: some View {
        Button { v3ShowDateMenu = true } label: {
            v3ChipLabel(v3DateFilterText, "calendar", dateFilterMode == "all" ? .white.opacity(0.6) : v3Cyan)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).v3Hover()
        .popover(isPresented: $v3ShowDateMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                v3DateMenuRow("Today", "today")
                v3DateMenuRow("Yesterday", "yesterday")
                v3DateMenuRow("All dates", "all")
                Divider().overlay(.white.opacity(0.12)).padding(.vertical, 3)
                Button { v3ShowDateMenu = false; v3OpenDateRange() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.clock").font(.system(size: 12)).foregroundStyle(v3Cyan)
                        Text("Custom range…").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                }.buttonStyle(.plain).v3Hover(scale: 1.0, glow: v3Cyan)
            }
            .padding(6).frame(width: 210)
            .background(Color(hex: "#151024"))
            .preferredColorScheme(.dark)
        }
    }

    /// One row of the custom date dropdown — highlights the active mode, closes on pick.
    private func v3DateMenuRow(_ label: String, _ mode: String) -> some View {
        let active = dateFilterMode == mode
        return Button {
            dateFilterMode = mode; v3ShowDateMenu = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12)).foregroundStyle(active ? v3Cyan : .white.opacity(0.25))
                Text(label).font(.system(size: 13, weight: active ? .semibold : .regular)).foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(active ? v3Cyan.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).v3Hover(scale: 1.0)
    }

    private var v3DateFilterText: String {
        switch dateFilterMode {
        case "today": return "Today only"
        case "yesterday": return "Yesterday"
        case "custom":
            let from = v3PrettyYMD(dateFilterFrom)
            if dateFilterSubMode == "range" && !dateFilterTo.isEmpty {
                return "\(from) – \(v3PrettyYMD(dateFilterTo))"
            }
            return from.isEmpty ? "Custom dates" : from
        default: return "All dates"
        }
    }

    /// Convert a stored YYYYMMDD key to a short human label (e.g. "Jun 30").
    private func v3PrettyYMD(_ ymd: String) -> String {
        let inFmt = DateFormatter(); inFmt.dateFormat = "yyyyMMdd"
        guard let d = inFmt.date(from: ymd) else { return ymd }
        let out = DateFormatter(); out.dateFormat = "MMM d"
        return out.string(from: d)
    }

    /// Open the custom date-range sheet, seeding the pickers from any saved custom range.
    private func v3OpenDateRange() {
        let inFmt = DateFormatter(); inFmt.dateFormat = "yyyyMMdd"
        v3RangeFrom = inFmt.date(from: dateFilterFrom) ?? Date()
        v3RangeTo   = inFmt.date(from: dateFilterTo) ?? v3RangeFrom
        v3RangeSingleDay = (dateFilterSubMode != "range")
        showV3DateRange = true
    }

    /// Apply the chosen range: writes the custom-mode prefs the engine reads via buildIngestArgs.
    private func v3ApplyDateRange() {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd"
        // Normalize so From is never after To.
        let lo = min(v3RangeFrom, v3RangeTo), hi = max(v3RangeFrom, v3RangeTo)
        dateFilterFrom = fmt.string(from: lo)
        if v3RangeSingleDay {
            dateFilterSubMode = "single"
            dateFilterTo = ""
        } else {
            dateFilterSubMode = "range"
            dateFilterTo = fmt.string(from: hi)
        }
        dateFilterMode = "custom"
        showV3DateRange = false
    }

    /// Custom date-range picker (footage filter). "Single day" copies only that day's clips;
    /// "Range" copies From…To inclusive. Maps to --date-from / --date-to (yyyyMMdd).
    private var v3DateRangeSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Custom date filter").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                Spacer(); v3SheetClose { showV3DateRange = false }
            }
            Text("Only clips recorded in this window are copied. The rest are skipped (never deleted).")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)

            v3SheetLabel("MODE")
            v3Segment(left: ("calendar", "Date range"), right: ("calendar.day.timeline.left", "Single day"),
                      leftSelected: !v3RangeSingleDay, in: v3DateSegNS, group: "dateModeSeg") { pickedLeft in
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { v3RangeSingleDay = !pickedLeft }
            }

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    v3SheetLabel(v3RangeSingleDay ? "DAY" : "FROM")
                    DatePicker("", selection: $v3RangeFrom, displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.compact)
                }
                if !v3RangeSingleDay {
                    VStack(alignment: .leading, spacing: 6) {
                        v3SheetLabel("TO")
                        DatePicker("", selection: $v3RangeTo, in: v3RangeFrom..., displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.compact)
                    }
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Button("Clear filter") {
                    dateFilterMode = "all"; dateFilterFrom = ""; dateFilterTo = ""
                    showV3DateRange = false
                }.buttonStyle(.plain).foregroundStyle(v3Amber).v3Hover(scale: 1.04, brighten: true)
                Spacer()
                v3SheetCancel { showV3DateRange = false }
                v3SheetPrimary("Apply", icon: "checkmark", enabled: true) { v3ApplyDateRange() }
                    .fixedSize()
            }
            .padding(.top, 4)
        }
        .padding(26).frame(width: 460)
        .background(Color(hex: "#0c0822")).preferredColorScheme(.dark)
    }

    private func v3ChipLabel(_ t: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 6) { Image(systemName: icon); Text(t) }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.white.opacity(0.04), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.10)))
    }
    private func v3Chip(_ t: String, _ icon: String, _ color: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { v3ChipLabel(t, icon, color).contentShape(Capsule()) }.buttonStyle(.plain).v3Hover()
    }
}

// MARK: - v3 funnel anchor key (sources → ring → destinations connectors)

/// Reports the Activity-log tail marker's Y within the scroll viewport, so the sheet can tell
/// whether the live tail is visible (pinned → keep following) or scrolled away (show jump-to-tail).
/// Event-driven (fires on scroll), never an always-on loop — respects the core-burn guardrail.
struct V3LogTailKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct V3AnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}
