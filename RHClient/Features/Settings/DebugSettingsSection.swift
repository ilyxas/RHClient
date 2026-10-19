#if DEBUG
import SwiftUI
import UIKit

/// Debug only. "Export test signature" (PLAN, stage 1): a real Secure Enclave signature in the
/// format of contracts/vectors/ecdsa.json, so the server can add it as a vector.
struct DebugSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var exported = false

    var body: some View {
        Section("Debug") {
            Button("Export test signature") {
                Task {
                    if let vector = await model.exportTestSignature() {
                        UIPasteboard.general.string = vector
                        exported = true
                    }
                }
            }
            .accessibilityIdentifier("debug.exportSignature")
            if exported {
                Text("Copied to the clipboard. Paste it into the thread.").foregroundStyle(.secondary)
            }
        }
    }
}
#endif
