import SwiftUI

/// Home rows in display order. Each row remembers the card that last had focus.
enum TVHomeRow: Hashable { case resume, next, movies, series, episodes }

struct TVHomeFocus: Hashable {
    let row: TVHomeRow
    let id: String
}

struct TVHomeView: View {
    @Environment(TVCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = TVHomeStore()
    @State private var refresh = 0
    /// The focused card's item once focus has settled on it.
    @State private var spotlight: MediaItem?
    @State private var remembered: [TVHomeRow: String] = [:]
    /// While a card has focus the featured actions step aside, so Up from the first row reaches the tab bar.
    /// Kept apart from the focus binding and cleared when Home leaves the screen, so the featured actions
    /// are focusable again when tvOS restores focus after Back.
    @State private var browsing = false
    /// The featured actions' height, which the rows rise over while a card has focus.
    @State private var actionsHeight: CGFloat = 0
    @FocusState private var focus: TVHomeFocus?
    /// Home first draws while its rows load, so tvOS starts focus on the tab bar. When the featured title
    /// arrives, focus moves once to its primary action, so Select resumes or plays straight away.
    @FocusState private var featuredAction: TVFeaturedAction?
    @State private var offeredLaunchFocus = false

    private enum TVFeaturedAction: Hashable { case play, details }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 0) {
                if let featured = store.featured {
                    // While a card has focus the featured actions fade and stop taking focus, the synopsis keeps
                    // two lines, and the rows rise over the space the actions leave, so a focused row keeps its
                    // heading and captions clear of the bottom edge. The actions stay in the view tree.
                    spotlightPanel(spotlight ?? featured)
                        .frame(height: browsing ? 277 : 308, alignment: .bottomLeading)
                        .padding(.horizontal, TVLayout.margin)
                        .padding(.bottom, browsing ? 24 : 0)
                    featuredActions(featured)
                        .padding(.horizontal, TVLayout.margin)
                        .disabled(browsing)
                        .opacity(browsing ? 0 : 1)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actionsHeight = $0 }
                }
                ScrollViewReader { rows in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 34) {
                        if store.featured != nil {
                            if store.partial { partialNotice }
                            row(.resume, "Continue watching", store.resume, wide: true)
                            row(.next, "Up next", store.next, wide: true)
                            row(.movies, "Recently added movies", store.movies)
                            row(.series, "Recently added series", store.series)
                        } else if store.loading {
                            loadingRows
                        } else if let error = store.error {
                            TVFailure(title: "Home couldn’t load.", message: error) { refresh += 1 }
                                .padding(.horizontal, TVLayout.margin).padding(.top, 160)
                        } else {
                            emptyLibrary
                        }
                        episodeRow
                    }
                    .padding(.top, 30).padding(.bottom, 80)
                }
                .onChange(of: focus?.row) { _, row in
                    // After the focus engine's own scroll, pin the focused row to the top of the row area
                    // so earlier rows leave the screen instead of showing captions under the spotlight.
                    guard let row else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(60))
                        if reduceMotion { rows.scrollTo(row, anchor: .top) } else { withAnimation(.tvState) { rows.scrollTo(row, anchor: .top) } }
                    }
                }
                }
                .padding(.top, store.featured != nil && browsing ? -actionsHeight : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(edges: .horizontal)
        .background { TVBackdrop(item: spotlight ?? store.featured) }
        .onChange(of: focus) { _, value in
            if let value { remembered[value.row] = value.id }
            let card = value != nil
            if card != browsing { if reduceMotion { browsing = card } else { withAnimation(.tvState) { browsing = card } } }
        }
        .onDisappear { browsing = false }
        .task(id: focus) {
            guard let focus else { show(nil); return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            show(item(for: focus))
        }
        .onDisappear { store.cancel() }
        .task(id: store.featured?.id) {
            guard let featured = store.featured, !offeredLaunchFocus else { return }
            offeredLaunchFocus = true
            // Only while Home is the visible screen and nothing in it has focus yet.
            guard coordinator.tab == .home, coordinator.path.isEmpty, focus == nil, featuredAction == nil else { return }
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard coordinator.tab == .home, coordinator.path.isEmpty, focus == nil else { return }
            featuredAction = featured.isSeries ? .details : .play
        }
        .task(id: "\(coordinator.session.revision)|\(coordinator.session.libraryRevision)|\(refresh)") {
            if let api = coordinator.session.api { await store.load(api: api) }
        }
    }

    // MARK: Spotlight

    private func spotlightPanel(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TVGenreEyebrow(item: item)
            Text(item.title).font(.system(size: 56, weight: .bold)).tracking(-0.8).lineLimit(2)
                .foregroundStyle(Color.reelText).accessibilityIdentifier("heroTitle")
            if item.Type == "Episode" {
                Text(TVMetadata.caption(item)).font(.system(size: 28, weight: .semibold)).foregroundStyle(Color.reelText).lineLimit(1)
            }
            TVMetadataLine(item: item)
            if let overview = item.Overview, !overview.isEmpty {
                Text(overview).font(.system(size: 25)).foregroundStyle(Color.tvMuted).lineLimit(browsing ? 2 : 3)
                    .frame(maxWidth: 920, alignment: .leading)
            }
        }
        .id(item.id)
        .transition(.opacity)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featuredActions(_ featured: MediaItem) -> some View {
        HStack(spacing: 24) {
            if !featured.isSeries {
                Button { Task { await coordinator.play(featured) } } label: {
                    Label(featured.resumeTicks > 0 ? "Resume" : "Play", systemImage: "play.fill")
                }.focused($featuredAction, equals: .play).accessibilityIdentifier("heroPlay")
            }
            Button { coordinator.detail(featured) } label: { Label("Details", systemImage: "info.circle") }
                .focused($featuredAction, equals: .details).accessibilityIdentifier("heroDetails")
        }
        .font(.system(size: 26, weight: .semibold))
        .padding(.top, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private func item(for focus: TVHomeFocus) -> MediaItem? {
        let items: [MediaItem]
        switch focus.row {
        case .resume: items = store.resume
        case .next: items = store.next
        case .movies: items = store.movies
        case .series: items = store.series
        case .episodes: items = store.episodes
        }
        return items.first { $0.id == focus.id }
    }

    private func show(_ item: MediaItem?) {
        guard item?.id != spotlight?.id else { return }
        if reduceMotion { spotlight = item } else { withAnimation(.tvState) { spotlight = item } }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ row: TVHomeRow, _ title: String, _ items: [MediaItem], wide: Bool = false) -> some View {
        if !items.isEmpty {
            TVShelf(title: title) {
                cards(row, items, wide: wide, stale: store.partial || store.loading)
            }
            // Entering a row returns focus to the card it last had.
            .defaultFocus($focus, TVHomeFocus(row: row, id: remembered[row] ?? items[0].id), priority: .userInitiated)
            .id(row)
        }
    }

    private func cards(_ row: TVHomeRow, _ items: [MediaItem], wide: Bool, stale: Bool = false) -> some View {
        ForEach(items) { item in
            // Continue watching says how much is left of a movie; an episode keeps its number and name.
            TVCard(item: item, wide: wide, caption: row == .resume && item.Type != "Episode" ? TVMetadata.remaining(item) : nil, countStale: stale,
                   width: wide ? TVLayout.landscapeWidth : TVLayout.posterWidth, action: { coordinator.detail(item) },
                   focus: TVFocusTag(binding: $focus, value: TVHomeFocus(row: row, id: item.id)))
        }
    }

    private var partialNotice: some View {
        HStack(spacing: 28) {
            Text("Some rows couldn’t load.").font(.system(size: 24)).foregroundStyle(Color.tvMuted)
            Button("Retry") { refresh += 1 }.accessibilityIdentifier("partialRetry")
        }
        .padding(.horizontal, TVLayout.margin)
        .focusSection()
    }

    private var episodeRow: some View {
        TVShelf(title: "New episodes", identifier: "recentEpisodesShelf") {
            Button("See all") { coordinator.openLibrary(category: "Episodes", sort: .recentlyAdded) }
                .accessibilityIdentifier("seeAllEpisodes")
            Button(store.episodeError == nil ? "Refresh" : "Retry") {
                Task { if let api = coordinator.session.api { await store.retryEpisodes(api: api) } }
            }.disabled(store.episodesLoading).accessibilityIdentifier("refreshEpisodes")
        } content: {
            if store.episodesLoading {
                TVSkeletonRow(wide: true, count: 5)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Opening recent episodes…")
                    .accessibilityIdentifier("episodesLoading")
            } else if let error = store.episodeError {
                Text("Recent episodes couldn’t load. " + error).font(.system(size: 24)).foregroundStyle(Color.tvMuted)
                    .accessibilityIdentifier("episodesError")
            } else if store.episodes.isEmpty {
                Text("No recently added episodes.").font(.system(size: 24)).foregroundStyle(Color.tvMuted)
                    .accessibilityIdentifier("episodesEmpty")
            } else {
                cards(.episodes, store.episodes, wide: true)
            }
        }
        .defaultFocus($focus, TVHomeFocus(row: .episodes, id: remembered[.episodes] ?? store.episodes.first?.id ?? ""), priority: .userInitiated)
        .id(TVHomeRow.episodes)
    }

    // MARK: States

    private var loadingRows: some View {
        VStack(alignment: .leading, spacing: 56) {
            TVSkeletonRow(wide: true, count: 5)
            TVSkeletonRow(wide: false, count: 8)
        }
        .padding(.horizontal, TVLayout.margin).padding(.top, 420)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening your library.")
        .accessibilityIdentifier("homeLoading")
    }

    private var emptyLibrary: some View {
        TVEmpty(title: "Your library is empty.", message: "Movies, series and episodes appear here when they’re added to this Jellyfin library.") {
            Button("Refresh library") { refresh += 1 }
            Button("Manage servers") { coordinator.tab = .settings }
        }
        .padding(.horizontal, TVLayout.margin).padding(.top, 160)
    }
}
