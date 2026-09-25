#if os(iOS)
import SqueakCore
import SwiftUI
import VisionKit

struct PairView: View {
    @EnvironmentObject var model: AppModel
    @State private var scanning = false
    @State private var pasted = ""
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image("duck", bundle: .module)
                    .resizable().scaledToFit().frame(width: 96, height: 96)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    .accessibilityHidden(true)
                Text("Squeak").font(.largeTitle.bold())
                Text("See what your agents are doing on your Mac, and answer them from here.")
                    .foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "On your Mac, open Squeak and choose iPhone.")
                    step(2, "Click Pair an iPhone.")
                    step(3, "Scan the code it shows.")
                }
                Button(DataScannerViewController.isSupported ? "Scan the code" : "Camera not available") {
                    scanning = true
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!DataScannerViewController.isSupported || working)

                DisclosureGroup("Paste a pairing link instead") {
                    TextField("squeak://pair?d=…", text: $pasted, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    Button("Pair") { Task { await pair(pasted) } }.disabled(pasted.isEmpty || working)
                }
                .foregroundStyle(Theme.muted)

                if let problem = model.problem {
                    Text(problem).foregroundStyle(Theme.needsYou).font(.footnote)
                }
            }
            .padding(24)
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .sheet(isPresented: $scanning) {
            QRScanner { code in
                scanning = false
                Task { await pair(code) }
            }
            .ignoresSafeArea()
        }
    }

    private func pair(_ text: String) async {
        working = true
        await model.pair(with: text)
        working = false
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.footnote.bold()).frame(width: 22, height: 22)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
            Text(text)
        }
    }
}

struct AwaitingApprovalView: View {
    @EnvironmentObject var model: AppModel
    let code: String
    let mac: String

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("Approve on \(mac)").font(.title2.bold())
            Text("Your Mac shows a code. Approve only if it matches this one.")
                .multilineTextAlignment(.center).foregroundStyle(Theme.muted)
            Text("\(code.prefix(3)) \(code.suffix(3))")
                .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                .tracking(4)
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
            ProgressView().padding(.top, 8)
            if let problem = model.problem {
                Text(problem).foregroundStyle(Theme.needsYou).font(.footnote)
            }
            Spacer()
            Button("Cancel") { model.unpair() }.foregroundStyle(Theme.muted)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
    }
}

/// VisionKit's live QR scanner, stopping at the first Squeak code it sees.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(code) in items {
                if let value = code.payloadStringValue, value.hasPrefix("squeak://pair"), !done {
                    done = true
                    scanner.stopScanning()
                    onCode(value)
                }
            }
        }
    }
}
#endif
