import RHAPI
import SwiftUI
import UIKit

/// Scan the QR from `rhcore pair`, then wait for y/n on the Mac (SPEC §4.2).
/// In Debug the pairing string can also come from the clipboard or `-RHPairing`.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    /// Called after a successful pairing (used when the view is a Re-pair sheet).
    var onPaired: (() -> Void)?

    @State private var scanning = false
    @State private var parseError: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            content
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Pair with your Mac")
                .sheet(isPresented: $scanning) {
                    QRScannerView { text in
                        scanning = false
                        start(text)
                    }
                    .ignoresSafeArea()
                }
        }
        .task {
            #if DEBUG
            if model.pairingProgress == nil, let text = model.takeLaunchPairing() {
                start(text)
            }
            #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.pairingProgress {
        case .creatingKeys:
            ProgressView("Creating keys…")
        case .waitingForMac(let fingerprint):
            VStack(spacing: 20) {
                ProgressView()
                Text("Confirm on your Mac").font(.title2.bold())
                Text("Check that the terminal shows the same fingerprint, then answer y.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text(fingerprint)
                    .font(.system(.title2, design: .monospaced))
                    .accessibilityIdentifier("pairing.fingerprint")
                Button("Cancel", role: .cancel) { task?.cancel() }
            }
        case .failed(let message):
            VStack(spacing: 16) {
                Label("Pairing failed", systemImage: "exclamationmark.triangle").font(.title2.bold())
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Try again") { model.cancelPairing() }.buttonStyle(.borderedProminent)
            }
        case nil:
            VStack(spacing: 16) {
                Image(systemName: "qrcode.viewfinder").font(.system(size: 64)).foregroundStyle(.tint)
                Text("On your Mac run `rhcore pair` and scan the QR code it shows.")
                    .multilineTextAlignment(.center)
                if QRScannerView.isAvailable {
                    Button("Scan QR code") { scanning = true }.buttonStyle(.borderedProminent)
                }
                #if DEBUG
                Button("Paste pairing string") {
                    if let text = UIPasteboard.general.string { start(text) }
                }
                .accessibilityIdentifier("pairing.paste")
                #endif
                if let parseError {
                    Text(parseError).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
        }
    }

    private func start(_ text: String) {
        let pairing: PairingString
        do {
            pairing = try model.parsePairing(text)
        } catch {
            parseError = String(localized: "This is not a RemoteHands pairing code (\(String(describing: error))).")
            return
        }
        parseError = nil
        task = Task {
            if await model.pair(pairing, deviceName: UIDevice.current.name) {
                onPaired?()
            }
        }
    }
}
