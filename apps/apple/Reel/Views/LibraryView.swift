import SwiftUI

struct LibraryView: View {
    enum Mode { case library, search }
    let mode: Mode
    init(mode: Mode, initialFilter: String = "All", initialSort: LibrarySort = .title, parent: MediaItem? = nil, initialQueryIntent: Bool = false) {
        self.mode = mode; self.parent = parent; self.initialQueryIntent = initialQueryIntent
        self.openingSort = initialSort
        _usesInitialQueryIntent = State(initialValue: initialQueryIntent)
        _direction = State(initialValue: initialSort.defaultDirection)
        _filter = State(initialValue: initialFilter)
        _sort = State(initialValue: initialSort == .latestEpisodeAdded && initialFilter != "Series" ? .recentlyAdded : initialSort)
    }
    let parent: MediaItem?
    let initialQueryIntent: Bool
    private let openingSort: LibrarySort
    @Environment(Session.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.foldCrease) private var foldCrease
    @State private var page = LibraryPagination()
    @State private var libraries: [MediaItem] = []
    @State private var selectedLibrary = ""
    @State private var query = ""
    @State private var filter = "All"
    @State private var sort = LibrarySort.title
    @State private var direction = LibrarySortDirection.ascending
    @State private var favoritesOnly = false
    @State private var viewStyle = BrowseViewStyle.grid
    @State private var usesInitialQueryIntent = false
    @State private var preparedContext: ScopeIdentity?
    @State private var completedLoad: LoadIdentity?
    @State private var rootRestoredRevision: UUID?
    @State private var restoreRootAfterRetry = false
    @State private var optionsAttempt = 0
    @State private var lastOptionsAttempt = -1
    @State private var librariesReady = false
    @State private var genresReady = false
    @State private var preferencesError: String?
    @State private var resetIntent: ResetIntent?
    @State private var parentDetail: MediaItem?
    @State private var parentError: String?
    @State private var parentReadGeneration = UUID()
    @State private var genres: [MediaItem] = []
    @State private var genre = ""
    @State private var watchFilter = "Any"
    @State private var loading = false
    @State private var refreshFailed = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshTaskID: UUID?
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var optionsError: String?
    @State private var optionsRequestID = UUID()
    @State private var optionsLoading = false
    private var items: [MediaItem] { page.items }
    private var request: LibraryQuery {
        LibraryQuery(search: query, category: filter, sort: sort, direction: direction, libraryID: selectedLibrary, genreID: genre,
                     watchStatus: watchFilter, favoritesOnly: favoritesOnly, parentID: parent?.id, parentType: parent?.Type, isSearch: mode == .search)
    }
    private var activeFilters: Int { [!selectedLibrary.isEmpty, !genre.isEmpty, watchFilter != "Any", favoritesOnly].filter { $0 }.count }
    private var filterDescription: String {
        [libraries.first { $0.id == selectedLibrary }?.Name,
         genres.first { $0.id == genre }?.Name, watchFilter == "Any" ? nil : watchFilter, favoritesOnly || filter == "Favorites" ? "Favorites" : nil].compactMap { $0 }.joined(separator: " · ")
    }
    /// Library: the title count. Search: the result count once a search has returned.
    private var countLabel: String? {
        guard mode == .search else { return page.total.map { "\($0) titles" } ?? "\(items.count) loaded" }
        guard request.canLoad, completedLoad == loadIdentity, let total = page.total else { return nil }
        return total == 1 ? "1 result" : "\(total) results"
    }
    private var refreshLabel: String { mode == .search ? "Refresh results" : "Refresh library" }
    private var refreshStateLabel: String { preparedContext != scopeIdentity ? "Checking filters" : loading ? "Loading" : "Ready" }
    private let filters = ["All", "Movies", "Series", "Episodes", "Favorites", "Collections", "Playlists"]
    private var availableSorts: [LibrarySort] { LibrarySort.allCases.filter { $0 != .latestEpisodeAdded || filter == "Series" } }
    private func sortLabel(_ value: LibrarySort) -> String { filter == "Series" && value == .recentlyAdded ? "Series added" : value.label }

    var body: some View {
        GeometryReader { geometry in
            // One margin for the rail, the controls and the grid, so every row starts on the same edge.
            let margin = AdaptiveLayout.margin(regular: horizontalSizeClass == .regular, width: geometry.size.width)
            ScrollViewReader { scroll in
                if dynamicTypeSize.isAccessibilitySize || geometry.size.height < 400 {
                    VStack(alignment: .leading, spacing: 16) {
                        categoryRail(margin: margin)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                libraryControls(margin: margin).id(ScrollAnchor.top)
                                refreshFailureView(margin: margin)
                                if items.isEmpty {
                                    emptyState(width: geometry.size.width, margin: margin).fixedSize(horizontal: false, vertical: true)
                                        .frame(minHeight: max(240, geometry.size.height * 0.4))
                                } else {
                                    listingContent(availableWidth: geometry.size.width, margin: margin, scroll: scroll)
                                }
                            }.padding(.bottom, 24)
                        }.accessibilityIdentifier("libraryScroll")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        categoryRail(margin: margin)
                        libraryControls(margin: margin)
                        ScrollView {
                            Color.clear.frame(height: 1).id(ScrollAnchor.top)
                            refreshFailureView(margin: margin)
                            if items.isEmpty {
                                emptyState(width: geometry.size.width, margin: margin,
                                           page: FoldSpread(crease: foldCrease, in: geometry.frame(in: .global))?.leadingWidth)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(minHeight: max(240, geometry.size.height * 0.4))
                            } else {
                                listingContent(availableWidth: geometry.size.width, margin: margin, scroll: scroll)
                            }
                        }.accessibilityIdentifier("libraryScroll")
                    }
                }
            }
        }
        .reelCanvas()
        .navigationTitle(parent?.Name ?? (mode == .library ? "Library" : "Search"))
        .navigationBarTitleDisplayMode(.inline)
        // At accessibility sizes the collapsible field draws neither its icon nor its prompt, so it stays open.
        .modifier(LibrarySearch(query: $query, enabled: parent?.Type != "Playlist", alwaysVisible: mode == .search || dynamicTypeSize.isAccessibilitySize))
        .toolbar {
            // A blank search has nothing to refresh, so the button waits for a term.
            if !dynamicTypeSize.isAccessibilitySize && request.canLoad {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh() } } label: {
                        ZStack {
                            if loading { ProgressView().controlSize(.small).accessibilityHidden(true) }
                            else { Image(systemName: "arrow.clockwise").font(.system(size: 17, weight: .semibold)).accessibilityHidden(true) }
                        }.frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(loading || !request.canLoad || preparedContext != scopeIdentity)
                        .accessibilityIdentifier("libraryRefresh").accessibilityLabel(refreshLabel)
                        .accessibilityValue(refreshStateLabel)
                        .accessibilityHint("Reload the current results with your selected sort and filters.")
                }
            }
        }
        .task(id: PreparationIdentity(scope: scopeIdentity, attempt: optionsAttempt)) { await prepareContext() }
        .task(id: loadIdentity) {
            guard preparedContext == scopeIdentity else { return }
            if completedLoad == loadIdentity, error == nil { return }
            cancelRefresh()
            if mode == .search {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            await load(reset: true)
        }
        .task(id: session.libraryRevision) { await loadParent() }
        .onDisappear { cancelRefresh(); optionsRequestID = UUID() }
        .confirmationDialog("Reset saved browse choices?", isPresented: Binding(get: { resetIntent != nil }, set: { if !$0 { resetIntent = nil } }), titleVisibility: .visible) {
            if let intent = resetIntent {
                Button("Reset this account’s browse choices", role: .destructive) { resetIntent = nil; resetPreferences(intent) }
                    .accessibilityIdentifier("confirmBrowseReset")
                Button("Cancel", role: .cancel) { resetIntent = nil }.accessibilityIdentifier("cancelBrowseReset")
            }
        } message: { Text("This resets only browse choices for this Jellyfin account on this device. Your saved sign-in and server library stay in place.") }
    }

    @ViewBuilder private func categoryRail(margin: CGFloat) -> some View {
        if mode == .library && parent == nil {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(filters, id: \.self) { name in
                        let selected = filter == name
                        Button { chooseCategory(name) } label: {
                            Text(name).font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: true, vertical: false).padding(.horizontal, 16).frame(minWidth: 44, minHeight: 44)
                                .foregroundStyle(selected ? Color.reelText : Color.reelMuted)
                                .background(selected ? Color.reelText.opacity(0.2) : Color.reelFill, in: Capsule())
                                .contentShape(Capsule())
                        }.buttonStyle(.plain).accessibilityIdentifier("filter-\(name)")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }.contentMargins(.horizontal, margin, for: .scrollContent).scrollIndicators(.hidden)
                // Chips stop at the safe area, so on iPhone Duo's outer screen they never pass under the status strip.
                .clipped()
                .padding(.top, 8)
        }
    }

    private func libraryControls(margin: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preferencesError {
                VStack(alignment: .leading, spacing: 10) {
                    Text(preferencesError).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("browsePreferencesError")
                    HStack {
                        Button("Retry saved choices") { retryPreferences() }.accessibilityIdentifier("retryBrowsePreferences")
                        Button("Reset saved choices") { confirmReset() }.accessibilityIdentifier("resetBrowsePreferences")
                    }.font(.caption)
                }.padding(.horizontal, margin)
            }
            if let container = parentDetail ?? parent {
                VStack(alignment: .leading, spacing: 10) {
                    UnwatchedCountBadge(item: container)
                    WatchedStatusButton(item: container, identifier: "containerWatchStatus")
                    if let parentError {
                        Text("Container status could not refresh. Previous metadata is shown. " + parentError)
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Button("Retry container status") { Task { await loadParent() } }.accessibilityIdentifier("retryContainerStatus")
                    }
                }.padding(.horizontal, margin)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let countLabel {
                    Text(countLabel).font(.footnote.weight(.medium)).foregroundStyle(Color.reelMuted).accessibilityIdentifier("libraryCount")
                }
                // An empty search has nothing to sort or filter yet.
                if mode == .search && !request.canLoad { EmptyView() }
                else if parent?.Type != "Playlist" {
                    // One row when the sort name fits on one line beside the other controls. A narrower
                    // column, or the largest text sizes, wraps the controls instead of breaking the name.
                    ViewThatFits(in: .horizontal) {
                        if !dynamicTypeSize.isAccessibilitySize {
                            HStack(spacing: 8) {
                                sortControl(oneLine: true)
                                directionControl
                                filterControl
                                Spacer(minLength: 0)
                                viewStyleControl
                            }
                        }
                        WrapLayout(spacing: 8, lineSpacing: 8) {
                            sortControl(oneLine: !dynamicTypeSize.isAccessibilitySize)
                            directionControl
                            filterControl
                            viewStyleControl
                        }
                    }
                } else { viewStyleControl }
                if dynamicTypeSize.isAccessibilitySize && request.canLoad {
                    // Styled like the sort chip above it, not as a full-width slab.
                    Button { Task { await refresh() } } label: {
                        HStack(spacing: 6) {
                            if loading { ProgressView().controlSize(.small).accessibilityHidden(true) }
                            else { Image(systemName: "arrow.clockwise").font(.footnote.weight(.semibold)).foregroundStyle(Color.reelMuted).accessibilityHidden(true) }
                            Text(loading ? "Loading…" : refreshLabel)
                                .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                        }.font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelText).padding(.horizontal, 14)
                            .frame(minHeight: 44, alignment: .leading).background(Color.reelFill, in: Capsule()).contentShape(Capsule())
                    }.buttonStyle(.plain).disabled(loading || !request.canLoad || preparedContext != scopeIdentity)
                        .accessibilityIdentifier("libraryRefresh").accessibilityLabel(refreshLabel)
                        .accessibilityValue(refreshStateLabel)
                        .accessibilityHint("Reload the current results with your selected sort and filters.")
                }
            }.padding(.horizontal, margin)
            if !filterDescription.isEmpty {
                Text(filterDescription).font(.footnote).foregroundStyle(Color.reelMuted)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, margin).accessibilityIdentifier("libraryFilterSummary")
            }
            if optionsLoading {
                ProgressView(preparedContext == scopeIdentity ? "Loading filter choices…" : "Checking saved filters…")
                    .font(.caption).padding(.horizontal, margin).accessibilityIdentifier("libraryOptionsLoading")
            }
            if let optionsError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(optionsError).font(.caption).foregroundStyle(Color.reelMuted).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("libraryOptionsError")
                    Button("Retry library filters") { optionsAttempt += 1 }.disabled(optionsLoading).accessibilityIdentifier("libraryOptionsRetry")
                    if preparedContext != scopeIdentity {
                        Button("Use unfiltered view") { clearFilters() }.accessibilityIdentifier("libraryUseUnfiltered")
                    }
                }.padding(.horizontal, margin)
            }

        }
    }

    private func sortControl(oneLine: Bool) -> some View {
        Menu {
            Picker("Sort", selection: Binding(get: { sort }, set: chooseSort)) {
                ForEach(availableSorts) { Text(sortLabel($0)).tag($0) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down").font(.footnote.weight(.semibold)).foregroundStyle(Color.reelMuted)
                Text(sortLabel(sort)).lineLimit(oneLine ? 1 : nil).fixedSize(horizontal: oneLine, vertical: true).multilineTextAlignment(.leading)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Color.reelTertiary)
            }.font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelText).padding(.horizontal, 14)
                .frame(minHeight: 44, alignment: .leading).background(Color.reelFill, in: Capsule()).contentShape(Capsule())
        }.accessibilityIdentifier("librarySort").accessibilityValue(sortLabel(sort))
    }

    private var directionControl: some View {
        Button { chooseDirection() } label: {
            Label(direction == .ascending ? "Ascending" : "Descending", systemImage: direction == .ascending ? "arrow.up" : "arrow.down")
                // The circle grows with the arrow at accessibility sizes instead of clipping it.
                .labelStyle(.iconOnly).font(.subheadline.weight(.semibold))
                .padding(dynamicTypeSize.isAccessibilitySize ? 10 : 0).frame(minWidth: 44, minHeight: 44)
                .background(Color.reelFill, in: Circle()).contentShape(Circle())
        }.buttonStyle(.plain).accessibilityIdentifier("libraryDirection").accessibilityValue(direction.rawValue)
    }

    private var filterControl: some View {
        Menu {
            if parent == nil {
                Picker("Library", selection: Binding(get: { selectedLibrary }, set: chooseLibrary)) {
                    Text("All libraries").tag("")
                    if !selectedLibrary.isEmpty, !libraries.contains(where: { $0.id == selectedLibrary }) { Text("Checking saved library…").tag(selectedLibrary) }
                    ForEach(libraries) { Text($0.Name).tag($0.id) }
                }.disabled(!librariesReady)
            }
            Picker("Genre", selection: Binding(get: { genre }, set: chooseGenre)) {
                Text("All genres").tag("")
                if !genre.isEmpty, !genres.contains(where: { $0.id == genre }) { Text("Checking saved genre…").tag(genre) }
                ForEach(genres) { Text($0.Name).tag($0.id) }
            }.disabled(!genresReady)
            Picker("Watch status", selection: Binding(get: { watchFilter }, set: chooseWatch)) { Text("Any").tag("Any"); Text("Unwatched").tag("Unwatched"); Text("Watched").tag("Watched") }
            Toggle("Favorites only", isOn: Binding(get: { favoritesOnly || filter == "Favorites" }, set: chooseFavorites))
                .disabled(filter == "Favorites").accessibilityIdentifier("libraryFavorites")
            if activeFilters > 0 { Button("Clear filters", systemImage: "xmark.circle") { clearFilters() } }
            if optionsError != nil { Button("Retry library filters", systemImage: "arrow.clockwise") { optionsAttempt += 1 }.disabled(optionsLoading) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                if dynamicTypeSize.isAccessibilitySize { Text("Filters") }
                if activeFilters > 0 { Text("\(activeFilters)").font(.caption.weight(.bold)).foregroundStyle(Color.reelBlue) }
            }.font(.subheadline.weight(.semibold)).padding(.horizontal, activeFilters > 0 || dynamicTypeSize.isAccessibilitySize ? 14 : 0)
                .frame(minWidth: 44, minHeight: 44).background(Color.reelFill, in: Capsule()).contentShape(Capsule())
                .foregroundStyle(Color.reelText)
        }.accessibilityLabel(activeFilters == 0 ? "Filters" : "Filters, \(activeFilters) active").accessibilityIdentifier("libraryFilters")
    }

    private var viewStyleControl: some View {
        Picker("View style", selection: Binding(get: { viewStyle }, set: chooseView)) {
            Label("Grid", systemImage: "square.grid.2x2").tag(BrowseViewStyle.grid)
            Label("List", systemImage: "list.bullet").tag(BrowseViewStyle.list)
        }.labelStyle(.iconOnly).pickerStyle(.segmented).frame(width: 92).accessibilityIdentifier("libraryViewStyle")
    }

    @ViewBuilder private func refreshFailureView(margin: CGFloat) -> some View {
        if refreshFailed, let error {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your loaded titles are still here.").font(.caption).foregroundStyle(Color.reelText)
                Text(error).font(.caption).foregroundStyle(Color.reelMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry refresh") { Task { await refresh() } }
                    .buttonStyle(QuietButton()).disabled(loading).accessibilityIdentifier("libraryRefreshRetry")
            }.padding(.horizontal, margin)
        }
    }

    /// `page` is the left page's width on an open foldable: a message keeps to it, clear of the crease.
    @ViewBuilder private func emptyState(width: CGFloat, margin: CGFloat, page: CGFloat? = nil) -> some View {
        if preparedContext != scopeIdentity, request.canLoad {
            if optionsLoading { loadingPlaceholder("Checking saved filters…", availableWidth: width, margin: margin) }
            else { ContentUnavailableView("Check your saved filters", systemImage: "line.3.horizontal.decrease", description: Text("Retry the filter choices or use an unfiltered view before loading this collection.")) }
        }
        else if loading { loadingPlaceholder("Finding your titles…", availableWidth: width, margin: margin) }
        else {
            Group {
                if let error { FailureView(message: error) { Task { await load(reset: true) } } }
                else if mode == .search && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("A title in mind?", systemImage: "magnifyingglass", description: Text("Search movies, series and episodes.").foregroundStyle(Color.reelMuted))
                } else {
                    ContentUnavailableView(filter == "Favorites" ? "Keep the good ones close" : "No titles found", systemImage: filter == "Favorites" ? "heart" : "film", description: Text(filter == "Favorites" ? "Tap the heart on a film or series to save it here." : "Try another search or library."))
                }
            }
            .frame(width: page).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Grid columns from the width: as many posters as fit at the minimum width, never fewer than two.
    private func gridMetrics(availableWidth: CGFloat, margin: CGFloat) -> (count: Int, width: CGFloat) {
        let content = availableWidth - 2 * margin
        let minimum: CGFloat = horizontalSizeClass == .regular ? 160 : 150
        let count = dynamicTypeSize.isAccessibilitySize || viewStyle == .list ? 1
            : max(2, Int((content + Self.gridSpacing) / (minimum + Self.gridSpacing)))
        return (count, max(80, (content - CGFloat(count - 1) * Self.gridSpacing) / CGFloat(count)))
    }
    private static let gridSpacing: CGFloat = 16

    private func gridColumns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.gridSpacing, alignment: .top), count: count)
    }

    /// Shaped like the grid or list it stands in for, so nothing jumps when titles arrive.
    private func loadingPlaceholder(_ label: String, availableWidth: CGFloat, margin: CGFloat) -> some View {
        let grid = gridMetrics(availableWidth: availableWidth, margin: margin)
        let list = grid.count == 1
        return LazyVGrid(columns: gridColumns(grid.count), alignment: .leading, spacing: list ? 16 : 24) {
            ForEach(0..<(list ? 5 : grid.count * 2), id: \.self) { _ in
                if list {
                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))) {
                        RoundedRectangle(cornerRadius: ReelRadius.artwork).fill(Color.reelSurface).frame(width: 88, height: 132)
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.reelSurface).frame(width: 160, height: 14)
                            RoundedRectangle(cornerRadius: 4).fill(Color.reelSurface).frame(width: 96, height: 12)
                        }.padding(.top, 4)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: ReelRadius.artwork).fill(Color.reelSurface).frame(width: grid.width, height: grid.width * 1.5)
                        RoundedRectangle(cornerRadius: 4).fill(Color.reelSurface).frame(width: grid.width * 0.7, height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Color.reelSurface).frame(width: grid.width * 0.4, height: 10)
                    }
                }
            }
        }
        .padding(.horizontal, margin).frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement().accessibilityLabel(label)
    }

    private func listingContent(availableWidth: CGFloat, margin: CGFloat, scroll: ScrollViewProxy) -> some View {
        let grid = gridMetrics(availableWidth: availableWidth, margin: margin)
        return VStack(spacing: 0) {
            LazyVGrid(columns: gridColumns(grid.count), alignment: .leading, spacing: grid.count == 1 ? 16 : 24) {
                ForEach(items, id: \.listingID) { item in
                    NavigationLink {
                        if item.isContainer { LibraryView(mode: .library, parent: item) }
                        // A plain push: a zoom transition's swipe-down dismissal would
                        // take over pull-to-refresh on Details.
                        else { DetailView(item: item) }
                    } label: { libraryCard(item, width: grid.width) }
                        .buttonStyle(.plain).accessibilityIdentifier("item-\(item.id)")
                }
            }.padding(.horizontal, margin)
            if let error, !refreshFailed {
                Text(error).font(.footnote).padding()
                Button("Retry") { Task { await load(reset: false) } }
                    .disabled(loading).accessibilityIdentifier("libraryRetry")
            }
            if page.hasMore && error == nil {
                Button { Task { await load(reset: false) } } label: {
                    if loading { ProgressView() } else { Text("Load more titles") }
                }.buttonStyle(QuietButton()).disabled(loading || preparedContext != scopeIdentity).padding(24).accessibilityIdentifier("loadMore")
            }
            if page.nextIndex > 60 {
                Button {
                    if reduceMotion { scroll.scrollTo(ScrollAnchor.top, anchor: .top) }
                    else { withAnimation(.snappy) { scroll.scrollTo(ScrollAnchor.top, anchor: .top) } }
                } label: { Label("Back to top", systemImage: "arrow.up.to.line") }
                    .buttonStyle(QuietButton()).padding(.bottom, 12).accessibilityIdentifier("libraryBackToTop")
            }
            Color.clear.frame(height: 24)
        }
    }

    @ViewBuilder private func libraryCard(_ item: MediaItem, width: CGFloat) -> some View {
        if dynamicTypeSize.isAccessibilitySize || viewStyle == .list {
            // At accessibility sizes the poster sits above the text, so a title has the full width
            // and does not break mid-word.
            (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))) {
                Artwork(item: item, width: 300).frame(width: 88, height: 132)
                    .overlay(alignment: .topTrailing) {
                        if item.isFavorite {
                            Image(systemName: "heart.fill").font(.system(size: 11)).padding(6)
                                .background(.black.opacity(0.65), in: Circle()).padding(5).foregroundStyle(Color.reelBlue)
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: ReelRadius.artwork))
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.body.weight(.medium)).foregroundStyle(Color.reelText)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("libraryRowTitle-\(item.id)")
                    Text(item.subtitle).font(.subheadline).foregroundStyle(Color.reelMuted)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("libraryRowSubtitle-\(item.id)")
                    UnwatchedCountBadge(item: item)
                    if let date = catalogueLabel(item) { Text(date).font(.caption).foregroundStyle(Color.reelMuted).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("libraryAddedDate-\(item.id)") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(width: width, alignment: .leading).contentShape(Rectangle()).accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                PosterCard(item: item, width: width)
                UnwatchedCountBadge(item: item)
                if let date = catalogueLabel(item) { Text(date).font(.caption2).foregroundStyle(Color.reelMuted).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("libraryAddedDate-\(item.id)") }
            }.frame(width: width, alignment: .leading)
        }
    }
    private func catalogueLabel(_ item: MediaItem) -> String? {
        if request.effectiveSort == .latestEpisodeAdded, item.isSeries { return item.lastMediaAddedDateText }
        if request.effectiveSort == .recentlyAdded { return item.addedDateText }
        return nil
    }

    private struct ScopeIdentity: Hashable {
        let account: UUID; let library: String; let category: String; let parent: String?; let parentType: String?
    }
    private struct PreparationIdentity: Hashable { let scope: ScopeIdentity; let attempt: Int }
    private struct LoadIdentity: Hashable { let query: LibraryQuery; let account: UUID; let refresh: Int; let prepared: ScopeIdentity? }
    private struct ResetIntent { let account: BrowseAccountScope; let accountID: String; let revision: UUID }
    private enum OptionResult: Sendable { case libraries([MediaItem]), genres([MediaItem]), libraryError(String), genreError(String) }
    private enum ScrollAnchor: Hashable { case top }
    private var scopeIdentity: ScopeIdentity { ScopeIdentity(account: session.revision, library: selectedLibrary, category: filter, parent: parent?.id, parentType: parent?.Type) }
    private var loadIdentity: LoadIdentity { LoadIdentity(query: request, account: session.revision, refresh: session.libraryRevision, prepared: preparedContext) }
    private var preferenceScope: BrowseScope { BrowseScope(libraryID: selectedLibrary, category: filter, parentID: parent?.id, parentType: parent?.Type) }
    private var preferenceAccount: BrowseAccountScope? { session.account.flatMap { try? BrowseAccountScope(server: $0.server, userID: $0.userID) } }
    private var choices: BrowseChoices { BrowseChoices(sort: sort, direction: direction, genreID: genre, watchStatus: watchFilter, favoritesOnly: favoritesOnly, viewStyle: viewStyle) }

    private func apply(_ value: BrowseChoices) {
        sort = value.sort; direction = value.direction; genre = value.genreID
        watchFilter = value.watchStatus; favoritesOnly = value.favoritesOnly; viewStyle = value.viewStyle
    }
    private func updatePreferencesError(_ account: BrowseAccountScope) { preferencesError = BrowsePreferencesStore.shared.error(for: account) }
    private func persistChoices() {
        guard let account = preferenceAccount else { return }
        _ = BrowsePreferencesStore.shared.save(choices, for: preferenceScope, account: account)
        updatePreferencesError(account)
    }
    private func persistRoot() {
        guard mode == .library, parent == nil, !initialQueryIntent, let account = preferenceAccount else { return }
        _ = BrowsePreferencesStore.shared.saveRoot(BrowseRootLocation(libraryID: selectedLibrary, category: filter), account: account)
        updatePreferencesError(account)
    }
    private func chooseSort(_ value: LibrarySort) { usesInitialQueryIntent = false; sort = value; direction = value.defaultDirection; persistChoices() }
    private func chooseDirection() { usesInitialQueryIntent = false; direction = direction.opposite; persistChoices() }
    private func chooseGenre(_ value: String) { usesInitialQueryIntent = false; genre = value; persistChoices() }
    private func chooseWatch(_ value: String) { usesInitialQueryIntent = false; watchFilter = value; persistChoices() }
    private func chooseFavorites(_ value: Bool) { usesInitialQueryIntent = false; favoritesOnly = value; persistChoices() }
    private func chooseView(_ value: BrowseViewStyle) {
        viewStyle = value
        guard let account = preferenceAccount else { return }
        _ = BrowsePreferencesStore.shared.saveViewStyle(value, for: preferenceScope, account: account)
        updatePreferencesError(account)
    }
    private func chooseCategory(_ value: String) { preparedContext = nil; usesInitialQueryIntent = false; filter = value; persistRoot() }
    private func chooseLibrary(_ value: String) { preparedContext = nil; usesInitialQueryIntent = false; selectedLibrary = value; persistRoot() }
    private func clearFilters() {
        usesInitialQueryIntent = false; preparedContext = nil
        selectedLibrary = ""; genre = ""; watchFilter = "Any"; favoritesOnly = false
        // Persist the explicit clear in its FINAL scope, before that scope can query.
        persistChoices(); persistRoot(); optionsAttempt += 1
    }
    private func retryPreferences() {
        guard let account = preferenceAccount else { return }
        if BrowsePreferencesStore.shared.retry(account) { preparedContext = nil; restoreRootAfterRetry = true; optionsAttempt += 1 }
        updatePreferencesError(account)
    }
    private func confirmReset() {
        guard let account = session.account, let scope = preferenceAccount else { return }
        resetIntent = ResetIntent(account: scope, accountID: account.id, revision: session.revision)
    }
    private func resetPreferences(_ intent: ResetIntent) {
        guard session.account?.id == intent.accountID, session.revision == intent.revision else { return }
        if BrowsePreferencesStore.shared.reset(intent.account) {
            preparedContext = nil; completedLoad = nil; rootRestoredRevision = nil; optionsAttempt += 1
        }
        updatePreferencesError(intent.account)
    }

    private func prepareContext() async {
        guard let api = session.api, let account = preferenceAccount else { return }
        let revision = session.revision
        let document = BrowsePreferencesStore.shared.activate(account)
        updatePreferencesError(account)
        if preparedContext == scopeIdentity, rootRestoredRevision == revision, lastOptionsAttempt == optionsAttempt,
           !restoreRootAfterRetry, (request.isPlaylist || librariesReady && genresReady) {
            let latest = document.choices(for: preferenceScope)
            if usesInitialQueryIntent {
                viewStyle = latest.viewStyle
                return
            }
            if choices == latest { return }
            var sameQuery = latest
            sameQuery.viewStyle = viewStyle
            if sameQuery == choices {
                // A See all view-only edit updates the ordinary scope's view
                // without resetting its loaded page or saved query predicates.
                viewStyle = latest.viewStyle
                return
            }
            // An explicit edit from another route must validate restored IDs
            // before its changed query can start, just like initial restoration.
        }
        let retainingPage = preparedContext == scopeIdentity && completedLoad?.account == revision && !restoreRootAfterRetry
        cancelRefresh(); preparedContext = nil
        if !retainingPage { completedLoad = nil; page = LibraryPagination(); error = nil }
        lastOptionsAttempt = optionsAttempt
        if rootRestoredRevision != revision || restoreRootAfterRetry {
            rootRestoredRevision = revision; restoreRootAfterRetry = false
            if mode == .library, parent == nil, !initialQueryIntent {
                let changed = selectedLibrary != document.root.libraryID || filter != document.root.category
                selectedLibrary = document.root.libraryID; filter = document.root.category
                if changed { return } // The new context owns its own restoration task.
            }
        }
        let target = scopeIdentity, scope = preferenceScope
        var saved = document.choices(for: scope)
        if usesInitialQueryIntent {
            saved = BrowseChoices(sort: openingSort, direction: openingSort.defaultDirection, viewStyle: saved.viewStyle)
        } else {
            // Category/sort validation needs no network; a nonempty genre is kept
            // until its COMPLETE option set has positively established membership.
            saved = saved.validated(for: scope, genreIDs: saved.genreID.isEmpty ? [] : [saved.genreID])
        }
        apply(saved)
        librariesReady = false; genresReady = false; genres = []
        if request.isPlaylist {
            preparedContext = target; optionsLoading = false; optionsError = nil; return
        }
        if selectedLibrary.isEmpty && genre.isEmpty { preparedContext = target }
        let generation = UUID(); optionsRequestID = generation; optionsLoading = true; optionsError = nil
        defer { if optionsRequestID == generation, scopeIdentity == target { optionsLoading = false } }
        let parameters = request.parameters(start: 0)
        var genreQuery = ["includeItemTypes": parameters["includeItemTypes"] ?? "Movie,Series,Episode"]
        if let parent = parameters["parentId"] { genreQuery["parentId"] = parent }
        let query = genreQuery
        await withTaskGroup(of: OptionResult.self) { group in
            group.addTask {
                do { return .libraries(try await BrowseOptionsReader.libraries { try await api.page($0, query: $1) }) }
                catch { return .libraryError(error.localizedDescription) }
            }
            group.addTask {
                do { return .genres(try await BrowseOptionsReader.genres(query: query) { try await api.page($0, query: $1) }) }
                catch { return .genreError(error.localizedDescription) }
            }
            var failures: [String] = []
            for await result in group {
                guard !Task.isCancelled, session.revision == revision, scopeIdentity == target, optionsRequestID == generation else { group.cancelAll(); return }
                switch result {
                case .libraries(let values):
                    libraries = values; librariesReady = true
                    if !selectedLibrary.isEmpty, !values.contains(where: { $0.id == selectedLibrary }) {
                        selectedLibrary = ""; preparedContext = nil; persistRoot(); group.cancelAll(); return
                    }
                case .genres(let values):
                    genres = values; genresReady = true
                    if !genre.isEmpty, !values.contains(where: { $0.id == genre }) { genre = ""; persistChoices() }
                // Both reads usually fail for the same reason; say it once.
                case .libraryError(let value), .genreError(let value): if !failures.contains(value) { failures.append(value) }
                }
                optionsError = failures.isEmpty ? nil : failures.joined(separator: " ")
                if (selectedLibrary.isEmpty || librariesReady) && (genre.isEmpty || genresReady) { preparedContext = target }
            }
        }
    }

    private func loadParent() async {
        guard let parent, let api = session.api else { return }
        let revision = session.revision, generation = UUID(); parentReadGeneration = generation; parentError = nil
        do {
            let value = try await api.item(parent.id)
            try Task.checkCancellation()
            guard session.revision == revision, parentReadGeneration == generation else { return }
            guard value.id == parent.id else { throw ReelError.invalidResponse }
            parentDetail = value
        } catch is CancellationError { }
        catch { if session.revision == revision, parentReadGeneration == generation { parentError = error.localizedDescription } }
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
    }

    private func refresh() async {
        refreshTask?.cancel()
        let identity = UUID()
        let task = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await load(reset: true, preservingPage: true)
            await loadParent()
        }
        refreshTaskID = identity
        refreshTask = task
        await task.value
        guard refreshTaskID == identity else { return }
        refreshTask = nil
        refreshTaskID = nil
    }

    private func load(reset: Bool, preservingPage: Bool = false) async {
        guard let api = session.api, preparedContext == scopeIdentity else { return }
        guard reset || !loading else { return }
        let requested = request, identity = loadIdentity
        let account = session.revision
        let generation = UUID(); requestID = generation
        if reset && !preservingPage { page = LibraryPagination() }
        guard requested.canLoad else { loading = false; error = nil; return }
        loading = true; error = nil; refreshFailed = false
        defer { if requestID == generation { loading = false } }
        do {
            let result = try await api.page(requested.path, query: requested.parameters(start: reset ? 0 : page.nextIndex))
            try Task.checkCancellation()
            guard requestID == generation, request == requested, session.revision == account else { return }
            if reset {
                var replacement = LibraryPagination()
                replacement.append(result, playlist: requested.isPlaylist)
                page = replacement
            } else {
                page.append(result, playlist: requested.isPlaylist)
            }
            completedLoad = identity
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled, requestID == generation, request == requested, session.revision == account {
                self.error = error.localizedDescription
                refreshFailed = preservingPage && !items.isEmpty
            }
        }
    }
}

private struct LibrarySearch: ViewModifier {
    @Binding var query: String
    let enabled: Bool
    let alwaysVisible: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            if alwaysVisible {
                content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies, series and episodes")
                    .searchPresentationToolbarBehavior(.avoidHidingContent)
            } else {
                content.searchable(text: $query, prompt: "Movies, series and episodes")
            }
        } else { content }
    }
}
