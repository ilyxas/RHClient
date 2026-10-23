import RHAPI
import RHCrypto
import SwiftUI

/// Messages to the Friend session (friend.send). Each one is signed with the normal key;
/// the Mac keeps it as signed and Friend checks the signature itself. Shown in the Chat
/// tab until the RemoteHands chat arrives at stage 3. The list lives only while the app runs.
struct FriendView: View {
    @Environment(AppModel.self) private var model
    @State private var sent: [SentMessage] = []
    @State private var draft = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sent) { message in
                        SentMessageRow(message: message)
                    }
                } footer: {
                    Text("Signed on this iPhone. Friend checks the signature before reading.")
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("friend.list")
            .scrollContentBackground(.hidden)
            .background { AppBackground() }
            .overlay {
                if sent.isEmpty {
                    ContentUnavailableView(
                        "Message to Friend", systemImage: "checkmark.seal",
                        description: Text("Friend sees it as a verified message from you.")
                    )
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Friend")
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
            .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
