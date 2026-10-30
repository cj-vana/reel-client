import Foundation
import Network

enum PlaybackGatewayError: LocalizedError {
    case unsafeResource, invalidPlaylist, unavailable, invalidRequest

    var errorDescription: String? {
        switch self {
        case .unsafeResource: "This stream requests a resource outside your saved server address."
        case .invalidPlaylist: "This server returned an unsupported or invalid stream playlist."
        case .unavailable: "The private playback connection couldn’t be opened. Try playing again."
        case .invalidRequest: "The private playback request was invalid."
        }
    }
}

/// A per-play capability. Gateway credentials and Jellyfin URLs never enter AVPlayer's requests.
final class PlaybackGateway: Sendable {
    let localURL: URL
    private let engine: PlaybackGatewayEngine
    private let lifetime: PlaybackGatewayLifetime
    var isClosed: Bool { lifetime.isClosed }

    private init(localURL: URL, engine: PlaybackGatewayEngine, lifetime: PlaybackGatewayLifetime) {
        self.localURL = localURL; self.engine = engine; self.lifetime = lifetime
    }

    static func create(api: JellyfinAPI, sourceURL: URL) async throws -> PlaybackGateway {
        let lifetime = PlaybackGatewayLifetime()
        let engine = try PlaybackGatewayEngine(api: api, sourceURL: sourceURL, lifetime: lifetime)
        do {
            let localURL = try await engine.start()
            return PlaybackGateway(localURL: localURL, engine: engine, lifetime: lifetime)
        } catch { lifetime.cancel(); throw error }
    }

    /// Synchronous so replacing/stopping a player revokes its local capability immediately.
    func close() { lifetime.cancel() }
    deinit { lifetime.cancel() }
}

private enum PlaybackGatewayPolicy {
    static func permits(_ target: URL, server: URL) -> Bool {
        guard JellyfinAPI.sameOrigin(target, server), let parts = URLComponents(url: target, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.fragment == nil else { return false }
        // Reject ambiguous encodings before comparing the decoded path. Proxies differ in how
        // many times they decode these characters; none are needed in Jellyfin stream paths.
        let encoded = parts.percentEncodedPath.lowercased()
        guard !["%2f", "%5c", "%25", "%2e"].contains(where: encoded.contains),
              !parts.path.contains("\\"), !parts.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !parts.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { return false }
        let base = server.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = target.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return base.isEmpty || path == base || path.hasPrefix(base + "/")
    }
}

private final class PlaybackGatewayRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    let server: URL
    let headers: [String: String]
    init(server: URL, headers: [String: String]) { self.server = server; self.headers = headers }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let target = request.url, PlaybackGatewayPolicy.permits(target, server: server),
              ["GET", "HEAD"].contains(request.httpMethod ?? "GET") else { completionHandler(nil); return }
        var scoped = request
        for (name, value) in headers { scoped.setValue(value, forHTTPHeaderField: name) }
        scoped.httpShouldHandleCookies = false
        completionHandler(scoped)
    }
}

/// Network callbacks and player stop can run on different executors. This small lock protects
/// cancellation handles only; parsing, routing and credential handling stay in the engine actor.
private final class PlaybackGatewayLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var upstream: [UUID: URLSessionTask] = [:]
    var isClosed: Bool { lock.withLock { closed } }

    func setListener(_ value: NWListener) { if lock.withLock({ if closed { return false }; listener = value; return true }) == false { value.cancel() } }
    func add(_ value: NWConnection, id: UUID) -> Bool {
        lock.withLock { guard !closed, connections.count < 16 else { return false }; connections[id] = value; return true }
    }
    func add(_ value: Task<Void, Never>, id: UUID) { if lock.withLock({ if closed { return false }; workers[id] = value; return true }) == false { value.cancel() } }
    func add(_ value: URLSessionTask, id: UUID) { if lock.withLock({ if closed { return false }; upstream[id] = value; return true }) == false { value.cancel() } }
    func finish(_ id: UUID) {
        let values = lock.withLock { (connections.removeValue(forKey: id), upstream.removeValue(forKey: id), workers.removeValue(forKey: id)) }
        values.0?.cancel(); values.1?.cancel()
    }
    func cancel() {
        let values = lock.withLock { () -> (NWListener?, [NWConnection], [Task<Void, Never>], [URLSessionTask]) in
            closed = true
            let result = (listener, Array(connections.values), Array(workers.values), Array(upstream.values))
            listener = nil; connections.removeAll(); workers.removeAll(); upstream.removeAll()
            return result
        }
        values.0?.cancel(); values.1.forEach { $0.cancel() }; values.2.forEach { $0.cancel() }; values.3.forEach { $0.cancel() }
    }
}

private actor PlaybackGatewayEngine {
    private let api: JellyfinAPI
    private let sourceURL: URL
    private let lifetime: PlaybackGatewayLifetime
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.reelclient.ios.playbackRelay", qos: .userInitiated)
    private let capability = UUID().uuidString + UUID().uuidString
    private var port: UInt16 = 0
    private var resources: [String: URL] = [:]
    private var resourcePaths: [URL: String] = [:]
    private var startup: CheckedContinuation<URL, Error>?
    private var startupTimeout: Task<Void, Never>?
    private let playlistLimit = 1_048_576
    private let chunkSize = 65_536

    init(api: JellyfinAPI, sourceURL: URL, lifetime: PlaybackGatewayLifetime) throws {
        guard PlaybackGatewayPolicy.permits(sourceURL, server: api.server) else { throw PlaybackGatewayError.unsafeResource }
        self.api = api; self.sourceURL = sourceURL; self.lifetime = lifetime
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.includePeerToPeer = false
        listener = try NWListener(using: parameters)
        lifetime.setListener(listener)
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
                listener.stateUpdateHandler = { [weak self] state in Task { await self?.listenerState(state) } }
                listener.start(queue: queue)
                startupTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self?.failStartup()
                }
            }
        } onCancel: { lifetime.cancel() }
    }

    private func listenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard !lifetime.isClosed, let listenerPort = listener.port, startup != nil else { failStartup(); return }
            port = listenerPort.rawValue
            do { let url = try register(sourceURL); startup?.resume(returning: url); startup = nil; startupTimeout?.cancel() }
            catch { failStartup() }
        case .failed, .cancelled: failStartup()
        default: break
        }
    }

    private func failStartup() {
        if let startup { self.startup = nil; startup.resume(throwing: PlaybackGatewayError.unavailable); lifetime.cancel() }
        startupTimeout?.cancel(); startupTimeout = nil
    }

    private func register(_ upstream: URL) throws -> URL {
        guard !lifetime.isClosed, PlaybackGatewayPolicy.permits(upstream, server: api.server) else { throw PlaybackGatewayError.unsafeResource }
        if let path = resourcePaths[upstream] { return URL(string: "http://127.0.0.1:\(port)\(path)")! }
        guard resources.count < 16_384 else { throw PlaybackGatewayError.invalidPlaylist }
        let originalExtension = upstream.pathExtension.lowercased()
        let suffix = !originalExtension.isEmpty && originalExtension.count <= 8 && originalExtension.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) ? originalExtension : "media"
        let path = "/\(capability)/\(UUID().uuidString).\(suffix)"
        resources[path] = upstream; resourcePaths[upstream] = path
        return URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        guard case let .hostPort(host, _) = connection.endpoint, host.debugDescription == "127.0.0.1",
              lifetime.add(connection, id: id) else { connection.cancel(); return }
        connection.start(queue: queue)
        let worker = Task<Void, Never> { [weak self] in
            guard let self else { connection.cancel(); return }
            await self.handle(connection, id: id)
        }
        lifetime.add(worker, id: id)
    }

    private func handle(_ connection: NWConnection, id: UUID) async {
        defer { lifetime.finish(id) }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            connection.cancel()
        }
        do {
            let header = try await Self.readHeader(connection)
            deadline.cancel()
            let request = try GatewayRequest(header: header, port: port)
            guard !lifetime.isClosed, let resource = resources[request.path] else {
                try await Self.sendStatus(404, connection: connection); return
            }
            try await forward(resource, request: request, connection: connection, id: id)
        } catch {
            deadline.cancel()
            // A partial media response is closed rather than appending an HTTP error to it.
            connection.cancel()
        }
    }

    private static func readHeader(_ connection: NWConnection) async throws -> String {
        var data = Data()
        while data.count <= 16_384 {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { bytes, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                    else { continuation.resume(throwing: PlaybackGatewayError.invalidRequest) }
                }
            }
            data.append(chunk)
            if let end = data.range(of: Data("\r\n\r\n".utf8)) {
                guard data.count == end.upperBound, let header = String(data: data, encoding: .utf8) else { throw PlaybackGatewayError.invalidRequest }
                return header
            }
        }
        throw PlaybackGatewayError.invalidRequest
    }

    private func forward(_ resource: URL, request local: GatewayRequest, connection: NWConnection, id: UUID) async throws {
        var request = api.request("", method: local.method)
        request.url = resource
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let likelyPlaylist = ["m3u8", "m3u"].contains(resource.pathExtension.lowercased())
        if !likelyPlaylist, let range = local.range { request.setValue(range, forHTTPHeaderField: "Range") }
        try GatewayHeaderStore.apply(api.gatewayHeaders, to: &request, server: api.server)
        let redirects = PlaybackGatewayRedirects(server: api.server, headers: request.allHTTPHeaderFields ?? [:])
        let (bytes, response) = try await JellyfinAPI.transport.bytes(for: request, delegate: redirects)
        lifetime.add(bytes.task, id: id)
        defer { bytes.task.cancel() }
        guard !lifetime.isClosed, let response = response as? HTTPURLResponse, let finalURL = response.url,
              PlaybackGatewayPolicy.permits(finalURL, server: api.server) else { throw PlaybackGatewayError.unsafeResource }
        guard [200, 206].contains(response.statusCode) else {
            let status = [401, 403, 404, 416].contains(response.statusCode) ? response.statusCode : 502
            try await Self.sendHeaders(status: status, contentType: "application/octet-stream", length: 0,
                                       contentRange: status == 416 ? response.value(forHTTPHeaderField: "Content-Range") : nil,
                                       connection: connection)
            return
        }
        guard response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            try await Self.sendStatus(502, connection: connection); return
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        let playlistType = contentType.lowercased().contains("mpegurl")
        if local.method == "HEAD" {
            try await Self.sendHeaders(status: response.statusCode, contentType: contentType,
                                       length: likelyPlaylist || playlistType ? nil : response.expectedContentLength,
                                       contentRange: response.value(forHTTPHeaderField: "Content-Range"), chunked: false, connection: connection)
            return
        }
        var iterator = bytes.makeAsyncIterator()
        var prefix = Data()
        while prefix.count < 7, let byte = try await iterator.next() { prefix.append(byte) }
        let isPlaylist = likelyPlaylist || playlistType || prefix.starts(with: Data("#EXTM3U".utf8))
        if isPlaylist {
            var data = prefix
            while let byte = try await iterator.next() {
                guard data.count < playlistLimit else { throw PlaybackGatewayError.invalidPlaylist }
                data.append(byte)
            }
            do {
                let rewritten = try rewritePlaylist(data, baseURL: finalURL)
                try await Self.sendHeaders(status: 200, contentType: "application/vnd.apple.mpegurl", length: Int64(rewritten.count), connection: connection)
                try await Self.send(rewritten, connection: connection)
            } catch { try await Self.sendStatus(502, connection: connection) }
            return
        }
        let knownLength = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        try await Self.sendHeaders(status: response.statusCode, contentType: contentType, length: knownLength,
                                   contentRange: response.value(forHTTPHeaderField: "Content-Range"), chunked: knownLength == nil, connection: connection)
        var chunk = prefix
        var sent: Int64 = 0
        while let byte = try await iterator.next() {
            try Task.checkCancellation()
            chunk.append(byte)
            if chunk.count == chunkSize {
                // Pause upstream while the socket applies back pressure. No full media body is retained.
                bytes.task.suspend()
                try await Self.sendBody(chunk, chunked: knownLength == nil, connection: connection)
                bytes.task.resume()
                sent += Int64(chunk.count); chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { try await Self.sendBody(chunk, chunked: knownLength == nil, connection: connection); sent += Int64(chunk.count) }
        if let knownLength, sent != knownLength { throw PlaybackGatewayError.unavailable }
        if knownLength == nil { try await Self.send(Data("0\r\n\r\n".utf8), connection: connection) }
    }

    private func rewritePlaylist(_ data: Data, baseURL: URL) throws -> Data {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U"),
              !text.contains("{$"), !text.contains("#EXT-X-DEFINE:"), !text.contains("#EXT-X-CONTENT-STEERING:"),
              text.unicodeScalars.allSatisfy({ $0.value == 10 || $0.value == 13 || !CharacterSet.controlCharacters.contains($0) }) else { throw PlaybackGatewayError.invalidPlaylist }
        func replace(_ reference: String) throws -> String {
            guard !reference.isEmpty, let resolved = URL(string: reference, relativeTo: baseURL)?.absoluteURL else { throw PlaybackGatewayError.invalidPlaylist }
            return try register(resolved).absoluteString
        }
        var output: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { output.append(""); continue }
            if !line.hasPrefix("#") { output.append(try replace(line)); continue }
            if line.hasPrefix("#EXT-X-PREFETCH:") {
                output.append("#EXT-X-PREFETCH:" + (try replace(String(line.dropFirst("#EXT-X-PREFETCH:".count))))); continue
            }
            guard line.hasPrefix("#EXT"), let colon = line.firstIndex(of: ":"), line[colon...].contains("=") else { output.append(line); continue }
            var attributes: [String] = []
            var current = ""
            var quoted = false
            for character in line[line.index(after: colon)...] {
                if character == "\"" { quoted.toggle() }
                if character == ",", !quoted { attributes.append(current); current = "" }
                else { current.append(character) }
            }
            guard !quoted else { throw PlaybackGatewayError.invalidPlaylist }
            attributes.append(current)
            for index in attributes.indices {
                guard let equals = attributes[index].firstIndex(of: "=") else { continue }
                let name = attributes[index][..<equals].trimmingCharacters(in: .whitespaces).uppercased()
                if name.hasSuffix("URI") {
                    let value = attributes[index][attributes[index].index(after: equals)...].trimmingCharacters(in: .whitespaces)
                    guard value.count >= 2, value.first == "\"", value.last == "\"" else { throw PlaybackGatewayError.invalidPlaylist }
                    attributes[index] = String(attributes[index][...equals]) + "\"" + (try replace(String(value.dropFirst().dropLast()))) + "\""
                }
            }
            output.append(String(line[...colon]) + attributes.joined(separator: ","))
        }
        return Data(output.joined(separator: "\n").utf8)
    }

    private static func sendStatus(_ status: Int, connection: NWConnection) async throws {
        try await sendHeaders(status: status, contentType: "application/octet-stream", length: 0, connection: connection)
    }
    private static func sendHeaders(status: Int, contentType: String, length: Int64?, contentRange: String? = nil,
                                    chunked: Bool = false, connection: NWConnection) async throws {
        let type = contentType.utf8.count <= 200 && contentType.utf8.allSatisfy({ (32...126).contains($0) }) ? contentType : "application/octet-stream"
        var header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : status == 206 ? "Partial Content" : "Error")\r\nContent-Type: \(type)\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n"
        if let length, length >= 0 { header += "Content-Length: \(length)\r\n" }
        if chunked { header += "Transfer-Encoding: chunked\r\n" }
        if let contentRange, contentRange.range(of: "^bytes ([0-9]+-[0-9]+/[0-9]+|\\*/[0-9]+)$", options: .regularExpression) != nil {
            header += "Content-Range: \(contentRange)\r\nAccept-Ranges: bytes\r\n"
        }
        try await send(Data((header + "\r\n").utf8), connection: connection)
    }
    private static func sendBody(_ data: Data, chunked: Bool, connection: NWConnection) async throws {
        if chunked { try await send(Data((String(data.count, radix: 16) + "\r\n").utf8) + data + Data("\r\n".utf8), connection: connection) }
        else { try await send(data, connection: connection) }
    }
    private static func send(_ data: Data, connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

private struct GatewayRequest {
    let method: String
    let path: String
    let range: String?
    init(header: String, port: UInt16) throws {
        let lines = header.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])), ["HTTP/1.0", "HTTP/1.1"].contains(String(first[2])),
              first[1].hasPrefix("/"), first[1].utf8.count < 256, !first[1].contains("?"), !first[1].contains("%") else { throw PlaybackGatewayError.invalidRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), line.first != " ", line.first != "\t" else { throw PlaybackGatewayError.invalidRequest }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil, value.utf8.allSatisfy({ (32...126).contains($0) }) else { throw PlaybackGatewayError.invalidRequest }
            headers[name] = value
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["origin"] == nil,
              headers["transfer-encoding"] == nil, headers["content-length"].map({ $0 == "0" }) ?? true else { throw PlaybackGatewayError.invalidRequest }
        if let value = headers["range"] {
            guard value.range(of: "^bytes=([0-9]+-[0-9]*|-[0-9]+)$", options: .regularExpression) != nil, value.utf8.count <= 64 else { throw PlaybackGatewayError.invalidRequest }
        }
        method = String(first[0]); path = String(first[1]); range = headers["range"]
    }
}
