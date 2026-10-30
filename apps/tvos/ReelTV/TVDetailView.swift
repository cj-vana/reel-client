import SwiftUI

struct TVDetailView: View {
    let id: String
    @Environment(TVCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = TVDetailStore()
    @State private var refresh = 0
    @State private var loadedKey: String?
    @FocusState private var seasonsFocused: Bool

    var body: some View {
        @Bindable var store = store
        Group {
            ScrollViewReader { scroll in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        // A series waits for its first episodes and Next Up, so its first action does not
                        // change under the remote's focus a moment after the page appears.
                        if store.loading && (store.item == nil || store.item?.isSeries == true) {
                            loading
                        } else if let error = store.error {
                            TVFailure(title: "This title couldn’t load.", message: error) { refresh += 1 }
                                .padding(.horizontal, TVLayout.margin).padding(.top, 300)
                        } else if let item = store.item {
                            header(item, scroll: scroll)
                                .containerRelativeFrame(.vertical, alignment: .bottomLeading) { length, _ in length * (item.isSeries ? 0.8 : 0.92) }
                            if item.isSeries { seasons(store: store).id("seasons") }
                        }
                    }
                    // Kept short: with an episode focused the page sits at its end, and every point here
                    // pushes the genre and title up toward the TV's top overscan edge.
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(edges: .horizontal)
        .background { TVBackdrop(item: store.item) }
        .task(id: "\(id)|\(coordinator.session.revision)|\(refresh)") {
            guard let api = coordinator.session.api else { return }
            let key = "\(id)|\(coordinator.session.revision)|\(refresh)"
            // Returning from an episode or the player keeps the chosen season; only user data refreshes.
            if loadedKey == key, store.item != nil, store.error == nil { await store.refreshUserData(api: api); return }
            loadedKey = key
            await store.load(id: id, api: api)
        }
        .task(id: coordinator.session.libraryRevision) { if let api = coordinator.session.api { await store.refreshUserData(api: api) } }
        .onChange(of: store.seasonID) { _, _ in Task { if let api = coordinator.session.api { await store.loadEpisodes(api: api) } } }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 22) {
            ProgressView()
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.reelSurfaceRaised).frame(width: 640, height: 60)
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.reelSurfaceRaised).frame(width: 380, height: 26)
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.reelSurfaceRaised).frame(width: 900, height: 90)
        }
        .padding(.horizontal, TVLayout.margin).padding(.top, 520)
    }

    // MARK: Header

    private func header(_ item: MediaItem, scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if item.Type == "Episode", !episodeContext(item).isEmpty {
                Text(episodeContext(item)).font(.system(size: 28, weight: .semibold)).foregroundStyle(Color.reelText)
                    .accessibilityIdentifier("detailEpisodeContext")
            }
            TVGenreEyebrow(item: item)
            Text(item.Name).font(.system(size: 64, weight: .bold)).tracking(-1).lineLimit(2)
                .foregroundStyle(Color.reelText).accessibilityIdentifier("detailTitle")
            TVMetadataLine(item: item)
            TVUnwatchedCount(item: item, stale: store.userDataError != nil || store.userDataRefreshing)
            if let overview = item.Overview, !overview.isEmpty {
                Text(overview).font(.system(size: 26)).foregroundStyle(Color.reelText.opacity(0.82)).lineLimit(3)
                    .frame(maxWidth: 1040, alignment: .leading)
            }
            actions(item, scroll: scroll).padding(.top, 14)
            if !item.isSeries { options(item) }
            if let error = store.favoriteError {
                Text(error).font(.system(size: 23)).foregroundStyle(Color.tvMuted).accessibilityIdentifier("favoriteError")
            }
            if let error = store.userDataError {
                Text(error).font(.system(size: 23)).foregroundStyle(Color.tvMuted).accessibilityIdentifier("watchedDataError")
                HStack {
                    Button("Retry watched status") { if let api = coordinator.session.api { Task { await store.refreshUserData(api: api) } } }
                        .accessibilityIdentifier("retryWatchedData")
                    Spacer()
                }.focusSection()
            }
        }
        .padding(.horizontal, TVLayout.margin)
        .padding(.bottom, 24)
    }

    /// The episode a series page offers first: one already started in the chosen season, then the server's
    /// Next Up, then the season's first unwatched episode. None means Episodes leads instead.
    private var featuredEpisode: MediaItem? {
        guard !store.episodeLoading, store.episodeError == nil else { return store.nextUp }
        return store.episodes.first { $0.resumeTicks > 0 && $0.itemWatched != true }
            ?? store.nextUp
            ?? store.episodes.first { $0.itemWatched != true }
    }

    /// One row: Play or Resume, Restart, Episodes, Favorite, then the watched menu.
    private func actions(_ item: MediaItem, scroll: ScrollViewProxy) -> some View {
        TVWatchedControls(item: item, scopeKey: "detail:" + item.id, identifier: "detailWatchStatus") {
            if !item.isSeries {
                Button { play(item) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "play.fill")
                        Text(item.resumeTicks > 0 ? "Resume" : "Play")
                        if item.resumeTicks > 0, let left = TVMetadata.remaining(item) {
                            Text(left).font(.system(size: 22, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(coordinator.transitioning).accessibilityIdentifier("detailPlay")
                if item.resumeTicks > 0 {
                    Button { play(item, beginning: true) } label: { Label("Restart", systemImage: "arrow.counterclockwise") }
                        .disabled(coordinator.transitioning).accessibilityIdentifier("startOver")
                }
            } else if !store.seasons.isEmpty {
                if let episode = featuredEpisode {
                    let action = episode.resumeTicks > 0 ? "Resume" : "Play", number = TVMetadata.episodeLabel(episode)
                    Button { Task { await coordinator.play(episode) } } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "play.fill")
                            Text(number.isEmpty ? action + " episode" : action + " " + number)
                            if episode.resumeTicks > 0, let left = TVMetadata.remaining(episode) {
                                Text(left).font(.system(size: 22, weight: .medium)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(coordinator.transitioning)
                    .accessibilityHint(episode.Name)
                    .accessibilityIdentifier("seriesPlay")
                }
                Button {
                    seasonsFocused = true
                    // Scroll after the focus engine's own scroll to the picker, or the episodes stay
                    // cut off by the bottom edge.
                    Task {
                        try? await Task.sleep(for: .milliseconds(60))
                        if reduceMotion { scroll.scrollTo("seasons", anchor: .top) } else { withAnimation(.tvState) { scroll.scrollTo("seasons", anchor: .top) } }
                    }
                } label: { Label("Episodes", systemImage: "rectangle.stack") }
                    .accessibilityIdentifier("detailEpisodes")
            }
            Button { Task { await store.toggleFavorite(session: coordinator.session) } } label: {
                Label("Favorite", systemImage: item.isFavorite ? "heart.fill" : "heart")
            }
            .disabled(store.favoriteSaving)
            .accessibilityIdentifier("detailFavorite")
            .accessibilityValue(item.isFavorite ? "In favorites" : "Not in favorites")
        }
        .id(item.id)
        .font(.system(size: 26, weight: .semibold))
    }

    private func episodeContext(_ item: MediaItem) -> String {
        [item.SeriesName?.trimmingCharacters(in: .whitespacesAndNewlines), TVMetadata.episodeLabel(item)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func options(_ item: MediaItem) -> some View {
        HStack(spacing: 22) {
            if let sources = item.MediaSources, sources.count > 1 {
                Menu("Version: " + (store.selectedSource?.Name ?? "Original")) {
                    ForEach(sources, id: \.Id) { source in Button(source.Name ?? source.Id) { store.chooseSource(source.Id) } }
                }.accessibilityLabel("Version: " + (store.selectedSource?.Name ?? "Original")).accessibilityIdentifier("sourceOptions")
            }
            if let streams = store.selectedSource?.MediaStreams {
                let audio = streams.filter { $0.Type == "Audio" }
                let subtitles = streams.filter { $0.Type == "Subtitle" }
                if !audio.isEmpty {
                    Menu("Audio: " + (audio.first(where: { $0.Index == store.audio })?.DisplayTitle ?? "Default")) {
                        Button("Server default") { store.audio = nil }
                        ForEach(audio, id: \.Index) { stream in Button(stream.DisplayTitle ?? stream.Language ?? "Track \(stream.Index)") { store.audio = stream.Index } }
                    }.accessibilityLabel("Audio: " + (audio.first(where: { $0.Index == store.audio })?.DisplayTitle ?? "Default")).accessibilityIdentifier("audioOptions")
                }
                if !subtitles.isEmpty {
                    Menu("Subtitles: " + (store.subtitle == -1 ? "Off" : subtitles.first(where: { $0.Index == store.subtitle })?.DisplayTitle ?? "Default")) {
                        Button("Server default") { store.subtitle = nil }
                        Button("Off") { store.subtitle = -1 }
                        ForEach(subtitles, id: \.Index) { stream in Button(stream.DisplayTitle ?? stream.Language ?? "Track \(stream.Index)") { store.subtitle = stream.Index } }
                    }.accessibilityLabel("Subtitles: " + (store.subtitle == -1 ? "Off" : subtitles.first(where: { $0.Index == store.subtitle })?.DisplayTitle ?? "Default")).accessibilityIdentifier("subtitleOptions")
                }
            }
        }
        .font(.system(size: 22, weight: .medium))
        .focusSection()
    }

    // MARK: Seasons and episodes

    private func seasons(store: TVDetailStore) -> some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 18) {
            // The season's status sits above the season tabs: tvOS selects a tab as focus crosses it,
            // so a control beside the tabs would switch seasons on the way there. The tabs name the season,
            // so this row does not repeat its name. The series' own Watched control sits one row up, so this one
            // names its scope.
            if let season = store.seasons.first(where: { $0.id == store.seasonID }) {
                HStack(alignment: .center, spacing: 28) {
                    TVWatchedControls(item: season, scopeKey: "season:" + season.id, identifier: "seasonWatchStatus", title: "Season watched").id(season.id)
                        .font(.system(size: 22, weight: .semibold))
                    TVUnwatchedCount(item: season, stale: store.userDataError != nil || store.userDataRefreshing)
                }
                .padding(.horizontal, TVLayout.margin)
                .focusSection()
            }
            if !store.seasons.isEmpty {
                Picker("Season", selection: $store.seasonID) {
                    ForEach(store.seasons) { season in Text(season.Name).tag(season.id) }
                }
                .focused($seasonsFocused)
                .frame(maxWidth: min(1100, CGFloat(store.seasons.count) * 240), alignment: .leading)
                .accessibilityIdentifier("season")
                .accessibilityValue(store.seasons.first(where: { $0.id == store.seasonID })?.Name ?? "No season selected")
                .padding(.horizontal, TVLayout.margin)
                .focusSection()
            }
            if store.episodeLoading {
                TVSkeletonRow(wide: true, count: 5).padding(.horizontal, TVLayout.margin).padding(.vertical, 24)
                ProgressView().padding(.horizontal, TVLayout.margin)
            } else if let error = store.episodeError {
                TVFailure(title: "Episodes couldn’t load.", message: error) { Task { if let api = coordinator.session.api { await store.loadEpisodes(api: api) } } }
                    .padding(.horizontal, TVLayout.margin)
            } else if store.episodes.isEmpty {
                TVEmpty(title: "No episodes here yet.", message: "Choose another season, or add episodes to this library.")
                    .padding(.horizontal, TVLayout.margin)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: TVLayout.rowSpacing) {
                        ForEach(store.episodes) { episode in episodeCard(episode) }
                    }
                    .padding(.top, 24).padding(.bottom, 12)
                }
                .contentMargins(.horizontal, TVLayout.margin, for: .scrollContent)
                .scrollClipDisabled()
                .focusSection()
                .accessibilityIdentifier("episodeRow")
            }
        }
    }

    /// A still with the episode's state on it (progress, or a check once watched), then its number and name,
    /// how long it runs or has left, and two lines of its synopsis.
    private func episodeCard(_ episode: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { coordinator.detail(episode) } label: {
                TVArtwork(item: episode.thumbnailItem, backdrop: true, width: 800)
                    .aspectRatio(16.0 / 9, contentMode: .fit)
                    .overlay(alignment: .bottom) {
                        if episode.progress > 0 { TVProgressBar(progress: episode.progress).padding(14) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if watched(episode) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(Color.reelBlue)
                                .background(Circle().fill(Color.tvShadow.opacity(0.55)))
                                .padding(12)
                        }
                    }
            }
            .buttonStyle(TVLiftStyle())
            .accessibilityLabel(episodeHeading(episode))
            .accessibilityValue([TVMetadata.runtime(episode.RunTimeTicks), episode.progress > 0 ? TVMetadata.remaining(episode) : nil,
                                 watched(episode) ? "Watched" : nil].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("episode-" + episode.id)
            .accessibilityHint(episode.Overview ?? "")
            VStack(alignment: .leading, spacing: 6) {
                Text(episodeHeading(episode)).font(.system(size: 24, weight: .semibold)).foregroundStyle(Color.reelText).lineLimit(1)
                // One muted line, the same on every Reel client: how long it runs or has left, then Watched.
                let length = episode.progress > 0 ? TVMetadata.remaining(episode) : TVMetadata.runtime(episode.RunTimeTicks)
                let status = [length, watched(episode) ? "Watched" : nil].compactMap { $0 }.joined(separator: "  ")
                if !status.isEmpty { Text(status).font(.system(size: 20)).foregroundStyle(Color.tvMuted).lineLimit(1) }
                if let overview = episode.Overview, !overview.isEmpty {
                    Text(overview).font(.system(size: 20)).foregroundStyle(Color.tvMuted).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityHidden(true)
        }
        .frame(width: TVLayout.landscapeWidth)
    }

    private func watched(_ episode: MediaItem) -> Bool { episode.itemWatched == true && episode.progress == 0 }

    private func episodeHeading(_ episode: MediaItem) -> String {
        guard let number = episode.IndexNumber, number >= 0 else { return episode.Name }
        return "\(number). \(episode.Name)"
    }

    private func play(_ item: MediaItem, beginning: Bool = false) {
        Task { await coordinator.play(item, sourceID: store.sourceID.isEmpty ? nil : store.sourceID, audio: store.audio, subtitle: store.subtitle, fromBeginning: beginning) }
    }
}
