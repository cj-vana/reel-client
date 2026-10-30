import Foundation
import Observation
import Security

struct AccountVault: Codable, Equatable, Sendable {
    var accounts: [Account] = []
    var activeID: String?
    var active: Account? { accounts.first { $0.id == activeID } }

    mutating func remember(_ account: Account) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account }
        else { accounts.append(account) }
        activeID = account.id
    }
    mutating func select(_ id: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        activeID = id
    }
    mutating func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
        if activeID == id { activeID = accounts.first?.id }
    }
    static func decode(_ data: Data) throws -> AccountVault {
        if let legacy = try? JSONDecoder().decode(Account.self, from: data) {
            return AccountVault(accounts: [legacy], activeID: legacy.id)
        }
        let vault = try JSONDecoder().decode(AccountVault.self, from: data)
        guard Set(vault.accounts.map(\.id)).count == vault.accounts.count,
              vault.activeID == nil || vault.active != nil else { throw ReelError.storage }
        return vault
    }
}

enum ReelIdentity {
    static let credentialNamespace = namespace(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        override: Bundle.main.object(forInfoDictionaryKey: "ReelCredentialNamespace") as? String
    )

    static func namespace(bundleIdentifier: String?, override: String?) -> String {
        func valid(_ candidate: String?) -> String? {
            guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  candidate.utf8.count <= 255 else { return nil }
            let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts.allSatisfy({ part in
                !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }) else { return nil }
            return candidate
        }
        return valid(override) ?? valid(bundleIdentifier) ?? "app.reelclient.ios"
    }

    static func service(_ name: String) -> String { credentialNamespace + "." + name }
}

enum SecureAccount {
    static let service = ReelIdentity.service("account")
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "jellyfin"]
    }
    static func read() throws -> AccountVault {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return AccountVault() }
        guard status == errSecSuccess, let data = result as? Data else { throw ReelError.storage }
        return try AccountVault.decode(data)
    }
    static func save(_ vault: AccountVault) throws {
        let data = try JSONEncoder().encode(vault)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            let insertion = query.merging(attributes) { _, value in value }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw ReelError.storage }
        } else if update != errSecSuccess { throw ReelError.storage }
    }
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ReelError.storage }
    }
}

@MainActor protocol AccountVaultStorage {
    func read() throws -> AccountVault
    func save(_ vault: AccountVault) throws
    func clear() throws
}

struct KeychainAccountVaultStorage: AccountVaultStorage {
    func read() throws -> AccountVault { try SecureAccount.read() }
    func save(_ vault: AccountVault) throws { try SecureAccount.save(vault) }
    func clear() throws { try SecureAccount.clear() }
}

@MainActor struct SessionAccountServices {
    var authenticate: (URL, String, String, String) async throws -> Account
    var revoke: (Account, String) async throws -> Void
    var finishCasting: (String) async -> Void = { await CastCoordinator.shared.finishAccount($0) }
    var removeCredentials: (Account, AccountVault) throws -> Void = { account, remaining in
        try SessionAccountServices.removeSavedCredentials(account, remaining: remaining,
            removeSeerr: { try SeerrSecureStore.remove(accountID: $0) },
            removeGateway: { try GatewayHeaderStore.remove(for: $0) })
    }

    static func removeSavedCredentials(_ account: Account, remaining: AccountVault,
                                       removeSeerr: (String) throws -> Void, removeGateway: (URL) throws -> Void) throws {
        try removeSeerr(account.id)
        // GatewayHeaderStore uses the normalized server, independently of user.
        let key = try JellyfinAPI.normalize(account.server.absoluteString).absoluteString
        for other in remaining.accounts {
            if try JellyfinAPI.normalize(other.server.absoluteString).absoluteString == key { return }
        }
        try removeGateway(account.server)
    }

    static func hasRemainingTokenReference(_ account: Account, remaining: AccountVault) throws -> Bool {
        let key = try JellyfinAPI.normalize(account.server.absoluteString).absoluteString
        for other in remaining.accounts where other.token == account.token {
            // The opaque token is the authority; a saved row's user label cannot
            // make revoking a still-referenced token safe.
            if try JellyfinAPI.normalize(other.server.absoluteString).absoluteString == key { return true }
        }
        return false
    }

    static let jellyfin = Self(authenticate: { server, username, password, deviceID in
        try await JellyfinAPI(server: server, deviceID: deviceID).authenticate(username: username, password: password)
    }, revoke: { account, deviceID in
        let api = JellyfinAPI(server: account.server, token: account.token, userID: account.userID, deviceID: deviceID)
        try await api.post("Sessions/Logout")
    })
}

enum SavedAccountStorageError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "Your saved connections are temporarily unavailable. Unlock your device, then retry. Reel hasn’t changed your saved connections."
    }
}

@MainActor @Observable final class Session {
    private(set) var vault = AccountVault()
    private(set) var savedAccountsAvailable = false
    var account: Account? { savedAccountsAvailable ? vault.active : nil }
    var accounts: [Account] { savedAccountsAvailable ? vault.accounts : [] }
    var notice: String?
    func appendNotice(_ message: String) {
        let existing = notice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if existing.isEmpty { notice = message }
        else if !existing.components(separatedBy: "\n\n").contains(message) { notice = existing + "\n\n" + message }
    }
    private(set) var revision = UUID()
    var beforeRemove: ((Account) async -> Void)?
    /// Local noncredential cleanup after durable removal; never called for a failed or stale removal.
    var afterRemove: ((Account) -> Void)?
    var libraryRevision = 0
    @discardableResult func invalidateCatalogue(accountID: String, revision expected: UUID) -> Bool {
        guard revision == expected, account?.id == accountID else { return false }
        libraryRevision += 1
        return true
    }
    var privateViewing: Bool {
        didSet { defaults.set(privateViewing, forKey: "privateViewing") }
    }
    let deviceID: String
    @ObservationIgnored private let storage: any AccountVaultStorage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let services: SessionAccountServices
    @ObservationIgnored private var mutationGeneration = UUID()
    @ObservationIgnored private var pendingReset: Bool

    convenience init() {
        #if DEBUG && targetEnvironment(simulator)
        let reset = ProcessInfo.processInfo.arguments.contains("-reel-qa-reset")
        #else
        let reset = false
        #endif
        self.init(storage: KeychainAccountVaultStorage(), defaults: .standard, resetSavedAccounts: reset)
    }

    init(storage: any AccountVaultStorage, defaults: UserDefaults, resetSavedAccounts: Bool = false,
         services: SessionAccountServices = .jellyfin) {
        self.storage = storage
        self.defaults = defaults
        self.services = services
        pendingReset = resetSavedAccounts
        privateViewing = defaults.bool(forKey: "privateViewing")
        if let stored = defaults.string(forKey: "deviceID") { deviceID = stored }
        else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "deviceID")
        }
        try? retrySavedAccounts()
    }

    func retrySavedAccounts() throws {
        do {
            if pendingReset {
                try storage.clear()
                pendingReset = false
            }
            let stored = try storage.read()
            let becameAvailable = !savedAccountsAvailable
            if stored != vault || becameAvailable { mutationGeneration = UUID() }
            if stored.active != vault.active || becameAvailable { revision = UUID() }
            vault = stored
            savedAccountsAvailable = true
        } catch {
            if savedAccountsAvailable {
                mutationGeneration = UUID()
                revision = UUID()
            }
            savedAccountsAvailable = false
            throw SavedAccountStorageError.unavailable
        }
    }

    private func prepareMutation() throws {
        try Task.checkCancellation()
        try retrySavedAccounts()
    }
    var api: JellyfinAPI? {
        account.map { JellyfinAPI(server: $0.server, token: $0.token, userID: $0.userID, deviceID: deviceID, historyEnabled: !privateViewing) }
    }
    func signIn(server: String, username: String, password: String) async throws {
        try prepareMutation()
        let generation = mutationGeneration
        let protectedAccounts = vault.accounts
        let url = try JellyfinAPI.normalize(server)
        let result = try await services.authenticate(url, username.trimmingCharacters(in: .whitespacesAndNewlines), password, deviceID)
        do {
            try Task.checkCancellation()
            guard mutationGeneration == generation else { throw CancellationError() }
            try await accept(result)
        } catch {
            await Task { @MainActor in
                do {
                    // Read and decide inside this cancellation-independent job.
                    // Nothing suspends between ownership validation and invocation.
                    try retrySavedAccounts()
                    let references = AccountVault(accounts: protectedAccounts + vault.accounts)
                    if try !SessionAccountServices.hasRemainingTokenReference(result, remaining: references) {
                        do { try await services.revoke(result, deviceID) }
                        catch { appendNotice("Sign-in did not finish. Cleanup of its returned server session could not be confirmed.") }
                    }
                } catch {
                    appendNotice("Sign-in did not finish. Its server session was not revoked because saved connection references could not be verified.")
                }
            }.value
            throw error
        }
    }
    func accept(_ result: Account) async throws {
        try prepareMutation()
        let url = result.server
        var updated = vault
        updated.remember(result)
        try storage.save(updated)
        defaults.set(url.absoluteString, forKey: "lastServer")
        vault = updated
        mutationGeneration = UUID()
        revision = UUID()
        await ArtworkPipeline.shared.clear()
    }
    func select(_ account: Account) async throws {
        try prepareMutation()
        guard vault.accounts.contains(where: { $0.id == account.id }) else { return }
        guard account.id != vault.activeID else { return }
        var updated = vault
        updated.select(account.id)
        try storage.save(updated)
        vault = updated
        mutationGeneration = UUID()
        revision = UUID()
        await ArtworkPipeline.shared.clear()
    }
    func remove(_ account: Account, localCleanup: () -> Void = {}) async throws {
        try prepareMutation()
        guard let storedAccount = vault.accounts.first(where: { $0.id == account.id }) else { return }
        let generation = mutationGeneration
        await beforeRemove?(storedAccount)
        try Task.checkCancellation()
        guard mutationGeneration == generation else { throw CancellationError() }
        await services.finishCasting(storedAccount.id)
        try Task.checkCancellation()
        guard mutationGeneration == generation else { throw CancellationError() }
        try retrySavedAccounts()
        guard vault.accounts.first(where: { $0.id == storedAccount.id }) == storedAccount else { throw CancellationError() }
        let wasActive = vault.activeID == storedAccount.id
        var updated = vault
        updated.remove(storedAccount.id)
        try storage.save(updated)
        vault = updated
        mutationGeneration = UUID()
        do {
            try services.removeCredentials(storedAccount, updated)
        } catch { notice = "The Jellyfin sign-in was removed, but additional saved credentials need another cleanup attempt: " + error.localizedDescription }
        localCleanup()
        afterRemove?(storedAccount)
        if wasActive { revision = UUID() }
        await ArtworkPipeline.shared.clear()
        URLCache.shared.removeAllCachedResponses()
        let stillReferenced: Bool
        do {
            try retrySavedAccounts()
            stillReferenced = try SessionAccountServices.hasRemainingTokenReference(storedAccount, remaining: vault)
        } catch {
            appendNotice("Removed from this device. The server session was not revoked because saved connection references could not be verified.")
            return
        }
        if !stillReferenced {
            do { try await services.revoke(storedAccount, deviceID) }
            catch { appendNotice("Removed from this device. The server was unavailable to revoke its session.") }
        }
    }
    func signOut(localCleanup: () -> Void = {}) async throws {
        try prepareMutation()
        if let account { try await remove(account, localCleanup: localCleanup) }
    }
}
