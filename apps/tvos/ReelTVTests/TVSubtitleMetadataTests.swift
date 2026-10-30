import AVFoundation
import AVKit
import XCTest
@testable import ReelTV

@MainActor final class TVSubtitleMetadataTests: XCTestCase {
    func researchInventoryPerItemLegiblePresentationSchemeBeforeAndAfterInitialSelection() async throws {
        try TVFixture.requireQAHost()
        let server = URL(string: "http://127.0.0.1:18968")!
        var reset = try await TVFixture.request(server.appendingPathComponent("qa/reset"))
        reset.httpMethod = "POST"; reset.httpBody = Data("{}".utf8)
        reset.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: reset)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var control = try await TVFixture.request(server.appendingPathComponent("qa/control"))
        control.httpMethod = "POST"; control.httpBody = Data("{\"failReports\":false,\"failCleanup\":false}".utf8)
        control.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, controlResponse) = try await URLSession.shared.data(for: control)
        XCTAssertEqual((controlResponse as? HTTPURLResponse)?.statusCode, 200)
        let api = JellyfinAPI(server: server, token: "fixture-tv-track-output", userID: "tv-track-output", deviceID: "tv-subtitle-scheme-qa", historyEnabled: false)
        let media = try await api.item("movie-1")
        let reference = PlayerReference()
        var snapshots: [[String: Any]] = []
        let player = PlaybackController(beforeInitialPlayback: {
            guard let item = reference.player?.player.currentItem,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  reference.player?.player.currentItem === item else { return }
            snapshots.append(self.presentationInventory(item: item, group: group, phase: "Attached ready item before explicit selection"))
        })
        reference.player = player
        do {
            player.present(media, audio: 1, subtitle: 2, fromBeginning: true, mediaSourceID: "movie-1-source")
            player.start(api: api, quality: .original)
            for _ in 0..<150 {
                if player.error != nil || (player.isPlaying && player.player.currentTime().seconds > 0.5) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNil(player.error)
            XCTAssertTrue(player.isPlaying)
            XCTAssertGreaterThan(player.player.currentTime().seconds, 0.5)
            let item = try XCTUnwrap(player.player.currentItem)
            let loaded = try await item.asset.loadMediaSelectionGroup(for: .legible)
            let group = try XCTUnwrap(loaded)
            XCTAssertEqual(item.status, .readyToPlay)
            XCTAssertGreaterThan(item.presentationSize.width, 0)
            XCTAssertEqual(group.options.count, 1)
            snapshots.append(presentationInventory(item: item, group: group, phase: "Decoded advancing item after explicit selection"))
            XCTAssertEqual(snapshots.count, 2)
            let inventory: [String: Any] = ["snapshots": snapshots, "supportedAVKitCharacteristics": AVPlayerViewController.mediaCharacteristicsForSupportedCustomMediaSelectionSchemes.map(\.rawValue), "mutations": "No presentation setting/language/scheme or automatic policy was changed by this inventory; normal candidate startup performed its existing explicit selection."]
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: inventory, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "Public per-item legible presentation scheme inventory"
            attachment.lifetime = .keepAlways; add(attachment)
            player.stop(); await player.flushReports()
            let (stateData, stateResponse) = try await URLSession.shared.data(for: try await TVFixture.request(server.appendingPathComponent("qa/state")))
            XCTAssertEqual((stateResponse as? HTTPURLResponse)?.statusCode, 200)
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
            let resources = try XCTUnwrap(state["subtitleCleanups"] as? [[String: Any]])
            XCTAssertEqual(resources.count, 1)
            XCTAssertEqual(resources.first?["user"] as? String, "tv-track-output")
            XCTAssertEqual(resources.first?["deviceId"] as? [String], ["tv-subtitle-scheme-qa"])
            XCTAssertEqual(resources.first?["playSessionId"] as? [String], ["synthetic-track-session"])
            XCTAssertFalse((state["reports"] as? [[String: Any]] ?? []).contains { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
            let cleanup = XCTAttachment(data: stateData, uniformTypeIdentifier: "public.json")
            cleanup.name = "Presentation inventory owned encoder cleanup and privacy receipt"
            cleanup.lifetime = .keepAlways; add(cleanup)
        } catch {
            player.stop(); await player.flushReports()
            throw error
        }
    }

    @MainActor private final class PlayerReference {
        weak var player: PlaybackController?
    }

    private func presentationInventory(item: AVPlayerItem, group: AVMediaSelectionGroup, phase: String) -> [String: Any] {
        var result: [String: Any] = ["phase": phase, "schemeExists": group.customMediaSelectionScheme != nil,
            "preferredSchemeCount": item.preferredCustomMediaSelectionSchemes.count, "selectedOptionExists": item.currentMediaSelection.selectedMediaOption(in: group) != nil,
            "optionCount": group.options.count]
        if let scheme = group.customMediaSelectionScheme {
            let selected = item.selectedMediaPresentationSettings(for: group)
            let effective = item.effectiveMediaPresentationSettings(for: group)
            result["offersLanguageSelection"] = scheme.shouldOfferLanguageSelection
            result["availableLanguages"] = scheme.availableLanguages
            result["selectedPresentationLanguage"] = item.selectedMediaPresentationLanguage(for: group) ?? "none"
            result["selectors"] = scheme.selectors.map { selector in
                ["identifier": selector.identifier, "settingCharacteristics": selector.settings.map { $0.mediaCharacteristic.rawValue },
                 "selectedCharacteristic": (selected[selector] as? AVMediaPresentationSetting)?.mediaCharacteristic.rawValue ?? "none",
                 "effectiveCharacteristic": (effective[selector] as? AVMediaPresentationSetting)?.mediaCharacteristic.rawValue ?? "none"] as [String: Any]
            }
        }
        return result
    }

    func testInventoryActualAuthenticatedHLSLegibleMetadata() async throws {
        try await TVFixture.reset()
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18966")!, token: "fixture-tv-track-output", userID: "tv-track-output", deviceID: "tv-subtitle-metadata-qa", historyEnabled: false)
        let media = try await api.item("movie-1")
        let player = PlaybackController()
        do {
            player.present(media, audio: 1, subtitle: 2, fromBeginning: true, mediaSourceID: "movie-1-source")
            player.start(api: api, quality: .original)
            for _ in 0..<150 {
                if player.error != nil || player.player.currentTime().seconds > 0.5 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNil(player.error)
            let item = try XCTUnwrap(player.player.currentItem)
            let loaded = try await item.asset.loadMediaSelectionGroup(for: .legible)
            let group = try XCTUnwrap(loaded)
            var rows: [[String: Any]] = []
            for option in group.options {
                rows.append(try await describe(option))
            }
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            var inventory: [String: Any] = ["options": rows, "selectedExists": selected != nil]
            if let selected { inventory["selectedOption"] = try await describe(selected) }
            let data = try JSONSerialization.data(withJSONObject: inventory, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "Public native subtitle metadata inventory"
            attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(group.options.count, 1)
            XCTAssertGreaterThan(item.presentationSize.width, 0)
            XCTAssertGreaterThan(player.player.currentTime().seconds, 0.5)
            player.stop(); await player.flushReports()
        } catch {
            player.stop(); await player.flushReports()
            throw error
        }
    }

    private func describe(_ option: AVMediaSelectionOption) async throws -> [String: Any] {
        var metadata: [[String: String]] = []
        for entry in option.commonMetadata {
            let value = try await entry.load(.stringValue)
            metadata.append(["identifier": entry.identifier?.rawValue ?? "none", "commonKey": entry.commonKey?.rawValue ?? "none", "string": value ?? "none"])
        }
        return ["displayName": option.displayName, "language": option.extendedLanguageTag ?? "none", "playable": option.isPlayable, "forced": option.hasMediaCharacteristic(.containsOnlyForcedSubtitles), "SDH": option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility), "commonMetadata": metadata]
    }
}
