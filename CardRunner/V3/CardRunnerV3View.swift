//
//  CardRunnerV3View.swift — PURE-SIM demo of the v3 node dashboard (CR_V3_DEMO=1).
//
//  Faithful render of the target design driven entirely by V3Model (the simulator) — no engine,
//  no real I/O. Use the TESTING toolbar to plug fake cards, add drives, split/mirror, route, pull.
//  This exists to VALIDATE the design/interactions before building the real multi-destination
//  routing backend. The real-engine dashboard is ContentView.bodyV3 (CR_V3_PREVIEW=1).
//

import SwiftUI

struct CardRunnerV3View: View {
    @StateObject private var m = V3Model()
    @State private var breathe = false
    @State private var showSettings = false
    @State private var editingId: Int? = nil
    @State private var editText = ""
    @State private var doneExpanded = false
    @FocusState private var nameFieldFocused: Bool
    @State private var showAddDest = false
    @State private var addRole: DestRole = .target
    @State private var addPick = 0
    @State private var showFolder = false
    // Drag-to-route
    @State private var destFrames: [Int: CGRect] = [:]
    @State private var dragLine: DragLine? = nil
    @State private var dragOverDest: Int? = nil

    private let aCyan = Color(hex: "#0dcff5")
    private let aPurple = Color(hex: "#a855f7")
    private let aMag = Color(hex: "#ff5cdd")
    private let green = Color(hex: "#34d399")
    private let amber = Color(hex: "#fbbf24")
    private let red = Color(hex: "#f87171")

    private var brand: LinearGradient {
        LinearGradient(colors: [aCyan, aPurple, aMag], startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        ZStack {
            backgroundLayer
            VStack(spacing: 18) {
                topBar.zIndex(1)
                HStack(alignment: .top, spacing: 24) {
                    sources.frame(maxWidth: .infinity, alignment: .leading)
                    ring.frame(width: 340)
                    destinations.frame(maxWidth: .infinity, alignment: .trailing)
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
                                drawFunnel(&ctx, rects: rects, phase: phase)
                            }
                        }
                    }
                }
                toolbar
                bottomBar
            }
            .padding(26)
        }
        .frame(minWidth: 1200, minHeight: 780)
        .preferredColorScheme(.dark)
        .onAppear { breathe = true }
        .overlay(alignment: .bottom) {
            if let t = m.toast {
                Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.65), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                    .padding(.bottom, 92)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: m.toast)
        .sheet(isPresented: $showSettings) { demoSettingsSheet }
        .sheet(isPresented: $showAddDest) { addDestSheet }
        .sheet(isPresented: $showFolder) { folderSheet }
    }

    // Demo placeholder — the REAL settings reuse ContentView's settings sheet in the engine build.
    private var demoSettingsSheet: some View {
        VStack(spacing: 14) {
            Text("Settings").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
            Text("This is the DEMO dashboard (CR_V3_DEMO). In the real build, the gear opens CardRunner's full settings sheet.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
            Toggle("Verify after copy", isOn: $m.verify).tint(aCyan)
            Toggle("Auto-eject when safe", isOn: $m.autoEject).tint(green)
            Toggle("Auto-ingest on insert", isOn: $m.autoIngest).tint(green)
            Spacer()
            Button("Done") { showSettings = false }.keyboardShortcut(.defaultAction)
        }
        .padding(26).frame(width: 420, height: 320)
        .background(Color(hex: "#0c0822")).preferredColorScheme(.dark)
    }

    private var folderSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New project folder").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 6) {
                Text("PROJECT NAME").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.4))
                TextField("Project name", text: $m.projectName)
                    .textFieldStyle(.plain).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    .padding(10).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.10)))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("FINDER TAG COLOR").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.4))
                HStack(spacing: 10) {
                    ForEach(Array(m.folderColors.enumerated()), id: \.offset) { i, col in
                        Circle().fill(col).frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(.white, lineWidth: m.projectColorIndex == i ? 2 : 0))
                            .onTapGesture { m.projectColorIndex = i }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("FOLDER STRUCTURE").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.4))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill").foregroundStyle(m.folderColors[m.projectColorIndex])
                        Text(m.projectName.isEmpty ? "Untitled" : m.projectName).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    }
                    ForEach(m.scaffold, id: \.self) { f in
                        HStack(spacing: 6) {
                            Text("└").foregroundStyle(.white.opacity(0.3))
                            Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                            Text(f).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                        }.padding(.leading, 8)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            }
            Spacer()
            HStack {
                Button("Cancel") { showFolder = false }
                Spacer()
                Button("Create folder") { m.showToast("Project folder created: \(m.projectName)"); showFolder = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26).frame(width: 440, height: 480)
        .background(Color(hex: "#0c0822")).preferredColorScheme(.dark)
    }

    private func openAddDest(_ role: DestRole) {
        guard !m.availableSSDs.isEmpty else { m.showToast("Maximum destinations connected"); return }
        addRole = role; addPick = 0; showAddDest = true
    }

    private var addDestSheet: some View {
        let opts = m.availableSSDs
        return VStack(alignment: .leading, spacing: 14) {
            Text(addRole == .mirror ? "Add backup drive" : "Add destination")
                .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
            Text(addRole == .mirror
                 ? "Every card mirrors to this drive too — a second copy for safety."
                 : "Cards can be routed to this drive (split mode).")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            VStack(spacing: 8) {
                ForEach(Array(opts.enumerated()), id: \.offset) { i, o in
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive.fill").foregroundStyle(aPurple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            Text(o.free).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                        if addPick == i { Image(systemName: "checkmark.circle.fill").foregroundStyle(aCyan) }
                    }
                    .padding(12)
                    .background((addPick == i ? aCyan.opacity(0.12) : Color.white.opacity(0.03)), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(addPick == i ? aCyan.opacity(0.5) : .white.opacity(0.08)))
                    .contentShape(Rectangle()).onTapGesture { addPick = i }
                }
            }
            HStack {
                Text("Role").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8)); Spacer()
                Picker("", selection: $addRole) {
                    Text("Split target").tag(DestRole.target); Text("Mirror backup").tag(DestRole.mirror)
                }.pickerStyle(.segmented).frame(width: 210).labelsHidden()
            }
            Spacer()
            HStack {
                Button("Cancel") { showAddDest = false }
                Spacer()
                Button("Add") {
                    if opts.indices.contains(addPick) {
                        let o = opts[addPick]; m.addDestination(name: o.name, free: o.free, role: addRole)
                    }
                    showAddDest = false
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(26).frame(width: 440, height: 430)
        .background(Color(hex: "#0c0822")).preferredColorScheme(.dark)
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#0c0822"), Color(hex: "#080615"), Color(hex: "#050310")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(hex: "#7c3aed").opacity(0.20), .clear], center: .init(x: 0.22, y: 0.08), startRadius: 0, endRadius: 760)
            RadialGradient(colors: [Color(hex: "#0dcff5").opacity(0.13), .clear], center: .init(x: 0.84, y: 0.92), startRadius: 0, endRadius: 640)
            RadialGradient(colors: [Color(hex: "#d44dff").opacity(0.12), .clear], center: .init(x: 0.92, y: 0.06), startRadius: 0, endRadius: 580)
        }.ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.white.opacity(0.7)).frame(width: 32, height: 32)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.10)))
            }.buttonStyle(.plain)
            Spacer()
            HStack(spacing: 11) {
                cardLogo
                VStack(spacing: 2) {
                    Text("CARDRUNNER").font(.custom("Tech Headlines Italic", size: 24)).foregroundStyle(brand)
                    Text("Plug a card — it copies, instantly & safely").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(green).frame(width: 7, height: 7)
                Text("Auto-Ingest \(m.autoIngest ? "On" : "Off")").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8)
            .background(.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(green.opacity(0.35)))
            .onTapGesture { m.autoIngest.toggle() }
        }
    }

    private var cardLogo: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: "#c084fc"), Color(hex: "#7c3aed")], startPoint: .top, endPoint: .bottom))
            .frame(width: 26, height: 32)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.35)).frame(width: 11, height: 4).offset(y: -10))
            .shadow(color: Color(hex: "#7c3aed").opacity(0.5), radius: 8)
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            colHeader("SOURCES")
            ForEach(m.cards.filter { $0.status != .done }) { card in laneView(card) }
            if !m.doneCards.isEmpty { donePile }
            Spacer(minLength: 0)
        }
    }

    private func laneView(_ c: V3Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                cardIcon(c.accent)
                VStack(alignment: .leading, spacing: 2) {
                    if editingId == c.id {
                        TextField("Card name", text: $editText)
                            .textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white).focused($nameFieldFocused)
                            .onSubmit { m.rename(c.id, to: editText); editingId = nil }
                            .onExitCommand { editingId = nil }
                    } else {
                        Text(c.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .onTapGesture(count: 2) { editText = c.name; editingId = c.id; nameFieldFocused = true }
                            .help("Double-click to rename")
                    }
                    Text(routeLabel(c)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        .contentShape(Rectangle())
                        .onTapGesture { m.cycleRoute(c.id) }
                        .help(m.dests.count > 1 && !m.mirrorOn ? "Tap to send this card to a different drive" : "")
                }
                Spacer()
                if c.status == .awaiting {
                    Button { m.chooseNextDest(c.id) } label: {
                        Text(c.destId == nil ? "CHOOSE DEST" : "→ \(m.dests.first { $0.id == c.destId }?.name ?? "")")
                            .font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(amber)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(amber.opacity(0.5)))
                    }.buttonStyle(.plain)
                    .help("Tap to cycle drives, or drag the node onto a drive")
                } else {
                    statusBadge(c)
                }
            }
            laneBottom(c)
        }
        .padding(14)
        .background(surface(c))
        .overlay(border(c))
        .frame(width: 360)
        .overlay(alignment: .trailing) {
            // The draggable NODE — always present on a waiting card; on routable cards in split mode.
            if c.status == .awaiting || (m.dests.count > 1 && !m.mirrorOn && c.status != .done) { routeDot(c) }
        }
        .anchorPreference(key: V3AnchorKey.self, value: .bounds) { ["lane-\(c.id)": $0] }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .opacity.combined(with: .move(edge: .leading))))
    }

    @ViewBuilder
    private func laneBottom(_ c: V3Card) -> some View {
        switch c.status {
        case .detected, .copying:
            VStack(alignment: .leading, spacing: 5) {
                progressBar(c.pct)
                Text(String(format: "%.0f MB/s", (m.activeCards.first { $0.id == c.id } != nil) ? max(0, mbpsFor(c)) : 0))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            }
        case .finalizing:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Flushing to disk — keep card inserted").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
        case .verifying:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).tint(green)
                Text("Verifying checksums…").font(.system(size: 11)).foregroundStyle(green.opacity(0.9))
            }
        case .done:
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(green)
                Text("SAFE TO PULL").font(.system(size: 12, weight: .bold)).foregroundStyle(green)
                Spacer(); pullButton { m.pull(c.id) }
            }
        case .error:
            HStack(spacing: 7) {
                Text("Transfer failed — kept mounted, re-insert to retry")
                    .font(.system(size: 11)).foregroundStyle(red)
                Spacer()
                smallButton("Retry", color: red) { m.retry(c.id) }
            }
        case .blocked:
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(amber)
                Text("No destination — choose a drive to start")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(amber)
            }
        case .awaiting:
            HStack(spacing: 7) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted").font(.system(size: 11)).foregroundStyle(amber)
                Text("Drag the node to a drive · or").font(.system(size: 11)).foregroundStyle(amber.opacity(0.9))
                Spacer()
                Button { m.start(c.id) } label: {
                    Text("Start").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(green, in: Capsule())
                }.buttonStyle(.plain).help("Start now using the default destination")
            }
        }
    }

    private var donePile: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(green.opacity(0.18)).frame(width: 30, height: 30)
                        Text("\(m.doneCards.count)").font(.system(size: 13, weight: .bold)).foregroundStyle(green)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(m.doneCards.count) card\(m.doneCards.count == 1 ? "" : "s") safe to pull")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("Tap to review · or Pull all").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    Image(systemName: doneExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { doneExpanded.toggle() } }
                VStack(spacing: 2) {
                    Image(systemName: "eject").font(.system(size: 13)).foregroundStyle(green)
                    Text("All").font(.system(size: 9, weight: .semibold)).foregroundStyle(green)
                }
                .frame(width: 44, height: 44)
                .background(green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(green.opacity(0.4)))
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { m.pullAll() }; doneExpanded = false }
            }
            .padding(12)
            .background(green.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(green.opacity(0.25)))

            if doneExpanded {
                ForEach(m.doneCards) { c in
                    HStack(spacing: 10) {
                        Image(systemName: "sdcard").foregroundStyle(.white.opacity(0.5))
                        Text(c.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        Spacer()
                        pullButton { m.pull(c.id) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .frame(width: 360)
    }

    private var ring: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(brand).blur(radius: 46)
                    .opacity(m.cards.isEmpty ? (breathe ? 0.13 : 0.03) : 0.05)
                    .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: breathe)
                Circle().stroke(.white.opacity(0.06), lineWidth: 16)
                Circle().trim(from: 0, to: waitingToRoute ? 0 : m.aggregatePct / 100)
                    .stroke(ringStroke, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.2), value: m.aggregatePct)
                ringCenter
            }
            .frame(width: 320, height: 320)
            .anchorPreference(key: V3AnchorKey.self, value: .bounds) { ["ring": $0] }
            if waitingToRoute {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text("\(m.awaitingCards.count) card\(m.awaitingCards.count == 1 ? "" : "s") waiting — drag to a drive, or press Start")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(amber).padding(.horizontal, 16).padding(.vertical, 10)
                .background(amber.opacity(0.12), in: Capsule()).overlay(Capsule().strokeBorder(amber.opacity(0.45)))
            }
            if m.maxCardsOnOneDrive >= 2 && m.availableSSDs.count > 0 { contentionBanner }
            HStack(spacing: 7) {
                Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(amber)
                Text(m.autoIngest ? "Auto-Ingest ON · ready for the next card" : "Auto-Ingest off")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(aPurple.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(aPurple.opacity(0.4)))
            if !m.doneCards.isEmpty || (m.cards.isEmpty == false && m.activeCards.isEmpty) {
                Button { m.showToast("Opening destination in Finder…") } label: {
                    HStack(spacing: 7) { Image(systemName: "folder"); Text("Open in Finder") }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.white.opacity(0.05), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    /// True when cards are parked waiting to be routed and nothing is actively copying.
    private var waitingToRoute: Bool { !m.awaitingCards.isEmpty && m.activeCards.isEmpty }

    private var ringStroke: AnyShapeStyle {
        if m.hasError { return AnyShapeStyle(amber) }
        if waitingToRoute { return AnyShapeStyle(amber) }
        if m.activeCards.isEmpty && !m.doneCards.isEmpty { return AnyShapeStyle(green) }
        return AnyShapeStyle(brand)
    }

    @ViewBuilder private var ringCenter: some View {
        if m.cards.isEmpty {
            VStack(spacing: 6) {
                Text("Ready for cards").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                Text("Auto-ingest armed").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
        } else if m.hasError {
            VStack(spacing: 6) {
                Text("\(m.cards.filter{$0.status == .error}.count)").font(.system(size: 40, weight: .bold)).foregroundStyle(amber)
                Text("needs attention").font(.system(size: 13)).foregroundStyle(amber)
            }
        } else if !m.activeCards.isEmpty {
            VStack(spacing: 6) {
                Text("\(Int(m.aggregatePct))%").font(.system(size: 42, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text(summaryLine).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
            }.frame(width: 200)
        } else if !m.awaitingCards.isEmpty {
            VStack(spacing: 6) {
                Text("\(m.awaitingCards.count)").font(.system(size: 48, weight: .bold)).foregroundStyle(amber)
                Text("card\(m.awaitingCards.count == 1 ? "" : "s") waiting to route").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                Text("Drag each to a destination to start").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }.frame(width: 220)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle").font(.system(size: 34)).foregroundStyle(green)
                Text("All safe to pull").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                Text("\(m.doneCards.count) card\(m.doneCards.count == 1 ? "" : "s") ready to pull")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var summaryLine: String {
        var p: [String] = []
        let cp = m.cards.filter { $0.status == .copying }.count
        let fn = m.cards.filter { $0.status == .finalizing || $0.status == .verifying }.count
        if cp > 0 { p.append("\(cp) copying") }
        if fn > 0 { p.append("\(fn) finalizing") }
        if !m.doneCards.isEmpty { p.append("\(m.doneCards.count) ready") }
        return p.joined(separator: " · ")
    }

    private var contentionBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
            Text("\(m.maxCardsOnOneDrive) cards sharing one drive — add a destination for full speed")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(amber).padding(.horizontal, 14).padding(.vertical, 9)
        .background(amber.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(amber.opacity(0.3)))
    }

    private var destinations: some View {
        VStack(alignment: .trailing, spacing: 14) {
            colHeader("DESTINATIONS")
            defaultDestBox
            ForEach(m.dests.filter { $0.id != m.defaultDestId }) { d in destTile(d, isDefault: false) }
            Spacer(minLength: 0)
        }
    }

    private var defaultDestBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(amber)
                    Text("DEFAULT DESTINATION").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(amber)
                }
                Spacer()
                Text("Auto-routes the first card").font(.system(size: 10)).foregroundStyle(amber.opacity(0.7))
            }
            if let d = m.defDest() { destTile(d, isDefault: true) }
        }
        .padding(12).frame(width: 348)
        .background(amber.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(amber.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = Int(s) else { return false }
            return m.makeDefault(id)
        } isTargeted: { dragOverDest = $0 ? -99 : nil }
    }

    private func destTile(_ d: V3Dest, isDefault: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill").font(.system(size: 18)).foregroundStyle(aPurple)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(d.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    if isDefault { badge("DEFAULT", amber) } else { roleBadge(d.role) }
                }
                Text(d.free).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Text(isDefault ? "Default target"
                     : "\(m.cardsRouted(to: d.id)) card\(m.cardsRouted(to: d.id) == 1 ? "" : "s") \(m.mirrorOn ? "mirrored" : "routed")")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            if !isDefault {
                Image(systemName: m.canSwapDefault ? "line.3.horizontal" : "lock.fill")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.25))
                    .help(m.canSwapDefault ? "Drag onto the default box to make this the default" : "Locked while a transfer is running")
            }
            if m.dests.count > 1 {
                Image(systemName: "minus").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                    .contentShape(Rectangle()).onTapGesture { m.removeDest(d.id) }
            }
        }
        .padding(14).frame(width: 324, alignment: .leading)
        .background(.white.opacity(dragOverDest == d.id ? 0.09 : (isDefault ? 0.05 : 0.04)), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(dragOverDest == d.id ? aCyan.opacity(0.7) : .white.opacity(isDefault ? 0.0 : 0.10)))
        .anchorPreference(key: V3AnchorKey.self, value: .bounds) { ["dest-\(d.id)": $0] }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { destFrames[d.id] = g.frame(in: .named("stage")) }
                .onChange(of: g.frame(in: .named("stage"))) { _, f in destFrames[d.id] = f }
        })
        .if(!isDefault && m.canSwapDefault) { $0.draggable("\(d.id)") { destDragPreview(d) } }
    }

    private func destDragPreview(_ d: V3Dest) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.fill").font(.system(size: 14)).foregroundStyle(aPurple)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text("Drop on default to swap").font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(hex: "#1a1430"), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(aCyan.opacity(0.7), lineWidth: 1.5))
    }

    @ViewBuilder private func roleBadge(_ r: DestRole) -> some View {
        switch r {
        case .primary: badge("PRIMARY", aCyan)
        case .mirror:  badge("MIRROR", aPurple)
        case .target:  EmptyView()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            toolLabel("TESTING")
            primaryButton("＋ Plug in card") { m.plug() }
            toolButton("+5 cards") { m.plugMany(5) }
            toolButton("Finish one") { m.finish() }
            toolButton("Error one") { m.errorOne() }
            toolButton("Pull card") { if let d = m.doneCards.first { m.pull(d.id) } }
            toolLabel("DRIVES")
            toolButton("Add drive") { openAddDest(.target) }
            toolButton("Add backup") { openAddDest(.mirror) }
            toolButton(m.mode == .split ? "Split" : "Mirror") { m.setMode(m.mode == .split ? .mirror : .split) }
            toolButton("Reset") { m.reset() }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))
        .opacity(0.7)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text(bottomStatus).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            Spacer()
            bottomChip("New project folder", "folder.badge.plus", aPurple) { showFolder = true }
            bottomChip("Today only", "calendar", m.todayOnly ? aCyan : .white.opacity(0.6)) { m.todayOnly.toggle() }
            bottomChip("Auto-eject  \(m.autoEject ? "On" : "Off")", "eject", m.autoEject ? green : .white.opacity(0.6)) { m.autoEject.toggle() }
            primaryButton("＋ Add destination") { openAddDest(.target) }
        }
    }
    private var bottomStatus: String {
        let ready = m.doneCards.count, active = m.activeCards.count
        let lead = active > 0 ? "\(active) transferring · \(ready) ready" : "\(ready) ready"
        return "\(lead)   ·   \(m.mode == .split ? "Split" : "Mirror") · \(m.dests.count) drive\(m.dests.count == 1 ? "" : "s") · default \(m.defDest()?.name ?? "—")"
    }
    private func bottomChip(_ t: String, _ icon: String, _ color: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) { Image(systemName: icon); Text(t) }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(color)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.white.opacity(0.04), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
        }.buttonStyle(.plain)
    }

    private func routeDot(_ c: V3Card) -> some View {
        let waiting = c.status == .awaiting
        let dotColor = waiting ? amber : c.accent
        return Circle().fill(dotColor).frame(width: waiting ? 18 : 14, height: waiting ? 18 : 14)
            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: waiting ? 2 : 1))
            .shadow(color: dotColor.opacity(0.8), radius: waiting ? 8 : 4)
            .offset(x: 9)
            .help(waiting ? "Drag onto a drive to link & start this card" : "Drag to a drive to route this card")
            .gesture(
                DragGesture(coordinateSpace: .named("stage"))
                    .onChanged { v in
                        dragLine = DragLine(from: v.startLocation, to: v.location)
                        dragOverDest = destFrames.first { $0.value.contains(v.location) }?.key
                    }
                    .onEnded { v in
                        if let did = destFrames.first(where: { $0.value.contains(v.location) })?.key {
                            m.route(c.id, to: did)
                        }
                        dragLine = nil; dragOverDest = nil
                    }
            )
    }

    private func drawFunnel(_ ctx: inout GraphicsContext, rects: [String: CGRect], phase: CGFloat) {
        if let dl = dragLine {
            var p = Path(); p.move(to: dl.from)
            p.addCurve(to: dl.to,
                       control1: CGPoint(x: (dl.from.x + dl.to.x)/2, y: dl.from.y),
                       control2: CGPoint(x: (dl.from.x + dl.to.x)/2, y: dl.to.y))
            ctx.stroke(p, with: .color(aCyan.opacity(0.85)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 6]))
            ctx.fill(Path(ellipseIn: CGRect(x: dl.to.x - 5, y: dl.to.y - 5, width: 10, height: 10)), with: .color(aCyan))
        }
        guard let ring = rects["ring"] else { return }
        let laneCount = m.cards.filter { $0.status != .done }.count
        guard laneCount <= 6, m.dests.count <= 3 else { return }

        let rc = CGPoint(x: ring.midX, y: ring.midY)
        let rad = ring.width / 2
        let leftPort = CGPoint(x: rc.x - rad, y: rc.y)
        let rightPort = CGPoint(x: rc.x + rad, y: rc.y)
        let dash = StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 9], dashPhase: -phase)

        // Waiting/unrouted cards draw NO line yet — you drag their node to link them.
        for c in m.cards where c.status != .done && c.status != .awaiting {
            guard let lr = rects["lane-\(c.id)"] else { continue }
            let from = CGPoint(x: lr.maxX, y: lr.midY)
            var p = Path(); p.move(to: from)
            p.addCurve(to: leftPort,
                       control1: CGPoint(x: (from.x + leftPort.x) / 2, y: from.y),
                       control2: CGPoint(x: (from.x + leftPort.x) / 2, y: leftPort.y))
            let col = c.status == .error ? Color(hex: "#f87171")
                    : c.status == .blocked ? Color(hex: "#fbbf24") : c.accent
            ctx.stroke(p, with: .color(col.opacity(0.55)), style: dash)
        }
        let flowing = m.cards.contains { $0.status != .done && $0.status != .awaiting }
        if flowing { for d in m.dests {
            guard let dr = rects["dest-\(d.id)"] else { continue }
            let to = CGPoint(x: dr.minX, y: dr.midY)
            var p = Path(); p.move(to: rightPort)
            p.addCurve(to: to,
                       control1: CGPoint(x: (rightPort.x + to.x) / 2, y: rightPort.y),
                       control2: CGPoint(x: (rightPort.x + to.x) / 2, y: to.y))
            let col = m.hasError ? Color(hex: "#fbbf24")
                    : (m.activeCards.isEmpty && !m.doneCards.isEmpty) ? green : aPurple
            ctx.stroke(p, with: .color(col.opacity(0.5)), style: dash)
        } }
    }

    private func colHeader(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.4))
    }
    private func cardIcon(_ c: Color) -> some View {
        Image(systemName: "sdcard.fill").font(.system(size: 18)).foregroundStyle(c)
            .frame(width: 32, height: 32).background(c.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }
    private func routeLabel(_ c: V3Card) -> String {
        let drive = m.dests.first { $0.id == (c.destId ?? m.defaultDestId) }?.name ?? "—"
        return m.mirrorOn ? "\(c.media)  ·  → all drives" : "\(c.media)  ·  → \(drive)"
    }
    private func statusBadge(_ c: V3Card) -> some View {
        let (t, col): (String, Color) = {
            switch c.status {
            case .copying:    return ("\(Int(c.pct))%", c.accent)
            case .detected:   return ("STARTING", c.accent)
            case .finalizing: return ("FINALIZING", amber)
            case .verifying:  return ("VERIFYING", green)
            case .done:       return ("SAFE", green)
            case .error:      return ("ERROR", red)
            case .blocked:    return ("NO DEST", amber)
            case .awaiting:   return ("WAITING", amber)
            }
        }()
        return Text(t).font(.system(size: 11, weight: .bold)).foregroundStyle(col)
    }
    private func progressBar(_ p: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10)).frame(height: 4)
                Capsule().fill(brand).frame(width: geo.size.width * CGFloat(min(max(p,0),100))/100, height: 4)
            }
        }.frame(height: 4)
    }
    private func mbpsFor(_ c: V3Card) -> Double {
        let copying = m.cards.filter { $0.status == .copying && (m.mirrorOn || $0.destId == c.destId) }.count
        return min(c.type == .cfx ? 850 : 300, 1000 / Double(max(1, copying)))
    }
    private func surface(_ c: V3Card) -> some ShapeStyle { Color.white.opacity(0.04) }
    private func border(_ c: V3Card) -> some View {
        let col: Color = c.status == .error ? red.opacity(0.4)
            : c.status == .blocked ? amber.opacity(0.5)
            : c.status == .done ? green.opacity(0.3) : .white.opacity(0.10)
        return RoundedRectangle(cornerRadius: 16).strokeBorder(col)
    }
    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 9, weight: .bold)).foregroundStyle(c)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(c.opacity(0.14), in: Capsule())
    }
    private func pullButton(_ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 4) { Image(systemName: "eject.fill").font(.system(size: 9)); Text("Pull").font(.system(size: 11, weight: .semibold)) }
                .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                .background(.white.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        }.buttonStyle(.plain)
    }
    private func smallButton(_ t: String, color: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.10)))
        }.buttonStyle(.plain)
    }
    private func toolLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.3))
    }
    private func toolButton(_ t: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
    private func primaryButton(_ t: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(brand, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}

struct DragLine: Equatable { var from: CGPoint; var to: CGPoint }

extension View {
    /// Conditionally apply a modifier (used to gate `.draggable` on swap availability).
    @ViewBuilder func `if`<T: View>(_ condition: Bool, _ transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

#Preview { CardRunnerV3View() }
