import RHAPI
import RHCrypto
import SwiftUI

/// The Chat tab: the owner's messages to the channel agent with their state and the agent's
/// replies (friend.send / friend.messages), and the agent's questions waiting for a decision
/// (friend.questions / friend.decide). The agent is whoever `status.channel` names; every name on
/// this tab is its title, so a switch on the Mac renames the tab with the next status. "friend"
/// in identifiers is the mechanism's name, not the agent's.
///
/// A message is a **question** (answered in text; the agent's gate lets read-only tools through
/// and routes anything else through a decision) or a **task** (the agent works). Under each one:
/// Accepted by the Mac → received by the agent → working / waiting for a decision → answered; or
/// not accepted, or replaced by a newer message. The states after "Accepted by the Mac" and the
/// replies are what the agent reports over the Mac's local socket, not signed facts: only the
/// owner's signature on the way in and the Mac's on the way out are verified.
///
/// A question of the agent shows who asks, its text and the exact action in full, no truncation:
/// what you allow is exactly that tool call, nothing wider. **Allow** signs with the critical key
/// (a fresh Face ID), **Deny** with the normal key. The Mac keeps every decision as signed; the
/// gate lets exactly that call through once, within two minutes.
struct FriendView: View {
    @Environment(AppModel.self) private var model
    @State private var decided: [DecidedQuestion] = []
    @State private var deciding: String?
    @State private var draft = ""
    @State private var kind: MessageKind = .question
    @State private var sending = false
    @State private var acting: String?
    @FocusState private var composing: Bool

    /// How often the tab asks the core what changed while it is on screen (seconds).
    static let pollInterval: Duration = .seconds(3)

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
                    ForEach(model.chat.messages) { message in
                        MessageRow(
                            message: message,
                            agent: agent,
                            agentState: model.agentState,
                            busy: acting == message.id,
                            makeTask: canMakeTask(message) ? { makeTask(message) } : nil,
                            sendAgain: canSendAgain(message) ? { sendAgain(message) } : nil
                        )
                    }
                    ForEach(model.chat.outgoing) { item in
                        OutgoingRow(
                            item: item,
                            busy: acting == item.id,
                            retry: { retry(item) },
                            discard: { model.discard(item) }
                        )
                    }
                } header: {
                    if !model.chat.messages.isEmpty || !model.chat.outgoing.isEmpty { Text("Messages") }
                } footer: {
                    Text(
                        "Signed on this iPhone; \(agent) checks the signature before reading. After “Accepted by the Mac”, the states and replies are what \(agent) reports, not verified facts."
                    )
                }
            }
            .listStyle(.plain)
            // A tap outside the composer, or a drag of the list, puts the keyboard away. The tap
            // is simultaneous, so Allow, Deny and text selection in the list still work.
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { composing = false })
            .accessibilityIdentifier("friend.list")
            .scrollContentBackground(.hidden)
            .background { AppBackground() }
            .overlay {
                if model.chat.messages.isEmpty && model.chat.outgoing.isEmpty && model.questions.isEmpty && decided.isEmpty {
                    ContentUnavailableView(
                        "Message to \(agent)", systemImage: "checkmark.seal",
                        description: Text("\(agent) sees it as a verified message from you and answers here. Questions from \(agent) appear here too.")
                    )
                }
            }
            .refreshable {
                await model.loadQuestions()
                await model.pollMessages()
            }
            .task {
                // While the tab is on screen: the agent's questions once, then what changed
                // every few seconds (receipts, replies, state). Cancelled when the tab goes away.
                await model.loadQuestions()
                while !Task.isCancelled {
                    await model.pollMessages()
                    model.markChatSeen()
                    try? await Task.sleep(for: Self.pollInterval)
                }
            }
            .onChange(of: model.chat.newestReplySeq) { model.markChatSeen() }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle(agent)
        }
    }

    /// A question may become a task while it still matters (not replaced, not refused).
    private func canMakeTask(_ message: FriendMessage) -> Bool {
        message.kind == .question && message.state != .superseded && message.state != .rejected
    }

    /// Worth sending once more: the agent's verifier refused it, or the agent is not running.
    private func canSendAgain(_ message: FriendMessage) -> Bool {
        message.state == .rejected || (message.state == .received && model.agentState == "stopped")
    }

    private func makeTask(_ message: FriendMessage) {
        act(message.id) { await model.makeTask(message) }
    }

    private func sendAgain(_ message: FriendMessage) {
        act(message.id) { await model.sendAgain(message) }
    }

    private func retry(_ item: OutgoingMessage) {
        act(item.id) { await model.retry(item) }
    }

    /// One action at a time; the row shows it is busy meanwhile.
    private func act(_ id: String, _ work: @escaping @MainActor () async -> Void) {
        guard acting == nil else { return }
        acting = id
        Task {
            await work()
            acting = nil
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            Picker("Kind", selection: $kind) {
                Text("Question").tag(MessageKind.question)
                Text("Task").tag(MessageKind.task)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .accessibilityIdentifier("friend.kind")
            HStack(alignment: .bottom, spacing: 8) {
                TextField(kind == .question ? "Ask \(agent)" : "Task for \(agent)", text: $draft, axis: .vertical)
                    .focused($composing)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        draft = ""  // the message is in the list from now on, accepted or waiting for Retry
        await model.send(text, kind: kind)
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

/// One of the owner's messages as the core keeps it: the text, its kind, the state under it, the
/// agent's replies, and what the owner can do next.
private struct MessageRow: View {
    let message: FriendMessage
    let agent: String
    /// agents.status of the channel agent ("working", "stopped", …), to tell "on it" from "not running".
    let agentState: String?
    let busy: Bool
    let makeTask: (() -> Void)?
    let sendAgain: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(message.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Text(message.kind == .task ? "Task" : "Question")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Label(status, systemImage: icon)
                .font(.footnote)
                .foregroundStyle(color)
            ForEach(message.replies) { reply in
                ReplyBubble(reply: reply, agent: agent)
            }
            if makeTask != nil || sendAgain != nil {
                HStack(spacing: 12) {
                    if let sendAgain {
                        Button(action: sendAgain) {
                            Label("Send again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("friend.sendAgain")
                    }
                    if let makeTask {
                        Button(action: makeTask) {
                            Label("Make it a task", systemImage: busy ? "ellipsis" : "hammer")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .foregroundStyle(Palette.onAccent)
                        .accessibilityIdentifier("friend.makeTask")
                    }
                }
                .disabled(busy)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("friend.message")
    }

    private func time(_ stamp: String?) -> String {
        stamp.flatMap { ProtocolTime.parse($0) }.map { $0.formatted(date: .omitted, time: .standard) } ?? stamp ?? ""
    }

    /// What the owner sees under the message. Everything after "Accepted by the Mac" is the agent
    /// side's report (the footer says so).
    private var status: String {
        switch message.state {
        case .accepted:
            String(localized: "Accepted by the Mac · \(time(message.acceptedAt))")
        case .received where agentState == "stopped":
            String(localized: "\(agent) is not running · received \(time(message.receivedAt))")
        case .received:
            String(localized: "\(agent) is on it · received \(time(message.receivedAt))")
        case .waiting:
            String(localized: "\(agent) is waiting for your decision")
        case .answered:
            String(localized: "Answered · \(time(message.closedAt))")
        case .rejected:
            String(localized: "Not accepted by \(agent): \(message.rejectCode ?? "rejected")")
        case .superseded:
            String(localized: "Replaced by a newer message")
        }
    }

    private var icon: String {
        switch message.state {
        case .accepted: "checkmark.seal"
        case .received where agentState == "stopped": "power.circle"
        case .received: "ellipsis.circle"
        case .waiting: "questionmark.bubble"
        case .answered: "checkmark.bubble"
        case .rejected: "exclamationmark.triangle"
        case .superseded: "arrow.uturn.forward"
        }
    }

    private var color: Color {
        switch message.state {
        case .accepted, .answered: Palette.ok
        case .received where agentState == "stopped": .orange
        case .received, .superseded: .secondary
        case .waiting: .orange
        case .rejected: .red
        }
    }
}

/// One reply of the agent: a progress note on the way, or the answer.
private struct ReplyBubble: View {
    let reply: FriendReply
    let agent: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(agent) · \(ProtocolTime.parse(reply.at).map { $0.formatted(date: .omitted, time: .shortened) } ?? reply.at)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(reply.text)
                .font(reply.kind == .final ? .body : .callout.italic())
                .foregroundStyle(reply.kind == .final ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(.quaternary.opacity(reply.kind == .final ? 0.5 : 0.25), in: .rect(cornerRadius: 12))
        .accessibilityIdentifier(reply.kind == .final ? "friend.reply" : "friend.progress")
    }
}

/// A message the Mac has not accepted yet: on its way, or not sent, with Retry.
private struct OutgoingRow: View {
    let item: OutgoingMessage
    let busy: Bool
    let retry: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Label(item.failure ?? String(localized: "Sending…"), systemImage: item.failure == nil ? "clock" : "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(item.failure == nil ? Color.secondary : Color.red)
            if item.failure != nil {
                HStack(spacing: 12) {
                    Button(action: retry) {
                        Label(busy ? "Sending…" : "Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .foregroundStyle(Palette.onAccent)
                    .accessibilityIdentifier("friend.retry")
                    Button(role: .destructive, action: discard) {
                        Label("Discard", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("friend.discard")
                }
                .disabled(busy)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("friend.message")
    }
}
