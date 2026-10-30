import Foundation

enum BrowseOptionsError: LocalizedError {
    case malformed, incomplete, capacity
    var errorDescription: String? {
        switch self {
        case .malformed: "Jellyfin returned invalid filter choices. Your saved filters have not been replaced."
        case .incomplete: "The complete filter choices could not be verified. Retry before using saved filters."
        case .capacity: "This server has more filter choices than can be checked safely in one visit. Your saved filters have not been replaced."
        }
    }
}

enum BrowseOptionsReader {
    typealias Fetch = @Sendable (String, [String: String]) async throws -> ItemPage

    private static func validated(_ items: [MediaItem]) throws -> [MediaItem] {
        guard items.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 }) else { throw BrowseOptionsError.malformed }
        var known = Set<String>()
        return items.filter { known.insert($0.id).inserted }
    }

    /// UserViews is an unpaginated endpoint. Never invent startIndex/limit for it.
    static func libraries(fetch: Fetch) async throws -> [MediaItem] {
        let page = try await fetch("UserViews", [:])
        try Task.checkCancellation()
        guard page.TotalRecordCount == nil || page.TotalRecordCount == page.Items.count else { throw BrowseOptionsError.incomplete }
        return try validated(page.Items)
    }

    /// Genres supports paging. A partial option set cannot prove an ID was removed.
    static func genres(query: [String: String], fetch: Fetch) async throws -> [MediaItem] {
        let limit = 200
        var rawIndex = 0, total: Int?, output: [MediaItem] = [], seen = Set<String>()
        for _ in 0..<100 {
            try Task.checkCancellation()
            let parameters = query.merging(["startIndex": String(rawIndex), "limit": String(limit),
                                            "enableTotalRecordCount": "true", "sortBy": "SortName", "sortOrder": "Ascending"]) { _, new in new }
            let page = try await fetch("Genres", parameters)
            try Task.checkCancellation()
            guard page.Items.count <= limit else { throw BrowseOptionsError.incomplete }
            let values = try validated(page.Items)
            guard values.count == page.Items.count, values.allSatisfy({ !seen.contains($0.id) }) else { throw BrowseOptionsError.incomplete }
            if let count = page.TotalRecordCount {
                guard count >= 0, total == nil || total == count else { throw BrowseOptionsError.incomplete }
                total = count
            }
            rawIndex += page.Items.count
            guard total == nil || rawIndex <= total! else { throw BrowseOptionsError.incomplete }
            for value in values { seen.insert(value.id); output.append(value) }
            if let total {
                if rawIndex == total { return output }
                if page.Items.isEmpty { throw BrowseOptionsError.incomplete }
            } else if page.Items.count < limit { return output }
        }
        throw BrowseOptionsError.capacity
    }
}
