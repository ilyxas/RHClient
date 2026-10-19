import SwiftUI

/// SPEC §4.2: keys unusable, device revoked or unknown, or the core key does not match.
struct PairingLostView: View {
    let onRePair: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Pairing lost", systemImage: "link.badge.plus")
        } description: {
            Text("This iPhone can no longer sign requests for your Mac. Pair again with a new code from `rhcore pair`; the old pairing is revoked on the Mac.")
        } actions: {
            Button("Re-pair", action: onRePair).buttonStyle(.borderedProminent)
        }
    }
}
