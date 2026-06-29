import Foundation
import PICCPCore

struct CiphertextPrefetchResult: Equatable {
    var fetchedEnvelopeCount: Int
    var profileCount: Int
    var failures: [String]
}

@MainActor
struct CiphertextPrefetchRunner {
    private let store: CiphertextPrefetchStore
    private let maxEnvelopeCountPerProfile: Int

    init(
        store: CiphertextPrefetchStore,
        maxEnvelopeCountPerProfile: Int = 100
    ) {
        self.store = store
        self.maxEnvelopeCountPerProfile = maxEnvelopeCountPerProfile
    }

    static func runDefault() async -> CiphertextPrefetchResult {
        await CiphertextPrefetchRunner(store: CiphertextPrefetchStore()).run()
    }

    func run() async -> CiphertextPrefetchResult {
        let startedAt = Date()
        do {
            guard let config = try store.loadConfig(), !config.profiles.isEmpty else {
                let status = NoctyraPrefetchStatus(
                    lastAttemptAt: startedAt,
                    lastSuccessAt: nil,
                    lastResult: "No prefetch profiles are configured.",
                    lastFetchedEnvelopeCount: 0,
                    pendingEnvelopeCount: (try? store.loadStatus().pendingEnvelopeCount) ?? 0
                )
                try? store.saveStatus(status)
                return CiphertextPrefetchResult(fetchedEnvelopeCount: 0, profileCount: 0, failures: [status.lastResult ?? "No profiles."])
            }

            var fetchedCount = 0
            var failures: [String] = []
            for profile in config.profiles {
                do {
                    let envelopes = try await fetchDirectEnvelopes(for: profile)
                    let records = envelopes.map {
                        PrefetchedDirectEnvelopeRecord(
                            profileId: profile.id,
                            inboxId: profile.inboxId,
                            relay: profile.relay,
                            fetchedAt: Date(),
                            envelope: $0
                        )
                    }
                    try store.appendDirectEnvelopes(records)
                    fetchedCount += records.count
                } catch {
                    failures.append("\(profile.displayName): \(error.localizedDescription)")
                }
                for group in profile.groups {
                    do {
                        let envelopes = try await fetchGroupEnvelopes(group, for: profile)
                        let records = envelopes.map {
                            PrefetchedGroupEnvelopeRecord(
                                profileId: profile.id,
                                groupId: group.id,
                                groupInboxId: group.groupInboxId,
                                relay: profile.relay,
                                fetchedAt: Date(),
                                envelope: $0
                            )
                        }
                        try store.appendGroupEnvelopes(records)
                        fetchedCount += records.count
                    } catch {
                        failures.append("\(profile.displayName)/\(group.title): \(error.localizedDescription)")
                    }
                }
            }

            let pendingCount = (try? store.loadStatus().pendingEnvelopeCount) ?? 0
            let resultText = failures.isEmpty
                ? "Fetched \(fetchedCount) encrypted envelope(s)."
                : "Fetched \(fetchedCount) encrypted envelope(s); \(failures.count) profile(s) failed."
            try? store.saveStatus(
                NoctyraPrefetchStatus(
                    lastAttemptAt: startedAt,
                    lastSuccessAt: failures.isEmpty ? Date() : nil,
                    lastResult: resultText,
                    lastFetchedEnvelopeCount: fetchedCount,
                    pendingEnvelopeCount: pendingCount
                )
            )
            return CiphertextPrefetchResult(
                fetchedEnvelopeCount: fetchedCount,
                profileCount: config.profiles.count,
                failures: failures
            )
        } catch {
            try? store.saveStatus(
                NoctyraPrefetchStatus(
                    lastAttemptAt: startedAt,
                    lastSuccessAt: nil,
                    lastResult: error.localizedDescription,
                    lastFetchedEnvelopeCount: 0,
                    pendingEnvelopeCount: 0
                )
            )
            return CiphertextPrefetchResult(fetchedEnvelopeCount: 0, profileCount: 0, failures: [error.localizedDescription])
        }
    }

    private func fetchDirectEnvelopes(for profile: NoctyraPrefetchProfile) async throws -> [Envelope] {
        var request = FetchRequest(
            inboxId: profile.inboxId,
            routingToken: profile.inboxId,
            maxCount: maxEnvelopeCountPerProfile,
            longPollTimeoutSeconds: nil
        )
        let publicKey = profile.inboxAccessKey.publicKeyData
        let proof = try makeActorProof(
            signingKey: profile.inboxAccessKey,
            publicSigningKey: publicKey
        ) { actorProof in
            try request.signableData(for: actorProof)
        }
        request = FetchRequest(
            inboxId: profile.inboxId,
            routingToken: profile.inboxId,
            maxCount: maxEnvelopeCountPerProfile,
            longPollTimeoutSeconds: nil,
            accessProof: proof
        )
        let response = try await RelayClient(endpoint: profile.relay, authToken: profile.relayAuthToken)
            .send(.fetch(request), timeout: 8)
        guard response.type == .messages else {
            throw NSError(
                domain: "Noctyra.CiphertextPrefetch",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: response.error ?? "Relay did not return encrypted messages."]
            )
        }
        return response.messages ?? []
    }

    private func fetchGroupEnvelopes(
        _ group: NoctyraPrefetchGroup,
        for profile: NoctyraPrefetchProfile
    ) async throws -> [GroupRatchetEnvelope] {
        var request = FetchGroupMessagesRequest(
            groupId: group.id,
            groupInboxId: group.groupInboxId,
            maxCount: maxEnvelopeCountPerProfile,
            actorFingerprint: profile.identityFingerprint
        )
        let publicKey = profile.identitySigningKey.publicKeyData
        let proof = try makeActorProof(
            signingKey: profile.identitySigningKey,
            publicSigningKey: publicKey
        ) { actorProof in
            try request.signableData(for: actorProof)
        }
        request = FetchGroupMessagesRequest(
            groupId: group.id,
            groupInboxId: group.groupInboxId,
            maxCount: maxEnvelopeCountPerProfile,
            actorFingerprint: profile.identityFingerprint,
            actorProof: proof
        )
        let response = try await RelayClient(endpoint: profile.relay, authToken: profile.relayAuthToken)
            .send(.fetchGroupMessages(request), timeout: 8)
        guard response.type == .groupMessages else {
            throw NSError(
                domain: "Noctyra.CiphertextPrefetch",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: response.error ?? "Relay did not return encrypted group messages."]
            )
        }
        return response.groupMessages ?? []
    }

    private func makeActorProof(
        signingKey: SigningKeyPair,
        publicSigningKey: Data,
        signableDataBuilder: (RelayActorProof) throws -> Data
    ) throws -> RelayActorProof {
        let signedAt = Date()
        let nonce = UUID()
        let placeholder = RelayActorProof(
            fingerprint: CryptoBox.fingerprint(for: publicSigningKey),
            publicSigningKey: publicSigningKey,
            signedAt: signedAt,
            nonce: nonce,
            signature: Data()
        )
        let signature = try signingKey.sign(try signableDataBuilder(placeholder))
        return RelayActorProof(
            fingerprint: CryptoBox.fingerprint(for: publicSigningKey),
            publicSigningKey: publicSigningKey,
            signedAt: signedAt,
            nonce: nonce,
            signature: signature
        )
    }
}
