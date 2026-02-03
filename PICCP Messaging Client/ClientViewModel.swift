import Combine
import CryptoKit
import Foundation
import PICCPCore
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
#if canImport(LocalAuthentication)
import LocalAuthentication
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

@MainActor
final class ClientViewModel: ObservableObject {
    @Published var state: ClientState
    @Published var isReady = false
    @Published var lastError: String?
    @Published var lastInfo: String?
    @Published var isSyncing = false
    @Published var profileSyncStatus: [UUID: ProfileSyncState] = [:]
    @Published var activeContactId: UUID?
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

    private var store: ClientStateStore
    private var attachmentStore: AttachmentStore
    private let notifier = NotificationManager()
    private var autoFetchTask: Task<Void, Never>?
    private var sessionResetCooldown = SessionRecovery.Cooldown(interval: 30)
    private let resendRequestCount = 1
    private let attachmentChunkSize = 64 * 1024
    private let attachmentUploadTTLSeconds = 1800
    private let prekeyMinimumCount = 4
    private let prekeyTargetCount = 8
    private let rootRatchetInterval: UInt64 = 50
    private let isUITest: Bool
    private var lastInsecureRefresh: Date?
    private let insecureRefreshInterval: TimeInterval = 20
    private var insecureSelfTestToken: UUID?
    private var lastInactiveAt: Date?
    private let stateFileURL: URL
    private let attachmentDirectory: URL
    private static let storageModeKey = "lattice.storageProtection.mode.v1"
    private static let legacyKeychainConsentKey = "lattice.keychainConsent.v1"
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
            case .uploadFailed(let message):
                return message
            }
        }
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
        let resolvedMode = ClientViewModel.loadStorageProtectionMode()
        let useEncryption = resolvedMode?.usesKeychain ?? false

        self.stateFileURL = fileURL
        self.attachmentDirectory = attachmentDirectory
        self.isUITest = ProcessInfo.processInfo.arguments.contains("UI_TESTING")
        self.store = ClientStateStore(fileURL: fileURL, useEncryption: useEncryption)
        self.attachmentStore = AttachmentStore(directory: attachmentDirectory, useEncryption: useEncryption)
        self.storageProtectionMode = resolvedMode ?? .keychain
        self.requiresStorageChoice = !self.isUITest && resolvedMode == nil
        if isUITest {
            self.state = ClientViewModel.makeUITestState()
            self.isReady = true
            self.requiresStorageChoice = false
        } else {
            let defaultIdentity = Identity(displayName: "New User")
            let defaultRelay = RelayEndpoint(host: "127.0.0.1", port: 9339)
            let defaultServer = RelayServerRecord(name: "Local Relay", endpoint: defaultRelay)
            let defaultInbox = InboxAddress.generate()
            self.state = ClientState(
                identity: defaultIdentity,
                relay: defaultRelay,
                inboxId: defaultInbox,
                relayServers: [defaultServer],
                selectedRelayId: defaultServer.id
            )

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
        do {
            if let stored = try await store.load() {
                state = stored
            } else {
                try await store.save(state)
            }
            if state.insecurePairing.isEnabled {
                state.insecurePairing.isEnabled = false
                try await store.save(state)
            }
            await ensureRelaySelection()
            await ensurePrekeysForActiveProfiles()
            isReady = true
            await notifier.requestAuthorization()
            startAutoFetch()
            if shouldLockImmediately() {
                isLocked = true
            }
        } catch {
            lastError = "Failed to load state: \(error.localizedDescription)"
        }
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
        let bundle = prekeys.bundle(identityFingerprint: identity.fingerprint)
        let request = UploadPrekeyBundleRequest(
            fingerprint: identity.fingerprint,
            bundle: bundle
        )
        do {
            let client = RelayClient(endpoint: relay)
            let response = try await client.send(.uploadPrekeys(request))
            if response.type != .ok {
                lastError = "Failed to publish prekeys: \(response.error ?? "Relay error")"
            }
        } catch {
            lastError = "Failed to publish prekeys: \(error.localizedDescription)"
        }
    }

    func selectStorageProtection(_ mode: StorageProtectionMode) {
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
        Task {
            await load()
        }
    }

    func updateStorageProtectionMode(_ mode: StorageProtectionMode) async {
        guard storageProtectionMode != mode else { return }
        let previousStore = store
        let previousAttachmentStore = attachmentStore
        let previousMode = storageProtectionMode

        storageProtectionMode = mode
        persistStorageProtectionMode(mode)
        configureStores(for: mode)
        storageProtectionStatus = "Updating storage protection..."

        do {
            try await store.save(state)
            try migrateAttachments(from: previousAttachmentStore, to: attachmentStore)
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
            storageProtectionMode = previousMode
            persistStorageProtectionMode(previousMode)
            lastError = "Failed to update storage protection: \(error.localizedDescription)"
            storageProtectionStatus = "Storage protection update failed."
        }
    }

    func save() async {
        if isUITest {
            return
        }
        do {
            try await store.save(state)
        } catch {
            lastError = "Failed to save state: \(error.localizedDescription)"
        }
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

    func contactOfferCode() -> String {
        do {
            let offer = MessageEngine.makeContactOffer(identity: state.identity, inboxId: state.inboxId, relay: state.relay)
            return try ContactOfferCode.encode(offer)
        } catch {
            lastError = "Failed to encode contact offer: \(error.localizedDescription)"
            return ""
        }
    }

    func contactShareData(password: String) async -> Data? {
        let offer = MessageEngine.makeContactOffer(identity: state.identity, inboxId: state.inboxId, relay: state.relay)
        do {
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
            let contact = MessageEngine.contact(from: offer)
            state.upsert(contact: contact)
            recordContinuityEvent(
                kind: .contactAdded,
                contact: contact,
                newFingerprint: contact.fingerprint
            )
            try await store.save(state)
            lastInfo = "Added \(contact.displayName)."
        } catch {
            lastError = "Failed to add contact: \(error.localizedDescription)"
        }
    }

    func addContact(shareData: Data, password: String) async {
        do {
            let offer = try await Task.detached {
                try ContactShare.decode(shareData, password: password)
            }.value
            let contact = MessageEngine.contact(from: offer)
            state.upsert(contact: contact)
            recordContinuityEvent(
                kind: .contactAdded,
                contact: contact,
                newFingerprint: contact.fingerprint
            )
            try await store.save(state)
            lastInfo = "Added \(contact.displayName)."
        } catch {
            lastError = "Failed to import contact: \(error.localizedDescription)"
        }
    }

    private func fetchPrekeyBundle(for contact: Contact) async -> PrekeyBundle? {
        let client = RelayClient(endpoint: contact.relay)
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
        if !forceNew, let existing = state.conversation(for: contact.id) {
            return OutboundSessionContext(conversation: existing, kemCiphertext: nil, prekey: nil)
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
        do {
            let contact = state.contacts[contactIndex]
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
            try await store.save(state)
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
        guard !data.isEmpty else {
            lastError = "Attachment is empty."
            return
        }
        do {
            let preparedPayload = prepareAttachmentPayload(data: data, fileName: fileName, mimeType: mimeType)
            let contact = state.contacts[contactIndex]
            let session = try await prepareOutboundSession(for: contact)
            var conversation = session.conversation
            let rootRatchet = prepareRootRatchetIfNeeded(conversation: conversation, contact: contact)
            let prepared = try MessageEngine.prepareMessageKey(conversation: &conversation)
            let attachmentId = UUID()
            let chunkSize = attachmentChunkSize
            let chunkCount = Int(ceil(Double(preparedPayload.data.count) / Double(chunkSize)))
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
            let relayClient = RelayClient(endpoint: contact.relay)
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
            let title = descriptor.fileName?.isEmpty == false ? descriptor.fileName! : "Image"
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
            try await store.save(state)
            try await deliverEnvelope(envelope, to: contact, preferredRelay: state.relay)
            lastInfo = "Sent attachment to \(contact.displayName)."
        } catch {
            lastError = "Failed to send attachment: \(error.localizedDescription)"
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
            await fetchMessages(for: profile.id)
        }
    }

    private func fetchMessages(for profileId: UUID) async {
        guard var profile = state.identityProfile(id: profileId) else {
            return
        }
        profileSyncStatus[profileId] = .syncing
        do {
            let client = RelayClient(endpoint: profile.relay)
            let response = try await client.send(
                .fetch(FetchRequest(inboxId: profile.inboxId, routingToken: profile.inboxId))
            )
            guard response.type == .messages else {
                if let error = response.error {
                    lastError = "Relay error: \(error)"
                    profileSyncStatus[profileId] = .error(Date(), error)
                } else {
                    profileSyncStatus[profileId] = .error(Date(), "Relay returned an unexpected response.")
                }
                return
            }
            let envelopes = response.messages ?? []
            var pendingResends: [UUID: Int] = [:]
            for envelope in envelopes {
                guard let contactIndex = profile.contacts.firstIndex(where: { $0.fingerprint == envelope.senderFingerprint }) else {
                    continue
                }
                var signatureValid = false
                var fallbackConversation: Conversation?
                do {
                    var contact = profile.contacts[contactIndex]
                    var baseConversation: Conversation
                    var existingConversation: Conversation?
                    var usedPrekeyForSession = false
                    var inboundContext: InboundSessionContext?
                    signatureValid = envelope.verifySignature(publicSigningKey: contact.signingPublicKey)
                    if !signatureValid {
                        continue
                    }
                    if let existing = conversation(for: contact.id, in: profile), existing.id == envelope.conversationId {
                        existingConversation = existing
                        baseConversation = existing
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
                        continue
                    }
                    fallbackConversation = existingConversation ?? baseConversation
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
                            fallbackConversation = existingConversation ?? baseConversation
                        } else {
                            let fallback = existingConversation ?? baseConversation
                            if let rebuilt = await attemptSilentSessionReset(
                                contact: contact,
                                existingConversation: fallback,
                                identity: profile.identity,
                                preferredRelay: profile.relay
                            ) {
                                upsertConversation(rebuilt, in: &profile)
                            } else {
                                var mismatchConversation = fallback
                                let notice = Message(
                                    direction: .received,
                                    body: "Message could not be decrypted (session mismatch). Tap to retry.",
                                    timestamp: envelope.sentAt,
                                    counter: envelope.messageCounter,
                                    isMismatch: true
                                )
                                mismatchConversation.messages.append(notice)
                                mismatchConversation.unreadCount += 1
                                upsertConversation(mismatchConversation, in: &profile)
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
                            var fallback = try rebuildInboundConversation(
                                from: originalConversation,
                                inbound: inbound
                            )
                            let result = try MessageEngine.decryptWithKey(envelope: envelope, contact: contact, conversation: &fallback)
                            body = result.body
                            messageKey = result.messageKey
                            conversation = fallback
                        } else {
                            throw error
                        }
                    }
                    let appendedMessage: Message?
                    if case .attachment(let descriptor) = body {
                        let sessionId = envelope.sessionId ?? conversation.sessionId
                        let localFileName: String?
                        do {
                            localFileName = try await downloadAttachment(
                                descriptor: descriptor,
                                contact: contact,
                                conversationId: conversation.id,
                                sessionId: sessionId,
                                messageCounter: envelope.messageCounter,
                                messageKey: messageKey
                            )
                        } catch {
                            localFileName = nil
                            lastError = "Attachment download failed: \(error.localizedDescription)"
                        }
                        let title = descriptor.fileName?.isEmpty == false ? descriptor.fileName! : "Image"
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
                                let label = descriptor.fileName?.isEmpty == false ? descriptor.fileName! : "Attachment received"
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
                        markRecentSentMessagesAsMismatch(conversation: &conversation, count: request.count)
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
                    upsertConversation(conversation, in: &profile)
                    updateContact(contact, in: &profile)
                } catch {
                    if signatureValid, let ratchet = envelope.rootRatchet, var conversation = fallbackConversation {
                        do {
                            let sharedSecret = try profile.identity.agreementKey.decapsulate(ciphertext: ratchet.kemCiphertext)
                            MessageEngine.applyRootRatchet(
                                sharedSecret: sharedSecret,
                                counter: ratchet.counter,
                                identity: profile.identity,
                                contact: profile.contacts[contactIndex],
                                conversation: &conversation
                            )
                            let notice = Message(
                                direction: .received,
                                body: "Message could not be decrypted (ratchet applied).",
                                timestamp: envelope.sentAt,
                                counter: envelope.messageCounter,
                                isMismatch: true
                            )
                            conversation.messages.append(notice)
                            conversation.unreadCount += 1
                            upsertConversation(conversation, in: &profile)
                            updateContact(profile.contacts[contactIndex], in: &profile)
                            continue
                        } catch {
                            lastError = "Failed to apply root ratchet: \(error.localizedDescription)"
                        }
                    }
                    if shouldSkipEnvelope(error) {
                        continue
                    }
                    lastError = "Failed to process envelope: \(error.localizedDescription)"
                }
            }
            for (contactId, count) in pendingResends {
                await resendRecentMessages(contactId: contactId, count: count, profile: &profile)
            }
            state.updateIdentityProfile(profile)
            try await store.save(state)
            if profile.prekeys.oneTimePrekeys.count < prekeyMinimumCount {
                await ensurePrekeys(for: profileId)
            }
            profileSyncStatus[profileId] = .success(Date())
        } catch {
            lastError = "Failed to fetch messages: \(error.localizedDescription)"
            profileSyncStatus[profileId] = .error(Date(), error.localizedDescription)
        }
    }

    func rotateIdentity() async {
        do {
            let rotationContext = try state.identity.rotateKeys()
            let oldSigningKey = rotationContext.oldSigningKey
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

            var rebuiltConversations: [Conversation] = []
            for contact in state.contacts {
                guard var conversation = state.conversation(for: contact.id) else {
                    continue
                }
                let session = try await prepareOutboundSession(for: contact, forceNew: true)
                let envelope = try MessageEngine.encrypt(
                    body: .identityRotation(rotationContext.rotation),
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
            }
            state.conversations = rebuiltConversations
            try await store.save(state)
            lastInfo = "Rotated keys and notified contacts."
        } catch {
            lastError = "Failed to rotate keys: \(error.localizedDescription)"
        }
    }

    func burnIdentity() async {
        let oldIdentity = state.identity
        let oldSigningKey = oldIdentity.signingKey
        let oldFingerprint = oldIdentity.fingerprint

        state.identity = Identity(displayName: oldIdentity.displayName)
        state.inboxId = InboxAddress.generate()
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
                guard var conversation = state.conversation(for: contact.id) else {
                    continue
                }
                let newOffer = MessageEngine.makeContactOffer(
                    identity: state.identity,
                    inboxId: state.inboxId,
                    relay: state.relay
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
        let inboxId = InboxAddress.generate()
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
            for message in conversation.messages {
                if let fileName = message.attachment?.localFileName {
                    try? attachmentStore.deleteAttachment(fileName: fileName)
                }
            }
        }
        state.identityProfiles.removeAll { $0.id == profileId }
        if profileId == state.activeIdentityId {
            await switchToNextActiveIdentity(excluding: profileId)
        }
        await save()
    }

    private func switchToNextActiveIdentity(excluding profileId: UUID) async {
        if let next = state.identityProfiles.first(where: { !$0.isArchived && $0.id != profileId }) {
            state.activeIdentityId = next.id
        } else {
            let identity = Identity(displayName: "New Identity")
            let inboxId = InboxAddress.generate()
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

    func updateAppLock(_ settings: AppLockSettings) async {
        var updated = settings
        if updated.mode == .off {
            updated.pinHash = nil
            updated.pinSalt = nil
            isLocked = false
        }
        state.appLock = updated
        await save()
        if shouldLockImmediately(settings: updated) {
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
        guard let salt = state.appLock.pinSalt, let hash = state.appLock.pinHash else {
            return false
        }
        return pinHash(pin: normalizedPin(pin), salt: salt) == hash
    }

    func setActionPin(_ pin: String, action: AppLockPinAction) async -> Bool {
        let normalized = normalizedPin(pin)
        guard normalized.count == 6 else {
            lastError = "PIN must be 6 digits."
            return false
        }
        if verifyAppLockPin(normalized) {
            lastError = "Action PIN cannot match the unlock PIN."
            return false
        }
        if pinMatchesOtherActionPin(normalized, action: action) {
            lastError = "Action PIN must be unique."
            return false
        }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let hash = pinHash(pin: normalized, salt: salt)
        switch action {
        case .burnIdentity:
            state.appLock.burnPinSalt = salt
            state.appLock.burnPinHash = hash
        case .clearChats:
            state.appLock.clearChatsPinSalt = salt
            state.appLock.clearChatsPinHash = hash
        }
        await save()
        return true
    }

    func clearActionPin(_ action: AppLockPinAction) async {
        switch action {
        case .burnIdentity:
            state.appLock.burnPinSalt = nil
            state.appLock.burnPinHash = nil
        case .clearChats:
            state.appLock.clearChatsPinSalt = nil
            state.appLock.clearChatsPinHash = nil
        }
        await save()
    }

    func performActionPinIfNeeded(_ pin: String) async -> AppLockPinAction? {
        let normalized = normalizedPin(pin)
        if pinMatches(normalized, salt: state.appLock.burnPinSalt, hash: state.appLock.burnPinHash) {
            await burnIdentity()
            await clearActionPin(.burnIdentity)
            return .burnIdentity
        }
        if pinMatches(normalized, salt: state.appLock.clearChatsPinSalt, hash: state.appLock.clearChatsPinHash) {
            await clearAllChats()
            await clearActionPin(.clearChats)
            return .clearChats
        }
        return nil
    }

    func performBiometricUnlock() async -> Bool {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock Lattice") { success, _ in
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
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        guard state.appLock.mode != .off else { return }
        switch phase {
        case .active:
            if shouldLockForTimeout() {
                isLocked = true
            }
        case .inactive, .background:
            lastInactiveAt = Date()
        @unknown default:
            break
        }
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

    func removeContact(id: UUID) async {
        if let contact = state.contacts.first(where: { $0.id == id }) {
            recordContinuityEvent(
                kind: .contactRemoved,
                contact: contact,
                oldFingerprint: contact.fingerprint
            )
            state.contacts.removeAll { $0.id == id }
            state.conversations.removeAll { $0.contactId == id }
            await save()
            lastInfo = "Removed \(contact.displayName)."
        }
    }

    func deleteMessage(contactId: UUID, messageId: UUID) async {
        guard var conversation = state.conversation(for: contactId) else {
            return
        }
        if let message = conversation.messages.first(where: { $0.id == messageId }),
           let fileName = message.attachment?.localFileName {
            try? attachmentStore.deleteAttachment(fileName: fileName)
        }
        conversation.messages.removeAll { $0.id == messageId }
        state.upsert(conversation: conversation)
        await save()
    }

    func clearConversation(contactId: UUID) async {
        guard var conversation = state.conversation(for: contactId) else {
            return
        }
        for message in conversation.messages {
            if let fileName = message.attachment?.localFileName {
                try? attachmentStore.deleteAttachment(fileName: fileName)
            }
        }
        conversation.messages.removeAll()
        conversation.unreadCount = 0
        state.upsert(conversation: conversation)
        await save()
    }

    func clearAllChats() async {
        guard !state.conversations.isEmpty else { return }
        var updated: [Conversation] = []
        updated.reserveCapacity(state.conversations.count)
        for conversation in state.conversations {
            var cleared = conversation
            for message in cleared.messages {
                if let fileName = message.attachment?.localFileName {
                    try? attachmentStore.deleteAttachment(fileName: fileName)
                }
            }
            cleared.messages.removeAll()
            cleared.unreadCount = 0
            updated.append(cleared)
        }
        state.conversations = updated
        await save()
        lastInfo = "Cleared all chats."
    }

    func updateInsecurePairing(_ settings: InsecurePairingSettings) async {
        var updated = settings
        if updated.isEnabled, updated.method == nil {
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
            let offer = MessageEngine.makeContactOffer(identity: state.identity, inboxId: state.inboxId, relay: relay)
            let announceResponse = try await RelayClient(endpoint: relay).send(.announce(AnnounceRequest(offer: offer, ttlSeconds: 120)))
            if announceResponse.type == .error, let error = announceResponse.error {
                let message = "Insecure pairing announce failed: \(error)"
                lastError = message
                insecureLastError = message
            } else {
                insecureLastAnnounceAt = Date()
            }
            let announcementsResponse = try await RelayClient(endpoint: relay).send(.listAnnouncements(ListAnnouncementsRequest(limit: 50)))
            if announcementsResponse.type == .announcements {
                insecureAnnouncements = (announcementsResponse.announcements ?? [])
                    .filter { $0.offer.fingerprint != state.identity.fingerprint }
                insecureLastPeerCount = insecureAnnouncements.count
                insecureLastListAt = Date()
            } else if announcementsResponse.type == .error, let error = announcementsResponse.error {
                let message = "Insecure pairing list failed: \(error)"
                lastError = message
                insecureLastError = message
            }
            if state.insecurePairing.allowInboundRequests {
                let fetch = FetchPairRequestsRequest(fingerprint: state.identity.fingerprint, maxCount: 50)
                let requestsResponse = try await RelayClient(endpoint: relay).send(.fetchPairRequests(fetch))
                if requestsResponse.type == .pairRequests {
                    insecureRequests = requestsResponse.pairRequests ?? []
                    insecureLastRequestCount = insecureRequests.count
                    insecureLastRequestFetchAt = Date()
                } else if requestsResponse.type == .error, let error = requestsResponse.error {
                    let message = "Insecure pairing fetch failed: \(error)"
                    lastError = message
                    insecureLastError = message
                }
            }
        } catch {
            let message = "Insecure pairing failed: \(error.localizedDescription)"
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
            let offer = MessageEngine.makeContactOffer(identity: state.identity, inboxId: state.inboxId, relay: relay)
            let response = try await RelayClient(endpoint: relay).send(.announce(AnnounceRequest(offer: offer, ttlSeconds: 120)))
            if response.type == .error, let error = response.error {
                let message = "Insecure pairing announce failed: \(error)"
                lastError = message
                insecureLastError = message
            } else {
                insecureLastAnnounceAt = Date()
            }
        } catch {
            let message = "Insecure pairing announce failed: \(error.localizedDescription)"
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
            let message = "Enable insecure pairing first."
            lastError = message
            insecureLastError = message
            insecureLastSelfTestResult = message
            insecureSelfTestStep = nil
            insecureSelfTestToken = nil
            return
        }
        guard let relay = relayForInsecurePairing() else {
            let message = "Relay unavailable for insecure pairing."
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
            let offer = MessageEngine.makeContactOffer(identity: state.identity, inboxId: state.inboxId, relay: relay)
            let announceResponse = try await RelayClient(endpoint: relay)
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
            let listResponse = try await RelayClient(endpoint: relay)
                .send(.listAnnouncements(ListAnnouncementsRequest(limit: 50)))
            if listResponse.type == .error, let error = listResponse.error {
                throw InsecureSelfTestFailure(message: "List error: \(error)")
            }
            guard listResponse.type == .announcements else {
                throw InsecureSelfTestFailure(message: "List failed with \(listResponse.type).")
            }
            let listed = listResponse.announcements ?? []
            let hasSelf = listed.contains(where: { $0.offer.fingerprint == state.identity.fingerprint })
            guard hasSelf else {
                throw InsecureSelfTestFailure(message: "List did not include this device.")
            }
            insecureLastListAt = Date()
            insecureLastPeerCount = listed.filter { $0.offer.fingerprint != state.identity.fingerprint }.count

            insecureSelfTestStep = "Pair request"
            let pairResponse = try await RelayClient(endpoint: relay)
                .send(.sendPairRequest(SendPairRequest(targetFingerprint: state.identity.fingerprint, offer: offer)))
            if pairResponse.type == .error, let error = pairResponse.error {
                throw InsecureSelfTestFailure(message: "Pair request error: \(error)")
            }
            guard pairResponse.type == .ok else {
                throw InsecureSelfTestFailure(message: "Pair request failed with \(pairResponse.type).")
            }

            insecureSelfTestStep = "Fetch requests"
            let fetchResponse = try await RelayClient(endpoint: relay)
                .send(.fetchPairRequests(FetchPairRequestsRequest(fingerprint: state.identity.fingerprint, maxCount: 5)))
            if fetchResponse.type == .error, let error = fetchResponse.error {
                throw InsecureSelfTestFailure(message: "Fetch error: \(error)")
            }
            guard fetchResponse.type == .pairRequests else {
                throw InsecureSelfTestFailure(message: "Fetch failed with \(fetchResponse.type).")
            }
            let requests = fetchResponse.pairRequests ?? []
            guard requests.contains(where: { $0.from.fingerprint == state.identity.fingerprint }) else {
                throw InsecureSelfTestFailure(message: "Fetch did not return the test request.")
            }
            insecureLastRequestFetchAt = Date()
            insecureLastRequestCount = requests.count

            insecureLastSelfTestAt = Date()
            insecureLastSelfTestResult = "OK"
            lastInfo = "Insecure pairing self-test passed."
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
            lastError = "Relay unavailable for insecure pairing."
            return
        }
        do {
            let offer = MessageEngine.makeContactOffer(identity: state.identity, inboxId: state.inboxId, relay: relay)
            let request = SendPairRequest(targetFingerprint: announcement.offer.fingerprint, offer: offer)
            _ = try await RelayClient(endpoint: relay).send(.sendPairRequest(request))
            lastInfo = "Pairing request sent to \(announcement.offer.displayName)."
        } catch {
            lastError = "Failed to send pairing request: \(error.localizedDescription)"
        }
    }

    func acceptPairRequest(_ request: PairingRequest) async {
        let contact = MessageEngine.contact(from: request.from)
        state.upsert(contact: contact)
        recordContinuityEvent(
            kind: .contactAdded,
            contact: contact,
            newFingerprint: contact.fingerprint
        )
        insecureRequests.removeAll { $0.id == request.id }
        await save()
        lastInfo = "Added \(contact.displayName)."
    }

    func dismissPairRequest(_ request: PairingRequest) {
        insecureRequests.removeAll { $0.id == request.id }
    }

    func retryMismatch(contactId: UUID) async {
        guard let contact = state.contacts.first(where: { $0.id == contactId }) else {
            return
        }
        guard let conversation = state.conversation(for: contactId) else {
            return
        }
        do {
            let rebuilt = try await SessionRecovery.sendSessionResetAndResendRequest(
                identity: state.identity,
                contact: contact,
                existingConversation: conversation,
                preferredRelay: state.relay,
                resendCount: resendRequestCount
            )
            state.upsert(conversation: rebuilt)
            await save()
        } catch {
            lastError = "Retry failed: \(error.localizedDescription)"
        }
    }

    func loadAttachmentData(fileName: String) async -> Data? {
        do {
            return try attachmentStore.loadAttachment(fileName: fileName)
        } catch {
            print("[client] Failed to load attachment: \(error)")
            return nil
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
        guard descriptor.chunkCount > 0 else {
            throw AttachmentTransferError.invalidDescriptor
        }
        let client = RelayClient(endpoint: contact.relay)
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
        guard AttachmentCrypto.sha256(data) == descriptor.sha256 else {
            throw AttachmentTransferError.invalidChecksum
        }
        return try attachmentStore.saveAttachment(data, descriptor: descriptor)
    }

    func addRelayServer(name: String, host: String, port: UInt16, note: String? = nil, origin: RelayServerOrigin = .manual, sourceId: UUID? = nil) async {
        let endpoint = RelayEndpoint(host: host, port: port)
        if let index = state.relayServers.firstIndex(where: { $0.endpoint == endpoint }) {
            state.relayServers[index].name = name
            state.relayServers[index].note = note
            state.relayServers[index].origin = origin
            state.relayServers[index].sourceId = sourceId
        } else {
            state.relayServers.append(
                RelayServerRecord(
                    name: name,
                    endpoint: endpoint,
                    note: note,
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

    func updateRelayServer(id: UUID, name: String, host: String, port: UInt16, note: String?) async {
        let endpoint = RelayEndpoint(host: host, port: port)
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
        if oldEndpoint != endpoint {
            state.relayServers[index].advertisedInfo = nil
            state.relayServers[index].lastInfoFetchedAt = nil
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
        } catch {
            lastError = "Relay info fetch failed: \(error.localizedDescription)"
        }
    }

    func testSelectedRelay() async {
        let endpoint = state.relay
        do {
            let client = RelayClient(endpoint: endpoint)
            let response = try await client.send(.health())
            if response.type == .ok {
                lastInfo = "Relay \(endpoint.host):\(endpoint.port) is reachable."
                if let selected = state.selectedRelayId {
                    await fetchRelayInfo(id: selected)
                }
            } else if let error = response.error {
                lastError = "Relay error: \(error)"
            } else {
                lastError = "Relay returned unexpected response."
            }
        } catch {
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
        } catch {
            lastError = "Relay info fetch failed: \(error.localizedDescription)"
        }
    }

    func addMasterSource(name: String, url: String) async {
        state.masterServerSources.append(MasterServerSource(name: name, url: url))
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
        guard let url = URL(string: source.url) else {
            lastError = "Invalid master source URL."
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
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

    private func ensureRelaySelection() async {
        var didChange = false
        if state.relayServers.isEmpty {
            let fallback = RelayServerRecord(name: "Current Relay", endpoint: state.relay)
            state.relayServers = [fallback]
            state.selectedRelayId = fallback.id
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
                let parts = trimmed.split(separator: ",", maxSplits: 12, omittingEmptySubsequences: false)
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
                guard let (host, port) = parseHostPort(hostPort) else { continue }
                let entry = MasterServerEntry(
                    name: name?.isEmpty == true ? nil : name,
                    host: host,
                    port: port,
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
                    softwareVersion: softwareVersion?.isEmpty == true ? nil : softwareVersion
                )
                records.append(RelayServerRecord(entry: entry, sourceId: sourceId))
            }
            if !records.isEmpty {
                return records
            }
        }

        throw CryptoError.invalidPayload
    }

    private func parseHostPort(_ value: String) -> (String, UInt16)? {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            return nil
        }
        let host = String(parts[0])
        return host.isEmpty ? nil : (host, port)
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
        return RelayKind(rawValue: trimmed)
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

    private func loadRelayInfo(endpoint: RelayEndpoint) async throws -> RelayInfo {
        let client = RelayClient(endpoint: endpoint)
        let response = try await client.send(.info())
        guard response.type == .info, let info = response.relayInfo else {
            throw RelayInfoError.missing
        }
        return info
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

    private func startAutoFetch() {
        autoFetchTask?.cancel()
        autoFetchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                await self.fetchMessages()
                await self.refreshInsecurePairingIfNeeded()
            }
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
        switch state.insecurePairing.method ?? .relay {
        case .relay:
            return state.relay
        case .localNetwork:
            return state.relay
        case .bluetooth:
            return nil
        }
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
        do {
            return try await SessionRecovery.sendSessionResetAndResendRequest(
                identity: identity,
                contact: contact,
                existingConversation: existingConversation,
                preferredRelay: preferredRelay,
                resendCount: resendRequestCount
            )
        } catch {
            // Silent auto-recovery: avoid surfacing transient errors to the user.
            return nil
        }
    }

    private func shouldSkipEnvelope(_ error: Error) -> Bool {
        if error is CryptoKitError {
            return true
        }
        if let coreError = error as? CryptoError {
            switch coreError {
            case .counterOutOfOrder, .counterReplay, .counterWindowExceeded, .invalidPayload, .invalidSignature:
                return true
            default:
                return false
            }
        }
        return false
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

    private func upsertConversation(_ conversation: Conversation, in profile: inout IdentityProfile) {
        if let index = profile.conversations.firstIndex(where: { $0.contactId == conversation.contactId }) {
            profile.conversations[index] = conversation
        } else {
            profile.conversations.append(conversation)
        }
    }

    private func updateContact(_ contact: Contact, in profile: inout IdentityProfile) {
        if let index = profile.contacts.firstIndex(where: { $0.id == contact.id }) {
            profile.contacts[index] = contact
        }
    }

    private func resendRecentMessages(contactId: UUID, count: Int, profile: inout IdentityProfile) async {
        guard count > 0 else { return }
        guard let contact = profile.contacts.first(where: { $0.id == contactId }) else {
            return
        }
        guard var conversation = conversation(for: contactId, in: profile) else {
            return
        }
        let sentMessages = conversation.messages.filter { $0.direction == .sent }
        guard !sentMessages.isEmpty else { return }
        let toResend = sentMessages.suffix(count)
        for message in toResend {
            do {
                let envelope = try MessageEngine.encrypt(
                    body: .text(message.body),
                    senderSigningKey: profile.identity.signingKey,
                    senderFingerprint: profile.identity.fingerprint,
                    conversation: &conversation,
                    kemCiphertext: nil
                )
                conversation.markMessageProcessed()
                try await deliverEnvelope(envelope, to: contact, preferredRelay: profile.relay)
            } catch {
                lastError = "Resend failed: \(error.localizedDescription)"
                break
            }
        }
        upsertConversation(conversation, in: &profile)
    }

    private func deliverEnvelope(_ envelope: Envelope, to contact: Contact, preferredRelay: RelayEndpoint) async throws {
        try await SessionRecovery.deliver(
            envelope: envelope,
            inboxId: contact.inboxId,
            preferredRelay: preferredRelay,
            destinationRelay: contact.relay
        )
    }

    private func markRecentSentMessagesAsMismatch(conversation: inout Conversation, count: Int) {
        guard count > 0 else { return }
        var remaining = count
        for index in conversation.messages.indices.reversed() {
            let message = conversation.messages[index]
            guard message.direction == .sent else { continue }
            if !message.isMismatch {
                conversation.messages[index] = Message(
                    id: message.id,
                    direction: message.direction,
                    body: message.body,
                    timestamp: message.timestamp,
                    counter: message.counter,
                    isMismatch: true,
                    attachment: message.attachment
                )
            }
            remaining -= 1
            if remaining == 0 {
                break
            }
        }
    }

    private func prepareAttachmentPayload(
        data: Data,
        fileName: String?,
        mimeType: String
    ) -> (data: Data, fileName: String?, mimeType: String) {
        guard mimeType.lowercased().hasPrefix("image/") else {
            return (data, fileName, mimeType)
        }
        guard let compressed = compressImageData(data) else {
            return (data, fileName, mimeType)
        }
        guard compressed.count < data.count else {
            return (data, fileName, mimeType)
        }
        var updatedName = fileName
        if let fileName, !fileName.isEmpty {
            let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            updatedName = "\(base).jpg"
        }
        return (compressed, updatedName, "image/jpeg")
    }

    private func compressImageData(_ data: Data) -> Data? {
        let maxDimension: CGFloat = 1600
        let quality: CGFloat = 0.82
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else {
            return nil
        }
        let scale = min(1, maxDimension / max(width, height))
        let targetWidth = Int(width * scale)
        let targetHeight = Int(height * scale)
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
        let type = UTType.jpeg.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, scaled, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
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

    private func pinMatches(_ pin: String, salt: Data?, hash: Data?) -> Bool {
        guard let salt, let hash else { return false }
        return pinHash(pin: pin, salt: salt) == hash
    }

    private func pinMatchesActionPin(_ pin: String) -> Bool {
        pinMatches(pin, salt: state.appLock.burnPinSalt, hash: state.appLock.burnPinHash)
            || pinMatches(pin, salt: state.appLock.clearChatsPinSalt, hash: state.appLock.clearChatsPinHash)
    }

    private func pinMatchesOtherActionPin(_ pin: String, action: AppLockPinAction) -> Bool {
        switch action {
        case .burnIdentity:
            return pinMatches(pin, salt: state.appLock.clearChatsPinSalt, hash: state.appLock.clearChatsPinHash)
        case .clearChats:
            return pinMatches(pin, salt: state.appLock.burnPinSalt, hash: state.appLock.burnPinHash)
        }
    }

    private static func loadStorageProtectionMode() -> StorageProtectionMode? {
        if let raw = UserDefaults.standard.string(forKey: storageModeKey),
           let mode = StorageProtectionMode(rawValue: raw) {
            return mode
        }
        if UserDefaults.standard.bool(forKey: legacyKeychainConsentKey) {
            return .keychain
        }
        return nil
    }

    private func persistStorageProtectionMode(_ mode: StorageProtectionMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: ClientViewModel.storageModeKey)
        if mode == .keychain {
            UserDefaults.standard.set(true, forKey: ClientViewModel.legacyKeychainConsentKey)
        }
    }

    private func configureStores(for mode: StorageProtectionMode) {
        store = ClientStateStore(fileURL: stateFileURL, useEncryption: mode.usesKeychain)
        attachmentStore = AttachmentStore(directory: attachmentDirectory, useEncryption: mode.usesKeychain)
    }

    private func migrateAttachments(from oldStore: AttachmentStore, to newStore: AttachmentStore) throws {
        guard oldStore !== newStore else { return }
        var uniqueAttachments: [(String, AttachmentDescriptor)] = []
        var seen = Set<String>()
        for conversation in state.conversations {
            for message in conversation.messages {
                guard let attachment = message.attachment,
                      let fileName = attachment.localFileName else {
                    continue
                }
                if seen.insert(fileName).inserted {
                    uniqueAttachments.append((fileName, attachment.descriptor))
                }
            }
        }
        for (fileName, descriptor) in uniqueAttachments {
            let data = try oldStore.loadAttachment(fileName: fileName)
            _ = try newStore.saveAttachment(data, descriptor: descriptor)
        }
    }

    private func pinHash(pin: String, salt: Data) -> Data {
        let data = salt + Data(pin.utf8)
        return Data(SHA256.hash(data: data))
    }
}
