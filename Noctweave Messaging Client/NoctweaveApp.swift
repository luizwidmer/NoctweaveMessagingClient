import SwiftUI
import Combine
import NoctweaveCore

@main
struct NoctweaveApp: App {
    @StateObject private var session = ClientApplicationSession()
    @AppStorage("noctweave.appearance.palette") private var paletteRaw = ThemePalette.noir.rawValue

    private var theme: ThemeStyle {
        ThemeStyle(palette: ThemePalette(rawValue: paletteRaw) ?? .noir)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: session.model)
                .id(ObjectIdentifier(session.model))
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

@MainActor
private final class ClientApplicationSession: ObservableObject {
    @Published private(set) var model = ClientViewModel()

    init() { connectReset() }

    private func connectReset() {
        model.onLocalWipeCompleted = { [weak self] in
            guard let self else { return }
            // Old tasks keep their retired model, stores, and key provider.
            // Only the new session can create storage after the erase tombstone.
            self.model = ClientViewModel(afterLocalWipe: true)
            self.connectReset()
        }
    }
}
