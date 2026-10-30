import Foundation
import Darwin
import Network
import Observation
import Security
import Synchronization

enum ServerConnectionError: LocalizedError, Equatable {
    case invalidHeader, reservedHeader, duplicateHeader, tooManyHeaders, insecureHeaders, headerDestination, headerStorage
    case quickConnectDisabled, quickConnectExpired, invalidQuickConnect, discoveryUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidHeader: "Use a valid HTTP header name and a value without control characters."
        case .reservedHeader: "This header is managed by Reel. Use a separate gateway header, such as CF-Access-Client-Id or X-Api-Key."
        case .duplicateHeader: "Each gateway header needs a different name."
        case .tooManyHeaders: "Use up to 16 gateway headers, with a total size below 16 KB."
        case .insecureHeaders: "Use HTTPS for gateway credentials. Local HTTP sends these values without encryption."
        case .headerDestination: "Gateway credentials can only be sent to their saved server address."
        case .headerStorage: "Gateway credentials couldn’t be read or saved securely. Unlock your device and try again."
        case .quickConnectDisabled: "Quick Connect is disabled on this server. Sign in with your username and password."
        case .quickConnectExpired: "This Quick Connect code expired. Request a new code and try again."
        case .invalidQuickConnect: "The server returned an invalid Quick Connect response. Try password sign-in."
        case .discoveryUnavailable: "Discovery couldn’t use the local network. Check Local Network access in Settings, connect to Wi-Fi, or enter the server address manually."
        }
    }
}

struct GatewayHeader: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var value = ""
}

enum GatewayHeaderStore {
    private static let service = ReelIdentity.service("gatewayHeaders")
    private static let cache = Mutex<[String: [GatewayHeader]]>([:])
    private static let reserved: Set<String> = [
        "authorization", "host", "cookie", "set-cookie", "connection", "content-length", "transfer-encoding",
        "trailer", "te", "upgrade", "accept", "accept-encoding", "content-type", "user-agent", "origin", "referer",
        "forwarded", "via", "x-emby-authorization", "x-emby-token", "x-mediabrowser-token", "x-jellyfin-token"
    ]

    static func validated(_ rows: [GatewayHeader]) throws -> [GatewayHeader] {
        let rows = rows.filter { !$0.name.isEmpty || !$0.value.isEmpty }
        guard rows.count <= 16, rows.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 16_384 else {
            throw ServerConnectionError.tooManyHeaders
        }
        var names: Set<String> = []
        let punctuation = Set("!#$%&'*+-.^_`|~".utf8)
        for row in rows {
            guard !row.name.isEmpty, row.name.utf8.count <= 128, row.value.utf8.count <= 8_192,
                  row.name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || punctuation.contains($0) }),
                  row.value.utf8.allSatisfy({ (32...126).contains($0) }) else { throw ServerConnectionError.invalidHeader }
            let name = row.name.lowercased()
            guard !reserved.contains(name), !name.hasPrefix("proxy-"), !name.hasPrefix("sec-"), !name.hasPrefix("x-forwarded-") else {
                throw ServerConnectionError.reservedHeader
            }
            guard names.insert(name).inserted else { throw ServerConnectionError.duplicateHeader }
        }
        return rows
    }

    private static func query(for server: URL) throws -> [String: Any] {
        let address = try JellyfinAPI.normalize(server.absoluteString)
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: address.absoluteString]
    }

    static func read(for server: URL) throws -> [GatewayHeader] {
        let key = try JellyfinAPI.normalize(server.absoluteString).absoluteString
        return try cache.withLock { cached in
            if let rows = cached[key] { return rows }
            var query = try query(for: server)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { cached[key] = []; return [] }
            guard status == errSecSuccess, let data = result as? Data,
                  let rows = try? JSONDecoder().decode([GatewayHeader].self, from: data) else { throw ServerConnectionError.headerStorage }
            let checked = try validated(rows)
            cached[key] = checked
            return checked
        }
    }

    static func save(_ rows: [GatewayHeader], for server: URL) throws {
        let rows = try validated(rows)
        if rows.isEmpty { try remove(for: server); return }
        // Gateway service tokens are useful on remote networks; require TLS even for a LAN address.
        guard server.scheme?.lowercased() == "https" || isLoopback(server.host) else { throw ServerConnectionError.insecureHeaders }
        let key = try JellyfinAPI.normalize(server.absoluteString).absoluteString
        let query = try query(for: server)
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(rows),
                                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        try cache.withLock { cached in
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if update == errSecItemNotFound {
                guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                    throw ServerConnectionError.headerStorage
                }
            } else if update != errSecSuccess { throw ServerConnectionError.headerStorage }
            cached[key] = rows
        }
    }

    static func remove(for server: URL) throws {
        let key = try JellyfinAPI.normalize(server.absoluteString).absoluteString
        let query = try query(for: server)
        try cache.withLock { cached in
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ServerConnectionError.headerStorage }
            cached[key] = []
        }
    }

    static func apply(_ rows: [GatewayHeader], to request: inout URLRequest, server: URL) throws {
        let rows = try validated(rows)
        guard rows.isEmpty || server.scheme?.lowercased() == "https" || isLoopback(server.host) else { throw ServerConnectionError.insecureHeaders }
        guard let destination = request.url, JellyfinAPI.sameOrigin(destination, server) else { throw ServerConnectionError.headerDestination }
        let basePath = server.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetPath = destination.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !destination.path.split(separator: "/").contains(".."),
              basePath.isEmpty || targetPath == basePath || targetPath.hasPrefix(basePath + "/") else {
            throw ServerConnectionError.headerDestination
        }
        for row in rows { request.setValue(row.value, forHTTPHeaderField: row.name) }
    }

    static func isLoopback(_ host: String?) -> Bool { ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host?.lowercased() ?? "") }
}

struct QuickConnectRequest: Decodable, Sendable {
    let Authenticated: Bool
    let Secret: String
    let Code: String

    func validated() throws -> Self {
        guard (4...16).contains(Code.count), Code.utf8.allSatisfy({ (48...57).contains($0) }),
              (16...1_024).contains(Secret.utf8.count), Secret.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw ServerConnectionError.invalidQuickConnect
        }
        return self
    }
}

extension JellyfinAPI {
    func quickConnectEnabled() async throws -> Bool { try await get("QuickConnect/Enabled") }

    func initiateQuickConnect() async throws -> QuickConnectRequest {
        guard try await quickConnectEnabled() else { throw ServerConnectionError.quickConnectDisabled }
        let result: QuickConnectRequest = try await decode(request("QuickConnect/Initiate", method: "POST"))
        return try result.validated()
    }

    func quickConnectState(secret: String) async throws -> QuickConnectRequest {
        do {
            let result: QuickConnectRequest = try await get("QuickConnect/Connect", query: ["secret": secret])
            let state = try result.validated()
            guard state.Secret == secret else { throw ServerConnectionError.invalidQuickConnect }
            return state
        } catch ReelError.server(404) { throw ServerConnectionError.quickConnectExpired }
    }

    func authenticateQuickConnect(secret: String) async throws -> Account {
        let info: ServerInfo = try await get("System/Info/Public")
        let body = try JSONSerialization.data(withJSONObject: ["Secret": secret])
        let authentication: Authentication = try await decode(request("Users/AuthenticateWithQuickConnect", method: "POST", body: body))
        guard !authentication.AccessToken.isEmpty, !authentication.User.Id.isEmpty else { throw ReelError.invalidResponse }
        return Account(server: server, token: authentication.AccessToken, userID: authentication.User.Id,
                       name: authentication.User.Name, serverName: info.ServerName)
    }
}

@MainActor @Observable final class QuickConnectSignIn {
    enum Status: Equatable { case idle, requesting, waiting, completing, finished, failed }
    private(set) var status = Status.idle
    private(set) var code: String?
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func begin(api: JellyfinAPI, pollInterval: Duration = .seconds(2), lifetime: Duration = .seconds(300), protectedAccounts: [Account] = [],
               onAuthenticated: @escaping @MainActor (Account) async throws -> Void) {
        cancel()
        let current = generation
        status = .requesting
        task = Task { [weak self] in
            guard let self else { return }
            var provisional: Account?
            do {
                let request = try await api.initiateQuickConnect()
                try Task.checkCancellation()
                guard generation == current else { return }
                code = request.Code
                status = .waiting
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: lifetime)
                var authenticated = request.Authenticated
                while !authenticated {
                    guard clock.now < deadline else { throw ServerConnectionError.quickConnectExpired }
                    try await Task.sleep(for: pollInterval)
                    try Task.checkCancellation()
                    let state = try await api.quickConnectState(secret: request.Secret)
                    guard generation == current else { return }
                    authenticated = state.Authenticated
                }
                status = .completing
                let account = try await api.authenticateQuickConnect(secret: request.Secret)
                provisional = account
                try Task.checkCancellation()
                guard generation == current else { throw CancellationError() }
                try await onAuthenticated(account)
                provisional = nil
                guard generation == current else { return }
                code = nil
                status = .finished
                task = nil
            } catch is CancellationError { await revoke(provisional, deviceID: api.deviceID, protecting: protectedAccounts) }
            catch {
                await revoke(provisional, deviceID: api.deviceID, protecting: protectedAccounts)
                guard generation == current else { return }
                code = nil
                self.error = error.localizedDescription
                status = .failed
                task = nil
            }
        }
    }

    private func revoke(_ account: Account?, deviceID: String, protecting accounts: [Account]) async {
        guard let account, !accounts.contains(where: { $0.server == account.server && $0.token == account.token }) else { return }
        // An independent task can revoke the new session even when the sign-in task was cancelled.
        let cleanup = Task {
            let api = JellyfinAPI(server: account.server, token: account.token, userID: account.userID, deviceID: deviceID)
            var request = api.request("Sessions/Logout", method: "POST")
            request.timeoutInterval = 5
            _ = try? await api.send(request)
        }
        await cleanup.value
    }

    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        code = nil; error = nil; status = .idle
    }
}

struct DiscoveredServer: Identifiable, Equatable, Sendable {
    let serverID: String
    let name: String
    let address: URL
    var id: String { address.absoluteString }

    static func parse(_ data: Data, responderHost: String? = nil) throws -> Self {
        struct Response: Decodable { let Id: String; let Name: String; let Address: String }
        guard data.count <= 8_192 else { throw ReelError.invalidResponse }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard !response.Id.isEmpty, response.Id.count <= 200, !response.Name.isEmpty, response.Name.count <= 200,
              response.Address.utf8.count <= 2_048,
              !response.Name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ReelError.invalidResponse }
        let address = try JellyfinAPI.normalize(response.Address)
        guard let host = address.host, isLocalHost(host), responderHost.map(isLocalHost) ?? true else { throw ReelError.invalidServer }
        return Self(serverID: response.Id, name: response.Name, address: address)
    }

    static func isLocalHost(_ host: String) -> Bool {
        if GatewayHeaderStore.isLoopback(host) || host.lowercased().hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let address = IPv4Address(host) else { return false }
        let bytes = Array(address.rawValue)
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 100 && (64...127).contains(bytes[1])) || bytes[0] == 127
    }
}

@MainActor @Observable final class ServerDiscovery {
    enum Status: Equatable { case idle, searching, finished, failed }
    struct Configuration: Sendable {
        let destination: NWEndpoint
        let duration: Duration
        let loopbackOnly: Bool

        static let localNetwork = Self(destination: .hostPort(host: "255.255.255.255", port: 7359), duration: .seconds(4), loopbackOnly: false)

        func allows(destination: NWEndpoint) -> Bool {
            guard case let .hostPort(host, port) = destination, port.rawValue != 0 else { return false }
            if loopbackOnly { return host.debugDescription == "127.0.0.1" }
            return host.debugDescription == "255.255.255.255" || DiscoveredServer.isLocalHost(host.debugDescription)
        }

        func allows(server: DiscoveredServer, responderHost: String) -> Bool {
            !loopbackOnly || (responderHost == "127.0.0.1" && server.address.host == "127.0.0.1")
        }

        #if DEBUG && targetEnvironment(simulator)
        static func simulatorFixture(arguments: [String]) -> Self? {
            let flags = arguments.filter { $0.hasPrefix("-reel-qa-discovery") }
            guard !flags.isEmpty else { return nil }
            let port: UInt16
            switch flags {
            case ["-reel-qa-discovery-loopback"]: port = 17359
            case ["-reel-qa-discovery-empty"]: port = 17360
            default: port = 0
            }
            // Unknown or conflicting fixture flags fail before opening a socket.
            return Self(destination: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), duration: .seconds(4), loopbackOnly: true)
        }
        #endif
    }

    private let configuration: Configuration
    var isLoopbackOnly: Bool { configuration.loopbackOnly }
    private(set) var status = Status.idle
    private(set) var servers: [DiscoveredServer] = []
    private(set) var error: String?
    @ObservationIgnored private var transport: DiscoveryDatagrams?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(configuration: Configuration = .localNetwork) { self.configuration = configuration }

    // Jellyfin uses broadcast, rather than a multicast group. A single unconnected UDP socket
    // receives every unicast reply without Network.framework's shared-source-port limitation.
    func start(destination: NWEndpoint? = nil, duration: Duration? = nil) {
        stop()
        servers = []; error = nil; status = .searching
        let current = generation
        let destination = destination ?? configuration.destination
        let duration = duration ?? configuration.duration
        guard configuration.allows(destination: destination), case let .hostPort(host, port) = destination else {
            fail(current); return
        }
        let transport = DiscoveryDatagrams()
        self.transport = transport
        transport.start(host: host.debugDescription, port: port.rawValue) { [weak self] data, responder in
            Task { @MainActor in
                guard let self, self.generation == current, self.servers.count < 32,
                      let server = try? DiscoveredServer.parse(data, responderHost: responder),
                      self.configuration.allows(server: server, responderHost: responder) else { return }
                if !self.servers.contains(where: { $0.id == server.id }) { self.servers.append(server) }
            }
        } onFailure: { [weak self] in Task { @MainActor in self?.fail(current) } }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, self.generation == current else { return }
            self.stop()
            self.status = .finished
        }
    }

    private func fail(_ current: UUID) {
        guard generation == current else { return }
        stop()
        status = .failed
        error = ServerConnectionError.discoveryUnavailable.localizedDescription
    }

    func stop() {
        generation = UUID()
        timeout?.cancel(); timeout = nil
        transport?.cancel(); transport = nil
        if status == .searching { status = .idle }
    }
}

// Socket state is confined to this serial queue. Only immutable packets cross to the main actor.
private final class DiscoveryDatagrams: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.reelclient.ios.discovery", qos: .userInitiated)
    private var source: DispatchSourceRead?
    private var cancelled = false

    func start(host: String, port: UInt16, onPacket: @escaping @Sendable (Data, String) -> Void,
               onFailure: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !cancelled else { return }
            let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard descriptor >= 0 else { onFailure(); return }
            var broadcast: Int32 = 1
            var ttl: Int32 = 1
            var target = sockaddr_in()
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            target.sin_family = sa_family_t(AF_INET)
            target.sin_port = port.bigEndian
            let valid = host.withCString { inet_pton(AF_INET, $0, &target.sin_addr) } == 1
            guard valid, setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size)) == 0,
                  setsockopt(descriptor, IPPROTO_IP, IP_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size)) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { Darwin.close(descriptor); onFailure(); return }
            if host == "255.255.255.255" {
                guard var interface = Self.localInterfaceIndex(),
                      setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &interface, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
                    Darwin.close(descriptor); onFailure(); return
                }
            }
            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            local.sin_family = sa_family_t(AF_INET)
            let bound = withUnsafePointer(to: &local) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else { Darwin.close(descriptor); onFailure(); return }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            self.source = source
            source.setCancelHandler { Darwin.close(descriptor) }
            source.setEventHandler {
                for _ in 0..<32 {
                    var buffer = [UInt8](repeating: 0, count: 8_193)
                    let capacity = buffer.count
                    var sender = sockaddr_in()
                    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let count = withUnsafeMutablePointer(to: &sender) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.recvfrom(descriptor, &buffer, capacity, 0, $0, &length)
                        }
                    }
                    if count < 0 {
                        if errno != EAGAIN && errno != EWOULDBLOCK { onFailure() }
                        return
                    }
                    guard count > 0, count <= 8_192 else { continue }
                    var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    let hostCapacity = socklen_t(hostBuffer.count)
                    guard inet_ntop(AF_INET, &sender.sin_addr, &hostBuffer, hostCapacity) != nil else { continue }
                    onPacket(Data(buffer.prefix(count)), String(cString: hostBuffer))
                }
            }
            source.resume()
            let packet = Data("Who is JellyfinServer?".utf8)
            let sent = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent != packet.count { source.cancel(); self.source = nil; onFailure() }
        }
    }

    func cancel() { queue.async { [self] in cancelled = true; source?.cancel(); source = nil } }
    deinit { source?.cancel() }

    private static func localInterfaceIndex() -> UInt32? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var current = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            let value = interface.pointee
            guard let address = value.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  value.ifa_flags & UInt32(IFF_UP | IFF_BROADCAST) == UInt32(IFF_UP | IFF_BROADCAST),
                  value.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0 else { continue }
            let name = String(cString: value.ifa_name)
            // en* covers Apple Wi-Fi and Ethernet interfaces; pdp_ip* cellular is excluded.
            guard name.hasPrefix("en") else { continue }
            let index = if_nametoindex(value.ifa_name)
            if index != 0 { return index }
        }
        return nil
    }
}
