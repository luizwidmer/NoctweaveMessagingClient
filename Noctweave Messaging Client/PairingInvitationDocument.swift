import Combine
import NoctweaveCore
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

extension UTType {
    static let noctweavePairingInvitation = UTType(
        exportedAs: "org.noctweave.pairing-invitation",
        conformingTo: .data
    )
}

@MainActor
enum SensitiveInvitationPasteboard {
    private static let lifetime: Duration = .seconds(120)

    @discardableResult
    static func copy(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }

        #if os(macOS)
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        guard item.setString(value, forType: .string),
              item.setString(
                  "",
                  forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
              ),
              item.setString(
                  "",
                  forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
              ) else {
            return false
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        let changeCount = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: lifetime)
            guard NSPasteboard.general.changeCount == changeCount else { return }
            NSPasteboard.general.clearContents()
        }
        return true
        #elseif os(iOS)
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: value]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(120)
            ]
        )
        return true
        #else
        return false
        #endif
    }
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
            let data = try SecureRegularFileIO.read(
                from: url,
                maximumBytes: PasswordProtectedPairingPackageV1.maximumPackageBytes
            )
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
