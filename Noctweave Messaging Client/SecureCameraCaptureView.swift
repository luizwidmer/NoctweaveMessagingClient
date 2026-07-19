#if os(iOS)
import AVFoundation
import SwiftUI

struct SecureCameraCaptureView: View {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void
    @State private var session = SecureCameraSession()
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            SecureCameraController(
                session: session,
                onCapture: { data in
                    onCapture(data)
                    dismiss()
                },
                onError: { message in
                    errorMessage = message
                }
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button("Close") {
                        onCancel()
                        dismiss()
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(.ultraThinMaterial)
                    )
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Spacer()

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.black.opacity(0.7))
                        )
                        .padding(.bottom, 12)
                }

                Button {
                    session.capture()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.6), lineWidth: 3)
                            .frame(width: 70, height: 70)
                        Circle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 54, height: 54)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }
}

private final class SecureCameraSession {
    fileprivate weak var controller: SecureCameraViewController?

    func capture() {
        controller?.capturePhoto()
    }
}

private struct SecureCameraController: UIViewControllerRepresentable {
    let session: SecureCameraSession
    let onCapture: (Data) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> SecureCameraViewController {
        let controller = SecureCameraViewController(onCapture: onCapture, onError: onError)
        session.controller = controller
        return controller
    }

    func updateUIViewController(_ uiViewController: SecureCameraViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: SecureCameraViewController, coordinator: ()) {
        uiViewController.stop()
    }
}

private final class SecureCameraViewController: UIViewController, AVCapturePhotoCaptureDelegate {
    private let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "lattice.secure.camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private let onCapture: (Data) -> Void
    private let onError: (String) -> Void

    init(onCapture: @escaping (Data) -> Void, onError: @escaping (String) -> Void) {
        self.onCapture = onCapture
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestCameraAccessIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func capturePhoto() {
        guard isConfigured else { return }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        if #available(iOS 16.0, *) {
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        } else {
            settings.isHighResolutionPhotoEnabled = true
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func stop() {
        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    private func requestCameraAccessIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureSession()
                    } else {
                        self.onError("Camera access is required to capture photos.")
                    }
                }
            }
        default:
            onError("Camera access is denied. Enable it in Settings to capture photos.")
        }
    }

    private func configureSession() {
        sessionQueue.async {
            guard !self.isConfigured else { return }
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .photo

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                DispatchQueue.main.async {
                    self.onError("No camera available on this device.")
                }
                self.captureSession.commitConfiguration()
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                } else {
                    DispatchQueue.main.async {
                        self.onError("Unable to access the camera input.")
                    }
                    self.captureSession.commitConfiguration()
                    return
                }
            } catch {
                DispatchQueue.main.async {
                    self.onError("Unable to initialize the camera input.")
                }
                self.captureSession.commitConfiguration()
                return
            }

            if self.captureSession.canAddOutput(self.photoOutput) {
                self.captureSession.addOutput(self.photoOutput)
            } else {
                DispatchQueue.main.async {
                    self.onError("Unable to configure camera output.")
                }
                self.captureSession.commitConfiguration()
                return
            }

            self.captureSession.commitConfiguration()
            self.isConfigured = true

            DispatchQueue.main.async {
                let previewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
                previewLayer.videoGravity = .resizeAspectFill
                self.previewLayer = previewLayer
                self.view.layer.insertSublayer(previewLayer, at: 0)
                previewLayer.frame = self.view.bounds
            }

            self.captureSession.startRunning()
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if error != nil {
            DispatchQueue.main.async {
                self.onError("Capture failed. Try again.")
            }
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async {
                self.onError("Unable to read captured image data.")
            }
            return
        }
        DispatchQueue.main.async {
            self.onCapture(data)
        }
    }
}
#endif
