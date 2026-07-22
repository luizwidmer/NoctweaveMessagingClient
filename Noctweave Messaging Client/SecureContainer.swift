import SwiftUI

#if os(iOS)
import UIKit

struct SecureContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            WarningBackground()
            SecureContainerRepresentable(content: SecureLayerRoot(content: content))
        }
        .ignoresSafeArea()
    }
}

private struct SecureContainerRepresentable<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context: Context) -> SecureContainerController<Content> {
        SecureContainerController(rootView: content)
    }

    func updateUIViewController(_ uiViewController: SecureContainerController<Content>, context: Context) {
        uiViewController.update(rootView: content)
    }
}

struct WarningBackground: View {
    var body: some View {
        ZStack {
            // Keep a real background behind the secure layer so iOS captures show something intentional.
            // This also avoids the UI looking "flat black" if the secure layer fails to render for any reason.
            GlassBackground()
            Color.black.opacity(0.62)
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 36, weight: .semibold))
                Text("Screenshot detected")
                    .font(.headline)
                Text("Sensitive content is hidden in captures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SecureLayerRoot<Content: View>: View {
    let content: Content

    init(content: Content) {
        self.content = content
    }

    var body: some View {
        ZStack {
            SecureMaskBackground()
            content
        }
    }
}

private struct SecureMaskBackground: View {
    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
            // Avoid blend-mode heavy backgrounds here; the secure text rendering path can
            // render them as flat/black on some iOS versions.
            SecureGlassBackground()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Must be usable across the app on iOS because many screens set their own glass backgrounds.
// This variant avoids blend modes (which can render as flat/black inside secure-text pipelines).
struct SecureGlassBackground: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(isDark ? 0.72 : 0.08),
                    theme.backgroundTint.opacity(isDark ? 0.65 : 0.22),
                    Color.black.opacity(isDark ? 0.92 : 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    theme.glowPrimary.opacity(isDark ? 0.28 : 0.12),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 80,
                endRadius: 520
            )
            RadialGradient(
                colors: [
                    theme.glowSecondary.opacity(isDark ? 0.22 : 0.10),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 120,
                endRadius: 640
            )
            RadialGradient(
                colors: [
                    theme.glowTertiary.opacity(isDark ? 0.16 : 0.08),
                    Color.clear
                ],
                center: .center,
                startRadius: 180,
                endRadius: 720
            )
        }
        .ignoresSafeArea()
    }
}

private final class SecureTextField: UITextField {
    override var canBecomeFirstResponder: Bool { false }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.reversed().contains { subview in
            let converted = subview.convert(point, from: self)
            return subview.point(inside: converted, with: event)
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for subview in subviews.reversed() {
            let converted = subview.convert(point, from: self)
            if let hit = subview.hitTest(converted, with: event) {
                return hit
            }
        }
        return nil
    }
}

private final class SecureContainerController<Content: View>: UIViewController {
    private let secureField = SecureTextField()
    private let hostingController: UIHostingController<Content>
    private var protectedCanvasView: UIView?
    private var hostingConstraints: [NSLayoutConstraint] = []

    init(rootView: Content) {
        hostingController = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        secureField.isSecureTextEntry = true
        secureField.text = " "
        secureField.textColor = .clear
        secureField.tintColor = .clear
        secureField.backgroundColor = .clear
        secureField.borderStyle = .none
        secureField.textContentType = .oneTimeCode
        secureField.autocorrectionType = .no
        secureField.spellCheckingType = .no
        secureField.autocapitalizationType = .none
        secureField.smartQuotesType = .no
        secureField.smartDashesType = .no
        secureField.inputAssistantItem.leadingBarButtonGroups = []
        secureField.inputAssistantItem.trailingBarButtonGroups = []
        secureField.isOpaque = false
        secureField.isAccessibilityElement = false
        secureField.accessibilityElementsHidden = false
        secureField.isUserInteractionEnabled = true
        secureField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(secureField)
        NSLayoutConstraint.activate([
            secureField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            secureField.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            secureField.topAnchor.constraint(equalTo: view.topAnchor),
            secureField.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        view.layoutIfNeeded()
        secureField.layoutIfNeeded()

        addChild(hostingController)
        hostingController.view.backgroundColor = .clear
        hostingController.view.isOpaque = false
        hostingController.didMove(toParent: self)

        hostingController.view.accessibilityElementsHidden = false
        hostingController.view.shouldGroupAccessibilityChildren = false
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        installHostedContentInProtectedCanvas()
        publishAccessibilityTree()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installHostedContentInProtectedCanvas()
        publishAccessibilityTree()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        installHostedContentInProtectedCanvas()
    }

    func update(rootView: Content) {
        hostingController.rootView = rootView
        installHostedContentInProtectedCanvas()
        publishAccessibilityTree()
    }

    private func installHostedContentInProtectedCanvas() {
        secureField.layoutIfNeeded()
        let canvas: UIView
        if let protectedCanvasView {
            canvas = protectedCanvasView
        } else {
            // UIKit places secure text content in a layer-backed canvas. Keep
            // that canvas inside the live text-field hierarchy so UIKit owns
            // its protected rendering while the field forwards touches to the
            // hosted SwiftUI controls.
            guard let extracted = secureField.subviews.first else {
                return
            }
            extracted.isUserInteractionEnabled = true
            extracted.clipsToBounds = false
            extracted.isAccessibilityElement = false
            extracted.accessibilityElementsHidden = false
            protectedCanvasView = extracted
            canvas = extracted
        }

        guard hostingController.view.superview !== canvas else {
            return
        }

        NSLayoutConstraint.deactivate(hostingConstraints)
        hostingController.view.removeFromSuperview()
        canvas.addSubview(hostingController.view)
        hostingConstraints = [
            hostingController.view.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: canvas.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: canvas.bottomAnchor)
        ]
        NSLayoutConstraint.activate(hostingConstraints)
    }

    private func publishAccessibilityTree() {
        let elements: [Any] = [hostingController.view as Any]
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = false
        view.accessibilityElements = elements
        view.automationElements = elements
    }
}
#else
struct SecureContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
    }
}
#endif

extension View {
    @ViewBuilder
    func secureContainerIfAvailable() -> some View {
        #if os(iOS)
        SecureContainer { self }
        #else
        self
        #endif
    }
}
