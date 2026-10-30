import AVFoundation
import Observation
import SwiftUI

enum TVEpisodeSequence {
    static func neighbors(of current: MediaItem, in items: [MediaItem]) -> (previous: MediaItem?, next: MediaItem?) {
        guard current.Type == "Episode", let series = current.SeriesId,
              items.filter({ $0.id == current.id }).count == 1,
              let index = items.firstIndex(where: { $0.id == current.id }) else { return (nil, nil) }
        func valid(_ item: MediaItem) -> MediaItem? {
            item.Type == "Episode" && item.SeriesId == series && item.id != current.id ? item : nil
        }
        return (index > 0 ? valid(items[index - 1]) : nil, index + 1 < items.count ? valid(items[index + 1]) : nil)
    }

    static func intro(in segments: [MediaSegment], seconds: Double, duration: Double) -> MediaSegment? {
        guard seconds.isFinite, seconds >= 0, duration.isFinite, duration > 0 else { return nil }
        return segments.first {
            $0.Type == "Intro" && $0.StartTicks >= 0 && $0.EndTicks > $0.StartTicks
                && Double($0.EndTicks) / ticksPerSecond <= duration
                && seconds >= Double($0.StartTicks) / ticksPerSecond && seconds < Double($0.EndTicks) / ticksPerSecond
        }
    }
}

struct TVNextEpisodeCountdown {
    private(set) var endedID: UUID?
    private(set) var remaining: Int?
    private var deadline: Date?
    private var cancelledID: UUID?

    mutating func update(endedID: UUID?, eligible: Bool, active: Bool, now: Date = .now) -> Bool {
        if self.endedID != endedID { self.endedID = endedID; deadline = nil; remaining = nil; cancelledID = nil }
        guard let endedID, eligible, active, cancelledID != endedID else { deadline = nil; remaining = nil; return false }
        if deadline == nil { deadline = now.addingTimeInterval(10) }
        remaining = max(0, Int(ceil(deadline!.timeIntervalSince(now))))
        guard remaining == 0 else { return false }
        cancelledID = endedID; deadline = nil; remaining = nil
        return true
    }

    mutating func cancel() { cancelledID = endedID; deadline = nil; remaining = nil }
    mutating func suspend() { deadline = nil; remaining = nil }
}

@MainActor @Observable final class TVEpisodePlayback {
    private(set) var previous: MediaItem?
    private(set) var next: MediaItem?
    private(set) var neighborsLoading = false
    private(set) var neighborsError: String?
    private(set) var seasons: [MediaItem] = []
    private(set) var episodes: [MediaItem] = []
    private(set) var seasonID = ""
    private(set) var loading = false
    private(set) var error: String?
    private(set) var episodeLoading = false
    private(set) var episodeError: String?
    private(set) var intro: MediaSegment?
    /// The credits are rolling and a next episode is ready, so the player offers it.
    private(set) var inCredits = false
    private(set) var browserPresented = false
    private(set) var countdown = TVNextEpisodeCountdown()
    private(set) var switching = false
    var active = true {
        didSet { if !active { countdown.suspend() } }
    }
    var autoplay: Bool {
        didSet { defaults.set(autoplay, forKey: "autoplayNextEpisode") }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private weak var owner: TVCoordinator?
    @ObservationIgnored private var presentation: UUID?
    @ObservationIgnored private var accountRevision: UUID?
    private var item: MediaItem?
    @ObservationIgnored private var api: JellyfinAPI?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var seasonsGeneration = UUID()
    @ObservationIgnored private var seasonGeneration = UUID()
    @ObservationIgnored private var segments: [MediaSegment] = []
    /// The intro and credits found from the audio, for kinds the server did not mark.
    @ObservationIgnored private var foundSegments: [MediaSegment] = []
    @ObservationIgnored private var detectionTask: Task<Void, Never>?
    @ObservationIgnored private var skipped: Set<String> = []
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var browserTask: Task<Void, Never>?
    @ObservationIgnored private var resumeAfterBrowser = false
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoplay = defaults.object(forKey: "autoplayNextEpisode") == nil || defaults.bool(forKey: "autoplayNextEpisode")
    }

    var currentID: String? { item?.id }
    var seriesTitle: String { item?.SeriesName ?? "Episodes" }
    var isEpisode: Bool { item?.Type == "Episode" && item?.SeriesId != nil }

    func load(owner: TVCoordinator, presentation: UUID) async {
        invalidate()
        previous = nil; next = nil; neighborsError = nil; seasons = []; episodes = []; seasonID = ""
        segments = []; foundSegments = []; inCredits = false; skipped = []; browserPresented = false; countdown = TVNextEpisodeCountdown()
        loading = false; neighborsLoading = false; episodeLoading = false
        self.owner = owner; self.presentation = presentation; accountRevision = owner.session.revision
        item = owner.playback.activeItem; api = owner.session.api
        guard ownsPresentation else { return }
        lifecycleObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.active = false }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.active = true }
            }
        ]
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.ownsPresentation else { return }
                self.tick()
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
        let metadata = Task { [weak self] in
            guard let self else { return }
            async let neighborLoad: Void = self.loadNeighbors()
            async let segmentLoad: Void = self.loadSegments()
            _ = await (neighborLoad, segmentLoad)
            // The scan runs on its own, so loading never waits for it.
            self.detectionTask = Task { [weak self] in await self?.findIntroAndCredits() }
        }
        metadataTask = metadata
        await metadata.value
    }

    private var ownsPresentation: Bool {
        guard let owner, let item, let api else { return false }
        return owner.showingPlayer && owner.presentationID == presentation && owner.playback.activeItem?.id == item.id
            && owner.session.revision == accountRevision && owner.session.api?.server == api.server
            && owner.session.api?.userID == api.userID && owner.session.api?.token == api.token
    }

    func loadNeighbors() async {
        guard ownsPresentation, !neighborsLoading, let item, item.Type == "Episode", let series = item.SeriesId, let api else { return }
        let current = generation
        neighborsLoading = true; neighborsError = nil
        defer { if generation == current { neighborsLoading = false } }
        do {
            let page = try await api.page("Shows/\(series)/Episodes", query: ["adjacentTo": item.id, "isMissing": "false"])
            guard !Task.isCancelled, generation == current, ownsPresentation else { return }
            let result = TVEpisodeSequence.neighbors(of: item, in: page.Items)
            previous = result.previous; next = result.next
            if !page.Items.contains(where: { $0.id == item.id }) { neighborsError = "The current episode is missing from the series list. Browse episodes or try again." }
        } catch {
            if generation == current, ownsPresentation, !Task.isCancelled { neighborsError = "Nearby episodes couldn’t load. Try again while this episode keeps playing." }
        }
    }

    private func loadSegments() async {
        guard ownsPresentation, let item, let api, item.Type != "TvChannel" else { return }
        let current = generation
        do {
            let page: MediaSegmentPage = try await api.get("MediaSegments/\(item.id)")
            guard !Task.isCancelled, generation == current, ownsPresentation else { return }
            segments = page.Items
        } catch { /* Segment metadata is optional; never infer an intro from elapsed time. */ }
    }

    /// Fills in the intro and credits the server did not mark by comparing this episode's audio with a neighbor's.
    private func findIntroAndCredits() async {
        guard ownsPresentation, let item, let api, item.Type == "Episode",
              defaults.object(forKey: "findMarkers") == nil || defaults.bool(forKey: "findMarkers") else { return }
        let neighbors = [next, previous].compactMap { $0 }
        guard !neighbors.isEmpty else { return }
        let current = generation
        func apply(_ found: FoundMarkers) {
            guard !Task.isCancelled, generation == current, ownsPresentation else { return }
            foundSegments = found.segments(runtimeTicks: item.RunTimeTicks, server: segments)
        }
        apply(MarkerDetector.shared.known(accountID: MarkerDetector.accountID(api), item: item))
        let intro = !segments.contains { $0.Type == "Intro" }, credits = next != nil && !segments.contains { $0.Type == "Outro" }
        guard intro || credits else { return }
        // The picture starts first; the scan then downloads a few megabytes of low-quality audio.
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        guard let found = try? await MarkerDetector.shared.detect(api: api, item: item, neighbors: neighbors, intro: intro, credits: credits) else { return }
        apply(found)
    }

    func openBrowser() {
        guard ownsPresentation, isEpisode, !switching, let owner, !owner.transitioning else { return }
        resumeAfterBrowser = owner.playback.player.rate > 0
        owner.playback.player.pause(); owner.playback.reportPauseState()
        browserPresented = true
        if seasons.isEmpty { retryBrowser() }
    }

    func closeBrowser() {
        browserPresented = false
        if ownsPresentation, resumeAfterBrowser, let owner, !owner.playback.ended, owner.playback.error == nil {
            owner.playback.player.playImmediately(atRate: owner.playback.speed)
            owner.playback.reportPauseState()
        }
        resumeAfterBrowser = false
    }

    func retryBrowser() {
        browserTask?.cancel()
        browserTask = Task { [weak self] in await self?.loadSeasons() }
    }

    private func loadSeasons() async {
        guard ownsPresentation, let series = item?.SeriesId, let api else { return }
        let current = generation, operation = UUID()
        seasonsGeneration = operation
        loading = true; error = nil
        defer { if generation == current, seasonsGeneration == operation { loading = false } }
        do {
            let page = try await api.page("Shows/\(series)/Seasons", query: ["isMissing": "false"])
            guard !Task.isCancelled, generation == current, seasonsGeneration == operation, ownsPresentation else { return }
            var seen: Set<String> = []
            seasons = page.Items.filter { $0.Type == "Season" && seen.insert($0.id).inserted }
            seasonID = seasons.first(where: { $0.IndexNumber != nil && $0.IndexNumber == item?.ParentIndexNumber })?.id ?? seasons.first?.id ?? ""
            await loadEpisodes()
        } catch {
            if generation == current, seasonsGeneration == operation, ownsPresentation, !Task.isCancelled { self.error = "Seasons couldn’t load. Try again or return to playback." }
        }
    }

    func chooseSeason(_ id: String) {
        guard seasons.contains(where: { $0.id == id }), ownsPresentation else { return }
        seasonID = id
        retryEpisodes()
    }

    func retryEpisodes() {
        browserTask?.cancel()
        browserTask = Task { [weak self] in await self?.loadEpisodes() }
    }

    private func loadEpisodes() async {
        let operation = UUID(); seasonGeneration = operation
        episodes = []; episodeError = nil
        guard ownsPresentation, !seasonID.isEmpty, let series = item?.SeriesId, let api else { return }
        let season = seasonID
        episodeLoading = true
        defer { if seasonGeneration == operation { episodeLoading = false } }
        do {
            var collected: [MediaItem] = [], seen: Set<String> = []
            while true {
                let page = try await api.page("Shows/\(series)/Episodes", query: ["seasonId": season, "isMissing": "false", "startIndex": String(collected.count), "limit": "200"])
                guard !Task.isCancelled, seasonGeneration == operation, seasonID == season, ownsPresentation else { return }
                guard page.Items.allSatisfy({ $0.Type == "Episode" && $0.SeriesId == series && seen.insert($0.id).inserted }) else { throw ReelError.invalidResponse }
                collected += page.Items
                if page.Items.isEmpty || page.TotalRecordCount.map({ collected.count >= $0 }) == true || page.TotalRecordCount == nil && page.Items.count < 200 { break }
                guard collected.count < 10_000 else { throw ReelError.invalidResponse }
            }
            episodes = collected
        } catch {
            if seasonGeneration == operation, ownsPresentation, !Task.isCancelled { episodeError = "Episodes couldn’t load. Try again or choose another season." }
        }
    }

    func play(_ selected: MediaItem) {
        guard ownsPresentation, !switching, let owner, !owner.transitioning, !owner.changingSubtitles,
              selected.id != item?.id,
              [previous, next].compactMap({ $0 }).contains(where: { $0.id == selected.id }) || episodes.contains(where: { $0.id == selected.id }) else { return }
        switching = true; countdown.cancel()
        Task { [weak self, weak owner] in
            guard let self, let owner, self.ownsPresentation else { return }
            await owner.play(selected, fromBeginning: true)
            self.switching = false
        }
    }

    func cancelAutoplay() { countdown.cancel() }

    func skipIntro() {
        guard ownsPresentation, let owner, let intro, !owner.changingSubtitles, !owner.playback.preparing,
              owner.playback.error == nil, !owner.playback.ended, owner.preferences.segmentMode("Intro") != .none,
              TVEpisodeSequence.intro(in: [intro], seconds: owner.playback.player.currentTime().seconds, duration: owner.playback.player.currentItem?.duration.seconds ?? .nan) != nil else { return }
        skipped.insert(intro.id); self.intro = nil
        owner.playback.seek(to: intro.EndTicks)
    }

    private func tick() {
        guard let owner else { return }
        let playback = owner.playback
        let ready = !playback.preparing && !playback.ended && playback.error == nil && !owner.changingSubtitles && !switching
        let seconds = playback.player.currentTime().seconds, duration = playback.player.currentItem?.duration.seconds ?? .nan
        let candidate = ready ? TVEpisodeSequence.intro(in: segments + foundSegments, seconds: seconds, duration: duration) : nil
        let visible = owner.preferences.segmentMode("Intro") != .none ? candidate : nil
        if intro?.id != visible?.id { intro = visible }
        let credits = ready && next != nil && (segments + foundSegments).contains {
            $0.Type == "Outro" && seconds.isFinite && seconds >= Double($0.StartTicks) / ticksPerSecond && seconds < Double($0.EndTicks) / ticksPerSecond
        }
        if inCredits != credits { inCredits = credits }
        let foreground = active && UIApplication.shared.applicationState == .active
        if let intro, owner.preferences.segmentMode("Intro") == .auto, playback.isPlaying, foreground, !browserPresented, !skipped.contains(intro.id) { skipIntro() }
        let shouldPlay = countdown.update(endedID: playback.ended ? playback.endedSessionID : nil,
            eligible: autoplay && next != nil && !switching && !owner.transitioning && !playback.restartingEnded && playback.error == nil,
            active: foreground && !browserPresented)
        if shouldPlay, let next { play(next) }
    }

    func invalidate() {
        generation = UUID(); seasonsGeneration = UUID(); seasonGeneration = UUID()
        monitor?.cancel(); monitor = nil; browserTask?.cancel(); browserTask = nil
        metadataTask?.cancel(); metadataTask = nil; detectionTask?.cancel(); detectionTask = nil
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers = []
        countdown.cancel(); intro = nil; inCredits = false
        owner = nil; api = nil
    }
}

struct TVPlayerEpisodeBrowser: View {
    let store: TVEpisodePlayback
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.seriesTitle).font(.system(size: 52, weight: .bold)).tracking(-0.6).lineLimit(1)
                        Text("Choose an episode").font(.system(size: 26)).foregroundStyle(Color.tvMuted)
                    }
                    Spacer(minLength: 40)
                    Button("Return to playback") { store.closeBrowser() }.accessibilityIdentifier("closeEpisodeBrowser")
                        .font(.system(size: 24, weight: .semibold))
                }
                Toggle("Play the next episode automatically", isOn: Binding(get: { store.autoplay }, set: { store.autoplay = $0 }))
                    .accessibilityIdentifier("autoplayNextEpisode")
                if store.neighborsLoading { ProgressView("Finding nearby episodes…") }
                if let error = store.neighborsError {
                    Text(error).foregroundStyle(Color.tvMuted)
                    Button("Retry nearby episodes") { Task { await store.loadNeighbors() } }.accessibilityIdentifier("retryNearbyEpisodes")
                }
                if store.loading { ProgressView("Loading seasons…").accessibilityIdentifier("episodeBrowserLoading") }
                else if let error = store.error {
                    Text(error)
                    Button("Retry seasons") { store.retryBrowser() }.accessibilityIdentifier("retryPlayerSeasons")
                } else if store.seasons.isEmpty {
                    Text("No seasons available.").accessibilityIdentifier("emptyPlayerSeasons")
                } else {
                    Picker("Season", selection: Binding(get: { store.seasonID }, set: { store.chooseSeason($0) })) {
                        ForEach(store.seasons) { Text($0.Name).tag($0.id) }
                    }
                    // As wide as its seasons, like the season tabs on a series page.
                    .frame(maxWidth: min(1100, CGFloat(store.seasons.count) * 240), alignment: .leading)
                    .accessibilityIdentifier("playerSeason")
                    if store.episodeLoading { ProgressView("Loading episodes…").accessibilityIdentifier("playerEpisodesLoading") }
                    else if let error = store.episodeError {
                        Text(error)
                        Button("Retry episodes") { store.retryEpisodes() }.accessibilityIdentifier("retryPlayerEpisodes")
                    } else if store.episodes.isEmpty { Text("No episodes in this season.").accessibilityIdentifier("emptyPlayerEpisodes") }
                    else {
                        ForEach(store.episodes) { episode in
                            Button { store.play(episode) } label: {
                                HStack(spacing: 32) {
                                    TVArtwork(item: episode.thumbnailItem, backdrop: true, width: 600)
                                        .aspectRatio(16.0 / 9, contentMode: .fit).frame(width: 288)
                                        .clipShape(RoundedRectangle(cornerRadius: TVLayout.artworkRadius, style: .continuous))
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(heading(episode)).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                                        let line = status(episode)
                                        if !line.isEmpty { Text(line).font(.system(size: 22)).foregroundStyle(Color.tvMuted).lineLimit(1) }
                                        if let overview = episode.Overview, !overview.isEmpty {
                                            Text(overview).font(.system(size: 22)).foregroundStyle(Color.tvMuted).lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 24)
                                    if episode.id == store.currentID {
                                        Label("Now playing", systemImage: "play.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.tvMuted)
                                    }
                                }.padding(20)
                            }.buttonStyle(.card).disabled(episode.id == store.currentID || store.switching)
                                .accessibilityIdentifier("playerEpisode-" + episode.id)
                        }
                    }
                }
            }
            .padding(.horizontal, TVLayout.margin).padding(.vertical, 60)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .background(Color.reelBackground.opacity(0.96)).onExitCommand { store.closeBrowser() }
    }

    /// "1. First Light", as episode cards read on a series page.
    private func heading(_ episode: MediaItem) -> String {
        guard let number = episode.IndexNumber, number >= 0 else { return episode.Name }
        return "\(number). \(episode.Name)"
    }

    /// How long it runs or has left, then Watched, as on a series page.
    private func status(_ episode: MediaItem) -> String {
        let length = episode.progress > 0 ? TVMetadata.remaining(episode) : TVMetadata.runtime(episode.RunTimeTicks)
        let watched = episode.itemWatched == true && episode.progress == 0
        return [length, watched ? "Watched" : nil].compactMap { $0 }.joined(separator: "  ")
    }
}
