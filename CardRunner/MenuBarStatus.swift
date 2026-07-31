import SwiftUI
import Observation

// MARK: - Shared status center
//
// The rich live progress state (activeIngests / runningCount / MB/s / ETA) lives
// as inline @State on the giant ContentView struct — it is NOT observable from a
// separate scene. Rather than restructure ContentView (owned elsewhere), the
// menu-bar item reads from this tiny shared singleton, and ContentView publishes
// a snapshot into it from its existing progress plumbing.
//
// ┌─────────────────────────────────────────────────────────────────────────┐
// │  MERGE HOOK (one line, added by the ContentView owner):                  │
// │                                                                          │
// │  Inside ContentView, wherever `activeIngests` / `runningCount` change    │
// │  (e.g. the end of the poll/parse handler that already recomputes lanes,  │
// │  and in the ingest-completion handler), call:                            │
// │                                                                          │
// │      IngestStatusCenter.shared.publish(active: activeIngests,            │
// │                                        runningCount: runningCount,       │
// │                                        sessionDone: sessionCardCount)    │
// │                                                                          │
// │  `publish(active:...)` maps [UUID: ActiveIngest] → menu-bar rows and     │
// │  hops to the main actor, so it is safe to call from anywhere. Until      │
// │  that line is wired in, the menu bar correctly shows the idle state.     │
// └─────────────────────────────────────────────────────────────────────────┘

/// One card's worth of menu-bar-facing status. Deliberately a flat value type so
/// nothing about ContentView's internals leaks into the scene.
struct MenuBarCardStatus: Identifiable {
    let id: UUID
    var cardName: String
    var phaseText: String
    var symbol: String        // SF Symbol name for the row
    /// 0…1 copy progress, or nil when a fraction is not meaningful (scanning, done).
    var progress: Double?
    var mbps: Double
    var etaText: String?
    var isTerminal: Bool      // done or failed
}

/// Small shared observable the menu bar renders. Populated by ContentView via
/// `publish(...)`; safe to read from the MenuBarExtra scene.
@MainActor
@Observable
final class IngestStatusCenter {
    static let shared = IngestStatusCenter()
    private init() {}

    private(set) var cards: [MenuBarCardStatus] = []
    private(set) var runningCount: Int = 0
    private(set) var sessionDone: Int = 0
    private(set) var lastUpdate: Date = .distantPast

    /// True while any card is mid-flight (not terminal).
    var isBusy: Bool { runningCount > 0 || cards.contains { !$0.isTerminal } }

    var activeCards: [MenuBarCardStatus] { cards.filter { !$0.isTerminal } }

    /// Compact menu-bar title, e.g. "▶ 1 · ✓ 2" while busy, or "" (icon only) when idle.
    var titleText: String {
        guard isBusy else { return "" }
        let running = max(runningCount, activeCards.count)
        return "▶ \(running)  ✓ \(sessionDone)"
    }

    // MARK: Publish entry points

    /// Primary hook for ContentView. Maps live ingest state into flat rows and
    /// stores it. Accepts the exact types ContentView already holds.
    nonisolated func publish(active: [UUID: ActiveIngest],
                             runningCount: Int,
                             sessionDone: Int) {
        let rows = active
            .sorted { $0.value.ingestStartTime < $1.value.ingestStartTime }
            .map { (id, ing) -> MenuBarCardStatus in
                Self.row(id: id, ing: ing)
            }
        Task { @MainActor in
            self.cards = rows
            self.runningCount = runningCount
            self.sessionDone = sessionDone
            self.lastUpdate = Date()
        }
    }

    /// Clears live state back to idle (e.g. when a session ends). Optional.
    nonisolated func clearActive(sessionDone: Int) {
        Task { @MainActor in
            self.cards.removeAll()
            self.runningCount = 0
            self.sessionDone = sessionDone
            self.lastUpdate = Date()
        }
    }

    // MARK: Mapping

    nonisolated private static func row(id: UUID, ing: ActiveIngest) -> MenuBarCardStatus {
        let name = ing.cardName.isEmpty ? "Card" : ing.cardName

        let progress: Double?
        if ing.phase == .copying, ing.totalBytesNew > 0 {
            progress = min(1, max(0, Double(ing.doneBytes) / Double(ing.totalBytesNew)))
        } else if ing.phase == .verifying, ing.verifyTotal > 0 {
            progress = min(1, Double(ing.verifyChecked) / Double(ing.verifyTotal))
        } else {
            progress = nil
        }

        let symbol: String
        switch ing.phase {
        case .idle, .scanning, .building: symbol = "magnifyingglass"
        case .copying:                    symbol = "arrow.down.circle"
        case .verifying:                  symbol = "checkmark.shield"
        case .finalizing:                 symbol = "externaldrive.badge.checkmark"
        case .done:                       symbol = "checkmark.circle.fill"
        case .failed:                     symbol = "exclamationmark.triangle.fill"
        }

        // ETA from remaining bytes ÷ live speed (only meaningful mid-copy).
        var etaText: String? = nil
        if ing.phase == .copying, ing.liveMBps > 0.1, ing.totalBytesNew > 0 {
            let remaining = Double(ing.totalBytesNew - ing.doneBytes)
            let secs = remaining / (ing.liveMBps * 1_000_000)
            if secs.isFinite, secs >= 0 { etaText = Self.formatETA(secs) }
        }

        return MenuBarCardStatus(
            id: id,
            cardName: name,
            phaseText: ing.phase.displayText,
            symbol: symbol,
            progress: progress,
            mbps: ing.liveMBps,
            etaText: etaText,
            isTerminal: ing.phase == .done || ing.phase == .failed)
    }

    nonisolated private static func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60, r = s % 60
        if m < 60 { return r == 0 ? "\(m)m" : "\(m)m \(r)s" }
        let h = m / 60, mr = m % 60
        return "\(h)h \(mr)m"
    }
}

// MARK: - Menu-bar label (the item shown in the system menu bar)

struct MenuBarStatusLabel: View {
    var status: IngestStatusCenter

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.isBusy
                  ? "square.stack.3d.up.fill"
                  : "square.stack.3d.up")
            if !status.titleText.isEmpty {
                Text(status.titleText)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
        }
    }
}

// MARK: - Dropdown content

struct MenuBarStatusView: View {
    var status: IngestStatusCenter
    /// Brings the main window forward. Injected so the scene owns the AppKit poke.
    var showWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider().overlay(Color.white.opacity(0.08))

            if status.activeCards.isEmpty {
                idleRow
            } else {
                ForEach(status.activeCards) { card in
                    cardRow(card)
                }
            }

            Divider().overlay(Color.white.opacity(0.08))

            Button(action: showWindow) {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow")
                    Text("Show Main Window")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)

            Button(action: { NSApp.terminate(nil) }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                    Text("Quit CardRunner")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 288)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: status.isBusy
                  ? "square.stack.3d.up.fill"
                  : "square.stack.3d.up")
                .foregroundStyle(status.isBusy ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("CardRunner")
                    .font(.system(size: 13, weight: .semibold))
                Text(status.isBusy
                     ? "\(status.activeCards.count) card\(status.activeCards.count == 1 ? "" : "s") in flight"
                     : "Idle — no active ingests")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if status.sessionDone > 0 {
                Label("\(status.sessionDone)", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.green)
            }
        }
    }

    private var idleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
            Text("Insert a card to begin an offload.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func cardRow(_ card: MenuBarCardStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: card.symbol)
                    .foregroundStyle(card.symbol.contains("triangle")
                                     ? Color.orange : Color.accentColor)
                    .frame(width: 16)
                Text(card.cardName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if let p = card.progress {
                    Text("\(Int(p * 100))%")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let p = card.progress {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }

            HStack(spacing: 6) {
                Text(card.phaseText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if card.mbps > 0.1 {
                    Text("\(String(format: "%.0f", card.mbps)) MB/s")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let eta = card.etaText {
                    Text("· \(eta)")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
