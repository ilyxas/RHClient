import RHAPI
import SwiftUI

/// Stage 1 status screen: the link to the Mac and a signed ping. Home replaces it in stage 2.
struct StatusView: View {
    @Environment(AppModel.self) private var model
    @State private var pinging = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Mac", value: model.status?.macName ?? model.record?.macName ?? "—")
                    connectionRow
                }
                if let status = model.status {
                    Section("Core") {
                        LabeledContent("Core version", value: status.coreVersion)
                        LabeledContent("Agent", value: status.agentVersion ?? String(localized: "Not running"))
                        LabeledContent("Mode", value: status.mode.rawValue)
                        LabeledContent("Server time", value: status.serverTime)
                    }
                }
                Section {
                    Button {
                        pinging = true
                        Task {
                            await model.ping()
                            pinging = false
                        }
                    } label: {
                        HStack {
                            Text("Ping")
                            Spacer()
                            if pinging { ProgressView() }
                        }
                    }
                    .disabled(pinging)
                    .accessibilityIdentifier("status.ping")
                }
                if let notice = model.notice {
                    Section {
                        Text(notice).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Status")
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("status.settings")
                }
            }
        }
    }

    @ViewBuilder
    private var connectionRow: some View {
        if let connection = model.connection {
            Label {
                Text(connection.title)
            } icon: {
                Image(systemName: connection == .connected ? "checkmark.shield" : "exclamationmark.triangle")
                    .foregroundStyle(connection == .connected ? .green : .orange)
            }
            .accessibilityIdentifier("status.connection")
        } else {
            LabeledContent("Connection") { ProgressView() }
        }
    }
}
