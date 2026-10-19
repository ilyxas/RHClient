import RHAPI
import SwiftUI
import VisionKit

/// Camera QR scanner (VisionKit) that reports the first pairing string it sees.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void

    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: @MainActor (String) -> Void
        private var delivered = false

        init(onCode: @escaping @MainActor (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard !delivered, case .barcode(let barcode) = item, let text = barcode.payloadStringValue,
                      text.hasPrefix(PairingString.prefix)
                else { continue }
                delivered = true
                onCode(text)
            }
        }
    }
}
