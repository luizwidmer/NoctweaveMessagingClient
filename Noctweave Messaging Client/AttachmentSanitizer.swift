import Foundation
import PDFKit
import Compression
import UniformTypeIdentifiers

struct SanitizedAttachmentPayload {
    let data: Data
    let mimeType: String
}

enum AttachmentSanitizerError: LocalizedError {
    case unsupportedType
    case invalidDocument
    case unsafeDocument(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType:
            return "Unsupported attachment type."
        case .invalidDocument:
            return "Attachment could not be parsed as the declared document type."
        case .unsafeDocument(let reason):
            return "Attachment was rejected: \(reason)"
        }
    }
}

enum AttachmentSanitizer {
    private static let maxOfficeEntries = 2_000
    private static let maxOfficeUncompressedBytes = 64 * 1024 * 1024
    private static let maxOfficeInspectableXMLBytes = 8 * 1024 * 1024
    private static let maxPDFPages = 200

    static func sanitizeDocument(data: Data, fileName: String?, mimeType: String) throws -> SanitizedAttachmentPayload {
        let normalizedMime = normalizeMimeType(mimeType)
        let fileExtension = fileName.flatMap { URL(fileURLWithPath: $0).pathExtension.lowercased() }

        if isPlainText(mimeType: normalizedMime, fileExtension: fileExtension) {
            // Wire MIME values deliberately exclude parameters; attachment
            // descriptors reject semicolons to keep parsing canonical.
            return SanitizedAttachmentPayload(data: try sanitizeText(data), mimeType: "text/plain")
        }
        if normalizedMime == "application/pdf" || fileExtension == "pdf" {
            return SanitizedAttachmentPayload(data: try sanitizePDF(data), mimeType: "application/pdf")
        }
        if let officeKind = OfficeDocumentKind(mimeType: normalizedMime, fileExtension: fileExtension) {
            return SanitizedAttachmentPayload(
                data: try sanitizeOpenXMLPackage(data, kind: officeKind),
                mimeType: officeKind.mimeType
            )
        }
        throw AttachmentSanitizerError.unsupportedType
    }

    static func isSupportedDocument(mimeType: String) -> Bool {
        let normalizedMime = normalizeMimeType(mimeType)
        return isPlainText(mimeType: normalizedMime, fileExtension: nil)
            || normalizedMime == "application/pdf"
            || OfficeDocumentKind(mimeType: normalizedMime, fileExtension: nil) != nil
    }

    static func displayTitle(for mimeType: String) -> String? {
        let normalizedMime = normalizeMimeType(mimeType)
        if isPlainText(mimeType: normalizedMime, fileExtension: nil) {
            return "Text file"
        }
        if normalizedMime == "application/pdf" {
            return "PDF"
        }
        if OfficeDocumentKind(mimeType: normalizedMime, fileExtension: nil) != nil {
            return "Office document"
        }
        return nil
    }

    static func normalizeMimeType(_ mimeType: String) -> String {
        mimeType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? mimeType.lowercased()
    }

    private static func isPlainText(mimeType: String, fileExtension: String?) -> Bool {
        if mimeType.hasPrefix("text/") || mimeType == "application/json" || mimeType == "application/xml" {
            return true
        }
        switch fileExtension {
        case "txt", "md", "csv", "tsv", "json", "xml", "log":
            return true
        default:
            return false
        }
    }

    private static func sanitizeText(_ data: Data) throws -> Data {
        let text: String
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let decoded = String(data: data.dropFirst(3), encoding: .utf8) else {
                throw AttachmentSanitizerError.invalidDocument
            }
            text = decoded
        } else if let decoded = String(data: data, encoding: .utf8) {
            text = decoded
        } else {
            throw AttachmentSanitizerError.invalidDocument
        }

        var output = String()
        output.reserveCapacity(text.count)
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09:
                output.unicodeScalars.append(scalar)
                previousWasCarriageReturn = false
            case 0x0A:
                if !previousWasCarriageReturn {
                    output.append("\n")
                }
                previousWasCarriageReturn = false
            case 0x0D:
                output.append("\n")
                previousWasCarriageReturn = true
            case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                output.unicodeScalars.append(scalar)
                previousWasCarriageReturn = false
            default:
                previousWasCarriageReturn = false
            }
        }
        guard let encoded = output.precomposedStringWithCanonicalMapping.data(using: .utf8) else {
            throw AttachmentSanitizerError.invalidDocument
        }
        return encoded
    }

    private static func sanitizePDF(_ data: Data) throws -> Data {
        guard let input = PDFDocument(data: data), input.pageCount > 0 else {
            throw AttachmentSanitizerError.invalidDocument
        }
        guard input.pageCount <= maxPDFPages else {
            throw AttachmentSanitizerError.unsafeDocument("PDF has too many pages.")
        }

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw AttachmentSanitizerError.invalidDocument
        }

        for index in 0..<input.pageCount {
            guard let page = input.page(at: index) else {
                throw AttachmentSanitizerError.invalidDocument
            }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0,
                  bounds.width.isFinite, bounds.height.isFinite else {
                throw AttachmentSanitizerError.invalidDocument
            }
            context.beginPDFPage([kCGPDFContextMediaBox as String: bounds] as CFDictionary)
            context.saveGState()
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        guard output.length > 0 else {
            throw AttachmentSanitizerError.invalidDocument
        }
        return output as Data
    }

    private static func sanitizeOpenXMLPackage(_ data: Data, kind: OfficeDocumentKind) throws -> Data {
        let entries = try ZipPackage.parse(data)
        guard entries.count <= maxOfficeEntries else {
            throw AttachmentSanitizerError.unsafeDocument("Office package has too many parts.")
        }
        let totalUncompressedSize = entries.reduce(0) { partial, entry in partial + Int(entry.uncompressedSize) }
        guard totalUncompressedSize <= maxOfficeUncompressedBytes else {
            throw AttachmentSanitizerError.unsafeDocument("Office package is too large after decompression.")
        }
        guard entries.contains(where: { $0.path == kind.requiredPart }) else {
            throw AttachmentSanitizerError.invalidDocument
        }
        guard entries.contains(where: { $0.path == "[content_types].xml" }) else {
            throw AttachmentSanitizerError.invalidDocument
        }

        let safeEntries = try entries.compactMap { entry -> ZipPackage.Entry? in
            if shouldDropOfficeEntry(entry.path) {
                return nil
            }
            if isDangerousOfficeEntry(entry.path) {
                throw AttachmentSanitizerError.unsafeDocument("Office package contains active or embedded content.")
            }
            if shouldInspectOfficeXML(entry.path) {
                let xml = try ZipPackage.entryData(entry, source: data, maxSize: maxOfficeInspectableXMLBytes)
                try inspectOfficeXML(xml, path: entry.path)
            }
            return entry
        }
        return try ZipPackage.rewrite(entries: safeEntries, source: data)
    }

    private static func shouldDropOfficeEntry(_ path: String) -> Bool {
        path.hasPrefix("docprops/")
            || path.hasPrefix("customxml/")
            || path.hasSuffix("/.ds_store")
            || path == ".ds_store"
            || path.hasPrefix("__macosx/")
    }

    private static func isDangerousOfficeEntry(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("vbaproject") || lower.contains("/activex/") || lower.contains("/embeddings/") {
            return true
        }
        if lower.contains("oleobject") || lower.contains("embeddedpackage") || lower.contains("/externallinks/") {
            return true
        }
        if lower.hasSuffix(".bin") || lower.hasSuffix(".exe") || lower.hasSuffix(".dll") || lower.hasSuffix(".js") {
            return true
        }
        return false
    }

    private static func shouldInspectOfficeXML(_ path: String) -> Bool {
        path == "[content_types].xml"
            || path.hasSuffix(".rels")
            || path.hasSuffix(".xml")
    }

    private static func inspectOfficeXML(_ data: Data, path: String) throws {
        guard let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw AttachmentSanitizerError.invalidDocument
        }
        let lower = xml.lowercased()
        if lower.contains("targetmode=\"external\"") || lower.contains("targetmode='external'") {
            throw AttachmentSanitizerError.unsafeDocument("Office package contains external relationships.")
        }
        if lower.contains("http://") || lower.contains("https://") || lower.contains("file://") || lower.contains("ftp://") {
            throw AttachmentSanitizerError.unsafeDocument("Office package contains external references.")
        }
        if path == "[content_types].xml" {
            let dangerousContentTypes = [
                "application/vnd.ms-office.vbaproject",
                "application/vnd.ms-office.active",
                "application/vnd.openxmlformats-officedocument.oleobject",
                "application/vnd.ms-excel.sheet.macroenabled",
                "application/vnd.ms-word.document.macroenabled",
                "application/vnd.ms-powerpoint.presentation.macroenabled"
            ]
            if dangerousContentTypes.contains(where: { lower.contains($0) }) {
                throw AttachmentSanitizerError.unsafeDocument("Office package declares active content.")
            }
        }
    }
}

private enum OfficeDocumentKind {
    case word
    case spreadsheet
    case presentation

    init?(mimeType: String, fileExtension: String?) {
        switch (mimeType, fileExtension) {
        case ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", _), (_, "docx"):
            self = .word
        case ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", _), (_, "xlsx"):
            self = .spreadsheet
        case ("application/vnd.openxmlformats-officedocument.presentationml.presentation", _), (_, "pptx"):
            self = .presentation
        default:
            return nil
        }
    }

    var mimeType: String {
        switch self {
        case .word:
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .spreadsheet:
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case .presentation:
            return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        }
    }

    var requiredPart: String {
        switch self {
        case .word:
            return "word/document.xml"
        case .spreadsheet:
            return "xl/workbook.xml"
        case .presentation:
            return "ppt/presentation.xml"
        }
    }
}

private enum ZipPackage {
    struct Entry {
        let path: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
        let compressedDataRange: Range<Int>
    }

    static func parse(_ data: Data) throws -> [Entry] {
        guard data.count >= 22,
              let endOfCentralDirectory = findEndOfCentralDirectory(in: data) else {
            throw AttachmentSanitizerError.invalidDocument
        }
        let entryCount = Int(readUInt16(data, at: endOfCentralDirectory + 10))
        let centralDirectorySize = Int(readUInt32(data, at: endOfCentralDirectory + 12))
        let centralDirectoryOffset = Int(readUInt32(data, at: endOfCentralDirectory + 16))
        guard entryCount > 0,
              centralDirectoryOffset >= 0,
              centralDirectorySize >= 0,
              centralDirectoryOffset + centralDirectorySize <= data.count else {
            throw AttachmentSanitizerError.invalidDocument
        }

        var entries: [Entry] = []
        var seenPaths = Set<String>()
        var offset = centralDirectoryOffset
        for _ in 0..<entryCount {
            guard offset + 46 <= data.count,
                  readUInt32(data, at: offset) == 0x02014B50 else {
                throw AttachmentSanitizerError.invalidDocument
            }
            let flags = readUInt16(data, at: offset + 8)
            let method = readUInt16(data, at: offset + 10)
            let crc32 = readUInt32(data, at: offset + 16)
            let compressedSize = readUInt32(data, at: offset + 20)
            let uncompressedSize = readUInt32(data, at: offset + 24)
            let fileNameLength = Int(readUInt16(data, at: offset + 28))
            let extraLength = Int(readUInt16(data, at: offset + 30))
            let commentLength = Int(readUInt16(data, at: offset + 32))
            let localHeaderOffset = readUInt32(data, at: offset + 42)
            let nameStart = offset + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd + extraLength + commentLength <= data.count,
                  let rawName = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
                throw AttachmentSanitizerError.invalidDocument
            }
            let path = try normalizedZipPath(rawName)
            guard seenPaths.insert(path).inserted else {
                throw AttachmentSanitizerError.unsafeDocument("Office package contains duplicate ZIP paths.")
            }
            guard method == 0 || method == 8 else {
                throw AttachmentSanitizerError.unsafeDocument("Office package uses an unsupported compression method.")
            }
            guard (flags & 0x0001) == 0, (flags & 0x0008) == 0 else {
                throw AttachmentSanitizerError.unsafeDocument("Office package uses encrypted or streaming ZIP entries.")
            }
            guard compressedSize != UInt32.max,
                  uncompressedSize != UInt32.max,
                  localHeaderOffset != UInt32.max else {
                throw AttachmentSanitizerError.unsafeDocument("Office package uses ZIP64 records.")
            }
            let compressedRange = try compressedDataRange(
                in: data,
                localHeaderOffset: Int(localHeaderOffset),
                compressedSize: Int(compressedSize)
            )
            entries.append(
                Entry(
                    path: path,
                    method: method,
                    flags: flags,
                    crc32: crc32,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset,
                    compressedDataRange: compressedRange
                )
            )
            offset = nameEnd + extraLength + commentLength
        }
        return entries
    }

    static func entryData(_ entry: Entry, source: Data, maxSize: Int) throws -> Data {
        let expectedSize = Int(entry.uncompressedSize)
        guard expectedSize <= maxSize else {
            throw AttachmentSanitizerError.unsafeDocument("Office XML part is too large.")
        }
        let compressedData = source[entry.compressedDataRange]
        let output: Data
        switch entry.method {
        case 0:
            guard Int(entry.compressedSize) == expectedSize else {
                throw AttachmentSanitizerError.invalidDocument
            }
            output = Data(compressedData)
        case 8:
            var destination = [UInt8](repeating: 0, count: expectedSize)
            let decodedCount: Int = compressedData.withUnsafeBytes { sourceBuffer in
                guard let sourceAddress = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                return compression_decode_buffer(
                    &destination,
                    destination.count,
                    sourceAddress,
                    compressedData.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            guard decodedCount == expectedSize else {
                throw AttachmentSanitizerError.invalidDocument
            }
            output = Data(destination)
        default:
            throw AttachmentSanitizerError.invalidDocument
        }
        guard crc32(output) == entry.crc32 else {
            throw AttachmentSanitizerError.invalidDocument
        }
        return output
    }

    static func rewrite(entries: [Entry], source: Data) throws -> Data {
        var output = Data()
        var centralDirectory = Data()
        var rewrittenCount: UInt16 = 0

        for entry in entries where !entry.path.hasSuffix("/") {
            guard let nameData = entry.path.data(using: .utf8),
                  nameData.count <= Int(UInt16.max),
                  output.count <= Int(UInt32.max) else {
                throw AttachmentSanitizerError.invalidDocument
            }
            let localOffset = UInt32(output.count)
            appendUInt32(0x04034B50, to: &output)
            appendUInt16(20, to: &output)
            appendUInt16(entry.flags & ~0x0800, to: &output)
            appendUInt16(entry.method, to: &output)
            appendUInt16(0, to: &output)
            appendUInt16(0, to: &output)
            appendUInt32(entry.crc32, to: &output)
            appendUInt32(entry.compressedSize, to: &output)
            appendUInt32(entry.uncompressedSize, to: &output)
            appendUInt16(UInt16(nameData.count), to: &output)
            appendUInt16(0, to: &output)
            output.append(nameData)
            output.append(source[entry.compressedDataRange])

            appendUInt32(0x02014B50, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(entry.flags & ~0x0800, to: &centralDirectory)
            appendUInt16(entry.method, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(entry.crc32, to: &centralDirectory)
            appendUInt32(entry.compressedSize, to: &centralDirectory)
            appendUInt32(entry.uncompressedSize, to: &centralDirectory)
            appendUInt16(UInt16(nameData.count), to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(0, to: &centralDirectory)
            appendUInt32(localOffset, to: &centralDirectory)
            centralDirectory.append(nameData)
            rewrittenCount += 1
        }

        guard rewrittenCount > 0,
              output.count <= Int(UInt32.max),
              centralDirectory.count <= Int(UInt32.max) else {
            throw AttachmentSanitizerError.invalidDocument
        }

        let centralDirectoryOffset = UInt32(output.count)
        output.append(centralDirectory)
        appendUInt32(0x06054B50, to: &output)
        appendUInt16(0, to: &output)
        appendUInt16(0, to: &output)
        appendUInt16(rewrittenCount, to: &output)
        appendUInt16(rewrittenCount, to: &output)
        appendUInt32(UInt32(centralDirectory.count), to: &output)
        appendUInt32(centralDirectoryOffset, to: &output)
        appendUInt16(0, to: &output)
        return output
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        let minimum = 22
        let maximumCommentLength = min(data.count - minimum, Int(UInt16.max))
        let start = data.count - minimum - maximumCommentLength
        for offset in stride(from: data.count - minimum, through: start, by: -1) {
            if readUInt32(data, at: offset) == 0x06054B50 {
                return offset
            }
        }
        return nil
    }

    private static func compressedDataRange(in data: Data, localHeaderOffset: Int, compressedSize: Int) throws -> Range<Int> {
        guard localHeaderOffset >= 0,
              localHeaderOffset + 30 <= data.count,
              readUInt32(data, at: localHeaderOffset) == 0x04034B50 else {
            throw AttachmentSanitizerError.invalidDocument
        }
        let fileNameLength = Int(readUInt16(data, at: localHeaderOffset + 26))
        let extraLength = Int(readUInt16(data, at: localHeaderOffset + 28))
        let start = localHeaderOffset + 30 + fileNameLength + extraLength
        let end = start + compressedSize
        guard start >= 0, end <= data.count else {
            throw AttachmentSanitizerError.invalidDocument
        }
        return start..<end
    }

    private static func normalizedZipPath(_ rawName: String) throws -> String {
        let path = rawName.replacingOccurrences(of: "\\", with: "/").lowercased()
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains(":"),
              !components.contains(where: { $0 == "." || $0 == ".." }),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw AttachmentSanitizerError.unsafeDocument("Office package contains an unsafe path.")
        }
        return path
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = 0 &- (crc & 1)
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.index(data.startIndex, offsetBy: offset)])
            | (UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(readUInt16(data, at: offset)) | (UInt32(readUInt16(data, at: offset + 2)) << 16)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        appendUInt16(UInt16(value & 0xFFFF), to: &data)
        appendUInt16(UInt16((value >> 16) & 0xFFFF), to: &data)
    }
}
