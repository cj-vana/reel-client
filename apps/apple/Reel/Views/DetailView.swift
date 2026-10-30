import SwiftUI

struct DetailView: View {
    let item: MediaItem
    @Environment(Session.self) private var session
    @Environment(PlaybackController.self) private var playback
    @Environment(Downloads.self) private var downloads
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.foldCrease) private var foldCrease
    @Environment(\.screenInsets) private var screenInsets
    /// The screen is laid out as two pages around a foldable's crease.
    @State private var onSpread = false
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 32
    @ScaledMetric(relativeTo: .largeTitle) private var wideTitleSize = 42
    @ScaledMetric(relativeTo: .subheadline) private var castCellWidth: CGFloat = 100
    @State private var showingRemote = false
    @State private var detail: MediaItem?
    @State private var seasons: [MediaItem] = []
    @State private var episodes: [MediaItem] = []
    @State private var season = ""
    @State private var error: String?
    @State private var episodeError: String?
    @State private var loading = true
    @State private var loadingEpisodes = false
    @State private var loadedSeason = ""
    @State private var savingFavorite = false
    @State private var audio: Int?
    @State private var subtitle: Int?
    @State private var related: [MediaItem] = []
    @State private var sourceID: String?
    @State private var pull: CGFloat = 0
    @State private var condensed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var overviewExpanded = false
    @State private var overviewFullHeight: CGFloat = 0
    @State private var overviewShownHeight: CGFloat = 0
    private var selectedSource: MediaSource? { current.MediaSources?.first { $0.Id == sourceID } ?? current.MediaSources?.first }
    @State private var readGeneration = UUID()
    @State private var episodeReadGeneration = UUID()
    /// The reader's place, kept across a layout change: opening or closing a foldable swaps the
    /// header and turns the episode list into a grid, so the old scroll offset points somewhere
    /// else. Visibility is recorded per layout, and when scrolling stops the first visible
    /// section or episode becomes the place to return to.
    @State private var visibleAnchors: Set<ReadingAnchor> = []
    @State private var readingAnchor: String?
    private struct ReadingAnchor: Hashable { let regular: Bool; let id: String }
    private var current: MediaItem { detail ?? item }
    private var featuredEpisode: MediaItem? {
        guard !loadingEpisodes, episodeError == nil, loadedSeason == season else { return nil }
        return episodes.first { $0.resumeTicks > 0 && $0.UserData?.Played != true }
            ?? episodes.first { $0.UserData?.Played != true }
            ?? episodes.first
    }

    var body: some View {
        GeometryReader { geometry in
            let spread = FoldSpread(crease: foldCrease, in: geometry.frame(in: .global))
            Group {
                if let spread { spreadLayout(geometry, spread: spread) } else { singleLayout(geometry) }
            }
            .onChange(of: spread != nil, initial: true) { _, value in onSpread = value }
        }
        .reelCanvas()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The bar spans both pages of a spread, so its centered title would sit on the crease.
            ToolbarItem(placement: .principal) {
                Text(current.Name).font(.headline).lineLimit(1).opacity(condensed && !onSpread ? 1 : 0)
                    .accessibilityHidden(!condensed || onSpread)
            }
        }
        .toolbarBackground(Color.reelBackground, for: .navigationBar)
        .toolbarBackgroundVisibility(condensed ? .visible : .hidden, for: .navigationBar)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: condensed)
        .sheet(isPresented: $showingRemote) { NavigationStack { RemoteSessionsView(selectedItem: current) } }
        .onChange(of: sourceID) { _, _ in audio = nil; subtitle = nil }
        .task(id: session.libraryRevision) { await load() }
        .task(id: EpisodeLoadIdentity(season: season, revision: session.libraryRevision)) { if !season.isEmpty { await loadEpisodes() } }
        .onChange(of: playback.activeItem == nil) { _, closed in
            if closed {
                Task {
                    await playback.flushReports()
                    await load()
                    if current.isSeries, !season.isEmpty { await loadEpisodes() }
                }
            }
        }
    }

    // MARK: Layouts

    /// iPhone, iPad, and a foldable without a usable crease: one scrolling column.
    private func singleLayout(_ geometry: GeometryProxy) -> some View {
        let regular = AdaptiveLayout.detailsSideBySide(horizontalSizeClass, accessibility: dynamicTypeSize.isAccessibilitySize, width: geometry.size.width)
        let margin = AdaptiveLayout.margin(regular: regular, width: geometry.size.width)
        // The page spans the screen's side insets, such as the strip beside a foldable's screen, so
        // the backdrop and rows reach the edge; words keep clear of the strip.
        let lead = max(geometry.safeAreaInsets.leading, screenInsets.leading)
        let trail = max(geometry.safeAreaInsets.trailing, screenInsets.trailing)
        let full = geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
        return ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: regular ? 40 : 32) {
                    Group {
                        if regular { regularHeader(geometry, margin: margin, lead: lead, trail: trail, full: full) }
                        else { compactHeader(geometry, margin: margin, lead: lead, trail: trail, full: full) }
                    }.readingAnchor("header") { noteAnchor("header", visible: $0, regular: regular) }
                    if current.isSeries { episodeSection(regular: regular).padding(.leading, margin + lead).padding(.trailing, margin + trail) }
                    castSection(margin: margin, regular: regular, lead: lead, trail: trail)
                    relatedSection(margin: margin, regular: regular, lead: lead, trail: trail)
                    errorSection(margin: margin, lead: lead, trail: trail)
                }.frame(width: full, alignment: .leading).padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: [.top, .horizontal])
            // The backdrop runs under the bar; the bar's own edge appears once the title condenses.
            .scrollEdgeEffectHidden(!condensed, for: .top)
            .onScrollGeometryChange(for: CGFloat.self) { max(0, -($0.contentOffset.y + $0.contentInsets.top)) } action: { _, value in pull = value }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > (regular ? geometry.size.height * 0.22 : geometry.size.width * 0.62) } action: { _, value in condensed = value }
            .onScrollPhaseChange { _, phase in
                if phase == .idle { readingAnchor = anchorOrder.first { visibleAnchors.contains(ReadingAnchor(regular: regular, id: $0)) } }
            }
            .onChange(of: regular) { _, _ in returnToReadingAnchor(reader) }
            .accessibilityIdentifier("detailScroll").refreshable { await load() }
        }
    }

    /// An open foldable: two pages split at the crease. The left page holds the title and its
    /// actions, and a series' overview; the right page scrolls on its own with the episodes, or a
    /// movie's overview and options, then cast and related titles. Only the backdrop crosses.
    private func spreadLayout(_ geometry: GeometryProxy, spread: FoldSpread) -> some View {
        let top = geometry.safeAreaInsets.top
        let margin = AdaptiveLayout.margin(regular: true, width: spread.leadingWidth)
        let trail = max(geometry.safeAreaInsets.trailing, screenInsets.trailing)
        return ZStack(alignment: .topLeading) {
            spreadBackdrop(page: spread.trailingStart / max(1, geometry.size.width + geometry.safeAreaInsets.trailing))
                .frame(width: geometry.size.width + geometry.safeAreaInsets.trailing, height: top + geometry.size.height * 0.62)
                .scaleEffect(1 + pull / 600, anchor: .bottom)
                .ignoresSafeArea(edges: [.top, .trailing])
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    information(regular: false, titleSize: titleSize, notes: current.isSeries)
                        .padding(.horizontal, margin)
                        .padding(.top, top + max(120, geometry.size.height * 0.3))
                        .padding(.bottom, 32)
                        // A short page, such as a movie's without its overview, settles at the foot
                        // of the artwork instead of leaving an empty band under the actions.
                        .frame(minHeight: top + geometry.size.height, alignment: .bottomLeading)
                }
                .frame(width: spread.leadingWidth)
                .scrollEdgeEffectHidden(!condensed, for: .top)
                .onScrollGeometryChange(for: CGFloat.self) { max(0, -($0.contentOffset.y + $0.contentInsets.top)) } action: { _, value in pull = value }
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > geometry.size.height * 0.24 } action: { _, value in condensed = value }
                .accessibilityIdentifier("detailScroll").refreshable { await load() }
                Color.clear.frame(width: spread.crease.width)
                // The right page runs under the strip that holds the status and tab bars; its
                // words stop short of the strip and its rows scroll beneath it.
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        if current.isSeries { episodeSection(regular: false).padding(.leading, margin).padding(.trailing, margin + trail) }
                        else {
                            VStack(alignment: .leading, spacing: 18) {
                                overview
                                optionChips
                            }.padding(.leading, margin).padding(.trailing, margin + trail)
                        }
                        castSection(margin: margin, regular: false, trail: trail)
                        relatedSection(margin: margin, regular: false, trail: trail)
                        errorSection(margin: margin, trail: trail)
                    }
                    .padding(.top, top + 20).padding(.bottom, 40)
                }
                .frame(maxWidth: .infinity)
                .scrollEdgeEffectHidden(true, for: .top)
                .accessibilityIdentifier("detailPage")
            }
            .ignoresSafeArea(edges: [.top, .trailing])
        }
    }

    /// The backdrop of a spread: clear on the left page, dimmed behind the right page's list, and
    /// faded into the canvas at its foot. `page` is where the right page starts, as a fraction.
    private func spreadBackdrop(page: CGFloat) -> some View {
        Artwork(item: current, backdrop: true, width: 2000)
            .overlay {
                LinearGradient(stops: [.init(color: Color.reelBackground.opacity(0.5), location: 0), .init(color: .clear, location: 0.24)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: max(0, page - 0.12)),
                                       .init(color: Color.reelBackground.opacity(0.86), location: min(1, page + 0.06)),
                                       .init(color: Color.reelBackground.opacity(0.9), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: Color.reelBackground.opacity(0.72), location: 0.62),
                                       .init(color: Color.reelBackground, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipped()
    }

    @ViewBuilder private func errorSection(margin: CGFloat, lead: CGFloat = 0, trail: CGFloat = 0) -> some View {
        if let error {
            VStack(alignment: .leading, spacing: 12) {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.reelMuted)
                Button("Retry details") { Task { await load() } }.buttonStyle(QuietButton())
            }.padding(.leading, margin + lead).padding(.trailing, margin + trail)
        }
    }

    // MARK: Reading place

    /// Sections and episodes in reading order; the first one on screen is the reader's place.
    private var anchorOrder: [String] {
        ["header"] + (current.isSeries ? ["episodes"] + episodes.map(\.id) : []) + ["cast", "related"]
    }

    private func noteAnchor(_ id: String, visible: Bool, regular: Bool) {
        let anchor = ReadingAnchor(regular: regular, id: id)
        if visible { visibleAnchors.insert(anchor) } else { visibleAnchors.remove(anchor) }
    }

    /// Scrolls the new layout to where the reader was in the old one, once it has laid out.
    private func returnToReadingAnchor(_ reader: ScrollViewProxy) {
        guard let anchor = readingAnchor, anchor != "header" else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            // A little below the top, clear of the navigation bar.
            reader.scrollTo(anchor, anchor: UnitPoint(x: 0.5, y: 0.12))
        }
    }

    // MARK: Headers

    /// iPhone: a backdrop that stretches when pulled down, with the title over its lower edge.
    private func compactHeader(_ geometry: GeometryProxy, margin: CGFloat, lead: CGFloat, trail: CGFloat, full: CGFloat) -> some View {
        let top = geometry.safeAreaInsets.top
        let visual = min(geometry.size.width * 0.66, max(200, geometry.size.height * 0.5))
        return VStack(alignment: .leading, spacing: 0) {
            Artwork(item: current, backdrop: true, width: 1400)
                .frame(width: full, height: top + visual)
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.3),
                                           .init(color: Color.reelBackground.opacity(0.55), location: 0.65), .init(color: Color.reelBackground, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .clipped()
                .scaleEffect(1 + pull / max(1, top + visual), anchor: .bottom)
            information(regular: false, titleSize: titleSize)
                .padding(.leading, margin + lead).padding(.trailing, margin + trail).padding(.top, -72)
        }
    }

    /// iPad and an open foldable: poster and information side by side over a full-bleed backdrop.
    /// Between about 570 and 760 points the poster, gap and title shrink so the
    /// information column keeps room for Play and its action tiles.
    private func regularHeader(_ geometry: GeometryProxy, margin: CGFloat, lead: CGFloat, trail: CGFloat, full: CGFloat) -> some View {
        let roomy = geometry.size.width >= AdaptiveLayout.roomyWidth
        let posterWidth = min(260, max(AdaptiveLayout.Details.posterMinimum, geometry.size.width * 0.24))
        return HStack(alignment: .top, spacing: roomy ? 36 : AdaptiveLayout.Details.spacing) {
            Artwork(item: current, width: 600)
                .frame(width: posterWidth, height: posterWidth * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: ReelRadius.artwork))
                .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                .accessibilityHidden(true)
            information(regular: true, titleSize: roomy ? wideTitleSize : titleSize).frame(maxWidth: 680, alignment: .leading)
        }
        .padding(.leading, margin + lead).padding(.trailing, margin + trail)
        .padding(.top, geometry.safeAreaInsets.top + max(48, geometry.size.height * 0.16))
        .padding(.bottom, 8)
        .frame(width: full, alignment: .leading)
        .background(alignment: .top) {
            // Text sits over most of this image, so it is dimmed throughout,
            // darker on the reading side and fading into the canvas below.
            Artwork(item: current, backdrop: true, width: 2000)
                .overlay {
                    LinearGradient(stops: [.init(color: Color.reelBackground.opacity(0.88), location: 0), .init(color: Color.reelBackground.opacity(0.68), location: 0.6),
                                           .init(color: Color.reelBackground.opacity(0.42), location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.3), location: 0), .init(color: .clear, location: 0.22),
                                           .init(color: .clear, location: 0.55), .init(color: Color.reelBackground, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .clipped()
                .scaleEffect(1 + pull / 600, anchor: .bottom)
        }
    }

    /// `notes` adds the overview and the playback options; a movie's spread shows them on its right page.
    private func information(regular: Bool, titleSize: CGFloat, notes: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: regular ? 20 : 18) {
            VStack(alignment: .leading, spacing: 10) {
                if current.Type == "Episode" {
                    Text([current.SeriesName, current.episodeNumberText.isEmpty ? nil : current.episodeNumberText].compactMap { $0 }.joined(separator: "  "))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelMuted)
                } else if let genre = current.Genres?.first(where: { !$0.isEmpty }) {
                    Eyebrow(text: genre).accessibilityIdentifier("detailGenre")
                }
                Text(current.Name).font(.system(size: titleSize, weight: .bold)).tracking(-0.9)
                    .foregroundStyle(Color.reelText)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("detailTitle")
                MetadataLine(item: current, source: current.isSeries ? nil : selectedSource)
                UnwatchedCountBadge(item: current)
                if !current.isSeries, current.progress > 0, current.UserData?.Played != true {
                    HStack(spacing: 10) {
                        WatchProgressBar(value: current.progress).frame(maxWidth: 160)
                        if let remaining = current.remainingText { Text(remaining).font(.footnote.weight(.medium)).foregroundStyle(Color.reelMuted) }
                    }.padding(.top, 2)
                }
            }
            actions(regular: regular)
            if notes {
                overview
                optionChips
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func actions(regular: Bool) -> some View {
        WatchedStatusButton(item: current, style: .tile) { watched in
            if regular {
                // One row beside the poster; a narrower column (portrait, an open
                // foldable, split view) puts the tiles on a second row that shares
                // the column's width.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        primaryAction.frame(minWidth: 200, maxWidth: 260)
                        secondaryActions(watched, tileWidth: 82)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        primaryAction.frame(maxWidth: 360)
                        HStack(alignment: .top, spacing: 8) { secondaryActions(watched, tileWidth: nil) }
                            .frame(maxWidth: 460, alignment: .leading)
                    }
                }
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    primaryAction
                    secondaryActions(watched, tileWidth: nil)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    primaryAction
                    HStack(alignment: .top, spacing: 8) { secondaryActions(watched, tileWidth: nil) }
                }
            }
            if !current.isSeries, let account = session.account, let message = downloads.errors[Downloads.key(account: account, item: current)] {
                Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.reelMuted)
            }
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if current.isSeries {
            Button {
                if let episode = featuredEpisode { playback.present(episode) }
            } label: {
                PlayLabel(title: seriesPlayLabel, timeLeft: featuredEpisode?.remainingText).frame(maxWidth: .infinity)
            }.buttonStyle(PrimaryButton()).disabled(featuredEpisode == nil)
                .accessibilityIdentifier("seriesPlay")
                .accessibilityHint(featuredEpisode?.Name ?? "Choose a season with available episodes.")
        } else {
            Button { playback.present(current, audio: audio, subtitle: subtitle, mediaSourceID: sourceID) } label: {
                PlayLabel(title: current.resumeTicks > 0 ? "Resume" : "Play", timeLeft: current.remainingText).frame(maxWidth: .infinity)
            }.buttonStyle(PrimaryButton()).accessibilityIdentifier("detailPlay")
                .accessibilityHint(current.remainingText ?? "")
        }
    }

    @ViewBuilder private func secondaryActions(_ watched: WatchedStatusMenu, tileWidth: CGFloat?) -> some View {
        if !current.isSeries, current.resumeTicks > 0 {
            Button {
                var beginning = current; beginning.UserData?.PlaybackPositionTicks = 0
                playback.present(beginning, audio: audio, subtitle: subtitle, fromBeginning: true, mediaSourceID: sourceID)
            } label: { ActionTile(title: "Restart", systemImage: "arrow.counterclockwise") }
                .buttonStyle(.plain).frame(width: tileWidth).accessibilityIdentifier("detailStartOver")
                .accessibilityLabel("Restart from the beginning")
        }
        Button { Task { await toggleFavorite() } } label: {
            ActionTile(title: "Favorite", systemImage: current.isFavorite ? "heart.fill" : "heart", highlighted: current.isFavorite)
        }.buttonStyle(.plain).frame(width: tileWidth).disabled(savingFavorite || session.api?.isSimulatorPreview == true)
            .accessibilityLabel(current.isFavorite ? "Remove favorite" : "Add favorite").accessibilityIdentifier("favorite")
        watched.frame(width: tileWidth)
        downloadAction(tileWidth: tileWidth)
        if !current.isSeries {
            Menu {
                Button { showingRemote = true } label: {
                    Label("Play on another device", systemImage: "airplay.video")
                    Text("Or start a watch together session")
                }.accessibilityIdentifier("remotePlayback")
            } label: { ActionTile(title: "More", systemImage: "ellipsis") }
                .frame(width: tileWidth).accessibilityIdentifier("detailMore").accessibilityLabel("More options")
        }
    }

    @ViewBuilder private func downloadAction(tileWidth: CGFloat?) -> some View {
        if !current.isSeries, current.Type != "TvChannel", let account = session.account, let api = session.api {
            let key = Downloads.key(account: account, item: current)
            if let saved = downloads.saved(account: account, item: current) {
                Button { playback.presentDownload(saved.item, url: downloads.url(saved)) } label: {
                    ActionTile(title: "Play offline", systemImage: "arrow.down.circle.fill", highlighted: true)
                }.buttonStyle(.plain).frame(width: tileWidth).accessibilityIdentifier("playDownload")
                    .accessibilityLabel("Play downloaded copy")
            } else if downloads.active.contains(key) {
                Button { downloads.cancel(key) } label: {
                    ActionTile(title: "Cancel", systemImage: "stop.circle", progress: downloads.progress[key] ?? 0)
                }.buttonStyle(.plain).frame(width: tileWidth).accessibilityIdentifier("detailCancelDownload")
                    .accessibilityLabel("Cancel download").accessibilityValue("Downloading")
            } else {
                let original = Downloads.compatible(current)
                let smaller = Downloads.canOptimize(current)
                if smaller {
                    Menu {
                        if original { originalDownload(account: account, api: api, tile: false) }
                        Section("Converted by your server") {
                            ForEach(DownloadSize.allCases) { size in
                                Button { downloads.download(current, account: account, api: api, optimized: true, size: size) } label: {
                                    Label {
                                        Text(size.title)
                                        Text(size.perHour)
                                    } icon: { Image(systemName: "arrow.down.circle.dotted") }
                                }.accessibilityIdentifier(size == .standard ? "downloadOptimized" : "downloadOptimized-" + size.rawValue)
                            }
                        }
                    } label: { ActionTile(title: "Download", systemImage: "arrow.down.circle") }
                        .frame(width: tileWidth).accessibilityIdentifier("downloadMenu").accessibilityLabel("Download")
                } else if original {
                    originalDownload(account: account, api: api, tile: true)
                        .buttonStyle(.plain).frame(width: tileWidth)
                }
            }
        }
    }

    /// The original file: a menu item with its trade-off, or a tile when it is the only choice.
    private func originalDownload(account: Account, api: JellyfinAPI, tile: Bool) -> some View {
        Button { downloads.download(current, account: account, api: api) } label: {
            if tile {
                ActionTile(title: "Download", systemImage: "arrow.down.circle")
            } else {
                Label {
                    Text("Original quality")
                    Text("Full size. External subtitles aren’t included.")
                } icon: { Image(systemName: "arrow.down.circle") }
            }
        }.accessibilityIdentifier("download")
    }

    // MARK: Overview and options

    @ViewBuilder private var overview: some View {
        if let overview = current.Overview, !overview.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(overview).font(.body).lineSpacing(3).foregroundStyle(Color.reelText.opacity(0.82))
                    .lineLimit(overviewExpanded ? nil : 3)
                    .textSelection(.enabled).accessibilityIdentifier("detailOverview")
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { overviewShownHeight = $0 }
                    .background(alignment: .topLeading) {
                        Text(overview).font(.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                            .hidden().accessibilityHidden(true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { overviewFullHeight = $0 }
                    }
                if overviewExpanded || overviewFullHeight > overviewShownHeight + 1 {
                    Button(overviewExpanded ? "Less" : "More") { overviewExpanded.toggle() }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelText)
                        .frame(minHeight: 44).accessibilityIdentifier("detailOverviewMore")
                        .accessibilityLabel(overviewExpanded ? "Show less of the description" : "Show the full description")
                }
            }
        } else if loading && detail == nil {
            VStack(alignment: .leading, spacing: 8) {
                ForEach([1.0, 0.92, 0.6], id: \.self) { fraction in
                    RoundedRectangle(cornerRadius: 4).fill(Color.reelSurface).frame(height: 12).containerRelativeFrame(.horizontal) { width, _ in width * fraction * 0.8 }
                }
            }.accessibilityLabel("Loading details")
        }
    }

    @ViewBuilder private var optionChips: some View {
        if !current.isSeries {
            let sources = current.MediaSources ?? []
            let streams = selectedSource?.MediaStreams
            let chapters = current.Chapters ?? []
            if sources.count > 1 || streams != nil || !chapters.isEmpty {
                WrapLayout(spacing: 8, lineSpacing: 8) {
                    if sources.count > 1 {
                        Menu {
                            Picker("Version", selection: Binding(get: { selectedSource?.Id }, set: { sourceID = $0 })) {
                                ForEach(sources, id: \.Id) { source in Text(source.Name ?? source.Container?.uppercased() ?? "Version").tag(Optional(source.Id)) }
                            }
                        } label: { OptionChip(title: "Version", systemImage: "square.stack", value: sourceName) }
                            .accessibilityIdentifier("versionPicker").accessibilityLabel("Version").accessibilityValue(sourceName)
                    }
                    if let streams {
                        // Two submenus that show their current choice, like the system player's own menu.
                        Menu {
                            Picker("Audio", selection: $audio) {
                                Text("Server default").tag(nil as Int?)
                                ForEach(streams.filter { $0.Type == "Audio" }, id: \.Index) { stream in Text(stream.DisplayTitle ?? stream.Language ?? "Track \(stream.Index)").tag(Optional(stream.Index)) }
                            }.pickerStyle(.menu)
                            Picker("Subtitles", selection: $subtitle) {
                                Text("Server default").tag(nil as Int?)
                                Text("Off").tag(Optional(-1))
                                ForEach(streams.filter { $0.Type == "Subtitle" }, id: \.Index) { stream in Text(stream.DisplayTitle ?? stream.Language ?? "Track \(stream.Index)").tag(Optional(stream.Index)) }
                            }.pickerStyle(.menu)
                        } label: { OptionChip(title: "Audio and subtitles", systemImage: "captions.bubble", value: tracksSummary(streams)) }
                            .accessibilityIdentifier("detailTracks").accessibilityLabel("Audio and subtitles")
                            .accessibilityValue(tracksSummary(streams) ?? "Default")
                    }
                    if !chapters.isEmpty {
                        Menu {
                            ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                                Button(chapter.Name ?? "Chapter \(index + 1)") {
                                    var selection = current
                                    if selection.UserData == nil { selection.UserData = UserData() }
                                    selection.UserData?.PlaybackPositionTicks = chapter.StartPositionTicks
                                    playback.present(selection, audio: audio, subtitle: subtitle, fromBeginning: true, mediaSourceID: sourceID)
                                }
                            }
                        } label: { OptionChip(title: "Chapters", systemImage: "list.bullet.rectangle", value: nil) }
                            .accessibilityIdentifier("detailChapters").accessibilityLabel("Chapters")
                    }
                }
            }
        }
    }

    private var sourceName: String { selectedSource?.Name ?? selectedSource?.Container?.uppercased() ?? "Version" }

    private func trackName(_ index: Int?, in streams: [MediaStream]) -> String {
        guard let index, let stream = streams.first(where: { $0.Index == index }) else { return "Default" }
        return stream.DisplayTitle ?? stream.Language ?? "Track \(index)"
    }

    /// Nothing while both follow the server; otherwise the chosen audio and subtitles.
    private func tracksSummary(_ streams: [MediaStream]) -> String? {
        if audio == nil && subtitle == nil { return nil }
        return trackName(audio, in: streams) + ", " + (subtitle == -1 ? "Subtitles off" : trackName(subtitle, in: streams))
    }

    private var seriesPlayLabel: String {
        guard let episode = featuredEpisode else {
            if episodeError != nil || (error != nil && episodes.isEmpty) { return "Episodes unavailable" }
            return loadingEpisodes || loading || loadedSeason != season ? "Loading episodes…" : "No episodes available"
        }
        let action = episode.resumeTicks > 0 ? "Resume" : "Play"
        return episode.episodeNumberText.isEmpty ? "\(action) episode" : "\(action) \(episode.episodeNumberText)"
    }

    // MARK: Episodes, cast and related titles

    private func episodeSection(regular: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Episodes").font(.title3.weight(.bold)).tracking(-0.3)
                .readingAnchor("episodes") { noteAnchor("episodes", visible: $0, regular: regular) }
            if let selected = seasons.first(where: { $0.id == season }) {
                WatchedStatusButton(item: selected, identifier: "seasonWatchStatus", style: .chip) { watched in
                    WrapLayout(spacing: 8, lineSpacing: 8) {
                        seasonMenu
                        watched
                        UnwatchedCountBadge(item: selected)
                    }
                }
            } else if !seasons.isEmpty { seasonMenu }
            if loadingEpisodes {
                (regular ? AnyLayout(HStackLayout(alignment: .top, spacing: 20)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))) {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(alignment: .top, spacing: 14) {
                            RoundedRectangle(cornerRadius: ReelRadius.artwork).fill(Color.reelSurface).frame(width: 150, height: 84)
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 4).fill(Color.reelSurface).frame(width: 70, height: 10)
                                RoundedRectangle(cornerRadius: 4).fill(Color.reelSurface).frame(width: 150, height: 14)
                            }
                        }
                    }
                }.accessibilityElement().accessibilityLabel("Loading episodes")
            }
            else if let episodeError { FailureView(message: episodeError) { Task { await loadEpisodes() } }.frame(minHeight: 180) }
            else if episodes.isEmpty {
                ContentUnavailableView("No episodes", systemImage: "tv", description: Text("This season has no episodes yet."))
            }
            else if regular {
                // Two columns from about 570 points (an open foldable), three or four on a wide iPad.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 480), spacing: 24, alignment: .top)], alignment: .leading, spacing: 28) {
                    ForEach(episodes) { episode in
                        EpisodeTile(episode: episode, card: true)
                            .readingAnchor(episode.id) { noteAnchor(episode.id, visible: $0, regular: regular) }
                    }
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(episodes) { episode in
                        EpisodeTile(episode: episode, card: false)
                            .readingAnchor(episode.id) { noteAnchor(episode.id, visible: $0, regular: regular) }
                    }
                }
            }
        }
    }

    private var seasonMenu: some View {
        Menu {
            Picker("Season", selection: $season) { ForEach(seasons) { Text($0.Name).tag($0.id) } }
        } label: {
            OptionChip(title: seasons.first { $0.id == season }?.Name ?? "Season", systemImage: "rectangle.stack", value: nil)
        }
        .accessibilityIdentifier("seasonPicker").accessibilityLabel("Season")
        .accessibilityValue(seasons.first { $0.id == season }?.Name ?? "")
    }

    @ViewBuilder private func castSection(margin: CGFloat, regular: Bool, lead: CGFloat = 0, trail: CGFloat = 0) -> some View {
        if let people = current.People, !people.isEmpty {
            // At accessibility sizes a name needs more than 100 points or it breaks mid-word,
            // so cells widen with the text and sit on the heading's edge.
            let large = dynamicTypeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: 14) {
                Text("Cast & crew").font(.title3.weight(.bold)).tracking(-0.3)
                    .padding(.leading, margin + lead).padding(.trailing, margin + trail)
                    .readingAnchor("cast") { noteAnchor("cast", visible: $0, regular: regular) }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(people.prefix(24)) { person in
                            VStack(alignment: large ? .leading : .center, spacing: 8) {
                                Group {
                                    if person.PrimaryImageTag != nil {
                                        Artwork(item: MediaItem(Id: person.Id, Name: person.Name, ImageTags: person.PrimaryImageTag.map { ["Primary": $0] }), width: 250)
                                    } else {
                                        // No photo on the server: the person's initials, not a film placeholder.
                                        Circle().fill(Color.reelSurface)
                                            .overlay { Text(Self.initials(person.Name)).font(.title2.weight(.semibold)).foregroundStyle(Color.reelMuted) }
                                    }
                                }
                                    .frame(width: 84, height: 84).clipShape(Circle())
                                Text(person.Name).font(.subheadline.weight(.semibold)).lineLimit(large ? 3 : 2).multilineTextAlignment(large ? .leading : .center)
                                Text(person.Role ?? "").font(.caption).foregroundStyle(Color.reelMuted).lineLimit(2).multilineTextAlignment(large ? .leading : .center)
                            }.frame(width: large ? castCellWidth : 100, alignment: large ? .leading : .center).accessibilityElement(children: .combine)
                        }
                    }.scrollTargetLayout()
                }
                // Each 84 point portrait is centered in a 100 point cell; this puts the first
                // portrait on the same edge as the heading.
                .contentMargins(.leading, (large ? margin : margin - 8) + lead, for: .scrollContent)
                .contentMargins(.trailing, margin - 8 + trail, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
            }
        }
    }

    /// "Quinn Varga" becomes "QV"; a single name gives one letter.
    private static func initials(_ name: String) -> String {
        let words = name.split(separator: " ")
        return [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first.map(String.init) }.joined().uppercased()
    }

    @ViewBuilder private func relatedSection(margin: CGFloat, regular: Bool, lead: CGFloat = 0, trail: CGFloat = 0) -> some View {
        if !related.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("More like this").font(.title3.weight(.bold)).tracking(-0.3)
                    .padding(.leading, margin + lead).padding(.trailing, margin + trail)
                    .readingAnchor("related") { noteAnchor("related", visible: $0, regular: regular) }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(related) { item in
                            NavigationLink { DetailView(item: item) } label: { PosterCard(item: item, width: regular ? 160 : 132) }
                                .buttonStyle(.plain).accessibilityIdentifier("related-\(item.id)")
                        }
                    }.scrollTargetLayout()
                }
                .contentMargins(.leading, margin + lead, for: .scrollContent)
                .contentMargins(.trailing, margin + trail, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
            }
        }
    }

    private struct EpisodeLoadIdentity: Hashable { let season: String; let revision: Int }

    private func load() async {
        guard let api = session.api else { return }
        let accountRevision = session.revision
        let generation = UUID(); readGeneration = generation
        loading = true; error = nil
        defer { if readGeneration == generation { loading = false } }
        func currentRead() -> Bool { !Task.isCancelled && readGeneration == generation && session.revision == accountRevision }
        do {
            let updated = try await api.item(item.id)
            try Task.checkCancellation()
            guard currentRead() else { return }
            guard updated.id == item.id else { throw ReelError.invalidResponse }
            detail = updated
            if !((updated.MediaSources ?? []).contains { $0.Id == sourceID }) {
                sourceID = updated.MediaSources?.first?.Id
            }
            if updated.isSeries {
                let result = try await api.page("Shows/\(item.id)/Seasons")
                try Task.checkCancellation()
                guard currentRead() else { return }
                seasons = result.Items
                if !seasons.contains(where: { $0.id == season }) { season = seasons.first?.id ?? "" }
            }
            // Related content is optional; core details and seasons publish first.
            let similar: [MediaItem]
            do { similar = try await api.page("Items/\(item.id)/Similar", query: ["limit": "12"]).Items }
            catch is CancellationError { return }
            catch { similar = [] }
            guard currentRead() else { return }
            related = similar
        } catch is CancellationError { }
        catch { if currentRead() { self.error = error.localizedDescription } }
    }
    private func loadEpisodes() async {
        guard let api = session.api else { return }
        let target = season, accountRevision = session.revision
        let generation = UUID(); episodeReadGeneration = generation
        loadingEpisodes = true; episodeError = nil
        defer { if episodeReadGeneration == generation { loadingEpisodes = false } }
        func currentRead() -> Bool { !Task.isCancelled && episodeReadGeneration == generation && season == target && session.revision == accountRevision }
        do {
            let result = try await api.page("Shows/\(item.id)/Episodes", query: ["seasonId": target, "isMissing": "false"])
            try Task.checkCancellation()
            guard currentRead() else { return }
            episodes = result.Items
            loadedSeason = target
        } catch is CancellationError { }
        catch { if currentRead() { episodeError = error.localizedDescription } }
    }
    private func toggleFavorite() async {
        guard let api = session.api, let account = session.account else { return }
        let accountRevision = session.revision
        savingFavorite = true; readGeneration = UUID()
        defer { savingFavorite = false }
        do {
            let value = !current.isFavorite
            try await api.favorite(item.id, value: value)
            guard session.account?.id == account.id, session.revision == accountRevision else { return }
            var updated = current
            if updated.UserData == nil { updated.UserData = UserData() }
            updated.UserData?.IsFavorite = value; detail = updated
            // The accepted effect invalidates dependent lists before optional reads.
            _ = session.invalidateCatalogue(accountID: account.id, revision: accountRevision)
        } catch {
            guard session.account?.id == account.id, session.revision == accountRevision else { return }
            self.error = error.localizedDescription
            _ = session.invalidateCatalogue(accountID: account.id, revision: accountRevision)
        }
    }
}

/// One episode: the thumbnail plays it, the text opens its details. On iPad
/// it is a landscape card in a grid of two or three columns; on iPhone a row in a list.
private struct EpisodeTile: View {
    let episode: MediaItem
    let card: Bool
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = card || dynamicTypeSize.isAccessibilitySize
        (stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))) {
            Button { playback.present(episode) } label: { thumbnail }
                .buttonStyle(.plain)
                .frame(width: stacked ? nil : 150)
                .accessibilityIdentifier("episodePlay-\(episode.id)")
                .accessibilityLabel("\(episode.resumeTicks > 0 ? "Resume" : "Play") \(episode.Name)")
            NavigationLink { DetailView(item: episode) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(numberedTitle).font(.headline).foregroundStyle(Color.reelText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2).multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        if let time = played ? episode.duration : episode.remainingText ?? episode.duration { Text(time) }
                        if played { Text("Watched") }
                    }.font(.caption.weight(.semibold)).foregroundStyle(Color.reelMuted)
                    if let overview = episode.Overview, !overview.isEmpty {
                        Text(overview).font(.subheadline).foregroundStyle(Color.reelMuted)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2).multilineTextAlignment(.leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("episode-\(episode.id)")
        }
    }

    private var played: Bool { episode.UserData?.Played == true }

    private var numberedTitle: String {
        guard let number = episode.IndexNumber, number >= 0 else { return episode.Name }
        return "\(number). \(episode.Name)"
    }

    private var thumbnail: some View {
        Color.clear.aspectRatio(16 / 9, contentMode: .fit)
            .overlay { Artwork(item: episode.thumbnailItem, backdrop: true, width: card ? 900 : 500) }
            .overlay {
                Image(systemName: "play.fill").font(.system(size: card ? 18 : 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: card ? 48 : 38, height: card ? 48 : 38).background(.black.opacity(0.45), in: Circle())
            }
            .overlay(alignment: .bottom) {
                if episode.progress > 0, episode.UserData?.Played != true { WatchProgressBar(value: episode.progress).padding(8) }
            }
            .overlay(alignment: .topTrailing) {
                if episode.UserData?.Played == true {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(Color.reelBlue)
                        .background(Circle().fill(.black.opacity(0.5))).padding(7)
                        .accessibilityLabel("Watched")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: ReelRadius.artwork))
            .contentShape(RoundedRectangle(cornerRadius: ReelRadius.artwork))
    }
}

/// Play or Resume, then the time left in a lighter weight, as on the TV and web clients. The time
/// drops out when the button is too narrow for both.
private struct PlayLabel: View {
    let title: String
    let timeLeft: String?

    var body: some View {
        Label {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(title)
                    if let timeLeft { Text(timeLeft).font(.subheadline.weight(.medium)).monospacedDigit().opacity(0.62) }
                }
                Text(title)
            }
        } icon: {
            Image(systemName: "play.fill")
        }
    }
}

private extension View {
    /// Names a place on Details that the scroll position can return to, and reports when it
    /// comes on screen or leaves it.
    func readingAnchor(_ id: String, visibilityChanged: @escaping (Bool) -> Void) -> some View {
        self.id(id).onScrollVisibilityChange(threshold: 0.3, visibilityChanged)
    }
}
