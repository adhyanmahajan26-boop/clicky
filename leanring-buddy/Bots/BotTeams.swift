//
//  BotTeams.swift
//  leanring-buddy
//
//  Categories as teams. You make a category, add bots to it and may pick a
//  leader: the leader hands work to its team and reports to the CEO (the
//  primary bot); with no leader, every member reports for itself. The team
//  page shows the members, the leader, the team's job and its reports, and
//  sends a report now or on a schedule. Home shows the whole org chart.
//

import SwiftUI

/// A category's tile: its colour and symbol, like a bot's.
struct CategoryTile: View {
    let section: BotsLayout.Section
    let size: CGFloat

    static func swatch(for section: BotsLayout.Section) -> BotPalette.Swatch {
        if let named = BotPalette.swatches.first(where: { $0.id == section.swatch }) { return named }
        let index = Int(section.id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }) % 8
        return BotPalette.swatches[index]
    }

    var body: some View {
        let swatch = Self.swatch(for: section)
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        shape.fill(LinearGradient(colors: [Color(hex: swatch.from).opacity(0.9), Color(hex: swatch.to).opacity(0.9)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .overlay(Image(systemName: section.symbol ?? "folder.fill").font(.system(size: size * 0.44, weight: .semibold)).foregroundColor(.white))
            .frame(width: size, height: size)
    }
}

/// An SF Symbol that bounces when hovered or when `trigger` changes.
struct MotionSymbol: View {
    let name: String
    var size: CGFloat = 14
    var weight: Font.Weight = .regular
    var color: Color = DS.Colors.textSecondary
    var trigger = false
    @State private var hovering = false

    var body: some View {
        Image(systemName: name).font(.system(size: size, weight: weight)).foregroundColor(color)
            .symbolEffect(.bounce, value: hovering)
            .symbolEffect(.bounce, value: trigger)
            .onHover { if $0 { hovering.toggle() } }
    }
}

/// A sidebar icon: a colour tile with a glyph that keeps moving, each in its own way, and moves more when
/// hovered or open. The clock's hand turns, the gear spins, the pencil writes, the page's lines draw.
struct NavIcon: View {
    let symbol: String
    var active = false
    var size: CGFloat = 24
    @State private var hovering = false

    private var colors: (UInt32, UInt32) {
        switch symbol {
        case "square.and.pencil": return (0xF2784B, 0xE0476A)
        case "house": return (0x4EA8F0, 0x4A6FE0)
        case "note.text": return (0xF5B13D, 0xE8782E)
        case "clock.arrow.circlepath": return (0x3FC8B4, 0x2E8FB8)
        case "puzzlepiece.extension": return (0xA468EB, 0xD152B8)
        case "gearshape": return (0x7C8697, 0x4D5666)
        case "magnifyingglass": return (0x9BD14B, 0x3FA65C)
        default: return (0x6E7BF0, 0x8A55E0)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * (hovering || active ? 2.2 : 1)
            ZStack {
                shape.fill(LinearGradient(colors: [Color(hex: colors.0), Color(hex: colors.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center))
                glyph(t)
            }
            .frame(width: size, height: size)
            .scaleEffect(hovering ? 1.1 : 1)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private func glyph(_ t: Double) -> some View {
        let unit = size / 24
        switch symbol {
        case "clock.arrow.circlepath":
            ZStack {
                Circle().stroke(Color.white, lineWidth: 1.6 * unit).frame(width: 13 * unit, height: 13 * unit)
                Capsule().fill(Color.white).frame(width: 1.6 * unit, height: 5 * unit).offset(y: -2.2 * unit).rotationEffect(.degrees(t * 90))
                Capsule().fill(Color.white).frame(width: 1.6 * unit, height: 3.6 * unit).offset(y: -1.5 * unit).rotationEffect(.degrees(t * 8))
            }
        case "gearshape":
            Image(systemName: "gearshape.fill").font(.system(size: 14 * unit, weight: .semibold)).foregroundColor(.white)
                .rotationEffect(.degrees(t * 28))
        case "note.text":
            VStack(alignment: .leading, spacing: 2 * unit) {
                ForEach(0..<3, id: \.self) { row in
                    let width = 6 + 6 * (sin(t * 1.6 + Double(row) * 1.1) * 0.5 + 0.5)
                    Capsule().fill(Color.white).frame(width: width * unit, height: 1.8 * unit)
                }
            }
            .frame(width: 12 * unit, alignment: .leading)
        case "square.and.pencil":
            Image(systemName: "pencil").font(.system(size: 14 * unit, weight: .bold)).foregroundColor(.white)
                .rotationEffect(.degrees(sin(t * 3) * 10))
                .offset(x: cos(t * 1.5) * 1.6 * unit, y: sin(t * 3) * 1.2 * unit)
        case "house":
            Image(systemName: "house.fill").font(.system(size: 13 * unit, weight: .semibold)).foregroundColor(.white)
                .offset(y: sin(t * 1.8) * 0.9 * unit)
        case "puzzlepiece.extension":
            Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 13 * unit, weight: .semibold)).foregroundColor(.white)
                .rotationEffect(.degrees(sin(t * 1.4) * 12))
        case "magnifyingglass":
            Image(systemName: "magnifyingglass").font(.system(size: 13 * unit, weight: .bold)).foregroundColor(.white)
                .offset(x: cos(t * 1.3) * 1.6 * unit, y: sin(t * 2.6) * 1.2 * unit)
        default:
            Image(systemName: symbol).font(.system(size: 13 * unit, weight: .semibold)).foregroundColor(.white)
        }
    }
}

// MARK: - The team page

struct CategoryScreen: View {
    @ObservedObject var store: BotsStore
    @ObservedObject var selection: BotsSelection
    let sectionID: String
    @State private var name = ""
    @State private var purpose = ""
    @State private var reporting = false
    @State private var editingLook = false
    @State private var pickingLeader = false

    private static let symbols = ["folder.fill", "briefcase.fill", "envelope.fill", "hammer.fill", "chart.line.uptrend.xyaxis", "paintbrush.fill",
                                  "megaphone.fill", "book.fill", "house.fill", "sparkles", "dollarsign.circle.fill", "graduationcap.fill"]

    private func lookPicker(_ section: BotsLayout.Section) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Colour").font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 5), spacing: 8) {
                ForEach(BotPalette.swatches) { swatch in
                    Button { store.updateCategory(sectionID) { $0.swatch = swatch.id } } label: {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hex: swatch.from), Color(hex: swatch.to)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 26, height: 26)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).inset(by: -3)
                                .stroke(CategoryTile.swatch(for: section).id == swatch.id ? Color.white : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Symbol").font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 6), spacing: 6) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button { store.updateCategory(sectionID) { $0.symbol = symbol } } label: {
                        Image(systemName: symbol).font(.system(size: 13)).foregroundColor(DS.Colors.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill((section.symbol ?? "folder.fill") == symbol ? DS.Colors.selected : DS.Colors.hover))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }

    private func leaderPicker(_ members: [NativeBot], current: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Team leader").font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Colors.textTertiary).padding(.bottom, 4)
            ForEach(members) { bot in
                Button { store.setLeader(bot.id, of: sectionID); pickingLeader = false } label: {
                    HStack(spacing: 8) {
                        BotAvatar(bot: bot, size: 22, state: .idle)
                        Text(bot.name).font(.system(size: 13)).foregroundColor(DS.Colors.textPrimary)
                        Spacer()
                        if current == bot.id { Image(systemName: "crown.fill").font(.system(size: 10)).foregroundColor(Color(hex: 0xF5B13D)) }
                    }
                    .padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
                }
                .buttonStyle(SidebarButtonStyle(isSelected: current == bot.id))
            }
            if members.isEmpty { Text("Add bots to the team first.").font(.system(size: 12)).foregroundColor(DS.Colors.textTertiary) }
            Divider().padding(.vertical, 4)
            Button { store.setLeader(nil, of: sectionID); pickingLeader = false } label: {
                Text("No leader: everyone reports to the CEO").font(.system(size: 12.5)).foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 8).frame(height: 30).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle(isSelected: current == nil))
        }
        .padding(12).frame(width: 260)
    }

    private var section: BotsLayout.Section? { store.category(sectionID) }

    var body: some View {
        if let section {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header(section)
                    chain(section)
                    membersGrid(section)
                    reports(section)
                }
                .padding(.horizontal, 36).padding(.vertical, 34)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear { name = section.name; purpose = section.purpose ?? "" }
            .onChange(of: sectionID) { _, _ in name = self.section?.name ?? ""; purpose = self.section?.purpose ?? "" }
        } else {
            Text("This category is gone.").foregroundColor(DS.Colors.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ section: BotsLayout.Section) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Button { editingLook = true } label: { CategoryTile(section: section, size: 64) }
                .buttonStyle(LiftButtonStyle())
                .help("Change colour and symbol")
                .popover(isPresented: $editingLook, arrowEdge: .bottom) { lookPicker(section) }
            VStack(alignment: .leading, spacing: 6) {
                TextField("Team name", text: $name, onCommit: { store.renameSection(sectionID, to: name) })
                    .textFieldStyle(.plain).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundColor(DS.Colors.textPrimary)
                TextField("What is this team for? (inbox and calendar, ship the website…)", text: $purpose, onCommit: savePurpose)
                    .textFieldStyle(.plain).font(.system(size: 14)).foregroundColor(DS.Colors.textSecondary)
                    .onChange(of: purpose) { _, _ in savePurpose() }
                HStack(spacing: 8) {
                    pill("\(store.members(of: section).count) bots", "person.2.fill")
                    if let routine = store.reportRoutine(of: sectionID) { pill(routine.schedule.label, "clock.fill") }
                }
                .padding(.top, 4)
            }
            Spacer()
            Button {
                reporting.toggle()
                store.reportToCEO(sectionID)
                if let ceo = store.primary {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { selection.pane = .bot(ceo.id) }
                }
            } label: {
                HStack(spacing: 7) {
                    MotionSymbol(name: "paperplane.fill", size: 12, weight: .semibold, color: .white, trigger: reporting)
                    Text("Report to \(store.primary?.name ?? "CEO") now").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                }
                .padding(.horizontal, 14).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Colors.accent))
            }
            .buttonStyle(.plain)
            .disabled(store.members(of: section).isEmpty)
        }
    }

    private func savePurpose() {
        let trimmed = purpose.trimmingCharacters(in: .whitespaces)
        store.updateCategory(sectionID) { $0.purpose = trimmed.isEmpty ? nil : trimmed }
    }

    /// Members → leader → CEO, drawn as a chain, with the leader and the schedule picked right there.
    private func chain(_ section: BotsLayout.Section) -> some View {
        let members = store.members(of: section)
        let leader = section.leaderID.flatMap { store.bot($0) }
        return HStack(spacing: 0) {
            node(title: "Team", detail: members.isEmpty ? "No bots yet" : members.map(\.name).joined(separator: ", ")) {
                HStack(spacing: -8) {
                    ForEach(members.prefix(5)) { bot in
                        BotAvatar(bot: bot, size: 30, state: store.replying[bot.id] != nil ? .thinking : .idle)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(DS.Colors.surface, lineWidth: 2))
                    }
                    if members.isEmpty { emptyCircle }
                }
            }
            arrow
            node(title: "Leader", detail: leader?.name ?? "No leader: everyone reports") {
                Button { pickingLeader = true } label: {
                    if let leader {
                        BotAvatar(bot: leader, size: 30, state: store.replying[leader.id] != nil ? .thinking : .idle)
                            .overlay(alignment: .top) { Image(systemName: "crown.fill").font(.system(size: 10)).foregroundColor(Color(hex: 0xF5B13D)).offset(y: -10) }
                    } else {
                        emptyCircle.overlay(Image(systemName: "crown").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary))
                    }
                }
                .buttonStyle(LiftButtonStyle())
                .help("Pick the team's leader")
                .popover(isPresented: $pickingLeader, arrowEdge: .bottom) { leaderPicker(members, current: section.leaderID) }
            }
            arrow
            node(title: "Reports to", detail: (store.primary?.name ?? "CEO") + ", the CEO") {
                if let ceo = store.primary { BotAvatar(bot: ceo, size: 30, state: .idle) }
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 6) {
                Text("Report on a schedule").font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Colors.textTertiary)
                Picker("", selection: Binding(get: { scheduleChoice }, set: { setSchedule($0) })) {
                    Text("Only when I ask").tag("off")
                    Text("Every day at 6 pm").tag("daily")
                    Text("Weekdays at 6 pm").tag("weekdays")
                    Text("Fridays at 5 pm").tag("weekly")
                    Text("Every 2 hours").tag("every")
                }
                .labelsHidden().frame(width: 170)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Colors.borderSubtle))
    }

    private var scheduleChoice: String {
        guard let schedule = store.reportRoutine(of: sectionID)?.schedule else { return "off" }
        return schedule.kind.rawValue
    }

    private func setSchedule(_ choice: String) {
        switch choice {
        case "daily": store.setReportSchedule(.init(kind: .daily, hour: 18), for: sectionID)
        case "weekdays": store.setReportSchedule(.init(kind: .weekdays, hour: 18), for: sectionID)
        case "weekly": store.setReportSchedule(.init(kind: .weekly, hour: 17, weekday: 6), for: sectionID)
        case "every": store.setReportSchedule(.init(kind: .every, intervalMinutes: 120), for: sectionID)
        default: store.setReportSchedule(nil, for: sectionID)
        }
    }

    private func membersGrid(_ section: BotsLayout.Section) -> some View {
        let members = store.members(of: section)
        let others = store.bots.filter { bot in !members.contains { $0.id == bot.id } }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Members").font(.system(size: 15, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Menu {
                    if others.isEmpty { Text("Every bot is already here") }
                    ForEach(others) { bot in Button(bot.name) { store.addMember(bot.id, to: sectionID) } }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        Text("Add bot").font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textPrimary)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                ForEach(members) { bot in memberCard(bot, isLeader: section.leaderID == bot.id) }
                if members.isEmpty {
                    Text("Add bots with “Add bot”, or drag them onto this category in the sidebar.")
                        .font(.system(size: 13)).foregroundColor(DS.Colors.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(DS.Colors.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                }
            }
        }
    }

    private func memberCard(_ bot: NativeBot, isLeader: Bool) -> some View {
        let working = store.replying[bot.id] != nil
        return Button { selection.pane = .bot(bot.id) } label: {
            HStack(alignment: .top, spacing: 12) {
                BotAvatar(bot: bot, size: 46, state: working ? .thinking : .idle)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(bot.name).font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                        if isLeader {
                            Label("Leader", systemImage: "crown.fill").labelStyle(.titleAndIcon)
                                .font(.system(size: 9.5, weight: .bold)).foregroundColor(Color(hex: 0xF5B13D))
                        }
                    }
                    Text(bot.description.isEmpty ? "No description yet" : bot.description)
                        .font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary).lineLimit(2)
                    HStack(spacing: 5) {
                        Circle().fill(!bot.isOn ? DS.Colors.textDisabled : working ? DS.Colors.warning : DS.Colors.success).frame(width: 6, height: 6)
                        Text((!bot.isOn ? "Off" : working ? "Working" : "Ready") + " · " + bot.modelLabel)
                            .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isLeader ? Color(hex: 0xF5B13D).opacity(0.45) : DS.Colors.borderSubtle))
            .contentShape(Rectangle())
        }
        .buttonStyle(LiftButtonStyle())
        .contextMenu {
            if isLeader {
                Button("Remove as leader") { store.setLeader(nil, of: sectionID) }
            } else {
                Button("Make leader") { store.setLeader(bot.id, of: sectionID) }
            }
            Button("Remove from team", role: .destructive) { store.removeMember(bot.id, from: sectionID) }
        }
    }

    private func reports(_ section: BotsLayout.Section) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reports to \(store.primary?.name ?? "the CEO")").font(.system(size: 15, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
            let reports = (section.reports ?? []).reversed()
            if reports.isEmpty {
                Text(section.leaderID == nil
                     ? "No reports yet. With no leader, each bot reports for itself."
                     : "No reports yet. The leader sums up the team's work for the CEO.")
                    .font(.system(size: 13)).foregroundColor(DS.Colors.textTertiary)
            }
            ForEach(Array(reports)) { report in
                HStack(alignment: .top, spacing: 12) {
                    if let author = store.bot(report.author) { BotAvatar(bot: author, size: 28, state: .idle) }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(store.bot(report.author)?.name ?? "A bot").font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                            Text(report.at.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                        }
                        Text(LocalizedStringKey(report.text)).font(.system(size: 13)).foregroundColor(DS.Colors.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface1))
            }
        }
    }

    private func node<Icon: View>(title: String, detail: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundColor(DS.Colors.textTertiary)
            icon().frame(height: 34, alignment: .leading)
            Text(detail).font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary).lineLimit(2).frame(maxWidth: 150, alignment: .leading)
        }
    }

    private var arrow: some View {
        FlowArrow().frame(width: 54, height: 12).padding(.horizontal, 6)
    }

    private var emptyCircle: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(DS.Colors.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            .frame(width: 30, height: 30)
    }

    private func pill(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 11.5, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill(DS.Colors.hover))
    }
}

/// A dashed arrow whose dashes run toward the CEO, so reporting reads as motion.
struct FlowArrow: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let phase = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0
                    : -CGFloat(timeline.date.timeIntervalSinceReferenceDate * 18).truncatingRemainder(dividingBy: 10)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2)); line.addLine(to: CGPoint(x: size.width - 6, y: size.height / 2))
                context.stroke(line, with: .color(DS.Colors.accent.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 6], dashPhase: phase))
                var head = Path()
                head.move(to: CGPoint(x: size.width - 8, y: size.height / 2 - 4)); head.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
                head.addLine(to: CGPoint(x: size.width - 8, y: size.height / 2 + 4))
                context.stroke(head, with: .color(DS.Colors.accent.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Cards lift a little under the pointer and press in on click.
struct LiftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LiftBody(configuration: configuration)
    }

    private struct LiftBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .offset(y: hovering && !configuration.isPressed ? -2 : 0)
                .shadow(color: .black.opacity(hovering ? 0.3 : 0), radius: 12, y: 6)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - The org chart on Home

/// The CEO on top, each team below with its leader and members, then bots in no team. Everything opens on click.
struct OrgChart: View {
    @ObservedObject var store: BotsStore
    @ObservedObject var selection: BotsSelection
    var onNewTeam: () -> Void = {}

    var body: some View {
        let teams = store.rootSections
        let filed = Set(store.layout.sections.flatMap { store.memberIDs(of: $0) })
        let free = store.bots.filter { !$0.primary && !filed.contains($0.id) }
        VStack(spacing: 0) {
            if let ceo = store.primary {
                Button { selection.pane = .bot(ceo.id) } label: {
                    VStack(spacing: 8) {
                        BotAvatar(bot: ceo, size: 64, state: store.replying[ceo.id] != nil ? .thinking : .idle)
                        Text(ceo.name).font(.system(size: 14, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                        Text("CEO · " + ceo.modelLabel).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Colors.surface))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.Colors.accent.opacity(0.4)))
                }
                .buttonStyle(LiftButtonStyle())
            }
            Rectangle().fill(DS.Colors.borderStrong).frame(width: 1.5, height: 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(teams) { team in teamCard(team) }
                    if !free.isEmpty { freeCard(free) }
                    Button(action: onNewTeam) {
                        VStack(spacing: 8) {
                            MotionSymbol(name: "plus", size: 16, weight: .semibold)
                            Text("New team").font(.system(size: 12.5, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
                        }
                        .frame(width: 150, height: 150)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(DS.Colors.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(LiftButtonStyle())
                }
                .padding(.vertical, 8).padding(.horizontal, 2)
            }
        }
    }

    private func teamCard(_ team: BotsLayout.Section) -> some View {
        let members = store.members(of: team)
        let leader = team.leaderID.flatMap { store.bot($0) }
        return Button { selection.pane = .category(team.id) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    CategoryTile(section: team, size: 26)
                    Text(team.name).font(.system(size: 13.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let leader {
                        BotAvatar(bot: leader, size: 26, state: store.replying[leader.id] != nil ? .thinking : .idle)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(leader.name).font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                            Label("Leader", systemImage: "crown.fill").font(.system(size: 9.5, weight: .semibold)).foregroundColor(Color(hex: 0xF5B13D))
                        }
                    } else {
                        Text("No leader: everyone reports").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                    }
                }
                HStack(spacing: -6) {
                    ForEach(members.filter { $0.id != leader?.id }.prefix(5)) { bot in
                        BotAvatar(bot: bot, size: 22, state: store.replying[bot.id] != nil ? .thinking : .idle)
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DS.Colors.surface, lineWidth: 1.5))
                    }
                }
                Text(team.purpose ?? "\(members.count) bots").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
            }
            .padding(12)
            .frame(width: 200, height: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Colors.borderSubtle))
        }
        .buttonStyle(LiftButtonStyle())
    }

    private func freeCard(_ bots: [NativeBot]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Not in a team").font(.system(size: 13.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(bots.prefix(10)) { bot in
                    Button { selection.pane = .bot(bot.id) } label: {
                        BotAvatar(bot: bot, size: 30, state: store.replying[bot.id] != nil ? .thinking : .idle)
                    }
                    .buttonStyle(.plain).help(bot.name)
                }
            }
            Text("Drag them onto a team in the sidebar.").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
        }
        .padding(12)
        .frame(width: 200, height: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Colors.borderSubtle))
    }
}
