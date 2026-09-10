import CryptoKit
import Foundation
import NoctweaveCore
import Security

@main
struct ClientDuressTransitionTests {
    enum Failure: Error { case assertion(String), interrupted }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }
    @MainActor
    static func main() async throws {
        try require(!NoctweaveUITestRuntime.isEnabled, "Production prefetch cleanup must not be skipped by a UI fixture")
        // macOS has no iOS widget access-group entitlement. Its real cleanup
        // path must succeed without attempting to erase that shared Keychain.
        try OpaqueRoutePrefetchBridge.eraseAllLocalState()
        for interrupted in [false, true] {
            try await checkReplacement(interrupted: interrupted)
        }
        print("Duress transition checks passed: real Keychain rotation, selective attachment retention, durable new password, old-writer fencing, and restart after interrupted cleanup.")
    }

    @MainActor
    private static func checkReplacement(interrupted: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noctweave-replacement-test-\(UUID())")
        let scope = "org.noctweave.tests.replacement.\(UUID())"
        let storage = ClientStorageSession(stateURL: root.appendingPathComponent("state.nwstate"),
            attachmentsURL: root.appendingPathComponent("attachments"), scope: scope,
            usesFixtureKeys: false, usesPlaintextFixture: false, clearsSupportDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            for suffix in [""] + AppLockDuressAction.allCases.map({ ".replacement.\($0.rawValue)" }) {
                let identifier = scope + suffix
                let stateDigest = Data(SHA256.hash(data: Data("noctweave.client-state.scope.v2\0".utf8) + Data(identifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                let anchorDigest = Data(SHA256.hash(data: Data("noctweave.client-state.anchor.v2\0".utf8) + Data(identifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                let attachmentDigest = Data(SHA256.hash(data: Data(identifier.utf8))).base64EncodedString()
                for (service, account) in [("org.noctweave.securestorage", "vault-key-v3-" + stateDigest),
                                           ("org.noctweave.securestorage", "state-anchor-v2-" + anchorDigest),
                                           ("com.noctweave.securestorage", "attachment-vault-v2-" + attachmentDigest)] {
                    SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecAttrSynchronizable as String: kCFBooleanFalse as Any] as CFDictionary)
                }
            }
        }
        let oldState = storage.stateStore()
        let oldAttachments = storage.attachments()
        var state = try ClientState(displayName: "Retained persona", hasCompletedOnboarding: true,
            hasAcceptedPrivacyPolicy: true, hasAcceptedTermsOfUse: true)
        let keptID = UUID(), erasedID = UUID()
        let retainedBytes = Data("Retained attachment".utf8)
        let erasedBytes = Data("Erased attachment".utf8)
        var relationship = try makeRelationship()
        let descriptor = AttachmentDescriptor(id: keptID, fileName: nil, mimeType: "text/plain", byteCount: retainedBytes.count,
            sha256: Data(SHA256.hash(data: retainedBytes)), chunkCount: 1, chunkSize: retainedBytes.count)
        _ = try relationship.appendEvent(ConversationEvent(conversationId: relationship.conversationID,
            authorEndpointHandle: relationship.localEndpointHandle, createdAt: Date(timeIntervalSince1970: 1_788_000_000),
            kind: .application, content: EncodedContent(type: .attachment, payload: try NoctweaveCoder.encode(descriptor))))
        try state.updateActivePersona { try $0.upsert(relationship: relationship) }
        _ = try oldAttachments.saveSanitizedAttachment(retainedBytes, attachmentId: keptID)
        _ = try oldAttachments.saveSanitizedAttachment(erasedBytes, attachmentId: erasedID)
        let plan = try AppLockDuressPassword.makePlan(password: "future password", label: "Test", action: .decoy,
            decoyChats: [.init(personaID: state.activePersonaID, kind: .relationship, chatID: relationship.id)])
        let oldPIN = try AppLockPINV2.makeRecord(pin: "123456")
        state.appLock = AppLockSettings(mode: .pinOnly, pinSalt: oldPIN.salt, pinHash: oldPIN.encodedHash, duressPlans: [plan])
        try await oldState.save(state, replacing: nil)
        let frozen = try await oldState.suspendForLocalTransition()!
        oldAttachments.suspendWritesForLocalTransition()
        let replacement = try frozen.replacementAfterDuress(plan: plan, password: "future password")
        let transition = ClientDuressTransition(storage: storage)
        try await transition.stage(replacement, action: .decoy, sourceAttachments: oldAttachments, groupNames: [:])
        let before = try await transition.pending()
        try require(before != nil, "Durable transition missing before cleanup")
        if interrupted {
            do {
                try await transition.complete(replacement, action: .decoy, oldState: oldState, oldAttachments: oldAttachments) {
                    throw Failure.interrupted
                }
                throw Failure.assertion("Interruption was ignored")
            } catch Failure.interrupted { }
            let restarted = ClientDuressTransition(storage: storage)
            guard let (action, pendingState) = try await restarted.pending() else { throw Failure.assertion("Interrupted intent lost") }
            try await restarted.complete(pendingState, action: action, oldState: storage.stateStore(), oldAttachments: storage.attachments(), clearSideEffects: {})
        } else {
            try await transition.complete(replacement, action: .decoy, oldState: oldState, oldAttachments: oldAttachments, clearSideEffects: {})
        }
        let reloaded = try await storage.stateStore().load()!
        try require(reloaded.appLock.duressPlans.isEmpty, "Action remained armed")
        try require(AppLockPasswordV1.verify(password: "future password", salt: reloaded.appLock.pinSalt!, encodedHash: reloaded.appLock.pinHash!), "New password did not survive restart")
        try require(!AppLockPasswordV1.verify(password: "123456", salt: reloaded.appLock.pinSalt!, encodedHash: reloaded.appLock.pinHash!), "Old password still works")
        let kept = try storage.attachments().loadSanitizedAttachment(fileName: "\(keptID.uuidString).bin")
        try require(kept == retainedBytes, "Kept attachment changed")
        try require(storage.attachments().existingFileName(attachmentId: erasedID) == nil, "Unselected attachment survived")
        try require(try await transition.pending() == nil, "Transition stayed armed")
        do { try await oldState.save(state, replacing: nil); throw Failure.assertion("Old state writer resumed") }
        catch is ClientStateStoreError { }
        do { try await oldState.destroyLocalEncryptionMaterial(preservingCiphertext: false); throw Failure.assertion("Old cleanup erased replacement") }
        catch is ClientStateStoreError { }
        do { _ = try oldAttachments.saveSanitizedAttachment(erasedBytes, attachmentId: erasedID); throw Failure.assertion("Old attachment writer resumed") }
        catch is ClientAttachmentStoreError { }
        let stillPresent = try await storage.stateStore().load()
        try require(stillPresent?.activePersonaID == reloaded.activePersonaID, "Old session destroyed fresh state")
        let orphan = root.appendingPathComponent("interrupted-write.tmp")
        try Data("orphaned fixture".utf8).write(to: orphan)
        let fullReset = ClientFullReset(storage: storage)
        try fullReset.begin()
        do {
            try await fullReset.complete { throw Failure.interrupted }
            throw Failure.assertion("Full reset ignored cleanup failure")
        } catch Failure.interrupted { }
        try require(fullReset.isPending, "Full reset intent was lost on failure")
        try await ClientFullReset(storage: storage).complete(clearSideEffects: {})
        try require(!fullReset.isPending, "Full reset did not finish")
        try require(!FileManager.default.fileExists(atPath: orphan.path), "Interrupted temporary file survived purge")
        try require(try await storage.stateStore().load() == nil, "Active state survived purge")
        try require(try await transition.pending() == nil, "Replacement state survived purge")
        try require(!FileManager.default.fileExists(atPath: storage.attachmentsURL.path), "Attachments survived purge")
        try require(try await storage.stateStore().isAwaitingFreshState(), "Reset lost rollback tombstone")
    }

    private static func makeRelationship() throws -> PairwiseRelationshipV2 {
        var offer = try ContactPairingHandshakeV2.makeOffer(
            createdAt: Date(timeIntervalSince1970: 1_788_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_788_000_000).addingTimeInterval(300)
        )
        let first = try activateParticipant(name: "A", host: "a.example")
        let second = try activateParticipant(name: "B", host: "b.example")
        var ledger = RendezvousRedemptionLedgerV2()
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let response = try ContactPairingResponderFlowV2.begin(invitation: offer.invitation, participant: second, at: now.addingTimeInterval(1))
        var responderFlow = response.flow
        let offered = try ContactPairingOffererFlowV2.begin(pendingOffer: &offer.pending, invitation: offer.invitation,
            participant: first, openRequest: response.openRequest, acceptanceFrame: response.acceptanceFrame,
            ledger: &ledger, at: now.addingTimeInterval(2))
        var offererFlow = offered.flow
        let confirmation = try responderFlow.receiveOffer(offered.offerFrame, at: now.addingTimeInterval(3))
        return try offererFlow.receiveConfirmation(confirmation, at: now.addingTimeInterval(4)).relationship
    }

    private static func activateParticipant(
        name: String,
        host: String
    ) throws -> PreparedContactParticipantV2 {
        let pending = try PendingContactParticipantV2.prepare(
            relationshipPseudonym: name,
            relay: RelayEndpoint(
                host: host,
                port: 443,
                useTLS: true,
                transport: .websocket
            ),
            createdAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let route = try OpaqueReceiveRouteV2.creating(
            from: pending.routeCreateRequest,
            presentedRenewCapability: pending.clientCapabilities.renewCapability,
            existing: nil,
            confidentialTransport: true,
            receivedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        return try pending.activate(createdRoute: route)
    }

}
