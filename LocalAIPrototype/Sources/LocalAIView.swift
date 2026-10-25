import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct LocalAIView: View {
    @StateObject private var model = LocalAIModel()
    @State private var photo: PhotosPickerItem?
    @State private var files = false
    @State private var comparison = 0.0
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            VStack(spacing:16) {
                HStack {
                    PhotosPicker("Vælg reference",selection:$photo,matching:.images).disabled(model.busy)
                    Button("Åbn fra Filer") { files = true }.disabled(model.busy)
                    Spacer()
                    if !model.installed {
                        Button("Hent lokal model") { model.install() }.disabled(model.busy)
                    } else {
                        Button("Dan stencil på iPad") { comparison = 0; model.generate() }
                            .buttonStyle(.borderedProminent).disabled(model.busy || model.sourceData == nil)
                    }
                }
                GeometryReader { geometry in
                    if let reference = model.reference {
                        let aspect = Double(reference.width)/Double(reference.height)
                        let width = min(geometry.size.width,geometry.size.height*aspect)
                        ZStack(alignment:.leading) {
                            Color.white
                            if let stencil = model.stencil {
                                Image(decorative:stencil,scale:1).resizable().interpolation(.none)
                            }
                            Image(decorative:reference,scale:1).resizable()
                                .mask(alignment:.leading) {
                                    Rectangle().frame(width:model.stencil == nil ? width : width*comparison)
                                }
                            if model.stencil != nil, comparison > 0, comparison < 1 {
                                Rectangle().fill(.purple).frame(width:2).offset(x:width*comparison)
                            }
                        }.frame(width:width,height:width/aspect)
                            .frame(maxWidth:.infinity,maxHeight:.infinity)
                    } else {
                        ContentUnavailableView("Lokal stenciltest",systemImage:"pencil.and.outline",
                            description:Text("Hent FLUX.2 klein én gang og vælg et referencebillede. Modellen arbejder på denne iPad."))
                    }
                }.background(Color(white:0.12))
                if model.stencil != nil {
                    HStack { Text("Stencil"); Slider(value:$comparison,in:0...1); Text("Reference") }
                }
                if model.busy { ProgressView(value:model.progress) }
                HStack {
                    Text(model.status).font(.callout)
                    Spacer()
                    if model.busy { Button("Annuller") { model.cancel() }.disabled(model.cancelling) }
                    else if model.stencil != nil {
                        if let file = model.exported { ShareLink("Gem PNG",item:file) }
                        else { Button("Klargør PNG") { model.export() } }
                    }
                }
                if let seconds = model.seconds, let stencil = model.stencil {
                    Text(String(format:"%.1f sek. · %d × %d px · målt hukommelse op til %d MB",seconds,stencil.width,stencil.height,model.peakMB))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text("Prototype · 6-bit model · højst 768 px · ingen PC/cloud. Modellens streger og proportioner skal kontrolleres før overførsel.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding().navigationTitle("Stencil · lokal AI")
        }
        .task { await model.refreshInstallation() }
        .task(id:photo) {
            do {
                if let data = try await photo?.loadTransferable(type:Data.self), !Task.isCancelled { model.select(data) }
            } catch { if !Task.isCancelled { model.error = error.localizedDescription } }
        }
        .fileImporter(isPresented:$files,allowedContentTypes:[.image]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys:[.fileSizeKey])
                guard let size = values.fileSize, size <= 50*1024*1024 else { throw LocalAIError.invalidImage }
                model.select(try Data(contentsOf:url))
            } catch { model.error = error.localizedDescription }
        }
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) { _ in model.memoryWarning() }
        .onChange(of:phase) { _, phase in if phase == .background { model.cancel() } }
        .alert("Lokal AI",isPresented:Binding(get:{model.error != nil},set:{if !$0 { model.error = nil }})) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
