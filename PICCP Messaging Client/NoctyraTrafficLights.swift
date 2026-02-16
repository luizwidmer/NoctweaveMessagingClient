import SwiftUI

#if os(macOS)
import AppKit
import Combine

@MainActor
final class AppWindowController: ObservableObject {
    @Published private(set) var isWindowKey: Bool = true
    @Published private(set) var isAppActive: Bool = true
    @Published private(set) var isWindowCaptureBlocked: Bool = true

    weak var window: NSWindow? {
        didSet {
            // Also triggers observers so focus state updates immediately.
            attachFocusObservers()
            applySharingType()
        }
    }

    private var focusCancellables: Set<AnyCancellable> = []

    var isActiveForControls: Bool {
        isAppActive && isWindowKey
    }

    func close() {
        activateIfNeeded()
        // `performClose(_:)` can be a no-op for some borderless configurations.
        // `close()` reliably dismisses the window.
        window?.close()
    }

    func minimize() {
        activateIfNeeded()
        window?.miniaturize(nil)
    }

    func zoom() {
        activateIfNeeded()
        window?.zoom(nil)
    }

    func setBlockWindowCapture(_ blocked: Bool) {
        isWindowCaptureBlocked = blocked
        applySharingType()
    }

    private func activateIfNeeded() {
        guard let window else { return }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func attachFocusObservers() {
        focusCancellables.removeAll()
        isAppActive = NSApp.isActive
        isWindowKey = window?.isKeyWindow ?? true

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.isAppActive = true
            }
            .store(in: &focusCancellables)

        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.isAppActive = false
            }
            .store(in: &focusCancellables)

        guard let window else { return }

        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: window)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.isWindowKey = true
            }
            .store(in: &focusCancellables)

        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: window)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.isWindowKey = false
            }
            .store(in: &focusCancellables)
    }

    private func applySharingType() {
        guard let window else { return }
        // Best-effort protection: this prevents other processes from capturing the window via
        // standard WindowServer APIs. It does not stop a physical camera.
        window.sharingType = isWindowCaptureBlocked ? .none : .readOnly
    }
}

/// Captures the hosting NSWindow so SwiftUI can drive custom window controls.
struct WindowCaptureView: NSViewRepresentable {
    @ObservedObject var controller: AppWindowController

    func makeNSView(context: Context) -> NSView {
        CaptureView(controller: controller)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CaptureView)?.controller = controller
        (nsView as? CaptureView)?.captureIfNeeded()
    }

    private final class CaptureView: NSView {
        var controller: AppWindowController

        init(controller: AppWindowController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            captureIfNeeded()
        }

        func captureIfNeeded() {
            guard let window else { return }
            if controller.window !== window {
                controller.window = window
            }
        }
    }
}

private enum TrafficLightKind {
    case close
    case minimize
    case zoom

    var baseColor: Color {
        switch self {
        case .close: return Color(red: 1.0, green: 0.35, blue: 0.32)
        case .minimize: return Color(red: 1.0, green: 0.80, blue: 0.22)
        case .zoom: return Color(red: 0.26, green: 0.84, blue: 0.42)
        }
    }

    var hoverSymbol: String {
        switch self {
        case .close: return "xmark"
        case .minimize: return "minus"
        case .zoom: return "plus"
        }
    }
}

struct NoctyraTrafficLights: View {
    @EnvironmentObject private var windowController: AppWindowController
    @Environment(\.colorScheme) private var colorScheme

    @State private var hovering: TrafficLightKind?

    private var isDark: Bool { colorScheme == .dark }
    private var isActive: Bool { windowController.isActiveForControls }

    var body: some View {
        HStack(spacing: 7) {
            light(.close) { windowController.close() }
            light(.minimize) { windowController.minimize() }
            light(.zoom) { windowController.zoom() }
        }
        // Invisible hit target: user requested no visible pill/material behind the dots.
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func light(_ kind: TrafficLightKind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isActive ? kind.baseColor : Color.gray.opacity(isDark ? 0.55 : 0.45))
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(isDark ? 0.30 : 0.16), lineWidth: 0.6)
                    )
                    .shadow(
                        color: (isActive ? kind.baseColor : Color.black).opacity(isDark ? 0.18 : 0.12),
                        radius: 8,
                        x: 0,
                        y: 3
                    )
                if isActive, hovering == kind {
                    Image(systemName: kind.hoverSymbol)
                        .font(.system(size: 7.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.black.opacity(isDark ? 0.55 : 0.65))
                        .offset(y: -0.2)
                }
            }
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .onHover { isHovering in
            hovering = isHovering ? kind : (hovering == kind ? nil : hovering)
        }
        .accessibilityLabel(accessibilityLabel(for: kind))
    }

    private func accessibilityLabel(for kind: TrafficLightKind) -> String {
        switch kind {
        case .close: return "Close window"
        case .minimize: return "Minimize window"
        case .zoom: return "Zoom window"
        }
    }
}

#endif
