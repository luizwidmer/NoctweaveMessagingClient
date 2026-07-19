import Foundation
import SwiftUI
#if os(iOS)
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#elseif os(macOS)
import AppKit

struct ShareSheet: NSViewRepresentable {
    let items: [Any]
    @Binding var isPresented: Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard isPresented, !items.isEmpty else { return }
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
        DispatchQueue.main.async {
            isPresented = false
        }
    }
}
#endif
