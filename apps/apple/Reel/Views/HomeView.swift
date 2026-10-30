import SwiftUI

struct HomeData: Sendable {
    var resume: [MediaItem] = []
    var next: [MediaItem] = []
    var movies: [MediaItem] = []
    var shows: [MediaItem] = []
    var episodes: [MediaItem] = []
    var isEmpty: Bool { resume.isEmpty && next.isEmpty && movies.isEmpty && shows.isEmpty && episodes.isEmpty }
}

struct HomeView: View {
    @Environment(Session.self) private var session
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.foldCrease) private var foldCrease
    @Environment(\.screenInsets) private var screenInsets
    @ScaledMetric(relativeTo: .subheadline) private var categoryHeight = 44
    @State private var data = HomeData()
    @State private var loading = true
    @State private var error: String?
    @State private var category = "For you"
    @State private var featuredID: String?
    @State private var requestID = UUID()
    @State private var refreshTask: Task<Void, Never>?
    @State private var isVisible = false
    /// The featured band has scrolled up under the navigation bar.
    @State private var condensed = false
    private var featured: [MediaItem] {
        let items = category == "Movies" ? data.movies : category == "Series" ? data.shows : Array(data.movies.prefix(4)) + Array(data.shows.prefix(2))
        return Array(items.prefix(8))
    }
    private var featuredItem: MediaItem? {
        featured.first(where: { $0.id == featuredID }) ?? featured.first ?? data.resume.first ?? data.episodes.first
    }

    var body: some View {
        GeometryReader { geometry in
            let spread = FoldSpread(crease: foldCrease, in: geometry.frame(in: .global))
            let wide = spread != nil || AdaptiveLayout.homeBand(horizontalSizeClass, accessibility: dynamicTypeSize.isAccessibilitySize, width: geometry.size.width)
            // On a spread the margins follow the page, not the whole screen.
            let margin = AdaptiveLayout.margin(regular: wide, width: spread?.leadingWidth ?? geometry.size.width)
            let band = geometry.safeAreaInsets.top + bandHeight(geometry.size, wide: wide)
            // The page spans the screen's side insets, such as the strip beside a foldable's screen,
            // so art and rows run to the edge; words and controls are inset by the larger of the
            // page's own insets and the screen's.
            let lead = max(geometry.safeAreaInsets.leading, screenInsets.leading)
            let trail = max(geometry.safeAreaInsets.trailing, screenInsets.trailing)
            let full = geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
            Group {
                if loading && data.isEmpty { HomeSkeleton(wide: wide, margin: margin, top: geometry.safeAreaInsets.top, height: band) }
                else if let error, data.isEmpty {
                    ScrollView {
                        FailureView(message: error) { refresh() }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: max(240, geometry.size.height * 0.6))
                    }.accessibilityIdentifier("homeErrorScroll")
                }
                else if data.isEmpty {
                    ScrollView {
                        ContentUnavailableView("A little quiet in here", systemImage: "film.stack", description: Text("Movies and series will appear when they’re added to your Jellyfin libraries."))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: max(240, geometry.size.height * 0.6))
                    }.accessibilityIdentifier("homeEmptyScroll")
                }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: wide ? 32 : 24) {
                            featuredBand(geometry, spread: spread, wide: wide, margin: margin, height: band, lead: lead, trail: trail, full: full)
                            if session.api?.isSimulatorPreview == true {
                                Label("History and library changes are off for this server in this build.", systemImage: "eye.slash")
                                    .font(.caption).foregroundStyle(Color.reelMuted)
                                    .padding(.leading, margin + lead).padding(.trailing, margin + trail)
                            }
                            if let error {
                                HStack(spacing: 12) {
                                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.reelMuted)
                                    Spacer()
                                    Button("Retry") { refresh() }.font(.subheadline.weight(.semibold)).frame(minHeight: 44).disabled(loading).accessibilityIdentifier("homeRetry")
                                }.padding(.leading, margin + lead).padding(.trailing, margin + trail)
                            }
                            // Rows scroll under a foldable's tab strip; each one's last card can still
                            // scroll clear of it.
                            rows(width: geometry.size.width, margin: margin, wide: wide, lead: lead, trail: trail)
                                .frame(width: full, alignment: .leading).clipped()
                        }
                        .padding(.bottom, 36)
                    }
                    // The band runs under the navigation bar, which fills in once it scrolls away,
                    // and under the side strips.
                    .ignoresSafeArea(edges: [.top, .horizontal])
                    .scrollEdgeEffectHidden(!condensed, for: .top)
                    .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > band - 96 } action: { _, value in condensed = value }
                    .refreshable { await reload() }
                    .accessibilityIdentifier("homeScroll")
                }
            }
        }
        .reelCanvas()
        .toolbar {
            // A foldable's outer screen can turn this bar vertical, too narrow for the name.
            ToolbarItem(placement: .principal) {
                if horizontalSizeClass != .regular { ViewThatFits(in: .horizontal) { ReelMark(); ReelMark(markOnly: true) } }
            }
            // Pull to refresh does the same; this keeps a visible way to reload and shows progress,
            // grouped with the server switcher so the band carries only the filters.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { refresh() } label: {
                    Group {
                        if loading { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }.frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(loading || session.account == nil)
                    .accessibilityIdentifier("homeRefresh").accessibilityLabel("Refresh Home")
                    .accessibilityValue(loading ? "Loading" : "Ready")
                    .accessibilityHint("Reload your recommendations and recently added titles.")
                ServerSwitcher(compact: true).buttonStyle(.plain)
            }
        }
        .toolbarBackground(Color.reelBackground, for: .navigationBar)
        .toolbarBackgroundVisibility(condensed || (data.isEmpty && !loading) ? .visible : .hidden, for: .navigationBar)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: condensed)
        .navigationBarTitleDisplayMode(.inline)
        // A plain push: a zoom transition's swipe-down dismissal would take over
        // the pull-to-refresh and stretching artwork on Details.
        .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
        .onAppear { isVisible = true; refresh() }
        .onDisappear { isVisible = false; cancelRefresh() }
        .onChange(of: session.libraryRevision) { _, _ in if isVisible { refresh() } }
        .onChange(of: session.revision) { _, _ in
            cancelRefresh(); data = HomeData(); error = nil
            if isVisible { refresh() }
        }
        .onChange(of: playback.activeItem == nil) { _, stopped in if stopped && isVisible { refresh() } }
    }

    /// Height of the featured band below the top safe area.
    private func bandHeight(_ size: CGSize, wide: Bool) -> CGFloat {
        if wide { return min(560, max(340, size.width * 0.42), size.height * 0.64) }
        // A phone shows the band and the first row's heading; a short outer screen keeps a row in view.
        return min(max(400, size.width * 1.1), size.height * 0.64)
    }

    // MARK: Featured band

    /// The featured title as a full-bleed band that runs under the navigation bar, with the category
    /// pills at its top and the selector under its buttons. On an open foldable the artwork spans
    /// both pages while every word and control stays on the left one.
    private func featuredBand(_ geometry: GeometryProxy, spread: FoldSpread?, wide: Bool, margin: CGFloat, height: CGFloat, lead: CGFloat, trail: CGFloat, full: CGFloat) -> some View {
        let top = geometry.safeAreaInsets.top
        let page = spread?.leadingWidth ?? geometry.size.width
        let item = featuredItem
        return VStack(alignment: .leading, spacing: 0) {
            if let item {
                HeroDetails(item: item, wide: wide, roomy: spread == nil && geometry.size.width >= AdaptiveLayout.roomyWidth)
                    .frame(maxWidth: wide ? min(560, page - margin * 2) : .infinity, alignment: .leading)
                    .padding(.leading, margin + lead).padding(.trailing, margin + trail)
                if featured.count > 1 {
                    // Each segment's 44 point target is wider than its mark; this lines the first
                    // mark up with the text above it.
                    featureSelector(maxWidth: page - margin * 2).padding(.leading, margin - 6 + lead).padding(.top, wide ? 14 : 8)
                }
            }
        }
        .padding(.top, top + 8 + categoryHeight + (wide ? 40 : 24))
        // The selector's 44 point targets already leave room under its marks.
        .padding(.bottom, featured.count > 1 ? 0 : 12)
        .frame(width: full, alignment: .leading)
        .frame(minHeight: item == nil ? 0 : height, alignment: .bottom)
        .overlay(alignment: .topLeading) {
            categories(margin: margin + lead).frame(width: page + lead, alignment: .leading).padding(.top, top + 8)
        }
        .background {
            if let item {
                FeaturedArtwork(item: item, wide: wide, tallText: dynamicTypeSize.isAccessibilitySize).id(item.id).transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: item?.id)
    }

    private func categories(margin: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(["For you", "Movies", "Series"], id: \.self) { name in
                    let selected = category == name
                    Button { category = name; featuredID = nil } label: {
                        Text(name).font(.subheadline.weight(.semibold))
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 16)
                            .frame(minWidth: 44, minHeight: categoryHeight)
                            // Selected is a lighter neutral fill, as on the other clients; the
                            // white button stays reserved for the band's main action.
                            .foregroundStyle(Color.reelText)
                            .background {
                                Capsule().fill(.ultraThinMaterial)
                                    .overlay { if selected { Capsule().fill(Color.reelText.opacity(0.24)) } }
                            }
                            .contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("home-\(name)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .scrollIndicators(.hidden)
    }

    /// A segmented track, one segment per featured title, that picks what the band shows.
    private func featureSelector(maxWidth: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(featured) { item in
                    let selected = (featuredID ?? featured.first?.id) == item.id
                    Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { featuredID = item.id } } label: {
                        Capsule().fill(selected ? Color.reelText : Color.reelText.opacity(0.32))
                            .frame(width: 32, height: 3)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Feature \(item.Name)")
                        .accessibilityIdentifier("feature-\(item.id)").accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(width: min(CGFloat(featured.count) * 44, max(44, maxWidth)), height: 44)
        .accessibilityIdentifier("homeFeatureSelector")
    }

    // MARK: Rows

    /// `lead` and `trail` are the side insets from the screen's edges; the rows themselves span them.
    @ViewBuilder private func rows(width: CGFloat, margin: CGFloat, wide: Bool, lead: CGFloat, trail: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: wide ? 32 : 24) {
            if !data.resume.isEmpty {
                shelf(title: "Continue watching", margin: margin, lead: lead, trail: trail) {
                    ForEach(data.resume) { item in
                        Button { playback.present(item) } label: { ResumeCard(item: item, width: landscapeWidth(width, margin: margin, wide: wide)) }
                            .buttonStyle(.plain).accessibilityIdentifier("resume-\(item.id)")
                    }
                }
            }
            if category != "Movies" { row("Up next", items: data.next, key: "next", width: width, margin: margin, wide: wide, lead: lead, trail: trail) }
            if category != "Series" { row("Recently added movies", items: data.movies, key: "movies", filter: "Movies", width: width, margin: margin, wide: wide, lead: lead, trail: trail) }
            if category != "Movies" { row("Recently added series", items: data.shows, key: "shows", filter: "Series", width: width, margin: margin, wide: wide, lead: lead, trail: trail) }
            if category != "Movies", loading && data.episodes.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("New episodes").font(.title3.weight(.bold)).tracking(-0.3)
                        .padding(.leading, margin + lead).padding(.trailing, margin + trail)
                    SkeletonRow(count: 3, width: landscapeWidth(width, margin: margin, wide: wide), aspect: 9 / 16)
                        .padding(.leading, margin + lead).padding(.trailing, margin + trail)
                }.accessibilityElement().accessibilityLabel("Loading new episodes")
            }
            if category != "Movies" { row("New episodes", items: data.episodes, key: "episodes", filter: "Episodes", width: width, margin: margin, wide: wide, lead: lead, trail: trail) }
        }
    }

    private func posterWidth(_ width: CGFloat, margin: CGFloat, wide: Bool) -> CGFloat {
        // At least 3.3 posters across a narrow regular window, 168 points once there is room.
        if wide { return min(168, max(140, (width - margin - 14 * 3) / 3.3)) }
        // About 2.3 posters across, so the row reads as scrollable.
        return max(104, ((width - margin) - 14 * 2) / 2.3)
    }

    private func landscapeWidth(_ width: CGFloat, margin: CGFloat, wide: Bool) -> CGFloat {
        if wide { return min(300, max(250, (width - margin - 14) / 2.15)) }
        return max(200, ((width - margin) - 14) / 1.45)
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        requestID = UUID()
        loading = false
    }

    private func refresh() {
        cancelRefresh()
        guard isVisible, let api = session.api else { return }
        let generation = UUID(); requestID = generation
        let account = session.revision
        loading = true; error = nil
        refreshTask = Task { @MainActor in
            defer {
                if requestID == generation { loading = false; refreshTask = nil }
            }
            await load(api: api, generation: generation, account: account)
        }
    }

    /// Pull to refresh: holds the spinner until the reload settles.
    private func reload() async {
        refresh()
        await refreshTask?.value
    }

    private func load(api: JellyfinAPI, generation: UUID, account: UUID) async {
        guard !Task.isCancelled, isVisible, requestID == generation, session.revision == account else { return }
        await playback.flushReports()
        guard !Task.isCancelled, isVisible, requestID == generation, session.revision == account else { return }
        async let resume: Result<[MediaItem], Error> = {
            do { return .success(try await api.page("UserItems/Resume", query: ["limit": "12", "mediaTypes": "Video"]).Items) }
            catch { return .failure(error) }
        }()
        async let next: Result<[MediaItem], Error> = {
            do { return .success(try await api.page("Shows/NextUp", query: ["limit": "12"]).Items) }
            catch { return .failure(error) }
        }()
        async let movies: Result<[MediaItem], Error> = {
            do { return .success(try await api.latest(type: "Movie")) }
            catch { return .failure(error) }
        }()
        async let shows: Result<[MediaItem], Error> = {
            do { return .success(try await api.latest(type: "Series")) }
            catch { return .failure(error) }
        }()
        async let episodes = recentEpisodes(api)
        let mainResults = await (resume, next, movies, shows)
        guard !Task.isCancelled, isVisible, requestID == generation, session.revision == account else { return }
        var result = data
        var mainFailure: Error?
        switch mainResults.0 { case .success(let items): result.resume = items; case .failure(let failure): mainFailure = failure }
        switch mainResults.1 { case .success(let items): result.next = items; case .failure(let failure): mainFailure = mainFailure ?? failure }
        switch mainResults.2 { case .success(let items): result.movies = items; case .failure(let failure): mainFailure = mainFailure ?? failure }
        switch mainResults.3 { case .success(let items): result.shows = items; case .failure(let failure): mainFailure = mainFailure ?? failure }
        data = result
        let mainError = mainFailure.map { "Some Home rows couldn’t refresh. " + $0.localizedDescription }
        error = mainError
        let episodeResult = await episodes
        guard !Task.isCancelled, isVisible, requestID == generation, session.revision == account else { return }
        switch episodeResult {
        case .success(let items): data.episodes = items
        case .failure(let failure): error = [mainError, "New episodes couldn’t load. " + failure.localizedDescription].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func recentEpisodes(_ api: JellyfinAPI) async -> Result<[MediaItem], Error> {
        do { return .success(try await api.page("Items", query: LibraryQuery(category: "Episodes", sort: .recentlyAdded).parameters(start: 0, limit: 18)).Items) }
        catch { return .failure(error) }
    }

    private func shelf<Content: View>(title: String, margin: CGFloat, lead: CGFloat, trail: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.bold)).tracking(-0.3)
                .padding(.leading, margin + lead).padding(.trailing, margin + trail)
            ScrollView(.horizontal) { LazyHStack(alignment: .top, spacing: 14, content: content).scrollTargetLayout() }
                .contentMargins(.leading, margin + lead, for: .scrollContent)
                .contentMargins(.trailing, margin + trail, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
        }
    }

    @ViewBuilder private func row(_ title: String, items: [MediaItem], key: String, filter: String? = nil, width: CGFloat, margin: CGFloat, wide: Bool, lead: CGFloat, trail: CGFloat) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title).font(.title3.weight(.bold)).tracking(-0.3)
                    Spacer()
                    if let filter {
                        NavigationLink { LibraryView(mode: .library, initialFilter: filter, initialSort: .recentlyAdded, initialQueryIntent: true) } label: {
                            HStack(spacing: 4) { Text("See all"); Image(systemName: "chevron.right").font(.caption.weight(.bold)) }
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelMuted).frame(minHeight: 44)
                        }.accessibilityIdentifier("recent-\(filter)-seeAll").accessibilityLabel("See all \(title.lowercased())")
                    }
                }.padding(.leading, margin + lead).padding(.trailing, margin + trail)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                if item.Type == "Episode" { EpisodeCard(item: item, width: landscapeWidth(width, margin: margin, wide: wide)) }
                                else { PosterCard(item: item, width: posterWidth(width, margin: margin, wide: wide)) }
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("item-\(item.id)")
                        }
                    }.scrollTargetLayout()
                }
                .contentMargins(.leading, margin + lead, for: .scrollContent)
                .contentMargins(.trailing, margin + trail, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
            }
        }
    }
}

/// The featured title's words and actions, set over the band's artwork.
private struct HeroDetails: View {
    let item: MediaItem
    let wide: Bool
    /// A wide iPad band, which takes the largest title.
    let roomy: Bool
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var roomyTitleSize = 42
    @ScaledMetric(relativeTo: .largeTitle) private var wideTitleSize = 34
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 30

    /// The first genre, as on the web client; episodes carry their series' genres, so they show none.
    private var genre: String? {
        guard item.Type != "Episode" else { return nil }
        return item.Genres?.first { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let genre {
                Text(genre).font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelText.opacity(0.78))
                    .accessibilityIdentifier("homeHeroGenre")
            }
            Text(item.Name).font(.system(size: roomy ? roomyTitleSize : wide ? wideTitleSize : titleSize, weight: .bold))
                .tracking(-0.8).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("homeHeroTitle")
            MetadataLine(item: item, foreground: Color.reelText.opacity(0.78))
            if wide, let overview = item.Overview, !overview.isEmpty {
                Text(overview).font(.subheadline).lineSpacing(3).lineLimit(2).foregroundStyle(Color.reelText.opacity(0.78))
            }
            (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))) {
                if !item.isSeries {
                    Button { playback.present(item) } label: {
                        Label(item.resumeTicks > 0 ? "Resume" : "Play", systemImage: "play.fill").frame(maxWidth: wide ? nil : .infinity)
                    }.buttonStyle(PrimaryButton()).accessibilityIdentifier("heroPlay")
                }
                // A series has no Play here, so Details becomes the primary action.
                if item.isSeries {
                    NavigationLink(value: item) {
                        Label("Details", systemImage: "info.circle").frame(maxWidth: wide ? nil : .infinity)
                    }.buttonStyle(PrimaryButton()).accessibilityIdentifier("heroDetails")
                } else {
                    NavigationLink(value: item) {
                        Label("Details", systemImage: "info.circle").frame(maxWidth: wide ? nil : .infinity)
                    }.buttonStyle(GlassDetailsButton()).accessibilityIdentifier("heroDetails")
                }
            }.padding(.top, 8)
        }
        .foregroundStyle(Color.reelText)
    }
}

/// Artwork behind the featured band. It darkens under the bar and behind the text, and fades into
/// the canvas at its foot, so the band has no edge.
private struct FeaturedArtwork: View {
    let item: MediaItem
    let wide: Bool
    /// At accessibility text sizes the title block climbs well up the band, so the scrim starts
    /// higher to keep it legible over bright artwork.
    var tallText = false

    var body: some View {
        Artwork(item: item, backdrop: true, width: wide ? 2000 : 1200)
            .overlay {
                LinearGradient(stops: [.init(color: Color.reelBackground.opacity(0.55), location: 0), .init(color: .clear, location: 0.3)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay {
                if wide {
                    LinearGradient(stops: [.init(color: Color.reelBackground.opacity(0.78), location: 0), .init(color: Color.reelBackground.opacity(0.3), location: 0.45),
                                           .init(color: .clear, location: 0.75)],
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: tallText ? 0.12 : wide ? 0.42 : 0.3),
                                       .init(color: Color.reelBackground.opacity(0.74), location: tallText ? 0.42 : wide ? 0.74 : 0.64),
                                       .init(color: Color.reelBackground, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
    }
}

/// Secondary action over artwork: translucent fill with a hairline edge.
private struct GlassDetailsButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .padding(.horizontal, 20).padding(.vertical, 13).frame(minHeight: 50)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ReelRadius.control))
            .overlay(RoundedRectangle(cornerRadius: ReelRadius.control).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .foregroundStyle(Color.reelText)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct ContinueRow: View {
    let item: MediaItem
    var body: some View {
        HStack(spacing: 12) {
            Artwork(item: item, backdrop: true, width: 300).frame(width: 88, height: 58).clipShape(RoundedRectangle(cornerRadius: ReelRadius.artwork))
                .overlay { Image(systemName: "play.circle.fill").foregroundStyle(.white).shadow(radius: 3) }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(Color.reelText)
                Text(item.subtitle).font(.caption).lineLimit(1).foregroundStyle(Color.reelMuted)
                if item.progress > 0 { WatchProgressBar(value: item.progress) }
            }
        }.contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

/// The first frame of Home, shaped like the band and the first row it becomes.
struct HomeSkeleton: View {
    var wide = false
    var margin: CGFloat = 20
    var top: CGFloat = 0
    var height: CGFloat = 460
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.reelSurfaceRaised).frame(width: wide ? 320 : 220, height: 30)
                    RoundedRectangle(cornerRadius: 4).fill(Color.reelSurfaceRaised).frame(width: 160, height: 14)
                    HStack(spacing: 10) {
                        ForEach(0..<2, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: ReelRadius.control).fill(Color.reelSurfaceRaised).frame(maxWidth: wide ? 140 : .infinity).frame(height: 50)
                        }
                    }.frame(maxWidth: wide ? 300 : .infinity, alignment: .leading).padding(.top, 8)
                }
                .padding(.horizontal, margin).padding(.bottom, wide ? 28 : 12)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 8) { ForEach([88, 76, 72], id: \.self) { Capsule().fill(Color.reelSurfaceRaised).frame(width: CGFloat($0), height: 44) } }
                        .padding(.horizontal, margin).padding(.top, top + 8)
                }
                .background(LinearGradient(colors: [Color.reelSurface, Color.reelBackground], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 4).fill(Color.reelSurface).frame(width: 160, height: 18).padding(.horizontal, margin)
                SkeletonRow(count: 5, width: wide ? 168 : 140).padding(.horizontal, margin)
            }
        }
        .ignoresSafeArea(edges: .top)
        .scrollDisabled(true).accessibilityLabel("Loading library")
    }
}
