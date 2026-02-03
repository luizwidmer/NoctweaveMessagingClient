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

    #if os(iOS)
    private func setupObservers() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.updateCaptureStatus()
            }
        )
        observers.append(
            center.addObserver(forName: UIScreen.didConnectNotification, object: nil, queue: .main) { [weak self] _ in
                self?.updateCaptureStatus()
            }
        )
        observers.append(
            center.addObserver(forName: UIScreen.didDisconnectNotification, object: nil, queue: .main) { [weak self] _ in
                self?.updateCaptureStatus()
            }
        )
    }

    private func updateCaptureStatus() {
        let isCaptured = UIScreen.main.isCaptured
        let isMirroring = UIScreen.screens.contains { $0.mirrored != nil } || UIScreen.screens.count > 1
        isCaptureActive = isCaptured || isMirroring
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
        isSensitiveHidden = isCaptureActive
    }
}
