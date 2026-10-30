import Darwin
import CoreGraphics
import Foundation
import Observation
import PDFKit

// These messages describe local recovery without disclosing a filesystem path.
enum HubReaderFailure: Error, Equatable, Sendable {
    case missing, unreadable, damagedPDF, emptyPDF, emptyFile, changed, unavailable

    var title: String {
        switch self {
        case .missing: "Saved file is missing"
        case .unreadable: "Saved file is unavailable"
        case .damagedPDF: "This PDF couldn’t be opened"
        case .emptyPDF: "This PDF has no pages"
        case .emptyFile: "This saved file is empty"
        case .changed: "The saved file changed"
        case .unavailable: "This saved file is no longer available"
        }
    }
    var message: String {
        switch self {
        case .missing: "The saved entry and your reading position are still here. Restore the saved copy, then retry."
        case .unreadable: "Reel couldn’t open this saved copy. Unlock your device or check its access and available storage, then retry."
        case .damagedPDF: "The saved copy may be damaged or may not be a PDF. Your original and reading position have been kept."
        case .emptyPDF: "The saved PDF contains no readable pages. Your saved copy and reading position have been kept."
        case .emptyFile: "The saved copy contains no data. Your saved entry and reading position have been kept."
        case .changed: "Reload the saved copy to continue. Your reading position has been kept."
        case .unavailable: "Return to your current connection’s saved books and open the file again."
        }
    }
}

struct HubReaderRequest: Equatable, Sendable {
    let fileID: UUID
    let accountID: String
    let filename: String
    let directory: URL
    var url: URL { directory.appendingPathComponent(filename) }
    var bookmarkKey: String { "hub-page|" + filename }
}

struct HubReaderFingerprint: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let bytes: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; bytes = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
    }
}

// The loader exclusively creates/inspects the PDF on its worker. After returning,
// it never touches it again; the receiving MainActor alone owns PDFKit access.
final class HubReaderSnapshot: @unchecked Sendable {
    let data: Data
    let url: URL
    let fingerprint: HubReaderFingerprint
    let pdf: PDFDocument?
    let locked: Bool
    fileprivate init(data: Data, url: URL, fingerprint: HubReaderFingerprint, pdf: PDFDocument?, locked: Bool) {
        self.data = data; self.url = url; self.fingerprint = fingerprint; self.pdf = pdf; self.locked = locked
    }
    func removeTemporaryFile() { try? FileManager.default.removeItem(at: url) }
    deinit { removeTemporaryFile() }
}

enum HubReaderLoader {
    private static func failure(_ number: Int32) -> HubReaderFailure {
        number == ENOENT ? .missing : .unreadable
    }
    private static func withFile<T>(_ request: HubReaderRequest, _ body: (Int32) throws -> T) throws -> T {
        guard MediaHub.validFilename(request.filename), request.directory.isFileURL else { throw HubReaderFailure.unavailable }
        let directory = request.directory.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard directory >= 0 else { throw failure(errno) }
        defer { Darwin.close(directory) }
        // NONBLOCK also prevents a substituted FIFO from hanging before fstat.
        let descriptor = request.filename.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw failure(errno) }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { throw failure(errno) }
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw HubReaderFailure.unreadable }
        return try body(descriptor)
    }
    private static func fingerprint(_ descriptor: Int32) throws -> HubReaderFingerprint {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw failure(errno) }
        return HubReaderFingerprint(value)
    }
    static func fingerprint(_ request: HubReaderRequest) throws -> HubReaderFingerprint {
        try withFile(request) { try fingerprint($0) }
    }
    static func validatePageCount(_ count: Int) throws {
        guard count > 0 else { throw HubReaderFailure.emptyPDF }
    }
    static func read(_ request: HubReaderRequest) throws -> HubReaderSnapshot {
        try Task.checkCancellation()
        let snapshotURL = URL.temporaryDirectory.appendingPathComponent("ReelReaderSnapshot-" + UUID().uuidString + "." + request.url.pathExtension)
        var retained = false
        var createdSnapshot = false
        defer { if createdSnapshot && !retained { try? FileManager.default.removeItem(at: snapshotURL) } }
        let original = try withFile(request) { descriptor in
            let before = try fingerprint(descriptor)
            guard before.bytes > 0 else { throw HubReaderFailure.emptyFile }
            let output = snapshotURL.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) } ?? -1
            }
            guard output >= 0 else { throw HubReaderFailure.unreadable }
            createdSnapshot = true
            defer { Darwin.close(output) }
            var total: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure(errno)
                }
                if count == 0 { break }
                // A growing or substituted original must not turn into an unbounded copy.
                guard total + Int64(count) <= before.bytes else { throw HubReaderFailure.changed }
                var written = 0
                while written < count {
                    try Task.checkCancellation()
                    let amount = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress?.advanced(by: written), count - written) }
                    if amount < 0, errno == EINTR { continue }
                    guard amount > 0 else { throw HubReaderFailure.unreadable }
                    written += amount
                }
                total += Int64(count)
            }
            guard total == before.bytes, try fingerprint(descriptor) == before else { throw HubReaderFailure.changed }
            guard fchmod(output, 0o400) == 0 else { throw HubReaderFailure.unreadable }
            return before
        }
        guard try fingerprint(request) == original else { throw HubReaderFailure.changed }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: snapshotURL.path)
        // This is a private, regular, read-only local copy. Mapping it avoids a
        // whole-book allocation and never maps the mutable original.
        let data = try Data(contentsOf: snapshotURL, options: .alwaysMapped)
        try Task.checkCancellation()
        var pdf: PDFDocument?
        var locked = false
        if request.url.pathExtension.lowercased() == "pdf" {
            if let document = PDFDocument(data: data) {
                locked = document.isLocked
                // PDFKit requires locked documents to be unlocked before page inspection.
                if !locked {
                    try validatePageCount(document.pageCount)
                    pdf = document
                }
            } else if let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) {
                // Inspect only metadata the native parser actually recognizes;
                // rejected bytes are not proof of a readable zero-page PDF.
                if document.isEncrypted && !document.isUnlocked { locked = true }
                else {
                    try validatePageCount(document.numberOfPages)
                    throw HubReaderFailure.damagedPDF
                }
            } else { throw HubReaderFailure.damagedPDF }
        }
        try Task.checkCancellation()
        let snapshot = HubReaderSnapshot(data: data, url: snapshotURL, fingerprint: original, pdf: pdf, locked: locked)
        retained = true
        return snapshot
    }
}

@MainActor @Observable final class HubReaderModel {
    enum State {
        case loading
        case ready(HubReaderSnapshot)
        case failed(HubReaderFailure)
    }
    private(set) var state: State = .loading
    private var generation = UUID()
    private var worker: Task<HubReaderSnapshot, Error>?
    private let read: @Sendable (HubReaderRequest) async throws -> HubReaderSnapshot

    init(read: @escaping @Sendable (HubReaderRequest) async throws -> HubReaderSnapshot = { request in try HubReaderLoader.read(request) }) { self.read = read }

    func cancel() {
        generation = UUID(); worker?.cancel(); worker = nil; state = .loading
    }
    func load(_ request: HubReaderRequest, stillOwned: @MainActor () -> Bool) async {
        cancel()
        let operation = generation
        guard stillOwned() else { state = .failed(.unavailable); return }
        let read = self.read
        let task = Task.detached(priority: .userInitiated) { try await read(request) }
        worker = task
        defer { if generation == operation { worker = nil } }
        do {
            let snapshot = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, generation == operation, stillOwned() else { return }
            guard try HubReaderLoader.fingerprint(request) == snapshot.fingerprint else { throw HubReaderFailure.changed }
            state = .ready(snapshot)
        } catch {
            guard !Task.isCancelled, generation == operation, stillOwned() else { return }
            state = .failed(error as? HubReaderFailure ?? .unreadable)
        }
    }
}

@MainActor enum HubReaderAccess {
    static func owns(_ file: HubFile, hub: MediaHub, session: Session) -> Bool {
        guard session.account?.id == file.accountID, MediaHub.validFilename(file.filename) else { return false }
        let matches = hub.files.filter { $0.filename == file.filename }
        return matches.count == 1 && matches[0].id == file.id && matches[0].accountID == file.accountID
    }
    static func request(_ file: HubFile, hub: MediaHub) -> HubReaderRequest {
        HubReaderRequest(fileID: file.id, accountID: file.accountID, filename: file.filename, directory: hub.directory)
    }
}

struct HubReaderExport: Identifiable, Sendable {
    let id = UUID()
    let snapshot: HubReaderSnapshot
    let filename: String
    let title: String
    var data: Data { snapshot.data }
}

@MainActor @Observable final class HubFileExporter {
    private(set) var preparing = false
    var item: HubReaderExport?
    var failure: HubReaderFailure?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var owner: (@MainActor () -> Bool)?
    private let reader: HubReaderModel

    init(reader: HubReaderModel = HubReaderModel()) { self.reader = reader }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; reader.cancel()
        preparing = false; item = nil; failure = nil; owner = nil
    }
    func revalidateOwnership() { if let owner, !owner() { cancel() } }
    func export(_ file: HubFile, hub: MediaHub, session: Session) {
        cancel()
        let operation = generation
        let request = HubReaderAccess.request(file, hub: hub)
        let revision = session.revision
        let owns = { @MainActor in session.revision == revision && HubReaderAccess.owns(file, hub: hub, session: session) }
        guard owns() else { failure = .unavailable; return }
        owner = owns
        preparing = true
        task = Task { [weak self] in
            guard let self else { return }
            await reader.load(request, stillOwned: owns)
            guard !Task.isCancelled, generation == operation, owns() else {
                if generation == operation { preparing = false; task = nil; item = nil; reader.cancel() }
                return
            }
            preparing = false; task = nil
            switch reader.state {
            case .ready(let snapshot):
                // The provider receives the private read-only snapshot, never the mutable original.
                item = HubReaderExport(snapshot: snapshot, filename: file.filename, title: file.item.Name)
            case .failed(let failure): self.failure = failure
            case .loading: break
            }
            reader.cancel()
        }
    }
}
