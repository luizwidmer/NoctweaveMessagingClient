import SwiftUI
import NoctweaveCore

@main
struct NoctweaveApp: App {
    @StateObject private var model = ClientViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .environment(\.appTheme, ThemeStyle(palette: .noir))
                .preferredColorScheme(.dark)
                #if os(macOS)
                .frame(minWidth: 860, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .defaultSize(width: 1_120, height: 720)
        #endif
    }
}
