import RHAPI
import SwiftUI

/// Settings → Devices (SPEC §4.5): paired devices and Revoke with the critical key.
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [DevicesResponse.Device]?
    @State private var revoking: String?

    var body: some View {
        List {
            if let devices {
                ForEach(devices) { device in
                    row(device)
                }
            } else {
                ProgressView()
            }
            if let notice = model.notice {
                Text(notice).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Devices")
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ device: DevicesResponse.Device) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(device.name)
                    if device.current {
                        Text("This iPhone").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(device.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(device.status == .revoked ? String(localized: "Revoked \(device.revokedAt ?? "")") : String(localized: "Paired \(device.pairedAt)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if device.status == .active {
                if revoking == device.id {
                    ProgressView()
                } else {
                    Button("Revoke", role: .destructive) {
                        Task {
                            revoking = device.id
                            if await model.revoke(device.id) { await load() }
                            revoking = nil
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(revoking != nil)
                    .accessibilityIdentifier("devices.revoke.\(device.id)")
                }
            }
        }
    }

    private func load() async {
        if let loaded = await model.devices() { devices = loaded }
    }
}
