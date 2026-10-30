import AVFoundation
import XCTest
@testable import Reel

@MainActor final class PlaybackSeekingTests: XCTestCase {
    func testNativeSeeksReachRequestedPositionsAndReportTheCompletedTarget() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Native fixture playback requires the disposable simulator and loopback server.")
        #else
        let user = "precise-seek-" + UUID().uuidString
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-" + user, userID: user, deviceID: "precise-seek-test")
        let item = try await api.item("movie-3")
        let controller = PlaybackController()
        defer { controller.stop() }
        controller.present(item, fromBeginning: true)
        controller.start(api: api, quality: .original)
        for _ in 0..<100 {
            if !controller.preparing { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(controller.preparing)
        XCTAssertNil(controller.error)
        XCTAssertEqual(controller.player.currentItem?.status, .readyToPlay)
        controller.player.pause()

        controller.seek(to: 52_500_000)
        try await expectPosition(5.25, controller: controller)
        try await expectProgress(5.25, controller: controller, user: user, server: api.server)
        controller.skip(3.5)
        try await expectPosition(8.75, controller: controller)
        try await expectProgress(8.75, controller: controller, user: user, server: api.server)
        controller.skip(-6.5)
        try await expectPosition(2.25, controller: controller)
        try await expectProgress(2.25, controller: controller, user: user, server: api.server)
        controller.seek(to: 80_000_000)
        try await expectPosition(8, controller: controller)
        try await expectProgress(8, controller: controller, user: user, server: api.server)

        controller.skip(-30)
        try await expectPosition(0, controller: controller)
        controller.stop()
        await controller.flushReports()
        #endif
    }

    private func expectPosition(_ expected: Double, controller: PlaybackController) async throws {
        for _ in 0..<60 {
            let current = controller.player.currentTime().seconds
            if current.isFinite && abs(current - expected) < 0.12 {
                XCTAssertEqual(controller.player.currentTime().seconds, expected, accuracy: 0.12)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Native position \(controller.player.currentTime().seconds) did not reach \(expected).")
    }

    private func expectProgress(_ expected: Double, controller: PlaybackController, user: String, server: URL) async throws {
        for _ in 0..<60 {
            await controller.flushReports()
            let (data, _) = try await URLSession.shared.data(from: server.appendingPathComponent("qa/state"))
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let reports = try XCTUnwrap(state["reports"] as? [[String: Any]])
            let progress = reports.filter { ($0["user"] as? String) == user && ($0["path"] as? String) == "/Sessions/Playing/Progress" }
            if let body = progress.last?["body"] as? [String: Any], let ticks = body["PositionTicks"] as? NSNumber,
               abs(ticks.doubleValue / ticksPerSecond - expected) < 0.15 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("No completed-seek progress receipt reached \(expected).")
    }
}
