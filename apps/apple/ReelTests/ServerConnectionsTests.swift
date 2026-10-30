import XCTest
import Network
@testable import Reel

final class ServerConnectionsTests: XCTestCase {
    func testGatewayHeadersRejectInjectionAndManagedHeaders() throws {
        for name in ["Authorization", "HOST", "Cookie", "X-Emby-Token", "Proxy-Authorization", "X-Forwarded-User", "Sec-Fetch-Site"] {
            XCTAssertThrowsError(try GatewayHeaderStore.validated([GatewayHeader(name: name, value: "fixture")]), name)
        }
        for header in [GatewayHeader(name: "X-Test\r\nCookie", value: "fixture"), GatewayHeader(name: "X-Test", value: "fixture\r\nHost: other"), GatewayHeader(name: "X Test", value: "fixture")] {
            XCTAssertThrowsError(try GatewayHeaderStore.validated([header]))
        }
        XCTAssertThrowsError(try GatewayHeaderStore.validated([GatewayHeader(name: "X-Test", value: "1"), GatewayHeader(name: "x-test", value: "2")]))
        XCTAssertEqual(try GatewayHeaderStore.validated([GatewayHeader()]), [])
    }

    func testGatewayHeadersStayAtExactOriginAndBasePath() throws {
        let server = URL(string: "https://media.example.com/jellyfin")!
        let rows = [GatewayHeader(name: "CF-Access-Client-Id", value: "fixture-client"), GatewayHeader(name: "CF-Access-Client-Secret", value: "fixture-secret")]
        var request = URLRequest(url: server.appendingPathComponent("Items"))
        request.setValue("MediaBrowser Token=\"fixture\"", forHTTPHeaderField: "Authorization")
        try GatewayHeaderStore.apply(rows, to: &request, server: server)
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "fixture-client")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "MediaBrowser Token=\"fixture\"")
        for destination in ["https://evil.example.com/jellyfin/Items", "http://media.example.com/jellyfin/Items", "https://media.example.com:8443/jellyfin/Items", "https://media.example.com/other/Items", "https://media.example.com/jellyfin/../other/Items", "https://media.example.com/jellyfin/%2e%2e/other/Items"] {
            var foreign = URLRequest(url: URL(string: destination)!)
            XCTAssertThrowsError(try GatewayHeaderStore.apply(rows, to: &foreign, server: server), destination)
            XCTAssertNil(foreign.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
        }
    }

    func testGatewayKeychainRoundTripIsolationAndRemoval() throws {
        let first = URL(string: "https://fixture-\(UUID().uuidString.lowercased()).example.com/jellyfin")!
        let second = URL(string: "https://fixture-\(UUID().uuidString.lowercased()).example.com/jellyfin")!
        defer { try? GatewayHeaderStore.remove(for: first); try? GatewayHeaderStore.remove(for: second) }
        let rows = [GatewayHeader(name: "X-Api-Key", value: "fixture-gateway-secret")]
        try GatewayHeaderStore.save(rows, for: first)
        XCTAssertEqual(try GatewayHeaderStore.read(for: first), rows)
        let updated = [GatewayHeader(name: "X-Api-Key", value: "fixture-updated-secret")]
        try GatewayHeaderStore.save(updated, for: first)
        XCTAssertEqual(try GatewayHeaderStore.read(for: first), updated, "Successful updates must replace the process cache.")
        XCTAssertTrue(try GatewayHeaderStore.read(for: second).isEmpty)
        try GatewayHeaderStore.remove(for: first)
        XCTAssertTrue(try GatewayHeaderStore.read(for: first).isEmpty)
        XCTAssertThrowsError(try GatewayHeaderStore.save(rows, for: URL(string: "http://192.0.2.10:8096")!))
    }

    func testDiscoveryRejectsMalformedOversizedAndRemoteAdvertisements() throws {
        let good = Data(#"{"Id":"fixture","Name":"Nearby server","Address":"http://192.168.1.20:8096/jellyfin/"}"#.utf8)
        let result = try DiscoveredServer.parse(good, responderHost: "192.168.1.20")
        XCTAssertEqual(result.address.absoluteString, "http://192.168.1.20:8096/jellyfin")
        for address in ["http://10.0.0.1.attacker.example", "https://public.example.com", "https://user:password@192.168.1.20", "http://192.168.1.20?ApiKey=fixture"] {
            let data = try JSONSerialization.data(withJSONObject: ["Id": "fixture", "Name": "Nearby", "Address": address])
            XCTAssertThrowsError(try DiscoveredServer.parse(data), address)
        }
        XCTAssertThrowsError(try DiscoveredServer.parse(good, responderHost: "8.8.8.8"))
        XCTAssertThrowsError(try DiscoveredServer.parse(Data(repeating: 32, count: 8193)))
    }

    func testQuickConnectFixtureApprovalAndOneTimeAuthentication() async throws {
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, deviceID: "connections-contract-tests")
        let request = try await api.initiateQuickConnect()
        XCTAssertFalse(request.Authenticated)
        let pending = try await api.quickConnectState(secret: request.Secret)
        XCTAssertFalse(pending.Authenticated)
        do { _ = try await api.authenticateQuickConnect(secret: request.Secret); XCTFail("Unapproved code signed in") }
        catch { XCTAssertEqual(error as? ReelError, .unauthorized) }
        try await api.post("qa/quick-connect/approve", body: ["code": request.Code])
        let approved = try await api.quickConnectState(secret: request.Secret)
        XCTAssertTrue(approved.Authenticated)
        let account = try await api.authenticateQuickConnect(secret: request.Secret)
        XCTAssertEqual(account.userID, "quickconnect")
        do { _ = try await api.quickConnectState(secret: request.Secret); XCTFail("Consumed secret remained active") }
        catch { XCTAssertEqual(error as? ServerConnectionError, .quickConnectExpired) }
    }

    @MainActor func testQuickConnectCancelStopsCompletionAndDiscardsCode() async throws {
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, deviceID: "connections-cancel-tests")
        let signIn = QuickConnectSignIn()
        var completed = false
        signIn.begin(api: api, pollInterval: .milliseconds(100)) { _ in completed = true }
        for _ in 0..<100 { if signIn.code != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let code = try XCTUnwrap(signIn.code)
        signIn.cancel()
        try await api.post("qa/quick-connect/approve", body: ["code": code])
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(completed)
        XCTAssertNil(signIn.code)
        XCTAssertEqual(signIn.status, .idle)
    }

    @MainActor func testDiscoveryLoopbackRepliesAndCancellation() async throws {
        let discovery = ServerDiscovery()
        discovery.start(destination: .hostPort(host: "127.0.0.1", port: 17359), duration: .seconds(2))
        for _ in 0..<100 { if !discovery.servers.isEmpty || discovery.status == .failed { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(discovery.servers.first?.serverID, "fixture-discovery")
        discovery.stop()
        let count = discovery.servers.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(discovery.servers.count, count)
        XCTAssertEqual(discovery.status, .idle)
    }

    @MainActor func testQuickConnectSaveFailureRevokesOnlyNewSession() async throws {
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, deviceID: "connections-cleanup-tests")
        func logoutCount() async throws -> Int {
            let data = try await api.send(api.request("qa/quick-connect/state"))
            let state = try JSONSerialization.jsonObject(with: data) as? [String: Int]
            return try XCTUnwrap(state?["LogoutCount"])
        }
        let before = try await logoutCount()
        let signIn = QuickConnectSignIn()
        signIn.begin(api: api, pollInterval: .milliseconds(20)) { _ in throw ReelError.storage }
        for _ in 0..<100 { if signIn.code != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let code = try XCTUnwrap(signIn.code)
        try await api.post("qa/quick-connect/approve", body: ["code": code])
        for _ in 0..<100 { if signIn.status == .failed { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(signIn.status, .failed)
        let afterNewSession = try await logoutCount()
        XCTAssertEqual(afterNewSession, before + 1)

        let existing = Account(server: api.server, token: "fixture-quickconnect", userID: "quickconnect", name: "Existing", serverName: "Fixture")
        signIn.begin(api: api, pollInterval: .milliseconds(20), protectedAccounts: [existing]) { _ in throw ReelError.storage }
        for _ in 0..<100 { if signIn.code != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let protectedCode = try XCTUnwrap(signIn.code)
        try await api.post("qa/quick-connect/approve", body: ["code": protectedCode])
        for _ in 0..<100 { if signIn.status == .failed { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(signIn.status, .failed)
        let afterExistingSession = try await logoutCount()
        XCTAssertEqual(afterExistingSession, afterNewSession, "A pre-existing saved token must never be revoked by failed sign-in cleanup.")
    }
}
