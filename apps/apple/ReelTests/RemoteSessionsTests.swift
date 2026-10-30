import AVFoundation
import XCTest
@testable import Reel

@MainActor final class RemoteSessionsTests: XCTestCase {
    private func fixtureAPI(_ user: String = "remote-unit") -> JellyfinAPI {
        JellyfinAPI(server: URL(string: "http://127.0.0.1:18769")!, token: "fixture-" + user, userID: user, deviceID: "remote-native-tests")
    }

    func testSocketAuthenticationUsesHeaderAndPreservesBasePath() throws {
        let api = JellyfinAPI(server: URL(string: "https://example.test/jellyfin")!, token: "private-test-token", userID: "user", deviceID: "phone")
        let request = try RemoteProtocol.socketRequest(api: api)
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.path, "/jellyfin/socket")
        XCTAssertFalse(request.url!.absoluteString.contains("private-test-token"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), api.authorization)
        XCTAssertThrowsError(try RemoteProtocol.component("../another-session"))
        XCTAssertThrowsError(try RemoteProtocol.component("session/command"))
    }

    func testOldRemoteCommandCompletionCannotRestorePreviousAccount() async throws {
        let oldAPI = fixtureAPI("remote-delayed-" + UUID().uuidString)
        let newAPI = fixtureAPI("remote-new-" + UUID().uuidString)
        let remote = RemoteSessions()
        await remote.refresh(api: oldAPI)
        let player = try XCTUnwrap(remote.sessions.first)
        let outgoing = Task { await remote.command("Pause", session: player, api: oldAPI) }
        try await Task.sleep(for: .milliseconds(80))
        remote.reset(api: newAPI)
        await remote.refresh(api: newAPI)
        await outgoing.value
        XCTAssertEqual(remote.sessions.first?.name, "New account player")
        XCTAssertNil(remote.notice)
        XCTAssertNil(remote.error)
    }

    func testClearingGroupQueueCancelsDelayedMediaPreparation() async throws {
        let playback = PlaybackController()
        let sync = SyncPlayClient()
        defer { sync.disconnect() }
        sync.configure(api: fixtureAPI("slow"), playback: playback)
        let joined = Data("""
        {"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"test","Type":"GroupJoined","Data":{"GroupId":"test","GroupName":"Race test","State":"Paused","Participants":[]}}}
        """.utf8)
        try await sync.receive(joined)
        let queued = Data("""
        {"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"test","Type":"PlayQueue","Data":{"LastUpdate":"2026-10-23T12:00:00Z","Playlist":[{"ItemId":"movie-1","PlaylistItemId":"entry-1"}],"PlayingItemIndex":0,"StartPositionTicks":0,"IsPlaying":false}}}
        """.utf8)
        try await sync.receive(queued)
        try await Task.sleep(for: .milliseconds(80))
        let cleared = Data("""
        {"MessageType":"SyncPlayGroupUpdate","Data":{"GroupId":"test","Type":"PlayQueue","Data":{"LastUpdate":"2026-10-23T12:00:01Z","Playlist":[],"PlayingItemIndex":-1,"StartPositionTicks":0,"IsPlaying":false}}}
        """.utf8)
        try await sync.receive(cleared)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(sync.currentEntry)
        XCTAssertTrue(sync.queue.isEmpty)
        XCTAssertNil(playback.activeItem)
    }

    func testCreatedGroupResponseCannotReplaceNewAccountsState() async throws {
        let oldAPI = fixtureAPI("group-delayed-" + UUID().uuidString)
        let newAPI = fixtureAPI("group-new-" + UUID().uuidString)
        let sync = SyncPlayClient()
        let playback = PlaybackController()
        defer { sync.disconnect() }
        sync.configure(api: oldAPI, playback: playback)
        await sync.refresh()
        let creating = Task { await sync.create(name: "Old account group") }
        var receivedCreate = false
        for _ in 0..<100 {
            let data = try await oldAPI.send(oldAPI.request("qa/remote-state"))
            let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let events = state["events"] as! [[String: Any]]
            if events.contains(where: { $0["user"] as? String == oldAPI.userID && $0["path"] as? String == "/SyncPlay/New" }) {
                receivedCreate = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(receivedCreate)
        sync.configure(api: newAPI, playback: playback)
        XCTAssertFalse(sync.busy)
        XCTAssertFalse(sync.loading)
        await creating.value
        XCTAssertNil(sync.group)
        XCTAssertNil(sync.currentEntry)
        XCTAssertFalse(sync.connected)
        XCTAssertNil(sync.error)
    }

    func testOldSyncPlayCommandFailureCannotReplaceNewAccountsError() async throws {
        let oldAPI = fixtureAPI("group-command-delayed-" + UUID().uuidString)
        let sync = SyncPlayClient()
        let playback = PlaybackController()
        defer { sync.detach() }
        sync.configure(api: oldAPI, playback: playback)
        await sync.refresh()
        await sync.create(name: "Command race")
        XCTAssertNotNil(sync.group)
        let command = Task { await sync.request("Pause") }
        try await Task.sleep(for: .milliseconds(80))
        sync.configure(api: fixtureAPI("group-command-new-" + UUID().uuidString), playback: playback)
        sync.error = "New account message"
        await command.value
        XCTAssertEqual(sync.error, "New account message")
        XCTAssertNil(sync.group)
    }

    func testDetachLeavesOnlyPreviousAccountMembership() async throws {
        let api = fixtureAPI("group-detach-" + UUID().uuidString)
        let sync = SyncPlayClient()
        let playback = PlaybackController()
        sync.configure(api: api, playback: playback)
        await sync.refresh()
        await sync.create(name: "Detach lifecycle")
        let accountID = api.server.absoluteString + "|" + (api.userID ?? "")
        XCTAssertTrue(sync.ownsAccount(accountID))
        XCTAssertFalse(sync.ownsAccount("another-account"))
        sync.detach()
        XCTAssertFalse(sync.ownsAccount(accountID))
        XCTAssertFalse(sync.connected)
        XCTAssertNil(sync.group)
        var left = false
        for _ in 0..<100 {
            let data = try await api.send(api.request("qa/remote-state"))
            let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let events = state["events"] as! [[String: Any]]
            if events.contains(where: { $0["user"] as? String == api.userID && $0["path"] as? String == "/SyncPlay/Leave" }) { left = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(left)
    }

    func testRealServerRemoteAndSyncPlayMutationsAreProtected() {
        let api = JellyfinAPI(server: URL(string: "http://192.0.2.10:8096")!, token: "non-secret-fixture", userID: "test", deviceID: "test")
        XCTAssertThrowsError(try RemoteProtocol.requireWritable(api)) { error in
            XCTAssertEqual(error as? ReelError, .previewProtected)
        }
    }

    func testSyncPlaySocketCarriesScopedGatewayHeaders() throws {
        let server = URL(string: "http://127.0.0.1:18769/gateway-socket-test")!
        try GatewayHeaderStore.save([GatewayHeader(name: "X-Test-Gateway", value: "fixture-only")], for: server)
        defer { try? GatewayHeaderStore.remove(for: server) }
        let api = JellyfinAPI(server: server, token: "fixture-socket", userID: "socket", deviceID: "socket-tests")
        let request = try RemoteProtocol.socketRequest(api: api)
        XCTAssertEqual(request.url?.scheme, "ws")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test-Gateway"), "fixture-only")
        XCTAssertFalse(request.url!.absoluteString.contains("fixture-only"))
    }

    func testClockOffsetAccountsForRoundTripAndServerProcessing() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        // Server is two seconds ahead; each network leg is 50 ms; it processes for 20 ms.
        let sample = try SyncPlayClockSample(sent: base, received: base.addingTimeInterval(0.12),
            requestReception: base.addingTimeInterval(2.05), responseTransmission: base.addingTimeInterval(2.07))
        XCTAssertEqual(sample.offset, 2, accuracy: 0.0001)
        XCTAssertEqual(sample.roundTrip, 0.1, accuracy: 0.0001)
        XCTAssertThrowsError(try SyncPlayClockSample(sent: base, received: base.addingTimeInterval(-1), requestReception: base, responseTransmission: base))
    }

    func testScheduledCommandEstimatesOnlyUnpausedTimeline() throws {
        let data = Data("""
        {"GroupId":"group","PlaylistItemId":"entry","When":"2026-10-23T12:00:00.000Z","PositionTicks":50000000,"Command":"Unpause","EmittedAt":"2026-10-23T11:59:59.900Z"}
        """.utf8)
        let command = try JSONDecoder().decode(SyncPlayServerCommand.self, from: data)
        let later = try XCTUnwrap(RemoteProtocol.date("2026-10-23T12:00:01.500Z"))
        XCTAssertEqual(try command.position(at: later), 65_000_000)
        let paused = SyncPlayServerCommand(GroupId: "group", PlaylistItemId: "entry", When: command.When,
            PositionTicks: 50_000_000, Command: "Pause", EmittedAt: command.EmittedAt)
        XCTAssertEqual(try paused.position(at: later), 50_000_000)
        XCTAssertEqual(try command.position(at: later.addingTimeInterval(-5)), 50_000_000)
    }

    func testRemoteCommandsUseSessionContractsAndReceiverCapabilities() async throws {
        let api = fixtureAPI("remote-" + UUID().uuidString)
        let controller = RemoteSessions()
        await controller.refresh(api: api)
        XCTAssertNil(controller.error)
        let receiver = try XCTUnwrap(controller.sessions.first)
        XCTAssertTrue(receiver.acceptsVideo)
        await controller.command("Pause", session: receiver, api: api)
        XCTAssertNil(controller.error)
        XCTAssertEqual(controller.sessions.first?.PlayState?.IsPaused, true)
        await controller.command("Seek", session: receiver, api: api, ticks: 90_000_000)
        XCTAssertEqual(controller.sessions.first?.PlayState?.PositionTicks, 90_000_000)
        let item = try await api.item("movie-2")
        await controller.play(item, on: receiver, mode: "PlayNext", api: api)
        XCTAssertNil(controller.error)
        await controller.command("Stop", session: receiver, api: api)
        XCTAssertNil(controller.sessions.first?.NowPlayingItem)
        await controller.play(item, on: receiver, mode: "PlayNow", api: api)
        XCTAssertNotNil(controller.sessions.first?.NowPlayingItem)
        let state = try await api.send(api.request("qa/remote-state"))
        let json = try JSONSerialization.jsonObject(with: state) as! [String: Any]
        let receipts = (json["events"] as! [[String: Any]]).filter { $0["user"] as? String == api.userID }
        XCTAssertTrue(receipts.contains { receipt in
            let query = receipt["query"] as? [String: Any]
            return receipt["path"] as? String == "/Sessions/qa-living-room/Playing" && query?["playCommand"] as? String == "PlayNext" && query?["itemIds"] as? String == "movie-2"
        })
        let forbidden = RemoteSessions()
        await forbidden.refresh(api: fixtureAPI("remote-denied"))
        XCTAssertNotNil(forbidden.error)
    }

    func testSyncPlayCreatesAndLeavesOverAuthenticatedWebSocket() async throws {
        let api = fixtureAPI("group-owner-" + UUID().uuidString)
        let playback = PlaybackController()
        let sync = SyncPlayClient()
        defer { sync.disconnect() }
        sync.configure(api: api, playback: playback)
        await sync.refresh()
        XCTAssertTrue(sync.canCreate)
        await sync.create(name: "Native group lifecycle")
        XCTAssertNil(sync.error)
        XCTAssertNotNil(sync.group)
        XCTAssertTrue(sync.connected)
        XCTAssertTrue(playback.syncPlayManaged)
        XCTAssertFalse(playback.player.allowsExternalPlayback)
        await sync.leave()
        XCTAssertNil(sync.group)
        XCTAssertFalse(sync.connected)
        XCTAssertFalse(playback.syncPlayManaged)
    }

    func testSyncPlayJoinReadyScheduleSeekPauseAndLeaveNativePlayer() async throws {
        let api = fixtureAPI("sync-native-" + UUID().uuidString)
        let playback = PlaybackController()
        let sync = SyncPlayClient()
        defer { sync.disconnect() }
        sync.configure(api: api, playback: playback)
        await sync.refresh()
        let group = try XCTUnwrap(sync.groups.first { $0.id == "fixture-group" })
        await sync.join(group)
        XCTAssertNil(sync.error)
        for _ in 0..<100 {
            if playback.activeItem != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(playback.activeItem)
        // In the app PlayerView starts the active item. Drive that same boundary here.
        playback.start(api: api, quality: .original)
        XCTAssertFalse(playback.player.allowsExternalPlayback, "Preparing group media must retain SyncPlay's receiver ownership.")
        for _ in 0..<200 {
            if playback.player.rate > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(sync.error)
        XCTAssertNil(playback.error)
        XCTAssertGreaterThan(playback.player.rate, 0)
        await sync.request("Pause")
        for _ in 0..<30 {
            if playback.player.rate == 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(playback.player.rate, 0)
        await sync.request("Seek", ticks: 80_000_000)
        for _ in 0..<50 {
            if playback.player.currentTime().seconds >= 7.8 && playback.player.rate > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThanOrEqual(playback.player.currentTime().seconds, 7.8)
        XCTAssertGreaterThan(playback.player.rate, 0)
        await sync.leave()
        XCTAssertNil(playback.activeItem)
        XCTAssertFalse(playback.syncPlayManaged)
        let state = try await api.send(api.request("qa/remote-state"))
        let json = try JSONSerialization.jsonObject(with: state) as! [String: Any]
        let paths = (json["events"] as! [[String: Any]]).filter { $0["user"] as? String == api.userID }.compactMap { $0["path"] as? String }
        XCTAssertTrue(paths.contains("/SyncPlay/Ready"))
        XCTAssertTrue(paths.contains("/SyncPlay/Seek"))
        XCTAssertTrue(paths.contains("/SyncPlay/Leave"))
    }
}
