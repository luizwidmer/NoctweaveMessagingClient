import Foundation
import UniformTypeIdentifiers
import SwiftUI

struct ContactShareDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.noctweaveContactShare, .data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    static var noctweaveContactShare: UTType {
        UTType(exportedAs: "org.noctweave.contactshare")
    }
}
