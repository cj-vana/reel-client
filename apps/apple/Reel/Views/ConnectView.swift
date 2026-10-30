import SwiftUI

struct ConnectView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .largeTitle) private var headingSize = 32
    var addingServer = false
    let savedAccount: Account?
    init(addingServer: Bool = false, account: Account? = nil) {
        self.addingServer = addingServer
        savedAccount = account
        _server = State(initialValue: account?.server.absoluteString ?? "")
        _username = State(initialValue: account?.name ?? "")
    }
    @State private var showingAdvanced = false
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var connecting = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var reachableName: String?
    @FocusState private var field: Field?
    enum Field { case server, username, password }

    var body: some View {
        GeometryReader { geometry in
          // The layout swap keeps the same fields, so focus and the keyboard
          // survive a width change such as opening a foldable.
          let wide = AdaptiveLayout.connectSideBySide(horizontalSizeClass, accessibility: dynamicTypeSize.isAccessibilitySize, width: geometry.size.width)
          let column = wide || horizontalSizeClass != .regular ? 1100 : AdaptiveLayout.Connect.stackedColumn
          ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if addingServer { form.frame(maxWidth: 500) }
                    else {
                        // Side by side, the mark heads the page and the pair sits in the middle.
                        // Stacked, the form rests on the bottom within thumb reach, and the mark
                        // and introduction sit centered in the room above it, so a tall phone
                        // shows no empty band. When the keyboard or large text takes the room, it scrolls.
                        if wide { ReelMark().padding(.top, 8); Spacer(minLength: 40) }
                        // Both spaces sit in the one stack so they split the room evenly; the
                        // optional spaces keep the introduction and the form at fixed positions.
                        let layout = wide
                            ? AnyLayout(HStackLayout(alignment: .center, spacing: 56))
                            : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                        layout {
                            if !wide { Spacer(minLength: 0) }
                            introduction(withMark: !wide)
                            if !wide { Spacer(minLength: 28) }
                            form.frame(maxWidth: wide ? 380 : .infinity)
                        }
                        if wide { Spacer(minLength: 40) }
                    }
                }
                .padding(.horizontal, wide ? 48 : 24).padding(.vertical, 24)
                .frame(maxWidth: column, minHeight: geometry.size.height, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: field) { _, focused in
                if let focused { reveal(focused, in: scroll) }
            }
            .onChange(of: geometry.size) { previous, current in
                if current.width != previous.width || current.height < previous.height,
                   let field {
                    reveal(field, in: scroll)
                }
            }
          }
        }
        .background(Color.reelBackground.ignoresSafeArea())
        .toolbar { if addingServer { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { connectionTask?.cancel(); dismiss() } } } }
        .sheet(isPresented: $showingAdvanced) { NavigationStack { AdvancedConnectionView(server: $server, deviceID: session.deviceID) { account in try await session.accept(account); if addingServer { dismiss() } } } }
        .onDisappear { connectionTask?.cancel(); password = "" }
        .task(id: server) {
            reachableName = nil
            do {
                try await Task.sleep(for: .milliseconds(300))
                let api = JellyfinAPI(server: try JellyfinAPI.normalize(server), deviceID: session.deviceID)
                let info: ServerInfo = try await api.get("System/Info/Public")
                try Task.checkCancellation()
                reachableName = info.ServerName
            } catch { }
        }
        .onAppear {
            #if DEBUG
            if savedAccount == nil, let testServer = ProcessInfo.processInfo.environment["REEL_QA_SERVER"] { server = testServer }
            #endif
        }
    }

    private func introduction(withMark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if withMark { ReelMark().padding(.bottom, 14) }
            Text("Connect to Jellyfin")
                .font(.system(size: headingSize, weight: .bold)).tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)
            Text("Sign in to your server to start watching.")
                .font(.body).foregroundStyle(Color.reelMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            if addingServer { Text("Add a server").font(.title2.weight(.bold)).padding(.bottom, 4) }
            VStack(spacing: 0) {
                fieldRow(.server) {
                    HStack(spacing: 8) {
                        fieldLabel("Server address")
                        Spacer(minLength: 8)
                        if let reachableName {
                            Label(reachableName, systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold))
                                .foregroundStyle(Color.reelBlue).lineLimit(1).accessibilityIdentifier("serverReachable")
                        }
                    }
                    TextField("https://your-server", text: $server).textContentType(.URL).keyboardType(.URL)
                        .focused($field, equals: .server).submitLabel(.next).onSubmit { field = .username }
                        .accessibilityIdentifier("server")
                }
                ConnectDivider()
                fieldRow(.username) {
                    fieldLabel("Username")
                    TextField("Your Jellyfin username", text: $username).textContentType(.username)
                        .focused($field, equals: .username).submitLabel(.next).onSubmit { field = .password }
                        .accessibilityIdentifier("username")
                }
                ConnectDivider()
                fieldRow(.password) {
                    fieldLabel("Password")
                    SecureField("Your Jellyfin password", text: $password).textContentType(.password)
                        .focused($field, equals: .password).submitLabel(.go).onSubmit { connect() }.accessibilityIdentifier("password")
                }
            }
            .background(Color.reelSurface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.reelHairline))
            if server.lowercased().hasPrefix("http:") {
                note("HTTP sends your sign-in unencrypted. Use it only on a trusted network or through Tailscale.", systemImage: "lock.open")
            }
            if let error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                    Text(error).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("connectionError")
                }.font(.footnote.weight(.medium)).foregroundStyle(.orange)
            }
            VStack(spacing: 4) {
                Button(action: connect) {
                    HStack(spacing: 10) {
                        if connecting { ProgressView().tint(Color.reelBackground) }
                        Text(connecting ? "Connecting…" : addingServer ? "Save and connect" : "Sign in")
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryButton()).disabled(connecting || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || server.isEmpty)
                    .accessibilityIdentifier("connect")
                Button { showingAdvanced = true } label: {
                    Text("More ways to connect").font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelMuted)
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint("Find servers nearby, use Quick Connect or add gateway headers.")
                    .accessibilityIdentifier("advancedConnection")
            }
            // Room below the buttons so they never sit flush against the keyboard.
            .padding(.bottom, 8).id(Self.connectAnchor)
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .disabled(connecting)
    }

    /// One labelled field in the grouped panel. A tap anywhere on the row focuses its field.
    private func fieldRow(_ which: Field, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) { content() }
            .font(.body).foregroundStyle(Color.reelText)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(Rectangle()).onTapGesture { field = which }
            .id(which)
    }

    private func note(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }.font(.footnote).foregroundStyle(Color.reelMuted).padding(.horizontal, 4)
    }
    /// Keeps the focused field on screen. From the password field the next step is the
    /// connect button, so the button is scrolled up to the keyboard's edge instead; the
    /// password field sits just above it.
    private func reveal(_ focused: Field, in scroll: ScrollViewProxy) {
        if focused == .password { scroll.scrollTo(Self.connectAnchor, anchor: .bottom) }
        else { scroll.scrollTo(focused, anchor: .center) }
    }
    private static let connectAnchor = "connectButton"

    private func fieldLabel(_ value: String) -> some View {
        Text(value).font(.caption.weight(.semibold)).foregroundStyle(Color.reelMuted)
    }
    private func connect() {
        guard !connecting, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        field = nil; error = nil; connecting = true
        connectionTask = Task {
            defer { connecting = false }
            do { try await session.signIn(server: server, username: username, password: password); password = ""; if addingServer { dismiss() } }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Hairline between rows of the sign-in panel, inset to the text.
private struct ConnectDivider: View {
    var body: some View { Rectangle().fill(Color.reelHairline).frame(height: 1).padding(.leading, 16) }
}
