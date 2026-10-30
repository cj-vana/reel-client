import XCTest
@testable import Reel

@MainActor final class BrowsePreferencesTests: XCTestCase {
    private enum Fault: Error { case unavailable }
    private final class Memory: BrowsePreferencesStorage {
        var bytes: [BrowseAccountScope: Data] = [:]
        var failRead = false
        var failWrite = false
        var failRemove = false
        var writeAttempts = 0
        func read(account: BrowseAccountScope) throws -> Data? {
            if failRead { throw Fault.unavailable }
            return bytes[account]
        }
        func write(_ data: Data, account: BrowseAccountScope) throws {
            writeAttempts += 1
            if failWrite { throw Fault.unavailable }
            bytes[account] = data
        }
        func remove(account: BrowseAccountScope) throws {
            if failRemove { throw Fault.unavailable }
            bytes[account] = nil
        }
    }
    private func account(_ user: String = "A", _ server: String = "https://fixture.example/jellyfin") throws -> BrowseAccountScope {
        try BrowseAccountScope(server: URL(string: server)!, userID: user)
    }
    private var scope: BrowseScope { BrowseScope(libraryID: "shows", category: "Series") }
    private var complex: BrowseChoices {
        BrowseChoices(sort: .latestEpisodeAdded, direction: .ascending, genreID: "drama", watchStatus: "Unwatched", favoritesOnly: true, viewStyle: .grid)
    }
    private func document(_ account: BrowseAccountScope, choices: BrowseChoices) -> BrowseDocument {
        var value = BrowseDocument(account: account)
        value.root = BrowseRootLocation(libraryID: "shows", category: "Series")
        value.entries = [.init(scope: scope, choices: choices)]
        return value
    }
    private func encoded(_ value: BrowseDocument) throws -> Data { try JSONEncoder().encode(value) }
    private func durable(_ memory: Memory, _ account: BrowseAccountScope) throws -> BrowseDocument {
        try JSONDecoder().decode(BrowseDocument.self, from: XCTUnwrap(memory.bytes[account]))
    }

    func testNormalizedServerUserAndBasepathIdentity() throws {
        XCTAssertEqual(try account("A", "https://FIXTURE.example:443/jellyfin/"), try account())
        XCTAssertNotEqual(try account("a"), try account())
        XCTAssertNotEqual(try account("A", "https://fixture.example/other"), try account())
        XCTAssertNotEqual(try account("A", "https://fixture.example:8443/jellyfin"), try account())
        XCTAssertNotEqual(try account("A", "https://fixture.example/Jellyfin"), try account())
    }
    func testInvalidAccountIdentityRejected() throws {
        for text in ["ftp://fixture.example", "https://user:password@fixture.example", "https://fixture.example?token=x", "https://fixture.example/#fragment"] {
            XCTAssertThrowsError(try account("A", text), text)
        }
        XCTAssertThrowsError(try account(""))
    }
    func testMissingStorageDoesNotWriteAndFullChoicesRestoreInNewStore() throws {
        let key = try account(), memory = Memory(), store = BrowsePreferencesStore(storage: Memory())
        _ = store.activate(key)
        let first = BrowsePreferencesStore(storage: memory)
        XCTAssertEqual(first.choices(for: scope, account: key), BrowseChoices())
        XCTAssertEqual(memory.writeAttempts, 0)
        XCTAssertTrue(first.save(complex, for: scope, account: key))
        XCTAssertEqual(BrowsePreferencesStore(storage: memory).choices(for: scope, account: key), complex)
    }
    func testUnreadableViewEditMakesNoWriteAndRecoveryMergesPredicates() throws {
        let key = try account(), memory = Memory(); memory.failRead = true
        let store = BrowsePreferencesStore(storage: memory)
        _ = store.activate(key)
        XCTAssertFalse(store.saveViewStyle(.list, for: scope, account: key))
        XCTAssertEqual(memory.writeAttempts, 0)
        XCTAssertEqual(store.status(for: key), .unavailable)
        memory.bytes[key] = try encoded(document(key, choices: complex)); memory.failRead = false
        XCTAssertTrue(store.retry(key))
        var expected = complex; expected.viewStyle = .list
        XCTAssertEqual(try durable(memory, key).choices(for: scope), expected)
        XCTAssertEqual(try durable(memory, key).root, document(key, choices: complex).root)
    }
    func testCorruptBytesRemainUntouchedUntilSuccessfulRecovery() throws {
        let key = try account(), memory = Memory(), corrupt = Data("{broken".utf8)
        memory.bytes[key] = corrupt
        let store = BrowsePreferencesStore(storage: memory)
        XCTAssertFalse(store.saveViewStyle(.list, for: scope, account: key))
        XCTAssertEqual(memory.bytes[key], corrupt)
        XCTAssertFalse(store.retry(key)); XCTAssertEqual(memory.writeAttempts, 0)
        memory.bytes[key] = try encoded(document(key, choices: complex))
        XCTAssertTrue(store.retry(key))
        var expected = complex; expected.viewStyle = .list
        XCTAssertEqual(try durable(memory, key).choices(for: scope), expected)
    }
    func testUnknownVersionPreservedWithoutAutomaticReset() throws {
        let key = try account(), memory = Memory()
        var unknown = document(key, choices: complex); unknown.version = 99
        let bytes = try encoded(unknown); memory.bytes[key] = bytes
        let store = BrowsePreferencesStore(storage: memory)
        _ = store.activate(key)
        XCTAssertEqual(store.status(for: key), .unavailable)
        XCTAssertFalse(store.saveViewStyle(.list, for: scope, account: key))
        XCTAssertEqual(memory.bytes[key], bytes); XCTAssertEqual(memory.writeAttempts, 0)
    }
    func testFailedViewWritesKeepLatestFieldOnlyIntentAcrossRecovery() throws {
        let key = try account(), memory = Memory(); memory.bytes[key] = try encoded(document(key, choices: complex))
        let store = BrowsePreferencesStore(storage: memory); _ = store.activate(key); memory.failWrite = true
        XCTAssertFalse(store.saveViewStyle(.list, for: scope, account: key))
        XCTAssertFalse(store.saveViewStyle(.grid, for: scope, account: key))
        XCTAssertEqual(store.status(for: key), .dirty)
        var recovered = complex; recovered.sort = .releaseYear; recovered.genreID = "comedy"; recovered.watchStatus = "Watched"
        memory.bytes[key] = try encoded(document(key, choices: recovered)); memory.failWrite = false
        XCTAssertTrue(store.retry(key))
        XCTAssertEqual(try durable(memory, key).choices(for: scope), recovered)
        XCTAssertEqual(memory.writeAttempts, 3)
    }
    func testExplicitFullSaveThenViewPatchRetainsBothUserIntents() throws {
        let key = try account(), memory = Memory(); memory.failRead = true
        let store = BrowsePreferencesStore(storage: memory)
        XCTAssertFalse(store.save(complex, for: scope, account: key))
        XCTAssertFalse(store.saveViewStyle(.list, for: scope, account: key))
        memory.bytes[key] = try encoded(document(key, choices: BrowseChoices())); memory.failRead = false
        XCTAssertTrue(store.retry(key))
        var expected = complex; expected.viewStyle = .list
        XCTAssertEqual(try durable(memory, key).choices(for: scope), expected)
    }
    func testViewPatchThenExplicitFullSaveUsesLatestCompleteChoice() throws {
        let key = try account(), memory = Memory(); memory.failRead = true
        let store = BrowsePreferencesStore(storage: memory)
        XCTAssertFalse(store.saveViewStyle(.list, for: scope, account: key))
        XCTAssertFalse(store.save(complex, for: scope, account: key))
        memory.bytes[key] = try encoded(document(key, choices: BrowseChoices())); memory.failRead = false
        XCTAssertTrue(store.retry(key))
        XCTAssertEqual(try durable(memory, key).choices(for: scope), complex)
    }
    func testViewOnlyRecoveryPreservesOtherScopeAndAccount() throws {
        let key = try account(), other = try account("B"), memory = Memory(), secondScope = BrowseScope(libraryID: "films", category: "Movies")
        var saved = document(key, choices: complex); saved.entries.append(.init(scope: secondScope, choices: complex))
        memory.bytes[other] = try encoded(document(other, choices: complex)); let otherBytes = memory.bytes[other]
        memory.failRead = true; let store = BrowsePreferencesStore(storage: memory)
        XCTAssertFalse(store.saveViewStyle(.list, for: scope, account: key))
        memory.bytes[key] = try encoded(saved); memory.failRead = false
        XCTAssertTrue(store.retry(key))
        XCTAssertEqual(try durable(memory, key).choices(for: secondScope), complex)
        XCTAssertEqual(memory.bytes[other], otherBytes)
    }
    func testRecoveryDoesNotTrimCapacityAndRetainsPendingPatch() throws {
        let key = try account(), memory = Memory()
        var saved = BrowseDocument(account: key)
        saved.entries = (0..<256).map { .init(scope: BrowseScope(libraryID: "library-\($0)"), choices: complex) }
        let full = try encoded(saved); memory.bytes[key] = full
        let store = BrowsePreferencesStore(storage: memory), extra = BrowseScope(libraryID: "extra")
        XCTAssertFalse(store.saveViewStyle(.list, for: extra, account: key))
        XCTAssertEqual(memory.bytes[key], full); XCTAssertEqual(store.status(for: key), .dirty)
        saved.entries.removeLast(); memory.bytes[key] = try encoded(saved)
        XCTAssertTrue(store.retry(key))
        let result = try durable(memory, key)
        XCTAssertEqual(result.entries.count, 256); XCTAssertEqual(result.choices(for: extra).viewStyle, .list)
        XCTAssertEqual(result.choices(for: BrowseScope(libraryID: "library-0")), complex)
    }
    func testFailedResetRetainsPendingAndOtherAccount() throws {
        let key = try account(), other = try account("B"), memory = Memory(); memory.failRead = true
        memory.bytes[other] = try encoded(document(other, choices: complex)); let otherBytes = memory.bytes[other]
        let store = BrowsePreferencesStore(storage: memory)
        XCTAssertFalse(store.saveViewStyle(.list, for: scope, account: key))
        memory.failWrite = true; XCTAssertFalse(store.reset(key))
        XCTAssertEqual(store.choices(for: scope, account: key).viewStyle, .list)
        XCTAssertEqual(memory.bytes[other], otherBytes)
        memory.failWrite = false; XCTAssertTrue(store.reset(key))
        XCTAssertEqual(store.choices(for: scope, account: key), BrowseChoices())
        XCTAssertEqual(memory.bytes[other], otherBytes)
    }
    func testAccountRemovalIsScopedAndFailedRemovalRetainsState() throws {
        let key = try account(), other = try account("B"), memory = Memory()
        let store = BrowsePreferencesStore(storage: memory)
        XCTAssertTrue(store.save(complex, for: scope, account: key)); XCTAssertTrue(store.save(complex, for: scope, account: other))
        let otherBytes = memory.bytes[other]; memory.failRemove = true
        XCTAssertFalse(store.removeAccount(key)); XCTAssertEqual(store.choices(for: scope, account: key), complex)
        memory.failRemove = false; XCTAssertTrue(store.removeAccount(key))
        XCTAssertNil(memory.bytes[key]); XCTAssertEqual(memory.bytes[other], otherBytes)
    }
    func testWrongAccountDocumentCannotBeOverwrittenByActivation() throws {
        let key = try account(), other = try account("B"), memory = Memory()
        let wrong = try encoded(document(other, choices: complex)); memory.bytes[key] = wrong
        let store = BrowsePreferencesStore(storage: memory)
        _ = store.activate(key)
        XCTAssertEqual(store.status(for: key), .unavailable)
        XCTAssertFalse(store.saveViewStyle(.list, for: scope, account: key))
        XCTAssertEqual(memory.bytes[key], wrong); XCTAssertEqual(memory.writeAttempts, 0)
    }
    func testRemovedLibraryGenreAndInvalidCategoryValidation() {
        XCTAssertEqual(BrowseRootLocation(libraryID: "removed", category: "invalid").validated(libraryIDs: ["films"]), BrowseRootLocation())
        var choices = complex; choices.genreID = "removed"
        let repaired = choices.validated(for: BrowseScope(category: "Episodes"), genreIDs: ["drama"])
        XCTAssertEqual(repaired.genreID, ""); XCTAssertEqual(repaired.sort, .recentlyAdded)
        XCTAssertEqual(repaired.direction, .ascending); XCTAssertTrue(repaired.favoritesOnly)
    }
    func testRealFileStorageRelaunchIsolationAndRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReelBrowseTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileBrowsePreferencesStorage(directory: directory), key = try account(), other = try account("B")
        let first = BrowsePreferencesStore(storage: storage)
        XCTAssertTrue(first.save(complex, for: scope, account: key)); XCTAssertTrue(first.saveRoot(.init(libraryID: "shows", category: "Series"), account: key))
        XCTAssertTrue(first.saveViewStyle(.list, for: scope, account: other))
        let otherBytes = try storage.read(account: other)
        let relaunched = BrowsePreferencesStore(storage: storage)
        XCTAssertEqual(relaunched.choices(for: scope, account: key), complex)
        XCTAssertEqual(relaunched.activate(key).root, BrowseRootLocation(libraryID: "shows", category: "Series"))
        XCTAssertTrue(relaunched.removeAccount(key)); XCTAssertNil(try storage.read(account: key))
        XCTAssertEqual(try storage.read(account: other), otherBytes)
    }
    func testMissingRealRootReadsAbsentAndFirstExplicitSaveCreatesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReelBrowseNewRoot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileBrowsePreferencesStorage(directory: directory), key = try account()
        XCTAssertNil(try storage.read(account: key)); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let store = BrowsePreferencesStore(storage: storage)
        XCTAssertTrue(store.save(complex, for: scope, account: key))
        XCTAssertEqual(BrowsePreferencesStore(storage: storage).choices(for: scope, account: key), complex)
    }
    func testExistingRealRootMissingLeafReadsAndRemovesAbsent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReelBrowseNewLeaf-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storage = FileBrowsePreferencesStorage(directory: directory), key = try account()
        XCTAssertNil(try storage.read(account: key)); XCTAssertNoThrow(try storage.remove(account: key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try storage.file(account: key).path))
        let bytes = Data("owned browse bytes".utf8)
        try storage.write(bytes, account: key); XCTAssertEqual(try storage.read(account: key), bytes)
    }
    func testRealPermissionFailuresPreserveBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReelBrowsePermission-\(UUID())")
        let storage = FileBrowsePreferencesStorage(directory: directory), key = try account(), target = try storage.file(account: key)
        let parent = target.deletingLastPathComponent(), bytes = Data("preserve on denial".utf8)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try storage.write(bytes, account: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.path)
        XCTAssertThrowsError(try storage.read(account: key))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        XCTAssertThrowsError(try storage.write(Data("replacement".utf8), account: key))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
    func testRealNonDirectoryComponentIsNotMissingAndPreservesBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReelBrowseNotDirectory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocked = directory.appendingPathComponent("blocked"), bytes = Data("preserve file".utf8)
        try bytes.write(to: blocked)
        let storage = FileBrowsePreferencesStorage(directory: blocked), key = try account()
        XCTAssertThrowsError(try storage.read(account: key)); XCTAssertThrowsError(try storage.write(Data(), account: key)); XCTAssertThrowsError(try storage.remove(account: key))
        XCTAssertEqual(try Data(contentsOf: blocked), bytes)
    }
    func testUnexpectedLeafDirectoryAndChildrenSurviveAllStorageOperations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReelBrowseLeafType-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileBrowsePreferencesStorage(directory: directory), key = try account(), leaf = try storage.file(account: key)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        let child = leaf.appendingPathComponent("preserve.txt"), bytes = Data("preserve unexpected child".utf8)
        try bytes.write(to: child)
        XCTAssertThrowsError(try storage.read(account: key))
        XCTAssertThrowsError(try storage.write(Data("replacement".utf8), account: key))
        XCTAssertThrowsError(try storage.remove(account: key))
        let store = BrowsePreferencesStore(storage: storage); _ = store.activate(key)
        XCTAssertEqual(store.status(for: key), .unavailable)
        XCTAssertFalse(store.reset(key)); XCTAssertFalse(store.removeAccount(key))
        XCTAssertEqual(try Data(contentsOf: child), bytes)
        XCTAssertTrue(try leaf.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }
    func testAcceptedLongIdentityRealFileRoundtripAndSiblingIsolation() throws {
        let prefix = "https://fixture.example/"
        let server = URL(string: prefix + String(repeating: "p", count: 2048 - prefix.utf8.count))!
        let longA = try BrowseAccountScope(server: server, userID: String(repeating: "u", count: 512))
        let longB = try BrowseAccountScope(server: server, userID: String(repeating: "u", count: 511) + "B")
        XCTAssertEqual(longA.server.utf8.count, 2048); XCTAssertEqual(longA.userID.utf8.count, 512)
        XCTAssertNotEqual(longA, longB)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReelBrowseAcceptedBounds-\(UUID())")
        defer {
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) }
                catch { XCTFail("Owned accepted-bound fixture cleanup failed: \(error)") }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
        print("Accepted browse owned fixture: \(directory.path)")
        let storage = FileBrowsePreferencesStorage(directory: directory), short = try account()
        XCTAssertTrue(BrowsePreferencesStore(storage: storage).save(complex, for: scope, account: short))
        let shortBytes = try XCTUnwrap(storage.read(account: short))
        let path = try storage.file(account: longA)
        print("Accepted browse bounds: serverBytes=\(longA.server.utf8.count) userBytes=\(longA.userID.utf8.count) pathBytes=\(path.path.utf8.count) largestComponentBytes=\(path.pathComponents.map { $0.utf8.count }.max() ?? 0)")
        do {
            let aBytes = try encoded(document(longA, choices: complex))
            var bChoices = complex; bChoices.viewStyle = .list; bChoices.sort = .releaseYear
            let bBytes = try encoded(document(longB, choices: bChoices))
            try storage.write(aBytes, account: longA); XCTAssertEqual(try storage.read(account: longA), aBytes)
            try storage.write(bBytes, account: longB); XCTAssertEqual(try storage.read(account: longB), bBytes)
            let relaunched = BrowsePreferencesStore(storage: storage)
            XCTAssertEqual(relaunched.choices(for: scope, account: longA), complex)
            XCTAssertEqual(relaunched.choices(for: scope, account: longB), bChoices)
            XCTAssertTrue(relaunched.removeAccount(longA)); XCTAssertNil(try storage.read(account: longA))
            XCTAssertEqual(try storage.read(account: longB), bBytes)
            XCTAssertEqual(try storage.read(account: short), shortBytes)
        } catch {
            let value = error as NSError, underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError
            print("Accepted browse FS failure: domain=\(value.domain) code=\(value.code) underlyingDomain=\(underlying?.domain ?? "none") underlyingCode=\(underlying?.code ?? 0)")
            XCTAssertEqual(try storage.read(account: short), shortBytes)
            throw error
        }
    }
    func testVersionedCanonicalKeyHasStableGoldenDigestAndBoundedName() throws {
        let storage = FileBrowsePreferencesStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent("key-only"))
        let key = try storage.file(account: account()).deletingLastPathComponent().lastPathComponent
        XCTAssertEqual(key, "f777495cc359abd3219049a740046a88c1a319c36af6d6d014912debf9dd1391")
        XCTAssertEqual(key.count, 64); XCTAssertTrue(key.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(try storage.file(account: account("A", "https://FIXTURE.example:443/jellyfin/")), try storage.file(account: account()))
        XCTAssertNotEqual(try storage.file(account: account("B")), try storage.file(account: account()))
        XCTAssertNotEqual(try storage.file(account: account("A", "https://fixture.example/other")), try storage.file(account: account()))
    }
    func testRecognizableForeignInputCannotCreateAnAccountFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReelBrowseForeignInput-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileBrowsePreferencesStorage(directory: directory), key = try account(), other = try account("B")
        XCTAssertThrowsError(try storage.write(encoded(document(other, choices: complex)), account: key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testRecognizableForeignRecordSurvivesWriteResetAndRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReelBrowseForeignRecord-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileBrowsePreferencesStorage(directory: directory), key = try account(), other = try account("B")
        let foreign = try encoded(document(other, choices: complex)), target = try storage.file(account: key)
        try storage.write(foreign, account: other)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try foreign.write(to: target)
        XCTAssertThrowsError(try storage.read(account: key)); XCTAssertThrowsError(try storage.write(encoded(document(key, choices: complex)), account: key)); XCTAssertThrowsError(try storage.remove(account: key))
        let store = BrowsePreferencesStore(storage: storage); _ = store.activate(key)
        XCTAssertEqual(store.status(for: key), .unavailable)
        XCTAssertTrue(store.error(for: key)?.contains("different account") == true)
        XCTAssertFalse(store.reset(key)); XCTAssertFalse(store.removeAccount(key))
        XCTAssertEqual(try Data(contentsOf: target), foreign)
        XCTAssertEqual(try storage.read(account: other), foreign)
    }
    func testForeignHeaderIsPreservedEvenWithUnknownDocumentVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReelBrowseForeignVersion-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileBrowsePreferencesStorage(directory: directory), key = try account(), other = try account("B"), target = try storage.file(account: key)
        var value = document(other, choices: complex); value.version = 99
        let bytes = try encoded(value)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: target)
        let store = BrowsePreferencesStore(storage: storage); _ = store.activate(key)
        XCTAssertFalse(store.saveViewStyle(.list, for: scope, account: key)); XCTAssertFalse(store.reset(key)); XCTAssertFalse(store.removeAccount(key))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
    func testOwnUnknownVersionAndSmallCorruptionRequireExplicitReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReelBrowseOwnedRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileBrowsePreferencesStorage(directory: directory), key = try account(), target = try storage.file(account: key)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var unknown = document(key, choices: complex); unknown.version = 99
        for bytes in [Data("{unrecognized".utf8), try encoded(unknown)] {
            try bytes.write(to: target)
            let store = BrowsePreferencesStore(storage: storage); _ = store.activate(key)
            XCTAssertEqual(store.status(for: key), .unavailable)
            XCTAssertFalse(store.saveViewStyle(.list, for: scope, account: key)); XCTAssertEqual(try Data(contentsOf: target), bytes)
            XCTAssertTrue(store.reset(key)); XCTAssertEqual(store.status(for: key), .ready)
            let restored = try JSONDecoder().decode(BrowseDocument.self, from: XCTUnwrap(storage.read(account: key)))
            XCTAssertEqual(restored.account, key); XCTAssertTrue(restored.entries.isEmpty)
        }
    }
    func testOversizedUnverifiableRecordIsPreservedByResetAndRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReelBrowseUnverifiable-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileBrowsePreferencesStorage(directory: directory), key = try account(), target = try storage.file(account: key)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(repeating: 65, count: 1_048_577); try bytes.write(to: target)
        let store = BrowsePreferencesStore(storage: storage); _ = store.activate(key)
        XCTAssertFalse(store.reset(key)); XCTAssertFalse(store.removeAccount(key))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
    func testRealFileSymlinkPreservesForeignTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReelBrowseLinks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileBrowsePreferencesStorage(directory: directory), key = try account(), target = try storage.file(account: key)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = directory.appendingPathComponent("preserve.txt"), bytes = Data("preserve".utf8)
        try bytes.write(to: foreign); try FileManager.default.createSymbolicLink(at: target, withDestinationURL: foreign)
        XCTAssertThrowsError(try storage.read(account: key)); XCTAssertThrowsError(try storage.write(Data(), account: key)); XCTAssertThrowsError(try storage.remove(account: key))
        XCTAssertEqual(try Data(contentsOf: foreign), bytes)
    }
    func testOversizedRealFileIsReadOnlyFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReelBrowseLimit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileBrowsePreferencesStorage(directory: directory), key = try account(), target = try storage.file(account: key)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(repeating: 65, count: 1_048_577); try bytes.write(to: target)
        XCTAssertThrowsError(try storage.read(account: key))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
}

final class BrowseMetadataTests: XCTestCase {
    private func item(_ values: [String: Any]) throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: ["Id": "fixture", "Name": "Title"].merging(values) { _, new in new }))
    }
    func testAggregateKnownZeroAndPositiveCounts() throws {
        XCTAssertEqual(try item(["Type": "Series", "UserData": ["UnplayedItemCount": 0]]).aggregateUnplayedCount, 0)
        XCTAssertEqual(try item(["Type": "Season", "UserData": ["UnplayedItemCount": 4]]).aggregateUnplayedCount, 4)
        XCTAssertEqual(try item(["Type": "BoxSet", "UserData": ["UnplayedItemCount": 2]]).aggregateUnplayedCount, 2)
    }
    func testMissingMalformedNegativeAndNonaggregateCountsAreUnknown() throws {
        for values: [String: Any] in [[:], ["UserData": NSNull()], ["UserData": [:]], ["UserData": ["UnplayedItemCount": NSNull()]], ["UserData": ["UnplayedItemCount": "wrong"]], ["UserData": ["UnplayedItemCount": -1]]] {
            XCTAssertNil(try item(["Type": "Series"].merging(values) { _, new in new }).aggregateUnplayedCount)
        }
        XCTAssertNil(try item(["Type": "Episode", "UserData": ["UnplayedItemCount": 2]]).aggregateUnplayedCount)
    }
    func testEpisodeNumbersPreserveSpecialsAndOmitMissingNumbers() throws {
        XCTAssertEqual(try item(["Type": "Episode"]).subtitle, "Title")
        XCTAssertEqual(try item(["Type": "Episode", "ParentIndexNumber": 0, "IndexNumber": 0]).episodeNumberText, "S0 E0")
        XCTAssertEqual(try item(["Type": "Episode", "ParentIndexNumber": -1, "IndexNumber": 3]).episodeNumberText, "E3")
    }
    func testRuntimeLabelsNeverRoundShortMediaToNothing() throws {
        XCTAssertEqual(try item(["RunTimeTicks": 240_000_000]).duration, "24s")
        XCTAssertEqual(try item(["RunTimeTicks": 2_000_000]).duration, "1s")
        XCTAssertEqual(try item(["RunTimeTicks": 6_720_000_000]).duration, "11m")
        XCTAssertEqual(try item(["RunTimeTicks": 67_200_000_000]).duration, "1h 52m")
        XCTAssertEqual(try item(["RunTimeTicks": 72_000_000_000]).duration, "2h")
        XCTAssertNil(try item(["RunTimeTicks": 0]).duration)
        XCTAssertEqual(try item(["RunTimeTicks": 67_200_000_000, "UserData": ["PlaybackPositionTicks": 42_000_000_000]]).remainingText, "42m left")
        XCTAssertNil(try item(["RunTimeTicks": 67_200_000_000]).remainingText)
    }
    func testMediaBadgesComeOnlyFromReportedStreams() throws {
        let source = try JSONDecoder().decode(MediaSource.self, from: JSONSerialization.data(withJSONObject: ["Id": "source", "MediaStreams": [
            ["Index": 0, "Type": "Video", "Width": 3840, "Height": 2160, "VideoRangeType": "DOVIWithHDR10"],
            ["Index": 1, "Type": "Audio", "Channels": 8, "AudioSpatialFormat": "DolbyAtmos"],
            ["Index": 2, "Type": "Subtitle", "Language": "eng"]]]))
        XCTAssertEqual(source.badges, ["4K", "Dolby Vision", "Atmos", "CC"])
        let plain = try JSONDecoder().decode(MediaSource.self, from: JSONSerialization.data(withJSONObject: ["Id": "plain", "MediaStreams": [
            ["Index": 0, "Type": "Video", "Width": 1920, "Height": 1080, "VideoRangeType": "SDR"],
            ["Index": 1, "Type": "Audio", "Channels": 6]]]))
        XCTAssertEqual(plain.badges, ["5.1"])
        XCTAssertEqual(MediaSource(Id: "empty").badges, [])
    }
    func testSentinelAndMissingDatesHaveNoLabels() throws {
        for value in ["0001-01-01T00:00:00Z", "0001-01-01T00:00:00.0000000Z", "0000-01-01T00:00:00Z", ""] {
            let result = try item(["DateCreated": value, "DateLastMediaAdded": value])
            XCTAssertNil(result.addedDateText, value); XCTAssertNil(result.lastMediaAddedDateText, value)
        }
        XCTAssertNil(try item([:]).addedDateText)
    }
    func testInvalidCalendarClockZoneAndTrailingBytesHaveNoLabels() throws {
        for value in ["2026-02-30T12:00:00Z", "2025-02-29T12:00:00Z", "2026-13-01T12:00:00Z", "2026-10-00T12:00:00Z", "2026-10-24T24:00:00Z", "2026-10-24T12:60:00Z", "2026-10-24T12:00:60Z", "2026-10-24T12:00:00+99:99", "2026-10-24T12:00:00Z\n", String(repeating: "1", count: 65)] {
            XCTAssertNil(try item(["DateCreated": value]).addedDateText, value)
        }
    }
    func testValidDatesKeepAddedAndContentAddedMeanings() throws {
        for value in ["2024-02-29T12:00:00Z", "2026-10-24T12:00:00.1234567Z", "2026-10-24T12:00:00+02:00"] {
            let result = try item(["DateCreated": value, "DateLastMediaAdded": value])
            XCTAssertTrue(try XCTUnwrap(result.addedDateText).hasPrefix("Added "), value)
            XCTAssertTrue(try XCTUnwrap(result.lastMediaAddedDateText).hasPrefix("Content added "), value)
        }
    }
    func testEpisodeFavoriteGenreWatchLibraryAndDirectionCompose() {
        let result = LibraryQuery(category: "Episodes", sort: .recentlyAdded, direction: .ascending, libraryID: "shows", genreID: "drama", watchStatus: "Unwatched", favoritesOnly: true).parameters(start: 60)
        XCTAssertEqual(result["includeItemTypes"], "Episode"); XCTAssertEqual(result["sortBy"], "DateCreated,SortName")
        XCTAssertEqual(result["sortOrder"], "Ascending,Ascending"); XCTAssertEqual(result["parentId"], "shows")
        XCTAssertEqual(result["genreIds"], "drama"); XCTAssertEqual(result["isPlayed"], "false"); XCTAssertEqual(result["filters"], "IsFavorite")
        XCTAssertEqual(Set(result["fields"]!.split(separator: ",")), ["Overview", "Genres", "DateCreated", "DateLastMediaAdded"])
    }
    func testSeriesUpdatedSortUsesCorrectTokenAndExplicitDirection() {
        let result = LibraryQuery(category: "Series", sort: .latestEpisodeAdded, direction: .ascending).parameters(start: 0)
        XCTAssertEqual(result["sortBy"], "DateLastContentAdded,SortName"); XCTAssertEqual(result["sortOrder"], "Ascending,Ascending")
        XCTAssertFalse(result["fields"]!.contains("DateLastContentAdded"))
    }
}
