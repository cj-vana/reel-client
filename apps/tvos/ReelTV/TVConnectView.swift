import SwiftUI

struct TVConnectView: View {
    var addingServer = false
    @Environment(TVCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var attemptID = UUID()
    /// While signing in, Sign in is disabled and Cancel holds focus. Cancel leaves when the attempt ends, so focus
    /// returns to Sign in explicitly instead of wherever tvOS would move it.
    @FocusState private var signInFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 120) {
            VStack(alignment: .leading, spacing: 28) {
                TVMark()
                Text(addingServer ? "Add a Jellyfin server" : "Connect to Jellyfin")
                    .font(.system(size: 56, weight: .bold)).tracking(-0.8).fixedSize(horizontal: false, vertical: true)
                Text("Enter your server address and sign in. The sign-in is saved on this Apple TV.")
                    .font(.system(size: 26)).foregroundStyle(Color.tvMuted).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: 720, alignment: .leading)
            VStack(alignment: .leading, spacing: 22) {
                field("Server address") {
                    TextField("", text: $server, prompt: prompt("https://jellyfin.example"))
                        .textContentType(.URL).accessibilityIdentifier("server")
                }
                field("Username") {
                    TextField("", text: $username, prompt: prompt("Username"))
                        .textContentType(.username).accessibilityIdentifier("username")
                }
                field("Password") {
                    SecureField("", text: $password, prompt: prompt("Password"))
                        .textContentType(.password).accessibilityIdentifier("password")
                }
                if server.lowercased().hasPrefix("http:") {
                    Text("HTTP is unencrypted. Use it only on a trusted local network.").font(.system(size: 24)).foregroundStyle(Color.tvMuted)
                }
                if let error { Text(error).font(.system(size: 24)).foregroundStyle(Color.reelText).accessibilityIdentifier("connectionError") }
                HStack(spacing: 24) {
                    // As wide as the fields, so it reads as the form's one action.
                    Button { connect() } label: {
                        HStack(spacing: 14) { if busy { ProgressView() }; Text(busy ? "Signing in…" : "Sign in") }
                            .frame(maxWidth: .infinity)
                    }.disabled(busy).focused($signInFocused).accessibilityIdentifier("connect")
                    if addingServer || busy { Button("Cancel") { cancelConnection() }.accessibilityIdentifier("cancelConnection") }
                }.padding(.top, 18)
            }
            .font(.system(size: 26, weight: .semibold))
            .frame(width: 700)
            .padding(40)
            .background(Color.reelSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focusSection()
        }
        .padding(.horizontal, 100)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.reelBackground.ignoresSafeArea())
        .onExitCommand { if addingServer || busy { cancelConnection() } }
        .onChange(of: busy) { _, value in if !value { signInFocused = true } }
        .onDisappear { attemptID = UUID(); task?.cancel(); password = "" }
    }

    private func prompt(_ text: String) -> Text {
        Text(text).foregroundStyle(Color.tvFieldPlaceholder)
    }

    /// A label above each field keeps its purpose visible after it holds a value. tvOS draws the field's capsule,
    /// its text colors and its focused lift. At rest that capsule only darkens what is under it by about a third,
    /// so a lighter fill beneath it lands on the raised surface color.
    private func field<Input: View>(_ label: String, @ViewBuilder input: () -> Input) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.system(size: 24, weight: .semibold)).foregroundStyle(Color.reelText.opacity(0.82)).accessibilityHidden(true)
            input()
                .font(.system(size: 28, weight: .medium))
                .disabled(busy)
                .accessibilityLabel(label)
                .background(Capsule().fill(Color(red: 0.2, green: 0.2, blue: 0.224)))
        }
    }

    private func connect() {
        guard !busy else { return }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Enter your server address and username."; return
        }
        busy = true; error = nil
        let current = UUID(); attemptID = current
        let address = server, name = username, secret = password
        task = Task {
            defer { if attemptID == current { busy = false } }
            do {
                try await coordinator.session.signIn(server: address, username: name, password: secret)
                guard attemptID == current, !Task.isCancelled else { return }
                password = ""
                if addingServer { dismiss() }
            } catch is CancellationError { }
            catch { if attemptID == current { self.error = error.localizedDescription } }
        }
    }

    private func cancelConnection() {
        attemptID = UUID(); task?.cancel(); task = nil; busy = false; error = nil
        if addingServer { dismiss() }
    }
}
