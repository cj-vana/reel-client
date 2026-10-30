import XCTest
import AVKit
import SwiftUI
@testable import ReelTV

@MainActor final class TVEpisodePlaybackTests: XCTestCase {
    func testOwnedMetadataSurvivesCancelledCallerAndCloseFencesResult() async throws {
        guard ProcessInfo.processInfo.environment["REEL_TV_EPISODE_JOURNEYS"] == "1" else { throw XCTSkip("Owned episode fixture is required.") }
        try TVFixtureOwnership.requireHost(allowedBundles: ["app.reelclient.tv.qa"])
        let suite = "TVMetadata-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var loadedOwner: TVCoordinator?
        var loadedStore: TVEpisodePlayback?
        try await episodeControls(["slowAdjacent": true])
        do {
            let session = Session(storage: TVEpisodeMemoryVault(), defaults: defaults)
            try await session.accept(Account(server: URL(string: "http://127.0.0.1:18967")!, token: "fixture-tv-metadata", userID: "tv-metadata", name: "QA", serverName: "Silent fixture"))
            let owner = TVCoordinator(session: session), api = try XCTUnwrap(session.api)
            loadedOwner = owner
            owner.playback.player.isMuted = true
            await owner.play(try await api.item("episode-1-1"), fromBeginning: true)
            owner.startPlayback(id: owner.presentationID)
            let store = TVEpisodePlayback(defaults: defaults)
            loadedStore = store
            let load = Task { await store.load(owner: owner, presentation: owner.presentationID) }
            for _ in 0..<30 { if store.neighborsLoading { break }; try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertTrue(store.neighborsLoading)
            load.cancel()
            await load.value
            XCTAssertEqual(store.next?.id, "episode-1-2", "AVKit presentation cancelling a SwiftUI caller must not cancel the owned metadata request")
            let replacement = Task { await store.load(owner: owner, presentation: owner.presentationID) }
            for _ in 0..<30 { if store.neighborsLoading { break }; try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertTrue(store.neighborsLoading)
            store.invalidate()
            await replacement.value
            await owner.closePlayback()
            XCTAssertNil(store.next, "A cancelled presentation must not publish a late metadata result")
        } catch {
            loadedStore?.invalidate()
            await loadedOwner?.closePlayback()
            try? await episodeControls(["slowAdjacent": false])
            throw error
        }
        try await episodeControls(["slowAdjacent": false])
    }

    private func episodeControls(_ body: [String: Bool]) async throws {
        var request = try await TVFixtureOwnership.request(URL(string: "http://127.0.0.1:18967/qa/tv-control")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testOwnedFixtureServerIntroNoneAndAutoUseActualNativeTimeline() async throws {
        guard ProcessInfo.processInfo.environment["REEL_TV_EPISODE_JOURNEYS"] == "1" else { throw XCTSkip("Owned episode fixture is required.") }
        try TVFixtureOwnership.requireHost(allowedBundles: ["app.reelclient.tv.qa"])
        for mode in [ServerSegmentMode.none, .auto] {
            let suite = "TVEpisodePreferences-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let session = Session(storage: TVEpisodeMemoryVault(), defaults: defaults)
            let user = "tv-intro-" + mode.rawValue
            let account = Account(server: URL(string: "http://127.0.0.1:18967")!, token: "fixture-" + user, userID: user, name: "QA", serverName: "Silent fixture")
            try await session.accept(account)
            let owner = TVCoordinator(session: session), api = try XCTUnwrap(session.api)
            owner.playback.player.isMuted = true
            owner.preferences.setEnabled(true, accountID: account.id)
            defer { owner.preferences.clear(accountID: account.id) }
            await owner.preferences.activate(accountID: account.id, api: api)
            XCTAssertEqual(owner.preferences.segmentMode("Intro"), mode)
            await owner.play(try await api.item("episode-1-1"), fromBeginning: true)
            owner.startPlayback(id: owner.presentationID)
            let store = TVEpisodePlayback(defaults: defaults)
            await store.load(owner: owner, presentation: owner.presentationID)
            for _ in 0..<40 {
                if !owner.playback.preparing, mode == .none || owner.playback.player.currentTime().seconds >= 10 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNil(owner.playback.error)
            XCTAssertFalse(owner.playback.preparing)
            if mode == .none {
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertNil(store.intro)
                XCTAssertLessThan(owner.playback.player.currentTime().seconds, 5)
            } else {
                XCTAssertGreaterThanOrEqual(owner.playback.player.currentTime().seconds, 10)
                XCTAssertNil(store.intro)
            }
            store.invalidate()
            await owner.closePlayback()
        }
    }

    func testOwnedFixtureIntroAfterActualNativeReadiness() async throws {
        guard ProcessInfo.processInfo.environment["REEL_TV_EPISODE_JOURNEYS"] == "1" else { throw XCTSkip("Owned episode fixture is required.") }
        try TVFixtureOwnership.requireHost(allowedBundles: ["app.reelclient.tv.qa"])
        for episodeID in ["episode-1-1", "episode-2-3"] {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "TVEpisodeFixture-" + UUID().uuidString))
            let session = Session(storage: TVEpisodeMemoryVault(), defaults: defaults)
            try await session.accept(Account(server: URL(string: "http://127.0.0.1:18967")!, token: "fixture-tv-intro-unit", userID: "tv-intro-unit", name: "QA", serverName: "Silent fixture"))
            let owner = TVCoordinator(session: session)
            owner.playback.player.isMuted = true
            let api = try XCTUnwrap(session.api)
            await owner.play(try await api.item(episodeID), fromBeginning: true)
            owner.startPlayback(id: owner.presentationID)
            let store = TVEpisodePlayback(defaults: defaults)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let prior = scene.windows.first(where: { $0.isKeyWindow }), window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: TVNativePlayer(coordinator: owner, presentationID: owner.presentationID, episodes: store))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; prior?.makeKeyAndVisible() }
            await store.load(owner: owner, presentation: owner.presentationID)
            for _ in 0..<100 {
                if store.intro != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNil(owner.playback.error)
            XCTAssertFalse(owner.playback.preparing)
            XCTAssertEqual(store.intro?.id, "intro", "duration=\(owner.playback.player.currentItem?.duration.seconds ?? .nan), time=\(owner.playback.player.currentTime().seconds), ended=\(owner.playback.ended)")
            var player: AVPlayerViewController?
            func find(_ controller: UIViewController) -> AVPlayerViewController? {
                if let player = controller as? AVPlayerViewController { return player }
                if let presented = controller.presentedViewController, let found = find(presented) { return found }
                return controller.children.compactMap(find).first
            }
            for _ in 0..<50 {
                player = find(host)
                if player?.contextualActions.first?.title == "Skip intro" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(player?.contextualActions.first?.title, "Skip intro")
            let previous = try XCTUnwrap(player?.transportBarCustomMenuItems.first(where: { $0.title == "Previous episode" }) as? UIAction)
            let next = try XCTUnwrap(player?.transportBarCustomMenuItems.first(where: { $0.title == "Next episode" }) as? UIAction)
            XCTAssertEqual(previous.attributes.contains(.disabled), episodeID == "episode-1-1")
            XCTAssertEqual(next.attributes.contains(.disabled), episodeID == "episode-2-3")
            store.invalidate()
            await owner.closePlayback()
        }
    }

    private func episode(_ id: String, series: String = "series") -> MediaItem {
        var item = MediaItem(Id: id, Name: id)
        item.Type = "Episode"; item.SeriesId = series
        return item
    }

    func testAdjacentEpisodesKeepServerOrderAcrossSeasonBoundary() {
        let previous = episode("s1e3"), current = episode("s2e1"), next = episode("s2e2")
        let result = TVEpisodeSequence.neighbors(of: current, in: [previous, current, next])
        XCTAssertEqual(result.previous?.id, previous.id)
        XCTAssertEqual(result.next?.id, next.id)
    }

    func testFirstFinalAndMissingEpisodeDoNotInventNeighbors() {
        let first = episode("first"), last = episode("last")
        XCTAssertNil(TVEpisodeSequence.neighbors(of: first, in: [first, last]).previous)
        XCTAssertNil(TVEpisodeSequence.neighbors(of: last, in: [first, last]).next)
        let absent = TVEpisodeSequence.neighbors(of: episode("missing"), in: [first, last])
        XCTAssertNil(absent.previous); XCTAssertNil(absent.next)
        let duplicate = TVEpisodeSequence.neighbors(of: first, in: [first, last, first])
        XCTAssertNil(duplicate.previous); XCTAssertNil(duplicate.next)
    }

    func testMalformedSeriesAndNonEpisodeNeighborsAreRejected() {
        let current = episode("current"), wrongSeries = episode("wrong", series: "other")
        var movie = episode("movie"); movie.Type = "Movie"
        let result = TVEpisodeSequence.neighbors(of: current, in: [wrongSeries, current, movie])
        XCTAssertNil(result.previous); XCTAssertNil(result.next)
        XCTAssertNil(TVEpisodeSequence.neighbors(of: movie, in: [movie, current]).next)
    }

    func testIntroRequiresRealValidSegmentAndCurrentInterval() {
        let intro = MediaSegment(Id: "intro", Type: "Intro", StartTicks: 20_000_000, EndTicks: 60_000_000)
        XCTAssertNil(TVEpisodeSequence.intro(in: [], seconds: 3, duration: 20))
        XCTAssertNil(TVEpisodeSequence.intro(in: [intro], seconds: 1, duration: 20))
        XCTAssertEqual(TVEpisodeSequence.intro(in: [intro], seconds: 2, duration: 20)?.id, "intro")
        XCTAssertNil(TVEpisodeSequence.intro(in: [intro], seconds: 6, duration: 20))
        XCTAssertNil(TVEpisodeSequence.intro(in: [intro], seconds: 3, duration: 5))
        XCTAssertNil(TVEpisodeSequence.intro(in: [intro], seconds: .nan, duration: 20))
        XCTAssertNil(TVEpisodeSequence.intro(in: [intro], seconds: 3, duration: .infinity))
        for segment in [MediaSegment(Id: "bad", Type: "Intro", StartTicks: -1, EndTicks: 6),
                        MediaSegment(Id: "bad", Type: "Intro", StartTicks: 6, EndTicks: 6),
                        MediaSegment(Id: "recap", Type: "Recap", StartTicks: 0, EndTicks: 60_000_000)] {
            XCTAssertNil(TVEpisodeSequence.intro(in: [segment], seconds: 3, duration: 20))
        }
    }

    func testCountdownStartsOnlyAtEligibleEOFAndFiresExactlyOnce() {
        let id = UUID(), now = Date(timeIntervalSince1970: 100)
        var countdown = TVNextEpisodeCountdown()
        XCTAssertFalse(countdown.update(endedID: nil, eligible: true, active: true, now: now))
        XCTAssertNil(countdown.remaining)
        XCTAssertFalse(countdown.update(endedID: id, eligible: false, active: true, now: now))
        XCTAssertNil(countdown.remaining)
        XCTAssertFalse(countdown.update(endedID: id, eligible: true, active: true, now: now))
        XCTAssertEqual(countdown.remaining, 10)
        XCTAssertFalse(countdown.update(endedID: id, eligible: true, active: true, now: now.addingTimeInterval(9)))
        XCTAssertEqual(countdown.remaining, 1)
        XCTAssertTrue(countdown.update(endedID: id, eligible: true, active: true, now: now.addingTimeInterval(10)))
        XCTAssertFalse(countdown.update(endedID: id, eligible: true, active: true, now: now.addingTimeInterval(30)))
    }

    func testCancelAppliesToExactEOFAndReplayGetsFreshCountdown() {
        let id = UUID(), now = Date(timeIntervalSince1970: 100)
        var countdown = TVNextEpisodeCountdown()
        _ = countdown.update(endedID: id, eligible: true, active: true, now: now)
        countdown.cancel()
        XCTAssertFalse(countdown.update(endedID: id, eligible: true, active: true, now: now.addingTimeInterval(20)))
        XCTAssertNil(countdown.remaining)
        XCTAssertFalse(countdown.update(endedID: UUID(), eligible: true, active: true, now: now.addingTimeInterval(20)))
        XCTAssertEqual(countdown.remaining, 10)
    }

    func testBackgroundOrBrowserRestartsFullCountdownWithoutImmediatePlayback() {
        let id = UUID(), now = Date(timeIntervalSince1970: 100)
        var countdown = TVNextEpisodeCountdown()
        _ = countdown.update(endedID: id, eligible: true, active: true, now: now)
        XCTAssertFalse(countdown.update(endedID: id, eligible: true, active: false, now: now.addingTimeInterval(9)))
        XCTAssertNil(countdown.remaining)
        XCTAssertFalse(countdown.update(endedID: id, eligible: true, active: true, now: now.addingTimeInterval(60)))
        XCTAssertEqual(countdown.remaining, 10)
        XCTAssertFalse(countdown.update(endedID: nil, eligible: true, active: true, now: now.addingTimeInterval(80)))
        XCTAssertNil(countdown.remaining)
    }

    func testAutoplayDefaultAndPreferenceSurviveStoreReplacement() throws {
        let suite = "TVEpisodePlaybackTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = TVEpisodePlayback(defaults: defaults)
        XCTAssertTrue(first.autoplay)
        first.autoplay = false
        XCTAssertFalse(TVEpisodePlayback(defaults: defaults).autoplay)
        first.autoplay = true
        XCTAssertTrue(TVEpisodePlayback(defaults: defaults).autoplay)
    }
}

@MainActor private final class TVEpisodeMemoryVault: AccountVaultStorage {
    private var value = AccountVault(accounts: [], activeID: nil)
    func read() throws -> AccountVault { value }
    func save(_ value: AccountVault) throws { self.value = value }
    func clear() throws { value = AccountVault(accounts: [], activeID: nil) }
}
