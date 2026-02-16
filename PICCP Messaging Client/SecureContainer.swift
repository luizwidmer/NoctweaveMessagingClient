import SwiftUI

#if os(iOS)
import UIKit

struct SecureContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        SecureContainerRepresentable(content: SecureLayerRoot(content: content))
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
		    override var canBecomeFirstResponder: Bool {
		        false
		    }

        override func textRect(forBounds bounds: CGRect) -> CGRect {
            bounds
        }

        override func editingRect(forBounds bounds: CGRect) -> CGRect {
            bounds
        }

	        override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
	            bounds
	        }

            override func leftViewRect(forBounds bounds: CGRect) -> CGRect {
                bounds
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                // Ensure the secure container (leftView) fills the field.
                leftView?.frame = bounds
            }

		    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		        // Don't let the invisible secure field swallow gestures meant for the hosted SwiftUI content.
		        for sub in subviews.reversed() {
		            let p = sub.convert(point, from: self)
	            if sub.point(inside: p, with: event) {
	                return true
	            }
	        }
	        return false
	    }

	    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
	        // Forward hit-testing into subviews so the hosted content remains interactive.
	        for sub in subviews.reversed() {
	            let p = sub.convert(point, from: self)
	            if let hit = sub.hitTest(p, with: event) {
	                return hit
	            }
	        }
	        return nil
	    }
	}

private final class SecureContainerController<Content: View>: UIViewController {
    private let secureField = SecureTextField()
    private let hostingController: UIHostingController<Content>
    private let secureContainerView = UIView()
    private var hostingConstraints: [NSLayoutConstraint] = []

    init(rootView: Content) {
        hostingController = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        secureField.isOpaque = false
        secureField.accessibilityElementsHidden = true
        secureField.isUserInteractionEnabled = true
        secureField.leftView = secureContainerView
        secureField.leftViewMode = .always
        secureField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(secureField)
        NSLayoutConstraint.activate([
            secureField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            secureField.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            secureField.topAnchor.constraint(equalTo: view.topAnchor),
            secureField.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        addChild(hostingController)
        hostingController.view.backgroundColor = .clear
        hostingController.view.isOpaque = false
        hostingController.didMove(toParent: self)

        // Install the hosted content into the secure text field's leftView. This is a stable,
        // non-private way to attach content to the secure rendering pipeline so it is redacted
        // in screenshots/screen recordings.
        secureContainerView.isUserInteractionEnabled = true
        secureContainerView.clipsToBounds = false
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        secureContainerView.addSubview(hostingController.view)
        hostingConstraints = [
            hostingController.view.leadingAnchor.constraint(equalTo: secureContainerView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: secureContainerView.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: secureContainerView.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: secureContainerView.bottomAnchor)
        ]
        NSLayoutConstraint.activate(hostingConstraints)
    }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Re-assert secure entry after the view is attached to a window.
            // Some iOS versions only fully enable redaction after this point.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Force UIKit to rebuild its internal secure canvas if needed.
                self.secureField.isSecureTextEntry = false
                self.secureField.isSecureTextEntry = true
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
            }
        }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        secureContainerView.frame = secureField.bounds
    }

    func update(rootView: Content) {
        hostingController.rootView = rootView
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
