import SwiftUI

struct TVLibraryView: View {
    var searching = false
    var destination: TVLibraryDestination?
    /// Set for a top-level tab pinned to one category, such as Movies.
    var section: String? = nil
    @Environment(TVCoordinator.self) private var coordinator
    @State private var store = TVBrowseStore()
    @State private var watched = TVWatchedStore()
    @State private var query = ""
    @State private var refresh = 0
    @State private var confirmReset = false
    @FocusState private var focus: Focus?
    private enum Focus: Hashable { case selection, search, category(String), sort, direction, filters, library, genre, watch, favorite, style, clear, options, defaults, preferences, item(String), more, refresh }
    private var sorts: [LibrarySort] { LibrarySort.allCases.filter { $0 != .latestEpisodeAdded || store.scope.category == "Series" } }
    private var heading: String {
        if let parent = destination?.parent { return parent.Name }
        if let section { return section }
        if searching { return "Search" }
        if store.scope.category == "Episodes" {
            return store.choices.sort == .recentlyAdded && store.choices.direction == .descending ? "Recently added episodes" : "Episodes"
        }
        return "Library"
    }
    /// Search with nothing typed yet: the browse controls and the title count have nothing to act on.
    private var searchIdle: Bool { searching && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !watched.selecting }
    private var activeFilterCount: Int { [!store.scope.libraryID.isEmpty, !store.choices.genreID.isEmpty, store.choices.watchStatus != "Any", store.choices.favoritesOnly].filter { $0 }.count }
    private var filterSummary: String {
        [store.libraries.first { $0.id == store.scope.libraryID }?.Name,
         store.genres.first { $0.id == store.choices.genreID }?.Name,
         store.choices.watchStatus == "Any" ? nil : store.choices.watchStatus,
         store.scope.category == "Favorites" ? "Favorites category" : store.choices.favoritesOnly ? "Favorites only" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    private var watchedKey: String {
        let payload: [String: Any] = ["path": store.query.path, "parameters": store.query.parameters(start: 0)]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]) else { return UUID().uuidString }
        return String(decoding: data, as: UTF8.self)
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Text(heading)
                        .font(.system(size: 52, weight: .bold)).tracking(-0.6).accessibilityIdentifier("libraryTitle").id("libraryTop")
                    if searching {
                        TextField("Movies, series and episodes", text: $query).frame(maxWidth: 1100).accessibilityIdentifier("search")
                            .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focus, equals: .search).disabled(watched.busy)
                    }
                    parentStatus
                    if !searching && destination?.parent == nil && section == nil { categories.disabled(watched.busy) }
                    if !searchIdle {
                        if !store.isPlaylist { queryControls.disabled(watched.busy) }
                        else {
                            HStack(spacing: 30) {
                                Text("Playlist order. Repeated entries stay in place.").foregroundStyle(Color.tvMuted)
                                Spacer()
                                presentationMenu
                            }.font(.system(size: 22, weight: .semibold)).focusSection()
                        }
                    }
                    recovery
                    if !searchIdle { selectionBar }
                    TVWatchedFeedback(store: watched)
                    listing
                }.padding(.horizontal, TVLayout.margin).padding(.top, 40).padding(.bottom, 90)
            }
            .scrollClipDisabled()
            .ignoresSafeArea(edges: .horizontal)
            .onChange(of: store.query) { old, new in
                if old != new {
                    watched.configure(session: coordinator.session, key: watchedKey, items: store.items, lane: coordinator.watchedLane)
                    scroll.scrollTo("libraryTop", anchor: .top)
                }
            }
        }
        .background(Color.reelBackground)
        .watchedPresentation(watched)
        .modifier(TVSelectionExit(active: watched.selecting) { watched.exitWithBack() })
        .onAppear { watched.configure(session: coordinator.session, key: watchedKey, items: store.items, lane: coordinator.watchedLane) }
        .onChange(of: store.items) { _, _ in
            watched.configure(session: coordinator.session, key: watchedKey, items: store.items, lane: coordinator.watchedLane)
            if case .item(let previous) = focus, !store.rows.contains(where: { $0.accessibilityID == previous }) {
                focus = store.rows.first.map { .item($0.accessibilityID) } ?? .selection
            } else if watched.selecting, watched.selected.isEmpty, focus == nil { focus = .selection }
        }
        .onChange(of: watched.entries.count) { old, new in if old > 0 && new == 0 { focus = .selection } }
        .onChange(of: watched.selecting) { _, value in
            if value, let row = store.rows.first { focus = .item(row.accessibilityID) }
            else { focus = .selection }
        }
        .onChange(of: query) { _, text in if searching { store.prepareSearch(text) } }
        .onDisappear { store.cancel() }
        .task(id: "\(coordinator.session.revision)|\(coordinator.session.libraryRevision)|\(query)|\(refresh)") {
            if searching {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            if let api = coordinator.session.api {
                await store.open(api: api, destination: destination, searching: searching, search: query)
            }
        }
        // The dialog takes the system tint so its focused action keeps a dark label (see ReelTVApp).
        .tint(Color.reelText)
        .confirmationDialog("Reset this account’s browse choices?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset browse choices", role: .destructive) {
                if let api = coordinator.session.api { Task {
                    await store.resetPreferences(api: api)
                    if store.active { focus = store.isPlaylist ? .refresh : .sort }
                } }
            }.accessibilityIdentifier("confirmResetBrowse")
            Button("Keep saved choices", role: .cancel) { }
        } message: { Text("This replaces only this server account’s saved library sort and filter choices. Your accounts, playback settings and watch history stay unchanged.") }
        .tint(nil)
    }

    @ViewBuilder private var parentStatus: some View {
        if destination?.parent != nil {
            VStack(alignment: .leading, spacing: 20) {
                if let item = store.parentItem {
                    TVUnwatchedCount(item: item, stale: store.parentError != nil || store.parentLoading || store.optionsLoading || store.optionsError != nil)
                    TVWatchedControls(item: item, scopeKey: watchedKey + "|parent:" + item.id, identifier: "parentWatchStatus", dataReady: store.parentError == nil && !store.parentLoading).id(item.id)
                } else { Text("Unwatched count unavailable").font(.system(size: 22)).foregroundStyle(Color.tvMuted) }
                if store.parentLoading { ProgressView().accessibilityIdentifier("parentStatusLoading") }
                if let error = store.parentError {
                    Text(error).foregroundStyle(.orange).accessibilityIdentifier("parentStatusError")
                    Button("Retry container status") { if let api = coordinator.session.api { Task { await store.refreshParent(api: api) } } }
                        .accessibilityIdentifier("retryParentStatus")
                }
            }.focusSection()
        }
    }

    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 25) {
                if watched.selecting {
                    Text("\(watched.selected.count) titles selected").accessibilityIdentifier("selectedTitleCount")
                    Button("Select loaded titles") { watched.selectLoaded(store.items, session: coordinator.session) }.disabled(watched.busy).accessibilityIdentifier("selectLoadedTitles")
                    Button("Clear selection") { watched.clear() }.disabled(watched.busy || watched.selected.isEmpty).accessibilityIdentifier("clearTitleSelection")
                    Button("Done selecting") { watched.finishSelection() }.disabled(watched.busy).accessibilityIdentifier("finishTitleSelection").focused($focus, equals: .selection)
                } else {
                    Button("Select titles") { watched.begin() }.disabled(watched.busy || store.loading || store.items.isEmpty).accessibilityIdentifier("beginTitleSelection").focused($focus, equals: .selection)
                }
                // The count and Refresh share this row so the grid starts higher on the first screen.
                Spacer(minLength: 25)
                Text(store.total.map { "\(store.items.count) of \($0) titles" } ?? "\(store.items.count) titles loaded")
                    .foregroundStyle(Color.tvTertiary).accessibilityIdentifier("libraryCount")
                Button(store.loading ? "Loading…" : "Refresh library") {
                    if let api = coordinator.session.api { Task { await store.refresh(api: api) } }
                }.disabled(watched.busy || store.loading || !store.optionsReady || !store.query.canLoad)
                    .accessibilityIdentifier("libraryRefresh").focused($focus, equals: .refresh)
            }.frame(maxWidth: .infinity, alignment: .leading).focusSection()
            if watched.selecting {
                if watched.anotherOperation { Text("Another watched operation is in progress.").font(.system(size: 20)).foregroundStyle(Color.tvMuted) }
                HStack(spacing: 25) {
                    Button("Mark selected as watched") { requestSelected(true) }.accessibilityIdentifier("bulkMarkWatched")
                    Button("Mark selected as unwatched") { requestSelected(false) }.accessibilityIdentifier("bulkMarkUnwatched")
                }.frame(maxWidth: .infinity, alignment: .leading).disabled(!watched.canStart || watched.selected.isEmpty || TVWatchedStore.refusal(coordinator.session) != nil).focusSection()
                Text("Selection applies to loaded titles only. Repeated playlist entries share one watched status.").font(.system(size: 20)).foregroundStyle(Color.tvMuted)
                if let reason = TVWatchedStore.refusal(coordinator.session) { Text(reason).font(.system(size: 20)).foregroundStyle(Color.tvMuted).accessibilityIdentifier("bulkWatchRefusal") }
            }
        }
        .font(.system(size: 22, weight: .semibold))
    }
    private func requestSelected(_ played: Bool) {
        watched.request(store.items.filter { watched.selected.contains($0.id) }, played: played, session: coordinator.session, key: watchedKey)
    }
    private func open(_ item: MediaItem) {
        if watched.selecting { watched.toggle(item) } else { coordinator.detail(item) }
    }

    private var categories: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 22) {
                ForEach(BrowseScope.categories, id: \.self) { value in
                    Button(value) {
                        focus = .category(value)
                        if let api = coordinator.session.api { Task { await store.selectCategory(value, api: api) } }
                    }.buttonStyle(TVChipStyle(selected: store.scope.category == value))
                        .accessibilityIdentifier("filter-" + value).focused($focus, equals: .category(value))
                        .accessibilityAddTraits(store.scope.category == value ? .isSelected : [])
                }
            }.padding(.vertical, 12)
        }
        // The focused chip lifts past the row's edges; clipping cut the first one in half.
        .scrollClipDisabled()
        .font(.system(size: 24, weight: .semibold))
        .focusSection().disabled(!store.optionsReady)
    }

    private var queryControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 25) {
                Menu("Sort: " + sortLabel(store.choices.sort)) {
                    ForEach(sorts) { value in
                        Button(sortLabel(value)) { change(.sort) { $0.sort = value; $0.direction = value.defaultDirection } }
                    }
                }.accessibilityIdentifier("librarySort").focused($focus, equals: .sort)
                Menu("Direction: " + store.choices.direction.rawValue) {
                    ForEach(LibrarySortDirection.allCases) { value in Button(value.rawValue) { change(.direction) { $0.direction = value } } }
                }.accessibilityIdentifier("libraryDirection").focused($focus, equals: .direction)
                Menu(activeFilterCount == 0 ? "Filters" : "Filters · \(activeFilterCount)") {
                    if destination?.parent == nil {
                        Menu("Library: " + (store.libraries.first { $0.id == store.scope.libraryID }?.Name ?? "All libraries")) {
                            Button("All libraries") { selectLibrary("") }
                            ForEach(store.libraries) { item in Button(item.Name) { selectLibrary(item.id) } }
                        }.accessibilityIdentifier("libraryPicker")
                    }
                    Menu("Genre: " + (store.genres.first { $0.id == store.choices.genreID }?.Name ?? "All genres")) {
                        Button("All genres") { change(.genre) { $0.genreID = "" } }
                        ForEach(store.genres) { item in Button(item.Name) { change(.genre) { $0.genreID = item.id } } }
                    }.accessibilityIdentifier("genrePicker")
                    Menu("Watch: " + store.choices.watchStatus) {
                        ForEach(["Any", "Watched", "Unwatched"], id: \.self) { value in Button(value) { change(.watch) { $0.watchStatus = value } } }
                    }.accessibilityIdentifier("watchPicker")
                    if store.scope.category == "Favorites" {
                        Text("This category shows favorites.")
                    } else {
                        Button(store.choices.favoritesOnly ? "Favorites only: On" : "Favorites only: Off") {
                            change(.favorite) { $0.favoritesOnly.toggle() }
                        }.accessibilityIdentifier("favoritesOnly")
                    }
                    if activeFilterCount > 0 {
                        Button("Clear filters") {
                            focus = .filters
                            if let api = coordinator.session.api { Task { await store.clearFilters(api: api) } }
                        }.accessibilityIdentifier("clearFilters")
                    }
                }.accessibilityIdentifier("libraryFilters").accessibilityValue(filterSummary.isEmpty ? "All libraries, any watch status" : filterSummary)
                    .focused($focus, equals: .filters)
                presentationMenu
            }
            // Full width, so Up from Refresh library at the far right of the next row lands here
            // instead of skipping to the tab bar.
            .frame(maxWidth: .infinity, alignment: .leading).focusSection()
            if !filterSummary.isEmpty { Text(filterSummary).font(.system(size: 21)).foregroundStyle(Color.tvMuted).accessibilityIdentifier("libraryFilterSummary") }
        }
        .font(.system(size: 22, weight: .semibold))
        .disabled(!store.optionsReady || store.optionsLoading)
    }

    private var presentationMenu: some View {
        Menu("View: " + (store.choices.viewStyle == .grid ? "Grid" : "List")) {
            Button("Grid") { change(.style) { $0.viewStyle = .grid } }
            Button("List") { change(.style) { $0.viewStyle = .list } }
        }.accessibilityIdentifier("libraryViewStyle").focused($focus, equals: .style)
    }

    @ViewBuilder private var recovery: some View {
        if store.optionsLoading { HStack(spacing: 18) { ProgressView(); Text("Opening library filters…") }.accessibilityIdentifier("filterOptionsLoading") }
        if let message = store.optionsError {
            VStack(alignment: .leading, spacing: 20) {
                Text(message).foregroundStyle(Color.tvMuted).accessibilityIdentifier("filterOptionsError")
                HStack(spacing: 25) {
                    Button("Retry library filters") {
                        focus = .options
                        if let api = coordinator.session.api { Task {
                            await store.retryOptions(api: api)
                            restoreFocus(from: .options, to: store.optionsError == nil ? (store.isPlaylist ? .refresh : .sort) : .options)
                        } }
                    }.disabled(store.optionsLoading).accessibilityIdentifier("retryFilterOptions").focused($focus, equals: .options)
                    Button("Browse with temporary defaults") {
                        focus = .defaults
                        if let api = coordinator.session.api { Task { await store.browseWithDefaults(api: api) } }
                    }.disabled(store.optionsLoading).accessibilityIdentifier("browseDefaults").focused($focus, equals: .defaults)
                }
            }.focusSection()
        }
        if store.usingTemporaryDefaults {
            Text("Showing all libraries without your saved filters. Retry library filters to bring them back.")
                .foregroundStyle(Color.tvMuted).accessibilityIdentifier("temporaryBrowseDefaults")
        }
        if let message = store.preferenceError {
            VStack(alignment: .leading, spacing: 20) {
                Text(message).foregroundStyle(Color.tvMuted).accessibilityIdentifier("browsePreferenceError")
                HStack(spacing: 25) {
                    Button("Retry saved choices") {
                        focus = .preferences
                        if let api = coordinator.session.api { Task {
                            await store.retryPreferences(api: api)
                            restoreFocus(from: .preferences, to: store.preferenceError == nil ? (store.isPlaylist ? .refresh : .sort) : .preferences)
                        } }
                    }.accessibilityIdentifier("retryBrowsePreferences").focused($focus, equals: .preferences)
                    Button("Reset this account’s browse choices") { confirmReset = true }.accessibilityIdentifier("resetBrowsePreferences")
                }
            }.focusSection()
        }
    }

    @ViewBuilder private var listing: some View {
        if searching && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            TVEmpty(title: "A title in mind?", message: "Search movies, series and episodes.", symbol: "magnifyingglass")
                .padding(.top, 60)
        } else if store.loading && store.items.isEmpty {
            TVSkeletonGrid(wide: store.scope.category == "Episodes")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Opening your library.")
                .accessibilityIdentifier("libraryLoading")
        } else if let error = store.error, store.items.isEmpty {
            TVFailure(title: "The library couldn’t load.", message: error) { refresh += 1 }
        } else if !store.optionsReady && !store.optionsLoading && store.items.isEmpty {
            Text("Choose Retry or temporary defaults above to open this library.").foregroundStyle(Color.tvMuted)
        } else if store.items.isEmpty && store.optionsReady {
            TVEmpty(title: "No titles found.", message: searching ? "Try another title or a shorter search." : "Try another filter or clear the current filters.",
                    symbol: searching ? "magnifyingglass" : "line.3.horizontal.decrease.circle")
        } else {
            if store.choices.viewStyle == .grid {
                // Rows align to the top, so a still beside posters (search mixes them) starts on the same line.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: store.scope.category == "Episodes" ? 350 : 230, maximum: store.scope.category == "Episodes" ? 440 : 310), spacing: 35, alignment: .top)], alignment: .leading, spacing: 40) {
                    ForEach(store.rows) { row in
                        TVCard(item: row.item, wide: row.item.Type == "Episode", dateText: dateText(row.item), controlID: row.accessibilityID, countStale: store.error != nil || store.loading || store.optionsLoading || store.optionsError != nil, selection: watched.selecting ? watched.selected.contains(row.item.id) : nil,
                               action: { open(row.item) }, focus: TVFocusTag(binding: $focus, value: Focus.item(row.accessibilityID)))
                            .disabled(watched.busy)
                    }
                }.focusSection().accessibilityIdentifier("libraryGrid")
            } else {
                LazyVStack(alignment: .leading, spacing: 25) {
                    ForEach(store.rows) { row in
                        let item = row.item
                        Button { open(item) } label: {
                            HStack(spacing: 30) {
                                TVArtwork(item: item.thumbnailItem, backdrop: true, width: 350).aspectRatio(16.0 / 9, contentMode: .fit).frame(width: 200)
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(item.title).font(.system(size: 28, weight: .medium)).lineLimit(2)
                                    Text(item.subtitle).font(.system(size: 22)).foregroundStyle(Color.tvMuted).lineLimit(2)
                                    TVUnwatchedCount(item: item, stale: store.error != nil || store.loading || store.optionsLoading || store.optionsError != nil)
                                    if watched.selecting { Label(watched.selected.contains(item.id) ? "Selected" : "Not selected", systemImage: watched.selected.contains(item.id) ? "checkmark.circle.fill" : "circle") }
                                    if let date = dateText(item) { Text(date).font(.system(size: 19)).foregroundStyle(Color.tvMuted) }
                                }
                                Spacer(minLength: 20)
                            }.padding(18).background(Color.reelSurface).contentShape(Rectangle())
                        }.buttonStyle(TVLiftStyle(scale: 1.02, radius: 16)).accessibilityIdentifier(row.accessibilityID)
                            .accessibilityValue([item.isAggregate ? item.aggregateUnplayedCount.map { "\($0) unwatched" } ?? "Unwatched count unavailable" : nil, watched.selecting ? watched.selected.contains(item.id) ? "Selected" : "Not selected" : nil].compactMap { $0 }.joined(separator: ", "))
                            .accessibilityAddTraits(watched.selecting && watched.selected.contains(item.id) ? .isSelected : [])
                            .focused($focus, equals: .item(row.accessibilityID)).disabled(watched.busy)
                    }
                }.focusSection().accessibilityIdentifier("libraryList")
            }
            if let error = store.error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("libraryPageError") }
            if store.hasMore {
                Button(store.loading ? "Loading…" : store.error == nil ? "Load more titles" : "Retry loading more titles") {
                    focus = .more
                    if let api = coordinator.session.api { Task {
                        let before = store.items.count, expected = store.query
                        await store.loadMore(api: api)
                        if store.active, store.query == expected, !store.hasMore,
                           let row = store.rows.dropFirst(before).first ?? store.rows.last {
                            restoreFocus(from: .more, to: .item(row.accessibilityID))
                        } else { restoreFocus(from: .more, to: .more) }
                    } }
                }.disabled(watched.busy || store.loading).accessibilityIdentifier("loadMore").focused($focus, equals: .more)
            }
        }
    }

    private func restoreFocus(from previous: Focus, to target: Focus) {
        if store.active, focus == previous || focus == nil { focus = target }
    }
    /// The added date is shown only when the order depends on it, as on iPhone and iPad.
    private func dateText(_ item: MediaItem) -> String? {
        if store.choices.sort == .latestEpisodeAdded, item.isSeries { return item.lastMediaAddedDateText }
        return store.choices.sort == .recentlyAdded ? item.addedDateText : nil
    }
    private func sortLabel(_ sort: LibrarySort) -> String {
        if sort == .recentlyAdded { return store.scope.category == "Series" ? "Series added" : store.scope.category == "Episodes" ? "Episode added" : "Recently added" }
        return sort.label
    }
    private func selectLibrary(_ id: String) {
        focus = .filters
        if let api = coordinator.session.api { Task { await store.selectLibrary(id, api: api) } }
    }
    private func change(_ focused: Focus, _ edit: @escaping (inout BrowseChoices) -> Void) {
        switch focused {
        case .library, .genre, .watch, .favorite, .clear: focus = .filters
        default: focus = focused
        }
        if let api = coordinator.session.api { Task { await store.change(api: api, edit) } }
    }
}
