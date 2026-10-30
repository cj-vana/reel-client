import XCTest
@testable import Reel

final class LiveTVTests: XCTestCase {
    private func fixture(_ user: String) -> JellyfinAPI {
        JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-" + user, userID: user, deviceID: "livetv-tests")
    }
    private func upcoming(series: Bool = true) -> LiveTVProgram {
        LiveTVProgram(Id: "program-test", Name: "A test program", ChannelId: "channel-test", StartDate: LiveTVDate.string(.now.addingTimeInterval(3_600)), EndDate: LiveTVDate.string(.now.addingTimeInterval(7_200)), IsSeries: series)
    }

    func testGuideDatesParseFractionalUTCAndRespectDaylightSaving() throws {
        XCTAssertEqual(LiveTVDate.parse("2026-10-23T12:00:00Z"), LiveTVDate.parse("2026-10-23T12:00:00.0000000Z"))
        XCTAssertNil(LiveTVDate.parse("invalid"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        let springDay = try XCTUnwrap(LiveTVDate.parse("2026-03-08T12:00:00Z"))
        let interval = LiveTVDate.interval(for: springDay, calendar: calendar)
        XCTAssertEqual(interval.duration, 23 * 3_600)
        XCTAssertEqual(calendar.component(.hour, from: interval.start), 0)
        XCTAssertEqual(calendar.component(.day, from: interval.end), 9)
    }

    func testRecordingDraftPreservesProviderDefaultsAndRejectsInvalidPrograms() throws {
        let data = Data(#"{"Id":"default-id","PrePaddingSeconds":120,"PostPaddingSeconds":180,"RecordNewOnly":true,"RecordAnyTime":true,"Days":["Monday","Tuesday"],"ProviderDefault":{"keep":"provider-value"}}"#.utf8)
        var draft = try JSONDecoder().decode(LiveTVRecordingDraft.self, from: data)
        XCTAssertEqual(draft.prePaddingMinutes, 2)
        XCTAssertEqual(draft.postPaddingMinutes, 3)
        draft.postPaddingMinutes = 10
        draft.newEpisodesOnly = false
        let single = try draft.creating(program: upcoming(), series: false)
        XCTAssertNil(single.values["Id"])
        XCTAssertEqual(single.values["Type"], .string("Timer"))
        XCTAssertEqual(single.values["PostPaddingSeconds"], .number(600))
        XCTAssertEqual(single.values["ProviderDefault"], .object(["keep": .string("provider-value")]))
        let series = try draft.creating(program: upcoming(), series: true)
        XCTAssertEqual(series.values["RecordNewOnly"], .bool(false))
        XCTAssertEqual(series.values["Days"], .array([.string("Monday"), .string("Tuesday")]))
        let encoded = try JSONEncoder().encode(series)
        XCTAssertEqual(try JSONDecoder().decode(LiveTVRecordingDraft.self, from: encoded), series)
        XCTAssertThrowsError(try draft.creating(program: upcoming(series: false), series: true))
        var ended = upcoming()
        ended.EndDate = LiveTVDate.string(.now.addingTimeInterval(-1))
        XCTAssertThrowsError(try draft.creating(program: ended, series: false))
        var malformed = upcoming()
        malformed.ChannelId = nil
        XCTAssertThrowsError(try draft.creating(program: malformed, series: false))
    }

    func testGuideRecordingSeriesAndCancellationContract() async throws {
        let user = "livetv-" + UUID().uuidString
        let api = fixture(user)
        let service = LiveTVAPI(api: api)
        let permissions = try await service.permissions()
        XCTAssertEqual(permissions.Policy?.EnableLiveTvManagement, true)
        let guide = try await service.guide(date: .now)
        XCTAssertFalse(guide.Items.isEmpty)
        let program = try await service.program("program-2")
        XCTAssertTrue(program.canRecord())
        XCTAssertEqual(program.IsSeries, true)
        var draft = try await service.defaults(program: program)
        draft.prePaddingMinutes = 5
        try await service.schedule(program: program, draft: draft, series: false)
        let timers = try await service.timers()
        let timer = try XCTUnwrap(timers.first { $0.ProgramId == program.id })
        let refreshed = try await service.program(program.id)
        XCTAssertEqual(refreshed.TimerId, timer.id)
        try await service.cancel(timer, series: false)
        let afterCancellation = try await service.timers()
        XCTAssertFalse(afterCancellation.contains { $0.id == timer.id })
        try await service.schedule(program: program, draft: draft, series: true)
        let rules = try await service.series()
        let rule = try XCTUnwrap(rules.first { $0.Name == program.Name })
        let seriesProgram = try await service.program(program.id)
        XCTAssertEqual(seriesProgram.SeriesTimerId, rule.id)
        try await service.cancel(rule, series: true)
        let remainingRules = try await service.series()
        XCTAssertFalse(remainingRules.contains { $0.id == rule.id })
        let recordings = try await service.recordings()
        XCTAssertEqual(recordings.Items.first?.id, "recording-1")
        let recording = try await api.item("recording-1")
        XCTAssertEqual(recording.Type, "Movie")
        let state = try await api.send(api.request("qa/state"))
        let json = try JSONSerialization.jsonObject(with: state) as! [String: Any]
        let reports = json["reports"] as! [[String: Any]]
        XCTAssertFalse(reports.contains { ($0["user"] as? String) == user && ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
    }

    @MainActor func testReadOnlyRecordingPermissionFailsWithoutChangingState() async throws {
        let api = fixture("readonlytv")
        let store = LiveTVStore()
        await store.loadPermissions(api: api)
        XCTAssertFalse(store.canManage(api: api))
        let service = LiveTVAPI(api: api)
        let program = try await service.program("program-2")
        let draft = try await service.defaults(program: program)
        do { try await service.schedule(program: program, draft: draft, series: false); XCTFail("Read-only account scheduled recording") }
        catch { XCTAssertEqual(error as? ReelError, .unauthorized) }
        let timers = try await service.timers()
        XCTAssertTrue(timers.isEmpty)
        let guide = try await service.guide(date: .now, channelID: "missing")
        XCTAssertTrue(guide.Items.isEmpty)
    }

    func testSimulatorProtectsProductionDVRMutationsBeforeNetwork() async throws {
        let api = JellyfinAPI(server: URL(string: "http://192.0.2.10:8096")!, token: "fixture-invalid", userID: "test", deviceID: "livetv-protection")
        guard api.isSimulatorPreview else { throw XCTSkip("Simulator-only history protection test") }
        let service = LiveTVAPI(api: api)
        for series in [false, true] {
            do { try await service.schedule(program: upcoming(), draft: LiveTVRecordingDraft(), series: series); XCTFail("Production DVR write passed simulator guard") }
            catch { XCTAssertEqual(error as? ReelError, .previewProtected) }
        }
    }
}
