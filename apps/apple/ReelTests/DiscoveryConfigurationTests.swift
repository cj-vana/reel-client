import XCTest
import Network
import Darwin
import Synchronization
@testable import Reel

@MainActor final class DiscoveryConfigurationTests: XCTestCase {
    private final class PacketReceipt: Sendable {
        let value = Mutex(false)
    }
    private func loopback(port: UInt16 = 17359, duration: Duration = .seconds(2)) -> ServerDiscovery.Configuration {
        ServerDiscovery.Configuration(destination: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), duration: duration, loopbackOnly: true)
    }

    private func advertised(_ address: String) throws -> DiscoveredServer {
        let data = try JSONSerialization.data(withJSONObject: ["Id": "test-advertisement", "Name": "Synthetic discovery", "Address": address])
        return try DiscoveredServer.parse(data, responderHost: "127.0.0.1")
    }

    func testDefaultConfigurationRetainsBroadcastAndTimeout() {
        let configuration = ServerDiscovery.Configuration.localNetwork
        XCTAssertFalse(configuration.loopbackOnly)
        XCTAssertEqual(configuration.duration, .seconds(4))
        guard case let .hostPort(host, port) = configuration.destination else { return XCTFail("Expected Jellyfin broadcast endpoint") }
        XCTAssertEqual(host.debugDescription, "255.255.255.255")
        XCTAssertEqual(port.rawValue, 7359)
        XCTAssertTrue(configuration.allows(destination: .hostPort(host: "192.168.1.20", port: 7359)))
        XCTAssertFalse(configuration.allows(destination: .hostPort(host: "8.8.8.8", port: 7359)))
    }

    func testLoopbackScopeRejectsBroadcastAndNonloopbackOverridesBeforeSend() {
        let configuration = loopback()
        for endpoint in [NWEndpoint.hostPort(host: "255.255.255.255", port: 7359),
                         .hostPort(host: "192.168.1.20", port: 7359),
                         .hostPort(host: "public.example.com", port: 7359),
                         .hostPort(host: "127.0.0.1", port: .any)] {
            XCTAssertFalse(configuration.allows(destination: endpoint))
            let discovery = ServerDiscovery(configuration: configuration)
            discovery.start(destination: endpoint)
            XCTAssertEqual(discovery.status, .failed)
            XCTAssertNotNil(discovery.error)
            XCTAssertTrue(discovery.servers.isEmpty)
        }
    }

    func testLoopbackScopeRejectsNonloopbackResponderAndAdvertisedServer() throws {
        let configuration = loopback()
        let local = try advertised("http://127.0.0.1:18766")
        XCTAssertTrue(configuration.allows(server: local, responderHost: "127.0.0.1"))
        XCTAssertFalse(configuration.allows(server: local, responderHost: "192.168.1.20"))
        for address in ["http://192.168.1.20:8096", "https://10.0.0.1:8096", "http://localhost:18766"] {
            let server = try advertised(address)
            XCTAssertFalse(configuration.allows(server: server, responderHost: "127.0.0.1"))
            XCTAssertTrue(ServerDiscovery.Configuration.localNetwork.allows(server: server, responderHost: "127.0.0.1"))
        }
    }

    func testSimulatorFlagsOnlySelectFixedEndpointsAndUnknownFlagsFailClosed() throws {
        #if DEBUG && targetEnvironment(simulator)
        let factory = ServerDiscovery.Configuration.simulatorFixture
        XCTAssertNil(factory(["Reel", "-reel-qa-reset"]))
        for (arguments, expectedPort) in [
            (["-reel-qa-discovery-loopback"], UInt16(17359)),
            (["-reel-qa-discovery-empty"], UInt16(17360)),
            (["-reel-qa-discovery-unavailable"], UInt16(0)),
            (["-reel-qa-discovery-host=192.168.1.20"], UInt16(0)),
            (["-reel-qa-discovery-loopback", "-reel-qa-discovery-empty"], UInt16(0))
        ] {
            let configuration = try XCTUnwrap(factory(arguments))
            XCTAssertTrue(configuration.loopbackOnly)
            guard case let .hostPort(host, port) = configuration.destination else { return XCTFail("Fixture endpoint must be unicast loopback") }
            XCTAssertEqual(host.debugDescription, "127.0.0.1")
            XCTAssertEqual(port.rawValue, expectedPort)
        }
        #else
        throw XCTSkip("The fixed fixture selector exists only in DEBUG simulator builds.")
        #endif
    }

    func testInjectedDestinationReceivesRealLoopbackReply() async throws {
        let discovery = ServerDiscovery(configuration: loopback())
        defer { discovery.stop() }
        discovery.start()
        for _ in 0..<100 {
            if !discovery.servers.isEmpty || discovery.status == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(discovery.servers.first?.serverID, "fixture-discovery")
        XCTAssertEqual(discovery.servers.first?.address.host, "127.0.0.1")
    }

    func testExplicitStartDestinationAndDurationRemainCompatible() async throws {
        let discovery = ServerDiscovery()
        defer { discovery.stop() }
        discovery.start(destination: .hostPort(host: "127.0.0.1", port: 17359), duration: .seconds(2))
        for _ in 0..<100 {
            if !discovery.servers.isEmpty || discovery.status == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(discovery.servers.first?.serverID, "fixture-discovery")
    }

    func testStopCancelsTimeoutAndNextSearchFinishesEmpty() async throws {
        let discovery = ServerDiscovery(configuration: loopback(port: 17360, duration: .milliseconds(100)))
        discovery.start()
        XCTAssertEqual(discovery.status, .searching)
        discovery.stop()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(discovery.status, .idle)
        XCTAssertTrue(discovery.servers.isEmpty)
        discovery.start()
        for _ in 0..<50 {
            if discovery.status != .searching { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(discovery.status, .finished)
        XCTAssertTrue(discovery.servers.isEmpty)
        discovery.stop()
    }

    func testStoppedSearchDoesNotAcceptDelayedLoopbackDatagram() async throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return XCTFail("Could not open isolated loopback responder") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        XCTAssertEqual(named, 0)
        var receiveTimeout = timeval(tv_sec: 1, tv_usec: 0)
        XCTAssertEqual(setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size)), 0)
        let received = PacketReceipt()
        let reply = Task.detached {
            var sender = sockaddr_in(), senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            var buffer = [UInt8](repeating: 0, count: 128)
            let capacity = buffer.count
            let count = withUnsafeMutablePointer(to: &sender) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, capacity, 0, $0, &senderLength) } }
            guard count > 0 else { return false }
            received.value.withLock { $0 = true }
            try await Task.sleep(for: .milliseconds(200))
            let payload = Data(#"{"Id":"late-loopback","Name":"Late fixture","Address":"http://127.0.0.1:18766"}"#.utf8)
            return payload.withUnsafeBytes { bytes in
                withUnsafePointer(to: &sender) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } == payload.count
        }
        let discovery = ServerDiscovery(configuration: loopback(port: UInt16(bigEndian: address.sin_port)))
        discovery.start()
        for _ in 0..<100 {
            if received.value.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(received.value.withLock { $0 })
        discovery.stop()
        let sent = try await reply.value
        XCTAssertTrue(sent)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(discovery.status, .idle)
        XCTAssertTrue(discovery.servers.isEmpty)
    }
}
