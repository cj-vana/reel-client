import AVFoundation
import XCTest
@testable import ReelTV

@MainActor final class TVSubtitleStartupTests: XCTestCase {
    private let server = URL(string: "http://127.0.0.1:18968")!

    private func api(user: String = "tv-track-output", historyEnabled: Bool = false) -> JellyfinAPI {
        JellyfinAPI(server: server, token: "fixture-" + user, userID: user, deviceID: "tv-subtitle-startup-qa", historyEnabled: historyEnabled)
    }

    func testControllerExplicitOffOverridesOnPolicyWithRealRenditionStillInManifest() async throws {
        try await reset()
        let api = api()
        let media = try await api.item("movie-1")
        let player = PlaybackController()
        player.player.setMediaSelectionCriteria(AVPlayerMediaSelectionCriteria(preferredLanguages: ["en"], preferredMediaCharacteristics: []), forMediaCharacteristic: .legible)
        let automatic = player.player.appliesMediaSelectionCriteriaAutomatically
        let audible = criteria(player.player.mediaSelectionCriteria(forMediaCharacteristic: .audible))
        do {
            player.present(media, fromBeginning: true, mediaSourceID: "movie-1-source")
            player.start(api: api, quality: .original)
            let initial = try await ready(player)
            let loadedInitialGroup = try await initial.asset.loadMediaSelectionGroup(for: .legible)
            let initialGroup = try XCTUnwrap(loadedInitialGroup)
            XCTAssertNotNil(initial.currentMediaSelection.selectedMediaOption(in: initialGroup), "Establish native On before testing explicit Off.")
            player.present(media, subtitle: -1, fromBeginning: true, mediaSourceID: "movie-1-source")
            player.start(api: api, quality: .original)
            let item = try await ready(player)
            let loadedGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
            let group = try XCTUnwrap(loadedGroup)
            XCTAssertEqual(group.options.count, 1, "This Off regression must retain a real available subtitle rendition.")
            XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: group))
            XCTAssertTrue(try XCTUnwrap((item.asset as? AVURLAsset)?.url).path.contains("/on/"))
            XCTAssertEqual(player.player.appliesMediaSelectionCriteriaAutomatically, automatic)
            XCTAssertEqual(criteria(player.player.mediaSelectionCriteria(forMediaCharacteristic: .audible)), audible)
            try await attachState("Explicit startup Off with retained native subtitle option")
            player.stop(); await player.flushReports()
        } catch {
            player.stop(); await player.flushReports()
            throw error
        }
    }

    func testStopDuringMetadataLoadCannotInstallOrStartTheCanceledItem() async throws {
        try await reset()
        try await delay(true)
        let api = api()
        let media = try await api.item("movie-1")
        let player = PlaybackController()
        player.present(media, subtitle: 2, fromBeginning: true, mediaSourceID: "movie-1-source")
        player.start(api: api, quality: .original)
        do {
            try await waitForMaster()
            XCTAssertTrue(player.preparing)
            XCTAssertNil(player.player.currentItem)
            player.stop(); await player.flushReports()
            try await Task.sleep(for: .seconds(3))
            XCTAssertNil(player.player.currentItem)
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(player.method, "")
            XCTAssertNil(player.error)
            try await attachState("Canceled metadata preparation cleanup")
            try await delay(false)
        } catch {
            player.stop(); await player.flushReports()
            try? await delay(false)
            throw error
        }
    }

    func testMetadataTransportFallbackPreservesFreshServerResumeAndCleansOnlyFailedEncoder() async throws {
        try await reset()
        let api = api()
        let stale = try await api.item("movie-1")
        XCTAssertEqual(stale.resumeTicks, 0)
        try await post("/qa/tv-control", ["subtitleMetadataFailure": true, "subtitleRefreshedResume": true])
        let player = PlaybackController()
        player.present(stale, subtitle: 2, mediaSourceID: "movie-1-source")
        player.start(api: api, quality: .original)
        do {
            _ = try await ready(player)
            XCTAssertGreaterThanOrEqual(player.player.currentTime().seconds, 8)
            await player.flushReports()
            let (_, value) = try await state()
            let negotiations = (value["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }
            XCTAssertEqual(negotiations.count, 2)
            XCTAssertEqual(negotiations.compactMap { ($0["body"] as? [String: Any])?["StartTimeTicks"] as? Int }, [80_000_000, 80_000_000])
            let sources = try XCTUnwrap(value["subtitleNegotiations"] as? [[String: String]])
            XCTAssertEqual(sources.map { $0["session"] ?? "" }, ["synthetic-bad-metadata-session", "synthetic-track-session"])
            try await attachState("Metadata transport fallback retains refreshed eight-second resume", expectedSession: "synthetic-bad-metadata-session")
            player.stop(); await player.flushReports()
        } catch {
            player.stop(); await player.flushReports()
            throw error
        }
    }

    func testLateMetadataFromAccountACannotMutateAccountBPlayer() async throws {
        try await reset()
        try await delay(true)
        let accountA = api()
        let accountB = api(user: "tv-subtitle-other-account")
        let mediaA = try await accountA.item("movie-1")
        let mediaB = try await accountB.item("movie-3")
        let player = PlaybackController()
        player.present(mediaA, subtitle: 2, fromBeginning: true, mediaSourceID: "movie-1-source")
        player.start(api: accountA, quality: .original)
        do {
            try await waitForMaster()
            XCTAssertNil(player.player.currentItem)
            player.present(mediaB, fromBeginning: true)
            player.start(api: accountB, quality: .original)
            let itemB = try await ready(player)
            try await Task.sleep(for: .seconds(3))
            XCTAssertTrue(player.player.currentItem === itemB)
            XCTAssertEqual(player.activeItem?.id, mediaB.id)
            XCTAssertNil(player.error)
            XCTAssertTrue(player.isPlaying)
            XCTAssertGreaterThan(player.player.currentTime().seconds, 1)
            try await attachState("Late accountA metadata leaves decoded accountB untouched")
            player.stop(); await player.flushReports()
            try await delay(false)
        } catch {
            player.stop(); await player.flushReports()
            try? await delay(false)
            throw error
        }
    }

    func testCanceledReadyStartupCannotSeekOrStartAfterStop() async throws {
        try await reset()
        let api = api()
        var media = try await api.item("movie-1")
        media.UserData = UserData(PlaybackPositionTicks: 80_000_000)
        let gate = StartupGate()
        let player = PlaybackController(beforeInitialPlayback: { await gate.waitOnce() })
        player.present(media, subtitle: 2, fromBeginning: true, mediaSourceID: "movie-1-source")
        player.start(api: api, quality: .original)
        do {
            try await gate.waitForEntry()
            try await assertNegotiatedEightSecondResume()
            XCTAssertEqual(player.player.currentItem?.status, .readyToPlay)
            XCTAssertTrue(player.preparing)
            player.stop()
            gate.release()
            await player.flushReports()
            XCTAssertNil(player.player.currentItem)
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(player.method, "")
            XCTAssertNil(player.error)
            XCTAssertEqual(gate.entries, 1)
            try await attachState("Canceled ready startup releases its encoder without starting")
        } catch {
            player.stop(); gate.release(); await player.flushReports()
            throw error
        }
    }

    func testCanceledReadyStartupCannotSeekAccountBOrReportAccountAStarted() async throws {
        try await reset()
        let accountA = api(historyEnabled: true)
        let accountB = api(user: "tv-queued-startup-other", historyEnabled: true)
        var mediaA = try await accountA.item("movie-1")
        mediaA.UserData = UserData(PlaybackPositionTicks: 80_000_000)
        let mediaB = try await accountB.item("movie-3")
        let gate = StartupGate()
        let player = PlaybackController(beforeInitialPlayback: { await gate.waitOnce() })
        player.present(mediaA, subtitle: 2, fromBeginning: true, mediaSourceID: "movie-1-source")
        player.start(api: accountA, quality: .original)
        do {
            try await gate.waitForEntry()
            try await assertNegotiatedEightSecondResume()
            player.present(mediaB, fromBeginning: true)
            player.start(api: accountB, quality: .original)
            let itemB = try await ready(player)
            XCTAssertLessThan(player.player.currentTime().seconds, 3)
            gate.release()
            await player.flushReports()
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(player.player.currentItem === itemB)
            XCTAssertEqual(player.activeItem?.id, mediaB.id)
            XCTAssertTrue(player.isPlaying)
            XCTAssertLessThan(player.player.currentTime().seconds, 3, "Canceled A must not seek B to A’s eight-second resume offset.")
            XCTAssertEqual(gate.entries, 2, "Each ready item owns a single startup operation.")
            let (_, value) = try await state()
            let starts = (value["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Sessions/Playing" }
            XCTAssertFalse(starts.contains { $0["user"] as? String == "tv-track-output" })
            XCTAssertEqual(starts.filter { $0["user"] as? String == "tv-queued-startup-other" }.count, 1)
            try await attachState("Canceled ready accountA cannot seek or start decoded accountB")
            player.stop(); await player.flushReports()
        } catch {
            player.stop(); gate.release(); await player.flushReports()
            throw error
        }
    }

    @MainActor private final class StartupGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var entries = 0

        func waitOnce() async {
            entries += 1
            guard entries == 1, !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func waitForEntry() async throws {
            for _ in 0..<150 {
                if entries > 0 { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("The real attached ready item did not enter its startup gate.")
            throw URLError(.timedOut)
        }

        func release() {
            released = true
            continuation?.resume(); continuation = nil
        }
    }

    private func assertNegotiatedEightSecondResume() async throws {
        let (_, value) = try await state()
        let negotiation = (value["reports"] as? [[String: Any]] ?? []).last { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }
        XCTAssertEqual((negotiation?["body"] as? [String: Any])?["StartTimeTicks"] as? Int, 80_000_000, "The canceled startup must have an armed eight-second seek before Stop or replacement.")
    }

    private func ready(_ player: PlaybackController) async throws -> AVPlayerItem {
        for _ in 0..<150 {
            if player.error != nil || (!player.preparing && player.isPlaying && player.player.currentTime().seconds > 0.5) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(player.error)
        XCTAssertGreaterThan(player.player.currentTime().seconds, 0.5)
        XCTAssertFalse(player.preparing)
        XCTAssertTrue(player.isPlaying)
        let item = try XCTUnwrap(player.player.currentItem)
        XCTAssertEqual(item.status, .readyToPlay)
        XCTAssertGreaterThan(item.presentationSize.width, 0)
        return item
    }

    private func reset() async throws {
        try await post("/qa/reset", [:])
        try await post("/qa/control", ["failReports": false, "failCleanup": false])
    }

    private func delay(_ enabled: Bool) async throws {
        try await post("/qa/tv-control", ["subtitleManifestDelay": enabled])
    }

    private func post(_ path: String, _ body: [String: Bool]) async throws {
        try TVFixture.requireQAHost()
        var request = try await TVFixture.request(server.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func state() async throws -> (Data, [String: Any]) {
        try TVFixture.requireQAHost()
        let (data, response) = try await URLSession.shared.data(for: try await TVFixture.request(server.appendingPathComponent("qa/state")))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return (data, try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }

    private func waitForMaster() async throws {
        for _ in 0..<100 {
            let (_, value) = try await state()
            if (value["trackRequests"] as? [[String: Any]] ?? []).contains(where: { ($0["path"] as? String)?.hasSuffix("master.m3u8") == true }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The delayed authenticated master request did not begin.")
        throw URLError(.timedOut)
    }

    private func attachState(_ name: String, expectedSession: String = "synthetic-track-session") async throws {
        let (data, value) = try await state()
        let cleanup = (value["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Videos/ActiveEncodings" }
        XCTAssertEqual(cleanup.count, 1, "Exactly the old owned accountA encoder must be released before the attached state.")
        XCTAssertEqual(cleanup.first?["user"] as? String, "tv-track-output")
        let resources = try XCTUnwrap(value["subtitleCleanups"] as? [[String: Any]])
        XCTAssertEqual(resources.count, 1)
        XCTAssertEqual(resources.first?["user"] as? String, "tv-track-output")
        XCTAssertEqual(resources.first?["deviceId"] as? [String], ["tv-subtitle-startup-qa"])
        XCTAssertEqual(resources.first?["playSessionId"] as? [String], [expectedSession])
        let receipt = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        receipt.name = name; receipt.lifetime = .keepAlways; add(receipt)
    }
    private struct Criteria: Equatable {
        let exists: Bool
        let languages: [String]?
        let characteristics: [String]?
        let principal: [String]?
    }
    private func criteria(_ value: AVPlayerMediaSelectionCriteria?) -> Criteria {
        Criteria(exists: value != nil, languages: value?.preferredLanguages,
                 characteristics: value?.preferredMediaCharacteristics?.map(\.rawValue),
                 principal: value?.principalMediaCharacteristics?.map(\.rawValue))
    }

}
