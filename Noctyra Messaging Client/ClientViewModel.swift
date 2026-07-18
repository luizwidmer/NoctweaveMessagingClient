import CryptoKit
import Combine
import Foundation
import LocalAuthentication
import NoctweaveCore

enum ClientBootState: Equatable {
    case loading
    case ready
    case failed(String)
}

private enum NoctyraClientError: Error, LocalizedError {
    case invalidPairingLink
    case pairingExpired
    case relayRejected(String)
    case missingPairingFrame(UInt64)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidPairingLink:
            return "The one-use pairing invitation is invalid."
        case .pairingExpired:
            return "The one-use pairing invitation expired. Start a fresh exchange."
        case .relayRejected(let message):
            return message
        case .missingPairingFrame(let sequence):
            return "The pairing exchange is missing transport frame \(sequence)."
        case .unavailable:
            return "The encrypted client state is not ready."
        }
    }
}

private struct NoctyraPairingLinkV1: Codable {
    static let prefix = "noctyra-pair-v1:"
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
            throw NoctyraClientError.invalidPairingLink
        }
        return value
    }

    static func decode(_ value: String) throws -> NoctyraPairingLinkV1 {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix(prefix),
              normalized.count <= maximumCharacters,
              let data = Data(base64Encoded: String(normalized.dropFirst(prefix.count))) else {
            throw NoctyraClientError.invalidPairingLink
        }
        let decoded = try NoctweaveCoder.decode(NoctyraPairingLinkV1.self, from: data)
        guard decoded.version == 1,
              decoded.relay.isStructurallyValid,
              decoded.invitation.isStructurallyValid else {
            throw NoctyraClientError.invalidPairingLink
        }
        return decoded
    }
}

@MainActor
final class ClientViewModel: ObservableObject {
    @Published private(set) var bootState: ClientBootState = .loading
    @Published private(set) var state: ClientState?
    @Published var selectedRelationshipID: UUID?
    @Published var draftMessage = ""
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage = "Opening encrypted local state…"
    @Published private(set) var lastError: String?

    @Published private(set) var isPairing = false
    @Published private(set) var pairingLink: String?
    @Published private(set) var pairingStatus = ""

    @Published private(set) var isLocked = false
    @Published private(set) var biometricStepPassed = false
    @Published private(set) var lockError: String?

    private let stateStore: ClientStateStore
    private var client: HeadlessMessagingClient?
    private var pairingTask: Task<Void, Never>?
    private var failedPINAttempts = 0
    private var pinLockedUntil: Date?

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("NoctyraClient", isDirectory: true)
        let isUITest = ProcessInfo.processInfo.arguments.contains("UI_TESTING")
        let stateURL = isUITest
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("NoctyraCleanV1UITests", isDirectory: true)
                .appendingPathComponent("client-state-v1.nwstate")
            : support.appendingPathComponent("client-state-v1.nwstate")
        if isUITest { try? FileManager.default.removeItem(at: stateURL) }
        stateStore = ClientStateStore(
            fileURL: stateURL,
            useEncryption: true
        )
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
        activePersona?.groupRuntimes.sorted {
            $0.groupId.uuidString < $1.groupId.uuidString
        } ?? []
    }

    var selectedRelationship: PairwiseRelationshipV2? {
        guard let selectedRelationshipID else { return nil }
        return relationships.first { $0.id == selectedRelationshipID }
    }

    var selectedEvents: [ConversationEvent] {
        selectedRelationship?.events.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        } ?? []
    }

    var appLockMode: AppLockMode {
        state?.appLock.mode ?? .off
    }

    var appLockMessage: String {
        let value = state?.appLock.lockScreenMessage
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Your encrypted conversations are locked." : value
    }

    func open() async {
        bootState = .loading
        do {
            let opened = try await HeadlessMessagingClient.open(
                stateStore: stateStore,
                displayName: "Local Persona"
            )
            client = opened
            try await refresh()
            isLocked = appLockMode != .off
            statusMessage = "Encrypted local state is ready."
            bootState = .ready
        } catch {
            let message = describe(error)
            lastError = message
            bootState = .failed(message)
        }
    }

    func refresh() async throws {
        guard let client else { throw NoctyraClientError.unavailable }
        let snapshot = await client.snapshot()
        state = snapshot
        #if os(iOS)
        try OpaqueRoutePrefetchBridge.update(from: snapshot)
        #endif
        let available = snapshot.personas
            .first { $0.id == snapshot.activePersonaID }?
            .relationships ?? []
        if let selectedRelationshipID,
           !available.contains(where: { $0.id == selectedRelationshipID }) {
            self.selectedRelationshipID = nil
        }
        if self.selectedRelationshipID == nil {
            self.selectedRelationshipID = available.first?.id
        }
    }

    func sendDraft() {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let relationshipID = selectedRelationshipID else { return }
        draftMessage = ""
        runOperation(label: "Sending…") { client in
            _ = try await client.sendText(text, relationshipID: relationshipID)
            self.statusMessage = "Message persisted and submitted through opaque routes."
        }
    }

    func syncAll() {
        runOperation(label: "Maintaining routes and synchronizing…") { client in
            var maintenanceError: Error?
            do {
                _ = try await client.maintainAllRelationships()
            } catch {
                maintenanceError = error
            }

            let relationshipIDs = (await client.activePersona()).relationships.map(\.id)
            var received = 0
            var syncErrors: [Error] = []
            for relationshipID in relationshipIDs {
                do {
                    for _ in 0..<8 {
                        let batches = try await client.sync(relationshipID: relationshipID)
                        received += batches.reduce(0) { $0 + $1.receivedEvents.count }
                        if !batches.contains(where: \.hasMore) { break }
                    }
                } catch {
                    syncErrors.append(error)
                }
            }

            if let first = syncErrors.first ?? maintenanceError {
                self.statusMessage = "Sync completed with partial relay availability: \(self.describe(first))"
            } else {
                self.statusMessage = "Sync complete. \(received) new event\(received == 1 ? "" : "s")."
            }
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

    func burnPersona(replacementName: String = "Local Persona") {
        runOperation(label: "Burning local persona…") { client in
            _ = try await client.burnActivePersona(replacementDisplayName: replacementName)
            self.selectedRelationshipID = nil
            self.statusMessage = "The local persona was burned and replaced without continuity."
        }
    }

    func startOfferingPairing(relayText: String, pseudonym: String) {
        guard !isPairing else { return }
        isPairing = true
        pairingLink = nil
        pairingStatus = "Preparing fresh relationship authority and opaque route…"
        lastError = nil
        pairingTask = Task { [weak self] in
            await self?.runOffererPairing(relayText: relayText, pseudonym: pseudonym)
        }
    }

    func startAcceptingPairing(link: String, pseudonym: String) {
        guard !isPairing else { return }
        isPairing = true
        pairingLink = nil
        pairingStatus = "Opening the one-use encrypted rendezvous…"
        lastError = nil
        pairingTask = Task { [weak self] in
            await self?.runResponderPairing(link: link, pseudonym: pseudonym)
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingStatus = "Cancelling and removing the temporary relay lanes…"
    }

    func clearPairingLink() {
        pairingLink = nil
        pairingStatus = ""
    }

    func lockNow() {
        biometricStepPassed = false
        lockError = nil
        isLocked = true
    }

    func lockForBackgroundIfConfigured() {
        if appLockMode != .off { lockNow() }
    }

    func unlockWithBiometrics() async {
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
                localizedReason: "Unlock encrypted Noctyra conversations"
            )
            guard accepted else {
                lockError = "Biometric authentication failed."
                return
            }
            if appLockMode == .biometricsAndPin {
                biometricStepPassed = true
            } else {
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
        isLocked = false
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

    func isOutgoing(_ event: ConversationEvent) -> Bool {
        event.authorEndpointHandle == selectedRelationship?.localEndpointHandle
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
                guard let client else { throw NoctyraClientError.unavailable }
                try await operation(client)
                try await refresh()
            } catch {
                lastError = describe(error)
                statusMessage = "The operation did not complete."
            }
        }
    }

    private func runOffererPairing(relayText: String, pseudonym: String) async {
        var cleanup: (RelayClient, RendezvousRelayAdapterV2)?
        defer {
            isPairing = false
            pairingTask = nil
        }
        do {
            guard let client else { throw NoctyraClientError.unavailable }
            let endpoint = try RelayEndpointParser.parse(relayText)
            let localPseudonym = try validatedPseudonym(pseudonym)
            let now = Date()
            let pendingParticipant = try await client.prepareContactParticipant(
                relay: endpoint,
                relationshipPseudonym: localPseudonym,
                createdAt: now
            )
            let participant = try await client.activateContactParticipant(pendingParticipant)
            var offer = try await client.makeContactPairingInvitation(
                createdAt: now,
                expiresAt: now.addingTimeInterval(10 * 60)
            )
            let adapter = try RendezvousRelayAdapterV2(offer: offer.invitation.offer)
            let relay = RelayClient(endpoint: endpoint)
            cleanup = (relay, adapter)

            try requireEmpty(
                await relay.send(.registerRendezvousTransportV2(adapter.registrationRequest))
            )
            pairingLink = try NoctyraPairingLinkV1(
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
                throw NoctyraClientError.invalidPairingLink
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
                throw NoctyraClientError.invalidPairingLink
            }
            let completion = try flow.receiveConfirmation(confirmation, at: Date())
            let scope = await client.mintActivePersonaScopeToken()
            try await client.addRelationship(
                completion.relationship,
                consent: .accepted,
                personaScope: scope
            )
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
            pairingLink = nil
            if error is CancellationError {
                pairingStatus = "Pairing cancelled. Start with a fresh invitation."
            } else {
                lastError = describe(error)
                pairingStatus = "Pairing did not complete. Start with a fresh invitation."
            }
        }
    }

    private func runResponderPairing(link: String, pseudonym: String) async {
        var cleanup: (RelayClient, RendezvousRelayAdapterV2)?
        defer {
            isPairing = false
            pairingTask = nil
        }
        do {
            guard let client else { throw NoctyraClientError.unavailable }
            let shared = try NoctyraPairingLinkV1.decode(link)
            guard Date() < shared.invitation.offer.expiresAt else {
                throw NoctyraClientError.pairingExpired
            }
            let localPseudonym = try validatedPseudonym(pseudonym)
            let adapter = try RendezvousRelayAdapterV2(offer: shared.invitation.offer)
            let relay = RelayClient(endpoint: shared.relay)
            cleanup = (relay, adapter)
            try requireEmpty(
                await relay.send(.registerRendezvousTransportV2(adapter.registrationRequest))
            )

            let pendingParticipant = try await client.prepareContactParticipant(
                relay: shared.relay,
                relationshipPseudonym: localPseudonym
            )
            let participant = try await client.activateContactParticipant(pendingParticipant)
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
                throw NoctyraClientError.invalidPairingLink
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
                throw NoctyraClientError.invalidPairingLink
            }
            let relationship = try flow.receiveConfirmation(finalConfirmation, at: Date())
            let scope = await client.mintActivePersonaScopeToken()
            try await client.addRelationship(
                relationship,
                consent: .accepted,
                personaScope: scope
            )
            await deleteTemporaryLanes(relay: relay, adapter: adapter)
            cleanup = nil
            pairingStatus = "A fresh unlinkable relationship is ready."
            try await refresh()
        } catch {
            if let cleanup {
                await deleteTemporaryLanes(relay: cleanup.0, adapter: cleanup.1)
            }
            if error is CancellationError {
                pairingStatus = "Pairing cancelled. Start with a fresh invitation."
            } else {
                lastError = describe(error)
                pairingStatus = "Pairing did not complete. Start with a fresh invitation."
            }
        }
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
                throw NoctyraClientError.relayRejected(
                    response.error?.message ?? "The relay rejected the pairing sync."
                )
            }
            let frames = batch.frames.sorted { $0.sequence < $1.sequence }
            if frames.contains(where: { $0.sequence == throughSequence }) {
                return frames
            }
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        throw NoctyraClientError.pairingExpired
    }

    private func frame(
        sequence: UInt64,
        in frames: [RendezvousRelayCiphertextFrameV2]
    ) throws -> RendezvousRelayCiphertextFrameV2 {
        guard let value = frames.first(where: { $0.sequence == sequence }) else {
            throw NoctyraClientError.missingPairingFrame(sequence)
        }
        return value
    }

    private func requireEmpty(_ response: RelayResponse) throws {
        guard response.status == .success, case .empty? = response.successBody else {
            throw NoctyraClientError.relayRejected(
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
            throw NoctyraClientError.invalidPairingLink
        }
        return normalized
    }

    private func matchesStructuredPIN(
        _ pin: String,
        salt: Data,
        expected: Data
    ) -> Bool {
        let digits = pin.filter(\.isNumber)
        guard digits.count == 6,
              expected.count == 41,
              expected.prefix(5) == Data("NPIN2".utf8) else {
            return false
        }
        var rounds: UInt32 = 0
        for byte in expected[5..<9] {
            rounds = (rounds << 8) | UInt32(byte)
        }
        guard (10_000...500_000).contains(Int(rounds)) else { return false }
        let key = SymmetricKey(data: Data(digits.utf8))
        var block = Data(HMAC<SHA256>.authenticationCode(for: salt, using: key))
        var digest = block
        if rounds > 1 {
            for _ in 2...rounds {
                block = Data(HMAC<SHA256>.authenticationCode(for: block, using: key))
                for index in digest.indices { digest[index] ^= block[index] }
            }
        }
        let stored = Data(expected.suffix(32))
        guard digest.count == stored.count else { return false }
        var difference: UInt8 = 0
        for index in digest.indices { difference |= digest[index] ^ stored[index] }
        return difference == 0
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
