import Foundation
import XCTest
@testable import ReelTV

@MainActor enum TVParityFixture {
    static let base = URL(string: "http://127.0.0.1:18970")!

    static func api(_ user: String) -> JellyfinAPI {
        JellyfinAPI(server: base, token: "fixture-" + user, userID: user, deviceID: "tv-parity-" + user, historyEnabled: false)
    }

    static func requireOwnedHost() async throws -> String {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Browsing parity runs only in a new owned disposable tvOS simulator")
        #else
        guard Bundle.main.bundleIdentifier == "app.reelclient.tv.qa",
              ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Reel QA Apple TV",
              let device = ProcessInfo.processInfo.environment["REEL_TV_PARITY_DEVICE_UDID"],
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == device,
              let owner = ProcessInfo.processInfo.environment["REEL_TV_PARITY_OWNER"], owner.count >= 24 else {
            throw NSError(domain: "TVParityFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing exact QA host or fixture ownership identity"])
        }
        let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("qa/parity-identity"))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let identity = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              identity["kind"] as? String == "reel-tv-library-parity", identity["owner"] as? String == owner,
              identity["port"] as? Int == 18970 else {
            throw NSError(domain: "TVParityFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "The listener is not this test run’s owned parity fixture"])
        }
        return owner
        #endif
    }

    static func control(_ user: String, _ values: [String: Any], options: Bool = false) async throws {
        let owner = try await requireOwnedHost()
        guard user.hasPrefix("library-") else { throw URLError(.badURL) }
        var request = try api(user).request(options ? "qa/parity-control" : "qa/library-control", method: "POST", body: JSONSerialization.data(withJSONObject: values))
        request.setValue(owner, forHTTPHeaderField: "X-Reel-Parity-Owner")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    static func state(_ user: String) async throws -> [String: Any] {
        let owner = try await requireOwnedHost()
        var request = URLRequest(url: base.appendingPathComponent("qa/parity-state"))
        request.setValue(owner, forHTTPHeaderField: "X-Reel-Parity-Owner")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return ((state["users"] as? [String: [String: Any]])?[user]) ?? [:]
    }

    static func requests(_ user: String) async throws -> [[String: Any]] {
        let state = try await state(user)
        return state["requests"] as? [[String: Any]] ?? []
    }
}
