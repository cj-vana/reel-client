import Foundation
import AVFoundation
import Observation

enum TVTab: Hashable { case home, movies, shows, search, library, settings }
enum TVRoute: Hashable { case detail(String), library(TVLibraryDestination) }
enum TVFilter: String, CaseIterable { case all = "All", movies = "Movies", series = "Series" }

@MainActor @Observable final class TVCoordinator {
    let session: Session
    let playback = PlaybackController()
    let preferences = ServerPreferences()
    let watchedLane = TVWatchedLane()
    let removedBrowseCleanup: RemovedBrowsePreferencesCleanup
    var tab = TVTab.home
    /// Fixed so the Movies and Shows tabs keep their browse state while the app runs.
    let moviesTab = TVLibraryDestination(category: "Movies", sort: nil, parent: nil)
    let showsTab = TVLibraryDestination(category: "Series", sort: nil, parent: nil)
    var path: [TVRoute] = []
    var showingPlayer = false
    private(set) var presentationID = UUID()
    private(set) var transitioning = false
    private(set) var changingSubtitles = false
    private(set) var subtitleChoice: Int?
    var subtitleError: String?
    private(set) var subtitleMetadataLoading = false
    private(set) var subtitleMetadata: MediaItem?
    private(set) var subtitleMetadataError: String?
    @ObservationIgnored private var subtitleMetadataTask: Task<Void, Never>?
    @ObservationIgnored private var subtitleMetadataGeneration = UUID()
    @ObservationIgnored private var subtitleChange: Task<Void, Never>?
    @ObservationIgnored private var subtitleGeneration = UUID()
    @ObservationIgnored private var mountedPresentationID: UUID?
    @ObservationIgnored private var dismissalWaiters: [UUID: (presentation: UUID, continuation: CheckedContinuation<Void, Never>)] = [:]
    @ObservationIgnored private var dismissalTimeouts: [UUID: Task<Void, Never>] = [:]
    var error: String?
    var quality = StreamQuality(rawValue: UserDefaults.standard.integer(forKey: "streamQuality")) ?? .original {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "streamQuality") }
    }

    init(session: Session = Session(), browsePreferences: BrowsePreferencesStore = .shared) {
        self.session = session
        removedBrowseCleanup = RemovedBrowsePreferencesCleanup(store: browsePreferences)
        removedBrowseCleanup.install(on: session)
    }

    func activated() async {
        let interruptedSubtitleChange = changingSubtitles
        cancelSubtitleChange()
        if interruptedSubtitleChange { playback.stop(); await playback.flushReports() }
        path = []; tab = .home
        session.beforeRemove = { [weak self] account in
            guard let self else { return }
            if account.id == self.session.account?.id { await self.closePlayback() }
            else { await self.playback.flushReports() }
        }
        if let account = session.account, let api = session.api {
            PlaybackReporter.updatePrivacy(api: api)
            await preferences.activate(accountID: account.id, api: api)
            guard !Task.isCancelled, session.account?.id == account.id else { return }
            await playback.retryReports(api: api)
        }
    }

    func detail(_ item: MediaItem) {
        if item.isContainer { openLibrary(parent: item) }
        else { path.append(.detail(item.id)) }
    }

    func openLibrary(category: String? = nil, sort: LibrarySort? = nil, parent: MediaItem? = nil) {
        path.append(.library(TVLibraryDestination(category: category, sort: sort, parent: parent)))
    }

    func play(_ item: MediaItem, sourceID: String? = nil, audio: Int? = nil, subtitle: Int? = nil, fromBeginning: Bool = false) async {
        guard !transitioning, let accountID = session.account?.id else { return }
        let revision = session.revision
        transitioning = true
        defer { transitioning = false }
        await closePlayback()
        guard !Task.isCancelled, mountedPresentationID == nil, session.account?.id == accountID, session.revision == revision else { return }
        playback.present(fromBeginning ? beginning(item) : item, audio: audio, subtitle: subtitle, fromBeginning: fromBeginning, mediaSourceID: sourceID)
        subtitleChoice = subtitle
        presentationID = UUID()
        showingPlayer = true
    }

    func startPlayback(id: UUID) {
        guard presentationID == id, showingPlayer, let api = session.api else { return }
        playback.speed = preferences.playbackRate()
        playback.start(api: api, quality: quality, bitrate: preferences.bitrate(local: quality.rawValue))
        loadSubtitleMetadata()
    }

    func closePlayback(id: UUID? = nil) async {
        guard id == nil || presentationID == id else { return }
        cancelSubtitleChange()
        cancelSubtitleMetadata()
        subtitleChoice = nil; subtitleError = nil
        let currentID = presentationID, accountID = session.account?.id
        let wasPresented = showingPlayer || playback.activeItem != nil
        playback.stop()
        playback.activeItem = nil
        showingPlayer = false
        await playback.flushReports()
        await waitForDismissal(of: currentID)
        if wasPresented, presentationID == currentID, session.account?.id == accountID { session.libraryRevision += 1 }
    }

    func presentationAppeared(id: UUID) {
        guard showingPlayer, presentationID == id else { return }
        mountedPresentationID = id
    }

    func presentationDismissed(id: UUID) {
        guard mountedPresentationID == id else { return }
        mountedPresentationID = nil
        for key in dismissalWaiters.filter({ $0.value.presentation == id }).map(\.key) {
            dismissalTimeouts.removeValue(forKey: key)?.cancel()
            dismissalWaiters.removeValue(forKey: key)?.continuation.resume()
        }
    }

    private func waitForDismissal(of id: UUID) async {
        guard mountedPresentationID == id else { return }
        let key = UUID()
        await withCheckedContinuation { continuation in
            dismissalWaiters[key] = (id, continuation)
            dismissalTimeouts[key] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, let waiter = self.dismissalWaiters.removeValue(forKey: key) else { return }
                self.dismissalTimeouts[key] = nil
                self.error = "The player hasn’t finished closing. Try opening the title again."
                waiter.continuation.resume()
            }
        }
    }

    func retryPlayback(id: UUID? = nil) {
        guard id == nil || presentationID == id, showingPlayer, let api = session.api else { return }
        cancelSubtitleChange()
        subtitleError = nil
        playback.retry(api: api, quality: quality, bitrate: preferences.bitrate(local: quality.rawValue))
    }

    func replayPlayback(id requestedID: UUID? = nil, endedID: UUID? = nil) async {
        guard requestedID == nil || presentationID == requestedID, playback.activeItem != nil,
              showingPlayer, !transitioning, !changingSubtitles, let api = session.api else { return }
        if let endedID { guard playback.endedSessionID == endedID else { return } }
        transitioning = true
        defer { transitioning = false }
        let id = presentationID, accountID = session.account?.id
        await playback.replay(endedID: endedID, api: api, quality: quality, bitrate: preferences.bitrate(local: quality.rawValue))
        guard showingPlayer, presentationID == id, session.account?.id == accountID else { return }
        subtitleChoice = playback.currentSubtitleIndex
    }

    func changeQuality(_ value: StreamQuality, id: UUID? = nil) {
        guard id == nil || (presentationID == id && showingPlayer), !preferences.bitrateLocked, !changingSubtitles else { return }
        quality = value
        retryPlayback()
    }

    var subtitleCatalog: TVSubtitleCatalog { TVSubtitleCatalog(item: subtitleMetadata ?? playback.activeItem, sourceID: playback.currentSourceID) }
    var subtitleSelectionConfirmed: Bool {
        !changingSubtitles && !playback.preparing && !playback.ended && playback.error == nil && playback.player.currentItem?.status == .readyToPlay
    }

    func loadSubtitleMetadata(force: Bool = false) {
        guard showingPlayer, let item = playback.activeItem, let api = session.api, let account = session.account?.id else { return }
        cancelSubtitleMetadata()
        if !force, item.MediaSources != nil { subtitleMetadata = item; return }
        let generation = UUID(), id = presentationID, revision = session.revision
        subtitleMetadataGeneration = generation; subtitleMetadataLoading = true
        subtitleMetadataTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.subtitleMetadataGeneration == generation { self.subtitleMetadataLoading = false; self.subtitleMetadataTask = nil }
            }
            @MainActor func current() -> Bool {
                !Task.isCancelled && self.subtitleMetadataGeneration == generation && self.presentationID == id && self.showingPlayer
                    && self.playback.activeItem?.id == item.id && self.session.account?.id == account && self.session.revision == revision
                    && self.session.api?.server == api.server && self.session.api?.userID == api.userID && self.session.api?.token == api.token
            }
            do {
                let updated = try await api.item(item.id)
                guard current(), updated.id == item.id else { return }
                self.subtitleMetadata = updated
            } catch is CancellationError { }
            catch { if current() { self.subtitleMetadataError = "The subtitle track list couldn’t load. Continue playback, or reload the track list and try again." } }
        }
    }

    func changeSubtitle(_ index: Int?, nativeItem: AVPlayerItem?, catalog expectedCatalog: TVSubtitleCatalog, id: UUID, itemID: String, sourceID: String?) {
        guard let nativeItem, playback.player.currentItem === nativeItem, subtitleCatalog == expectedCatalog,
              presentationID == id, showingPlayer, !transitioning, !changingSubtitles,
              playback.activeItem?.id == itemID, playback.currentSourceID == sourceID else { return }
        guard !playback.preparing, !playback.ended, playback.error == nil,
              nativeItem.status == .readyToPlay,
              var item = playback.activeItem, let sourceID, let api = session.api,
              let accountID = session.account?.id else {
            subtitleError = "Playback isn’t ready to change subtitles. Continue playback and try again."
            return
        }
        let catalog = subtitleCatalog
        guard index == nil || index == -1 || catalog.tracks.contains(where: { $0.index == index }) else {
            subtitleError = catalog.error ?? "This subtitle track is no longer available. Return to Details and choose another track or Off."
            return
        }
        guard index != subtitleChoice else { return }
        let revision = session.revision, generation = UUID()
        if let metadata = subtitleMetadata, metadata.id == item.id { item.MediaSources = metadata.MediaSources }
        subtitleGeneration = generation; changingSubtitles = true; subtitleError = nil
        subtitleChange = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.subtitleGeneration == generation {
                    self.changingSubtitles = false; self.subtitleChange = nil
                }
            }
            do {
                let capturedAudio = try await self.playback.captureCurrentAudioChoice(api: api)
                guard self.ownsSubtitleChange(generation, presentation: id, item: itemID, account: accountID, revision: revision, api: api),
                      self.playback.player.currentItem === nativeItem, self.subtitleCatalog == expectedCatalog,
                      nativeItem.status == .readyToPlay, !self.playback.preparing else { return }
                let audioIntent = try self.playback.audioRestoreIntent(from: capturedAudio)
                let position = self.playback.player.currentTime().seconds
                guard position.isFinite, position >= 0, position < Double(Int64.max) / ticksPerSecond else {
                    throw PlaybackAudioSelection.SelectionError.unavailable
                }
                let paused = self.playback.player.rate == 0, rate = self.playback.speed
                self.playback.stop()
                await self.playback.flushReports()
                guard self.ownsSubtitleChange(generation, presentation: id, item: itemID, account: accountID, revision: revision, api: api) else { return }
                self.playback.present(item, subtitle: index, fromBeginning: true, mediaSourceID: sourceID, audioRestore: audioIntent)
                self.subtitleChoice = index
                self.playback.speed = rate
                self.playback.resumeOnDevice(at: position, api: api, quality: self.quality, bitrate: self.preferences.bitrate(local: self.quality.rawValue), initiallyPaused: paused)
                while self.playback.preparing {
                    try await Task.sleep(for: .milliseconds(50))
                    guard self.ownsSubtitleChange(generation, presentation: id, item: itemID, account: accountID, revision: revision, api: api) else { return }
                }
            } catch {
                guard self.ownsSubtitleChange(generation, presentation: id, item: itemID, account: accountID, revision: revision, api: api) else { return }
                self.subtitleError = (error as? PlaybackAudioSelection.SelectionError)?.localizedDescription
                    ?? PlaybackAudioSelection.SelectionError.unavailable.localizedDescription
            }
        }
    }

    private func ownsSubtitleChange(_ generation: UUID, presentation: UUID, item: String, account: String, revision: UUID, api: JellyfinAPI) -> Bool {
        !Task.isCancelled && subtitleGeneration == generation && presentationID == presentation && showingPlayer
            && playback.activeItem?.id == item && session.account?.id == account && session.revision == revision
            && session.api?.server == api.server && session.api?.userID == api.userID && session.api?.token == api.token
    }

    private func cancelSubtitleChange() {
        subtitleGeneration = UUID(); subtitleChange?.cancel(); subtitleChange = nil
        changingSubtitles = false
    }

    private func cancelSubtitleMetadata() {
        subtitleMetadataGeneration = UUID(); subtitleMetadataTask?.cancel(); subtitleMetadataTask = nil
        subtitleMetadata = nil; subtitleMetadataError = nil; subtitleMetadataLoading = false
    }

    private func beginning(_ item: MediaItem) -> MediaItem {
        var item = item
        if item.UserData == nil { item.UserData = UserData() }
        item.UserData?.PlaybackPositionTicks = 0
        return item
    }

    func setPrivateViewing(_ enabled: Bool) {
        session.privateViewing = enabled
        if let api = session.api { PlaybackReporter.updatePrivacy(api: api) }
    }

    func select(_ account: Account) async {
        guard !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        await closePlayback()
        do { try await session.select(account) }
        catch { self.error = error.localizedDescription }
    }

    func remove(_ account: Account) async {
        guard !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        do {
            try await session.remove(account) { self.preferences.clear(accountID: account.id) }
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor @Observable final class TVDetailStore {
    private(set) var item: MediaItem?
    private(set) var seasons: [MediaItem] = []
    private(set) var episodes: [MediaItem] = []
    /// The episode the server says comes next in this series, if it names one.
    private(set) var nextUp: MediaItem?
    private(set) var loading = false
    private(set) var episodeLoading = false
    private(set) var error: String?
    private(set) var episodeError: String?
    var seasonID = ""
    var sourceID = ""
    var audio: Int?
    var subtitle: Int?
    private var generation = UUID()
    private var episodeGeneration = UUID()
    var selectedSource: MediaSource? { item?.MediaSources?.first(where: { $0.Id == sourceID }) ?? item?.MediaSources?.first }

    func load(id: String, api: JellyfinAPI) async {
        let current = UUID(); generation = current
        userDataGeneration = UUID(); userDataRefreshing = false; userDataError = nil
        episodeGeneration = UUID(); episodeLoading = false; episodeError = nil
        loading = true; error = nil; favoriteError = nil
        item = nil; seasons = []; episodes = []; nextUp = nil; seasonID = ""; sourceID = ""; audio = nil; subtitle = nil
        do {
            let item = try await api.item(id)
            try Task.checkCancellation()
            guard generation == current else { return }
            self.item = item; sourceID = item.MediaSources?.first?.Id ?? ""
            if item.isSeries {
                let page = try await api.page("Shows/\(id)/Seasons")
                try Task.checkCancellation()
                guard generation == current else { return }
                seasons = page.Items; seasonID = seasons.first?.id ?? ""
                async let next = Self.nextUp(seriesID: id, api: api)
                await loadEpisodes(api: api)
                let found = await next
                if generation == current, !Task.isCancelled { nextUp = found }
            }
        } catch is CancellationError { }
        catch { if generation == current { self.error = error.localizedDescription } }
        if generation == current { loading = false }
    }

    func loadEpisodes(api: JellyfinAPI) async {
        guard let item, !seasonID.isEmpty else { episodes = []; return }
        let parent = generation, parentID = item.id, requestedSeason = seasonID
        let current = UUID(); episodeGeneration = current
        episodeLoading = true; episodeError = nil
        episodes = []
        do {
            let page = try await api.page("Shows/\(parentID)/Episodes", query: ["seasonId": requestedSeason, "isMissing": "false"])
            try Task.checkCancellation()
            guard episodeGeneration == current, generation == parent, self.item?.id == parentID, seasonID == requestedSeason else { return }
            episodes = page.Items
        } catch is CancellationError { }
        catch { if episodeGeneration == current { episodeError = error.localizedDescription } }
        if episodeGeneration == current { episodeLoading = false }
    }

    private(set) var userDataRefreshing = false
    private(set) var userDataError: String?
    private var userDataGeneration = UUID()

    /// Refresh only watched/resume/count data. Preserve valid season and all
    /// preplay version/audio/subtitle choices rather than running full load().
    func refreshUserData(api: JellyfinAPI) async {
        guard let existing = item else { return }
        let parentGeneration = generation, parentID = existing.id, selectedSeason = seasonID
        let operation = UUID(); userDataGeneration = operation
        userDataRefreshing = true; userDataError = nil
        defer { if userDataGeneration == operation { userDataRefreshing = false } }
        do {
            let updated = try await api.item(parentID)
            var freshSeasons: [MediaItem] = [], freshEpisodes: [MediaItem] = [], freshNext: MediaItem?
            if existing.isSeries {
                freshSeasons = try await api.page("Shows/\(parentID)/Seasons").Items
                if !selectedSeason.isEmpty {
                    freshEpisodes = try await api.page("Shows/\(parentID)/Episodes", query: ["seasonId": selectedSeason, "isMissing": "false"]).Items
                }
                freshNext = await Self.nextUp(seriesID: parentID, api: api)
            }
            guard !Task.isCancelled, userDataGeneration == operation, generation == parentGeneration,
                  item?.id == parentID, updated.id == parentID, seasonID == selectedSeason else { return }
            item?.UserData = updated.UserData
            if existing.isSeries { nextUp = freshNext }
            let seasonsByID = Dictionary(freshSeasons.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let episodesByID = Dictionary(freshEpisodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            seasons = seasons.map { old in var value = old; value.UserData = seasonsByID[old.id]?.UserData; return value }
            episodes = episodes.map { old in var value = old; value.UserData = episodesByID[old.id]?.UserData; return value }
        } catch is CancellationError { }
        catch {
            if userDataGeneration == operation, generation == parentGeneration, item?.id == parentID, seasonID == selectedSeason {
                userDataError = "Watched status and counts couldn’t refresh. They may be out of date."
            }
        }
    }

    /// Some servers answer Next Up for every series even when asked for one, so only an episode of this
    /// series counts. Without one the page keeps Episodes as its first action, so a failure is not an error here.
    private static func nextUp(seriesID: String, api: JellyfinAPI) async -> MediaItem? {
        guard let page = try? await api.page("Shows/NextUp", query: ["seriesId": seriesID]) else { return nil }
        return page.Items.first { $0.Type == "Episode" && $0.SeriesId == seriesID }
    }

    func chooseSource(_ value: String) { sourceID = value; audio = nil; subtitle = nil }

    private(set) var favoriteSaving = false
    private(set) var favoriteError: String?

    /// Same contract as the iPhone and iPad details screen: an accepted change updates this title,
    /// then invalidates dependent lists so the user-data refresh reads the server's value back.
    func toggleFavorite(session: Session) async {
        guard !favoriteSaving, let existing = item, let api = session.api, let account = session.account else { return }
        let revision = session.revision, parentGeneration = generation, value = !existing.isFavorite
        favoriteSaving = true; favoriteError = nil
        defer { favoriteSaving = false }
        do {
            try await api.favorite(existing.id, value: value)
            guard session.account?.id == account.id, session.revision == revision,
                  generation == parentGeneration, item?.id == existing.id else { return }
            if item?.UserData == nil { item?.UserData = UserData() }
            item?.UserData?.IsFavorite = value
            session.invalidateCatalogue(accountID: account.id, revision: revision)
        } catch {
            guard session.account?.id == account.id, session.revision == revision, generation == parentGeneration else { return }
            favoriteError = error.localizedDescription
        }
    }
}
