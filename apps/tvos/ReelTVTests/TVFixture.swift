import Foundation
import XCTest

@MainActor enum TVFixture {
    static func requireQAHost() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("TV contract tests require the disposable simulator QA host.")
        #else
        try TVFixtureOwnership.requireHost(allowedBundles: ["app.reelclient.tv.qa"])
        #endif
    }

    static func request(_ url: URL) async throws -> URLRequest {
        try requireQAHost()
        return try await TVFixtureOwnership.request(url)
    }

    static func reset() async throws {
        try await send("reset", body: [:])
        try await control(failReports: false, failCleanup: false)
    }

    static func control(failReports: Bool, failCleanup: Bool, reportDelay: Double = 0) async throws {
        try await send("control", body: ["failReports": failReports, "failCleanup": failCleanup, "reportDelay": reportDelay, "recoveryAllowed": false])
    }

    static func reports() async throws -> [[String: Any]] {
        try requireQAHost()
        let request = try await Self.request(URL(string: "http://127.0.0.1:18966/qa/state")!)
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(state["reports"] as? [[String: Any]])
    }

    private static func send(_ action: String, body: [String: Any]) async throws {
        try requireQAHost()
        guard ["reset", "control"].contains(action) else { throw URLError(.unsupportedURL) }
        var request = try await Self.request(URL(string: "http://127.0.0.1:18966/qa/" + action)!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
}
