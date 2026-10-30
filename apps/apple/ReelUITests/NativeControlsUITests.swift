import XCTest
import UIKit

@MainActor final class NativeControlsUITests: XCTestCase {
    private var app = XCUIApplication()
    private var user = ""

    private func launch(_ prefix: String = "native-controls", userOverride: String? = nil, textCategory: String? = nil) throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Account-reset control coverage uses a disposable simulator and loopback fixtures.")
        #else
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        user = userOverride ?? prefix + "-" + String(UUID().uuidString.prefix(8))
        app = XCUIApplication()
        app.launchArguments = ["-reel-qa-reset"]
        if let textCategory { app.launchArguments += ["-UIPreferredContentSizeCategoryName", textCategory] }
        app.launchEnvironment["REEL_QA_SERVER"] = "http://127.0.0.1:18766"
        app.launch()
        if prefix == "final-brand" { attach("native-final-brand-connect") }
        let username = app.textFields["username"]
        reveal(username)
        XCTAssertTrue(username.waitForExistence(timeout: 8))
        username.tap(); username.typeText(user)
        app.secureTextFields["password"].tap(); app.secureTextFields["password"].typeText("demo")
        tap("connect")
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        #endif
    }

    private func reveal(_ element: XCUIElement, down: Bool = false) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            if down { app.swipeDown() } else { app.swipeUp() }
        }
    }

    private func tap(_ identifier: String) {
        app.prepareReelPlayerControl(identifier)
        let button = app.buttons[identifier].firstMatch
        reveal(button, down: ["Done", "hubClosePlayer", "hubCloseLyrics", "hubCloseReader", "hubClosePhoto"].contains(identifier))
        XCTAssertTrue(button.waitForExistence(timeout: 8), "\(identifier)\n\(app.debugDescription)")
        button.tap()
    }

    private func more(_ title: String) {
        let root = app.buttons["ellipsis.circle"].firstMatch
        if !root.exists, app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        root.tap()
        if !app.navigationBars["More"].waitForExistence(timeout: 2) { root.tap() }
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
        tap(title)
    }

    private func back() {
        let button = app.buttons["BackButton"].firstMatch
        if button.exists { button.tap() }
        else { XCTAssertTrue(app.navigationBars.buttons.firstMatch.exists); app.navigationBars.buttons.firstMatch.tap() }
    }

    private func replace(_ field: XCUIElement, with value: String) {
        reveal(field, down: true); field.tap(); field.press(forDuration: 1)
        if app.menuItems["Select All"].waitForExistence(timeout: 1) { app.menuItems["Select All"].tap() }
        else if app.buttons["Select All"].exists { app.buttons["Select All"].tap() }
        else { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 180)) }
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        if !value.isEmpty { field.typeText(value) }
        if app.keyboards.buttons["Search"].isHittable { app.keyboards.buttons["Search"].tap() }
    }

    private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 8) async {
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
    }

    private func readyAudio() async {
        let button = app.buttons["hubToggle"]
        XCTAssertTrue(button.waitForExistence(timeout: 12))
        await wait(NSPredicate(format: "enabled == true"), on: button, timeout: 20)
    }

    private func pauseAudio() async {
        await readyAudio()
        if app.buttons["hubToggle"].label == "Pause music" { tap("hubToggle") }
        XCTAssertEqual(app.buttons["hubToggle"].label, "Play music")
    }

    private func title(_ value: String) async {
        await wait(NSPredicate(format: "label == %@", value), on: app.staticTexts["hubCurrentTitle"])
    }

    private func toggle(_ label: String) async {
        let wrapper = app.switches[label].firstMatch
        reveal(wrapper)
        let previous = wrapper.value as? String
        let control = wrapper.switches.firstMatch
        if control.exists { control.tap() } else { wrapper.tap() }
        if let previous { await wait(NSPredicate(format: "value != %@", previous), on: wrapper) }
    }

    private func increment(_ identifier: String) async {
        let stepper = app.steppers[identifier]
        reveal(stepper)
        XCTAssertTrue(stepper.waitForExistence(timeout: 5), app.debugDescription)
        guard let previous = Int(stepper.value as? String ?? "") else { XCTFail("Missing native stepper value"); return }
        let down = stepper.buttons[identifier + "-Decrement"]
        let up = stepper.buttons[identifier + "-Increment"]
        XCTAssertTrue(down.exists); XCTAssertTrue(up.exists)
        for value in stride(from: previous - 1, through: 0, by: -1) {
            down.tap(); await wait(NSPredicate(format: "value == %@", String(value)), on: stepper)
        }
        XCTAssertFalse(down.isEnabled, "Padding cannot be negative.")
        for value in 1...(previous + 1) {
            up.tap(); await wait(NSPredicate(format: "value == %@", String(value)), on: stepper)
        }
    }

    private func attach(_ name: String) {
        let value = XCTAttachment(screenshot: app.screenshot()); value.name = name; value.lifetime = .keepAlways; add(value)
    }

    private func json(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18766" + path)!)
        if !user.isEmpty { request.setValue("MediaBrowser Token=\"fixture-\(user)\"", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0))
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func tvState() async throws -> [String: Any] {
        let all = try await json("/qa/state")
        return (all["livetv"] as? [String: Any])?[user] as? [String: Any] ?? [:]
    }

    private func reportCount() async throws -> Int { (try await json("/qa/state")["reports"] as? [[String: Any]])?.count ?? 0 }

    private func assertAudioSeek(item: String, seconds: Double, after index: Int) async throws {
        var found = false
        for _ in 0..<25 {
            let state = try await json("/qa/state")
            let reports = state["reports"] as? [[String: Any]] ?? []
            found = reports.dropFirst(index).contains { report in
                guard report["user"] as? String == user, report["path"] as? String == "/Sessions/Playing/Progress",
                      let body = report["body"] as? [String: Any], body["ItemId"] as? String == item,
                      let ticks = body["PositionTicks"] as? NSNumber else { return false }
                return abs(ticks.doubleValue / 10_000_000 - seconds) < 1
            }
            if found { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(found, "No native audio progress receipt for \(item) at \(seconds) seconds")
    }

    private func cancelConfirmation() {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
        else {
            let outside = (app.otherElements.matching(identifier: "PopoverDismissRegion").allElementsBoundByIndex.last ?? app.otherElements["PopoverDismissRegion"])
            XCTAssertTrue(outside.waitForExistence(timeout: 3), app.debugDescription)
            let bar = app.navigationBars.allElementsBoundByIndex.last ?? app.navigationBars.firstMatch
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
        }
    }

    private func guideQuery() async throws -> [String: String] {
        let state = try await tvState()
        return (state["requests"] as? [[String: Any]])?.last(where: { $0["path"] as? String == "/LiveTv/Programs" })?["query"] as? [String: String] ?? [:]
    }

    private func waitForGuideDate(_ value: String, equal: Bool) async throws {
        var received = ""
        for _ in 0..<30 {
            received = try await guideQuery()["minenddate"] ?? ""
            if !received.isEmpty && (received == value) == equal { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTFail("Guide request date did not satisfy equality=\(equal): expected \(value), got \(received)")
    }

    private func scrubAudio(_ slider: XCUIElement, item: String) async throws {
        let before = try await reportCount()
        slider.adjust(toNormalizedSliderPosition: 0.25)
        let selected = Double(slider.normalizedSliderPosition) * 120
        XCTAssertGreaterThan(selected, 15, "The native gesture must move the audio position.")
        XCTAssertLessThan(selected, 80)
        try await assertAudioSeek(item: item, seconds: selected, after: before)
    }

    private func dismissShare() async {
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 8), app.debugDescription)
        attach("native-control-share")
        if app.otherElements["PopoverDismissRegion"].exists { app.otherElements["PopoverDismissRegion"].tap() }
        else if app.buttons["Close"].exists { app.buttons["Close"].tap() }
        else { XCTAssertTrue(app.buttons["Cancel"].exists); app.buttons["Cancel"].tap() }
        await wait(NSPredicate(format: "exists == false"), on: sheet)
    }

    func testFinalBrandConnectHomeSettingsAndDownloads() throws {
        try launch("final-brand")
        attach("native-final-brand-home-header")
        tap("Downloads")
        XCTAssertTrue(app.staticTexts["downloadsEmpty"].waitForExistence(timeout: 8))
        attach("native-final-brand-downloads")
        more("Settings")
        app.swipeUp(); app.swipeUp(); app.swipeUp()
        attach("native-final-brand-settings-footer")
        tap("Home")
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 8))
    }

    func testGuideDateChannelOptionsAndKeepCancellation() async throws {
        try launch("dvr-options"); more("Live TV"); tap("tv-Guide")
        let date = app.descendants(matching: .any).matching(identifier: "guideDate").firstMatch
        XCTAssertTrue(date.waitForExistence(timeout: 8))
        let today = try await guideQuery()["minenddate"] ?? ""
        XCTAssertFalse(today.isEmpty)
        tap("Next guide day"); try await waitForGuideDate(today, equal: false)
        XCTAssertTrue(app.buttons["program-program-2"].waitForExistence(timeout: 8))
        tap("Previous guide day"); try await waitForGuideDate(today, equal: true)
        tap("Next guide day"); tap("Today"); try await waitForGuideDate(today, equal: true)
        date.tap()
        let calendarSnapshot = XCTAttachment(string: app.debugDescription)
        calendarSnapshot.name = "native-guide-calendar-hierarchy"; calendarSnapshot.lifetime = .keepAlways; add(calendarSnapshot)
        attach("native-guide-calendar")
        let target = Calendar.current.date(byAdding: .day, value: 3, to: Date())!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US"); formatter.dateFormat = "EEEE, MMMM d"
        let day = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", formatter.string(from: target))).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 3), app.debugDescription); day.tap()
        let dismissCalendar = app.buttons["PopoverDismissRegion"]
        XCTAssertTrue(dismissCalendar.waitForExistence(timeout: 3), app.debugDescription)
        dismissCalendar.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.05)).tap()
        await wait(NSPredicate(format: "exists == false"), on: day)
        try await waitForGuideDate(today, equal: false)
        tap("Today"); try await waitForGuideDate(today, equal: true)
        tap("guideChannel"); tap("Reel Test TV")
        XCTAssertTrue(app.buttons["program-program-2"].waitForExistence(timeout: 8))
        tap("guideChannel"); tap("All channels"); tap("refreshLiveTV")
        tap("program-program-2")
        XCTAssertTrue(app.staticTexts["programTitle"].waitForExistence(timeout: 8))
        await increment("recordingPrePadding"); await increment("recordingPostPadding")
        for label in ["New episodes only", "Any channel", "Any time", "Skip episodes already in library"] { await toggle(label) }
        tap("recordSeries"); cancelConfirmation()
        XCTAssertTrue(app.buttons["recordSeries"].isEnabled)
        let beforeScheduling = try await tvState()
        XCTAssertEqual((beforeScheduling["events"] as? [[String: Any]])?.count, 0)
        tap("recordSeries"); tap("Schedule series")
        XCTAssertTrue(app.staticTexts["Series rule created"].waitForExistence(timeout: 8))
        let state = try await tvState()
        let event = (state["events"] as? [[String: Any]])?.last
        let payload = event?["body"] as? [String: Any]
        XCTAssertEqual(payload?["PrePaddingSeconds"] as? Int, 120)
        XCTAssertEqual(payload?["PostPaddingSeconds"] as? Int, 240)
        XCTAssertEqual(payload?["RecordNewOnly"] as? Bool, false)
        XCTAssertEqual(payload?["RecordAnyChannel"] as? Bool, true)
        XCTAssertEqual(payload?["RecordAnyTime"] as? Bool, false)
        XCTAssertEqual(payload?["SkipEpisodesInLibrary"] as? Bool, false)
        XCTAssertEqual((payload?["ProviderDefault"] as? [String: String])?["keep"], "fixture-default")
        tap("Done"); tap("tv-Series rules"); tap("cancelSeries-series-1"); cancelConfirmation()
        XCTAssertTrue(app.buttons["cancelSeries-series-1"].exists)
        let retainedRule = try await tvState()
        XCTAssertEqual((retainedRule["series"] as? [String: Any])?.count, 1)
        tap("cancelSeries-series-1"); tap("Cancel series rule")
        await wait(NSPredicate(format: "exists == false"), on: app.buttons["cancelSeries-series-1"])
        XCTAssertTrue(app.staticTexts["No series rules"].waitForExistence(timeout: 8))
        tap("tv-Scheduled"); XCTAssertTrue(app.staticTexts["Nothing scheduled"].waitForExistence(timeout: 8))
    }

    func testMusicSeekLyricsRepeatQueueMiniPlayerAndSavedOriginal() async throws {
        try launch("music-controls"); more("Media"); tap("hub-Audio"); tap("hub-audio-hub-track-1")
        await pauseAudio(); await title("First signal")
        let slider = app.sliders["hubSeek"]; reveal(slider)
        try await scrubAudio(slider, item: "hub-track-1")
        let beforeLyric = try await reportCount()
        tap("hubLyrics"); tap("hub-lyric-1"); tap("hubCloseLyrics")
        try await assertAudioSeek(item: "hub-track-1", seconds: 10, after: beforeLyric)
        let repeatButton = app.buttons["hubRepeat"]
        if repeatButton.label != "Repeat on" { tap("hubRepeat") }
        XCTAssertEqual(repeatButton.label, "Repeat on")
        tap("hubSpeed"); tap("1.25×"); XCTAssertTrue(app.buttons["hubSpeed"].label.contains("1.25"))
        tap("hub-queue-1"); await title("Second signal"); await pauseAudio()
        reveal(slider)
        try await scrubAudio(slider, item: "hub-track-2")
        let beforeRestart = try await reportCount(); tap("hubPrevious")
        await title("Second signal")
        try await assertAudioSeek(item: "hub-track-2", seconds: 0, after: beforeRestart)
        tap("hubPrevious"); await title("First signal")
        tap("hubNext"); await title("Second signal")
        tap("hubNext"); await title("First signal")
        tap("hubRepeat"); XCTAssertEqual(repeatButton.label, "Repeat off")
        await pauseAudio(); tap("hubClosePlayer")
        let mini = app.buttons["hubMiniToggle"]
        XCTAssertEqual(mini.label, "Play music"); mini.tap(); XCTAssertEqual(mini.label, "Pause music")
        tap("Next track"); tap("hubNowPlaying"); await title("Second signal"); await pauseAudio(); tap("hubClosePlayer")
        tap("hub-audio-options-hub-track-1"); tap("Save original for offline")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "hub-save-status-hub-track-1").firstMatch.waitForExistence(timeout: 15))
        tap("hub-audio-options-hub-track-1"); tap("Export saved original"); await dismissShare()
        more("Media"); tap("hub-saved"); tap("hub-saved-hub-track-1")
        await title("First signal"); await pauseAudio(); tap("hubClosePlayer")
        tap("hub-saved-options-hub-track-1"); tap("Remove saved file"); cancelConfirmation()
        XCTAssertTrue(app.buttons["hub-saved-hub-track-1"].exists)
        tap("hub-saved-options-hub-track-1"); tap("Remove saved file"); tap("hubConfirmRemoveSaved")
        await wait(NSPredicate(format: "exists == false"), on: app.buttons["hub-saved-hub-track-1"])
        XCTAssertTrue(app.staticTexts["Take it with you"].exists)
    }

    func testSingleRecordingCancelKeepAndProgramWatchLive() async throws {
        try launch("dvr-single"); more("Live TV"); tap("tv-Guide"); tap("program-program-1"); tap("watchProgramLive")
        let transport = app.reelPlaybackButton("transportPlayPause")
        XCTAssertTrue(transport.waitForExistence(timeout: 12))
        await wait(NSPredicate(format: "enabled == true"), on: transport, timeout: 20)
        tap("closePlayer")
        XCTAssertTrue(app.buttons["program-program-3"].waitForExistence(timeout: 8)); tap("program-program-3")
        tap("recordProgram"); cancelConfirmation()
        let beforeScheduling = try await tvState()
        XCTAssertEqual((beforeScheduling["events"] as? [[String: Any]])?.count, 0)
        tap("recordProgram"); tap("Schedule recording")
        XCTAssertTrue(app.staticTexts["Recording scheduled"].waitForExistence(timeout: 8)); tap("Done")
        tap("tv-Scheduled"); tap("cancelTimer-timer-1"); cancelConfirmation()
        XCTAssertTrue(app.buttons["cancelTimer-timer-1"].exists)
        let retained = try await tvState()
        XCTAssertEqual((retained["timers"] as? [String: Any])?.count, 1)
        tap("cancelTimer-timer-1"); tap("Cancel recording")
        await wait(NSPredicate(format: "exists == false"), on: app.buttons["cancelTimer-timer-1"])
        XCTAssertTrue(app.staticTexts["Nothing scheduled"].exists)
    }

    func testDVRReadOnlyAndNoAccessStatesRemainUsable() throws {
        try launch(userOverride: "readonlytv"); more("Live TV"); tap("tv-Guide"); tap("program-program-2")
        let explanation = app.staticTexts["Recording management needs permission from your Jellyfin administrator."]
        reveal(explanation)
        XCTAssertTrue(explanation.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["recordProgram"].exists); XCTAssertFalse(app.buttons["recordSeries"].exists)
        tap("Done"); tap("refreshLiveTV")
        XCTAssertTrue(app.buttons["program-program-2"].waitForExistence(timeout: 8))
        try launch(userOverride: "notv"); more("Live TV")
        XCTAssertTrue(app.staticTexts["No channels yet"].waitForExistence(timeout: 8))
        tap("tv-Guide"); XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 8))
        tap("retry"); XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["program-program-2"].exists)
        tap("tv-Channels"); XCTAssertTrue(app.staticTexts["No channels yet"].waitForExistence(timeout: 8))
    }

    func testArtistPlaylistShuffleAndAudiobookChapters() async throws {
        try launch("hub-browse"); more("Media"); tap("hub-MusicArtist"); tap("hub-item-hub-artist-1"); tap("hub-item-hub-album-1")
        XCTAssertTrue(app.buttons["hub-audio-hub-track-1"].waitForExistence(timeout: 8))
        more("Media"); tap("hub-Playlist"); tap("hub-item-hub-playlist-1")
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        tap("hubPlayAll"); await title("Second signal"); await readyAudio()
        tap("hubNext"); await title("First signal"); await pauseAudio(); tap("hubClosePlayer")
        tap("hubShuffle"); await readyAudio()
        XCTAssertTrue(["First signal", "Second signal"].contains(app.staticTexts["hubCurrentTitle"].label))
        reveal(app.buttons["hub-queue-1"])
        XCTAssertTrue(app.buttons["hub-queue-0"].exists); XCTAssertTrue(app.buttons["hub-queue-1"].exists)
        XCTAssertFalse(app.buttons["hub-queue-2"].exists)
        await pauseAudio(); tap("hubClosePlayer")
        more("Media"); tap("hub-AudioBook"); tap("hub-audio-hub-audiobook-1")
        await pauseAudio(); let beforeChapter = try await reportCount(); tap("hubChapters"); tap("A second step")
        try await assertAudioSeek(item: "hub-audiobook-1", seconds: 10, after: beforeChapter)
        attach("native-audiobook-chapter"); tap("hubClosePlayer")
    }

    func testPhotoZoomPanPagingAndReaderPagePersistence() async throws {
        try launch("photo-reader"); more("Media"); tap("hub-Photo"); tap("hub-photo-hub-photo-1")
        let photo = app.images["hubFullPhoto-hub-photo-1"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10)); attach("native-photo-before-zoom")
        photo.tap(withNumberOfTaps: 2, numberOfTouches: 1); attach("native-photo-after-double-tap")
        photo.swipeLeft(); XCTAssertTrue(photo.exists); attach("native-photo-panned")
        photo.tap(withNumberOfTaps: 2, numberOfTouches: 1)
        photo.pinch(withScale: 1.7, velocity: 1); attach("native-photo-after-pinch")
        photo.swipeUp(); attach("native-photo-vertical-pan"); photo.tap(withNumberOfTaps: 2, numberOfTouches: 1); attach("native-photo-reset")
        app.swipeLeft(); XCTAssertTrue(app.images["hubFullPhoto-hub-photo-2"].waitForExistence(timeout: 8))
        app.swipeRight(); XCTAssertTrue(photo.waitForExistence(timeout: 8)); tap("hubClosePhoto")
        more("Media"); tap("hub-Book"); tap("hub-book-hub-book-1"); tap("hubSaveBook"); tap("hubOpenBook")
        let secondPage = app.staticTexts["Page two - your place can be restored."]
        reveal(secondPage)
        XCTAssertTrue(secondPage.isHittable, app.debugDescription)
        app.otherElements["hubPDFReader"].swipeUp()
        attach("native-pdf-page-two"); try await Task.sleep(for: .milliseconds(500))
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        more("Media"); tap("hub-saved"); tap("hub-saved-hub-book-1")
        XCTAssertTrue(app.otherElements["hubPDFReader"].waitForExistence(timeout: 8))
        XCTAssertTrue(secondPage.isHittable, "The PDF reader should restore page two after relaunch.\n\(app.debugDescription)")
        attach("native-pdf-page-two-restored"); tap("hubCloseReader")
    }

    func testReadOnlyDVRAccountCanPlayRecordingWithoutManagementWrites() async throws {
        try launch("readonly-recording", userOverride: "readonlytv")
        more("Live TV"); tap("tv-Guide"); tap("program-program-2")
        let permission = app.staticTexts["Recording management needs permission from your Jellyfin administrator."]
        reveal(permission)
        XCTAssertTrue(permission.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["recordProgram"].exists)
        XCTAssertFalse(app.buttons["recordSeries"].exists)
        tap("Done"); tap("tv-Recordings")
        let before = try await tvState()["events"] as? [[String: Any]] ?? []
        attach("native-readonly-recording-row")
        tap("recording-recording-1")
        let transport = app.reelPlaybackButton("transportPlayPause")
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        await wait(NSPredicate(format: "enabled == true"), on: transport, timeout: 25)
        if transport.label == "Pause" { tap("transportPlayPause") }
        XCTAssertEqual(transport.label, "Play")
        let reports = try await json("/qa/state")["reports"] as? [[String: Any]] ?? []
        XCTAssertTrue(reports.contains { $0["user"] as? String == user && $0["path"] as? String == "/Items/recording-1/PlaybackInfo" })
        attach("native-readonly-recorded-playback"); tap("closePlayer")
        let after = try await tvState()["events"] as? [[String: Any]] ?? []
        XCTAssertEqual(after.count, before.count, "Watching a recording must not create or cancel DVR rules")
    }

    func testRecordingRowsKeepReadableTitlesAndSeparatePlaybackFromDetails() async throws {
        for (category, size) in [("UICTContentSizeCategoryL", UIContentSizeCategory.large),
                                 ("UICTContentSizeCategoryAccessibilityXXXL", .accessibilityExtraExtraExtraLarge)] {
            try launch("recording-layout", userOverride: "readonlytv", textCategory: category)
            more("Live TV"); tap("tv-Recordings")
            let notice = app.staticTexts["Recording changes need permission."]
            XCTAssertTrue(notice.waitForExistence(timeout: 8))
            let traits = UITraitCollection(preferredContentSizeCategory: size)
            let caption = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
            let expectedNotice = (notice.label as NSString).boundingRect(
                with: CGSize(width: notice.frame.width + 1, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: caption], context: nil)
            XCTAssertGreaterThanOrEqual(notice.frame.height, expectedNotice.height - caption.lineHeight * 0.25,
                                        "The permission explanation must show every line at this text size.")
            let recording = app.buttons["recording-recording-1"]
            XCTAssertTrue(recording.waitForExistence(timeout: 8))
            attach("native-recording-row-layout-" + category)
            XCTAssertTrue(recording.label.contains("Reel test recording"))
            let font = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
            XCTAssertLessThan(recording.frame.height, font.lineHeight * 6 + 66,
                              "A short recording title must wrap into readable lines rather than a one-character column.\n\(app.debugDescription)")
            tap("Recording details")
            XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 8))
            XCTAssertEqual(app.staticTexts["detailTitle"].label, "Reel test recording")
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch.exists, "Details must not also start playback")
            back()
            tap("recording-recording-1")
            let transport = app.reelPlaybackButton("transportPlayPause")
            XCTAssertTrue(transport.waitForExistence(timeout: 10))
            await wait(NSPredicate(format: "enabled == true"), on: transport, timeout: 25)
            if transport.label == "Pause" { tap("transportPlayPause") }
            XCTAssertEqual(transport.label, "Play")
            attach("native-recording-layout-player-" + category)
            tap("closePlayer")
        }
    }

    func testDVRPermissionCheckFailureAndRefreshRecovery() async throws {
        try launch("dvr-policy")
        _ = try await json("/qa/livetv-control", body: ["failPermissions": 1])
        more("Live TV")
        let error = app.staticTexts["Recording permissions couldn’t be checked. Refresh Live TV to try again."]
        XCTAssertTrue(error.waitForExistence(timeout: 8))
        tap("Check permissions again")
        await wait(NSPredicate(format: "exists == false"), on: error)
        tap("tv-Guide"); tap("program-program-2")
        let record = app.buttons["recordProgram"]; reveal(record)
        XCTAssertTrue(record.waitForExistence(timeout: 8)); XCTAssertTrue(record.isEnabled)
        tap("Done")
    }

    func testDVRLoadingGuideProgramEmptyAndFailureRecovery() async throws {
        try launch("dvr-browse-state")
        _ = try await json("/qa/livetv-control", body: ["delayMs": 3000, "emptyChannels": true])
        more("Live TV")
        XCTAssertTrue(app.staticTexts["Loading Live TV…"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["No channels yet"].waitForExistence(timeout: 8))
        _ = try await json("/qa/livetv-control", body: ["reset": true])
        tap("refreshLiveTV"); XCTAssertTrue(app.buttons["channel-channel-1"].waitForExistence(timeout: 8))
        _ = try await json("/qa/livetv-control", body: ["failGet": 1, "failPath": "/LiveTv/Programs"])
        tap("tv-Guide"); XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 8))
        tap("retry"); XCTAssertTrue(app.buttons["program-program-2"].waitForExistence(timeout: 8))
        _ = try await json("/qa/livetv-control", body: ["emptyPrograms": true])
        tap("refreshLiveTV"); XCTAssertTrue(app.staticTexts["No programs in this guide"].waitForExistence(timeout: 8))
        _ = try await json("/qa/livetv-control", body: ["emptyPrograms": false])
        tap("refreshLiveTV"); XCTAssertTrue(app.buttons["program-program-2"].waitForExistence(timeout: 8))
        _ = try await json("/qa/livetv-control", body: ["failGet": 1, "failPath": "/LiveTv/Programs/program-2"])
        tap("program-program-2"); tap("Refresh program")
        let record = app.buttons["recordProgram"]; reveal(record)
        XCTAssertTrue(record.waitForExistence(timeout: 8)); tap("Done")
        _ = try await json("/qa/livetv-control", body: ["emptyRecordings": true])
        tap("tv-Recordings"); XCTAssertTrue(app.staticTexts["No recordings yet"].waitForExistence(timeout: 8))
        _ = try await json("/qa/livetv-control", body: ["emptyRecordings": false])
        tap("refreshLiveTV"); XCTAssertTrue(app.buttons["recording-recording-1"].waitForExistence(timeout: 8))
    }

    func testDVRWriteAndCancelFailurePreserveStateUntilRetry() async throws {
        try launch("dvr-write-state"); more("Live TV"); tap("tv-Guide"); tap("program-program-2")
        _ = try await json("/qa/livetv-control", body: ["failPost": 1, "failPath": "/LiveTv/Timers"])
        tap("recordProgram"); tap("Schedule recording")
        let error = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "The server couldn’t confirm the recording change.")).firstMatch
        reveal(error); XCTAssertTrue(error.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Recording scheduled"].exists)
        let failed = try await tvState(); XCTAssertEqual((failed["timers"] as? [String: Any])?.count, 0)
        _ = try await json("/qa/livetv-control", body: ["reset": true])
        tap("Refresh program"); tap("recordProgram"); tap("Schedule recording")
        XCTAssertTrue(app.staticTexts["Recording scheduled"].waitForExistence(timeout: 8)); tap("Done"); tap("tv-Scheduled")
        _ = try await json("/qa/livetv-control", body: ["failDelete": 1, "failPath": "/LiveTv/Timers/timer-1"])
        tap("cancelTimer-timer-1"); tap("Cancel recording")
        XCTAssertTrue(app.buttons["OK"].waitForExistence(timeout: 8)); tap("OK")
        XCTAssertTrue(app.buttons["cancelTimer-timer-1"].exists)
        let kept = try await tvState(); XCTAssertEqual((kept["timers"] as? [String: Any])?.count, 1)
        _ = try await json("/qa/livetv-control", body: ["reset": true])
        tap("cancelTimer-timer-1"); tap("Cancel recording")
        await wait(NSPredicate(format: "exists == false"), on: app.buttons["cancelTimer-timer-1"])
    }

    func testDVRChannelsGuideAndRecordingsPagination() async throws {
        try launch("dvr-pages")
        _ = try await json("/qa/livetv-control", body: ["pageSize": 2, "channelCount": 3, "recordingCount": 3])
        more("Live TV"); tap("tvLoadMore")
        XCTAssertTrue(app.buttons["channel-channel-3"].waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["tvLoadMore"].exists)
        tap("tv-Guide"); tap("tvLoadMore"); tap("tvLoadMore")
        let lastProgram = app.buttons["program-program-6"]; reveal(lastProgram)
        XCTAssertTrue(lastProgram.waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["tvLoadMore"].exists)
        tap("tv-Recordings"); tap("tvLoadMore")
        let lastRecording = app.buttons["recording-recording-3"]; reveal(lastRecording)
        XCTAssertTrue(lastRecording.waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["tvLoadMore"].exists)
        let state = try await tvState()
        let requests = state["requests"] as? [[String: Any]] ?? []
        for path in ["/LiveTv/Channels", "/LiveTv/Programs", "/LiveTv/Recordings"] {
            XCTAssertTrue(requests.contains { $0["path"] as? String == path && ($0["query"] as? [String: String])?["startindex"] == "2" }, path)
        }
    }

    func testMediaBrowseLoadingPaginationSearchEmptyAndRetry() async throws {
        try launch("hub-browse-state")
        _ = try await json("/qa/hub-control", body: ["browseDelayMs": 3000, "failBrowse": 1, "pageSize": 2, "trackCount": 5])
        more("Media"); tap("hub-Audio")
        XCTAssertTrue(app.staticTexts["Opening songs…"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 8))
        _ = try await json("/qa/hub-control", body: ["browseDelayMs": 0])
        tap("retry"); tap("hubLoadMore"); tap("hubLoadMore")
        let last = app.buttons["hub-audio-hub-track-5"]; reveal(last)
        XCTAssertTrue(last.waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["hubLoadMore"].exists)
        replace(app.searchFields.firstMatch, with: "absent-fixture-title")
        XCTAssertTrue(app.staticTexts["Nothing here yet"].waitForExistence(timeout: 8))
        _ = try await json("/qa/hub-control", body: ["empty": true])
        replace(app.searchFields.firstMatch, with: "")
        XCTAssertTrue(app.staticTexts["Nothing here yet"].waitForExistence(timeout: 8))
        _ = try await json("/qa/hub-control", body: ["empty": false])
        replace(app.searchFields.firstMatch, with: "First")
        XCTAssertTrue(app.buttons["hub-audio-hub-track-1"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["hub-audio-hub-track-2"].exists)
        replace(app.searchFields.firstMatch, with: "")
        XCTAssertTrue(app.buttons["hub-audio-hub-track-2"].waitForExistence(timeout: 8))
    }

    func testAudioLyricsAndPhotoErrorRecovery() async throws {
        try launch("hub-media-errors")
        _ = try await json("/qa/hub-control", body: ["failAudio": 1, "audioDelayMs": 3000, "lyricsEmpty": true])
        more("Media"); tap("hub-Audio"); tap("hub-audio-hub-track-1")
        XCTAssertTrue(app.staticTexts["Opening audio…"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["hubAudioRetry"].waitForExistence(timeout: 10))
        _ = try await json("/qa/hub-control", body: ["audioDelayMs": 0])
        tap("hubAudioRetry"); await pauseAudio()
        tap("hubLyrics"); XCTAssertTrue(app.staticTexts["No lyrics supplied"].waitForExistence(timeout: 8)); tap("hubCloseLyrics")
        _ = try await json("/qa/hub-control", body: ["lyricsEmpty": false, "failLyrics": 1])
        tap("hubLyrics"); XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 8)); tap("retry")
        XCTAssertTrue(app.buttons["hub-lyric-0"].waitForExistence(timeout: 8)); tap("hubCloseLyrics"); tap("hubClosePlayer")
        more("Media"); tap("hub-Photo")
        _ = try await json("/qa/hub-control", body: ["failPhoto": 20])
        tap("hub-photo-hub-photo-1"); XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 8))
        _ = try await json("/qa/hub-control", body: ["failPhoto": 0])
        tap("retry"); XCTAssertTrue(app.images["hubFullPhoto-hub-photo-1"].waitForExistence(timeout: 10))
        attach("native-photo-error-recovered"); tap("hubClosePhoto")
    }

    func testTextBookReaderRendersAfterNativePreviewLoads() async throws {
        try launch("text-reader-render")
        _ = try await json("/qa/hub-control", body: ["extraBooks": true])
        more("Media"); tap("hub-Book"); tap("hub-book-hub-book-text")
        await wait(NSPredicate(format: "label == %@", "The text reader"), on: app.staticTexts["hubBookTitle"])
        tap("hubSaveBook"); tap("hubOpenBook")
        XCTAssertTrue(app.otherElements["hubDocumentReader"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["Reel native text reader"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["Local fixture content for Quick Look."].exists)
        attach("native-text-reader-after-load")
        let snapshot = XCTAttachment(string: app.debugDescription)
        snapshot.name = "native-text-reader-after-load-hierarchy"; snapshot.lifetime = .keepAlways; add(snapshot)
        tap("hubCloseReader")
    }

    func testEveryBookGridTileOpensItsOwnTitleAfterReturning() async throws {
        try launch("book-selection")
        _ = try await json("/qa/hub-control", body: ["extraBooks": true])
        more("Media"); tap("hub-Book")
        let first = app.buttons["hub-book-hub-book-1"]
        let second = app.buttons["hub-book-hub-book-text"]
        XCTAssertTrue(first.waitForExistence(timeout: 8)); XCTAssertTrue(second.waitForExistence(timeout: 8))
        XCTAssertLessThanOrEqual(first.frame.maxX, second.frame.minX, "Adjacent book buttons must have disjoint native hit frames.")
        for (id, name) in [("hub-book-text", "The text reader"), ("hub-book-mobi", "An external reader example"), ("hub-book-1", "The test reader")] {
            let book = app.buttons["hub-book-" + id]
            reveal(book)
            let state = XCTAttachment(string: app.debugDescription)
            state.name = "native-book-grid-before-" + id; state.lifetime = .keepAlways; add(state)
            attach("native-book-grid-before-" + id)
            tap("hub-book-" + id)
            await wait(NSPredicate(format: "label == %@", name), on: app.staticTexts["hubBookTitle"])
            back()
        }
    }

    func testMediaSaveRetryDismissCancelAndDocumentFormats() async throws {
        try launch("hub-save-states"); more("Media"); tap("hub-Audio")
        _ = try await json("/qa/hub-control", body: ["failDownload": 1])
        tap("hub-audio-options-hub-track-1"); tap("Save original for offline")
        XCTAssertTrue(app.staticTexts["hub-save-error-hub-track-1"].waitForExistence(timeout: 8))
        tap("hub-retry-save-hub-track-1")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "hub-save-status-hub-track-1").firstMatch.waitForExistence(timeout: 15))
        _ = try await json("/qa/hub-control", body: ["failDownload": 20])
        tap("hub-audio-options-hub-track-2"); tap("Save original for offline")
        XCTAssertTrue(app.staticTexts["hub-save-error-hub-track-2"].waitForExistence(timeout: 8)); tap("hub-dismiss-save-hub-track-2")
        XCTAssertFalse(app.staticTexts["hub-save-error-hub-track-2"].exists)
        _ = try await json("/qa/hub-control", body: ["failDownload": 0, "downloadDelayMs": 10000])
        tap("hub-audio-options-hub-track-2"); tap("Save original for offline")
        let transfer = app.descendants(matching: .any).matching(identifier: "hub-saving-hub-track-2").firstMatch
        XCTAssertTrue(transfer.waitForExistence(timeout: 3), app.debugDescription)
        let cancelTransfer = app.buttons["hub-cancel-save-hub-track-2"].exists ? app.buttons["hub-cancel-save-hub-track-2"] : app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelTransfer.waitForExistence(timeout: 3), app.debugDescription); cancelTransfer.tap()
        try await Task.sleep(for: .milliseconds(10500))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "hub-save-status-hub-track-2").firstMatch.exists)
        _ = try await json("/qa/hub-control", body: ["downloadDelayMs": 0, "extraBooks": true])
        more("Media"); tap("hub-Book"); tap("hub-book-hub-book-text"); tap("hubSaveBook"); tap("hubOpenBook")
        XCTAssertTrue(app.otherElements["hubDocumentReader"].waitForExistence(timeout: 10)); attach("native-quicklook-text-reader"); tap("hubCloseReader")
        more("Media"); tap("hub-Book"); tap("hub-book-hub-book-mobi"); tap("hubSaveBook"); tap("hubOpenBook")
        XCTAssertTrue(app.staticTexts["Open in your reader"].waitForExistence(timeout: 8))
        tap("Export original file"); await dismissShare(); tap("hubCloseReader")
        _ = try await json("/qa/hub-control", body: ["downloadDelayMs": 10000])
        more("Media"); tap("hub-Book"); tap("hub-book-hub-book-1"); tap("hubSaveBook")
        let saving = app.descendants(matching: .any).matching(identifier: "hubCancelBook").firstMatch
        XCTAssertTrue(saving.waitForExistence(timeout: 5)); saving.tap()
        await wait(NSPredicate(format: "exists == false"), on: saving)
        XCTAssertTrue(app.buttons["hubSaveBook"].exists)
        try await Task.sleep(for: .milliseconds(10500))
        XCTAssertTrue(app.buttons["hubSaveBook"].exists); XCTAssertFalse(app.buttons["hubOpenBook"].exists)
    }

    func testSavedMusicPermissionRecoveryAndAccountIsolation() async throws {
        try launch("hub-permission"); more("Media"); tap("hub-Audio")
        _ = try await json("/qa/hub-control", body: ["reset": true, "denyDownload": true])
        tap("hub-audio-options-hub-track-1"); tap("Save original for offline")
        XCTAssertTrue(app.staticTexts["hub-save-error-hub-track-1"].waitForExistence(timeout: 8))
        _ = try await json("/qa/hub-control", body: ["allowDownload": true])
        tap("hub-retry-save-hub-track-1")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "hub-save-status-hub-track-1").firstMatch.waitForExistence(timeout: 15))
        let first = user; let second = "hub-other-" + String(UUID().uuidString.prefix(8))
        tap("Home"); tap("servers"); tap("addServer")
        replace(app.textFields["server"], with: "http://127.0.0.1:18767")
        replace(app.textFields["username"], with: second); replace(app.secureTextFields["password"], with: "demo"); tap("connect")
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15)); more("Media"); tap("hub-saved")
        XCTAssertTrue(app.staticTexts["Take it with you"].waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["hub-saved-hub-track-1"].exists)
        tap("Home"); tap("servers"); tap("server-" + first)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15)); more("Media"); tap("hub-saved")
        XCTAssertTrue(app.buttons["hub-saved-hub-track-1"].waitForExistence(timeout: 8))
        tap("hub-saved-options-hub-track-1"); tap("Remove saved file"); tap("hubConfirmRemoveSaved")
        await wait(NSPredicate(format: "exists == false"), on: app.buttons["hub-saved-hub-track-1"])
    }
}
