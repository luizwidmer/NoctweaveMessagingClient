import Foundation
import NoctweaveCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let noctweaveGroupExchange = UTType(
        exportedAs: "org.noctweave.group-exchange",
        conformingTo: .data
    )
}

enum GroupExchangeArtifactTransferError: Error, LocalizedError {
    case invalidArtifact
    case invalidEncoding
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidArtifact:
            return "This is not the expected Noctweave group exchange package."
        case .invalidEncoding:
            return "The group exchange file is not valid UTF-8."
        case .tooLarge:
            return "The group exchange file exceeds the 24 MiB safety limit."
        }
    }
}

enum GroupExchangeArtifactTransfer {
    static let maximumBytes = 24 * 1_024 * 1_024

    static func normalize(_ value: String, expectedPrefix: String? = nil) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExpectedPrefix = expectedPrefix.map { normalized.hasPrefix($0) }
            ?? isSupported(normalized)
        guard !normalized.isEmpty, hasExpectedPrefix else {
            throw GroupExchangeArtifactTransferError.invalidArtifact
        }
        guard normalized.utf8.count <= maximumBytes else {
            throw GroupExchangeArtifactTransferError.tooLarge
        }
        return normalized
    }

    static func read(from url: URL, expectedPrefix: String) throws -> String {
        let data = try SecureRegularFileIO.read(from: url, maximumBytes: maximumBytes)
        guard let value = String(data: data, encoding: .utf8) else {
            throw GroupExchangeArtifactTransferError.invalidEncoding
        }
        return try normalize(value, expectedPrefix: expectedPrefix)
    }

    static func encodedData(_ value: String) throws -> Data {
        let normalized = try normalize(value)
        guard let data = normalized.data(using: .utf8), data.count <= maximumBytes else {
            throw GroupExchangeArtifactTransferError.tooLarge
        }
        return data
    }

    private static func isSupported(_ value: String) -> Bool {
        value.hasPrefix(NoctweaveGroupAdmissionRequestLinkV1.prefix)
            || value.hasPrefix(NoctweaveGroupAdmissionResponseLinkV1.prefix)
    }
}

struct GroupExchangeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.noctweaveGroupExchange] }

    let payload: Data

    init() {
        payload = Data()
    }

    init(validating artifact: String) throws {
        payload = try GroupExchangeArtifactTransfer.encodedData(artifact)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              !data.isEmpty,
              data.count <= GroupExchangeArtifactTransfer.maximumBytes else {
            throw GroupExchangeArtifactTransferError.invalidArtifact
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw GroupExchangeArtifactTransferError.invalidEncoding
        }
        payload = try GroupExchangeArtifactTransfer.encodedData(value)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard !payload.isEmpty,
              payload.count <= GroupExchangeArtifactTransfer.maximumBytes else {
            throw GroupExchangeArtifactTransferError.invalidArtifact
        }
        return FileWrapper(regularFileWithContents: payload)
    }
}
