import XCTest
import SwiftUI
import PDFKit
@testable import Reel

@MainActor final class HubReaderRecoveryTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() async throws {
        directory = URL.temporaryDirectory.appendingPathComponent("ReelReaderTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        suite = "Reel.ReaderTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }
    private func request(_ extensionName: String = "pdf", account: String = "synthetic-account") -> HubReaderRequest {
        HubReaderRequest(fileID: UUID(), accountID: account, filename: UUID().uuidString + "." + extensionName, directory: directory)
    }
    private func pdf(_ text: String = "Reader recovery", pages: Int = 3) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 500)).pdfData { context in
            for page in 0..<pages {
                context.beginPage()
                ("\(text) · Page \(page + 1)" as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
    }
    private func noPageCatalogue() -> Data {
        var text = "%PDF-1.4\n"
        let first = text.utf8.count
        text += "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        let second = text.utf8.count
        text += "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n"
        let xref = text.utf8.count
        text += "xref\n0 3\n0000000000 65535 f \n" + String(format: "%010d 00000 n \n%010d 00000 n \n", first, second)
        text += "trailer\n<< /Size 3 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(text.utf8)
    }

    private func read(_ request: HubReaderRequest) async throws -> HubReaderSnapshot {
        try await Task.detached { try HubReaderLoader.read(request) }.value
    }
    private func failed(_ request: HubReaderRequest, _ expected: HubReaderFailure) async throws {
        do { _ = try await read(request); XCTFail("Expected a specific local recovery error.") }
        catch { XCTAssertEqual(error as? HubReaderFailure, expected) }
    }
    private func awaitGate(_ gate: ReaderGate) async throws {
        for _ in 0..<100 {
            if await gate.waiting { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The owned reader worker did not reach its gate.")
        throw CocoaError(.coderInvalidValue)
    }
    private func file(_ request: HubReaderRequest, audio: Bool = false) -> HubFile {
        HubFile(id: request.fileID, accountID: request.accountID, item: HubItem(Id: request.fileID.uuidString, Name: "Owned test book", Type: audio ? "Audio" : "Book", Container: audio ? "mp3" : "pdf"), filename: request.filename, bytes: 99)
    }
    private func manifest(_ files: [HubFile]) throws {
        try JSONEncoder().encode(files).write(to: directory.appendingPathComponent("files.json"))
    }

    func testHealthyPDFLoadsFromImmutableBytesWithoutChangingOriginal() async throws {
        let request = request(); let data = pdf()
        try data.write(to: request.url)
        let snapshot = try await read(request)
        XCTAssertEqual(snapshot.data, data)
        XCTAssertEqual(snapshot.pdf?.pageCount, 3)
        XCTAssertFalse(snapshot.locked)
        XCTAssertEqual(try Data(contentsOf: request.url), data)
        try pdf("Replacement").write(to: request.url, options: .atomic)
        XCTAssertTrue(snapshot.pdf?.string?.contains("Reader recovery") == true)
        XCTAssertEqual(snapshot.data, data)
    }
    func testOwnedSnapshotIsReadOnlyAndRemovedAfterItsLastOwner() async throws {
        let request = request(); let bytes = pdf(); try bytes.write(to: request.url)
        var snapshot: HubReaderSnapshot? = try await read(request)
        let temporary = try XCTUnwrap(snapshot?.url)
        XCTAssertNotEqual(temporary, request.url)
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)
        XCTAssertEqual(snapshot?.data, bytes)
        snapshot = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(try Data(contentsOf: request.url), bytes)
    }
    func testFailedParseRemovesOnlyItsTemporarySnapshot() async throws {
        let request = request(); let bytes = Data("invalid PDF".utf8); try bytes.write(to: request.url)
        let temp = URL.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("ReelReaderSnapshot-") })
        try await failed(request, .damagedPDF)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("ReelReaderSnapshot-") })
        XCTAssertEqual(after, before)
        XCTAssertEqual(try Data(contentsOf: request.url), bytes)
    }
    func testMissingOriginalHasSpecificFailureAndRetryRecovers() async throws {
        let request = request()
        try await failed(request, .missing)
        try pdf().write(to: request.url)
        let restored = try await read(request)
        XCTAssertEqual(restored.pdf?.pageCount, 3)
    }
    func testMalformedPDFPreservesBytesAndBookmarkThenRetryReadsReplacement() async throws {
        let request = request(); let bytes = Data("not a PDF".utf8)
        try bytes.write(to: request.url)
        UserDefaults.standard.set(2, forKey: request.bookmarkKey)
        defer { UserDefaults.standard.removeObject(forKey: request.bookmarkKey) }
        for _ in 0..<2 { try await failed(request, .damagedPDF) }
        XCTAssertEqual(try Data(contentsOf: request.url), bytes)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: request.bookmarkKey), 2)
        try pdf().write(to: request.url)
        let restored = try await read(request)
        XCTAssertEqual(restored.pdf?.pageCount, 3)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: request.bookmarkKey), 2)
    }
    func testZeroBytesAndSDKZeroPagesAreDistinctFromRejectedCatalogue() async throws {
        let request = request(); try Data().write(to: request.url)
        try await failed(request, .emptyFile)
        XCTAssertEqual(try Data(contentsOf: request.url), Data())

        let emptyDocument = PDFDocument()
        XCTAssertEqual(emptyDocument.pageCount, 0)
        XCTAssertThrowsError(try HubReaderLoader.validatePageCount(emptyDocument.pageCount)) {
            XCTAssertEqual($0 as? HubReaderFailure, .emptyPDF)
        }
        let healthyDocument = try XCTUnwrap(PDFDocument(data: pdf(pages: 1)))
        XCTAssertNoThrow(try HubReaderLoader.validatePageCount(healthyDocument.pageCount))

        // iOS 27.1 rejects this serialized empty page tree. Exercise that real
        // failure instead of pretending it is an SDK-readable zero-page file.
        let bytes = noPageCatalogue()
        XCTAssertNil(PDFDocument(data: bytes))
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        XCTAssertNil(CGPDFDocument(provider))
        try bytes.write(to: request.url)
        try await failed(request, .damagedPDF)
        XCTAssertEqual(try Data(contentsOf: request.url), bytes)
    }

    func testPasswordProtectedPDFIsNotClassifiedAsCorruptAndExportsOriginalBytes() async throws {
        let request = request(); let document = try XCTUnwrap(PDFDocument(data: pdf()))
        XCTAssertTrue(document.write(to: request.url, withOptions: [.ownerPasswordOption: "synthetic-owner", .userPasswordOption: "synthetic-reader"]))
        let original = try Data(contentsOf: request.url)
        let snapshot = try await read(request)
        XCTAssertTrue(snapshot.locked)
        XCTAssertNil(snapshot.pdf, "Locked pages must not be inspected before unlocking.")
        XCTAssertEqual(snapshot.data, original, "An external reader receives the encrypted original, never an unlocked derivative.")
        XCTAssertEqual(try Data(contentsOf: request.url), original)
    }
    func testAutomaticallyUnlockedEncryptedPDFRemainsReadable() async throws {
        let request = request(); let document = try XCTUnwrap(PDFDocument(data: pdf()))
        XCTAssertTrue(document.write(to: request.url, withOptions: [.ownerPasswordOption: "synthetic-owner", .userPasswordOption: ""]))
        let snapshot = try await read(request)
        XCTAssertFalse(snapshot.locked)
        XCTAssertEqual(snapshot.pdf?.pageCount, 3)
    }
    func testTextAndUnsupportedOriginalsStayReadableWithoutPretendingToBePDFs() async throws {
        for extensionName in ["txt", "epub", "cbz", "mobi"] {
            let request = request(extensionName); let bytes = Data("synthetic original".utf8)
            try bytes.write(to: request.url)
            let snapshot = try await read(request)
            XCTAssertNil(snapshot.pdf); XCTAssertFalse(snapshot.locked); XCTAssertEqual(snapshot.data, bytes)
        }
    }
    func testSymlinkOriginalIsRejectedWithoutReadingTarget() async throws {
        let target = directory.appendingPathComponent("owned-secret.txt")
        let bytes = Data("must not be followed".utf8); try bytes.write(to: target)
        let request = request(); try FileManager.default.createSymbolicLink(at: request.url, withDestinationURL: target)
        try await failed(request, .unreadable)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
    func testSymlinkStorageRootIsRejected() async throws {
        let target = directory.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let request = HubReaderRequest(fileID: UUID(), accountID: "owned", filename: UUID().uuidString + ".pdf", directory: alias)
        try pdf().write(to: target.appendingPathComponent(request.filename))
        try await failed(request, .unreadable)
    }
    func testDirectoryAndTraversalAreRejected() async throws {
        let request = request(); try FileManager.default.createDirectory(at: request.url, withIntermediateDirectories: false)
        try await failed(request, .unreadable)
        for filename in ["../outside.pdf", "/outside.pdf", "invalid.pdf"] {
            let invalid = HubReaderRequest(fileID: UUID(), accountID: "owned", filename: filename, directory: directory)
            try await failed(invalid, .unavailable)
        }
    }
    func testCancellationBeforeReadDoesNotReturnDocument() async throws {
        let request = request(); try pdf().write(to: request.url)
        let gate = ReaderGate()
        let worker = Task.detached { await gate.wait(); try Task.checkCancellation(); return try HubReaderLoader.read(request) }
        try await awaitGate(gate); worker.cancel(); await gate.release()
        do { _ = try await worker.value; XCTFail("A canceled read must not return a document.") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testClosingDuringLoadDiscardsLateCompletionAndLeavesBookmarkAlone() async throws {
        let request = request(); try pdf().write(to: request.url)
        let snapshot = try await read(request); let gate = ReaderGate()
        let model = HubReaderModel(read: { _ in await gate.wait(); return snapshot })
        UserDefaults.standard.set(2, forKey: request.bookmarkKey)
        defer { UserDefaults.standard.removeObject(forKey: request.bookmarkKey) }
        let task = Task { await model.load(request, stillOwned: { true }) }
        try await awaitGate(gate); model.cancel(); await gate.release(); await task.value
        guard case .loading = model.state else { return XCTFail("A closed reader must not accept a late result.") }
        XCTAssertEqual(UserDefaults.standard.integer(forKey: request.bookmarkKey), 2)
    }
    func testAccountChangeDuringLoadCannotCommitOldDocument() async throws {
        let request = request(); try pdf().write(to: request.url)
        let snapshot = try await read(request); let gate = ReaderGate(); var owns = true
        let model = HubReaderModel(read: { _ in await gate.wait(); return snapshot })
        let task = Task { await model.load(request, stillOwned: { owns }) }
        try await awaitGate(gate); owns = false; await gate.release(); await task.value
        guard case .loading = model.state else { return XCTFail("Old account data must not be committed.") }
    }
    func testReplacedFileDuringLoadRequiresExplicitRetry() async throws {
        let request = request(); try pdf().write(to: request.url)
        let snapshot = try await read(request); let gate = ReaderGate()
        let model = HubReaderModel(read: { _ in await gate.wait(); return snapshot })
        let task = Task { await model.load(request, stillOwned: { true }) }
        try await awaitGate(gate); try pdf("new original").write(to: request.url, options: .atomic)
        await gate.release(); await task.value
        guard case .failed(.changed) = model.state else { return XCTFail("A changed file must not accept the prior snapshot.") }
    }
    func testSupersededFileLoadCannotReplaceNewerDocument() async throws {
        let first = request(); let second = request()
        try pdf("First").write(to: first.url); try pdf("Second").write(to: second.url)
        let original = try await read(first); let gate = ReaderGate()
        let model = HubReaderModel(read: { request in
            if request == first { await gate.wait(); return original }
            return try HubReaderLoader.read(request)
        })
        let task = Task { await model.load(first, stillOwned: { true }) }
        try await awaitGate(gate)
        await model.load(second, stillOwned: { true })
        await gate.release(); await task.value
        guard case .ready(let current) = model.state else { return XCTFail("The newer document should remain ready.") }
        XCTAssertTrue(current.pdf?.string?.contains("Second") == true)
    }
    func testMissingBookSurvivesRelaunchAndUnrelatedManifestWriteWhileAudioCleanupStaysUnchanged() throws {
        let missing = file(request()); let existingRequest = request(); let existing = file(existingRequest)
        let missingAudio = file(request("mp3"), audio: true)
        let bytes = pdf(); try bytes.write(to: existingRequest.url)
        try manifest([missing, existing, missingAudio])
        let bookmark = "hub-page|" + missing.filename
        defaults.set(2, forKey: bookmark)
        let hub = MediaHub(directory: directory, defaults: defaults)
        XCTAssertEqual(Set(hub.files.map(\.id)), Set([missing.id, existing.id]))
        try hub.remove(existing)
        let restored = MediaHub(directory: directory, defaults: defaults)
        XCTAssertEqual(restored.files.map(\.id), [missing.id])
        XCTAssertEqual(defaults.integer(forKey: bookmark), 2)
        let disk = try JSONDecoder().decode([HubFile].self, from: Data(contentsOf: directory.appendingPathComponent("files.json")))
        XCTAssertEqual(disk.map(\.id), [missing.id])
        try restored.remove(missing)
        XCTAssertTrue(restored.files.isEmpty)
        XCTAssertNil(defaults.object(forKey: bookmark), "Only explicit removal clears the page bookmark.")
    }
    func testExportRevalidatesOwnershipAfterSuspendedReadAndCannotLeakAcrossAccountSwitch() async throws {
        let first = Account(server: URL(string: "https://reader.invalid")!, token: "synthetic-one", userID: "one", name: "One", serverName: "Synthetic")
        let second = Account(server: first.server, token: "synthetic-two", userID: "two", name: "Two", serverName: "Synthetic")
        let store = ReaderVault(AccountVault(accounts: [first, second], activeID: first.id))
        let services = SessionAccountServices(authenticate: { _, _, _, _ in throw HubReaderFailure.unavailable }, revoke: { _, _ in }, removeCredentials: { _, _ in })
        let session = Session(storage: store, defaults: defaults, services: services)
        let request = request(account: first.id); let entry = file(request)
        try pdf().write(to: request.url); try manifest([entry])
        let hub = MediaHub(directory: directory, defaults: defaults)
        let snapshot = try await read(request); let gate = ReaderGate()
        let exporter = HubFileExporter(reader: HubReaderModel(read: { _ in await gate.wait(); return snapshot }))
        exporter.export(entry, hub: hub, session: session)
        try await awaitGate(gate); try await session.select(second)
        await gate.release()
        for _ in 0..<100 { if !exporter.preparing { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(exporter.preparing); XCTAssertNil(exporter.item); XCTAssertNil(exporter.failure)
        XCTAssertFalse(HubReaderAccess.owns(entry, hub: hub, session: session))
        XCTAssertEqual(try Data(contentsOf: request.url), snapshot.data)
    }
    private func fakeSession(_ accounts: [Account]) -> Session {
        let store = ReaderVault(AccountVault(accounts: accounts, activeID: accounts.first?.id))
        let services = SessionAccountServices(authenticate: { _, _, _, _ in throw HubReaderFailure.unavailable }, revoke: { _, _ in }, removeCredentials: { _, _ in })
        return Session(storage: store, defaults: defaults, services: services)
    }
    private func awaitExport(_ exporter: HubFileExporter) async throws {
        for _ in 0..<100 { if !exporter.preparing { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("The owned local export did not finish.")
        throw CocoaError(.coderInvalidValue)
    }
    func testMissingAndMalformedFilesCannotExportOrRewriteTheirSavedRecords() async throws {
        let account = Account(server: URL(string: "https://reader.invalid")!, token: "synthetic-only", userID: "one", name: "One", serverName: "Synthetic")
        let session = fakeSession([account]); let request = request(account: account.id); let entry = file(request)
        try manifest([entry]); let before = try Data(contentsOf: directory.appendingPathComponent("files.json"))
        let hub = MediaHub(directory: directory, defaults: defaults); let exporter = HubFileExporter()
        exporter.export(entry, hub: hub, session: session); try await awaitExport(exporter)
        XCTAssertNil(exporter.item); XCTAssertEqual(exporter.failure, .missing)
        let invalid = Data("not a PDF".utf8); try invalid.write(to: request.url)
        exporter.export(entry, hub: hub, session: session); try await awaitExport(exporter)
        XCTAssertNil(exporter.item); XCTAssertEqual(exporter.failure, .damagedPDF)
        XCTAssertEqual(try Data(contentsOf: request.url), invalid)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("files.json")), before)
    }
    func testExportUsesSnapshotBytesAndUnrelatedSavedFileChangesDoNotDismissIt() async throws {
        let account = Account(server: URL(string: "https://reader.invalid")!, token: "synthetic-only", userID: "one", name: "One", serverName: "Synthetic")
        let session = fakeSession([account]); let request = request(account: account.id); let entry = file(request)
        let original = pdf(); try original.write(to: request.url); try manifest([entry])
        let hub = MediaHub(directory: directory, defaults: defaults); let exporter = HubFileExporter()
        exporter.export(entry, hub: hub, session: session); try await awaitExport(exporter)
        XCTAssertEqual(exporter.item?.data, original)
        try Data("later replacement".utf8).write(to: request.url, options: .atomic)
        XCTAssertEqual(exporter.item?.data, original, "Already prepared shares never resolve a later mutable URL.")
        let other = file(self.request(account: account.id)); try manifest([entry, other]); hub.recoverStorage()
        exporter.revalidateOwnership(); XCTAssertNotNil(exporter.item)
        try hub.remove(other); exporter.revalidateOwnership(); XCTAssertNotNil(exporter.item)
        try hub.remove(entry); exporter.revalidateOwnership(); XCTAssertNil(exporter.item)
    }
    func testDuplicateFilenameAcrossAccountsFailsClosedWithoutChangingManifest() throws {
        let first = Account(server: URL(string: "https://reader.invalid")!, token: "synthetic-one", userID: "one", name: "One", serverName: "Synthetic")
        let second = Account(server: first.server, token: "synthetic-two", userID: "two", name: "Two", serverName: "Synthetic")
        let request = request(account: first.id); let entry = file(request)
        let duplicate = HubFile(id: UUID(), accountID: second.id, item: entry.item, filename: entry.filename, bytes: entry.bytes)
        try pdf().write(to: request.url); try manifest([entry, duplicate])
        let before = try Data(contentsOf: directory.appendingPathComponent("files.json"))
        let hub = MediaHub(directory: directory, defaults: defaults); let session = fakeSession([first, second])
        XCTAssertFalse(HubReaderAccess.owns(entry, hub: hub, session: session))
        let exporter = HubFileExporter(); exporter.export(entry, hub: hub, session: session)
        XCTAssertEqual(exporter.failure, .unavailable); XCTAssertNil(exporter.item); XCTAssertFalse(exporter.preparing)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("files.json")), before)
    }
    func testExplicitFileRemovalDuringLoadCannotCommitOldDocument() async throws {
        let request = request(); let entry = file(request)
        try pdf().write(to: request.url); try manifest([entry])
        let hub = MediaHub(directory: directory, defaults: defaults)
        let snapshot = try await read(request); let gate = ReaderGate()
        let model = HubReaderModel(read: { _ in await gate.wait(); return snapshot })
        let task = Task { await model.load(request, stillOwned: { hub.files.contains { $0.id == entry.id } }) }
        try await awaitGate(gate); try hub.remove(entry); await gate.release(); await task.value
        guard case .loading = model.state else { return XCTFail("A removed saved file must not reopen after a late result.") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.url.path))
    }
    func testErrorsNeverContainPrivatePathOrArbitraryUnderlyingError() {
        for failure in [HubReaderFailure.missing, .unreadable, .damagedPDF, .emptyPDF, .emptyFile, .changed, .unavailable] {
            XCTAssertFalse(failure.title.contains(directory.path)); XCTAssertFalse(failure.message.contains(directory.path))
            XCTAssertFalse(failure.message.contains("synthetic-reader"))
        }
    }
}

private actor ReaderGate {
    private(set) var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class ReaderVault: AccountVaultStorage {
    var value: AccountVault
    init(_ value: AccountVault) { self.value = value }
    func read() throws -> AccountVault { value }
    func save(_ vault: AccountVault) throws { value = vault }
    func clear() throws { value = AccountVault() }
}
