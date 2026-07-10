import Foundation
import Combine

#if os(iOS)
import UIKit
#else
import AppKit
import CoreGraphics
#endif

final class ScreenProtectionMonitor: ObservableObject {
    @Published private(set) var isCaptureActive = false
    @Published private(set) var isSensitiveHidden = false
    private let isUITesting = ProcessInfo.processInfo.arguments.contains("UI_TESTING")
    #if os(macOS)
    @Published private(set) var isAppInFocus = true
    private var hideWhenUnfocusedEnabled = true
    #endif

    private var observers: [NSObjectProtocol] = []

    init() {
        setupObservers()
        refresh()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func refresh() {
        #if os(iOS)
        updateCaptureStatus()
        #else
        updateMirroringStatus()
        #endif
    }

    #if os(macOS)
    func setHideWhenUnfocusedEnabled(_ enabled: Bool) {
        hideWhenUnfocusedEnabled = enabled
        updateHiddenStatus()
    }

    func setAppInFocus(_ focused: Bool) {
        isAppInFocus = focused
        updateHiddenStatus()
    }
    #endif

    #if os(iOS)
    private func setupObservers() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.updateCaptureStatus()
            }
        )
        // iOS 26+ deprecates `UIScreen.didConnect/Disconnect` and `UIScreen.screens`.
        // Track screen topology via scene lifecycle notifications instead.
        let sceneNotifications: [NSNotification.Name] = [
            UIScene.willConnectNotification,
            UIScene.didDisconnectNotification,
            UIScene.didActivateNotification,
            UIScene.willDeactivateNotification,
            UIScene.willEnterForegroundNotification,
            UIScene.didEnterBackgroundNotification
        ]
        for name in sceneNotifications {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.updateCaptureStatus()
                }
            )
        }
        observers.append(
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.updateCaptureStatus()
            }
        )
    }

    private func updateCaptureStatus() {
        guard !isUITesting else {
            isCaptureActive = false
            updateHiddenStatus()
            return
        }
        // Prefer scene-derived screens to avoid deprecated UIScreen globals.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let screens = scenes.map(\.screen)

        let isCaptured = screens.contains { $0.isCaptured }
        let uniqueScreenCount = Set(screens.map { ObjectIdentifier($0) }).count
        let isExternalOrSecondaryScreen = uniqueScreenCount > 1

        isCaptureActive = isCaptured || isExternalOrSecondaryScreen
        updateHiddenStatus()
    }

    #else
    private func setupObservers() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateMirroringStatus()
            }
        )
    }

    private func updateMirroringStatus() {
        guard !isUITesting else {
            isCaptureActive = false
            updateHiddenStatus()
            return
        }
        isCaptureActive = isAnyDisplayMirrored() || isExternalDisplayConnected()
        updateHiddenStatus()
    }

    private func isAnyDisplayMirrored() -> Bool {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayId = CGDirectDisplayID(screenNumber.uint32Value)
            if CGDisplayIsInMirrorSet(displayId) != 0 || CGDisplayMirrorsDisplay(displayId) != 0 {
                return true
            }
        }
        return false
    }

    private func isExternalDisplayConnected() -> Bool {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayId = CGDirectDisplayID(screenNumber.uint32Value)
            if CGDisplayIsBuiltin(displayId) == 0 {
                return true
            }
        }
        return false
    }
    #endif

    private func updateHiddenStatus() {
        guard !isUITesting else {
            isSensitiveHidden = false
            return
        }
        #if os(macOS)
        isSensitiveHidden = isCaptureActive || (hideWhenUnfocusedEnabled && !isAppInFocus)
        #else
        isSensitiveHidden = isCaptureActive
        #endif
    }
}
