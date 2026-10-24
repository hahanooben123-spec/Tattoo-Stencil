import SwiftUI
import StencilCore

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var parameters = Preset.portrait.parameters
    @Published var styles = Dictionary(uniqueKeysWithValues: LayerKind.allCases.map { ($0, LayerStyle()) })
    @Published var imported: ImportedImage?
    @Published var result: StencilResult?
    @Published var isBusy = false
    @Published var progress = 0.0
    @Published var status = "Import a reference to begin"
    @Published var error: String?
    @Published var exportURL: URL?
    @Published var widthMM = 150.0
    @Published var transparent = false
    @Published var inverted = false
    @Published var exportFormat = ExportFormat.png
    @Published var debugStage = DebugStage.stencil
    @Published var debugImage: CGImage?
    private var worker: Task<StencilResult, Error>?
    private var importWorker: Task<ImportedImage, Error>?
    private var debounce: Task<Void, Never>?
    private var revision = UUID()

    var sourceSize: String {
        guard let source = imported?.original else { return "No reference" }
        return "\(source.width) × \(source.height) px"
    }
    var previewScale: Double {
        guard let source = imported?.original, let result else { return 1 }
        return Double(result.width) / Double(source.width)
    }
    var heightMM: Double {
        guard let source = imported?.original else { return widthMM }
        return widthMM * Double(source.height) / Double(source.width)
    }

    func cancel() {
        revision = UUID(); worker?.cancel(); importWorker?.cancel(); debounce?.cancel()
        isBusy = false; status = "Cancelled"
    }

    func importData(_ data: Data) {
        cancel(); result = nil; debugImage = nil; imported = nil; exportURL = nil
        isBusy = true; progress = 0; status = "Decoding reference"
        let id = revision
        let task = Task.detached(priority: .userInitiated) { try ImageImportService.load(data) }
        importWorker = task
        Task {
            do {
                let image = try await task.value
                guard revision == id else { return }
                imported = image; importWorker = nil; schedulePreview()
            } catch { finish(error, revision: id) }
        }
    }

    func schedulePreview() {
        guard let imported else { return }
        cancel(); exportURL = nil
        let id = revision, source = imported.preview
        // Length and area controls are specified in native source pixels.
        let scale = Double(source.width) / Double(imported.original.width)
        var p = parameters
        p.minimumContourLength *= scale
        p.minimumRegionArea = max(1, Int(Double(p.minimumRegionArea) * scale * scale))
        p.minimumHighlightArea = max(1, Int(Double(p.minimumHighlightArea) * scale * scale))
        p.smoothing *= scale
        let snapshot = p
        isBusy = true; progress = 0; status = "Preview pending"
        debounce = Task {
            do {
                try await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled, revision == id else { return }
                let task = Task.detached(priority: .userInitiated) {
                    try StencilProcessingCoordinator().process(source, parameters: snapshot) { [weak self] fraction, stage in
                        Task { @MainActor in
                            guard let self, self.revision == id else { return }
                            self.progress = fraction; self.status = stage
                        }
                    }
                }
                worker = task
                let output = try await task.value
                guard revision == id else { return }
                result = output; worker = nil; updateDebug(); isBusy = false
                status = "Preview · \(output.outlines.count) outlines · \(output.shadows.count) shadow paths"
            } catch { finish(error, revision: id) }
        }
    }

    func updateDebug() {
        guard let result, debugStage != .stencil else { debugImage = nil; return }
        debugImage = try? StencilRenderer.debugImage(result, stage: debugStage)
    }

    func export() {
        guard let imported else { return }
        cancel(); exportURL = nil
        let id = revision, p = parameters, image = imported.original
        let styles = styles, mm = widthMM, transparent = transparent, inverted = inverted, format = exportFormat
        isBusy = true; progress = 0; status = "Full-resolution processing"
        let task = Task.detached(priority: .userInitiated) {
            let input = try ImageImportService.luminance(image)
            return try StencilProcessingCoordinator().process(input, parameters: p) { [weak self] fraction, stage in
                Task { @MainActor in
                    guard let self, self.revision == id else { return }
                    self.progress = fraction; self.status = "Full resolution · " + stage
                }
            }
        }
        worker = task
        Task {
            do {
                let output = try await task.value
                guard revision == id else { return }
                status = "Rendering export"
                let url = try await Task.detached(priority: .userInitiated) {
                    try ExportService.export(output, styles: styles, parameters: p, widthMM: mm,
                                             transparent: transparent, inverted: inverted, format: format)
                }.value
                guard revision == id else { return }
                worker = nil; isBusy = false
                guard self.styles == styles, self.widthMM == mm, self.transparent == transparent,
                      self.inverted == inverted, self.exportFormat == format else {
                    status = "Export settings changed; generate again"
                    return
                }
                exportURL = url
                status = "Export ready · \(output.width) × \(output.height) px · \(Int(mm)) mm wide"
            } catch { finish(error, revision: id) }
        }
    }

    private func finish(_ failure: Error, revision id: UUID) {
        guard revision == id else { return }
        isBusy = false
        if failure is CancellationError { status = "Cancelled" }
        else { error = failure.localizedDescription; status = "Processing failed" }
    }
}
