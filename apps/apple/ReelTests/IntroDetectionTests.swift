import Foundation
import XCTest
@testable import Reel

/// Programme-like audio: a new chord of three partials every 200 to 500 ms over faint noise. Each seed gives a
/// different, never-repeating sequence. Mirrors `apps/web/tests/synthetic-audio.ts`.
private func programme(_ seconds: Double, seed: UInt32, level: Float = 0.2) -> [Float] {
    var state = seed
    func next() -> Float {
        state &+= 0x6d2b79f5
        var t = (state ^ (state >> 15)) &* (1 | state)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Float(Double(t ^ (t >> 14)) / 4_294_967_296)
    }
    let rate = Float(AudioFingerprint.sampleRate)
    var out = [Float](repeating: 0, count: Int(seconds * AudioFingerprint.sampleRate))
    var i = 0
    while i < out.count {
        let length = Int((0.2 + next() * 0.3) * rate), partials = (0..<3).map { _ in 150 + next() * 2800 }
        var k = 0
        while k < length, i < out.count {
            let fade = min(1, Float(k) / 80, Float(length - k) / 80)
            let chord = partials.reduce(Float(0)) { $0 + sin(2 * Float.pi * $1 * Float(k) / rate) } / 3
            out[i] = level * fade * chord + (next() - 0.5) * 0.01
            k += 1; i += 1
        }
    }
    return out
}

private func mix(_ base: [Float], _ insert: [Float], at seconds: Double) -> [Float] {
    var out = base
    let offset = Int((seconds * AudioFingerprint.sampleRate).rounded())
    // Parts of `insert` before the start or past the end of `base` are dropped.
    for (index, value) in insert.enumerated() where offset + index >= 0 && offset + index < out.count { out[offset + index] = value }
    return out
}

private let theme = programme(40, seed: 99, level: 0.3)
private let creditsTheme = programme(50, seed: 77, level: 0.3)
private func near(_ actual: Double?, _ expected: Double) -> Bool { actual.map { abs($0 - expected) < 1 } ?? false }

final class AudioFingerprintTests: XCTestCase {
    func testFindsASharedThemeAtUnalignedPositions() {
        let a = AudioFingerprint.make(mix(programme(150, seed: 1), theme, at: 30.3))
        let b = AudioFingerprint.make(mix(programme(150, seed: 2), theme, at: 75.77))
        let run = AudioFingerprint.sharedRun(a, b, minSeconds: 15, maxSeconds: 150)
        XCTAssertTrue(near(run?.aStart, 30.3) && near(run?.aEnd, 70.3))
        XCTAssertTrue(near(run?.bStart, 75.77) && near(run?.bEnd, 115.77))
    }

    func testReportsNothingForUnrelatedEpisodesSilenceOrDuplicates() {
        for seed in stride(from: UInt32(20), to: 26, by: 2) {
            XCTAssertTrue(AudioFingerprint.sharedRun(AudioFingerprint.make(programme(120, seed: seed)), AudioFingerprint.make(programme(120, seed: seed + 1)), minSeconds: 15, maxSeconds: 150) == nil)
        }
        var silentA = programme(120, seed: 10), silentB = programme(120, seed: 11)
        silentA.replaceSubrange(16_000..<(16_000 + 480_000), with: [Float](repeating: 0, count: 480_000))
        silentB.replaceSubrange(160_000..<(160_000 + 480_000), with: [Float](repeating: 0, count: 480_000))
        XCTAssertTrue(AudioFingerprint.sharedRun(AudioFingerprint.make(silentA), AudioFingerprint.make(silentB), minSeconds: 15, maxSeconds: 150) == nil)
        let episode = AudioFingerprint.make(programme(200, seed: 12))
        XCTAssertTrue(AudioFingerprint.sharedRun(episode, episode, minSeconds: 15, maxSeconds: 150) == nil)
    }

    func testIgnoresSharedAudioShorterThanTheMinimum() {
        let sting = Array(theme.prefix(8 * 8000))
        let run = AudioFingerprint.sharedRun(AudioFingerprint.make(mix(programme(120, seed: 8), sting, at: 20)), AudioFingerprint.make(mix(programme(120, seed: 9), sting, at: 50)), minSeconds: 15, maxSeconds: 150)
        XCTAssertTrue(run == nil)
    }
}

/// Episodes of 600 seconds whose audio holds the shared theme at 10 + 7n seconds and the credits music at 530 + n.
private func episode(_ n: Int) -> MediaItem {
    var item = MediaItem(Id: "episode-\(n)", Name: "Episode \(n)")
    item.Type = "Episode"; item.SeriesId = "show"; item.RunTimeTicks = 600 * 10_000_000
    return item
}

private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(id: String, start: Double)] = []
    var requests: [(id: String, start: Double)] { lock.withLock { calls } }
    let status: Int?
    /// Sends the rest of the episode whatever window was asked for, as a server ignoring the bitrate could.
    let everything: Bool
    init(status: Int? = nil, everything: Bool = false) { self.status = status; self.everything = everything }

    func detector(defaults: UserDefaults) -> MarkerDetector {
        MarkerDetector(store: MarkerStore(defaults: defaults), fetch: { [self] _, item, start, _ in
            lock.withLock { calls.append((item.id, start)) }
            if let status { throw status == 403 ? ReelError.unauthorized : ReelError.server(status) }
            return Data("\(item.id)|\(start)".utf8)
        }, decode: { [everything] data in
            let parts = String(decoding: data, as: UTF8.self).split(separator: "|")
            let n = Int(parts[0].split(separator: "-")[1])!, start = Double(parts[1])!, seconds = start > 0 || everything ? 600 - start : 180
            var audio = programme(seconds, seed: UInt32(n * 1000) + UInt32(start))
            audio = mix(audio, theme, at: Double(10 + 7 * n) - start)
            if start > 0 || everything { audio = mix(audio, creditsTheme, at: Double(530 + n) - start) }
            return audio
        })
    }
}

private func freshDefaults() -> UserDefaults {
    let name = "reel-intro-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18793")!, token: "token", userID: "user", deviceID: "device")

final class MarkerDetectorTests: XCTestCase {
    func testScanWindowsFollowTheEpisodeLength() {
        XCTAssertTrue(MarkerDetector.headWindow(episode(1)) == (0, 180))
        XCTAssertTrue(MarkerDetector.tailWindow(episode(1))! == (480, 120))
        var long = episode(1); long.RunTimeTicks = 3600 * 10_000_000
        XCTAssertTrue(MarkerDetector.headWindow(long) == (0, 600))
        XCTAssertTrue(MarkerDetector.tailWindow(long)! == (3300, 300))
        var short = episode(1); short.RunTimeTicks = 200 * 10_000_000
        XCTAssertTrue(MarkerDetector.tailWindow(short) == nil)
    }

    func testFindsTheIntroAndCreditsAndLearnsTheNeighborsToo() async throws {
        let server = FakeServer(), detector = server.detector(defaults: freshDefaults())
        let found = try await detector.detect(api: api, item: episode(2), neighbors: [episode(3), episode(1)], intro: true, credits: true)
        XCTAssertTrue(near(found.intro?.lowerBound, 24) && near(found.intro?.upperBound, 64))
        XCTAssertTrue(near(found.credits, 532))
        XCTAssertTrue(server.requests.map(\.id) == ["episode-2", "episode-3", "episode-2", "episode-3"])
        XCTAssertTrue(server.requests.map(\.start) == [0, 0, 480, 480])
        let neighbor = detector.known(accountID: MarkerDetector.accountID(api), item: episode(3))
        XCTAssertTrue(near(neighbor.intro?.lowerBound, 31) && near(neighbor.credits, 533))
        XCTAssertTrue(detector.known(accountID: "another|account", item: episode(3)) == FoundMarkers())
        // What is known is not scanned again.
        _ = try await detector.detect(api: api, item: episode(3), neighbors: [episode(4)], intro: true, credits: true)
        XCTAssertTrue(server.requests.count == 4)
    }

    func testAScanReadsOnlyItsOwnWindowWhenTheServerSendsMore() async throws {
        // Past the opening window the credits music would be found and taken for the intro.
        let server = FakeServer(everything: true), detector = server.detector(defaults: freshDefaults())
        let found = try await detector.detect(api: api, item: episode(2), neighbors: [episode(1)], intro: true, credits: true)
        XCTAssertTrue(near(found.intro?.lowerBound, 24) && near(found.intro?.upperBound, 64), "intro \(String(describing: found.intro))")
        XCTAssertTrue(near(found.credits, 532))
    }

    func testARefusingServerIsNotAskedAgain() async throws {
        let server = FakeServer(status: 403), detector = server.detector(defaults: freshDefaults())
        let first = try await detector.detect(api: api, item: episode(2), neighbors: [episode(1)], intro: true, credits: true)
        let second = try await detector.detect(api: api, item: episode(4), neighbors: [episode(3)], intro: true, credits: true)
        XCTAssertEqual(first, FoundMarkers()); XCTAssertEqual(second, FoundMarkers())
        XCTAssertTrue(server.requests.count == 1)
    }

    func testFoundMarkersBecomeSegmentsOnlyWhereTheServerHasNone() {
        let found = FoundMarkers(intro: 24...64, credits: 532)
        let both = found.segments(runtimeTicks: 600 * 10_000_000, server: [])
        XCTAssertTrue(both.map(\.Type) == ["Intro", "Outro"])
        XCTAssertTrue(both[0].StartTicks == 240_000_000 && both[0].EndTicks == 640_000_000)
        XCTAssertTrue(both[1].StartTicks == 5_320_000_000 && both[1].EndTicks == 6_000_000_000)
        let server = [MediaSegment(Id: "server", Type: "Intro", StartTicks: 0, EndTicks: 10)]
        XCTAssertTrue(found.segments(runtimeTicks: 600 * 10_000_000, server: server).map(\.Type) == ["Outro"])
    }

    func testMarkerStoreExpiresMissesSoonerAndForgetsAnAccount() {
        let defaults = freshDefaults(), start = Date(timeIntervalSince1970: 1_790_000_000), day = 86_400.0
        let store = MarkerStore(defaults: defaults)
        store.update("a|found", now: start) { $0.i = [5, 50] }
        store.update("a|missing", now: start) { $0.i = [] }
        store.update("b|found", now: start) { $0.c = 1200 }
        let reloaded = MarkerStore(defaults: defaults)
        XCTAssertTrue(reloaded.get("a|found", now: start.addingTimeInterval(100 * day))?.i == [5, 50])
        XCTAssertTrue(reloaded.get("a|missing", now: start.addingTimeInterval(13 * day))?.i == [])
        XCTAssertTrue(reloaded.get("a|missing", now: start.addingTimeInterval(15 * day)) == nil)
        reloaded.forget(accountID: "a")
        XCTAssertTrue(MarkerStore(defaults: defaults).get("a|found", now: start) == nil)
        XCTAssertTrue(MarkerStore(defaults: defaults).get("b|found", now: start)?.c == 1200)
    }

    func testADownloadStoppedMidFrameIsCutBackToWholeFrames() {
        // MPEG-2 Layer III, 32 kbps at 16 kHz: 144 bytes a frame, 145 with the padding bit.
        func frame(_ padding: UInt8) -> [UInt8] { [0xff, 0xf3, 0x48 | padding, 0xc4] + [UInt8](repeating: 0x11, count: 140 + Int(padding / 2)) }
        var lookalike = frame(0); lookalike.replaceSubrange(40..<44, with: [0xff, 0xf3, 0x18, 0xc4])
        let id3: [UInt8] = [0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 2, 0xaa, 0xbb]
        let bytes = id3 + frame(0) + lookalike + frame(2) + Array(frame(0).prefix(60))
        XCTAssertTrue(MarkerDetector.wholeFrames(Data(bytes)).count == id3.count + 144 + 144 + 145)
        XCTAssertTrue(MarkerDetector.frameLength(frame(2), at: 0) == 145)
        XCTAssertTrue(MarkerDetector.wholeFrames(Data("not audio".utf8)) == Data("not audio".utf8))
    }
}
