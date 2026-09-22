import CoreGraphics
import Foundation
import PDFKit
import Compression
import ImageIO
import UniformTypeIdentifiers

@main
struct AttachmentSanitizerSmokeTests {
    static func main() throws {
        try testTextAttachmentIsNormalized()
        try testPDFIsRewritten()
        try testPDFWithUnsafeDimensionsIsRejected()
        try testIncomingPDFPreviewRemovesExternalActions()
        try testIncomingPDFPreviewRejectsOversizedPages()
        try testIncomingImagePreviewIsReencoded()
        try testImageDimensionsAreRejectedBeforeDecode()
        try testImagePixelBudgetIsRejectedBeforeDecode()
        try testUnknownPreviewDoesNotExposeBytes()
        try testIncomingTextPreviewIsNormalized()
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
        try assert(sanitized.mimeType == "text/plain", "text MIME should be canonical and descriptor-safe")
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
        let bounds = document.page(at: 0)?.bounds(for: .mediaBox)
        try assert(bounds?.width == 200 && bounds?.height == 200, "sanitized PDF should preserve safe page dimensions")
    }

    private static func testPDFWithUnsafeDimensionsIsRejected() throws {
        let input = try makeSinglePagePDF(width: 12_001, height: 200)
        try expectThrows("PDF dimensions above the rendering limit should be rejected") {
            _ = try AttachmentSanitizer.sanitizeDocument(
                data: input,
                fileName: "oversized.pdf",
                mimeType: "application/pdf"
            )
        }
    }

    private static func testIncomingPDFPreviewRemovesExternalActions() throws {
        guard let document = PDFDocument(data: try makeSinglePagePDF()), let page = document.page(at: 0) else {
            throw TestFailure("failed to create malicious-peer PDF fixture")
        }
        let link = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 150, height: 100), forType: .link, withProperties: nil)
        link.action = PDFActionURL(url: URL(string: "https://example.invalid/receiver-tracking")!)
        page.addAnnotation(link)
        guard let raw = document.dataRepresentation(), let baseline = PDFDocument(data: raw) else {
            throw TestFailure("failed to encode malicious-peer PDF fixture")
        }
        // This is what the former raw-data preview sink accepted. Never activate the URL.
        try assert(baseline.page(at: 0)?.annotations.contains { $0.action is PDFActionURL } == true,
                   "the attacker fixture must retain its external action before receiver sanitization")
        let payload = try AttachmentSanitizer.sanitizePreview(data: raw, mimeType: "application/pdf")
        guard let sanitized = PDFDocument(data: payload.data) else { throw TestFailure("preview PDF should parse") }
        try assert(sanitized.pageCount == 1, "safe preview should preserve visible pages")
        try assert(sanitized.page(at: 0)?.annotations.isEmpty == true, "receiver preview must remove PDF actions")
    }

    private static func testIncomingPDFPreviewRejectsOversizedPages() throws {
        let raw = try makeSinglePagePDF(width: 12_001)
        try assert(PDFDocument(data: raw)?.pageCount == 1, "raw oversized PDF fixture should parse")
        try expectThrows("cached or received oversized pages must not reach PDFView") {
            _ = try AttachmentSanitizer.sanitizePreview(data: raw, mimeType: "application/pdf")
        }
    }

    private static func makeImageFixture(width: UInt32 = 1, height: UInt32 = 1) throws -> Data {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw TestFailure("image fixture context unavailable") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw TestFailure("image fixture encoder unavailable")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGComment: "private metadata"]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TestFailure("image fixture encode failed") }
        var data = output as Data
        // Modify only the tiny fixture header; rejection must precede pixel decoding.
        for (offset, value) in [(16, width), (20, height)] {
            data.replaceSubrange(offset..<(offset + 4), with: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
        }
        let checksum = crc32(data.subdata(in: 12..<29))
        data.replaceSubrange(29..<33, with: [UInt8((checksum >> 24) & 255), UInt8((checksum >> 16) & 255), UInt8((checksum >> 8) & 255), UInt8(checksum & 255)])
        return data
    }

    private static func testIncomingImagePreviewIsReencoded() throws {
        let raw = try makeImageFixture()
        let payload = try AttachmentSanitizer.sanitizePreview(data: raw, mimeType: "image/png")
        try assert(payload.mimeType == "image/png", "image preview must declare its reencoded format")
        try assert(payload.data.range(of: Data("private metadata".utf8)) == nil,
                   "image preview must strip supplied metadata")
        guard let source = CGImageSourceCreateWithData(payload.data as CFData, nil) else { throw TestFailure("sanitized image must parse") }
        try assert(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil, "sanitized image must render")
    }

    private static func testImageDimensionsAreRejectedBeforeDecode() throws {
        let raw = try makeImageFixture(width: 12_001)
        guard let source = CGImageSourceCreateWithData(raw as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw TestFailure("dimension bomb fixture should expose metadata")
        }
        try assert((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 12_001, "image header must declare oversized width")
        try expectUnsafe("image dimensions must be bounded before decoding") {
            _ = try AttachmentSanitizer.sanitizePreview(data: raw, mimeType: "image/png")
        }
    }

    private static func testImagePixelBudgetIsRejectedBeforeDecode() throws {
        let raw = try makePixelBudgetFixture()
        guard let source = CGImageSourceCreateWithData(raw as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw TestFailure("pixel budget fixture should expose metadata")
        }
        try assert((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 7_000,
                   "pixel budget fixture must declare its real width")
        try expectUnsafe("individually valid dimensions must also respect total pixel budget") {
            _ = try AttachmentSanitizer.sanitizeImage(data: raw, mimeType: "image/png")
        }
    }

    private static func makePixelBudgetFixture() throws -> Data {
        // A valid highly compressed 1-bit grayscale PNG: 42 million pixels,
        // without allocating or decoding a 168 MB RGBA image in the test.
        let width = 7_000, height = 6_000
        let rows = Data(repeating: 0, count: height * (1 + (width + 7) / 8))
        var compressed = Data([0x78, 0x9c])
        compressed.append(try deflate(rows))
        // Adler-32 for an all-zero byte stream: A=1, B=count mod 65521.
        appendBigEndian(UInt32(rows.count % 65_521) << 16 | 1, to: &compressed)
        var header = Data()
        appendBigEndian(UInt32(width), to: &header)
        appendBigEndian(UInt32(height), to: &header)
        header.append(contentsOf: [1, 0, 0, 0, 0])
        var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        for (name, payload) in [("IHDR", header), ("IDAT", compressed), ("IEND", Data())] {
            appendBigEndian(UInt32(payload.count), to: &png)
            let content = Data(name.utf8) + payload
            png.append(content)
            appendBigEndian(crc32(content), to: &png)
        }
        return png
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
                                UInt8((value >> 8) & 255), UInt8(value & 255)])
    }

    private static func testUnknownPreviewDoesNotExposeBytes() throws {
        let payload = try AttachmentSanitizer.sanitizePreview(data: Data("<script>untrusted</script>".utf8), mimeType: "application/octet-stream")
        try assert(payload.data.isEmpty, "unknown content must not reach a platform previewer")
    }

    private static func testIncomingTextPreviewIsNormalized() throws {
        let payload = try AttachmentSanitizer.sanitizePreview(data: Data("test\r\n\u{0000}".utf8), mimeType: "text/html")
        try assert(payload.mimeType == "text/plain" && payload.data == Data("test\n".utf8), "text preview must use canonical safe text")
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

    private static func makeSinglePagePDF(
        width: CGFloat = 200,
        height: CGFloat = 200
    ) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else {
            throw TestFailure("failed to create PDF context")
        }
        var bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            throw TestFailure("failed to create PDF context")
        }
        context.beginPDFPage(nil)
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

    private static func expectUnsafe(_ message: String, _ work: () throws -> Void) throws {
        do {
            try work()
        } catch AttachmentSanitizerError.unsafeDocument {
            return
        } catch {
            throw TestFailure("\(message): must reject header bounds before attempting pixel decoding")
        }
        throw TestFailure(message)
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
