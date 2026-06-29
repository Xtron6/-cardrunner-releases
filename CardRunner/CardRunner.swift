import SwiftUI
import Sparkle

// MARK: - Notification names

extension Notification.Name {
    // Existing
    static let showShortcutsHelp    = Notification.Name("cardrunner.showShortcutsHelp")

    // Menu → ContentView
    static let menuOpenSettings     = Notification.Name("cardrunner.menu.openSettings")
    static let menuReportIssue      = Notification.Name("cardrunner.menu.reportIssue")
    static let menuStartIngest      = Notification.Name("cardrunner.menu.startIngest")
    static let menuStopTransfer     = Notification.Name("cardrunner.menu.stopTransfer")
    static let menuOpenDestination  = Notification.Name("cardrunner.menu.openDestination")
    static let menuOpenLastFolder   = Notification.Name("cardrunner.menu.openLastFolder")
    static let menuEjectCard        = Notification.Name("cardrunner.menu.ejectCard")
    static let menuToggleAutoIngest = Notification.Name("cardrunner.menu.toggleAutoIngest")
    static let menuVideoMode        = Notification.Name("cardrunner.menu.videoMode")
    static let menuPhotoMode        = Notification.Name("cardrunner.menu.photoMode")
    static let menuToggleHistory    = Notification.Name("cardrunner.menu.toggleHistory")
    static let menuToggleLog        = Notification.Name("cardrunner.menu.toggleLog")
    static let menuToggleDarkMode   = Notification.Name("cardrunner.menu.toggleDarkMode")
    static let menuViewLogFiles     = Notification.Name("cardrunner.menu.viewLogFiles")
}

// MARK: - Menu commands

private struct CardRunnerCommands: Commands {
    var updaterController: SPUStandardUpdaterController
    /// Only show the Debug menu in the v3 preview (keeps the shipping menu clean).
    var showDebugMenu: Bool = false
    /// Shared with CardRunnerV3View via UserDefaults — toggling here shows/hides the testing strip.
    @AppStorage("pref_v3ShowDebugTools") private var showDebugTools = false

    var body: some Commands {

        // ── Debug (v3 preview only) ──────────────────────────────────────────
        if showDebugMenu {
            CommandMenu("Debug") {
                Toggle("Show Testing Tools", isOn: $showDebugTools)
                    .keyboardShortcut("t", modifiers: [.command, .option])
            }
        }


        // ── App menu — replace default Preferences with our Settings sheet ──
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                post(.menuOpenSettings)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        // ── App menu — Check for Updates (after About) ───────────────────────
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updaterController.checkForUpdates(nil)
            }
        }

        // ── File ─────────────────────────────────────────────────────────────
        // Replaces the default "New / Open" group at the top of the File menu.
        CommandGroup(replacing: .newItem) {

            // Primary action
            Button("Start Ingest") {
                post(.menuStartIngest)
            }
            .keyboardShortcut(.return, modifiers: .command)

            Button("Stop Transfer") {
                post(.menuStopTransfer)
            }
            .keyboardShortcut(".", modifiers: .command)

            Divider()

            // Second path to the settings panel (user-requested)
            Button("Settings…") {
                post(.menuOpenSettings)
            }

            Divider()

            // Post-ingest navigation
            Button("Open Destination in Finder") {
                post(.menuOpenDestination)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Open Last Ingested Folder") {
                post(.menuOpenLastFolder)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            Button("Eject Card") {
                post(.menuEjectCard)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        // ── View ─────────────────────────────────────────────────────────────
        CommandMenu("View") {

            Button("Video Mode") {
                post(.menuVideoMode)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Photo Mode") {
                post(.menuPhotoMode)
            }
            .keyboardShortcut("2", modifiers: .command)

            Divider()

            Button("Toggle Auto Ingest") {
                post(.menuToggleAutoIngest)
            }
            .keyboardShortcut("a", modifiers: [.command, .option])

            Divider()

            Button("Show History") {
                post(.menuToggleHistory)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button("Show Log") {
                post(.menuToggleLog)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Divider()

            Button("Toggle Dark / Light Mode") {
                post(.menuToggleDarkMode)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        // ── Help ─────────────────────────────────────────────────────────────
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts…") {
                post(.showShortcutsHelp)
            }
            .keyboardShortcut("/", modifiers: .command)

            Divider()

            Button("Report an Issue…") {
                post(.menuReportIssue)
            }

            Button("View Log Files") {
                post(.menuViewLogFiles)
            }
        }
    }

    // Convenience so every action reads identically.
    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

// MARK: - Bundle helpers

private extension Bundle {
    /// "1.0 (3)" — version + build number for display in alerts.
    var appVersionString: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build   = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - App entry point

@main
struct CardRunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            // CR_V3_DEMO=1  → pure-sim node dashboard (CardRunnerV3View) for previewing the design.
            // CR_V3_PREVIEW=1 → real-engine v3 face (handled inside ContentView.body).
            // neither        → the shipping legacy UI.
            if ProcessInfo.processInfo.environment["CR_V3_DEMO"] == "1" {
                CardRunnerV3View()
            } else {
                ContentView()
            }
        }
        .defaultSize(width: 1200, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.automatic)
        .commands {
            CardRunnerCommands(
                updaterController: appDelegate.updaterController,
                showDebugMenu: ProcessInfo.processInfo.environment["CR_V3_PREVIEW"] == "1")
        }
    }
}
