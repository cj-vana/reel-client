import AVKit
import Observation
import SwiftUI

struct TVPlayerScreen: View {
    @Environment(TVCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var phase
    @State private var id: UUID
    @State private var episodes = TVEpisodePlayback()

    init(id: UUID) { _id = State(initialValue: id) }

    var body: some View {
        ZStack {
            Color.reelBackground.ignoresSafeArea()
            TVNativePlayer(coordinator: coordinator, presentationID: id, episodes: episodes).ignoresSafeArea()
        }
        .task {
            coordinator.startPlayback(id: id)
            episodes.active = phase == .active
            await episodes.load(owner: coordinator, presentation: id)
        }
        .onChange(of: phase) { _, value in episodes.active = value == .active }
        .onAppear { coordinator.presentationAppeared(id: id) }
    }
}

private struct TVPlaybackStatus: View {
    let coordinator: TVCoordinator
    let id: UUID
    let episodes: TVEpisodePlayback

    var body: some View {
        ZStack {
            if coordinator.playback.preparing || coordinator.playback.restartingEnded || coordinator.changingSubtitles {
                VStack(spacing: 25) { ProgressView(); Text("Starting playback…").font(.title2); Button("Back to library") { close() }.accessibilityIdentifier("cancelPreparing") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.reelBackground.opacity(0.85)).accessibilityElement(children: .contain).accessibilityIdentifier("playerPreparing")
            }
            if let error = coordinator.playback.error {
                VStack(spacing: 25) {
                    Text("This title couldn’t play.").font(.title2.bold())
                    Text(error).foregroundStyle(Color.tvMuted).multilineTextAlignment(.center).frame(maxWidth: 900)
                    Button("Retry from saved position") { coordinator.retryPlayback(id: id) }.accessibilityIdentifier("retryPlayer")
                    Button("Back to library") { close() }.accessibilityIdentifier("closePlayer")
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.reelBackground.opacity(0.95))
            }
            if coordinator.playback.ended && !coordinator.playback.restartingEnded && !episodes.browserPresented {
                // This overlay has its own hosting controller; the Up Next artwork reads the session from the environment.
                endedCard(endedID: coordinator.playback.endedSessionID).environment(coordinator.session)
            }
            if let error = coordinator.subtitleError {
                VStack(spacing: 25) {
                    Text("Subtitles couldn’t change.").font(.title2.bold()).accessibilityIdentifier("subtitleMenuError")
                    Text(error).foregroundStyle(Color.tvMuted).multilineTextAlignment(.center).frame(maxWidth: 900)
                    Button("Continue playback") { coordinator.subtitleError = nil }.accessibilityIdentifier("continueAfterSubtitleError")
                    Button("Reload subtitle tracks") { coordinator.subtitleError = nil; coordinator.loadSubtitleMetadata(force: true) }.accessibilityIdentifier("reloadSubtitleTracks")
                    Button("Back to library") { close() }.accessibilityIdentifier("closePlayer")
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.reelBackground.opacity(0.95))
            }
            if episodes.browserPresented { TVPlayerEpisodeBrowser(store: episodes).environment(coordinator.session) }
        }
        .onExitCommand { if episodes.browserPresented { episodes.closeBrowser() } else { close() } }
        .preferredColorScheme(.dark)
        .tint(Color.reelText)
    }

    /// The end of a title: the last frame stays visible and an Up Next card sits bottom right,
    /// where the remote's focus lands on its first action. With nothing to follow, the card names the
    /// title that ended and is only as wide as its actions.
    private func endedCard(endedID: UUID?) -> some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(stops: [.init(color: .clear, location: 0.2), .init(color: Color.reelBackground.opacity(0.94), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                Text(episodes.next == nil ? "Finished watching" : "Up next").font(.system(size: 24, weight: .semibold)).foregroundStyle(Color.tvMuted)
                if let next = episodes.next {
                    TVArtwork(item: next.thumbnailItem, backdrop: true, width: 800)
                        .aspectRatio(16.0 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: TVLayout.artworkRadius, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(next.Name).font(.system(size: 34, weight: .bold)).tracking(-0.4).foregroundStyle(Color.reelText).lineLimit(2)
                        let context = [next.SeriesName, TVMetadata.episodeLabel(next)].compactMap { $0 }.filter { !$0.isEmpty }
                        if !context.isEmpty {
                            Text(context.joined(separator: " · ")).font(.system(size: 24)).foregroundStyle(Color.tvMuted).lineLimit(1)
                        }
                    }
                    if let remaining = episodes.countdown.remaining {
                        Text("Playing in \(remaining) seconds").font(.system(size: 24, weight: .medium)).monospacedDigit()
                            .foregroundStyle(Color.reelText).accessibilityIdentifier("nextEpisodeCountdown")
                    }
                    HStack(spacing: 20) {
                        Button { episodes.play(next) } label: { Label("Play next episode", systemImage: "play.fill") }
                            .disabled(coordinator.transitioning || episodes.switching).accessibilityIdentifier("playNextEpisode")
                        if episodes.countdown.remaining != nil {
                            Button("Cancel") { episodes.cancelAutoplay() }
                                .accessibilityLabel("Cancel automatic playback").accessibilityIdentifier("cancelNextEpisode")
                        }
                    }.focusSection()
                } else if let ended = coordinator.playback.activeItem {
                    Text(ended.Type == "Episode" ? ended.Name : ended.title).font(.system(size: 34, weight: .bold)).tracking(-0.4)
                        .foregroundStyle(Color.reelText).lineLimit(2)
                }
                HStack(spacing: 20) {
                    if episodes.isEpisode {
                        Button("Episodes") { episodes.openBrowser() }.accessibilityLabel("Browse episodes").accessibilityIdentifier("browseEndedEpisodes")
                    }
                    Button("Play again") { episodes.cancelAutoplay(); Task { await coordinator.replayPlayback(id: id, endedID: endedID) } }
                        .disabled(coordinator.transitioning).accessibilityIdentifier("replay")
                    Button("Back to library") { close() }.accessibilityIdentifier("closePlayer")
                }.focusSection()
            }
            .font(.system(size: 24, weight: .semibold))
            .frame(width: episodes.next == nil ? nil : 680, alignment: .leading)
            .padding(36)
            .background(Color.reelSurface.opacity(0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.trailing, TVLayout.margin).padding(.bottom, 72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func close() { Task { await coordinator.closePlayback(id: id) } }
}

struct TVNativePlayer: UIViewControllerRepresentable {
    let coordinator: TVCoordinator
    let presentationID: UUID
    let episodes: TVEpisodePlayback

    func makeCoordinator() -> Coordinator { Coordinator(owner: coordinator, presentationID: presentationID) }

    func makeUIViewController(context: Context) -> TVPlayerPresenter {
        let controller = AVPlayerViewController()
        controller.player = coordinator.playback.player
        controller.delegate = context.coordinator
        controller.showsPlaybackControls = true
        // The custom Speed menu owns rate changes and imported rate locks.
        controller.speeds = []
        controller.allowedSubtitleOptionLanguages = []
        controller.allowsPictureInPicturePlayback = false
        controller.appliesPreferredDisplayCriteriaAutomatically = true
        controller.videoGravity = .resizeAspect
        let presenter = TVPlayerPresenter(playerController: controller, owner: coordinator, presentationID: presentationID, episodes: episodes)
        let cache = context.coordinator
        presenter.onPlaybackChange = { [weak owner = coordinator, weak cache] in
            guard let owner, let cache else { return }
            Self.configure(controller, owner: owner, presentationID: presentationID, episodes: episodes, cache: cache)
        }
        update(presenter, context: context)
        return presenter
    }

    func updateUIViewController(_ presenter: TVPlayerPresenter, context: Context) { update(presenter, context: context) }

    static func dismantleUIViewController(_ presenter: TVPlayerPresenter, coordinator: Coordinator) {
        presenter.invalidate()
        coordinator.requestClose()
    }

    private func update(_ presenter: TVPlayerPresenter, context: Context) {
        presenter.refreshPlayback()
    }

    @MainActor private static func configure(_ controller: AVPlayerViewController, owner coordinator: TVCoordinator, presentationID: UUID, episodes: TVEpisodePlayback, cache: Coordinator) {
        guard coordinator.presentationID == presentationID, coordinator.showingPlayer else { return }
        let item = coordinator.playback.activeItem
        let currentItem = coordinator.playback.player.currentItem
        let currentID = currentItem.map(ObjectIdentifier.init)
        let format = PlaybackFormat.describe(source: coordinator.playback.currentMediaSource, method: coordinator.playback.method, audio: coordinator.playback.currentAudioDisclosure)
        let formatDescription = [format.source, format.delivery, format.output, format.warning].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if currentItem == nil { cache.metadataItem = nil; cache.signature = "" }
        if let currentItem, let item, cache.metadataItem !== currentItem || cache.metadataFormat != formatDescription {
            func metadata(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
                let entry = AVMutableMetadataItem()
                entry.identifier = identifier; entry.value = value as NSString; entry.extendedLanguageTag = "und"
                return entry
            }
            currentItem.externalMetadata = [metadata(.commonIdentifierTitle, item.title), metadata(.iTunesMetadataTrackSubTitle, item.subtitle), metadata(.commonIdentifierDescription, [item.Overview ?? "", formatDescription].filter { !$0.isEmpty }.joined(separator: "\n\n"))]
            cache.metadataItem = currentItem
            cache.metadataFormat = formatDescription
            cache.signature = ""
        }
        let signature = "\(coordinator.quality.rawValue)|\(coordinator.playback.speed)|\(item?.id ?? "")|\(coordinator.preferences.bitrateLocked)|\(coordinator.preferences.rateLocked)|\(String(describing: currentID))|\(coordinator.playback.currentSourceID ?? "")|\(String(describing: coordinator.subtitleChoice))|\(coordinator.subtitleSelectionConfirmed)|\(coordinator.changingSubtitles)|\(coordinator.subtitleMetadataLoading)|\(coordinator.subtitleMetadata?.hashValue ?? 0)|\(coordinator.subtitleMetadataError ?? "")|\(episodes.previous?.id ?? "")|\(episodes.next?.id ?? "")|\(episodes.intro?.id ?? "")|\(episodes.autoplay)|\(episodes.isEpisode)|\(episodes.switching)"
        guard signature != cache.signature else { return }
        cache.signature = signature
        let quality = UIMenu(title: "Quality", image: UIImage(systemName: "slider.horizontal.3"), children: StreamQuality.allCases.map { value in
            UIAction(title: value.label, attributes: coordinator.preferences.bitrateLocked || coordinator.changingSubtitles ? .disabled : [], state: coordinator.quality == value ? .on : .off) { _ in coordinator.changeQuality(value, id: presentationID) }
        })
        let speed = UIMenu(title: "Speed", image: UIImage(systemName: "speedometer"), children: [Float(0.75), 1, 1.25, 1.5, 2].map { value in
            UIAction(title: "\(value.formatted())×", attributes: coordinator.preferences.rateLocked || coordinator.changingSubtitles ? .disabled : [], state: coordinator.playback.speed == value ? .on : .off) { _ in
                guard coordinator.presentationID == presentationID, coordinator.showingPlayer, !coordinator.changingSubtitles else { return }
                coordinator.playback.speed = value
            }
        })
        var menus: [UIMenuElement] = [quality, speed]
        if episodes.intro != nil {
            menus.insert(UIAction(title: "Skip intro", image: UIImage(systemName: "forward.end")) { _ in episodes.skipIntro() }, at: 0)
        }
        if episodes.isEpisode {
            let enabled = !coordinator.transitioning && !coordinator.changingSubtitles && !episodes.switching
            menus.append(UIAction(title: "Previous episode", image: UIImage(systemName: "backward.end.fill"), attributes: enabled && episodes.previous != nil ? [] : .disabled) { _ in
                if let previous = episodes.previous { episodes.play(previous) }
            })
            menus.append(UIAction(title: "Next episode", image: UIImage(systemName: "forward.end.fill"), attributes: enabled && episodes.next != nil ? [] : .disabled) { _ in
                if let next = episodes.next { episodes.play(next) }
            })
            menus.append(UIAction(title: "Episodes", image: UIImage(systemName: "rectangle.stack"), attributes: enabled ? [] : .disabled) { _ in episodes.openBrowser() })
        }
        controller.contextualActions = episodes.intro == nil ? [] : [UIAction(title: "Skip intro", image: UIImage(systemName: "forward.end")) { _ in episodes.skipIntro() }]
        if let chapters = item?.Chapters, !chapters.isEmpty {
            menus.append(UIMenu(title: "Chapters", image: UIImage(systemName: "list.bullet.rectangle"), children: chapters.enumerated().map { index, chapter in
                UIAction(title: chapter.Name ?? "Chapter \(index + 1)", attributes: coordinator.changingSubtitles ? .disabled : []) { _ in
                    guard coordinator.presentationID == presentationID, coordinator.showingPlayer, !coordinator.changingSubtitles else { return }
                    coordinator.playback.seek(to: chapter.StartPositionTicks)
                }
            }))
        }
        if let item {
            let sourceID = coordinator.playback.currentSourceID
            let catalog = coordinator.subtitleCatalog
            let enabled = coordinator.subtitleSelectionConfirmed && !coordinator.transitioning && !coordinator.subtitleMetadataLoading
            func action(_ title: String, index: Int?) -> UIAction {
                UIAction(title: title, attributes: enabled ? [] : .disabled,
                         state: enabled && coordinator.subtitleChoice == index ? .on : .off) { [weak currentItem] _ in
                    coordinator.changeSubtitle(index, nativeItem: currentItem, catalog: catalog, id: presentationID, itemID: item.id, sourceID: sourceID)
                }
            }
            var choices: [UIMenuElement] = [action("Server default", index: nil), action("Off", index: -1)]
            choices += catalog.tracks.map { action($0.title, index: $0.index) }
            if coordinator.subtitleMetadataLoading {
                choices.append(UIAction(title: "Loading subtitle tracks…", attributes: .disabled) { _ in })
            } else if let error = coordinator.subtitleMetadataError ?? catalog.error {
                choices.append(UIAction(title: "Track list unavailable", image: UIImage(systemName: "exclamationmark.triangle")) { [weak currentItem] _ in
                    guard coordinator.presentationID == presentationID, coordinator.showingPlayer,
                          let currentItem, coordinator.playback.player.currentItem === currentItem, coordinator.subtitleCatalog == catalog,
                          coordinator.playback.activeItem?.id == item.id, coordinator.playback.currentSourceID == sourceID else { return }
                    coordinator.subtitleError = error
                })
            }
            menus.append(UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), children: choices))
        }
        controller.transportBarCustomMenuItems = menus
        controller.infoViewActions = [UIAction(title: "Back to library", image: UIImage(systemName: "arrow.backward")) { _ in Task { await coordinator.closePlayback(id: presentationID) } }]
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var signature = ""
        weak var metadataItem: AVPlayerItem?
        var metadataFormat = ""
        private weak var owner: TVCoordinator?
        private let presentationID: UUID
        init(owner: TVCoordinator, presentationID: UUID) { self.owner = owner; self.presentationID = presentationID }
        func requestClose() {
            let owner = owner, id = presentationID
            Task { @MainActor in await owner?.closePlayback(id: id) }
        }
        func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
            requestClose()
            return false
        }


    }
}

final class TVPlayerPresenter: UIViewController {
    let playerController: AVPlayerViewController
    var onPlaybackChange: (() -> Void)?
    private weak var owner: TVCoordinator?
    private let presentationID: UUID
    private var didPresent = false
    private var invalidated = false
    private var blockingStatus = false
    private var syncMessage: String?
    private var presentingStatus = false
    private var dismissingStatus = false
    private var statusRetry: Task<Void, Never>?
    private let status: UIHostingController<TVPlaybackStatus>
    private let syncLabel = UILabel()
    private let episodes: TVEpisodePlayback

    init(playerController: AVPlayerViewController, owner: TVCoordinator, presentationID: UUID, episodes: TVEpisodePlayback) {
        self.playerController = playerController
        self.owner = owner
        self.presentationID = presentationID
        self.episodes = episodes
        status = UIHostingController(rootView: TVPlaybackStatus(coordinator: owner, id: presentationID, episodes: episodes))
        super.init(nibName: nil, bundle: nil)
        playerController.modalPresentationStyle = .fullScreen
        status.modalPresentationStyle = .overFullScreen
        status.view.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Storyboard construction is unavailable.") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Color.reelBackground)
        if let overlay = playerController.contentOverlayView {
            // AVKit's content overlay is reserved for noninteractive information.
            syncLabel.isUserInteractionEnabled = false
            syncLabel.numberOfLines = 3
            syncLabel.font = .systemFont(ofSize: 22)
            syncLabel.textColor = .white
            syncLabel.textAlignment = .center
            syncLabel.backgroundColor = UIColor(Color.reelBackground).withAlphaComponent(0.9)
            syncLabel.accessibilityIdentifier = "watchSyncMessage"
            syncLabel.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(syncLabel)
            NSLayoutConstraint.activate([
                syncLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                syncLabel.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.8),
                syncLabel.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -45)
            ])
        }
        observePlayback()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !invalidated, !didPresent, !isBeingDismissed,
              owner?.presentationID == presentationID, owner?.showingPlayer == true else { return }
        didPresent = true
        // AVKit enables its interactive tvOS transport UI for a modal presentation.
        present(playerController, animated: false) { [weak self] in self?.reconcileStatus() }
    }

    func refreshPlayback() {
        guard !invalidated, let owner, owner.presentationID == presentationID, owner.showingPlayer else { return }
        let playback = owner.playback
        updateStatus(blocking: playback.preparing || playback.restartingEnded || owner.changingSubtitles || playback.error != nil || playback.ended || owner.subtitleError != nil || episodes.browserPresented, syncMessage: playback.audioSelectionError ?? playback.syncError)
        onPlaybackChange?()
    }

    private func observePlayback() {
        guard !invalidated, let owner, owner.presentationID == presentationID, owner.showingPlayer else { return }
        // The SwiftUI cover can be offscreen behind modal AVKit. Keep the native
        // presentation responsive to EOF, errors and retries in its own lifecycle.
        withObservationTracking {
            _ = owner.playback.preparing
            _ = owner.playback.error
            _ = owner.playback.ended
            _ = owner.playback.restartingEnded
            _ = owner.playback.syncError
            _ = owner.playback.audioSelectionError
            _ = owner.playback.activeItem
            _ = owner.playback.currentMediaSource
            _ = owner.playback.currentAudioDisclosure
            _ = owner.changingSubtitles
            _ = owner.subtitleChoice
            _ = owner.subtitleError
            _ = owner.subtitleMetadataLoading
            _ = owner.subtitleMetadata
            _ = owner.subtitleMetadataError
            _ = owner.playback.speed
            _ = owner.quality
            _ = owner.preferences.bitrateLocked
            _ = owner.preferences.rateLocked
            _ = episodes.previous
            _ = episodes.next
            _ = episodes.intro
            _ = episodes.autoplay
            _ = episodes.isEpisode
            _ = episodes.switching
            _ = episodes.browserPresented
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observePlayback() }
        }
        refreshPlayback()
    }

    private func updateStatus(blocking: Bool, syncMessage: String?) {
        blockingStatus = blocking
        self.syncMessage = syncMessage
        guard isViewLoaded else { return }
        syncLabel.text = syncMessage
        syncLabel.isHidden = syncMessage == nil
        reconcileStatus()
    }

    private func reconcileStatus() {
        guard !invalidated, didPresent, !playerController.isBeingDismissed,
              owner?.presentationID == presentationID, owner?.showingPlayer == true,
              playerController.presentingViewController != nil,
              !presentingStatus, !dismissingStatus else { return }
        if blockingStatus {
            guard status.presentingViewController == nil else { return }
            guard playerController.presentedViewController == nil else { retryStatusAfterNativeTransition(); return }
            presentingStatus = true
            // A separate modal owns remote focus for Retry/Back/Play again.
            playerController.present(status, animated: false) { [weak self] in
                guard let self else { return }
                self.presentingStatus = false
                self.reconcileStatus()
            }
        } else if status.presentingViewController != nil {
            dismissingStatus = true
            status.dismiss(animated: false) { [weak self] in
                guard let self else { return }
                self.dismissingStatus = false
                self.reconcileStatus()
            }
        }
    }

    private func retryStatusAfterNativeTransition() {
        guard statusRetry == nil else { return }
        statusRetry = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self else { return }
            self.statusRetry = nil
            self.reconcileStatus()
        }
    }

    func invalidate() {
        invalidated = true
        statusRetry?.cancel(); statusRetry = nil
        onPlaybackChange = nil
        playerController.delegate = nil
        playerController.player = nil
        episodes.invalidate()
    }
}
