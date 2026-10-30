import Foundation
import Observation

struct TVBrowseRow: Identifiable {
    enum ID: Hashable { case item(String), entry(String), untaggedEntry(Int, String) }
    let item: MediaItem
    let id: ID
    let accessibilityID: String
    init(item: MediaItem, position: Int, playlist: Bool) {
        self.item = item
        if playlist, let entry = item.PlaylistItemId {
            id = .entry(entry); accessibilityID = "item-" + entry
        } else if playlist {
            id = .untaggedEntry(position, item.id); accessibilityID = "local-playlist-entry-\(position)-" + item.id
        } else {
            id = .item(item.id); accessibilityID = "item-" + item.id
        }
    }
}

@MainActor @Observable final class TVBrowseStore {
    private struct Identity: Equatable {
        let server: URL
        let user: String?
        let token: String?
        init(_ api: JellyfinAPI) { server = api.server; user = api.userID; token = api.token }
    }
    private(set) var page = LibraryPagination()
    private(set) var scope = BrowseScope()
    private(set) var choices = BrowseChoices()
    private(set) var parentItem: MediaItem?
    private(set) var parentError: String?
    private(set) var parentLoading = false
    private(set) var libraries: [MediaItem] = []
    private(set) var genres: [MediaItem] = []
    private(set) var loading = false
    private(set) var optionsLoading = false
    private(set) var optionsReady = false
    private(set) var usingTemporaryDefaults = false
    private(set) var error: String?
    private(set) var optionsError: String?
    private(set) var preferenceError: String?
    private(set) var preferenceStatus = BrowsePreferencesStore.Status.ready
    private(set) var searchText = ""
    private(set) var searching = false
    private(set) var active = false
    private var identity: Identity?
    private var account: BrowseAccountScope?
    private var destination: TVLibraryDestination?
    private var generation = UUID()
    private var optionGeneration = UUID()
    private var request: Task<ItemPage, Error>?
    private var optionsRequest: Task<(ItemPage, ItemPage), Error>?
    private var initialized = false
    private var temporaryEdits = false
    private var navigationIntent = false
    private let preferences: BrowsePreferencesStore

    init(preferences: BrowsePreferencesStore = .shared) { self.preferences = preferences }
    var items: [MediaItem] { page.items }
    var rows: [TVBrowseRow] { items.enumerated().map { TVBrowseRow(item: $0.element, position: $0.offset, playlist: isPlaylist) } }
    var total: Int? { page.total }
    var hasMore: Bool { page.hasMore }
    var isPlaylist: Bool { scope.parentType == "Playlist" && scope.parentID != nil }
    var query: LibraryQuery {
        LibraryQuery(search: searchText, category: scope.category, sort: choices.sort, direction: choices.direction,
                     libraryID: scope.libraryID, genreID: choices.genreID, watchStatus: choices.watchStatus,
                     favoritesOnly: choices.favoritesOnly, parentID: scope.parentID, parentType: scope.parentType,
                     isSearch: searching)
    }

    func open(api: JellyfinAPI, destination: TVLibraryDestination?, searching: Bool, search: String) async {
        let previousQuery = query
        let nextIdentity = Identity(api)
        if identity != nextIdentity || self.destination != destination || self.searching != searching {
            cancel()
            identity = nextIdentity; self.destination = destination; self.searching = searching
            account = try? BrowseAccountScope(server: api.server, userID: api.userID ?? "")
            page = LibraryPagination(); scope = BrowseScope(); choices = BrowseChoices()
            parentItem = nil; parentError = nil
            libraries = []; genres = []; optionsReady = false; optionsError = nil
            initialized = false; usingTemporaryDefaults = false; temporaryEdits = false
            navigationIntent = destination?.category != nil || destination?.sort != nil
        }
        active = true; searchText = search
        guard let account else { error = "This connection has no valid account for browsing."; return }
        _ = preferences.activate(account); updatePreferenceState()
        if !initialized {
            await loadOptions(api: api)
            guard optionsReady, !Task.isCancelled else { return }
        }
        await loadPage(api: api, preservingPage: query == previousQuery)
        await refreshParent(api: api)
    }

    func refreshParent(api: JellyfinAPI) async {
        guard active, identity == Identity(api), let parent = destination?.parent else { return }
        let location = destination, context = identity
        parentLoading = true; parentError = nil
        defer { if destination == location, identity == context { parentLoading = false } }
        do {
            let value = try await api.item(parent.id)
            guard active, !Task.isCancelled, destination == location, identity == context, value.id == parent.id else { return }
            parentItem = value
        } catch is CancellationError { }
        catch { if active, destination == location, identity == context { parentError = "Container status couldn’t refresh. Its count may be out of date." } }
    }

    func cancel() {
        active = false; generation = UUID(); optionGeneration = UUID()
        request?.cancel(); request = nil; optionsRequest?.cancel(); optionsRequest = nil
        loading = false; optionsLoading = false; initialized = false
    }

    func loadOptions(api: JellyfinAPI) async {
        guard active, identity == Identity(api), let account else { return }
        let operation = UUID(), context = identity
        optionGeneration = operation
        optionsRequest?.cancel(); optionsLoading = true; optionsReady = false; optionsError = nil
        defer { if optionGeneration == operation { optionsLoading = false; optionsRequest = nil } }
        let task = Task {
            async let views = api.page("UserViews")
            async let tags = api.page("Genres", query: ["includeItemTypes": "Movie,Series,Episode"])
            return try await (views, tags)
        }
        optionsRequest = task
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard active, !Task.isCancelled, optionGeneration == operation, identity == context else { return }
            libraries = result.0.Items; genres = result.1.Items
            optionsReady = true; optionsError = nil
            let document = preferences.activate(account)
            let validatedRoot = document.root.validated(libraryIDs: Set(libraries.map(\.id)))
            if usingTemporaryDefaults && temporaryEdits {
                scope.libraryID = scope.libraryID.isEmpty || libraries.contains(where: { $0.id == scope.libraryID }) ? scope.libraryID : ""
                choices = choices.validated(for: scope, genreIDs: Set(genres.map(\.id)))
                usingTemporaryDefaults = false
                persist()
            } else {
                var location = validatedRoot
                if searching { location = BrowseRootLocation() }
                if navigationIntent, let category = destination?.category { location = BrowseRootLocation(libraryID: "", category: category) }
                scope = BrowseScope(libraryID: location.libraryID, category: location.category,
                                    parentID: destination?.parent?.id, parentType: destination?.parent?.Type)
                let saved = preferences.choices(for: scope, account: account)
                choices = saved.validated(for: scope, genreIDs: Set(genres.map(\.id)))
                if navigationIntent {
                    let style = saved.viewStyle
                    choices = BrowseChoices(); choices.viewStyle = style
                    if let sort = destination?.sort { choices.sort = sort; choices.direction = sort.defaultDirection }
                }
                usingTemporaryDefaults = false
                if validatedRoot != document.root, destination == nil, !searching { _ = preferences.saveRoot(validatedRoot, account: account) }
                if choices != saved, !navigationIntent { _ = preferences.save(choices, for: scope, account: account) }
            }
            initialized = true
            updatePreferenceState()
        } catch is CancellationError { }
        catch {
            guard active, !Task.isCancelled, optionGeneration == operation, identity == context else { return }
            optionsError = "Library filters couldn’t load. Retry before using saved filters, or browse all libraries with temporary defaults."
            optionsReady = usingTemporaryDefaults
        }
    }

    func retryOptions(api: JellyfinAPI) async {
        await loadOptions(api: api)
        if optionsReady && active { await loadPage(api: api) }
    }

    func browseWithDefaults(api: JellyfinAPI) async {
        guard active, identity == Identity(api) else { return }
        request?.cancel(); generation = UUID()
        let category = destination?.category ?? "All"
        scope = BrowseScope(category: category, parentID: destination?.parent?.id, parentType: destination?.parent?.Type)
        choices = BrowseChoices()
        if let sort = destination?.sort { choices.sort = sort; choices.direction = sort.defaultDirection }
        usingTemporaryDefaults = true; temporaryEdits = false; initialized = true; optionsReady = true
        updatePreferenceState()
        await loadPage(api: api)
    }

    func selectCategory(_ value: String, api: JellyfinAPI) async {
        guard active, optionsReady, identity == Identity(api), BrowseScope.categories.contains(value), !isPlaylist else { return }
        generation = UUID(); request?.cancel(); navigationIntent = false
        scope.category = value
        if usingTemporaryDefaults { choices = BrowseChoices(); temporaryEdits = true }
        else if let account { choices = preferences.choices(for: scope, account: account).validated(for: scope, genreIDs: Set(genres.map(\.id))) }
        persist()
        await loadPage(api: api)
    }

    func selectLibrary(_ value: String, api: JellyfinAPI) async {
        guard active, optionsReady, identity == Identity(api), value.isEmpty || libraries.contains(where: { $0.id == value }), scope.parentID == nil else { return }
        generation = UUID(); request?.cancel(); navigationIntent = false
        scope.libraryID = value
        if usingTemporaryDefaults { temporaryEdits = true }
        else if let account { choices = preferences.choices(for: scope, account: account).validated(for: scope, genreIDs: Set(genres.map(\.id))) }
        persist()
        await loadPage(api: api)
    }

    func change(api: JellyfinAPI, _ edit: (inout BrowseChoices) -> Void) async {
        guard active, optionsReady, identity == Identity(api) else { return }
        let previous = choices
        var desired = choices
        edit(&desired)
        desired = desired.validated(for: scope, genreIDs: Set(genres.map(\.id)))
        var presentationOnly = previous; presentationOnly.viewStyle = desired.viewStyle
        choices = desired
        if presentationOnly == desired {
            if let account { _ = preferences.saveViewStyle(desired.viewStyle, for: scope, account: account) }
            updatePreferenceState()
            return
        }
        generation = UUID(); request?.cancel(); navigationIntent = false
        if usingTemporaryDefaults { temporaryEdits = true }
        persist()
        await loadPage(api: api)
    }

    func clearFilters(api: JellyfinAPI) async {
        guard active, optionsReady, identity == Identity(api) else { return }
        navigationIntent = false
        scope.libraryID = ""
        choices.genreID = ""; choices.watchStatus = "Any"; choices.favoritesOnly = false
        if usingTemporaryDefaults { temporaryEdits = true }
        persist()
        await loadPage(api: api)
    }

    func retryPreferences(api: JellyfinAPI) async {
        guard active, let account, identity == Identity(api) else { return }
        _ = preferences.retry(account)
        initialized = false; temporaryEdits = false
        updatePreferenceState()
        await loadOptions(api: api)
        if optionsReady && initialized { await loadPage(api: api) }
    }

    func resetPreferences(api: JellyfinAPI) async {
        guard active, let account, identity == Identity(api) else { return }
        guard preferences.reset(account) else { updatePreferenceState(); return }
        navigationIntent = destination?.category != nil || destination?.sort != nil
        initialized = false; temporaryEdits = false
        updatePreferenceState()
        await loadOptions(api: api)
        if optionsReady && initialized { await loadPage(api: api) }
    }

    func refresh(api: JellyfinAPI) async { await loadPage(api: api, preservingPage: true) }
    func loadMore(api: JellyfinAPI) async { await loadPage(api: api, append: true) }

    func prepareSearch(_ text: String) {
        guard !searching || searchText != text else { return }
        searching = true; searchText = text
        generation = UUID(); request?.cancel(); request = nil
        loading = false; error = nil; page = LibraryPagination()
    }

    // Retained baseline contracts exercise the same shared query and raw-page loader.
    func load(api: JellyfinAPI, filter: TVFilter, search: String? = nil, append: Bool = false) async {
        active = true; identity = Identity(api); scope = BrowseScope(category: filter.rawValue)
        searching = search != nil; searchText = search ?? ""; optionsReady = true; initialized = true
        await loadPage(api: api, append: append)
    }

    private func persist() {
        guard let account else { return }
        if !usingTemporaryDefaults && !navigationIntent {
            _ = preferences.save(choices, for: scope, account: account)
            if scope.parentID == nil && !searching { _ = preferences.saveRoot(BrowseRootLocation(libraryID: scope.libraryID, category: scope.category), account: account) }
        }
        updatePreferenceState()
    }

    private func updatePreferenceState() {
        guard let account else { return }
        preferenceStatus = preferences.status(for: account)
        preferenceError = preferences.error(for: account)
    }

    private func loadPage(api: JellyfinAPI, append: Bool = false, preservingPage: Bool = false) async {
        guard active, optionsReady, identity == Identity(api), !(append && loading) else { return }
        let requested = query, context = identity
        if append && !hasMore { return }
        request?.cancel()
        let operation = UUID(); generation = operation
        if !append && !preservingPage { page = LibraryPagination() }
        error = nil
        guard requested.canLoad else { loading = false; return }
        let start = append ? page.nextIndex : 0
        loading = true
        defer { if generation == operation { loading = false; request = nil } }
        let task = Task { try await api.page(requested.path, query: requested.parameters(start: start)) }
        request = task
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard active, !Task.isCancelled, generation == operation, identity == context, query == requested else { return }
            if append, result.Items.isEmpty, let total = result.TotalRecordCount ?? page.total, start < total {
                error = "The next page was unexpectedly empty. Your loaded titles are still here. Try loading more again."
                return
            }
            if append { page.append(result, playlist: requested.isPlaylist) }
            else { var replacement = LibraryPagination(); replacement.append(result, playlist: requested.isPlaylist); page = replacement }
        } catch is CancellationError { }
        catch {
            if active, !Task.isCancelled, generation == operation, identity == context, query == requested { self.error = error.localizedDescription }
        }
    }
}
