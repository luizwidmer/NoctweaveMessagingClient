import Combine
import CryptoKit
import Darwin
import Foundation
import PICCPCore
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if os(iOS)
import UIKit
#endif

enum StorageProtectionMode: String, CaseIterable, Identifiable {
    case keychain
    case deviceOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keychain:
            return "Keychain (Recommended)"
        case .deviceOnly:
            return "Device Only"
        }
    }

    var descriptionText: String {
        switch self {
        case .keychain:
            return "Encrypts local data and attachments with a Keychain-backed key. macOS may prompt for password access; on iOS this key is device-bound."
        case .deviceOnly:
            return "Relies on OS file protection only. This avoids Keychain prompts but reduces protection if the OS account is compromised."
        }
    }

    var usesKeychain: Bool {
        switch self {
        case .keychain:
            return true
        case .deviceOnly:
            return false
        }
    }
}

enum ProfileSyncState: Equatable {
    case idle
    case syncing
    case success(Date)
    case error(Date, String)
}

struct RelayHealthSnapshot: Equatable {
    var lastCheckedAt: Date
    var latencyMs: Int?
    var isReachable: Bool
    var failureReason: String?
}

@MainActor
final class ClientViewModel: ObservableObject {
    @Published var state: ClientState
    @Published var isReady = false
    @Published var requiresOnboarding = false
    @Published var lastError: String?
    @Published var lastInfo: String?
    @Published var isSyncing = false
    @Published var profileSyncStatus: [UUID: ProfileSyncState] = [:]
    @Published var activeContactId: UUID?
    @Published var activeGroupId: UUID?
    @Published var pendingGroupJoinRequests: [UUID: [RelayGroupJoinRequest]] = [:]
    @Published var insecureAnnouncements: [PairingAnnouncement] = []
    @Published var insecureRequests: [PairingRequest] = []
    @Published var insecureLastAnnounceAt: Date?
    @Published var insecureLastListAt: Date?
    @Published var insecureLastRequestFetchAt: Date?
    @Published var insecureLastPeerCount: Int = 0
    @Published var insecureLastRequestCount: Int = 0
    @Published var insecureLastError: String?
    @Published var insecureLastRelay: RelayEndpoint?
    @Published var insecureLastSelfTestAt: Date?
    @Published var insecureLastSelfTestResult: String?
    @Published var insecureSelfTestStep: String?
    @Published var isLocked = false
    @Published var requiresStorageChoice = false
    @Published var storageProtectionMode: StorageProtectionMode = .keychain
    @Published var storageProtectionStatus: String?
    @Published var biometricsAvailable = false
    @Published var relayHealth: [UUID: RelayHealthSnapshot] = [:]
    @Published var isBurningIdentity = false

    private var store: ClientStateStore
    private var attachmentStore: AttachmentStore
    private var threadMessageStore: ThreadMessageStore
    private let notifier = NotificationManager()
    private var autoFetchTask: Task<Void, Never>?
    private var sessionResetCooldown = SessionRecovery.Cooldown(interval: 30)
    private let resendRequestCount = 32
    private let attachmentChunkSize = 64 * 1024
    private let attachmentUploadTTLSeconds = 1800
    private let maxAttachmentBytes = 8 * 1024 * 1024
    private let maxAttachmentChunkCount = 128
    private let maxAttachmentInputDimension: CGFloat = 8192
    private let maxAttachmentInputPixels = 48_000_000
    private let attachmentOutputMaxDimension: CGFloat = 1600
    private let attachmentOutputQuality: CGFloat = 0.82
    private let attachmentQuotaWindowSeconds: TimeInterval = 3600
    private let maxAttachmentCountPerContactPerWindow = 20
    private let maxAttachmentBytesPerContactPerWindow = 24 * 1024 * 1024
    private let maxAttachmentBytesPerRelayPerWindow = 96 * 1024 * 1024
    private let prekeyMinimumCount = 4
    private let prekeyTargetCount = 8
    private let rootRatchetInterval: UInt64 = 50
    private let isUITest: Bool
    private var lastInsecureRefresh: Date?
    private let insecureRefreshInterval: TimeInterval = 20
    private var lastCoordinatorSyncAt: Date?
    private let coordinatorSyncInterval: TimeInterval = 45
    private var wakeFailureCountsByProfile: [UUID: Int] = [:]
    private let defaultActivePollSeconds = 8
    private let maxActiveWakePollSeconds = 300
    private var insecureSelfTestToken: UUID?
    private var pendingOutboundPairRequestFingerprints: Set<String> = []
    private var lastInactiveAt: Date?
    private let stateFileURL: URL
    private let attachmentDirectory: URL
    private let threadMessageDirectory: URL
    private let corruptionKillSwitchURL: URL
    private var pinFailedAttempts = 0
    private var pinLockedUntil: Date?
    private let pinHashMagic = Data("NPIN2".utf8)
    private let pinHashRounds = 120_000
    private let pinMinimumRounds = 60_000
    private let pinMaximumRounds = 300_000
    private let pinLockoutThreshold = 5
    private let pinLockoutBaseSeconds = 3
    private let pinLockoutMaxSeconds = 300
    private var outboundAttachmentQuotaByContact: [UUID: [AttachmentQuotaEvent]] = [:]
    private var inboundAttachmentQuotaByContact: [UUID: [AttachmentQuotaEvent]] = [:]
    private var outboundAttachmentQuotaByRelay: [String: [AttachmentQuotaEvent]] = [:]
    private var inboundAttachmentQuotaByRelay: [String: [AttachmentQuotaEvent]] = [:]
    private var decryptedAttachmentCache: [String: SecureRAMBuffer] = [:]
    private var decryptedAttachmentScopes: [String: AttachmentCacheScope] = [:]
    private static let storageModeKey = "lattice.storageProtection.mode.v1"
    private static let keychainAuthPreflightKey = "noctyra.keychainAuthPreflight.v1"
    private enum AttachmentCacheScope: Hashable {
        case contact(UUID)
        case group(UUID)
        case transient
    }
    private struct InsecureSelfTestFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private enum AttachmentTransferError: LocalizedError {
        case invalidDescriptor
        case missingChunk(Int)
        case invalidChunkSize
        case invalidSize
        case invalidChecksum
        case unsupportedType
        case imageProcessingFailed
        case attachmentTooLarge(maxBytes: Int)
        case quotaExceeded(String)
        case uploadFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .invalidDescriptor:
                return "Invalid attachment descriptor."
            case .missingChunk(let index):
                return "Missing attachment chunk \(index)."
            case .invalidChunkSize:
                return "Attachment chunk size mismatch."
            case .invalidSize:
                return "Attachment size mismatch."
            case .invalidChecksum:
                return "Attachment checksum mismatch."
            case .unsupportedType:
                return "Unsupported attachment type."
            case .imageProcessingFailed:
                return "Failed to process image securely."
            case .attachmentTooLarge(let maxBytes):
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                return "Attachment exceeds size limit (\(formatter.string(fromByteCount: Int64(maxBytes))))."
            case .quotaExceeded(let message):
                return message
            case .uploadFailed(let message):
                return message
            }
        }
    }

    private struct AttachmentQuotaEvent {
        let timestamp: Date
        let bytes: Int
    }
    private struct PrekeySelection {
        let reference: PrekeyReference
        let publicKey: Data
    }

    private struct OutboundSessionContext {
        let conversation: Conversation
        let kemCiphertext: Data?
        let prekey: PrekeyReference?
    }

    private struct InboundSessionContext {
        let conversation: Conversation
        let usedPrekey: Bool
        let agreementKey: AgreementKeyPair?
    }

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PICCPClient", isDirectory: true)
        let fileURL = directory.appendingPathComponent("state.json")
        let attachmentDirectory = directory.appendingPathComponent("attachments", isDirectory: true)
        let threadMessageDirectory = directory.appendingPathComponent("threads", isDirectory: true)
        let corruptionKillSwitchURL = directory.appendingPathComponent(".corruption-kill-switch")
        let isUITest = ProcessInfo.processInfo.arguments.contains("UI_TESTING")
        let resolvedMode = ClientViewModel.loadStorageProtectionMode()
        let useEncryption = resolvedMode?.usesKeychain ?? false

        self.stateFileURL = fileURL
        self.attachmentDirectory = attachmentDirectory
        self.threadMessageDirectory = threadMessageDirectory
        self.corruptionKillSwitchURL = corruptionKillSwitchURL
        self.isUITest = isUITest
        if !isUITest {
            ClientViewModel.enforceCorruptionKillSwitchIfNeeded(at: corruptionKillSwitchURL)
        }
        self.store = ClientStateStore(fileURL: fileURL, useEncryption: useEncryption)
        self.attachmentStore = AttachmentStore(directory: attachmentDirectory, useEncryption: useEncryption)
        self.threadMessageStore = ThreadMessageStore(directory: threadMessageDirectory, useEncryption: useEncryption)
        self.storageProtectionMode = resolvedMode ?? .keychain
        self.requiresStorageChoice = !isUITest && resolvedMode == nil
        self.biometricsAvailable = ClientViewModel.detectBiometricAvailability()
        if isUITest {
            self.state = ClientViewModel.makeUITestState()
            self.isReady = true
            self.requiresStorageChoice = false
            self.requiresOnboarding = false
        } else {
            // Placeholder identity: first-run setup will replace this before any relay publish happens.
            let defaultIdentity = Identity(displayName: "Setup Required")
            let defaultRelay = RelayEndpoint(host: "127.0.0.1", port: 9339)
            let defaultServer = RelayServerRecord(name: "Local Relay", endpoint: defaultRelay)
            let defaultInbox = InboxAddress.generate()
            self.state = ClientState(
                identity: defaultIdentity,
                relay: defaultRelay,
                inboxId: defaultInbox,
                relayServers: [defaultServer],
                selectedRelayId: defaultServer.id,
                hasCompletedOnboarding: false,
                hasAcceptedPrivacyPolicy: false,
                hasAcceptedTermsOfUse: false
            )
            self.requiresOnboarding = false

            if requiresStorageChoice {
                isReady = false
            } else {
                Task {
                    await load()
                }
            }
        }
    }

    func load() async {
        if isUITest {
            return
        }
        enforceCorruptionKillSwitchIfNeeded()
        do {
            if let stored = try await store.load() {
                state = stored
                if shouldForceOnboarding(for: state) {
                    state.hasCompletedOnboarding = false
                    state.hasAcceptedPrivacyPolicy = false
                    state.hasAcceptedTermsOfUse = false
                    try await persistState()
                }
            } else {
                // First boot: don't persist an identity until the user finishes onboarding.
                state.hasCompletedOnboarding = false
                state.hasAcceptedPrivacyPolicy = false
                state.hasAcceptedTermsOfUse = false
                requiresOnboarding = true
                isReady = true
                return
            }
            refreshBiometricAvailability()
            let didSanitizeActionPlans = sanitizeActionPlans()
            let didSanitizeAppLock = sanitizeAppLockForBiometricAvailability()
            if state.insecurePairing.isEnabled {
                state.insecurePairing.isEnabled = false
                try await persistState()
            } else if didSanitizeActionPlans || didSanitizeAppLock {
                try await persistState()
            }
            requiresOnboarding = !state.hasCompletedOnboarding
                || !state.hasAcceptedPrivacyPolicy
                || !state.hasAcceptedTermsOfUse
            if requiresOnboarding {
                // Defer relay publish/autofetch until first-run setup completes.
                isReady = true
                return
            }
            await ensureRelaySelection()
            await ensurePrekeysForActiveProfiles()
            await syncRelayGroupsForActiveProfiles()
            isLocked = shouldLockImmediately()
            isReady = true
            if !isLocked {
                await notifier.requestAuthorization()
                startAutoFetch()
            }
        } catch {
            lastError = "Failed to load state: \(error.localizedDescription)"
        }
    }

    func completeOnboarding(
        displayName: String,
        relayId: UUID?,
        privacy: PrivacySettings,
        appLock: AppLockSettings,
        acceptedPrivacyPolicy: Bool,
        acceptedTermsOfUse: Bool
    ) async {
        guard acceptedPrivacyPolicy && acceptedTermsOfUse else {
            lastError = "Accept the Privacy Policy and Terms of Use to continue."
            return
        }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Choose a display name."
            return
        }
        let relaySelection = relayId.flatMap { id in
            state.relayServers.first(where: { $0.id == id })
        } ?? state.relayServers.first
        guard let relaySelection else {
            lastError = "Add a relay server first."
            return
        }
        if requiresPin(mode: appLock.mode) && !appLock.isPinConfigured {
            lastError = "Set a 6-digit PIN for the selected app lock mode."
            return
        }

        let identity = Identity(displayName: trimmed)
        let inboxAccessKey = SigningKeyPair()
        let inboxId = InboxAddress.derived(from: inboxAccessKey.publicKeyData)
        let prekeys = (try? PrekeyState.generate(identity: identity, oneTimeCount: prekeyTargetCount)) ?? PrekeyState(
            signedPrekeyId: UUID(),
            signedPrekeyPublicKey: Data(),
            signedPrekeyPrivateKey: Data(),
            signedPrekeySignature: Data(),
            signedPrekeyIssuedAt: Date(),
            oneTimePrekeys: []
        )
        let profile = IdentityProfile(
            identity: identity,
            inboxId: inboxId,
            inboxAccessKey: inboxAccessKey,
            relay: relaySelection.endpoint,
            selectedRelayId: relaySelection.id,
            prekeys: prekeys
        )
        state.identityProfiles = [profile]
        state.activeIdentityId = profile.id
        state.selectedRelayId = relaySelection.id
        state.relay = relaySelection.endpoint
        state.privacy = privacy
        var finalAppLock = sanitizeAppLock(appLock)
        if finalAppLock.mode == .off {
            finalAppLock.pinHash = nil
            finalAppLock.pinSalt = nil
        }
        state.appLock = finalAppLock
        state.hasCompletedOnboarding = true
        state.hasAcceptedPrivacyPolicy = acceptedPrivacyPolicy
        state.hasAcceptedTermsOfUse = acceptedTermsOfUse
        requiresOnboarding = false
        await save()

        await ensureRelaySelection()
        await ensurePrekeysForActiveProfiles()
        await syncRelayGroupsForActiveProfiles()
        await notifier.requestAuthorization()
        startAutoFetch()
        lastInfo = "Setup complete."
    }

    private func ensurePrekeys() async {
        await ensurePrekeys(for: state.activeIdentityId)
    }

    private func ensurePrekeysForActiveProfiles() async {
        let profiles = state.identityProfiles.filter { !$0.isArchived }
        for profile in profiles {
            await ensurePrekeys(for: profile.id)
        }
    }

    private func ensurePrekeys(for profileId: UUID) async {
        guard var profile = state.identityProfile(id: profileId) else {
            return
        }
        var didUpdate = false
        if !isSignedPrekeyValid(prekeys: profile.prekeys, identity: profile.identity) {
            if let regenerated = try? PrekeyState.generate(identity: profile.identity, oneTimeCount: prekeyTargetCount) {
                profile.prekeys = regenerated
                didUpdate = true
            }
        } else if profile.prekeys.oneTimePrekeys.count < prekeyMinimumCount {
            let needed = max(0, prekeyTargetCount - profile.prekeys.oneTimePrekeys.count)
            if needed > 0 {
                for _ in 0..<needed {
                    let keyPair = AgreementKeyPair()
                    profile.prekeys.oneTimePrekeys.append(
                        PrekeyPrivateRecord(
                            id: UUID(),
                            publicKey: keyPair.publicKeyData,
                            privateKey: keyPair.privateKeyData
                        )
                    )
                }
                didUpdate = true
            }
        }

        if didUpdate {
            state.updateIdentityProfile(profile)
            await save()
        }

        await publishPrekeys(profile.prekeys, identity: profile.identity, relay: profile.relay)
    }

    private func isSignedPrekeyValid(prekeys: PrekeyState, identity: Identity) -> Bool {
        guard !prekeys.signedPrekeyPublicKey.isEmpty, !prekeys.signedPrekeySignature.isEmpty else {
            return false
        }
        let signed = SignedPrekey(
            id: prekeys.signedPrekeyId,
            publicKey: prekeys.signedPrekeyPublicKey,
            issuedAt: prekeys.signedPrekeyIssuedAt,
            signature: prekeys.signedPrekeySignature
        )
        return signed.verify(using: identity.signingKey.publicKeyData)
    }

    private func publishPrekeys(_ prekeys: PrekeyState, identity: Identity, relay: RelayEndpoint) async {
        do {
            let bundle = try prekeys.bundle(identity: identity)
            let unsignedRequest = UploadPrekeyBundleRequest(
                fingerprint: identity.fingerprint,
                bundle: bundle
            )
            let proof = try makeActorProof(
                fingerprint: identity.fingerprint,
                signingKey: identity.signingKey,
                publicSigningKey: identity.signingKey.publicKeyData,
                signableDataBuilder: { proof in
                    try unsignedRequest.signableData(for: proof)
                }
            )
            let request = UploadPrekeyBundleRequest(
                fingerprint: identity.fingerprint,
                bundle: bundle,
                actorProof: proof
            )
            let client = relayClient(for: relay)
            let response = try await client.send(.uploadPrekeys(request))
            if response.type != .ok {
                lastError = "Failed to publish prekeys: \(response.error ?? "Relay error")"
            }
        } catch {
            lastError = "Failed to publish prekeys: \(error.localizedDescription)"
        }
    }

    func selectStorageProtection(_ mode: StorageProtectionMode) {
        Task { @MainActor in
            do {
                if mode.usesKeychain {
                    storageProtectionStatus = "Verifying Keychain access..."
                    try await warmUpKeychainAccess()
                }
                storageProtectionMode = mode
                requiresStorageChoice = false
                persistStorageProtectionMode(mode)
                configureStores(for: mode)
                storageProtectionStatus = "Storage protection set to \(mode.displayName)."
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if storageProtectionStatus == "Storage protection set to \(mode.displayName)." {
                        storageProtectionStatus = nil
                    }
                }
                await load()
            } catch {
                // Keep chooser visible so user can pick device-only mode if keychain access fails.
                requiresStorageChoice = true
                storageProtectionStatus = nil
                lastError = "Unable to access Keychain: \(error.localizedDescription)"
            }
        }
    }

    func updateStorageProtectionMode(_ mode: StorageProtectionMode) async {
        guard storageProtectionMode != mode else { return }
        let previousStore = store
        let previousAttachmentStore = attachmentStore
        let previousThreadMessageStore = threadMessageStore
        let previousMode = storageProtectionMode

        storageProtectionMode = mode
        persistStorageProtectionMode(mode)
        configureStores(for: mode)
        storageProtectionStatus = "Updating storage protection..."

        do {
            if mode.usesKeychain {
                try await warmUpKeychainAccess()
            }
            try migrateThreadMessages(from: previousThreadMessageStore, to: threadMessageStore)
            try migrateAttachments(from: previousAttachmentStore, to: attachmentStore)
            try await store.save(strippedStateForPersistence(state))
            evictInactiveThreadMessagesFromRAM()
            storageProtectionStatus = "Storage protection updated."
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if storageProtectionStatus == "Storage protection updated." {
                    storageProtectionStatus = nil
                }
            }
        } catch {
            store = previousStore
            attachmentStore = previousAttachmentStore
            threadMessageStore = previousThreadMessageStore
            storageProtectionMode = previousMode
            persistStorageProtectionMode(previousMode)
            lastError = "Failed to update storage protection: \(error.localizedDescription)"
            storageProtectionStatus = "Storage protection update failed."
        }
    }

    private func warmUpKeychainAccess() async throws {
        await preauthorizeKeychainIfPossible()
        try await store.warmUpKeychain()
    }

    private func preauthorizeKeychainIfPossible() async {
        #if os(macOS)
        guard !isUITest else { return }
        if UserDefaults.standard.bool(forKey: ClientViewModel.keychainAuthPreflightKey) {
            return
        }
        let context = LAContext()
        var canEvaluateError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &canEvaluateError) else {
            // Some Macs don't support LocalAuthentication password prompts in this flow.
            // Keychain warmup below remains the source of truth.
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authorize secure Keychain storage for Noctyra."
            ) { success, error in
                DispatchQueue.main.async {
                    if success {
                        UserDefaults.standard.set(true, forKey: ClientViewModel.keychainAuthPreflightKey)
                    }
                    _ = error
                    continuation.resume()
                }
            }
        }
        #endif
    }

    private func shouldForceOnboarding(for loadedState: ClientState) -> Bool {
        let displayName = loadedState.identity.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.caseInsensitiveCompare("Setup Required") == .orderedSame
    }

    func save() async {
        if isUITest {
            return
        }
        do {
            try await persistState()
        } catch {
            lastError = "Failed to save state: \(error.localizedDescription)"
        }
    }

    private func persistState() async throws {
        try persistAllThreadMessagesFromState(state)
        let sanitized = strippedStateForPersistence(state)
        try await store.save(sanitized)
        evictInactiveThreadMessagesFromRAM()
    }

    private func recordContinuityEvent(
        kind: ContinuityEventKind,
        contact: Contact? = nil,
        note: String? = nil,
        oldFingerprint: String? = nil,
        newFingerprint: String? = nil,
        profileId: UUID? = nil
    ) {
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = ContinuityEvent(
            kind: kind,
            contactId: contact?.id,
            contactDisplayName: contact?.displayName,
            note: trimmedNote?.isEmpty == true ? nil : trimmedNote,
            oldFingerprint: oldFingerprint,
            newFingerprint: newFingerprint
        )
        state.appendContinuityEvent(event, profileId: profileId)
    }

    private static func makeUITestState() -> ClientState {
        let identity = Identity(displayName: "UITest User")
        let relay = RelayEndpoint(host: "127.0.0.1", port: 9339)
        let server = RelayServerRecord(name: "Local Relay", endpoint: relay)
        let contactIdentity = Identity(displayName: "UITest Contact")
        let contactId = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
        let contact = Contact(
            id: contactId,
            displayName: contactIdentity.displayName,
            inboxId: "ui-contact-inbox",
            relay: relay,
            signingPublicKey: contactIdentity.signingKey.publicKeyData,
            agreementPublicKey: contactIdentity.agreementKey.publicKeyData
        )
        var conversation: Conversation
        if let session = try? MessageEngine.createOutboundSession(identity: identity, contact: contact) {
            conversation = session.conversation
        } else {
            conversation = Conversation(
                id: "ui-conversation",
                contactId: contactId,
                sessionId: "ui-session",
                sendChain: ChainKeyState(keyData: Data(repeating: 0, count: 32)),
                receiveChain: ChainKeyState(keyData: Data(repeating: 1, count: 32))
            )
        }
        conversation.messages = [
            Message(direction: .received, body: "Secret message", timestamp: Date(), counter: 0)
        ]

        return ClientState(
            identity: identity,
            relay: relay,
            inboxId: "ui-inbox",
            contacts: [contact],
            conversations: [conversation],
            relayServers: [server],
            selectedRelayId: server.id
        )
    }

    func contactOfferCode() async -> String {
        let identity = state.identity
        let inboxId = state.inboxId
        let relay = state.relay
        let inboxAccessPublicKey = state.inboxAccessKey?.publicKeyData
        do {
            return try await Task.detached(priority: .userInitiated) {
                let offer = try MessageEngine.makeContactOffer(
                    identity: identity,
                    inboxId: inboxId,
                    relay: relay,
                    inboxAccessPublicKey: inboxAccessPublicKey
                )
                return try ContactOfferCode.encode(offer)
            }.value
        } catch {
            lastError = "Failed to encode contact offer: \(error.localizedDescription)"
            return ""
        }
    }

    func contactShareData(password: String) async -> Data? {
        do {
            let offer = try MessageEngine.makeContactOffer(
                identity: state.identity,
                inboxId: state.inboxId,
                relay: state.relay,
                inboxAccessPublicKey: state.inboxAccessKey?.publicKeyData
            )
            return try await Task.detached {
                try ContactShare.encode(offer, password: password)
            }.value
        } catch {
            lastError = "Failed to create contact share file: \(error.localizedDescription)"
            return nil
        }
    }

    func addContact(code: String) async {
        do {
            let offer = try ContactOfferCode.decode(code)
            let contact = try validatedContact(from: offer)
            let wasKnown = state.contacts.contains { existing in
                existing.fingerprint == contact.fingerprint || contactAddressKey(for: existing) == contactAddressKey(for: contact)
            }
            state.upsert(contact: contact)
            if !wasKnown {
                recordContinuityEvent(
                    kind: .contactAdded,
                    contact: contact,
                    newFingerprint: contact.fingerprint
                )
            }
            try await persistState()
            lastInfo = wasKnown ? "Updated \(contact.displayName)." : "Added \(contact.displayName)."
        } catch {
            lastError = "Failed to add contact: \(error.localizedDescription)"
        }
    }

    func addContact(shareData: Data, password: String) async {
        do {
            let offer = try await Task.detached {
                try ContactShare.decode(shareData, password: password)
            }.value
            let contact = try validatedContact(from: offer)
            let wasKnown = state.contacts.contains { existing in
                existing.fingerprint == contact.fingerprint || contactAddressKey(for: existing) == contactAddressKey(for: contact)
            }
            state.upsert(contact: contact)
            if !wasKnown {
                recordContinuityEvent(
                    kind: .contactAdded,
                    contact: contact,
                    newFingerprint: contact.fingerprint
                )
            }
            try await persistState()
            lastInfo = wasKnown ? "Updated \(contact.displayName)." : "Added \(contact.displayName)."
        } catch {
            lastError = "Failed to import contact: \(error.localizedDescription)"
        }
    }

    private func validatedContact(from offer: ContactOffer) throws -> Contact {
        let verifiedOffer = try offer.verified()
        let contact = try MessageEngine.contact(from: verifiedOffer)
        return normalizedContact(contact, preferredRelay: state.relay)
    }

    private func fetchPrekeyBundle(for contact: Contact) async -> PrekeyBundle? {
        let endpoint = reachableRelayEndpoint(contact.relay, preferredRelay: state.relay)
        let client = relayClient(for: endpoint)
        do {
            let response = try await client.send(
                .fetchPrekeyBundle(FetchPrekeyBundleRequest(fingerprint: contact.fingerprint))
            )
            guard response.type == .prekeyBundle else {
                return nil
            }
            return response.prekeyBundle
        } catch {
            return nil
        }
    }

    private func selectPrekey(for contact: Contact) async -> PrekeySelection? {
        guard let bundle = await fetchPrekeyBundle(for: contact) else {
            return nil
        }
        guard bundle.identityFingerprint == contact.fingerprint else {
            return nil
        }
        guard bundle.signedPrekey.verify(using: contact.signingPublicKey) else {
            return nil
        }
        if let oneTime = bundle.oneTimePrekeys.first {
            guard oneTime.verify(using: contact.signingPublicKey) else {
                return nil
            }
            return PrekeySelection(
                reference: PrekeyReference(kind: .oneTime, id: oneTime.id),
                publicKey: oneTime.publicKey
            )
        }
        return PrekeySelection(
            reference: PrekeyReference(kind: .signed, id: bundle.signedPrekey.id),
            publicKey: bundle.signedPrekey.publicKey
        )
    }

    private func prepareOutboundSession(for contact: Contact, forceNew: Bool = false) async throws -> OutboundSessionContext {
        let contact = normalizedContact(contact, preferredRelay: state.relay)
        if !forceNew, let existing = state.conversation(for: contact.id) {
            loadConversationMessagesIntoRAM(contactId: contact.id)
            let hydrated = state.conversation(for: contact.id) ?? existing
            return OutboundSessionContext(conversation: hydrated, kemCiphertext: nil, prekey: nil)
        }
        if let selection = await selectPrekey(for: contact) {
            let session = try MessageEngine.createOutboundSession(
                identity: state.identity,
                contact: contact,
                recipientAgreementPublicKey: selection.publicKey
            )
            return OutboundSessionContext(
                conversation: session.conversation,
                kemCiphertext: session.kemCiphertext,
                prekey: selection.reference
            )
        }
        let session = try MessageEngine.createOutboundSession(identity: state.identity, contact: contact)
        return OutboundSessionContext(
            conversation: session.conversation,
            kemCiphertext: session.kemCiphertext,
            prekey: nil
        )
    }

    private func prepareRootRatchetIfNeeded(
        conversation: Conversation,
        contact: Contact
    ) -> RootRatchetContext? {
        let counter = conversation.sendChain.counter
        guard counter > 0, counter % rootRatchetInterval == 0 else {
            return nil
        }
        do {
            return try MessageEngine.createRootRatchet(contact: contact, conversation: conversation)
        } catch {
            lastError = "Failed to start root ratchet: \(error.localizedDescription)"
            return nil
        }
    }

    private func applyRootRatchetIfNeeded(
        _ context: RootRatchetContext?,
        contact: Contact,
        conversation: inout Conversation
    ) {
        guard let context else { return }
        MessageEngine.applyRootRatchet(
            sharedSecret: context.sharedSecret,
            counter: context.ratchet.counter,
            identity: state.identity,
            contact: contact,
            conversation: &conversation
        )
    }

    func sendMessage(text: String, to contactId: UUID) async {
        guard let contactIndex = state.contacts.firstIndex(where: { $0.id == contactId }) else {
            lastError = "Contact not found."
            return
        }
        loadConversationMessagesIntoRAM(contactId: contactId)
        do {
            let contact = normalizedContact(state.contacts[contactIndex], preferredRelay: state.relay)
            let session = try await prepareOutboundSession(for: contact)
            var conversation = session.conversation
            let rootRatchet = prepareRootRatchetIfNeeded(conversation: conversation, contact: contact)
            let envelope = try MessageEngine.encrypt(
                body: .text(text),
                senderSigningKey: state.identity.signingKey,
                senderFingerprint: state.identity.fingerprint,
                conversation: &conversation,
                kemCiphertext: session.kemCiphertext,
                prekey: session.prekey,
                rootRatchet: rootRatchet?.ratchet
            )
            _ = MessageEngine.appendMessage(
                body: .text(text),
                direction: .sent,
                counter: envelope.messageCounter,
                timestamp: envelope.sentAt,
                conversation: &conversation
            )
            conversation.markMessageProcessed()
            applyRootRatchetIfNeeded(rootRatchet, contact: contact, conversation: &conversation)
            state.upsert(conversation: conversation)
            try await persistState()
            try await deliverEnvelope(envelope, to: contact, preferredRelay: state.relay)
            lastInfo = "Sent message to \(contact.displayName)."
        } catch {
            lastError = "Failed to send message: \(error.localizedDescription)"
        }
    }

    func sendAttachment(data: Data, fileName: String?, mimeType: String, to contactId: UUID) async {
        guard let contactIndex = state.contacts.firstIndex(where: { $0.id == contactId }) else {
            lastError = "Contact not found."
            return
        }
        loadConversationMessagesIntoRAM(contactId: contactId)
        guard !data.isEmpty else {
            lastError = "Attachment is empty."
            return
        }
        do {
            let preparedPayload = try prepareAttachmentPayload(data: data, fileName: fileName, mimeType: mimeType)
            guard preparedPayload.data.count <= maxAttachmentBytes else {
                throw AttachmentTransferError.attachmentTooLarge(maxBytes: maxAttachmentBytes)
            }
            let contact = normalizedContact(state.contacts[contactIndex], preferredRelay: state.relay)
            try validateAttachmentQuota(
                bytes: preparedPayload.data.count,
                contactId: contact.id,
                relay: contact.relay,
                direction: .outbound
            )
            let session = try await prepareOutboundSession(for: contact)
            var conversation = session.conversation
            let rootRatchet = prepareRootRatchetIfNeeded(conversation: conversation, contact: contact)
            let prepared = try MessageEngine.prepareMessageKey(conversation: &conversation)
            let attachmentId = UUID()
            let chunkSize = attachmentChunkSize
            let chunkCount = Int(ceil(Double(preparedPayload.data.count) / Double(chunkSize)))
            guard chunkCount > 0, chunkCount <= maxAttachmentChunkCount else {
                throw AttachmentTransferError.invalidDescriptor
            }
            let descriptor = AttachmentDescriptor(
                id: attachmentId,
                fileName: preparedPayload.fileName,
                mimeType: preparedPayload.mimeType,
                byteCount: preparedPayload.data.count,
                sha256: AttachmentCrypto.sha256(preparedPayload.data),
                chunkCount: chunkCount,
                chunkSize: chunkSize
            )
            let sessionId = conversation.sessionId
            let relayClient = relayClient(for: reachableRelayEndpoint(contact.relay, preferredRelay: state.relay))
            for chunkIndex in 0..<chunkCount {
                let start = chunkIndex * chunkSize
                let end = min(start + chunkSize, preparedPayload.data.count)
                let chunk = preparedPayload.data.subdata(in: start..<end)
                let authenticatedData = AttachmentCrypto.authenticatedData(
                    conversationId: conversation.id,
                    sessionId: sessionId,
                    messageCounter: prepared.counter,
                    attachmentId: attachmentId,
                    chunkIndex: chunkIndex,
                    byteCount: chunk.count
                )
                let payload = try AttachmentCrypto.encryptChunk(
                    plaintext: chunk,
                    messageKey: prepared.key,
                    attachmentId: attachmentId,
                    chunkIndex: chunkIndex,
                    authenticatedData: authenticatedData
                )
                let request = UploadAttachmentRequest(
                    attachmentId: attachmentId,
                    chunkIndex: chunkIndex,
                    payload: payload,
                    ttlSeconds: attachmentUploadTTLSeconds
                )
                let response = try await relayClient.send(.uploadAttachment(request))
                guard response.type == .attachment else {
                    throw AttachmentTransferError.uploadFailed(message: response.error ?? "Upload failed")
                }
            }
            let body = MessageBody.attachment(descriptor)
            let envelope = try MessageEngine.encrypt(
                body: body,
                senderSigningKey: state.identity.signingKey,
                senderFingerprint: state.identity.fingerprint,
                conversation: conversation,
                messageCounter: prepared.counter,
                messageKey: prepared.key,
                kemCiphertext: session.kemCiphertext,
                prekey: session.prekey,
                rootRatchet: rootRatchet?.ratchet
            )
            let localFileName = try attachmentStore.saveAttachment(preparedPayload.data, descriptor: descriptor)
            let title = attachmentDisplayTitle(descriptor, fallback: "Attachment")
            let message = Message(
                direction: .sent,
                body: title,
                timestamp: envelope.sentAt,
                counter: envelope.messageCounter,
                attachment: AttachmentInfo(descriptor: descriptor, localFileName: localFileName)
            )
            conversation.messages.append(message)
            conversation.markMessageProcessed()
            applyRootRatchetIfNeeded(rootRatchet, contact: contact, conversation: &conversation)
            state.upsert(conversation: conversation)
            try await persistState()
            try await deliverEnvelope(envelope, to: contact, preferredRelay: state.relay)
            recordAttachmentQuotaUsage(
                bytes: preparedPayload.data.count,
                contactId: contact.id,
                relay: contact.relay,
                direction: .outbound
            )
            lastInfo = "Sent attachment to \(contact.displayName)."
        } catch {
            lastError = "Failed to send attachment: \(error.localizedDescription)"
        }
    }

    func sendGroupAttachment(data: Data, fileName: String?, mimeType: String, to groupId: UUID) async {
        guard var group = state.group(for: groupId) else {
            lastError = "Group not found."
            return
        }
        guard !data.isEmpty else {
            lastError = "Attachment is empty."
            return
        }
        do {
            let preparedPayload = try prepareAttachmentPayload(data: data, fileName: fileName, mimeType: mimeType)
            guard preparedPayload.data.count <= maxAttachmentBytes else {
                throw AttachmentTransferError.attachmentTooLarge(maxBytes: maxAttachmentBytes)
            }
            try validateAttachmentQuota(
                bytes: preparedPayload.data.count,
                contactId: group.id,
                relay: state.relay,
                direction: .outbound
            )
            group.messages = group.messages.isEmpty
                ? storedGroupMessages(profileId: state.activeIdentityId, groupId: group.id)
                : group.messages
            _ = try await makeGroupAuthenticatedContext(forSending: &group)
            guard let groupInboxId = group.relayInboxId,
                  var ratchetState = group.groupRatchetState else {
                throw RelayGroupRegistryError.invalidResponse
            }
            let prepared = try GroupRatchet.prepareMessageKey(
                senderFingerprint: state.identity.fingerprint,
                state: &ratchetState
            )
            let attachmentId = UUID()
            let chunkSize = attachmentChunkSize
            let chunkCount = Int(ceil(Double(preparedPayload.data.count) / Double(chunkSize)))
            guard chunkCount > 0, chunkCount <= maxAttachmentChunkCount else {
                throw AttachmentTransferError.invalidDescriptor
            }
            let descriptor = AttachmentDescriptor(
                id: attachmentId,
                fileName: preparedPayload.fileName,
                mimeType: preparedPayload.mimeType,
                byteCount: preparedPayload.data.count,
                sha256: AttachmentCrypto.sha256(preparedPayload.data),
                chunkCount: chunkCount,
                chunkSize: chunkSize
            )
            let client = relayClient(for: state.relay)
            for chunkIndex in 0..<chunkCount {
                let start = chunkIndex * chunkSize
                let end = min(start + chunkSize, preparedPayload.data.count)
                let chunk = preparedPayload.data.subdata(in: start..<end)
                let authenticatedData = groupAttachmentAuthenticatedData(
                    groupId: group.id,
                    epoch: ratchetState.epoch,
                    transcriptHash: ratchetState.transcriptHash,
                    messageCounter: prepared.counter,
                    attachmentId: attachmentId,
                    chunkIndex: chunkIndex,
                    byteCount: chunk.count
                )
                let payload = try AttachmentCrypto.encryptChunk(
                    plaintext: chunk,
                    messageKey: prepared.key,
                    attachmentId: attachmentId,
                    chunkIndex: chunkIndex,
                    authenticatedData: authenticatedData
                )
                let response = try await client.send(.uploadAttachment(UploadAttachmentRequest(
                    attachmentId: attachmentId,
                    chunkIndex: chunkIndex,
                    payload: payload,
                    ttlSeconds: attachmentUploadTTLSeconds
                )))
                guard response.type == .attachment else {
                    throw AttachmentTransferError.uploadFailed(message: response.error ?? "Upload failed")
                }
            }
            let envelope = try GroupRatchet.encrypt(
                body: .attachment(descriptor),
                senderSigningKey: state.identity.signingKey,
                senderFingerprint: state.identity.fingerprint,
                messageCounter: prepared.counter,
                messageKey: prepared.key,
                state: ratchetState
            )
            let response = try await client.send(.deliverGroupMessage(DeliverGroupMessageRequest(
                groupId: group.id,
                groupInboxId: groupInboxId,
                envelope: envelope
            )))
            guard response.type == .delivered else {
                throw RelayGroupRegistryError.rejected(response.error ?? "Relay rejected group attachment.")
            }
            let localFileName = try attachmentStore.saveAttachment(preparedPayload.data, descriptor: descriptor)
            let title = attachmentDisplayTitle(descriptor, fallback: "Attachment")
            group.groupRatchetState = ratchetState
            group.messages.append(
                Message(
                    id: envelope.id,
                    direction: .sent,
                    senderDisplayName: state.identity.displayName,
                    body: title,
                    timestamp: envelope.sentAt,
                    counter: envelope.messageCounter,
                    attachment: AttachmentInfo(descriptor: descriptor, localFileName: localFileName)
                )
            )
            state.upsert(group: group)
            recordAttachmentQuotaUsage(
                bytes: preparedPayload.data.count,
                contactId: group.id,
                relay: state.relay,
                direction: .outbound
            )
            try await persistState()
            lastInfo = "Sent group attachment."
        } catch {
            lastError = "Failed to send group attachment: \(error.localizedDescription)"
        }
    }

    func fetchMessages() async {
        if isSyncing {
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        let profiles = state.identityProfiles.filter { !$0.isArchived }
        for profile in profiles {
            await syncRelayGroups(for: profile.id)
            await fetchMessages(for: profile.id)
        }
    }

    private func fetchMessages(for profileId: UUID) async {
        guard var profile = state.identityProfile(id: profileId) else {
            return
        }
        profileSyncStatus[profileId] = .syncing
        do {
            var didUpdateMailbox = false
            if profile.inboxAccessKey == nil {
                profile.inboxAccessKey = SigningKeyPair()
                didUpdateMailbox = true
            }
            if let accessKey = profile.inboxAccessKey,
               !InboxAddress.isBound(profile.inboxId, to: accessKey.publicKeyData) {
                profile.inboxId = InboxAddress.derived(from: accessKey.publicKeyData)
                didUpdateMailbox = true
            }
            if didUpdateMailbox {
                state.updateIdentityProfile(profile)
                try await persistState()
            }
            guard let inboxAccessKey = profile.inboxAccessKey,
                  !inboxAccessKey.publicKeyData.isEmpty,
                  !inboxAccessKey.privateKeyData.isEmpty else {
                throw CryptoError.operationFailed
            }
            let client = relayClient(for: profile.relay)
            let contactOffer = try MessageEngine.makeContactOffer(
                identity: profile.identity,
                inboxId: profile.inboxId,
                relay: profile.relay,
                inboxAccessPublicKey: inboxAccessKey.publicKeyData
            )
            var registration = RegisterInboxRequest(
                inboxId: profile.inboxId,
                accessPublicKey: inboxAccessKey.publicKeyData,
                contactOffer: contactOffer
            )
            let registrationProof = try makeActorProof(
                fingerprint: CryptoBox.fingerprint(for: inboxAccessKey.publicKeyData),
                signingKey: inboxAccessKey,
                publicSigningKey: inboxAccessKey.publicKeyData,
                signableDataBuilder: { proof in
                    try registration.signableData(for: proof)
                }
            )
            registration = RegisterInboxRequest(
                inboxId: profile.inboxId,
                accessPublicKey: inboxAccessKey.publicKeyData,
                contactOffer: contactOffer,
                accessProof: registrationProof
            )
            let registrationResponse = try await client.send(.registerInbox(registration))
            guard registrationResponse.type == .ok else {
                throw RelayMailboxError.rejected(
                    registrationResponse.error ?? "Inbox registration failed."
                )
            }
            let wakePolicy = wakeSupport(for: profile.relay)
            let longPollTimeoutSeconds = wakePolicy?.mode == .longPoll
                ? wakePolicy?.longPollTimeoutSeconds
                : nil
            var fetchRequest = FetchRequest(
                inboxId: profile.inboxId,
                routingToken: profile.inboxId,
                longPollTimeoutSeconds: longPollTimeoutSeconds
            )
            let fetchProof = try makeActorProof(
                fingerprint: CryptoBox.fingerprint(for: inboxAccessKey.publicKeyData),
                signingKey: inboxAccessKey,
                publicSigningKey: inboxAccessKey.publicKeyData,
                signableDataBuilder: { proof in
                    try fetchRequest.signableData(for: proof)
                }
            )
            fetchRequest = FetchRequest(
                inboxId: profile.inboxId,
                routingToken: profile.inboxId,
                longPollTimeoutSeconds: longPollTimeoutSeconds,
                accessProof: fetchProof
            )
            let response = try await client.send(
                .fetch(fetchRequest),
                timeout: relayFetchTimeoutSeconds(longPollTimeoutSeconds: longPollTimeoutSeconds)
            )
            guard response.type == .messages else {
                if let error = response.error {
                    lastError = "Relay error: \(error)"
                    profileSyncStatus[profileId] = .error(Date(), error)
                    recordWakeSyncFailure(for: profileId)
                } else {
                    profileSyncStatus[profileId] = .error(Date(), "Relay returned an unexpected response.")
                    recordWakeSyncFailure(for: profileId)
                }
                return
            }
            let envelopes = response.messages ?? []
            var pendingResends: [UUID: Int] = [:]
            var acknowledgedEnvelopeIds = Set<UUID>()
            for envelope in envelopes {
                guard let contactIndex = profile.contacts.firstIndex(where: { $0.fingerprint == envelope.senderFingerprint }) else {
                    acknowledgedEnvelopeIds.insert(envelope.id)
                    continue
                }
                var signatureValid = false
                var recoveryConversation: Conversation?
                do {
                    var contact = profile.contacts[contactIndex]
                    contact = normalizedContact(contact, preferredRelay: profile.relay)
                    var baseConversation: Conversation
                    var existingConversation: Conversation?
                    var usedPrekeyForSession = false
                    var inboundContext: InboundSessionContext?
                    signatureValid = envelope.verifySignature(publicSigningKey: contact.signingPublicKey)
                    if !signatureValid {
                        acknowledgedEnvelopeIds.insert(envelope.id)
                        continue
                    }
                    if let existing = conversation(for: contact.id, in: profile), existing.id == envelope.conversationId {
                        var hydratedExisting = existing
                        if hydratedExisting.messages.isEmpty {
                            hydratedExisting.messages = storedDirectMessages(
                                profileId: profile.id,
                                contactId: contact.id
                            )
                        }
                        existingConversation = hydratedExisting
                        baseConversation = hydratedExisting
                    } else if envelope.kemCiphertext != nil {
                        let inbound = try createInboundSession(
                            for: envelope,
                            contact: contact,
                            identity: profile.identity,
                            profile: &profile
                        )
                        baseConversation = inbound.conversation
                        usedPrekeyForSession = inbound.usedPrekey
                        inboundContext = inbound
                    } else {
                        acknowledgedEnvelopeIds.insert(envelope.id)
                        continue
                    }
                    recoveryConversation = existingConversation ?? baseConversation
                    if isSessionMismatch(envelope: envelope, conversation: baseConversation) {
                        if envelope.kemCiphertext != nil {
                            let inbound = try createInboundSession(
                                for: envelope,
                                contact: contact,
                                identity: profile.identity,
                                profile: &profile
                            )
                            baseConversation = inbound.conversation
                            usedPrekeyForSession = inbound.usedPrekey
                            inboundContext = inbound
                            if let existing = existingConversation {
                                baseConversation.messages = existing.messages
                                baseConversation.unreadCount = existing.unreadCount
                            }
                            recoveryConversation = existingConversation ?? baseConversation
                        } else {
                            let recovery = existingConversation ?? baseConversation
                            if let rebuilt = await attemptSilentSessionReset(
                                contact: contact,
                                existingConversation: recovery,
                                identity: profile.identity,
                                preferredRelay: profile.relay
                            ) {
                                upsertConversation(rebuilt, in: &profile)
                                acknowledgedEnvelopeIds.insert(envelope.id)
                            }
                            continue
                        }
                    }
                    let originalConversation = baseConversation
                    let body: MessageBody
                    let messageKey: SymmetricKey
                    var conversation: Conversation
                    do {
                        var attempt = originalConversation
                        let result = try MessageEngine.decryptWithKey(envelope: envelope, contact: contact, conversation: &attempt)
                        body = result.body
                        messageKey = result.messageKey
                        conversation = attempt
                    } catch {
                        if envelope.kemCiphertext != nil, !usedPrekeyForSession {
                            let inbound = try createInboundSession(
                                for: envelope,
                                contact: contact,
                                identity: profile.identity,
                                profile: &profile
                            )
                            inboundContext = inbound
                            usedPrekeyForSession = inbound.usedPrekey
                            var recoveredConversation = try rebuildInboundConversation(
                                from: originalConversation,
                                inbound: inbound
                            )
                            let result = try MessageEngine.decryptWithKey(envelope: envelope, contact: contact, conversation: &recoveredConversation)
                            body = result.body
                            messageKey = result.messageKey
                            conversation = recoveredConversation
                        } else {
                            throw error
                        }
                    }
                    let appendedMessage: Message?
                    if case .attachment(let descriptor) = body {
                        let sessionId = envelope.sessionId ?? conversation.sessionId
                        let localFileName: String?
                        do {
                            try validateInboundAttachmentDescriptor(descriptor)
                            try validateAttachmentQuota(
                                bytes: descriptor.byteCount,
                                contactId: contact.id,
                                relay: contact.relay,
                                direction: .inbound
                            )
                            localFileName = try await downloadAttachment(
                                descriptor: descriptor,
                                contact: contact,
                                conversationId: conversation.id,
                                sessionId: sessionId,
                                messageCounter: envelope.messageCounter,
                                messageKey: messageKey
                            )
                            if localFileName != nil {
                                recordAttachmentQuotaUsage(
                                    bytes: descriptor.byteCount,
                                    contactId: contact.id,
                                    relay: contact.relay,
                                    direction: .inbound
                                )
                            }
                        } catch {
                            localFileName = nil
                            lastError = "Attachment download failed: \(error.localizedDescription)"
                        }
                        let title = attachmentDisplayTitle(descriptor, fallback: "Attachment received")
                        let message = Message(
                            direction: .received,
                            body: title,
                            timestamp: envelope.sentAt,
                            counter: envelope.messageCounter,
                            attachment: AttachmentInfo(descriptor: descriptor, localFileName: localFileName)
                        )
                        conversation.messages.append(message)
                        appendedMessage = message
                    } else {
                        appendedMessage = MessageEngine.appendMessage(
                            body: body,
                            direction: .received,
                            counter: envelope.messageCounter,
                            timestamp: envelope.sentAt,
                            conversation: &conversation
                        )
                    }
                    if let _ = appendedMessage {
                        if activeContactId != contact.id {
                            conversation.unreadCount += 1
                            if case .text(let text) = body {
                                notifier.notify(title: contact.displayName, body: text)
                            } else if case .attachment(let descriptor) = body {
                                let label = attachmentDisplayTitle(descriptor, fallback: "Attachment received")
                                notifier.notify(title: contact.displayName, body: label)
                            }
                        }
                        lastInfo = "Received message from \(contact.displayName)."
                    }
                    switch body {
                    case .identityRotation(let rotation):
                        let previousFingerprint = contact.fingerprint
                        if contact.apply(rotation: rotation) {
                            profile.continuityEvents.append(
                                ContinuityEvent(
                                    kind: .contactRotationReceived,
                                    contactId: contact.id,
                                    contactDisplayName: contact.displayName,
                                    oldFingerprint: previousFingerprint,
                                    newFingerprint: contact.fingerprint
                                )
                            )
                        }
                    case .identityReset(let reset):
                        let previousFingerprint = contact.fingerprint
                        if contact.apply(reset: reset) {
                            profile.continuityEvents.append(
                                ContinuityEvent(
                                    kind: .contactResetReceived,
                                    contactId: contact.id,
                                    contactDisplayName: contact.displayName,
                                    oldFingerprint: previousFingerprint,
                                    newFingerprint: contact.fingerprint
                                )
                            )
                            if let kemCiphertext = envelope.kemCiphertext {
                                let newConversation = try MessageEngine.createInboundSession(
                                    identity: profile.identity,
                                    contact: contact,
                                    kemCiphertext: kemCiphertext,
                                    agreementKey: inboundContext?.agreementKey
                                )
                                var rebuilt = newConversation
                                rebuilt.messages = conversation.messages
                                conversation = rebuilt
                            }
                        }
                    case .sessionReset:
                        if let kemCiphertext = envelope.kemCiphertext {
                            let newConversation = try MessageEngine.createInboundSession(
                                identity: profile.identity,
                                contact: contact,
                                kemCiphertext: kemCiphertext,
                                agreementKey: inboundContext?.agreementKey
                            )
                            var rebuilt = newConversation
                            rebuilt.messages = conversation.messages
                            rebuilt.unreadCount = conversation.unreadCount
                            conversation = rebuilt
                        }
                    case .resendRequest(let request):
                        let current = pendingResends[contact.id] ?? 0
                        pendingResends[contact.id] = max(current, request.count)
                    default:
                        break
                    }
                    if case .sessionReset = body {
                        conversation.markReset()
                    } else {
                        conversation.markMessageProcessed()
                    }
                    if let ratchet = envelope.rootRatchet, ratchet.counter > conversation.rootCounter {
                        do {
                            let sharedSecret = try profile.identity.agreementKey.decapsulate(ciphertext: ratchet.kemCiphertext)
                            MessageEngine.applyRootRatchet(
                                sharedSecret: sharedSecret,
                                counter: ratchet.counter,
                                identity: profile.identity,
                                contact: contact,
                                conversation: &conversation
                            )
                        } catch {
                            lastError = "Failed to apply root ratchet: \(error.localizedDescription)"
                        }
                    }
                    contact = normalizedContact(contact, preferredRelay: profile.relay)
                    upsertConversation(conversation, in: &profile)
                    updateContact(contact, in: &profile)
                    acknowledgedEnvelopeIds.insert(envelope.id)
                } catch {
                    if signatureValid, let ratchet = envelope.rootRatchet, var conversation = recoveryConversation {
                        do {
                            let sharedSecret = try profile.identity.agreementKey.decapsulate(ciphertext: ratchet.kemCiphertext)
                            MessageEngine.applyRootRatchet(
                                sharedSecret: sharedSecret,
                                counter: ratchet.counter,
                                identity: profile.identity,
                                contact: profile.contacts[contactIndex],
                                conversation: &conversation
                            )
                            upsertConversation(conversation, in: &profile)
                            updateContact(profile.contacts[contactIndex], in: &profile)
                            acknowledgedEnvelopeIds.insert(envelope.id)
                            continue
                        } catch {
                            lastError = "Failed to apply root ratchet: \(error.localizedDescription)"
                        }
                    }
                    switch RatchetRecoveryPolicy.decision(for: error) {
                    case .recover:
                        if let recovery = recoveryConversation,
                           let rebuilt = await attemptSilentSessionReset(
                                contact: profile.contacts[contactIndex],
                                existingConversation: recovery,
                                identity: profile.identity,
                                preferredRelay: profile.relay
                           ) {
                            upsertConversation(rebuilt, in: &profile)
                            acknowledgedEnvelopeIds.insert(envelope.id)
                        }
                        continue
                    case .acknowledge:
                        acknowledgedEnvelopeIds.insert(envelope.id)
                        continue
                    case .retryLater:
                        lastError = "Failed to process envelope: \(error.localizedDescription)"
                    }
                }
            }
            for (contactId, count) in pendingResends {
                await resendRecentMessages(contactId: contactId, count: count, profile: &profile)
            }
            mergeCurrentThreadMessages(into: &profile)
            state.updateIdentityProfile(profile)
            try await persistState()
            let acknowledgementIds = envelopes.map(\.id).filter { acknowledgedEnvelopeIds.contains($0) }
            if !acknowledgementIds.isEmpty {
                var acknowledgement = AcknowledgeMessagesRequest(
                    inboxId: profile.inboxId,
                    messageIds: acknowledgementIds
                )
                let acknowledgementProof = try makeActorProof(
                    fingerprint: CryptoBox.fingerprint(for: inboxAccessKey.publicKeyData),
                    signingKey: inboxAccessKey,
                    publicSigningKey: inboxAccessKey.publicKeyData,
                    signableDataBuilder: { proof in
                        try acknowledgement.signableData(for: proof)
                    }
                )
                acknowledgement = AcknowledgeMessagesRequest(
                    inboxId: profile.inboxId,
                    messageIds: acknowledgementIds,
                    accessProof: acknowledgementProof
                )
                let acknowledgementResponse = try await client.send(
                    .acknowledgeMessages(acknowledgement)
                )
                guard acknowledgementResponse.type == .ok else {
                    throw RelayMailboxError.rejected(
                        acknowledgementResponse.error ?? "Message acknowledgement failed."
                    )
                }
            }
            try await fetchRelayGroupMessages(for: &profile)
            mergeCurrentThreadMessages(into: &profile)
            state.updateIdentityProfile(profile)
            try await persistState()
            if profile.prekeys.oneTimePrekeys.count < prekeyMinimumCount {
                await ensurePrekeys(for: profileId)
            }
            profileSyncStatus[profileId] = .success(Date())
            recordWakeSyncSuccess(for: profileId)
        } catch {
            lastError = "Failed to fetch messages: \(error.localizedDescription)"
            profileSyncStatus[profileId] = .error(Date(), error.localizedDescription)
            recordWakeSyncFailure(for: profileId)
        }
    }

    private func fetchRelayGroupMessages(for profile: inout IdentityProfile) async throws {
        for index in profile.groups.indices {
            var group = profile.groups[index]
            guard let groupInboxId = group.relayInboxId else {
                continue
            }
            guard let descriptor = try await fetchRelayGroup(
                groupId: group.id,
                relay: profile.relay,
                memberFingerprint: profile.identity.fingerprint,
                signingKey: profile.identity.signingKey,
                publicSigningKey: profile.identity.signingKey.publicKeyData
            ) else {
                continue
            }
            group.title = descriptor.title
            group.memberContactIds = contactIds(for: descriptor.members.map(\.fingerprint), contacts: profile.contacts)
            group.relayInboxId = descriptor.inboxId
            group.relayEpoch = descriptor.epoch
            group.relayTranscriptHash = descriptor.mlsEpochState.confirmedTranscriptHash
            group.createdByFingerprint = descriptor.createdByFingerprint
            group.groupRatchetState = groupRatchetState(
                from: descriptor,
                identity: profile.identity,
                existing: group.groupRatchetState
            )
            guard group.relayInboxId == groupInboxId,
                  var ratchetState = group.groupRatchetState else {
                profile.groups[index] = group
                continue
            }
            if group.messages.isEmpty {
                group.messages = storedGroupMessages(profileId: profile.id, groupId: group.id)
            }
            var fetchRequest = FetchGroupMessagesRequest(
                groupId: group.id,
                groupInboxId: groupInboxId,
                actorFingerprint: profile.identity.fingerprint
            )
            let fetchProof = try makeActorProof(
                fingerprint: profile.identity.fingerprint,
                signingKey: profile.identity.signingKey,
                publicSigningKey: profile.identity.signingKey.publicKeyData
            ) { proof in
                try fetchRequest.signableData(for: proof)
            }
            fetchRequest = FetchGroupMessagesRequest(
                groupId: group.id,
                groupInboxId: groupInboxId,
                actorFingerprint: profile.identity.fingerprint,
                actorProof: fetchProof
            )
            let response = try await relayClient(for: profile.relay).send(.fetchGroupMessages(fetchRequest))
            guard response.type == .groupMessages else {
                if let error = response.error {
                    lastError = "Relay group message error: \(error)"
                }
                profile.groups[index] = group
                continue
            }
            var acknowledgedIds = Set<UUID>()
            for envelope in response.groupMessages ?? [] {
                if envelope.senderFingerprint == profile.identity.fingerprint {
                    acknowledgedIds.insert(envelope.id)
                    continue
                }
                if group.messages.contains(where: { $0.id == envelope.id }) {
                    acknowledgedIds.insert(envelope.id)
                    continue
                }
                if envelope.epoch < ratchetState.epoch {
                    acknowledgedIds.insert(envelope.id)
                    continue
                }
                if envelope.epoch != ratchetState.epoch || envelope.transcriptHash != ratchetState.transcriptHash {
                    if let recovered = groupRatchetState(from: descriptor, identity: profile.identity, existing: nil),
                       recovered.epoch == envelope.epoch,
                       recovered.transcriptHash == envelope.transcriptHash {
                        ratchetState = recovered
                    }
                }
                guard envelope.epoch == ratchetState.epoch,
                      envelope.transcriptHash == ratchetState.transcriptHash,
                      let sender = descriptor.members.first(where: { $0.fingerprint == envelope.senderFingerprint }),
                      let senderSigningKey = sender.signingPublicKey else {
                    continue
                }
                do {
                    let decrypted = try GroupRatchet.decryptWithKey(
                        envelope: envelope,
                        senderPublicSigningKey: senderSigningKey,
                        state: &ratchetState
                    )
                    let body = decrypted.body
                    switch body {
                    case .text(let text):
                        group.messages.append(
                            Message(
                                id: envelope.id,
                                direction: .received,
                                senderDisplayName: sender.displayName,
                                body: text,
                                timestamp: envelope.sentAt,
                                counter: envelope.messageCounter
                            )
                        )
                        if activeGroupId != group.id {
                            group.unreadCount += 1
                            notifier.notify(title: group.title, body: "\(sender.displayName ?? "Group member"): \(text)")
                        }
                        lastInfo = "Received group message."
                        acknowledgedIds.insert(envelope.id)
                    case .attachment(let descriptor):
                        let localFileName: String?
                        do {
                            try validateInboundAttachmentDescriptor(descriptor)
                            try validateAttachmentQuota(
                                bytes: descriptor.byteCount,
                                contactId: group.id,
                                relay: profile.relay,
                                direction: .inbound
                            )
                            localFileName = try await downloadGroupAttachment(
                                descriptor: descriptor,
                                groupId: group.id,
                                epoch: envelope.epoch,
                                transcriptHash: envelope.transcriptHash,
                                messageCounter: envelope.messageCounter,
                                messageKey: decrypted.messageKey,
                                relay: profile.relay
                            )
                            if localFileName != nil {
                                recordAttachmentQuotaUsage(
                                    bytes: descriptor.byteCount,
                                    contactId: group.id,
                                    relay: profile.relay,
                                    direction: .inbound
                                )
                            }
                        } catch {
                            localFileName = nil
                            lastError = "Group attachment download failed: \(error.localizedDescription)"
                        }
                        let title = attachmentDisplayTitle(descriptor, fallback: "Attachment received")
                        group.messages.append(
                            Message(
                                id: envelope.id,
                                direction: .received,
                                senderDisplayName: sender.displayName,
                                body: title,
                                timestamp: envelope.sentAt,
                                counter: envelope.messageCounter,
                                attachment: AttachmentInfo(descriptor: descriptor, localFileName: localFileName)
                            )
                        )
                        if activeGroupId != group.id {
                            group.unreadCount += 1
                            notifier.notify(title: group.title, body: "\(sender.displayName ?? "Group member"): \(title)")
                        }
                        lastInfo = "Received group attachment."
                        acknowledgedIds.insert(envelope.id)
                    default:
                        acknowledgedIds.insert(envelope.id)
                    }
                } catch {
                    if let recovered = groupRatchetState(from: descriptor, identity: profile.identity, existing: nil),
                       recovered.epoch == envelope.epoch,
                       recovered.transcriptHash == envelope.transcriptHash,
                       let sender = descriptor.members.first(where: { $0.fingerprint == envelope.senderFingerprint }),
                       let senderSigningKey = sender.signingPublicKey {
                        var recoveryState = recovered
                        do {
                            let decrypted = try GroupRatchet.decryptWithKey(
                                envelope: envelope,
                                senderPublicSigningKey: senderSigningKey,
                                state: &recoveryState
                            )
                            switch decrypted.body {
                            case .text(let text):
                                group.messages.append(
                                    Message(
                                        id: envelope.id,
                                        direction: .received,
                                        senderDisplayName: sender.displayName,
                                        body: text,
                                        timestamp: envelope.sentAt,
                                        counter: envelope.messageCounter
                                    )
                                )
                                if activeGroupId != group.id {
                                    group.unreadCount += 1
                                    notifier.notify(title: group.title, body: "\(sender.displayName ?? "Group member"): \(text)")
                                }
                                lastInfo = "Recovered group message."
                                acknowledgedIds.insert(envelope.id)
                                ratchetState = recoveryState
                            case .attachment:
                                lastError = "Group attachment recovery deferred until normal ratchet state is available."
                            default:
                                acknowledgedIds.insert(envelope.id)
                                ratchetState = recoveryState
                            }
                        } catch {
                            if envelope.epoch < ratchetState.epoch {
                                acknowledgedIds.insert(envelope.id)
                            }
                        }
                    } else if envelope.epoch < ratchetState.epoch {
                        acknowledgedIds.insert(envelope.id)
                    }
                }
            }
            group.groupRatchetState = ratchetState
            profile.groups[index] = group
            if !acknowledgedIds.isEmpty {
                var acknowledgement = AcknowledgeGroupMessagesRequest(
                    groupId: group.id,
                    groupInboxId: groupInboxId,
                    messageIds: Array(acknowledgedIds),
                    actorFingerprint: profile.identity.fingerprint
                )
                let ackProof = try makeActorProof(
                    fingerprint: profile.identity.fingerprint,
                    signingKey: profile.identity.signingKey,
                    publicSigningKey: profile.identity.signingKey.publicKeyData
                ) { proof in
                    try acknowledgement.signableData(for: proof)
                }
                acknowledgement = AcknowledgeGroupMessagesRequest(
                    groupId: group.id,
                    groupInboxId: groupInboxId,
                    messageIds: Array(acknowledgedIds),
                    actorFingerprint: profile.identity.fingerprint,
                    actorProof: ackProof
                )
                let acknowledgementResponse = try await relayClient(for: profile.relay).send(
                    .acknowledgeGroupMessages(acknowledgement)
                )
                guard acknowledgementResponse.type == .ok else {
                    throw RelayMailboxError.rejected(
                        acknowledgementResponse.error ?? "Group message acknowledgement failed."
                    )
                }
            }
        }
    }

    func rotateIdentity() async {
        do {
            var previousIdentity = state.identity
            let rotationContext = try state.identity.rotateKeys()
            let oldSigningKey = rotationContext.oldSigningKey
            previousIdentity.signingKey = oldSigningKey
            previousIdentity.agreementKey = rotationContext.oldAgreementKey
            let oldFingerprint = rotationContext.oldFingerprint
            recordContinuityEvent(
                kind: .identityRotated,
                oldFingerprint: oldFingerprint,
                newFingerprint: state.identity.fingerprint
            )
            if let regenerated = try? PrekeyState.generate(identity: state.identity, oneTimeCount: prekeyTargetCount) {
                state.prekeys = regenerated
                await publishPrekeys(regenerated, identity: state.identity, relay: state.relay)
            }

            var rebuiltByContact: [UUID: Conversation] = [:]
            var failedContacts: [String] = []
            for rawContact in state.contacts {
                let contact = normalizedContact(rawContact, preferredRelay: state.relay)
                loadConversationMessagesIntoRAM(contactId: contact.id)
                let existingConversation = state.conversation(for: contact.id)
                do {
                    let bootstrapSession = try MessageEngine.createOutboundSession(identity: previousIdentity, contact: contact)
                    var bootstrapConversation = bootstrapSession.conversation
                    let envelope = try MessageEngine.encrypt(
                        body: .identityRotation(rotationContext.rotation),
                        senderSigningKey: oldSigningKey,
                        senderFingerprint: oldFingerprint,
                        conversation: &bootstrapConversation,
                        kemCiphertext: bootstrapSession.kemCiphertext,
                        prekey: nil
                    )
                    bootstrapConversation.markMessageProcessed()
                    try await deliverEnvelope(envelope, to: contact, preferredRelay: state.relay)

                    if let existingConversation {
                        var migrated = bootstrapConversation
                        migrated.messages = existingConversation.messages
                        migrated.unreadCount = existingConversation.unreadCount
                        rebuiltByContact[contact.id] = migrated
                    } else {
                        rebuiltByContact[contact.id] = bootstrapConversation
                    }
                } catch {
                    if let existingConversation {
                        rebuiltByContact[contact.id] = existingConversation
                    }
                    failedContacts.append(contact.displayName)
                }
            }
            state.conversations = state.contacts.compactMap { rebuiltByContact[$0.id] }
            await migrateRelayBackedGroupsAfterRotation(
                oldFingerprint: oldFingerprint,
                oldSigningKey: oldSigningKey
            )
            try await persistState()
            if failedContacts.isEmpty {
                lastInfo = "Rotated keys and notified contacts."
            } else {
                lastError = "Rotated keys, but delivery failed for: \(failedContacts.joined(separator: ", "))."
            }
        } catch {
            lastError = "Failed to rotate keys: \(error.localizedDescription)"
        }
    }

    private func migrateRelayBackedGroupsAfterRotation(
        oldFingerprint: String,
        oldSigningKey: SigningKeyPair
    ) async {
        let relayBackedGroups = state.groups.filter { $0.relayInboxId != nil }
        guard !relayBackedGroups.isEmpty else {
            return
        }
        let updatedProfile = relayGroupMemberProfileForActiveIdentity()

        for group in relayBackedGroups {
            do {
                if group.createdByFingerprint == oldFingerprint {
                    let descriptor = try await updateRelayGroupRegistry(
                        groupId: group.id,
                        actorFingerprint: oldFingerprint,
                        actorSigningKey: oldSigningKey,
                        title: nil,
                        addMemberFingerprints: [state.identity.fingerprint],
                        addMemberProfiles: [updatedProfile],
                        removeMemberFingerprints: [oldFingerprint],
                        relay: state.relay
                    )
                    var merged = group
                    merged.title = descriptor.title
                    merged.memberContactIds = contactIds(for: descriptor.members.map { $0.fingerprint })
                    merged.relayInboxId = descriptor.inboxId
                    merged.relayEpoch = descriptor.epoch
                    merged.relayTranscriptHash = descriptor.mlsEpochState.confirmedTranscriptHash
                    merged.createdByFingerprint = descriptor.createdByFingerprint
                    state.upsert(group: merged)
                } else {
                    _ = try await requestRelayGroupJoin(
                        groupId: group.id,
                        requesterProfile: updatedProfile,
                        relay: state.relay
                    )
                }
            } catch {
                continue
            }
        }
        await syncRelayGroups(for: state.activeIdentityId)
    }

    func burnIdentity() async {
        guard !isBurningIdentity else {
            return
        }
        isBurningIdentity = true
        defer { isBurningIdentity = false }

        let oldIdentity = state.identity
        let oldSigningKey = oldIdentity.signingKey
        let oldFingerprint = oldIdentity.fingerprint

        state.identity = Identity(displayName: oldIdentity.displayName)
        let newInboxAccessKey = SigningKeyPair()
        state.inboxAccessKey = newInboxAccessKey
        state.inboxId = InboxAddress.derived(from: newInboxAccessKey.publicKeyData)
        recordContinuityEvent(
            kind: .identityBurned,
            oldFingerprint: oldFingerprint,
            newFingerprint: state.identity.fingerprint
        )
        if let regenerated = try? PrekeyState.generate(identity: state.identity, oneTimeCount: prekeyTargetCount) {
            state.prekeys = regenerated
            await publishPrekeys(regenerated, identity: state.identity, relay: state.relay)
        }

        var rebuiltConversations: [Conversation] = []
        var updatedContacts: [Contact] = []

        for contact in state.contacts {
            guard contact.allowIdentityReset else {
                continue
            }
            do {
                loadConversationMessagesIntoRAM(contactId: contact.id)
                guard var conversation = state.conversation(for: contact.id) else {
                    continue
                }
                let newOffer = try MessageEngine.makeContactOffer(
                    identity: state.identity,
                    inboxId: state.inboxId,
                    relay: state.relay,
                    inboxAccessPublicKey: state.inboxAccessKey?.publicKeyData
                )
                let reset = try IdentityReset.create(newOffer: newOffer, signingKey: oldSigningKey)
                let session = try await prepareOutboundSession(for: contact, forceNew: true)
                let envelope = try MessageEngine.encrypt(
                    body: .identityReset(reset),
                    senderSigningKey: oldSigningKey,
                    senderFingerprint: oldFingerprint,
                    conversation: &conversation,
                    kemCiphertext: session.kemCiphertext,
                    prekey: session.prekey
                )
                conversation.markMessageProcessed()
                try await deliverEnvelope(envelope, to: contact, preferredRelay: state.relay)

                var merged = session.conversation
                merged.messages = conversation.messages
                rebuiltConversations.append(merged)
                updatedContacts.append(contact)
            } catch {
                lastError = "Failed to notify \(contact.displayName): \(error.localizedDescription)"
            }
        }

        state.contacts = updatedContacts
        state.conversations = rebuiltConversations
        await save()
        lastInfo = "Identity burned. Contacts marked in Contact Book were notified."
    }

    func purgeContinuityAudit() async {
        state.purgeContinuityEvents()
        await save()
        lastInfo = "Continuity audit purged."
    }

    func updateDisplayName(_ displayName: String) async {
        state.identity.displayName = displayName
        await save()
    }

    func addIdentityProfile(displayName: String, relayId: UUID?) async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty ? "New Identity" : trimmed
        let identity = Identity(displayName: resolvedName)
        let inboxAccessKey = SigningKeyPair()
        let inboxId = InboxAddress.derived(from: inboxAccessKey.publicKeyData)
        let relaySelection = relayId.flatMap { id in
            state.relayServers.first(where: { $0.id == id })
        } ?? state.relayServers.first
        let relay = relaySelection?.endpoint ?? state.relay
        let selectedRelayId = relaySelection?.id
        let prekeys = (try? PrekeyState.generate(identity: identity)) ?? PrekeyState(
            signedPrekeyId: UUID(),
            signedPrekeyPublicKey: Data(),
            signedPrekeyPrivateKey: Data(),
            signedPrekeySignature: Data(),
            signedPrekeyIssuedAt: Date(),
            oneTimePrekeys: []
        )
        let profile = IdentityProfile(
            identity: identity,
            inboxId: inboxId,
            inboxAccessKey: inboxAccessKey,
            relay: relay,
            selectedRelayId: selectedRelayId,
            prekeys: prekeys
        )
        state.identityProfiles.append(profile)
        recordContinuityEvent(
            kind: .identityCreated,
            newFingerprint: identity.fingerprint,
            profileId: profile.id
        )
        await save()
        await ensurePrekeys(for: profile.id)
    }

    func setActiveIdentity(_ profileId: UUID) async {
        guard let profile = state.identityProfiles.first(where: { $0.id == profileId }) else {
            return
        }
        guard !profile.isArchived else {
            lastError = "Restore the identity before activating it."
            return
        }
        try? persistAllThreadMessagesFromState(state)
        evictAllThreadMessagesFromRAM()
        state.activeIdentityId = profileId
        await ensureRelaySelection()
        await ensurePrekeys()
        await save()
    }

    func updateIdentityRelay(profileId: UUID, relayId: UUID?) async {
        guard var profile = state.identityProfile(id: profileId) else {
            return
        }
        if let relayId, let record = state.relayServers.first(where: { $0.id == relayId }) {
            profile.relay = record.endpoint
            profile.selectedRelayId = record.id
        } else if let first = state.relayServers.first {
            profile.relay = first.endpoint
            profile.selectedRelayId = first.id
        }
        state.updateIdentityProfile(profile)
        if profileId == state.activeIdentityId {
            await ensureRelaySelection()
        }
        await save()
        await ensurePrekeys(for: profileId)
    }

    func archiveIdentityProfile(profileId: UUID) async {
        guard var profile = state.identityProfile(id: profileId) else {
            return
        }
        guard !profile.isArchived else {
            return
        }
        profile.isArchived = true
        profile.archivedAt = Date()
        state.updateIdentityProfile(profile)
        if profileId == state.activeIdentityId {
            await switchToNextActiveIdentity(excluding: profileId)
        }
        await save()
    }

    func restoreIdentityProfile(profileId: UUID) async {
        guard var profile = state.identityProfile(id: profileId) else {
            return
        }
        guard profile.isArchived else {
            return
        }
        profile.isArchived = false
        profile.archivedAt = nil
        state.updateIdentityProfile(profile)
        await save()
    }

    func deleteIdentityProfile(profileId: UUID) async {
        guard let profile = state.identityProfile(id: profileId) else {
            return
        }
        if profileId == state.activeIdentityId {
            if state.identityProfiles.count <= 1 {
                await burnIdentity()
                return
            }
            lastError = "Switch identities before deleting the active one."
            return
        }
        if state.identityProfiles.count <= 1 {
            lastError = "At least one identity must remain."
            return
        }
        for conversation in profile.conversations {
            let messages = conversation.messages.isEmpty
                ? storedDirectMessages(profileId: profile.id, contactId: conversation.contactId)
                : conversation.messages
            removeAttachmentFiles(from: messages)
        }
        for group in profile.groups {
            let messages = group.messages.isEmpty
                ? storedGroupMessages(profileId: profile.id, groupId: group.id)
                : group.messages
            removeAttachmentFiles(from: messages)
        }
        try? threadMessageStore.deleteAllMessages(profileId: profile.id)
        state.identityProfiles.removeAll { $0.id == profileId }
        if profileId == state.activeIdentityId {
            await switchToNextActiveIdentity(excluding: profileId)
        }
        await save()
    }

    private func switchToNextActiveIdentity(excluding profileId: UUID) async {
        try? persistAllThreadMessagesFromState(state)
        evictAllThreadMessagesFromRAM()
        if let next = state.identityProfiles.first(where: { !$0.isArchived && $0.id != profileId }) {
            state.activeIdentityId = next.id
        } else {
            let identity = Identity(displayName: "New Identity")
            let inboxAccessKey = SigningKeyPair()
            let inboxId = InboxAddress.derived(from: inboxAccessKey.publicKeyData)
            let relaySelection = state.relayServers.first
            let relay = relaySelection?.endpoint ?? state.relay
            let selectedRelayId = relaySelection?.id
            let prekeys = (try? PrekeyState.generate(identity: identity)) ?? PrekeyState(
                signedPrekeyId: UUID(),
                signedPrekeyPublicKey: Data(),
                signedPrekeyPrivateKey: Data(),
                signedPrekeySignature: Data(),
                signedPrekeyIssuedAt: Date(),
                oneTimePrekeys: []
            )
            let profile = IdentityProfile(
                identity: identity,
                inboxId: inboxId,
                inboxAccessKey: inboxAccessKey,
                relay: relay,
                selectedRelayId: selectedRelayId,
                prekeys: prekeys
            )
            state.identityProfiles.append(profile)
            state.activeIdentityId = profile.id
        }
        await ensureRelaySelection()
        await ensurePrekeys()
    }

    func updateTheme(_ theme: ThemePalette) async {
        state.appearance.theme = theme
        await save()
    }

    func updatePrivacy(_ settings: PrivacySettings) async {
        state.privacy = settings
        await save()
    }

    func updateContactIdentityReset(contactId: UUID, allow: Bool) async {
        guard let index = state.contacts.firstIndex(where: { $0.id == contactId }) else {
            return
        }
        var contact = state.contacts[index]
        contact.allowIdentityReset = allow
        state.updateContact(contact)
        await save()
    }

    func assertContactTrust(contactId: UUID, note: String? = nil) async {
        guard var contact = state.contacts.first(where: { $0.id == contactId }) else {
            return
        }
        let assertion = ContactTrustAssertion(
            kind: .verified,
            fingerprint: contact.fingerprint,
            note: note
        )
        contact.trustAssertions.append(assertion)
        state.updateContact(contact)
        recordContinuityEvent(
            kind: .trustAsserted,
            contact: contact,
            note: note,
            newFingerprint: contact.fingerprint
        )
        await save()
        lastInfo = "Verified \(contact.displayName)."
    }

    func revokeContactTrust(contactId: UUID, note: String? = nil) async {
        guard var contact = state.contacts.first(where: { $0.id == contactId }) else {
            return
        }
        let assertion = ContactTrustAssertion(
            kind: .revoked,
            fingerprint: contact.fingerprint,
            note: note
        )
        contact.trustAssertions.append(assertion)
        state.updateContact(contact)
        recordContinuityEvent(
            kind: .trustRevoked,
            contact: contact,
            note: note,
            newFingerprint: contact.fingerprint
        )
        await save()
        lastInfo = "Revoked trust for \(contact.displayName)."
    }

    func updateAppLock(_ settings: AppLockSettings, lockAfterUpdate: Bool = true) async {
        refreshBiometricAvailability()
        var updated = sanitizeAppLock(settings)
        if updated.mode == .off {
            updated.pinHash = nil
            updated.pinSalt = nil
            isLocked = false
            clearPinAttemptState()
        }
        state.appLock = updated
        await save()
        if lockAfterUpdate && shouldLockImmediately(settings: updated) {
            isLocked = true
        }
    }

    func setAppLockPin(_ pin: String) async -> Bool {
        let normalized = normalizedPin(pin)
        guard normalized.count == 6 else {
            lastError = "PIN must be 6 digits."
            return false
        }
        if pinMatchesActionPin(normalized) {
            lastError = "PIN cannot match an action PIN."
            return false
        }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let hash = pinHash(pin: normalized, salt: salt)
        state.appLock.pinSalt = salt
        state.appLock.pinHash = hash
        await save()
        return true
    }

    func verifyAppLockPin(_ pin: String) -> Bool {
        let normalized = normalizedPin(pin)
        guard normalized.count == 6 else {
            return false
        }
        if appLockPinLockoutRemainingSeconds() > 0 {
            return false
        }
        guard let salt = state.appLock.pinSalt, let hash = state.appLock.pinHash else {
            return false
        }
        guard pinMatches(normalized, salt: salt, hash: hash) else {
            recordFailedPinAttempt()
            return false
        }
        clearPinAttemptState()
        return true
    }

    func appLockPinLockoutRemainingSeconds() -> Int {
        guard let pinLockedUntil else {
            return 0
        }
        let remaining = Int(ceil(pinLockedUntil.timeIntervalSinceNow))
        if remaining <= 0 {
            self.pinLockedUntil = nil
            return 0
        }
        return remaining
    }

    func setActionPlanPin(
        pin: String,
        planId: UUID?,
        label: String,
        operations: [AppLockActionOperation]
    ) async -> Bool {
        let normalized = normalizedPin(pin)
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count == 6 else {
            lastError = "PIN must be 6 digits."
            return false
        }
        guard !trimmedLabel.isEmpty else {
            lastError = "Choose a label for this action pin."
            return false
        }
        guard !operations.isEmpty else {
            lastError = "Choose at least one action."
            return false
        }
        if unlockPinMatches(normalized) {
            lastError = "Action PIN cannot match the unlock PIN."
            return false
        }
        if pinMatchesAnyActionPlan(normalized, excluding: planId) {
            lastError = "Action PIN must be unique."
            return false
        }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let hash = pinHash(pin: normalized, salt: salt)
        let normalizedOperations = normalizeActionOperations(operations)
        guard !normalizedOperations.isEmpty else {
            lastError = "Selected actions are no longer supported."
            return false
        }
        if let planId, let index = state.appLock.actionPlans.firstIndex(where: { $0.id == planId }) {
            state.appLock.actionPlans[index].label = trimmedLabel
            state.appLock.actionPlans[index].pinSalt = salt
            state.appLock.actionPlans[index].pinHash = hash
            state.appLock.actionPlans[index].operations = normalizedOperations
        } else {
            state.appLock.actionPlans.append(
                AppLockActionPlan(
                    label: trimmedLabel,
                    pinSalt: salt,
                    pinHash: hash,
                    operations: normalizedOperations
                )
            )
        }
        await save()
        return true
    }

    func removeActionPlan(planId: UUID) async {
        state.appLock.actionPlans.removeAll { $0.id == planId }
        await save()
    }

    func setActionPin(_ pin: String, action: AppLockPinAction) async -> Bool {
        let operation: AppLockActionOperation
        let label: String
        switch action {
        case .burnIdentity:
            operation = AppLockActionOperation(kind: .burnIdentities, identityIds: [state.activeIdentityId])
            label = "Burn Identity"
        case .clearChats:
            operation = AppLockActionOperation(
                kind: .deleteChats,
                groupIds: state.groups.map(\.id),
                chatContactIds: state.conversations.map(\.contactId)
            )
            label = "Clear Chats"
        }
        return await setActionPlanPin(pin: pin, planId: nil, label: label, operations: [operation])
    }

    func clearActionPin(_ action: AppLockPinAction) async {
        let matchingKind: AppLockActionKind = action == .burnIdentity ? .burnIdentities : .deleteChats
        state.appLock.actionPlans.removeAll { plan in
            plan.operations.count == 1 && plan.operations[0].kind == matchingKind
        }
        await save()
    }

    func performActionPinIfNeeded(_ pin: String) async -> String? {
        let normalized = normalizedPin(pin)
        if let plan = state.appLock.actionPlans.first(where: { pinMatches(normalized, salt: $0.pinSalt, hash: $0.pinHash) }) {
            await executeActionPlan(plan, pin: normalized)
            clearPinAttemptState()
            return plan.label
        }
        return nil
    }

    func performBiometricUnlock(reason: String = "Unlock app") async -> Bool {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            biometricsAvailable = false
            return false
        }
        biometricsAvailable = true
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
        #else
        return false
        #endif
    }

    func completeUnlock() {
        isLocked = false
        lastInactiveAt = nil
        startAutoFetchIfEligible()
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase == .active {
            refreshBiometricAvailability()
            if sanitizeAppLockForBiometricAvailability() {
                Task { await save() }
            }
        }
        if phase == .inactive || phase == .background {
            stopAutoFetch()
        }
        if phase == .background {
            lastInactiveAt = Date()
            try? persistAllThreadMessagesFromState(state)
            evictAllThreadMessagesFromRAM()
            purgeAllAttachmentDecryptionMemory()
            Task { await save() }
        }
        guard state.appLock.mode != .off else {
            if phase == .active {
                startAutoFetchIfEligible()
            }
            return
        }
        switch phase {
        case .active:
            if shouldLockForTimeout() {
                isLocked = true
            }
            if !isLocked {
                startAutoFetchIfEligible()
            }
        case .inactive, .background:
            break
        @unknown default:
            break
        }
    }

    func openConversation(contactId: UUID) async {
        loadConversationMessagesIntoRAM(contactId: contactId)
    }

    func latestDirectMessage(contactId: UUID) -> Message? {
        directMessagesForDisplay(contactId: contactId).last
    }

    func directMessagesForDisplay(contactId: UUID) -> [Message] {
        mergedMessages(
            storedDirectMessages(profileId: state.activeIdentityId, contactId: contactId),
            state.conversation(for: contactId)?.messages ?? []
        )
    }

    func latestGroupMessage(groupId: UUID) -> Message? {
        groupMessagesForDisplay(groupId: groupId).last
    }

    func groupMessagesForDisplay(groupId: UUID) -> [Message] {
        mergedMessages(
            storedGroupMessages(profileId: state.activeIdentityId, groupId: groupId),
            state.group(for: groupId)?.messages ?? []
        )
    }

    func closeConversation(contactId: UUID) async {
        persistAndEvictConversationMessages(contactId: contactId)
        purgeAttachmentDecryptionMemory(contactId: contactId)
    }

    func openGroupConversation(groupId: UUID) async {
        loadGroupMessagesIntoRAM(groupId: groupId)
    }

    func closeGroupConversation(groupId: UUID) async {
        persistAndEvictGroupMessages(groupId: groupId)
        purgeAttachmentDecryptionMemory(groupId: groupId)
    }

    func markConversationRead(contactId: UUID) async {
        guard var conversation = state.conversation(for: contactId) else {
            return
        }
        guard conversation.unreadCount > 0 else {
            return
        }
        conversation.unreadCount = 0
        state.upsert(conversation: conversation)
        await save()
    }

    func markGroupRead(groupId: UUID) async {
        guard var group = state.group(for: groupId) else {
            return
        }
        guard group.unreadCount > 0 else {
            return
        }
        group.unreadCount = 0
        state.upsert(group: group)
        await save()
    }

    func createGroup(title: String, memberContactIds: [UUID]) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            lastError = "Choose a group name."
            return
        }
        let members = Array(Set(memberContactIds))
        guard members.count >= 2 else {
            lastError = "Select at least 2 contacts."
            return
        }
        let knownContacts = Set(state.contacts.map(\.id))
        let validMembers = members.filter { knownContacts.contains($0) }
        guard validMembers.count >= 2 else {
            lastError = "Selected contacts are no longer available."
            return
        }
        if let selectedRelay = state.relayServers.first(where: { $0.id == state.selectedRelayId }),
           selectedRelay.advertisedInfo?.groupCreationMode == .disabled {
            lastError = "Group creation is disabled on the selected relay."
            return
        }
        let memberFingerprints = validMembers.compactMap { memberId in
            state.contacts.first(where: { $0.id == memberId })?.fingerprint
        }
        guard memberFingerprints.count >= 2 else {
            lastError = "Selected members are missing relay fingerprints."
            return
        }
        let memberProfiles: [RelayGroupMemberProfile] = validMembers.compactMap { memberId -> RelayGroupMemberProfile? in
            guard let contact = state.contacts.first(where: { $0.id == memberId }) else {
                return nil
            }
            return relayGroupMemberProfile(for: contact)
        }
        let relayGroup: RelayGroupDescriptor
        do {
            relayGroup = try await createRelayGroupRegistry(
                title: trimmedTitle,
                memberFingerprints: memberFingerprints,
                memberProfiles: memberProfiles
            )
        } catch {
            lastError = "Failed to create relay group: \(error.localizedDescription)"
            return
        }

        let group = GroupConversation(
            id: relayGroup.id,
            title: relayGroup.title,
            memberContactIds: validMembers,
            relayInboxId: relayGroup.inboxId,
            relayEpoch: relayGroup.epoch,
            relayTranscriptHash: relayGroup.mlsEpochState.confirmedTranscriptHash,
            groupRatchetState: groupRatchetState(from: relayGroup, identity: state.identity),
            createdByFingerprint: relayGroup.createdByFingerprint
        )
        state.upsert(group: group)
        await save()
        lastInfo = "Created relay-backed group \(group.title)."
    }

    func removeGroup(id: UUID) async {
        guard let group = state.group(for: id) else { return }
        loadGroupMessagesIntoRAM(groupId: id)
        let messages = state.group(for: id)?.messages ?? []
        removeAttachmentFiles(from: messages)
        try? threadMessageStore.deleteGroupMessages(profileId: state.activeIdentityId, groupId: id)
        state.groups.removeAll { $0.id == id }
        if activeGroupId == id {
            activeGroupId = nil
        }
        await save()
        lastInfo = "Removed group \(group.title)."
    }

    func updateGroup(id: UUID, title: String, memberContactIds: [UUID]) async {
        guard var group = state.group(for: id) else {
            lastError = "Group not found."
            return
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            lastError = "Choose a group name."
            return
        }
        let normalizedMembers = Array(Set(memberContactIds))
        guard normalizedMembers.count >= 2 else {
            lastError = "Select at least 2 contacts."
            return
        }
        let knownContacts = Set(state.contacts.map(\.id))
        let validMembers = normalizedMembers.filter { knownContacts.contains($0) }
        guard validMembers.count >= 2 else {
            lastError = "Selected contacts are no longer available."
            return
        }
        let newMemberFingerprints = Set(validMembers.compactMap { memberId in
            state.contacts.first(where: { $0.id == memberId })?.fingerprint
        })
        guard newMemberFingerprints.count >= 2 else {
            lastError = "Selected members are missing relay fingerprints."
            return
        }

        if group.relayInboxId != nil {
            let currentFingerprints = Set(group.memberContactIds.compactMap { memberId in
                state.contacts.first(where: { $0.id == memberId })?.fingerprint
            })
            let addMembers = Array(newMemberFingerprints.subtracting(currentFingerprints)).sorted()
            let removeMembers = Array(currentFingerprints.subtracting(newMemberFingerprints)).sorted()
            let memberProfilesForRelay: [RelayGroupMemberProfile] = validMembers.compactMap { memberId -> RelayGroupMemberProfile? in
                guard let contact = state.contacts.first(where: { $0.id == memberId }) else {
                    return nil
                }
                return relayGroupMemberProfile(for: contact)
            }
            do {
                let descriptor = try await updateRelayGroupRegistry(
                    groupId: id,
                    title: trimmedTitle == group.title ? nil : trimmedTitle,
                    addMemberFingerprints: addMembers,
                    addMemberProfiles: memberProfilesForRelay,
                    removeMemberFingerprints: removeMembers
                )
                group.title = descriptor.title
                group.memberContactIds = contactIds(for: descriptor.members.map(\.fingerprint))
                group.relayInboxId = descriptor.inboxId
                group.relayEpoch = descriptor.epoch
                group.relayTranscriptHash = descriptor.mlsEpochState.confirmedTranscriptHash
                group.groupRatchetState = groupRatchetState(
                    from: descriptor,
                    identity: state.identity,
                    existing: group.groupRatchetState
                )
                group.createdByFingerprint = descriptor.createdByFingerprint
                state.upsert(group: group)
                await save()
                lastInfo = "Updated relay-backed group \(group.title)."
                return
            } catch {
                lastError = "Failed to update relay group: \(error.localizedDescription)"
                return
            }
        }

        group.title = trimmedTitle
        group.memberContactIds = validMembers
        state.upsert(group: group)
        await save()
        lastInfo = "Updated group \(trimmedTitle)."
    }

    func isRelayGroupCreator(_ group: GroupConversation) -> Bool {
        guard group.relayInboxId != nil,
              let creator = group.createdByFingerprint else {
            return false
        }
        return Set(activeIdentityLineageFingerprints()).contains(creator)
    }

    func canEditRelayGroup(_ group: GroupConversation) -> Bool {
        group.relayInboxId == nil || isRelayGroupCreator(group)
    }

    func leaveGroup(id: UUID) async {
        guard let group = state.group(for: id) else { return }
        if group.relayInboxId != nil {
            let relay = state.relay
            let identityFingerprints = activeIdentityLineageFingerprints()
            let identitySet = Set(identityFingerprints)
            let descriptor: RelayGroupDescriptor?
            do {
                descriptor = try await fetchRelayGroup(groupId: id, relay: relay)
            } catch {
                lastError = "Failed to leave relay-backed group: \(error.localizedDescription)"
                return
            }

            if let descriptor, identitySet.contains(descriptor.createdByFingerprint) {
                let creatorFingerprint = descriptor.createdByFingerprint
                do {
                    try await deleteRelayGroupRegistry(
                        groupId: id,
                        actorFingerprint: creatorFingerprint,
                        relay: relay
                    )
                } catch {
                    lastError = "Failed to extinguish relay-backed group: \(error.localizedDescription)"
                    return
                }
            } else if let descriptor {
                let memberFingerprints = Set(descriptor.members.map(\.fingerprint))
                let selfMemberships = identityFingerprints.filter { memberFingerprints.contains($0) }
                if selfMemberships.isEmpty {
                    loadGroupMessagesIntoRAM(groupId: id)
                    let messages = state.group(for: id)?.messages ?? []
                    removeAttachmentFiles(from: messages)
                    try? threadMessageStore.deleteGroupMessages(profileId: state.activeIdentityId, groupId: id)
                    state.groups.removeAll { $0.id == id }
                    if activeGroupId == id {
                        activeGroupId = nil
                    }
                    await save()
                    await syncRelayGroups(for: state.activeIdentityId)
                    lastInfo = "Removed stale group \(group.title)."
                    return
                }

                var removedAnyMembership = false
                var lastMembershipError: String?
                for membershipFingerprint in selfMemberships {
                    do {
                        _ = try await updateRelayGroupRegistry(
                            groupId: id,
                            actorFingerprint: membershipFingerprint,
                            title: nil,
                            addMemberFingerprints: [],
                            addMemberProfiles: [],
                            removeMemberFingerprints: [membershipFingerprint],
                            relay: relay
                        )
                        removedAnyMembership = true
                    } catch {
                        lastMembershipError = error.localizedDescription
                    }
                }

                guard removedAnyMembership else {
                    lastError = "Failed to leave relay-backed group: \(lastMembershipError ?? "Unknown relay error.")"
                    return
                }
            }
        }
        loadGroupMessagesIntoRAM(groupId: id)
        let messages = state.group(for: id)?.messages ?? []
        removeAttachmentFiles(from: messages)
        try? threadMessageStore.deleteGroupMessages(profileId: state.activeIdentityId, groupId: id)
        state.groups.removeAll { $0.id == id }
        if activeGroupId == id {
            activeGroupId = nil
        }
        await save()
        if group.relayInboxId != nil {
            await syncRelayGroups(for: state.activeIdentityId)
        }
        if isRelayGroupCreator(group) {
            lastInfo = "Extinguished group \(group.title)."
        } else {
            lastInfo = "Left group \(group.title)."
        }
    }

    func requestJoin(groupId: UUID) async {
        do {
            _ = try await requestRelayGroupJoin(groupId: groupId)
            lastInfo = "Join request sent."
        } catch {
            lastError = "Failed to request join: \(error.localizedDescription)"
        }
    }

    func refreshPendingJoinRequests(groupId: UUID) async {
        do {
            let requests = try await listRelayGroupJoinRequests(groupId: groupId)
            pendingGroupJoinRequests[groupId] = requests
        } catch {
            lastError = "Failed to fetch join requests: \(error.localizedDescription)"
        }
    }

    func approvePendingJoinRequest(groupId: UUID, joinRequestId: UUID) async {
        do {
            _ = try await approveRelayGroupJoin(groupId: groupId, joinRequestId: joinRequestId)
            await syncRelayGroups(for: state.activeIdentityId)
            let requests = try await listRelayGroupJoinRequests(groupId: groupId)
            pendingGroupJoinRequests[groupId] = requests
            lastInfo = "Join request approved."
        } catch {
            lastError = "Failed to approve join request: \(error.localizedDescription)"
        }
    }

    func rejectPendingJoinRequest(groupId: UUID, joinRequestId: UUID) async {
        do {
            try await rejectRelayGroupJoin(groupId: groupId, joinRequestId: joinRequestId)
            let requests = try await listRelayGroupJoinRequests(groupId: groupId)
            pendingGroupJoinRequests[groupId] = requests
            lastInfo = "Join request rejected."
        } catch {
            lastError = "Failed to reject join request: \(error.localizedDescription)"
        }
    }

    func refreshRelayGroups() async {
        await syncRelayGroupsForActiveProfiles()
    }

    func sendGroupMessage(text: String, to groupId: UUID) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        loadGroupMessagesIntoRAM(groupId: groupId)
        guard var group = state.group(for: groupId) else {
            lastError = "Group not found."
            return
        }
        do {
            _ = try await makeGroupAuthenticatedContext(forSending: &group)
        } catch {
            lastError = "Failed to prepare group security context: \(error.localizedDescription)"
            return
        }
        guard group.relayInboxId != nil, group.groupRatchetState != nil else {
            lastError = "This group is missing relay-backed group ratchet state. Refresh the group before sending."
            return
        }
        do {
            try await sendRelayGroupRatchetMessage(trimmed, group: group)
        } catch {
            lastError = "Failed to send group message: \(error.localizedDescription)"
        }
    }

    private func sendRelayGroupRatchetMessage(_ text: String, group: GroupConversation) async throws {
        guard let groupInboxId = group.relayInboxId,
              var ratchetState = group.groupRatchetState else {
            throw RelayGroupRegistryError.invalidResponse
        }
        let envelope = try GroupRatchet.encrypt(
            body: .text(text),
            senderSigningKey: state.identity.signingKey,
            senderFingerprint: state.identity.fingerprint,
            state: &ratchetState
        )
        let response = try await relayClient(for: state.relay).send(
            .deliverGroupMessage(
                DeliverGroupMessageRequest(
                    groupId: group.id,
                    groupInboxId: groupInboxId,
                    envelope: envelope
                )
            )
        )
        guard response.type == .delivered else {
            throw RelayGroupRegistryError.rejected(response.error ?? "Relay rejected group message.")
        }
        var updatedGroup = group
        if updatedGroup.messages.isEmpty {
            updatedGroup.messages = storedGroupMessages(profileId: state.activeIdentityId, groupId: group.id)
        }
        updatedGroup.groupRatchetState = ratchetState
        updatedGroup.messages.append(
            Message(
                id: envelope.id,
                direction: .sent,
                senderDisplayName: state.identity.displayName,
                body: text,
                timestamp: envelope.sentAt,
                counter: envelope.messageCounter
            )
        )
        state.upsert(group: updatedGroup)
        await save()
        lastInfo = "Sent group message."
    }

    private func makeGroupAuthenticatedContext(forSending group: inout GroupConversation) async throws -> MessageAuthenticatedContext {
        if group.relayInboxId != nil,
           let descriptor = try await fetchRelayGroup(groupId: group.id, relay: state.relay) {
            group.title = descriptor.title
            group.memberContactIds = contactIds(for: descriptor.members.map(\.fingerprint))
            group.relayInboxId = descriptor.inboxId
            group.relayEpoch = descriptor.epoch
            group.relayTranscriptHash = descriptor.mlsEpochState.confirmedTranscriptHash
            group.groupRatchetState = groupRatchetState(
                from: descriptor,
                identity: state.identity,
                existing: group.groupRatchetState
            )
            group.createdByFingerprint = descriptor.createdByFingerprint
        }
        guard let epoch = group.relayEpoch,
              let transcriptHash = group.relayTranscriptHash,
              group.relayInboxId != nil,
              group.groupRatchetState != nil else {
            throw RelayGroupRegistryError.invalidResponse
        }
        return .group(
            groupId: group.id,
            epoch: epoch,
            senderFingerprint: state.identity.fingerprint,
            transcriptHash: transcriptHash
        )
    }

    func removeContact(id: UUID) async {
        if let contact = state.contacts.first(where: { $0.id == id }) {
            purgeAttachmentDecryptionMemory(contactId: id)
            try? threadMessageStore.deleteDirectMessages(profileId: state.activeIdentityId, contactId: id)
            recordContinuityEvent(
                kind: .contactRemoved,
                contact: contact,
                oldFingerprint: contact.fingerprint
            )
            state.contacts.removeAll { $0.id == id }
            state.conversations.removeAll { $0.contactId == id }
            for index in state.groups.indices {
                state.groups[index].memberContactIds.removeAll { $0 == id }
            }
            state.groups.removeAll { $0.memberContactIds.count < 2 }
            await save()
            lastInfo = "Removed \(contact.displayName)."
        }
    }

    func deleteMessage(contactId: UUID, messageId: UUID) async {
        loadConversationMessagesIntoRAM(contactId: contactId)
        guard var conversation = state.conversation(for: contactId) else {
            return
        }
        if let message = conversation.messages.first(where: { $0.id == messageId }),
           let fileName = message.attachment?.localFileName {
            decryptedAttachmentCache[fileName]?.wipe()
            decryptedAttachmentCache.removeValue(forKey: fileName)
            decryptedAttachmentScopes.removeValue(forKey: fileName)
            try? attachmentStore.deleteAttachment(fileName: fileName)
        }
        conversation.messages.removeAll { $0.id == messageId }
        state.upsert(conversation: conversation)
        await save()
    }

    func clearConversation(contactId: UUID) async {
        loadConversationMessagesIntoRAM(contactId: contactId)
        guard var conversation = state.conversation(for: contactId) else {
            return
        }
        purgeAttachmentDecryptionMemory(contactId: contactId)
        for message in conversation.messages {
            if let fileName = message.attachment?.localFileName {
                try? attachmentStore.deleteAttachment(fileName: fileName)
            }
        }
        conversation.messages.removeAll()
        conversation.unreadCount = 0
        try? threadMessageStore.deleteDirectMessages(profileId: state.activeIdentityId, contactId: contactId)
        state.upsert(conversation: conversation)
        await save()
    }

    func deleteGroupMessage(groupId: UUID, messageId: UUID) async {
        loadGroupMessagesIntoRAM(groupId: groupId)
        guard var group = state.group(for: groupId) else {
            return
        }
        if let message = group.messages.first(where: { $0.id == messageId }),
           let fileName = message.attachment?.localFileName {
            decryptedAttachmentCache[fileName]?.wipe()
            decryptedAttachmentCache.removeValue(forKey: fileName)
            decryptedAttachmentScopes.removeValue(forKey: fileName)
            try? attachmentStore.deleteAttachment(fileName: fileName)
        }
        group.messages.removeAll { $0.id == messageId }
        state.upsert(group: group)
        await save()
    }

    func clearGroupConversation(groupId: UUID) async {
        loadGroupMessagesIntoRAM(groupId: groupId)
        guard var group = state.group(for: groupId) else {
            return
        }
        purgeAttachmentDecryptionMemory(groupId: groupId)
        group.messages.removeAll()
        group.unreadCount = 0
        try? threadMessageStore.deleteGroupMessages(profileId: state.activeIdentityId, groupId: groupId)
        state.upsert(group: group)
        await save()
    }

    func clearAllChats() async {
        guard !state.conversations.isEmpty || !state.groups.isEmpty else { return }
        purgeAllAttachmentDecryptionMemory()
        var updated: [Conversation] = []
        updated.reserveCapacity(state.conversations.count)
        for conversation in state.conversations {
            var cleared = conversation
            let messagesToDelete = cleared.messages.isEmpty
                ? storedDirectMessages(profileId: state.activeIdentityId, contactId: cleared.contactId)
                : cleared.messages
            for message in messagesToDelete {
                if let fileName = message.attachment?.localFileName {
                    try? attachmentStore.deleteAttachment(fileName: fileName)
                }
            }
            cleared.messages.removeAll()
            cleared.unreadCount = 0
            try? threadMessageStore.deleteDirectMessages(
                profileId: state.activeIdentityId,
                contactId: cleared.contactId
            )
            updated.append(cleared)
        }
        state.conversations = updated
        for index in state.groups.indices {
            let groupId = state.groups[index].id
            let messagesToDelete = state.groups[index].messages.isEmpty
                ? storedGroupMessages(profileId: state.activeIdentityId, groupId: groupId)
                : state.groups[index].messages
            for message in messagesToDelete {
                if let fileName = message.attachment?.localFileName {
                    try? attachmentStore.deleteAttachment(fileName: fileName)
                }
            }
            try? threadMessageStore.deleteGroupMessages(profileId: state.activeIdentityId, groupId: groupId)
            state.groups[index].messages.removeAll()
            state.groups[index].unreadCount = 0
        }
        await save()
        lastInfo = "Cleared all chats."
    }

    func updateInsecurePairing(_ settings: InsecurePairingSettings) async {
        var updated = settings
        if updated.isEnabled {
            updated.method = .relay
        } else if updated.method == nil {
            updated.method = .relay
        }
        state.insecurePairing = updated
        await save()
        if !updated.isReady {
            insecureAnnouncements = []
            insecureRequests = []
            insecureLastAnnounceAt = nil
            insecureLastListAt = nil
            insecureLastRequestFetchAt = nil
            insecureLastPeerCount = 0
            insecureLastRequestCount = 0
            insecureLastError = nil
            insecureLastRelay = nil
            insecureLastSelfTestAt = nil
            insecureLastSelfTestResult = nil
            pendingOutboundPairRequestFingerprints.removeAll()
        } else {
            await refreshInsecurePairing()
        }
    }

    func refreshInsecurePairing() async {
        guard state.insecurePairing.isReady else {
            return
        }
        guard let relay = relayForInsecurePairing() else {
            return
        }
        do {
            insecureLastRelay = relay
            insecureLastError = nil
            let offer = try MessageEngine.makeContactOffer(
                identity: state.identity,
                inboxId: state.inboxId,
                relay: relay,
                inboxAccessPublicKey: state.inboxAccessKey?.publicKeyData
            )
            let announceResponse = try await relayClient(for: relay).send(.announce(AnnounceRequest(offer: offer, ttlSeconds: 120)))
            if announceResponse.type == .error, let error = announceResponse.error {
                let message = "Relay pairing announce failed: \(error)"
                lastError = message
                insecureLastError = message
            } else {
                insecureLastAnnounceAt = Date()
            }
            let announcementsResponse = try await relayClient(for: relay).send(.listAnnouncements(ListAnnouncementsRequest(limit: 50)))
            if announcementsResponse.type == .announcements {
                insecureAnnouncements = (announcementsResponse.announcements ?? [])
                    .filter { announcement in
                        guard announcement.offer.fingerprint != state.identity.fingerprint else {
                            return false
                        }
                        return (try? announcement.offer.verified()) != nil
                    }
                insecureLastPeerCount = insecureAnnouncements.count
                insecureLastListAt = Date()
            } else if announcementsResponse.type == .error, let error = announcementsResponse.error {
                let message = "Relay pairing list failed: \(error)"
                lastError = message
                insecureLastError = message
            }
            if state.insecurePairing.allowInboundRequests || !pendingOutboundPairRequestFingerprints.isEmpty {
                let fetch = try makeFetchPairRequestsRequest(maxCount: 50)
                let requestsResponse = try await relayClient(for: relay).send(.fetchPairRequests(fetch))
                if requestsResponse.type == .pairRequests {
                    let fetchedRequests = (requestsResponse.pairRequests ?? []).filter { request in
                        (try? request.from.verified()) != nil
                    }
                    let remainingRequests = await autoAcceptMatchingPairRequests(fetchedRequests)
                    if state.insecurePairing.allowInboundRequests {
                        insecureRequests = remainingRequests
                    } else {
                        insecureRequests = []
                    }
                    insecureLastRequestCount = insecureRequests.count
                    insecureLastRequestFetchAt = Date()
                } else if requestsResponse.type == .error, let error = requestsResponse.error {
                    let message = "Relay pairing fetch failed: \(error)"
                    lastError = message
                    insecureLastError = message
                }
            }
        } catch {
            let message = "Relay pairing failed: \(error.localizedDescription)"
            lastError = message
            insecureLastError = message
        }
    }

    func announceInsecurePairing() async {
        guard state.insecurePairing.isReady else { return }
        guard let relay = relayForInsecurePairing() else { return }
        do {
            insecureLastRelay = relay
            insecureLastError = nil
            let offer = try MessageEngine.makeContactOffer(
                identity: state.identity,
                inboxId: state.inboxId,
                relay: relay,
                inboxAccessPublicKey: state.inboxAccessKey?.publicKeyData
            )
            let response = try await relayClient(for: relay).send(.announce(AnnounceRequest(offer: offer, ttlSeconds: 120)))
            if response.type == .error, let error = response.error {
                let message = "Relay pairing announce failed: \(error)"
                lastError = message
                insecureLastError = message
            } else {
                insecureLastAnnounceAt = Date()
            }
        } catch {
            let message = "Relay pairing announce failed: \(error.localizedDescription)"
            lastError = message
            insecureLastError = message
        }
    }

    func runInsecurePairingSelfTest() async {
        let token = UUID()
        insecureSelfTestToken = token
        insecureLastSelfTestAt = Date()
        insecureLastSelfTestResult = "Running..."
        insecureSelfTestStep = "Starting"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            await self?.checkSelfTestTimeout(token: token)
        }
        guard state.insecurePairing.isReady else {
            let message = "Enable pairing via relay first."
            lastError = message
            insecureLastError = message
            insecureLastSelfTestResult = message
            insecureSelfTestStep = nil
            insecureSelfTestToken = nil
            return
        }
        guard let relay = relayForInsecurePairing() else {
            let message = "Relay unavailable for pairing via relay."
            lastError = message
            insecureLastError = message
            insecureLastSelfTestResult = message
            insecureSelfTestStep = nil
            insecureSelfTestToken = nil
            return
        }
        do {
            insecureLastRelay = relay
            insecureLastError = nil
            insecureSelfTestStep = "Announce"
            let offer = try MessageEngine.makeContactOffer(
                identity: state.identity,
                inboxId: state.inboxId,
                relay: relay,
                inboxAccessPublicKey: state.inboxAccessKey?.publicKeyData
            )
            let announceResponse = try await relayClient(for: relay)
                .send(.announce(AnnounceRequest(offer: offer, ttlSeconds: 120)))
            if announceResponse.type == .error, let error = announceResponse.error {
                throw InsecureSelfTestFailure(message: "Announce error: \(error)")
            }
            guard announceResponse.type == .announcements,
                  let announced = announceResponse.announcements,
                  announced.contains(where: { $0.offer.fingerprint == state.identity.fingerprint }) else {
                throw InsecureSelfTestFailure(message: "Announce did not return this device.")
            }
            insecureLastAnnounceAt = Date()

            insecureSelfTestStep = "List"
            let listResponse = try await relayClient(for: relay)
                .send(.listAnnouncements(ListAnnouncementsRequest(limit: 50)))
            if listResponse.type == .error, let error = listResponse.error {
                throw InsecureSelfTestFailure(message: "List error: \(error)")
            }
            guard listResponse.type == .announcements else {
                throw InsecureSelfTestFailure(message: "List failed with \(listResponse.type).")
            }
            let listed = (listResponse.announcements ?? []).filter { (try? $0.offer.verified()) != nil }
            let hasSelf = listed.contains(where: { $0.offer.fingerprint == state.identity.fingerprint })
            guard hasSelf else {
                throw InsecureSelfTestFailure(message: "List did not include this device.")
            }
            insecureLastListAt = Date()
            insecureLastPeerCount = listed.filter { $0.offer.fingerprint != state.identity.fingerprint }.count

            insecureSelfTestStep = "Pair request"
            let pairResponse = try await relayClient(for: relay)
                .send(.sendPairRequest(try makeSendPairRequest(
                    targetFingerprint: state.identity.fingerprint,
                    offer: offer
                )))
            if pairResponse.type == .error, let error = pairResponse.error {
                throw InsecureSelfTestFailure(message: "Pair request error: \(error)")
            }
            guard pairResponse.type == .ok else {
                throw InsecureSelfTestFailure(message: "Pair request failed with \(pairResponse.type).")
            }

            insecureSelfTestStep = "Fetch requests"
            let fetchRequest = try makeFetchPairRequestsRequest(maxCount: 5)
            let fetchResponse = try await relayClient(for: relay)
                .send(.fetchPairRequests(fetchRequest))
            if fetchResponse.type == .error, let error = fetchResponse.error {
                throw InsecureSelfTestFailure(message: "Fetch error: \(error)")
            }
            guard fetchResponse.type == .pairRequests else {
                throw InsecureSelfTestFailure(message: "Fetch failed with \(fetchResponse.type).")
            }
            let requests = (fetchResponse.pairRequests ?? []).filter { (try? $0.from.verified()) != nil }
            guard requests.contains(where: { $0.from.fingerprint == state.identity.fingerprint }) else {
                throw InsecureSelfTestFailure(message: "Fetch did not return the test request.")
            }
            insecureLastRequestFetchAt = Date()
            insecureLastRequestCount = requests.count

            insecureLastSelfTestAt = Date()
            insecureLastSelfTestResult = "OK"
            lastInfo = "Relay pairing self-test passed."
            insecureSelfTestStep = nil
            insecureSelfTestToken = nil
        } catch {
            let message = "Self-test failed: \(error.localizedDescription)"
            lastError = message
            insecureLastError = message
            insecureLastSelfTestResult = message
            insecureSelfTestStep = nil
            insecureSelfTestToken = nil
        }
    }

    private func checkSelfTestTimeout(token: UUID) async {
        guard insecureSelfTestToken == token,
              insecureLastSelfTestResult == "Running..." else {
            return
        }
        let message = "Self-test failed: Relay request timed out."
        lastError = message
        insecureLastError = message
        insecureLastSelfTestResult = message
        insecureSelfTestStep = nil
        insecureSelfTestToken = nil
    }

    func sendPairRequest(to announcement: PairingAnnouncement) async {
        guard let relay = relayForInsecurePairing() else {
            lastError = "Relay unavailable for pairing via relay."
            return
        }
        do {
            _ = try announcement.offer.verified()
            let offer = try MessageEngine.makeContactOffer(
                identity: state.identity,
                inboxId: state.inboxId,
                relay: relay,
                inboxAccessPublicKey: state.inboxAccessKey?.publicKeyData
            )
            let request = try makeSendPairRequest(
                targetFingerprint: announcement.offer.fingerprint,
                offer: offer
            )
            let response = try await relayClient(for: relay).send(.sendPairRequest(request))
            if response.type == .error, let error = response.error {
                throw NSError(domain: "Noctyra.InsecurePairing", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
            }
            guard response.type == .ok else {
                throw NSError(
                    domain: "Noctyra.InsecurePairing",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Relay rejected pair request (\(response.type))."]
                )
            }
            pendingOutboundPairRequestFingerprints.insert(announcement.offer.fingerprint)
            lastInfo = "Pairing request sent to \(announcement.offer.displayName)."
        } catch {
            lastError = "Failed to send pairing request: \(error.localizedDescription)"
        }
    }

    func acceptPairRequest(_ request: PairingRequest) async {
        await acceptPairRequest(request, sendReciprocalRequest: true, automatic: false)
    }

    func dismissPairRequest(_ request: PairingRequest) {
        insecureRequests.removeAll { $0.id == request.id }
    }

    private func autoAcceptMatchingPairRequests(_ requests: [PairingRequest]) async -> [PairingRequest] {
        var remaining: [PairingRequest] = []
        var autoAcceptedNames: [String] = []
        for request in requests {
            if pendingOutboundPairRequestFingerprints.contains(request.from.fingerprint) {
                await acceptPairRequest(request, sendReciprocalRequest: false, automatic: true)
                autoAcceptedNames.append(request.from.displayName)
            } else {
                remaining.append(request)
            }
        }
        if !autoAcceptedNames.isEmpty {
            lastInfo = "Pairing completed with \(autoAcceptedNames.joined(separator: ", "))."
        }
        return remaining
    }

    private func acceptPairRequest(
        _ request: PairingRequest,
        sendReciprocalRequest: Bool,
        automatic: Bool
    ) async {
        let contact: Contact
        do {
            contact = try validatedContact(from: request.from)
        } catch {
            insecureRequests.removeAll { $0.id == request.id }
            lastError = "Rejected pairing request: \(error.localizedDescription)"
            insecureLastError = lastError
            return
        }
        let wasKnown = state.contacts.contains { existing in
            existing.fingerprint == contact.fingerprint || contactAddressKey(for: existing) == contactAddressKey(for: contact)
        }
        state.upsert(contact: contact)
        if !wasKnown {
            recordContinuityEvent(
                kind: .contactAdded,
                contact: contact,
                newFingerprint: contact.fingerprint
            )
        }
        insecureRequests.removeAll { $0.id == request.id }
        pendingOutboundPairRequestFingerprints.remove(request.from.fingerprint)

        var reciprocalError: String?
        if sendReciprocalRequest {
            if let relay = relayForInsecurePairing() {
                do {
                    let offer = try MessageEngine.makeContactOffer(
                        identity: state.identity,
                        inboxId: state.inboxId,
                        relay: relay,
                        inboxAccessPublicKey: state.inboxAccessKey?.publicKeyData
                    )
                    let requestPayload = try makeSendPairRequest(
                        targetFingerprint: request.from.fingerprint,
                        offer: offer
                    )
                    let response = try await relayClient(for: relay).send(.sendPairRequest(requestPayload))
                    if response.type == .error {
                        reciprocalError = response.error ?? "Relay rejected reciprocal pairing request."
                    } else if response.type != .ok {
                        reciprocalError = "Relay rejected reciprocal pairing request (\(response.type))."
                    }
                } catch {
                    reciprocalError = error.localizedDescription
                }
            } else {
                reciprocalError = "Relay unavailable to send pairing acceptance."
            }
        }

        await save()
        if let reciprocalError {
            lastError = "Accepted \(contact.displayName), but failed to notify requester: \(reciprocalError)"
        } else if !automatic {
            lastInfo = "Added \(contact.displayName). Pairing completed."
        }
    }

    func retryMismatch(contactId: UUID) async {
        guard let contact = state.contacts.first(where: { $0.id == contactId }) else {
            return
        }
        loadConversationMessagesIntoRAM(contactId: contactId)
        guard let conversation = state.conversation(for: contactId) else {
            return
        }
        do {
            let rebuilt = try await SessionRecovery.sendSessionResetAndResendRequest(
                identity: state.identity,
                contact: contact,
                existingConversation: conversation,
                preferredRelay: state.relay,
                resendCount: resendRequestCount,
                preferredRelayAuthToken: relayAuthToken(for: state.relay),
                destinationRelayAuthToken: relayAuthToken(for: contact.relay)
            )
            state.upsert(conversation: rebuilt)
            await save()
        } catch {
            lastError = "Retry failed: \(error.localizedDescription)"
        }
    }

    func loadAttachmentData(fileName: String) async -> Data? {
        if let cached = decryptedAttachmentCache[fileName] {
            return cached.snapshot()
        }
        do {
            var encrypted = try attachmentStore.loadEncryptedAttachment(fileName: fileName)
            var decrypted = try attachmentStore.decryptAttachmentPayload(encrypted)
            encrypted.secureWipe()
            let buffer = SecureRAMBuffer(copying: decrypted)
            decrypted.secureWipe()
            cacheAttachmentBuffer(buffer, for: fileName, scope: currentAttachmentCacheScope())
            return buffer.snapshot()
        } catch {
            print("[client] Failed to load attachment: \(error)")
            return nil
        }
    }

    func purgeAttachmentDecryptionMemory(contactId: UUID) {
        purgeAttachmentDecryptionMemory(scopes: [.contact(contactId)])
    }

    func purgeAttachmentDecryptionMemory(groupId: UUID) {
        purgeAttachmentDecryptionMemory(scopes: [.group(groupId)])
    }

    func purgeAllAttachmentDecryptionMemory() {
        for buffer in decryptedAttachmentCache.values {
            buffer.wipe()
        }
        decryptedAttachmentCache.removeAll()
        decryptedAttachmentScopes.removeAll()
    }

    private func cacheAttachmentBuffer(_ buffer: SecureRAMBuffer, for fileName: String, scope: AttachmentCacheScope) {
        if let existing = decryptedAttachmentCache[fileName] {
            existing.wipe()
        }
        decryptedAttachmentCache[fileName] = buffer
        decryptedAttachmentScopes[fileName] = scope
    }

    private func currentAttachmentCacheScope() -> AttachmentCacheScope {
        if let activeContactId {
            return .contact(activeContactId)
        }
        if let activeGroupId {
            return .group(activeGroupId)
        }
        return .transient
    }

    private func purgeAttachmentDecryptionMemory(scopes: Set<AttachmentCacheScope>) {
        guard !scopes.isEmpty else { return }
        let fileNamesToPurge = decryptedAttachmentScopes.compactMap { fileName, scope in
            scopes.contains(scope) ? fileName : nil
        }
        for fileName in fileNamesToPurge {
            decryptedAttachmentCache[fileName]?.wipe()
            decryptedAttachmentCache.removeValue(forKey: fileName)
            decryptedAttachmentScopes.removeValue(forKey: fileName)
        }
    }

    private func downloadAttachment(
        descriptor: AttachmentDescriptor,
        contact: Contact,
        conversationId: String,
        sessionId: String,
        messageCounter: UInt64,
        messageKey: SymmetricKey
    ) async throws -> String? {
        try validateInboundAttachmentDescriptor(descriptor)
        let client = relayClient(for: contact.relay)
        var data = Data()
        data.reserveCapacity(descriptor.byteCount)
        for chunkIndex in 0..<descriptor.chunkCount {
            let response = try await client.send(.fetchAttachment(FetchAttachmentRequest(
                attachmentId: descriptor.id,
                chunkIndex: chunkIndex
            )))
            guard response.type == .attachment, let chunk = response.attachment else {
                throw AttachmentTransferError.missingChunk(chunkIndex)
            }
            let expectedCount = min(
                descriptor.chunkSize,
                max(0, descriptor.byteCount - (chunkIndex * descriptor.chunkSize))
            )
            let authenticatedData = AttachmentCrypto.authenticatedData(
                conversationId: conversationId,
                sessionId: sessionId,
                messageCounter: messageCounter,
                attachmentId: descriptor.id,
                chunkIndex: chunkIndex,
                byteCount: expectedCount
            )
            let plaintext = try AttachmentCrypto.decryptChunk(
                payload: chunk.payload,
                messageKey: messageKey,
                attachmentId: descriptor.id,
                chunkIndex: chunkIndex,
                authenticatedData: authenticatedData
            )
            guard plaintext.count == expectedCount else {
                throw AttachmentTransferError.invalidChunkSize
            }
            data.append(plaintext)
        }
        guard data.count == descriptor.byteCount else {
            throw AttachmentTransferError.invalidSize
        }
        guard detectSupportedImageFormat(data) != nil else {
            throw AttachmentTransferError.unsupportedType
        }
        guard AttachmentCrypto.sha256(data) == descriptor.sha256 else {
            throw AttachmentTransferError.invalidChecksum
        }
        return try attachmentStore.saveAttachment(data, descriptor: descriptor)
    }

    private func downloadGroupAttachment(
        descriptor: AttachmentDescriptor,
        groupId: UUID,
        epoch: UInt64,
        transcriptHash: Data,
        messageCounter: UInt64,
        messageKey: SymmetricKey,
        relay: RelayEndpoint
    ) async throws -> String? {
        try validateInboundAttachmentDescriptor(descriptor)
        let client = relayClient(for: relay)
        var data = Data()
        data.reserveCapacity(descriptor.byteCount)
        for chunkIndex in 0..<descriptor.chunkCount {
            let response = try await client.send(.fetchAttachment(FetchAttachmentRequest(
                attachmentId: descriptor.id,
                chunkIndex: chunkIndex
            )))
            guard response.type == .attachment, let chunk = response.attachment else {
                throw AttachmentTransferError.missingChunk(chunkIndex)
            }
            let expectedCount = min(
                descriptor.chunkSize,
                max(0, descriptor.byteCount - (chunkIndex * descriptor.chunkSize))
            )
            let authenticatedData = groupAttachmentAuthenticatedData(
                groupId: groupId,
                epoch: epoch,
                transcriptHash: transcriptHash,
                messageCounter: messageCounter,
                attachmentId: descriptor.id,
                chunkIndex: chunkIndex,
                byteCount: expectedCount
            )
            let plaintext = try AttachmentCrypto.decryptChunk(
                payload: chunk.payload,
                messageKey: messageKey,
                attachmentId: descriptor.id,
                chunkIndex: chunkIndex,
                authenticatedData: authenticatedData
            )
            guard plaintext.count == expectedCount else {
                throw AttachmentTransferError.invalidChunkSize
            }
            data.append(plaintext)
        }
        guard data.count == descriptor.byteCount else {
            throw AttachmentTransferError.invalidSize
        }
        guard AttachmentCrypto.sha256(data) == descriptor.sha256 else {
            throw AttachmentTransferError.invalidChecksum
        }
        return try attachmentStore.saveAttachment(data, descriptor: descriptor)
    }

    private func groupAttachmentAuthenticatedData(
        groupId: UUID,
        epoch: UInt64,
        transcriptHash: Data,
        messageCounter: UInt64,
        attachmentId: UUID,
        chunkIndex: Int,
        byteCount: Int
    ) -> Data {
        AttachmentCrypto.authenticatedData(
            conversationId: "group:\(groupId.uuidString)",
            sessionId: groupAttachmentSessionId(epoch: epoch, transcriptHash: transcriptHash),
            messageCounter: messageCounter,
            attachmentId: attachmentId,
            chunkIndex: chunkIndex,
            byteCount: byteCount
        )
    }

    private func groupAttachmentSessionId(epoch: UInt64, transcriptHash: Data) -> String {
        "epoch:\(epoch):\(transcriptHash.base64EncodedString())"
    }

    func addRelayServer(
        name: String,
        endpoint: RelayEndpoint,
        note: String? = nil,
        relayPassword: String? = nil,
        origin: RelayServerOrigin = .manual,
        sourceId: UUID? = nil
    ) async {
        if let index = state.relayServers.firstIndex(where: { $0.endpoint == endpoint }) {
            state.relayServers[index].name = name
            state.relayServers[index].note = note
            state.relayServers[index].relayPassword = relayPassword
            state.relayServers[index].origin = origin
            state.relayServers[index].sourceId = sourceId
        } else {
            state.relayServers.append(
                RelayServerRecord(
                    name: name,
                    endpoint: endpoint,
                    note: note,
                    relayPassword: relayPassword,
                    origin: origin,
                    sourceId: sourceId
                )
            )
        }
        if state.selectedRelayId == nil, let first = state.relayServers.first {
            state.selectedRelayId = first.id
            state.relay = first.endpoint
        }
        await save()
    }

    func updateRelayServer(
        id: UUID,
        name: String,
        endpoint: RelayEndpoint,
        note: String?,
        relayPassword: String?
    ) async {
        if state.relayServers.contains(where: { $0.id != id && $0.endpoint == endpoint }) {
            lastError = "That relay already exists."
            return
        }
        guard let index = state.relayServers.firstIndex(where: { $0.id == id }) else {
            lastError = "Relay server not found."
            return
        }
        let oldEndpoint = state.relayServers[index].endpoint
        state.relayServers[index].name = name
        state.relayServers[index].endpoint = endpoint
        state.relayServers[index].note = note
        state.relayServers[index].relayPassword = relayPassword
        if oldEndpoint != endpoint {
            state.relayServers[index].advertisedInfo = nil
            state.relayServers[index].lastInfoFetchedAt = nil
            relayHealth[id] = nil
        }
        if state.relayServers[index].origin == .master {
            state.relayServers[index].origin = .manual
            state.relayServers[index].sourceId = nil
        }
        if state.selectedRelayId == id {
            state.relay = endpoint
        }
        await save()
    }

    func removeRelayServer(id: UUID) async {
        state.relayServers.removeAll { $0.id == id }
        relayHealth[id] = nil
        if state.selectedRelayId == id {
            if let first = state.relayServers.first {
                state.selectedRelayId = first.id
                state.relay = first.endpoint
            } else {
                state.selectedRelayId = nil
            }
        }
        await save()
    }

    func selectRelayServer(id: UUID) async {
        guard let index = state.relayServers.firstIndex(where: { $0.id == id }) else {
            lastError = "Relay server not found."
            return
        }
        let endpoint = state.relayServers[index].endpoint
        do {
            let info = try await loadRelayInfo(endpoint: endpoint)
            if info.kind == .coordinator {
                lastError = "Coordinator nodes cannot be selected as a home relay."
                return
            }
            if let policy = state.federationPolicy,
               !isFederationCompatible(policy: policy, info: info.federation) {
                lastError = federationMismatchMessage(policy: policy, info: info.federation)
                return
            }
            state.relayServers[index].advertisedInfo = info
            state.relayServers[index].lastInfoFetchedAt = Date()
            if state.federationPolicy == nil {
                state.federationPolicy = info.federation
            }
            state.selectedRelayId = state.relayServers[index].id
            state.relay = endpoint
            await save()
            await refreshCoordinatorDirectoryIfNeeded(force: true)
            await syncRelayGroups(for: state.activeIdentityId)
        } catch {
            lastError = "Relay info fetch failed: \(error.localizedDescription)"
        }
    }

    func testSelectedRelay() async {
        let endpoint = state.relay
        let start = DispatchTime.now()
        do {
            let client = relayClient(for: endpoint)
            let response = try await client.send(.health())
            if response.type == .ok {
                recordRelayHealth(endpoint: endpoint, latencyMs: elapsedMilliseconds(since: start), isReachable: true, failureReason: nil)
                lastInfo = "Relay \(endpoint.host):\(endpoint.port) is reachable."
                if let selected = state.selectedRelayId {
                    await fetchRelayInfo(id: selected)
                }
                await refreshCoordinatorDirectoryIfNeeded(force: true)
            } else if let error = response.error {
                recordRelayHealth(endpoint: endpoint, latencyMs: elapsedMilliseconds(since: start), isReachable: false, failureReason: error)
                lastError = "Relay error: \(error)"
            } else {
                recordRelayHealth(endpoint: endpoint, latencyMs: elapsedMilliseconds(since: start), isReachable: false, failureReason: "Unexpected response type")
                lastError = "Relay returned unexpected response."
            }
        } catch {
            recordRelayHealth(endpoint: endpoint, latencyMs: elapsedMilliseconds(since: start), isReachable: false, failureReason: error.localizedDescription)
            lastError = "Relay connection failed: \(error.localizedDescription)"
        }
    }

    func fetchRelayInfo(id: UUID) async {
        guard let index = state.relayServers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let endpoint = state.relayServers[index].endpoint
        do {
            let info = try await loadRelayInfo(endpoint: endpoint)
            if let policy = state.federationPolicy,
               !isFederationCompatible(policy: policy, info: info.federation) {
                lastError = federationMismatchMessage(policy: policy, info: info.federation)
                return
            }
            state.relayServers[index].advertisedInfo = info
            state.relayServers[index].lastInfoFetchedAt = Date()
            if state.federationPolicy == nil {
                state.federationPolicy = info.federation
            }
            await save()
            await refreshCoordinatorDirectoryIfNeeded(force: true)
        } catch {
            lastError = "Relay info fetch failed: \(error.localizedDescription)"
        }
    }

    func addMasterSource(name: String, url: String) async {
        guard let parsedURL = URL(string: url),
              parsedURL.scheme?.lowercased() == "https",
              parsedURL.host?.isEmpty == false else {
            lastError = "Master sources must use a valid HTTPS URL."
            return
        }
        state.masterServerSources.append(MasterServerSource(name: name, url: parsedURL.absoluteString))
        await save()
    }

    func removeMasterSource(id: UUID) async {
        state.masterServerSources.removeAll { $0.id == id }
        await save()
    }

    func setMasterSourceEnabled(id: UUID, isEnabled: Bool) async {
        guard let index = state.masterServerSources.firstIndex(where: { $0.id == id }) else {
            return
        }
        state.masterServerSources[index].isEnabled = isEnabled
        await save()
    }

    func fetchMasterSources() async {
        for source in state.masterServerSources where source.isEnabled {
            await fetchMasterSource(source)
        }
    }

    func fetchMasterSource(_ source: MasterServerSource) async {
        guard let url = URL(string: source.url),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else {
            lastError = "Master sources must use a valid HTTPS URL."
            return
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                throw MasterSourceError.invalidHTTPResponse
            }
            guard data.count <= 1_000_000 else {
                throw MasterSourceError.responseTooLarge
            }
            let records = try parseMasterServerData(data, sourceId: source.id)
            mergeMasterServers(records)
            if let index = state.masterServerSources.firstIndex(where: { $0.id == source.id }) {
                state.masterServerSources[index].lastFetchedAt = Date()
            }
            await save()
            lastInfo = "Fetched \(records.count) servers from \(source.name)."
        } catch {
            lastError = "Failed to fetch master servers: \(error.localizedDescription)"
        }
    }

    private enum MasterSourceError: LocalizedError {
        case invalidHTTPResponse
        case responseTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidHTTPResponse:
                return "Master source returned an invalid HTTP response."
            case .responseTooLarge:
                return "Master source exceeds the 1 MB limit."
            }
        }
    }

    private func ensureRelaySelection() async {
        var didChange = false
        if state.relayServers.isEmpty {
            let defaultServer = RelayServerRecord(name: "Current Relay", endpoint: state.relay)
            state.relayServers = [defaultServer]
            state.selectedRelayId = defaultServer.id
            didChange = true
        }

        if let selectedId = state.selectedRelayId,
           let selected = state.relayServers.first(where: { $0.id == selectedId }) {
            if state.relay != selected.endpoint {
                state.relay = selected.endpoint
                didChange = true
            }
        } else if let match = state.relayServers.first(where: { $0.endpoint == state.relay }) {
            state.selectedRelayId = match.id
            didChange = true
        } else if let first = state.relayServers.first {
            state.selectedRelayId = first.id
            state.relay = first.endpoint
            didChange = true
        }

        if didChange {
            await save()
        }
    }

    private func parseMasterServerData(_ data: Data, sourceId: UUID) throws -> [RelayServerRecord] {
        if let entries = try? PICCPCoder.decode([MasterServerEntry].self, from: data) {
            return entries.map { RelayServerRecord(entry: $0, sourceId: sourceId) }
        }

        if let list = try? PICCPCoder.decode(MasterServerList.self, from: data) {
            return list.servers.map { RelayServerRecord(entry: $0, sourceId: sourceId) }
        }

        if let text = String(data: data, encoding: .utf8) {
            let lines = text.split(whereSeparator: \.isNewline)
            var records: [RelayServerRecord] = []
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let parts = trimmed.split(separator: ",", maxSplits: 19, omittingEmptySubsequences: false)
                let hostPort = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let name = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
                let region = parts.count > 2 ? String(parts[2]).trimmingCharacters(in: .whitespaces) : nil
                let tags = parts.count > 3 ? parseTags(String(parts[3])) : nil
                let website = parts.count > 4 ? String(parts[4]).trimmingCharacters(in: .whitespaces) : nil
                let note = parts.count > 5 ? String(parts[5]).trimmingCharacters(in: .whitespaces) : nil
                let relayKind = parts.count > 6 ? parseRelayKind(String(parts[6])) : nil
                let federationMode = parts.count > 7 ? parseFederationMode(String(parts[7])) : nil
                let federationName = parts.count > 8 ? String(parts[8]).trimmingCharacters(in: .whitespaces) : nil
                let federationDescription = parts.count > 9 ? String(parts[9]).trimmingCharacters(in: .whitespaces) : nil
                let temporalBucketSeconds = parts.count > 10 ? parseBucketSeconds(String(parts[10])) : nil
                let operatorNote = parts.count > 11 ? String(parts[11]).trimmingCharacters(in: .whitespaces) : nil
                let softwareVersion = parts.count > 12 ? String(parts[12]).trimmingCharacters(in: .whitespaces) : nil
                let groupCreationMode = parts.count > 13 ? parseGroupCreationMode(String(parts[13])) : nil
                let requiresPassword = parts.count > 14 ? parseBool(String(parts[14])) : nil
                let tlsFlag = parts.count > 15 ? parseBool(String(parts[15])) : nil
                let curatedStrictPolicyEnabled = parts.count > 16 ? parseBool(String(parts[16])) : nil
                let curatedCoordinatorQuorum = parts.count > 17 ? parsePositiveInt(String(parts[17])) : nil
                let curatedRequireSignedDirectory = parts.count > 18 ? parseBool(String(parts[18])) : nil
                let transport = parts.count > 19 ? parseRelayTransport(String(parts[19])) : nil
                guard let parsedEndpoint = parseHostPort(hostPort) else { continue }
                let entry = MasterServerEntry(
                    name: name?.isEmpty == true ? nil : name,
                    host: parsedEndpoint.host,
                    port: parsedEndpoint.port,
                    note: note?.isEmpty == true ? nil : note,
                    region: region?.isEmpty == true ? nil : region,
                    tags: tags,
                    website: website?.isEmpty == true ? nil : website,
                    relayKind: relayKind,
                    federationMode: federationMode,
                    federationName: federationName?.isEmpty == true ? nil : federationName,
                    federationDescription: federationDescription?.isEmpty == true ? nil : federationDescription,
                    temporalBucketSeconds: temporalBucketSeconds,
                    operatorNote: operatorNote?.isEmpty == true ? nil : operatorNote,
                    softwareVersion: softwareVersion?.isEmpty == true ? nil : softwareVersion,
                    groupCreationMode: groupCreationMode,
                    requiresPassword: requiresPassword,
                    useTLS: tlsFlag ?? parsedEndpoint.useTLS,
                    transport: transport ?? parsedEndpoint.transport,
                    curatedStrictPolicyEnabled: curatedStrictPolicyEnabled,
                    curatedCoordinatorQuorum: curatedCoordinatorQuorum,
                    curatedRequireSignedDirectory: curatedRequireSignedDirectory
                )
                records.append(RelayServerRecord(entry: entry, sourceId: sourceId))
            }
            if !records.isEmpty {
                return records
            }
        }

        throw CryptoError.invalidPayload
    }

    private func parseHostPort(_ value: String) -> RelayEndpoint? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let components = URLComponents(string: trimmed), let scheme = components.scheme, !scheme.isEmpty {
            guard let host = components.host else { return nil }
            let loweredScheme = scheme.lowercased()
            let defaultPort: Int
            switch loweredScheme {
            case "https", "wss":
                defaultPort = 443
            case "http", "ws":
                defaultPort = 80
            default:
                defaultPort = 9339
            }
            guard let port = UInt16(exactly: components.port ?? defaultPort) else { return nil }
            switch loweredScheme {
            case "https":
                return RelayEndpoint(host: host, port: port, useTLS: true, transport: .http)
            case "http":
                return RelayEndpoint(host: host, port: port, useTLS: false, transport: .http)
            case "wss":
                return RelayEndpoint(host: host, port: port, useTLS: true, transport: .websocket)
            case "ws":
                return RelayEndpoint(host: host, port: port, useTLS: false, transport: .websocket)
            case "tls":
                return RelayEndpoint(host: host, port: port, useTLS: true, transport: .tcp)
            case "tcp":
                return RelayEndpoint(host: host, port: port, useTLS: false, transport: .tcp)
            default:
                return RelayEndpoint(host: host, port: port, useTLS: false, transport: .tcp)
            }
        }
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let remainder = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard remainder.hasPrefix(":"),
                  let port = UInt16(remainder.dropFirst()) else {
                return nil
            }
            return RelayEndpoint(host: host, port: port, useTLS: false, transport: .tcp)
        }
        let parts = trimmed.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            return nil
        }
        let host = String(parts[0])
        return host.isEmpty ? nil : RelayEndpoint(host: host, port: port, useTLS: false, transport: .tcp)
    }

    private func parseTags(_ value: String) -> [String]? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(whereSeparator: { $0 == "|" || $0 == ";" })
        let tags = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return tags.isEmpty ? nil : tags
    }

    private func parseRelayKind(_ value: String) -> RelayKind? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "private" || trimmed == "priv" {
            return .privateRelay
        }
        if trimmed == "coord" {
            return .coordinator
        }
        return RelayKind(rawValue: trimmed)
    }

    private func parseRelayTransport(_ value: String) -> RelayEndpointTransport? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        switch trimmed {
        case "tcp", "raw":
            return .tcp
        case "http", "https":
            return .http
        case "ws", "wss", "websocket":
            return .websocket
        default:
            return RelayEndpointTransport(rawValue: trimmed)
        }
    }

    private func parseFederationMode(_ value: String) -> FederationMode? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        return FederationMode(rawValue: trimmed)
    }

    private func parseBucketSeconds(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("m") {
            let number = trimmed.dropLast()
            if let minutes = Int(number) {
                return minutes * 60
            }
        }
        if trimmed.hasSuffix("s") {
            let number = trimmed.dropLast()
            return Int(number)
        }
        return Int(trimmed)
    }

    private func parsePositiveInt(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed), parsed > 0 else {
            return nil
        }
        return parsed
    }

    private func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y":
            return true
        case "0", "false", "no", "n":
            return false
        default:
            return nil
        }
    }

    private func parseGroupCreationMode(_ value: String) -> GroupCreationMode? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "allowed", "on", "enabled", "true", "1":
            return .allowed
        case "disabled", "off", "false", "0":
            return .disabled
        default:
            return nil
        }
    }

    private func mergeMasterServers(_ records: [RelayServerRecord]) {
        let filtered = filterFederationCompatible(records)
        for record in filtered {
            if let index = state.relayServers.firstIndex(where: { $0.endpoint == record.endpoint }) {
                if state.relayServers[index].origin == .manual {
                    continue
                }
                state.relayServers[index].name = record.name
                state.relayServers[index].note = record.note
                state.relayServers[index].origin = record.origin
                state.relayServers[index].sourceId = record.sourceId
                if let password = record.relayPassword {
                    state.relayServers[index].relayPassword = password
                }
                if let advertisedInfo = record.advertisedInfo {
                    state.relayServers[index].advertisedInfo = advertisedInfo
                    state.relayServers[index].lastInfoFetchedAt = record.lastInfoFetchedAt ?? Date()
                }
            } else {
                state.relayServers.append(record)
            }
        }
        if state.selectedRelayId == nil, let first = state.relayServers.first {
            state.selectedRelayId = first.id
            state.relay = first.endpoint
        }
    }

    private func filterFederationCompatible(_ records: [RelayServerRecord]) -> [RelayServerRecord] {
        guard let policy = state.federationPolicy else {
            return records
        }
        return records.filter { record in
            guard let info = record.advertisedInfo else {
                return false
            }
            return isFederationCompatible(policy: policy, info: info.federation)
        }
    }

    private func isFederationCompatible(policy: FederationDescriptor, info: FederationDescriptor) -> Bool {
        guard policy.mode == info.mode else {
            return false
        }
        if let name = policy.name, !name.isEmpty {
            return info.name == name
        }
        return true
    }

    private func federationMismatchMessage(policy: FederationDescriptor, info: FederationDescriptor) -> String {
        "Relay federation \(describeFederation(info)) does not match this identity's federation \(describeFederation(policy))."
    }

    private func describeFederation(_ federation: FederationDescriptor) -> String {
        switch federation.mode {
        case .solo:
            return "Solo"
        case .curated:
            if let name = federation.name, !name.isEmpty {
                return "Curated (\(name))"
            }
            return "Curated"
        case .open:
            if let name = federation.name, !name.isEmpty {
                return "Open (\(name))"
            }
            return "Open"
        }
    }

    private func relayAuthToken(for endpoint: RelayEndpoint) -> String? {
        guard let value = state.relayServers.first(where: { $0.endpoint == endpoint })?.relayPassword?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func relayClient(for endpoint: RelayEndpoint) -> RelayClient {
        RelayClient(endpoint: endpoint, authToken: relayAuthToken(for: endpoint))
    }

    private func loadRelayInfo(endpoint: RelayEndpoint) async throws -> RelayInfo {
        let startedAt = DispatchTime.now()
        let client = relayClient(for: endpoint)
        do {
            let response = try await client.send(.info())
            let latencyMs = elapsedMilliseconds(since: startedAt)
            guard response.type == .info, let info = response.relayInfo else {
                recordRelayHealth(
                    endpoint: endpoint,
                    latencyMs: latencyMs,
                    isReachable: false,
                    failureReason: RelayInfoError.missing.localizedDescription
                )
                throw RelayInfoError.missing
            }
            recordRelayHealth(endpoint: endpoint, latencyMs: latencyMs, isReachable: true, failureReason: nil)
            return info
        } catch {
            if case RelayInfoError.missing = error {
                throw error
            }
            recordRelayHealth(
                endpoint: endpoint,
                latencyMs: elapsedMilliseconds(since: startedAt),
                isReachable: false,
                failureReason: error.localizedDescription
            )
            throw error
        }
    }

    private func elapsedMilliseconds(since start: DispatchTime) -> Int {
        let end = DispatchTime.now().uptimeNanoseconds
        let begin = start.uptimeNanoseconds
        guard end >= begin else { return 0 }
        return Int((end - begin) / 1_000_000)
    }

    private func recordRelayHealth(endpoint: RelayEndpoint, latencyMs: Int?, isReachable: Bool, failureReason: String?) {
        guard let relayId = state.relayServers.first(where: { $0.endpoint == endpoint })?.id else {
            return
        }
        relayHealth[relayId] = RelayHealthSnapshot(
            lastCheckedAt: Date(),
            latencyMs: latencyMs,
            isReachable: isReachable,
            failureReason: failureReason
        )
    }

    private func makeActorProof(
        fingerprint: String,
        signingKey: SigningKeyPair,
        publicSigningKey: Data,
        signableDataBuilder: (RelayActorProof) throws -> Data
    ) throws -> RelayActorProof {
        let signedAt = Date()
        let nonce = UUID()
        let placeholder = RelayActorProof(
            fingerprint: fingerprint,
            publicSigningKey: publicSigningKey,
            signedAt: signedAt,
            nonce: nonce,
            signature: Data()
        )
        let signableData = try signableDataBuilder(placeholder)
        let signature = try signingKey.sign(signableData)
        return RelayActorProof(
            fingerprint: fingerprint,
            publicSigningKey: publicSigningKey,
            signedAt: signedAt,
            nonce: nonce,
            signature: signature
        )
    }

    private func makeActiveIdentityActorProof(
        signableDataBuilder: (RelayActorProof) throws -> Data
    ) throws -> RelayActorProof {
        try makeActorProof(
            fingerprint: state.identity.fingerprint,
            signingKey: state.identity.signingKey,
            publicSigningKey: state.identity.signingKey.publicKeyData,
            signableDataBuilder: signableDataBuilder
        )
    }

    private func makeFetchPairRequestsRequest(maxCount: Int?) throws -> FetchPairRequestsRequest {
        var request = FetchPairRequestsRequest(
            fingerprint: state.identity.fingerprint,
            maxCount: maxCount
        )
        let proof = try makeActiveIdentityActorProof { actorProof in
            try request.signableData(for: actorProof)
        }
        request = FetchPairRequestsRequest(
            fingerprint: state.identity.fingerprint,
            maxCount: maxCount,
            actorProof: proof
        )
        return request
    }

    private func makeSendPairRequest(
        targetFingerprint: String,
        offer: ContactOffer
    ) throws -> SendPairRequest {
        var request = SendPairRequest(
            targetFingerprint: targetFingerprint,
            offer: offer
        )
        let proof = try makeActiveIdentityActorProof { actorProof in
            try request.signableData(for: actorProof)
        }
        request = SendPairRequest(
            targetFingerprint: targetFingerprint,
            offer: offer,
            actorProof: proof
        )
        return request
    }

    private func createRelayGroupRegistry(
        title: String,
        memberFingerprints: [String],
        memberProfiles: [RelayGroupMemberProfile]
    ) async throws -> RelayGroupDescriptor {
        let client = relayClient(for: state.relay)
        let groupId = UUID()
        let allProfiles = uniqueRelayGroupProfiles([relayGroupMemberProfileForActiveIdentity()] + memberProfiles)
        let initialDistribution = try GroupRatchetEpochSecretDistribution.seal(
            secret: freshGroupRatchetSecret(),
            groupId: groupId,
            epoch: 0,
            operation: .create,
            recipients: allProfiles
        )
        var request = CreateGroupRequest(
            groupId: groupId,
            title: title,
            creatorFingerprint: state.identity.fingerprint,
            memberFingerprints: memberFingerprints,
            creatorProfile: relayGroupMemberProfileForActiveIdentity(),
            memberProfiles: memberProfiles,
            initialRatchetSecretDistribution: initialDistribution
        )
        let proof = try makeActiveIdentityActorProof { actorProof in
            try request.signableData(for: actorProof)
        }
        request = CreateGroupRequest(
            groupId: request.groupId,
            title: request.title,
            creatorFingerprint: request.creatorFingerprint,
            memberFingerprints: request.memberFingerprints,
            creatorProfile: request.creatorProfile,
            memberProfiles: request.memberProfiles,
            initialRatchetSecretDistribution: request.initialRatchetSecretDistribution,
            creatorProof: proof
        )
        let response = try await client.send(
            .createGroup(request)
        )
        if response.type == .error {
            throw RelayGroupRegistryError.rejected(response.error ?? "Relay rejected group request.")
        }
        guard response.type == .group,
              let group = response.group else {
            throw RelayGroupRegistryError.invalidResponse
        }
        return group
    }

    private func fetchRelayGroup(groupId: UUID, relay: RelayEndpoint) async throws -> RelayGroupDescriptor? {
        try await fetchRelayGroup(
            groupId: groupId,
            relay: relay,
            memberFingerprint: state.identity.fingerprint,
            signingKey: state.identity.signingKey,
            publicSigningKey: state.identity.signingKey.publicKeyData
        )
    }

    private func fetchRelayGroup(
        groupId: UUID,
        relay: RelayEndpoint,
        memberFingerprint: String,
        signingKey: SigningKeyPair,
        publicSigningKey: Data
    ) async throws -> RelayGroupDescriptor? {
        let client = relayClient(for: relay)
        var request = GetGroupRequest(
            groupId: groupId,
            memberFingerprint: memberFingerprint
        )
        let proof = try makeActorProof(
            fingerprint: memberFingerprint,
            signingKey: signingKey,
            publicSigningKey: publicSigningKey
        ) { actorProof in
            try request.signableData(for: actorProof)
        }
        request = GetGroupRequest(
            groupId: groupId,
            memberFingerprint: memberFingerprint,
            memberProof: proof
        )
        let response = try await client.send(.getGroup(request))
        if response.type == .error {
            throw RelayGroupRegistryError.rejected(response.error ?? "Relay rejected group lookup.")
        }
        guard response.type == .group else {
            throw RelayGroupRegistryError.invalidResponse
        }
        return response.group
    }

    private func updateRelayGroupRegistry(
        groupId: UUID,
        actorFingerprint: String? = nil,
        actorSigningKey: SigningKeyPair? = nil,
        title: String?,
        addMemberFingerprints: [String],
        addMemberProfiles: [RelayGroupMemberProfile],
        removeMemberFingerprints: [String],
        relay: RelayEndpoint? = nil
    ) async throws -> RelayGroupDescriptor {
        let targetRelay = relay ?? state.relay
        let actor = actorFingerprint ?? state.identity.fingerprint
        let signerKey = actorSigningKey ?? state.identity.signingKey
        let signerPublicKey = actorSigningKey?.publicKeyData ?? state.identity.signingKey.publicKeyData
        let client = relayClient(for: targetRelay)
        guard let currentGroup = try await fetchRelayGroup(
            groupId: groupId,
            relay: targetRelay,
            memberFingerprint: actor,
            signingKey: signerKey,
            publicSigningKey: signerPublicKey
        ) else {
            throw RelayGroupRegistryError.rejected("Relay group not found.")
        }
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let addFingerprints = Array(Set(addMemberFingerprints.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        let removeFingerprints = Array(Set(removeMemberFingerprints.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        let profiles = addMemberProfiles
            .filter { !$0.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.fingerprint < $1.fingerprint }
        var request = UpdateGroupRequest(
            groupId: groupId,
            actorFingerprint: actor,
            title: normalizedTitle?.isEmpty == false ? normalizedTitle : nil,
            addMemberFingerprints: addFingerprints,
            addMemberProfiles: profiles,
            removeMemberFingerprints: removeFingerprints
        )
        let operation = relayGroupCommitOperation(
            request: request,
            currentGroup: currentGroup,
            actorFingerprint: actor
        )
        let targetProfiles = projectedRelayGroupProfiles(
            currentMembers: currentGroup.members,
            addProfiles: request.normalizedAddMemberProfiles,
            removeFingerprints: request.normalizedRemoveMemberFingerprints
        )
        let ratchetDistribution = try GroupRatchetEpochSecretDistribution.seal(
            secret: freshGroupRatchetSecret(),
            groupId: groupId,
            epoch: currentGroup.epoch + 1,
            operation: operation,
            recipients: targetProfiles
        )
        var groupCommit = SignedGroupCommit(
            operation: operation,
            groupId: groupId,
            actorFingerprint: actor,
            baseEpoch: currentGroup.epoch,
            previousTranscriptHash: currentGroup.mlsEpochState.confirmedTranscriptHash,
            title: request.normalizedTitle,
            addMemberFingerprints: request.normalizedAddMemberFingerprints,
            addMemberProfiles: request.normalizedAddMemberProfiles,
            removeMemberFingerprints: request.normalizedRemoveMemberFingerprints,
            ratchetSecretDistribution: ratchetDistribution
        )
        let groupCommitProof = try makeActorProof(
            fingerprint: actor,
            signingKey: signerKey,
            publicSigningKey: signerPublicKey
        ) { actorProof in
            try groupCommit.signableData(for: actorProof)
        }
        groupCommit = SignedGroupCommit(
            operation: groupCommit.operation,
            groupId: groupCommit.groupId,
            actorFingerprint: groupCommit.actorFingerprint,
            baseEpoch: groupCommit.baseEpoch,
            previousTranscriptHash: groupCommit.previousTranscriptHash,
            title: groupCommit.title,
            addMemberFingerprints: groupCommit.addMemberFingerprints,
            addMemberProfiles: groupCommit.addMemberProfiles,
            removeMemberFingerprints: groupCommit.removeMemberFingerprints,
            ratchetSecretDistribution: groupCommit.ratchetSecretDistribution,
            actorProof: groupCommitProof
        )
        let proof = try makeActorProof(
            fingerprint: actor,
            signingKey: signerKey,
            publicSigningKey: signerPublicKey
        ) { actorProof in
            try request.signableData(for: actorProof)
        }
        request = UpdateGroupRequest(
            groupId: request.groupId,
            actorFingerprint: request.actorFingerprint,
            title: request.title,
            addMemberFingerprints: request.addMemberFingerprints,
            addMemberProfiles: request.addMemberProfiles,
            removeMemberFingerprints: request.removeMemberFingerprints,
            actorProof: proof,
            groupCommit: groupCommit
        )
        let response = try await client.send(
            .updateGroup(request)
        )
        if response.type == .error {
            throw RelayGroupRegistryError.rejected(response.error ?? "Relay rejected group update.")
        }
        guard response.type == .group,
              let group = response.group else {
            throw RelayGroupRegistryError.invalidResponse
        }
        return group
    }

    private func relayGroupCommitOperation(
        request: UpdateGroupRequest,
        currentGroup: RelayGroupDescriptor,
        actorFingerprint: String
    ) -> MLSGroupCommitOperation {
        let isCreator = actorFingerprint == currentGroup.createdByFingerprint
        if !isCreator,
           !request.normalizedRemoveMemberFingerprints.isEmpty,
           Set(request.normalizedRemoveMemberFingerprints).isSubset(of: [actorFingerprint]) {
            return .selfLeave
        }
        let hasTitleChange = request.normalizedTitle != nil
        let hasAdds = !request.normalizedAddMemberFingerprints.isEmpty || !request.normalizedAddMemberProfiles.isEmpty
        let hasRemoves = !request.normalizedRemoveMemberFingerprints.isEmpty
        if hasAdds {
            return hasRemoves || hasTitleChange ? .update : .addMembers
        }
        if hasRemoves {
            return hasTitleChange ? .update : .removeMembers
        }
        return .update
    }

    private func deleteRelayGroupRegistry(
        groupId: UUID,
        actorFingerprint: String,
        relay: RelayEndpoint,
        actorSigningKey: SigningKeyPair? = nil
    ) async throws {
        let actor = actorFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actor.isEmpty else {
            throw RelayGroupRegistryError.rejected("Invalid group creator fingerprint.")
        }
        let signerKey = actorSigningKey ?? state.identity.signingKey
        let signerPublicKey = actorSigningKey?.publicKeyData ?? state.identity.signingKey.publicKeyData
        let client = relayClient(for: relay)
        var request = DeleteGroupRequest(
            groupId: groupId,
            actorFingerprint: actor
        )
        let proof = try makeActorProof(
            fingerprint: actor,
            signingKey: signerKey,
            publicSigningKey: signerPublicKey
        ) { actorProof in
            try request.signableData(for: actorProof)
        }
        request = DeleteGroupRequest(
            groupId: request.groupId,
            actorFingerprint: request.actorFingerprint,
            actorProof: proof
        )
        let response = try await client.send(
            .deleteGroup(request)
        )
        if response.type == .error {
            throw RelayGroupRegistryError.rejected(response.error ?? "Relay rejected group delete request.")
        }
        guard response.type == .ok else {
            throw RelayGroupRegistryError.invalidResponse
        }
    }

    private func listRelayGroups(
        memberFingerprint: String,
        signerIdentity: Identity,
        relay: RelayEndpoint
    ) async throws -> [RelayGroupDescriptor] {
        let client = relayClient(for: relay)
        var request = ListGroupsRequest(memberFingerprint: memberFingerprint, limit: 256)
        let proof = try makeActorProof(
            fingerprint: signerIdentity.fingerprint,
            signingKey: signerIdentity.signingKey,
            publicSigningKey: signerIdentity.signingKey.publicKeyData
        ) { actorProof in
            try request.signableData(for: actorProof)
        }
        request = ListGroupsRequest(
            memberFingerprint: request.memberFingerprint,
            limit: request.limit,
            memberProof: proof
        )
        let response = try await client.send(
            .listGroups(request)
        )
        if response.type == .error {
            throw RelayGroupRegistryError.rejected(response.error ?? "Relay rejected group list request.")
        }
        guard response.type == .groups else {
            throw RelayGroupRegistryError.invalidResponse
        }
        return response.groups ?? []
    }

    private func requestRelayGroupJoin(
        groupId: UUID,
        requesterProfile: RelayGroupMemberProfile? = nil,
        relay: RelayEndpoint? = nil
    ) async throws -> RelayGroupJoinRequest {
        let targetRelay = relay ?? state.relay
        let client = relayClient(for: targetRelay)
        var request = RequestGroupJoinRequest(
            groupId: groupId,
            requesterProfile: requesterProfile ?? relayGroupMemberProfileForActiveIdentity()
        )
        let proof = try makeActiveIdentityActorProof { actorProof in
            try request.signableData(for: actorProof)
        }
        request = RequestGroupJoinRequest(
            groupId: request.groupId,
            requesterProfile: request.requesterProfile,
            requesterProof: proof
        )
        let response = try await client.send(
            .requestGroupJoin(request)
        )
        if response.type == .error {
            throw RelayGroupRegistryError.rejected(response.error ?? "Relay rejected join request.")
        }
        guard response.type == .groupJoinRequests,
              let request = response.groupJoinRequests?.first else {
            throw RelayGroupRegistryError.invalidResponse
        }
        return request
    }

    private func listRelayGroupJoinRequests(groupId: UUID) async throws -> [RelayGroupJoinRequest] {
        let client = relayClient(for: state.relay)
        var request = ListGroupJoinRequestsRequest(
            groupId: groupId,
            actorFingerprint: state.identity.fingerprint,
            limit: 256
        )
        let proof = try makeActiveIdentityActorProof { actorProof in
            try request.signableData(for: actorProof)
        }
        request = ListGroupJoinRequestsRequest(
            groupId: request.groupId,
            actorFingerprint: request.actorFingerprint,
            limit: request.limit,
            actorProof: proof
        )
        let response = try await client.send(
            .listGroupJoinRequests(request)
        )
        if response.type == .error {
            throw RelayGroupRegistryError.rejected(response.error ?? "Relay rejected join request listing.")
        }
        guard response.type == .groupJoinRequests else {
            throw RelayGroupRegistryError.invalidResponse
        }
        return response.groupJoinRequests ?? []
    }

    private func approveRelayGroupJoin(groupId: UUID, joinRequestId: UUID) async throws -> RelayGroupDescriptor {
        let client = relayClient(for: state.relay)
        guard let currentGroup = try await fetchRelayGroup(groupId: groupId, relay: state.relay) else {
            throw RelayGroupRegistryError.rejected("Relay group not found.")
        }
        let pendingRequests = try await listRelayGroupJoinRequests(groupId: groupId)
        guard let joinRequest = pendingRequests.first(where: { $0.id == joinRequestId }) else {
            throw RelayGroupRegistryError.rejected("Join request not found.")
        }
        let joinRatchetDistribution = try GroupRatchetEpochSecretDistribution.seal(
            secret: freshGroupRatchetSecret(),
            groupId: groupId,
            epoch: currentGroup.epoch + 1,
            operation: .joinApprove,
            recipients: projectedRelayGroupProfiles(
                currentMembers: currentGroup.members,
                addProfiles: [joinRequest.requester],
                removeFingerprints: []
            )
        )
        var groupCommit = SignedGroupCommit(
            operation: .joinApprove,
            groupId: groupId,
            actorFingerprint: state.identity.fingerprint,
            baseEpoch: currentGroup.epoch,
            previousTranscriptHash: currentGroup.mlsEpochState.confirmedTranscriptHash,
            addMemberFingerprints: [joinRequest.requester.fingerprint],
            addMemberProfiles: [joinRequest.requester],
            ratchetSecretDistribution: joinRatchetDistribution
        )
        let groupCommitProof = try makeActiveIdentityActorProof { actorProof in
            try groupCommit.signableData(for: actorProof)
        }
        groupCommit = SignedGroupCommit(
            operation: groupCommit.operation,
            groupId: groupCommit.groupId,
            actorFingerprint: groupCommit.actorFingerprint,
            baseEpoch: groupCommit.baseEpoch,
            previousTranscriptHash: groupCommit.previousTranscriptHash,
            title: groupCommit.title,
            addMemberFingerprints: groupCommit.addMemberFingerprints,
            addMemberProfiles: groupCommit.addMemberProfiles,
            removeMemberFingerprints: groupCommit.removeMemberFingerprints,
            ratchetSecretDistribution: groupCommit.ratchetSecretDistribution,
            actorProof: groupCommitProof
        )
        var request = ApproveGroupJoinRequest(
            groupId: groupId,
            actorFingerprint: state.identity.fingerprint,
            joinRequestId: joinRequestId,
            groupCommit: groupCommit
        )
        let proof = try makeActiveIdentityActorProof { actorProof in
            try request.signableData(for: actorProof)
        }
        request = ApproveGroupJoinRequest(
            groupId: request.groupId,
            actorFingerprint: request.actorFingerprint,
            joinRequestId: request.joinRequestId,
            groupCommit: request.groupCommit,
            actorProof: proof
        )
        let response = try await client.send(
            .approveGroupJoin(request)
        )
        if response.type == .error {
            throw RelayGroupRegistryError.rejected(response.error ?? "Relay rejected join approval.")
        }
        guard response.type == .group, let group = response.group else {
            throw RelayGroupRegistryError.invalidResponse
        }
        return group
    }

    private func rejectRelayGroupJoin(groupId: UUID, joinRequestId: UUID) async throws {
        let client = relayClient(for: state.relay)
        var request = RejectGroupJoinRequest(
            groupId: groupId,
            actorFingerprint: state.identity.fingerprint,
            joinRequestId: joinRequestId
        )
        let proof = try makeActiveIdentityActorProof { actorProof in
            try request.signableData(for: actorProof)
        }
        request = RejectGroupJoinRequest(
            groupId: request.groupId,
            actorFingerprint: request.actorFingerprint,
            joinRequestId: request.joinRequestId,
            actorProof: proof
        )
        let response = try await client.send(
            .rejectGroupJoin(request)
        )
        if response.type == .error {
            throw RelayGroupRegistryError.rejected(response.error ?? "Relay rejected join rejection.")
        }
        guard response.type == .ok else {
            throw RelayGroupRegistryError.invalidResponse
        }
    }

    private func syncRelayGroupsForActiveProfiles() async {
        let profileIds = state.identityProfiles.filter { !$0.isArchived }.map(\.id)
        for profileId in profileIds {
            await syncRelayGroups(for: profileId)
        }
    }

    private func syncRelayGroups(for profileId: UUID) async {
        guard var profile = state.identityProfile(id: profileId) else {
            return
        }
        let descriptors: [RelayGroupDescriptor]
        do {
            descriptors = try await listRelayGroups(
                memberFingerprint: profile.identity.fingerprint,
                signerIdentity: profile.identity,
                relay: profile.relay
            )
        } catch {
            return
        }

        let didMaterializeContacts = materializeGroupDirectoryContacts(from: descriptors, profile: &profile)

        let localOnlyGroups = profile.groups.filter { $0.relayInboxId == nil }
        let existingById = Dictionary(uniqueKeysWithValues: profile.groups.map { ($0.id, $0) })
        let descriptorIds = Set(descriptors.map(\.id))
        let preservedRelayGroups = profile.groups.filter { group in
            group.relayInboxId != nil && !descriptorIds.contains(group.id)
        }
        let relayBackedGroups = descriptors.map { descriptor -> GroupConversation in
            let memberFingerprints = normalizedRelayMemberFingerprints(
                from: descriptor.members,
                preferredRelay: profile.relay
            )
            var merged = existingById[descriptor.id] ?? GroupConversation(
                id: descriptor.id,
                title: descriptor.title,
                memberContactIds: contactIds(for: memberFingerprints, contacts: profile.contacts),
                relayInboxId: descriptor.inboxId,
                relayEpoch: descriptor.epoch,
                relayTranscriptHash: descriptor.mlsEpochState.confirmedTranscriptHash,
                createdByFingerprint: descriptor.createdByFingerprint,
                createdAt: descriptor.createdAt
            )
            merged.title = descriptor.title
            merged.memberContactIds = contactIds(for: memberFingerprints, contacts: profile.contacts)
            merged.relayInboxId = descriptor.inboxId
            merged.relayEpoch = descriptor.epoch
            merged.relayTranscriptHash = descriptor.mlsEpochState.confirmedTranscriptHash
            merged.groupRatchetState = groupRatchetState(
                from: descriptor,
                identity: profile.identity,
                existing: merged.groupRatchetState
            )
            merged.createdByFingerprint = descriptor.createdByFingerprint
            return merged
        }

        var mergedById: [UUID: GroupConversation] = [:]
        for group in localOnlyGroups {
            mergedById[group.id] = group
        }
        for group in preservedRelayGroups {
            mergedById[group.id] = group
        }
        for group in relayBackedGroups {
            mergedById[group.id] = group
        }

        let mergedGroups = mergedById.values.sorted { lhs, rhs in
            let leftDate = lhs.messages.last?.timestamp ?? lhs.createdAt
            let rightDate = rhs.messages.last?.timestamp ?? rhs.createdAt
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        if mergedGroups != profile.groups || didMaterializeContacts {
            profile.groups = mergedGroups
            mergeCurrentThreadMessages(into: &profile)
            state.updateIdentityProfile(profile)
            if profileId == state.activeIdentityId,
               let activeGroupId,
               !mergedGroups.contains(where: { $0.id == activeGroupId }) {
                self.activeGroupId = nil
            }
            await save()
        }
    }

    @discardableResult
    private func materializeGroupDirectoryContacts(
        from descriptors: [RelayGroupDescriptor],
        profile: inout IdentityProfile
    ) -> Bool {
        var changed = false
        for descriptor in descriptors {
            let members = normalizedRelayMembers(descriptor.members, preferredRelay: profile.relay)
            for member in members {
                let fingerprint = member.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fingerprint.isEmpty, fingerprint != profile.identity.fingerprint else {
                    continue
                }
                guard let inboxId = member.inboxId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !inboxId.isEmpty,
                      let relay = member.relay,
                      let signingPublicKey = member.signingPublicKey,
                      !signingPublicKey.isEmpty,
                      let agreementPublicKey = member.agreementPublicKey,
                      !agreementPublicKey.isEmpty else {
                    continue
                }
                let reachableRelay = reachableRelayEndpoint(relay, preferredRelay: profile.relay)
                let displayName = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedName = (displayName?.isEmpty == false ? displayName! : "Group Member \(abbreviatedFingerprint(fingerprint))")
                if let index = profile.contacts.firstIndex(where: { $0.fingerprint == fingerprint }) {
                    var existing = profile.contacts[index]
                    var didUpdate = false
                    if existing.displayName != resolvedName {
                        existing.displayName = resolvedName
                        didUpdate = true
                    }
                    if existing.inboxId != inboxId {
                        existing.inboxId = inboxId
                        didUpdate = true
                    }
                    if existing.relay != reachableRelay {
                        existing.relay = reachableRelay
                        didUpdate = true
                    }
                    if existing.signingPublicKey != signingPublicKey {
                        existing.signingPublicKey = signingPublicKey
                        didUpdate = true
                    }
                    if existing.agreementPublicKey != agreementPublicKey {
                        existing.agreementPublicKey = agreementPublicKey
                        didUpdate = true
                    }
                    if didUpdate {
                        profile.contacts[index] = existing
                        changed = true
                    }
                } else if let index = profile.contacts.firstIndex(where: { existing in
                    existing.inboxId == inboxId && existing.relay == reachableRelay
                }) {
                    var existing = profile.contacts[index]
                    var didUpdate = false
                    if existing.fingerprint != fingerprint {
                        existing.signingPublicKey = signingPublicKey
                        existing.agreementPublicKey = agreementPublicKey
                        didUpdate = true
                    }
                    if existing.displayName != resolvedName {
                        existing.displayName = resolvedName
                        didUpdate = true
                    }
                    if existing.signingPublicKey != signingPublicKey {
                        existing.signingPublicKey = signingPublicKey
                        didUpdate = true
                    }
                    if existing.agreementPublicKey != agreementPublicKey {
                        existing.agreementPublicKey = agreementPublicKey
                        didUpdate = true
                    }
                    if didUpdate {
                        profile.contacts[index] = existing
                        changed = true
                    }
                } else {
                    let contact = Contact(
                        displayName: resolvedName,
                        inboxId: inboxId,
                        relay: reachableRelay,
                        signingPublicKey: signingPublicKey,
                        agreementPublicKey: agreementPublicKey
                    )
                    profile.contacts.append(contact)
                    changed = true
                }
            }
        }
        return changed
    }

    private func activeIdentityLineageFingerprints() -> [String] {
        guard let profile = state.identityProfile(id: state.activeIdentityId) else {
            return [state.identity.fingerprint]
        }
        var ordered: [String] = [profile.identity.fingerprint]
        let continuityEvents = profile.continuityEvents.sorted { $0.timestamp > $1.timestamp }
        for event in continuityEvents {
            if let newFingerprint = event.newFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines),
               !newFingerprint.isEmpty {
                ordered.append(newFingerprint)
            }
            if let oldFingerprint = event.oldFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines),
               !oldFingerprint.isEmpty {
                ordered.append(oldFingerprint)
            }
        }
        var seen = Set<String>()
        return ordered.filter { fingerprint in
            guard !seen.contains(fingerprint) else {
                return false
            }
            seen.insert(fingerprint)
            return true
        }
    }

    private func relayGroupMemberProfileForActiveIdentity() -> RelayGroupMemberProfile {
        RelayGroupMemberProfile(
            fingerprint: state.identity.fingerprint,
            displayName: state.identity.displayName,
            inboxId: state.inboxId,
            relay: state.relay,
            signingPublicKey: state.identity.signingKey.publicKeyData,
            agreementPublicKey: state.identity.agreementKey.publicKeyData
        )
    }

    private func relayGroupMemberProfile(for contact: Contact) -> RelayGroupMemberProfile {
        RelayGroupMemberProfile(
            fingerprint: contact.fingerprint,
            displayName: contact.displayName,
            inboxId: contact.inboxId,
            relay: contact.relay,
            signingPublicKey: contact.signingPublicKey,
            agreementPublicKey: contact.agreementPublicKey
        )
    }

    private func relayGroupMemberProfile(for member: RelayGroupMember) -> RelayGroupMemberProfile {
        RelayGroupMemberProfile(
            fingerprint: member.fingerprint,
            displayName: member.displayName,
            inboxId: member.inboxId,
            relay: member.relay,
            signingPublicKey: member.signingPublicKey,
            agreementPublicKey: member.agreementPublicKey
        )
    }

    private func uniqueRelayGroupProfiles(_ profiles: [RelayGroupMemberProfile]) -> [RelayGroupMemberProfile] {
        var byFingerprint: [String: RelayGroupMemberProfile] = [:]
        for profile in profiles {
            let fingerprint = profile.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fingerprint.isEmpty else { continue }
            byFingerprint[fingerprint] = RelayGroupMemberProfile(
                fingerprint: fingerprint,
                displayName: profile.displayName,
                inboxId: profile.inboxId,
                relay: profile.relay,
                signingPublicKey: profile.signingPublicKey,
                agreementPublicKey: profile.agreementPublicKey
            )
        }
        return byFingerprint.values.sorted { $0.fingerprint < $1.fingerprint }
    }

    private func projectedRelayGroupProfiles(
        currentMembers: [RelayGroupMember],
        addProfiles: [RelayGroupMemberProfile],
        removeFingerprints: [String]
    ) -> [RelayGroupMemberProfile] {
        var profiles = Dictionary(uniqueKeysWithValues: currentMembers.map {
            ($0.fingerprint, relayGroupMemberProfile(for: $0))
        })
        for profile in addProfiles {
            let fingerprint = profile.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fingerprint.isEmpty else { continue }
            profiles[fingerprint] = profile
        }
        for fingerprint in removeFingerprints {
            profiles.removeValue(forKey: fingerprint)
        }
        return uniqueRelayGroupProfiles(Array(profiles.values))
    }

    private func freshGroupRatchetSecret() -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &rng) })
    }

    private func groupRatchetState(
        from descriptor: RelayGroupDescriptor,
        identity: Identity,
        existing: GroupRatchetState? = nil
    ) -> GroupRatchetState? {
        GroupRatchetRecovery.state(
            from: descriptor,
            identity: identity,
            existing: existing
        )
    }

    private func contactIds(for memberFingerprints: [String], contacts: [Contact]? = nil) -> [UUID] {
        let availableContacts = contacts ?? state.contacts
        let uniqueFingerprints = Set(memberFingerprints)
        let ids = availableContacts
            .filter { uniqueFingerprints.contains($0.fingerprint) }
            .map(\.id)
        return Array(Set(ids)).sorted { lhs, rhs in
            lhs.uuidString < rhs.uuidString
        }
    }

    private func normalizedContact(_ contact: Contact, preferredRelay: RelayEndpoint) -> Contact {
        var updated = contact
        updated.relay = reachableRelayEndpoint(contact.relay, preferredRelay: preferredRelay)
        return updated
    }

    private func normalizedRelayMembers(_ members: [RelayGroupMember], preferredRelay: RelayEndpoint) -> [RelayGroupMember] {
        var keyedMembers: [String: RelayGroupMember] = [:]
        var fingerprintOnly: [String: RelayGroupMember] = [:]

        for member in members {
            guard let key = relayMemberEndpointKey(member, preferredRelay: preferredRelay) else {
                let fingerprint = member.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fingerprint.isEmpty else { continue }
                if let existing = fingerprintOnly[fingerprint] {
                    if member.joinedAt > existing.joinedAt {
                        fingerprintOnly[fingerprint] = member
                    }
                } else {
                    fingerprintOnly[fingerprint] = member
                }
                continue
            }

            if let existing = keyedMembers[key] {
                if member.joinedAt > existing.joinedAt {
                    keyedMembers[key] = member
                }
            } else {
                keyedMembers[key] = member
            }
        }

        let combined = Array(keyedMembers.values) + Array(fingerprintOnly.values)
        return combined.sorted { lhs, rhs in
            if lhs.joinedAt != rhs.joinedAt {
                return lhs.joinedAt > rhs.joinedAt
            }
            return lhs.fingerprint < rhs.fingerprint
        }
    }

    private func normalizedRelayMemberFingerprints(
        from members: [RelayGroupMember],
        preferredRelay: RelayEndpoint
    ) -> [String] {
        let normalizedMembers = normalizedRelayMembers(members, preferredRelay: preferredRelay)
        return normalizedMembers.map { $0.fingerprint }
    }

    private func relayMemberEndpointKey(_ member: RelayGroupMember, preferredRelay: RelayEndpoint) -> String? {
        guard let inboxId = member.inboxId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !inboxId.isEmpty,
              let relay = member.relay else {
            return nil
        }
        let endpoint = reachableRelayEndpoint(relay, preferredRelay: preferredRelay)
        return "\(endpoint.host.lowercased()):\(endpoint.port):\(endpoint.useTLS ? 1 : 0):\(endpoint.transport.rawValue):\(inboxId)"
    }

    private func reachableRelayEndpoint(_ endpoint: RelayEndpoint, preferredRelay: RelayEndpoint) -> RelayEndpoint {
        guard endpoint.port == preferredRelay.port else {
            return endpoint
        }
        guard isLoopbackOrWildcardHost(endpoint.host), !isLoopbackOrWildcardHost(preferredRelay.host) else {
            return endpoint
        }
        return RelayEndpoint(
            host: preferredRelay.host,
            port: preferredRelay.port,
            useTLS: preferredRelay.useTLS,
            transport: preferredRelay.transport,
            tlsCertificateFingerprintSHA256: preferredRelay.tlsCertificateFingerprintSHA256,
            directorySigningPublicKey: preferredRelay.directorySigningPublicKey
        )
    }

    private func isLoopbackOrWildcardHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if normalized == "localhost" || normalized == "::1" || normalized == "0.0.0.0" || normalized == "::" {
            return true
        }
        return normalized.hasPrefix("127.")
    }

    private func abbreviatedFingerprint(_ fingerprint: String) -> String {
        if fingerprint.count <= 12 {
            return fingerprint
        }
        let prefix = fingerprint.prefix(6)
        let suffix = fingerprint.suffix(4)
        return "\(prefix)…\(suffix)"
    }

    private enum RelayInfoError: LocalizedError {
        case missing

        var errorDescription: String? {
            switch self {
            case .missing:
                return "Relay did not report its configuration."
            }
        }
    }

    private enum RelayMailboxError: LocalizedError {
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let message):
                return message
            }
        }
    }

    private enum RelayGroupRegistryError: LocalizedError {
        case rejected(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .rejected(let message):
                return message
            case .invalidResponse:
                return "Relay group registry response was invalid."
            }
        }
    }

    private func startAutoFetch() {
        autoFetchTask?.cancel()
        autoFetchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let delaySeconds = self.nextAutoFetchDelaySeconds()
                try? await Task.sleep(for: .seconds(delaySeconds))
                await self.fetchMessages()
                await self.refreshInsecurePairingIfNeeded()
                await self.refreshCoordinatorDirectoryIfNeeded()
            }
        }
    }

    private func nextAutoFetchDelaySeconds(now: Date = Date()) -> Int {
        let activeProfiles = state.identityProfiles.filter { !$0.isArchived }
        let wakeProfiles = activeProfiles.map { profile in
            DecentralizedWakeProfile(
                support: wakeSupport(for: profile.relay),
                identitySeed: wakeIdentitySeed(for: profile),
                relayIdentifier: wakeRelayIdentifier(for: profile.relay),
                failureCount: wakeFailureCountsByProfile[profile.id] ?? 0
            )
        }
        return DecentralizedWakePlanner.nextPollDelaySeconds(
            for: wakeProfiles,
            defaultDelaySeconds: defaultActivePollSeconds,
            maxDelaySeconds: maxActiveWakePollSeconds,
            now: now
        )
    }

    private func wakeSupport(for relay: RelayEndpoint) -> DecentralizedWakeSupport? {
        state.relayServers.first(where: { $0.endpoint == relay })?.advertisedInfo?.wakeSupport
    }

    private func wakeIdentitySeed(for profile: IdentityProfile) -> Data {
        if !profile.inboxId.isEmpty {
            return Data(profile.inboxId.utf8)
        }
        return Data(profile.identity.fingerprint.utf8)
    }

    private func wakeRelayIdentifier(for relay: RelayEndpoint) -> String {
        "\(relay.transport.rawValue):\(relay.useTLS ? "tls" : "plain"):\(quotaRelayKey(relay))"
    }

    private func relayFetchTimeoutSeconds(longPollTimeoutSeconds: Int?) -> TimeInterval {
        RelayClient.defaultTimeout + TimeInterval(max(0, longPollTimeoutSeconds ?? 0))
    }

    private func recordWakeSyncSuccess(for profileId: UUID) {
        wakeFailureCountsByProfile[profileId] = nil
    }

    private func recordWakeSyncFailure(for profileId: UUID) {
        let current = wakeFailureCountsByProfile[profileId] ?? 0
        wakeFailureCountsByProfile[profileId] = min(current + 1, 6)
    }

    private func startAutoFetchIfEligible() {
        guard isReady,
              !requiresOnboarding,
              !isLocked,
              state.hasCompletedOnboarding,
              state.hasAcceptedPrivacyPolicy,
              state.hasAcceptedTermsOfUse else {
            return
        }
        startAutoFetch()
    }

    private func refreshCoordinatorDirectoryIfNeeded(force: Bool = false) async {
        guard let selectedId = state.selectedRelayId,
              let relay = state.relayServers.first(where: { $0.id == selectedId }),
              let info = relay.advertisedInfo else {
            return
        }
        let coordinators = info.federationCoordinatorEndpoints ?? []
        guard !coordinators.isEmpty else {
            return
        }
        let now = Date()
        if !force,
           let last = lastCoordinatorSyncAt,
           now.timeIntervalSince(last) < coordinatorSyncInterval {
            return
        }
        lastCoordinatorSyncAt = now
        do {
            let nodes = try await loadCoordinatorNodes(coordinators: coordinators, federation: info.federation)
            mergeCoordinatorDiscoveredRelays(nodes)
            await save()
        } catch {
            // Keep this silent; coordinator availability should not interrupt active messaging.
        }
    }

    private func loadCoordinatorNodes(
        coordinators: [RelayEndpoint],
        federation: FederationDescriptor
    ) async throws -> [FederationNodeRecord] {
        var merged: [String: FederationNodeRecord] = [:]
        var firstError: Error?
        let effectiveRequest = ListFederationNodesRequest(
            mode: federation.mode,
            federationName: federation.name,
            onlyHealthy: true,
            maxStalenessSeconds: 300,
            requireSignedSnapshot: true
        )
        for coordinator in coordinators {
            do {
                let client = relayClient(for: coordinator)
                let infoResponse = try await client.send(.info())
                guard infoResponse.type == .info else { continue }
                let advertisedPublicKey = infoResponse.relayInfo?.federationDirectoryPublicKey
                let trustedPublicKey = coordinator.directorySigningPublicKey
                if let trustedPublicKey, let advertisedPublicKey, trustedPublicKey != advertisedPublicKey {
                    throw RelayInfoError.missing
                }
                let response = try await client.send(
                    .listFederationNodes(effectiveRequest)
                )
                guard response.type == .federationNodes else { continue }
                let nodes = try validatedCoordinatorNodes(
                    response: response,
                    request: effectiveRequest,
                    trustedPublicKey: trustedPublicKey
                )
                for node in nodes {
                    // Directory should expose actual message relays, not other coordinator-only endpoints.
                    guard node.relayInfo.kind != .coordinator else { continue }
                    let key = "\(node.endpoint.host.lowercased()):\(node.endpoint.port):\(node.endpoint.useTLS ? 1 : 0):\(node.endpoint.transport.rawValue)"
                    if let existing = merged[key] {
                        if node.lastHeartbeatAt > existing.lastHeartbeatAt {
                            merged[key] = node
                        }
                    } else {
                        merged[key] = node
                    }
                }
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if merged.isEmpty, let firstError {
            throw firstError
        }
        return merged.values.sorted { lhs, rhs in
            if lhs.lastHeartbeatAt != rhs.lastHeartbeatAt {
                return lhs.lastHeartbeatAt > rhs.lastHeartbeatAt
            }
            return lhs.endpoint.host < rhs.endpoint.host
        }
    }

    private func validatedCoordinatorNodes(
        response: RelayResponse,
        request: ListFederationNodesRequest,
        trustedPublicKey: Data?
    ) throws -> [FederationNodeRecord] {
        if let snapshot = response.federationSnapshot {
            if let mode = request.mode, snapshot.mode != mode {
                throw RelayInfoError.missing
            }
            if let expectedName = request.federationName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !expectedName.isEmpty,
               snapshot.federationName != expectedName {
                throw RelayInfoError.missing
            }
            guard snapshot.validUntil > Date() else {
                throw RelayInfoError.missing
            }
            if request.requireSignedSnapshot == true {
                guard let trustedPublicKey,
                      FederationDirectorySignature.verify(snapshot: snapshot, trustedPublicKey: trustedPublicKey) else {
                    throw RelayInfoError.missing
                }
            } else if let trustedPublicKey, snapshot.signature != nil {
                guard FederationDirectorySignature.verify(snapshot: snapshot, trustedPublicKey: trustedPublicKey) else {
                    throw RelayInfoError.missing
                }
            }
            return applyFreshnessPolicy(nodes: snapshot.nodes, request: request)
        }
        if request.requireSignedSnapshot == true {
            throw RelayInfoError.missing
        }
        return applyFreshnessPolicy(nodes: response.federationNodes ?? [], request: request)
    }

    private func applyFreshnessPolicy(
        nodes: [FederationNodeRecord],
        request: ListFederationNodesRequest
    ) -> [FederationNodeRecord] {
        let now = Date()
        var filtered = nodes
        if request.onlyHealthy == true {
            filtered = filtered.filter { $0.expiresAt > now }
        }
        if let maxStaleness = request.maxStalenessSeconds, maxStaleness > 0 {
            let cutoff = now.addingTimeInterval(-TimeInterval(maxStaleness))
            filtered = filtered.filter { $0.lastHeartbeatAt >= cutoff }
        }
        return filtered
    }

    private func mergeCoordinatorDiscoveredRelays(_ nodes: [FederationNodeRecord]) {
        var peerHints: [RelayEndpoint] = []
        for node in nodes {
            let endpoint = node.endpoint
            let defaultName = node.relayInfo.relayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = (defaultName?.isEmpty == false ? defaultName! : "\(endpoint.host):\(endpoint.port)")
            if let index = state.relayServers.firstIndex(where: { $0.endpoint == endpoint }) {
                // Preserve operator-entered names/notes for manual entries.
                state.relayServers[index].advertisedInfo = node.relayInfo
                state.relayServers[index].lastInfoFetchedAt = node.lastHeartbeatAt
            } else {
                state.relayServers.append(
                    RelayServerRecord(
                        name: resolvedName,
                        endpoint: endpoint,
                        note: "Discovered via federation coordinator.",
                        advertisedInfo: node.relayInfo,
                        lastInfoFetchedAt: node.lastHeartbeatAt,
                        origin: .master,
                        sourceId: nil
                    )
                )
            }
            peerHints.append(contentsOf: node.relayInfo.knownOpenPeers ?? [])
        }
        for endpoint in peerHints {
            if state.relayServers.contains(where: { $0.endpoint == endpoint }) {
                continue
            }
            state.relayServers.append(
                RelayServerRecord(
                    name: "\(endpoint.host):\(endpoint.port)",
                    endpoint: endpoint,
                    note: "Discovered via relay peer exchange.",
                    advertisedInfo: nil,
                    lastInfoFetchedAt: nil,
                    origin: .master,
                    sourceId: nil
                )
            )
        }
    }

    private func refreshInsecurePairingIfNeeded() async {
        guard state.insecurePairing.isReady else { return }
        let now = Date()
        if let last = lastInsecureRefresh, now.timeIntervalSince(last) < insecureRefreshInterval {
            return
        }
        lastInsecureRefresh = now
        await refreshInsecurePairing()
    }

    private func relayForInsecurePairing() -> RelayEndpoint? {
        state.relay
    }

    private func isSessionMismatch(envelope: Envelope, conversation: Conversation) -> Bool {
        if let sessionId = envelope.sessionId {
            return sessionId != conversation.sessionId
        }
        return !conversation.sessionId.isEmpty
    }

    private func shouldAttemptSessionReset(contactId: UUID) -> Bool {
        sessionResetCooldown.shouldAttempt(contactId: contactId)
    }

    private func attemptSilentSessionReset(
        contact: Contact,
        existingConversation: Conversation,
        identity: Identity,
        preferredRelay: RelayEndpoint
    ) async -> Conversation? {
        guard shouldAttemptSessionReset(contactId: contact.id) else {
            return nil
        }
        let contact = normalizedContact(contact, preferredRelay: preferredRelay)
        do {
            return try await SessionRecovery.sendSessionResetAndResendRequest(
                identity: identity,
                contact: contact,
                existingConversation: existingConversation,
                preferredRelay: preferredRelay,
                resendCount: resendRequestCount,
                preferredRelayAuthToken: relayAuthToken(for: preferredRelay),
                destinationRelayAuthToken: relayAuthToken(for: contact.relay)
            )
        } catch {
            // Silent auto-recovery: avoid surfacing transient errors to the user.
            return nil
        }
    }

    private func createInboundSession(
        for envelope: Envelope,
        contact: Contact,
        identity: Identity,
        profile: inout IdentityProfile
    ) throws -> InboundSessionContext {
        guard let kemCiphertext = envelope.kemCiphertext else {
            throw CryptoError.invalidPayload
        }
        let agreementKey: AgreementKeyPair?
        var usedPrekey = false
        if let prekey = envelope.prekey {
            usedPrekey = true
            switch prekey.kind {
            case .oneTime:
                guard let keyPair = profile.prekeys.consumeOneTimePrekey(id: prekey.id) else {
                    throw CryptoError.invalidPayload
                }
                agreementKey = keyPair
            case .signed:
                guard prekey.id == profile.prekeys.signedPrekeyId,
                      let keyPair = profile.prekeys.signedPrekeyKeyPair() else {
                    throw CryptoError.invalidPayload
                }
                agreementKey = keyPair
            }
        } else {
            agreementKey = nil
        }
        let conversation = try MessageEngine.createInboundSession(
            identity: identity,
            contact: contact,
            kemCiphertext: kemCiphertext,
            agreementKey: agreementKey
        )
        return InboundSessionContext(
            conversation: conversation,
            usedPrekey: usedPrekey,
            agreementKey: agreementKey
        )
    }

    private func rebuildInboundConversation(
        from original: Conversation,
        inbound: InboundSessionContext
    ) throws -> Conversation {
        var rebuilt = inbound.conversation
        rebuilt.messages = original.messages
        rebuilt.unreadCount = original.unreadCount
        return rebuilt
    }

    private func conversation(for contactId: UUID, in profile: IdentityProfile) -> Conversation? {
        let matches = profile.conversations.filter { $0.contactId == contactId }
        if matches.count <= 1 {
            return matches.first
        }
        return matches.max(by: { lhs, rhs in
            let leftDate = lhs.messages.last?.timestamp ?? Date.distantPast
            let rightDate = rhs.messages.last?.timestamp ?? Date.distantPast
            if leftDate != rightDate {
                return leftDate < rightDate
            }
            return lhs.receiveChain.counter < rhs.receiveChain.counter
        })
    }

    private func group(for groupId: UUID, in profile: IdentityProfile) -> GroupConversation? {
        profile.groups.first(where: { $0.id == groupId })
    }

    private func upsertConversation(_ conversation: Conversation, in profile: inout IdentityProfile) {
        if let index = profile.conversations.firstIndex(where: { $0.contactId == conversation.contactId }) {
            profile.conversations[index] = conversation
        } else {
            profile.conversations.append(conversation)
        }
    }

    private func upsertGroup(_ group: GroupConversation, in profile: inout IdentityProfile) {
        if let index = profile.groups.firstIndex(where: { $0.id == group.id }) {
            profile.groups[index] = group
        } else {
            profile.groups.append(group)
        }
    }

    private func updateContact(_ contact: Contact, in profile: inout IdentityProfile) {
        let incomingAddressKey = contactAddressKey(for: contact)
        let primaryIndex: Int?
        if let index = profile.contacts.firstIndex(where: { $0.id == contact.id }) {
            primaryIndex = index
        } else if let index = profile.contacts.firstIndex(where: { $0.fingerprint == contact.fingerprint }) {
            primaryIndex = index
        } else if let incomingAddressKey,
                  let index = profile.contacts.firstIndex(where: { existing in
                      contactAddressKey(for: existing) == incomingAddressKey
                  }) {
            primaryIndex = index
        } else {
            primaryIndex = nil
        }

        guard let primaryIndex else {
            profile.contacts.append(contact)
            return
        }

        let merged = mergeContact(existing: profile.contacts[primaryIndex], incoming: contact)
        profile.contacts[primaryIndex] = merged

        var duplicateIndices: [Int] = []
        var duplicateIds: [UUID] = []
        for (index, existing) in profile.contacts.enumerated() where index != primaryIndex {
            let sameFingerprint = existing.fingerprint == merged.fingerprint
            let sameAddress = {
                guard let mergedAddress = contactAddressKey(for: merged) else {
                    return false
                }
                return contactAddressKey(for: existing) == mergedAddress
            }()
            if sameFingerprint || sameAddress {
                duplicateIndices.append(index)
                duplicateIds.append(existing.id)
            }
        }

        if !duplicateIndices.isEmpty {
            for index in duplicateIndices.sorted(by: >) {
                profile.contacts.remove(at: index)
            }
            remapProfileContactReferences(from: duplicateIds, to: merged.id, profile: &profile)
        }
    }

    private func contactAddressKey(for contact: Contact) -> String? {
        let inbox = contact.inboxId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !inbox.isEmpty else {
            return nil
        }
        let relay = contact.relay
        let host = relay.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return "\(host):\(relay.port):\(relay.useTLS ? 1 : 0):\(relay.transport.rawValue):\(inbox)"
    }

    private func mergeContact(existing: Contact, incoming: Contact) -> Contact {
        let trimmedName = incoming.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? existing.displayName : trimmedName
        let keysChanged = incoming.signingPublicKey != existing.signingPublicKey
            || incoming.agreementPublicKey != existing.agreementPublicKey
        let mergedCounter = keysChanged
            ? incoming.rotationCounter
            : max(existing.rotationCounter, incoming.rotationCounter)
        var trustById: [UUID: ContactTrustAssertion] = [:]
        for assertion in existing.trustAssertions {
            trustById[assertion.id] = assertion
        }
        for assertion in incoming.trustAssertions {
            trustById[assertion.id] = assertion
        }
        let mergedTrust = trustById.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        return Contact(
            id: existing.id,
            displayName: resolvedName,
            inboxId: incoming.inboxId,
            relay: incoming.relay,
            signingPublicKey: incoming.signingPublicKey,
            agreementPublicKey: incoming.agreementPublicKey,
            rotationCounter: mergedCounter,
            allowIdentityReset: existing.allowIdentityReset || incoming.allowIdentityReset,
            trustAssertions: mergedTrust
        )
    }

    private func remapProfileContactReferences(from oldIds: [UUID], to newId: UUID, profile: inout IdentityProfile) {
        let staleIds = Set(oldIds.filter { $0 != newId })
        guard !staleIds.isEmpty else {
            return
        }

        var rebuiltConversations: [Conversation] = []
        for conversation in profile.conversations {
            let resolvedContactId = staleIds.contains(conversation.contactId) ? newId : conversation.contactId
            let adjusted = conversationWithContactId(conversation, contactId: resolvedContactId)
            if let index = rebuiltConversations.firstIndex(where: { $0.contactId == resolvedContactId }) {
                rebuiltConversations[index] = preferredConversation(
                    existing: rebuiltConversations[index],
                    candidate: adjusted
                )
            } else {
                rebuiltConversations.append(adjusted)
            }
        }
        profile.conversations = rebuiltConversations

        for index in profile.groups.indices {
            let remapped = profile.groups[index].memberContactIds.map { staleIds.contains($0) ? newId : $0 }
            var seen: Set<UUID> = []
            profile.groups[index].memberContactIds = remapped.filter { seen.insert($0).inserted }
        }

        if let activeContactId, staleIds.contains(activeContactId) {
            self.activeContactId = newId
        }
    }

    private func conversationWithContactId(_ conversation: Conversation, contactId: UUID) -> Conversation {
        guard conversation.contactId != contactId else {
            return conversation
        }
        return Conversation(
            id: conversation.id,
            contactId: contactId,
            sessionId: conversation.sessionId,
            rootKey: conversation.rootKey,
            rootCounter: conversation.rootCounter,
            sendChain: conversation.sendChain,
            receiveChain: conversation.receiveChain,
            messages: conversation.messages,
            unreadCount: conversation.unreadCount,
            ratchetState: conversation.ratchetState
        )
    }

    private func preferredConversation(existing: Conversation, candidate: Conversation) -> Conversation {
        let existingDate = existing.messages.last?.timestamp ?? Date.distantPast
        let candidateDate = candidate.messages.last?.timestamp ?? Date.distantPast
        if existingDate != candidateDate {
            return candidateDate > existingDate ? candidate : existing
        }
        if existing.receiveChain.counter != candidate.receiveChain.counter {
            return candidate.receiveChain.counter > existing.receiveChain.counter ? candidate : existing
        }
        return existing.id <= candidate.id ? existing : candidate
    }

    private func resendRecentMessages(contactId: UUID, count: Int, profile: inout IdentityProfile) async {
        guard count > 0 else { return }
        guard let contact = profile.contacts.first(where: { $0.id == contactId }) else {
            return
        }
        guard var conversation = conversation(for: contactId, in: profile) else {
            return
        }
        if conversation.messages.isEmpty {
            conversation.messages = storedDirectMessages(profileId: profile.id, contactId: contactId)
        }
        var directCandidates: [(timestamp: Date, payload: String)] = []

        for message in conversation.messages where message.direction == .sent {
            guard message.attachment == nil else { continue }
            directCandidates.append((timestamp: message.timestamp, payload: message.body))
        }

        let sortedDirect = directCandidates
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp > rhs.timestamp
                }
                return lhs.payload < rhs.payload
            }

        var toResend: [String] = []
        toResend.reserveCapacity(count)
        for candidate in sortedDirect {
            toResend.append(candidate.payload)
            if toResend.count == count {
                break
            }
        }

        guard !toResend.isEmpty else { return }

        for payload in toResend {
            do {
                let envelope = try MessageEngine.encrypt(
                    body: .text(payload),
                    senderSigningKey: profile.identity.signingKey,
                    senderFingerprint: profile.identity.fingerprint,
                    conversation: &conversation,
                    kemCiphertext: nil
                )
                conversation.markMessageProcessed()
                try await deliverEnvelope(envelope, to: contact, preferredRelay: profile.relay)
            } catch {
                continue
            }
        }
        upsertConversation(conversation, in: &profile)
    }

    private func deliverEnvelope(_ envelope: Envelope, to contact: Contact, preferredRelay: RelayEndpoint) async throws {
        let destinationRelay = reachableRelayEndpoint(contact.relay, preferredRelay: preferredRelay)
        try await SessionRecovery.deliver(
            envelope: envelope,
            inboxId: contact.inboxId,
            preferredRelay: preferredRelay,
            destinationRelay: destinationRelay,
            preferredRelayAuthToken: relayAuthToken(for: preferredRelay),
            destinationRelayAuthToken: relayAuthToken(for: destinationRelay)
        )
    }

    private enum AttachmentQuotaDirection {
        case outbound
        case inbound
    }

    private enum SupportedImageFormat {
        case jpeg
        case png
        case heic
        case heif
        case avif
    }

    private enum SupportedAudioFormat {
        case m4a
        case aac
        case wav
        case caf
        case mp3
        case ogg

        var mimeType: String {
            switch self {
            case .m4a:
                return "audio/m4a"
            case .aac:
                return "audio/aac"
            case .wav:
                return "audio/wav"
            case .caf:
                return "audio/x-caf"
            case .mp3:
                return "audio/mpeg"
            case .ogg:
                return "audio/ogg"
            }
        }

        var fileExtension: String {
            switch self {
            case .m4a:
                return "m4a"
            case .aac:
                return "aac"
            case .wav:
                return "wav"
            case .caf:
                return "caf"
            case .mp3:
                return "mp3"
            case .ogg:
                return "ogg"
            }
        }
    }

    private func prepareAttachmentPayload(
        data: Data,
        fileName: String?,
        mimeType: String
    ) throws -> (data: Data, fileName: String?, mimeType: String) {
        let normalizedMime = normalizeMimeType(mimeType)
        if normalizedMime.hasPrefix("image/") {
            guard detectSupportedImageFormat(data) != nil else {
                throw AttachmentTransferError.unsupportedType
            }
            try validateImageInputDimensions(data)
            guard let canonicalJPEG = transcodeImageToCanonicalJPEG(data) else {
                throw AttachmentTransferError.imageProcessingFailed
            }
            var updatedName = fileName
            if let fileName, !fileName.isEmpty {
                let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
                updatedName = "\(base).jpg"
            }
            return (canonicalJPEG, updatedName, "image/jpeg")
        }

        guard normalizedMime.hasPrefix("audio/"),
              let audioFormat = detectSupportedAudioFormat(data, normalizedMimeType: normalizedMime) else {
            throw AttachmentTransferError.unsupportedType
        }
        var updatedName = fileName
        if let fileName, !fileName.isEmpty {
            let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            updatedName = "\(base).\(audioFormat.fileExtension)"
        }
        if updatedName == nil || updatedName?.isEmpty == true {
            updatedName = "voice.\(audioFormat.fileExtension)"
        }
        return (data, updatedName, audioFormat.mimeType)
    }

    private func validateInboundAttachmentDescriptor(_ descriptor: AttachmentDescriptor) throws {
        guard descriptor.byteCount > 0 else {
            throw AttachmentTransferError.invalidDescriptor
        }
        guard descriptor.byteCount <= maxAttachmentBytes else {
            throw AttachmentTransferError.attachmentTooLarge(maxBytes: maxAttachmentBytes)
        }
        guard descriptor.chunkSize > 0, descriptor.chunkSize <= attachmentChunkSize else {
            throw AttachmentTransferError.invalidDescriptor
        }
        guard descriptor.chunkCount > 0, descriptor.chunkCount <= maxAttachmentChunkCount else {
            throw AttachmentTransferError.invalidDescriptor
        }
        let expectedChunkCount = Int(ceil(Double(descriptor.byteCount) / Double(descriptor.chunkSize)))
        guard expectedChunkCount == descriptor.chunkCount else {
            throw AttachmentTransferError.invalidDescriptor
        }
        guard descriptor.sha256.count == 32 else {
            throw AttachmentTransferError.invalidDescriptor
        }
        let normalizedMime = normalizeMimeType(descriptor.mimeType)
        let isImage = normalizedMime.hasPrefix("image/")
        let isAudio = normalizedMime.hasPrefix("audio/") && isSupportedAudioMimeType(normalizedMime)
        guard isImage || isAudio else {
            throw AttachmentTransferError.unsupportedType
        }
    }

    private func attachmentDisplayTitle(_ descriptor: AttachmentDescriptor, fallback: String) -> String {
        if let fileName = descriptor.fileName, !fileName.isEmpty {
            return fileName
        }
        let normalizedMime = normalizeMimeType(descriptor.mimeType)
        if normalizedMime.hasPrefix("audio/") {
            return "Voice message"
        }
        if normalizedMime.hasPrefix("image/") {
            return "Image"
        }
        return fallback
    }

    private func isSupportedAudioMimeType(_ normalizedMime: String) -> Bool {
        switch normalizedMime {
        case "audio/m4a", "audio/mp4", "audio/aac", "audio/wav", "audio/x-wav", "audio/x-caf", "audio/mpeg", "audio/mp3", "audio/ogg":
            return true
        default:
            return false
        }
    }

    private func detectSupportedAudioFormat(_ data: Data, normalizedMimeType: String) -> SupportedAudioFormat? {
        let bytes = [UInt8](data.prefix(16))
        if bytes.count >= 12,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return .m4a
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 {
            return .wav
        }
        if bytes.count >= 4,
           bytes[0] == 0x63, bytes[1] == 0x61, bytes[2] == 0x66, bytes[3] == 0x66 {
            return .caf
        }
        if bytes.count >= 3,
           bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            return .mp3
        }
        if bytes.count >= 2,
           bytes[0] == 0xFF,
           (bytes[1] & 0xF0) == 0xF0 {
            return .aac
        }
        if bytes.count >= 4,
           bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 {
            return .ogg
        }
        switch normalizedMimeType {
        case "audio/m4a", "audio/mp4":
            return .m4a
        case "audio/wav", "audio/x-wav":
            return .wav
        case "audio/x-caf":
            return .caf
        case "audio/mpeg", "audio/mp3":
            return .mp3
        case "audio/aac":
            return .aac
        case "audio/ogg":
            return .ogg
        default:
            return nil
        }
    }

    private func validateAttachmentQuota(
        bytes: Int,
        contactId: UUID,
        relay: RelayEndpoint,
        direction: AttachmentQuotaDirection
    ) throws {
        let now = Date()
        let relayKey = quotaRelayKey(relay)
        var contactMap = quotaMapByContact(direction: direction)
        var relayMap = quotaMapByRelay(direction: direction)

        let contactEvents = pruneQuotaEvents(contactMap[contactId] ?? [], now: now)
        let relayEvents = pruneQuotaEvents(relayMap[relayKey] ?? [], now: now)
        contactMap[contactId] = contactEvents
        relayMap[relayKey] = relayEvents
        setQuotaMaps(contactMap: contactMap, relayMap: relayMap, direction: direction)

        let contactCount = contactEvents.count
        let contactBytes = contactEvents.reduce(0) { $0 + $1.bytes }
        let relayBytes = relayEvents.reduce(0) { $0 + $1.bytes }

        guard contactCount < maxAttachmentCountPerContactPerWindow else {
            throw AttachmentTransferError.quotaExceeded("Attachment rate limit reached for this contact. Try again later.")
        }
        guard contactBytes + bytes <= maxAttachmentBytesPerContactPerWindow else {
            throw AttachmentTransferError.quotaExceeded("Attachment byte quota reached for this contact.")
        }
        guard relayBytes + bytes <= maxAttachmentBytesPerRelayPerWindow else {
            throw AttachmentTransferError.quotaExceeded("Attachment byte quota reached for this relay.")
        }
    }

    private func recordAttachmentQuotaUsage(
        bytes: Int,
        contactId: UUID,
        relay: RelayEndpoint,
        direction: AttachmentQuotaDirection
    ) {
        let now = Date()
        let relayKey = quotaRelayKey(relay)
        var contactMap = quotaMapByContact(direction: direction)
        var relayMap = quotaMapByRelay(direction: direction)

        var contactEvents = pruneQuotaEvents(contactMap[contactId] ?? [], now: now)
        contactEvents.append(AttachmentQuotaEvent(timestamp: now, bytes: bytes))
        contactMap[contactId] = contactEvents

        var relayEvents = pruneQuotaEvents(relayMap[relayKey] ?? [], now: now)
        relayEvents.append(AttachmentQuotaEvent(timestamp: now, bytes: bytes))
        relayMap[relayKey] = relayEvents

        setQuotaMaps(contactMap: contactMap, relayMap: relayMap, direction: direction)
    }

    private func pruneQuotaEvents(_ events: [AttachmentQuotaEvent], now: Date) -> [AttachmentQuotaEvent] {
        events.filter { now.timeIntervalSince($0.timestamp) <= attachmentQuotaWindowSeconds }
    }

    private func quotaMapByContact(direction: AttachmentQuotaDirection) -> [UUID: [AttachmentQuotaEvent]] {
        switch direction {
        case .outbound:
            return outboundAttachmentQuotaByContact
        case .inbound:
            return inboundAttachmentQuotaByContact
        }
    }

    private func quotaMapByRelay(direction: AttachmentQuotaDirection) -> [String: [AttachmentQuotaEvent]] {
        switch direction {
        case .outbound:
            return outboundAttachmentQuotaByRelay
        case .inbound:
            return inboundAttachmentQuotaByRelay
        }
    }

    private func setQuotaMaps(
        contactMap: [UUID: [AttachmentQuotaEvent]],
        relayMap: [String: [AttachmentQuotaEvent]],
        direction: AttachmentQuotaDirection
    ) {
        switch direction {
        case .outbound:
            outboundAttachmentQuotaByContact = contactMap
            outboundAttachmentQuotaByRelay = relayMap
        case .inbound:
            inboundAttachmentQuotaByContact = contactMap
            inboundAttachmentQuotaByRelay = relayMap
        }
    }

    private func quotaRelayKey(_ relay: RelayEndpoint) -> String {
        "\(relay.host.lowercased()):\(relay.port)"
    }

    private func normalizeMimeType(_ mimeType: String) -> String {
        mimeType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? mimeType.lowercased()
    }

    private func validateImageInputDimensions(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let widthValue = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightValue = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw AttachmentTransferError.imageProcessingFailed
        }
        let width = widthValue.intValue
        let height = heightValue.intValue
        guard width > 0, height > 0 else {
            throw AttachmentTransferError.imageProcessingFailed
        }
        guard CGFloat(width) <= maxAttachmentInputDimension,
              CGFloat(height) <= maxAttachmentInputDimension else {
            throw AttachmentTransferError.invalidDescriptor
        }
        let pixels = width * height
        guard pixels > 0, pixels <= maxAttachmentInputPixels else {
            throw AttachmentTransferError.invalidDescriptor
        }
    }

    private func transcodeImageToCanonicalJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else {
            return nil
        }
        let scale = min(1, attachmentOutputMaxDimension / max(width, height))
        let targetWidth = max(1, Int(width * scale))
        let targetHeight = max(1, Int(height * scale))
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(targetWidth), height: CGFloat(targetHeight)))
        guard let scaled = context.makeImage() else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: attachmentOutputQuality] as CFDictionary
        // Write only the rendered raster and no source metadata to strip EXIF/GPS fields.
        CGImageDestinationAddImage(destination, scaled, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }

    private func detectSupportedImageFormat(_ data: Data) -> SupportedImageFormat? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(32))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return .jpeg
        }
        if bytes.count >= 8,
           bytes[0] == 0x89,
           bytes[1] == 0x50,
           bytes[2] == 0x4E,
           bytes[3] == 0x47,
           bytes[4] == 0x0D,
           bytes[5] == 0x0A,
           bytes[6] == 0x1A,
           bytes[7] == 0x0A {
            return .png
        }
        if bytes.count >= 12,
           bytes[4] == 0x66,
           bytes[5] == 0x74,
           bytes[6] == 0x79,
           bytes[7] == 0x70 {
            let brandBytes = Array(bytes[8..<12])
            guard let brand = String(bytes: brandBytes, encoding: .ascii)?.lowercased() else {
                return nil
            }
            if ["heic", "heix", "hevc", "hevx"].contains(brand) {
                return .heic
            }
            if ["mif1", "msf1", "heif"].contains(brand) {
                return .heif
            }
            if ["avif", "avis"].contains(brand) {
                return .avif
            }
        }
        return nil
    }

    private func sanitizeAppLock(_ settings: AppLockSettings) -> AppLockSettings {
        var updated = settings
        updated.lockScreenMessage = normalizedLockScreenMessage(updated.lockScreenMessage)
        if !biometricsAvailable {
            switch updated.mode {
            case .biometricsAndPin:
                updated.mode = updated.isPinConfigured ? .pinOnly : .off
            case .biometrics:
                updated.mode = updated.isPinConfigured ? .pinOnly : .off
            case .pinOnly, .off:
                break
            }
        }
        return updated
    }

    private func sanitizeAppLockForBiometricAvailability() -> Bool {
        let updated = sanitizeAppLock(state.appLock)
        guard updated != state.appLock else {
            return false
        }
        state.appLock = updated
        return true
    }

    func refreshBiometricAvailability() {
        biometricsAvailable = ClientViewModel.detectBiometricAvailability()
    }

    private static func detectBiometricAvailability() -> Bool {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        #else
        return false
        #endif
    }

    private func shouldLockForTimeout() -> Bool {
        let minutes = state.appLock.sessionTimeoutMinutes
        if minutes <= 0 {
            return true
        }
        if requiresPin(mode: state.appLock.mode) && !state.appLock.isPinConfigured {
            return false
        }
        guard let lastInactiveAt else {
            return false
        }
        let elapsed = Date().timeIntervalSince(lastInactiveAt)
        return elapsed >= Double(minutes * 60)
    }

    private func shouldLockImmediately() -> Bool {
        shouldLockImmediately(settings: state.appLock)
    }

    private func shouldLockImmediately(settings: AppLockSettings) -> Bool {
        guard settings.mode != .off else { return false }
        if requiresPin(mode: settings.mode) && !settings.isPinConfigured {
            return false
        }
        return true
    }

    private func requiresPin(mode: AppLockMode) -> Bool {
        mode == .biometricsAndPin || mode == .pinOnly
    }

    private func normalizedPin(_ pin: String) -> String {
        String(pin.filter { $0.isNumber }.prefix(6))
    }

    private func normalizedLockScreenMessage(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(140))
    }

    private func unlockPinMatches(_ pin: String) -> Bool {
        guard let salt = state.appLock.pinSalt, let hash = state.appLock.pinHash else {
            return false
        }
        return pinMatches(pin, salt: salt, hash: hash)
    }

    private func pinMatches(_ pin: String, salt: Data?, hash: Data?) -> Bool {
        guard let salt, let hash else { return false }
        let normalized = normalizedPin(pin)
        guard normalized.count == 6 else {
            return false
        }
        if let parsed = parseStructuredPinHash(hash) {
            let digest = stretchedPinDigest(pin: normalized, salt: salt, rounds: parsed.rounds)
            return secureCompare(digest, parsed.digest)
        }
        return false
    }

    private func pinMatchesActionPin(_ pin: String) -> Bool {
        pinMatchesAnyActionPlan(pin, excluding: nil)
    }

    private func pinMatchesAnyActionPlan(_ pin: String, excluding planId: UUID?) -> Bool {
        state.appLock.actionPlans.contains { plan in
            if let planId, plan.id == planId {
                return false
            }
            return pinMatches(pin, salt: plan.pinSalt, hash: plan.pinHash)
        }
    }

    private func recordFailedPinAttempt() {
        pinFailedAttempts += 1
        guard pinFailedAttempts >= pinLockoutThreshold else {
            return
        }
        let exponent = min(10, pinFailedAttempts - pinLockoutThreshold)
        let delay = min(pinLockoutMaxSeconds, pinLockoutBaseSeconds * (1 << exponent))
        pinLockedUntil = Date().addingTimeInterval(TimeInterval(delay))
    }

    private func clearPinAttemptState() {
        pinFailedAttempts = 0
        pinLockedUntil = nil
    }

    private func normalizeActionOperations(_ operations: [AppLockActionOperation]) -> [AppLockActionOperation] {
        operations.map { operation in
            AppLockActionOperation(
                id: operation.id,
                kind: operation.kind,
                identityIds: Array(Set(operation.identityIds)),
                groupIds: Array(Set(operation.groupIds)),
                contactIds: Array(Set(operation.contactIds)),
                chatContactIds: Array(Set(operation.chatContactIds))
            )
        }
    }

    private func sanitizeActionPlans() -> Bool {
        var didChange = false
        var sanitizedPlans: [AppLockActionPlan] = []
        for plan in state.appLock.actionPlans {
            let supportedOperations = normalizeActionOperations(plan.operations)
            if supportedOperations.isEmpty {
                didChange = true
                continue
            }
            if supportedOperations != plan.operations {
                didChange = true
            }
            sanitizedPlans.append(
                AppLockActionPlan(
                    id: plan.id,
                    label: plan.label,
                    pinSalt: plan.pinSalt,
                    pinHash: plan.pinHash,
                    operations: supportedOperations,
                    createdAt: plan.createdAt
                )
            )
        }
        if sanitizedPlans != state.appLock.actionPlans {
            state.appLock.actionPlans = sanitizedPlans
            didChange = true
        }
        return didChange
    }

    private func executeActionPlan(_ plan: AppLockActionPlan, pin: String) async {
        var didRequestCorruption = false
        for operation in plan.operations {
            switch operation.kind {
            case .appReset:
                await performAppResetOperation()
            case .burnIdentities:
                await burnIdentityProfiles(operation.identityIds)
            case .deleteGroups:
                await deleteGroups(operation.groupIds)
            case .deleteIdentities:
                await deleteIdentityProfiles(operation.identityIds)
            case .appCorruption:
                didRequestCorruption = true
                applyInMemoryCorruption()
            case .throwAround:
                await performThrowAroundOperation()
            case .deleteChats:
                await deleteChats(contactIds: operation.chatContactIds, groupIds: operation.groupIds)
            case .deleteContacts:
                await deleteContacts(operation.contactIds)
            case .wipePhotos:
                await wipeAttachments(imageOnly: true)
            case .wipeDocuments:
                await wipeAttachments(imageOnly: false)
                deleteAllLocalDocuments()
            }
        }
        await promoteUsedActionPinToUnlock(pin, consumedPlanId: plan.id)
        if didRequestCorruption {
            injectPersistedCorruption()
            crashNow("Noctyra storage was intentionally corrupted and this install can no longer be reopened.")
        } else {
            lastInfo = "Action plan executed."
        }
    }

    private func promoteUsedActionPinToUnlock(_ normalizedPin: String, consumedPlanId: UUID? = nil) async {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        state.appLock.pinSalt = salt
        state.appLock.pinHash = pinHash(pin: normalizedPin, salt: salt)
        if let consumedPlanId {
            state.appLock.actionPlans.removeAll { $0.id == consumedPlanId }
        }
        await save()
    }

    private func performAppResetOperation() async {
        stopAutoFetch()
        removeAllAttachmentsFromDisk()
        try? FileManager.default.removeItem(at: stateFileURL)
        try? FileManager.default.removeItem(at: corruptionKillSwitchURL)
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ClientViewModel.storageModeKey)
        storageProtectionMode = .keychain
        requiresStorageChoice = true
        isLocked = false
        lastInactiveAt = nil
        activeContactId = nil
        activeGroupId = nil
        insecureAnnouncements = []
        insecureRequests = []
        insecureLastAnnounceAt = nil
        insecureLastListAt = nil
        insecureLastRequestFetchAt = nil
        insecureLastPeerCount = 0
        insecureLastRequestCount = 0
        insecureLastError = nil
        insecureLastRelay = nil
        insecureLastSelfTestAt = nil
        insecureLastSelfTestResult = nil
        insecureSelfTestStep = nil
        pendingOutboundPairRequestFingerprints.removeAll()

        let identity = Identity(displayName: "Setup Required")
        let relay = RelayEndpoint(host: "127.0.0.1", port: 9339)
        let relayRecord = RelayServerRecord(name: "Local Relay", endpoint: relay)
        let profile = makeIdentityProfile(displayName: identity.displayName, relay: relay, relayId: relayRecord.id)
        state.identityProfiles = [profile]
        state.activeIdentityId = profile.id
        state.relayServers = [relayRecord]
        state.selectedRelayId = relayRecord.id
        state.relay = relay
        state.contacts = []
        state.conversations = []
        state.groups = []
        state.masterServerSources = []
        state.insecurePairing = InsecurePairingSettings()
        state.appearance = AppearanceSettings()
        state.privacy = PrivacySettings()
        state.hasCompletedOnboarding = false
        state.hasAcceptedPrivacyPolicy = false
        state.hasAcceptedTermsOfUse = false
        requiresOnboarding = true
    }

    private func burnIdentityProfiles(_ ids: [UUID]) async {
        let targetIds = ids.isEmpty ? [state.activeIdentityId] : ids
        for id in targetIds {
            burnIdentityProfileLocally(id)
        }
    }

    private func burnIdentityProfileLocally(_ profileId: UUID) {
        guard var profile = state.identityProfile(id: profileId) else {
            return
        }
        for conversation in profile.conversations {
            let messages = conversation.messages.isEmpty
                ? storedDirectMessages(profileId: profileId, contactId: conversation.contactId)
                : conversation.messages
            removeAttachmentFiles(from: messages)
        }
        for group in profile.groups {
            let messages = group.messages.isEmpty
                ? storedGroupMessages(profileId: profileId, groupId: group.id)
                : group.messages
            removeAttachmentFiles(from: messages)
        }
        try? threadMessageStore.deleteAllMessages(profileId: profileId)
        let oldFingerprint = profile.identity.fingerprint
        let oldDisplayName = profile.identity.displayName
        let replacement = Identity(displayName: oldDisplayName)
        let replacementInboxAccessKey = SigningKeyPair()
        profile.identity = replacement
        profile.inboxAccessKey = replacementInboxAccessKey
        profile.inboxId = InboxAddress.derived(from: replacementInboxAccessKey.publicKeyData)
        profile.contacts.removeAll()
        profile.conversations.removeAll()
        profile.groups.removeAll()
        profile.prekeys = (try? PrekeyState.generate(identity: replacement, oneTimeCount: prekeyTargetCount)) ?? profile.prekeys
        state.updateIdentityProfile(profile)
        recordContinuityEvent(
            kind: .identityBurned,
            oldFingerprint: oldFingerprint,
            newFingerprint: replacement.fingerprint,
            profileId: profileId
        )
    }

    private func deleteGroups(_ groupIds: [UUID]) async {
        let ids = Set(groupIds)
        guard !ids.isEmpty else { return }
        for id in ids {
            purgeAttachmentDecryptionMemory(groupId: id)
        }
        for profileIndex in state.identityProfiles.indices {
            let profileId = state.identityProfiles[profileIndex].id
            for group in state.identityProfiles[profileIndex].groups where ids.contains(group.id) {
                let messages = group.messages.isEmpty
                    ? storedGroupMessages(profileId: profileId, groupId: group.id)
                    : group.messages
                removeAttachmentFiles(from: messages)
                try? threadMessageStore.deleteGroupMessages(profileId: profileId, groupId: group.id)
            }
            state.identityProfiles[profileIndex].groups.removeAll { ids.contains($0.id) }
        }
        if let activeGroupId, ids.contains(activeGroupId) {
            self.activeGroupId = nil
        }
    }

    private func deleteIdentityProfiles(_ profileIds: [UUID]) async {
        let ids = Set(profileIds)
        guard !ids.isEmpty else { return }
        for profile in state.identityProfiles where ids.contains(profile.id) {
            for conversation in profile.conversations {
                let messages = conversation.messages.isEmpty
                    ? storedDirectMessages(profileId: profile.id, contactId: conversation.contactId)
                    : conversation.messages
                removeAttachmentFiles(from: messages)
            }
            for group in profile.groups {
                let messages = group.messages.isEmpty
                    ? storedGroupMessages(profileId: profile.id, groupId: group.id)
                    : group.messages
                removeAttachmentFiles(from: messages)
            }
            try? threadMessageStore.deleteAllMessages(profileId: profile.id)
        }
        state.identityProfiles.removeAll { ids.contains($0.id) }
        ensureValidActiveIdentityAfterDestructiveChanges()
    }

    private func performThrowAroundOperation() async {
        removeAllAttachmentsFromDisk()
        let relaySelection = state.relayServers.first
        let relay = relaySelection?.endpoint ?? RelayEndpoint(host: "127.0.0.1", port: 9339)
        let relayId = relaySelection?.id
        let profile = makeIdentityProfile(displayName: "Cover \(Int.random(in: 1000...9999))", relay: relay, relayId: relayId)
        var mutated = profile
        for index in 1...3 {
            let fake = Identity(displayName: "Node \(index)")
            let contact = Contact(
                displayName: fake.displayName,
                inboxId: InboxAddress.generate(),
                relay: relay,
                signingPublicKey: fake.signingKey.publicKeyData,
                agreementPublicKey: fake.agreementKey.publicKeyData
            )
            mutated.contacts.append(contact)
            var conversation: Conversation
            if let session = try? MessageEngine.createOutboundSession(identity: mutated.identity, contact: contact) {
                conversation = session.conversation
            } else {
                conversation = Conversation(
                    id: UUID().uuidString,
                    contactId: contact.id,
                    sessionId: UUID().uuidString,
                    sendChain: ChainKeyState(keyData: Data(repeating: 0x23, count: 32)),
                    receiveChain: ChainKeyState(keyData: Data(repeating: 0x42, count: 32))
                )
            }
            conversation.messages = [
                Message(
                    direction: .received,
                    senderDisplayName: contact.displayName,
                    body: randomBogusText(),
                    timestamp: Date(),
                    counter: 0
                ),
                Message(
                    direction: .sent,
                    senderDisplayName: mutated.identity.displayName,
                    body: randomBogusText(),
                    timestamp: Date(),
                    counter: 1
                )
            ]
            mutated.conversations.append(conversation)
        }
        state.identityProfiles = [mutated]
        state.activeIdentityId = mutated.id
        state.hasCompletedOnboarding = true
        state.hasAcceptedPrivacyPolicy = true
        state.hasAcceptedTermsOfUse = true
        requiresOnboarding = false
    }

    private func deleteChats(contactIds: [UUID], groupIds: [UUID]) async {
        let directIds = Set(contactIds)
        let relayGroupIds = Set(groupIds)
        for profileIndex in state.identityProfiles.indices {
            let profileId = state.identityProfiles[profileIndex].id
            for conversationIndex in state.identityProfiles[profileIndex].conversations.indices {
                if directIds.contains(state.identityProfiles[profileIndex].conversations[conversationIndex].contactId) {
                    let contactId = state.identityProfiles[profileIndex].conversations[conversationIndex].contactId
                    let messages = state.identityProfiles[profileIndex].conversations[conversationIndex].messages.isEmpty
                        ? storedDirectMessages(profileId: profileId, contactId: contactId)
                        : state.identityProfiles[profileIndex].conversations[conversationIndex].messages
                    removeAttachmentFiles(from: messages)
                    state.identityProfiles[profileIndex].conversations[conversationIndex].messages.removeAll()
                    state.identityProfiles[profileIndex].conversations[conversationIndex].unreadCount = 0
                    try? threadMessageStore.deleteDirectMessages(profileId: profileId, contactId: contactId)
                }
            }
            for groupIndex in state.identityProfiles[profileIndex].groups.indices {
                if relayGroupIds.contains(state.identityProfiles[profileIndex].groups[groupIndex].id) {
                    let groupId = state.identityProfiles[profileIndex].groups[groupIndex].id
                    let messages = state.identityProfiles[profileIndex].groups[groupIndex].messages.isEmpty
                        ? storedGroupMessages(profileId: profileId, groupId: groupId)
                        : state.identityProfiles[profileIndex].groups[groupIndex].messages
                    removeAttachmentFiles(from: messages)
                    state.identityProfiles[profileIndex].groups[groupIndex].messages.removeAll()
                    state.identityProfiles[profileIndex].groups[groupIndex].unreadCount = 0
                    try? threadMessageStore.deleteGroupMessages(profileId: profileId, groupId: groupId)
                }
            }
        }
    }

    private func deleteContacts(_ contactIds: [UUID]) async {
        let ids = Set(contactIds)
        guard !ids.isEmpty else { return }
        for id in ids {
            purgeAttachmentDecryptionMemory(contactId: id)
        }
        for profileIndex in state.identityProfiles.indices {
            let profileId = state.identityProfiles[profileIndex].id
            for conversation in state.identityProfiles[profileIndex].conversations where ids.contains(conversation.contactId) {
                let messages = conversation.messages.isEmpty
                    ? storedDirectMessages(profileId: profileId, contactId: conversation.contactId)
                    : conversation.messages
                removeAttachmentFiles(from: messages)
                try? threadMessageStore.deleteDirectMessages(profileId: profileId, contactId: conversation.contactId)
            }
            let removedGroupIds = state.identityProfiles[profileIndex].groups
                .filter { group in
                    let remainingMembers = Set(group.memberContactIds).subtracting(ids)
                    return remainingMembers.count < 2
                }
                .map(\.id)
            state.identityProfiles[profileIndex].contacts.removeAll { ids.contains($0.id) }
            state.identityProfiles[profileIndex].conversations.removeAll { ids.contains($0.contactId) }
            for groupIndex in state.identityProfiles[profileIndex].groups.indices {
                state.identityProfiles[profileIndex].groups[groupIndex].memberContactIds.removeAll { ids.contains($0) }
            }
            state.identityProfiles[profileIndex].groups.removeAll { $0.memberContactIds.count < 2 }
            for groupId in removedGroupIds {
                let messages = storedGroupMessages(profileId: profileId, groupId: groupId)
                removeAttachmentFiles(from: messages)
                try? threadMessageStore.deleteGroupMessages(profileId: profileId, groupId: groupId)
            }
        }
    }

    private func wipeAttachments(imageOnly: Bool) async {
        for profileIndex in state.identityProfiles.indices {
            let profileId = state.identityProfiles[profileIndex].id
            for conversationIndex in state.identityProfiles[profileIndex].conversations.indices {
                let contactId = state.identityProfiles[profileIndex].conversations[conversationIndex].contactId
                let inMemoryMessages = state.identityProfiles[profileIndex].conversations[conversationIndex].messages
                let originalMessages = inMemoryMessages.isEmpty
                    ? storedDirectMessages(profileId: profileId, contactId: contactId)
                    : inMemoryMessages
                let updatedMessages = originalMessages.map { message in
                    guard let attachment = message.attachment else {
                        return message
                    }
                    let isImage = attachment.descriptor.mimeType.lowercased().hasPrefix("image/")
                    guard imageOnly ? isImage : !isImage else {
                        return message
                    }
                    if let fileName = attachment.localFileName {
                        try? attachmentStore.deleteAttachment(fileName: fileName)
                    }
                    return Message(
                        id: message.id,
                        direction: message.direction,
                        senderDisplayName: message.senderDisplayName,
                        body: message.body,
                        timestamp: message.timestamp,
                        counter: message.counter,
                        isMismatch: message.isMismatch,
                        attachment: nil
                    )
                }
                if inMemoryMessages.isEmpty {
                    try? threadMessageStore.saveDirectMessages(updatedMessages, profileId: profileId, contactId: contactId)
                } else {
                    state.identityProfiles[profileIndex].conversations[conversationIndex].messages = updatedMessages
                }
            }
            for groupIndex in state.identityProfiles[profileIndex].groups.indices {
                let groupId = state.identityProfiles[profileIndex].groups[groupIndex].id
                let inMemoryMessages = state.identityProfiles[profileIndex].groups[groupIndex].messages
                let originalMessages = inMemoryMessages.isEmpty
                    ? storedGroupMessages(profileId: profileId, groupId: groupId)
                    : inMemoryMessages
                let updatedMessages = originalMessages.map { message in
                    guard let attachment = message.attachment else {
                        return message
                    }
                    let isImage = attachment.descriptor.mimeType.lowercased().hasPrefix("image/")
                    guard imageOnly ? isImage : !isImage else {
                        return message
                    }
                    if let fileName = attachment.localFileName {
                        try? attachmentStore.deleteAttachment(fileName: fileName)
                    }
                    return Message(
                        id: message.id,
                        direction: message.direction,
                        senderDisplayName: message.senderDisplayName,
                        body: message.body,
                        timestamp: message.timestamp,
                        counter: message.counter,
                        isMismatch: message.isMismatch,
                        attachment: nil
                    )
                }
                if inMemoryMessages.isEmpty {
                    try? threadMessageStore.saveGroupMessages(updatedMessages, profileId: profileId, groupId: groupId)
                } else {
                    state.identityProfiles[profileIndex].groups[groupIndex].messages = updatedMessages
                }
            }
        }
    }

    private func applyInMemoryCorruption() {
        for profileIndex in state.identityProfiles.indices {
            state.identityProfiles[profileIndex].identity.displayName = "corrupt-\(Int.random(in: 10000...99999))"
            for contactIndex in state.identityProfiles[profileIndex].contacts.indices {
                state.identityProfiles[profileIndex].contacts[contactIndex].displayName = "bogus-\(Int.random(in: 1000...9999))"
                state.identityProfiles[profileIndex].contacts[contactIndex].inboxId = InboxAddress.generate()
            }
            for conversationIndex in state.identityProfiles[profileIndex].conversations.indices {
                state.identityProfiles[profileIndex].conversations[conversationIndex].messages =
                    state.identityProfiles[profileIndex].conversations[conversationIndex].messages.map { message in
                        Message(
                            id: message.id,
                            direction: message.direction,
                            senderDisplayName: message.senderDisplayName,
                            body: randomBogusText(),
                            timestamp: message.timestamp,
                            counter: message.counter,
                            isMismatch: message.isMismatch,
                            attachment: message.attachment
                        )
                    }
            }
            for groupIndex in state.identityProfiles[profileIndex].groups.indices {
                state.identityProfiles[profileIndex].groups[groupIndex].title = "ghost-\(Int.random(in: 100...999))"
                state.identityProfiles[profileIndex].groups[groupIndex].messages =
                    state.identityProfiles[profileIndex].groups[groupIndex].messages.map { message in
                        Message(
                            id: message.id,
                            direction: message.direction,
                            senderDisplayName: message.senderDisplayName,
                            body: randomBogusText(),
                            timestamp: message.timestamp,
                            counter: message.counter,
                            isMismatch: message.isMismatch,
                            attachment: message.attachment
                        )
                    }
            }
        }
    }

    private func injectPersistedCorruption() {
        let fileManager = FileManager.default
        let supportDirectory = stateFileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let marker = "NOCTYRA_CORRUPTED_V1\n\(Date().timeIntervalSince1970)"
        try? marker.data(using: .utf8)?.write(to: corruptionKillSwitchURL, options: [.atomic])
        let bogusState = Data((0..<2048).map { _ in UInt8.random(in: 0...255) })
        try? bogusState.write(to: stateFileURL, options: [.atomic])
        if let files = try? fileManager.contentsOfDirectory(at: attachmentDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                let garbage = Data((0..<1024).map { _ in UInt8.random(in: 0...255) })
                try? garbage.write(to: file, options: [.atomic])
            }
        }
        let bogusDocument = supportDirectory.appendingPathComponent("bogus-\(UUID().uuidString).bin")
        let bogusPayload = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        try? bogusPayload.write(to: bogusDocument, options: [.atomic])
    }

    private func enforceCorruptionKillSwitchIfNeeded() {
        ClientViewModel.enforceCorruptionKillSwitchIfNeeded(at: corruptionKillSwitchURL)
    }

    private static func enforceCorruptionKillSwitchIfNeeded(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        crashNow("Noctyra storage is intentionally corrupted and cannot be reopened.")
    }

    @inline(never)
    private func crashNow(_ message: String) -> Never {
        ClientViewModel.crashNow(message)
    }

    @inline(never)
    private static func crashNow(_ message: String) -> Never {
        fputs("[Noctyra] \(message)\n", stderr)
        fflush(stderr)
        raise(SIGABRT)
        Darwin.abort()
    }

    private func randomBogusText() -> String {
        let source = "abcdefghijklmnopqrstuvwxyz0123456789"
        let length = Int.random(in: 16...48)
        return String((0..<length).map { _ in source.randomElement() ?? "x" })
    }

    private func removeAttachmentFiles(from messages: [Message]) {
        for message in messages {
            if let fileName = message.attachment?.localFileName {
                decryptedAttachmentCache[fileName]?.wipe()
                decryptedAttachmentCache.removeValue(forKey: fileName)
                decryptedAttachmentScopes.removeValue(forKey: fileName)
                try? attachmentStore.deleteAttachment(fileName: fileName)
            }
        }
    }

    private func removeAllAttachmentsFromDisk() {
        purgeAllAttachmentDecryptionMemory()
        if FileManager.default.fileExists(atPath: attachmentDirectory.path) {
            try? FileManager.default.removeItem(at: attachmentDirectory)
        }
        if FileManager.default.fileExists(atPath: threadMessageDirectory.path) {
            try? FileManager.default.removeItem(at: threadMessageDirectory)
        }
    }

    private func ensureValidActiveIdentityAfterDestructiveChanges() {
        if state.identityProfiles.isEmpty {
            let relaySelection = state.relayServers.first
            let relay = relaySelection?.endpoint ?? RelayEndpoint(host: "127.0.0.1", port: 9339)
            let replacement = makeIdentityProfile(
                displayName: "Recovered Identity",
                relay: relay,
                relayId: relaySelection?.id
            )
            state.identityProfiles = [replacement]
            state.activeIdentityId = replacement.id
            return
        }
        if let active = state.identityProfiles.first(where: { $0.id == state.activeIdentityId }), !active.isArchived {
            return
        }
        if let next = state.identityProfiles.first(where: { !$0.isArchived }) {
            state.activeIdentityId = next.id
        } else if let first = state.identityProfiles.first {
            state.activeIdentityId = first.id
        }
    }

    private func makeIdentityProfile(displayName: String, relay: RelayEndpoint, relayId: UUID?) -> IdentityProfile {
        let identity = Identity(displayName: displayName)
        let inboxAccessKey = SigningKeyPair()
        let inboxId = InboxAddress.derived(from: inboxAccessKey.publicKeyData)
        let prekeys = (try? PrekeyState.generate(identity: identity, oneTimeCount: prekeyTargetCount)) ?? PrekeyState(
            signedPrekeyId: UUID(),
            signedPrekeyPublicKey: Data(),
            signedPrekeyPrivateKey: Data(),
            signedPrekeySignature: Data(),
            signedPrekeyIssuedAt: Date(),
            oneTimePrekeys: []
        )
        return IdentityProfile(
            identity: identity,
            inboxId: inboxId,
            inboxAccessKey: inboxAccessKey,
            relay: relay,
            selectedRelayId: relayId,
            prekeys: prekeys
        )
    }

    private func persistAllThreadMessagesFromState(_ snapshot: ClientState) throws {
        for profile in snapshot.identityProfiles {
            for conversation in profile.conversations {
                // Conversations are frequently evicted from RAM for privacy. Avoid
                // clobbering persisted thread files with empty arrays during generic saves.
                guard !conversation.messages.isEmpty else {
                    continue
                }
                try threadMessageStore.saveDirectMessages(
                    conversation.messages,
                    profileId: profile.id,
                    contactId: conversation.contactId
                )
            }
            for group in profile.groups {
                // Same rule for group threads: only write when RAM currently holds messages.
                guard !group.messages.isEmpty else {
                    continue
                }
                try threadMessageStore.saveGroupMessages(
                    group.messages,
                    profileId: profile.id,
                    groupId: group.id
                )
            }
        }
    }

    private func mergeCurrentThreadMessages(into profile: inout IdentityProfile) {
        guard let current = state.identityProfile(id: profile.id) else {
            return
        }

        var conversationsByContact: [UUID: Conversation] = [:]
        for conversation in profile.conversations {
            if var existing = conversationsByContact[conversation.contactId] {
                existing.messages = mergedMessages(existing.messages, conversation.messages)
                existing.unreadCount = max(existing.unreadCount, conversation.unreadCount)
                conversationsByContact[conversation.contactId] = existing
            } else {
                conversationsByContact[conversation.contactId] = conversation
            }
        }
        for conversation in current.conversations {
            var merged = conversationsByContact[conversation.contactId] ?? conversation
            merged.messages = mergedMessages(
                storedDirectMessages(profileId: profile.id, contactId: conversation.contactId),
                conversation.messages,
                merged.messages
            )
            merged.unreadCount = max(merged.unreadCount, conversation.unreadCount)
            conversationsByContact[conversation.contactId] = merged
        }
        profile.conversations = conversationsByContact.values.sorted { lhs, rhs in
            let leftDate = lhs.messages.last?.timestamp ?? Date.distantPast
            let rightDate = rhs.messages.last?.timestamp ?? Date.distantPast
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return lhs.contactId.uuidString < rhs.contactId.uuidString
        }

        var groupsById: [UUID: GroupConversation] = [:]
        for group in profile.groups {
            if var existing = groupsById[group.id] {
                existing.messages = mergedMessages(existing.messages, group.messages)
                existing.unreadCount = max(existing.unreadCount, group.unreadCount)
                groupsById[group.id] = existing
            } else {
                groupsById[group.id] = group
            }
        }
        for group in current.groups {
            var merged = groupsById[group.id] ?? group
            merged.messages = mergedMessages(
                storedGroupMessages(profileId: profile.id, groupId: group.id),
                group.messages,
                merged.messages
            )
            merged.unreadCount = max(merged.unreadCount, group.unreadCount)
            groupsById[group.id] = merged
        }
        profile.groups = groupsById.values.sorted { lhs, rhs in
            let leftDate = lhs.messages.last?.timestamp ?? lhs.createdAt
            let rightDate = rhs.messages.last?.timestamp ?? rhs.createdAt
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func mergedMessages(_ messageSets: [Message]...) -> [Message] {
        var byId: [UUID: Message] = [:]
        for messages in messageSets {
            for message in messages {
                byId[message.id] = message
            }
        }
        return byId.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            if lhs.counter != rhs.counter {
                return lhs.counter < rhs.counter
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func strippedStateForPersistence(_ snapshot: ClientState) -> ClientState {
        var copy = snapshot
        for profileIndex in copy.identityProfiles.indices {
            for conversationIndex in copy.identityProfiles[profileIndex].conversations.indices {
                copy.identityProfiles[profileIndex].conversations[conversationIndex].messages.removeAll()
            }
            for groupIndex in copy.identityProfiles[profileIndex].groups.indices {
                copy.identityProfiles[profileIndex].groups[groupIndex].messages.removeAll()
            }
        }
        return copy
    }

    private func loadConversationMessagesIntoRAM(contactId: UUID) {
        guard var conversation = state.conversation(for: contactId) else {
            return
        }
        guard conversation.messages.isEmpty else {
            return
        }
        let messages = (try? threadMessageStore.loadDirectMessages(
            profileId: state.activeIdentityId,
            contactId: contactId
        )) ?? []
        if !messages.isEmpty {
            conversation.messages = messages
            state.upsert(conversation: conversation)
        }
    }

    private func loadGroupMessagesIntoRAM(groupId: UUID) {
        guard var group = state.group(for: groupId) else {
            return
        }
        guard group.messages.isEmpty else {
            return
        }
        let messages = (try? threadMessageStore.loadGroupMessages(
            profileId: state.activeIdentityId,
            groupId: groupId
        )) ?? []
        if !messages.isEmpty {
            group.messages = messages
            state.upsert(group: group)
        }
    }

    private func persistAndEvictConversationMessages(contactId: UUID) {
        guard var conversation = state.conversation(for: contactId) else {
            return
        }
        // Avoid clobbering persisted history when RAM was already evicted by a transient scene change.
        if !conversation.messages.isEmpty {
            try? threadMessageStore.saveDirectMessages(
                conversation.messages,
                profileId: state.activeIdentityId,
                contactId: contactId
            )
        }
        conversation.messages.removeAll()
        state.upsert(conversation: conversation)
    }

    private func persistAndEvictGroupMessages(groupId: UUID) {
        guard var group = state.group(for: groupId) else {
            return
        }
        // Same protection for group threads.
        if !group.messages.isEmpty {
            try? threadMessageStore.saveGroupMessages(
                group.messages,
                profileId: state.activeIdentityId,
                groupId: groupId
            )
        }
        group.messages.removeAll()
        state.upsert(group: group)
    }

    private func evictInactiveThreadMessagesFromRAM() {
        for profileIndex in state.identityProfiles.indices {
            let profileId = state.identityProfiles[profileIndex].id
            for conversationIndex in state.identityProfiles[profileIndex].conversations.indices {
                let contactId = state.identityProfiles[profileIndex].conversations[conversationIndex].contactId
                let isActiveConversation = profileId == state.activeIdentityId && contactId == activeContactId
                if !isActiveConversation {
                    state.identityProfiles[profileIndex].conversations[conversationIndex].messages.removeAll()
                }
            }
            for groupIndex in state.identityProfiles[profileIndex].groups.indices {
                let groupId = state.identityProfiles[profileIndex].groups[groupIndex].id
                let isActiveGroup = profileId == state.activeIdentityId && groupId == activeGroupId
                if !isActiveGroup {
                    state.identityProfiles[profileIndex].groups[groupIndex].messages.removeAll()
                }
            }
        }
    }

    private func evictAllThreadMessagesFromRAM() {
        for profileIndex in state.identityProfiles.indices {
            for conversationIndex in state.identityProfiles[profileIndex].conversations.indices {
                state.identityProfiles[profileIndex].conversations[conversationIndex].messages.removeAll()
            }
            for groupIndex in state.identityProfiles[profileIndex].groups.indices {
                state.identityProfiles[profileIndex].groups[groupIndex].messages.removeAll()
            }
        }
    }

    private func storedDirectMessages(profileId: UUID, contactId: UUID) -> [Message] {
        (try? threadMessageStore.loadDirectMessages(profileId: profileId, contactId: contactId)) ?? []
    }

    private func storedGroupMessages(profileId: UUID, groupId: UUID) -> [Message] {
        (try? threadMessageStore.loadGroupMessages(profileId: profileId, groupId: groupId)) ?? []
    }

    private func stopAutoFetch() {
        autoFetchTask?.cancel()
        autoFetchTask = nil
    }

    private func deleteAllLocalDocuments() {
        let supportDirectory = stateFileURL.deletingLastPathComponent()
        if let files = try? FileManager.default.contentsOfDirectory(at: supportDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "piccp" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func loadStorageProtectionMode() -> StorageProtectionMode? {
        if let raw = UserDefaults.standard.string(forKey: storageModeKey),
           let mode = StorageProtectionMode(rawValue: raw) {
            return mode
        }
        return nil
    }

    private func persistStorageProtectionMode(_ mode: StorageProtectionMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: ClientViewModel.storageModeKey)
    }

    private func configureStores(for mode: StorageProtectionMode) {
        store = ClientStateStore(fileURL: stateFileURL, useEncryption: mode.usesKeychain)
        attachmentStore = AttachmentStore(directory: attachmentDirectory, useEncryption: mode.usesKeychain)
        threadMessageStore = ThreadMessageStore(directory: threadMessageDirectory, useEncryption: mode.usesKeychain)
    }

    private func migrateThreadMessages(from oldStore: ThreadMessageStore, to newStore: ThreadMessageStore) throws {
        guard oldStore !== newStore else { return }
        for profile in state.identityProfiles {
            for conversation in profile.conversations {
                let messages = conversation.messages.isEmpty
                    ? (try oldStore.loadDirectMessages(profileId: profile.id, contactId: conversation.contactId))
                    : conversation.messages
                try newStore.saveDirectMessages(messages, profileId: profile.id, contactId: conversation.contactId)
            }
            for group in profile.groups {
                let messages = group.messages.isEmpty
                    ? (try oldStore.loadGroupMessages(profileId: profile.id, groupId: group.id))
                    : group.messages
                try newStore.saveGroupMessages(messages, profileId: profile.id, groupId: group.id)
            }
        }
    }

    private func migrateAttachments(from oldStore: AttachmentStore, to newStore: AttachmentStore) throws {
        guard oldStore !== newStore else { return }
        var uniqueAttachments: [(String, AttachmentDescriptor)] = []
        var seen = Set<String>()
        for profile in state.identityProfiles {
            for conversation in profile.conversations {
                let messages = conversation.messages.isEmpty
                    ? storedDirectMessages(profileId: profile.id, contactId: conversation.contactId)
                    : conversation.messages
                for message in messages {
                    guard let attachment = message.attachment,
                          let fileName = attachment.localFileName else {
                        continue
                    }
                    if seen.insert(fileName).inserted {
                        uniqueAttachments.append((fileName, attachment.descriptor))
                    }
                }
            }
            for group in profile.groups {
                let messages = group.messages.isEmpty
                    ? storedGroupMessages(profileId: profile.id, groupId: group.id)
                    : group.messages
                for message in messages {
                    guard let attachment = message.attachment,
                          let fileName = attachment.localFileName else {
                        continue
                    }
                    if seen.insert(fileName).inserted {
                        uniqueAttachments.append((fileName, attachment.descriptor))
                    }
                }
            }
        }
        for (fileName, descriptor) in uniqueAttachments {
            let data = try oldStore.loadAttachment(fileName: fileName)
            _ = try newStore.saveAttachment(data, descriptor: descriptor)
        }
    }

    private func pinHash(pin: String, salt: Data) -> Data {
        let normalized = normalizedPin(pin)
        let boundedRounds = min(pinMaximumRounds, max(pinMinimumRounds, pinHashRounds))
        let digest = stretchedPinDigest(pin: normalized, salt: salt, rounds: boundedRounds)
        var encoded = Data()
        encoded.append(pinHashMagic)
        var roundsBE = UInt32(boundedRounds).bigEndian
        withUnsafeBytes(of: &roundsBE) { rawBuffer in
            encoded.append(contentsOf: rawBuffer)
        }
        encoded.append(digest)
        return encoded
    }

    private func stretchedPinDigest(pin: String, salt: Data, rounds: Int) -> Data {
        let boundedRounds = min(pinMaximumRounds, max(pinMinimumRounds, rounds))
        let key = SymmetricKey(data: Data(pin.utf8))
        var u = Data(HMAC<SHA256>.authenticationCode(for: salt, using: key))
        var t = u
        if boundedRounds > 1 {
            for _ in 2...boundedRounds {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                t.xorInPlace(with: u)
            }
        }
        return t
    }

    private func parseStructuredPinHash(_ value: Data) -> (rounds: Int, digest: Data)? {
        let prefixLength = pinHashMagic.count
        let roundsLength = MemoryLayout<UInt32>.size
        let digestLength = 32
        let expectedLength = prefixLength + roundsLength + digestLength
        guard value.count == expectedLength else {
            return nil
        }
        guard value.prefix(prefixLength) == pinHashMagic else {
            return nil
        }
        let roundsSlice = value[prefixLength..<(prefixLength + roundsLength)]
        var rounds: UInt32 = 0
        for byte in roundsSlice {
            rounds = (rounds << 8) | UInt32(byte)
        }
        let boundedRounds = min(pinMaximumRounds, max(pinMinimumRounds, Int(rounds)))
        let digest = Data(value.suffix(digestLength))
        return (rounds: boundedRounds, digest: digest)
    }

    private func secureCompare(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

private extension Data {
    mutating func xorInPlace(with other: Data) {
        let count = Swift.min(self.count, other.count)
        guard count > 0 else { return }
        for index in 0..<count {
            self[index] ^= other[index]
        }
    }

    mutating func secureWipe() {
        guard !isEmpty else { return }
        let byteCount = count
        withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            _ = memset_s(baseAddress, byteCount, 0, byteCount)
        }
        removeAll(keepingCapacity: false)
    }
}

private final class SecureRAMBuffer {
    private var pointer: UnsafeMutableRawPointer?
    private let byteCount: Int
    private let lock = NSLock()

    init(copying data: Data) {
        self.byteCount = data.count
        guard byteCount > 0 else { return }
        let allocated = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<UInt8>.alignment
        )
        data.copyBytes(to: allocated.assumingMemoryBound(to: UInt8.self), count: byteCount)
        pointer = allocated
    }

    deinit {
        wipe()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let pointer, byteCount > 0 else {
            return Data()
        }
        return Data(bytes: pointer, count: byteCount)
    }

    func wipe() {
        lock.lock()
        defer { lock.unlock() }
        guard let pointer else { return }
        _ = memset_s(pointer, byteCount, 0, byteCount)
        pointer.deallocate()
        self.pointer = nil
    }
}
