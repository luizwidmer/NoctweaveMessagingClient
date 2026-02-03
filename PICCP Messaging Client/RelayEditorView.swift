import SwiftUI
import PICCPCore

struct RelayEditorView: View {
    let title: String
    let initial: RelayServerRecord?
    let onSave: (String, String, UInt16, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var note: String

    init(title: String, initial: RelayServerRecord?, onSave: @escaping (String, String, UInt16, String?) -> Void) {
        self.title = title
        self.initial = initial
        self.onSave = onSave
        _name = State(initialValue: initial?.name ?? "")
        _host = State(initialValue: initial?.endpoint.host ?? "")
        _port = State(initialValue: initial.map { String($0.endpoint.port) } ?? "")
        _note = State(initialValue: initial?.note ?? "")
    }

    private var portValue: UInt16? {
        UInt16(port)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                    #if os(iOS)
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    #else
                    TextField("Host", text: $host)
                    TextField("Port", text: $port)
                    #endif
                }

                Section("Note") {
                    TextField("Optional note", text: $note)
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
                        guard let portValue else { return }
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let finalName = trimmedName.isEmpty ? "\(host):\(portValue)" : trimmedName
                        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(finalName, host, portValue, trimmedNote.isEmpty ? nil : trimmedNote)
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || portValue == nil)
                }
            }
        }
    }
}
