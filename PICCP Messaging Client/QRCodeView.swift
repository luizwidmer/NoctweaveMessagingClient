import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
#endif

struct QRCodeView: View {
    let text: String
    var size: CGFloat = 220

    var body: some View {
        if let image = QRCodeGenerator.makeImage(from: text) {
            Image(platformImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: size, maxHeight: size)
        } else {
            Text("QR code unavailable")
                .foregroundStyle(.secondary)
        }
    }
}

struct AnimatedQRCodeView: View {
    let frames: [String]
    var size: CGFloat = 220
    var interval: TimeInterval = 0.6
    @State private var index = 0

    var body: some View {
        VStack(spacing: 6) {
            QRCodeView(text: currentFrame, size: size)
            if frames.count > 1 {
                Text("\(index + 1) / \(frames.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onReceive(timer) { _ in
            guard frames.count > 1 else { return }
            index = (index + 1) % frames.count
        }
    }

    private var currentFrame: String {
        frames.isEmpty ? "" : frames[index % frames.count]
    }

    private var timer: Publishers.Autoconnect<Timer.TimerPublisher> {
        Timer.publish(every: interval, on: .main, in: .common).autoconnect()
    }
}

enum QRCodeGenerator {
    private static let context = CIContext()

    static func makeImage(from text: String) -> PlatformImage? {
        guard let data = text.data(using: .utf8), !data.isEmpty else {
            return nil
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "Q"
        guard let outputImage = filter.outputImage else {
            return nil
        }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #elseif os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
        #endif
    }
}

private extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self = Image(uiImage: platformImage)
        #elseif os(macOS)
        self = Image(nsImage: platformImage)
        #endif
    }
}
