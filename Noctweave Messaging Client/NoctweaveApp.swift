import SwiftUI
import NoctweaveCore

@main
struct NoctweaveApp: App {
    @StateObject private var model = ClientViewModel()
    @AppStorage("noctweave.appearance.palette") private var paletteRaw = ThemePalette.noir.rawValue

    private var theme: ThemeStyle {
        ThemeStyle(palette: ThemePalette(rawValue: paletteRaw) ?? .noir)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .environment(\.appTheme, theme)
                .preferredColorScheme(theme.preferredColorScheme)
                .tint(theme.accent)
                .onOpenURL { PairingInvitationInbox.shared.receive(url: $0) }
                #if os(macOS)
                .frame(minWidth: 860, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1_120, height: 720)
        #endif
    }
}
