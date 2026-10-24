import SwiftUI
import StencilCore

private struct ImportDelivery: Sendable { let image: ImportedImage; let engine: InteractivePreviewEngine }
private struct PreviewDelivery: Sendable { let frame: PreviewFrame; let drawing: PreparedStencil }
private struct NativeDelivery: Sendable { let result: StencilResult; let drawing: PreparedStencil; let url: URL?; let agreement: PreviewAgreement? }
private struct PreviewIntent: Sendable { let id: UUID; let parameters: Parameters; let quality: PreviewQuality }

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var parameters = Preset.portrait.parameters
    @Published var controls = StencilControls()
    @Published var subjectEnabled = true
    @Published private(set) var subjectStatus = "Motivet findes automatisk ved import"
    @Published var styles = Dictionary(uniqueKeysWithValues: LayerKind.allCases.map { kind in
        var style = LayerStyle()
        if kind == .outlines { style.width = 2 }
        else { style.width = 1 }
        return (kind, style)
    })
    @Published var imported: ImportedImage?
    @Published var result: StencilResult?
    @Published private(set) var drawing: PreparedStencil?
    @Published var isBusy = false
    @Published private(set) var showsProgress = false
    @Published var progress = 0.0
    @Published var status = "Vælg et referencebillede"
    @Published var error: String?
    @Published var exportURL: URL?
    @Published var widthMM = 150.0
    @Published var transparent = false
    @Published var exportFormat = ExportFormat.png
    @Published var debugStage = DebugStage.stencil
    @Published var debugImage: CGImage?
    @Published private(set) var fullResolutionVerified = false
    @Published private(set) var agreement: PreviewAgreement?
    private var importWorker: Task<ImportDelivery,Error>?
    private var nativeWorker: Task<NativeDelivery,Error>?
    private var previewWorker: Task<PreviewDelivery,Error>?
    private var previewPump: Task<Void,Never>?
    private var refinementTask: Task<Void,Never>?
    private var subjectWorker: Task<SubjectAnalysis,Error>?
    private var debugTask: Task<Void,Never>?
    private let lane = ProcessingLane()
    private let subjectLane = ProcessingLane()
    private var engine: InteractivePreviewEngine?
    private var lastPreview: PreviewDelivery?
    private var pendingPreview: PreviewIntent?
    private var renderingQuality: PreviewQuality?
    private var operationRevision = UUID()
    private var previewContext = UUID()
    private var requestID = UUID()
    private var subjectRevision = UUID()
    private var processedParameters: Parameters?
    private var subjectPoint: Point?
    private var cachedSubject: SubjectAnalysis?
    private var interacting = false
    private var needsRefinement = false

    var sourceSize: String {
        guard let source = imported else { return "Intet billede" }
        return "\(source.width) × \(source.height) px"
    }
    var previewScale: Double {
        guard let source = imported, let drawing else { return 1 }
        return Double(drawing.width)/Double(source.width)
    }
    var heightMM: Double {
        guard let source = imported else { return widthMM }
        return widthMM*Double(source.height)/Double(source.width)
    }
    var agreementText: String? {
        guard let agreement else { return nil }
        return "Preview/final: outlines \(Int(agreement.outlines.score*100))%, shadows \(Int(agreement.shadows.score*100))% within \(agreement.tolerancePixels) preview pixels."
    }
    func applyControls() {
        do { parameters = try controls.parameters(width: imported?.width ?? 900,height: imported?.height ?? 900) }
        catch { self.error = error.localizedDescription }
    }
    func parametersChanged(from previous: Parameters) {
        if parameters.hasSameGeometry(as: previous) {
            if processedParameters != nil { processedParameters = parameters }
            exportURL = nil
        } else { schedulePreview() }
    }
    func setInteracting(_ active: Bool) {
        interacting = active
        if active {
            refinementTask?.cancel(); refinementTask = nil
            if renderingQuality == .refined && needsRefinement { enqueue(.interactive) }
        } else if needsRefinement { scheduleRefinement() }
        refreshBusy()
    }
    func selectSubject(_ point: Point?) { subjectPoint = point; resolveSubject() }
    func subjectModeChanged() { resolveSubject() }

    private func stopPreview() {
        previewContext = UUID()
        previewWorker?.cancel(); previewPump?.cancel(); refinementTask?.cancel(); debugTask?.cancel()
        previewWorker = nil; previewPump = nil; refinementTask = nil; debugTask = nil
        pendingPreview = nil; renderingQuality = nil
    }
    func cancel() {
        operationRevision = UUID(); subjectRevision = UUID()
        nativeWorker?.cancel(); importWorker?.cancel(); subjectWorker?.cancel(); stopPreview()
        nativeWorker = nil; importWorker = nil; subjectWorker = nil
        needsRefinement = false; isBusy = false; showsProgress = false; status = "Afbrudt"
    }
    func importData(_ data: Data) {
        cancel(); result = nil; drawing = nil; lastPreview = nil; engine = nil; imported = nil; debugImage = nil
        exportURL = nil; agreement = nil; fullResolutionVerified = false; processedParameters = nil
        subjectPoint = nil; cachedSubject = nil; subjectStatus = "Finder motiv …"
        progress = 0; status = "Åbner billede"
        let id = operationRevision, lane = lane
        let task = Task.detached(priority: .userInitiated) {
            try await lane.run {
                let image = try ImageImportService.load(data)
                let engine = try InteractivePreviewEngine(source: image.preview,nativeWidth: image.width)
                return ImportDelivery(image: image,engine: engine)
            }
        }
        importWorker = task; refreshBusy()
        Task {
            do {
                let delivery = try await task.value
                guard operationRevision == id else { return }
                imported = delivery.image; engine = delivery.engine; importWorker = nil
                applyControls(); resolveSubject()
            } catch { finish(error,revision: id) }
        }
    }

    /// Vision has its own lifetime, keyed only by source/subject selection. Slider
    /// changes neither cancel nor rerun inference. Draft feedback need not await it.
    private func resolveSubject() {
        guard let imported else { return }
        subjectWorker?.cancel(); subjectRevision = UUID(); cachedSubject = nil
        stopPreview()
        if !subjectEnabled {
            subjectWorker = nil; subjectStatus = "Hele billedet · motivfokus slået fra"
            schedulePreview(); return
        }
        let id = subjectRevision, point = subjectPoint, subjectLane = subjectLane
        subjectStatus = "Finder hovedmotiv …"
        let task = Task.detached(priority: .utility) {
            try await subjectLane.run { try AppleSubjectDetector.detect(imported.previewImage,point: point) }
        }
        subjectWorker = task
        schedulePreview()
        Task {
            do {
                let analysis = try await task.value
                guard subjectRevision == id else { return }
                cachedSubject = analysis; subjectStatus = analysis.message; subjectWorker = nil
                // A new guidance context invalidates old frames, not the reusable
                // preprocessing/tonal cache entries inside the engine.
                stopPreview(); schedulePreview()
            } catch {
                guard subjectRevision == id else { return }
                subjectWorker = nil; subjectStatus = "Motivgenkendelse afbrudt · hele billedet bruges"
                refreshBusy()
            }
        }
    }

    func schedulePreview() {
        guard imported != nil, engine != nil else { return }
        nativeWorker?.cancel(); nativeWorker = nil; operationRevision = UUID()
        exportURL = nil; agreement = nil
        if fullResolutionVerified {
            result = lastPreview?.frame.result; drawing = lastPreview?.drawing
        }
        fullResolutionVerified = false; processedParameters = nil
        debugTask?.cancel(); debugImage = nil
        requestID = UUID(); needsRefinement = true
        enqueue(.interactive)
        if !interacting { scheduleRefinement() }
    }
    private func scheduleRefinement() {
        refinementTask?.cancel()
        let id = requestID, context = previewContext
        refinementTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled, requestID == id, previewContext == context, !interacting else { return }
                refinementTask = nil; enqueue(.refined)
            } catch { }
        }
    }
    private func enqueue(_ quality: PreviewQuality) {
        guard let engine else { return }
        pendingPreview = PreviewIntent(id: requestID,parameters: parameters,quality: quality)
        // Preempt expensive refinement when the next drag starts. Let short draft
        // jobs finish so a continuous gesture cannot starve visible updates.
        if quality == .interactive && renderingQuality == .refined { previewWorker?.cancel() }
        guard previewPump == nil else { refreshBusy(); return }
        let context = previewContext, guidance = cachedSubject?.guidance
        previewPump = Task { await drainPreview(engine: engine,context: context,guidance: guidance) }
        refreshBusy()
    }
    private func drainPreview(engine: InteractivePreviewEngine,context: UUID,guidance: SubjectGuidance?) async {
        while !Task.isCancelled, previewContext == context, let intent = pendingPreview {
            pendingPreview = nil; renderingQuality = intent.quality
            let task = Task.detached(priority: .userInitiated) {
                let frame = try await engine.render(parameters: intent.parameters,quality: intent.quality,guidance: guidance)
                return PreviewDelivery(frame: frame,drawing: try StencilRenderer.prepare(frame.result))
            }
            previewWorker = task; refreshBusy()
            do {
                let delivery = try await task.value
                guard previewContext == context else { return }
                // While dragging, intermediate snapshots are useful feedback. Once
                // released, only the exact latest geometry may replace the canvas.
                if intent.id == requestID || (interacting && intent.quality == .interactive) {
                    fullResolutionVerified = false
                    result = delivery.frame.result; drawing = delivery.drawing; lastPreview = delivery
                    processedParameters = intent.parameters
                    if intent.quality == .refined && intent.id == requestID { needsRefinement = false }
                    status = intent.quality == .interactive ? "Hurtig forhåndsvisning · finpudses ved slip" : "Detaljeret forhåndsvisning klar"
                }
            } catch {
                guard previewContext == context else { return }
                if !(error is CancellationError), intent.id == requestID { self.error = error.localizedDescription }
            }
            previewWorker = nil; renderingQuality = nil
            // Bound UI publication frequency without delaying the first frame.
            if pendingPreview != nil { try? await Task.sleep(for: .milliseconds(16)) }
        }
        guard previewContext == context else { return }
        previewPump = nil; refreshBusy()
        if debugStage != .stencil { updateDebug() }
    }

    func updateDebug() {
        debugTask?.cancel(); debugImage = nil
        guard let result, debugStage != .stencil else { return }
        let context = previewContext, id = requestID, stage = debugStage, lane = lane
        debugTask = Task {
            do {
                let image = try await lane.run { try StencilRenderer.debugImage(result,stage: stage) }
                guard !Task.isCancelled, previewContext == context, requestID == id, debugStage == stage else { return }
                debugImage = image
            } catch { }
        }
    }
    func export() { runFullResolution(exporting: true) }
    func verifyFullResolution() { runFullResolution(exporting: false) }
    func handleMemoryPressure() {
        let oldEngine = engine
        cancel(); result = nil; drawing = nil; lastPreview = nil; debugImage = nil; agreement = nil
        fullResolutionVerified = false; processedParameters = nil; exportURL = nil
        Task { await oldEngine?.clear() }
        status = "Hukommelsen er presset · behandling afbrudt"
    }
    private func runFullResolution(exporting: Bool) {
        guard let imported, subjectWorker == nil else { return }
        let nativeSize = result?.width == imported.width && result?.height == imported.height
        let cached = fullResolutionVerified && nativeSize && processedParameters?.hasSameGeometry(as: parameters) == true ? result : nil
        let preview = lastPreview?.frame.result
        stopPreview(); nativeWorker?.cancel(); operationRevision = UUID()
        exportURL = nil; fullResolutionVerified = false; needsRefinement = false
        let id = operationRevision, p = parameters, lane = lane, limits = ProcessingLimits.device, engine = engine
        let guidance = cachedSubject?.guidance
        let styles = styles, mm = widthMM, transparent = transparent, format = exportFormat
        let callback = progressCallback(id: id)
        progress = 0; status = "Behandler fuld opløsning"
        let task = Task.detached(priority: .userInitiated) {
            await engine?.clear()
            return try await lane.run {
                _ = try limits.bounded(width: imported.width,height: imported.height)
                let output: StencilResult
                if let cached { output = cached }
                else {
                    let input = try ImageImportService.fullLuminance(imported,limits: limits)
                    output = try StencilProcessingCoordinator().process(input,parameters: p,limits: limits,guidance: guidance,progress: callback)
                }
                try Task.checkCancellation()
                let agreement = try preview.map { try PreviewFidelity.compare(preview: $0,final: output) }
                let drawing = try StencilRenderer.prepare(output)
                let url = exporting ? try ExportService.export(output,styles: styles,parameters: p,widthMM: mm,
                                                               transparent: transparent,format: format) : nil
                return NativeDelivery(result: output,drawing: drawing,url: url,agreement: agreement)
            }
        }
        nativeWorker = task; refreshBusy()
        Task {
            do {
                let delivery = try await task.value
                guard operationRevision == id else { return }
                result = delivery.result; drawing = delivery.drawing; processedParameters = parameters
                fullResolutionVerified = true; agreement = delivery.agreement
                nativeWorker = nil; refreshBusy(); updateDebug()
                guard self.styles == styles, self.widthMM == mm, self.transparent == transparent,
                      self.exportFormat == format, self.parameters == p else {
                    status = "Endelig geometri klar · eksportens udseende er ændret"; return
                }
                exportURL = delivery.url
                status = exporting ? "Eksport klar" : "Endelig stencil klar"
            } catch { finish(error,revision: id) }
        }
    }
    private func refreshBusy() {
        let busy = importWorker != nil || nativeWorker != nil || previewWorker != nil || pendingPreview != nil || refinementTask != nil || subjectWorker != nil
        let visible = importWorker != nil || nativeWorker != nil || subjectWorker != nil
        if isBusy != busy { isBusy = busy }
        if showsProgress != visible { showsProgress = visible }
    }
    private func progressCallback(id: UUID) -> @Sendable (Double,String) -> Void {
        { [weak self] fraction,stage in
            Task { @MainActor in
                guard let self, self.operationRevision == id, self.nativeWorker != nil else { return }
                self.progress = fraction; self.status = stage
            }
        }
    }
    private func finish(_ failure: Error,revision id: UUID) {
        guard operationRevision == id else { return }
        nativeWorker = nil; importWorker = nil; refreshBusy()
        if failure is CancellationError { status = "Afbrudt" }
        else { error = failure.localizedDescription; status = "Behandling stoppet" }
    }
}
