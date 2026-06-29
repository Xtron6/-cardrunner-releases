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

enum SettingsTab: String, CaseIterable {
    case general   = "General"
    case presets   = "Presets"
    case shortcuts = "Shortcuts"
    case advanced  = "Advanced"
    case proTools  = "Pro Tools"
    case about     = "About"

    /// SF Symbol for the sidebar navigation row
    var sidebarIcon: String {
        switch self {
        case .general:   return "gearshape"
        case .presets:   return "slider.horizontal.3"
        case .shortcuts: return "keyboard"
        case .advanced:  return "wrench.and.screwdriver"
        case .proTools:  return "hammer"
        case .about:     return "info.circle"
        }
    }
}

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
                    .font(.custom("DM Sans", size: 12).weight(.semibold))
                    .foregroundStyle(useLightMode ? Color(hex: "#0F1923") : .white)
                Text(animationType.previewDescription)
                    .font(.custom("DM Sans", size: 10))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if animationType != .none {
                    Button { triggerPreview() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: previewing ? "stop.circle" : "play.circle.fill")
                                .font(.system(size: 11))
                            Text(previewing ? "Playing…" : "▶  Preview")
                                .font(.custom("DM Sans", size: 11).weight(.medium))
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

struct Volume: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    var cameraModel: String = "Camera"
    var volumeUUID: String? = nil   // set at detection time; persists through ingest lifecycle
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

    init(card: Volume, dateOverride: String?,
         wrongClockDate: String? = nil, reelFilter: [String] = [], reelMulti: Bool = false) {
        self.card = card
        self.dateOverride = dateOverride
        self.wrongClockDate = wrongClockDate
        self.reelFilter = reelFilter
        self.reelMulti = reelMulti
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

// MARK: - Lenient array decoding

/// Wrapper that decodes its element leniently — a failed element becomes nil instead
/// of throwing, so an array of these never fails wholesale on one corrupt/legacy row.
private struct LenientDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - All-Time Stats

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
    let friendlyName: String   // card label e.g. "Lucas"
    let projectName: String    // e.g. "20260515_Conor Daly Doc"
    let failedAt: Date
    let filesToCopy: Int
    let mbToCopy: Int
    let reason: String         // "Cancelled" or "Error"
}

// MARK: - Ingest Phase

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

// MARK: - Per-Ingest State

struct ActiveIngest {
    var cardName: String = ""
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

// MARK: - Ingest Outcome (pure, testable)

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

// MARK: - Progress protocol parsing (pure, testable)

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
        if !work.isEmpty { ingest.currentFileName = (work as NSString).lastPathComponent }

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

    } else if line.hasPrefix("PROGRESS_DEST ") {
        ingest.destPath = line.replacingOccurrences(of: "PROGRESS_DEST ", with: "")

    } else if line.hasPrefix("VERIFY_PROGRESS") {
        if let rc = line.range(of: "current="), let rt = line.range(of: "total=") {
            ingest.verifyChecked = crExtractInt(from: line, after: rc)
            ingest.verifyTotal   = crExtractInt(from: line, after: rt)
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

    } else if line.hasPrefix("VERIFY_OK ") || line.hasPrefix("VERIFY_SKIP")
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

// MARK: - Concurrent scheduler (pure, testable)

/// State the admission decision needs, kept free of View/@State so it's unit-testable.
struct SchedulerSnapshot {
    /// Physical-volume device IDs (st_dev) of ingests currently running — one per card.
    let runningDestDevices: [dev_t]
    /// True while the onboarding demo holds the engine.
    let demoActive: Bool
    /// pref_maxConcurrentCards — hard ceiling on simultaneous ingests.
    let maxConcurrent: Int
}

/// Decide whether a card whose destination lives on `candidateDestDevice` may START NOW
/// (true) or must QUEUE (false). The scheduler is DESTINATION-AWARE: it parallelizes across
/// SEPARATE physical drives but never runs two cards onto the SAME volume at once — two
/// streams to one drive only split its bandwidth (no speedup) and add controller contention.
/// Net effect: the everyday "several cards → one SSD" case stays sequential and safe exactly
/// as it is today, while cards bound for different drives run truly in parallel.
func canAdmitIngest(candidateDestDevice: dev_t?, snapshot: SchedulerSnapshot) -> Bool {
    if snapshot.demoActive { return false }
    if snapshot.runningDestDevices.count >= max(1, snapshot.maxConcurrent) { return false }
    // Never two ingests writing to the same physical volume simultaneously.
    if let dev = candidateDestDevice, snapshot.runningDestDevices.contains(dev) { return false }
    return true
}

// MARK: - Main View

struct ContentView: View {

    // Theme base — mode-aware so icons/buttons stay readable in both modes
    private var accentBlue:   Color { useLightMode ? Color(hex: "#2472A4") : Color(hex: "#3DC8F5") }
    private var accentPurple: Color { useLightMode ? CardRunnerTheme.neonPurpleDark : CardRunnerTheme.neonPurple }
    /// Onboarding-matching violet — used for destination-mode UI (toggle, drive icon, action buttons)
    private var accentViolet: Color { useLightMode ? Color(hex: "#6D3BBF") : Color(hex: "#9B5FFF") }

    // Light/Dark mode (dark by default)
    @AppStorage("pref_useLightMode") private var useLightMode: Bool = false
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
    @State private var settingsTab: SettingsTab = .general
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
    // Persist light mode, import mode, etc...
    // Only keep the pref_useLightMode version
    // If you also want the XML checkbox:
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
    @AppStorage("pref_latestCount") private var latestCount: Int = 0
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
    @State private var showCompletionFlash: Bool = false

    // Completion confidence state — shown in the ring after a successful ingest
    @State private var showCompletionState: Bool = false

    // Confetti state (full-screen overlay)
    @State private var confettiPieces: [ConfettiPiece] = []
    @State private var confettiActive: Bool = false

    // ── Inline ring particle state ────────────────────────────────────────────
    // Pixel Fireworks — two-phase (shoot then fade) + pixel spark scatter
    @State private var victoryFireworks:  [VictoryFirework] = []
    @State private var fireworksShooting: Bool              = false
    @State private var fireworksFading:   Bool              = false
    @State private var pixelSparks:       [PixelSpark]      = []
    @State private var sparksFalling:     Bool              = false
    // Fizzy Soda — bubbles manage their own lifecycle via onAppear
    @State private var victoryBubbles:    [VictoryBubble]   = []
    // Retro Sparkle — sparkles manage their own lifecycle via onAppear
    @State private var victorySparkles:   [VictorySparkle]  = []

    @Namespace private var modeToggleNS
    @Namespace private var ingestToggleNS
    @Namespace private var lightModeToggleNS
    @Namespace private var destToggleNS
    @Namespace private var statsToggleNS
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
    @AppStorage("pref_showHistory") private var showHistory: Bool = false

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
    @State private var hoveredSettingsTab: SettingsTab? = nil
    @State private var hoveredPresetID: UUID? = nil
    @State private var prevTabIndex: Int = 0

    // Persisted SSD selection path
    @AppStorage("pref_primarySSDPath") private var primarySSDPath: String = ""

    // Custom destination — bypasses SSD+Project picker entirely
    @AppStorage("pref_useCustomDest")  private var useCustomDest:  Bool   = false
    @AppStorage("pref_customDestPath") private var customDestPath: String = ""
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

    var body: some View {
        if ProcessInfo.processInfo.environment["CR_V3_PREVIEW"] == "1" {
            // v3 graft: the legacy body stays mounted but invisible so ALL its proven wiring
            // (card detection via didMount → scanForNewCardsAndIngest, timers, menu handlers,
            // settings/alert sheets) keeps running. bodyV3 is a new face over the SAME @State.
            ZStack {
                legacyBody.opacity(0).allowsHitTesting(false)
                bodyV3
            }
        } else {
            legacyBody
        }
    }

    var legacyBody: some View {
        ZStack {
            // Full-window background — three tiers based on OS version:
            if #available(macOS 26.0, *) {
                // ── Tahoe: Liquid Glass era — material base + heavy neon tint ──
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Group {
                            if useLightMode {
                                LinearGradient(
                                    colors: [
                                        Color(hex: "#B8C5D6"),
                                        Color(hex: "#C5D0E0"),
                                        Color(hex: "#BFC2D8")
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .opacity(0.95)
                            } else {
                                LinearGradient(
                                    colors: [
                                        Color(hex: "#020817"),
                                        Color(hex: "#04152f"),
                                        Color(hex: "#071f43")
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .opacity(0.80)
                            }
                        }
                    )
                    .ignoresSafeArea()
            } else if #available(macOS 12.0, *) {
                // ── Sonoma / Sequoia ──
                // Dark mode: same solid gradient as Tahoe — no glass, but identical
                //   contrast and readability. Material was too translucent/unpredictable.
                // Light mode: system material looks native and clean.
                if useLightMode {
                    Rectangle()
                        .fill(.regularMaterial)
                        .ignoresSafeArea()
                } else {
                    LinearGradient(
                        colors: [
                            Color(hex: "#020817"),
                            Color(hex: "#04152f"),
                            Color(hex: "#071f43")
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                }
            } else {
                // ── Very old macOS fallback: solid gradient ──
                if useLightMode {
                    LinearGradient(
                        colors: [
                            Color(hex: "#B8C5D6"),
                            Color(hex: "#C5D0E0"),
                            Color(hex: "#BFC2D8")
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                } else {
                    LinearGradient(
                        colors: [
                            Color(hex: "#020817"),
                            Color(hex: "#04152f"),
                            Color(hex: "#071f43")
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                }
            }

            VStack(alignment: .leading, spacing: 20) {
                headerSection

                // FDA warning banner — shown any time FDA is not granted,
                // even after the wizard is skipped/dismissed.
                if !fdaGranted {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Full Disk Access required")
                                .font(.custom("DM Sans", size: 12).weight(.semibold))
                                .foregroundStyle(.orange)
                            Text("CardRunner can't read cards or write to drives without it.")
                                .font(.custom("DM Sans", size: 11))
                                .foregroundStyle(.orange.opacity(0.75))
                        }
                        Spacer()
                        Button {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text("Grant Access →")
                                .font(.custom("DM Sans", size: 11).weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Color.orange.opacity(0.85)))
                                .foregroundColor(.black)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.orange.opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35), lineWidth: 1))
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                HStack(alignment: .top, spacing: 24) {
                    leftColumnSection
                    VStack(spacing: 16) {
                        activeZoneSection
                        centerHistorySection
                    }
                    rightColumnSection
                }
                .layoutPriority(1)

                if debugMode {
                    logSection
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 52)      // breathing room for traffic-light buttons
            .padding(.bottom, 32)
            .frame(minWidth: 960, minHeight: 660)
            .preferredColorScheme(useLightMode ? .light : .dark)
            .blur(radius: license.isLicensed ? 0 : 14)
            .allowsHitTesting(license.isLicensed)
            .animation(.easeInOut(duration: 0.3), value: license.isLicensed)
            .onAppear {
                // Check license first — blocks the UI until resolved
                Task { await license.checkOnLaunch() }

                // Refresh SSD list + restore previous selection on launch.
                // NOTE: orphan-partial cleanup is deliberately deferred until AFTER
                // checkForStaleCheckpoints() below, so the sweep can skip any drive that
                // has a resumable checkpoint (its .cardrunner_partial staging is exactly
                // what a resume needs — deleting it first defeats/races the resume).
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
                    startAutoScanLoop()
                    scanForNewCardsAndIngest(forceRescan: true)
                } else {
                    AudioEngine.shared.autoIngestDisabled()
                    stopAutoScanLoop()
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
            .onReceive(NotificationCenter.default.publisher(for: .showShortcutsHelp)) { _ in
                settingsTab = .shortcuts
                isShowingSettings = true
            }

            // ── Menu bar handlers live in a separate overlay to avoid
            //    exhausting the type-checker on the long modifier chain. ──────
            .background(menuNotificationHandlers)

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
                        startIngest(for: card)
                    }
                }
            } message: {
                Text("All \(tier0SkippedCount) clip\(tier0SkippedCount == 1 ? "" : "s") on this card were excluded by the current date filter. Ingest everything?")
            }
            .sheet(isPresented: $showDatePickerSheet) {
                datePickerSheet
            }
            .sheet(isPresented: $showReelPickerSheet) {
                reelPickerSheet
            }

            // ── License gate ─────────────────────────────────────────────────
            // Show for both .unlicensed (never had a key) and .revoked (key
            // rejected by server — store migration, refund, wrong product).
            // NOT shown during .checking to prevent a flash on every launch.
            if license.status == .unlicensed || license.status == .revoked {
                LicenseGateView()
                    .transition(.opacity)
            }

            // ── Welcome celebration — shown for returning users re-activating ──
            // (New first-time users get WelcomeCelebrationView as page 0 of
            //  OnboardingView below instead.)
            if showWelcomeOverlay {
                WelcomeCelebrationView {
                    showWelcomeOverlay = false
                    license.clearJustActivated()
                }
                .transition(.opacity)
                .zIndex(50)
            }

            // ── Onboarding flow — first-launch walkthrough ────────────────────
            if showOnboarding {
                OnboardingView(
                    runDemo:    { runDemoIngest() },
                    demoStatus: $onboardingDemoStatus,
                    onComplete: {
                        withAnimation(.easeInOut(duration: 0.55)) { showOnboarding = false }
                        onboardingCompleted = true
                        onboardingDemoStatus = ""
                        // Re-scan destinations so selectedPrimary picks up the SSD the
                        // user chose during onboarding (commitScreen2 saved the path to
                        // @AppStorage but selectedPrimary is @State and needs a refresh).
                        refreshDestinations()
                    }
                )
                .transition(.opacity)
                .zIndex(60)
            }

            // ── Completion flash overlay ─────────────────────────────────────
            if showCompletionFlash {
                completionFlashOverlay
            }

            // ── Settings overlay (ZStack instead of .sheet so tapping outside closes it) ──
            if isShowingSettings {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { isShowingSettings = false } }
                    .transition(.opacity)
                    .zIndex(80)

                settingsSheet
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.55), radius: 40, y: 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
                    .zIndex(81)
            }
        } // end ZStack
        .onChange(of: license.justActivated) {
            if license.justActivated {
                if onboardingCompleted {
                    // Returning user re-activating: just show the welcome celebration
                    showWelcomeOverlay = true
                } else {
                    // Brand-new user: launch the full onboarding (which begins with
                    // WelcomeCelebrationView as its first page)
                    showOnboarding = true
                }
            }
        }
        // Clicking anywhere outside a text field resigns focus so keyboard
        // shortcuts (especially Space) work immediately without an extra click.
        .simultaneousGesture(
            TapGesture().onEnded { NSApp.keyWindow?.makeFirstResponder(nil) }
        )
    } // end var body

    // MARK: - Completion Animations

    /// Routes to the correct overlay based on the chosen animation.
    /// Inline ring animations (pixelFireworks, fizzySoda, retroSparkle) return
    /// EmptyView here — they render directly inside the ring ZStack.
    @ViewBuilder
    private var completionFlashOverlay: some View {
        switch completionAnim {
        case .none:           EmptyView()
        case .confetti:       confettiOverlay
        case .pixelFireworks: EmptyView()
        case .fizzySoda:      EmptyView()
        case .retroSparkle:   EmptyView()
        case .victory:        EmptyView()
        }
    }

    // ── 1. Confetti Burst ────────────────────────────────────────────────────

    private static let confettiColors: [Color] = [
        Color(hex: "#FF3B30"), Color(hex: "#FF9500"), Color(hex: "#FFCC02"),
        Color(hex: "#34C759"), Color(hex: "#00C7BE"), Color(hex: "#007AFF"),
        Color(hex: "#AF52DE"), Color(hex: "#FF2D55"),
    ]

    private func makeConfettiPieces() -> [ConfettiPiece] {
        (0..<90).map { i in
            let angle  = Double(i) / 90.0 * 2 * .pi + Double(i % 7) * 0.18
            let dist   = CGFloat(160 + (i * 23) % 340)  // 160–500 pt travel
            let xT     = cos(angle) * dist
            // Bias downward so pieces fall naturally — upper arc goes up, lower falls more
            let yT     = sin(angle) * dist * 0.65 + CGFloat(60 + (i * 13) % 200)
            return ConfettiPiece(
                id:     i,
                color:  Self.confettiColors[i % Self.confettiColors.count],
                xTarget: xT,
                yTarget: yT,
                rotate: Double(i * 43 % 720),
                w:      CGFloat(6 + i % 10),
                h:      CGFloat(3 + i % 6),
                delay:  Double(i % 10) * 0.025
            )
        }
    }

    private var confettiOverlay: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(confettiPieces) { piece in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(piece.color)
                        .frame(width: piece.w, height: piece.h)
                        .rotationEffect(.degrees(confettiActive ? piece.rotate : 0))
                        .offset(
                            x: confettiActive ? piece.xTarget : 0,
                            y: confettiActive ? piece.yTarget : 0
                        )
                        .opacity(confettiActive ? 0.0 : 1.0)
                        .animation(
                            .easeOut(duration: 1.1).delay(piece.delay),
                            value: confettiActive
                        )
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.38)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func triggerConfetti() {
        confettiPieces  = makeConfettiPieces()
        confettiActive  = false

        Task { @MainActor in
            // Let pieces render at origin for one frame, then burst
            try? await Task.sleep(nanoseconds: 16_000_000)
            confettiActive = true
            // Total lifetime: max delay (0.21s) + duration (1.1s) + tail (0.3s)
            try? await Task.sleep(nanoseconds: 1_650_000_000)
            showCompletionFlash = false
            confettiPieces = []
            confettiActive = false
        }
    }

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

    // 18 starbursts evenly spread 360° around the ring, with varied ray sizes
    private func makeVictoryFireworks() -> [VictoryFirework] {
        var result: [VictoryFirework] = []
        for i in 0..<18 {
            let base: Double   = Double(i) / 18.0 * 2.0 * Double.pi
            let jitter: Double = Double(i * 17 % 29) * 0.07 - 0.06
            let rLen: CGFloat  = CGFloat(13 + (i * 7) % 11)   // 13–23 px rays
            result.append(VictoryFirework(
                spawnAngle: base + jitter,
                color:      Self.fwColors[i % Self.fwColors.count],
                rayLength:  rLen,
                delay:      Double(i % 6) * 0.055
            ))
        }
        return result
    }

    // 10 sparks per burst, fanning outward with strong gravity arc
    private func makePixelSparks(from fws: [VictoryFirework]) -> [PixelSpark] {
        let ringR: CGFloat = 115
        var result: [PixelSpark] = []
        for fw in fws {
            let bx = CGFloat(cos(fw.spawnAngle)) * ringR
            let by = CGFloat(sin(fw.spawnAngle)) * ringR
            for j in 0..<10 {
                let sAngle    = fw.spawnAngle + Double(j) * (2.0 * Double.pi / 10.0) + Double.pi / 20.0
                let dist: CGFloat = CGFloat(28 + j * 9)          // 28–109 pt scatter
                let bxTgt = CGFloat(cos(sAngle)) * dist
                let byTgt = CGFloat(sin(sAngle)) * dist + CGFloat(14 + j * 4) // gravity bias
                result.append(PixelSpark(
                    originX:  bx,
                    originY:  by,
                    targetX:  bxTgt,
                    targetY:  byTgt,
                    color:    Self.sparkColor[(j + i_hash(fw.delay)) % Self.sparkColor.count],
                    size:     CGFloat(2 + j % 4),
                    delay:    fw.delay + 0.05 + Double(j) * 0.018,
                    duration: 0.75 + Double(j % 4) * 0.12
                ))
            }
        }
        return result
    }

    // 32 bubbles from the full ring perimeter — sizes and heights vary widely
    private func makeVictoryBubbles() -> [VictoryBubble] {
        let ringR: CGFloat = 115
        var result: [VictoryBubble] = []
        for i in 0..<32 {
            // Full 360° ring perimeter with small jitter
            let angle    = Double(i) / 32.0 * 2.0 * Double.pi + Double(i * 7 % 13) * 0.04
            let startX   = CGFloat(cos(angle)) * ringR
            let startY   = CGFloat(sin(angle)) * ringR
            let sz: CGFloat    = CGFloat(6 + (i * 11) % 17)      // 6–22 px
            let opac: Double   = 0.65 + Double(i % 5) * 0.06     // 0.65–0.89
            let wAmp: CGFloat  = CGFloat(8 + i % 14)             // 8–21 wobble
            let wPer: Double   = 0.20 + Double(i % 4) * 0.08     // 0.20–0.44 s
            let rDur: Double   = 1.5 + Double(i % 6) * 0.22 + Double(i * 11 % 9) * 0.07
            let dly: Double    = Double(i) / 32.0 * 2.0 + Double(i * 7 % 11) * 0.05
            // Rise to 140–230 pt above spawn (well outside the ring boundary)
            let endY: CGFloat  = startY - CGFloat(140 + (i * 9) % 90)
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

    // 54 sparkles blanketing 360° at radii 130–230 pt — dense starfield effect
    private func makeVictorySparkles() -> [VictorySparkle] {
        let ringR: CGFloat = 115
        // Dense ring: 20 top arc, 8 left, 8 right, 8 bottom, 10 diagonal fill
        var angles: [Double] = []
        for i in 0..<20 { angles.append(-Double.pi/2 + (Double(i)-9.5) * Double.pi/11 + Double(i*7%11)*0.04) }
        for i in 0..<8  { angles.append(Double.pi   + (Double(i)-3.5) * Double.pi/9  + Double(i*11%9)*0.03) }
        for i in 0..<8  { angles.append(0           + (Double(i)-3.5) * Double.pi/9  + Double(i*13%9)*0.03) }
        for i in 0..<8  { angles.append(Double.pi/2 + (Double(i)-3.5) * Double.pi/9  + Double(i*9%8)*0.04)  }
        for i in 0..<10 { angles.append(Double(i) / 10.0 * 2.0 * Double.pi + 0.31)  }  // diagonal fill

        var result: [VictorySparkle] = []
        for (idx, angle) in angles.enumerated() {
            let r = ringR + CGFloat(15 + (idx * 9) % 100)   // 130–230 pt from center
            result.append(VictorySparkle(
                x:            CGFloat(cos(angle)) * r,
                y:            CGFloat(sin(angle)) * r,
                size:         CGFloat(8 + (idx * 7) % 17),  // 8–24 px
                color:        Self.sparkleColors[idx % Self.sparkleColors.count],
                isPlus:       (idx % 2 == 0),
                rotated45:    (idx % 3 == 0),
                appearDelay:  Double(idx) / Double(angles.count) * 2.8 + Double(idx*7%12)*0.04,
                holdDuration: 0.12 + Double(idx * 11 % 22) * 0.01
            ))
        }
        return result
    }

    // Hash helper to avoid calling .hashValue on Double in hot path
    private func i_hash(_ d: Double) -> Int { Int(d * 1000) }

    // Inline particle layer (rendered inside ring ZStack) ─────────────────────

    @ViewBuilder
    private var inlineParticleLayer: some View {
        let ringR: CGFloat = 115

        ZStack {
            // ── Pixel Fireworks: starbursts shoot outward 90 pt from ring edge ──
            ForEach(victoryFireworks) { fw in
                let ca = CGFloat(cos(fw.spawnAngle))
                let sa = CGFloat(sin(fw.spawnAngle))
                PixelStarburst(rayLength: fw.rayLength, color: fw.color)
                    .offset(
                        x: fireworksShooting ? ca * (ringR + 90) : ca * ringR,
                        y: fireworksShooting ? sa * (ringR + 90) : sa * ringR
                    )
                    .opacity(fireworksFading ? 0.0 : 1.0)
                    .animation(.easeOut(duration: 0.50).delay(fw.delay),        value: fireworksShooting)
                    .animation(.easeOut(duration: 0.25).delay(fw.delay + 0.35), value: fireworksFading)
            }

            // ── Pixel Sparks: tiny squares fall with gravity after burst ─────
            ForEach(pixelSparks) { sp in
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

            // ── Fizzy Soda: bubbles manage their own rise + wobble + fade ────
            ForEach(victoryBubbles) { b in
                FizzySodaBubbleView(b: b)
            }

            // ── Retro Sparkle: shapes manage their own appear/hold/disappear ─
            ForEach(victorySparkles) { sp in
                RetroSparkleShapeView(sp: sp)
            }
        }
    }

    // Trigger functions ───────────────────────────────────────────────────────

    private func resetInlineParticles() {
        victoryFireworks  = []; pixelSparks     = []
        victoryBubbles    = []; victorySparkles = []
        fireworksShooting = false; fireworksFading = false; sparksFalling = false
    }

    private func triggerPixelFireworks() {
        resetInlineParticles()
        let fws           = makeVictoryFireworks()
        victoryFireworks  = fws
        pixelSparks       = makePixelSparks(from: fws)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            fireworksShooting = true                      // starbursts launch (500 ms)
            try? await Task.sleep(nanoseconds: 350_000_000)
            fireworksFading = true; sparksFalling = true   // fade + sparks scatter
            // max delay (0.30 s) + shoot (0.50 s) + fade (0.25 s) + sparks (~1.5 s) + tail
            try? await Task.sleep(nanoseconds: 2_700_000_000)
            showCompletionFlash = false; resetInlineParticles()
        }
    }

    private func triggerFizzySoda() {
        resetInlineParticles()
        victoryBubbles = makeVictoryBubbles()  // onAppear fires immediately
        Task { @MainActor in
            // stagger (2.0 s) + max rise (~2.8 s) + tail
            try? await Task.sleep(nanoseconds: 5_200_000_000)
            showCompletionFlash = false; victoryBubbles = []
        }
    }

    private func triggerRetroSparkle() {
        resetInlineParticles()
        victorySparkles = makeVictorySparkles()  // onAppear fires immediately
        Task { @MainActor in
            // spread (2.8 s) + max hold (0.34 s) + scale-out (0.07 s) + tail
            try? await Task.sleep(nanoseconds: 3_700_000_000)
            showCompletionFlash = false; victorySparkles = []
        }
    }

    private func triggerVictory() {
        resetInlineParticles()
        let fws          = makeVictoryFireworks()
        victoryFireworks = fws
        pixelSparks      = makePixelSparks(from: fws)
        victoryBubbles   = makeVictoryBubbles()
        victorySparkles  = makeVictorySparkles()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            fireworksShooting = true
            try? await Task.sleep(nanoseconds: 350_000_000)
            fireworksFading = true; sparksFalling = true
            // Longest sub-animation is bubbles ~5.2 s total
            try? await Task.sleep(nanoseconds: 5_500_000_000)
            showCompletionFlash = false; resetInlineParticles()
        }
    }

    // ── Shared dispatcher ────────────────────────────────────────────────────

    private func triggerCompletionFlash() {
        guard completionAnim != .none else { return }
        guard !showCompletionFlash else { return }
        showCompletionFlash = true
        switch completionAnim {
        case .confetti:       triggerConfetti()
        case .pixelFireworks: triggerPixelFireworks()
        case .fizzySoda:      triggerFizzySoda()
        case .retroSparkle:   triggerRetroSparkle()
        case .victory:        triggerVictory()
        case .none:           break
        }
    }

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

    // MARK: - Sections
    private var leftColumnSection: some View {
        VStack(spacing: 20) {

            // Failed ingest warning strip — shown when a previous ingest didn't complete
            if !failedIngestRecords.isEmpty {
                VStack(spacing: 6) {
                    ForEach(failedIngestRecords) { record in
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                let name = record.friendlyName.isEmpty ? record.cardName : record.friendlyName
                                Text("\(name) — \(record.reason == "Cancelled" ? "ingest cancelled" : "ingest error")")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.orange)
                                let elapsed = relativeTimeString(from: record.failedAt)
                                let detail = record.filesToCopy > 0
                                    ? "\(record.filesToCopy) files not copied · \(elapsed)"
                                    : "Transfer did not complete · \(elapsed)"
                                Text(detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.orange.opacity(0.75))
                            }
                            Spacer()
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    dismissFailedRecord(id: record.id)
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.orange.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // CONNECTED SOURCES (always shows SD icon)
            GroupBox(label:
                HStack(spacing: 8) {
                    Image(systemName: "sdcard.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(accentBlue)
                    Text("Connected sources")
                        .font(.custom("DM Sans", size: 13).weight(.semibold))
                        .foregroundStyle(textPrimary.opacity(0.9))
                }
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    panelSectionHeader("Sources")
                    if runningCount == 0 && cardQueue.isEmpty {
                        // ── No activity ──────────────────────────────────
                        HStack(alignment: .center, spacing: 16) {
                            Image(systemName: "sdcard.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(accentBlue)
                                .shadow(color: accentBlue.opacity(0.45), radius: 10)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("No card detected")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(textPrimary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    } else {
                        // ── Active card ───────────────────────────────────
                        if runningCount > 0 {
                            let activeNewClips = activeIngests.values.reduce(0) { $0 + $1.newFiles }
                            let activeClipInfo: String? = {
                                guard mediaTotal > 0 else { return nil }
                                return activeNewClips > 0
                                    ? "\(mediaTotal) \(mediaLabel)  \u{00B7}  \(activeNewClips) new"
                                    : "\(mediaTotal) \(mediaLabel)"
                            }()
                            CardQueueRow(
                                name: currentCardName,
                                subtitle: currentCameraModel,
                                progress: totalProgress,
                                textPrimary: textPrimary,
                                textSecondary: textSecondary,
                                clipInfo: activeClipInfo,
                                finalizing: isFinalizing
                            )
                        }
                        // ── Queued cards ──────────────────────────────────
                        ForEach(Array(cardQueue.enumerated()), id: \.element.card.id) { index, item in
                            Divider().opacity(0.3)
                            CardQueueRow(
                                name: item.card.name,
                                subtitle: "\(item.card.cameraModel) · Queue #\(index + 2)",
                                progress: nil,
                                textPrimary: textPrimary,
                                textSecondary: textSecondary
                            )
                        }

                        // Sparkline — only visible while a transfer is active
                        if runningCount > 0 && speedHistory.count >= 1 {
                            Divider().opacity(0.25)
                            SparklineView(
                                samples: speedHistory,
                                currentMBps: currentLiveMBps,
                                color: accentBlue
                            )
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .animation(.easeInOut(duration: 0.3), value: runningCount > 0)

            }
            .groupBoxStyle(CardRunnerGroupBoxStyle(border: borderStroke, fill: panelColor))

            // PRIMARY DESTINATION (matches SD card section styling)
            GroupBox(label:
                HStack(spacing: 8) {
                    Image(systemName: useCustomDest ? "folder.fill" : "externaldrive.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(accentPurple)
                    Text("Primary destination")
                        .font(.custom("DM Sans", size: 13).weight(.semibold))
                        .foregroundStyle(textPrimary.opacity(0.9))
                }
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    panelSectionHeader(useCustomDest ? "Custom folder" : "Primary drive")
                    HStack(alignment: .center, spacing: 16) {
                        Image(systemName: useCustomDest ? "folder.fill" : "externaldrive.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(accentViolet)
                            .shadow(color: accentViolet.opacity(0.45), radius: 10)

                        VStack(alignment: .leading, spacing: 5) {
                            if useCustomDest {
                                if customDestPath.isEmpty {
                                    Text("No folder selected")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(textPrimary.opacity(0.95))
                                    Text("Choose a destination folder in the right panel.")
                                        .font(.caption2)
                                        .foregroundStyle(textSecondary)
                                } else {
                                    Text(URL(fileURLWithPath: customDestPath).lastPathComponent)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(textPrimary.opacity(0.95))
                                    let freeGB  = Double(primaryFreeBytes)  / 1_073_741_824.0
                                    let totalGB = Double(primaryTotalBytes) / 1_073_741_824.0
                                    if totalGB > 0 {
                                        Text(String(format: "%.2f TB available of %.2f TB",
                                                    freeGB / 1000.0, totalGB / 1000.0))
                                            .font(.caption2)
                                            .foregroundStyle(textSecondary)
                                            .lineLimit(1)
                                    }
                                    Text(customDestPath)
                                        .font(.system(size: 9))
                                        .foregroundStyle(textMuted)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                            } else {
                                if let primary = selectedPrimary {
                                    Text(primary.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(textPrimary.opacity(0.95))

                                    let freeGB  = Double(primaryFreeBytes)  / 1_073_741_824.0
                                    let totalGB = Double(primaryTotalBytes) / 1_073_741_824.0

                                    if totalGB > 0 {
                                        let spaceColor: Color = {
                                            switch ssdSpaceLevel {
                                            case "crit": return .red
                                            case "warn": return Color(hex: "#F59E0B")
                                            default:     return textSecondary
                                            }
                                        }()
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(String(format: "%.2f TB available of %.2f TB",
                                                        freeGB / 1000.0, totalGB / 1000.0))
                                                .font(.caption2)
                                                .foregroundStyle(spaceColor)
                                                .lineLimit(1)
                                            if ssdSpaceLevel == "crit" {
                                                Text("⛔ Disk full — ingest blocked")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(Color.red)
                                            } else if ssdSpaceLevel == "warn" {
                                                Text("⚠️ Low disk space")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(Color(hex: "#F59E0B"))
                                            }
                                        }
                                    } else {
                                        Text("Capacity: calculating…")
                                            .font(.caption2)
                                            .foregroundStyle(textSecondary)
                                            .lineLimit(1)
                                    }
                                } else {
                                    Text("No SSD selected")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(textPrimary.opacity(0.95))
                                    Text("Select a primary SSD in settings.")
                                        .font(.caption2)
                                        .foregroundStyle(textSecondary)
                                }
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .groupBoxStyle(CardRunnerGroupBoxStyle(border: borderStroke, fill: panelColor))

            // SESSION SUMMARY — today's totals OR all-time recap, toggled via pill
            let allTimePurple = Color(hex: "#A78BFA")
            GroupBox(label:
                HStack(spacing: 8) {
                    Image(systemName: showingAllTimeStats ? "star.fill" : "chart.bar.fill")
                        .font(.system(size: 13))
                        .foregroundStyle((showingAllTimeStats ? allTimePurple : accentBlue).opacity(0.9))
                        .animation(.easeInOut(duration: 0.2), value: showingAllTimeStats)
                    Text(showingAllTimeStats ? "All time" : "Session")
                        .font(.custom("DM Sans", size: 13).weight(.semibold))
                        .foregroundStyle(textPrimary.opacity(0.9))
                        .animation(.easeInOut(duration: 0.2), value: showingAllTimeStats)
                    Spacer()
                    // Today / All time toggle pill
                    HStack(spacing: 0) {
                        ForEach([("Session", false), ("All time", true)], id: \.0) { label, isAllTime in
                            let sel = showingAllTimeStats == isAllTime
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.68)) {
                                    showingAllTimeStats = isAllTime
                                }
                            } label: {
                                Text(label)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(sel ? (useLightMode ? Color.black.opacity(0.75) : .white) : textSecondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background {
                                        if sel {
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .fill(useLightMode ? Color.white.opacity(0.8) : Color.white.opacity(0.14))
                                                .shadow(color: .black.opacity(useLightMode ? 0.10 : 0.25), radius: 3, y: 1)
                                                .matchedGeometryEffect(id: "statsTogglePill", in: statsToggleNS)
                                        }
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(useLightMode ? Color.black.opacity(0.07) : Color.white.opacity(0.06))
                    )
                }
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    panelSectionHeader(showingAllTimeStats ? "All time" : "Session summary")
                    if showingAllTimeStats {
                        // ── ALL-TIME VIEW ────────────────────────────────────
                        if allTimeStats.totalCards == 0 {
                            Text("No transfers recorded yet.")
                                .font(.caption2)
                                .foregroundStyle(textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 14)
                        } else {
                            HStack(spacing: 0) {
                                // Total cards
                                VStack(spacing: 6) {
                                    Text("\(allTimeStats.totalCards)")
                                        .font(.system(size: 30, weight: .bold, design: .rounded))
                                        .foregroundStyle(allTimePurple)
                                        .lineLimit(1).minimumScaleFactor(0.6)
                                    Text("cards")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(textMuted)
                                }
                                .frame(maxWidth: .infinity)

                                Divider().frame(height: 52).opacity(0.3)

                                // Total data
                                VStack(spacing: 6) {
                                    Text(allTimeDataString)
                                        .font(.system(size: 30, weight: .bold, design: .rounded))
                                        .foregroundStyle(allTimePurple)
                                        .lineLimit(1).minimumScaleFactor(0.45)
                                    Text("offloaded")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(textMuted)
                                }
                                .frame(maxWidth: .infinity)

                                Divider().frame(height: 52).opacity(0.3)

                                // Peak speed
                                VStack(spacing: 6) {
                                    Text("\(allTimeStats.peakMBps)")
                                        .font(.system(size: 30, weight: .bold, design: .rounded))
                                        .foregroundStyle(allTimePurple)
                                        .lineLimit(1).minimumScaleFactor(0.6)
                                    Text("MB/s peak")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(textMuted)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .padding(.vertical, 14)

                            // Footnote — files · duration · since date
                            if !allTimeFootnote.isEmpty {
                                Text(allTimeFootnote)
                                    .font(.system(size: 9))
                                    .foregroundStyle(allTimePurple.opacity(0.55))
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    } else {
                        // ── SESSION VIEW ─────────────────────────────────────
                        if sessionCardCount == 0 {
                            Text("No cards ingested this session.")
                                .font(.caption2)
                                .foregroundStyle(textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 14)
                        } else {
                            HStack(spacing: 0) {
                                // Cards
                                VStack(spacing: 6) {
                                    Text("\(sessionCardCount)")
                                        .font(.system(size: 30, weight: .bold, design: .rounded))
                                        .foregroundStyle(textPrimary)
                                        .lineLimit(1).minimumScaleFactor(0.6)
                                    Text("cards")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(textMuted)
                                }
                                .frame(maxWidth: .infinity)

                                Divider().frame(height: 52).opacity(0.3)

                                // GB transferred
                                VStack(spacing: 6) {
                                    Text(sessionTotalGB < 1
                                         ? String(format: "%.0f", sessionTotalGB * 1024)
                                         : String(format: "%.1f", sessionTotalGB))
                                        .font(.system(size: 30, weight: .bold, design: .rounded))
                                        .foregroundStyle(textPrimary)
                                        .lineLimit(1).minimumScaleFactor(0.6)
                                    Text(sessionTotalGB < 1 ? "MB transferred" : "GB transferred")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(textMuted)
                                }
                                .frame(maxWidth: .infinity)

                                Divider().frame(height: 52).opacity(0.3)

                                // Avg speed
                                VStack(spacing: 6) {
                                    Text(String(format: "%.0f", sessionAvgMBps))
                                        .font(.system(size: 30, weight: .bold, design: .rounded))
                                        .foregroundStyle(textPrimary)
                                        .lineLimit(1).minimumScaleFactor(0.6)
                                    Text("MB/s avg")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(textMuted)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .padding(.vertical, 14)
                        }
                    }
                } // end VStack
            }
            .groupBoxStyle(CardRunnerGroupBoxStyle(border: borderStroke, fill: panelColor))

        }
        .frame(minWidth: 260, maxWidth: 260, maxHeight: .infinity, alignment: .top)
    }
    private var activeZoneSection: some View {
        GroupBox {
            VStack(alignment: .center, spacing: 18) {
                HStack {
                    Text("Active zone")
                        .font(.headline)
                        .foregroundStyle(textPrimary)
                    Spacer()
                    HStack(spacing: 6) {
                        Text(statusText)
                            .font(.custom("DM Sans", size: 12).weight(.medium))
                            .foregroundStyle(textPrimary.opacity(0.9))
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(useLightMode ? Color.black.opacity(0.07) : Color.white.opacity(0.16))
                    )
                }

                // Neon ring
                ZStack {
                    let isActive = autoIngest || runningCount > 0
                    let ringSize: CGFloat = 230
                    let glowSize: CGFloat = 270
                    // Mode-aware ring colours — deeper saturation in light mode
                    let ringBlue   = useLightMode ? CardRunnerTheme.neonBlueDark   : CardRunnerTheme.neonBlue
                    let ringPurple = useLightMode ? CardRunnerTheme.neonPurpleDark : CardRunnerTheme.neonPurple
                    let inactiveOpacity: Double = useLightMode ? 0.60 : 0.45

                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    ringBlue.opacity(isActive ? 1.0 : inactiveOpacity),
                                    ringPurple.opacity(isActive ? 1.0 : inactiveOpacity)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isActive ? 9 : 7
                        )
                        .frame(width: ringSize, height: ringSize)
                        .shadow(color: ringBlue.opacity(isActive ? (useLightMode ? 0.22 : 0.95) : (useLightMode ? 0.0 : 0.45)),
                                radius: isActive ? 30 : 16)
                        .shadow(color: ringPurple.opacity(isActive ? (useLightMode ? 0.18 : 0.85) : (useLightMode ? 0.0 : 0.38)),
                                radius: isActive ? 36 : 22)
                        .animation(.easeInOut(duration: 0.18), value: isActive)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    ringBlue.opacity(isActive ? (useLightMode ? 0.10 : 0.35) : 0.0),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: isActive ? 160 : 130
                            )
                        )
                        .frame(width: glowSize, height: glowSize)
                        .animation(.easeInOut(duration: 0.18), value: isActive)

                    // Inner content — hard-capped to keep everything inside the ring.
                    // Width: ~78 % of ring diameter keeps text clear of the curved edge.
                    // "Open in Finder" lives OUTSIDE this ZStack (see below) so it never
                    // adds extra height here.
                    VStack(spacing: 8) {
                        // Mode-aware ring text colours (all inside the neon ring)
                        let ringPrimary:   Color = useLightMode ? Color(hex: "#0F1923")            : .white
                        let ringSecondary: Color = useLightMode ? Color(hex: "#0F1923").opacity(0.75) : .white.opacity(0.85)
                        let ringMuted:     Color = useLightMode ? Color(hex: "#0F1923").opacity(0.45) : .white.opacity(0.55)
                        let ringFaint:     Color = useLightMode ? Color(hex: "#0F1923").opacity(0.30) : .white.opacity(0.38)

                        Group {
                            if runningCount > 0, totalBytesNew > 0 || totalFiles > 0 {
                                // ── Active copy ───────────────────────────
                                // During the F_FULLFSYNC flush at the end, swap the frozen
                                // "99%" for an explicit, gently-pulsing "Finalizing…" so the
                                // operator knows the drive is committing data, not hung.
                                Text(isFinalizing ? "Finalizing…" : "\(Int(totalProgress * 100))%")
                                    .font(.system(size: isFinalizing ? 22 : 28, weight: .bold, design: .rounded))
                                    .foregroundColor(ringPrimary)
                                    .opacity(isFinalizing && finalizePulse ? 0.45 : 1.0)
                                    .animation(isFinalizing
                                               ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                                               : .default,
                                               value: finalizePulse)
                                Text(isFinalizing
                                     ? "Flushing to disk — keep card inserted"
                                     : "Copying \(mediaLabel)\(currentCardName.isEmpty ? "" : " from \(currentCardName)")")
                                    .font(.caption)
                                    .foregroundColor(ringSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                // Clip count — shown once PROGRESS_META arrives
                                let totalNewClips = activeIngests.values.reduce(0) { $0 + $1.newFiles }
                                if mediaTotal > 0 {
                                    Text(totalNewClips > 0
                                         ? "\(mediaTotal) \(mediaLabel)  \u{00B7}  \(totalNewClips) new"
                                         : "\(mediaTotal) \(mediaLabel)")
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundColor(ringMuted)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                // Low disk warning
                                if activeIngests.values.contains(where: { $0.lowDiskWarning }) {
                                    if let ing = activeIngests.values.first(where: { $0.lowDiskWarning }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.system(size: 9))
                                            Text(String(format: "%.0f GB free — tight", ing.destFreeGB))
                                                .font(.system(size: 10, weight: .medium))
                                        }
                                        .foregroundStyle(Color.orange)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                    }
                                }
                            } else if showCompletionState && runningCount == 0 && lastNewFiles > 0 {
                                // ── Post-ingest completion ────────────────
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 34))
                                    .foregroundStyle(
                                        LinearGradient(colors: [Color(hex: "#34D399"), Color(hex: "#10B981")],
                                                       startPoint: .top, endPoint: .bottom)
                                    )
                                    .shadow(color: Color(hex: "#10B981").opacity(0.5), radius: 8)

                                Text("Transfer Complete")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundColor(ringPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)

                                // Single consolidated stat line: "756 photos · 7m 12s · 103 MB/s avg"
                                let _statLine: String = {
                                    let dur = lastDurationSec >= 60
                                        ? "\(lastDurationSec / 60)m \(lastDurationSec % 60)s"
                                        : "\(lastDurationSec)s"
                                    var parts = ["\(lastNewFiles) \(lastMediaLabel)"]
                                    if lastDurationSec > 0 { parts.append(dur) }
                                    if lastAvgMBps > 0 { parts.append("\(lastAvgMBps) MB/s avg") }
                                    return parts.joined(separator: "  ·  ")
                                }()
                                Text(_statLine)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(ringSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .multilineTextAlignment(.center)

                                // Collision rename warning — shown when cardcopy had to
                                // auto-rename clips to avoid overwriting distinct same-named files
                                if !lastCollisionRenames.isEmpty {
                                    HStack(spacing: 5) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 9))
                                        let n = lastCollisionRenames.count
                                        Text(n == 1
                                             ? "1 clip renamed — duplicate filename detected"
                                             : "\(n) clips renamed — duplicate filenames detected")
                                            .font(.system(size: 10, weight: .medium))
                                    }
                                    .foregroundStyle(Color.orange)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.orange.opacity(0.12),
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                                }

                            } else if autoIngest {
                                Text("Ready for cards")
                                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                                    .foregroundColor(ringPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                // Destination preview — lets user verify before inserting card
                                if !predictedDestPreview.isEmpty {
                                    VStack(spacing: 3) {
                                        Text("Files will go to")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundColor(ringMuted)
                                        Text(predictedDestPreview)
                                            .font(.system(size: 10, weight: .regular))
                                            .foregroundColor(ringFaint)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .truncationMode(.middle)
                                    }
                                    .padding(.top, 2)
                                }
                            } else {
                                Text("Auto ingest is OFF")
                                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                                    .foregroundColor(ringPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Text("Toggle Auto ingest\nto watch for cards")
                                    .font(.caption)
                                    .foregroundColor(ringSecondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                // Still show destination preview so user can verify setup
                                if !predictedDestPreview.isEmpty {
                                    VStack(spacing: 3) {
                                        Text("Destination configured")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundColor(ringMuted)
                                        Text(predictedDestPreview)
                                            .font(.system(size: 10, weight: .regular))
                                            .foregroundColor(ringFaint)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .truncationMode(.middle)
                                    }
                                    .padding(.top, 2)
                                }
                            }
                        }

                        // ── Auto-ingest swoosh toggle ──────────────────
                        let swoosh = Animation.spring(response: 0.32, dampingFraction: 0.62)
                        let isTransferring = runningCount > 0

                        Group {
                        if isTransferring {
                            // Stop-transfer button — red pill with fade/scale transition
                            Button(action: {
                                withAnimation(swoosh) { autoIngest = false }
                                cancelAllIngests()
                            }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "stop.fill")
                                        .font(.caption2.bold())
                                    Text("Stop  \(currentShortcut(for: .stopTransfer).displayString)")
                                        .font(.caption.bold())
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(
                                        LinearGradient(
                                            colors: [Color.red.opacity(0.9), Color.red.opacity(0.65)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .shadow(color: Color.red.opacity(0.45), radius: 8, y: 3)
                                )
                                .foregroundColor(.white)
                            }
                            .buttonStyle(.plain)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                        } else {
                            // Sliding pill: OFF ←→ ON
                            HStack(spacing: 0) {
                                // OFF segment
                                Button(action: {
                                    withAnimation(swoosh) { autoIngest = false }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "moon.fill")
                                            .font(.caption2)
                                        Text("Off")
                                            .font(.caption.bold())
                                    }
                                    .scaleEffect(!autoIngest ? 1.0 : 0.88)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 7)
                                    .foregroundColor(!autoIngest
                                                     ? (useLightMode ? Color(hex: "#0F1923") : .white)
                                                     : (useLightMode ? Color(hex: "#0F1923").opacity(0.35) : .white.opacity(0.4)))
                                    .background {
                                        if !autoIngest {
                                            Capsule()
                                                .fill(LinearGradient(
                                                    colors: useLightMode
                                                        ? [Color.black.opacity(0.12), Color.black.opacity(0.06)]
                                                        : [Color.white.opacity(0.22), Color.white.opacity(0.10)],
                                                    startPoint: .leading,
                                                    endPoint: .trailing
                                                ))
                                                .shadow(color: useLightMode ? Color.black.opacity(0.08) : Color.white.opacity(0.12), radius: 6, y: 2)
                                                .matchedGeometryEffect(id: "ingestPill", in: ingestToggleNS)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                // ON segment
                                Button(action: {
                                    withAnimation(swoosh) { autoIngest = true }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "bolt.fill")
                                            .font(.caption2)
                                        Text("Auto Ingest")
                                            .font(.caption.bold())
                                    }
                                    .scaleEffect(autoIngest ? 1.0 : 0.88)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 7)
                                    .foregroundColor(autoIngest
                                                     ? .white
                                                     : (useLightMode ? Color(hex: "#0F1923").opacity(0.35) : .white.opacity(0.4)))
                                    .background {
                                        if autoIngest {
                                            Capsule()
                                                .fill(LinearGradient(
                                                    colors: [accentPurple, accentBlue],
                                                    startPoint: .leading,
                                                    endPoint: .trailing
                                                ))
                                                .shadow(color: accentBlue.opacity(0.5), radius: 8, y: 3)
                                                .matchedGeometryEffect(id: "ingestPill", in: ingestToggleNS)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .background(Capsule().fill(useLightMode ? Color.black.opacity(0.07) : Color.white.opacity(0.07)))
                            .animation(swoosh, value: autoIngest)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                        } // end Group
                        .animation(swoosh, value: isTransferring)
                    }
                    // Hard cap: never wider than ring * 0.78 so text clears the curved edge
                    .frame(maxWidth: ringSize * 0.78)

                    // ── Victory Burst particle layer ───────────────────────
                    // Zero-footprint anchor: Color.clear takes up 0×0 in the
                    // ZStack so it never contributes to layout sizing, while the
                    // overlay renders the full 800×800 particle canvas centered
                    // on the ring without pushing any parent view.
                    if !victoryFireworks.isEmpty || !pixelSparks.isEmpty || !victoryBubbles.isEmpty || !victorySparkles.isEmpty {
                        Color.clear
                            .frame(width: 0, height: 0)
                            .overlay(
                                inlineParticleLayer
                                    .frame(width: 800, height: 800)
                                    .allowsHitTesting(false)
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)

                // ── Open in Finder — lives OUTSIDE the ring ZStack so it never
                // adds height to the circle's content budget. Shown only after a
                // successful ingest.
                if showCompletionState && runningCount == 0 && !lastDestPath.isEmpty {
                    let ringSecondaryOut: Color = useLightMode
                        ? Color(hex: "#0F1923").opacity(0.75) : .white.opacity(0.85)
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: lastDestPath))
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                            Text("Open in Finder")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(useLightMode ? Color.black.opacity(0.08) : Color.white.opacity(0.12)))
                        .foregroundColor(ringSecondaryOut)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // Progress + summary underneath the ring
                progressAndSummarySection


            }
        }
        .groupBoxStyle(CardRunnerGroupBoxStyle(border: borderStroke, fill: panelColor))
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var rightColumnSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                projectSection
            }
        }
        .groupBoxStyle(CardRunnerGroupBoxStyle(border: borderStroke, fill: panelColor))
        .frame(width: 260, alignment: .top)
    }

    private var headerSection: some View {
        ZStack {
            // Edge controls row (Settings + Video/Photo on left, Light mode on right)
            HStack {
                HStack(spacing: 12) {
                    settingsButton
                    videoPhotoSegment
                }
                Spacer()
                lightModeControl
            }

            // Centered logo stack stays visually centered regardless of side content
            logoStack
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
                    .font(.custom("DM Sans", size: 16).weight(.bold))
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
                    .font(.custom("DM Sans", size: 16).weight(.bold))
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
                        .font(.custom("DM Sans", size: 13).weight(.semibold))
                        .foregroundStyle(textPrimary)
                    Text("The card was already mounted. This usually takes a few seconds.")
                        .font(.custom("DM Sans", size: 11))
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
                        .font(.custom("DM Sans", size: 13).weight(.semibold))
                        .foregroundStyle(textPrimary)
                    Text("The card may still be initialising. Try scanning again, or tap \u{201C}Ingest all\u{201D} to copy everything.")
                        .font(.custom("DM Sans", size: 11))
                        .foregroundStyle(textMuted)
                        .multilineTextAlignment(.center)
                    Button {
                        retryDateScan()
                    } label: {
                        Label("Scan again", systemImage: "arrow.clockwise")
                            .font(.custom("DM Sans", size: 12).weight(.semibold))
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
                        .font(.custom("DM Sans", size: 11).weight(.medium))
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
                        .font(.custom("DM Sans", size: 11))
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
                                                .font(.custom("DM Sans", size: 13).weight(.semibold))
                                                .foregroundStyle(textPrimary)
                                            if info.isToday {
                                                Text("today")
                                                    .font(.custom("DM Sans", size: 10).weight(.medium))
                                                    .foregroundStyle(accentBlue)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Capsule().fill(accentBlue.opacity(0.15)))
                                            }
                                        }
                                        Text("\(info.fileCount) file\(info.fileCount == 1 ? "" : "s") · \(info.displaySize)")
                                            .font(.custom("DM Sans", size: 11))
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
                .font(.custom("DM Sans", size: 13).weight(.medium))
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
                    .font(.custom("DM Sans", size: 13).weight(.semibold))
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
                        .font(.custom("DM Sans", size: 15).weight(.bold))
                        .foregroundStyle(textPrimary)
                    Text("Select which reels to ingest — files will land in today's folder")
                        .font(.custom("DM Sans", size: 11))
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
                    .font(.custom("DM Sans", size: 11).weight(.medium))
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
                    .font(.custom("DM Sans", size: 11))
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
                                        .font(.custom("DM Sans", size: 13).weight(.semibold))
                                        .foregroundStyle(textPrimary)
                                    Text("\(reel.fileCount) file\(reel.fileCount == 1 ? "" : "s") · \(reel.displaySize)")
                                        .font(.custom("DM Sans", size: 11))
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
                .font(.custom("DM Sans", size: 13).weight(.medium))
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
                    .font(.custom("DM Sans", size: 13).weight(.semibold))
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

    private var settingsSheet: some View {
        let sidebarAnim = Animation.easeInOut(duration: 0.15)

        return HStack(spacing: 0) {

            // ════════════════════════════════════════════════════════════
            // SIDEBAR  (~200 px, slightly darker frosted glass)
            // ════════════════════════════════════════════════════════════
            ZStack(alignment: .bottom) {
                // Glass background — darker sidebar material
                VisualEffectBlur(material: .sidebar, blendingMode: .behindWindow)

                VStack(spacing: 0) {
                    // Top padding (traffic lights live here)
                    Spacer().frame(height: 52)

                    // ── Nav items ──────────────────────────────────────
                    VStack(spacing: 2) {
                        ForEach(SettingsTab.allCases, id: \.self) { tab in
                            settingsSidebarRow(tab: tab, animation: sidebarAnim)
                        }
                    }
                    .padding(.horizontal, 10)

                    Spacer()

                    // ── Bottom: version watermark ──────────────────────
                    Text(appVersionString)
                        .font(.custom("DM Sans", size: 10))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(.bottom, 16)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: 196)
            // Hairline separator between sidebar and content
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
            }

            // ════════════════════════════════════════════════════════════
            // CONTENT AREA (lighter frosted glass)
            // ════════════════════════════════════════════════════════════
            ZStack(alignment: .topTrailing) {
                // Glass background — lighter content material
                VisualEffectBlur(material: .headerView, blendingMode: .behindWindow)

                VStack(spacing: 0) {
                    // ── Top bar: Done button ───────────────────────────
                    HStack {
                        Spacer()
                        Button("Done") { withAnimation(.easeInOut(duration: 0.18)) { isShowingSettings = false } }
                            .keyboardShortcut(.cancelAction)
                            .buttonStyle(.plain)
                            .font(.custom("DM Sans", size: 13).weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.75))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.09))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.white.opacity(0.13), lineWidth: 1)
                                    )
                            )
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 10)

                    Divider()
                        .opacity(0.4)

                    // ── Tab content ────────────────────────────────────
                    SmoothScrollView {
                        Group {
                            switch settingsTab {
                            case .general:   settingsGeneralTab
                            case .presets:   settingsPresetsTab
                            case .proTools:  settingsProToolsTab
                            case .shortcuts: settingsShortcutsTab
                            case .advanced:  settingsAdvancedTab
                            case .about:     settingsAboutTab
                            }
                        }
                        .id(settingsTab)
                        .transition(.opacity)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                    }
                    .animation(.easeInOut(duration: 0.15), value: settingsTab)
                }
            }
        }
        .frame(width: 720, height: 560)
        // Remove default sheet chrome background so our glass shows through
        .background(.clear)
        .preferredColorScheme(.dark)
    }

    /// One sidebar navigation row.
    @ViewBuilder
    private func settingsSidebarRow(tab: SettingsTab, animation: Animation) -> some View {
        let isSelected = settingsTab == tab
        let isHovered  = hoveredSettingsTab == tab
        let iconBlue   = Color(hex: "#4F8EF7")
        let showBadge  = (tab == .proTools) && !license.isLicensed

        Button {
            withAnimation(animation) { settingsTab = tab }
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: tab.sidebarIcon)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(
                            isSelected
                                ? iconBlue
                                : iconBlue.opacity(isHovered ? 0.85 : 0.55)
                        )
                        .frame(width: 20, height: 20)
                        .shadow(color: isSelected ? iconBlue.opacity(0.45) : .clear,
                                radius: 5, x: 0, y: 0)

                    if showBadge {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.orange)
                            .offset(x: 6, y: -4)
                    }
                }

                Text(tab.rawValue)
                    .font(.custom("DM Sans", size: 13).weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        isSelected
                            ? Color.white
                            : Color.white.opacity(isHovered ? 0.85 : 0.55)
                    )

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                        .matchedGeometryEffect(id: "settingsSidebarSelection", in: settingsTabNS)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.13), value: isHovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over in
            withAnimation(.easeInOut(duration: 0.13)) {
                hoveredSettingsTab = over ? tab : nil
            }
        }
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
                            .font(.custom("DM Sans", size: 12).weight(.semibold))
                            .foregroundStyle(textPrimary.opacity(0.7))
                        TextField("e.g. Run & Gun, Studio, B-cam", text: draft.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.custom("DM Sans", size: 13))
                        if isDuplicate {
                            Label("A preset with this name already exists.", systemImage: "exclamationmark.circle")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }

                    Divider().opacity(0.4)

                    // Import mode
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Import Mode")
                            .font(.custom("DM Sans", size: 12).weight(.semibold))
                            .foregroundStyle(textPrimary.opacity(0.7))
                        HStack(spacing: 8) {
                            ForEach([("Video", "video"), ("Photo", "photo")], id: \.1) { label, val in
                                let sel = presetEditorDraft.importMode == val
                                Button { draft.importMode.wrappedValue = val } label: {
                                    Text(label)
                                        .font(.custom("DM Sans", size: 12).weight(.medium))
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
                            .font(.custom("DM Sans", size: 12).weight(.semibold))
                            .foregroundStyle(textPrimary.opacity(0.7))
                        Text("Newest first lets editors start on the latest footage immediately.")
                            .font(.caption).foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            ForEach([("Oldest first", "oldest"), ("Newest first", "newest")], id: \.1) { label, val in
                                let sel = presetEditorDraft.ingestOrder == val
                                Button { draft.ingestOrder.wrappedValue = val } label: {
                                    Text(label)
                                        .font(.custom("DM Sans", size: 12).weight(.medium))
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
                            .font(.custom("DM Sans", size: 12).weight(.semibold))
                            .foregroundStyle(textPrimary.opacity(0.7))
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(dateFormats, id: \.format) { option in
                                let sel = presetEditorDraft.dateFolderFormat == option.format
                                let fill: Color = sel ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.06)
                                let stroke: Color = sel ? Color.accentColor.opacity(0.7) : borderStroke.opacity(0.5)
                                Button { draft.dateFolderFormat.wrappedValue = option.format } label: {
                                    Text(option.label)
                                        .font(.custom("DM Sans", size: 11).weight(.medium))
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
                                .font(.custom("DM Sans", size: 12).weight(.semibold))
                                .foregroundStyle(textPrimary.opacity(0.7))
                            InfoPopover("By default presets use your selected SSD + project folder. Enable Custom Folder to lock this preset to a specific path on your Mac (Desktop, NAS, any folder). The date-folder structure is still created inside that folder.")
                        }

                        // Mode toggle — full-area clickable tabs
                        HStack(spacing: 0) {
                            ForEach([("SSD + Project", false), ("Custom Folder", true)], id: \.0) { label, isCustom in
                                let selected = draft.useCustomDest.wrappedValue == isCustom
                                Button { draft.useCustomDest.wrappedValue = isCustom } label: {
                                    Text(label)
                                        .font(.custom("DM Sans", size: 11).weight(.medium))
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
                                            .font(.custom("DM Sans", size: 11))
                                            .foregroundStyle(textMuted)
                                    } else {
                                        Text(URL(fileURLWithPath: draft.customDestPath.wrappedValue).lastPathComponent)
                                            .font(.custom("DM Sans", size: 11).weight(.semibold))
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
                                        .font(.custom("DM Sans", size: 11).weight(.medium))
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
                            .font(.custom("DM Sans", size: 12).weight(.semibold))
                            .foregroundStyle(textPrimary.opacity(0.7))

                        // Today only toggle
                        let todayOnlyPresetBinding = Binding<Bool>(
                            get: { draft.dateFilterMode.wrappedValue == "today" },
                            set: { draft.dateFilterMode.wrappedValue = $0 ? "today" : "all" }
                        )
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Today only")
                                    .font(.custom("DM Sans", size: 11).weight(.medium))
                                    .foregroundStyle(textPrimary)
                                Text(draft.dateFilterMode.wrappedValue == "today"
                                     ? "Only today's files are ingested."
                                     : "All files ingested — confirm before start.")
                                    .font(.custom("DM Sans", size: 9))
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
                                    .font(.custom("DM Sans", size: 11))
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
                            .font(.custom("DM Sans", size: 12).weight(.semibold))
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
                                .font(.custom("DM Sans", size: 12).weight(.semibold))
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
                                        .font(.custom("DM Sans", size: 10))
                                        .foregroundStyle(textMuted)
                                    Spacer()
                                    if !isUsingGlobal {
                                        Button("Reset to global") {
                                            draft.scaffoldFolders.wrappedValue = ""
                                            presetNewScaffoldFolder = ""
                                        }
                                        .font(.custom("DM Sans", size: 10))
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
                                                    .font(.custom("DM Sans", size: 11))
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
                                                .font(.custom("DM Sans", size: 10).weight(.semibold))
                                                .foregroundStyle(accentBlue)
                                                .buttonStyle(.plain)
                                            } else {
                                                // Display mode: show "Folder / subfolder" with distinct styles
                                                let parts = presetFolders[i].components(separatedBy: "/")
                                                HStack(spacing: 2) {
                                                    Text(parts[0])
                                                        .font(.custom("DM Sans", size: 11))
                                                        .foregroundStyle(textPrimary)
                                                    if parts.count > 1 {
                                                        Text("/ \(parts[1...].joined(separator: "/"))")
                                                            .font(.custom("DM Sans", size: 11))
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
                                            .font(.custom("DM Sans", size: 11))
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
                                            .font(.custom("DM Sans", size: 11))
                                            .foregroundStyle(textMuted.opacity(presetNewScaffoldFolder.isEmpty ? 0.35 : 0.7))
                                        TextField("subfolder (opt.)", text: $presetNewScaffoldSubfolder)
                                            .textFieldStyle(.plain)
                                            .font(.custom("DM Sans", size: 11))
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
                                            .font(.custom("DM Sans", size: 10).weight(.medium))
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
                .font(.custom("DM Sans", size: 12))
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

    // MARK: Settings — General tab
    private var settingsGeneralTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Color.clear.frame(height: 4) // top breathing room
            // Victory animation picker — top of General
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accentBlue.opacity(0.85))
                    Text("Victory Animation")
                        .font(.body)
                    Spacer()
                }
                Text("Plays when a card finishes offloading.")
                    .font(.caption).foregroundColor(.secondary)

                // Option pill buttons
                HStack(spacing: 8) {
                    ForEach(CompletionAnimation.allCases, id: \.rawValue) { anim in
                        Button { completionAnimationRaw = anim.rawValue } label: {
                            HStack(spacing: 5) {
                                Text(anim.emoji).font(.system(size: 13))
                                Text(anim.label)
                                    .font(.custom("DM Sans", size: 12).weight(.medium))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(completionAnimationRaw == anim.rawValue
                                          ? Color.accentColor.opacity(0.25)
                                          : (useLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.06)))
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(completionAnimationRaw == anim.rawValue
                                                ? Color.accentColor.opacity(0.7)
                                                : borderStroke.opacity(0.5), lineWidth: 1))
                            )
                            .foregroundStyle(completionAnimationRaw == anim.rawValue ? Color.accentColor : textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }

                // Live preview card — shown for every selection including None
                AnimationPreviewWidget(animationType: completionAnim, useLightMode: useLightMode)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            .animation(.easeInOut(duration: 0.2), value: completionAnim)

            Divider().opacity(0.4)

            // Date folder format
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accentBlue.opacity(0.85))
                    Text("Folder Date Format")
                        .font(.body)
                    Spacer()
                }
                Text("How the date folder is named during ingest.")
                    .font(.caption).foregroundColor(.secondary)

                // Labels are computed from today so the preview never goes stale.
                let formats: [(label: String, format: String)] = {
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

                // 2-column grid so long date strings never overflow the sheet
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                          spacing: 8) {
                    ForEach(formats, id: \.format) { option in
                        let isSelected = dateFolderFormat == option.format
                        let fillColor: Color = isSelected
                            ? Color.accentColor.opacity(0.25)
                            : (useLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.06))
                        let strokeColor: Color = isSelected
                            ? Color.accentColor.opacity(0.7)
                            : borderStroke.opacity(0.5)
                        Button { dateFolderFormat = option.format } label: {
                            Text(option.label)
                                .font(.custom("DM Sans", size: 11).weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(fillColor)
                                        .overlay(RoundedRectangle(cornerRadius: 8)
                                            .stroke(strokeColor, lineWidth: 1))
                                )
                                .foregroundStyle(isSelected ? Color.accentColor : textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().opacity(0.4)

            // Ingest order
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accentBlue.opacity(0.85))
                    Text("Ingest Order")
                        .font(.body)
                    Spacer()
                }
                Text("Controls the order files are dispatched to the copy engine. Use \u{201C}Newest first\u{201D} so editors can start cutting the latest material while older footage continues copying.")
                    .font(.caption).foregroundColor(.secondary)

                HStack(spacing: 8) {
                    ForEach([("Oldest first", "oldest"), ("Newest first", "newest")], id: \.1) { label, val in
                        let isSelected = ingestOrder == val
                        Button { ingestOrder = val } label: {
                            Text(label)
                                .font(.custom("DM Sans", size: 12).weight(.medium))
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isSelected
                                              ? Color.accentColor.opacity(0.25)
                                              : (useLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.06)))
                                        .overlay(RoundedRectangle(cornerRadius: 8)
                                            .stroke(isSelected ? Color.accentColor.opacity(0.7) : borderStroke.opacity(0.5), lineWidth: 1))
                                )
                                .foregroundStyle(isSelected ? Color.accentColor : textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .onChange(of: ingestOrder) { _, newVal in
                    // Keep active preset in sync so applyPreset() doesn't revert it.
                    if let id = activePresetID,
                       let idx = presets.firstIndex(where: { $0.id == id }) {
                        presets[idx].ingestOrder = newVal
                        savePresets()
                    }
                }
            }

            Divider().opacity(0.4)

            // Finder tag on subsequent transfers
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accentBlue.opacity(0.85))
                    Text("Transfer Marker Tag")
                        .font(.body)
                    Spacer()
                    Toggle("", isOn: $finderTagEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: finderTagEnabled) { _, newVal in
                            // Keep active preset in sync so applyPreset() doesn't revert it.
                            if let id = activePresetID,
                               let idx = presets.firstIndex(where: { $0.id == id }) {
                                presets[idx].finderTagEnabled = newVal
                                savePresets()
                            }
                        }
                }
                Text("Tags the first clip of each subsequent transfer into a folder so you can instantly spot where a new batch starts.")
                    .font(.caption).foregroundColor(.secondary)

                if finderTagEnabled {
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
                            Button {
                                finderTagColor = option.value
                                // Keep the active preset in sync so a future applyPreset()
                                // call doesn't silently revert the color the user just picked.
                                if let id = activePresetID,
                                   let idx = presets.firstIndex(where: { $0.id == id }) {
                                    presets[idx].finderTagColor = option.value
                                    savePresets()
                                }
                            } label: {
                                let sel = finderTagColor == option.value
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 24, height: 24)
                                    .overlay(Circle().stroke(Color.white.opacity(sel ? 0.9 : 0), lineWidth: 2).padding(2))
                                    .overlay(Circle().stroke(option.color.opacity(sel ? 1 : 0), lineWidth: 2))
                                    .shadow(color: sel ? option.color.opacity(0.5) : .clear, radius: 4)
                            }
                            .buttonStyle(.plain)
                            .animation(.easeInOut(duration: 0.15), value: finderTagColor)
                        }
                        Spacer()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.2), value: finderTagEnabled)
                }
            }

            Divider().opacity(0.4)

            // Day-start / session reset hour
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accentBlue.opacity(0.85))
                    Text("Session Resets At")
                        .font(.body)
                    Spacer()
                }
                Text("Defines when Today's summary rolls over. Set past your latest wrap time so a shoot that runs past midnight stays in one session.")
                    .font(.caption).foregroundColor(.secondary)

                let options: [(label: String, hour: Int)] = [
                    ("12 am (midnight)", 0),
                    ("2 am",  2),
                    ("4 am",  4),
                    ("6 am",  6),
                ]
                HStack(spacing: 8) {
                    ForEach(options, id: \.hour) { option in
                        Button { dayStartHour = option.hour } label: {
                            Text(option.label)
                                .font(.custom("DM Sans", size: 11).weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(dayStartHour == option.hour
                                              ? Color.accentColor.opacity(0.25)
                                              : (useLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.06)))
                                        .overlay(RoundedRectangle(cornerRadius: 8)
                                            .stroke(dayStartHour == option.hour
                                                    ? Color.accentColor.opacity(0.7)
                                                    : borderStroke.opacity(0.5), lineWidth: 1))
                                )
                                .foregroundStyle(dayStartHour == option.hour ? Color.accentColor : textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }

            Divider().opacity(0.4)

            // Broadcast-day folder routing
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Broadcast Day Folder Routing")
                            .font(.body)
                        Text("Clips shot between midnight and your day-start hour are filed under the previous calendar day — keeping a game that runs past midnight in one folder.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $broadcastDayFolders)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if broadcastDayFolders {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(accentBlue.opacity(0.9))
                        Text("Uses your Session Resets At hour (\(dayStartHour == 0 ? "12 am" : "\(dayStartHour) am")) as the cutoff. Only applies to new ingests.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.2), value: broadcastDayFolders)
                }
            }

            Color.clear.frame(height: 4) // bottom breathing room
        }
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
                            .font(.custom("DM Sans", size: 12).weight(.semibold))
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
                            .font(.custom("DM Sans", size: 12).weight(.semibold))
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

    private var licenseSettingsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("License")
                .font(.body)
            HStack(spacing: 10) {
                Text(license.isLicensed ? license.maskedKey() : "Not activated")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if case .grace(let days) = license.status {
                    Text("Offline — \(days)d left")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Button("Deactivate on this Mac") {
                    showDeactivateConfirm = true
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(!license.isLicensed || license.isDeactivating)
            }
            if let err = deactivateError {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
        }
        .confirmationDialog("Deactivate CardRunner on this Mac?",
                            isPresented: $showDeactivateConfirm,
                            titleVisibility: .visible) {
            Button("Deactivate", role: .destructive) {
                Task {
                    deactivateError = await license.deactivate()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can re-activate on another Mac using the same license key.")
        }
    }

    // MARK: Settings — Pro Tools tab
    private var settingsProToolsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Professional features for on-set workflows. All off by default.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor.opacity(0.75))
                        .frame(width: 16)
                    Toggle("Dual-destination backup", isOn: $dualDestEnabled)
                        .font(.body)
                    InfoPopover("Copies every file from the card to both your primary SSD and a second drive in the same pass. Both copies come directly from the card source — not a copy of a copy. If the secondary drive isn't mounted when an ingest starts, the secondary copy is skipped and a warning is logged.")
                }
                Text("Copy every file to a second drive simultaneously. Never one copy.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if dualDestEnabled {
                    HStack(spacing: 8) {
                        Text("Secondary SSD")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                        Picker("Secondary SSD", selection: $selectedSecondary) {
                            Text("— none —").tag(Optional<Volume>.none)
                            ForEach(availableDestinations.filter { $0.path != selectedPrimary?.path }) { vol in
                                Text(vol.name).tag(Optional(vol))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .onChange(of: selectedSecondary) {
                            secondaryPath = selectedSecondary?.path ?? ""
                        }
                    }
                    .padding(.top, 2)
                    if selectedSecondary == nil {
                        Text("Select a mounted drive above.")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }
            SettingsRow(
                toggle: $fullVerifyEnabled,
                title: "Full checksum verification",
                detail: "MD5-verify every transferred file, not just a sample.",
                icon: "checkmark.shield.fill",
                info: "Computes an MD5 hash on both the source and destination for every file after copying. Any mismatch is flagged immediately. Without this, only up to 10 random files are spot-checked. Adds time proportional to card size."
            )
            SettingsRow(
                toggle: $transferReportEnabled,
                title: "Transfer report",
                detail: "Save a CSV log of every file copied during each ingest.",
                icon: "doc.text.magnifyingglass",
                info: "After each ingest a CSV is written to TransferReports/ inside your project folder. Columns: filename, size in bytes, source path, destination path, and timestamp. Open it in any spreadsheet app."
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor.opacity(0.75))
                        .frame(width: 16)
                    Toggle("Rename on ingest", isOn: $renameOnIngestEnabled)
                        .font(.body)
                    InfoPopover("Files are renamed as they land in the destination folder using a template you define. Supported tokens: {cardname} is replaced with the card label or volume name, {original} is the original filename without its extension. The original file extension is always preserved.")
                }
                Text("Rename files using a template as they're copied.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if renameOnIngestEnabled {
                    HStack(spacing: 8) {
                        TextField("e.g. {cardname}_{original}", text: $renameTemplate)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button("Reset") {
                            renameTemplate = "{cardname}_{original}"
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 2)

                    // Live preview using placeholder values
                    let preview = renameTemplatePreview(renameTemplate)
                    HStack(spacing: 6) {
                        Image(systemName: "eye")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(preview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(preview.hasPrefix("⚠") ? .orange : accentBlue)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
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
                    .font(.custom("DM Sans", size: 20).bold())
                    .foregroundStyle(.white)

                Text("A smoother ingest workflow for creators")
                    .font(.custom("DM Sans", size: 11))
                    .foregroundStyle(Color.white.opacity(0.45))
            }

            Spacer().frame(height: 12)

            // ── Info card ─────────────────────────────────────────────────
            VStack(spacing: 0) {

                // Version + update button
                VStack(spacing: 8) {
                    Text("CardRunner \(shortVersion)")
                        .font(.custom("DM Sans", size: 13).weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.7))

                    Button {
                        (NSApp.delegate as? AppDelegate)?.updaterController.checkForUpdates(nil)
                    } label: {
                        Text("Check for Updates")
                            .font(.custom("DM Sans", size: 12).weight(.medium))
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
                                .font(.custom("DM Sans", size: 12).weight(.semibold))
                                .foregroundStyle(Color.white.opacity(0.85))
                        }
                        if let email = license.customerEmail {
                            Text("Registered to: \(email)")
                                .font(.custom("DM Sans", size: 11))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                        Text(license.maskedKey())
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.3))

                        if case .grace(let days) = license.status {
                            Text("Offline — \(days) day\(days == 1 ? "" : "s") remaining")
                                .font(.custom("DM Sans", size: 10))
                                .foregroundStyle(.orange.opacity(0.85))
                        }

                        Button("Deactivate on this Mac") {
                            showDeactivateConfirm = true
                        }
                        .font(.custom("DM Sans", size: 11))
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
                                .font(.custom("DM Sans", size: 12).weight(.semibold))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { isShowingSettings = false }
                        } label: {
                            Text("Enter license key…")
                                .font(.custom("DM Sans", size: 11).weight(.medium))
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
                            .font(.custom("DM Sans", size: 12).weight(.medium))
                            .foregroundStyle(accentBlue)
                    }
                    .buttonStyle(.plain)

                    // License Terms + Privacy Policy on one line
                    HStack(spacing: 10) {
                        Button {
                            NSWorkspace.shared.open(URL(string: "https://www.xaviergallo.com/cardrunner-license")!)
                        } label: {
                            Text("License Terms")
                                .font(.custom("DM Sans", size: 12).weight(.medium))
                                .foregroundStyle(accentBlue)
                        }
                        .buttonStyle(.plain)

                        Text("·")
                            .font(.custom("DM Sans", size: 12))
                            .foregroundStyle(Color.white.opacity(0.25))

                        Button {
                            NSWorkspace.shared.open(URL(string: "https://www.xaviergallo.com/cardrunner-privacy-policy")!)
                        } label: {
                            Text("Privacy Policy")
                                .font(.custom("DM Sans", size: 12).weight(.medium))
                                .foregroundStyle(accentBlue)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 10)

                Divider().opacity(0.35).padding(.horizontal, 20)

                // Copyright
                Text("© 2025–2026 Xavier Gallo / XG Creative LLC")
                    .font(.custom("DM Sans", size: 11))
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

    // MARK: Settings — Advanced tab
    private var settingsAdvancedTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Note: Winter Olympics mode toggle is intentionally hidden from UI.
            // The feature is still functional — set winterOlympicsMode via defaults if needed.
            SettingsRow(
                toggle: $autoEject,
                title: "Auto eject card after ingest",
                detail: "Unmount the card automatically when copying finishes.",
                icon: "eject.fill",
                info: "After a successful ingest the card is safely ejected so it's ready to reformat in-camera. Has no effect in Dry Run mode."
            )
            SettingsRow(
                toggle: $includeProxies,
                title: "Copy in-camera proxies",
                detail: "Include proxy files alongside your main clips.",
                icon: "film.stack",
                info: "Copies low-res proxy files into a Proxies/ subfolder next to your main clips. Supports Sony S03 proxies and cameras that store proxies in a folder named Proxy or Sub."
            )
            SettingsRow(
                toggle: $verifyTransfer,
                title: "Verify transfer (spot-check)",
                detail: "Spot-check up to 10 files with MD5 after every ingest.",
                icon: "checkmark.shield",
                info: "After copying, a random sample of up to 10 files is checksummed on both source and destination. Any mismatch is logged as a warning. Adds a few seconds per ingest. For full file-by-file verification, enable Full Checksum Verification in Pro Tools."
            )
            SettingsRow(
                toggle: $copyXML,
                title: "Copy XML sidecars",
                detail: "Include XML sidecar files alongside video clips.",
                icon: "doc.plaintext",
                info: "When enabled, any .xml files found alongside your video clips on the card are copied to the same destination folder. Has no effect in photo mode."
            )

            Divider().opacity(0.4)

            // ── Project Scaffold ─────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                        .foregroundStyle(accentBlue)
                    Text("Project Scaffold")
                        .font(.custom("DM Sans", size: 12).weight(.semibold))
                        .foregroundStyle(textPrimary)
                    InfoPopover("Automatically creates a set of companion folders inside every new project. Runs when a card first ingests into a project, and when you create a new project folder. Tweak the list to match your own folder naming.")
                    Spacer()
                    MiniPillToggle(isOn: $scaffoldEnabled, onColor: accentBlue)
                }

                if scaffoldEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Folders created in each project")
                            .font(.custom("DM Sans", size: 10))
                            .foregroundStyle(textMuted)
                            .padding(.bottom, 2)

                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(scaffoldFolderList.indices, id: \.self) { i in
                                HStack(spacing: 6) {
                                    Image(systemName: editingScaffoldIndex == i ? "pencil" : "folder")
                                        .font(.system(size: 10))
                                        .foregroundStyle(editingScaffoldIndex == i ? accentBlue : accentBlue.opacity(0.8))

                                    if editingScaffoldIndex == i {
                                        // Edit mode: single field with full path (e.g. "Footage/A-Camera")
                                        TextField("", text: $editingScaffoldText)
                                            .textFieldStyle(.plain)
                                            .font(.custom("DM Sans", size: 11))
                                            .foregroundStyle(textPrimary)
                                            .onSubmit {
                                                renameScaffoldFolder(at: i, to: editingScaffoldText)
                                                editingScaffoldIndex = nil
                                            }
                                        Button("Save") {
                                            renameScaffoldFolder(at: i, to: editingScaffoldText)
                                            editingScaffoldIndex = nil
                                        }
                                        .font(.custom("DM Sans", size: 10).weight(.semibold))
                                        .foregroundStyle(accentBlue)
                                        .buttonStyle(.plain)
                                    } else {
                                        // Display mode: show "Folder / subfolder" with distinct styles
                                        let parts = scaffoldFolderList[i].components(separatedBy: "/")
                                        HStack(spacing: 2) {
                                            Text(parts[0])
                                                .font(.custom("DM Sans", size: 11))
                                                .foregroundStyle(textPrimary)
                                            if parts.count > 1 {
                                                Text("/ \(parts[1...].joined(separator: "/"))")
                                                    .font(.custom("DM Sans", size: 11))
                                                    .foregroundStyle(textMuted)
                                            }
                                        }
                                        Spacer()
                                        // Edit
                                        Button {
                                            editingScaffoldText  = scaffoldFolderList[i]
                                            editingScaffoldIndex = i
                                        } label: {
                                            Image(systemName: "pencil")
                                                .font(.system(size: 9))
                                                .foregroundStyle(textMuted.opacity(0.6))
                                        }
                                        .buttonStyle(.plain)
                                        // Delete
                                        Button { removeScaffoldFolder(at: i) } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(textMuted.opacity(0.6))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(editingScaffoldIndex == i
                                          ? (useLightMode ? accentBlue.opacity(0.06) : accentBlue.opacity(0.12))
                                          : (useLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.05))))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(editingScaffoldIndex == i ? accentBlue.opacity(0.3) : Color.clear, lineWidth: 1)
                                )
                                .animation(.easeInOut(duration: 0.15), value: editingScaffoldIndex)
                            }

                            // Add folder row — folder name + optional subfolder
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(accentBlue)
                                TextField("Folder", text: $newScaffoldFolder)
                                    .textFieldStyle(.plain)
                                    .font(.custom("DM Sans", size: 11))
                                    .foregroundStyle(textPrimary)
                                    .onSubmit { addScaffoldFolder() }
                                Text("/")
                                    .font(.custom("DM Sans", size: 11))
                                    .foregroundStyle(textMuted.opacity(newScaffoldFolder.isEmpty ? 0.35 : 0.7))
                                TextField("subfolder (opt.)", text: $newScaffoldSubfolder)
                                    .textFieldStyle(.plain)
                                    .font(.custom("DM Sans", size: 11))
                                    .foregroundStyle(textPrimary)
                                    .onSubmit { addScaffoldFolder() }
                                    .disabled(newScaffoldFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                                if !newScaffoldFolder.isEmpty {
                                    Button("Add") { addScaffoldFolder() }
                                        .font(.custom("DM Sans", size: 10).weight(.medium))
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

                        HStack {
                            Spacer()
                            Button("Reset to defaults") {
                                scaffoldFoldersRaw = "Footage\nAudio\nGraphics\nExports\nAssets\nDocuments"
                                editingScaffoldIndex = nil
                            }
                            .font(.custom("DM Sans", size: 10))
                            .foregroundStyle(textMuted)
                            .buttonStyle(.plain)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: scaffoldEnabled)

            Divider().opacity(0.4)

            // ── Debug Mode ───────────────────────────────────────────────────
            // Reveals the Log panel and Dry Run toggle in the main UI.
            // Hidden from normal users — off by default.
            SettingsRow(
                toggle: $debugMode,
                title: "Debug Mode",
                detail: "Reveal the Log panel and Dry Run toggle.",
                icon: "ladybug",
                info: "Enables developer tools in the main panel: a live Log panel (shows exactly what the ingest engine is doing) and a Dry Run toggle (simulates a transfer without copying any files). Turn off to keep the UI clean for day-to-day use.",
                onChange: {
                    if !debugMode {
                        // Hide and reset both debug features when mode is turned off
                        showDryRunToggle = false
                        dryRun           = false
                        showLog          = false
                    } else {
                        showDryRunToggle = true
                    }
                }
            )

            if debugMode {
                SettingsRow(
                    toggle: $showDryRunToggle,
                    title: "Dry Run toggle",
                    detail: "Show a Dry Run switch in the ingest panel.",
                    icon: "wand.and.rays",
                    info: "When enabled, a Dry Run toggle appears in the main panel. Turning Dry Run on simulates an ingest — folder structure is evaluated and logged but no files are copied or ejected. Useful for testing folder layout without writing anything.",
                    onChange: { if !showDryRunToggle { dryRun = false } }
                )
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))

                // ── Onboarding debug controls ─────────────────────────────
                Divider().opacity(0.28).padding(.leading, 16).padding(.top, 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text("ONBOARDING")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 16)
                        .padding(.bottom, 4)

                    Button {
                        onboardingCompleted = false
                    } label: {
                        Label("Reset Onboarding", systemImage: "arrow.counterclockwise")
                            .font(.custom("DM Sans", size: 11))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 16)

                    Button {
                        isShowingSettings    = false
                        onboardingDemoStatus = ""
                        showOnboarding       = true
                    } label: {
                        Label("Preview Onboarding Now", systemImage: "play.circle")
                            .font(.custom("DM Sans", size: 11))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 16)
                }
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: debugMode)
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

    private var logoStack: some View {
        HStack(alignment: .center, spacing: 12) {
            // PNG logo instead of SF Symbol
            Image("CardRunnerLogo")        // <-- must match asset name
                .resizable()
                .renderingMode(.original)  // keep your logo’s colors
                .aspectRatio(contentMode: .fit)
                .frame(width: 75, height: 64)
                .shadow(color: accentBlue.opacity(useLightMode ? 0.20 : 0.45), radius: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text("CardRunner")
                    .font(.custom("Tech Headlines Italic", size: 30))
                    .kerning(0.8)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [accentBlue, accentPurple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Text("A smoother ingest workflow for creators")
                    .font(.custom("DM Sans", size: 11))
                    .foregroundStyle(textSecondary)
                
            }
        }
    }
    private var settingsButton: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.18)) { isShowingSettings = true } }) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(textSecondary)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(useLightMode ? 0.10 : 0.08))
                )
        }
        .buttonStyle(.plain)
        .help("Open settings  ⌘,")
    }
    
    private var videoPhotoSegment: some View {
        let isVideo = importMode != "photo"

        // Underdamped spring → slight overshoot gives the "swoosh" feel
        let swoosh = Animation.spring(response: 0.32, dampingFraction: 0.62)

        return HStack(spacing: 0) {

            // ── Video ──────────────────────────────────────────────────────
            Button {
                withAnimation(swoosh) { importMode = "video" }
                AudioEngine.shared.modeSwitch()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Video")
                        .font(.custom("DM Sans", size: 12).weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .frame(minWidth: 80)
                .foregroundStyle(isVideo ? Color.white : textSecondary)
                .scaleEffect(isVideo ? 1.0 : 0.88)
                .background {
                    if isVideo {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient(
                                colors: [accentBlue,
                                         accentPurple.opacity(0.85)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .shadow(color: accentBlue.opacity(0.45), radius: 8, y: 3)
                            .matchedGeometryEffect(id: "modePill", in: modeToggleNS)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ── Photo ──────────────────────────────────────────────────────
            Button {
                withAnimation(swoosh) { importMode = "photo" }
                AudioEngine.shared.modeSwitch()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Photo")
                        .font(.custom("DM Sans", size: 12).weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .frame(minWidth: 80)
                .foregroundStyle(!isVideo ? Color.white : textSecondary)
                .scaleEffect(!isVideo ? 1.0 : 0.88)
                .background {
                    if !isVideo {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient(
                                colors: [accentPurple,
                                         accentBlue.opacity(0.85)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .shadow(color: accentPurple.opacity(0.45), radius: 8, y: 3)
                            .matchedGeometryEffect(id: "modePill", in: modeToggleNS)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(useLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(useLightMode ? Color.black.opacity(0.10) : Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(useLightMode ? 0.12 : 0.35), radius: 14, x: 0, y: 8)
        )
        .animation(swoosh, value: importMode)
    }

    private var lightModeControl: some View {
        let swoosh = Animation.spring(response: 0.32, dampingFraction: 0.62)

        return HStack(spacing: 0) {

            // ── Dark ───────────────────────────────────────────────────────
            Button {
                withAnimation(swoosh) { useLightMode = false }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Dark")
                        .font(.custom("DM Sans", size: 12).weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(!useLightMode ? Color.white : textSecondary.opacity(0.55))
                .scaleEffect(!useLightMode ? 1.0 : 0.88)
                .background {
                    if !useLightMode {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient(
                                colors: [CardRunnerTheme.neonBlue,
                                         CardRunnerTheme.neonPurple.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing))
                            .shadow(color: CardRunnerTheme.neonBlue.opacity(0.4), radius: 6, y: 2)
                            .matchedGeometryEffect(id: "lightPill", in: lightModeToggleNS)
                    }
                }
                // Note: this pill only renders in dark mode — no light-mode fix needed
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ── Light ──────────────────────────────────────────────────────
            Button {
                withAnimation(swoosh) { useLightMode = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Light")
                        .font(.custom("DM Sans", size: 12).weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(useLightMode ? Color(hex: "#1a1a2e") : textSecondary.opacity(0.55))
                .scaleEffect(useLightMode ? 1.0 : 0.88)
                .background {
                    if useLightMode {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color(hex: "#F59E0B").opacity(0.95),
                                         Color(hex: "#FBBF24").opacity(0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing))
                            .shadow(color: Color(hex: "#F59E0B").opacity(0.45), radius: 6, y: 2)
                            .matchedGeometryEffect(id: "lightPill", in: lightModeToggleNS)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(useLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            useLightMode ? Color.black.opacity(0.09) : Color.white.opacity(0.09),
                            lineWidth: 1
                        )
                )
        )
        .animation(swoosh, value: useLightMode)
    }

    // MARK: - Preset UI

    private var presetPickerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accentBlue.opacity(0.75))

            if let id = activePresetID, let preset = presets.first(where: { $0.id == id }) {
                Text(preset.name)
                    .font(.custom("DM Sans", size: 11).weight(.semibold))
                    .foregroundStyle(textPrimary)
                    .lineLimit(1)
            } else {
                Text("No Preset")
                    .font(.custom("DM Sans", size: 11))
                    .foregroundStyle(textMuted)
            }

            Spacer()

            // Switch preset button
            Button {
                showPresetPopover = true
            } label: {
                HStack(spacing: 4) {
                    Text("Switch")
                        .font(.custom("DM Sans", size: 10).weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(accentBlue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(accentBlue.opacity(0.12))
                        .overlay(Capsule().stroke(accentBlue.opacity(0.3), lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .popover(isPresented: $showPresetPopover, arrowEdge: .bottom) {
                presetSwitchPopover
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(accentBlue.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(accentBlue.opacity(0.18), lineWidth: 1))
        )
    }

    private var presetSwitchPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Presets")
                .font(.custom("DM Sans", size: 11).weight(.semibold))
                .foregroundStyle(textMuted)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // "No Preset" option
                    PopoverRow(isActive: activePresetID == nil, useLightMode: useLightMode) {
                        activePresetID = nil
                        savePresets()
                        showPresetPopover = false
                    } content: {
                        HStack {
                            Text("No Preset")
                                .font(.custom("DM Sans", size: 12))
                                .foregroundStyle(textPrimary)
                            Spacer()
                            if activePresetID == nil {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(accentBlue)
                            }
                        }
                    }

                    Divider()

                    ForEach(Array(presets.enumerated()), id: \.element.id) { idx, preset in
                        PopoverRow(isActive: activePresetID == preset.id, useLightMode: useLightMode) {
                            applyPreset(preset)
                            showPresetPopover = false
                        } content: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(preset.name)
                                        .font(.custom("DM Sans", size: 12).weight(.medium))
                                        .foregroundStyle(textPrimary)
                                    Text(presetSubtitle(preset))
                                        .font(.custom("DM Sans", size: 10))
                                        .foregroundStyle(textMuted)
                                }
                                Spacer()
                                // Shortcut badge ⌘1–⌘6
                                let sc = currentShortcut(for: presetSlotAction(idx))
                                if !sc.isNone {
                                    Text(sc.displayString)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(textMuted)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(useLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
                                        )
                                }
                                if activePresetID == preset.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(accentBlue)
                                }
                            }
                        }
                        if preset.id != presets.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 280)

            Divider()

            Button {
                showPresetPopover = false
                settingsTab = .presets
                isShowingSettings = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10))
                    Text("Manage Presets…")
                        .font(.custom("DM Sans", size: 11))
                }
                .foregroundStyle(accentBlue)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 220)
        .background(bgColor)
    }

    private var saveNewPresetPopover: some View {
        let trimmed     = newPresetName.trimmingCharacters(in: .whitespaces)
        let atLimit     = presets.count >= 6
        let isDuplicate = presets.contains { $0.name.lowercased() == trimmed.lowercased() }
        let isEmpty     = trimmed.isEmpty
        let canSave     = !isEmpty && !isDuplicate && !atLimit

        let hint: String? = {
            if atLimit     { return "6 preset limit reached — delete one first." }
            if isDuplicate { return "A preset named \"\(trimmed)\" already exists." }
            return nil
        }()

        return VStack(spacing: 0) {
            // Header + text field
            VStack(alignment: .leading, spacing: 8) {
                Text("Save as Preset")
                    .font(.custom("DM Sans", size: 13).weight(.semibold))
                    .foregroundStyle(textPrimary)

                TextField("e.g. Run & Gun, Studio, B-cam", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .font(.custom("DM Sans", size: 13))
                    .disabled(atLimit)
                    .onSubmit {
                        guard canSave else { return }
                        saveCurrentAsPreset(name: trimmed)
                        showSavePresetSheet = false
                    }

                // Inline validation hint — only shown when there's something to say
                if let hint {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10))
                        Text(hint)
                            .font(.custom("DM Sans", size: 10))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Color.orange)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: hint)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            Divider()

            // Full-width action buttons
            HStack(spacing: 0) {
                Button("Cancel") {
                    showSavePresetSheet = false
                }
                .buttonStyle(.plain)
                .font(.custom("DM Sans", size: 13))
                .foregroundStyle(textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Rectangle())

                Divider().frame(height: 44)

                Button("Save") {
                    guard canSave else { return }
                    saveCurrentAsPreset(name: trimmed)
                    showSavePresetSheet = false
                }
                .buttonStyle(.plain)
                .font(.custom("DM Sans", size: 13).weight(.semibold))
                .foregroundStyle(canSave ? accentBlue : textMuted.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .disabled(!canSave)
            }
        }
        .frame(width: 260)
        .background(bgColor)
    }

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
                        .font(.custom("DM Sans", size: 13).weight(.medium))
                        .foregroundStyle(textMuted)
                    Text("Tap \"New Preset…\" to create one — you can customize all options right in the editor.")
                        .font(.custom("DM Sans", size: 11))
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
                .font(.custom("DM Sans", size: 11))
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
                        .font(.custom("DM Sans", size: 12).weight(.medium))
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
                            .font(.custom("DM Sans", size: 10).weight(.medium))
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
                .font(.custom("DM Sans", size: 10))
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

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 14) {

            // ── CLUSTER 1: PRESET ─────────────────────────────────────────
            if !presets.isEmpty {
                presetPickerRow
                Divider().opacity(0.15).padding(.vertical, 2)
            }

            // ── CLUSTER 2: DESTINATION ────────────────────────────────────
            panelSectionHeader("Destination")

            // ── Destination mode toggle: SSD ↔ Custom Folder ──────────────
            let destSwoosh = Animation.spring(response: 0.30, dampingFraction: 0.65)

            HStack(spacing: 0) {

                // ── SSD tab ────────────────────────────────────────────────
                let ssdSelected = !useCustomDest
                let ssdHovered  = destTabHovered == false && !ssdSelected
                Button {
                    withAnimation(destSwoosh) { useCustomDest = false }
                    Task { @MainActor in self.updateSSDInfo() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text("SSD")
                            .font(.custom("DM Sans", size: 11).weight(.medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(ssdSelected ? (useLightMode ? Color.black.opacity(0.75) : Color.white) : textSecondary)
                    .scaleEffect(ssdSelected ? 1.0 : (ssdHovered ? 0.96 : 0.92))
                    .brightness(ssdHovered ? 0.10 : 0)
                    .background {
                        if ssdSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(useLightMode ? Color.white.opacity(0.75) : accentViolet.opacity(0.28))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(accentViolet.opacity(useLightMode ? 0 : 0.45), lineWidth: 1))
                                .shadow(color: accentViolet.opacity(useLightMode ? 0.10 : 0.35), radius: 6, y: 1)
                                .matchedGeometryEffect(id: "destPill", in: destToggleNS)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(runningCount > 0)
                .onHover { destTabHovered = $0 ? false : nil }

                // ── Custom Folder tab ──────────────────────────────────────
                let cfSelected = useCustomDest
                let cfHovered  = destTabHovered == true && !cfSelected
                Button {
                    withAnimation(destSwoosh) { useCustomDest = true }
                    Task { @MainActor in self.updateSSDInfo() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Custom Folder")
                            .font(.custom("DM Sans", size: 11).weight(.medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(cfSelected ? (useLightMode ? Color.black.opacity(0.75) : Color.white) : textSecondary)
                    .scaleEffect(cfSelected ? 1.0 : (cfHovered ? 0.96 : 0.92))
                    .brightness(cfHovered ? 0.10 : 0)
                    .background {
                        if cfSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(useLightMode ? Color.white.opacity(0.75) : accentViolet.opacity(0.28))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(accentViolet.opacity(useLightMode ? 0 : 0.45), lineWidth: 1))
                                .shadow(color: accentViolet.opacity(useLightMode ? 0.10 : 0.35), radius: 6, y: 1)
                                .matchedGeometryEffect(id: "destPill", in: destToggleNS)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(runningCount > 0)
                .onHover { destTabHovered = $0 ? true : nil }
            }
            .opacity(runningCount > 0 ? 0.45 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: runningCount > 0)
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(useLightMode ? Color.black.opacity(0.07) : Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(borderStroke, lineWidth: 1))
            )
            .animation(destSwoosh, value: useCustomDest)
            // ── Destination picker (SSD or Custom) ───────────────────────
            if useCustomDest {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        if customDestPath.isEmpty {
                            Text("No folder chosen")
                                .font(.custom("DM Sans", size: 11))
                                .foregroundStyle(textMuted)
                        } else {
                            HStack(spacing: 4) {
                                if !customDestIsValid {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.orange)
                                }
                                Text(URL(fileURLWithPath: customDestPath).lastPathComponent)
                                    .font(.custom("DM Sans", size: 11).weight(.semibold))
                                    .foregroundStyle(customDestIsValid ? textPrimary : .orange)
                                    .lineLimit(1)
                            }
                            Text(customDestIsValid ? customDestPath : "Folder not found — choose again")
                                .font(.system(size: 9))
                                .foregroundStyle(customDestIsValid ? textMuted : .orange.opacity(0.8))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Button { showCustomDestPanel() } label: {
                        Text(customDestPath.isEmpty ? "Choose…" : "Change…")
                            .font(.custom("DM Sans", size: 11).weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(accentViolet.opacity(customDestBtnHovered ? 0.28 : 0.15))
                                    .overlay(Capsule().stroke(accentViolet.opacity(customDestBtnHovered ? 0.60 : 0.35), lineWidth: 1))
                            )
                            .foregroundStyle(accentViolet)
                            .scaleEffect(customDestBtnHovered ? 1.04 : 1.0)
                            .brightness(customDestBtnHovered ? 0.08 : 0)
                    }
                    .buttonStyle(.plain)
                    .onHover { customDestBtnHovered = $0 }
                    .animation(.easeOut(duration: 0.15), value: customDestBtnHovered)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(useLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderStroke, lineWidth: 1))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                pickerRow("Primary SSD") {
                    Picker("Primary SSD", selection: $selectedPrimary) {
                        ForEach(availableDestinations) { vol in
                            Text(vol.name).tag(Optional(vol))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedPrimary) {
                    refreshProjectFolders()
                    updateSSDInfo()
                    primarySSDPath = selectedPrimary?.path ?? ""
                    restoreProjectForCurrentSSD()
                }
                .onChange(of: projectName) {
                    saveProjectForCurrentSSD()
                    withAnimation(.easeInOut(duration: 0.2)) { refreshSubfolders() }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // ── CLUSTER 3: PROJECT ────────────────────────────────────────

            if useCustomDest {
                // New project folder inside the chosen custom dest — same style as SSD
                Button {
                    customDestNewFolderName = todayDatePrefix()
                    customDestFolderColor = 0
                    showCustomDestNewFolder = true
                } label: {
                    Label("New project folder…", systemImage: "folder.badge.plus")
                        .font(.custom("DM Sans", size: 11))
                        .foregroundStyle(customDestPath.isEmpty ? textMuted.opacity(0.5) : accentViolet.opacity(0.85))
                }
                .buttonStyle(.plain)
                .disabled(customDestPath.isEmpty)
                .popover(isPresented: $showCustomDestNewFolder, arrowEdge: .bottom) {
                    NewProjectPopover(
                        name:            $customDestNewFolderName,
                        folderColor:     $customDestFolderColor,
                        isPresented:     $showCustomDestNewFolder,
                        primaryName:     customDestPath.isEmpty ? "Custom Folder" : {
                            let url = URL(fileURLWithPath: customDestPath)
                            return (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
                        }(),
                        scaffoldEnabled: scaffoldEnabled,
                        scaffoldFolders: scaffoldFolderList,
                        hintShown:       $scaffoldHintShown,
                        useLightMode:    useLightMode,
                        onCreate:        createCustomDestSubfolder,
                        onOpenSettings: {
                            showCustomDestNewFolder = false
                            NotificationCenter.default.post(name: .menuOpenSettings, object: nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                settingsTab = .advanced
                            }
                        }
                    )
                }
            } else {
                // Project folder picker
                pickerRow("Project folder") {
                    Picker("Project folder", selection: $projectName) {
                        if availableProjects.isEmpty {
                            if !projectName.isEmpty {
                                Text(projectName).tag(projectName)
                            } else {
                                Text("No folders found").tag("")
                            }
                        } else {
                            ForEach(availableProjects, id: \.self) { name in
                                Text(name).tag(name)
                            }
                            if !projectName.isEmpty && !availableProjects.contains(projectName) {
                                Text(projectName).tag(projectName)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                Button {
                    newProjectName = todayDatePrefix()
                    newProjectFolderColor = 0
                    showNewProjectSheet = true
                } label: {
                    Label("New project folder…", systemImage: "folder.badge.plus")
                        .font(.custom("DM Sans", size: 11))
                        .foregroundStyle(accentViolet.opacity(0.85))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showNewProjectSheet, arrowEdge: .bottom) {
                    NewProjectPopover(
                        name:             $newProjectName,
                        folderColor:      $newProjectFolderColor,
                        isPresented:      $showNewProjectSheet,
                        primaryName:      selectedPrimary?.name ?? "SSD",
                        scaffoldEnabled:  scaffoldEnabled,
                        scaffoldFolders:  scaffoldFolderList,
                        hintShown:        $scaffoldHintShown,
                        useLightMode:     useLightMode,
                        onCreate:         createNewProjectFolder,
                        onOpenSettings: {
                            showNewProjectSheet = false
                            NotificationCenter.default.post(name: .menuOpenSettings, object: nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                settingsTab = .advanced
                            }
                        }
                    )
                }

                if !availableSubfolders.isEmpty {
                    pickerRow("Subfolder") {
                        Picker("Subfolder", selection: $selectedSubfolder) {
                            Text("Default").tag("Default")
                            ForEach(availableSubfolders, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // Volume-mount / unmount listeners (always active regardless of dest mode)
            Color.clear
            .onReceive(NotificationCenter.Publisher(
                center: NSWorkspace.shared.notificationCenter,
                name: NSWorkspace.didMountNotification)) { _ in
                volumeCardCache = [:]
                refreshDestinations()
                cleanupOrphanPartialDirs()
                restoreProjectForCurrentSSD()
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
                revalidateCustomDest()   // drive holding custom dest may have been ejected
            }
            // Kick / stop the "Finalizing…" pulse as the flush window opens and closes.
            .onChange(of: isFinalizing) { _, now in
                finalizePulse = now
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
            .frame(height: 0)

            // ── CLUSTER 4: OPTIONS ────────────────────────────────────────
            Divider().opacity(0.15).padding(.vertical, 2)
            panelSectionHeader("Options")

            VStack(alignment: .leading, spacing: 12) {
                // ── Today only toggle ─────────────────────────────────────
                let todayOnlyBinding = Binding<Bool>(
                    get: { dateFilterMode == "today" },
                    set: { dateFilterMode = $0 ? "today" : "all" }
                )
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today only")
                            .font(.custom("DM Sans", size: 11))
                            .foregroundStyle(textPrimary)
                        Text(dateFilterMode == "today"
                             ? "Only today's files are ingested."
                             : "All files ingested — choose dates on card insert.")
                            .font(.custom("DM Sans", size: 9))
                            .foregroundStyle(textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    MiniPillToggle(isOn: todayOnlyBinding, onColor: accentBlue)
                }

                Divider().opacity(0.10)

                // ── Custom card name ──────────────────────────────────────
                HStack(spacing: 6) {
                    Text("Custom card name")
                        .font(.custom("DM Sans", size: 11))
                        .foregroundStyle(textPrimary)
                    if currentCardIsKnown {
                        // Recognised card — show the matched label name
                        Label(currentCardMatchedName, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    } else if currentCardInserted {
                        // Card present but not yet in the nickname store
                        Label("New card", systemImage: "questionmark.circle")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(textMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                    Spacer()
                    MiniPillToggle(isOn: $useCustomCardName, onColor: accentBlue)
                }

                if useCustomCardName {
                    TextField("e.g. Steadicam, Drone", text: $customCardName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .foregroundColor(textPrimary)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onChange(of: customCardName) { _, newVal in
                            // Block saves triggered by programmatic writes (auto-fill,
                            // preset apply, field clear). Only genuine user keystrokes
                            // should persist a nickname for the inserted card.
                            if skipNextNicknameSave {
                                skipNextNicknameSave = false
                                return
                            }
                            let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty, let uuid = currentInsertedCardUUID else { return }
                            // User typed this name — save it immediately and update the badge.
                            cardNameIsFromMemory   = false
                            knownCardNicknames[uuid] = trimmed
                            persistCardNicknames()
                            currentCardIsKnown     = true
                            currentCardMatchedName = trimmed
                            // Keep the Active Zone status bubble in sync with the typed name.
                            if !autoIngest && currentCardInserted {
                                statusText = "\(trimmed) ready — start transfer when you're ready"
                            }
                        }
                }

                // ── Debug tools — only visible when debug mode is ON in Settings ──
                if showDryRunToggle {
                    Divider().opacity(0.10)
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Dry run")
                                .font(.custom("DM Sans", size: 11))
                                .foregroundStyle(textPrimary)
                            Text("Logs what would copy without writing files.")
                                .font(.custom("DM Sans", size: 9))
                                .foregroundStyle(textMuted)
                        }
                        Spacer()
                        MiniPillToggle(isOn: $dryRun, onColor: .orange)
                    }
                    Button { runDemoIngest() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.circle.fill").font(.system(size: 11))
                            Text("Run UI Demo").font(.custom("DM Sans", size: 11).weight(.medium))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(Color.orange.opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.orange.opacity(0.35), lineWidth: 1)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.72), value: useCustomCardName)
            .animation(.spring(response: 0.35, dampingFraction: 0.72), value: currentCardIsKnown)
            .animation(.spring(response: 0.35, dampingFraction: 0.72), value: currentCardInserted)
            .animation(.easeInOut(duration: 0.18), value: dateFilterMode)
            .animation(.easeInOut(duration: 0.18), value: showDryRunToggle)
        }
    }

    private var ingestControlSection: some View { EmptyView() }

    // MARK: - Menu bar notification handlers
    // Applied as an invisible .background so we don't blow the type-checker
    // with an already-long modifier chain on the root ZStack.
    private var menuNotificationHandlers: some View {
        let spring  = Animation.spring(response: 0.32, dampingFraction: 0.62)
        let spring2 = Animation.spring(response: 0.38, dampingFraction: 0.78)
        return Color.clear
            // File → Settings…  (⌘,)
            .onReceive(NotificationCenter.default.publisher(for: .menuOpenSettings)) { _ in
                settingsTab = .general
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
            // File → Open Destination in Finder  (⌘⇧O)
            .onReceive(NotificationCenter.default.publisher(for: .menuOpenDestination)) { _ in
                if let primary = selectedPrimary {
                    NSWorkspace.shared.open(URL(fileURLWithPath: primary.path))
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
            // View → Show History  (⌘⇧H)
            .onReceive(NotificationCenter.default.publisher(for: .menuToggleHistory)) { _ in
                withAnimation(spring2) { showHistory.toggle() }
            }
            // View → Show Log  (⌘⇧G)
            .onReceive(NotificationCenter.default.publisher(for: .menuToggleLog)) { _ in
                withAnimation(spring2) { showLog.toggle() }
            }
            // View → Toggle Dark / Light  (⌘⇧D)
            .onReceive(NotificationCenter.default.publisher(for: .menuToggleDarkMode)) { _ in
                withAnimation(spring) { useLightMode.toggle() }
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

    private var progressAndSummarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if autoIngest {
                if totalBytesNew > 0 || totalFiles > 0 {
                    let fraction = totalProgress

                    HStack {
                        // % always reflects bytes — shows "—" until byte total arrives
                        if totalBytesNew > 0 {
                            Text("Overall: \(Int(fraction * 100))%")
                                .font(.body)
                                .foregroundStyle(textPrimary.opacity(0.9))
                        } else {
                            Text("Preparing…")
                                .font(.body)
                                .foregroundStyle(textPrimary.opacity(0.9))
                        }
                        Spacer()
                        if totalFiles > 0 {
                            Text("Files: \(min(completedFiles, totalFiles))/\(totalFiles)")
                                .font(.caption)
                                .foregroundStyle(textMuted)
                        }
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(
                                        colors: [accentBlue, accentPurple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(0, CGFloat(fraction) * geo.size.width), height: 4)
                                .animation(.easeInOut(duration: 0.18), value: fraction)
                        }
                    }
                    .frame(height: 4)

                    // ETA — the one number an operator needs mid-transfer
                    let _etaVal: String = {
                        let s = etaString
                        return s.hasPrefix("ETA: ") ? String(s.dropFirst(5)) : s
                    }()
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("ETA")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(textMuted)
                        Text(_etaVal)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(textPrimary)
                        Spacer()
                        if !transferSummaryString.isEmpty {
                            Text(transferSummaryString)
                                .font(.system(size: 10))
                                .foregroundStyle(textMuted)
                        }
                    }

                } else {
                    Text("Searching for cards…")
                        .font(.body)
                        .foregroundStyle(textPrimary.opacity(0.8))
                    ShimmerBar()
                        .frame(height: 4)
                }

                if let vp = verifyProgressText {
                    Text(vp)
                        .font(.caption2)
                        .foregroundStyle(accentBlue)
                } else if !currentFileName.isEmpty {
                    let _activeDestPath = activeIngests.values.first?.destPath ?? ""
                    let _destFolder: String = {
                        guard !_activeDestPath.isEmpty else { return "" }
                        let comps = URL(fileURLWithPath: _activeDestPath)
                            .pathComponents
                            .filter { $0 != "/" }
                        return comps.suffix(2).joined(separator: " › ")
                    }()
                    HStack(spacing: 4) {
                        Text("Current file:")
                            .font(.caption2)
                            .foregroundStyle(textMuted)
                            .fixedSize()
                        Text(currentFileName)
                            .font(.caption2)
                            .foregroundStyle(textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        if !_activeDestPath.isEmpty && !_destFolder.isEmpty {
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: _activeDestPath))
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 8))
                                    Text(_destFolder)
                                        .font(.caption2)
                                        .underline()
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                                .foregroundStyle(accentBlue.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                        }
                    }
                }
            } else {
                Text("Auto ingest is OFF")
                    .font(.body)
                    .foregroundStyle(textMuted)
                ShimmerBar()
                    .frame(height: 4)
            }

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

    private var centerHistorySection: some View {
        let entries    = sessionHistoryEntries.filter { $0.newFiles > 0 }
        let rowH       = Self.historyRowH
        let divH       = Self.historyDivH
        let maxRows    = Self.historyMaxRows
        let n          = entries.count
        // Natural height for up to `maxRows` collapsed rows (no expansion accounted for)
        let naturalH    = CGFloat(n) * rowH + CGFloat(max(0, n - 1)) * divH
        let capH        = CGFloat(maxRows) * rowH + CGFloat(maxRows - 1) * divH
        let needsScroll = n > maxRows

        // When a row is expanded the detail section adds ~68 pt of content.
        // Without this, the fixed-height ScrollView clips the expanded detail.
        // Only apply the bonus in non-scrolling mode; in scrolling mode the
        // user can scroll to see expanded content within the capped viewport.
        let expandedBonus: CGFloat = {
            guard !needsScroll,
                  let eid = expandedHistoryEntryID,
                  entries.contains(where: { $0.id == eid }) else { return 0 }
            return 68
        }()
        let frameH = needsScroll ? capH : min(naturalH, capH) + expandedBonus

        return GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                Text("History")
                    .font(.headline)
                    .foregroundStyle(textPrimary)
                    .padding(.bottom, 8)

                if entries.isEmpty {
                    // ── Empty state — centred, minimum-height placeholder ──
                    Text("No completed ingests this session.")
                        .font(.caption)
                        .foregroundStyle(textMuted)
                        .frame(maxWidth: .infinity, minHeight: Self.historyEmptyMinH, alignment: .center)
                } else {
                    // ── Rows — naturally sized up to 5, scrollable beyond ──
                    SmoothScrollView(
                        showsIndicators:    needsScroll,
                        alwaysShowScroller: needsScroll
                    ) {
                        VStack(spacing: 0) {
                            ForEach(entries) { entry in
                                let _isExpanded = expandedHistoryEntryID == entry.id
                                VStack(spacing: 0) {
                                    // ── Collapsed summary row ──
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color(hex: "#34D399").opacity(0.75))
                                        Text(entry.cardName.isEmpty ? "Card" : entry.cardName)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(textPrimary.opacity(0.85))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text("·  \(entry.newFiles) \(entry.mediaLabel)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(textMuted)
                                        Spacer()
                                        let _ed = entry.durationSec >= 60
                                            ? "\(entry.durationSec / 60)m \(entry.durationSec % 60)s"
                                            : "\(entry.durationSec)s"
                                        Text(_ed)
                                            .font(.system(size: 11))
                                            .foregroundStyle(textMuted)
                                        Image(systemName: _isExpanded ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 8, weight: .semibold))
                                            .foregroundStyle(textMuted.opacity(0.55))
                                    }
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                                            expandedHistoryEntryID = _isExpanded ? nil : entry.id
                                        }
                                    }

                                    // ── Expanded detail ──
                                    if _isExpanded {
                                        VStack(alignment: .leading, spacing: 5) {
                                            HStack(spacing: 14) {
                                                Label("\(entry.newFiles) \(entry.mediaLabel)", systemImage: "doc.fill")
                                                let _dur = entry.durationSec >= 60
                                                    ? "\(entry.durationSec / 60)m \(entry.durationSec % 60)s"
                                                    : "\(entry.durationSec)s"
                                                Label(_dur, systemImage: "clock")
                                                if entry.avgMBps > 0 {
                                                    Label("\(entry.avgMBps) MB/s avg", systemImage: "bolt.fill")
                                                }
                                            }
                                            .font(.system(size: 10))
                                            .foregroundStyle(textSecondary)

                                            if !entry.destPath.isEmpty {
                                                Button {
                                                    NSWorkspace.shared.open(URL(fileURLWithPath: entry.destPath))
                                                } label: {
                                                    HStack(spacing: 3) {
                                                        Image(systemName: "folder.fill")
                                                            .font(.system(size: 9))
                                                        Text(URL(fileURLWithPath: entry.destPath)
                                                            .pathComponents
                                                            .filter { $0 != "/" }
                                                            .suffix(3)
                                                            .joined(separator: " › "))
                                                            .font(.system(size: 10))
                                                            .underline()
                                                            .lineLimit(1)
                                                            .truncationMode(.head)
                                                    }
                                                    .foregroundStyle(accentBlue.opacity(0.85))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.leading, 16)
                                        .padding(.bottom, 7)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }

                                if entry.id != entries.last?.id {
                                    Divider().opacity(0.10)
                                }
                            }
                        }
                    }
                    .frame(height: frameH)
                }
            }
        }
        .groupBoxStyle(CardRunnerGroupBoxStyle(border: borderStroke, fill: panelColor))
        .frame(maxWidth: .infinity)
    }

    private var historySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("History")
                        .font(.headline)
                        .foregroundStyle(textPrimary)
                    Spacer()
                    MiniPillToggle(isOn: $showHistory)
                }

                if showHistory && !sessionHistoryEntries.isEmpty {
                    SmoothScrollView(showsIndicators: false) {
                        VStack(spacing: 8) {
                            ForEach(sessionHistoryEntries) { entry in
                                historyCard(
                                    title: entry.cardName,
                                    status: entry.status,
                                    newFiles: entry.newFiles,
                                    skipped: entry.skippedFiles,
                                    avgMBps: entry.avgMBps,
                                    durationSec: entry.durationSec,
                                    destPath: entry.destPath
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(minHeight: 150, maxHeight: 260)
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else if showHistory {
                    Text("No history yet. Ingest a card to see entries here.")
                        .font(.caption)
                        .foregroundStyle(textSecondary)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: showHistory)
        }
        .groupBoxStyle(CardRunnerGroupBoxStyle(border: borderStroke, fill: panelColor))
    }

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

    private var logSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Log")
                        .font(.headline)
                        .foregroundStyle(textPrimary.opacity(0.9))
                    Spacer()
                    Button("View log history") {
                        NSWorkspace.shared.open(logsDirectoryURL)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                    .opacity(showLog ? 1 : 0)
                    .animation(.easeInOut(duration: 0.18), value: showLog)
                    if debugMode {
                        MiniPillToggle(isOn: $showLog)
                    }
                }

                if showLog {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(borderStroke, lineWidth: 1)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(useLightMode ? Color.black.opacity(0.01) : Color.white.opacity(0.02))
                            )

                        SmoothScrollView(showsIndicators: false) {
                            Text(logText)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(textPrimary.opacity(0.9))
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(10)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(minHeight: 200, maxHeight: 260)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: showLog)
        }
        .groupBoxStyle(CardRunnerGroupBoxStyle(border: borderStroke, fill: panelColor))
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

    /// Reusable date-picker row used by both "single date" and "range from/to" modes.
    /// `label` is nil for single mode, or "From"/"To" for range mode.
    @ViewBuilder
    private func singleDateRow(
        label: String?,
        displayText: Binding<String>,
        storedDate: Binding<String>,
        calDate: Binding<Date>,
        showPop: Binding<Bool>,
        isFocused: FocusState<Bool>.Binding
    ) -> some View {
        HStack(spacing: 8) {
            if let label {
                Text(label)
                    .font(.custom("DM Sans", size: 10).weight(.semibold))
                    .foregroundStyle(textSecondary)
                    .frame(width: 28, alignment: .leading)
            }
            Image(systemName: "calendar")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accentBlue)
            Spacer()
            TextField("MM/DD/YYYY", text: displayText)
                .textFieldStyle(.plain)
                .font(.custom("DM Sans", size: 11).weight(.medium))
                .foregroundStyle(textPrimary)
                .multilineTextAlignment(.trailing)
                .frame(width: 88)
                .focused(isFocused)
                .onChange(of: displayText.wrappedValue) { _, newVal in
                    let digits = newVal.filter { $0.isNumber }
                    let capped  = String(digits.prefix(8))
                    var formatted = ""
                    for (i, ch) in capped.enumerated() {
                        if i == 2 || i == 4 { formatted += "/" }
                        formatted.append(ch)
                    }
                    if formatted != newVal { displayText.wrappedValue = formatted }
                    if capped.count == 8 {
                        let fmt = DateFormatter(); fmt.dateFormat = "MMddyyyy"
                        if let d = fmt.date(from: capped) {
                            let store = DateFormatter(); store.dateFormat = "yyyyMMdd"
                            storedDate.wrappedValue = store.string(from: d)
                        }
                    }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(useLightMode ? Color.black.opacity(0.06) : Color.white.opacity(0.09))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(accentBlue.opacity(showPop.wrappedValue || isFocused.wrappedValue ? 0.6 : 0.3), lineWidth: 1))
        )
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            showPop.wrappedValue = true
            isFocused.wrappedValue = true
        })
        .popover(isPresented: showPop, arrowEdge: .top) {
            DatePicker("", selection: calDate, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(12)
                .background(useLightMode ? Color(hex: "#CDD5E0") : Color(hex: "#0d1e36"))
                .colorScheme(useLightMode ? .light : .dark)
        }
        .onAppear {
            let parse = DateFormatter(); parse.dateFormat = "yyyyMMdd"
            let d = parse.date(from: storedDate.wrappedValue) ?? Date()
            let display = DateFormatter(); display.dateFormat = "MM/dd/yyyy"
            displayText.wrappedValue = display.string(from: d)
        }
    }

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

    private func rowLabel<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(textPrimary.opacity(0.9))
            Spacer()
            content()
        }
    }

    // MARK: - Skip Summary Row

    @ViewBuilder
    private func skipSummaryRow(summary: IngestHistoryEntry) -> some View {
        let totalSkipped = summary.totalSkipped
        let allSkipped   = summary.newFiles == 0 && totalSkipped > 0

        VStack(alignment: .leading, spacing: 6) {
            // ── Header row ──────────────────────────────────────
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSkipDetail.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: summary.newFiles > 0 ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(summary.newFiles > 0 ? .green : accentBlue)

                    if allSkipped {
                        Text("All \(totalSkipped) files skipped")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(textPrimary)
                    } else if summary.newFiles > 0 && totalSkipped > 0 {
                        Text("\(summary.newFiles) copied · \(totalSkipped) skipped")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(textPrimary)
                    } else if summary.newFiles > 0 {
                        Text("\(summary.newFiles) files copied")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(textPrimary)
                    } else {
                        Text("Nothing to copy")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(textPrimary)
                    }

                    Spacer()

                    if totalSkipped > 0 {
                        Image(systemName: showSkipDetail ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(textMuted)
                    }
                }
            }
            .buttonStyle(.plain)

            // ── Expanded breakdown ───────────────────────────────
            if showSkipDetail && totalSkipped > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    skipReasonRow(count: summary.skipDestExists,
                                  icon: "externaldrive.fill",
                                  color: accentBlue,
                                  label: "Already at destination")
                    skipReasonRow(count: summary.skipManifest,
                                  icon: "clock.arrow.circlepath",
                                  color: accentPurple,
                                  label: "Already copied previously")
                    skipReasonRow(count: summary.skipTodayFilter,
                                  icon: "calendar",
                                  color: .orange,
                                  label: "Filtered by today-only")
                    skipReasonRow(count: summary.skipWrongMode,
                                  icon: "camera.fill",
                                  color: .gray,
                                  label: "Wrong mode (\(importMode == "video" ? "photo" : "video") files)")
                    skipReasonRow(count: summary.skipProxy,
                                  icon: "film.stack",
                                  color: .teal,
                                  label: "Proxy/sub clips (proxy copy off)")
                    skipReasonRow(count: summary.skipMissing,
                                  icon: "exclamationmark.triangle.fill",
                                  color: .red,
                                  label: "Missing at copy time — NOT copied")
                }
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func skipReasonRow(count: Int, icon: String, color: Color, label: String) -> some View {
        if count > 0 {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(color.opacity(0.85))
                    .frame(width: 12)
                Text("\(count) \(label)")
                    .font(.system(size: 10))
                    .foregroundStyle(textSecondary)
            }
        }
    }

    /// Subtle all-caps section divider used inside the right panel.
    private func panelSectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(textSecondary.opacity(0.6))
                .kerning(0.8)
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
        }
    }

    /// Label stacked above a full-width picker in a subtle pill background.
    private func pickerRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.custom("DM Sans", size: 10))
                .foregroundStyle(textSecondary)
            HStack {
                content()
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(useLightMode ? Color.black.opacity(0.05) : Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(borderStroke.opacity(0.6), lineWidth: 1))
            )
        }
    }

    @ViewBuilder
    private func ssdInfoTile(for vol: Volume) -> some View {
        let freeGB = Double(primaryFreeBytes) / 1_073_741_824.0
        let totalGB = Double(primaryTotalBytes) / 1_073_741_824.0

        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 32))
                .foregroundStyle(accentBlue)
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(vol.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(textPrimary.opacity(0.95))
                if totalGB > 0 {
                    Text(String(format: "Free: %.2f GB of %.2f GB", freeGB, totalGB))
                        .font(.caption2)
                        .foregroundStyle(textPrimary.opacity(0.8))
                } else {
                    Text("Free space: calculating…")
                        .font(.caption2)
                        .foregroundStyle(textSecondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(useLightMode ? Color.black.opacity(0.02) : Color.white.opacity(0.06))
        )
    }

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

    private func saveProjectForCurrentSSD() {
        guard let ssd = selectedPrimary else { return }
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var map = UserDefaults.standard.dictionary(forKey: "pref_ssdProjectMap") as? [String: String] ?? [:]
        map[ssd.path] = name
        UserDefaults.standard.set(map, forKey: "pref_ssdProjectMap")
    }

    private func restoreProjectForCurrentSSD() {
        guard let ssd = selectedPrimary else { return }
        let map = UserDefaults.standard.dictionary(forKey: "pref_ssdProjectMap") as? [String: String] ?? [:]
        if let remembered = map[ssd.path], !remembered.isEmpty {
            projectName = remembered
        }
    }

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

                // Always apply nickname / badge — passive, no transfers started.
                if !newCards.isEmpty {
                    self.applyNicknameIfKnown(from: newCards, nicknames: capturedNicknames)
                }

                if self.autoIngest {
                    // Auto Ingest on — route cards to the date picker / ingest flow.
                    self.routeCardsForIngest(newCards)
                } else if !newCards.isEmpty {
                    // Auto Ingest off — card recognised; let the user decide when to start.
                    let label = self.currentCardMatchedName.isEmpty
                        ? "Card ready"
                        : "\(self.currentCardMatchedName) ready"
                    self.statusText = "\(label) — start transfer when you're ready"
                }

                if finalCards.isEmpty && self.runningCount == 0 {
                    self.currentCardIsKnown      = false
                    self.currentCardInserted     = false
                    self.currentCardMatchedName  = ""
                    self.currentInsertedCardUUID = nil
                    self.cardNameIsFromMemory    = false
                    self.statusText = self.autoIngest ? "Searching for cards…" : "Waiting for cards…"
                }
            }
        }
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
    /// Called from every scan path (auto-ingest loop, 30-s fallback loop, force-rescan)
    /// so the behaviour is consistent regardless of how a card is detected.
    @MainActor private func routeCardsForIngest(_ cards: [Volume]) {
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
                    await MainActor.run { self.startIngest(for: card) }
                    continue
                }

                let dates = analysis.dates

                if !dates.isEmpty {
                    // Dates found — handle without loading state
                    await MainActor.run {
                        if dates.count == 1 {
                            self.startIngest(for: card, dateOverride: dates[0].yyyymmdd)
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
                             wrongClockDate: String?, reelFilter: [String], reelMulti: Bool) {
        if !cardQueue.contains(where: {
            cardIdentifier(for: $0.card) == cardIdentifier(for: card)
                && $0.dateOverride == dateOverride
        }) {
            cardQueue.append(QueuedIngest(card: card, dateOverride: dateOverride,
                                          wrongClockDate: wrongClockDate,
                                          reelFilter: reelFilter, reelMulti: reelMulti))
        }
    }

    /// The physical volume a new ingest would write to under the current destination config.
    /// (Per-card routing is a later slice; today all cards share the configured destination.)
    private func currentDestRootForScheduling() -> String? {
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
            let dev = volumeDeviceID(of: currentDestRootForScheduling() ?? "")
            guard canAdmitIngest(candidateDestDevice: dev, snapshot: currentSchedulerSnapshot()) else { break }
            let item = cardQueue.removeFirst()
            startIngest(for: item.card, dateOverride: item.dateOverride,
                        wrongClockDate: item.wrongClockDate,
                        reelFilter: item.reelFilter, reelMulti: item.reelMulti)
        }
    }

    private func startIngest(for card: Volume, dateOverride: String? = nil,
                              wrongClockDate: String? = nil,
                              reelFilter: [String] = [], reelMulti: Bool = false) {
        // The onboarding demo owns the engine exclusively — queue real cards behind it.
        if demoTask != nil {
            enqueueIfNew(card: card, dateOverride: dateOverride,
                         wrongClockDate: wrongClockDate, reelFilter: reelFilter, reelMulti: reelMulti)
            return
        }

        // Resolve destination — custom folder takes priority over SSD+Project
        let resolvedDestRoot: String
        let resolvedProjectRoot: String
        if useCustomDest {
            var isDestDir: ObjCBool = false
            guard !customDestPath.isEmpty,
                  FileManager.default.fileExists(atPath: customDestPath, isDirectory: &isDestDir),
                  isDestDir.boolValue else {
                statusText = "Custom destination folder not found."
                return
            }
            resolvedDestRoot    = customDestPath
            resolvedProjectRoot = customDestPath
        } else {
            guard let primary = selectedPrimary else {
                statusText = "Select a primary SSD."
                return
            }
            let trimmedProject = projectName.trimmingCharacters(in: .whitespaces)
            guard !trimmedProject.isEmpty else {
                statusText = "Project name required."
                return
            }
            resolvedDestRoot    = primary.path   // passed as --primary to shell
            resolvedProjectRoot = "\(primary.path)/\(trimmedProject)"
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
                         wrongClockDate: wrongClockDate, reelFilter: reelFilter, reelMulti: reelMulti)
            return
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
        activeIngests[processID]?.friendlyName = useCustomCardName ? customCardName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        // Record the destination volume so the scheduler keeps the next card off this drive.
        activeIngests[processID]?.destDeviceID = candidateDestDevice ?? 0

        // Clear stale summary card
        lastNewFiles        = 0
        lastAvgMBps         = 0
        lastDurationSec     = 0
        lastDestPath        = ""
        lastReportPath      = ""
        showCompletionState = false

        var args: [String] = []
        args.append(scriptPath)
        // Pass the real app version so it appears correctly in log files.
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        args.append(contentsOf: ["--app-version", "v\(appVersion)"])
        args.append(contentsOf: ["--card", card.path])

        if useCustomDest {
            // --dest-root bypasses PRIMARY_ROOT/PROJECT_NAME construction in the shell
            args.append(contentsOf: ["--dest-root", resolvedDestRoot])
            // Pass --primary as the volume root so the shell can derive secondary-dest paths.
            // e.g. /Users/xavier/Desktop/ClientA  →  volume root is /  (local disk)
            // e.g. /Volumes/MySSD/Shoots/2026     →  volume root is /Volumes/MySSD
            let urlComponents = URL(fileURLWithPath: resolvedDestRoot).pathComponents
            let volumeRoot: String
            if urlComponents.count >= 3 && urlComponents[1] == "Volumes" {
                volumeRoot = "/" + urlComponents[1] + "/" + urlComponents[2]  // /Volumes/DriveName
            } else {
                volumeRoot = resolvedDestRoot   // non-external path — just use the custom dest itself
            }
            args.append(contentsOf: ["--primary", volumeRoot])
        } else {
            let trimmedProject = projectName.trimmingCharacters(in: .whitespaces)
            args.append(contentsOf: ["--primary", resolvedDestRoot])
            args.append(contentsOf: ["--project", trimmedProject])
        }

        if selectedSubfolder != "Default" {
            args.append(contentsOf: ["--subfolder", selectedSubfolder])
        }

        if useCustomCardName {
            // Only create a subfolder when the field has a name.
            // Empty field → no --cardlabel → files land directly in the date folder.
            let trimmedLabel = customCardName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLabel.isEmpty {
                args.append(contentsOf: ["--cardlabel", trimmedLabel])
            }
        }

        if latestCount > 0 {
            args.append(contentsOf: ["--latest", String(latestCount)])
        }

        if dryRun {
            args.append("--dry-run")
        }

        // Wrong-clock date override: use real ingest date for dest folders
        if let wcd = wrongClockDate {
            args += ["--date-override", wcd]
        }

        // Reel filter: restrict ingest to selected top-level capture folders
        if !reelFilter.isEmpty {
            args += ["--reels", reelFilter.joined(separator: ",")]
            if reelMulti {
                args.append("--reel-multi")
            }
        }

        if let override = dateOverride {
            if override.contains(",") {
                // Multiple dates from the picker — single pass via --dates DATE1,DATE2,...
                args += ["--dates", override]
            } else {
                // Single date (picker chose one, or Case 2 single-date card)
                args += ["--date-from", override]
            }
        } else if wrongClockDate == nil {
            // Normal date filtering (skip when wrong-clock override is active)
            switch dateFilterMode {
            case "today":
                args.append("--today-only")
            case "yesterday":
                let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd"
                let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                args += ["--date-from", fmt.string(from: yesterday)]
            case "custom":
                if !dateFilterFrom.isEmpty {
                    args += ["--date-from", dateFilterFrom]
                    if dateFilterSubMode == "range" && !dateFilterTo.isEmpty {
                        args += ["--date-to", dateFilterTo]
                    }
                }
            default: break  // "all" — no filter
            }
        }

        if autoEject {
            args.append("--auto-eject")
        }

        if fullVerifyEnabled {
            args.append("--full-verify")
        } else if verifyTransfer {
            args.append("--verify")
        }

        if transferReportEnabled {
            args.append("--transfer-report")
        }

        if dualDestEnabled, let secondary = selectedSecondary,
           !destinationIsOnCard(card: card, destPath: secondary.path) {
            args.append(contentsOf: ["--secondary", secondary.path])
        }

        if renameOnIngestEnabled {
            let tmpl = renameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tmpl.isEmpty {
                args.append(contentsOf: ["--rename-template", tmpl])
            }
        }

        // Use Winter Olympics folder layout when enabled, and pass custom code for the middle segment
        if winterOlympicsMode {
            args.append("--winter-olympics")
            let trimmedCode = olympicsCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCode.isEmpty {
                args.append(contentsOf: ["--olympics-code", trimmedCode])
            }
        }

        // Project scaffold — create sibling folders at the project root level
        if scaffoldEnabled {
            let pipeSeparated = scaffoldFolderList.joined(separator: "|")
            if !pipeSeparated.isEmpty {
                args.append(contentsOf: ["--scaffold", pipeSeparated])
            }
        }

        // Include XML sidecars when requested – VIDEO MODE ONLY
        if copyXML && importMode != "photo" {
            args.append("--include-xml")
        }

        if includeProxies {
            args.append("--include-proxies")
        }

        // IMPORTANT: tell the shell script whether we're in video or photo mode
        if importMode == "photo" {
            args.append(contentsOf: ["--mode", "photo"])
        } else {
            args.append(contentsOf: ["--mode", "video"])
        }

        // Ingest order — only pass when non-default so old shell versions ignore it gracefully
        if ingestOrder == "newest" {
            args.append(contentsOf: ["--sort-order", "newest"])
        }

        if dateFolderFormat != "%y%m%d" {
            args.append(contentsOf: ["--date-format", dateFolderFormat])
        }

        if broadcastDayFolders {
            args.append(contentsOf: ["--broadcast-day-hour", "\(dayStartHour)"])
        }

        if finderTagEnabled {
            args.append(contentsOf: ["--finder-tag-color", finderTagColor])
        }

        if showLog { appendLog("=== Starting ingest for card: \(card.name) ===\n") }
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
        if useCustomDest {
            checkpointPrimaryPath = resolvedProjectRoot
            checkpointProjectName = URL(fileURLWithPath: resolvedProjectRoot).lastPathComponent
        } else {
            checkpointPrimaryPath = selectedPrimary?.path ?? ""
            checkpointProjectName = projectName.trimmingCharacters(in: .whitespaces)
        }

        let startSub = (selectedSubfolder == "Default" || selectedSubfolder.isEmpty) ? "clips" : selectedSubfolder
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
            subfolder:        selectedSubfolder == "Default" ? "" : selectedSubfolder,
            cardLabel:        useCustomCardName ? customCardName.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            dateFormat:       dateFolderFormat,
            finderTagColor:   finderTagEnabled ? finderTagColor : "",
            mode:             importMode,
            secondaryPath:    dualDestEnabled ? (selectedSecondary?.path ?? "") : "",
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
    private func runDemoIngest() {
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

        // Turn on auto-ingest visually so the ring lights up
        let wasAutoIngest = autoIngest
        autoIngest = true

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
            self.triggerCompletionFlash()
            AudioEngine.shared.transferComplete()
            // Demo released the engine — start any real cards queued behind it.
            self.drainQueue()
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
                    if !droppedNames.isEmpty {
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
                if self.showLog { self.appendLog("=== Finished ingest for card: \(card.name) ===\n\n") }

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
                if didFail && newFiles > 0 {
                    let mb = Int(Double(ingest.totalBytesNew) / 1_048_576)
                    let rec = FailedIngestRecord(
                        id: UUID(), cardName: card.name,
                        friendlyName: ingest.friendlyName,
                        projectName: self.projectName,
                        failedAt: Date(),
                        filesToCopy: newFiles,
                        mbToCopy: mb > 0 ? mb : 0,
                        reason: "Error"
                    )
                    self.saveFailedRecord(rec)
                } else if statusString == "Completed" {
                    self.clearFailedRecords(friendlyName: ingest.friendlyName, projectName: self.projectName)
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
                    self.triggerCompletionFlash()
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
        } catch {
            appendLog("❌ Failed to run script for card \(card.name): \(error.localizedDescription)\n")
            statusText = "Error starting ingest."
            runningCount = max(0, runningCount - 1)
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
            if debugMode { showLog.toggle() }
        case .openHistory:
            showHistory.toggle()
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

    private func clearFailedRecords(friendlyName: String, projectName: String) {
        let fn = friendlyName.trimmingCharacters(in: .whitespaces).lowercased()
        let pn = projectName.trimmingCharacters(in: .whitespaces).lowercased()
        let before = failedIngestRecords.count
        failedIngestRecords.removeAll {
            $0.friendlyName.lowercased() == fn && $0.projectName.lowercased() == pn
        }
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

    private func updateCurrentPreset() {
        guard let id = activePresetID,
              let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        // General
        presets[idx].importMode             = importMode
        presets[idx].dateFolderFormat       = dateFolderFormat
        presets[idx].ingestOrder            = ingestOrder
        presets[idx].todayOnly              = dateFilterMode == "today"
        presets[idx].dateFilterMode         = dateFilterMode
        presets[idx].dateFilterFrom         = dateFilterFrom
        presets[idx].selectedSubfolder      = selectedSubfolder
        presets[idx].useCustomCardName      = useCustomCardName
        presets[idx].customCardName         = customCardName
        presets[idx].finderTagEnabled       = finderTagEnabled
        presets[idx].finderTagColor         = finderTagColor
        presets[idx].completionAnimationRaw = completionAnimationRaw
        presets[idx].dayStartHour           = dayStartHour
        presets[idx].broadcastDayFolders    = broadcastDayFolders
        // Destination
        presets[idx].useCustomDest          = useCustomDest
        presets[idx].customDestPath         = customDestPath
        // Advanced
        presets[idx].autoEject              = autoEject
        presets[idx].copyXML               = copyXML
        presets[idx].verifyTransfer         = verifyTransfer
        presets[idx].includeProxies         = includeProxies
        // Pro Tools
        presets[idx].dualDestEnabled        = dualDestEnabled
        presets[idx].fullVerifyEnabled      = fullVerifyEnabled
        presets[idx].transferReportEnabled  = transferReportEnabled
        presets[idx].renameOnIngestEnabled  = renameOnIngestEnabled
        presets[idx].renameTemplate         = renameTemplate
        // Scaffold
        presets[idx].scaffoldEnabled        = scaffoldEnabled
        presets[idx].scaffoldFolders        = scaffoldFoldersRaw
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
                    LinearGradient(
                        colors: [Color(hex: "#050912"), Color(hex: "#0a1628"), Color(hex: "#060c1a")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    // Soft radial glow, offset like Apple's — gives the glass depth feel
                    RadialGradient(
                        colors: [Color(hex: "#0eb0e9").opacity(0.18), .clear],
                        center: UnitPoint(x: 0.35, y: 0.42),
                        startRadius: 0,
                        endRadius: geo.size.width * 0.7
                    )
                    RadialGradient(
                        colors: [Color(hex: "#5e3bea").opacity(0.12), .clear],
                        center: UnitPoint(x: 0.72, y: 0.28),
                        startRadius: 0,
                        endRadius: geo.size.width * 0.5
                    )
                }
                .ignoresSafeArea()
                .opacity(bgOpacity)
                .animation(.easeInOut(duration: 0.5), value: bgOpacity)

                // ── "hello." — thin italic, write-on left-to-right ───────────
                Text("hello.")
                    .font(.system(size: 82, weight: .thin, design: .default).italic())
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
                        .font(.custom("Tech Headlines Italic", size: 30))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, Color(hex: "#b8d8ff")],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color(hex: "#0eb0e9").opacity(0.6), radius: 18)

                    Text("A smoother ingest workflow for creators")
                        .font(.custom("DM Sans", size: 14))
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
                .font(.custom("DM Sans", size: 14).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 32).padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(LinearGradient(
                            colors: [color, color.opacity(0.72)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .shadow(color: color.opacity(hovered ? 0.55 : 0.35),
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

    // ── Screen 2 ──────────────────────────────────────────────────────────────
    @AppStorage("pref_primarySSDPath")  private var savedDrivePath:  String = ""
    @AppStorage("pref_projectName")     private var savedProject:    String = ""
    @AppStorage("pref_useCustomDest")   private var ob2UseCustomDest: Bool   = false
    @AppStorage("pref_customDestPath")  private var ob2CustomDestPath: String = ""
    @AppStorage("pref_dateFolderFormat") private var ob2DateFormat:  String = "%y%m%d"
    @State private var availableVolumes: [OnboardingVolume] = []
    @State private var selectedVolume:   OnboardingVolume?  = nil
    @State private var projectInput:     String             = ""
    @State private var showSkipNote:     Bool               = false

    // ── Screen 3 — Scaffold ───────────────────────────────────────────────────
    @AppStorage("pref_scaffoldEnabled")    private var ob3ScaffoldOn:  Bool   = false
    @AppStorage("pref_scaffoldFoldersRaw") private var ob3FoldersRaw: String = "Footage\nAudio\nGraphics\nExports\nAssets\nDocuments"

    // ── Screen 4 — Live demo ──────────────────────────────────────────────────
    @State private var demoStarted:  Bool   = false
    @State private var modalOpacity: Double = 1.0

    // ── Dismiss ───────────────────────────────────────────────────────────────
    @State private var globalOpacity: Double = 1.0

    // ── Palette ───────────────────────────────────────────────────────────────
    private let purple = Color(hex: "#9B5FFF")
    private let blue   = Color(hex: "#0EB0E9")
    private let muted  = Color.white.opacity(0.50)
    private let bgGrad = LinearGradient(
        colors: [Color(hex: "#050912"), Color(hex: "#0a1628"), Color(hex: "#060c1a")],
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
                        RadialGradient(colors: [Color(hex: "#0eb0e9").opacity(0.14), .clear],
                                       center: UnitPoint(x: 0.34, y: 0.42),
                                       startRadius: 0, endRadius: g.size.width * 0.70)
                        RadialGradient(colors: [Color(hex: "#5e3bea").opacity(0.10), .clear],
                                       center: UnitPoint(x: 0.73, y: 0.27),
                                       startRadius: 0, endRadius: g.size.width * 0.50)
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
            if page == 1 { screen1.id("ob1").transition(pageSlide) }
            if page == 2 { screen2.id("ob2").transition(pageSlide) }
            if page == 3 { screen3.id("ob3").transition(pageSlide) }
            if page == 4 { screen4.id("ob4").transition(pageSlide) }
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
                font: .custom("Tech Headlines Italic", size: 28),
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
                font: .custom("DM Sans", size: 14),
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
                .font(.custom("DM Sans", size: 10))
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
                    font: .custom("Tech Headlines Italic", size: 26),
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
                    font: .custom("DM Sans", size: 13),
                    delay: 0.80,
                    foreground: AnyShapeStyle(Color.white.opacity(0.50))
                )
                .padding(.horizontal, 52)
                .padding(.top, 14)

                // ── SSD / Custom Folder toggle ─────────────────────────────
                HStack(spacing: 0) {
                    ob2PillTab(label: "SSD", isActive: !ob2UseCustomDest) {
                        withAnimation(.easeInOut(duration: 0.22)) { ob2UseCustomDest = false }
                    }
                    ob2PillTab(label: "Custom Folder", isActive: ob2UseCustomDest) {
                        withAnimation(.easeInOut(duration: 0.22)) { ob2UseCustomDest = true }
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
                                    .font(.custom("DM Sans", size: 12))
                                    .foregroundStyle(Color.white.opacity(0.35))
                                    .multilineTextAlignment(.center)
                                Button {
                                    loadVolumes()
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                                        Text("Refresh").font(.custom("DM Sans", size: 12).weight(.medium))
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
                            .font(.custom("DM Sans", size: 11).weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.48))

                        HStack(spacing: 0) {
                            TextField("e.g. MyProject_2026", text: $projectInput)
                                .textFieldStyle(.plain)
                                .font(.custom("DM Sans", size: 13))
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
                                    .font(.custom("DM Sans", size: 11).weight(.medium))
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
                                    .font(.custom("DM Sans", size: 13).weight(.medium))
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
                                    .font(.custom("DM Sans", size: 11))
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
                    Text("Your footage will land in a date folder — e.g. \(Text("`\(exampleDate)`").font(.custom("DM Mono", size: 11)).foregroundStyle(Color(hex: "#0eb0e9").opacity(0.85))). The format is customizable in Settings.")
                        .font(.custom("DM Sans", size: 11))
                        .foregroundStyle(Color.white.opacity(0.38))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 44)
                .padding(.top, 20)

                // Skip note
                if showSkipNote {
                    Text("You can set this up in the app anytime.")
                        .font(.custom("DM Sans", size: 11))
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
                            .font(.custom("DM Sans", size: 13).weight(.medium))
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
                .font(.custom("DM Sans", size: 12).weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .white : Color.white.opacity(0.42))
                .padding(.horizontal, 20).padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(isActive ? purple.opacity(0.85) : Color.clear)
                )
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
                    .font(.custom("DM Sans", size: 13).weight(.semibold))
                    .foregroundStyle(isSelected ? .white : Color.white.opacity(0.72))
                if vol.freeGB > 0 {
                    Text(vol.freeLabel)
                        .font(.custom("DM Sans", size: 11))
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
    // MARK: Screen 3 — Project scaffold
    // ─────────────────────────────────────────────────────────────────────────
    private var screen3: some View {
        let folders = ob3FoldersRaw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                logoMark

                // Badge
                Text("Project scaffold")
                    .font(.custom("DM Sans", size: 11).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(purple.opacity(0.88)))

                // Headline
                OnboardingReveal(
                    "Folders, ready before\nyou even hit ingest.",
                    font: .custom("Tech Headlines Italic", size: 26),
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
                    font: .custom("DM Sans", size: 13),
                    delay: 0.55,
                    foreground: AnyShapeStyle(Color.white.opacity(0.50))
                )
                .multilineTextAlignment(.center)

                // ── Folder tree preview ──────────────────────────────────
                VStack(alignment: .leading, spacing: 0) {
                    // Project root row
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(purple)
                        Text("20260522_Project Name")
                            .font(.custom("DM Sans", size: 12).weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.80))
                    }
                    .padding(.bottom, 6)

                    // Child folder rows
                    ForEach(Array(folders.enumerated()), id: \.offset) { idx, folder in
                        let isLast = idx == folders.count - 1
                        HStack(alignment: .top, spacing: 0) {
                            // Tree branch line
                            VStack(spacing: 0) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(width: 1)
                                    .frame(maxHeight: .infinity)
                                if isLast { Color.clear.frame(height: 10) }
                            }
                            .frame(width: 1, height: 28)
                            .padding(.leading, 6)

                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 12, height: 1)
                                .padding(.top, 13)
                                .padding(.leading, 0)

                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(hex: "#60a5fa").opacity(0.80))
                                Text(folder)
                                    .font(.custom("DM Sans", size: 12))
                                    .foregroundStyle(Color.white.opacity(0.65))
                            }
                            .padding(.leading, 6)
                            .frame(height: 28)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.09), lineWidth: 1))
                )

                // ── Enable toggle ────────────────────────────────────────
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable project scaffold")
                            .font(.custom("DM Sans", size: 13).weight(.medium))
                            .foregroundStyle(.white)
                        Text("You can customise the folders anytime in Settings.")
                            .font(.custom("DM Sans", size: 11))
                            .foregroundStyle(Color.white.opacity(0.38))
                    }
                    Spacer()
                    Toggle("", isOn: $ob3ScaffoldOn)
                        .toggleStyle(.switch)
                        .tint(purple)
                        .labelsHidden()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(ob3ScaffoldOn ? purple.opacity(0.12) : Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(ob3ScaffoldOn ? purple.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1))
                )
                .animation(.easeInOut(duration: 0.20), value: ob3ScaffoldOn)

                // ── CTAs ─────────────────────────────────────────────────
                OnboardingButton("Next  →", color: purple) {
                    withAnimation(.easeInOut(duration: 0.46)) { page = 4 }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.46)) { page = 4 }
                } label: {
                    Text("Skip")
                        .font(.custom("DM Sans", size: 12))
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
                        .font(.custom("DM Sans", size: 11).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(purple.opacity(0.88)))

                    // Headline
                    OnboardingReveal(
                        "Watch what happens\nwhen a card comes in.",
                        font: .custom("Tech Headlines Italic", size: 24),
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
                            font: .custom("DM Sans", size: 13),
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
                            .font(.custom("DM Sans", size: 12))
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
                            font: .custom("DM Sans", size: 14).weight(.medium),
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
                                .font(.custom("DM Sans", size: 12))
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
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color(hex: "#07101f").opacity(0.90))
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(LinearGradient(
                                    colors: [blue.opacity(0.38), purple.opacity(0.38)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ), lineWidth: 1)
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
                .font(.custom("DM Sans", size: 13).weight(.semibold))
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
                    .font(.custom("DM Sans", size: 13).weight(.semibold))
                    .foregroundStyle(textPrimary)
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 10))
                    Text("\(primaryName)/")
                        .font(.custom("DM Sans", size: 11))
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
                    .font(.custom("DM Sans", size: 10).weight(.medium))
                    .foregroundStyle(textSecondary)
                    .textCase(.uppercase)
                    .kerning(0.5)

                TextField("e.g. ClientShoot", text: $name)
                    .textFieldStyle(.plain)
                    .font(.custom("DM Sans", size: 13))
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
                    .font(.custom("DM Sans", size: 10).weight(.medium))
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
                            .font(.custom("DM Sans", size: 10).weight(.medium))
                    }
                    .foregroundStyle(accent.opacity(0.9))

                    let displayed = scaffoldFolders.prefix(8)
                    FlowLayout(spacing: 4) {
                        ForEach(Array(displayed.enumerated()), id: \.offset) { _, folder in
                            Text(folder)
                                .font(.custom("DM Sans", size: 10).weight(.medium))
                                .foregroundStyle(textSecondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(surface)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        if scaffoldFolders.count > 8 {
                            Text("+\(scaffoldFolders.count - 8) more")
                                .font(.custom("DM Sans", size: 10))
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
                            .font(.custom("DM Sans", size: 10))
                            .foregroundStyle(textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Open Settings → Advanced") {
                            hintShown = true
                            onOpenSettings()
                        }
                        .font(.custom("DM Sans", size: 10).weight(.semibold))
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
                .font(.custom("DM Sans", size: 12))
                .foregroundStyle(textSecondary)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(surface)
                .clipShape(RoundedRectangle(cornerRadius: 7))

                Button("Create Folder") {
                    onCreate()
                }
                .font(.custom("DM Sans", size: 12).weight(.semibold))
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

    @AppStorage("pref_useLightMode") private var useLightMode: Bool = false

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
                        .font(.custom("DM Sans", size: 14))
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
                                    .font(.custom("DM Sans", size: 12).weight(.semibold))
                                    .foregroundStyle(textPrimary)
                                Text("We've moved our store. Please enter the new key from your purchase email or dashboard.")
                                    .font(.custom("DM Sans", size: 11))
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
                                .font(.custom("DM Sans", size: 14).weight(.semibold))
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
                        .font(.custom("DM Sans", size: 13))
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
// invisible legacy body (still mounted under CR_V3_PREVIEW) does all detection / copying /
// history / sheets. This is purely presentation.

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
    private var v3DoneCount: Int { activeIngests.values.filter { $0.phase == .done }.count }
    private var v3CopyingCount: Int { activeIngests.values.filter { [.copying, .scanning, .building].contains($0.phase) }.count }
    private var v3FinalizingCount: Int { activeIngests.values.filter { [.finalizing, .verifying].contains($0.phase) }.count }
    private var v3AllDone: Bool { !activeIngests.isEmpty && runningCount == 0 && activeIngests.values.allSatisfy { $0.phase == .done || $0.phase == .failed } }

    private func v3LanePct(_ ing: ActiveIngest) -> Double {
        ing.totalBytesNew > 0 ? min(100, Double(ing.doneBytes) / Double(ing.totalBytesNew) * 100) : 0
    }
    private func v3Status(_ ing: ActiveIngest) -> (String, Color) {
        switch ing.phase {
        case .copying:                   return ("\(Int(v3LanePct(ing)))%", v3Cyan)
        case .scanning, .building, .idle: return ("STARTING", v3Cyan)
        case .finalizing:                return ("FINALIZING", v3Amber)
        case .verifying:                 return ("VERIFYING", v3Green)
        case .done:                      return ("SAFE", v3Green)
        case .failed:                    return ("FAILED", v3Red)
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
    private func v3FreeSpace(_ path: String) -> String {
        if let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let b = v.volumeAvailableCapacity {
            return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) + " free"
        }
        return "—"
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
                HStack(alignment: .top, spacing: 24) {
                    v3Sources.frame(maxWidth: .infinity, alignment: .leading)
                    v3Ring.frame(width: 360)
                    v3Destinations.frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(maxHeight: .infinity)
                .coordinateSpace(name: "stage")
                .backgroundPreferenceValue(V3AnchorKey.self) { anchors in
                    GeometryReader { geo in
                        let rects = anchors.mapValues { geo[$0] }
                        TimelineView(.animation) { tl in
                            Canvas { ctx, _ in
                                let phase = CGFloat(tl.date.timeIntervalSinceReferenceDate
                                    .truncatingRemainder(dividingBy: 0.7)) / 0.7 * 14
                                v3DrawFunnel(&ctx, rects: rects, phase: phase)
                            }
                        }
                    }
                }
                v3BottomBar
            }
            .padding(26)
        }
        .frame(minWidth: 1200, minHeight: 780)
        .preferredColorScheme(.dark)
    }

    /// Animated neon connectors: each active lane → ring, and ring → destination.
    private func v3DrawFunnel(_ ctx: inout GraphicsContext, rects: [String: CGRect], phase: CGFloat) {
        guard let ring = rects["ring"], v3ActiveLanes.count <= 6 else { return }
        let rc = CGPoint(x: ring.midX, y: ring.midY)
        let rad = ring.width / 2
        let leftPort = CGPoint(x: rc.x - rad, y: rc.y)
        let rightPort = CGPoint(x: rc.x + rad, y: rc.y)
        let dash = StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 9], dashPhase: -phase)
        for item in v3ActiveLanes {
            guard let lr = rects["lane-\(item.id)"] else { continue }
            let from = CGPoint(x: lr.maxX, y: lr.midY)
            var p = Path(); p.move(to: from)
            p.addCurve(to: leftPort,
                       control1: CGPoint(x: (from.x + leftPort.x) / 2, y: from.y),
                       control2: CGPoint(x: (from.x + leftPort.x) / 2, y: leftPort.y))
            let col: Color = item.ing.phase == .failed ? v3Red : v3Mag
            ctx.stroke(p, with: .color(col.opacity(0.6)), style: dash)
        }
        if let dr = rects["dest-default"] {
            let to = CGPoint(x: dr.minX, y: dr.midY)
            var p = Path(); p.move(to: rightPort)
            p.addCurve(to: to,
                       control1: CGPoint(x: (rightPort.x + to.x) / 2, y: rightPort.y),
                       control2: CGPoint(x: (rightPort.x + to.x) / 2, y: to.y))
            let col = v3FailedCount > 0 ? v3Amber : v3AllDone ? v3Green : v3Cyan
            ctx.stroke(p, with: .color(col.opacity(0.6)), style: dash)
        }
    }

    private var v3Background: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#0c0822"), Color(hex: "#080615"), Color(hex: "#050310")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(hex: "#7c3aed").opacity(0.20), .clear], center: .init(x: 0.22, y: 0.08), startRadius: 0, endRadius: 760)
            RadialGradient(colors: [Color(hex: "#0dcff5").opacity(0.13), .clear], center: .init(x: 0.84, y: 0.92), startRadius: 0, endRadius: 640)
        }.ignoresSafeArea()
    }

    // MARK: Top bar
    private var v3TopBar: some View {
        HStack {
            Button { v3Post(.menuOpenSettings) } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.white.opacity(0.7)).frame(width: 32, height: 32)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.10)))
            }.buttonStyle(.plain)
            Spacer()
            VStack(spacing: 2) {
                Text("CARDRUNNER").font(.custom("Tech Headlines Italic", size: 24)).foregroundStyle(v3Brand)
                Text("Plug a card — it copies, instantly & safely").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(autoIngest ? v3Green : v3Amber).frame(width: 7, height: 7)
                Text("Auto-Ingest \(autoIngest ? "On" : "Off")").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8)
            .background(.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder((autoIngest ? v3Green : v3Amber).opacity(0.35)))
            .contentShape(Capsule())
            .onTapGesture { autoIngest.toggle() }   // fires the real onChange(of: autoIngest)
        }
    }

    // MARK: Sources (real lanes)
    private var v3Sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SOURCES").font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.4))
            if v3Lanes.isEmpty {
                Text(autoIngest ? "Waiting for a card…" : "Auto-ingest is off")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                    .frame(width: 360, alignment: .leading).padding(.vertical, 8)
            }
            ForEach(v3ActiveLanes, id: \.id) { item in v3Lane(item.id, item.ing) }
            if !v3DoneLanes.isEmpty { v3DonePile }
            Spacer(minLength: 0)
        }
    }

    private func v3Lane(_ id: UUID, _ ing: ActiveIngest) -> some View {
        let (badge, col) = v3Status(ing)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sdcard.fill").font(.system(size: 18)).foregroundStyle(col)
                    .frame(width: 32, height: 32).background(col.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(ing.cardName.isEmpty ? "Card" : ing.cardName).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    HStack(spacing: 5) {
                        Text(ing.cameraModel.isEmpty ? "Camera" : ing.cameraModel)
                        Text("·  → \(v3DestDriveName)").foregroundStyle(.white.opacity(0.35))
                    }
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                Text(badge).font(.system(size: 11, weight: .bold)).foregroundStyle(col)
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

    /// Collapsed "N cards safe to pull" pile (matches the design's green ready strip).
    private var v3DonePile: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(v3Green.opacity(0.18)).frame(width: 30, height: 30)
                Text("\(v3DoneLanes.count)").font(.system(size: 13, weight: .bold)).foregroundStyle(v3Green)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(v3DoneLanes.count) card\(v3DoneLanes.count == 1 ? "" : "s") safe to pull")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text("Eject when ready").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Button { v3Post(.menuEjectCard) } label: {
                VStack(spacing: 2) {
                    Image(systemName: "eject").font(.system(size: 13)).foregroundStyle(v3Green)
                    Text("All").font(.system(size: 9, weight: .semibold)).foregroundStyle(v3Green)
                }
                .frame(width: 44, height: 44)
                .background(v3Green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(v3Green.opacity(0.4)))
            }.buttonStyle(.plain)
        }
        .padding(12).frame(width: 360)
        .background(v3Green.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(v3Green.opacity(0.25)))
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
                Text(String(format: "%.0f MB/s", max(0, ing.liveMBps)))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            }
        case .finalizing:
            HStack(spacing: 7) { ProgressView().controlSize(.small)
                Text("Flushing to disk — keep card inserted").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)) }
        case .verifying:
            HStack(spacing: 7) { ProgressView().controlSize(.small).tint(v3Green)
                Text("Verifying checksums…").font(.system(size: 11)).foregroundStyle(v3Green.opacity(0.9)) }
        case .done:
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
        case .failed:
            Text("Transfer failed — card kept mounted, re-insert to retry")
                .font(.system(size: 11)).foregroundStyle(v3Red)
        }
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
            HStack(spacing: 7) {
                Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(v3Amber)
                Text(runningCount > 0 ? "Engine running · Auto Ingest \(autoIngest ? "ON" : "OFF")"
                     : autoIngest ? "Auto-Ingest ON · ready for the next card" : "Auto-Ingest off")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(v3Purple.opacity(0.18), in: Capsule()).overlay(Capsule().strokeBorder(v3Purple.opacity(0.4)))
            if v3DestRoot.isEmpty && v3AnyActive {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text("No destination — choose a folder to start").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(v3Amber).padding(.horizontal, 16).padding(.vertical, 10)
                .background(v3Amber.opacity(0.12), in: Capsule()).overlay(Capsule().strokeBorder(v3Amber.opacity(0.4)))
            }
            if v3AllDone || (!v3DestRoot.isEmpty && !v3AnyActive) {
                Button { v3Post(.menuOpenDestination) } label: {
                    HStack(spacing: 7) { Image(systemName: "folder"); Text("Open in Finder") }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.white.opacity(0.05), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
    private var v3RingStroke: AnyShapeStyle {
        if v3FailedCount > 0 { return AnyShapeStyle(v3Amber) }
        if v3AllDone { return AnyShapeStyle(v3Green) }
        return AnyShapeStyle(v3Brand)
    }
    @ViewBuilder private var v3RingCenter: some View {
        if !v3AnyActive {
            VStack(spacing: 6) {
                Text("Ready for cards").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                Text(autoIngest ? "Auto-ingest armed" : "Auto-ingest off").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
        } else if v3FailedCount > 0 {
            VStack(spacing: 6) {
                Text("\(v3FailedCount)").font(.system(size: 40, weight: .bold)).foregroundStyle(v3Amber)
                Text("needs attention").font(.system(size: 13)).foregroundStyle(v3Amber)
            }
        } else if v3AllDone {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle").font(.system(size: 34)).foregroundStyle(v3Green)
                Text("All safe to pull").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                Text("\(v3DoneCount) card\(v3DoneCount == 1 ? "" : "s") ready").font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
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

    // MARK: Destinations (DEFAULT DESTINATION golden box — bound to the real primary dest)
    private var v3Destinations: some View {
        VStack(alignment: .trailing, spacing: 14) {
            Text("DESTINATIONS").font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.4))
            v3DefaultDestBox
            Spacer(minLength: 0)
        }
    }

    private var v3DefaultDestBox: some View {
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
                    HStack(spacing: 6) {
                        Text(unset ? "No destination" : v3DestDriveName)
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(unset ? v3Amber : .white)
                        if !unset {
                            Text("DEFAULT").font(.system(size: 9, weight: .bold)).foregroundStyle(v3Amber)
                                .padding(.horizontal, 7).padding(.vertical, 3).background(v3Amber.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(unset ? "Open the picker to choose a drive & folder" : v3FreeSpace(v3DestDrivePath))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    if !unset {
                        Text(URL(fileURLWithPath: v3DestRoot).lastPathComponent + "  ·  default target")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer()
                if runningCount > 0 && !unset {
                    Text(v3SpeedText(v3CombinedMBps)).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(v3Cyan)
                }
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
        let lead = v3Summary.isEmpty ? (autoIngest ? "Ready" : "Auto-ingest off") : v3Summary
        let speed = runningCount > 0 ? "  ·  \(v3SpeedText(v3CombinedMBps)) combined" : ""
        let dest = v3DestRoot.isEmpty ? "no destination" : "default \(v3DestDriveName)"
        return "\(lead)\(speed)  ·  \(dest)"
    }
    private var v3BottomBar: some View {
        HStack(spacing: 10) {
            Text(v3BottomStatus).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            Spacer()
            if runningCount > 0 {
                v3Chip("Stop", "stop.circle", v3Red) { v3Post(.menuStopTransfer) }
            }
            v3Chip("New project folder", "folder.badge.plus", v3Purple) { v3Post(.menuOpenSettings) }
            v3Chip("Today only", "calendar", dateFilterMode == "today" ? v3Cyan : .white.opacity(0.6)) {
                dateFilterMode = dateFilterMode == "today" ? "all" : "today"
            }
            v3Chip("Auto-eject  \(autoEject ? "On" : "Off")", "eject", autoEject ? v3Green : .white.opacity(0.6)) { autoEject.toggle() }
            Button { v3ChooseDestination() } label: {
                HStack(spacing: 6) { Image(systemName: "plus"); Text("Add destination") }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9).background(v3Brand, in: Capsule())
            }.buttonStyle(.plain)
        }
    }
    private func v3Chip(_ t: String, _ icon: String, _ color: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) { Image(systemName: icon); Text(t) }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(color)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.white.opacity(0.04), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.10)))
        }.buttonStyle(.plain)
    }
}

// MARK: - v3 funnel anchor key (sources → ring → destinations connectors)

struct V3AnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}
