import AVFoundation
import SwiftUI

struct QRCodeScannerView: View {
    let onScan: (String) -> Void
    let onError: (String) -> Void
    var allowsMultiple: Bool = false
    @State private var permission = CameraPermission.unknown

    var body: some View {
        VStack(spacing: 16) {
            if permission == .authorized {
                ScannerRepresentable(onScan: onScan, onError: onError, allowsMultiple: allowsMultiple)
                    .frame(minHeight: 240, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.secondary.opacity(0.4), lineWidth: 1)
                    )
            } else if permission == .denied {
                VStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 32))
                    Text("Camera access is required to scan QR codes.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                ProgressView("Requesting camera access…")
            }
        }
        .onAppear {
            requestAccess()
        }
    }

    private func requestAccess() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            permission = .authorized
        case .denied, .restricted:
            permission = .denied
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    permission = granted ? .authorized : .denied
                }
            }
        @unknown default:
            permission = .denied
        }
    }
}

private enum CameraPermission {
    case unknown
    case authorized
    case denied
}

#if os(iOS)
private struct ScannerRepresentable: UIViewRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void
    let allowsMultiple: Bool

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        context.coordinator.configure(previewLayer: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        uiView.previewLayer.frame = uiView.bounds
    }

    static func dismantleUIView(_ uiView: CameraPreviewView, coordinator: Coordinator) {
        coordinator.stopSession()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError, allowsMultiple: allowsMultiple)
    }
}

private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as? AVCaptureVideoPreviewLayer ?? AVCaptureVideoPreviewLayer()
    }
}
#elseif os(macOS)
private struct ScannerRepresentable: NSViewRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void
    let allowsMultiple: Bool

    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        context.coordinator.configure(previewLayer: view.previewLayer)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        nsView.previewLayer.frame = nsView.bounds
    }

    static func dismantleNSView(_ nsView: CameraPreviewView, coordinator: Coordinator) {
        coordinator.stopSession()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError, allowsMultiple: allowsMultiple)
    }
}

private final class CameraPreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVCaptureVideoPreviewLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = AVCaptureVideoPreviewLayer()
    }

    override var wantsUpdateLayer: Bool { true }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as? AVCaptureVideoPreviewLayer ?? AVCaptureVideoPreviewLayer()
    }

    override func updateLayer() {
        previewLayer.frame = bounds
    }
}
#endif

private final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private let onScan: (String) -> Void
    private let onError: (String) -> Void
    private var didScan = false
    private var session: AVCaptureSession?
    private let allowsMultiple: Bool
    private var lastScanTime: Date?

    init(onScan: @escaping (String) -> Void, onError: @escaping (String) -> Void, allowsMultiple: Bool) {
        self.onScan = onScan
        self.onError = onError
        self.allowsMultiple = allowsMultiple
    }

    func configure(previewLayer: AVCaptureVideoPreviewLayer) {
        guard session == nil else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video) else {
            reportError("No camera available.")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                reportError("Unable to add camera input.")
                return
            }
        } catch {
            reportError("Camera error: \(error.localizedDescription)")
            return
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
        } else {
            reportError("Unable to add QR output.")
            return
        }

        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        self.session = session
        session.startRunning()
    }

    func stopSession() {
        session?.stopRunning()
        session = nil
        didScan = false
        lastScanTime = nil
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !didScan || allowsMultiple else { return }
        if let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
           object.type == .qr,
           let value = object.stringValue,
           !value.isEmpty {
            if allowsMultiple {
                let now = Date()
                if let lastScanTime, now.timeIntervalSince(lastScanTime) < 0.6 {
                    return
                }
                lastScanTime = now
                onScan(value)
            } else {
                didScan = true
                session?.stopRunning()
                onScan(value)
            }
        }
    }

    private func reportError(_ message: String) {
        DispatchQueue.main.async {
            self.onError(message)
        }
    }
}
