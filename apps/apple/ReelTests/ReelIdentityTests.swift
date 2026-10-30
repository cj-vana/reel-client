import XCTest
@testable import Reel

final class ReelIdentityTests: XCTestCase {
    func testExistingBundleKeepsItsCredentialNamespace() {
        XCTAssertEqual(ReelIdentity.namespace(bundleIdentifier: "org.example.player", override: nil), "org.example.player")
        XCTAssertNotEqual(ReelIdentity.namespace(bundleIdentifier: "app.reelclient.ios", override: nil),
                          ReelIdentity.namespace(bundleIdentifier: "app.reelclient.tv", override: nil))
    }

    func testExplicitNamespacePreservesAnExistingCredentialStore() {
        XCTAssertEqual(ReelIdentity.namespace(bundleIdentifier: "org.example.television", override: "org.example.player"), "org.example.player")
        XCTAssertEqual(ReelIdentity.namespace(bundleIdentifier: nil, override: " org.example.player "), "org.example.player")
    }

    func testMalformedOrUnexpandedBuildValuesCannotBecomeCredentialNamespaces() {
        for value in ["", "$(REEL_CREDENTIAL_NAMESPACE)", "org..example", ".org.example", "org.example.", "org.example\nplayer", "org.example/other", String(repeating: "a", count: 256)] {
            XCTAssertEqual(ReelIdentity.namespace(bundleIdentifier: "org.example.player", override: value), "org.example.player")
        }
        XCTAssertEqual(ReelIdentity.namespace(bundleIdentifier: nil, override: nil), "app.reelclient.ios")
        XCTAssertEqual(ReelIdentity.namespace(bundleIdentifier: "$(PRODUCT_BUNDLE_IDENTIFIER)", override: nil), "app.reelclient.ios")
    }

    func testCredentialServicesRemainDistinctWithinTheBuiltApplication() {
        XCTAssertEqual(SecureAccount.service, ReelIdentity.credentialNamespace + ".account")
        let services = ["account", "gatewayHeaders", "seerr"].map(ReelIdentity.service)
        XCTAssertEqual(Set(services).count, 3)
        XCTAssertTrue(services.allSatisfy { $0.hasPrefix(ReelIdentity.credentialNamespace + ".") })
    }
}
