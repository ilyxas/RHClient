import SwiftUI

/// Pairing first, then the tab bar; Pairing lost in between when the link breaks.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var rePairing = false
    @State private var wasInBackground = false

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView()
            case .unpaired:
                PairingView()
            case .pairingLost:
                if rePairing {
                    PairingView(onPaired: { rePairing = false })
                } else {
                    PairingLostView(onRePair: { rePairing = true })
                }
            case .paired:
                RootTabView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active where wasInBackground:
                wasInBackground = false
                Task { await model.becameActive() }
            case .background:
                wasInBackground = true
                model.enteredBackground()
            default: break
            }
        }
    }
}
