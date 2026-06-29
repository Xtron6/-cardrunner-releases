//
//  V3Model.swift — PURE-SIM demo view-model for previewing the v3 node dashboard.
//
//  No engine, no real I/O. Drives a fake multi-card / multi-destination workflow (plug, copy,
//  finalize, verify, done, route, split/mirror, pull) so the FULL target design can be evaluated
//  and validated without hardware. Shown via the CR_V3_DEMO=1 launch flag. Completely separate
//  from the real-engine dashboard (ContentView.bodyV3, CR_V3_PREVIEW=1).
//

import SwiftUI
import Combine

enum CardType { case cfx, sd
    var media: String { self == .cfx ? "CFexpress" : "SD UHS-II" }
}

enum CardStatus: String {
    case detected, awaiting, blocked, copying, finalizing, verifying, done, error
    var isActive: Bool { [.detected, .copying, .finalizing, .verifying].contains(self) }
}

enum RoutingMode { case split, mirror }
enum DestRole { case primary, mirror, target }

struct V3Card: Identifiable {
    let id: Int
    var name: String
    var type: CardType
    var sizeGB: Double
    var reel: String
    var status: CardStatus
    var pct: Double = 0
    var destId: Int?
    var accent: Color
    var t0: Date = Date()
    var media: String { reel.isEmpty ? type.media : "\(type.media) · \(reel)" }
}

struct V3Dest: Identifiable {
    let id: Int
    var name: String
    var free: String
    var role: DestRole
    var folder: String? = nil
}

@MainActor
final class V3Model: ObservableObject {
    @Published var cards: [V3Card] = []
    @Published var dests: [V3Dest] = [V3Dest(id: 1, name: "Samsung T7", free: "1.8 TB free", role: .primary)]
    @Published var mode: RoutingMode = .split
    @Published var verify = true
    @Published var autoEject = false
    @Published var autoIngest = true
    @Published var todayOnly = true
    @Published var defaultDestId = 1
    @Published var toast: String? = nil
    @Published var projectName = "260629_Project"
    @Published var projectColorIndex = 5

    let folderColors: [Color] = [Color(hex: "#f87171"), Color(hex: "#fb923c"), Color(hex: "#fbbf24"),
                                 Color(hex: "#34d399"), Color(hex: "#5b8def"), Color(hex: "#c084fc"), Color(hex: "#9ca3af")]
    var scaffold = ["Footage", "Audio", "Graphics", "Exports", "Assets", "Documents"]

    private let CAP: Double = 1000
    private let MAXCARDS = 10
    private let MAXDESTS = 4
    private let palette: [Color] = [Color(hex: "#22d3ee"), Color(hex: "#b388ff"), Color(hex: "#ff5cdd"),
                                    Color(hex: "#34d399"), Color(hex: "#fbbf24"), Color(hex: "#5b8def"),
                                    Color(hex: "#fb7185"), Color(hex: "#a78bfa")]
    private let cardPool: [(String, CardType, Double)] = [
        ("RED KOMODO", .cfx, 512), ("SONY FX6", .sd, 256), ("CANON R5 C", .cfx, 1024),
        ("ARRI ALEXA 35", .cfx, 512), ("SONY A7S III", .sd, 256), ("BMPCC 6K", .cfx, 512),
        ("NIKON Z9", .sd, 128), ("PANASONIC S1H", .sd, 256),
    ]
    private let destPool: [(String, String)] = [
        ("OWC Envoy Pro", "3.7 TB free"), ("G-DRIVE Pro", "920 GB free"), ("RAID Tower", "12 TB free"),
    ]

    private var idSeq = 0
    private var reelSeq = 2
    private var destSeq = 1
    private var poolIdx = 0
    private var timer: AnyCancellable?

    init() { startTick() }

    // MARK: Derived
    func typeMax(_ t: CardType) -> Double { t == .cfx ? 850 : 300 }
    var mirrorOn: Bool { mode == .mirror && dests.count >= 2 }
    func defDest() -> V3Dest? { dests.first { $0.id == defaultDestId } ?? dests.first }
    var canSwapDefault: Bool { activeCards.isEmpty }

    private func effMap() -> [Int: Double] {
        var groups: [Int: [V3Card]] = [:]
        for c in cards where c.status == .copying {
            let key = mirrorOn ? -1 : (c.destId ?? defaultDestId)
            groups[key, default: []].append(c)
        }
        var out: [Int: Double] = [:]
        for (_, g) in groups {
            let share = CAP / Double(g.count)
            for c in g { out[c.id] = min(typeMax(c.type), share) }
        }
        return out
    }
    var combinedMBps: Double { effMap().values.reduce(0, +) }
    var maxCardsOnOneDrive: Int {
        if mirrorOn { return cards.filter { $0.status == .copying }.count }
        var counts: [Int: Int] = [:]
        for c in cards where c.status == .copying { counts[c.destId ?? defaultDestId, default: 0] += 1 }
        return counts.values.max() ?? 0
    }
    var activeCards: [V3Card] { cards.filter { $0.status.isActive } }
    var doneCards: [V3Card] { cards.filter { $0.status == .done } }
    var hasError: Bool { cards.contains { $0.status == .error } }
    var aggregatePct: Double {
        let a = activeCards
        guard !a.isEmpty else { return doneCards.isEmpty ? 0 : 100 }
        return a.map { $0.status == .copying ? $0.pct : 100 }.reduce(0, +) / Double(a.count)
    }

    // MARK: Tick — lifecycle state machine
    private func startTick() {
        timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }
    private func tick() {
        guard cards.contains(where: { $0.status.isActive }) else { return }
        let now = Date(); let eff = effMap(); let SCALE = 520.0; var changed = false
        for i in cards.indices {
            var c = cards[i]
            switch c.status {
            case .detected:
                if now.timeIntervalSince(c.t0) > 0.6 { c.status = .copying; c.t0 = now; changed = true }
            case .copying:
                let e = eff[c.id] ?? 0
                let p = c.pct + (e / (c.sizeGB * 1024)) * 100 * 0.85 * SCALE * 0.1
                if p >= 100 { c.pct = 100; c.status = .finalizing; c.t0 = now } else { c.pct = p }
                changed = true
            case .finalizing:
                if now.timeIntervalSince(c.t0) > 1.6 {
                    c.status = verify ? .verifying : .done; c.t0 = now; changed = true
                    if c.status == .done { scheduleAfterDone(c.id) }
                }
            case .verifying:
                if now.timeIntervalSince(c.t0) > 1.5 { c.status = .done; c.t0 = now; changed = true; scheduleAfterDone(c.id) }
            default: break
            }
            cards[i] = c
        }
        if changed { objectWillChange.send() }
    }
    private func scheduleAfterDone(_ id: Int) {
        if autoEject { DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in self?.pull(id) } }
    }

    // MARK: Actions
    func plug() {
        guard cards.count < MAXCARDS else { return }
        idSeq += 1
        let (name, type, size) = cardPool[poolIdx % cardPool.count]; poolIdx += 1
        reelSeq += 1
        let reel = String(format: "A%03d", reelSeq)
        let accent = palette[idSeq % palette.count]
        let hasDefault = defDest() != nil
        // Auto-Ingest OFF → the card WAITS to be routed (drag its node to a drive, or press Start).
        // Auto-Ingest ON → it auto-routes to the default and starts immediately.
        let status: CardStatus = !autoIngest ? .awaiting : (hasDefault ? .detected : .blocked)
        var card = V3Card(id: idSeq, name: name, type: type, sizeGB: size, reel: reel, status: status, accent: accent)
        card.destId = (status == .awaiting) ? nil : defDest()?.id
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { cards.append(card) }
    }

    /// Cards parked in the "waiting to route" state (drag a node to a drive, or press Start).
    var awaitingCards: [V3Card] { cards.filter { $0.status == .awaiting } }

    /// Start a waiting card — routes to its chosen drive (or the default) and begins the lifecycle.
    func start(_ id: Int) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        if cards[i].destId == nil { cards[i].destId = defDest()?.id }
        cards[i].status = defDest() != nil ? .detected : .blocked
        cards[i].t0 = Date()
    }

    /// "Choose dest" affordance — cycle the card through the available drives without starting it.
    func chooseNextDest(_ id: Int) {
        guard !dests.isEmpty, let i = cards.firstIndex(where: { $0.id == id }) else { return }
        let di = dests.firstIndex { $0.id == cards[i].destId } ?? -1
        cards[i].destId = dests[(di + 1) % dests.count].id
    }
    func plugMany(_ n: Int) { for _ in 0..<n { plug() } }
    func finish() { if let i = cards.firstIndex(where: { $0.status.isActive }) { cards[i].status = .done; cards[i].pct = 100 } }
    func errorOne() { if let i = cards.firstIndex(where: { $0.status == .copying || $0.status == .detected }) { cards[i].status = .error } }
    func retry(_ id: Int) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].status = defDest() != nil ? .detected : .blocked; cards[i].pct = 0; cards[i].t0 = Date()
    }
    func rename(_ id: Int, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].name = t
    }
    func pull(_ id: Int) { withAnimation(.easeInOut(duration: 0.45)) { cards.removeAll { $0.id == id } } }
    func pullAll() { withAnimation(.easeInOut(duration: 0.45)) { cards.removeAll { $0.status == .done } } }
    func route(_ id: Int, to destId: Int) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].destId = destId
        if cards[i].status == .blocked || cards[i].status == .awaiting { cards[i].status = .detected; cards[i].t0 = Date() }
    }
    func cycleRoute(_ id: Int) {
        guard !mirrorOn else { showToast("Mirror copies every card to all drives"); return }
        guard dests.count >= 2 else { showToast("Add a destination to choose a drive"); return }
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        let di = dests.firstIndex { $0.id == cards[i].destId } ?? -1
        cards[i].destId = dests[(di + 1) % dests.count].id
    }
    func cardsRouted(to destId: Int) -> Int {
        if mirrorOn { return cards.filter { $0.status != .done }.count }
        return cards.filter { $0.destId == destId && $0.status != .done }.count
    }
    @discardableResult func makeDefault(_ id: Int) -> Bool {
        guard canSwapDefault else { showToast("Finish the active transfer before swapping destinations"); return false }
        guard id != defaultDestId, dests.contains(where: { $0.id == id }) else { return false }
        let name = dests.first { $0.id == id }?.name ?? ""
        defaultDestId = id; showToast("Default destination → \(name)"); return true
    }

    // MARK: Destinations
    func addDest() {
        guard dests.count < MAXDESTS, destPool.count >= dests.count else { return }
        destSeq += 1
        let (name, free) = destPool[(dests.count - 1) % destPool.count]
        dests.append(V3Dest(id: destSeq, name: name, free: free, role: .target))
    }
    func addBackup() { addDest(); if let last = dests.indices.last { dests[last].role = .mirror }; mode = .mirror }
    func removeDest(_ id: Int) {
        guard dests.count > 1 else { showToast("Keep at least one destination"); return }
        dests.removeAll { $0.id == id }
        if id == defaultDestId { defaultDestId = dests.first?.id ?? 0 }
        for i in cards.indices where cards[i].destId == id { cards[i].destId = defaultDestId }
        if dests.count < 2 { mode = .split }
    }
    let ssdOptions: [(name: String, free: String)] = [
        ("OWC Envoy Pro", "3.7 TB free"), ("G-DRIVE Pro", "920 GB free"),
        ("RAID Tower", "12 TB free"), ("LaCie Rugged SSD", "1.9 TB free"),
    ]
    var availableSSDs: [(name: String, free: String)] { ssdOptions.filter { o in !dests.contains { $0.name == o.name } } }
    func addDestination(name: String, free: String, role: DestRole) {
        guard dests.count < MAXDESTS else { showToast("Maximum destinations connected"); return }
        destSeq += 1
        dests.append(V3Dest(id: destSeq, name: name, free: free, role: role))
        if role == .mirror { mode = .mirror }
    }
    func setMode(_ m: RoutingMode) {
        if m == .mirror && dests.count < 2 { showToast("Add a backup drive to mirror"); return }
        mode = m
    }
    func showToast(_ msg: String) {
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in if self?.toast == msg { self?.toast = nil } }
    }
    func reset() {
        cards = []; dests = [V3Dest(id: 1, name: "Samsung T7", free: "1.8 TB free", role: .primary)]
        mode = .split; defaultDestId = 1; idSeq = 0; reelSeq = 2; destSeq = 1; poolIdx = 0
    }
}
