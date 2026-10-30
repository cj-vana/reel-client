import SwiftUI

enum PlayerEpisodeCatalog {
    static func seasons(in items: [MediaItem], seriesID: String) -> [MediaItem] {
        items.filter { candidate in
            candidate.Type == "Season" && (candidate.SeriesId == nil || candidate.SeriesId == seriesID)
                && !candidate.id.isEmpty && items.filter { $0.id == candidate.id }.count == 1
        }
    }
    static func episodes(in items: [MediaItem], seriesID: String) -> [MediaItem] {
        items.filter { candidate in
            candidate.Type == "Episode" && candidate.SeriesId == seriesID
                && !candidate.id.isEmpty && items.filter { $0.id == candidate.id }.count == 1
        }
    }
}

struct PlayerEpisodePicker: View {
    let current: MediaItem
    let onSelect: (MediaItem) -> Void
    @Environment(Session.self) private var session
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var seasons: [MediaItem] = []
    @State private var selectedSeasonID: String?
    @State private var episodes: [MediaItem] = []
    @State private var loadingSeasons = true
    @State private var loadingEpisodes = false
    @State private var seasonError: String?
    @State private var episodeError: String?
    @State private var seasonAttempt = 0
    @State private var episodeAttempt = 0
    @State private var seasonGeneration = UUID()
    @State private var episodeGeneration = UUID()
    @State private var loadedSeasonID: String?
    @State private var loadedRevision: UUID?
    @State private var submitted = false

    private struct SeasonRequest: Hashable {
        let itemID: String
        let revision: UUID
        let attempt: Int
    }
    private struct EpisodeRequest: Hashable {
        let seasons: SeasonRequest
        let seasonID: String?
        let attempt: Int
    }
    private var seasonRequest: SeasonRequest {
        SeasonRequest(itemID: current.id, revision: session.revision, attempt: seasonAttempt)
    }
    private var episodeRequest: EpisodeRequest {
        EpisodeRequest(seasons: seasonRequest, seasonID: selectedSeasonID, attempt: episodeAttempt)
    }
    private var selectedSeason: MediaItem? { seasons.first { $0.id == selectedSeasonID } }
    private var ownsPlayback: Bool {
        playback.activeItem?.id == current.id && !playback.syncPlayManaged && playback.method != "Offline"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(current.SeriesName ?? current.title).font(.title2.bold()).tracking(-0.4)
                    Text("Now playing: \(current.Name)").font(.subheadline).foregroundStyle(Color.reelMuted)
                }
                if loadingSeasons {
                    loading("Loading seasons…", identifier: "playerSeasonsLoading")
                } else if let seasonError {
                    failure("Couldn’t load seasons", message: seasonError, identifier: "playerSeasonsError") { seasonAttempt += 1 }
                } else if seasons.isEmpty {
                    empty("No seasons available", detail: "This series has no seasons to browse yet.", identifier: "playerSeasonsEmpty")
                } else {
                    seasonMenu
                    episodeList
                }
            }
            .padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color.reelBackground)
        .foregroundStyle(Color.reelText)
        .navigationTitle("Episodes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.accessibilityIdentifier("closePlayerEpisodes")
            }
        }
        .toolbarMinimizationBehavior(.never, for: .navigationBar)
        .task(id: seasonRequest) { await loadSeasons() }
        .task(id: episodeRequest) { await loadEpisodes() }
        .onChange(of: playback.activeItem?.id) { _, id in if id != current.id { dismiss() } }
        .onChange(of: session.revision) { _, _ in dismiss() }
        .onDisappear { seasonGeneration = UUID(); episodeGeneration = UUID() }
    }

    private var seasonMenu: some View {
        Menu {
            ForEach(seasons) { season in
                Button {
                    selectedSeasonID = season.id
                } label: {
                    if season.id == selectedSeasonID { Label(season.Name, systemImage: "checkmark") }
                    else { Text(season.Name) }
                }
            }
        } label: {
            OptionChip(title: selectedSeason?.Name ?? "Choose a season", systemImage: "rectangle.stack", value: nil)
        }
        .foregroundStyle(Color.reelText)
        .accessibilityLabel("Season")
        .accessibilityValue(selectedSeason?.Name ?? "Choose a season")
        .accessibilityIdentifier("playerSeasonPicker")
        .disabled(submitted || !ownsPlayback)
    }

    @ViewBuilder private var episodeList: some View {
        if loadingEpisodes || loadedSeasonID != selectedSeasonID {
            loading("Loading episodes…", identifier: "playerEpisodesLoading")
        } else if let episodeError {
            failure("Couldn’t load episodes", message: episodeError, identifier: "playerEpisodesError") { episodeAttempt += 1 }
        } else if episodes.isEmpty {
            empty("No episodes available", detail: "Try another season, or check back when episodes have been added.", identifier: "playerEpisodesEmpty")
        } else {
            LazyVStack(spacing: 4) {
                ForEach(episodes) { episode in episodeRow(episode) }
            }
        }
    }

    private func episodeRow(_ episode: MediaItem) -> some View {
        let playing = episode.id == playback.activeItem?.id
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        return Button { select(episode) } label: {
            layout {
                Artwork(item: episode.thumbnailItem, backdrop: true, width: 600)
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? 240 : 144,
                           height: dynamicTypeSize.isAccessibilitySize ? 135 : 81)
                    .overlay {
                        Image(systemName: playing ? "waveform" : "play.fill")
                            .font(.subheadline.weight(.semibold)).frame(width: 36, height: 36)
                            .background(.black.opacity(0.55), in: Circle())
                            .foregroundStyle(playing ? Color.reelBlue : .white)
                    }
                    .overlay(alignment: .bottom) {
                        if episode.progress > 0, !playing { WatchProgressBar(value: episode.progress).padding(7).accessibilityHidden(true) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: ReelRadius.artwork)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(episode.episodeNumberText)
                        if let duration = episode.duration { Text(duration) }
                    }.font(.caption.weight(.semibold)).foregroundStyle(Color.reelMuted)
                    Text(episode.Name).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if playing {
                        Label("Playing", systemImage: "waveform").font(.caption.weight(.semibold)).foregroundStyle(Color.reelBlue)
                    } else if episode.UserData?.Played == true {
                        Label("Watched", systemImage: "checkmark").font(.caption.weight(.medium)).foregroundStyle(Color.reelMuted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(playing ? Color.reelSurface : .clear, in: RoundedRectangle(cornerRadius: ReelRadius.control))
            .contentShape(RoundedRectangle(cornerRadius: ReelRadius.control))
        }
        .buttonStyle(.plain).foregroundStyle(Color.reelText)
        .disabled(playing || submitted || !ownsPlayback || loadedRevision != session.revision)
        .accessibilityLabel([episode.episodeNumberText, episode.Name, episode.duration].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityValue(playing ? "Playing" : episode.UserData?.Played == true ? "Watched" : episode.progress > 0 ? "\(Int(episode.progress * 100)) percent watched" : "Not watched")
        .accessibilityHint(playing ? "This episode is already playing" : "Plays this episode")
        .accessibilityIdentifier("playerEpisode-\(episode.id)")
    }

    private func loading(_ title: String, identifier: String) -> some View {
        ProgressView(title).tint(Color.reelBlue).font(.subheadline)
            .frame(maxWidth: .infinity, minHeight: 160).accessibilityIdentifier(identifier)
    }
    private func failure(_ title: String, message: String, identifier: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: "wifi.exclamationmark").font(.headline).accessibilityIdentifier(identifier)
            Text(message).font(.subheadline).foregroundStyle(Color.reelMuted)
            Button("Try again", action: retry).buttonStyle(QuietButton()).accessibilityIdentifier(identifier + "Retry")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func empty(_ title: String, detail: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityIdentifier(identifier)
            Text(detail).font(.subheadline).foregroundStyle(Color.reelMuted)
        }.frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    }
    private func loadSeasons() async {
        guard !Task.isCancelled else { return }
        let generation = UUID(), revision = session.revision
        seasonGeneration = generation
        loadingSeasons = true; seasonError = nil; seasons = []; selectedSeasonID = nil
        episodes = []; loadedSeasonID = nil; loadedRevision = nil; submitted = false
        defer { if seasonGeneration == generation { loadingSeasons = false } }
        guard let seriesID = current.SeriesId, !seriesID.isEmpty else {
            seasonError = "Season information isn’t available for this video."
            return
        }
        guard let api = session.api else {
            seasonError = "Sign in to browse this series."
            return
        }
        func admitted() -> Bool {
            !Task.isCancelled && seasonGeneration == generation && session.revision == revision && ownsPlayback
        }
        guard admitted() else { return }
        do {
            let page = try await api.page("Shows/\(seriesID)/Seasons")
            guard admitted() else { return }
            seasons = PlayerEpisodeCatalog.seasons(in: page.Items, seriesID: seriesID)
            selectedSeasonID = seasons.first { $0.IndexNumber == current.ParentIndexNumber && current.ParentIndexNumber != nil }?.id ?? seasons.first?.id
        } catch is CancellationError { }
        catch { if admitted() { seasonError = error.localizedDescription } }
    }

    private func loadEpisodes() async {
        guard !Task.isCancelled else { return }
        let generation = UUID(), revision = session.revision
        episodeGeneration = generation
        episodes = []; episodeError = nil; loadedSeasonID = nil; loadedRevision = nil; loadingEpisodes = false
        guard let seasonID = selectedSeasonID, let seriesID = current.SeriesId, let api = session.api else { return }
        loadingEpisodes = true
        defer { if episodeGeneration == generation { loadingEpisodes = false } }
        func admitted() -> Bool {
            !Task.isCancelled && episodeGeneration == generation && session.revision == revision
                && selectedSeasonID == seasonID && ownsPlayback
        }
        guard admitted() else { return }
        do {
            let page = try await api.page("Shows/\(seriesID)/Episodes", query: ["seasonId": seasonID, "isMissing": "false"])
            guard admitted() else { return }
            episodes = PlayerEpisodeCatalog.episodes(in: page.Items, seriesID: seriesID)
            loadedSeasonID = seasonID; loadedRevision = revision
        } catch is CancellationError { }
        catch {
            if admitted() { episodeError = error.localizedDescription; loadedSeasonID = seasonID }
        }
    }

    private func select(_ episode: MediaItem) {
        guard !submitted, ownsPlayback, !loadingSeasons, !loadingEpisodes,
              loadedRevision == session.revision, loadedSeasonID == selectedSeasonID,
              episode.id != playback.activeItem?.id, episodes.contains(where: { $0.id == episode.id }) else { return }
        submitted = true
        onSelect(episode)
    }
}
