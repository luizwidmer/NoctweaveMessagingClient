import SwiftUI

@main
struct NoctweaveApp: App {
    @StateObject private var model = ClientViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 560)
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .defaultSize(width: 1_120, height: 720)
        #endif
    }
}
