import RHAPI
import RHCrypto
import SwiftUI

/// Switches the tab bar, e.g. Quick Access "+" → Pages, a question → Chat.
struct OpenTabAction {
    let handler: @MainActor (AppTab) -> Void

    @MainActor func callAsFunction(_ tab: AppTab) {
        handler(tab)
    }
}

extension EnvironmentValues {
    @Entry var openTab = OpenTabAction { _ in }
}

/// SPEC §8.2, top to bottom: header, metrics, Quick Access, Needs Attention, Active Agents,
/// Last Activity. Loaded on open, on return from the background and by pull-to-refresh.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openTab) private var openTab
    @AppStorage(ThemePreference.storageKey) private var theme: ThemePreference = .system

    static let agentsShown = 4
    static let activityShown = 5

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    GlassEffectContainer(spacing: 12) {
                        metrics
                    }
                    quickAccess
                    needsAttention
                    activeAgents
                    lastActivity
                    if let notice = model.notice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background { AppBackground() }
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { themeMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("home.settings")
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .agents: AgentsListView()
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.status?.macName ?? model.record?.macName ?? "Mac")
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                if let connection = model.connection {
                    StatusDot(state: connection.dotState)
                    Text(connection.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("home.connection")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }

    private var themeMenu: some View {
        Menu {
            Picker("Theme", selection: $theme) {
                ForEach(ThemePreference.allCases) { choice in
                    Label(choice.title, systemImage: choice.systemImage).tag(choice)
                }
            }
        } label: {
            Label("Theme", systemImage: theme.systemImage)
        }
        .accessibilityIdentifier("home.theme")
    }

    // MARK: - Metrics

    private var metrics: some View {
        HStack(spacing: 12) {
            metric(BuiltinData.cpu, title: String(localized: "CPU"), systemImage: "cpu")
            metric(BuiltinData.memory, title: String(localized: "Memory"), systemImage: "memorychip")
            metric(BuiltinData.diskFree, title: String(localized: "Disk"), systemImage: "internaldrive", caption: String(localized: "free"))
        }
    }

    private func metric(_ id: String, title: String, systemImage: String, caption: String? = nil) -> some View {
        let result = model.homeData[id]
        var text: String?
        var problem: String?
        switch result {
        case .active(.number(let value, let unit), _)?: text = MetricFormat.number(value, unit: unit)
        case .active?: problem = String(localized: "Unexpected value")
        case .pending?: problem = String(localized: "Pending")
        case .error(let message)?: problem = message
        case nil: break
        }
        // "112 GB" + "free": the number in SF Mono, the unit with the caption ("112 GB free").
        var value = text
        var words = caption
        if let text, let space = text.firstIndex(of: " ") {
            value = String(text[..<space])
            words = [String(text[text.index(after: space)...]), caption].compactMap { $0 }.joined(separator: " ")
        }
        return MetricCard(title: title, systemImage: systemImage, value: value, caption: value == nil ? nil : words, problem: problem)
            .accessibilityIdentifier("home.metric.\(id)")
    }

    // MARK: - Quick Access

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "Quick Access"))
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        ForEach(model.quickItems) { item in
                            // Opening pinned pages and actions arrives with Pages (stage 5).
                            ActionTile(title: item.title, systemImage: item.icon ?? (item.kind == .page ? "doc.text" : "bolt")) {
                                openTab(.pages)
                            }
                        }
                        ActionTile(title: String(localized: "Add from Pages"), systemImage: "plus") {
                            openTab(.pages)
                        }
                        .accessibilityIdentifier("home.quick.add")
                    }
                    .padding(.vertical, 2)
                }
            }
            .scrollClipDisabled()
        }
    }

    // MARK: - Needs Attention

    private var needsAttention: some View {
        let approvals = rows(BuiltinData.approvals)
        let questions = rows(BuiltinData.questions)
        let count = (approvals?.count ?? 0) + (questions?.count ?? 0)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "Needs Attention"), count: count)
                .accessibilityIdentifier("home.attention")
            GlassCard {
                if approvals == nil && questions == nil {
                    sourceProblem(BuiltinData.approvals)
                } else if count == 0 {
                    Label("Nothing needs your attention", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(approvals ?? []) { row in
                            // The approval screen arrives at stage 4.
                            StatusRow(title: row.title, subtitle: row.subtitle, status: StatusValue(state: .warn), systemImage: "exclamationmark.shield", time: date(row.at))
                        }
                        ForEach(questions ?? []) { row in
                            Button {
                                openTab(.chat)
                            } label: {
                                StatusRow(title: row.title, subtitle: row.subtitle, status: StatusValue(state: .warn), systemImage: "questionmark.bubble", time: date(row.at))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Active Agents

    private var activeAgents: some View {
        let agents = rows(BuiltinData.agents)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "Active Agents")) {
                if let agents, !agents.isEmpty {
                    NavigationLink("View all", value: HomeRoute.agents)
                        .accessibilityIdentifier("home.agents.all")
                }
            }
            GlassCard {
                if let agents {
                    if agents.isEmpty {
                        Text("No team configured on the Mac.").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(agents.prefix(Self.agentsShown)) { agent in
                                StatusRow(title: agent.title, subtitle: agent.subtitle, status: agent.status)
                                    .accessibilityIdentifier("home.agent.\(agent.id)")
                            }
                        }
                    }
                } else {
                    sourceProblem(BuiltinData.agents)
                }
            }
        }
    }

    // MARK: - Last Activity

    private var lastActivity: some View {
        let activity = rows(BuiltinData.activity)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "Last Activity")) {
                Button("View all") { openTab(.log) }
                    .accessibilityIdentifier("home.activity.all")
            }
            GlassCard {
                if let activity {
                    if activity.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(activity.prefix(Self.activityShown)) { row in
                                StatusRow(title: row.title, subtitle: row.subtitle, status: row.status, time: date(row.at))
                            }
                        }
                    }
                } else {
                    sourceProblem(BuiltinData.activity)
                }
            }
        }
    }

    // MARK: - Helpers

    private func rows(_ id: String) -> [Row]? {
        model.homeData[id]?.value?.rows
    }

    private func date(_ timestamp: String?) -> Date? {
        timestamp.flatMap(ProtocolTime.parse)
    }

    @ViewBuilder
    private func sourceProblem(_ id: String) -> some View {
        switch model.homeData[id] {
        case .error(let message)?:
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        case .pending?:
            Text("Pending").foregroundStyle(.secondary)
        default:
            HStack {
                ProgressView()
                Text("Loading…").foregroundStyle(.secondary)
            }
        }
    }
}

enum HomeRoute: Hashable {
    case agents
}

/// Active Agents → View all: the whole team with statuses.
struct AgentsListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.homeData[BuiltinData.agents]?.value?.rows ?? []) { agent in
                StatusRow(title: agent.title, subtitle: agent.subtitle, status: agent.status)
            }
        }
        .navigationTitle("Agents")
        .refreshable { await model.refresh() }
    }
}

extension ConnectionState {
    var dotState: StatusValue.State {
        switch self {
        case .connected: .ok
        case .unreachable: .warn
        case .authError, .pairingLost: .error
        }
    }
}
