import SwiftUI
import AVFoundation
import Combine

struct VoiceRecorderSheetView: View {
    let onRecorded: (Data, String, String) -> Void
    let onError: (String) -> Void
    let onCancel: () -> Void

    @StateObject private var recorder = VoiceRecorderController()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SheetActionBar(closeLabel: "Cancel", onClose: cancel) {
                        Button {
                            sendRecording()
                        } label: {
                            Label("Send", systemImage: "paperplane.fill")
                        }
                        .glassButton(prominent: true, compact: true)
                        .disabled(!recorder.canSend)
                    }

                    SheetHero(
                        icon: "waveform",
                        title: "Voice Message",
                        subtitle: "Record up to five minutes of encrypted audio."
                    )

                    SheetSection(title: "Microphone", icon: "mic.fill") {
                        permissionSection
                        if recorder.permission == .granted {
                            recorderSection
                        }
                    }

                    SheetSection(title: "Privacy", icon: "lock.shield.fill") {
                        Text("Audio is recorded into the app’s temporary storage and sent through the encrypted attachment pipeline. The temporary file is discarded when this sheet closes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .noctyraSheetBackground()
            .hideSheetNavigationBar()
        }
        .onAppear {
            recorder.requestPermissionIfNeeded()
        }
        .onDisappear {
            recorder.stopAndDiscard()
        }
        .frame(minWidth: 360, minHeight: 260)
        .noctyraSheetPresentation()
    }

    private func cancel() {
        recorder.stopAndDiscard()
        onCancel()
    }

    private func sendRecording() {
        do {
            let payload = try recorder.finishAndLoad()
            onRecorded(payload.data, payload.fileName, payload.mimeType)
        } catch {
            onError(error.localizedDescription)
        }
    }

    @ViewBuilder
    private var permissionSection: some View {
        switch recorder.permission {
        case .unknown:
            HStack(spacing: 8) {
                ProgressView()
                Text("Requesting microphone access...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Label("Microphone access is disabled.", systemImage: "mic.slash")
                    .foregroundStyle(.orange)
                Text("Enable microphone permission in system settings to record voice messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .granted:
            EmptyView()
        }
    }

    private var recorderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    recorder.toggleRecording()
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                .glassCircleButton(prominent: recorder.isRecording, diameter: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(recorder.isRecording ? "Recording..." : "Ready to record")
                        .font(.subheadline.weight(.semibold))
                    Text(recorder.elapsedLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text("Tap the mic to start recording, tap stop, then send.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
    }
}

@MainActor
private final class VoiceRecorderController: NSObject, ObservableObject {
    private let maximumDuration: TimeInterval = 300
    enum PermissionState {
        case unknown
        case granted
        case denied
    }

    @Published private(set) var permission: PermissionState = .unknown
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var tickerTask: Task<Void, Never>?

    var canSend: Bool {
        !isRecording && recordingURL != nil
    }

    var elapsedLabel: String {
        let seconds = max(0, Int(elapsed.rounded()))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }

    func requestPermissionIfNeeded() {
        switch permission {
        case .granted, .denied:
            return
        case .unknown:
            break
        }

        #if os(iOS)
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                permission = .granted
            case .denied:
                permission = .denied
            case .undetermined:
                AVAudioApplication.requestRecordPermission { allowed in
                    Task { @MainActor in
                        self.permission = allowed ? .granted : .denied
                    }
                }
            @unknown default:
                permission = .denied
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted:
                permission = .granted
            case .denied:
                permission = .denied
            case .undetermined:
                session.requestRecordPermission { allowed in
                    Task { @MainActor in
                        self.permission = allowed ? .granted : .denied
                    }
                }
            @unknown default:
                permission = .denied
            }
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permission = .granted
        case .denied, .restricted:
            permission = .denied
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                Task { @MainActor in
                    self.permission = allowed ? .granted : .denied
                }
            }
        @unknown default:
            permission = .denied
        }
        #endif
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func finishAndLoad() throws -> (data: Data, fileName: String, mimeType: String) {
        if isRecording {
            stopRecording()
        }
        guard let url = recordingURL else {
            throw VoiceRecorderError.noRecording
        }
        let data = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        recordingURL = nil
        return (data, "voice.m4a", "audio/m4a")
    }

    func stopAndDiscard() {
        if isRecording {
            recorder?.stop()
        }
        stopTicker()
        recorder = nil
        isRecording = false
        elapsed = 0
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func startRecording() {
        guard permission == .granted else {
            requestPermissionIfNeeded()
            return
        }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: [])
        } catch {
            return
        }
        #endif

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctyra-voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = false
            recorder.prepareToRecord()
            guard recorder.record() else {
                return
            }
            self.recorder = recorder
            recordingURL = url
            isRecording = true
            elapsed = 0
            startTicker()
        } catch {
            return
        }
    }

    private func stopRecording() {
        recorder?.stop()
        isRecording = false
        stopTicker()
    }

    private func startTicker() {
        stopTicker()
        tickerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let recorder = self.recorder {
                    self.elapsed = recorder.currentTime
                    if recorder.currentTime >= self.maximumDuration {
                        self.stopRecording()
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
    }
}

private enum VoiceRecorderError: LocalizedError {
    case noRecording

    var errorDescription: String? {
        switch self {
        case .noRecording:
            return "No voice recording available."
        }
    }
}
