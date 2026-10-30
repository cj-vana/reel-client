import AVFoundation
import AVKit
import SwiftUI
import XCTest
@testable import ReelTV

@MainActor final class TVSubtitleMenuTests: XCTestCase {
    private let server = URL(string: "http://127.0.0.1:18968")!

    func testCatalogRequiresExactSourceAndUniqueTrackIdentity() {
        let track = MediaStream(Index: 2, Type: "Subtitle", DisplayTitle: "English full")
        var item = MediaItem(Id: "movie", Name: "Movie", MediaSources: [MediaSource(Id: "one", MediaStreams: [track])])
        XCTAssertEqual(TVSubtitleCatalog(item: item, sourceID: "one").tracks.map(\.index), [2])
        XCTAssertNotNil(TVSubtitleCatalog(item: item, sourceID: "different").error)
        item.MediaSources?.append(MediaSource(Id: "one", MediaStreams: [track]))
        XCTAssertNotNil(TVSubtitleCatalog(item: item, sourceID: "one").error)
        item.MediaSources = [MediaSource(Id: "one", MediaStreams: [track, track])]
        XCTAssertTrue(TVSubtitleCatalog(item: item, sourceID: "one").tracks.isEmpty)
        item.MediaSources = [MediaSource(Id: "one", MediaStreams: [track, MediaStream(Index: 3, Type: "Subtitle", DisplayTitle: " English full ")])]
        XCTAssertNotNil(TVSubtitleCatalog(item: item, sourceID: "one").error)
    }

    func testCatalogHandlesEmptyTracksAndKeepsUnrelatedAudioOut() {
        let item = MediaItem(Id: "movie", Name: "Movie", MediaSources: [MediaSource(Id: "one", MediaStreams: [MediaStream(Index: 1, Type: "Audio", DisplayTitle: "English")])])
        let catalog = TVSubtitleCatalog(item: item, sourceID: "one")
        XCTAssertNil(catalog.error)
        XCTAssertTrue(catalog.tracks.isEmpty)
        XCTAssertNotNil(TVSubtitleCatalog(item: item, sourceID: nil).error)
    }

    func testPrivateSwitchRetainsDecodedPositionAndPauseThenClearsExplicitChoiceForDefault() async throws {
        try await withCoordinator { coordinator in
            try await self.start(coordinator)
            let automatic = coordinator.playback.player.appliesMediaSelectionCriteriaAutomatically
            let audible = self.criteriaSnapshot(coordinator.playback.player.mediaSelectionCriteria(forMediaCharacteristic: .audible))
            coordinator.playback.seek(to: 80_000_000)
            for _ in 0..<100 {
                if coordinator.playback.player.currentTime().seconds >= 8 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            coordinator.playback.player.pause()
            let position = coordinator.playback.player.currentTime().seconds
            XCTAssertGreaterThanOrEqual(position, 8)
            let id = coordinator.presentationID
            coordinator.changeSubtitle(-1, nativeItem: coordinator.playback.player.currentItem, catalog: coordinator.subtitleCatalog, id: id, itemID: "movie-1", sourceID: "movie-1-source")
            XCTAssertTrue(coordinator.changingSubtitles)
            XCTAssertFalse(coordinator.subtitleSelectionConfirmed)
            try await self.ready(coordinator)
            XCTAssertEqual(coordinator.subtitleChoice, -1)
            XCTAssertEqual(coordinator.playback.player.rate, 0)
            XCTAssertEqual(coordinator.playback.player.currentTime().seconds, position, accuracy: 0.3)
            let item = try XCTUnwrap(coordinator.playback.player.currentItem)
            let loaded = try await item.asset.loadMediaSelectionGroup(for: .legible)
            let group = try XCTUnwrap(loaded)
            XCTAssertEqual(group.options.count, 1)
            XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: group))
            coordinator.changeSubtitle(nil, nativeItem: coordinator.playback.player.currentItem, catalog: coordinator.subtitleCatalog, id: id, itemID: "movie-1", sourceID: "movie-1-source")
            try await self.ready(coordinator)
            XCTAssertNil(coordinator.subtitleChoice, "Server default clears the explicit Off intent; it does not assert a native selected option.")
            XCTAssertEqual(coordinator.playback.player.rate, 0)
            let state = try await self.state()
            let bodies = (state["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }.compactMap { $0["body"] as? [String: Any] }
            XCTAssertEqual(bodies.count, 3)
            guard bodies.count == 3 else { throw URLError(.badServerResponse) }
            XCTAssertEqual(bodies[1]["SubtitleStreamIndex"] as? Int, -1)
            XCTAssertNil(bodies[2]["SubtitleStreamIndex"])
            XCTAssertEqual(coordinator.playback.player.appliesMediaSelectionCriteriaAutomatically, automatic)
            XCTAssertEqual(self.criteriaSnapshot(coordinator.playback.player.mediaSelectionCriteria(forMediaCharacteristic: .audible)), audible)
            XCTAssertTrue(bodies.dropFirst().allSatisfy { ($0["StartTimeTicks"] as? Int ?? 0) >= 80_000_000 })
            XCTAssertFalse((state["reports"] as? [[String: Any]] ?? []).contains { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
            XCTAssertEqual((state["subtitleCleanups"] as? [[String: Any]])?.count, 2)
            let reports = try XCTUnwrap(state["reports"] as? [[String: Any]])
            let cleanupIndices = reports.indices.filter { reports[$0]["path"] as? String == "/Videos/ActiveEncodings" }
            let negotiationIndices = reports.indices.filter { reports[$0]["path"] as? String == "/Items/movie-1/PlaybackInfo" }
            XCTAssertEqual(cleanupIndices.count, 2)
            XCTAssertTrue(zip(cleanupIndices, negotiationIndices.dropFirst()).allSatisfy { $0 < $1 }, "Each old owned encoder must be drained before the replacement negotiation.")
            self.attach(state, name: "Private subtitle restart retains pause and eight-second position without watch history")
        }
    }

    func testUnavailableTrackLeavesCurrentDecodedPlaybackAndCheckmarkIntact() async throws {
        try await withCoordinator { coordinator in
            try await self.start(coordinator)
            let item = try XCTUnwrap(coordinator.playback.player.currentItem)
            coordinator.changeSubtitle(999, nativeItem: coordinator.playback.player.currentItem, catalog: coordinator.subtitleCatalog, id: coordinator.presentationID, itemID: "movie-1", sourceID: "movie-1-source")
            XCTAssertTrue(coordinator.playback.player.currentItem === item)
            XCTAssertEqual(coordinator.subtitleChoice, 2)
            XCTAssertNotNil(coordinator.subtitleError)
            XCTAssertGreaterThan(coordinator.playback.player.rate, 0)
            XCTAssertFalse(coordinator.changingSubtitles)
        }
    }

    func testFailedChoiceHasNoSuccessCheckmarkAndRetryRecoversTheRequestedTrack() async throws {
        try await withCoordinator { coordinator in
            let api = try XCTUnwrap(coordinator.session.api)
            await coordinator.play(try await api.item("movie-1"), sourceID: "movie-1-source", subtitle: -1, fromBeginning: true)
            coordinator.startPlayback(id: coordinator.presentationID)
            try await self.ready(coordinator)
            try await self.control(["subtitleWrongName": true])
            coordinator.changeSubtitle(2, nativeItem: coordinator.playback.player.currentItem, catalog: coordinator.subtitleCatalog, id: coordinator.presentationID, itemID: "movie-1", sourceID: "movie-1-source")
            for _ in 0..<300 {
                if coordinator.playback.error != nil && !coordinator.changingSubtitles { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertNotNil(coordinator.playback.error)
            XCTAssertFalse(coordinator.subtitleSelectionConfirmed, "A requested but failed track must not receive a successful selection checkmark.")
            try await self.control(["subtitleWrongName": false])
            coordinator.retryPlayback(id: coordinator.presentationID)
            try await self.ready(coordinator)
            XCTAssertTrue(coordinator.subtitleSelectionConfirmed)
            XCTAssertEqual(coordinator.subtitleChoice, 2)
            let item = try XCTUnwrap(coordinator.playback.player.currentItem)
            let loaded = try await item.asset.loadMediaSelectionGroup(for: .legible)
            XCTAssertNotNil(item.currentMediaSelection.selectedMediaOption(in: try XCTUnwrap(loaded)))
        }
    }

    func testHomeDTOWithoutSourcesLoadsTrackMetadataAlongsidePlayback() async throws {
        try await withCoordinator { coordinator in
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let priorWindow = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: TVRootView().environment(coordinator).environment(coordinator.session).environment(coordinator.playback).environment(coordinator.preferences))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; priorWindow?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(300))
            let api = try XCTUnwrap(coordinator.session.api)
            var item = try await api.item("movie-1"); item.MediaSources = nil
            try await self.control(["subtitleCatalogDelay": true])
            do {
                await coordinator.play(item, subtitle: -1, fromBeginning: true)
                try await self.ready(coordinator)
                let native = try await self.presentedPlayer(from: host)
                XCTAssertTrue(coordinator.subtitleMetadataLoading)
                for _ in 0..<40 {
                    if native.transportBarCustomMenuItems.compactMap({ $0 as? UIMenu }).flatMap(\.children).compactMap({ $0 as? UIAction }).contains(where: { $0.title == "Loading subtitle tracks…" }) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let menu = try XCTUnwrap(native.transportBarCustomMenuItems.compactMap { $0 as? UIMenu }.first { $0.title == "Subtitles" })
                let actions = menu.children.compactMap { $0 as? UIAction }
                XCTAssertEqual(actions.map(\.title), ["Server default", "Off", "Loading subtitle tracks…"])
                XCTAssertTrue(actions.allSatisfy { $0.attributes.contains(.disabled) }, "Assert the public UIAction state rather than AVKit's enabled accessibility wrapper.")
                let receipt = XCTAttachment(string: actions.map { "\($0.title): disabled=\($0.attributes.contains(.disabled))" }.joined(separator: "\n"))
                receipt.name = "Actual hosted public subtitle loading menu attributes"; receipt.lifetime = .keepAlways; self.add(receipt)
                try await self.control(["subtitleCatalogDelay": false])
                for _ in 0..<100 {
                    if !coordinator.subtitleMetadataLoading { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertFalse(coordinator.subtitleMetadataLoading)
                XCTAssertNil(coordinator.subtitleMetadataError)
                XCTAssertEqual(coordinator.subtitleCatalog.tracks.map(\.index), [2])
                XCTAssertEqual(coordinator.playback.currentSourceID, "movie-1-source")
                XCTAssertGreaterThan(coordinator.playback.player.currentItem?.presentationSize.width ?? 0, 0)
                await coordinator.closePlayback()
            } catch {
                try? await self.control(["subtitleCatalogDelay": false])
                throw error
            }
        }
    }

    func testCloseDuringDelayedSubtitlePreparationCannotRestartPlayer() async throws {
        try await withCoordinator { coordinator in
            try await self.start(coordinator)
            try await self.control(["subtitleManifestDelay": true])
            coordinator.changeSubtitle(-1, nativeItem: coordinator.playback.player.currentItem, catalog: coordinator.subtitleCatalog, id: coordinator.presentationID, itemID: "movie-1", sourceID: "movie-1-source")
            try await self.waitForMasters(2)
            XCTAssertTrue(coordinator.changingSubtitles)
            await coordinator.closePlayback()
            try await Task.sleep(for: .seconds(3))
            XCTAssertNil(coordinator.playback.player.currentItem)
            XCTAssertNil(coordinator.subtitleChoice)
            XCTAssertFalse(coordinator.showingPlayer)
            XCTAssertFalse(coordinator.changingSubtitles)
            let state = try await self.state()
            XCTAssertEqual((state["subtitleCleanups"] as? [[String: Any]])?.count, 2)
        }
    }

    func testOldMenuActionCannotChangeNewPresentation() async throws {
        try await withCoordinator { coordinator in
            try await self.start(coordinator)
            let oldID = coordinator.presentationID
            let api = try XCTUnwrap(coordinator.session.api)
            let next = try await api.item("movie-3")
            await coordinator.play(next, fromBeginning: true)
            coordinator.startPlayback(id: coordinator.presentationID)
            try await self.ready(coordinator)
            let native = try XCTUnwrap(coordinator.playback.player.currentItem)
            coordinator.changeSubtitle(-1, nativeItem: coordinator.playback.player.currentItem, catalog: coordinator.subtitleCatalog, id: oldID, itemID: "movie-1", sourceID: "movie-1-source")
            XCTAssertTrue(coordinator.playback.player.currentItem === native)
            XCTAssertEqual(coordinator.playback.activeItem?.id, "movie-3")
            XCTAssertNil(coordinator.subtitleChoice)
            XCTAssertFalse(coordinator.changingSubtitles)
        }
    }

    func testQueuedOldNativeItemActionCannotChangeSamePresentationReplacement() async throws {
        try await withCoordinator { coordinator in
            try await self.start(coordinator)
            let id = coordinator.presentationID, original = try XCTUnwrap(coordinator.playback.player.currentItem)
            let catalog = coordinator.subtitleCatalog
            coordinator.retryPlayback(id: id)
            // Retry installs its new item asynchronously, and the original is already ready, so wait for the swap first.
            for _ in 0..<300 {
                if coordinator.playback.player.currentItem !== original { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await self.ready(coordinator)
            let replacement = try XCTUnwrap(coordinator.playback.player.currentItem)
            XCTAssertFalse(replacement === original)
            XCTAssertEqual(coordinator.presentationID, id)
            coordinator.playback.player.pause()
            let position = coordinator.playback.player.currentTime().seconds
            let before = try await self.state()
            let count = (before["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }.count
            coordinator.changeSubtitle(-1, nativeItem: original, catalog: catalog, id: id, itemID: "movie-1", sourceID: "movie-1-source")
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(coordinator.playback.player.currentItem === replacement)
            XCTAssertEqual(coordinator.playback.player.currentTime().seconds, position, accuracy: 0.02)
            XCTAssertEqual(coordinator.playback.player.rate, 0)
            XCTAssertEqual(coordinator.subtitleChoice, 2)
            XCTAssertNil(coordinator.subtitleError)
            XCTAssertFalse(coordinator.changingSubtitles)
            let after = try await self.state()
            XCTAssertEqual((after["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }.count, count)
        }
    }

    func testQueuedCatalogChoiceRejectsReloadedIdentityAtSameIndexAndNativeItem() async throws {
        try await withCoordinator { coordinator in
            let api = try XCTUnwrap(coordinator.session.api)
            await coordinator.play(try await api.item("movie-1"), sourceID: "movie-1-source", subtitle: -1, fromBeginning: true)
            coordinator.startPlayback(id: coordinator.presentationID)
            try await self.ready(coordinator)
            let native = try XCTUnwrap(coordinator.playback.player.currentItem), catalog = coordinator.subtitleCatalog
            try await self.control(["subtitleCatalogRenamed": true])
            coordinator.loadSubtitleMetadata(force: true)
            for _ in 0..<150 {
                if !coordinator.subtitleMetadataLoading { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotEqual(coordinator.subtitleCatalog, catalog)
            XCTAssertEqual(coordinator.subtitleCatalog.tracks.map(\.index), catalog.tracks.map(\.index))
            XCTAssertEqual(coordinator.subtitleCatalog.tracks.first?.title, "Synthetic captions renamed")
            let before = try await self.state()
            let count = (before["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }.count
            coordinator.changeSubtitle(2, nativeItem: native, catalog: catalog, id: coordinator.presentationID, itemID: "movie-1", sourceID: "movie-1-source")
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(coordinator.playback.player.currentItem === native)
            XCTAssertEqual(coordinator.subtitleChoice, -1)
            XCTAssertNil(coordinator.subtitleError)
            XCTAssertFalse(coordinator.changingSubtitles)
            let after = try await self.state()
            XCTAssertEqual((after["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }.count, count)
        }
    }

    func testAccountReplacementCancelsPendingSubtitleStartup() async throws {
        try await withCoordinator { coordinator in
            try await self.start(coordinator)
            let oldID = coordinator.presentationID
            try await self.control(["subtitleManifestDelay": true])
            coordinator.changeSubtitle(-1, nativeItem: coordinator.playback.player.currentItem, catalog: coordinator.subtitleCatalog, id: oldID, itemID: "movie-1", sourceID: "movie-1-source")
            try await self.waitForMasters(2)
            let account = Account(server: self.server, token: "fixture-tv-subtitle-menu-other-account", userID: "tv-subtitle-menu-other-account", name: "TV QA B", serverName: "Synthetic tracks")
            try await coordinator.session.accept(account)
            await coordinator.activated()
            let api = try XCTUnwrap(coordinator.session.api)
            await coordinator.play(try await api.item("movie-3"), fromBeginning: true)
            coordinator.startPlayback(id: coordinator.presentationID)
            try await self.ready(coordinator)
            let current = try XCTUnwrap(coordinator.playback.player.currentItem)
            try await Task.sleep(for: .seconds(3))
            XCTAssertTrue(coordinator.playback.player.currentItem === current)
            XCTAssertEqual(coordinator.session.account?.id, account.id)
            XCTAssertEqual(coordinator.playback.activeItem?.id, "movie-3")
            XCTAssertNil(coordinator.subtitleChoice)
            XCTAssertFalse(coordinator.changingSubtitles)
            XCTAssertGreaterThan(coordinator.playback.player.currentTime().seconds, 1)
            coordinator.changeSubtitle(2, nativeItem: coordinator.playback.player.currentItem, catalog: coordinator.subtitleCatalog, id: oldID, itemID: "movie-1", sourceID: "movie-1-source")
            XCTAssertTrue(coordinator.playback.player.currentItem === current)
        }
    }

    private struct CriteriaSnapshot: Equatable {
        let exists: Bool
        let languages: [String]?
        let characteristics: [String]?
        let principal: [String]?
    }
    private func criteriaSnapshot(_ value: AVPlayerMediaSelectionCriteria?) -> CriteriaSnapshot {
        CriteriaSnapshot(exists: value != nil, languages: value?.preferredLanguages,
                         characteristics: value?.preferredMediaCharacteristics?.map(\.rawValue),
                         principal: value?.principalMediaCharacteristics?.map(\.rawValue))
    }

    private final class Store: AccountVaultStorage {
        var vault: AccountVault
        init(_ account: Account) { vault = AccountVault(accounts: [account], activeID: account.id) }
        func read() throws -> AccountVault { vault }
        func save(_ value: AccountVault) throws { vault = value }
        func clear() throws { vault = AccountVault() }
    }

    private func withCoordinator(_ body: (TVCoordinator) async throws -> Void) async throws {
        try TVFixture.requireQAHost()
        try await post("reset", [:]); try await post("control", ["failReports": false, "failCleanup": false])
        let account = Account(server: server, token: "fixture-tv-track-output", userID: "tv-track-output", name: "TV QA", serverName: "Synthetic tracks")
        let suite = "app.reelclient.tv.qa.subtitle-menu." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "privateViewing"); defaults.set("tv-subtitle-menu-qa", forKey: "deviceID")
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = Session(storage: Store(account), defaults: defaults,
                              services: SessionAccountServices(authenticate: { _, _, _, _ in account }, revoke: { _, _ in }, removeCredentials: { _, _ in }))
        let coordinator = TVCoordinator(session: session)
        do { try await body(coordinator); await coordinator.closePlayback() }
        catch { await coordinator.closePlayback(); throw error }
    }

    private func start(_ coordinator: TVCoordinator) async throws {
        let api = try XCTUnwrap(coordinator.session.api)
        await coordinator.play(try await api.item("movie-1"), sourceID: "movie-1-source", subtitle: 2, fromBeginning: true)
        coordinator.startPlayback(id: coordinator.presentationID)
        try await ready(coordinator)
    }

    private func ready(_ coordinator: TVCoordinator) async throws {
        for _ in 0..<300 {
            if coordinator.playback.error != nil || (!coordinator.playback.preparing && !coordinator.changingSubtitles && coordinator.playback.player.currentItem?.status == .readyToPlay) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(coordinator.playback.error)
        XCTAssertFalse(coordinator.playback.preparing)
        XCTAssertFalse(coordinator.changingSubtitles)
        XCTAssertEqual(coordinator.playback.player.currentItem?.status, .readyToPlay)
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

    private func control(_ body: [String: Bool]) async throws { try await post("tv-control", body) }
    private func post(_ path: String, _ body: [String: Bool]) async throws {
        try TVFixture.requireQAHost()
        var request = try await TVFixture.request(server.appendingPathComponent("qa/" + path))
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    private func state() async throws -> [String: Any] {
        try TVFixture.requireQAHost()
        let (data, response) = try await URLSession.shared.data(for: try await TVFixture.request(server.appendingPathComponent("qa/state")))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func waitForMasters(_ count: Int) async throws {
        for _ in 0..<150 {
            if ((try await state()["trackRequests"] as? [[String: Any]]) ?? []).filter({ ($0["path"] as? String)?.hasSuffix("master.m3u8") == true }).count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The real delayed replacement master did not begin."); throw URLError(.timedOut)
    }
    private func attach(_ state: [String: Any], name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        let receipt = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        receipt.name = name; receipt.lifetime = .keepAlways; add(receipt)
    }
}
