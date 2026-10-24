import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import StencilCore

@MainActor
struct WorkspaceView: View {
    @StateObject private var model = WorkspaceModel()
    @State private var photo: PhotosPickerItem?
    @State private var showFiles = false
    @State private var comparison = 0.0
    @State private var zoom = 1.0
    @State private var gestureBase = 1.0
    @State private var preset = Preset.portrait

    var body: some View {
        NavigationSplitView {
            Form {
                Section("Reference") {
                    PhotosPicker(selection: $photo, matching: .images) { Label("Import photo", systemImage: "photo") }
                    Button("Import from Files") { showFiles = true }
                    Text(model.sourceSize).font(.caption).foregroundStyle(.secondary)
                    Picker("Preset", selection: $preset) { ForEach(Preset.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Text("Presets are starting points. Adjust every parameter below.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Structural outlines") {
                    floatSlider("Detail", value: $model.parameters.detail, range: 0...1)
                    floatSlider("Edge threshold", value: $model.parameters.edgeThreshold, range: 0.01...0.8)
                    doubleSlider("Minimum length · px", value: $model.parameters.minimumContourLength, range: 0...160)
                    doubleSlider("Simplification · px", value: $model.parameters.smoothing, range: 0...2)
                }
                Section("Shadow boundaries") {
                    Stepper("Tonal levels: \(model.parameters.tonalLevels)", value: $model.parameters.tonalLevels, in: 3...10)
                    floatSlider("Sensitivity", value: $model.parameters.shadowSensitivity, range: 0...1)
                    Stepper("Minimum area: \(model.parameters.minimumRegionArea) px²", value: $model.parameters.minimumRegionArea, in: 1...10000, step: 25)
                    doubleSlider("Dash length · px", value: $model.parameters.dashLength, range: 1...30)
                    doubleSlider("Dash spacing · px", value: $model.parameters.dashSpacing, range: 1...30)
                }
                Section("Highlights · experimental") {
                    Toggle("Generate highlights", isOn: $model.parameters.highlightsEnabled)
                    floatSlider("Sensitivity", value: $model.parameters.highlightSensitivity, range: 0...1)
                    Stepper("Minimum area: \(model.parameters.minimumHighlightArea) px²", value: $model.parameters.minimumHighlightArea, in: 1...10000, step: 25)
                }
                Section("Preprocessing") {
                    floatSlider("Noise reduction", value: $model.parameters.noiseReduction, range: 0...1)
                    floatSlider("Contrast", value: $model.parameters.contrast, range: 0.5...2)
                    Toggle("Invert stencil colors", isOn: $model.inverted)
                    Toggle("Transparent PNG", isOn: $model.transparent)
                }
                Section("Layers · source-pixel widths") {
                    ForEach(LayerKind.allCases, id: \.self) { kind in
                        VStack(alignment: .leading) {
                            Toggle(kind.rawValue.capitalized, isOn: style(kind, \.visible))
                            doubleSlider("Opacity", value: style(kind, \.opacity), range: 0...1)
                            doubleSlider("Width", value: style(kind, \.width), range: 0.4...6)
                        }
                    }
                    Text("To export one layer, hide the others.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Export") {
                    Picker("Format", selection: $model.exportFormat) { ForEach(ExportFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    HStack { Text("Width · mm"); TextField("Width", value: $model.widthMM, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    Text(String(format: "Height: %.1f mm · aspect ratio locked", model.heightMM)).font(.caption)
                    Button("Generate full-resolution export") { model.export() }
                        .disabled(model.imported == nil || model.isBusy || !model.widthMM.isFinite || !(10...2000).contains(model.widthMM))
                    if let url = model.exportURL { ShareLink(item: url) { Label("Save or share export", systemImage: "square.and.arrow.up") } }
                    Text("PDF page size matches the requested dimensions. Select 100% / actual size when printing; verify with a ruler.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Inspect processing") {
                    Picker("Stage", selection: $model.debugStage) { ForEach(DebugStage.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    if let result = model.result { Text("Adaptive thresholds: " + result.segmentation.thresholds.map { String(format: "%.2f", $0) }.joined(separator: ", ")).font(.caption.monospaced()) }
                }
            }
            .navigationTitle("Stencil Studio")
            .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Text("REFERENCE / STENCIL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Fit / reset") { zoom = 1; gestureBase = 1 }
                    Text("\(Int(zoom * 100))%").font(.caption.monospacedDigit())
                }.padding()
                GeometryReader { geometry in
                    if let source = model.imported {
                        let aspect = Double(source.preview.width) / Double(source.preview.height)
                        let width = min(geometry.size.width - 32, (geometry.size.height - 32) * aspect)
                        ScrollView([.horizontal, .vertical]) {
                            canvas(source: source)
                                .frame(width: max(1, width) * zoom, height: max(1, width / aspect) * zoom)
                                .padding(16)
                        }
                        .gesture(MagnifyGesture().onChanged { value in zoom = min(8, max(1, gestureBase * value.magnification)) }
                            .onEnded { _ in gestureBase = zoom })
                    } else {
                        ContentUnavailableView("Your reference, precisely traced", systemImage: "pencil.and.outline", description: Text("Import a photograph to generate structural contours and dashed tonal boundaries locally on this iPad."))
                    }
                }.background(Color(white: 0.10))
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Stencil"); Slider(value: $comparison, in: 0...1); Text("Reference") }
                    if model.isBusy { ProgressView(value: model.progress) }
                    HStack {
                        Text(model.status).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.isBusy { Button("Cancel") { model.cancel() }.font(.caption) }
                    }
                    Text("Development build · inspect every line before transfer. Manual editing is planned for Phase 3.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("Workspace")
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                Task {
                    do {
                        let data = try await Task.detached(priority: .userInitiated) {
                            let accessed = url.startAccessingSecurityScopedResource()
                            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                            return try Data(contentsOf: url)
                        }.value
                        model.importData(data)
                    } catch { model.error = error.localizedDescription }
                }
            } catch { model.error = error.localizedDescription }
        }
        .task(id: photo) {
            do {
                if let data = try await photo?.loadTransferable(type: Data.self), !Task.isCancelled { model.importData(data) }
            } catch { if !Task.isCancelled { model.error = error.localizedDescription } }
        }
        .onChange(of: preset) { _, value in model.parameters = value.parameters }
        .onChange(of: model.parameters) { _, _ in model.schedulePreview() }
        .onChange(of: model.debugStage) { _, _ in model.updateDebug() }
        .onChange(of: model.widthMM) { _, _ in model.exportURL = nil }
        .onChange(of: model.transparent) { _, _ in model.exportURL = nil }
        .onChange(of: model.inverted) { _, _ in model.exportURL = nil }
        .onChange(of: model.exportFormat) { _, _ in model.exportURL = nil }
        .alert("Unable to complete operation", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func canvas(source: ImportedImage) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                model.inverted ? Color.black : Color.white
                if let debug = model.debugImage {
                    Image(decorative: debug, scale: 1).resizable().interpolation(.none)
                } else if let result = model.result {
                    Canvas { context, size in
                        context.withCGContext { cg in
                            cg.scaleBy(x: size.width / Double(result.width), y: size.height / Double(result.height))
                            StencilRenderer.draw(result, context: cg, styles: model.styles, parameters: model.parameters,
                                                 strokeScale: model.previewScale, inverted: model.inverted)
                        }
                    }
                }
                Image(decorative: source.previewImage, scale: 1).resizable()
                    .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width * comparison) }
                if comparison > 0 && comparison < 1 {
                    Rectangle().fill(Color.purple).frame(width: 2).offset(x: geometry.size.width * comparison)
                }
            }
        }
        .accessibilityLabel("Image-aligned stencil preview. Use the comparison slider to reveal the reference.")
    }

    private func style<T>(_ kind: LayerKind, _ key: WritableKeyPath<LayerStyle, T>) -> Binding<T> {
        Binding(get: { (model.styles[kind] ?? LayerStyle())[keyPath: key] }, set: { value in
            var style = model.styles[kind] ?? LayerStyle(); style[keyPath: key] = value
            model.styles[kind] = style; model.exportURL = nil
        })
    }
    private func floatSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading) { Text(title).font(.caption); Slider(value: value, in: range) }
    }
    private func doubleSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) { Text("\(title): \(value.wrappedValue, specifier: "%.1f")").font(.caption); Slider(value: value, in: range) }
    }
}
