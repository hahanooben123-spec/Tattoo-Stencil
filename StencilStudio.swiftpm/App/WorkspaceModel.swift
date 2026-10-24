import SwiftUI
import StencilCore

private struct ProcessingDelivery: Sendable {
    let result: StencilResult
    let agreement: PreviewAgreement?
    let exportURL: URL?
    let subject: SubjectAnalysis
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var parameters = Preset.portrait.parameters
    @Published var controls = StencilControls()
    @Published var subjectEnabled = true
    @Published private(set) var subjectStatus = "Motivet findes automatisk ved import"
    @Published var styles = Dictionary(uniqueKeysWithValues: LayerKind.allCases.map { kind in
        var style = LayerStyle()
        if kind == .outlines { style.width = 2 }
        else { style.opacity = kind == .shadows ? 0.5 : 0.4; style.width = 1 }
        return (kind, style)
    })
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
    @Published private(set) var fullResolutionVerified = false
    @Published private(set) var agreement: PreviewAgreement?
    private var worker: Task<ProcessingDelivery, Error>?
    private var importWorker: Task<ImportedImage, Error>?
    private var debounce: Task<Void, Never>?
    private var debugTask: Task<Void, Never>?
    private var revision = UUID()
    private let lane = ProcessingLane()
    private var processedParameters: Parameters?
    private var subjectPoint: Point?
    private var cachedSubject: SubjectAnalysis?

    func applyControls() {
        do { parameters = try controls.parameters(width: imported?.width ?? 900,height: imported?.height ?? 900) }
        catch { self.error = error.localizedDescription }
    }
    func parametersChanged(from previous: Parameters) {
        var analysisOnly = parameters
        analysisOnly.outlineEmphasis = previous.outlineEmphasis
        if analysisOnly == previous {
            processedParameters?.outlineEmphasis = parameters.outlineEmphasis
            exportURL = nil
        } else { schedulePreview() }
    }
    func selectSubject(_ point: Point?) {
        subjectPoint = point; cachedSubject = nil; schedulePreview()
    }
    func subjectModeChanged() {
        cachedSubject = nil; schedulePreview()
    }

    var sourceSize: String {
        guard let source = imported else { return "No reference" }
        return "\(source.width) × \(source.height) px"
    }
    var previewScale: Double {
        guard let source = imported, let result else { return 1 }
        return Double(result.width) / Double(source.width)
    }
    var heightMM: Double {
        guard let source = imported else { return widthMM }
        return widthMM * Double(source.height) / Double(source.width)
    }
    var agreementText: String? {
        guard let agreement else { return nil }
        return "Preview/final: outlines \(Int(agreement.outlines.score * 100))%, shadows \(Int(agreement.shadows.score * 100))% within \(agreement.tolerancePixels) preview pixels. Showing final paths."
    }

    func cancel() {
        revision = UUID(); worker?.cancel(); importWorker?.cancel(); debounce?.cancel(); debugTask?.cancel()
        worker = nil; importWorker = nil; debounce = nil; debugTask = nil
        isBusy = false; status = "Cancelled"
    }

    func importData(_ data: Data) {
        cancel(); result = nil; debugImage = nil; imported = nil; exportURL = nil
        agreement = nil; fullResolutionVerified = false; processedParameters = nil
        subjectPoint = nil; cachedSubject = nil; subjectStatus = "Finder motiv …"
        isBusy = true; progress = 0; status = "Decoding reference thumbnail"
        let id = revision, lane = lane
        let task = Task.detached(priority: .userInitiated) {
            try await lane.run { try ImageImportService.load(data) }
        }
        importWorker = task
        Task {
            do {
                let image = try await task.value
                guard revision == id else { return }
                imported = image; importWorker = nil; applyControls(); schedulePreview()
            } catch { finish(error, revision: id) }
        }
    }

    func schedulePreview() {
        guard let imported else { return }
        cancel(); exportURL = nil; agreement = nil
        result = nil; debugImage = nil; fullResolutionVerified = false; processedParameters = nil
        let id = revision, source = imported.preview, p = parameters, lane = lane
        let enabled = subjectEnabled, cachedSubject = cachedSubject, point = subjectPoint
        let scale = Double(source.width) / Double(imported.width)
        isBusy = true; progress = 0; status = "Approximate preview pending"
        debounce = Task {
            do {
                try await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled, revision == id else { return }
                let callback = progressCallback(id: id, prefix: "Preview · ")
                let task = Task.detached(priority: .userInitiated) {
                    try await lane.run {
                        callback(0,"Finder hovedmotiv")
                        let subject: SubjectAnalysis
                        if enabled { subject = try cachedSubject ?? AppleSubjectDetector.detect(imported.previewImage,point: point) }
                        else { subject = SubjectAnalysis(guidance: nil,message: "Hele billedet · motivfokus slået fra") }
                        let output = try StencilProcessingCoordinator().process(source, parameters: p.forPreview(scale: scale),
                                                                               guidance: subject.guidance, progress: callback)
                        return ProcessingDelivery(result: output, agreement: nil, exportURL: nil,subject: subject)
                    }
                }
                worker = task
                let output = try await task.value
                guard revision == id else { return }
                result = output.result; processedParameters = p; worker = nil; isBusy = false; updateDebug()
                self.cachedSubject = output.subject; subjectStatus = output.subject.message
                status = "Approximate preview · verify full resolution before transfer"
            } catch { finish(error, revision: id) }
        }
    }

    func updateDebug() {
        debugTask?.cancel(); debugImage = nil
        guard let result, debugStage != .stencil else { debugImage = nil; return }
        let id = revision, stage = debugStage, lane = lane
        debugTask = Task {
            do {
                let image = try await lane.run { try StencilRenderer.debugImage(result, stage: stage) }
                guard revision == id, debugStage == stage else { return }
                debugImage = image
            } catch { if revision == id { debugImage = nil } }
        }
    }

    func export() { runFullResolution(exporting: true) }
    func verifyFullResolution() { runFullResolution(exporting: false) }

    func handleMemoryPressure() {
        cancel(); result = nil; debugImage = nil; agreement = nil
        fullResolutionVerified = false; processedParameters = nil; exportURL = nil
        status = "Memory pressure: processing cancelled. Reference retained; try a smaller image."
    }

    private func runFullResolution(exporting: Bool) {
        guard let imported else { return }
        let cached = fullResolutionVerified && processedParameters == parameters ? result : nil
        let preview = !fullResolutionVerified ? result : nil
        cancel(); exportURL = nil; result = nil; debugImage = nil; fullResolutionVerified = false
        let id = revision, p = parameters, lane = lane, limits = ProcessingLimits.device
        let enabled = subjectEnabled, cachedSubject = cachedSubject, point = subjectPoint
        let styles = styles, mm = widthMM, transparent = transparent, inverted = inverted, format = exportFormat
        let previousAgreement = agreement
        isBusy = true; progress = 0; status = "Checking full-resolution memory budget"
        let callback = progressCallback(id: id, prefix: "Full resolution · ")
        let task = Task.detached(priority: .userInitiated) {
            try await lane.run {
                _ = try limits.bounded(width: imported.width, height: imported.height)
                let subject: SubjectAnalysis
                if enabled { subject = try cachedSubject ?? AppleSubjectDetector.detect(imported.previewImage,point: point) }
                else { subject = SubjectAnalysis(guidance: nil,message: "Hele billedet · motivfokus slået fra") }
                let output: StencilResult
                if let cached { output = cached }
                else {
                    let input = try ImageImportService.fullLuminance(imported, limits: limits)
                    output = try StencilProcessingCoordinator().process(input, parameters: p, limits: limits, guidance: subject.guidance, progress: callback)
                }
                try Task.checkCancellation()
                let agreement = try preview.map { try PreviewFidelity.compare(preview: $0, final: output) } ?? previousAgreement
                let url = exporting ? try ExportService.export(output, styles: styles, parameters: p, widthMM: mm,
                                                               transparent: transparent, inverted: inverted, format: format) : nil
                try Task.checkCancellation()
                return ProcessingDelivery(result: output, agreement: agreement, exportURL: url,subject: subject)
            }
        }
        worker = task
        Task {
            do {
                let delivery = try await task.value
                guard revision == id else { return }
                result = delivery.result; processedParameters = p; fullResolutionVerified = true; agreement = delivery.agreement
                self.cachedSubject = delivery.subject; subjectStatus = delivery.subject.message
                worker = nil; isBusy = false; updateDebug()
                guard self.styles == styles, self.widthMM == mm, self.transparent == transparent,
                      self.inverted == inverted, self.exportFormat == format else {
                    status = "Full-resolution paths verified; export settings changed"
                    return
                }
                exportURL = delivery.exportURL
                status = "\(exporting ? "Export ready" : "Full resolution verified") · \(delivery.result.width) × \(delivery.result.height) px"
            } catch { finish(error, revision: id) }
        }
    }

    private func progressCallback(id: UUID, prefix: String) -> @Sendable (Double, String) -> Void {
        { [weak self] fraction, stage in
            Task { @MainActor in
                guard let self, self.revision == id, self.isBusy else { return }
                self.progress = fraction; self.status = prefix + stage
            }
        }
    }
    private func finish(_ failure: Error, revision id: UUID) {
        guard revision == id else { return }
        worker = nil; importWorker = nil; isBusy = false
        if failure is CancellationError { status = "Cancelled" }
        else { error = failure.localizedDescription; status = "Processing stopped" }
    }
}
