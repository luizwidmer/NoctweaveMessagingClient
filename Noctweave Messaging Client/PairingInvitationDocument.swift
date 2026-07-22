import Combine
import NoctweaveCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let noctweavePairingInvitation = UTType(
        exportedAs: "org.noctweave.pairing-invitation",
        conformingTo: .data
    )
}

struct PairingInvitationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.noctweavePairingInvitation] }

    let payload: Data

    init(payload: Data = Data()) {
        self.payload = payload
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              !data.isEmpty,
              data.count <= PasswordProtectedPairingPackageV1.maximumPackageBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        payload = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard !payload.isEmpty,
              payload.count <= PasswordProtectedPairingPackageV1.maximumPackageBytes else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(regularFileWithContents: payload)
    }
}

@MainActor
final class PairingInvitationInbox: ObservableObject {
    static let shared = PairingInvitationInbox()

    @Published private(set) var revision: UInt64 = 0
    private var pendingPackage: Data?
    private var pendingError: String?

    var hasPendingItem: Bool {
        pendingPackage != nil || pendingError != nil
    }

    func receive(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty,
                  data.count <= PasswordProtectedPairingPackageV1.maximumPackageBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }
            pendingPackage = data
            pendingError = nil
        } catch {
            pendingPackage = nil
            pendingError = "The received file is not a valid protected Noctweave invitation."
        }
        revision &+= 1
    }

    func takePendingItem() -> (package: Data?, error: String?) {
        defer {
            pendingPackage = nil
            pendingError = nil
        }
        return (pendingPackage, pendingError)
    }
}
