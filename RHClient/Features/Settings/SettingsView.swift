import SwiftUI

/// SPEC §8.7: connection, devices, Face ID reset time, core address, version, Re-pair.
/// The theme switch is in the Home header (SPEC §8.1).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var rePairing = false

    private static let resetChoices: [TimeInterval] = [60, 5 * 60, 15 * 60, 60 * 60]

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                NavigationLink("Connection") { StatusView() }
                    .accessibilityIdentifier("settings.connection")
                NavigationLink("Devices") { DevicesView() }
                    .accessibilityIdentifier("settings.devices")
            }
            Section {
                Picker("Ask for Face ID after", selection: $model.resetInterval) {
                    ForEach(Self.resetChoices, id: \.self) { seconds in
                        Text(Duration.seconds(seconds), format: .units(allowed: [.hours, .minutes], width: .wide))
                            .tag(seconds)
                    }
                }
            } header: {
                Text("Face ID")
            } footer: {
                Text("Time in the background before the app asks for Face ID again.")
            }
            Section("Pairing") {
                LabeledContent("Core address", value: model.record?.coreURL.absoluteString ?? "—")
                Button("Re-pair") { rePairing = true }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
            #if DEBUG
            DebugSettingsSection()
            #endif
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $rePairing) {
            PairingView(onPaired: { rePairing = false })
        }
    }
}
