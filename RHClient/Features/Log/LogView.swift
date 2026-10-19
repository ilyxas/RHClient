import RHAPI
import RHCrypto
import SwiftUI

/// SPEC §8.5: the core journal and chat messages, newest first. Filters All / Commands /
/// Approvals / Chat / Errors, search, read only. Pages load as the list scrolls.
struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var feed = LogFeed()
    @State private var filter: LogFilter = .all
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(feed.entries) { entry in
                        LogEntryRow(entry: entry)
                    }
                    if feed.next != nil {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .task(id: feed.next) { await feed.loadMore(model) }
                    }
                } header: {
                    filterBar
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { AppBackground() }
            .overlay { emptyState }
            .navigationTitle("Log")
            .searchable(text: $search, prompt: Text("Search the log"))
            .refreshable { await feed.reload(model, filter: filter, query: search) }
            .task(id: LogQuery(filter: filter, search: search)) {
                // Wait for typing to pause before asking the Mac.
                if !search.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
                guard !Task.isCancelled else { return }
                await feed.reload(model, filter: filter, query: search)
            }
            .accessibilityIdentifier("log.list")
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LogFilter.allCases, id: \.self) { choice in
                    Button {
                        filter = choice
                    } label: {
                        Text(choice.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(filter == choice ? Palette.onAccent : Color.primary)
                    .glassEffect(filter == choice ? .regular.tint(Palette.accent).interactive() : .regular.interactive(), in: .capsule)
                    .accessibilityAddTraits(filter == choice ? .isSelected : [])
                    .accessibilityIdentifier("log.filter.\(choice.rawValue)")
                }
            }
            .padding(.vertical, 6)
        }
        .scrollClipDisabled()
        .textCase(nil)
    }

    @ViewBuilder
    private var emptyState: some View {
        if feed.entries.isEmpty {
            if feed.loading {
                ProgressView()
            } else if let problem = feed.problem {
                ContentUnavailableView("Log unavailable", systemImage: "exclamationmark.triangle", description: Text(problem))
            } else if feed.loaded {
                if search.isEmpty {
                    ContentUnavailableView("No entries", systemImage: "list.bullet.rectangle", description: Text("Nothing matches this filter yet."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
    }
}

private struct LogQuery: Equatable {
    let filter: LogFilter
    let search: String
}

/// Pages of log.list for one filter and search. A reload starts a new generation, so a
/// late answer for an old filter is dropped.
@MainActor
@Observable
final class LogFeed {
    static let pageSize = 50

    private(set) var entries: [LogEntry] = []
    private(set) var next: String?
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var problem: String?
    private var request = LogRequest()
    private var generation = 0

    func reload(_ model: AppModel, filter: LogFilter, query: String) async {
        generation += 1
        let mine = generation
        request = LogRequest(filter: filter, query: query.trimmingCharacters(in: .whitespaces), limit: Self.pageSize)
        loading = true
        defer { if mine == generation { loading = false } }
        let page = await model.log(request)
        guard mine == generation else { return }
        loaded = true
        guard let page else {
            problem = model.notice ?? model.connection?.title
            return
        }
        problem = nil
        entries = page.entries
        next = page.next
    }

    func loadMore(_ model: AppModel) async {
        guard let cursor = next, !loading else { return }
        let mine = generation
        var more = request
        more.before = cursor
        loading = true
        defer { if mine == generation { loading = false } }
        guard let page = await model.log(more), mine == generation else { return }
        // A cursor is a journal position, so pages never overlap; skip ids seen anyway.
        let seen = Set(entries.map(\.id))
        entries += page.entries.filter { !seen.contains($0.id) }
        next = page.next
    }
}

struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(entry.kind == .error ? Color.red : entry.kind == .command ? Palette.accent : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.body)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                if let date = ProtocolTime.parse(entry.ts) {
                    Text(date, format: .dateTime.day().month(.abbreviated).hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowBackground(Color.clear)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("log.entry")
    }
}

extension LogFilter {
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .commands: String(localized: "Commands")
        case .approvals: String(localized: "Approvals")
        case .chat: String(localized: "Chat")
        case .errors: String(localized: "Errors")
        }
    }
}

extension LogEntry.Kind {
    var systemImage: String {
        switch self {
        case .command: "terminal"
        case .approval: "checkmark.shield"
        case .chat: "bubble.left"
        case .error: "exclamationmark.triangle"
        case .system, .other: "gearshape"
        }
    }
}
