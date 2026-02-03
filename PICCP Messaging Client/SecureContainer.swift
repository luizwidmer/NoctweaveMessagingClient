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
            Color.black
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
            GlassBackground()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private final class SecureTextField: UITextField {
    override var canBecomeFirstResponder: Bool {
        false
    }
}

private final class SecureContainerController<Content: View>: UIViewController {
    private let secureField = SecureTextField()
    private let hostingController: UIHostingController<Content>

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
        secureField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(secureField)
        NSLayoutConstraint.activate([
            secureField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            secureField.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            secureField.topAnchor.constraint(equalTo: view.topAnchor),
            secureField.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        addChild(hostingController)
        let secureContainer = secureField.subviews.first { String(describing: type(of: $0)).contains("Canvas") } ?? secureField
        secureContainer.backgroundColor = .clear
        hostingController.view.backgroundColor = .clear
        hostingController.view.isOpaque = false
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        secureContainer.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: secureContainer.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: secureContainer.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: secureContainer.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: secureContainer.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
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
