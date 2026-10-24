import SwiftUI

@main
@MainActor
struct StencilApp: App {
    var body: some Scene { WindowGroup { WorkspaceView().preferredColorScheme(.dark) } }
}
