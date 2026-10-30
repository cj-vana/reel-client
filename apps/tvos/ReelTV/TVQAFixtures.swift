import Foundation

extension TVCoordinator {
    static func forApplication() -> TVCoordinator {
        #if DEBUG && targetEnvironment(simulator)
        if Bundle.main.bundleIdentifier == "app.reelclient.tv.qa",
           ProcessInfo.processInfo.arguments.contains("-reel-tv-qa-vault-unavailable") {
            var services = SessionAccountServices.jellyfin
            services.authenticate = { server, username, password, deviceID in
                guard server.host == "127.0.0.1", [18966, 18967].contains(server.port) else { throw ReelError.previewProtected }
                return try await JellyfinAPI(server: server, deviceID: deviceID).authenticate(username: username, password: password)
            }
            services.revoke = { account, deviceID in
                guard account.server.host == "127.0.0.1", [18966, 18967].contains(account.server.port) else { throw ReelError.previewProtected }
                try await JellyfinAPI(server: account.server, token: account.token, userID: account.userID, deviceID: deviceID).post("Sessions/Logout")
            }
            services.removeCredentials = { _, _ in }
            return TVCoordinator(session: Session(storage: TVUnavailableVaultFixture(), defaults: .standard, services: services))
        }
        #endif
        return TVCoordinator()
    }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor private final class TVUnavailableVaultFixture: AccountVaultStorage {
    private var failures = 2
    private var vault: AccountVault
    init() {
        let account = Account(server: URL(string: "http://127.0.0.1:18966")!, token: "fixture-tv-vault-recovery", userID: "tv-vault-recovery", name: "Alex", serverName: "Reel Cinema")
        vault = AccountVault(accounts: [account], activeID: account.id)
    }
    func read() throws -> AccountVault {
        if failures > 0 { failures -= 1; throw ReelError.storage }
        return vault
    }
    func save(_ value: AccountVault) throws {
        guard value.accounts.allSatisfy({ $0.server.host == "127.0.0.1" && [18966, 18967].contains($0.server.port) }) else { throw ReelError.storage }
        vault = value
    }
    func clear() throws { throw ReelError.storage }
}
#endif
