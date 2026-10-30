import Foundation
import Observation
import Security

enum SeerrMediaKind: String, Codable, CaseIterable, Sendable {
    case movie, tv
    var label: String { self == .movie ? "Movie" : "Series" }
}

struct SeerrUser: Codable, Hashable, Sendable {
    let id: Int
    var username: String?
    var jellyfinUsername: String?
    var displayName: String?
    var permissions: Int?
    var name: String { displayName ?? username ?? jellyfinUsername ?? "Seerr account" }
    func has(_ permission: Int) -> Bool { ((permissions ?? 0) & 2) != 0 || ((permissions ?? 0) & permission) != 0 }
    func canRequest(_ kind: SeerrMediaKind, is4k: Bool = false) -> Bool {
        if is4k { return has(1024) || has(kind == .movie ? 2048 : 4096) }
        return has(32) || has(kind == .movie ? 262144 : 524288)
    }
    func canCancel(_ request: SeerrRequest) -> Bool {
        request.status == 1 && (request.requestedBy?.id == id || has(16))
    }
}

struct SeerrSeason: Codable, Hashable, Identifiable, Sendable {
    let seasonNumber: Int
    var name: String?
    var episodeCount: Int?
    var status: Int?
    var status4k: Int?
    var id: Int { seasonNumber }
    var label: String { name ?? (seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)") }
}

struct SeerrMediaInfo: Codable, Hashable, Sendable {
    var id: Int?
    var tmdbId: Int?
    var mediaType: SeerrMediaKind?
    var status: Int?
    var status4k: Int?
    var requests: [SeerrRequest]?
    var seasons: [SeerrSeason]?
    func status(is4k: Bool) -> Int { (is4k ? status4k : status) ?? 1 }
    static func label(_ status: Int) -> String {
        switch status {
        case 2: "Requested"
        case 3: "Processing"
        case 4: "Partly available"
        case 5: "Available"
        case 6: "Unavailable"
        case 7: "Removed"
        default: "Not in your library"
        }
    }
}

struct SeerrRequest: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let status: Int
    var type: SeerrMediaKind?
    var is4k: Bool?
    var media: SeerrMediaInfo?
    var requestedBy: SeerrUser?
    var seasons: [SeerrSeason]?
    var createdAt: String?
    var kind: SeerrMediaKind? { type ?? media?.mediaType }
    var statusLabel: String {
        switch status {
        case 1: "Awaiting approval"
        case 2: media?.status(is4k: is4k == true) == 5 ? "Available" : "Approved"
        case 3: "Declined"
        case 4: "Failed"
        case 5: "Completed"
        default: "Unknown status"
        }
    }
}

struct SeerrTitle: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    var mediaType: String?
    var title: String?
    var name: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var voteAverage: Double?
    var runtime: Int?
    var seasons: [SeerrSeason]?
    var mediaInfo: SeerrMediaInfo?
    var kind: SeerrMediaKind? { mediaType.flatMap(SeerrMediaKind.init(rawValue:)) }
    var displayTitle: String { title ?? name ?? "Untitled" }
    var year: String { String((releaseDate ?? firstAirDate ?? "").prefix(4)) }
    var listingID: String { (mediaType ?? "unknown") + "-" + String(id) }
    func unavailableSeasons(is4k: Bool) -> Set<Int> {
        var numbers = Set((mediaInfo?.seasons ?? []).filter { (2...5).contains((is4k ? $0.status4k : $0.status) ?? 1) }.map(\.seasonNumber))
        for request in mediaInfo?.requests ?? [] where (request.is4k ?? false) == is4k && [1, 2, 4].contains(request.status) {
            numbers.formUnion((request.seasons ?? []).map(\.seasonNumber))
        }
        return numbers
    }
    static func posterURL(_ path: String?, backdrop: Bool = false) -> URL? {
        guard let path, path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.contains("?"), !path.contains("#"), !path.contains("..") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/" + (backdrop ? "w1280" : "w500") + path)
    }
}

struct SeerrResults: Decodable, Sendable {
    let page: Int
    let totalPages: Int
    let totalResults: Int?
    let results: [SeerrTitle]
}
struct SeerrRequestResults: Decodable, Sendable {
    struct PageInfo: Decodable, Sendable { let results: Int; let pages: Int? }
    let pageInfo: PageInfo
    let results: [SeerrRequest]
}
struct SeerrQuota: Decodable, Sendable {
    struct Limit: Decodable, Sendable {
        var limit: Int?
        var remaining: Int?
        var restricted: Bool?
    }
    let movie: Limit
    let tv: Limit
    func remaining(for kind: SeerrMediaKind) -> Limit { kind == .movie ? movie : tv }
}

struct SeerrConnection: Codable, Equatable, Sendable {
    let server: URL
    let apiKey: String?
    let sessionCookie: String?
    let user: SeerrUser
}

enum SeerrError: LocalizedError, Equatable {
    case signIn, permission, duplicate, noSeasons, invalidResponse, unavailable, previewProtected, invalidSelection, storage
    var errorDescription: String? {
        switch self {
        case .signIn: "Seerr didn’t accept this sign-in, or its session expired. Connect again."
        case .permission: "Seerr denied this action. Check your account permissions, request quota and any blocked titles."
        case .duplicate: "This title or these seasons already have a request. Refresh to see its status."
        case .noSeasons: "These seasons are already available or requested. Refresh and choose other seasons."
        case .invalidResponse: "Seerr returned a response Reel couldn’t read. Check the server address and version."
        case .unavailable: "Seerr couldn’t confirm the action. Check your connection and refresh the status before trying again."
        case .previewProtected: "Simulator preview can browse Seerr using an API key. Sign-in and request changes are disabled for real servers."
        case .invalidSelection: "Choose a movie or at least one available season to request."
        case .storage: "Reel couldn’t save this Seerr connection securely. Unlock the device and try again."
        }
    }
}

enum SeerrSecureStore {
    private static func query(_ accountID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: ReelIdentity.service("seerr"), kSecAttrAccount as String: accountID]
    }
    static func read(accountID: String) throws -> SeerrConnection? {
        var query = query(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let connection = try? JSONDecoder().decode(SeerrConnection.self, from: data) else { throw SeerrError.storage }
        return connection
    }
    static func save(_ connection: SeerrConnection, accountID: String) throws {
        let data = try JSONEncoder().encode(connection)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query(accountID) as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            guard SecItemAdd(query(accountID).merging(attributes) { _, value in value } as CFDictionary, nil) == errSecSuccess else { throw SeerrError.storage }
        } else if result != errSecSuccess { throw SeerrError.storage }
    }
    static func remove(accountID: String) throws {
        let result = SecItemDelete(query(accountID) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw SeerrError.storage }
    }
}

struct SeerrAPI: Sendable {
    let server: URL
    let apiKey: String?
    let sessionCookie: String?
    static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
    }()
    init(server: URL, apiKey: String? = nil, sessionCookie: String? = nil) {
        self.server = server; self.apiKey = apiKey; self.sessionCookie = sessionCookie
    }
    init(connection: SeerrConnection) { self.init(server: connection.server, apiKey: connection.apiKey, sessionCookie: connection.sessionCookie) }
    var isSimulatorPreview: Bool { JellyfinAPI.previewProtected(server: server) }
    func request(_ path: String, query: [String: String] = [:], method: String = "GET", body: Data? = nil) -> URLRequest {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        components.path += "/api/v1/" + path
        components.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        if let sessionCookie { request.setValue(sessionCookie, forHTTPHeaderField: "Cookie") }
        return request
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, JellyfinAPI.sameOrigin(url, server) else { throw SeerrError.invalidResponse }
        if isSimulatorPreview && !["GET", "HEAD"].contains(request.httpMethod ?? "GET") { throw SeerrError.previewProtected }
        do {
            let (data, response) = try await Self.transport.data(for: request, delegate: SameOriginRedirects(server: server))
            guard let response = response as? HTTPURLResponse,
                  response.url.map({ JellyfinAPI.sameOrigin($0, server) }) == true else { throw SeerrError.invalidResponse }
            switch response.statusCode {
            case 200, 201, 204: return (data, response)
            case 202: throw SeerrError.noSeasons
            case 401: throw SeerrError.signIn
            case 403: throw url.path.contains("/auth/") ? SeerrError.signIn : SeerrError.permission
            case 409: throw SeerrError.duplicate
            default: throw SeerrError.unavailable
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as SeerrError { throw error }
        catch { throw SeerrError.unavailable }
    }
    func decode<T: Decodable & Sendable>(_ request: URLRequest) async throws -> T {
        let (data, _) = try await send(request)
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw SeerrError.invalidResponse }
        return value
    }
    func currentUser() async throws -> SeerrUser { try await decode(request("auth/me")) }
    func browse(query: String = "", page: Int = 1) async throws -> SeerrResults {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await decode(request(query.isEmpty ? "discover/trending" : "search", query: query.isEmpty ? ["page": String(max(1, page))] : ["query": query, "page": String(max(1, page))]))
    }
    func detail(id: Int, kind: SeerrMediaKind) async throws -> SeerrTitle {
        var title: SeerrTitle = try await decode(request("\(kind.rawValue)/\(id)"))
        title.mediaType = kind.rawValue
        return title
    }
    func myRequests(userID: Int, skip: Int = 0) async throws -> SeerrRequestResults {
        try await decode(request("user/\(userID)/requests", query: ["take": "20", "skip": String(max(0, skip))]))
    }
    func quota(userID: Int) async throws -> SeerrQuota { try await decode(request("user/\(userID)/quota")) }
    func create(title: SeerrTitle, kind: SeerrMediaKind, seasons: Set<Int>, is4k: Bool, user: SeerrUser) async throws -> SeerrRequest {
        guard user.canRequest(kind, is4k: is4k) else { throw SeerrError.permission }
        guard title.id > 0, kind == .movie || (!seasons.isEmpty && seasons.allSatisfy({ $0 >= 0 })) else { throw SeerrError.invalidSelection }
        var body: [String: Any] = ["mediaType": kind.rawValue, "mediaId": title.id, "is4k": is4k]
        if kind == .tv { body["seasons"] = seasons.sorted() }
        return try await decode(request("request", method: "POST", body: JSONSerialization.data(withJSONObject: body)))
    }
    func cancel(_ request: SeerrRequest, user: SeerrUser) async throws {
        guard user.canCancel(request) else { throw SeerrError.permission }
        _ = try await send(self.request("request/\(request.id)", method: "DELETE"))
    }
    func jellyfinLogin(username: String, password: String) async throws -> SeerrConnection {
        let data = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let (body, response) = try await send(request("auth/jellyfin", method: "POST", body: data))
        guard let user = try? JSONDecoder().decode(SeerrUser.self, from: body) else { throw SeerrError.invalidResponse }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: server).first(where: { $0.name == "connect.sid" }),
              !cookie.value.isEmpty else { throw SeerrError.signIn }
        return SeerrConnection(server: server, apiKey: nil, sessionCookie: cookie.name + "=" + cookie.value, user: user)
    }
}

@MainActor @Observable final class SeerrStore {
    private(set) var connection: SeerrConnection?
    private(set) var connecting = false
    var error: String?
    private var accountID: String?
    private var generation = UUID()
    var api: SeerrAPI? { connection.map(SeerrAPI.init(connection:)) }
    func restore(accountID: String) {
        generation = UUID(); self.accountID = accountID; connection = nil; connecting = false; error = nil
        do { connection = try SeerrSecureStore.read(accountID: accountID) }
        catch { self.error = error.localizedDescription }
    }
    func connect(server: String, key: String, username: String, password: String, usingKey: Bool, accountID: String) async throws {
        let current = generation
        connecting = true
        defer { if generation == current { connecting = false } }
        let url = try JellyfinAPI.normalize(server)
        let connection: SeerrConnection
        if usingKey {
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw SeerrError.signIn }
            let user = try await SeerrAPI(server: url, apiKey: key).currentUser()
            connection = SeerrConnection(server: url, apiKey: key, sessionCookie: nil, user: user)
        } else {
            guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SeerrError.signIn }
            connection = try await SeerrAPI(server: url).jellyfinLogin(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        }
        try Task.checkCancellation()
        guard generation == current, self.accountID == accountID else { throw CancellationError() }
        try SeerrSecureStore.save(connection, accountID: accountID)
        self.connection = connection
        error = nil
    }
    func disconnect() throws {
        guard let accountID else { return }
        try SeerrSecureStore.remove(accountID: accountID)
        generation = UUID(); connecting = false; connection = nil; error = nil
    }
}
