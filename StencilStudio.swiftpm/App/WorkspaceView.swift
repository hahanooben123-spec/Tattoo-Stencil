import SwiftUI
import UIKit
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
    @State private var choosingSubject = false
    @State private var showAdvanced = false

    var body: some View {
        NavigationSplitView {
            Form {
                Section("Reference") {
                    PhotosPicker(selection: $photo, matching: .images) { Label("Vælg billede", systemImage: "photo") }
                    Button("Åbn fra Filer") { showFiles = true }
                    Text(model.sourceSize).font(.caption).foregroundStyle(.secondary)
                    if model.imported != nil {
                        Button(choosingSubject ? "Annuller motivvalg" : "Vælg hovedmotiv") {
                            choosingSubject.toggle()
                            comparison = choosingSubject ? 1 : 0
                        }.disabled(model.isBusy || !model.subjectEnabled)
                        Text(model.subjectStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Stencil") {
                    floatSlider("Detaljer", value: $model.controls.detail, range: 0...1)
                    floatSlider("Hovedkontur", value: $model.controls.outlineEmphasis, range: 0...1)
                    floatSlider("Skygger", value: $model.controls.shadows, range: 0...1)
                    Text("Tydelig hovedkontur, fine detaljer og diskrete skyggelinjer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Eksport") {
                    Picker("Format", selection: $model.exportFormat) { ForEach(ExportFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    HStack { Text("Bredde · mm"); TextField("Bredde", value: $model.widthMM, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    Text(String(format: "Højde: %.1f mm", model.heightMM)).font(.caption)
                    Button("Kontrollér endelig stencil") { model.verifyFullResolution() }.disabled(model.imported == nil || model.isBusy)
                    Button("Eksportér stencil") { model.export() }
                        .disabled(model.imported == nil || model.isBusy || !model.widthMM.isFinite || !(10...2000).contains(model.widthMM))
                    if let url = model.exportURL { ShareLink(item: url) { Label("Gem eller del", systemImage: "square.and.arrow.up") } }
                    Text("Print ved 100 % / faktisk størrelse. Kontrollér målet med en lineal.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("Avanceret",isExpanded: $showAdvanced) { advancedControls }
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
                        let aspect = Double(source.width) / Double(source.height)
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
                    if choosingSubject { Text("Tryk på det motiv, der skal fremhæves.").font(.callout).foregroundStyle(.purple) }
                    HStack { Text("Stencil"); Slider(value: $comparison, in: 0...1); Text("Reference") }
                    if model.isBusy { ProgressView(value: model.progress) }
                    HStack {
                        Text(model.status).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.isBusy { Button("Cancel") { model.cancel() }.font(.caption) }
                    }
                    Text(model.fullResolutionVerified ? "Endelig stencil · kontrollér før overførsel" : "Forhåndsvisning · kontrollér den endelige stencil før overførsel")
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
        .onChange(of: model.controls) { _, _ in model.applyControls() }
        .onChange(of: model.parameters) { previous, _ in model.parametersChanged(from: previous) }
        .onChange(of: model.subjectEnabled) { _, _ in model.subjectModeChanged() }
        .onChange(of: showAdvanced) { _, expanded in if !expanded { model.debugStage = .stencil } }
        .onChange(of: model.debugStage) { _, _ in model.updateDebug() }
        .onChange(of: model.widthMM) { _, _ in model.exportURL = nil }
        .onChange(of: model.transparent) { _, _ in model.exportURL = nil }
        .onChange(of: model.inverted) { _, _ in model.exportURL = nil }
        .onChange(of: model.exportFormat) { _, _ in model.exportURL = nil }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.handleMemoryPressure()
        }
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
                    Canvas(rendersAsynchronously: true) { context, size in
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
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard choosingSubject, model.subjectEnabled else { return }
                model.selectSubject(Point(Double(location.x/geometry.size.width),Double(location.y/geometry.size.height)))
                choosingSubject = false; comparison = 0
            }
        }
        .accessibilityLabel("Image-aligned stencil preview. Use the comparison slider to reveal the reference.")
    }

    private var advancedControls: some View {
        VStack(alignment: .leading,spacing: 18) {
            Toggle("Fokus på motiv · Apple Vision",isOn: $model.subjectEnabled)
            Button("Find automatisk hovedmotiv igen") { model.selectSubject(nil) }.disabled(model.imported == nil || model.isBusy)
            Picker("Preset", selection: $preset) { ForEach(Preset.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            advancedOutlineControls
            advancedShadowControls
            VStack(alignment: .leading) {
                Text("Højlys og baggrund").font(.headline)
                Toggle("Markér højlys",isOn: $model.parameters.highlightsEnabled)
                floatSlider("Følsomhed for højlys",value: $model.parameters.highlightSensitivity,range: 0...1)
                floatSlider("Støjreduktion",value: $model.parameters.noiseReduction,range: 0...1)
                floatSlider("Kontrast",value: $model.parameters.contrast,range: 0.5...2)
                Toggle("Invertér farver",isOn: $model.inverted)
                Toggle("Transparent PNG",isOn: $model.transparent)
            }
            ForEach(LayerKind.allCases,id: \.self) { kind in
                VStack(alignment: .leading) {
                    Toggle(kind.rawValue.capitalized,isOn: style(kind,\.visible))
                    doubleSlider("Opacitet",value: style(kind,\.opacity),range: 0...1)
                    doubleSlider("Linjebredde · px",value: style(kind,\.width),range: 0.4...6)
                }
            }
            Picker("Vis behandlingstrin",selection: $model.debugStage) { ForEach(DebugStage.allCases,id: \.self) { Text($0.rawValue).tag($0) } }
            if let text = model.agreementText { Text(text).font(.caption) }
        }.padding(.vertical,8)
    }
    private var advancedOutlineControls: some View {
        VStack(alignment: .leading) {
            Text("Konturer").font(.headline)
            floatSlider("Teksturfilter",value: $model.parameters.textureSuppression,range: 0...1)
            floatSlider("Kanttærskel",value: $model.parameters.edgeThreshold,range: 0.01...0.8)
            doubleSlider("Mindste længde · px",value: $model.parameters.minimumContourLength,range: 0...500)
            doubleSlider("Forenkling · px",value: $model.parameters.smoothing,range: 0...2)
        }
    }
    private var advancedShadowControls: some View {
        VStack(alignment: .leading) {
            Text("Skyggegrænser").font(.headline)
            Toggle("Skyggelinjer",isOn: $model.parameters.shadowsEnabled)
            Stepper("Toneniveauer: \(model.parameters.tonalLevels)",value: $model.parameters.tonalLevels,in: 3...10)
            floatSlider("Følsomhed",value: $model.parameters.shadowSensitivity,range: 0...1)
            floatSlider("Sammenhæng",value: $model.parameters.regionCoherence,range: 0...1)
            doubleSlider("Mindste afstand · px",value: $model.parameters.shadowSpacing,range: 0...16)
            Toggle("Fjern overlap med konturer",isOn: $model.parameters.suppressOutlineDuplicates)
            Stepper("Mindste område: \(model.parameters.minimumRegionArea) px²",value: $model.parameters.minimumRegionArea,in: 1...1_000_000,step: 100)
            doubleSlider("Streglængde · px",value: $model.parameters.dashLength,range: 1...30)
            doubleSlider("Mellemrum · px",value: $model.parameters.dashSpacing,range: 1...30)
        }
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
