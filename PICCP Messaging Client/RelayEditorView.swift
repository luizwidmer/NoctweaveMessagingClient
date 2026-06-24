import SwiftUI
import PICCPCore

struct RelayEditorView: View {
    let title: String
    let initial: RelayServerRecord?
    let onSave: (String, RelayEndpoint, String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var relayAddress: String
    @State private var note: String
    @State private var relayPassword: String
    @State private var certificatePin: String
    @State private var isResolvingAddress = false
    @State private var addressError: String?

    init(title: String, initial: RelayServerRecord?, onSave: @escaping (String, RelayEndpoint, String?, String?) -> Void) {
        self.title = title
        self.initial = initial
        self.onSave = onSave
        _name = State(initialValue: initial?.name ?? "")
        _relayAddress = State(initialValue: initial.map { Self.endpointAddress($0.endpoint) } ?? "")
        _note = State(initialValue: initial?.note ?? "")
        _relayPassword = State(initialValue: initial?.relayPassword ?? "")
        _certificatePin = State(
            initialValue: initial?.endpoint.tlsCertificateFingerprintSHA256?.base64EncodedString() ?? ""
        )
    }

    private static func endpointAddress(_ endpoint: RelayEndpoint) -> String {
        let defaultPort: UInt16 = {
            switch endpoint.transport {
            case .tcp:
                return 9339
            case .http, .websocket:
                return endpoint.useTLS ? 443 : 80
            }
        }()
        let scheme: String? = {
            switch endpoint.transport {
            case .tcp:
                return nil
            case .http:
                return endpoint.useTLS ? "https" : "http"
            case .websocket:
                return endpoint.useTLS ? "wss" : "ws"
            }
        }()
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        if let scheme {
            if endpoint.port == defaultPort {
                return "\(scheme)://\(host)"
            }
            return "\(scheme)://\(host):\(endpoint.port)"
        }
        if endpoint.port == defaultPort {
            return host
        }
        return "\(host):\(endpoint.port)"
    }

    private enum ParsedRelayAddress {
        case explicit(RelayEndpoint)
        case hostPort(host: String, port: UInt16?)
    }

    private var parsedAddress: ParsedRelayAddress? {
        parseRelayAddress(relayAddress)
    }

    private func parseRelayAddress(_ value: String) -> ParsedRelayAddress? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let components = URLComponents(string: trimmed), let scheme = components.scheme, !scheme.isEmpty {
            guard let host = components.host else { return nil }
            let lowerScheme = scheme.lowercased()
            let defaultPort: Int
            let useTLS: Bool
            let transport: RelayEndpointTransport
            switch lowerScheme {
            case "https":
                defaultPort = 443
                useTLS = true
                transport = .http
            case "http":
                defaultPort = 80
                useTLS = false
                transport = .http
            case "wss":
                defaultPort = 443
                useTLS = true
                transport = .websocket
            case "ws":
                defaultPort = 80
                useTLS = false
                transport = .websocket
            case "tls":
                defaultPort = 9339
                useTLS = true
                transport = .tcp
            case "tcp":
                defaultPort = 9339
                useTLS = false
                transport = .tcp
            default:
                return nil
            }
            guard let port = UInt16(exactly: components.port ?? defaultPort) else { return nil }
            return .explicit(RelayEndpoint(host: host, port: port, useTLS: useTLS, transport: transport))
        }

        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let remainder = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty {
                return .hostPort(host: host, port: nil)
            }
            guard remainder.hasPrefix(":") else { return nil }
            let portString = String(remainder.dropFirst())
            guard let port = UInt16(portString) else { return nil }
            return .hostPort(host: host, port: port)
        }

        if let separator = trimmed.lastIndex(of: ":") {
            let hostPart = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let portPart = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !hostPart.isEmpty, let port = UInt16(portPart) {
                return .hostPort(host: hostPart, port: port)
            }
        }

        return .hostPort(host: trimmed, port: nil)
    }

    private func candidates(for host: String, port: UInt16?) -> [RelayEndpoint] {
        let resolvedPort = port ?? 9339
        var list: [RelayEndpoint]
        if let port {
            list = [
                RelayEndpoint(host: host, port: port, useTLS: true, transport: .http),
                RelayEndpoint(host: host, port: port, useTLS: false, transport: .http),
                RelayEndpoint(host: host, port: port, useTLS: true, transport: .websocket),
                RelayEndpoint(host: host, port: port, useTLS: false, transport: .websocket),
                RelayEndpoint(host: host, port: port, useTLS: true, transport: .tcp),
                RelayEndpoint(host: host, port: port, useTLS: false, transport: .tcp)
            ]
        } else {
            list = [
                RelayEndpoint(host: host, port: 443, useTLS: true, transport: .http),
                RelayEndpoint(host: host, port: 80, useTLS: false, transport: .http),
                RelayEndpoint(host: host, port: 443, useTLS: true, transport: .websocket),
                RelayEndpoint(host: host, port: 80, useTLS: false, transport: .websocket),
                RelayEndpoint(host: host, port: resolvedPort, useTLS: false, transport: .tcp),
                RelayEndpoint(host: host, port: resolvedPort, useTLS: true, transport: .tcp)
            ]
        }
        var seen: Set<String> = []
        return list.filter { endpoint in
            let key = "\(endpoint.host.lowercased()):\(endpoint.port):\(endpoint.useTLS ? 1 : 0):\(endpoint.transport.rawValue)"
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }
    }

    private func canReachRelay(_ endpoint: RelayEndpoint) async -> Bool {
        let client = RelayClient(endpoint: endpoint)
        do {
            let response = try await client.send(.health(), timeout: 1.1)
            return response.type == .ok
        } catch {
            return false
        }
    }

    private func resolveEndpoint(from parsed: ParsedRelayAddress) async -> RelayEndpoint {
        switch parsed {
        case .explicit(let endpoint):
            return endpoint
        case .hostPort(let host, let port):
            for candidate in candidates(for: host, port: port) {
                if await canReachRelay(candidate) {
                    return candidate
                }
            }
            // Default to the raw relay endpoint when transport probing cannot determine transport.
            return RelayEndpoint(host: host, port: port ?? 9339, useTLS: false, transport: .tcp)
        }
    }

    @MainActor
    private func saveRelay() async {
        addressError = nil
        guard let parsedAddress else {
            addressError = "Enter a valid relay URL or IP."
            return
        }
        isResolvingAddress = true
        var endpoint = await resolveEndpoint(from: parsedAddress)
        isResolvingAddress = false
        let trimmedPin = certificatePin.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPin.isEmpty {
            guard endpoint.useTLS else {
                addressError = "Certificate pinning requires a TLS relay."
                return
            }
            guard let pin = decodeCertificatePin(trimmedPin), pin.count == 32 else {
                addressError = "Certificate pin must be a 32-byte SHA-256 value in base64 or hexadecimal."
                return
            }
            endpoint.tlsCertificateFingerprintSHA256 = pin
        } else if let initial,
                  initial.endpoint.host == endpoint.host,
                  initial.endpoint.port == endpoint.port,
                  initial.endpoint.useTLS == endpoint.useTLS,
                  initial.endpoint.transport == endpoint.transport {
            endpoint.tlsCertificateFingerprintSHA256 = initial.endpoint.tlsCertificateFingerprintSHA256
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? Self.endpointAddress(endpoint) : trimmedName
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = relayPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(finalName, endpoint, trimmedNote.isEmpty ? nil : trimmedNote, trimmedPassword.isEmpty ? nil : trimmedPassword)
        dismiss()
    }

    private func decodeCertificatePin(_ value: String) -> Data? {
        if let decoded = Data(base64Encoded: value) {
            return decoded
        }
        let hex = value
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetActionBar(closeLabel: "Cancel") {
                    dismiss()
                } trailing: {
                    Button {
                        Task { await saveRelay() }
                    } label: {
                        Label(isResolvingAddress ? "Checking…" : "Save", systemImage: "checkmark")
                    }
                    .glassButton(prominent: true, compact: true)
                    .disabled(isResolvingAddress || parsedAddress == nil)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SheetHero(
                            icon: "antenna.radiowaves.left.and.right",
                            title: title,
                            subtitle: "Enter one address. Noctyra detects the protocol, TLS, and default port."
                        )

                        editorSection(
                            title: "Connection",
                            subtitle: "A friendly name is optional. The address may be a URL, hostname, or IP.",
                            symbol: "network"
                        ) {
                            styledField("Relay name (optional)", text: $name)
                            #if os(iOS)
                            styledField("URL or IP address", text: $relayAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            #else
                            styledField("URL or IP address", text: $relayAddress)
                            #endif
                            HStack(spacing: 8) {
                                Image(systemName: parsedAddress == nil ? "circle.dashed" : "checkmark.circle.fill")
                                    .foregroundStyle(parsedAddress == nil ? Color.secondary : Color.green)
                                Text(parsedAddress == nil ? "Waiting for a valid address" : "Address format recognized")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let addressError {
                                Label(addressError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        editorSection(
                            title: "Access",
                            subtitle: "Optional credentials and a private note stored with this relay.",
                            symbol: "key.fill"
                        ) {
                            SecureField("Relay password (optional)", text: $relayPassword)
                                .noctyraInputField()
                            styledField("Private note (optional)", text: $note)
                        }

                        editorSection(
                            title: "Certificate Pin",
                            subtitle: "Optional advanced protection against unexpected TLS certificate changes.",
                            symbol: "checkmark.shield.fill"
                        ) {
                            #if os(iOS)
                            styledField("SHA-256 pin (base64 or hex)", text: $certificatePin)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            #else
                            styledField("SHA-256 pin (base64 or hex)", text: $certificatePin)
                            #endif
                            Text("Leave empty to use system trust. A pinned relay is rejected if its leaf certificate changes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if isResolvingAddress {
                            HStack(spacing: 12) {
                                ProgressView()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Checking relay")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Detecting transport and TLS configuration…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .uniformGlassCard(cornerRadius: 16, padding: 14, minHeight: 66)
                        }
                    }
                    .frame(maxWidth: 700)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
            }
            .noctyraSheetBackground()
            .hideSheetNavigationBar()
        }
    }

    private func editorSection<Content: View>(
        title: String,
        subtitle: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .uniformGlassCard(cornerRadius: 18, padding: 14)
    }

    private func styledField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .noctyraInputField()
    }
}
