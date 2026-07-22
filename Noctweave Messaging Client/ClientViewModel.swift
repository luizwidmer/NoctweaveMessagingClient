import AVFoundation
import CryptoKit
import Combine
import Foundation
import ImageIO
import LocalAuthentication
import NoctweaveCore
import UserNotifications
import UniformTypeIdentifiers

@MainActor
private final class ClientNotificationManager {
    private var isAuthorized = false
    private var didRequest = false

    func requestAuthorization() async {
        guard !didRequest else { return }
        didRequest = true
        do {
            isAuthorized = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            isAuthorized = false
        }
    }

    func notifyNewMessage(count: Int = 1) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Noctweave"
        content.body = count == 1
            ? "A new encrypted message is ready."
            : "\(count) new encrypted messages are ready."
        content.sound = .default
        content.threadIdentifier = "noctweave-encrypted-message"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ),
            withCompletionHandler: nil
        )
    }
}

@MainActor
private final class ClientAttachmentStore {
    private static let maximumStoredAttachmentBytes = 12 * 1024 * 1024
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func saveSanitizedAttachment(_ data: Data, attachmentId: UUID) throws -> String {
        guard !data.isEmpty,
              data.count <= AttachmentDescriptor.maximumTransportBytes else {
            throw ClientAttachmentStoreError.invalidPayload
        }
        let fileName = "\(attachmentId.uuidString).bin"
        let url = try attachmentURL(fileName: fileName)
        guard let sealed = try? AES.GCM.seal(data, using: storageKey()),
              var combined = sealed.combined else {
            throw ClientAttachmentStoreError.invalidPayload
        }
        defer { combined.secureWipeClientAttachment() }
        let envelope = try NoctweaveCoder.encode(
            ClientAttachmentEnvelope(version: 1, sealed: combined)
        )
        guard envelope.count <= Self.maximumStoredAttachmentBytes else {
            throw ClientAttachmentStoreError.fileTooLarge
        }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try envelope.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return fileName
    }

    func warmUpKeychain() throws {
        _ = try storageKey()
    }

    func existingFileName(attachmentId: UUID) -> String? {
        let fileName = "\(attachmentId.uuidString).bin"
        guard let url = try? attachmentURL(fileName: fileName),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return fileName
    }

    func loadSanitizedAttachment(fileName: String) throws -> Data {
        let url = try attachmentURL(fileName: fileName)
        let encoded = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard encoded.count <= Self.maximumStoredAttachmentBytes else {
            throw ClientAttachmentStoreError.fileTooLarge
        }
        let envelope = try NoctweaveCoder.decode(ClientAttachmentEnvelope.self, from: encoded)
        guard envelope.version == 1,
              let sealed = try? AES.GCM.SealedBox(combined: envelope.sealed) else {
            throw ClientAttachmentStoreError.invalidPayload
        }
        let opened = try AES.GCM.open(sealed, using: storageKey())
        guard !opened.isEmpty,
              opened.count <= AttachmentDescriptor.maximumTransportBytes else {
            throw ClientAttachmentStoreError.invalidPayload
        }
        return opened
    }

    private func attachmentURL(fileName: String) throws -> URL {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == (trimmed as NSString).lastPathComponent,
              trimmed.hasSuffix(".bin"),
              UUID(uuidString: String(trimmed.dropLast(4))) != nil else {
            throw ClientAttachmentStoreError.invalidFileName
        }
        return directory.appendingPathComponent(trimmed, isDirectory: false)
    }

    private func storageKey() throws -> SymmetricKey {
        try SecureStorageKeyProvider.shared.loadOrCreateKey(
            service: "com.noctweave.securestorage",
            account: "attachment-vault-v1"
        )
    }
}

private struct ClientAttachmentEnvelope: Codable {
    let version: Int
    let sealed: Data
}

private enum ClientAttachmentStoreError: Error {
    case invalidFileName
    case invalidPayload
    case fileTooLarge
}

enum ClientBootState: Equatable {
    case loading
    case ready
    case failed(String)
}

enum ClientAttachmentWorkflowError: LocalizedError {
    case audioExportFailed
    case unsupportedPayload

    var errorDescription: String? {
        switch self {
        case .audioExportFailed:
            return "Audio metadata could not be stripped safely."
        case .unsupportedPayload:
            return "This attachment format cannot be sanitized safely on this client."
        }
    }
}

enum ClientAttachmentSanitizer {
    private static let audioExtensions: Set<String> = [
        "aac", "aif", "aiff", "caf", "flac", "m4a", "m4b", "mp3", "oga", "ogg", "opus", "wav"
    ]

    private static let audioMIMEs: Set<String> = [
        "audio/aac", "audio/aiff", "audio/flac", "audio/mp4", "audio/mpeg",
        "audio/ogg", "audio/opus", "audio/wav", "audio/x-aiff", "audio/x-flac", "audio/x-wav"
    ]

    static func sanitize(
        data: Data,
        fileName: String?,
        mimeType: String
    ) async throws -> ClientSanitizedAttachmentPayload {
        let normalizedMIME = normalizeMIME(mimeType)
        let fileExtension = fileName.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        if isAudio(mimeType: normalizedMIME, fileExtension: fileExtension) {
            return try await sanitizeAudio(data: data, fileExtension: fileExtension)
        }
        return try sanitizeDocument(
            data: data,
            mimeType: normalizedMIME,
            fileName: fileName
        )
    }

    private static func normalizeMIME(_ value: String) -> String {
        value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "application/octet-stream"
    }

    private static func isAudio(mimeType: String, fileExtension: String) -> Bool {
        if audioMIMEs.contains(mimeType) || mimeType.hasPrefix("audio/") {
            return true
        }
        guard !fileExtension.isEmpty,
              audioExtensions.contains(fileExtension) else { return false }
        return UTType(filenameExtension: fileExtension)?.conforms(to: .audio) ?? true
    }

    private static func sanitizeDocument(
        data: Data,
        mimeType: String,
        fileName: String?
    ) throws -> ClientSanitizedAttachmentPayload {
        guard !data.isEmpty else { throw ClientAttachmentWorkflowError.unsupportedPayload }
        if !mimeType.hasPrefix("image/") {
            let sanitized = try AttachmentSanitizer.sanitizeDocument(
                data: data,
                fileName: fileName,
                mimeType: mimeType
            )
            return ClientSanitizedAttachmentPayload(
                data: sanitized.data,
                mimeType: sanitized.mimeType
            )
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ClientAttachmentWorkflowError.unsupportedPayload
        }
        let outputType: CFString = mimeType == "image/jpeg"
            ? UTType.jpeg.identifier as CFString
            : UTType.png.identifier as CFString
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, outputType, 1, nil) else {
            throw ClientAttachmentWorkflowError.unsupportedPayload
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ClientAttachmentWorkflowError.unsupportedPayload
        }
        return ClientSanitizedAttachmentPayload(
            data: output as Data,
            mimeType: outputType == UTType.jpeg.identifier as CFString ? "image/jpeg" : "image/png"
        )
    }

    /// Re-encodes audio into a metadata-free M4A container. The descriptor
    /// therefore carries canonical `audio/mp4` and the post-sanitization digest.
    private static func sanitizeAudio(
        data: Data,
        fileExtension: String
    ) async throws -> ClientSanitizedAttachmentPayload {
        guard !data.isEmpty else { throw ClientAttachmentWorkflowError.unsupportedPayload }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoctweaveAttachmentSanitize", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let inputURL = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension.isEmpty ? "audio" : fileExtension)
        let outputURL = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        try data.write(to: inputURL, options: [.atomic])
        let asset = AVURLAsset(url: inputURL)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty,
              let exporter = AVAssetExportSession(
                  asset: asset,
                  presetName: AVAssetExportPresetAppleM4A
              ) else {
            throw ClientAttachmentWorkflowError.audioExportFailed
        }
        exporter.shouldOptimizeForNetworkUse = true
        do {
            try await exporter.export(to: outputURL, as: .m4a)
        } catch {
            throw ClientAttachmentWorkflowError.audioExportFailed
        }
        let sanitized = try Data(contentsOf: outputURL)
        guard !sanitized.isEmpty else { throw ClientAttachmentWorkflowError.audioExportFailed }
        return ClientSanitizedAttachmentPayload(data: sanitized, mimeType: "audio/mp4")
    }
}

private extension Data {
    mutating func secureWipeClientAttachment() {
        guard !isEmpty else { return }
        resetBytes(in: startIndex..<endIndex)
        removeAll(keepingCapacity: false)
    }
}

struct ClientSanitizedAttachmentPayload {
    let data: Data
    let mimeType: String
}

enum ClientOnboardingStep: String, CaseIterable, Identifiable {
    case legal
    case persona
    case relay
    case storageProtection
    case privacy
    case appLock
    case complete

    var id: String { rawValue }
}

enum PairingRelayCheckState: Equatable {
    case idle
    case checking
    case ready(RelayPairingReadiness)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

private enum NoctweaveClientError: Error, LocalizedError {
    case invalidPairingLink
    case invalidGroupIdentifier
    case pendingAdmissionMissing
    case pairingExpired
    case relayRejected(String)
    case missingPairingFrame(UInt64)
    case unexpectedDirectPairingStage
    case settingsAuthorizationRequired
    case biometricAuthenticationUnavailable
    case biometricAuthenticationFailed
    case invalidAppLockPIN
    case invalidPersonaName
    case personaOperationInProgress
    case invalidAttachment
    case attachmentDownloadInProgress
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidPairingLink:
            return "The one-use pairing invitation is invalid."
        case .invalidGroupIdentifier:
            return "The group identifier must be a UUID."
        case .pendingAdmissionMissing:
            return "The saved one-use group admission is unavailable."
        case .pairingExpired:
            return "The one-use pairing invitation expired. Start a fresh exchange."
        case .relayRejected(let message):
            return message
        case .missingPairingFrame(let sequence):
            return "The pairing exchange is missing transport frame \(sequence)."
        case .unexpectedDirectPairingStage:
            return "This direct pairing code is not the next expected stage. Use the code currently shown on the other device."
        case .settingsAuthorizationRequired:
            return "Authenticate with the current unlock method before changing app security."
        case .biometricAuthenticationUnavailable:
            return "Biometric authentication is unavailable on this device."
        case .biometricAuthenticationFailed:
            return "Biometric authentication did not complete."
        case .invalidAppLockPIN:
            return "Enter exactly six digits and confirm the same PIN."
        case .invalidPersonaName:
            return "Enter a display name between 1 and 512 bytes."
        case .personaOperationInProgress:
            return "Finish the current operation before changing personas."
        case .invalidAttachment:
            return "The attachment is invalid or failed integrity verification."
        case .attachmentDownloadInProgress:
            return "This attachment is already being downloaded."
        case .unavailable:
            return "The encrypted client state is not ready."
        }
    }
}

private struct DirectPairingOffererPendingContext {
    var pendingOffer: PendingRendezvousOfferV2
    let invitation: ContactPairingInvitationV2
    let participant: PreparedContactParticipantV2
    var ledger: RendezvousRedemptionLedgerV2
}

private struct NoctweavePairingLinkV1: Codable {
    static let prefix = "noctweave-pair-v1:"
    static let maximumCharacters = 96 * 1_024

    let version: Int
    let relay: RelayEndpoint
    let invitation: ContactPairingInvitationV2

    init(relay: RelayEndpoint, invitation: ContactPairingInvitationV2) {
        version = 1
        self.relay = relay
        self.invitation = invitation
    }

    func encoded() throws -> String {
        let data = try NoctweaveCoder.encode(self, sortedKeys: true)
        let value = Self.prefix + data.base64EncodedString()
        guard value.count <= Self.maximumCharacters else {
            throw NoctweaveClientError.invalidPairingLink
        }
        return value
    }

    static func decode(_ value: String) throws -> NoctweavePairingLinkV1 {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix(prefix),
              value.count <= maximumCharacters else {
            throw NoctweaveClientError.invalidPairingLink
        }
        let encoded = String(value.dropFirst(prefix.count))
        guard !encoded.isEmpty,
              encoded.unicodeScalars.allSatisfy({
                  $0.isASCII
                    && ((48...57).contains($0.value)
                        || (65...90).contains($0.value)
                        || (97...122).contains($0.value)
                        || $0 == "+" || $0 == "/" || $0 == "=")
              }),
              let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) else {
            throw NoctweaveClientError.invalidPairingLink
        }
        guard data.base64EncodedString() == encoded else {
            throw NoctweaveClientError.invalidPairingLink
        }
        let decoded = try NoctweaveCoder.decode(NoctweavePairingLinkV1.self, from: data)
        guard decoded.version == 1,
              decoded.relay.isStructurallyValid,
              decoded.invitation.isStructurallyValid,
              decoded.invitation.offer.expiresAt > Date(),
              decoded.invitation.offer.expiresAt.timeIntervalSinceNow <= 24 * 60 * 60 else {
            throw NoctweaveClientError.invalidPairingLink
        }
        return decoded
    }
}

@MainActor
final class ClientViewModel: ObservableObject {
    @Published private(set) var bootState: ClientBootState = .loading
    @Published private(set) var state: ClientState?
    @Published var selectedRelationshipID: UUID?
    @Published var selectedGroupID: UUID?
    @Published var draftMessage = ""
    @Published var groupDraftMessage = ""
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage = "Opening encrypted local state…"
    @Published private(set) var lastError: String?

    @Published private(set) var isPairing = false
    @Published private(set) var pairingLink: String?
    @Published private(set) var pairingStatus = ""
    @Published private(set) var pairingRelayCheckState: PairingRelayCheckState = .idle
    @Published private(set) var isPairingProcessing = false
    @Published private(set) var directPairingPayload: String?
    @Published private(set) var directPairingCanFinish = false

    @Published private(set) var groupExchangeLink: String?
    @Published private(set) var groupExchangeStatus = ""
    @Published private(set) var groupMaintenanceStatus: [UUID: String] = [:]

    @Published private(set) var isLocked = false
    @Published private(set) var biometricStepPassed = false
    @Published private(set) var lockError: String?
    @Published private(set) var isSavingSettings = false
    @Published private(set) var settingsMessage: String?
    @Published private(set) var settingsError: String?
    @Published private(set) var onboardingRelayCheckState: PairingRelayCheckState = .idle
    @Published private(set) var relayManagementCheckState: PairingRelayCheckState = .idle
    @Published private(set) var onboardingStorageProtectionAcknowledged = false
    @Published private(set) var archivedPersonaIDs: Set<UUID> = []
    @Published private(set) var receivedAttachmentFileNames: [UUID: String] = [:]

    private let stateStore: ClientStateStore
    private let attachmentStore: ClientAttachmentStore
    private var client: HeadlessMessagingClient?
    private var pairingTask: Task<Void, Never>?
    private var pairingRelayCheckTask: Task<Void, Never>?
    private var pairingRelayCheckID = UUID()
    private var directOffererPending: DirectPairingOffererPendingContext?
    private var directOffererFlow: ContactPairingOffererFlowV2?
    private var directResponderFlow: ContactPairingResponderFlowV2?
    private var directTemporaryParticipant: PreparedContactParticipantV2?
    private var failedPINAttempts = 0
    private var pinLockedUntil: Date?
    private var backgroundedAt: Date?
    private var settingsAuthorizedUntil: Date?
    private var settingsBiometricAuthorizedUntil: Date?
    private var onboardingLegalAccepted = false
    private var onboardingPersonaNameSaved = false
    private var onboardingPrivacyCompleted = false
    private var biometricRequestInFlight = false
    private var onboardingRelayCheckTask: Task<Void, Never>?
    private var relayManagementTask: Task<Void, Never>?
    private var attachmentDownloadsInFlight = Set<UUID>()
    private let notificationManager = ClientNotificationManager()
    private let onboardingStorageKey = "noctweave.onboarding.storage-protection-ack.v1"
    private let onboardingPrivacyKey = "noctweave.onboarding.privacy-ack.v1"
    private let onboardingPersonaKey = "noctweave.onboarding.persona-ack.v1"
    private let isUITest: Bool
    private let isUITestReadyState: Bool
    private let isUITestProductFixture: Bool

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("NoctweaveClient", isDirectory: true)
        let isUITest = ProcessInfo.processInfo.arguments.contains("UI_TESTING")
        self.isUITest = isUITest
        isUITestReadyState = ProcessInfo.processInfo.arguments.contains("UI_TESTING_READY_STATE")
            && isUITest
        isUITestProductFixture = ProcessInfo.processInfo.arguments.contains("UI_TESTING_PRODUCT_FIXTURE")
            && isUITest
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoctweaveCleanV1UITests", isDirectory: true)
        let stateURL = isUITest
            ? testRoot.appendingPathComponent("client-state-v1.nwstate")
            : support.appendingPathComponent("client-state-v1.nwstate")
        if isUITest {
            try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent())
            stateStore = ClientStateStore(
                fileURL: stateURL,
                protection: .encrypted,
                encryptionKey: SymmetricKey(data: Data(repeating: 0x4E, count: 32)),
                rollbackAnchorStore: VolatileClientStateRollbackAnchorStore()
            )
        } else {
            stateStore = ClientStateStore(fileURL: stateURL)
        }
        attachmentStore = ClientAttachmentStore(
            directory: (isUITest ? testRoot : support)
                .appendingPathComponent("attachments", isDirectory: true)
        )
        onboardingStorageProtectionAcknowledged = isUITest
            || UserDefaults.standard.bool(forKey: onboardingStorageKey)
        Task { await open() }
    }

    var activePersona: PersonaProfileV1? {
        guard let state else { return nil }
        return state.personas.first { $0.id == state.activePersonaID }
    }

    var relationships: [PairwiseRelationshipV2] {
        activePersona?.relationships.sorted {
            let lhsDate = $0.events.last?.createdAt ?? $0.createdAt
            let rhsDate = $1.events.last?.createdAt ?? $1.createdAt
            if lhsDate == rhsDate { return $0.id.uuidString < $1.id.uuidString }
            return lhsDate > rhsDate
        } ?? []
    }

    var groups: [GroupRuntimeRecord] {
        activePersona?.groupRuntimes
            .filter { $0.deletionState == nil && $0.localRemoval == nil }
            .sorted { $0.groupId.uuidString < $1.groupId.uuidString } ?? []
    }

    var pendingGroupAdmissions: [PendingGroupAdmissionV2] {
        activePersona?.pendingGroupAdmissions.sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt < $1.createdAt
        } ?? []
    }

    var selectedRelationship: PairwiseRelationshipV2? {
        guard let selectedRelationshipID else { return nil }
        return relationships.first { $0.id == selectedRelationshipID }
    }

    var selectedGroup: GroupRuntimeRecord? {
        guard let selectedGroupID else { return nil }
        return groups.first { $0.groupId == selectedGroupID }
    }

    var selectedEvents: [ConversationEvent] {
        selectedRelationship?.events.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        } ?? []
    }

    var selectedGroupEvents: [GroupConversationEventV2] {
        selectedGroup?.events ?? []
    }

    var appLockMode: AppLockMode {
        state?.appLock.mode ?? .off
    }

    var appearanceSettings: AppearanceSettings {
        state?.appearance ?? AppearanceSettings()
    }

    var privacySettings: PrivacySettings {
        state?.privacy ?? PrivacySettings()
    }

    var appLockSettings: AppLockSettings {
        state?.appLock ?? AppLockSettings()
    }

    var biometricDisplayName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Biometrics unavailable"
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometrics"
        }
    }

    var biometricsAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    var appLockMessage: String {
        let value = state?.appLock.lockScreenMessage
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Your encrypted conversations are locked." : value
    }

    var activePersonaRelayPreference: LocalRelayPreference? {
        guard let state,
              let preferenceID = state.preferredRelayPreferenceID(forPersonaID: state.activePersonaID) else {
            return nil
        }
        return state.relayPreferences.first { $0.id == preferenceID }
    }

    var onboardingStep: ClientOnboardingStep {
        guard let state else { return .legal }
        if state.hasCompletedOnboarding { return .complete }
        if !onboardingLegalAccepted
                && (!state.hasAcceptedPrivacyPolicy || !state.hasAcceptedTermsOfUse) {
            return .legal
        }
        if !hasCompletedPersonaOnboarding { return .persona }
        if state.relayPreferences.isEmpty { return .relay }
        if !onboardingStorageProtectionAcknowledged { return .storageProtection }
        if !onboardingPrivacyCompleted
                && (isUITest || !UserDefaults.standard.bool(forKey: onboardingPrivacyKey)) {
            return .privacy
        }
        return .appLock
    }

    var hasCompletedPersonaOnboarding: Bool {
        state?.hasCompletedOnboarding == true
            || (onboardingPersonaNameSaved
                || (!isUITest && UserDefaults.standard.bool(forKey: onboardingPersonaKey)))
                && !(activePersona?.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var isOnboardingComplete: Bool {
        onboardingStep == .complete
    }

    func open() async {
        bootState = .loading
        do {
            // Integration assumption: current Core exposes ClientState's
            // onboarding flags but not a dedicated first-run builder. Create
            // only a non-authoritative placeholder aggregate; the user-chosen
            // persona is persisted before the mature shell is revealed.
            let opened: HeadlessMessagingClient
            if let existing = try await stateStore.load() {
                opened = try HeadlessMessagingClient(stateStore: stateStore, initialState: existing)
            } else {
                var initial: ClientState
                if isUITestProductFixture {
                    initial = try Self.makeProductFixtureState()
                } else {
                    initial = try ClientState.initialLocalState(
                        displayName: isUITestReadyState ? "UI Test Persona" : "Unnamed Persona"
                    )
                    if isUITestReadyState {
                        var accepted = initial
                        try accepted.completeOnboarding(
                            privacyPolicyAccepted: true,
                            termsOfUseAccepted: true
                        )
                        initial = accepted
                    }
                }
                try await stateStore.save(initial, replacing: nil)
                opened = try HeadlessMessagingClient(stateStore: stateStore, initialState: initial)
            }
            client = opened
            try await refresh()
            onboardingLegalAccepted = state?.hasAcceptedPrivacyPolicy == true
                && state?.hasAcceptedTermsOfUse == true
            isLocked = isOnboardingComplete && appLockMode != .off
            statusMessage = "Encrypted local state is ready."
            bootState = .ready
            if isOnboardingComplete && !isLocked {
                await notificationManager.requestAuthorization()
                syncAll()
            }
        } catch {
            let message = describe(error)
            lastError = message
            bootState = .failed(message)
        }
    }

    func refresh() async throws {
        guard let client else { throw NoctweaveClientError.unavailable }
        let snapshot = await client.snapshot()
        state = snapshot
        archivedPersonaIDs = snapshot.archivedPersonaIDs
        var attachmentFiles: [UUID: String] = [:]
        for persona in snapshot.personas {
            for relationship in persona.relationships {
                for event in relationship.events where event.content.type == .attachment {
                    guard let descriptor = try? NoctweaveCoder.decode(
                        AttachmentDescriptor.self,
                        from: event.content.payload
                    ), let fileName = attachmentStore.existingFileName(attachmentId: descriptor.id) else {
                        continue
                    }
                    attachmentFiles[descriptor.id] = fileName
                }
            }
        }
        receivedAttachmentFileNames = attachmentFiles
        #if os(iOS)
        // Widget access is strictly gated by the encrypted state's completed
        // onboarding flag. The widget only stages sealed packets; foreground
        // sync remains authoritative because current Core has no public
        // staged-batch import method yet.
        if snapshot.hasCompletedOnboarding {
            try OpaqueRoutePrefetchBridge.update(from: snapshot)
        }
        #endif
        let available = snapshot.personas
            .first { $0.id == snapshot.activePersonaID }?
            .relationships ?? []
        let availableGroups = snapshot.personas
            .first { $0.id == snapshot.activePersonaID }?
            .groupRuntimes.filter {
                $0.deletionState == nil && $0.localRemoval == nil
            } ?? []
        if let selectedRelationshipID,
           !available.contains(where: { $0.id == selectedRelationshipID }) {
            self.selectedRelationshipID = nil
        }
        if self.selectedRelationshipID == nil {
            if selectedGroupID == nil {
                self.selectedRelationshipID = available.first?.id
            }
        }
        if let selectedGroupID,
           !availableGroups.contains(where: { $0.groupId == selectedGroupID }) {
            self.selectedGroupID = nil
        }
    }

    // MARK: - First-run workflow

    func acceptOnboardingLegalDocuments() {
        onboardingLegalAccepted = true
        statusMessage = "Legal documents accepted for this onboarding session."
    }

    func saveOnboardingPersonaName(_ value: String) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 512 else {
            lastError = describe(NoctweaveClientError.invalidPersonaName)
            return
        }
        runStateMutation(label: "Creating local persona…") { state in
            try state.updateActivePersona { persona in
                persona.displayName = name
            }
            self.onboardingPersonaNameSaved = true
            UserDefaults.standard.set(true, forKey: self.onboardingPersonaKey)
        }
    }

    func validateOnboardingRelay(relayText: String, password: String = "") {
        onboardingRelayCheckTask?.cancel()
        onboardingRelayCheckState = .checking
        do {
            let endpoint = try RelayEndpointParser.parse(relayText)
            let accessPassword = relayAccessPassword(for: endpoint, supplied: password)
            onboardingRelayCheckTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let readiness = try await RelayPairingPreflight.check(
                        client: RelayClient(endpoint: endpoint, authToken: accessPassword),
                        requirement: .rendezvous
                    )
                    try Task.checkCancellation()
                    guard let client else { throw NoctweaveClientError.unavailable }
                    let relayPreferenceID = try await rememberRelay(
                        readiness,
                        accessPassword: accessPassword,
                        client: client
                    )
                    try await client.setPreferredRelayPreference(
                        relayPreferenceID,
                        forPersonaID: (await client.snapshot()).activePersonaID
                    )
                    onboardingRelayCheckState = .ready(readiness)
                    try await refresh()
                } catch is CancellationError {
                } catch {
                    onboardingRelayCheckState = .failed(describe(error))
                }
                onboardingRelayCheckTask = nil
            }
        } catch {
            onboardingRelayCheckState = .failed(describe(error))
        }
    }

    func acknowledgeOnboardingStorageProtection() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await stateStore.warmUpKeychain()
                UserDefaults.standard.set(true, forKey: onboardingStorageKey)
                onboardingStorageProtectionAcknowledged = true
                statusMessage = "Encrypted local storage is ready."
            } catch {
                lastError = describe(error)
            }
        }
    }

    func completeOnboardingPrivacy(_ settings: PrivacySettings) async -> Bool {
        guard await savePrivacy(settings) else { return false }
        onboardingPrivacyCompleted = true
        UserDefaults.standard.set(true, forKey: onboardingPrivacyKey)
        return true
    }

    func completeOnboardingAppLock(
        mode: AppLockMode,
        sessionTimeoutMinutes: Int = 5,
        lockScreenMessage: String = "",
        newPIN: String? = nil
    ) async -> Bool {
        guard await saveAppLockConfiguration(
            mode: mode,
            sessionTimeoutMinutes: sessionTimeoutMinutes,
            lockScreenMessage: lockScreenMessage,
            newPIN: newPIN
        ) else { return false }
        return await finishOnboarding()
    }

    func skipOnboardingAppLock() async -> Bool {
        await finishOnboarding()
    }

    func finishOnboarding() async -> Bool {
        guard onboardingLegalAccepted
                || (state?.hasAcceptedPrivacyPolicy == true
                    && state?.hasAcceptedTermsOfUse == true),
              hasCompletedPersonaOnboarding,
              !(state?.relayPreferences.isEmpty ?? true),
              onboardingStorageProtectionAcknowledged,
              onboardingPrivacyCompleted
                || (!isUITest && UserDefaults.standard.bool(forKey: onboardingPrivacyKey)) else {
            settingsError = "Complete each required onboarding step first."
            return false
        }
        do {
            try await replaceStoredState { state in
                try state.completeOnboarding(
                    privacyPolicyAccepted: true,
                    termsOfUseAccepted: true
                )
            }
            settingsError = nil
            await notificationManager.requestAuthorization()
            syncAll()
            return true
        } catch {
            settingsError = describe(error)
            return false
        }
    }

    // MARK: - Local personas

    func createPersona(displayName: String) {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 512 else {
            lastError = describe(NoctweaveClientError.invalidPersonaName)
            return
        }
        runStateMutation(label: "Creating local persona…") { state in
            _ = try state.addPersona(displayName: name)
        }
    }

    func switchPersona(_ personaID: UUID) {
        runStateMutation(label: "Switching local persona…") { state in
            try state.selectPersona(personaID)
        }
    }

    func archivePersona(_ personaID: UUID) {
        guard personaID != state?.activePersonaID,
              state?.personas.contains(where: { $0.id == personaID }) == true else { return }
        runStateMutation(label: "Archiving local persona…") { state in
            try state.archivePersona(personaID)
        }
    }

    func unarchivePersona(_ personaID: UUID) {
        guard state?.personas.contains(where: { $0.id == personaID }) == true else { return }
        runStateMutation(label: "Restoring local persona…") { state in
            try state.unarchivePersona(personaID)
        }
    }

    func renamePersona(_ personaID: UUID, displayName: String) {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 512 else {
            lastError = describe(NoctweaveClientError.invalidPersonaName)
            return
        }
        runStateMutation(label: "Renaming local persona…") { state in
            try state.renamePersona(personaID, displayName: name)
        }
    }

    func deleteInactivePersona(_ personaID: UUID) {
        guard let snapshot = state,
              personaID != snapshot.activePersonaID,
              snapshot.personas.contains(where: { $0.id == personaID }) else {
            lastError = "Only an inactive persona can be deleted."
            return
        }
        runStateMutation(label: "Deleting inactive persona…") { state in
            state = try Self.stateByRemovingPersona(personaID, from: state)
        }
    }

    func setPersonaRelay(
        _ endpoint: RelayEndpoint,
        personaID: UUID,
        name: String,
        accessPassword: String?
    ) {
        guard state?.personas.contains(where: { $0.id == personaID }) == true else { return }
        runOperation(label: "Saving persona relay…") { client in
            try await client.upsertRelayPreference(
                endpoint: endpoint,
                name: name,
                accessPassword: accessPassword
            )
            let relayState = await client.snapshot()
            guard let relayID = relayState.relayPreferences.first(where: {
                $0.endpoint == endpoint
            })?.id else { throw NoctweaveClientError.unavailable }
            try await self.replaceStoredState { state in
                try state.setPreferredRelayPreference(relayID, forPersonaID: personaID)
            }
        }
    }

    func validateAndSaveRelay(
        relayText: String,
        password: String = "",
        preferredForPersonaID: UUID? = nil
    ) {
        relayManagementTask?.cancel()
        relayManagementCheckState = .checking
        do {
            let endpoint = try RelayEndpointParser.parse(relayText)
            let accessPassword = relayAccessPassword(for: endpoint, supplied: password)
            relayManagementTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let readiness = try await RelayPairingPreflight.check(
                        client: RelayClient(endpoint: endpoint, authToken: accessPassword),
                        requirement: .rendezvous
                    )
                    try Task.checkCancellation()
                    guard let client else { throw NoctweaveClientError.unavailable }
                    let relayPreferenceID = try await rememberRelay(
                        readiness,
                        accessPassword: accessPassword,
                        client: client
                    )
                    if let preferredForPersonaID {
                        try await client.setPreferredRelayPreference(
                            relayPreferenceID,
                            forPersonaID: preferredForPersonaID
                        )
                    }
                    relayManagementCheckState = .ready(readiness)
                    try await refresh()
                } catch is CancellationError {
                } catch {
                    relayManagementCheckState = .failed(describe(error))
                }
                relayManagementTask = nil
            }
        } catch {
            relayManagementCheckState = .failed(describe(error))
        }
    }

    func saveVerifiedRelayPreference(
        endpoint: RelayEndpoint,
        name: String,
        accessPassword: String?,
        preferredForPersonaID personaID: UUID
    ) {
        runOperation(label: "Saving verified relay…") { client in
            try await client.upsertRelayPreference(
                endpoint: endpoint,
                name: name,
                accessPassword: accessPassword
            )
            guard let relayPreferenceID = (await client.snapshot()).relayPreferences
                .first(where: { $0.endpoint == endpoint })?.id else {
                throw NoctweaveClientError.unavailable
            }
            try await client.setPreferredRelayPreference(
                relayPreferenceID,
                forPersonaID: personaID
            )
        }
    }

    func selectRelayPreference(_ relayPreferenceID: UUID, forPersonaID personaID: UUID) {
        runOperation(label: "Selecting persona relay…") { client in
            try await client.setPreferredRelayPreference(
                relayPreferenceID,
                forPersonaID: personaID
            )
        }
    }

    func deleteRelayPreference(_ relayPreferenceID: UUID) {
        runOperation(label: "Removing saved relay…") { client in
            try await client.removeRelayPreference(relayPreferenceID)
        }
    }

    func burnActivePersona(replacementName: String = "Unnamed Persona") {
        burnPersona(replacementName: replacementName)
    }

    func sendDraft() {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let relationshipID = selectedRelationshipID else { return }
        runOperation(label: "Sending…") { client in
            _ = try await client.sendText(text, relationshipID: relationshipID)
            if self.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                self.draftMessage = ""
            }
            self.statusMessage = "Message persisted and submitted through opaque routes."
        }
    }

    func sendGroupDraft() {
        let text = groupDraftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let groupID = selectedGroupID else { return }
        runOperation(label: "Sending group event…") { client in
            let result = try await client.sendGroupText(groupID: groupID, text: text)
            if self.groupDraftMessage.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                self.groupDraftMessage = ""
            }
            self.statusMessage = result.complete
                ? "Group event persisted and submitted through group-scoped opaque routes."
                : "Group event is durable and queued for route retry (\(result.disposition.rawValue))."
        }
    }

    func createGroup(groupIDText: String, relayText: String) {
        runOperation(label: "Creating group-scoped runtime…") { client in
            guard let groupID = UUID(
                uuidString: groupIDText.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                throw NoctweaveClientError.invalidGroupIdentifier
            }
            let relay = try RelayEndpointParser.parse(relayText)
            let created = try await client.createGroup(groupID: groupID, relay: relay)
            self.selectedRelationshipID = nil
            self.selectedGroupID = created.groupID
            self.statusMessage = "Created group \(created.groupID.uuidString.prefix(8)) with a fresh group-only credential and receive route."
        }
    }

    func syncAll() {
        guard bootState == .ready, isOnboardingComplete, !isLocked else { return }
        runOperation(label: "Maintaining routes and synchronizing…") { client in
            var errors: [Error] = []
            do {
                _ = try await client.maintainAllRelationships()
            } catch {
                errors.append(error)
            }

            let persona = await client.activePersona()
            let relationshipIDs = persona.relationships.map(\.id)
            let groupIDs = persona.groupRuntimes
                .filter { $0.deletionState == nil && $0.localRemoval == nil }
                .map(\.groupId)
            var received = 0
            for relationshipID in relationshipIDs {
                do {
                    // Attachment chunks must reach their relay before the
                    // descriptor event is retried. Both calls are idempotent
                    // and publish the exact artifacts retained by Core.
                    _ = try await client.retryPendingAttachmentUploads(
                        relationshipID: relationshipID
                    )
                    _ = try await client.retryPendingDeliveries(
                        relationshipID: relationshipID
                    )
                } catch {
                    errors.append(error)
                }
                do {
                    for _ in 0..<8 {
                        let batches = try await client.sync(relationshipID: relationshipID)
                        received += batches.reduce(0) { $0 + $1.receivedEvents.count }
                        if !batches.contains(where: \.hasMore) { break }
                    }
                } catch {
                    errors.append(error)
                }
                if self.privacySettings.autoDownloadAttachments {
                    do {
                        let relationship = try await client.relationship(relationshipID)
                        let missing = relationship.directSessions
                            .flatMap(\.messages)
                            .filter { message in
                                guard let attachmentID = message.attachment?.descriptor.id else {
                                    return false
                                }
                                return !self.isAttachmentAvailable(attachmentID)
                            }
                        for message in missing {
                            _ = await self.downloadAttachment(
                                message: message,
                                relationshipID: relationshipID
                            )
                        }
                    } catch {
                        errors.append(error)
                    }
                }
            }

            for groupID in groupIDs {
                do {
                    let report = try await client.maintainGroup(groupID: groupID)
                    self.groupMaintenanceStatus[groupID] = report.requiresFollowUp
                        ? "Durable group transport still has queued retries."
                        : "Group routes and pending transport are healthy."
                } catch {
                    errors.append(error)
                    self.groupMaintenanceStatus[groupID] = "Maintenance unavailable: \(self.describe(error))"
                }
                do {
                    for _ in 0..<8 {
                        let batches = try await client.syncGroup(groupID: groupID)
                        received += batches.reduce(0) { $0 + $1.receivedEvents.count }
                        if !batches.contains(where: \.hasMore) { break }
                    }
                } catch {
                    errors.append(error)
                }
            }

            if received > 0 {
                self.notificationManager.notifyNewMessage(count: received)
            }

            if let first = errors.first {
                self.statusMessage = "Sync completed with partial relay availability: \(self.describe(first))"
            } else {
                self.statusMessage = "Sync complete. \(received) new event\(received == 1 ? "" : "s")."
            }
        }
    }

    func foregroundResumeSync() {
        guard isOnboardingComplete else { return }
        Task {
            await notificationManager.requestAuthorization()
            // Current Core exposes direct relay sync as the authoritative
            // import path. Widget batches remain sealed metadata-only staging
            // until Core publishes a staged-batch ingest API.
            syncAll()
        }
    }

    func maintainRelationships() {
        runOperation(label: "Maintaining relationship routes…") { client in
            let reports = try await client.maintainAllRelationships()
            let followUps = reports.filter(\.requiresFollowUp).count
            self.statusMessage = followUps == 0
                ? "All relationship routes are healthy."
                : "\(followUps) relationship\(followUps == 1 ? "" : "s") need another maintenance pass."
        }
    }

    func maintainAllTransport() {
        runOperation(label: "Maintaining relationship and group routes…") { client in
            var errors: [Error] = []
            let relationshipReports: [HeadlessRelationshipMaintenanceReportV2]
            do {
                relationshipReports = try await client.maintainAllRelationships()
            } catch {
                relationshipReports = []
                errors.append(error)
            }
            let groupIDs = (await client.activePersona()).groupRuntimes
                .filter { $0.deletionState == nil && $0.localRemoval == nil }
                .map(\.groupId)
            var groupFollowUps = 0
            for groupID in groupIDs {
                do {
                    let report = try await client.maintainGroup(groupID: groupID)
                    if report.requiresFollowUp { groupFollowUps += 1 }
                    self.groupMaintenanceStatus[groupID] = report.requiresFollowUp
                        ? "Durable group transport still has queued retries."
                        : "Group routes and pending transport are healthy."
                } catch {
                    errors.append(error)
                    self.groupMaintenanceStatus[groupID] = "Maintenance unavailable: \(self.describe(error))"
                }
            }
            let relationshipFollowUps = relationshipReports.filter(\.requiresFollowUp).count
            let totalFollowUps = relationshipFollowUps + groupFollowUps
            if let first = errors.first {
                self.statusMessage = "Maintenance completed with partial relay availability: \(self.describe(first))"
            } else if totalFollowUps == 0 {
                self.statusMessage = "All relationship and group routes are healthy."
            } else {
                self.statusMessage = "\(totalFollowUps) transport scope\(totalFollowUps == 1 ? "" : "s") need another maintenance pass."
            }
        }
    }

    func maintainSelectedGroup() {
        guard let groupID = selectedGroupID else { return }
        runOperation(label: "Maintaining group routes…") { client in
            let report = try await client.maintainGroup(groupID: groupID)
            let value = report.requiresFollowUp
                ? "Durable group transport still has queued retries."
                : "Group routes and pending transport are healthy."
            self.groupMaintenanceStatus[groupID] = value
            self.statusMessage = value
        }
    }

    func prepareGroupJoinRequest(groupIDText: String, relayText: String) {
        groupExchangeLink = nil
        groupExchangeStatus = "Preparing a fresh group-only credential and route…"
        runOperation(label: "Preparing one-use group admission…") { client in
            guard let groupID = UUID(
                uuidString: groupIDText.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                throw NoctweaveClientError.invalidGroupIdentifier
            }
            let relay = try RelayEndpointParser.parse(relayText)
            let bindingDigest = Self.freshGroupInvitationBinding(groupID: groupID)
            let prepared = try await client.prepareGroupAdmission(
                groupID: groupID,
                invitationBindingDigest: bindingDigest,
                relay: relay,
                expiresAt: Date().addingTimeInterval(12 * 60 * 60)
            )
            _ = try await client.resumeGroupAdmissionRoute(admissionID: prepared.admissionID)
            let pending = try Self.pendingAdmission(
                prepared.admissionID,
                in: await client.activePersona()
            )
            let request = try Self.groupAdmissionRequest(from: pending)
            self.groupExchangeLink = try request.encoded()
            self.groupExchangeStatus = "Admission \(prepared.admissionID.uuidString) is saved. Share this one-use request only through an authenticated encrypted channel."
        }
    }

    func resumeGroupJoinRequest(admissionID: UUID) {
        groupExchangeLink = nil
        groupExchangeStatus = "Resuming the exact saved route request…"
        runOperation(label: "Resuming saved group admission…") { client in
            _ = try await client.resumeGroupAdmissionRoute(admissionID: admissionID)
            let pending = try Self.pendingAdmission(
                admissionID,
                in: await client.activePersona()
            )
            self.groupExchangeLink = try Self.groupAdmissionRequest(from: pending).encoded()
            self.groupExchangeStatus = "Resumed saved admission \(admissionID.uuidString)."
        }
    }

    func prepareGroupMemberResponse(requestLink: String) {
        groupExchangeLink = nil
        groupExchangeStatus = "Verifying the admission and preparing a signed group epoch…"
        runOperation(label: "Verifying group admission and preparing epoch…") { client in
            let request = try NoctweaveGroupAdmissionRequestLinkV1.decode(requestLink)
            let prepared = try await client.prepareGroupMemberAddition(
                groupID: request.groupID,
                admission: request.admission,
                initialRouteSet: request.initialRouteSet,
                idempotencyKey: try request.requestDigest
            )
            let response = try NoctweaveGroupAdmissionResponseLinkV1(
                request: request,
                prepared: prepared
            )
            self.groupExchangeLink = try response.encoded()
            do {
                let report = try await client.maintainGroup(groupID: request.groupID)
                self.groupMaintenanceStatus[request.groupID] = report.requiresFollowUp
                    ? "Member epoch is durable; relay publication still needs retry."
                    : "Member epoch and group transport are published."
                self.groupExchangeStatus = report.requiresFollowUp
                    ? "Welcome package is ready. Share it through the same authenticated encrypted channel; run maintenance again for queued relay publication."
                    : "Welcome package is ready. Share it through the same authenticated encrypted channel."
            } catch {
                self.groupMaintenanceStatus[request.groupID] = "Member epoch is durable; maintenance unavailable: \(self.describe(error))"
                self.groupExchangeStatus = "Welcome package is ready; relay publication needs a later maintenance pass."
            }
        }
    }

    func acceptGroupMemberResponse(responseLink: String) {
        groupExchangeLink = nil
        groupExchangeStatus = "Verifying the response against the saved one-use admission…"
        runOperation(label: "Verifying one-use group welcome…") { client in
            let response = try NoctweaveGroupAdmissionResponseLinkV1.decode(responseLink)
            let pending = try Self.pendingAdmission(
                response.admissionID,
                in: await client.activePersona()
            )
            let request = try Self.groupAdmissionRequest(from: pending)
            guard response.matches(request) else {
                throw NoctweaveGroupExchangeLinkError.requestMismatch
            }
            _ = try await client.pinGroupJoinAnchor(
                admissionID: response.admissionID,
                anchor: response.anchor,
                invitationBindingDigest: request.invitationBindingDigest
            )
            for announcement in response.existingMemberRouteAnnouncements {
                _ = try await client.acceptGroupAdmissionRouteAnnouncement(
                    admissionID: response.admissionID,
                    announcement: announcement
                )
            }
            _ = try await client.acceptGroupAdmissionTransition(
                admissionID: response.admissionID,
                transition: response.transition
            )
            let progress = try await client.acceptGroupAdmissionWelcome(
                admissionID: response.admissionID,
                welcome: response.welcome
            )
            guard progress.completed else {
                throw NoctweaveGroupExchangeLinkError.invalidLink
            }
            self.selectedRelationshipID = nil
            self.selectedGroupID = response.groupID
            self.groupExchangeLink = nil
            self.groupExchangeStatus = "The one-use admission was consumed. This group now has an independent group-scoped runtime."
            self.statusMessage = "Joined group \(response.groupID.uuidString.prefix(8))."
        }
    }

    func clearGroupExchangeLink() {
        groupExchangeLink = nil
        groupExchangeStatus = ""
    }

    func burnPersona(replacementName: String = "Unnamed Persona") {
        runOperation(label: "Burning local persona…") { client in
            _ = try await client.burnActivePersona(replacementDisplayName: replacementName)
            self.selectedRelationshipID = nil
            self.statusMessage = "The local persona was burned and replaced without continuity."
        }
    }

    func startOfferingPairing(
        relayText: String,
        pseudonym: String,
        relayPassword: String = ""
    ) {
        guard !isPairing else { return }
        pairingRelayCheckTask?.cancel()
        isPairing = true
        isPairingProcessing = true
        pairingLink = nil
        pairingStatus = "Rechecking relay readiness…"
        lastError = nil
        pairingTask = Task { [weak self] in
            await self?.runOffererPairing(
                relayText: relayText,
                pseudonym: pseudonym,
                relayPassword: relayPassword
            )
        }
    }

    func startAcceptingPairing(
        link: String,
        pseudonym: String,
        relayPassword: String = ""
    ) {
        guard !isPairing else { return }
        pairingRelayCheckTask?.cancel()
        isPairing = true
        isPairingProcessing = true
        pairingLink = nil
        pairingStatus = "Rechecking invitation relay readiness…"
        lastError = nil
        pairingTask = Task { [weak self] in
            await self?.runResponderPairing(
                link: link,
                pseudonym: pseudonym,
                relayPassword: relayPassword
            )
        }
    }

    func checkPairingRelay(
        relayText: String,
        relayPassword: String = "",
        requirement: RelayPairingRequirement = .rendezvous
    ) {
        do {
            let endpoint = try RelayEndpointParser.parse(relayText)
            beginPairingRelayCheck(
                endpoint: endpoint,
                relayPassword: relayPassword,
                requirement: requirement
            )
        } catch {
            pairingRelayCheckTask?.cancel()
            pairingRelayCheckState = .failed(describe(error))
        }
    }

    func checkPairingInvitationRelay(link: String, relayPassword: String = "") {
        do {
            let shared = try NoctweavePairingLinkV1.decode(link)
            guard Date() < shared.invitation.offer.expiresAt else {
                throw NoctweaveClientError.pairingExpired
            }
            beginPairingRelayCheck(
                endpoint: shared.relay,
                relayPassword: relayPassword,
                requirement: .rendezvous
            )
        } catch {
            pairingRelayCheckTask?.cancel()
            pairingRelayCheckState = .failed(describe(error))
        }
    }

    func resetPairingRelayCheck() {
        pairingRelayCheckTask?.cancel()
        pairingRelayCheckTask = nil
        pairingRelayCheckID = UUID()
        pairingRelayCheckState = .idle
    }

    func startDirectPairing(
        relayText: String,
        pseudonym: String,
        relayPassword: String = ""
    ) {
        guard !isPairing else { return }
        pairingRelayCheckTask?.cancel()
        resetDirectPairingState()
        isPairing = true
        isPairingProcessing = true
        pairingStatus = "Provisioning a private relationship route…"
        lastError = nil
        pairingTask = Task { [weak self] in
            await self?.runDirectPairingStart(
                relayText: relayText,
                pseudonym: pseudonym,
                relayPassword: relayPassword
            )
        }
    }

    func continueDirectPairing(
        payload: String,
        relayText: String,
        pseudonym: String,
        relayPassword: String = ""
    ) {
        guard pairingTask == nil else { return }
        isPairing = true
        isPairingProcessing = true
        lastError = nil
        pairingTask = Task { [weak self] in
            await self?.runDirectPairingStage(
                payload: payload,
                relayText: relayText,
                pseudonym: pseudonym,
                relayPassword: relayPassword
            )
        }
    }

    func finishDirectPairing() {
        guard directPairingCanFinish else { return }
        directPairingCanFinish = false
        directPairingPayload = nil
        isPairing = false
        isPairingProcessing = false
        pairingStatus = "A fresh unlinkable relationship is ready."
        directOffererPending = nil
        directOffererFlow = nil
        directResponderFlow = nil
        directTemporaryParticipant = nil
    }

    func cancelPairing() {
        guard isPairing else { return }
        if let pairingTask {
            pairingStatus = "Cancelling and removing temporary relay state…"
            pairingTask.cancel()
            return
        } else {
            let participant = directTemporaryParticipant
            resetDirectPairingState()
            isPairing = false
            isPairingProcessing = false
            pairingStatus = "Pairing cancelled. Start with fresh one-use material."
            if let participant, let client {
                Task { try? await client.teardownContactParticipant(participant) }
            }
        }
    }

    func clearPairingLink() {
        pairingLink = nil
        directPairingPayload = nil
        pairingStatus = ""
        resetDirectPairingState()
        resetPairingRelayCheck()
    }

    // MARK: - Conversation and group maintenance

    func deleteContact(relationshipID: UUID) {
        runOperation(label: "Blocking and removing contact routes…") { client in
            // Core 1.0 intentionally retains relationship evidence and exposes
            // block/route teardown, not a destructive protocol-level delete.
            _ = try await client.blockRelationship(relationshipID)
            self.statusMessage = "Contact blocked and its active opaque routes were torn down."
        }
    }

    func clearChat(relationshipID: UUID) {
        runStateMutation(label: "Clearing local chat projection…") { state in
            try state.updateActivePersona { persona in
                guard let index = persona.relationships.firstIndex(where: { $0.id == relationshipID }) else {
                    throw HeadlessMessagingClientError.relationshipNotFound
                }
                var relationship = persona.relationships[index]
                relationship.directSessions = relationship.directSessions.map { session in
                    var cleared = session
                    cleared.messages.removeAll(keepingCapacity: false)
                    cleared.unreadCount = 0
                    return cleared
                }
                try persona.upsert(relationship: relationship)
            }
        }
    }

    func retryRelationship(relationshipID: UUID) {
        runOperation(label: "Retrying relationship delivery…") { client in
            _ = try await client.maintainRelationship(relationshipID: relationshipID)
            _ = try await client.retryPendingDeliveries(relationshipID: relationshipID)
            self.statusMessage = "Relationship delivery retry completed."
        }
    }

    func extinguishGroup(groupID: UUID) {
        runOperation(label: "Preparing group extinguish…") { client in
            let prepared = try await client.prepareGroupDeletion(
                groupID: groupID,
                idempotencyKey: Data(SHA256.hash(data: Data("group-delete:\(groupID.uuidString)".utf8)))
            )
            if let operation = prepared.transportOperation {
                _ = try await client.resumeGroupTransport(
                    groupID: groupID,
                    operationID: operation.id
                )
            }
            self.statusMessage = prepared.complete
                ? "Group extinguish was durably published."
                : "Group extinguish is durable and queued for retry."
        }
    }

    func leaveGroup(groupID: UUID) {
        runOperation(label: "Publishing private group departure…") { client in
            let persona = await client.activePersona()
            guard let group = persona.groupRuntimes.first(where: {
                $0.groupId == groupID && $0.deletionState == nil && $0.localRemoval == nil
            }) else {
                throw HeadlessMessagingClientError.invalidState
            }
            let complete = try await self.publishGroupMemberRemoval(
                client: client,
                group: group,
                target: group.localCredential.memberHandle
            )
            if complete {
                self.selectedGroupID = nil
            }
            self.statusMessage = complete
                ? "You left the group. Its group-only identity is now retired."
                : "Departure is durable and will finish when the relay is reachable."
        }
    }

    func removeGroupMember(
        groupID: UUID,
        memberHandle: GroupScopedMemberHandleV2
    ) {
        runOperation(label: "Removing group member…") { client in
            let persona = await client.activePersona()
            guard let group = persona.groupRuntimes.first(where: {
                $0.groupId == groupID && $0.deletionState == nil && $0.localRemoval == nil
            }) else {
                throw HeadlessMessagingClientError.invalidState
            }
            let complete = try await self.publishGroupMemberRemoval(
                client: client,
                group: group,
                target: memberHandle
            )
            self.statusMessage = complete
                ? "The member was removed with a signed group transition."
                : "Removal is durable and will finish when the relay is reachable."
        }
    }

    private func publishGroupMemberRemoval(
        client: HeadlessMessagingClient,
        group: GroupRuntimeRecord,
        target: GroupScopedMemberHandleV2
    ) async throws -> Bool {
        let currentEpoch = group.signedState.epoch
        guard currentEpoch < UInt64.max,
              group.signedState.activeMembers.contains(where: { $0.id == target }) else {
            throw HeadlessMessagingClientError.invalidState
        }
        let nextEpoch = currentEpoch + 1
        let proposedMembers = group.signedState.members.map { member in
            guard member.id == target else { return member }
            return GroupMemberV2(
                id: member.id,
                role: member.role,
                addedEpoch: member.addedEpoch,
                removedEpoch: nextEpoch
            )
        }
        let proposedCredentials = group.signedState.memberCredentials.map { credential in
            guard credential.memberHandle == target,
                  credential.isActive(at: currentEpoch) else {
                return credential
            }
            return GroupMemberCredentialV2(
                memberHandle: credential.memberHandle,
                credentialHandle: credential.credentialHandle,
                admissionDigest: credential.admissionDigest,
                signingPublicKey: credential.signingPublicKey,
                agreementPublicKey: credential.agreementPublicKey,
                contentTypes: credential.contentTypes,
                addedEpoch: credential.addedEpoch,
                removedEpoch: nextEpoch
            )
        }
        let idempotencyMaterial = Data(
            "org.noctweave.group-remove-member/v1:\(group.groupId.uuidString.lowercased()):\(target.rawValue):\(currentEpoch)".utf8
        )
        let prepared = try await client.prepareGroupEpoch(
            groupID: group.groupId,
            operation: .removeMember,
            proposedMembers: proposedMembers,
            proposedCredentials: proposedCredentials,
            proposedPermissions: group.signedState.permissions,
            proposedMetadataDigest: group.signedState.metadataDigest,
            idempotencyKey: Data(SHA256.hash(data: idempotencyMaterial))
        )
        guard let operation = prepared.transportOperation else {
            return prepared.complete
        }
        return try await client.resumeGroupTransport(
            groupID: group.groupId,
            operationID: operation.id
        ).complete
    }

    // MARK: - Direct attachments

    /// Sanitizes bytes before any relay operation, then hands the sanitized
    /// payload to Core's single-ratchet attachment transaction. The exact
    /// encrypted chunks, descriptor event, and outbox deliveries are committed
    /// together before network publication.
    func sendSanitizedDirectAttachment(
        data: Data,
        fileName: String?,
        mimeType: String,
        relationshipID: UUID,
        attachmentID: UUID = UUID(),
        sentAt: Date = Date()
    ) {
        runOperation(label: "Preparing encrypted attachment…") { client in
            let sanitized = try await ClientAttachmentSanitizer.sanitize(
                data: data,
                fileName: fileName,
                mimeType: mimeType
            )
            defer { var bytes = sanitized.data; bytes.secureWipeClientAttachment() }
            guard !sanitized.data.isEmpty,
                  sanitized.data.count <= AttachmentDescriptor.maximumTransportBytes else {
                throw NoctweaveClientError.invalidAttachment
            }
            let relationship = try await client.relationship(relationshipID)
            guard let relay = relationship.peerIdentity.sendRoutes
                .usableRoutes(at: sentAt)
                .first?.relay else {
                throw NoctweaveClientError.unavailable
            }
            let localFileName = try self.attachmentStore.saveSanitizedAttachment(
                sanitized.data,
                attachmentId: attachmentID
            )
            self.receivedAttachmentFileNames[attachmentID] = localFileName
            _ = try await client.sendAttachment(
                sanitized.data,
                mimeType: sanitized.mimeType,
                relay: relay,
                relationshipID: relationshipID,
                attachmentID: attachmentID,
                sentAt: sentAt
            )
            self.statusMessage = "Attachment sanitized, encrypted, and queued."
        }
    }

    func sendDirectAttachment(from url: URL, relationshipID: UUID) {
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  let byteCount = values.fileSize,
                  byteCount > 0,
                  byteCount <= AttachmentDescriptor.maximumTransportBytes else {
                throw NoctweaveClientError.invalidAttachment
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let type = UTType(filenameExtension: url.pathExtension)
            let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
            sendSanitizedDirectAttachment(
                data: data,
                fileName: url.lastPathComponent,
                mimeType: mimeType,
                relationshipID: relationshipID
            )
        } catch {
            lastError = describe(error)
            statusMessage = "The attachment could not be imported."
        }
    }

    func attachmentMessage(eventID: UUID, relationshipID: UUID) -> Message? {
        guard let relationship = relationships.first(where: { $0.id == relationshipID }) else {
            return nil
        }
        return relationship.directSessions
            .reversed()
            .lazy
            .flatMap { $0.messages.reversed() }
            .first { $0.id == eventID && $0.attachment != nil }
    }

    func isAttachmentAvailable(_ attachmentID: UUID) -> Bool {
        receivedAttachmentFileNames[attachmentID] != nil
            || attachmentStore.existingFileName(attachmentId: attachmentID) != nil
    }

    func decryptedAttachmentData(_ attachmentID: UUID) throws -> Data {
        guard let fileName = receivedAttachmentFileNames[attachmentID]
                ?? attachmentStore.existingFileName(attachmentId: attachmentID) else {
            throw NoctweaveClientError.invalidAttachment
        }
        return try attachmentStore.loadSanitizedAttachment(fileName: fileName)
    }

    func downloadAttachment(eventID: UUID, relationshipID: UUID) async -> String? {
        guard let message = attachmentMessage(
            eventID: eventID,
            relationshipID: relationshipID
        ) else {
            lastError = describe(NoctweaveClientError.invalidAttachment)
            return nil
        }
        return await downloadAttachment(message: message, relationshipID: relationshipID)
    }

    func downloadAttachment(
        message: Message,
        relationshipID: UUID
    ) async -> String? {
        guard let info = message.attachment,
              let cryptoContext = info.cryptoContext,
              let messageKeyData = info.messageKeyData,
              messageKeyData.count == 32,
              let relay = info.relay
                ?? activePersonaRelayPreference?.endpoint
                ?? state?.relayPreferences.first?.endpoint else {
            lastError = describe(NoctweaveClientError.invalidAttachment)
            return nil
        }
        let descriptor = info.descriptor
        guard descriptor.isStructurallyValid() else {
            lastError = describe(NoctweaveClientError.invalidAttachment)
            return nil
        }
        guard !attachmentDownloadsInFlight.contains(descriptor.id) else {
            lastError = describe(NoctweaveClientError.attachmentDownloadInProgress)
            return nil
        }
        attachmentDownloadsInFlight.insert(descriptor.id)
        defer { attachmentDownloadsInFlight.remove(descriptor.id) }
        do {
            guard let client else { throw NoctweaveClientError.unavailable }
            let relationshipSnapshot = try await client.relationship(relationshipID)
            let pending: PendingAttachmentDownloadV2
            if let existing = relationshipSnapshot.pendingAttachmentDownloads.first(where: {
                $0.descriptor.id == descriptor.id
            }) {
                pending = existing
            } else {
                pending = try await client.prepareAttachmentDownload(
                    descriptor,
                    relay: relay,
                    relationshipID: relationshipID
                )
            }

            var chunksByIndex = Dictionary(
                uniqueKeysWithValues: pending.receivedChunks.map { ($0.chunkIndex, $0) }
            )
            var fetchPasses = 0
            while chunksByIndex.count < descriptor.chunkCount {
                let previousCount = chunksByIndex.count
                let result = try await client.fetchAttachmentDownload(
                    downloadID: pending.id,
                    relationshipID: relationshipID
                )
                fetchPasses += 1
                for chunk in result.chunks {
                    guard chunk.attachmentId == descriptor.id,
                          (0..<descriptor.chunkCount).contains(chunk.chunkIndex),
                          chunk.isStructurallyValid else {
                        throw NoctweaveClientError.invalidAttachment
                    }
                    chunksByIndex[chunk.chunkIndex] = chunk
                }
                guard chunksByIndex.count > previousCount
                        || chunksByIndex.count == descriptor.chunkCount,
                      fetchPasses <= descriptor.chunkCount + 1 else {
                    throw NoctweaveClientError.unavailable
                }
            }

            var plaintext = Data()
            plaintext.reserveCapacity(descriptor.byteCount)
            for chunkIndex in 0..<descriptor.chunkCount {
                guard let chunk = chunksByIndex[chunkIndex] else {
                    throw NoctweaveClientError.invalidAttachment
                }
                let expectedBytes = min(
                    descriptor.chunkSize,
                    descriptor.byteCount - chunkIndex * descriptor.chunkSize
                )
                let authenticatedData = AttachmentCrypto.authenticatedData(
                    conversationId: cryptoContext.conversationId,
                    sessionId: cryptoContext.sessionId,
                    messageCounter: cryptoContext.messageCounter,
                    attachmentId: descriptor.id,
                    chunkIndex: chunkIndex,
                    byteCount: expectedBytes
                )
                let opened = try AttachmentCrypto.decryptChunk(
                    payload: chunk.payload,
                    messageKey: AttachmentCrypto.key(from: messageKeyData),
                    attachmentId: descriptor.id,
                    chunkIndex: chunkIndex,
                    authenticatedData: authenticatedData
                )
                guard opened.count == expectedBytes else {
                    throw NoctweaveClientError.invalidAttachment
                }
                plaintext.append(opened)
            }
            guard plaintext.count == descriptor.byteCount,
                  AttachmentCrypto.sha256(plaintext) == descriptor.sha256 else {
                throw NoctweaveClientError.invalidAttachment
            }
            let fileName = try attachmentStore.saveSanitizedAttachment(
                plaintext,
                attachmentId: descriptor.id
            )
            receivedAttachmentFileNames[descriptor.id] = fileName
            return fileName
        } catch {
            lastError = describe(error)
            return nil
        }
    }

    func lockNow() {
        backgroundedAt = nil
        biometricStepPassed = false
        lockError = nil
        isLocked = true
    }

    func lockForBackgroundIfConfigured() {
        guard appLockMode != .off else { return }
        if backgroundedAt == nil { backgroundedAt = Date() }
        if appLockSettings.sessionTimeoutMinutes == 0 { lockNow() }
    }

    func resumeFromBackground() {
        guard let backgroundedAt else { return }
        self.backgroundedAt = nil
        guard appLockMode != .off else { return }
        let timeout = TimeInterval(appLockSettings.sessionTimeoutMinutes * 60)
        if timeout == 0 || Date().timeIntervalSince(backgroundedAt) >= timeout {
            lockNow()
        }
    }

    func unlockWithBiometrics() async {
        guard !biometricRequestInFlight else { return }
        biometricRequestInFlight = true
        defer { biometricRequestInFlight = false }
        lockError = nil
        if appLockMode == .off {
            isLocked = false
            return
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            lockError = "Biometric authentication is unavailable."
            return
        }
        do {
            let accepted = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock encrypted Noctweave conversations"
            )
            guard accepted else {
                lockError = "Biometric authentication failed."
                return
            }
            if appLockMode == .biometricsAndPin {
                biometricStepPassed = true
            } else {
                backgroundedAt = nil
                isLocked = false
            }
        } catch {
            lockError = describe(error)
        }
    }

    func unlockWithPIN(_ value: String) {
        guard appLockMode == .pinOnly
                || (appLockMode == .biometricsAndPin && biometricStepPassed) else {
            lockError = "Complete biometric authentication first."
            return
        }
        if let pinLockedUntil, pinLockedUntil > Date() {
            lockError = "PIN entry is temporarily locked."
            return
        }
        guard let settings = state?.appLock,
              let salt = settings.pinSalt,
              let expected = settings.pinHash,
              matchesStructuredPIN(value, salt: salt, expected: expected) else {
            failedPINAttempts += 1
            if failedPINAttempts >= 5 {
                pinLockedUntil = Date().addingTimeInterval(30)
                failedPINAttempts = 0
                lockError = "Too many attempts. PIN entry is locked for 30 seconds."
            } else {
                lockError = "Incorrect PIN."
            }
            return
        }
        failedPINAttempts = 0
        pinLockedUntil = nil
        lockError = nil
        backgroundedAt = nil
        isLocked = false
    }

    func saveAppearance(_ palette: ThemePalette) async -> Bool {
        await performSettingsSave(success: "Appearance updated.") { client in
            try await client.updateAppearanceSettings(AppearanceSettings(theme: palette))
        }
    }

    func savePrivacy(_ settings: PrivacySettings) async -> Bool {
        await performSettingsSave(success: "Privacy preferences updated.") { client in
            try await client.updatePrivacySettings(settings)
        }
    }

    func authorizeAppLockChanges(pin: String? = nil) async -> Bool {
        settingsError = nil
        do {
            switch appLockMode {
            case .off:
                break
            case .biometrics:
                try await evaluateBiometrics(
                    reason: "Authorize changes to Noctweave app security"
                )
                settingsBiometricAuthorizedUntil = Date().addingTimeInterval(300)
            case .pinOnly:
                guard let pin, verifyConfiguredPIN(pin) else {
                    throw NoctweaveClientError.invalidAppLockPIN
                }
            case .biometricsAndPin:
                guard let pin, verifyConfiguredPIN(pin) else {
                    throw NoctweaveClientError.invalidAppLockPIN
                }
                try await evaluateBiometrics(
                    reason: "Authorize changes to Noctweave app security"
                )
                settingsBiometricAuthorizedUntil = Date().addingTimeInterval(300)
            }
            settingsAuthorizedUntil = Date().addingTimeInterval(300)
            return true
        } catch {
            settingsError = describe(error)
            return false
        }
    }

    func cancelAppLockChanges() {
        settingsAuthorizedUntil = nil
        settingsBiometricAuthorizedUntil = nil
        settingsError = nil
    }

    func saveAppLockConfiguration(
        mode: AppLockMode,
        sessionTimeoutMinutes: Int,
        lockScreenMessage: String,
        newPIN: String?
    ) async -> Bool {
        guard !isSavingSettings else { return false }
        settingsError = nil
        settingsMessage = nil
        isSavingSettings = true
        defer { isSavingSettings = false }

        do {
            if appLockMode != .off {
                guard let settingsAuthorizedUntil, settingsAuthorizedUntil > Date() else {
                    throw NoctweaveClientError.settingsAuthorizationRequired
                }
            }

            if mode == .biometrics || mode == .biometricsAndPin {
                if settingsBiometricAuthorizedUntil.map({ $0 > Date() }) != true {
                    try await evaluateBiometrics(
                        reason: "Enable biometric protection for Noctweave"
                    )
                }
            }

            let pinRecord: AppLockPINRecordV2?
            if mode == .pinOnly || mode == .biometricsAndPin {
                guard let newPIN else { throw NoctweaveClientError.invalidAppLockPIN }
                pinRecord = try await Task.detached(priority: .userInitiated) {
                    try AppLockPINV2.makeRecord(pin: newPIN)
                }.value
            } else {
                pinRecord = nil
            }

            let candidate = AppLockSettings(
                mode: mode,
                sessionTimeoutMinutes: sessionTimeoutMinutes,
                lockScreenMessage: lockScreenMessage.trimmingCharacters(in: .whitespacesAndNewlines),
                pinSalt: pinRecord?.salt,
                pinHash: pinRecord?.encodedHash,
                actionPlans: appLockSettings.actionPlans
            )
            guard candidate.isStructurallyValid else {
                throw NoctweaveClientError.invalidAppLockPIN
            }
            guard let client else { throw NoctweaveClientError.unavailable }
            try await client.updateAppLockSettings(candidate)
            try await refresh()
            if mode == .off {
                isLocked = false
                biometricStepPassed = false
            }
            settingsMessage = mode == .off
                ? "App lock disabled."
                : "App security updated."
            settingsAuthorizedUntil = nil
            settingsBiometricAuthorizedUntil = nil
            return true
        } catch {
            settingsError = describe(error)
            return false
        }
    }

    func displayText(for event: ConversationEvent) -> String {
        if event.content.type == .text,
           let value = String(data: event.content.payload, encoding: .utf8) {
            return value
        }
        if let fallback = event.content.fallbackText, !fallback.isEmpty {
            return fallback
        }
        return "Unsupported content: \(event.content.type.canonicalName)"
    }

    func displayText(for event: GroupConversationEventV2) -> String {
        if event.content.type == .text,
           let value = String(data: event.content.payload, encoding: .utf8) {
            return value
        }
        if let fallback = event.content.fallbackText, !fallback.isEmpty {
            return fallback
        }
        return "Unsupported group content: \(event.content.type.canonicalName)"
    }

    func isOutgoing(_ event: ConversationEvent) -> Bool {
        guard let relationshipID = selectedRelationshipID else { return false }
        return isOutgoing(event, relationshipID: relationshipID)
    }

    func isOutgoing(_ event: ConversationEvent, relationshipID: UUID) -> Bool {
        event.authorEndpointHandle == relationships
            .first(where: { $0.id == relationshipID })?
            .localEndpointHandle
    }

    func isOutgoing(_ event: GroupConversationEventV2) -> Bool {
        event.authorCredentialHandle == selectedGroup?.localCredential.credentialHandle
    }

    private static func pendingAdmission(
        _ admissionID: UUID,
        in persona: PersonaProfileV1
    ) throws -> PendingGroupAdmissionV2 {
        guard let pending = persona.pendingGroupAdmissions.first(where: { $0.id == admissionID })
        else {
            throw NoctweaveClientError.pendingAdmissionMissing
        }
        return pending
    }

    private static func groupAdmissionRequest(
        from pending: PendingGroupAdmissionV2
    ) throws -> NoctweaveGroupAdmissionRequestLinkV1 {
        guard let routeSet = pending.advertisedRouteSet else {
            throw NoctweaveClientError.pendingAdmissionMissing
        }
        return try NoctweaveGroupAdmissionRequestLinkV1(
            admissionID: pending.id,
            groupID: pending.groupID,
            invitationBindingDigest: pending.invitationBindingDigest,
            admission: pending.admission,
            initialRouteSet: routeSet
        )
    }

    private static func freshGroupInvitationBinding(groupID: UUID) -> Data {
        var material = Data("org.noctweave.group-invitation-binding/v1\0".utf8)
        material.append(Data(groupID.uuidString.lowercased().utf8))
        SymmetricKey(size: .bits256).withUnsafeBytes { material.append(contentsOf: $0) }
        return Data(SHA256.hash(data: material))
    }

    private func runOperation(
        label: String,
        _ operation: @escaping (HeadlessMessagingClient) async throws -> Void
    ) {
        guard !isWorking else { return }
        isWorking = true
        statusMessage = label
        lastError = nil
        Task {
            defer { isWorking = false }
            do {
                guard let client else { throw NoctweaveClientError.unavailable }
                try await operation(client)
                try await refresh()
            } catch {
                // Many Core operations are local-first transactions. Refresh
                // even when publication failed so a durably queued message or
                // attachment never disappears from the sender's UI.
                try? await refresh()
                lastError = describe(error)
                statusMessage = "The operation did not complete."
            }
        }
    }

    private func runStateMutation(
        label: String,
        _ mutation: @escaping (inout ClientState) throws -> Void
    ) {
        guard !isWorking else {
            lastError = describe(NoctweaveClientError.personaOperationInProgress)
            return
        }
        isWorking = true
        statusMessage = label
        lastError = nil
        Task {
            defer { isWorking = false }
            do {
                try await replaceStoredState(mutation)
                statusMessage = "Local state updated."
            } catch {
                lastError = describe(error)
                statusMessage = "The local state operation did not complete."
            }
        }
    }

    private func replaceStoredState(
        _ mutation: (inout ClientState) throws -> Void
    ) async throws {
        guard let previous = try await stateStore.load() else {
            throw NoctweaveClientError.unavailable
        }
        var candidate = previous
        try mutation(&candidate)
        try await stateStore.save(candidate, replacing: previous)
        client = try HeadlessMessagingClient(
            stateStore: stateStore,
            initialState: candidate
        )
        try await refresh()
        draftMessage = ""
        groupDraftMessage = ""
    }

    private static func makeProductFixtureState() throws -> ClientState {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var state = try ClientState(
            displayName: "Fixture Persona",
            hasCompletedOnboarding: true,
            hasAcceptedPrivacyPolicy: true,
            hasAcceptedTermsOfUse: true,
            createdAt: now
        )
        let firstPersonaID = state.activePersonaID
        let offer = try ContactPairingHandshakeV2.makeOffer(
            createdAt: now,
            expiresAt: now.addingTimeInterval(24 * 60 * 60)
        )
        let offerer = try Self.makeFixtureParticipant(
            pseudonym: "Fixture local contact",
            relay: RelayEndpoint(host: "fixture-offerer.invalid", port: 443, useTLS: true, transport: .websocket),
            createdAt: now
        )
        let responder = try Self.makeFixtureParticipant(
            pseudonym: "Fixture remote contact",
            relay: RelayEndpoint(host: "fixture-responder.invalid", port: 443, useTLS: true, transport: .websocket),
            createdAt: now
        )
        var pending = offer.pending
        var ledger = RendezvousRedemptionLedgerV2()
        let responderStart = try ContactPairingResponderFlowV2.begin(
            invitation: offer.invitation,
            participant: responder,
            at: now
        )
        var responderFlow = responderStart.flow
        let offererStart = try ContactPairingOffererFlowV2.begin(
            pendingOffer: &pending,
            invitation: offer.invitation,
            participant: offerer,
            openRequest: responderStart.openRequest,
            acceptanceFrame: responderStart.acceptanceFrame,
            ledger: &ledger,
            at: now
        )
        var offererFlow = offererStart.flow
        let responderConfirmation = try responderFlow.receiveOffer(
            offererStart.offerFrame,
            at: now
        )
        let offererCompletion = try offererFlow.receiveConfirmation(
            responderConfirmation,
            at: now
        )
        let relationship = try responderFlow.receiveConfirmation(
            offererCompletion.confirmationFrame,
            at: now
        )
        var relationshipWithEvent = relationship
        guard let content = EncodedContent.text("Fixture message") else {
            throw NoctweaveClientError.invalidAttachment
        }
        let event = ConversationEvent(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            clientTransactionId: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            conversationId: relationship.conversationID,
            authorEndpointHandle: relationship.localEndpointHandle,
            createdAt: now,
            kind: .application,
            content: content
        )
        guard try relationshipWithEvent.appendEvent(event) else {
            throw HeadlessMessagingClientError.conflictingEnvelope
        }
        try state.updateActivePersona { persona in
            try persona.upsert(relationship: relationshipWithEvent)
        }
        let inactive = try state.addPersona(displayName: "Fixture Inactive Persona", createdAt: now)
        try state.selectPersona(firstPersonaID)
        _ = inactive
        return state
    }

    private static func makeFixtureParticipant(
        pseudonym: String,
        relay: RelayEndpoint,
        createdAt: Date
    ) throws -> PreparedContactParticipantV2 {
        let pending = try PendingContactParticipantV2.prepare(
            relationshipPseudonym: pseudonym,
            relay: relay,
            createdAt: createdAt
        )
        let route = try OpaqueReceiveRouteV2.creating(
            from: pending.routeCreateRequest,
            presentedRenewCapability: pending.clientCapabilities.renewCapability,
            existing: nil,
            confidentialTransport: true,
            receivedAt: createdAt
        )
        return try pending.activate(createdRoute: route)
    }

    private static func stateByRemovingPersona(
        _ personaID: UUID,
        from original: ClientState
    ) throws -> ClientState {
        let retained = original.personas.filter { $0.id != personaID }
        guard !retained.isEmpty,
              let originalActive = original.personas.first(where: { $0.id == original.activePersonaID }),
              retained.contains(where: { $0.id == original.activePersonaID }) else {
            throw ClientStateError.invalidState
        }
        var rebuilt = try ClientState(
            displayName: retained[0].displayName,
            relayPreferences: original.relayPreferences,
            relaySourcePreferences: original.relaySourcePreferences,
            appearance: original.appearance,
            privacy: original.privacy,
            appLock: original.appLock,
            chatList: original.chatList,
            relayCertificatePins: original.relayCertificatePins,
            hasCompletedOnboarding: original.hasCompletedOnboarding,
            hasAcceptedPrivacyPolicy: original.hasAcceptedPrivacyPolicy,
            hasAcceptedTermsOfUse: original.hasAcceptedTermsOfUse,
            createdAt: retained[0].createdAt
        )
        var replacementIDs: [UUID: UUID] = [retained[0].id: rebuilt.activePersonaID]
        for persona in retained.dropFirst() {
            let replacement = try rebuilt.addPersona(
                displayName: persona.displayName,
                createdAt: persona.createdAt
            )
            replacementIDs[persona.id] = replacement.id
        }
        for (sourcePersonaID, relayPreferenceID) in original.preferredRelayPreferenceIDsByPersonaID {
            guard let replacementID = replacementIDs[sourcePersonaID] else { continue }
            try rebuilt.setPreferredRelayPreference(
                relayPreferenceID,
                forPersonaID: replacementID
            )
        }
        for sourcePersonaID in original.archivedPersonaIDs {
            guard let replacementID = replacementIDs[sourcePersonaID] else { continue }
            try rebuilt.archivePersona(replacementID)
        }
        for persona in retained {
            guard let replacementID = replacementIDs[persona.id] else {
                throw ClientStateError.invalidState
            }
            try rebuilt.selectPersona(replacementID)
            try rebuilt.updateActivePersona { destination in
                for relationship in persona.relationships {
                    try destination.upsert(relationship: relationship)
                }
                for group in persona.groupRuntimes {
                    try destination.upsert(groupRuntime: group)
                }
                for admission in persona.pendingGroupAdmissions {
                    try destination.insert(pendingGroupAdmission: admission)
                }
            }
        }
        guard let replacementActiveID = replacementIDs[originalActive.id] else {
            throw ClientStateError.invalidState
        }
        try rebuilt.selectPersona(replacementActiveID)
        return rebuilt
    }

    private func beginPairingRelayCheck(
        endpoint: RelayEndpoint,
        relayPassword: String,
        requirement: RelayPairingRequirement
    ) {
        pairingRelayCheckTask?.cancel()
        let checkID = UUID()
        pairingRelayCheckID = checkID
        pairingRelayCheckState = .checking
        let accessPassword = relayAccessPassword(
            for: endpoint,
            supplied: relayPassword
        )
        pairingRelayCheckTask = Task { [weak self] in
            guard let self else { return }
            do {
                let readiness = try await RelayPairingPreflight.check(
                    client: RelayClient(endpoint: endpoint, authToken: accessPassword),
                    requirement: requirement
                )
                try Task.checkCancellation()
                guard pairingRelayCheckID == checkID else { return }
                pairingRelayCheckState = .ready(readiness)
            } catch is CancellationError {
                return
            } catch {
                guard pairingRelayCheckID == checkID else { return }
                pairingRelayCheckState = .failed(describe(error))
            }
            if pairingRelayCheckID == checkID {
                pairingRelayCheckTask = nil
            }
        }
    }

    private func relayAccessPassword(
        for endpoint: RelayEndpoint,
        supplied: String
    ) -> String? {
        let normalized = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty { return normalized }
        return state?.relayPreferences.first(where: { $0.endpoint == endpoint })?
            .accessPassword
    }

    private func rememberRelay(
        _ readiness: RelayPairingReadiness,
        accessPassword: String?,
        client: HeadlessMessagingClient
    ) async throws -> UUID {
        let fallbackName = readiness.endpoint.host
        let name = readiness.relayInfo.relayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if let name, !name.isEmpty {
            resolvedName = name
        } else {
            resolvedName = fallbackName
        }
        try await client.upsertRelayPreference(
            endpoint: readiness.endpoint,
            name: resolvedName,
            accessPassword: accessPassword
        )
        guard let relayPreferenceID = (await client.snapshot()).relayPreferences
            .first(where: { $0.endpoint == readiness.endpoint })?.id else {
            throw NoctweaveClientError.unavailable
        }
        return relayPreferenceID
    }

    private func runOffererPairing(
        relayText: String,
        pseudonym: String,
        relayPassword: String
    ) async {
        var cleanup: (RelayClient, RendezvousRelayAdapterV2)?
        var temporaryParticipant: PreparedContactParticipantV2?
        defer {
            isPairing = false
            isPairingProcessing = false
            pairingTask = nil
        }
        do {
            guard let client else { throw NoctweaveClientError.unavailable }
            let endpoint = try RelayEndpointParser.parse(relayText)
            let accessPassword = relayAccessPassword(
                for: endpoint,
                supplied: relayPassword
            )
            let readiness = try await RelayPairingPreflight.check(
                client: RelayClient(endpoint: endpoint, authToken: accessPassword),
                requirement: .rendezvous,
                performRuntimeProbe: false
            )
            _ = try await rememberRelay(
                readiness,
                accessPassword: accessPassword,
                client: client
            )
            let localPseudonym = try validatedPseudonym(pseudonym)
            let now = Date()
            var offer = try await client.makeContactPairingInvitation(
                createdAt: now,
                expiresAt: now.addingTimeInterval(10 * 60)
            )
            let adapter = try RendezvousRelayAdapterV2(offer: offer.invitation.offer)
            let relay = RelayClient(endpoint: endpoint, authToken: accessPassword)
            cleanup = (relay, adapter)

            try requireEmpty(
                await relay.send(.registerRendezvousTransportV2(adapter.registrationRequest))
            )
            let pendingParticipant = try await client.prepareContactParticipant(
                relay: endpoint,
                relationshipPseudonym: localPseudonym,
                createdAt: now
            )
            let participant = try await client.activateContactParticipant(pendingParticipant)
            temporaryParticipant = participant
            pairingLink = try NoctweavePairingLinkV1(
                relay: endpoint,
                invitation: offer.invitation
            ).encoded()
            pairingStatus = "Share this one-use invitation privately. Waiting for the responder…"

            let inbound = try await waitForFrames(
                relay: relay,
                adapter: adapter,
                receivingAs: .offerer,
                afterSequence: 0,
                throughSequence: 2,
                deadline: offer.invitation.offer.expiresAt
            )
            let openFrame = try frame(sequence: 1, in: inbound)
            let acceptanceFrame = try frame(sequence: 2, in: inbound)
            guard case .open(let openRequest) = try adapter.open(
                openFrame,
                direction: .responderToOfferer
            ), case .sessionFrame(let acceptance) = try adapter.open(
                acceptanceFrame,
                direction: .responderToOfferer
            ) else {
                throw NoctweaveClientError.invalidPairingLink
            }

            var ledger = RendezvousRedemptionLedgerV2()
            let started = try ContactPairingOffererFlowV2.begin(
                pendingOffer: &offer.pending,
                invitation: offer.invitation,
                participant: participant,
                openRequest: openRequest,
                acceptanceFrame: acceptance,
                ledger: &ledger,
                at: Date()
            )
            var flow = started.flow
            try requireEmpty(await relay.send(.appendRendezvousTransportV2(
                try adapter.sealSessionFrame(started.offerFrame, transportSequence: 1)
            )))
            pairingStatus = "Introductions exchanged. Verifying the relationship transcript…"

            let confirmations = try await waitForFrames(
                relay: relay,
                adapter: adapter,
                receivingAs: .offerer,
                afterSequence: 2,
                throughSequence: 3,
                deadline: offer.invitation.offer.expiresAt
            )
            let confirmationOuter = try frame(sequence: 3, in: confirmations)
            guard case .sessionFrame(let confirmation) = try adapter.open(
                confirmationOuter,
                direction: .responderToOfferer
            ) else {
                throw NoctweaveClientError.invalidPairingLink
            }
            let completion = try flow.receiveConfirmation(confirmation, at: Date())
            let scope = await client.mintActivePersonaScopeToken()
            try await client.addRelationship(
                completion.relationship,
                consent: .accepted,
                personaScope: scope
            )
            temporaryParticipant = nil
            try requireEmpty(await relay.send(.appendRendezvousTransportV2(
                try adapter.sealSessionFrame(
                    completion.confirmationFrame,
                    transportSequence: 2
                )
            )))
            await deleteTemporaryLanes(relay: relay, adapter: adapter)
            cleanup = nil
            pairingLink = nil
            pairingStatus = "A fresh unlinkable relationship is ready."
            try await refresh()
        } catch {
            if let cleanup {
                await deleteTemporaryLanes(relay: cleanup.0, adapter: cleanup.1)
            }
            if let temporaryParticipant, let client {
                try? await client.teardownContactParticipant(temporaryParticipant)
            }
            pairingLink = nil
            if error is CancellationError {
                pairingStatus = "Pairing cancelled. Start with a fresh invitation."
            } else {
                lastError = describe(error)
                pairingStatus = "Pairing stopped: \(describe(error))"
            }
        }
    }

    private func runResponderPairing(
        link: String,
        pseudonym: String,
        relayPassword: String
    ) async {
        var cleanup: (RelayClient, RendezvousRelayAdapterV2)?
        var temporaryParticipant: PreparedContactParticipantV2?
        defer {
            isPairing = false
            isPairingProcessing = false
            pairingTask = nil
        }
        do {
            guard let client else { throw NoctweaveClientError.unavailable }
            let shared = try NoctweavePairingLinkV1.decode(link)
            guard Date() < shared.invitation.offer.expiresAt else {
                throw NoctweaveClientError.pairingExpired
            }
            let accessPassword = relayAccessPassword(
                for: shared.relay,
                supplied: relayPassword
            )
            let readiness = try await RelayPairingPreflight.check(
                client: RelayClient(endpoint: shared.relay, authToken: accessPassword),
                requirement: .rendezvous,
                performRuntimeProbe: false
            )
            _ = try await rememberRelay(
                readiness,
                accessPassword: accessPassword,
                client: client
            )
            let localPseudonym = try validatedPseudonym(pseudonym)
            let adapter = try RendezvousRelayAdapterV2(offer: shared.invitation.offer)
            let relay = RelayClient(endpoint: shared.relay, authToken: accessPassword)
            cleanup = (relay, adapter)
            try requireEmpty(
                await relay.send(.registerRendezvousTransportV2(adapter.registrationRequest))
            )

            let pendingParticipant = try await client.prepareContactParticipant(
                relay: shared.relay,
                relationshipPseudonym: localPseudonym
            )
            let participant = try await client.activateContactParticipant(pendingParticipant)
            temporaryParticipant = participant
            let started = try ContactPairingResponderFlowV2.begin(
                invitation: shared.invitation,
                participant: participant,
                at: Date()
            )
            var flow = started.flow
            try requireEmpty(await relay.send(.appendRendezvousTransportV2(
                try adapter.sealOpen(started.openRequest)
            )))
            try requireEmpty(await relay.send(.appendRendezvousTransportV2(
                try adapter.sealSessionFrame(started.acceptanceFrame, transportSequence: 2)
            )))
            pairingStatus = "Waiting for the offerer’s encrypted relationship introduction…"

            let offers = try await waitForFrames(
                relay: relay,
                adapter: adapter,
                receivingAs: .responder,
                afterSequence: 0,
                throughSequence: 1,
                deadline: shared.invitation.offer.expiresAt
            )
            let offerOuter = try frame(sequence: 1, in: offers)
            guard case .sessionFrame(let contactOffer) = try adapter.open(
                offerOuter,
                direction: .offererToResponder
            ) else {
                throw NoctweaveClientError.invalidPairingLink
            }
            let confirmation = try flow.receiveOffer(contactOffer, at: Date())
            try requireEmpty(await relay.send(.appendRendezvousTransportV2(
                try adapter.sealSessionFrame(confirmation, transportSequence: 3)
            )))
            pairingStatus = "Relationship transcript verified. Waiting for final confirmation…"

            let finals = try await waitForFrames(
                relay: relay,
                adapter: adapter,
                receivingAs: .responder,
                afterSequence: 1,
                throughSequence: 2,
                deadline: shared.invitation.offer.expiresAt
            )
            let finalOuter = try frame(sequence: 2, in: finals)
            guard case .sessionFrame(let finalConfirmation) = try adapter.open(
                finalOuter,
                direction: .offererToResponder
            ) else {
                throw NoctweaveClientError.invalidPairingLink
            }
            let relationship = try flow.receiveConfirmation(finalConfirmation, at: Date())
            let scope = await client.mintActivePersonaScopeToken()
            try await client.addRelationship(
                relationship,
                consent: .accepted,
                personaScope: scope
            )
            temporaryParticipant = nil
            await deleteTemporaryLanes(relay: relay, adapter: adapter)
            cleanup = nil
            pairingStatus = "A fresh unlinkable relationship is ready."
            try await refresh()
        } catch {
            if let cleanup {
                await deleteTemporaryLanes(relay: cleanup.0, adapter: cleanup.1)
            }
            if let temporaryParticipant, let client {
                try? await client.teardownContactParticipant(temporaryParticipant)
            }
            if error is CancellationError {
                pairingStatus = "Pairing cancelled. Start with a fresh invitation."
            } else {
                lastError = describe(error)
                pairingStatus = "Pairing stopped: \(describe(error))"
            }
        }
    }

    private func runDirectPairingStart(
        relayText: String,
        pseudonym: String,
        relayPassword: String
    ) async {
        defer {
            isPairingProcessing = false
            pairingTask = nil
        }
        do {
            guard let client else { throw NoctweaveClientError.unavailable }
            let endpoint = try RelayEndpointParser.parse(relayText)
            let accessPassword = relayAccessPassword(
                for: endpoint,
                supplied: relayPassword
            )
            let readiness = try await RelayPairingPreflight.check(
                client: RelayClient(endpoint: endpoint, authToken: accessPassword),
                requirement: .opaqueRouteOnly,
                performRuntimeProbe: false
            )
            _ = try await rememberRelay(
                readiness,
                accessPassword: accessPassword,
                client: client
            )
            let pseudonym = try validatedPseudonym(pseudonym)
            let now = Date()
            let pendingParticipant = try await client.prepareContactParticipant(
                relay: endpoint,
                relationshipPseudonym: pseudonym,
                createdAt: now
            )
            let participant = try await client.activateContactParticipant(pendingParticipant)
            directTemporaryParticipant = participant
            let offer = try await client.makeContactPairingInvitation(
                createdAt: now,
                expiresAt: now.addingTimeInterval(10 * 60)
            )
            directOffererPending = DirectPairingOffererPendingContext(
                pendingOffer: offer.pending,
                invitation: offer.invitation,
                participant: participant,
                ledger: RendezvousRedemptionLedgerV2()
            )
            directPairingPayload = try DirectPairingTransferV2
                .invitation(offer.invitation)
                .encoded()
            pairingStatus = "Show this invitation to the other device, then scan its encrypted response."
        } catch {
            await failDirectPairing(error)
        }
    }

    private func runDirectPairingStage(
        payload: String,
        relayText: String,
        pseudonym: String,
        relayPassword: String
    ) async {
        defer {
            isPairingProcessing = false
            pairingTask = nil
        }
        do {
            guard let client else { throw NoctweaveClientError.unavailable }
            let transfer = try DirectPairingTransferV2.decode(payload)
            switch transfer.stage {
            case .invitation:
                guard directOffererPending == nil,
                      directOffererFlow == nil,
                      directResponderFlow == nil,
                      directTemporaryParticipant == nil,
                      let invitation = transfer.invitation,
                      Date() < invitation.offer.expiresAt else {
                    throw NoctweaveClientError.unexpectedDirectPairingStage
                }
                let endpoint = try RelayEndpointParser.parse(relayText)
                let accessPassword = relayAccessPassword(
                    for: endpoint,
                    supplied: relayPassword
                )
                let readiness = try await RelayPairingPreflight.check(
                    client: RelayClient(endpoint: endpoint, authToken: accessPassword),
                    requirement: .opaqueRouteOnly,
                    performRuntimeProbe: false
                )
                _ = try await rememberRelay(
                    readiness,
                    accessPassword: accessPassword,
                    client: client
                )
                let pendingParticipant = try await client.prepareContactParticipant(
                    relay: endpoint,
                    relationshipPseudonym: try validatedPseudonym(pseudonym)
                )
                let participant = try await client.activateContactParticipant(
                    pendingParticipant
                )
                directTemporaryParticipant = participant
                let started = try ContactPairingResponderFlowV2.begin(
                    invitation: invitation,
                    participant: participant,
                    at: Date()
                )
                directResponderFlow = started.flow
                directPairingPayload = try DirectPairingTransferV2.response(
                    openRequest: started.openRequest,
                    acceptanceFrame: started.acceptanceFrame
                ).encoded()
                pairingStatus = "Your encrypted response is ready. Show it to the inviting device, then scan its contact offer."

            case .response:
                guard var context = directOffererPending,
                      directOffererFlow == nil,
                      directResponderFlow == nil,
                      let openRequest = transfer.openRequest,
                      let acceptanceFrame = transfer.frame,
                      Date() < context.invitation.offer.expiresAt else {
                    throw NoctweaveClientError.unexpectedDirectPairingStage
                }
                let started = try ContactPairingOffererFlowV2.begin(
                    pendingOffer: &context.pendingOffer,
                    invitation: context.invitation,
                    participant: context.participant,
                    openRequest: openRequest,
                    acceptanceFrame: acceptanceFrame,
                    ledger: &context.ledger,
                    at: Date()
                )
                directOffererPending = nil
                directOffererFlow = started.flow
                directPairingPayload = try DirectPairingTransferV2
                    .offer(started.offerFrame)
                    .encoded()
                pairingStatus = "The contact offer is ready. Show it to the other device, then scan its confirmation."

            case .offer:
                guard var flow = directResponderFlow,
                      directOffererPending == nil,
                      directOffererFlow == nil,
                      let frame = transfer.frame else {
                    throw NoctweaveClientError.unexpectedDirectPairingStage
                }
                let confirmation = try flow.receiveOffer(frame, at: Date())
                directResponderFlow = flow
                directPairingPayload = try DirectPairingTransferV2
                    .confirmation(confirmation)
                    .encoded()
                pairingStatus = "The relationship transcript is verified. Show this confirmation, then scan the final receipt."

            case .confirmation:
                guard var flow = directOffererFlow,
                      directOffererPending == nil,
                      directResponderFlow == nil,
                      let frame = transfer.frame else {
                    throw NoctweaveClientError.unexpectedDirectPairingStage
                }
                let completion = try flow.receiveConfirmation(frame, at: Date())
                let scope = await client.mintActivePersonaScopeToken()
                try await client.addRelationship(
                    completion.relationship,
                    consent: .accepted,
                    personaScope: scope
                )
                directOffererFlow = nil
                directTemporaryParticipant = nil
                directPairingPayload = try DirectPairingTransferV2
                    .finalConfirmation(completion.confirmationFrame)
                    .encoded()
                directPairingCanFinish = true
                pairingStatus = "Final receipt ready. Let the other device scan it before you finish."
                try await refresh()

            case .finalConfirmation:
                guard var flow = directResponderFlow,
                      directOffererPending == nil,
                      directOffererFlow == nil,
                      let frame = transfer.frame else {
                    throw NoctweaveClientError.unexpectedDirectPairingStage
                }
                let relationship = try flow.receiveConfirmation(frame, at: Date())
                let scope = await client.mintActivePersonaScopeToken()
                try await client.addRelationship(
                    relationship,
                    consent: .accepted,
                    personaScope: scope
                )
                directTemporaryParticipant = nil
                resetDirectPairingState()
                isPairing = false
                pairingStatus = "A fresh unlinkable relationship is ready."
                try await refresh()
            }
        } catch {
            await failDirectPairing(error)
        }
    }

    private func failDirectPairing(_ error: Error) async {
        let participant = directTemporaryParticipant
        resetDirectPairingState()
        isPairing = false
        if let participant, let client {
            try? await client.teardownContactParticipant(participant)
        }
        if error is CancellationError {
            pairingStatus = "Direct pairing cancelled. Start with a fresh exchange."
        } else {
            lastError = describe(error)
            pairingStatus = "Direct pairing stopped: \(describe(error))"
        }
    }

    private func resetDirectPairingState() {
        directOffererPending = nil
        directOffererFlow = nil
        directResponderFlow = nil
        directTemporaryParticipant = nil
        directPairingPayload = nil
        directPairingCanFinish = false
    }

    private func waitForFrames(
        relay: RelayClient,
        adapter: RendezvousRelayAdapterV2,
        receivingAs role: RendezvousRoleV2,
        afterSequence: UInt64,
        throughSequence: UInt64,
        deadline: Date
    ) async throws -> [RendezvousRelayCiphertextFrameV2] {
        while Date() < deadline {
            try Task.checkCancellation()
            let response = try await relay.send(.syncRendezvousTransportV2(
                adapter.syncRequest(receivingAs: role, afterSequence: afterSequence)
            ))
            guard response.status == .success,
                  case .rendezvousSync(let batch)? = response.successBody else {
                throw NoctweaveClientError.relayRejected(
                    response.error?.message ?? "The relay rejected the pairing sync."
                )
            }
            let frames = batch.frames.sorted { $0.sequence < $1.sequence }
            if frames.contains(where: { $0.sequence == throughSequence }) {
                return frames
            }
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        throw NoctweaveClientError.pairingExpired
    }

    private func frame(
        sequence: UInt64,
        in frames: [RendezvousRelayCiphertextFrameV2]
    ) throws -> RendezvousRelayCiphertextFrameV2 {
        guard let value = frames.first(where: { $0.sequence == sequence }) else {
            throw NoctweaveClientError.missingPairingFrame(sequence)
        }
        return value
    }

    private func requireEmpty(_ response: RelayResponse) throws {
        guard response.status == .success, case .empty? = response.successBody else {
            throw NoctweaveClientError.relayRejected(
                response.error?.message ?? "The relay rejected the pairing request."
            )
        }
    }

    private func deleteTemporaryLanes(
        relay: RelayClient,
        adapter: RendezvousRelayAdapterV2
    ) async {
        for request in adapter.deletionRequests() {
            _ = try? await relay.send(.deleteRendezvousTransportV2(request))
        }
    }

    private func validatedPseudonym(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 512 else {
            throw NoctweaveClientError.invalidPairingLink
        }
        return normalized
    }

    private func matchesStructuredPIN(
        _ pin: String,
        salt: Data,
        expected: Data
    ) -> Bool {
        AppLockPINV2.verify(pin: pin, salt: salt, encodedHash: expected)
    }

    private func verifyConfiguredPIN(_ value: String) -> Bool {
        guard let salt = appLockSettings.pinSalt,
              let hash = appLockSettings.pinHash else {
            return false
        }
        return matchesStructuredPIN(value, salt: salt, expected: hash)
    }

    private func evaluateBiometrics(reason: String) async throws {
        guard !biometricRequestInFlight else {
            throw NoctweaveClientError.biometricAuthenticationFailed
        }
        biometricRequestInFlight = true
        defer { biometricRequestInFlight = false }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw NoctweaveClientError.biometricAuthenticationUnavailable
        }
        let accepted = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )
        guard accepted else { throw NoctweaveClientError.biometricAuthenticationFailed }
    }

    private func performSettingsSave(
        success: String,
        operation: (HeadlessMessagingClient) async throws -> Void
    ) async -> Bool {
        guard !isSavingSettings else { return false }
        isSavingSettings = true
        settingsError = nil
        settingsMessage = nil
        defer { isSavingSettings = false }
        do {
            guard let client else { throw NoctweaveClientError.unavailable }
            try await operation(client)
            try await refresh()
            settingsMessage = success
            return true
        } catch {
            settingsError = describe(error)
            return false
        }
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }
}
