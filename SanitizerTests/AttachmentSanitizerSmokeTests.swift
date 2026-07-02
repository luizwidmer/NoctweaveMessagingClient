import CoreGraphics
import Foundation
import PDFKit
import Compression

@main
struct AttachmentSanitizerSmokeTests {
    static func main() throws {
        try testTextAttachmentIsNormalized()
        try testPDFIsRewritten()
        try testDocxMetadataIsDropped()
        try testXlsxIsAccepted()
        try testPptxIsAccepted()
        try testDocxMacroContentIsRejected()
        try testDocxExternalRelationshipIsRejected()
        try testCompressedDocxExternalRelationshipIsRejected()
        try testOfficePathTraversalIsRejected()
        try testOfficeDuplicatePathIsRejected()
        try testLegacyOfficeIsRejected()
        print("Attachment sanitizer smoke tests passed.")
    }

    private static func testTextAttachmentIsNormalized() throws {
        let input = Data([0xEF, 0xBB, 0xBF]) + Data("hello\r\nworld\u{0000}\n".utf8)
        let sanitized = try AttachmentSanitizer.sanitizeDocument(
            data: input,
            fileName: "note.txt",
            mimeType: "text/plain"
        )
        try assert(sanitized.mimeType == "text/plain; charset=utf-8", "text MIME should be canonical")
        try assert(String(data: sanitized.data, encoding: .utf8) == "hello\nworld\n", "text should normalize line endings and strip NUL")
    }

    private static func testPDFIsRewritten() throws {
        let input = try makeSinglePagePDF()
        let sanitized = try AttachmentSanitizer.sanitizeDocument(
            data: input,
            fileName: "sample.pdf",
            mimeType: "application/pdf"
        )
        try assert(sanitized.mimeType == "application/pdf", "PDF MIME should be canonical")
        guard let document = PDFDocument(data: sanitized.data) else {
            throw TestFailure("sanitized PDF should parse")
        }
        try assert(document.pageCount == 1, "sanitized PDF should preserve one page")
    }

    private static func testDocxMetadataIsDropped() throws {
        let package = makeStoredZip(entries: [
            "[Content_Types].xml": "<Types></Types>",
            "_rels/.rels": "<Relationships/>",
            "customXml/item1.xml": "<private/>",
            "docProps/core.xml": "<metadata/>",
            "word/document.xml": "<w:document/>"
        ])
        let sanitized = try AttachmentSanitizer.sanitizeDocument(
            data: package,
            fileName: "report.docx",
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        )
        let raw = String(data: sanitized.data, encoding: .isoLatin1) ?? ""
        try assert(raw.contains("word/document.xml"), "DOCX document part should remain")
        try assert(!raw.contains("docprops/core.xml"), "DOCX metadata part should be stripped")
        try assert(!raw.contains("customxml/item1.xml"), "DOCX custom XML should be stripped")
    }

    private static func testXlsxIsAccepted() throws {
        let package = makeStoredZip(entries: [
            "[Content_Types].xml": "<Types/>",
            "_rels/.rels": "<Relationships/>",
            "xl/workbook.xml": "<workbook/>",
            "xl/worksheets/sheet1.xml": "<worksheet/>"
        ])
        let sanitized = try AttachmentSanitizer.sanitizeDocument(
            data: package,
            fileName: "sheet.xlsx",
            mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        )
        try assert(sanitized.mimeType == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "XLSX MIME should be canonical")
        let raw = String(data: sanitized.data, encoding: .isoLatin1) ?? ""
        try assert(raw.contains("xl/workbook.xml"), "XLSX workbook should remain")
    }

    private static func testPptxIsAccepted() throws {
        let package = makeStoredZip(entries: [
            "[Content_Types].xml": "<Types/>",
            "_rels/.rels": "<Relationships/>",
            "ppt/presentation.xml": "<p:presentation/>",
            "ppt/slides/slide1.xml": "<p:sld/>"
        ])
        let sanitized = try AttachmentSanitizer.sanitizeDocument(
            data: package,
            fileName: "deck.pptx",
            mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        )
        try assert(sanitized.mimeType == "application/vnd.openxmlformats-officedocument.presentationml.presentation", "PPTX MIME should be canonical")
        let raw = String(data: sanitized.data, encoding: .isoLatin1) ?? ""
        try assert(raw.contains("ppt/presentation.xml"), "PPTX presentation should remain")
    }

    private static func testDocxMacroContentIsRejected() throws {
        let package = makeStoredZip(entries: [
            "[Content_Types].xml": "<Types/>",
            "word/document.xml": "<w:document/>",
            "word/vbaProject.bin": "macro"
        ])
        try expectThrows("DOCX macro content should be rejected") {
            _ = try AttachmentSanitizer.sanitizeDocument(
                data: package,
                fileName: "macro.docx",
                mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            )
        }
    }

    private static func testDocxExternalRelationshipIsRejected() throws {
        let package = makeStoredZip(entries: [
            "[Content_Types].xml": "<Types/>",
            "word/document.xml": "<w:document/>",
            "word/_rels/document.xml.rels": """
            <Relationships>
              <Relationship Id="rId1" TargetMode="External" Target="https://example.test/pixel"/>
            </Relationships>
            """
        ])
        try expectThrows("DOCX external relationships should be rejected") {
            _ = try AttachmentSanitizer.sanitizeDocument(
                data: package,
                fileName: "external.docx",
                mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            )
        }
    }

    private static func testCompressedDocxExternalRelationshipIsRejected() throws {
        let package = try makeZip(entries: [
            ZipFixtureEntry(name: "[Content_Types].xml", value: "<Types/>", method: 0),
            ZipFixtureEntry(name: "word/document.xml", value: "<w:document/>", method: 0),
            ZipFixtureEntry(
                name: "word/_rels/document.xml.rels",
                value: """
                <Relationships>
                  <Relationship Id="rId1" TargetMode="External" Target="https://example.test/pixel"/>
                </Relationships>
                """,
                method: 8
            )
        ])
        try expectThrows("compressed DOCX external relationships should be rejected") {
            _ = try AttachmentSanitizer.sanitizeDocument(
                data: package,
                fileName: "compressed-external.docx",
                mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            )
        }
    }


    private static func testOfficePathTraversalIsRejected() throws {
        let package = makeStoredZip(entries: [
            "[Content_Types].xml": "<Types/>",
            "word/document.xml": "<w:document/>",
            "../escape.xml": "<escape/>"
        ])
        try expectThrows("Office ZIP traversal should be rejected") {
            _ = try AttachmentSanitizer.sanitizeDocument(
                data: package,
                fileName: "escape.docx",
                mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            )
        }
    }

    private static func testOfficeDuplicatePathIsRejected() throws {
        let package = makeStoredZip(entries: [
            ("[Content_Types].xml", "<Types/>"),
            ("word/document.xml", "<w:document/>"),
            ("WORD/document.xml", "<w:document/>")
        ])
        try expectThrows("Office duplicate normalized paths should be rejected") {
            _ = try AttachmentSanitizer.sanitizeDocument(
                data: package,
                fileName: "duplicate.docx",
                mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            )
        }
    }

    private static func testLegacyOfficeIsRejected() throws {
        try expectThrows("legacy binary Office should be rejected") {
            _ = try AttachmentSanitizer.sanitizeDocument(
                data: Data("D0CF11E0".utf8),
                fileName: "legacy.doc",
                mimeType: "application/msword"
            )
        }
    }

    private static func makeSinglePagePDF() throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw TestFailure("failed to create PDF context")
        }
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        context.beginPDFPage([kCGPDFContextMediaBox as String: bounds] as CFDictionary)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 120, height: 120))
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }

    private static func makeStoredZip(entries: [String: String]) -> Data {
        try! makeZip(entries: entries.map { ZipFixtureEntry(name: $0.key, value: $0.value, method: 0) })
    }

    private static func makeStoredZip(entries: [(String, String)]) -> Data {
        try! makeZip(entries: entries.map { ZipFixtureEntry(name: $0.0, value: $0.1, method: 0) })
    }

    private static func makeZip(entries: [ZipFixtureEntry]) throws -> Data {
        var output = Data()
        var centralDirectory = Data()
        var count: UInt16 = 0

        for entry in entries.sorted(by: { $0.name < $1.name }) {
            let nameData = Data(entry.name.utf8)
            let payload = Data(entry.value.utf8)
            let storedPayload: Data
            switch entry.method {
            case 0:
                storedPayload = payload
            case 8:
                storedPayload = try deflate(payload)
            default:
                throw TestFailure("unsupported fixture compression method")
            }
            let crc = crc32(payload)
            let localOffset = UInt32(output.count)

            appendUInt32(0x04034B50, to: &output)
            appendUInt16(20, to: &output)
            appendUInt16(0, to: &output)
            appendUInt16(entry.method, to: &output)
            appendUInt16(0, to: &output)
            appendUInt16(0, to: &output)
            appendUInt32(crc, to: &output)
            appendUInt32(UInt32(storedPayload.count), to: &output)
            appendUInt32(UInt32(payload.count), to: &output)
            appendUInt16(UInt16(nameData.count), to: &output)
            appendUInt16(0, to: &output)
            output.append(nameData)
            output.append(storedPayload)

            appendUInt32(0x02014B50, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(entry.method, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(crc, to: &centralDirectory)
            appendUInt32(UInt32(storedPayload.count), to: &centralDirectory)
            appendUInt32(UInt32(payload.count), to: &centralDirectory)
            appendUInt16(UInt16(nameData.count), to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(0, to: &centralDirectory)
            appendUInt32(localOffset, to: &centralDirectory)
            centralDirectory.append(nameData)
            count += 1
        }

        let centralDirectoryOffset = UInt32(output.count)
        output.append(centralDirectory)
        appendUInt32(0x06054B50, to: &output)
        appendUInt16(0, to: &output)
        appendUInt16(0, to: &output)
        appendUInt16(count, to: &output)
        appendUInt16(count, to: &output)
        appendUInt32(UInt32(centralDirectory.count), to: &output)
        appendUInt32(centralDirectoryOffset, to: &output)
        appendUInt16(0, to: &output)
        return output
    }

    private static func deflate(_ data: Data) throws -> Data {
        var destination = [UInt8](repeating: 0, count: max(64, data.count * 2))
        let encodedCount = data.withUnsafeBytes { sourceBuffer in
            compression_encode_buffer(
                &destination,
                destination.count,
                sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard encodedCount > 0 else {
            throw TestFailure("failed to deflate fixture data")
        }
        return Data(destination.prefix(encodedCount))
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

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        appendUInt16(UInt16(value & 0xFFFF), to: &data)
        appendUInt16(UInt16((value >> 16) & 0xFFFF), to: &data)
    }

    private static func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw TestFailure(message)
        }
    }

    private static func expectThrows(_ message: String, _ work: () throws -> Void) throws {
        do {
            try work()
        } catch {
            return
        }
        throw TestFailure(message)
    }
}

private struct ZipFixtureEntry {
    let name: String
    let value: String
    let method: UInt16
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
