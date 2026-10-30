import Foundation

struct WatchedMutationScope: Equatable, Sendable {
    let itemID: String
    let type: String?
    let isFolder: Bool?
    let kind: WatchedItemKind
    init(item: MediaItem) {
        itemID = item.id; type = item.Type; isFolder = item.IsFolder; kind = item.watchedKind
    }
}

struct WatchedReadbackAdmission: Equatable, Sendable {
    let operationID: UUID
    let scope: WatchedMutationScope
    let accountID: String
    let accountRevision: UUID

    init(plan: WatchedMutationPlan, operationID: UUID, scope: WatchedMutationScope) {
        self.operationID = operationID; self.scope = scope
        accountID = plan.accountID; accountRevision = plan.accountRevision
    }

    func isCurrent(operationID: UUID, scope: WatchedMutationScope, account: Account?, revision: UUID) -> Bool {
        self.operationID == operationID && self.scope == scope
            && accountID == account?.id && accountRevision == revision
    }
}

struct WatchedMutationPlan: Identifiable, Sendable {
    let id = UUID()
    let itemID: String
    let name: String
    let type: String?
    let kind: WatchedItemKind
    let scope: WatchedMutationScope
    let played: Bool
    let accountID: String
    let accountRevision: UUID

    init(item: MediaItem, played: Bool, account: Account, revision: UUID) {
        itemID = item.id; name = item.Name; type = item.Type; kind = item.watchedKind; scope = WatchedMutationScope(item: item)
        self.played = played; accountID = account.id; accountRevision = revision
    }
    private init(itemID: String, name: String, type: String?, kind: WatchedItemKind, scope: WatchedMutationScope, played: Bool, accountID: String, accountRevision: UUID) {
        self.itemID = itemID; self.name = name; self.type = type; self.kind = kind
        self.scope = scope; self.played = played; self.accountID = accountID; self.accountRevision = accountRevision
    }
    var isSupported: Bool { kind != .unknown }
    var isBulk: Bool { kind == .container }
    var requiresConfirmation: Bool { isBulk }
    var method: String { played ? "POST" : "DELETE" }
    var actionLabel: String { Self.actionLabel(type: type, bulk: isBulk, played: played) }
    /// "Mark as watched" for one title, "Mark season as watched" for a season, and so on.
    static func actionLabel(type: String?, bulk: Bool, played: Bool) -> String {
        let scope = !bulk ? "" : type == "Season" ? "season " : type == "Series" ? "series " : "all "
        return "Mark \(scope)as \(played ? "watched" : "unwatched")"
    }
    var confirmationTitle: String { "\(actionLabel)?" }
    var confirmationMessage: String {
        let scope: String
        switch type {
        case "Series": scope = "all episodes in this series"
        case "Season": scope = "all episodes in this season"
        default:
            guard isBulk else {
                guard isSupported else { return "Jellyfin has not supplied supported type metadata. Watched status cannot be changed for this title." }
                return "This asks Jellyfin to mark “\(name)” \(played ? "watched" : "unwatched"). It does not play any media."
            }
            scope = "all playable items in this container"
        }
        return "This asks Jellyfin to change watched status for \(scope) in “\(name)”, including titles outside the current filters. Server permissions and container rules determine which titles change. Continue watching and Up next may also change."
    }
    func isCurrent(account: Account?, revision: UUID) -> Bool { account?.id == accountID && revision == accountRevision }
    func matchesScope(_ item: MediaItem) -> Bool { scope == WatchedMutationScope(item: item) && item.supportsWatchedMutation }
    func desiring(_ value: Bool) -> WatchedMutationPlan {
        WatchedMutationPlan(itemID: itemID, name: name, type: type, kind: kind, scope: scope, played: value, accountID: accountID, accountRevision: accountRevision)
    }
    func refreshed(from item: MediaItem) throws -> WatchedMutationPlan {
        guard item.id == itemID else { throw WatchedReadbackError.wrongItem }
        guard item.supportsWatchedMutation else { throw WatchedReadbackError.unsupportedType }
        return WatchedMutationPlan(itemID: itemID, name: item.Name, type: item.Type, kind: item.watchedKind, scope: WatchedMutationScope(item: item),
                                   played: played, accountID: accountID, accountRevision: accountRevision)
    }
    var path: String? {
        // Jellyfin IDs are opaque path components. Refuse separators/control data;
        // the API URL builder takes an unescaped path and encodes it once.
        guard isSupported, !itemID.isEmpty, itemID.utf8.count <= 256,
              itemID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return "UserPlayedItems/" + itemID
    }
}

enum WatchedReadbackError: LocalizedError {
    case wrongItem, unsupportedType
    var errorDescription: String? {
        switch self {
        case .wrongItem: "Jellyfin returned a different title. Reload before changing watched status."
        case .unsupportedType: "Jellyfin has not supplied supported type metadata. No additional watched request can be sent."
        }
    }
}

struct WatchedReadback: Equatable, Sendable {
    let kind: WatchedItemKind
    let serverPlayed: Bool?
    let leafPlayed: Bool?
    let unplayedCount: Int?
    init(item: MediaItem) {
        kind = item.watchedKind; serverPlayed = item.serverPlayed
        leafPlayed = item.itemWatched; unplayedCount = item.aggregateUnplayedCount
    }
    func matches(_ desired: Bool) -> Bool { kind == .leaf && leafPlayed == desired }
    var summary: String {
        let status = serverPlayed.map { $0 ? "watched" : "unwatched" } ?? "unknown"
        let count = unplayedCount.map { " \($0) unwatched reported." } ?? ""
        return (kind == .container ? "Server container Played field: \(status)." : "Last check reported \(status).") + count
    }
}
