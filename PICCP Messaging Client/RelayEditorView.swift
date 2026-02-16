import SwiftUI
import PICCPCore

struct RelayEditorView: View {
    let title: String
    let initial: RelayServerRecord?
    let onSave: (String, String, UInt16, Bool, String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var relayAddress: String
    @State private var useTLS: Bool
    @State private var note: String
    @State private var relayPassword: String

    init(title: String, initial: RelayServerRecord?, onSave: @escaping (String, String, UInt16, Bool, String?, String?) -> Void) {
        self.title = title
        self.initial = initial
        self.onSave = onSave
        _name = State(initialValue: initial?.name ?? "")
        _relayAddress = State(initialValue: initial.map { Self.endpointAddress($0.endpoint) } ?? "")
        _useTLS = State(initialValue: initial?.endpoint.useTLS ?? false)
        _note = State(initialValue: initial?.note ?? "")
        _relayPassword = State(initialValue: initial?.relayPassword ?? "")
    }

    private static func endpointAddress(_ endpoint: RelayEndpoint) -> String {
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        return "\(host):\(endpoint.port)"
    }

    private var parsedAddress: (host: String, port: UInt16, inferredTLS: Bool?)? {
        parseRelayAddress(relayAddress)
    }

    private var parsedEndpoint: RelayEndpoint? {
        guard let parsedAddress else { return nil }
        return RelayEndpoint(
            host: parsedAddress.host,
            port: parsedAddress.port,
            useTLS: parsedAddress.inferredTLS ?? useTLS
        )
    }

    private func parseRelayAddress(_ value: String) -> (host: String, port: UInt16, inferredTLS: Bool?)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // URL form, e.g. https://relay.example.org:9443
        if let components = URLComponents(string: trimmed), let scheme = components.scheme, !scheme.isEmpty {
            guard let host = components.host else { return nil }
            let resolvedPort = components.port ?? 9339
            guard let port = UInt16(exactly: resolvedPort) else { return nil }
            let lowerScheme = scheme.lowercased()
            if lowerScheme == "https" {
                return (host, port, true)
            }
            if lowerScheme == "http" {
                return (host, port, false)
            }
            return (host, port, nil)
        }

        // Bracketed IPv6 with optional port.
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let remainder = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty {
                return (host, 9339, nil)
            }
            guard remainder.hasPrefix(":") else { return nil }
            let portString = String(remainder.dropFirst())
            guard let port = UInt16(portString) else { return nil }
            return (host, port, nil)
        }

        // host:port for standard hostnames/IPv4.
        if let separator = trimmed.lastIndex(of: ":") {
            let hostPart = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let portPart = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !hostPart.isEmpty, let port = UInt16(portPart) {
                return (hostPart, port, nil)
            }
        }

        // Host only defaults to relay port.
        return (trimmed, 9339, nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                    #if os(iOS)
                    TextField("Relay Address", text: $relayAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #else
                    TextField("Relay Address", text: $relayAddress)
                    #endif
                    Text("Examples: `relay.example.org`, `relay.example.org:9339`, `https://relay.example.org:9443`, `[2001:db8::1]:9339`")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Toggle("Use TLS", isOn: $useTLS)
                    if parsedAddress?.inferredTLS == true {
                        Text("TLS is enabled automatically because address uses `https://`.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Note") {
                    TextField("Optional note", text: $note)
                }

                Section("Access Control") {
                    SecureField("Relay password (optional)", text: $relayPassword)
                }
            }
            .navigationTitle(title)
            .scrollContentBackground(.hidden)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let endpoint = parsedEndpoint else { return }
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let finalName = trimmedName.isEmpty ? "\(endpoint.host):\(endpoint.port)" : trimmedName
                        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedPassword = relayPassword.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(
                            finalName,
                            endpoint.host,
                            endpoint.port,
                            endpoint.useTLS,
                            trimmedNote.isEmpty ? nil : trimmedNote,
                            trimmedPassword.isEmpty ? nil : trimmedPassword
                        )
                        dismiss()
                    }
                    .disabled(parsedEndpoint == nil)
                }
            }
        }
    }
}
