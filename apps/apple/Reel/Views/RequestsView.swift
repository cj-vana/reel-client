import SwiftUI
import ImageIO

struct RequestsView: View {
    @Environment(Session.self) private var session
    @State private var store = SeerrStore()
    @State private var configuring = false
    @State private var disconnecting = false
    var body: some View {
        Group {
            if let connection = store.connection, let api = store.api {
                SeerrLibraryView(api: api, user: connection.user, accountID: session.account?.id ?? "")
                    .id((session.account?.id ?? "") + connection.server.absoluteString + String(connection.user.id))
            } else if let account = session.account {
                SeerrConnectView(store: store, accountID: account.id, accountName: account.name, cancellable: false)
            }
        }
        .background(Color.reelBackground)
        .navigationTitle("Requests")
        .toolbar {
            if let connection = store.connection {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Text(connection.user.name + " · " + (connection.server.host ?? "Seerr"))
                        Button("Connection settings", systemImage: "server.rack") { configuring = true }
                        Button("Disconnect Seerr", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { disconnecting = true }
                    } label: { Image(systemName: "person.crop.circle").frame(width: 44, height: 44) }
                        .accessibilityIdentifier("seerrConnectionOptions")
                }
            }
        }
        .task(id: session.account?.id) { if let account = session.account { store.restore(accountID: account.id) } }
        .sheet(isPresented: $configuring) {
            if let account = session.account { NavigationStack { SeerrConnectView(store: store, accountID: account.id, accountName: account.name, cancellable: true) } }
        }
        .confirmationDialog("Disconnect Seerr on this device?", isPresented: $disconnecting, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { do { try store.disconnect() } catch { store.error = error.localizedDescription } }
        } message: { Text("Your requests stay on Seerr. Only this saved connection is removed.") }
        .alert("Seerr", isPresented: Binding(get: { store.error != nil && store.connection != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

private struct SeerrConnectView: View {
    let store: SeerrStore
    let accountID: String
    let accountName: String
    let cancellable: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var usingKey = true
    @State private var error: String?
    @State private var connectionTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section {
                Label("Find your next watch", systemImage: "sparkle.magnifyingglass").font(.title2.bold())
                Text("Discover movies and series, request missing titles, and follow their status through your Seerr server.").foregroundStyle(Color.reelMuted)
            }
            Section("Seerr connection") {
                TextField("Server address", text: $server).keyboardType(.URL).textContentType(.URL).accessibilityIdentifier("seerrServer")
                Picker("Sign-in method", selection: $usingKey) { Text("API key").tag(true); Text("Jellyfin").tag(false) }.pickerStyle(.segmented).accessibilityIdentifier("seerrAuthMethod")
                if usingKey {
                    SecureField("Seerr API key", text: $apiKey).accessibilityIdentifier("seerrAPIKey")
                    Text("A Seerr API key acts as its administrator. It is sent only to this Seerr address and saved in device-only Keychain.").font(.footnote).foregroundStyle(Color.reelMuted)
                } else {
                    TextField("Jellyfin username", text: $username).textContentType(.username).accessibilityIdentifier("seerrUsername")
                    SecureField("Jellyfin password", text: $password).textContentType(.password).accessibilityIdentifier("seerrPassword")
                    Text("Use the Jellyfin account linked to this Seerr server. Your password is used to sign in and is never saved. Complete Seerr’s initial setup in Seerr first.").font(.footnote).foregroundStyle(Color.reelMuted)
                }
                if server.lowercased().hasPrefix("http:") { Text("HTTP sends this sign-in unencrypted. Use trusted Wi-Fi or Tailscale, or connect with HTTPS.").font(.footnote).foregroundStyle(Color.reelMuted) }
                #if targetEnvironment(simulator)
                Text("Real servers are read-only in Simulator. API keys can browse; Jellyfin sign-in and request changes are blocked. Loopback test servers support the complete workflow.").font(.footnote).foregroundStyle(Color.reelBlue)
                #endif
            }.disabled(store.connecting)
            if let error = error ?? store.error { Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("seerrConnectError") } }
            Section {
                Button {
                    error = nil
                    connectionTask = Task {
                        do {
                            try await store.connect(server: server, key: apiKey, username: username, password: password, usingKey: usingKey, accountID: accountID)
                            password = ""; apiKey = ""
                            if cancellable { dismiss() }
                        } catch is CancellationError { }
                        catch { self.error = error.localizedDescription }
                    }
                } label: {
                    HStack { if store.connecting { ProgressView() }; Text(store.connecting ? "Connecting…" : "Connect Seerr"); Spacer(); Image(systemName: "arrow.right") }
                }.disabled(store.connecting || server.isEmpty || (usingKey ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)).accessibilityIdentifier("seerrConnect")
            } footer: { Text("This connection belongs to your current Reel server and account. Each saved Jellyfin connection can use its own Seerr server.") }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .scrollContentBackground(.hidden).background(Color.reelBackground)
        .toolbar { if cancellable { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { connectionTask?.cancel(); dismiss() } } } }
        .onAppear {
            server = store.connection?.server.absoluteString ?? server
            username = accountName
            #if DEBUG
            if let fixture = ProcessInfo.processInfo.environment["REEL_QA_SEERR_SERVER"] { server = fixture }
            #endif
        }
        .onDisappear { connectionTask?.cancel(); password = ""; apiKey = "" }
        .onChange(of: usingKey) { _, _ in password = ""; apiKey = ""; error = nil }
    }
}

private struct SeerrLibraryView: View {
    let api: SeerrAPI
    let user: SeerrUser
    let accountID: String
    @State private var section = "Discover"
    @State private var query = ""
    @State private var titles: [SeerrTitle] = []
    @State private var requests: [SeerrRequest] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var requestTotal = 0
    @State private var loading = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var cancelling: SeerrRequest?
    @State private var changingRequestID: Int?
    private var key: String { section + "|" + query }
    var body: some View {
        VStack(spacing: 14) {
            Picker("Requests view", selection: $section) { Text("Discover").tag("Discover"); Text("My requests").tag("My requests") }
                .pickerStyle(.segmented).padding(.horizontal, 24).accessibilityIdentifier("seerrSection")
            if api.isSimulatorPreview { Label("Preview · request changes off", systemImage: "eye").font(.caption).foregroundStyle(Color.reelBlue) }
            if loading && titles.isEmpty && requests.isEmpty { ProgressView("Opening Seerr…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error, (section == "Discover" ? titles.isEmpty : requests.isEmpty) { FailureView(message: error) { Task { await load(reset: true) } } }
            else if section == "Discover" { discovery }
            else { requestList }
        }
        .background(Color.reelBackground)
        .searchable(text: $query, prompt: "Discover a movie or series")
        .task(id: key) {
            if !query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            await load(reset: true)
        }
        .onChange(of: query) { _, value in if !value.isEmpty { section = "Discover" } }
        .confirmationDialog("Cancel this pending request?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }), titleVisibility: .visible, presenting: cancelling) { request in
            Button("Cancel request", role: .destructive) {
                cancelling = nil
                Task {
                    changingRequestID = request.id
                    defer { changingRequestID = nil }
                    do { try await api.cancel(request, user: user); await load(reset: true) }
                    catch { self.error = error.localizedDescription }
                }
            }
        } message: { _ in Text("This removes the pending request from Seerr.") }
    }
    private var discovery: some View {
        GeometryReader { geometry in
            ScrollView {
                if titles.isEmpty { ContentUnavailableView("No titles found", systemImage: "magnifyingglass", description: Text("Try another title or clear the search to discover trending movies and series.")).frame(minHeight: 280) }
                let columns = max(2, Int((geometry.size.width - 48) / 170))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns), alignment: .leading, spacing: 24) {
                    ForEach(titles, id: \.listingID) { title in
                        NavigationLink {
                            SeerrDetailView(initial: title, api: api, user: user, accountID: accountID)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                SeerrArtwork(path: title.posterPath, accountID: accountID).aspectRatio(2 / 3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(title.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelText).lineLimit(2)
                                Text([title.kind?.label ?? "", title.year].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Color.reelMuted)
                                if let info = title.mediaInfo { Text(SeerrMediaInfo.label(info.status(is4k: false))).font(.caption2).foregroundStyle(Color.reelBlue) }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("seerrTitle-\(title.listingID)")
                    }
                }.padding(.horizontal, 24)
                if page < totalPages { Button("Load more titles") { Task { await load(reset: false) } }.buttonStyle(QuietButton()).disabled(loading).padding().accessibilityIdentifier("seerrLoadMore") }
                feedback
            }.accessibilityIdentifier("seerrDiscoverScroll").refreshable { await load(reset: true) }
        }
    }
    private var requestList: some View {
        List {
            if requests.isEmpty { ContentUnavailableView("Your next request starts here", systemImage: "tray", description: Text("Find a title in Discover and request it. Its approval and availability will appear here.")) }
            ForEach(requests) { request in
                HStack {
                    SeerrRequestLink(request: request, api: api, user: user, accountID: accountID)
                    if user.canCancel(request) {
                        Button { cancelling = request } label: { Image(systemName: "xmark.circle").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).disabled(api.isSimulatorPreview || loading || changingRequestID != nil).accessibilityLabel("Cancel pending request").accessibilityIdentifier("seerrCancel-\(request.id)")
                    }
                }.listRowBackground(Color.reelSurface)
            }
            if requests.count < requestTotal { Button("Load more requests") { Task { await load(reset: false) } }.disabled(loading).accessibilityIdentifier("seerrMoreRequests") }
            feedback
        }.scrollContentBackground(.hidden).refreshable { await load(reset: true) }.accessibilityIdentifier("seerrRequestsList")
    }
    @ViewBuilder private var feedback: some View {
        if loading && (!titles.isEmpty || !requests.isEmpty) { ProgressView().padding() }
        if let error { VStack(spacing: 10) { Text(error).font(.footnote).foregroundStyle(.orange); Button("Try again") { Task { await load(reset: false) } } }.padding() }
    }
    private func load(reset: Bool) async {
        let current = UUID(); generation = current
        loading = true; error = nil
        let target = key
        if reset { titles = []; requests = []; page = 0; totalPages = 1; requestTotal = 0 }
        defer { if generation == current { loading = false } }
        do {
            if section == "Discover" {
                let result = try await api.browse(query: query, page: page + 1)
                try Task.checkCancellation()
                guard generation == current, key == target else { return }
                let existing = Set(titles.map(\.listingID))
                titles.append(contentsOf: result.results.filter { $0.kind != nil && !existing.contains($0.listingID) })
                page = result.page; totalPages = min(500, result.totalPages)
            } else {
                let result = try await api.myRequests(userID: user.id, skip: requests.count)
                try Task.checkCancellation()
                guard generation == current, key == target else { return }
                let existing = Set(requests.map(\.id))
                requests.append(contentsOf: result.results.filter { !existing.contains($0.id) })
                requestTotal = result.pageInfo.results
            }
        } catch is CancellationError { }
        catch { if generation == current { self.error = error.localizedDescription } }
    }
}

private struct SeerrRequestLink: View {
    let request: SeerrRequest
    let api: SeerrAPI
    let user: SeerrUser
    let accountID: String
    @State private var title: SeerrTitle?
    var body: some View {
        Group {
            if let id = request.media?.tmdbId, let kind = request.kind {
                NavigationLink { SeerrDetailView(initial: title ?? SeerrTitle(id: id, mediaType: kind.rawValue), api: api, user: user, accountID: accountID) } label: { label }.accessibilityIdentifier("seerrRequest-\(request.id)")
            } else { label }
        }
        .task(id: request.id) { if let id = request.media?.tmdbId, let kind = request.kind { title = try? await api.detail(id: id, kind: kind) } }
    }
    private var label: some View {
        HStack(spacing: 14) {
            SeerrArtwork(path: title?.posterPath, accountID: accountID).frame(width: 60, height: 90).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 7) {
                Text(title?.displayTitle ?? "\(request.kind?.label ?? "Media") request #\(request.id)").font(.headline).lineLimit(2)
                Text(request.statusLabel + (request.is4k == true ? " · 4K" : "")).font(.subheadline).foregroundStyle(Color.reelBlue)
                if let seasons = request.seasons, !seasons.isEmpty { Text("Seasons " + seasons.map { String($0.seasonNumber) }.joined(separator: ", ")).font(.caption).foregroundStyle(Color.reelMuted) }
            }
        }.padding(.vertical, 5).contentShape(Rectangle())
    }
}

private struct SeerrDetailView: View {
    let initial: SeerrTitle
    let api: SeerrAPI
    let user: SeerrUser
    let accountID: String
    @State private var detail: SeerrTitle?
    @State private var selectedSeasons: Set<Int> = []
    @State private var is4k = false
    @State private var quota: SeerrQuota?
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    @State private var message: String?
    @State private var confirming = false
    @State private var cancelling: SeerrRequest?
    @State private var readGeneration = UUID()
    private var current: SeerrTitle { detail ?? initial }
    private var kind: SeerrMediaKind { initial.kind ?? .movie }
    private var unavailable: Set<Int> { current.unavailableSeasons(is4k: is4k) }
    private var availableSeasons: [SeerrSeason] { (current.seasons ?? []).filter { !unavailable.contains($0.seasonNumber) && ($0.episodeCount ?? 1) > 0 } }
    private var canSubmit: Bool {
        guard detail != nil, !loading, !busy, !api.isSimulatorPreview, user.canRequest(kind, is4k: is4k), quota?.remaining(for: kind).restricted != true else { return false }
        if kind == .tv {
            if let quota = quota?.tv, (quota.limit ?? 0) > 0, let remaining = quota.remaining, selectedSeasons.count > remaining { return false }
            return !selectedSeasons.isEmpty && selectedSeasons.isDisjoint(with: unavailable)
        }
        return ![2, 3, 4, 5].contains(current.mediaInfo?.status(is4k: is4k) ?? 1)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SeerrArtwork(path: current.backdropPath, backdrop: true, accountID: accountID).frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 18))
                Text(current.displayTitle).font(.largeTitle.bold()).accessibilityIdentifier("seerrDetailTitle")
                HStack(spacing: 14) {
                    Text([kind.label, current.year].filter { !$0.isEmpty }.joined(separator: " · "))
                    if let rating = current.voteAverage, rating > 0 { Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(Color.reelBlue) }
                }.font(.subheadline).foregroundStyle(Color.reelMuted)
                Text(SeerrMediaInfo.label(current.mediaInfo?.status(is4k: is4k) ?? 1)).font(.headline).foregroundStyle(Color.reelBlue)
                if let overview = current.overview, !overview.isEmpty { Text(overview).foregroundStyle(Color.reelMuted).lineSpacing(5) }
                if loading { ProgressView("Checking availability…") }
                if user.canRequest(kind, is4k: true) { Toggle("Request 4K version", isOn: $is4k).disabled(busy).accessibilityIdentifier("seerr4K") }
                if kind == .tv { seasonSelection }
                if let limit = quota?.remaining(for: kind), let maximum = limit.limit, maximum > 0 { Text("\(limit.remaining ?? 0) of \(maximum) \(kind == .movie ? "movie requests" : "season requests") remaining in your quota.").font(.footnote).foregroundStyle(Color.reelMuted) }
                if !user.canRequest(kind, is4k: is4k) { Label("Your Seerr account cannot request this media type.", systemImage: "lock").foregroundStyle(Color.reelMuted) }
                if api.isSimulatorPreview { Label("Simulator preview · requests are read-only", systemImage: "eye").font(.subheadline).foregroundStyle(Color.reelBlue) }
                Button { confirming = true } label: { HStack { if busy { ProgressView() }; Label(kind == .movie ? "Request movie" : "Request selected seasons", systemImage: "plus.circle") } }
                    .buttonStyle(PrimaryButton()).disabled(!canSubmit).accessibilityIdentifier("seerrSubmitRequest")
                if let message { Label(message, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(Color.reelBlue).accessibilityIdentifier("seerrRequestSuccess") }
                if let error { VStack(alignment: .leading, spacing: 10) { Text(error).font(.footnote).foregroundStyle(.orange); Button("Refresh status") { Task { await load() } } }.accessibilityIdentifier("seerrRequestError") }
                if let requests = current.mediaInfo?.requests, !requests.isEmpty {
                    Text("Requests for this title").font(.title2.bold())
                    ForEach(requests) { request in
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(request.statusLabel + (request.is4k == true ? " · 4K" : "")).font(.headline)
                                if let seasons = request.seasons, !seasons.isEmpty { Text("Seasons " + seasons.map { String($0.seasonNumber) }.joined(separator: ", ")).font(.caption).foregroundStyle(Color.reelMuted) }
                            }
                            Spacer()
                            if user.canCancel(request) { Button("Cancel request") { cancelling = request }.disabled(api.isSimulatorPreview || busy).accessibilityIdentifier("seerrDetailCancel-\(request.id)") }
                        }.padding(16).background(Color.reelSurface, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Color.reelBackground).navigationBarTitleDisplayMode(.inline).refreshable { await load() }
        .task { if user.canRequest(kind, is4k: true) && !user.canRequest(kind) { is4k = true }; await load() }
        .onChange(of: is4k) { _, _ in selectedSeasons = []; message = nil }
        .confirmationDialog(kind == .movie ? "Request \(current.displayTitle)?" : "Request \(selectedSeasons.count) seasons of \(current.displayTitle)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Send request") { Task { await submit() } }
        } message: { Text("Seerr will check your permissions, quota and server configuration. \(is4k ? "This requests the 4K version." : "")") }
        .confirmationDialog("Cancel this pending request?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }), titleVisibility: .visible, presenting: cancelling) { request in
            Button("Cancel request", role: .destructive) {
                cancelling = nil
                Task { busy = true; defer { busy = false }; do { try await api.cancel(request, user: user); message = "Request cancelled"; await load() } catch { self.error = error.localizedDescription } }
            }
        }
    }
    private var seasonSelection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Choose seasons").font(.title2.bold())
                Spacer()
                Button("Select available") { selectedSeasons = Set(availableSeasons.filter { $0.seasonNumber > 0 }.map(\.seasonNumber)) }.disabled(loading || busy || availableSeasons.isEmpty).accessibilityIdentifier("seerrAllSeasons")
            }
            if (current.seasons ?? []).isEmpty && !loading { Text("No seasons are available to request.").foregroundStyle(Color.reelMuted) }
            ForEach(current.seasons ?? []) { season in
                Button {
                    if selectedSeasons.contains(season.seasonNumber) { selectedSeasons.remove(season.seasonNumber) }
                    else { selectedSeasons.insert(season.seasonNumber) }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: selectedSeasons.contains(season.seasonNumber) ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.reelBlue)
                        VStack(alignment: .leading, spacing: 5) { Text(season.label).foregroundStyle(Color.reelText); Text(unavailable.contains(season.seasonNumber) ? "Available or already requested" : "\(season.episodeCount ?? 0) episodes").font(.caption).foregroundStyle(Color.reelMuted) }
                        Spacer()
                    }.padding(14).background(Color.reelSurface, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(loading || busy || unavailable.contains(season.seasonNumber) || (season.episodeCount ?? 1) == 0).accessibilityIdentifier("seerrSeason-\(season.seasonNumber)")
            }
        }
    }
    private func load() async {
        let generation = UUID(); readGeneration = generation
        loading = true; error = nil
        defer { if readGeneration == generation { loading = false } }
        do {
            async let quotaResult = try? api.quota(userID: user.id)
            let result = try await api.detail(id: initial.id, kind: kind)
            let updatedQuota = await quotaResult
            try Task.checkCancellation()
            guard readGeneration == generation else { return }
            detail = result
            quota = updatedQuota
            selectedSeasons.subtract(unavailable)
        } catch is CancellationError { }
        catch { if readGeneration == generation { self.error = error.localizedDescription } }
    }
    private func submit() async {
        guard canSubmit else { return }
        busy = true; error = nil; message = nil
        defer { busy = false }
        do {
            let request = try await api.create(title: current, kind: kind, seasons: selectedSeasons, is4k: is4k, user: user)
            selectedSeasons = []
            await load()
            message = "Request sent · " + request.statusLabel
        } catch is CancellationError { }
        catch {
            let failure = error.localizedDescription
            await load()
            self.error = failure
        }
    }
}

private struct SeerrArtwork: View {
    let path: String?
    var backdrop = false
    let accountID: String
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color.reelSurface
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "film").font(.title).foregroundStyle(Color.reelMuted.opacity(0.3)) }
        }.clipped().accessibilityHidden(true)
        .task(id: accountID + (path ?? "") + String(backdrop)) {
            image = nil
            guard let url = SeerrTitle.posterURL(path, backdrop: backdrop) else { return }
            do {
                let data = try await ArtworkPipeline.shared.data(request: URLRequest(url: url), userID: "seerr|" + accountID, server: URL(string: "https://image.tmdb.org")!)
                let size = backdrop ? 1280 : 500
                let bitmap = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                }.value
                try Task.checkCancellation()
                if let bitmap { image = UIImage(cgImage: bitmap) }
            } catch { }
        }
    }
}
