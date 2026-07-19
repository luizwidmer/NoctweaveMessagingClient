import SwiftUI

#if os(macOS)
import AppKit

// Borderless windows can't become key by default. Subclass to allow focus, menus, etc.
private final class BorderlessKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class NoctweaveAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()

        let host = NSHostingView(rootView: contentView)
        host.wantsLayer = true
        // Prevent any "see-through app" artifacts if SwiftUI clears backgrounds in some containers.
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let initialRect = NSRect(
            x: screenFrame.midX - 560,
            y: screenFrame.midY - 380,
            width: 1120,
            height: 760
        )

        // No titlebar, no toolbar, no traffic lights: pure content.
        let w = BorderlessKeyWindow(
            contentRect: initialRect,
            // NOTE: include `.closable` so `performClose(_:)` works for our custom close control.
            styleMask: [.resizable, .miniaturizable, .closable],
            backing: .buffered,
            defer: false
        )

        w.isReleasedWhenClosed = false
        w.contentView = host
        // Borderless + fully transparent reads as "see-through app".
        // Make the window itself opaque so the desktop doesn't bleed through,
        // and keep the glass/gradient look within the SwiftUI content.
        w.isOpaque = true
        w.backgroundColor = NSColor.windowBackgroundColor
        w.hasShadow = true
        w.level = .normal
        w.tabbingMode = .disallowed
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.fullScreenPrimary]
        w.titleVisibility = .hidden
        w.title = ""

        // Ensure standard buttons are not visible even if the system tries to create them.
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = w
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif
