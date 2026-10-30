import AVKit
import SwiftUI
import XCTest
@testable import ReelTV

@MainActor final class TVLifecycleTests: XCTestCase {
    private func account(_ user: String, port: Int = 18966) -> Account {
        Account(server: URL(string: "http://127.0.0.1:\(port)")!, token: "fixture-" + user, userID: user, name: "TV QA", serverName: "Reel Cinema")
    }

    private func withCoordinator(_ user: String, port: Int = 18966, perform: (TVCoordinator) async throws -> Void) async throws {
        try TVFixture.requireQAHost()
        guard [18966, 18969].contains(port) else { throw ReelError.previewProtected }
        if port == 18969 {
            for action in ["reset", "control"] {
                var request = try await TVFixture.request(URL(string: "http://127.0.0.1:18969/qa/" + action)!)
                request.httpMethod = "POST"
                request.httpBody = try JSONSerialization.data(withJSONObject: action == "reset" ? [:] : ["failReports": false, "failCleanup": false])
                let (_, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            }
        } else { try await TVFixture.reset() }
        let original = try SecureAccount.read()
        guard original.accounts.allSatisfy({ $0.server.host == "127.0.0.1" && [18966, 18967].contains($0.server.port) }) else {
            throw XCTSkip("The QA vault contains accounts outside the owned fixture; preserve it untouched.")
        }
        let previousPrivacy = UserDefaults.standard.object(forKey: "privateViewing")
        let previousQuality = UserDefaults.standard.object(forKey: "streamQuality")
        defer {
            for (key, value) in [("privateViewing", previousPrivacy), ("streamQuality", previousQuality)] {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let coordinator = TVCoordinator()
        coordinator.session.privateViewing = false
        coordinator.quality = .original
        do {
            try await coordinator.session.accept(account(user, port: port))
            await coordinator.activated()
            try await perform(coordinator)
            await coordinator.closePlayback()
            try SecureAccount.save(original)
        } catch {
            await coordinator.closePlayback()
            try SecureAccount.save(original)
            throw error
        }
    }

    private func ready(_ coordinator: TVCoordinator) async throws {
        for _ in 0..<150 {
            if !coordinator.playback.preparing, !coordinator.playback.resolvingReplacement { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(coordinator.playback.error)
        XCTAssertEqual(coordinator.playback.player.currentItem?.status, .readyToPlay)
    }

    func testHostedNativeInfoPublishesActualAudioChangeWithoutQualityOrSubtitleMutation() async throws {
        try await withCoordinator("tv-multiaudio", port: 18969) { coordinator in
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let prior = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: TVRootView().environment(coordinator).environment(coordinator.session).environment(coordinator.playback).environment(coordinator.preferences))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; prior?.makeKeyAndVisible() }
            let api = try XCTUnwrap(coordinator.session.api)
            await coordinator.play(try await api.item("movie-1"), sourceID: "movie-1-multiaudio", audio: 1, subtitle: -1)
            try await self.ready(coordinator)
            let native = try await self.presentedPlayer(from: host), item = try XCTUnwrap(coordinator.playback.player.currentItem)
            let loaded = try await item.asset.loadMediaSelectionGroup(for: .audible), group = try XCTUnwrap(loaded)
            let matches = group.options.filter { $0.extendedLanguageTag?.hasPrefix("es") == true }
            XCTAssertEqual(matches.count, 1)
            item.select(try XCTUnwrap(matches.first), in: group)
            let expected = try XCTUnwrap(PlaybackAudioSelection.languageName("spa"))
            var description = ""
            for _ in 0..<200 {
                description = try await item.externalMetadata.first { $0.identifier == .commonIdentifierDescription }?.load(.stringValue) ?? ""
                if coordinator.playback.currentAudioDisclosure == .effective(3), description.contains(expected) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(native.player?.currentItem === item)
            XCTAssertEqual(coordinator.playback.currentAudioDisclosure, .effective(3))
            XCTAssertTrue(description.contains(expected), "Native Info must follow audio selection with the same item/source/quality/subtitle state.")
            XCTAssertEqual(coordinator.quality, .original); XCTAssertEqual(coordinator.subtitleChoice, -1)
            let attachment = XCTAttachment(string: description); attachment.name = "Native Info after actual audible selection"; attachment.lifetime = .keepAlways; self.add(attachment)
        }
    }

    func testStartOverAndPlayAgainRequestZeroWhileResumeKeepsSavedOffset() async throws {
        try await withCoordinator("tv-beginning") { coordinator in
            let api = try XCTUnwrap(coordinator.session.api)
            var item = try await api.item("movie-3")
            item.UserData = UserData(PlaybackPositionTicks: 80_000_000)
            await coordinator.play(item, fromBeginning: true)
            XCTAssertEqual(coordinator.playback.activeItem?.resumeTicks, 0)
            coordinator.startPlayback(id: coordinator.presentationID)
            try await ready(coordinator)
            XCTAssertLessThan(coordinator.playback.player.currentTime().seconds, 3)
            // Replay must normalize the supplied active item as well as the flag.
            coordinator.playback.activeItem?.UserData = UserData(PlaybackPositionTicks: 80_000_000)
            await coordinator.replayPlayback(id: coordinator.presentationID)
            try await ready(coordinator)
            XCTAssertLessThan(coordinator.playback.player.currentTime().seconds, 3)
            let starts = try await TVFixture.reports().filter { $0["path"] as? String == "/Items/movie-3/PlaybackInfo" }
            XCTAssertEqual(starts.count, 2)
            XCTAssertTrue(starts.allSatisfy { ($0["body"] as? [String: Any])?["StartTimeTicks"] as? Int == 0 })
            await coordinator.closePlayback()
            await coordinator.play(item)
            XCTAssertEqual(coordinator.playback.activeItem?.resumeTicks, 80_000_000, "Normal Resume must retain the supplied offset.")
        }
    }

    func testOldPlayerDelegateAndPresentationCloseCannotStopNewPresentation() async throws {
        try await withCoordinator("tv-stale-close") { coordinator in
            let api = try XCTUnwrap(coordinator.session.api)
            let first = try await api.item("movie-1"), second = try await api.item("movie-3")
            await coordinator.play(first)
            let oldID = coordinator.presentationID
            let oldDelegate = TVNativePlayer.Coordinator(owner: coordinator, presentationID: oldID)
            await coordinator.play(second)
            let currentID = coordinator.presentationID
            XCTAssertNotEqual(oldID, currentID)
            XCTAssertFalse(oldDelegate.playerViewControllerShouldDismiss(AVPlayerViewController()))
            await coordinator.closePlayback(id: oldID)
            coordinator.changeQuality(.dataSaver, id: oldID)
            coordinator.retryPlayback(id: oldID)
            await coordinator.replayPlayback(id: oldID)
            await Task.yield()
            XCTAssertEqual(coordinator.presentationID, currentID)
            XCTAssertEqual(coordinator.playback.activeItem?.id, second.id)
            XCTAssertTrue(coordinator.showingPlayer)
        }
    }

    func testHostedRapidPresentationReplacementActuallyStartsNewVideo() async throws {
        try await withCoordinator("tv-hosted-replacement") { coordinator in
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let priorWindow = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: TVRootView().environment(coordinator).environment(coordinator.session).environment(coordinator.playback).environment(coordinator.preferences))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; priorWindow?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(300))
            let api = try XCTUnwrap(coordinator.session.api)
            let first = try await api.item("movie-1"), second = try await api.item("movie-3")
            await coordinator.play(first)
            try await ready(coordinator)
            let firstNative = try await presentedPlayer(from: host)
            XCTAssertNotNil(firstNative.presentingViewController, "Interactive tvOS AVKit must own a real modal presentation.")
            XCTAssertNil(firstNative.parent)
            XCTAssertTrue(firstNative.speeds.isEmpty, "Stock AVKit speeds must not bypass Reel's custom rate menu or its locks.")
            XCTAssertEqual(firstNative.view.bounds.size, window.bounds.size)
            let oldID = coordinator.presentationID
            let oldDelegate = TVNativePlayer.Coordinator(owner: coordinator, presentationID: oldID)
            await coordinator.closePlayback(id: oldID)
            await coordinator.play(second)
            let currentID = coordinator.presentationID
            XCTAssertNotEqual(oldID, currentID)
            try await ready(coordinator)
            let secondNative = try await presentedPlayer(from: host)
            XCTAssertFalse(firstNative === secondNative)
            XCTAssertNotNil(secondNative.presentingViewController)
            XCTAssertNil(secondNative.parent)
            XCTAssertTrue(secondNative.speeds.isEmpty, "Replacement players must keep the same rate-control policy.")
            for _ in 0..<60 {
                if coordinator.playback.player.currentTime().seconds > 0.2 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertGreaterThan(coordinator.playback.player.currentItem?.presentationSize.width ?? 0, 0)
            XCTAssertGreaterThan(coordinator.playback.player.currentTime().seconds, 0.2)
            XCTAssertFalse(oldDelegate.playerViewControllerShouldDismiss(AVPlayerViewController()))
            await coordinator.closePlayback(id: oldID)
            await Task.yield()
            XCTAssertEqual(coordinator.playback.activeItem?.id, "movie-3")
            XCTAssertEqual(coordinator.presentationID, currentID)
            XCTAssertTrue(coordinator.showingPlayer)
            let receipts = try await TVFixture.reports().filter { $0["user"] as? String == "tv-hosted-replacement" }
            XCTAssertTrue(receipts.contains { $0["path"] as? String == "/Items/movie-3/PlaybackInfo" })
            XCTAssertTrue(receipts.contains { $0["path"] as? String == "/Sessions/Playing" && ($0["body"] as? [String: Any])?["ItemId"] as? String == "movie-3" })
            await coordinator.closePlayback(id: currentID)
        }
    }

    private func presentedPlayer(from root: UIViewController) async throws -> AVPlayerViewController {
        func find(_ controller: UIViewController) -> AVPlayerViewController? {
            if let native = controller.presentedViewController as? AVPlayerViewController { return native }
            if let presented = controller.presentedViewController, let native = find(presented) { return native }
            for child in controller.children { if let native = find(child) { return native } }
            return nil
        }
        for _ in 0..<50 {
            if let native = find(root), native.view.window != nil { return native }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try XCTUnwrap(Optional<AVPlayerViewController>.none, "The hosted player never presented native AVKit modally.")
    }

    func testHostedRealEOFShowsInteractiveStatusAndReplayReturnsToNativeVideo() async throws {
        try await withCoordinator("tv-hosted-end") { coordinator in
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let priorWindow = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: TVRootView().environment(coordinator).environment(coordinator.session).environment(coordinator.playback).environment(coordinator.preferences))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; priorWindow?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(300))
            let api = try XCTUnwrap(coordinator.session.api)
            await coordinator.play(try await api.item("movie-3"))
            try await ready(coordinator)
            let native = try await presentedPlayer(from: host)
            coordinator.playback.seek(to: 235_000_000)
            coordinator.playback.player.play()
            for _ in 0..<80 {
                if coordinator.playback.ended { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(coordinator.playback.ended)
            for _ in 0..<30 {
                if native.presentedViewController != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let status = try XCTUnwrap(native.presentedViewController, "Real EOF must mount the interactive status modal.")
            XCTAssertTrue(String(reflecting: type(of: status)).contains("TVPlaybackStatus"))
            await coordinator.replayPlayback(id: coordinator.presentationID)
            try await ready(coordinator)
            for _ in 0..<30 {
                if native.presentedViewController == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNil(native.presentedViewController)
            XCTAssertFalse(coordinator.playback.ended)
            XCTAssertLessThan(coordinator.playback.player.currentTime().seconds, 3)
            await coordinator.closePlayback()
        }
    }

    func testHostedNativeDelegateSurvivesQualityAndPausedChapterSeek() async throws {
        try await withCoordinator("tv-hosted-native-close") { coordinator in
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let priorWindow = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: TVRootView().environment(coordinator).environment(coordinator.session).environment(coordinator.playback).environment(coordinator.preferences))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; priorWindow?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(300))
            let api = try XCTUnwrap(coordinator.session.api)
            await coordinator.play(try await api.item("movie-1"))
            try await ready(coordinator)
            let native = try await presentedPlayer(from: host)
            weak var originalDelegate: AnyObject? = native.delegate
            XCTAssertNotNil(originalDelegate)
            coordinator.changeQuality(.high, id: coordinator.presentationID)
            try await ready(coordinator)
            coordinator.playback.player.pause()
            coordinator.playback.speed = 2
            coordinator.playback.seek(to: 80_000_000)
            try await Task.sleep(for: .seconds(1))
            XCTAssertTrue(native.player === coordinator.playback.player)
            XCTAssertTrue(native.delegate === originalDelegate)
            let delegate = try XCTUnwrap(native.delegate as? TVNativePlayer.Coordinator)
            XCTAssertEqual(coordinator.playback.player.currentTime().seconds, 8, accuracy: 0.15)
            XCTAssertNotNil(native.presentingViewController)
            XCTAssertFalse(delegate.playerViewControllerShouldDismiss(native))
            for _ in 0..<50 {
                if !coordinator.showingPlayer { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertFalse(coordinator.showingPlayer, "The live native dismissal delegate must still close the current presentation after quality and chapter changes.")
        }
    }

    func testReplayAcquiresTransitionUntilFlushAndDropsDuplicateIntent() async throws {
        try await withCoordinator("tv-replay-lock") { coordinator in
            let api = try XCTUnwrap(coordinator.session.api)
            await coordinator.play(try await api.item("movie-3"))
            let id = coordinator.presentationID
            coordinator.startPlayback(id: id)
            try await ready(coordinator)
            try await TVFixture.control(failReports: false, failCleanup: false, reportDelay: 0.7)
            let first = Task { await coordinator.replayPlayback(id: id) }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(coordinator.transitioning)
            await coordinator.replayPlayback(id: id)
            XCTAssertTrue(coordinator.transitioning, "The duplicate intent must return while the original replay still owns the transition.")
            await first.value
            try await ready(coordinator)
            XCTAssertFalse(coordinator.transitioning)
            let starts = try await TVFixture.reports().filter { $0["path"] as? String == "/Items/movie-3/PlaybackInfo" }
            XCTAssertEqual(starts.count, 2)
            try await TVFixture.control(failReports: false, failCleanup: false)
        }
    }

    func testAccountChangeDuringPlayFlushRejectsOldAccountItemAndNewAccountRemainsUsable() async throws {
        try await withCoordinator("tv-switch-old") { coordinator in
            let oldAPI = try XCTUnwrap(coordinator.session.api)
            let oldItem = try await oldAPI.item("movie-1"), pendingItem = try await oldAPI.item("movie-2")
            await coordinator.play(oldItem)
            coordinator.startPlayback(id: coordinator.presentationID)
            try await ready(coordinator)
            try await TVFixture.control(failReports: false, failCleanup: false, reportDelay: 0.7)
            let pending = Task { await coordinator.play(pendingItem) }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(coordinator.transitioning)
            try await coordinator.session.accept(account("tv-switch-new"))
            await pending.value
            XCTAssertFalse(coordinator.showingPlayer)
            XCTAssertNil(coordinator.playback.activeItem)
            XCTAssertEqual(coordinator.session.account?.userID, "tv-switch-new")
            let receipts = try await TVFixture.reports()
            XCTAssertFalse(receipts.contains { $0["path"] as? String == "/Items/movie-2/PlaybackInfo" })
            try await TVFixture.control(failReports: false, failCleanup: false)
            let newAPI = try XCTUnwrap(coordinator.session.api)
            await coordinator.play(try await newAPI.item("movie-3"))
            coordinator.startPlayback(id: coordinator.presentationID)
            try await ready(coordinator)
        }
    }

    func testReplacementWaitsForMatchingDismissalAndIgnoresAnOldSignal() async throws {
        try await withCoordinator("tv-dismissal-fence") { coordinator in
            let api = try XCTUnwrap(coordinator.session.api)
            let first = try await api.item("movie-1"), second = try await api.item("movie-3")
            await coordinator.play(first)
            let oldID = coordinator.presentationID
            coordinator.presentationAppeared(id: oldID)
            let replacement = Task { await coordinator.play(second) }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(coordinator.showingPlayer)
            XCTAssertTrue(coordinator.transitioning)
            coordinator.presentationDismissed(id: UUID())
            await Task.yield()
            XCTAssertEqual(coordinator.presentationID, oldID)
            coordinator.presentationDismissed(id: oldID)
            await replacement.value
            XCTAssertTrue(coordinator.showingPlayer)
            XCTAssertEqual(coordinator.playback.activeItem?.id, second.id)
            coordinator.presentationDismissed(id: oldID)
            XCTAssertTrue(coordinator.showingPlayer)
        }
    }

    func testUnconfirmedDismissalRejectsReplacementWithRecoverableError() async throws {
        try await withCoordinator("tv-dismissal-timeout") { coordinator in
            let api = try XCTUnwrap(coordinator.session.api)
            let first = try await api.item("movie-1"), second = try await api.item("movie-3")
            await coordinator.play(first)
            let id = coordinator.presentationID
            coordinator.presentationAppeared(id: id)
            await coordinator.play(second)
            XCTAssertFalse(coordinator.showingPlayer)
            XCTAssertNil(coordinator.playback.activeItem)
            XCTAssertNotNil(coordinator.error)
            XCTAssertFalse(coordinator.transitioning)
            coordinator.presentationDismissed(id: id)
            coordinator.error = nil
            await coordinator.play(second)
            XCTAssertTrue(coordinator.showingPlayer)
        }
    }

    func testInactiveAccountRemovalDrainsPreviousCleanupBeforeLogoutWithoutStoppingCurrentPlayer() async throws {
        try await withCoordinator("tv-old-account") { coordinator in
            let oldAccount = try XCTUnwrap(coordinator.session.account)
            let oldAPI = try XCTUnwrap(coordinator.session.api)
            let first = try await oldAPI.item("movie-1")
            coordinator.quality = .dataSaver
            await coordinator.play(first)
            coordinator.startPlayback(id: coordinator.presentationID)
            try await ready(coordinator)
            try await TVFixture.control(failReports: false, failCleanup: false, reportDelay: 0.7)
            let closing = Task { await coordinator.closePlayback() }
            await Task.yield()
            try await coordinator.session.accept(account("tv-current-account"))
            let currentAPI = try XCTUnwrap(coordinator.session.api)
            let second = try await currentAPI.item("movie-3")
            // Model account activation racing the prior cover's async close.
            // B's presentation is already owned when A is removed.
            coordinator.playback.present(second)
            coordinator.showingPlayer = true
            let currentID = coordinator.presentationID
            await coordinator.remove(oldAccount)
            await closing.value
            XCTAssertEqual(coordinator.playback.activeItem?.id, second.id)
            XCTAssertTrue(coordinator.showingPlayer)
            XCTAssertEqual(coordinator.presentationID, currentID)
            let reports = try await TVFixture.reports().filter { $0["user"] as? String == "tv-old-account" }
            let cleanup = try XCTUnwrap(reports.firstIndex { $0["path"] as? String == "/Videos/ActiveEncodings" })
            let logout = try XCTUnwrap(reports.firstIndex { $0["path"] as? String == "/Sessions/Logout" })
            XCTAssertLessThan(cleanup, logout)
            try await TVFixture.control(failReports: false, failCleanup: false)
        }
    }

    func testParentReloadInvalidatesSlowPriorSeasonAndItsFailure() async throws {
        try await TVFixture.reset()
        func api(_ user: String) -> JellyfinAPI {
            JellyfinAPI(server: URL(string: "http://127.0.0.1:18966")!, token: "fixture-" + user, userID: user, deviceID: "tv-episode-qa")
        }
        for oldUser in ["tv-slow-season", "tv-fail-season"] {
            let detail = TVDetailStore()
            await detail.load(id: "series-7", api: api("tv-detail"))
            detail.seasonID = "season-2"
            let previous = Task { await detail.loadEpisodes(api: api(oldUser)) }
            try await Task.sleep(for: .milliseconds(100))
            await detail.load(id: "series-7", api: api("tv-empty-seasons"))
            await previous.value
            XCTAssertTrue(detail.seasons.isEmpty)
            XCTAssertTrue(detail.episodes.isEmpty)
            XCTAssertFalse(detail.episodeLoading)
            XCTAssertNil(detail.episodeError)
        }
    }

    func testCloseDuringMediaPreparationCleansNegotiatedEncoderAndCannotStartLate() async throws {
        try await withCoordinator("tv-slow-media") { coordinator in
            let api = try XCTUnwrap(coordinator.session.api)
            let item = try await api.item("movie-3")
            coordinator.quality = .dataSaver
            await coordinator.play(item)
            coordinator.startPlayback(id: coordinator.presentationID)
            for _ in 0..<100 {
                if coordinator.playback.method == "Transcode" { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(coordinator.playback.method, "Transcode")
            XCTAssertTrue(coordinator.playback.preparing)
            await coordinator.closePlayback(id: coordinator.presentationID)
            try await Task.sleep(for: .milliseconds(2300))
            XCTAssertFalse(coordinator.showingPlayer)
            XCTAssertNil(coordinator.playback.player.currentItem)
            XCTAssertFalse(coordinator.playback.isPlaying)
            let reports = try await TVFixture.reports().filter { $0["user"] as? String == "tv-slow-media" }
            XCTAssertTrue(reports.contains { $0["path"] as? String == "/Videos/ActiveEncodings" })
            XCTAssertFalse(reports.contains { $0["path"] as? String == "/Sessions/Playing" })
        }
    }
}
