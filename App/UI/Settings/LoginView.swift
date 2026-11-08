import SwiftUI

/// Anmeldung an einem Navidrome-/Subsonic-Server.
struct LoginView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var isSheet = false
    @State private var server = ""
    @State private var user = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.accent)
                        Text("HomeTune").font(.largeTitle.bold())
                        Text("Deine Musik vom eigenen Navidrome-Server – immer in 432 Hz.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }
                Section("Server") {
                    TextField("Serveradresse, z. B. http://musik.local:4533", text: $server)
                        .keyboardType(.URL).textContentType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("login.server")
                    TextField("Benutzername", text: $user)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("login.user")
                    SecureField("Passwort", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("login.password")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await login() }
                    } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("Anmelden").bold() }; Spacer() }
                    }
                    .disabled(busy || server.isEmpty || user.isEmpty || password.isEmpty)
                    .accessibilityIdentifier("login.submit")
                } footer: {
                    Text("Das Passwort bleibt im Schlüsselbund dieses iPhones. Die App spricht nur mit deinem Server.")
                }
            }
            .navigationTitle(isSheet ? Text("Konto hinzufügen") : Text(""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", role: .cancel) { dismiss() } }
                }
            }
        }
    }

    private func login() async {
        guard let url = AccountStore.normalize(server) else {
            error = String(localized: "Ungültige Serveradresse.")
            return
        }
        busy = true
        defer { busy = false }
        let account = ServerAccount(server: url, username: user.trimmingCharacters(in: .whitespaces))
        let client = SubsonicClient(account: account, password: password)
        do {
            _ = try await client.ping()
            app.accounts.add(account, password: password)
            app.connect()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
