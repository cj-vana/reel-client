import XCTest
import Network
@testable import Reel

@MainActor final class PlaybackGatewayTests: XCTestCase {
    private func makeAPI(_ fixture: GatewayHTTPFixture) async throws -> JellyfinAPI {
        let server = await fixture.url("/jellyfin")
        try GatewayHeaderStore.save([GatewayHeader(name: "X-Reel-Gateway", value: "fixture-gateway-secret")], for: server)
        return JellyfinAPI(server: server, token: "fixture-jellyfin-token", userID: "fixture-user", deviceID: "gateway-tests")
    }

    private func cleanup(_ fixture: GatewayHTTPFixture, api: JellyfinAPI) async {
        try? GatewayHeaderStore.remove(for: api.server)
        await fixture.close()
    }

    private func fetch(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method; request.timeoutInterval = 5
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private func playlistURLs(_ data: Data) throws -> [URL] {
        let text = String(decoding: data, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #"http://127\.0\.0\.1:[0-9]+/[^\s\",]+"#)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).flatMap { URL(string: String(text[$0])) }
        }
    }

    func testHLSRewritesEveryResourceAndKeepsCredentialsUpstream() async throws {
        let fixture = try await GatewayHTTPFixture.create()
        let api = try await makeAPI(fixture)
        await fixture.set("/jellyfin/master.m3u8", body: Data("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English, stereo",URI="audio.m3u8?ApiKey=upstream-only-token"
        #EXT-X-SESSION-KEY:METHOD=AES-128,URI="key.bin"
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1000,URI="iframe.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000,AUDIO="audio"
        video.m3u8?ApiKey=upstream-only-token
        """.utf8), type: "application/vnd.apple.mpegurl")
        await fixture.set("/jellyfin/video.m3u8", body: Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4,
        segment.ts?ApiKey=upstream-only-token
        #EXT-X-ENDLIST
        """.utf8), type: "application/vnd.apple.mpegurl")
        for name in ["audio", "iframe"] {
            await fixture.set("/jellyfin/\(name).m3u8", body: Data("#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8), type: "application/vnd.apple.mpegurl")
        }
        for name in ["key.bin", "init.mp4", "segment.ts"] { await fixture.set("/jellyfin/\(name)", body: Data(repeating: 71, count: 512)) }
        let upstream = await fixture.url("/jellyfin/master.m3u8?ApiKey=upstream-only-token")
        let lease = try await PlaybackGateway.create(api: api, sourceURL: upstream)
        defer { lease.close() }
        XCTAssertEqual(lease.localURL.host, "127.0.0.1")
        XCTAssertNil(lease.localURL.query)
        XCTAssertFalse(lease.localURL.absoluteString.contains("token"))
        var todo = [lease.localURL]
        var visited: Set<URL> = []
        while let resource = todo.popLast() {
            if !visited.insert(resource).inserted { continue }
            XCTAssertLessThan(visited.count, 20)
            let (data, response) = try await fetch(resource)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertNil(response.value(forHTTPHeaderField: "Set-Cookie"))
            if data.starts(with: Data("#EXTM3U".utf8)) {
                let text = String(decoding: data, as: UTF8.self)
                XCTAssertFalse(text.contains("upstream-only-token"))
                XCTAssertFalse(text.contains("fixture-gateway-secret"))
                XCTAssertFalse(text.contains(api.server.absoluteString))
                todo.append(contentsOf: try playlistURLs(data))
            }
        }
        let receipts = await fixture.receipts
        XCTAssertTrue(Set(receipts.map(\.path)).isSuperset(of: ["/jellyfin/key.bin", "/jellyfin/init.mp4", "/jellyfin/segment.ts", "/jellyfin/audio.m3u8", "/jellyfin/iframe.m3u8"]))
        for receipt in receipts {
            XCTAssertEqual(receipt.headers["x-reel-gateway"], "fixture-gateway-secret")
            XCTAssertTrue(receipt.headers["authorization"]?.contains("fixture-jellyfin-token") == true)
        }
        await cleanup(fixture, api: api)
    }

    func testForeignAndOutOfBasePlaylistResourcesFailBeforeAnyFetch() async throws {
        let fixture = try await GatewayHTTPFixture.create()
        let foreign = try await GatewayHTTPFixture.create()
        let api = try await makeAPI(fixture)
        let foreignURL = await foreign.url("/capture")
        let cases = [
            "#EXTM3U\n\(foreignURL.absoluteString)\n",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"\(foreignURL.absoluteString)\"\n",
            "#EXTM3U\n#EXT-X-MAP:URI=\"/outside/init.mp4\"\n",
            "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI=\"../outside/audio.m3u8\"\n",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"%2e%2e/outside/key.bin\"\n",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=key.bin\n",
            "#EXTM3U\n#EXT-X-CONTENT-STEERING:SERVER-URI=\"steering.json\"\n",
            "#EXTM3U\n#EXT-X-DEFINE:NAME=\"host\",VALUE=\"https://foreign.example\"\n{$host}/segment.ts\n"
        ]
        for (index, playlist) in cases.enumerated() {
            let path = "/jellyfin/bad-\(index).m3u8"
            await fixture.set(path, body: Data(playlist.utf8), type: "application/vnd.apple.mpegurl")
            let upstream = await fixture.url(path)
            let lease = try await PlaybackGateway.create(api: api, sourceURL: upstream)
            let (data, response) = try await fetch(lease.localURL)
            XCTAssertEqual(response.statusCode, 502, "case \(index)")
            XCTAssertTrue(data.isEmpty)
            lease.close()
        }
        let foreignReceipts = await foreign.receipts
        XCTAssertTrue(foreignReceipts.isEmpty)
        let receipts = await fixture.receipts
        XCTAssertTrue(receipts.allSatisfy { $0.path.hasPrefix("/jellyfin/bad-") })
        do {
            _ = try await PlaybackGateway.create(api: api, sourceURL: foreignURL)
            XCTFail("Foreign source accepted")
        } catch { XCTAssertTrue(error is PlaybackGatewayError) }
        await foreign.close()
        await cleanup(fixture, api: api)
    }

    func testRedirectsKeepTheExactOriginAndBasePathBoundary() async throws {
        let fixture = try await GatewayHTTPFixture.create()
        let foreign = try await GatewayHTTPFixture.create()
        let api = try await makeAPI(fixture)
        await fixture.set("/jellyfin/foreign", status: 302, headers: ["Location": (await foreign.url("/capture")).absoluteString])
        await fixture.set("/jellyfin/outside", status: 302, headers: ["Location": "/outside/capture"])
        await fixture.set("/jellyfin/allowed", status: 302, headers: ["Location": "/jellyfin/segment.ts"])
        await fixture.set("/jellyfin/segment.ts", body: Data("stream-data".utf8))
        for path in ["foreign", "outside"] {
            let lease = try await PlaybackGateway.create(api: api, sourceURL: await fixture.url("/jellyfin/\(path)"))
            let (_, response) = try await fetch(lease.localURL)
            XCTAssertEqual(response.statusCode, 502)
            lease.close()
        }
        let lease = try await PlaybackGateway.create(api: api, sourceURL: await fixture.url("/jellyfin/allowed"))
        let (data, response) = try await fetch(lease.localURL)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "stream-data")
        lease.close()
        let receipts = await fixture.receipts
        XCTAssertFalse(receipts.contains { $0.path == "/outside/capture" })
        XCTAssertEqual(receipts.last?.headers["x-reel-gateway"], "fixture-gateway-secret")
        let foreignReceipts = await foreign.receipts
        XCTAssertTrue(foreignReceipts.isEmpty)
        await foreign.close()
        await cleanup(fixture, api: api)
    }

    func testDirectMediaSupportsFullBodyRangeAndHead() async throws {
        let fixture = try await GatewayHTTPFixture.create()
        let api = try await makeAPI(fixture)
        let media = Data((0..<(2 * 1_024 * 1_024)).map { UInt8($0 % 251) })
        await fixture.set("/jellyfin/movie.mp4", body: media, type: "video/mp4")
        let lease = try await PlaybackGateway.create(api: api, sourceURL: await fixture.url("/jellyfin/movie.mp4"))
        defer { lease.close() }
        let (whole, fullResponse) = try await fetch(lease.localURL)
        XCTAssertEqual(fullResponse.statusCode, 200)
        XCTAssertEqual(whole, media)
        let (part, partResponse) = try await fetch(lease.localURL, range: "bytes=7-1030")
        XCTAssertEqual(partResponse.statusCode, 206)
        XCTAssertEqual(part, media.subdata(in: 7..<1031))
        XCTAssertEqual(partResponse.value(forHTTPHeaderField: "Content-Range"), "bytes 7-1030/\(media.count)")
        let (head, headResponse) = try await fetch(lease.localURL, method: "HEAD")
        XCTAssertTrue(head.isEmpty)
        XCTAssertEqual(headResponse.expectedContentLength, Int64(media.count))
        let (suffix, suffixResponse) = try await fetch(lease.localURL, range: "bytes=-1000")
        XCTAssertEqual(suffixResponse.statusCode, 206)
        XCTAssertEqual(suffix, media.suffix(1000))
        let (tail, tailResponse) = try await fetch(lease.localURL, range: "bytes=2097000-")
        XCTAssertEqual(tailResponse.statusCode, 206)
        XCTAssertEqual(tail, media.subdata(in: 2097000..<media.count))
        let (_, unsatisfiable) = try await fetch(lease.localURL, range: "bytes=9999999-")
        XCTAssertEqual(unsatisfiable.statusCode, 416)
        XCTAssertEqual(unsatisfiable.value(forHTTPHeaderField: "Content-Range"), "bytes */\(media.count)")
        await cleanup(fixture, api: api)
    }

    func testUnknownCapabilitiesAndMutationRequestsNeverReachUpstream() async throws {
        let fixture = try await GatewayHTTPFixture.create()
        let api = try await makeAPI(fixture)
        let lease = try await PlaybackGateway.create(api: api, sourceURL: await fixture.url("/jellyfin/movie.mp4"))
        defer { lease.close() }
        var unknown = URLComponents(url: lease.localURL, resolvingAgainstBaseURL: false)!
        unknown.path = "/unknown-capability/resource.mp4"
        let (_, missing) = try await fetch(unknown.url!)
        XCTAssertEqual(missing.statusCode, 404)
        for method in ["POST", "PUT", "DELETE", "CONNECT"] {
            _ = try? await fetch(lease.localURL, method: method)
        }
        var browser = URLRequest(url: lease.localURL)
        browser.timeoutInterval = 3
        browser.setValue("https://foreign.example", forHTTPHeaderField: "Origin")
        _ = try? await URLSession.shared.data(for: browser)
        let receipts = await fixture.receipts
        XCTAssertTrue(receipts.isEmpty)
        await cleanup(fixture, api: api)
    }

    func testCloseRevokesCapabilityAndCancelsAnActiveStream() async throws {
        let fixture = try await GatewayHTTPFixture.create()
        let api = try await makeAPI(fixture)
        await fixture.set("/jellyfin/slow.mp4", body: Data(repeating: 71, count: 1_024), type: "video/mp4", delay: .seconds(3))
        let lease = try await PlaybackGateway.create(api: api, sourceURL: await fixture.url("/jellyfin/slow.mp4"))
        let pending = Task { try await self.fetch(lease.localURL) }
        for _ in 0..<100 {
            if !(await fixture.receipts).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let receipts = await fixture.receipts
        XCTAssertFalse(receipts.isEmpty)
        lease.close()
        XCTAssertTrue(lease.isClosed)
        do { _ = try await pending.value; XCTFail("Closed stream completed") } catch { }
        do { _ = try await fetch(lease.localURL); XCTFail("Revoked capability reopened") } catch { }
        await cleanup(fixture, api: api)
    }
}

private actor GatewayHTTPFixture {
    struct Receipt: Sendable { let path: String; let headers: [String: String] }
    private struct Reply: Sendable {
        var status: Int
        var body: Data
        var type: String
        var headers: [String: String]
        var delay: Duration
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.reelclient.ios.gatewayFixture")
    private var port: UInt16 = 0
    private var ready: CheckedContinuation<Void, Error>?
    private var replies: [String: Reply] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private(set) var receipts: [Receipt] = []

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func create() async throws -> GatewayHTTPFixture {
        let fixture = try GatewayHTTPFixture()
        try await fixture.start()
        return fixture
    }
    private func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in Task { await self?.state(state) } }
            listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
            listener.start(queue: queue)
        }
    }
    private func state(_ state: NWListener.State) {
        if case .ready = state, let listenerPort = listener.port { port = listenerPort.rawValue; ready?.resume(); ready = nil }
        if case let .failed(error) = state { ready?.resume(throwing: error); ready = nil }
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func set(_ path: String, body: Data = Data(), type: String = "application/octet-stream", status: Int = 200,
             headers: [String: String] = [:], delay: Duration = .zero) {
        replies[path] = Reply(status: status, body: body, type: type, headers: headers, delay: delay)
    }
    func close() { listener.cancel(); connections.values.forEach { $0.cancel() }; connections.removeAll() }

    private func accept(_ connection: NWConnection) {
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        Task { [weak self] in await self?.handle(connection, id: id) }
    }

    private func handle(_ connection: NWConnection, id: UUID) async {
        defer { connection.cancel(); connections[id] = nil }
        do {
                var bytes = Data()
                while bytes.range(of: Data("\r\n\r\n".utf8)) == nil, bytes.count < 16_384 {
                    let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { data, _, _, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let data, !data.isEmpty { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: URLError(.badServerResponse)) }
                        }
                    }
                    bytes.append(chunk)
                }
                let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
                let start = (lines.first ?? "").split(separator: " ")
                guard start.count == 3 else { return }
                let target = String(start[1])
                let path = URLComponents(string: target)?.path ?? target
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let colon = line.firstIndex(of: ":") { headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
                }
                receipts.append(Receipt(path: path, headers: headers))
                var reply = replies[path] ?? Reply(status: 404, body: Data(), type: "application/octet-stream", headers: [:], delay: .zero)
                if let range = headers["range"], range.hasPrefix("bytes=") {
                    let values = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                    if values.count == 2 {
                        let lower = values[0].isEmpty ? max(0, reply.body.count - (Int(values[1]) ?? 0)) : Int(values[0]) ?? reply.body.count
                        let upper = min(Int(values[1]) ?? reply.body.count - 1, reply.body.count - 1)
                        let finalUpper = values[0].isEmpty ? reply.body.count - 1 : upper
                        if lower <= finalUpper, lower < reply.body.count {
                            reply.headers["Content-Range"] = "bytes \(lower)-\(finalUpper)/\(reply.body.count)"
                            reply.body = reply.body.subdata(in: lower..<(finalUpper + 1)); reply.status = 206
                        } else {
                            reply.headers["Content-Range"] = "bytes */\(reply.body.count)"
                            reply.body = Data(); reply.status = 416
                        }
                    }
                }
                var header = "HTTP/1.1 \(reply.status) Fixture\r\nContent-Length: \(reply.body.count)\r\nContent-Type: \(reply.type)\r\nConnection: close\r\nCache-Control: no-store\r\n"
                for (name, value) in reply.headers { header += "\(name): \(value)\r\n" }
                try await Self.send(Data((header + "\r\n").utf8), connection: connection)
                if reply.delay > .zero { try await Task.sleep(for: reply.delay) }
                if start[0] != "HEAD" { try await Self.send(reply.body, connection: connection) }
        } catch { }
    }
    private static func send(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
