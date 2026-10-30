import XCTest
@testable import Reel

final class SeerrTests: XCTestCase {
    private var server: URL { URL(string: "http://127.0.0.1:18768")! }
    private func reset() async throws {
        let api = SeerrAPI(server: server)
        _ = try await api.send(api.request("qa/reset", method: "POST"))
    }
    func testDiscoveryPaginationSearchDetailsAndAPIKeyScope() async throws {
        let api = SeerrAPI(server: server, apiKey: "fixture-seerr")
        let user = try await api.currentUser()
        XCTAssertTrue(user.canRequest(.movie))
        let first = try await api.browse()
        XCTAssertEqual(first.results.map(\.id), [101, 201])
        let second = try await api.browse(page: 2)
        XCTAssertEqual(second.results.map(\.id), [102])
        let search = try await api.browse(query: "Far Horizons")
        XCTAssertEqual(search.results.first?.kind, .tv)
        let details = try await api.detail(id: 201, kind: .tv)
        XCTAssertEqual(details.kind, .tv)
        XCTAssertEqual(details.seasons?.count, 3)
        XCTAssertTrue(details.unavailableSeasons(is4k: false).contains(1))
        let request = SeerrAPI(server: URL(string: "https://seerr.example.com/base")!, apiKey: "test-secret").request("search", query: ["query": "a & b"])
        XCTAssertEqual(request.url?.path, "/base/api/v1/search")
        XCTAssertFalse(request.url!.absoluteString.contains("test-secret"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "test-secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(SeerrTitle.posterURL("https://untrusted.example/a.jpg"))
        XCTAssertNil(SeerrTitle.posterURL("//untrusted.example/a.jpg"))
        XCTAssertEqual(SeerrTitle.posterURL("/poster.jpg")?.host, "image.tmdb.org")
    }
    func testJellyfinSessionMovieSeasonRequestStatusAndCancellation() async throws {
        try await reset()
        let connection = try await SeerrAPI(server: server).jellyfinLogin(username: "viewer", password: "demo")
        XCTAssertNil(connection.apiKey)
        XCTAssertEqual(connection.sessionCookie, "connect.sid=fixture-viewer")
        let api = SeerrAPI(connection: connection)
        let movie = try await api.detail(id: 101, kind: .movie)
        let request = try await api.create(title: movie, kind: .movie, seasons: [], is4k: false, user: connection.user)
        XCTAssertEqual(request.status, 1)
        XCTAssertTrue(connection.user.canCancel(request))
        let status = try await api.detail(id: 101, kind: .movie)
        XCTAssertEqual(status.mediaInfo?.requests?.first?.id, request.id)
        let rows = try await api.myRequests(userID: connection.user.id)
        XCTAssertEqual(rows.results.first?.id, request.id)
        try await api.cancel(request, user: connection.user)
        let cleared = try await api.myRequests(userID: connection.user.id)
        XCTAssertTrue(cleared.results.isEmpty)
        let series = try await api.detail(id: 201, kind: .tv)
        let seasons = try await api.create(title: series, kind: .tv, seasons: [3, 2], is4k: false, user: connection.user)
        XCTAssertEqual(seasons.seasons?.map(\.seasonNumber), [2, 3])
        let updated = try await api.detail(id: 201, kind: .tv)
        XCTAssertEqual(updated.unavailableSeasons(is4k: false), Set([1, 2, 3]))
        do { _ = try await api.create(title: series, kind: .tv, seasons: [2], is4k: false, user: connection.user); XCTFail("Duplicate request accepted") }
        catch { XCTAssertEqual(error as? SeerrError, .duplicate) }
        try await api.cancel(seasons, user: connection.user)
    }
    func testPermissionQuotaInvalidCredentialsAndSelectionRecovery() async throws {
        let restricted = try await SeerrAPI(server: server).jellyfinLogin(username: "restricted", password: "demo")
        let api = SeerrAPI(connection: restricted)
        let title = try await api.detail(id: 101, kind: .movie)
        XCTAssertFalse(restricted.user.canRequest(.movie))
        do { _ = try await api.create(title: title, kind: .movie, seasons: [], is4k: false, user: restricted.user); XCTFail("Permission ignored") }
        catch { XCTAssertEqual(error as? SeerrError, .permission) }
        let quota = try await SeerrAPI(server: server).jellyfinLogin(username: "quota", password: "demo")
        do { _ = try await SeerrAPI(connection: quota).create(title: title, kind: .movie, seasons: [], is4k: false, user: quota.user); XCTFail("Quota ignored") }
        catch { XCTAssertEqual(error as? SeerrError, .permission) }
        do { _ = try await SeerrAPI(server: server).jellyfinLogin(username: "viewer", password: "wrong"); XCTFail("Bad credentials accepted") }
        catch { XCTAssertEqual(error as? SeerrError, .signIn) }
        let viewer = SeerrUser(id: 2, permissions: 32)
        do { _ = try await api.create(title: title, kind: .tv, seasons: [], is4k: false, user: viewer); XCTFail("Empty seasons accepted") }
        catch { XCTAssertEqual(error as? SeerrError, .invalidSelection) }
        let stranger = SeerrUser(id: 20, permissions: 32)
        XCTAssertFalse(stranger.canCancel(SeerrRequest(id: 1, status: 1, requestedBy: viewer)))
        XCTAssertFalse(viewer.canCancel(SeerrRequest(id: 1, status: 2, requestedBy: viewer)))
    }
    func testSimulatorRejectsRealSeerrWritesBeforeNetworking() async throws {
        let api = SeerrAPI(server: URL(string: "http://192.0.2.10:5055")!, apiKey: "test-not-a-real-key")
        XCTAssertTrue(api.isSimulatorPreview)
        for path in ["auth/jellyfin", "request", "request/1"] {
            for method in ["POST", "PUT", "DELETE"] {
                do { _ = try await api.send(api.request(path, method: method)); XCTFail("Real Seerr mutation reached transport") }
                catch { XCTAssertEqual(error as? SeerrError, .previewProtected) }
            }
        }
    }
    func testSeerrConnectionsPersistIndependentlyInKeychain() throws {
        let account = "seerr-unit-" + UUID().uuidString
        let other = "seerr-unit-" + UUID().uuidString
        defer { try? SeerrSecureStore.remove(accountID: account); try? SeerrSecureStore.remove(accountID: other) }
        let user = SeerrUser(id: 2, username: "Test", permissions: 32)
        let first = SeerrConnection(server: server, apiKey: "fixture-test-key", sessionCookie: nil, user: user)
        let second = SeerrConnection(server: URL(string: "http://127.0.0.1:18769")!, apiKey: nil, sessionCookie: "connect.sid=fixture-viewer", user: user)
        try SeerrSecureStore.save(first, accountID: account)
        try SeerrSecureStore.save(second, accountID: other)
        XCTAssertEqual(try SeerrSecureStore.read(accountID: account), first)
        XCTAssertEqual(try SeerrSecureStore.read(accountID: other), second)
        try SeerrSecureStore.remove(accountID: account)
        XCTAssertNil(try SeerrSecureStore.read(accountID: account))
        XCTAssertEqual(try SeerrSecureStore.read(accountID: other), second)
    }
}
