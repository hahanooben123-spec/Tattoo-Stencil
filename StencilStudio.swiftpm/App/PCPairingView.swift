import SwiftUI
import AVFoundation

struct PCPairingView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var scanning = false
    @State private var connecting = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Start Stencil PC på computeren. Brug samme private Wi-Fi på begge enheder, og scan QR-koden på PC'ens parringsside.")
                    Button("Scan QR-kode") {
                        AVCaptureDevice.requestAccess(for:.video) { allowed in
                            Task { @MainActor in
                                if allowed { scanning = true }
                                else { error = "Tillad kamera i Indstillinger, eller indsæt parringskoden nedenfor." }
                            }
                        }
                    }
                    TextEditor(text:$code).frame(minHeight:100).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityLabel("Parringskode fra PC")
                    Button(connecting ? "Forbinder …" : "Forbind PC") {
                        connecting = true; error = nil
                        Task {
                            do { try await model.pairPC(code); dismiss() }
                            catch { self.error = error.localizedDescription }
                            connecting = false
                        }
                    }.disabled(connecting || code.isEmpty)
                    if let error { Text(error).foregroundStyle(.red) }
                } footer: { Text("Billeder behandles på din PC. PC'en skal være tændt. Parringen gemmes sikkert på denne enhed.") }
                if model.pcPairing != nil {
                    Button("Glem PC",role:.destructive) { model.forgetPC(); dismiss() }.disabled(connecting)
                }
            }
            .navigationTitle("Forbind PC")
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Luk") { dismiss() } } }
            .sheet(isPresented:$scanning) {
                NavigationStack {
                    PCQRScanner { value in code = value; scanning = false }
                        .navigationTitle("Scan PC-koden")
                        .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Luk") { scanning = false } } }
                }
            }
        }
    }
}

private struct PCQRScanner: UIViewControllerRepresentable {
    let received: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController(); controller.received = received; return controller
    }
    func updateUIViewController(_ controller: ScannerController, context: Context) { }
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var received: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label:"StencilStudio.QR")
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        guard let camera = AVCaptureDevice.default(for:.video),
              let input = try? AVCaptureDeviceInput(device:camera), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self,queue:.main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session:session)
        layer.videoGravity = .resizeAspectFill; view.layer.addSublayer(layer); preview = layer
        let capture = session
        queue.async { capture.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { let capture = session; queue.async { capture.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        delivered = true; stop(); received?(code)
    }
}
