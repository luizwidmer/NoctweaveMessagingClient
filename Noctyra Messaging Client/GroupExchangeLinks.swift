import CryptoKit
import Foundation
import NoctweaveCore

enum NoctyraGroupExchangeLinkError: Error, LocalizedError {
    case invalidLink
    case expiredLink
    case requestMismatch

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            return "The group exchange artifact is invalid or unsupported."
        case .expiredLink:
            return "The one-use group admission expired. Prepare a fresh request."
        case .requestMismatch:
            return "The invitation response does not match the saved one-use admission."
        }
    }
}

private struct NoctyraGroupExchangeCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func requireExactGroupExchangeFields<Key: CodingKey & CaseIterable>(
    _ decoder: Decoder,
    _ keyType: Key.Type
) throws where Key.AllCases: Collection {
    let strict = try decoder.container(keyedBy: NoctyraGroupExchangeCodingKey.self)
    guard Set(strict.allKeys.map(\.stringValue))
            == Set(keyType.allCases.map(\.stringValue)) else {
        throw NoctyraGroupExchangeLinkError.invalidLink
    }
}

private enum NoctyraGroupExchangeCodec {
    static let maximumDecodedBytes = 16 * 1_024 * 1_024
    static let maximumEncodedCharacters = 24 * 1_024 * 1_024

    static func encode<T: Encodable>(_ value: T, prefix: String) throws -> String {
        let bytes = try NoctweaveCoder.encode(value, sortedKeys: true)
        guard bytes.count <= maximumDecodedBytes else {
            throw NoctyraGroupExchangeLinkError.invalidLink
        }
        let encoded = prefix + bytes.base64EncodedString()
        guard encoded.count <= maximumEncodedCharacters else {
            throw NoctyraGroupExchangeLinkError.invalidLink
        }
        return encoded
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        value: String,
        prefix: String
    ) throws -> T {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix(prefix),
              normalized.count <= maximumEncodedCharacters,
              let bytes = Data(base64Encoded: String(normalized.dropFirst(prefix.count))),
              bytes.count <= maximumDecodedBytes else {
            throw NoctyraGroupExchangeLinkError.invalidLink
        }
        return try NoctweaveCoder.decode(type, from: bytes)
    }
}

/// Public, group-scoped admission material that a prospective member sends
/// through an already authenticated and encrypted channel. `admissionID` is
/// only a local replay handle; it creates no persona, account, or device link.
struct NoctyraGroupAdmissionRequestLinkV1: Codable {
    static let prefix = "noctyra-group-admission-v1:"
    static let version = 1

    let version: Int
    let admissionID: UUID
    let groupID: UUID
    let invitationBindingDigest: Data
    let admission: GroupCredentialAdmissionV2
    let initialRouteSet: SignedGroupOpaqueRouteSetV2

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case admissionID
        case groupID
        case invitationBindingDigest
        case admission
        case initialRouteSet
    }

    init(
        admissionID: UUID,
        groupID: UUID,
        invitationBindingDigest: Data,
        admission: GroupCredentialAdmissionV2,
        initialRouteSet: SignedGroupOpaqueRouteSetV2
    ) throws {
        version = Self.version
        self.admissionID = admissionID
        self.groupID = groupID
        self.invitationBindingDigest = invitationBindingDigest
        self.admission = admission
        self.initialRouteSet = initialRouteSet
        guard isValid(at: Date()) else {
            throw NoctyraGroupExchangeLinkError.invalidLink
        }
    }

    init(from decoder: Decoder) throws {
        try requireExactGroupExchangeFields(decoder, CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        admissionID = try values.decode(UUID.self, forKey: .admissionID)
        groupID = try values.decode(UUID.self, forKey: .groupID)
        invitationBindingDigest = try values.decode(Data.self, forKey: .invitationBindingDigest)
        admission = try values.decode(GroupCredentialAdmissionV2.self, forKey: .admission)
        initialRouteSet = try values.decode(
            SignedGroupOpaqueRouteSetV2.self,
            forKey: .initialRouteSet
        )
        guard isValid(at: Date()) else {
            throw NoctyraGroupExchangeLinkError.invalidLink
        }
    }

    func encoded() throws -> String {
        try NoctyraGroupExchangeCodec.encode(self, prefix: Self.prefix)
    }

    static func decode(_ value: String) throws -> Self {
        try NoctyraGroupExchangeCodec.decode(Self.self, value: value, prefix: Self.prefix)
    }

    var requestDigest: Data {
        get throws {
            var material = Data("org.noctyra.group-admission-request/v1\0".utf8)
            material.append(try NoctweaveCoder.encode(self, sortedKeys: true))
            return Data(SHA256.hash(data: material))
        }
    }

    func isValid(at date: Date) -> Bool {
        version == Self.version
            && invitationBindingDigest.count == SHA256.byteCount
            && admission.groupId == groupID
            && admission.expiresAt > date
            && initialRouteSet.groupID == groupID
            && initialRouteSet.ownerCredentialHandle == admission.credentialHandle
            && initialRouteSet.ownerAdmissionDigest == admission.digest
            && initialRouteSet.verify(ownerSigningPublicKey: admission.groupSigningPublicKey)
            && !initialRouteSet.usableRoutes(at: date).isEmpty
    }
}

/// The exact owner-produced artifacts for one saved admission request. Core
/// verification remains authoritative; the request digest prevents the UI
/// from applying a valid response to a different pending admission.
struct NoctyraGroupAdmissionResponseLinkV1: Codable {
    static let prefix = "noctyra-group-welcome-v1:"
    static let version = 1

    let version: Int
    let admissionID: UUID
    let groupID: UUID
    let invitationBindingDigest: Data
    let requestDigest: Data
    let anchor: GroupJoinAnchorV2
    let transition: GroupEpochTransitionEnvelopeV2
    let welcome: SignedGroupWelcomeV2
    let existingMemberRouteAnnouncements: [SignedGroupRouteSetAnnouncementV2]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case admissionID
        case groupID
        case invitationBindingDigest
        case requestDigest
        case anchor
        case transition
        case welcome
        case existingMemberRouteAnnouncements
    }

    init(
        request: NoctyraGroupAdmissionRequestLinkV1,
        prepared: HeadlessPreparedGroupMemberAdditionV2
    ) throws {
        version = Self.version
        admissionID = request.admissionID
        groupID = request.groupID
        invitationBindingDigest = request.invitationBindingDigest
        requestDigest = try request.requestDigest
        anchor = prepared.anchor
        transition = prepared.transition
        welcome = prepared.welcome
        existingMemberRouteAnnouncements = prepared.existingMemberRouteAnnouncements
        guard isStructurallyValid else {
            throw NoctyraGroupExchangeLinkError.invalidLink
        }
    }

    init(from decoder: Decoder) throws {
        try requireExactGroupExchangeFields(decoder, CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        admissionID = try values.decode(UUID.self, forKey: .admissionID)
        groupID = try values.decode(UUID.self, forKey: .groupID)
        invitationBindingDigest = try values.decode(Data.self, forKey: .invitationBindingDigest)
        requestDigest = try values.decode(Data.self, forKey: .requestDigest)
        anchor = try values.decode(GroupJoinAnchorV2.self, forKey: .anchor)
        transition = try values.decode(GroupEpochTransitionEnvelopeV2.self, forKey: .transition)
        welcome = try values.decode(SignedGroupWelcomeV2.self, forKey: .welcome)
        existingMemberRouteAnnouncements = try values.decode(
            [SignedGroupRouteSetAnnouncementV2].self,
            forKey: .existingMemberRouteAnnouncements
        )
        guard isStructurallyValid else {
            throw NoctyraGroupExchangeLinkError.invalidLink
        }
    }

    func encoded() throws -> String {
        try NoctyraGroupExchangeCodec.encode(self, prefix: Self.prefix)
    }

    static func decode(_ value: String) throws -> Self {
        try NoctyraGroupExchangeCodec.decode(Self.self, value: value, prefix: Self.prefix)
    }

    func matches(_ request: NoctyraGroupAdmissionRequestLinkV1) -> Bool {
        guard let digest = try? request.requestDigest else { return false }
        return admissionID == request.admissionID
            && groupID == request.groupID
            && invitationBindingDigest == request.invitationBindingDigest
            && requestDigest == digest
            && anchor.destinationMemberHandle == request.admission.memberHandle
            && anchor.destinationCredentialHandle == request.admission.credentialHandle
            && anchor.destinationAdmissionDigest == request.admission.digest
    }

    private var isStructurallyValid: Bool {
        version == Self.version
            && invitationBindingDigest.count == SHA256.byteCount
            && requestDigest.count == SHA256.byteCount
            && anchor.isStructurallyValid
            && anchor.baseState.groupId == groupID
            && transition.isStructurallyValid
            && welcome.isStructurallyValid
            && existingMemberRouteAnnouncements.count
                <= NoctweaveGroupArchitectureV2.maximumActiveExperimentalCredentials
            && existingMemberRouteAnnouncements.allSatisfy { $0.groupID == groupID }
    }
}
