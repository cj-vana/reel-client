import XCTest
@testable import Reel

final class ServerPreferencesTests: XCTestCase {
    func testPluginImportRetainsOnlyWhitelistedSettingsAndLocks() throws {
        let input = Data(#"{"settings":{"forwardSkipTime":{"value":30,"locked":true},"rewindSkipTime":{"value":10},"defaultPlaybackSpeed":{"value":1.5,"locked":true},"defaultBitrate":{"value":4000000,"locked":true},"skipIntro":{"value":"ask","locked":false},"jellyseerrApiKey":{"value":"fixture-admin-key-must-not-be-retained","locked":false},"home":{"value":{"sections":[{"custom":{"endpoint":"https://evil.example","headers":{"Authorization":"secret"}}}]}}},"notifications":{"arbitrary":"not-retained"}}"#.utf8)
        let settings = try ImportedServerSettings.decode(input)
        XCTAssertEqual(settings.forwardSkipTime?.value, 30)
        XCTAssertEqual(settings.forwardSkipTime?.locked, true)
        XCTAssertEqual(settings.rewindSkipTime?.locked, false)
        XCTAssertEqual(settings.defaultPlaybackSpeed?.value, 1.5)
        XCTAssertEqual(settings.defaultBitrate?.value, 4_000_000)
        let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        for forbidden in ["jellyseerr", "fixture-admin", "notifications", "evil.example", "Authorization"] { XCTAssertFalse(encoded.contains(forbidden), forbidden) }
    }

    func testOutOfRangeServerValuesUseNativeFallback() throws {
        let input = Data(#"{"settings":{"forwardSkipTime":{"value":-100,"locked":true},"rewindSkipTime":{"value":99999},"defaultPlaybackSpeed":{"value":100},"defaultBitrate":{"value":-20}}}"#.utf8)
        XCTAssertTrue(try ImportedServerSettings.decode(input).isEmpty)
    }

    @MainActor func testCastRequestRetainsLockedBitrateSnapshotAcrossPreferencesChange() async throws {
        let suite = "Reel.CastQualityTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ServerPreferences(defaults: defaults)
        let user = "cast-quality-" + UUID().uuidString
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-" + user, userID: user, deviceID: "cast-quality-tests", historyEnabled: false)
        let account = api.server.absoluteString + "|" + user
        preferences.setEnabled(true, accountID: account)
        await preferences.activate(accountID: account, api: api)
        XCTAssertEqual(preferences.status, .ready)
        XCTAssertTrue(preferences.bitrateLocked)
        let capturedBitrate = preferences.bitrate(local: StreamQuality.original.rawValue)
        XCTAssertEqual(capturedBitrate, 4_000_000)
        let item = try await api.item("movie-1")
        let preparation = Task { try await api.prepareCast(item, position: 7, bitrate: capturedBitrate, mediaSourceID: "movie-1-alternate", audioIndex: 4, subtitleIndex: -1) }
        // The pending handoff owns its quality snapshot even if preferences change before it resumes.
        preferences.setEnabled(false, accountID: account)
        XCTAssertEqual(preferences.bitrate(local: StreamQuality.dataSaver.rawValue), 2_000_000)
        var plans: [CastPlaybackPlan] = []
        func cleanup() async {
            let reporter = PlaybackReporter()
            for plan in plans {
                if plan.source.RequiresClosing == true, let liveID = plan.source.LiveStreamId {
                    reporter.enqueue(api: api, endpoint: "", body: ["LiveStreamId": liveID, "CleanupEncoder": false], cleanup: true)
                }
                if plan.method != "DirectPlay" {
                    reporter.enqueue(api: api, endpoint: "", body: ["PlaySessionId": plan.sessionID, "CleanupEncoder": true], cleanup: true)
                }
            }
            await reporter.flush()
        }
        do {
            plans.append(try await preparation.value)
            plans.append(try await api.prepareCast(item, position: 7, bitrate: StreamQuality.original.rawValue, mediaSourceID: "movie-1-alternate", audioIndex: 4, subtitleIndex: -1))
            let stateData = try await api.send(api.request("qa/state"))
            let state = try JSONSerialization.jsonObject(with: stateData) as? [String: Any]
            let reports = try XCTUnwrap(state?["reports"] as? [[String: Any]])
            let negotiations = reports.filter { $0["user"] as? String == user && $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }
            XCTAssertEqual(negotiations.count, 2)
            for (index, expected) in [4_000_000, 20_000_000].enumerated() {
                guard negotiations.indices.contains(index) else { throw ReelError.invalidResponse }
                let body = try XCTUnwrap(negotiations[index]["body"] as? [String: Any])
                let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
                XCTAssertEqual(body["MaxStreamingBitrate"] as? Int, expected)
                XCTAssertEqual(profile["MaxStreamingBitrate"] as? Int, expected)
                XCTAssertEqual(body["MediaSourceId"] as? String, "movie-1-alternate")
                XCTAssertEqual(body["AudioStreamIndex"] as? Int, 4)
                XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, -1)
                XCTAssertEqual(body["StartTimeTicks"] as? Int, 70_000_000)
            }
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    @MainActor func testPreferencesImportPersistenceIsolationAndDisable() async throws {
        let suite = "Reel.ServerPreferencesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ServerPreferences(defaults: defaults)
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-prefs", userID: "prefs", deviceID: "preferences-tests")
        let account = api.server.absoluteString + "|prefs"
        preferences.setEnabled(true, accountID: account)
        await preferences.activate(accountID: account, api: api)
        XCTAssertEqual(preferences.status, .ready)
        XCTAssertEqual(preferences.playbackRate(), 1.25)
        XCTAssertEqual(preferences.forwardSkip(), 30)
        XCTAssertEqual(preferences.rewindSkip(), 10)
        XCTAssertEqual(preferences.bitrate(local: 20_000_000), 4_000_000)
        XCTAssertTrue(preferences.rateLocked)
        await preferences.activate(accountID: "different-account", api: api)
        XCTAssertFalse(preferences.enabled)
        XCTAssertEqual(preferences.playbackRate(), 1)
        let restored = ServerPreferences(defaults: defaults)
        await restored.activate(accountID: account, api: api)
        XCTAssertTrue(restored.enabled)
        XCTAssertTrue(restored.rateLocked)
        restored.setEnabled(false, accountID: account)
        // With the server's preferences off, the app's own ten-second skip applies.
        XCTAssertEqual(restored.forwardSkip(), 10)
        XCTAssertEqual(restored.playbackRate(), 1)
        restored.clear(accountID: account)
    }
}

@MainActor final class SavedAccountRecoveryTests: XCTestCase {
    private final class Store: AccountVaultStorage {
        var bytes: Data?
        var readFails = false
        var saveFails = false
        var clearFails = false
        var reads = 0
        var saves = 0
        var clears = 0
        init(_ vault: AccountVault = AccountVault()) throws { bytes = try JSONEncoder().encode(vault) }
        func read() throws -> AccountVault {
            reads += 1
            if readFails { throw ReelError.storage }
            return try bytes.map(AccountVault.decode) ?? AccountVault()
        }
        func save(_ vault: AccountVault) throws {
            saves += 1
            if saveFails { throw ReelError.storage }
            bytes = try JSONEncoder().encode(vault)
        }
        func clear() throws {
            clears += 1
            if clearFails { throw ReelError.storage }
            bytes = nil
        }
    }

    @MainActor private final class Services {
        var result: Account
        var authentications = 0
        var revoked: [Account] = []
        var cleaned: [Account] = []
        var suspend = false
        var finishCasting: (String) async -> Void = { _ in }
        var pending: CheckedContinuation<Account, any Error>?
        init(_ result: Account) { self.result = result }
        var value: SessionAccountServices {
            SessionAccountServices(authenticate: { _, _, _, _ in
                self.authentications += 1
                if self.suspend { return try await withCheckedThrowingContinuation { self.pending = $0 } }
                return self.result
            }, revoke: { account, _ in self.revoked.append(account) },
               finishCasting: { await self.finishCasting($0) }, removeCredentials: { account, _ in self.cleaned.append(account) })
        }
    }

    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() async throws {
        suite = "Reel.SavedAccountRecoveryTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        suite = nil
    }
    private func account(_ name: String, token: String? = nil) -> Account {
        Account(server: URL(string: "https://\(name).invalid/jellyfin")!, token: token ?? "synthetic-\(name)", userID: name, name: name, serverName: "Synthetic \(name)")
    }
    private func session(_ store: Store, services: Services? = nil, reset: Bool = false) -> Session {
        Session(storage: store, defaults: defaults, resetSavedAccounts: reset, services: (services ?? Services(account("new"))).value)
    }
    private func waitForAuthentication(_ services: Services) async throws {
        for _ in 0..<100 {
            if services.pending != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The disposable authentication did not start.")
        throw ReelError.invalidResponse
    }

    @MainActor private final class CastGate {
        var entered = false
        private var pending: CheckedContinuation<Void, Never>?
        func wait() async { entered = true; await withCheckedContinuation { pending = $0 } }
        func release() { pending?.resume(); pending = nil }
    }
    private func waitForCast(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Owned account cleanup did not settle"); throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func removeAfterCanceledCast(activeRemoval: Bool, cancelInBeforeRemove: Bool) async throws {
        let first = account("cast-first"), second = account("cast-second")
        let store = try Store(AccountVault(accounts: [first, second], activeID: activeRemoval ? first.id : second.id))
        let services = Services(account("unused")), work = CastAccountWork()
        let preparation = CastGate(), cleanup = CastGate(), newerAccount = CastGate()
        var events: [String] = [], drained: [String] = []
        let old = work.track(accountID: first.id) {
            await preparation.wait()
            work.track(accountID: first.id) { await cleanup.wait(); events.append("cleanup-first") }
        }
        let newer = work.track(accountID: second.id) { await newerAccount.wait(); events.append("cleanup-second") }
        defer { preparation.release(); cleanup.release(); newerAccount.release(); old.cancel(); newer.cancel() }
        try await waitForCast { preparation.entered && newerAccount.entered }
        services.finishCasting = { id in drained.append(id); await work.flush(accountID: id); events.append("drained-first") }
        let session = session(store, services: services)
        session.beforeRemove = { _ in if cancelInBeforeRemove { old.cancel() } }
        if !cancelInBeforeRemove { old.cancel() } // Routes dismissal/account replacement cleared current UI ownership.
        let removal = Task { try await session.remove(first); events.append("removed-first") }
        defer { removal.cancel() }
        try await waitForCast { drained == [first.id] }
        XCTAssertTrue(services.revoked.isEmpty)
        XCTAssertEqual(session.accounts.count, 2)
        preparation.release()
        try await waitForCast { cleanup.entered }
        XCTAssertTrue(services.revoked.isEmpty, "Late preparation cleanup must finish before Logout.")
        cleanup.release()
        try await waitForCast { services.revoked == [first] }
        try await removal.value
        XCTAssertEqual(events, ["cleanup-first", "drained-first", "removed-first"])
        XCTAssertEqual(session.account, second)
        XCTAssertEqual(services.cleaned, [first])
        XCTAssertFalse(events.contains("cleanup-second"), "Removing A must neither stop nor wait for newer B's owned work.")
        newerAccount.release(); await newer.value
        XCTAssertEqual(events.last, "cleanup-second")
    }
    func testRoutesCanceledCastCleanupDrainsBeforeOriginalAccountLogout() async throws {
        try await removeAfterCanceledCast(activeRemoval: true, cancelInBeforeRemove: false)
    }
    func testInactiveOriginalCastAccountRemovalDrainsOnlyItsLatePreparation() async throws {
        try await removeAfterCanceledCast(activeRemoval: false, cancelInBeforeRemove: false)
    }
    func testCurrentAccountPlayerTeardownCancelStillDrainsCastBeforeLogout() async throws {
        try await removeAfterCanceledCast(activeRemoval: true, cancelInBeforeRemove: true)
    }

    func testUnavailableReadNeverBecomesAnEmptyWritableVault() async throws {
        let first = account("first"), second = account("second"), new = account("new")
        let store = try Store(AccountVault(accounts: [first, second], activeID: second.id))
        let original = store.bytes
        store.readFails = true
        let services = Services(new)
        let session = session(store, services: services)
        var cleanup = 0
        session.beforeRemove = { _ in cleanup += 1 }
        XCTAssertFalse(session.savedAccountsAvailable)
        XCTAssertNil(session.account)
        XCTAssertNil(session.api)
        XCTAssertTrue(session.accounts.isEmpty)
        for _ in 0..<2 {
            do { try await session.accept(new); XCTFail("Acceptance wrote without a readable vault") } catch { }
            do { try await session.signIn(server: new.server.absoluteString, username: new.name, password: "synthetic"); XCTFail("Authentication started without a readable vault") } catch { }
            do { try await session.select(second); XCTFail("Selection bypassed the storage gate") } catch { }
            do { try await session.remove(first) { cleanup += 1 }; XCTFail("Removal bypassed the storage gate") } catch { }
            do { try await session.signOut { cleanup += 1 }; XCTFail("Sign-out bypassed the storage gate") } catch { }
            XCTAssertThrowsError(try session.retrySavedAccounts())
        }
        XCTAssertEqual(store.saves, 0, "The fake store would accept a write, reproducing the dangerous read-failed/write-allowed boundary.")
        XCTAssertEqual(store.clears, 0)
        XCTAssertEqual(store.bytes, original)
        XCTAssertEqual(services.authentications, 0)
        XCTAssertTrue(services.revoked.isEmpty)
        XCTAssertTrue(services.cleaned.isEmpty)
        XCTAssertEqual(cleanup, 0)
        XCTAssertNil(defaults.string(forKey: "lastServer"))
    }

    func testRetryRestoresAllAccountsAndAcceptanceMergesRecoveredBytes() async throws {
        let first = account("first"), second = account("second"), new = account("new")
        let store = try Store(AccountVault(accounts: [first, second], activeID: second.id))
        store.readFails = true
        let session = session(store)
        store.readFails = false
        try session.retrySavedAccounts()
        XCTAssertTrue(session.savedAccountsAvailable)
        XCTAssertEqual(session.accounts, [first, second])
        XCTAssertEqual(session.account, second)
        XCTAssertEqual(store.saves, 0, "Recovery itself only reads.")
        // Simulate another saved connection appearing after the Retry snapshot.
        let concurrent = account("concurrent")
        store.bytes = try JSONEncoder().encode(AccountVault(accounts: [first, second, concurrent], activeID: first.id))
        try await session.accept(new)
        XCTAssertEqual(try store.read().accounts, [first, second, concurrent, new])
        XCTAssertEqual(session.account, new)
        XCTAssertEqual(defaults.string(forKey: "lastServer"), new.server.absoluteString)
        let restored = self.session(store)
        XCTAssertEqual(restored.accounts, [first, second, concurrent, new])
        XCTAssertEqual(restored.account, new)
    }

    func testAcceptCanRecoverDirectlyButRepeatedDecodingFailuresPreserveBytes() async throws {
        let first = account("first"), new = account("new")
        let store = try Store(AccountVault(accounts: [first], activeID: first.id))
        store.readFails = true
        let session = session(store)
        store.readFails = false
        try await session.accept(new)
        XCTAssertEqual(session.accounts, [first, new])
        for malformed in [Data("not json".utf8), try JSONEncoder().encode(AccountVault(accounts: [first, first], activeID: first.id)), try JSONEncoder().encode(AccountVault(accounts: [first], activeID: "missing"))] {
            store.bytes = malformed
            let saves = store.saves
            let broken = self.session(store)
            XCTAssertFalse(broken.savedAccountsAvailable)
            for _ in 0..<2 {
                do { try await broken.accept(new); XCTFail("Malformed saved bytes were replaced") } catch { }
                XCTAssertThrowsError(try broken.retrySavedAccounts())
            }
            XCTAssertEqual(store.bytes, malformed)
            XCTAssertEqual(store.saves, saves)
            store.bytes = try JSONEncoder().encode(AccountVault(accounts: [first], activeID: first.id))
            try broken.retrySavedAccounts()
            XCTAssertEqual(broken.account, first)
        }
    }

    func testNormalEmptyVaultLegacyReadReauthenticationAndSelection() async throws {
        let first = account("first"), second = account("second")
        let store = try Store()
        store.bytes = nil
        let session = session(store)
        XCTAssertTrue(session.savedAccountsAvailable)
        XCTAssertNil(session.account)
        try await session.accept(first)
        try await session.accept(second)
        let refreshed = account("first", token: "synthetic-refreshed")
        try await session.accept(refreshed)
        XCTAssertEqual(session.accounts, [refreshed, second])
        let saves = store.saves
        try await session.select(refreshed)
        try await session.select(account("missing"))
        XCTAssertEqual(store.saves, saves, "Same and unknown selections must not create writes.")
        try await session.select(second)
        XCTAssertEqual(session.account, second)
        store.bytes = try JSONEncoder().encode(first)
        try session.retrySavedAccounts()
        XCTAssertEqual(session.accounts, [first], "Legacy single-account data remains readable without an automatic migration write.")
        XCTAssertEqual(session.account, first)
    }

    func testReadFailureAfterInitialSuccessBlocksAllMutationSideEffectsUntilRetry() async throws {
        let first = account("first"), second = account("second")
        let store = try Store(AccountVault(accounts: [first, second], activeID: first.id))
        let session = session(store)
        let original = store.bytes
        store.readFails = true
        let revision = session.revision
        do { try await session.select(second); XCTFail("A later read failure allowed a write") } catch { }
        XCTAssertFalse(session.savedAccountsAvailable)
        XCTAssertNil(session.api)
        XCTAssertNotEqual(session.revision, revision, "Active consumers must detach when saved credentials become unavailable.")
        XCTAssertEqual(session.vault.accounts, [first, second], "The last known vault is retained internally, not replaced with empty data.")
        XCTAssertEqual(store.bytes, original)
        XCTAssertEqual(store.saves, 0)
        store.readFails = false
        try session.retrySavedAccounts()
        XCTAssertEqual(session.account, first)
    }

    func testFailedWritesDoNotCommitAccountsSelectionDefaultsOrCleanup() async throws {
        let first = account("first"), second = account("second"), new = account("new")
        let store = try Store(AccountVault(accounts: [first, second], activeID: first.id))
        let services = Services(new)
        let session = session(store, services: services)
        let original = store.bytes, revision = session.revision
        store.saveFails = true
        var cleaned = false
        do { try await session.accept(new); XCTFail("Failed save committed") } catch { }
        do { try await session.select(second); XCTFail("Failed selection committed") } catch { }
        do { try await session.remove(first) { cleaned = true }; XCTFail("Failed removal committed") } catch { }
        XCTAssertEqual(store.bytes, original)
        XCTAssertEqual(session.account, first)
        XCTAssertEqual(session.accounts, [first, second])
        XCTAssertEqual(session.revision, revision)
        XCTAssertNil(defaults.string(forKey: "lastServer"))
        XCTAssertFalse(cleaned)
        XCTAssertTrue(services.cleaned.isEmpty)
        XCTAssertTrue(services.revoked.isEmpty)
        store.saveFails = false
        try await session.select(second)
        XCTAssertEqual(session.account, second)
    }

    func testRemovalRereadsAfterAwaitAndPreservesConcurrentlyStoredAccounts() async throws {
        let first = account("first"), second = account("second"), concurrent = account("concurrent")
        let store = try Store(AccountVault(accounts: [first, second], activeID: first.id))
        let services = Services(account("new"))
        let session = session(store, services: services)
        session.beforeRemove = { _ in
            await Task.yield()
            store.bytes = try! JSONEncoder().encode(AccountVault(accounts: [first, second, concurrent], activeID: first.id))
        }
        var cleaned = false
        try await session.remove(first) { cleaned = true }
        XCTAssertEqual(session.accounts, [second, concurrent])
        XCTAssertEqual(try store.read().accounts, [second, concurrent])
        XCTAssertEqual(session.account, second)
        XCTAssertTrue(cleaned)
        XCTAssertEqual(services.cleaned, [first])
        XCTAssertEqual(services.revoked, [first])
        session.beforeRemove = nil
        try await session.signOut()
        XCTAssertEqual(session.account, concurrent)
        try await session.signOut()
        XCTAssertTrue(session.accounts.isEmpty)
        XCTAssertNil(session.account)
        XCTAssertTrue(session.savedAccountsAvailable)
    }

    func testRemovalDoesNotDeleteChangedCredentialsOrWriteAfterReadFailureDuringCleanup() async throws {
        let first = account("first"), second = account("second")
        for replaceCredentials in [false, true] {
            let store = try Store(AccountVault(accounts: [first, second], activeID: first.id))
            let services = Services(account("new"))
            let session = session(store, services: services)
            session.beforeRemove = { _ in
                await Task.yield()
                if replaceCredentials {
                    store.bytes = try! JSONEncoder().encode(AccountVault(accounts: [self.account("first", token: "reauthenticated"), second], activeID: first.id))
                } else { store.readFails = true }
            }
            do { try await session.remove(first); XCTFail("Removal used stale credentials") } catch { }
            XCTAssertEqual(store.saves, 0)
            XCTAssertTrue(services.cleaned.isEmpty)
            XCTAssertTrue(services.revoked.isEmpty)
            if replaceCredentials { XCTAssertEqual(try store.read().active?.token, "reauthenticated") }
            else { XCTAssertFalse(session.savedAccountsAvailable) }
        }
    }

    func testCancelledAcceptanceAndStalePasswordAuthenticationCannotSave() async throws {
        let first = account("first"), second = account("second"), new = account("new")
        let store = try Store(AccountVault(accounts: [first, second], activeID: first.id))
        let services = Services(new)
        let session = session(store, services: services)
        let cancelled = Task { try await session.accept(new) }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled acceptance committed") } catch is CancellationError { }
        XCTAssertEqual(store.saves, 0)
        services.suspend = true
        let signingIn = Task { try await session.signIn(server: new.server.absoluteString, username: "new", password: "synthetic") }
        try await waitForAuthentication(services)
        try await session.select(second)
        services.pending?.resume(returning: new); services.pending = nil
        do { try await signingIn.value; XCTFail("Stale authentication committed after switching") } catch is CancellationError { }
        XCTAssertEqual(session.account, second)
        XCTAssertEqual(store.saves, 1)
        XCTAssertEqual(services.revoked, [new])
    }

    func testCancelledRemovalWhileCleanupIsSuspendedDoesNotWriteOrRevoke() async throws {
        let first = account("first"), second = account("second")
        let store = try Store(AccountVault(accounts: [first, second], activeID: first.id))
        let original = store.bytes
        let services = Services(account("new"))
        let session = session(store, services: services)
        var pending: CheckedContinuation<Void, Never>?
        session.beforeRemove = { _ in await withCheckedContinuation { pending = $0 } }
        var cleaned = false
        let removing = Task { try await session.remove(first) { cleaned = true } }
        defer { removing.cancel(); pending?.resume(); session.beforeRemove = nil }
        for _ in 0..<100 {
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let continuation = try XCTUnwrap(pending)
        removing.cancel()
        pending = nil
        continuation.resume()
        do { try await removing.value; XCTFail("Cancelled removal committed after cleanup returned") } catch is CancellationError { }
        XCTAssertEqual(store.bytes, original)
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(session.account, first)
        XCTAssertFalse(cleaned)
        XCTAssertTrue(services.cleaned.isEmpty)
        XCTAssertTrue(services.revoked.isEmpty)
    }

    func testLocalAccountMutationDuringAwaitedRemovalRejectsStaleRemoval() async throws {
        let first = account("first"), second = account("second"), new = account("new")
        for accepting in [false, true] {
            let store = try Store(AccountVault(accounts: [first, second], activeID: first.id))
            let services = Services(new)
            let session = session(store, services: services)
            session.beforeRemove = { _ in
                if accepting { try? await session.accept(new) }
                else { try? await session.select(second) }
            }
            defer { session.beforeRemove = nil }
            var cleaned = false
            do { try await session.remove(first) { cleaned = true }; XCTFail("Stale removal committed after another account mutation") } catch is CancellationError { }
            XCTAssertEqual(store.saves, 1, "Only the intervening selection or acceptance may save.")
            XCTAssertEqual(session.account, accepting ? new : second)
            XCTAssertEqual(try store.read().accounts, accepting ? [first, second, new] : [first, second])
            XCTAssertFalse(cleaned)
            XCTAssertTrue(services.cleaned.isEmpty)
            XCTAssertTrue(services.revoked.isEmpty)
        }
    }

    func testCancelledPasswordAuthenticationRevokesOnlyNewTokens() async throws {
        let first = account("first")
        for result in [first, account("new")] {
            let store = try Store(AccountVault(accounts: [first], activeID: first.id))
            let services = Services(result)
            services.suspend = true
            let session = session(store, services: services)
            let signingIn = Task { try await session.signIn(server: result.server.absoluteString, username: result.name, password: "synthetic") }
            try await waitForAuthentication(services)
            signingIn.cancel()
            services.pending?.resume(returning: result); services.pending = nil
            do { try await signingIn.value; XCTFail("Cancelled password authentication committed") } catch is CancellationError { }
            XCTAssertEqual(store.saves, 0)
            XCTAssertEqual(session.account, first)
            XCTAssertEqual(services.revoked, result == first ? [] : [result])
        }
    }

    func testFailedResetCannotReadOrWriteUntilDeletionSucceeds() async throws {
        let first = account("first"), new = account("new")
        let store = try Store(AccountVault(accounts: [first], activeID: first.id))
        let original = store.bytes
        store.clearFails = true
        let session = session(store, reset: true)
        XCTAssertFalse(session.savedAccountsAvailable)
        XCTAssertEqual(store.reads, 0)
        do { try await session.accept(new); XCTFail("Failed deletion resumed writes") } catch { }
        XCTAssertThrowsError(try session.retrySavedAccounts())
        XCTAssertEqual(store.bytes, original)
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(store.reads, 0)
        store.clearFails = false
        try session.retrySavedAccounts()
        XCTAssertTrue(session.savedAccountsAvailable)
        XCTAssertTrue(session.accounts.isEmpty)
        try await session.accept(new)
        XCTAssertEqual(try store.read().accounts, [new])
    }
}
