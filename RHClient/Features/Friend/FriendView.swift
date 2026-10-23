import RHAPI
import RHCrypto
import SwiftUI

/// The Chat tab until the RemoteHands chat arrives at stage 3: the channel agent's questions
/// waiting for a decision (friend.questions / friend.decide) and messages to it (friend.send).
/// The agent is whoever `status.channel` names; every name on this tab is its title, so a
/// switch on the Mac renames the tab with the next status. "friend" in identifiers is the
/// mechanism's name, not the agent's.
///
/// A question shows who asks, its text and the exact action in full, no truncation: what you
/// allow is exactly that tool call, nothing wider. **Allow** signs with the critical key (a fresh
/// Face ID), **Deny** with the normal key. The Mac keeps every decision as signed; the gate lets
/// exactly that call through once, within two minutes.
struct FriendView: View {
    @Environment(AppModel.self) private var model
    @State private var sent: [SentMessage] = []
    @State private var decided: [DecidedQuestion] = []
    @State private var deciding: String?
    @State private var draft = ""
    @State private var sending = false

    /// The agent's name on screen; a neutral word until the first status names it.
    private var agent: String { model.channel?.title ?? String(localized: "Agent") }

    var body: some View {
        NavigationStack {
            List {
                if !model.questions.isEmpty || !decided.isEmpty {
                    Section {
                        ForEach(model.questions) { question in
                            QuestionCard(
                                question: question,
                                asker: agent,
                                busy: deciding == question.id,
                                decide: { decision in Task { await decide(question, decision) } }
                            )
                        }
                        ForEach(decided) { item in
                            DecidedRow(item: item)
                        }
                    } header: {
                        Text("Decisions")
                    } footer: {
                        Text("Allow needs Face ID and lets \(agent) run exactly this call once, within two minutes.")
                    }
                }
                Section {
                    ForEach(sent) { message in
                        SentMessageRow(message: message)
                    }
                } header: {
                    if !sent.isEmpty { Text("Messages") }
                } footer: {
                    Text("Signed on this iPhone. \(agent) checks the signature before reading.")
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("friend.list")
            .scrollContentBackground(.hidden)
            .background { AppBackground() }
            .overlay {
                if sent.isEmpty && model.questions.isEmpty && decided.isEmpty {
                    ContentUnavailableView(
                        "Message to \(agent)", systemImage: "checkmark.seal",
                        description: Text("\(agent) sees it as a verified message from you. Questions from \(agent) appear here too.")
                    )
                }
            }
            .refreshable { await model.loadQuestions() }
            .task { await model.loadQuestions() }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle(agent)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .accessibilityIdentifier("friend.input")
            Button {
                Task { await send() }
            } label: {
                Image(systemName: sending ? "ellipsis" : "arrow.up")
                    .font(.headline)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.onAccent)
            .glassEffect(.regular.tint(Palette.accent).interactive(), in: .circle)
            .disabled(sending || model.channel == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("friend.send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        let index = sent.count
        sent.append(SentMessage(text: text, state: .sending))
        if let answer = await model.sendToFriend(text) {
            sent[index].state = .accepted(answer.acceptedAt)
            draft = ""
        } else {
            sent[index].state = .failed(model.notice ?? model.connection?.title ?? String(localized: "Not sent"))
        }
    }

    private func decide(_ question: FriendQuestion, _ decision: FriendDecision) async {
        guard deciding == nil else { return }
        deciding = question.id
        defer { deciding = nil }
        if let answer = await model.decide(question, decision) {
            decided.insert(DecidedQuestion(question: question, decision: decision, acceptedAt: answer.acceptedAt), at: 0)
        } else if !model.questions.contains(where: { $0.id == question.id }) {
            // Gone from the list without our decision: answered elsewhere or withdrawn.
            decided.insert(DecidedQuestion(question: question, decision: nil, acceptedAt: nil), at: 0)
        }
    }
}

/// One question: who asks, the full text, the exact action, Deny and Allow.
private struct QuestionCard: View {
    let question: FriendQuestion
    /// The channel agent's title: the owner sees whose action this is before deciding.
    let asker: String
    let busy: Bool
    let decide: (FriendDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("\(asker) asks", systemImage: "questionmark.bubble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("\(asker) asks"))
                    .accessibilityIdentifier("friend.question.asker")
                Spacer()
                if let at = ProtocolTime.parse(question.askedAt) {
                    Text(at, format: .relative(presentation: .named))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(question.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityIdentifier("friend.question.text")
            VStack(alignment: .leading, spacing: 4) {
                Text(question.tool.map { "Exact action · \($0)" } ?? "Exact action")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(question.action)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                    .accessibilityIdentifier("friend.question.action")
            }
            HStack(spacing: 12) {
                Button(role: .cancel) {
                    decide(.deny)
                } label: {
                    Label("Deny", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("friend.deny")
                Button {
                    decide(.allow)
                } label: {
                    Label("Allow", systemImage: busy ? "ellipsis" : "faceid")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .foregroundStyle(Palette.onAccent)
                .accessibilityIdentifier("friend.allow")
            }
            .disabled(busy)
            .controlSize(.large)
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
        // No identifier on the stack: it would make the card one element and hide the text,
        // action and buttons from accessibility (and from the UI test).
    }
}

/// A question this phone has answered (or that went away), kept while the app runs.
struct DecidedQuestion: Identifiable, Equatable {
    let id = UUID()
    let question: FriendQuestion
    /// nil: the question left the list without a decision from this phone.
    let decision: FriendDecision?
    let acceptedAt: String?
}

private struct DecidedRow: View {
    let item: DecidedQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.question.text)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Label(status, systemImage: icon)
                .font(.footnote)
                .foregroundStyle(color)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("friend.decided")
    }

    private var time: String {
        item.acceptedAt.flatMap { ProtocolTime.parse($0) }.map { $0.formatted(date: .omitted, time: .standard) } ?? ""
    }

    private var status: String {
        switch item.decision {
        case .allow?: String(localized: "Allowed · accepted by the Mac · \(time)")
        case .deny?: String(localized: "Denied · accepted by the Mac · \(time)")
        case nil: String(localized: "No longer open")
        }
    }

    private var icon: String {
        switch item.decision {
        case .allow?: "checkmark.seal"
        case .deny?: "xmark.seal"
        case nil: "clock.badge.xmark"
        }
    }

    private var color: Color {
        switch item.decision {
        case .allow?: Palette.ok
        case .deny?: .secondary
        case nil: .secondary
        }
    }
}

struct SentMessage: Identifiable, Equatable {
    enum State: Equatable {
        case sending
        /// The Mac accepted it at this time (UTC, protocol format).
        case accepted(String)
        case failed(String)
    }

    let id = UUID()
    let text: String
    var state: State
}

private struct SentMessageRow: View {
    let message: SentMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Label(status, systemImage: icon)
                .font(.footnote)
                .foregroundStyle(color)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("friend.message")
    }

    private var status: String {
        switch message.state {
        case .sending: String(localized: "Sending…")
        case .accepted(let at):
            String(localized: "Accepted by the Mac · \(ProtocolTime.parse(at).map { $0.formatted(date: .omitted, time: .standard) } ?? at)")
        case .failed(let reason): reason
        }
    }

    private var icon: String {
        switch message.state {
        case .sending: "clock"
        case .accepted: "checkmark.seal"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch message.state {
        case .sending: .secondary
        case .accepted: Palette.ok
        case .failed: .red
        }
    }
}
