import Foundation

enum LibrarySort: String, CaseIterable, Identifiable, Codable, Sendable {
    case title = "SortName"
    case recentlyAdded = "DateCreated"
    case releaseYear = "ProductionYear"
    case latestEpisodeAdded = "DateLastContentAdded"

    var id: String { rawValue }
    var defaultDirection: LibrarySortDirection { self == .title ? .ascending : .descending }
    var label: String {
        switch self {
        case .title: "Title"
        case .recentlyAdded: "Recently added"
        case .releaseYear: "Release year"
        case .latestEpisodeAdded: "Latest episode added"
        }
    }
}

enum LibrarySortDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case ascending = "Ascending", descending = "Descending"
    var id: String { rawValue }
    var opposite: Self { self == .ascending ? .descending : .ascending }
}

struct LibraryQuery: Hashable {
    var search = ""
    var category = "All"
    var sort: LibrarySort = .title
    var direction: LibrarySortDirection?
    var libraryID = ""
    var genreID = ""
    var watchStatus = "Any"
    var favoritesOnly = false
    var parentID: String?
    var parentType: String?
    var isSearch = false
    var effectiveSort: LibrarySort { sort == .latestEpisodeAdded && category != "Series" ? .recentlyAdded : sort }

    var isPlaylist: Bool { parentType == "Playlist" && parentID != nil }
    var path: String { isPlaylist ? "Playlists/\(parentID!)/Items" : "Items" }
    var canLoad: Bool { !isSearch || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func parameters(start: Int, limit: Int = 60) -> [String: String] {
        var result = ["startIndex": String(max(0, start)), "limit": String(max(1, min(200, limit))), "enableTotalRecordCount": "true"]
        // Playlist entries have their own order and may repeat the same media ID.
        guard !isPlaylist else { return result }
        result["recursive"] = "true"
        result["fields"] = "Overview,Genres,DateCreated,DateLastMediaAdded"
        switch category {
        case "Movies": result["includeItemTypes"] = "Movie"
        case "Series": result["includeItemTypes"] = "Series"
        case "Episodes": result["includeItemTypes"] = "Episode"
        case "Collections": result["includeItemTypes"] = "BoxSet"
        case "Playlists": result["includeItemTypes"] = "Playlist"
        default: result["includeItemTypes"] = isSearch ? "Movie,Series,Episode" : "Movie,Series"
        }
        result["sortBy"] = effectiveSort == .title ? "SortName" : "\(effectiveSort.rawValue),SortName"
        let order = direction ?? effectiveSort.defaultDirection
        result["sortOrder"] = effectiveSort == .title ? order.rawValue : "\(order.rawValue),Ascending"
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty { result["searchTerm"] = term }
        if !genreID.isEmpty { result["genreIds"] = genreID }
        if watchStatus != "Any" { result["isPlayed"] = watchStatus == "Watched" ? "true" : "false" }
        if category == "Favorites" || favoritesOnly { result["filters"] = "IsFavorite" }
        if let parentID {
            result["parentId"] = parentID
            result["includeItemTypes"] = "Movie,Series,Episode,Video,MusicVideo,BoxSet,Playlist"
        } else if !libraryID.isEmpty { result["parentId"] = libraryID }
        return result
    }
}

struct LibraryPagination {
    private(set) var items: [MediaItem] = []
    private(set) var total: Int?
    private(set) var nextIndex = 0
    private(set) var hasMore = false

    mutating func append(_ page: ItemPage, playlist: Bool, limit: Int = 60) {
        // Advance by server records, including overlapping records removed below.
        // Using the displayed count would repeatedly request the same page.
        nextIndex += page.Items.count
        if playlist { items.append(contentsOf: page.Items) }
        else {
            var known = Set(items.map(\.id))
            items.append(contentsOf: page.Items.filter { known.insert($0.id).inserted })
        }
        total = page.TotalRecordCount.map { max(0, $0) } ?? total
        hasMore = !page.Items.isEmpty && (total.map { nextIndex < $0 } ?? (page.Items.count >= limit))
    }
}
