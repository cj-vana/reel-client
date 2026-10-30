import Foundation
import CryptoKit

struct BrowseAccountScope: Codable, Hashable, Sendable {
    let server: String
    let userID: String

    init(server: URL, userID: String) throws {
        guard var value = URLComponents(url: server, resolvingAgainstBaseURL: false),
              let scheme = value.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = value.host, !host.isEmpty, value.user == nil, value.password == nil,
              value.query == nil, value.fragment == nil, !userID.isEmpty, userID.utf8.count <= 512 else { throw BrowsePreferencesError.invalid }
        value.scheme = scheme; value.host = host.lowercased()
        if value.port == (scheme == "https" ? 443 : 80) { value.port = nil }
        while value.percentEncodedPath.hasSuffix("/") { value.percentEncodedPath.removeLast() }
        guard let normalized = value.string, normalized.utf8.count <= 2048 else { throw BrowsePreferencesError.invalid }
        self.server = normalized; self.userID = userID
    }
}

enum BrowseViewStyle: String, Codable, CaseIterable, Sendable { case grid, list }

struct BrowseScope: Codable, Hashable, Sendable {
    var libraryID = ""
    var category = "All"
    var parentID: String?
    var parentType: String?
    static let categories = ["All", "Movies", "Series", "Episodes", "Favorites", "Collections", "Playlists"]
    var isValid: Bool {
        Self.categories.contains(category) && libraryID.utf8.count <= 256
            && (parentID?.utf8.count ?? 0) <= 256 && (parentType?.utf8.count ?? 0) <= 64
    }
}

struct BrowseRootLocation: Codable, Equatable, Sendable {
    var libraryID = ""
    var category = "All"
    func validated(libraryIDs: Set<String>) -> Self {
        Self(libraryID: libraryID.isEmpty || libraryIDs.contains(libraryID) ? libraryID : "",
             category: BrowseScope.categories.contains(category) ? category : "All")
    }
}

struct BrowseChoices: Codable, Equatable, Sendable {
    var sort = LibrarySort.title
    var direction = LibrarySortDirection.ascending
    var genreID = ""
    var watchStatus = "Any"
    var favoritesOnly = false
    var viewStyle = BrowseViewStyle.grid

    func validated(for scope: BrowseScope, genreIDs: Set<String>) -> Self {
        var result = self
        if result.sort == .latestEpisodeAdded && scope.category != "Series" { result.sort = .recentlyAdded }
        if !genreID.isEmpty && !genreIDs.contains(genreID) { result.genreID = "" }
        if !["Any", "Unwatched", "Watched"].contains(watchStatus) { result.watchStatus = "Any" }
        return result
    }
    var isValid: Bool { genreID.utf8.count <= 256 && ["Any", "Unwatched", "Watched"].contains(watchStatus) }
}

struct BrowseDocument: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable { let scope: BrowseScope; var choices: BrowseChoices }
    var version = 1
    let account: BrowseAccountScope
    var root = BrowseRootLocation()
    var entries: [Entry] = []
    func choices(for scope: BrowseScope) -> BrowseChoices { entries.first { $0.scope == scope }?.choices ?? BrowseChoices() }
    var isValid: Bool {
        version == 1 && entries.count <= 256 && BrowseScope.categories.contains(root.category)
            && root.libraryID.utf8.count <= 256 && Set(entries.map(\.scope)).count == entries.count
            && entries.allSatisfy { $0.scope.isValid && $0.choices.isValid }
    }
}

enum BrowsePreferencesError: LocalizedError {
    case invalid, unreadable, writeFailed, capacity, foreignAccount
    var errorDescription: String? {
        switch self {
        case .invalid, .unreadable: "Saved browse choices couldn’t be read. Your saved choices have not been replaced. Temporary changes stay in this session until you retry or reset."
        case .writeFailed: "Browse choices couldn’t be saved. Your latest choices are kept in this session. Retry saving when storage is available."
        case .capacity: "This account has too many saved browse contexts. No saved choices were removed. Reset this account’s browse choices to start fresh."
        case .foreignAccount: "The saved browse record identifies a different account and has been preserved."
        }
    }
}

@MainActor protocol BrowsePreferencesStorage {
    func read(account: BrowseAccountScope) throws -> Data?
    func write(_ data: Data, account: BrowseAccountScope) throws
    func remove(account: BrowseAccountScope) throws
}

@MainActor struct FileBrowsePreferencesStorage: BrowsePreferencesStorage {
    private struct KeyIdentity: Encodable { let version: Int; let account: BrowseAccountScope }
    private struct StoredIdentity: Decodable { let account: BrowseAccountScope }
    let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Reel/BrowseChoices", isDirectory: true)) { self.directory = directory }

    private static func isMissingFile(_ error: any Error) -> Bool {
        var value = error as NSError
        for _ in 0..<4 {
            if value.domain == NSPOSIXErrorDomain { return value.code == Int(POSIXError.Code.ENOENT.rawValue) }
            guard value.domain == NSCocoaErrorDomain,
                  [CocoaError.Code.fileNoSuchFile.rawValue, CocoaError.Code.fileReadNoSuchFile.rawValue].contains(value.code) else { return false }
            guard let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError else { return true }
            value = underlying
        }
        return false
    }

    // Key format1 is canonical UTF8 JSON with sorted keys and unescaped slashes.
    // Full account identity stays in the document and is checked before mutation.
    // The constant-length filename is an identifier, not encryption or a vault.
    func file(account: BrowseAccountScope) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let identity = try encoder.encode(KeyIdentity(version: 1, account: account))
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key, isDirectory: true).appendingPathComponent("choices-v1.json")
    }
    private static func verifyRecognizedAccount(_ data: Data, account: BrowseAccountScope) throws {
        if let identity = try? JSONDecoder().decode(StoredIdentity.self, from: data), identity.account != account {
            throw BrowsePreferencesError.foreignAccount
        }
    }
    private func checkPath(_ file: URL) throws {
        var cursor = directory
        let components = Array(file.pathComponents.dropFirst(directory.pathComponents.count))
        for component in [""] + components {
            if !component.isEmpty { cursor.appendPathComponent(component) }
            do {
                let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw BrowsePreferencesError.unreadable }
                if cursor.path == file.path {
                    guard values.isRegularFile == true else { throw BrowsePreferencesError.unreadable }
                } else if values.isDirectory != true { throw BrowsePreferencesError.unreadable }
            } catch where Self.isMissingFile(error) { }
        }
    }
    func read(account: BrowseAccountScope) throws -> Data? {
        let target = try file(account: account); try checkPath(target)
        do {
            let handle = try FileHandle(forReadingFrom: target); defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { throw BrowsePreferencesError.unreadable }
            try Self.verifyRecognizedAccount(data, account: account)
            return data
        } catch where Self.isMissingFile(error) { return nil }
    }
    func write(_ data: Data, account: BrowseAccountScope) throws {
        guard data.count <= 1_048_576 else { throw BrowsePreferencesError.capacity }
        try Self.verifyRecognizedAccount(data, account: account)
        _ = try read(account: account)
        let target = try file(account: account); try checkPath(target)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: target, options: .atomic)
    }
    func remove(account: BrowseAccountScope) throws {
        _ = try read(account: account)
        let target = try file(account: account); try checkPath(target)
        do { try FileManager.default.removeItem(at: target) }
        catch where Self.isMissingFile(error) { }
    }
}

@MainActor final class BrowsePreferencesStore {
    enum Status: Equatable { case ready, unavailable, dirty }
    static let shared = BrowsePreferencesStore(storage: FileBrowsePreferencesStorage())
    private struct ChoiceChange {
        var replacement: BrowseChoices?
        var viewStyle: BrowseViewStyle?
        func applying(to saved: BrowseChoices) -> BrowseChoices {
            var result = replacement ?? saved
            if let viewStyle { result.viewStyle = viewStyle }
            return result
        }
    }
    private struct Pending {
        var root: BrowseRootLocation?
        var choices: [BrowseScope: ChoiceChange] = [:]
        var isEmpty: Bool { root == nil && choices.isEmpty }
    }
    private let storage: any BrowsePreferencesStorage
    private var documents: [BrowseAccountScope: BrowseDocument] = [:]
    private var pending: [BrowseAccountScope: Pending] = [:]
    private var states: [BrowseAccountScope: Status] = [:]
    private var errors: [BrowseAccountScope: String] = [:]

    init(storage: any BrowsePreferencesStorage) { self.storage = storage }
    func status(for account: BrowseAccountScope) -> Status { states[account] ?? .ready }
    func error(for account: BrowseAccountScope) -> String? { errors[account] }
    @discardableResult func activate(_ account: BrowseAccountScope) -> BrowseDocument {
        if let known = documents[account] { return known }
        do { documents[account] = try read(account); states[account] = .ready }
        catch { documents[account] = BrowseDocument(account: account); states[account] = .unavailable; errors[account] = (error as? BrowsePreferencesError)?.localizedDescription ?? BrowsePreferencesError.unreadable.localizedDescription }
        return documents[account]!
    }
    func choices(for scope: BrowseScope, account: BrowseAccountScope) -> BrowseChoices { activate(account).choices(for: scope) }

    @discardableResult func save(_ choices: BrowseChoices, for scope: BrowseScope, account: BrowseAccountScope) -> Bool {
        guard scope.isValid, choices.isValid else { errors[account] = BrowsePreferencesError.invalid.localizedDescription; return false }
        _ = activate(account)
        pending[account, default: Pending()].choices[scope] = ChoiceChange(replacement: choices)
        documents[account] = merging(pending[account]!, into: documents[account]!)
        return flush(account, recovering: false)
    }
    @discardableResult func saveViewStyle(_ value: BrowseViewStyle, for scope: BrowseScope, account: BrowseAccountScope) -> Bool {
        guard scope.isValid else { errors[account] = BrowsePreferencesError.invalid.localizedDescription; return false }
        _ = activate(account)
        pending[account, default: Pending()].choices[scope, default: ChoiceChange()].viewStyle = value
        documents[account] = merging(pending[account]!, into: documents[account]!)
        return flush(account, recovering: false)
    }
    @discardableResult func saveRoot(_ location: BrowseRootLocation, account: BrowseAccountScope) -> Bool {
        guard BrowseScope.categories.contains(location.category), location.libraryID.utf8.count <= 256 else { return false }
        _ = activate(account); pending[account, default: Pending()].root = location
        documents[account] = merging(pending[account]!, into: documents[account]!)
        return flush(account, recovering: false)
    }
    @discardableResult func retry(_ account: BrowseAccountScope) -> Bool { _ = activate(account); return flush(account, recovering: true) }
    @discardableResult func reset(_ account: BrowseAccountScope) -> Bool {
        do {
            let replacement = BrowseDocument(account: account)
            try storage.write(try encode(replacement), account: account)
            documents[account] = replacement; pending[account] = nil; states[account] = .ready; errors[account] = nil
            return true
        } catch { errors[account] = (error as? BrowsePreferencesError)?.localizedDescription ?? BrowsePreferencesError.writeFailed.localizedDescription; return false }
    }
    @discardableResult func removeAccount(_ account: BrowseAccountScope) -> Bool {
        do {
            try storage.remove(account: account)
            documents[account] = nil; pending[account] = nil; states[account] = nil; errors[account] = nil
            return true
        } catch { errors[account] = (error as? BrowsePreferencesError)?.localizedDescription ?? "Saved browse choices for the removed account couldn’t be cleared."; return false }
    }

    private func read(_ account: BrowseAccountScope) throws -> BrowseDocument {
        guard let data = try storage.read(account: account) else { return BrowseDocument(account: account) }
        guard data.count <= 1_048_576 else { throw BrowsePreferencesError.unreadable }
        let result = try JSONDecoder().decode(BrowseDocument.self, from: data)
        guard result.account == account, result.isValid else { throw BrowsePreferencesError.invalid }
        return result
    }
    private func encode(_ document: BrowseDocument) throws -> Data {
        guard document.isValid else { throw BrowsePreferencesError.capacity }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(document)
        guard bytes.count <= 1_048_576 else { throw BrowsePreferencesError.capacity }
        return bytes
    }
    private func merging(_ changes: Pending, into saved: BrowseDocument) -> BrowseDocument {
        var result = saved
        if let location = changes.root { result.root = location }
        for (scope, change) in changes.choices {
            if let index = result.entries.firstIndex(where: { $0.scope == scope }) {
                result.entries[index].choices = change.applying(to: result.entries[index].choices)
            } else { result.entries.append(.init(scope: scope, choices: change.applying(to: BrowseChoices()))) }
        }
        return result
    }
    private func flush(_ account: BrowseAccountScope, recovering: Bool) -> Bool {
        guard recovering || states[account] != .unavailable else { return false }
        let saved: BrowseDocument
        do { saved = try read(account) }
        catch { states[account] = .unavailable; errors[account] = (error as? BrowsePreferencesError)?.localizedDescription ?? BrowsePreferencesError.unreadable.localizedDescription; return false }
        let changes = pending[account] ?? Pending()
        let desired = merging(changes, into: saved)
        do {
            if !changes.isEmpty { try storage.write(try encode(desired), account: account) }
            documents[account] = desired; pending[account] = nil; states[account] = .ready; errors[account] = nil
            return true
        } catch {
            documents[account] = desired; states[account] = .dirty
            errors[account] = (error as? BrowsePreferencesError)?.localizedDescription ?? BrowsePreferencesError.writeFailed.localizedDescription
            return false
        }
    }
}
