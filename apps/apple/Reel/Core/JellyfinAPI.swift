import Foundation

final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    let server: URL?
    init(server: URL? = nil) { self.server = server }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let from = task.originalRequest?.url, let to = request.url,
              JellyfinAPI.sameOrigin(from, to) else { completionHandler(nil); return }
        if let server {
            let base = server.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let target = to.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard base.isEmpty || target == base || target.hasPrefix(base + "/") else { completionHandler(nil); return }
        }
        completionHandler(request)
    }
}

struct JellyfinAPI: Sendable {
    let server: URL
    let token: String?
    let userID: String?
    let deviceID: String
    let historyEnabled: Bool
    let gatewayHeaders: [GatewayHeader]
    var isSimulatorPreview: Bool { Self.previewProtected(server: server) }
    static func previewProtected(server: URL) -> Bool {
        #if DEBUG || targetEnvironment(simulator)
        return !GatewayHeaderStore.isLoopback(server.host)
        #else
        return false
        #endif
    }
    var redirects: SameOriginRedirects { SameOriginRedirects(server: server) }
    var recordsHistory: Bool { historyEnabled && !isSimulatorPreview }
    static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
    }()
    static let fields = "Overview,Genres"

    init(server: URL, token: String? = nil, userID: String? = nil, deviceID: String, historyEnabled: Bool = true) {
        self.server = server; self.token = token; self.userID = userID; self.deviceID = deviceID; self.historyEnabled = historyEnabled
        gatewayHeaders = (try? GatewayHeaderStore.read(for: server)) ?? []
    }

    static func normalize(_ raw: String) throws -> URL {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw ReelError.invalidServer }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        if parts.scheme == "http", !isPrivateHost(host) { throw ReelError.insecureRemote }
        parts.path = parts.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = parts.url else { throw ReelError.invalidServer }
        return url
    }

    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "::1" || h.hasSuffix(".local") || h.hasSuffix(".ts.net") { return true }
        let components = h.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return false }
        let n = components.compactMap { Int($0) }
        guard n.count == 4, n.allSatisfy({ (0...255).contains($0) }) else { return false }
        return n[0] == 10 || n[0] == 127 || (n[0] == 192 && n[1] == 168)
            || (n[0] == 172 && (16...31).contains(n[1])) || (n[0] == 100 && (64...127).contains(n[1]))
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ u: URL) -> Int { u.port ?? (u.scheme == "https" ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }

    var authorization: String {
        func clean(_ s: String) -> String { s.filter { $0 != "\"" && $0 != "\\" && !$0.isNewline && !$0.isASCIIControl } }
        var value = "MediaBrowser Client=\"Reel\", Device=\"iPhone\", DeviceId=\"\(clean(deviceID))\", Version=\"1.0.0\""
        if let token { value += ", Token=\"\(clean(token))\"" }
        return value
    }

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var parts = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        parts.path += "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !query.isEmpty { parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return parts.url!
    }

    func request(_ path: String, query: [String: String] = [:], method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.timeoutInterval = 18
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        try? GatewayHeaderStore.apply(gatewayHeaders, to: &request, server: server)
        return request
    }

    func send(_ request: URLRequest) async throws -> Data {
        let path = request.url?.path.lowercased() ?? ""
        let mutates = !["GET", "HEAD"].contains(request.httpMethod ?? "GET")
        let history = path.contains("/sessions/playing") || path.contains("/userplayeditems")
        let previewAllowed = path.hasSuffix("/users/authenticatebyname") || path.hasSuffix("/quickconnect/initiate") || path.hasSuffix("/users/authenticatewithquickconnect") || path.hasSuffix("/playbackinfo")
            || path.hasSuffix("/sessions/logout") || path.hasSuffix("/videos/activeencodings") || path.hasSuffix("/livestreams/close")
        if mutates && ((history && !recordsHistory) || (isSimulatorPreview && !previewAllowed)) { throw ReelError.previewProtected }
        do {
            let (data, response) = try await Self.transport.data(for: request, delegate: redirects)
            guard let response = response as? HTTPURLResponse else { throw ReelError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else {
                if response.statusCode == 401 || response.statusCode == 403 { throw ReelError.unauthorized }
                throw ReelError.server(response.statusCode)
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as ReelError { throw error }
        catch { throw ReelError.unavailable }
    }

    func get<T: Decodable & Sendable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await decode(request(path, query: query))
    }
    func decode<T: Decodable & Sendable>(_ request: URLRequest) async throws -> T {
        let data = try await send(request)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ReelError.invalidResponse }
    }
    func post(_ path: String, body: [String: any Sendable] = [:], query: [String: String] = [:], method: String = "POST") async throws {
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(request(path, query: query, method: method, body: data))
    }

    func authenticate(username: String, password: String) async throws -> Account {
        let info: ServerInfo = try await get("System/Info/Public")
        let body = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        let auth: Authentication = try await decode(request("Users/AuthenticateByName", method: "POST", body: body))
        guard !auth.AccessToken.isEmpty, !auth.User.Id.isEmpty else { throw ReelError.invalidResponse }
        return Account(server: server, token: auth.AccessToken, userID: auth.User.Id, name: auth.User.Name, serverName: info.ServerName)
    }

    var userQuery: [String: String] { ["userId": userID ?? "", "fields": Self.fields, "enableUserData": "true"] }
    func page(_ path: String, query: [String: String] = [:]) async throws -> ItemPage {
        try await get(path, query: userQuery.merging(query) { _, new in new })
    }
    func item(_ id: String) async throws -> MediaItem { try await get("Items/\(id)", query: userQuery.merging(["fields": "Overview,Genres,MediaSources,People,Chapters"]) { _, new in new }) }
    func latest(type: String) async throws -> [MediaItem] {
        try await get("Items/Latest", query: userQuery.merging(["includeItemTypes": type, "limit": "18"]) { _, new in new })
    }
    func favorite(_ id: String, value: Bool) async throws {
        _ = try await send(request("UserFavoriteItems/\(id)", query: ["userId": userID ?? ""], method: value ? "POST" : "DELETE"))
    }
    func imageRequest(_ item: MediaItem, backdrop: Bool, width: Int) -> URLRequest {
        let ref = item.imageReference(backdrop: backdrop)
        var q = ["maxWidth": String(width), "quality": "85"]
        q["tag"] = ref.tag
        return request("Items/\(ref.id)/Images/\(ref.type)", query: q)
    }

    func playback(_ item: MediaItem, quality: StreamQuality, audio: Int? = nil, subtitle: Int? = nil, mediaSourceID: String? = nil, forceHLS: Bool = false, compatibilityMode: Bool = false, bitrate: Int? = nil, liveStreamID: String? = nil) async throws -> PlaybackInfo {
        let bitrate = min(120_000_000, max(250_000, bitrate ?? quality.rawValue))
        let policy = PlaybackNegotiation(forceHLS: forceHLS, compatibilityMode: compatibilityMode, dataSaver: quality == .dataSaver)
        let capabilities = PlaybackCapabilities.current()
        let profile = capabilities.profile(bitrate: bitrate, compatibility: policy.compatibility, dataSaver: quality == .dataSaver)
        var body: [String: any Sendable] = ["UserId": userID ?? "", "MaxStreamingBitrate": bitrate,
            "StartTimeTicks": item.resumeTicks, "EnableDirectPlay": policy.allowsDirectPlay(audio: audio, subtitle: subtitle),
            "EnableDirectStream": false, "EnableTranscoding": true, "AllowVideoStreamCopy": policy.allowsStreamCopy,
            "AllowAudioStreamCopy": policy.allowsStreamCopy, "AutoOpenLiveStream": true, "DeviceProfile": profile]
        body["AudioStreamIndex"] = audio
        body["SubtitleStreamIndex"] = subtitle
        body["MediaSourceId"] = mediaSourceID
        body["LiveStreamId"] = liveStreamID
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await decode(request("Items/\(item.id)/PlaybackInfo", method: "POST", body: data))
    }

    func streamURL(item: MediaItem, source: MediaSource, sessionID: String) throws -> (url: URL, method: String, offset: Double) {
        let endpoint: URL
        let method: String
        let offset: Double
        if source.SupportsDirectPlay == true {
            endpoint = url("Videos/\(item.id)/stream", query: ["static": "true", "mediaSourceId": source.Id, "playSessionId": sessionID, "deviceId": deviceID])
            method = "DirectPlay"; offset = 0
        } else if let path = source.TranscodingUrl, let parsed = URLComponents(string: path) {
            if parsed.scheme != nil || parsed.host != nil {
                guard let absolute = parsed.url else { throw ReelError.noStream }
                endpoint = absolute
            } else {
                var target = URLComponents(url: server, resolvingAgainstBaseURL: false)!
                let base = server.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let relative = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                target.path = "/" + ((!base.isEmpty && relative != base && !relative.hasPrefix(base + "/")) ? base + "/" + relative : relative)
                target.percentEncodedQuery = parsed.percentEncodedQuery
                endpoint = target.url!
            }
            method = "Transcode"; offset = 0
        } else { throw ReelError.noStream }
        guard Self.sameOrigin(server, endpoint), var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil else { throw ReelError.unsafeStream }
        // AVPlayer loads HLS subresources itself; Jellyfin's native stream authentication uses ApiKey.
        parts.queryItems = (parts.queryItems ?? []).filter { !["apikey", "api_key"].contains($0.name.lowercased()) }
        parts.queryItems?.append(URLQueryItem(name: "ApiKey", value: token))
        guard let authenticated = parts.url else { throw ReelError.noStream }
        return (authenticated, method, offset)
    }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}
