import SwiftUI

struct AdvancedConnectionView: View {
    @Binding var server: String
    let deviceID: String
    let onAuthenticated: @MainActor (Account) async throws -> Void
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var discovery = ServerDiscovery(configuration: Self.discoveryConfiguration)
    @State private var quickConnect = QuickConnectSignIn()
    @State private var headers: [GatewayHeader] = []
    @State private var headersLoaded = false
    @State private var headerError: String?
    @State private var savedHeaders: [GatewayHeader]?
    private var saved: Bool { savedHeaders == headers }

    private static var discoveryConfiguration: ServerDiscovery.Configuration {
        #if DEBUG && targetEnvironment(simulator)
        if let fixture = ServerDiscovery.Configuration.simulatorFixture(arguments: ProcessInfo.processInfo.arguments) { return fixture }
        #endif
        return .localNetwork
    }

    var body: some View {
        Form {
            Section {
                TextField("https://your-server", text: $server).keyboardType(.URL).textContentType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("advancedServer")
            } header: { Text("Server address") }
            Section {
                if discovery.status == .searching {
                    HStack {
                        ProgressView(); Text("Looking on your local network…").accessibilityIdentifier("discoverySearching")
                        Spacer(); Button("Stop") { discovery.stop() }.accessibilityIdentifier("stopDiscovery")
                    }
                } else {
                    Button { discovery.start() } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "wifi").accessibilityHidden(true)
                            Text("Find nearby servers")
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.accessibilityLabel("Find nearby servers").accessibilityIdentifier("discoverServers")
                }
                ForEach(discovery.servers) { discovered in
                    Button {
                        server = discovered.address.absoluteString
                        discovery.stop()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(discovered.name).font(.headline)
                            Text(discovered.address.absoluteString).font(.caption).foregroundStyle(Color.reelMuted)
                        }
                    }.accessibilityIdentifier("discovered-\(discovered.serverID)")
                }
                if discovery.status == .finished, discovery.servers.isEmpty { Text("No servers replied. You can enter the address above and sign in normally.").font(.footnote).foregroundStyle(Color.reelMuted).accessibilityIdentifier("discoveryEmpty") }
                if let error = discovery.error { Text(error).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("discoveryError") }
                if discovery.isLoopbackOnly { Text("Loopback discovery test").font(.caption2).foregroundStyle(Color.reelMuted).accessibilityIdentifier("discoveryLoopbackOnly") }
            } header: { Text("Local discovery") } footer: {
                Text("Search sends one Jellyfin discovery message on UDP 7359 and stops after four seconds. Discovery needs Local Network access; broadcast networking on a physical iPhone also needs an Apple entitlement in the installed build.")
            }
            Section {
                if let code = quickConnect.code {
                    Text(code).font(.system(size: 38, weight: .bold, design: .monospaced)).tracking(7)
                        .frame(maxWidth: .infinity).textSelection(.enabled).accessibilityIdentifier("quickConnectCode")
                    Text("In another signed-in Jellyfin app or browser, open Quick Connect and enter this code. Approve only the connection you requested.")
                        .font(.subheadline).foregroundStyle(Color.reelMuted)
                    HStack { ProgressView(); Text(quickConnect.status == .completing ? "Completing sign-in…" : "Waiting for approval…"); Spacer(); Button("Cancel") { quickConnect.cancel() } }
                } else if quickConnect.status == .requesting { HStack { ProgressView(); Text("Checking Quick Connect…"); Spacer(); Button("Cancel") { quickConnect.cancel() } } }
                else {
                    Button { startQuickConnect() } label: { Label("Sign in with Quick Connect", systemImage: "number.square") }
                        .disabled(!headersLoaded).accessibilityIdentifier("quickConnect")
                }
                if let error = quickConnect.error { Text(error).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("quickConnectError") }
            } header: { Text("Quick Connect") } footer: { Text("Your server must enable Quick Connect. Password sign-in remains available when it is disabled.") }
            Section {
                ForEach($headers) { $header in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Header name", text: $header.name).font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier("gatewayName")
                            Button(role: .destructive) { headers.removeAll { $0.id == header.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("Remove gateway header")
                        }
                        SecureField("Header value", text: $header.value).font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("gatewayValue")
                    }.padding(.vertical, 5)
                }
                Button { headers.append(GatewayHeader()) } label: { Label("Add gateway header", systemImage: "plus.circle") }
                    .disabled(!headersLoaded || headers.count >= 16).accessibilityIdentifier("addGatewayHeader")
                Button(saved ? "Headers saved" : "Save gateway headers") { saveHeaders() }
                    .disabled(!headersLoaded).accessibilityIdentifier("saveGatewayHeaders")
                if let headerError {
                    Text(headerError).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("gatewayError")
                    if !headersLoaded { Button("Retry secure storage") { loadHeaders() } }
                }
            } header: { Text("Gateway authentication") } footer: {
                Text("For gateways that require separate headers, such as Cloudflare Access client credentials. Values stay in this device’s Keychain and apply only to this server over HTTPS. Reel manages its own Authorization, cookies and Host headers. Save before using password sign-in. These headers support sign-in, browsing, artwork and downloads. Native playback uses a private local connection to keep gateway credentials within this server. Casting and optimized background downloads require a receiver-accessible stream without extra gateway headers.")
            }
        }
        .scrollContentBackground(.hidden).background(Color.reelBackground)
        .navigationTitle("Connection options").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .toolbarMinimizationBehavior(.never, for: .navigationBar)
        .task(id: server) { quickConnect.cancel(); savedHeaders = nil; loadHeaders() }
        .onDisappear { discovery.stop(); quickConnect.cancel(); headers = [] }
    }

    private func loadHeaders() {
        headersLoaded = false; headers = []; headerError = nil
        do {
            let address = try JellyfinAPI.normalize(server)
            headers = try GatewayHeaderStore.read(for: address)
            headersLoaded = true
        } catch { headerError = error.localizedDescription }
    }

    @discardableResult private func saveHeaders() -> Bool {
        headerError = nil
        do {
            let address = try JellyfinAPI.normalize(server)
            headers = try GatewayHeaderStore.validated(headers)
            try GatewayHeaderStore.save(headers, for: address)
            savedHeaders = headers
            return true
        } catch { headerError = error.localizedDescription; return false }
    }

    private func startQuickConnect() {
        guard saveHeaders(), let address = try? JellyfinAPI.normalize(server) else { return }
        let api = JellyfinAPI(server: address, deviceID: deviceID)
        quickConnect.begin(api: api, protectedAccounts: session.accounts) { account in
            try await onAuthenticated(account)
            dismiss()
        }
    }
}
