import SwiftUI
import NoctweaveCore

struct RelayEditorView: View {
    let title: String
    let initial: RelayServerRecord?
    let requiresReachableRelay: Bool
    let onSave: (String, RelayEndpoint, String?, String?, RelayCertificatePinOrigin?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var relayAddress: String
    @State private var note: String
    @State private var relayPassword: String
    @State private var certificatePin: String
    @State private var showAdvancedOptions = false
    @State private var isResolvingAddress = false
    @State private var addressError: String?
    @State private var observedReplacementPin: String?

    init(
        title: String,
        initial: RelayServerRecord?,
        requiresReachableRelay: Bool = false,
        onSave: @escaping (String, RelayEndpoint, String?, String?, RelayCertificatePinOrigin?) -> Void
    ) {
        self.title = title
        self.initial = initial
        self.requiresReachableRelay = requiresReachableRelay
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

    private struct RelayProbeResult {
        let reachable: Bool
        let observedLeafCertificateSHA256: Data?
    }

    private var parsedAddress: ParsedRelayAddress? {
        parseRelayAddress(relayAddress)
    }

    private func parseRelayAddress(_ value: String) -> ParsedRelayAddress? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = try? RelayEndpointParser.parse(trimmed) else { return nil }
        if trimmed.contains("://") {
            return .explicit(endpoint)
        }
        let explicitPort: UInt16?
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let remainder = trimmed[trimmed.index(after: close)...]
            explicitPort = remainder.hasPrefix(":") ? UInt16(remainder.dropFirst()) : nil
        } else if trimmed.filter({ $0 == ":" }).count == 1,
                  let separator = trimmed.lastIndex(of: ":") {
            explicitPort = UInt16(trimmed[trimmed.index(after: separator)...])
        } else {
            explicitPort = nil
        }
        return .hostPort(host: endpoint.host, port: explicitPort)
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

    private func probeRelay(_ endpoint: RelayEndpoint, authToken: String?) async -> RelayProbeResult {
        let client = RelayClient(endpoint: endpoint, authToken: authToken)
        do {
            let observation = try await client.sendObservingTLS(.info(), timeout: 1.5)
            return RelayProbeResult(
                reachable: observation.response.type == .info
                    && observation.response.relayInfo != nil
                    && observation.response.relayInfo?.kind != .coordinator,
                observedLeafCertificateSHA256: observation.leafCertificateSHA256
            )
        } catch {
            return RelayProbeResult(reachable: false, observedLeafCertificateSHA256: nil)
        }
    }

    private func resolveEndpoint(
        from parsed: ParsedRelayAddress,
        authToken: String?
    ) async -> (endpoint: RelayEndpoint, probe: RelayProbeResult) {
        switch parsed {
        case .explicit(let endpoint):
            return (endpoint, await probeRelay(endpoint, authToken: authToken))
        case .hostPort(let host, let port):
            for candidate in candidates(for: host, port: port) {
                let probe = await probeRelay(candidate, authToken: authToken)
                if probe.reachable {
                    return (candidate, probe)
                }
            }
            // Default to the raw relay endpoint when transport probing cannot determine transport.
            return (
                RelayEndpoint(host: host, port: port ?? 9339, useTLS: false, transport: .tcp),
                RelayProbeResult(reachable: false, observedLeafCertificateSHA256: nil)
            )
        }
    }

    @MainActor
    private func saveRelay() async {
        addressError = nil
        observedReplacementPin = nil
        guard let parsedAddress else {
            addressError = "Enter a complete URL, IP address, localhost, or qualified hostname such as relay.example.org."
            return
        }
        isResolvingAddress = true
        defer { isResolvingAddress = false }
        let trimmedPassword = relayPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let authToken = trimmedPassword.isEmpty ? nil : trimmedPassword
        let resolution = await resolveEndpoint(from: parsedAddress, authToken: authToken)
        var endpoint = resolution.endpoint
        var certificatePinOrigin: RelayCertificatePinOrigin?
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
            if resolution.probe.reachable,
               let observed = resolution.probe.observedLeafCertificateSHA256,
               observed != pin {
                observedReplacementPin = observed.base64EncodedString()
                showAdvancedOptions = true
                addressError = "The saved pin does not match the relay's current system-trusted certificate. Review the change before replacing it."
                return
            }
            endpoint.tlsCertificateFingerprintSHA256 = pin
            certificatePinOrigin = .manual
        } else if let initial,
                  initial.endpoint.host == endpoint.host,
                  initial.endpoint.port == endpoint.port,
                  initial.endpoint.useTLS == endpoint.useTLS,
                  initial.endpoint.transport == endpoint.transport {
            endpoint.tlsCertificateFingerprintSHA256 = initial.endpoint.tlsCertificateFingerprintSHA256
        }
        if endpoint.useTLS,
           endpoint.tlsCertificateFingerprintSHA256 == nil,
           let observed = resolution.probe.observedLeafCertificateSHA256,
           observed.count == 32 {
            endpoint.tlsCertificateFingerprintSHA256 = observed
            certificatePinOrigin = .automaticFirstUse
        }
        if requiresReachableRelay {
            let finalEndpointReachable: Bool
            if resolution.probe.reachable,
               endpoint.tlsCertificateFingerprintSHA256 == resolution.probe.observedLeafCertificateSHA256 {
                finalEndpointReachable = true
            } else {
                finalEndpointReachable = (await probeRelay(endpoint, authToken: authToken)).reachable
            }
            guard finalEndpointReachable else {
                addressError = "No compatible Noctweave relay responded at this address. Check the address, access password, TLS, and proxy configuration."
                return
            }
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? Self.endpointAddress(endpoint) : trimmedName
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(
            finalName,
            endpoint,
            trimmedNote.isEmpty ? nil : trimmedNote,
            authToken,
            certificatePinOrigin
        )
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
                            subtitle: "Enter one address. Noctweave detects the protocol, TLS, and default port."
                        )

                        editorSection(
                            title: "Connection",
                            subtitle: "A friendly name is optional. Saving a new relay verifies that a compatible Noctweave service responds.",
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
                                Image(systemName: parsedAddress == nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                                    .foregroundStyle(parsedAddress == nil ? Color.orange : Color.green)
                                Text(parsedAddress == nil ? "Enter a complete relay address" : "Address format is valid")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let addressError {
                                Label(addressError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        DisclosureGroup(isExpanded: $showAdvancedOptions) {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Access", systemImage: "key.fill")
                                    .font(.subheadline.weight(.semibold))
                                SecureField("Relay password (optional)", text: $relayPassword)
                                    .noctweaveInputField()
                                styledField("Local note (optional)", text: $note)
                                Text("A private label for your own reference, such as “Home relay.” It stays on this device and is never sent to the relay.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Divider().opacity(0.25)

                                Label("Certificate Pin (Optional)", systemImage: "checkmark.shield.fill")
                                    .font(.subheadline.weight(.semibold))
                                #if os(iOS)
                                styledField("SHA-256 pin (base64 or hex)", text: $certificatePin)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                #else
                                styledField("SHA-256 pin (base64 or hex)", text: $certificatePin)
                                #endif
                                Text("Most users should leave this empty. Noctweave reads and pins the relay’s system-trusted TLS certificate during the successful connection check. Manual SHA-256 values are for operators who publish a verified certificate fingerprint through a separate trusted channel.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let observedReplacementPin {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("A different system-trusted certificate was observed. Only accept it after confirming the relay operator intentionally renewed or replaced the certificate.")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                        Button("Use Current Trusted Certificate") {
                                            certificatePin = observedReplacementPin
                                            self.observedReplacementPin = nil
                                            addressError = nil
                                        }
                                        .glassButton(compact: true)
                                    }
                                    .padding(10)
                                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                            .padding(.top, 12)
                        } label: {
                            Label("Advanced Relay Options", systemImage: "slider.horizontal.3")
                                .font(.headline)
                        }
                        .uniformGlassCard(cornerRadius: 16, padding: 14)

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
            .noctweaveSheetBackground()
            .hideSheetNavigationBar()
        }
        .onChange(of: relayAddress) { _, _ in
            addressError = nil
            observedReplacementPin = nil
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
            .noctweaveInputField()
    }
}
