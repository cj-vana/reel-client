import Foundation

/// Noncredential controls for disposable loopback fixtures, never the product API policy.
enum TVFixtureOwnership {
    static func requireHost(allowedBundles: Set<String> = ["app.reelclient.tv.qa", "app.reelclient.tv.qa.uitests.xctrunner"]) throws {
        let environment = ProcessInfo.processInfo.environment
        guard allowedBundles.contains(Bundle.main.bundleIdentifier ?? ""),
              environment["SIMULATOR_DEVICE_NAME"] == "Reel QA Apple TV",
              let expected = environment["REEL_TV_QA_DEVICE_UDID"].flatMap(UUID.init(uuidString:)),
              let actual = environment["SIMULATOR_UDID"].flatMap(UUID.init(uuidString:)), expected == actual,
              let owner = environment["REEL_TV_QA_OWNER"], (24...120).contains(owner.count),
              owner.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw NSError(domain: "TVFixtureOwnership", code: 1, userInfo: [NSLocalizedDescriptionKey: "Exact owned simulator and fixture identity are required."])
        }
    }

    static func request(_ url: URL) async throws -> URLRequest {
        try requireHost()
        guard url.scheme == "http", url.host == "127.0.0.1", let port = url.port,
              (18966...18969).contains(port), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              ["/qa/state", "/qa/reset", "/qa/control", "/qa/tv-control", "/qa/audio-control"].contains(url.path),
              let owner = ProcessInfo.processInfo.environment["REEL_TV_QA_OWNER"] else { throw URLError(.badURL) }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("qa/tv-identity"))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let identity = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              identity["kind"] as? String == "reel-tv-owned-fixture", identity["owner"] as? String == owner,
              identity["port"] as? Int == port else {
            throw NSError(domain: "TVFixtureOwnership", code: 2, userInfo: [NSLocalizedDescriptionKey: "The loopback listener does not belong to this test run."])
        }
        var request = URLRequest(url: url)
        request.setValue(owner, forHTTPHeaderField: "X-Reel-TV-Owner")
        return request
    }
}
