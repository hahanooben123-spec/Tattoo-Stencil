import Foundation
import SwiftUI
import UIKit
import Darwin

@MainActor
final class LocalAIModel: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var busy = false
    @Published private(set) var cancelling = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Hent modellen én gang. Derefter kan du teste uden internet."
    @Published private(set) var reference: CGImage?
    @Published private(set) var stencil: CGImage?
    @Published private(set) var sourceData: Data?
    @Published private(set) var seconds: Double?
    @Published private(set) var peakMB = 0
    @Published private(set) var exported: URL?
    @Published var error: String?
    private let engine = LocalAIEngine()
    private var work: Task<Void,Never>?
    private var meter: Task<Void,Never>?
    private var operationID = UUID()

    func refreshInstallation() async {
        do {
            installed = try await engine.isInstalled()
            if installed { status = "Model klar · vælg reference og dan stencil på iPad" }
        }
        catch { self.error = error.localizedDescription }
    }
    func select(_ data: Data) {
        guard !busy else { return }
        do {
            guard data.count <= 50*1024*1024 else { throw LocalAIError.invalidImage }
            let input = try LocalAIImages.prepare(data)
            sourceData = data; reference = input.reference; stencil = nil; exported = nil; seconds = nil
            status = installed ? "Reference klar · dan stencil på iPad" : "Reference klar · hent modellen først"
        } catch { self.error = error.localizedDescription }
    }
    func install() {
        run { engine,report in try await engine.install(progress:report); return nil }
    }
    func generate() {
        guard installed, let data = sourceData else { return }
        run { engine,report in try await engine.generate(data:data,progress:report) }
    }
    private func run(_ operation: @escaping @Sendable (LocalAIEngine,@escaping @Sendable (Double,String)->Void) async throws -> LocalAIOutput?) {
        guard !busy else { return }
        busy = true; cancelling = false; error = nil; progress = 0; peakMB = 0
        operationID = UUID()
        let id = operationID
        // UIKit backgrounding can suspend compute; keep the display awake only while processing.
        UIApplication.shared.isIdleTimerDisabled = true
        meter = Task {
            while !Task.isCancelled {
                peakMB = max(peakMB,Self.memoryFootprintMB())
                try? await Task.sleep(for:.milliseconds(250))
            }
        }
        let engine = engine
        work = Task {
            defer {
                meter?.cancel(); meter = nil; work = nil; busy = false; cancelling = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do {
                let result = try await operation(engine) { [weak self] value,message in
                    Task { @MainActor in
                        guard let self, self.busy, !self.cancelling, self.operationID == id else { return }
                        self.progress = value; self.status = message
                    }
                }
                try Task.checkCancellation()
                installed = try await engine.isInstalled()
                if let result {
                    reference = result.reference; stencil = result.stencil; seconds = result.seconds; exported = nil
                    status = "Stencil klar · kontrollér øjne og proportioner mod originalen"
                } else { status = "Model klar · vælg reference og dan stencil på iPad" }
                progress = 1
            } catch {
                installed = (try? await engine.isInstalled()) ?? false
                if error is CancellationError || Task.isCancelled { status = "Afbrudt" }
                else { self.error = error.localizedDescription; status = "Behandlingen kunne ikke afsluttes" }
            }
        }
    }
    func cancel() {
        guard busy else { return }
        cancelling = true; status = "Afbryder · venter på den igangværende GPU-operation"
        work?.cancel()
        // Stay busy until the SDK has actually finished cancellation.
    }
    func memoryWarning() { cancel(); status = "iPad'en mangler hukommelse · afbryder testen" }
    func export() {
        guard let stencil, !busy else { return }
        do {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Stencil-lokal-\(UUID().uuidString).png")
            guard let data = UIImage(cgImage:stencil).pngData() else { throw LocalAIError.noImage }
            try data.write(to:file,options:.atomic); exported = file
        } catch { self.error = error.localizedDescription }
    }
    static func memoryFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
                task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint/1024/1024) : 0
    }
}
