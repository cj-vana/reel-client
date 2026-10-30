import SwiftUI
import AVKit
import MediaPlayer

/// Where the picture and Reel's controls go, as plain geometry so the foldable postures can be
/// tested without the hardware. A book-style foldable reports its fold as a division region: a
/// horizontal band when it stands half open like a laptop (tabletop), a vertical band when it is
/// held half open like a book.
struct PlayerStage: Equatable {
    enum Posture: Equatable { case flat, tabletop, book }
    var posture: Posture
    /// The picture's frame. The layer letterboxes the video inside it.
    var video: CGRect
    /// Tabletop: the panel under the fold that holds the controls.
    var panel: CGRect?
    /// Book: the fold, which the transport and the pills keep clear of.
    var fold: CGRect?

    /// A split with a shorter picture or panel than this helps neither, so the fold is ignored.
    static let minimumVideoHeight: CGFloat = 180
    static let minimumPanelHeight: CGFloat = 200

    /// - Parameter divisions: the active division regions, in the container's coordinates.
    static func resolve(container: CGSize, divisions: [CGRect]) -> PlayerStage {
        let bounds = CGRect(origin: .zero, size: container)
        for division in divisions {
            let band = division.intersection(bounds)
            guard !band.isNull else { continue }
            if band.width >= container.width * 0.9, band.width > band.height {
                let panelHeight = container.height - band.maxY
                guard band.minY >= minimumVideoHeight, panelHeight >= minimumPanelHeight else { continue }
                return PlayerStage(posture: .tabletop,
                                   video: CGRect(x: 0, y: 0, width: container.width, height: band.minY),
                                   panel: CGRect(x: 0, y: band.maxY, width: container.width, height: panelHeight))
            }
            if band.height >= container.height * 0.9, band.height > band.width {
                return PlayerStage(posture: .book, video: bounds, fold: band)
            }
        }
        return PlayerStage(posture: .flat, video: bounds)
    }

    /// The transport's center: the middle of the picture. Held like a book, the picture spans
    /// both pages and the person faces the whole screen, so the transport stays centered on it;
    /// only the header keeps its two groups on their own pages.
    var transportCenter: CGPoint { CGPoint(x: video.midX, y: video.midY) }
}

/// The picture, drawn by an AVPlayerLayer this view owns. AVPlayerViewController exposes neither
/// its layer nor a way to start picture in picture, and its own controls would sit on top of
/// Reel's, so the player draws the one set of controls itself.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let pictureInPicture: PictureInPicture
    var allowsPictureInPicture: Bool
    /// Fills the view and crops the picture's edges, instead of showing it whole with bars.
    var fills = false

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
        view.playerLayer.player = player
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Video"
        view.accessibilityIdentifier = "nativePlayer"
        pictureInPicture.attach(view.playerLayer)
        pictureInPicture.allowed = allowsPictureInPicture
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        let gravity: AVLayerVideoGravity = fills ? .resizeAspectFill : .resizeAspect
        if view.playerLayer.videoGravity != gravity { view.playerLayer.videoGravity = gravity }
        pictureInPicture.allowed = allowsPictureInPicture
    }
}

/// Picture in picture for the player's own layer: from Reel's button, or on its own when the
/// app leaves the foreground during playback.
@MainActor @Observable final class PictureInPicture {
    private(set) var isPossible = false
    private(set) var isActive = false
    @ObservationIgnored var allowed = true {
        didSet {
            controller?.canStartPictureInPictureAutomaticallyFromInline = allowed
            if !allowed { stop() }
        }
    }
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    func attach(_ layer: AVPlayerLayer) {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        controller.canStartPictureInPictureAutomaticallyFromInline = allowed
        // KVO can report from any thread; each change hops to the main actor.
        observations = [
            controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { @Sendable [weak self] observed, _ in
                let possible = observed.isPictureInPicturePossible
                Task { @MainActor in self?.isPossible = possible }
            },
            controller.observe(\.isPictureInPictureActive, options: [.initial, .new]) { @Sendable [weak self] observed, _ in
                let active = observed.isPictureInPictureActive
                Task { @MainActor in self?.isActive = active }
            },
        ]
        self.controller = controller
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
        else if allowed, controller.isPictureInPicturePossible { controller.startPictureInPicture() }
    }

    func stop() {
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
    }
}

/// The lock screen and Control Center for video. AVPlayerViewController published these by
/// itself; with Reel drawing the controls, the player publishes them here.
@MainActor final class VideoNowPlaying {
    private var session: MPNowPlayingSession?
    private var targets: [(MPRemoteCommand, Any)] = []

    func begin(_ playback: PlaybackController, back: Int, forward: Int) {
        guard session == nil else { return }
        let session = MPNowPlayingSession(players: [playback.player])
        session.automaticallyPublishesNowPlayingInfo = true
        let commands = session.remoteCommandCenter
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: back)]
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: forward)]
        add(commands.togglePlayPauseCommand) { playback.togglePause() }
        add(commands.playCommand) { if !playback.isPlaying { playback.togglePause() } }
        add(commands.pauseCommand) { if playback.isPlaying { playback.togglePause() } }
        add(commands.skipBackwardCommand) { playback.skip(-Double(back)) }
        add(commands.skipForwardCommand) { playback.skip(Double(forward)) }
        let position = commands.changePlaybackPositionCommand
        targets.append((position, position.addTarget { @Sendable event in
            guard let seconds = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in playback.seek(to: Int64(seconds * ticksPerSecond)) }
            return .success
        }))
        session.becomeActiveIfPossible { _ in }
        self.session = session
    }

    /// The title and series of what is playing, added to what the session publishes on its own.
    func describe(_ item: MediaItem, on player: AVPlayer) {
        player.currentItem?.nowPlayingInfo = [MPMediaItemPropertyTitle: item.Name, MPMediaItemPropertyArtist: item.subtitle]
    }

    func end() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        session = nil
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable () -> Void) {
        targets.append((command, command.addTarget { @Sendable _ in
            Task { @MainActor in action() }
            return .success
        }))
    }
}

#if DEBUG
extension EnvironmentValues {
    /// Fold bands for checking the tabletop and book layouts on a simulator that cannot fold.
    @Entry var simulatedFoldDivisions: [CGRect]?
}
#endif

/// Shows the controls while a foldable's hinge moves. The hinge only animates the change; the
/// layout itself comes from the fold's division region.
/// Follows the hinge: records whether it is part way open, and shows the controls when it moves.
private struct RevealOnHingeChange: ViewModifier {
    @Binding var partlyOpen: Bool
    let action: @MainActor () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                partlyOpen = context.hinge?.status == .partiallyOpen
                action()
            }
        } else {
            content
        }
    }
}

struct PlayerView: View {
    let item: MediaItem
    @Environment(Session.self) private var session
    @Environment(PlaybackController.self) private var playback
    @Environment(ServerPreferences.self) private var preferences
    @Environment(SyncPlayClient.self) private var syncPlay
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @Environment(\.simulatedFoldDivisions) private var simulatedFoldDivisions
    #endif
    @AppStorage("streamQuality") private var quality = StreamQuality.original.rawValue
    @AppStorage("autoplayNextEpisode") private var autoplayNextEpisode = true
    /// "fill", "fit", or "auto": fill on a foldable's open screen, whose shape would otherwise
    /// put bars above and below a widescreen picture; fit everywhere else.
    @AppStorage("videoScale") private var videoScale = "auto"
    /// The hinge is part way open, as when the phone stands like a laptop or is held like a book.
    /// Fully open, the screen is one flat surface and the controls are laid out for it.
    @State private var hingePartlyOpen = false
    @State private var showingStreamInformation = false
    @State private var showingEpisodes = false
    @State private var previousEpisode: MediaItem?
    @State private var episodeNavigationError: String?
    @State private var autoplayRemaining: Int?
    @State private var cancelledAutoplaySession: UUID?
    @State private var showingGroup = false
    @State private var showingOptions = false
    @State private var segments: [MediaSegment] = []
    @State private var nextEpisode: MediaItem?
    @State private var chromeVisible = true
    @State private var chromeTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var pictureInPicture = PictureInPicture()
    @State private var nowPlaying = VideoNowPlaying()

    private var effectiveBitrate: Int { playback.currentBitrate ?? preferences.bitrate(local: quality) }

    private var keepsControlsVisible: Bool {
        voiceOverEnabled || dynamicTypeSize.isAccessibilitySize || !playback.isPlaying
            || playback.preparing || playback.ended || playback.error != nil || sheetShown
            || scrubbing || pictureInPicture.isActive
    }
    private var sheetShown: Bool { showingOptions || showingGroup || showingEpisodes }
    private var controlsShown: Bool { chromeVisible || keepsControlsVisible }
    private var showsEndCard: Bool { playback.ended && !playback.restartingEnded }
    private var offersEpisodes: Bool { item.Type == "Episode" && item.SeriesId != nil && playback.method != "Offline" && !playback.syncPlayManaged }

    var body: some View {
        // The outer reader keeps the safe area and reports its insets; the inner one spans the
        // whole screen, where the fold's division region is measured. A reader that ignores
        // the safe area reports no insets, so the controls take them from the outer one.
        GeometryReader { safeArea in
          let insets = safeArea.safeAreaInsets
          GeometryReader { proxy in
            let stage = PlayerStage.resolve(container: proxy.size, divisions: divisions(in: proxy))
            // The picture is always the first child, so a fold or a rotation moves it but never
            // replaces it: the same layer keeps playing through every posture.
            ZStack(alignment: .topLeading) {
                picture(split: stage.panel != nil, insets: insets,
                        fill: videoScale == "fill" || (videoScale == "auto" && stage.panel == nil && hasFold(in: proxy)))
                    .frame(width: stage.video.width, height: stage.video.height)
                    .offset(x: stage.video.minX, y: stage.video.minY)
                if let panel = stage.panel {
                    tabletopPanel(insets: insets)
                        .frame(width: panel.width, height: panel.height)
                        .offset(x: panel.minX, y: panel.minY)
                    if showsEndCard { endCard.frame(width: proxy.size.width, height: proxy.size.height) }
                } else {
                    overlay(stage: stage, insets: insets)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    segmentSkip
                        .padding(.trailing, max(24, insets.trailing + 16))
                        // Clears the timeline while the controls show.
                        .padding(.bottom, max(insets.bottom, 12) + (controlsShown ? 92 : 28))
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controlsShown)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: stage.posture)
            .onChange(of: stage.posture) { _, _ in revealControls() }
          }
          .ignoresSafeArea()
        }
        .background(.black)
        .foregroundStyle(.white)
        .modifier(RevealOnHingeChange(partlyOpen: $hingePartlyOpen, action: revealControls))
        .task(id: playback.activeItem?.id) { start(); await loadNext(); await loadSegments() }
        .onAppear { nowPlaying.begin(playback, back: preferences.rewindSkip(), forward: preferences.forwardSkip()) }
        .onChange(of: playback.preparing) { _, preparing in
            if !preparing { nowPlaying.describe(playback.activeItem ?? item, on: playback.player) }
        }
        .onChange(of: scenePhase) { _, _ in playback.reportPauseState() }
        .onChange(of: keepsControlsVisible) { _, _ in revealControls() }
        .onChange(of: playback.sleepDeadline) { previous, current in
            if let previous, previous <= Date(), current == nil {
                cancelledAutoplaySession = playback.endedSessionID
            }
        }
        .onDisappear {
            chromeTask?.cancel(); nowPlaying.end()
            if !showingOptions && !showingGroup && !showingEpisodes && playback.activeItem?.id == item.id { playback.stop() }
        }
        .task(id: autoplayIdentity) { await countDownToNextEpisode() }
        .sheet(isPresented: $showingEpisodes) {
            NavigationStack {
                PlayerEpisodePicker(current: item) { selected in
                    showingEpisodes = false
                    playback.present(selected)
                }
            }.preferredColorScheme(.dark).presentationBackground(Color.reelBackground)
        }
        .sheet(isPresented: $showingGroup) { NavigationStack { RemoteSessionsView() } }
        .sheet(isPresented: $showingOptions) {
            NavigationStack {
                companion
                    .navigationTitle("Playback options").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingOptions = false } } }
                    // A small screen, such as iPhone Duo's outer screen, otherwise tucks the bar and Done away on scroll.
                    .toolbarMinimizationBehavior(.never, for: .navigationBar)
            }.presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
                .preferredColorScheme(.dark)
                // Opaque at every height, so the picture never shows through below the content.
                .presentationBackground(Color.reelBackground)
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
    }

    private func divisions(in proxy: GeometryProxy) -> [CGRect] {
        #if DEBUG
        if let simulatedFoldDivisions { return simulatedFoldDivisions }
        #endif
        // A fully open screen still reports its crease as active, so the hinge decides.
        guard hingePartlyOpen, #available(iOS 27.1, *) else { return [] }
        return proxy.reservedRegions(kind: .division).filter(\.isActive).map(\.frame)
    }

    /// A foldable's open screen, folded or flat: it reports its crease even when inactive.
    private func hasFold(in proxy: GeometryProxy) -> Bool {
        #if DEBUG
        if simulatedFoldDivisions != nil { return true }
        #endif
        guard #available(iOS 27.1, *) else { return false }
        return !proxy.reservedRegions(kind: .division, options: .includeInactive).isEmpty
    }

    // MARK: Picture

    /// The video and what belongs to it: the loading and error states, notices, and in the
    /// flat layouts the end-of-playback card under the controls.
    private func picture(split: Bool, insets: EdgeInsets, fill: Bool) -> some View {
        ZStack {
            PlayerSurface(player: playback.player, pictureInPicture: pictureInPicture, allowsPictureInPicture: !playback.syncPlayManaged, fills: fill)
                .accessibilityAction(named: fill ? "Show the whole picture" : "Fill the screen") { videoScale = fill ? "fit" : "fill" }
            // A tap on the picture shows or hides the controls, or wakes the tabletop panel. A
            // double tap or a pinch switches between filling the screen and the whole picture.
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { videoScale = fill ? "fit" : "fill" }
                .onTapGesture { pictureTapped(split: split) }
                .gesture(MagnifyGesture().onEnded { value in
                    if value.magnification > 1.1, !fill { videoScale = "fill" }
                    else if value.magnification < 0.9, fill { videoScale = "fit" }
                })
            if pictureInPicture.isActive {
                notice("Playing in picture in picture", systemImage: "pip")
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if playback.player.isExternalPlaybackActive { notice("Playing on AirPlay", systemImage: "airplayvideo") }
                }
            }
            if playback.preparing || playback.restartingEnded {
                VStack(spacing: 14) { ProgressView(); Text("Setting the scene…").font(.system(size: 13)).foregroundStyle(Color.reelMuted) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.8))
            }
            if let error = playback.error {
                VStack(spacing: 14) {
                    FailureView(message: error, retry: { retry() })
                    if effectiveBitrate != StreamQuality.original.rawValue && !preferences.bitrateLocked {
                        Button("Play at Original quality") { quality = StreamQuality.original.rawValue; retry(original: true) }.buttonStyle(QuietButton()).accessibilityIdentifier("originalQualityRecovery").padding(.bottom, 24)
                    }
                }
                .padding(.top, split ? 0 : insets.top + 56)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            }
            VStack(spacing: 8) {
                Spacer()
                if let audioError = playback.audioSelectionError { Text(audioError).accessibilityIdentifier("audioSelectionError") }
                if let syncError = playback.syncError { Text(syncError).accessibilityIdentifier("syncError") }
            }
            .font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
            .padding(.horizontal, 24).padding(.bottom, split ? 16 : 140).allowsHitTesting(false)
            if !split && showsEndCard { endCard }
        }
        .clipped()
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 34, weight: .regular))
            Text(text).font(.subheadline.weight(.medium))
        }
        .foregroundStyle(Color.reelMuted).accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    private func pictureTapped(split: Bool) {
        if split || !chromeVisible || keepsControlsVisible { revealControls(); return }
        chromeTask?.cancel()
        chromeVisible = false
    }

    // MARK: Controls over the picture

    /// Closed, open flat and book postures: the controls float over the picture and fade
    /// after a few seconds of playback.
    private func overlay(stage: PlayerStage, insets: EdgeInsets) -> some View {
        // Each edge keeps its own inset: a foldable's outer screen reserves a strip on one side only.
        let leading = max(20, insets.leading + 8), trailing = max(20, insets.trailing + 8)
        return ZStack(alignment: .top) {
            // Faded controls leave the hierarchy entirely: glass buttons kept at zero
            // opacity stayed reachable to VoiceOver and to taps.
            if controlsShown {
                ZStack(alignment: .top) {
                    // Shades keep the controls legible over a bright picture; they take no touches.
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).frame(height: insets.top + 140)
                        Spacer(minLength: 0)
                        if !showsEndCard {
                            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: insets.bottom + 170)
                        }
                    }.allowsHitTesting(false)
                    VStack(spacing: 0) {
                        header(fold: stage.fold, width: stage.video.width, leading: leading, trailing: trailing)
                            .padding(.top, insets.top + 10)
                        Spacer(minLength: 0)
                        // At the end the card under these controls offers what comes next; only the header stays.
                        if !showsEndCard {
                            timeline.padding(.leading, leading).padding(.trailing, trailing).padding(.bottom, max(insets.bottom, 12) + 4)
                        }
                    }
                    if !showsEndCard { transport.position(stage.transportCenter) }
                }
                .transition(.opacity)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { revealControls() })
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controlsShown)
    }

    /// Close and title on the leading side, route and sheet buttons on the trailing side. Held
    /// like a book, each group stays on its own page; otherwise the buttons carry their names
    /// when everything fits on one line.
    @ViewBuilder private func header(fold: CGRect?, width: CGFloat, leading: CGFloat, trailing: CGFloat) -> some View {
        if let fold {
            HStack(spacing: 0) {
                HStack(spacing: 12) { closeButton; titleBlock }
                    .frame(width: max(0, fold.minX - leading - 8), alignment: .leading)
                Spacer(minLength: fold.width + 16)
                HStack(spacing: 10) { routeButtons; sheetButtons(labels: false) }
                    .frame(width: max(0, width - fold.maxX - trailing - 8), alignment: .trailing)
            }
            .padding(.leading, leading).padding(.trailing, trailing)
        } else {
            // Names on the buttons when everything fits, then icons, then (narrow portrait
            // screens such as a foldable's outer one) the title on its own line below.
            ViewThatFits(in: .horizontal) {
                headerRow(labels: true)
                headerRow(labels: false)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        closeButton
                        Spacer(minLength: 12)
                        routeButtons; sheetButtons(labels: false)
                    }
                    titleBlock.padding(.leading, 4)
                }
            }
            .padding(.leading, leading).padding(.trailing, trailing)
        }
    }

    private func headerRow(labels: Bool) -> some View {
        HStack(spacing: 12) {
            closeButton
            titleBlock
            Spacer(minLength: 12)
            HStack(spacing: 10) { routeButtons; sheetButtons(labels: labels) }
        }
    }

    // MARK: Tabletop panel

    /// Folded with the hinge across the screen: the picture keeps the top half and every
    /// control moves to this panel, which stays put and dims after a few idle seconds.
    private func tabletopPanel(insets: EdgeInsets) -> some View {
        let leading = max(24, insets.leading + 12), trailing = max(24, insets.trailing + 12)
        return VStack(spacing: 14) {
            HStack(spacing: 12) {
                closeButton
                titleBlock
                Spacer(minLength: 12)
                HStack(spacing: 10) { routeButtons }
            }
            timeline
            HStack(spacing: 16) {
                HStack(spacing: 10) {
                    segmentSkip
                    nextEpisodeButton
                }.frame(maxWidth: .infinity, alignment: .leading)
                transport
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { sheetButtons(labels: true) }
                    HStack(spacing: 10) { sheetButtons(labels: false) }
                }.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.leading, leading).padding(.trailing, trailing)
        .padding(.top, 14).padding(.bottom, max(insets.bottom, 12))
        .opacity(controlsShown ? 1 : 0.35)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: controlsShown)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.reelBackground)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { revealControls() })
        .accessibilityIdentifier("playerTabletopPanel")
    }

    // MARK: Shared controls

    private var closeButton: some View {
        Button { close() } label: {
            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle)
        .accessibilityLabel("Close player").accessibilityIdentifier("closePlayer")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.headline).lineLimit(1)
            if item.Type == "Episode" { Text(item.subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.72)).lineLimit(1) }
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier("playerTitle")
        .shadow(color: .black.opacity(0.4), radius: 6)
        // Takes its width before the spacer beside it, and truncates only when the row is full.
        .layoutPriority(1)
    }

    /// AirPlay and picture in picture, which AVKit's own controls used to offer.
    @ViewBuilder private var routeButtons: some View {
        if !playback.syncPlayManaged {
            AirPlayRouteButton(tint: .white, activeTint: UIColor(Color.reelBlue))
                .frame(width: 44, height: 44)
                .glassEffect(in: Circle())
                .accessibilityIdentifier("playerAirPlay")
            if pictureInPicture.isPossible || pictureInPicture.isActive {
                Button { pictureInPicture.toggle() } label: {
                    Image(systemName: pictureInPicture.isActive ? "pip.exit" : "pip.enter")
                        .font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .accessibilityLabel(pictureInPicture.isActive ? "Exit picture in picture" : "Picture in picture")
                .accessibilityIdentifier("playerPictureInPicture")
            }
        }
    }

    @ViewBuilder private func sheetButtons(labels: Bool) -> some View {
        if playback.syncPlayManaged {
            Button { showingGroup = true } label: { headerLabel("Group", systemImage: "person.2.wave.2", labels: labels) }
                .buttonStyle(.glass).accessibilityLabel("Group controls").accessibilityIdentifier("groupControls")
        }
        if offersEpisodes {
            Button { showingEpisodes = true } label: { headerLabel("Episodes", systemImage: "rectangle.stack", labels: labels) }
                .buttonStyle(.glass).accessibilityLabel("Episodes").accessibilityIdentifier("playerEpisodes")
        }
        Button { showingOptions = true } label: { headerLabel("Playback options", systemImage: "slider.horizontal.3", labels: labels) }
            .buttonStyle(.glass).accessibilityLabel("Playback options").accessibilityIdentifier("playbackOptions")
    }

    @ViewBuilder private func headerLabel(_ title: String, systemImage: String, labels: Bool) -> some View {
        if labels {
            // Never truncated: when the names don't fit, the row switches to icons.
            Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold)).fixedSize().frame(minHeight: 44)
        } else {
            Image(systemName: systemImage).font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
        }
    }

    /// The transport's sizes; the book posture keeps its whole width clear of the fold.
    enum TransportMetrics {
        static let skip: CGFloat = 52
        static let play: CGFloat = 68
        static let spacing: CGFloat = 30
        static var width: CGFloat { skip * 2 + play + spacing * 2 }
    }

    /// Skip back, play or pause, skip forward. The same three buttons sit over the picture and
    /// in the tabletop panel; the options sheet keeps its own copy for the managed group player.
    private var transport: some View {
        let back = preferences.rewindSkip(), forward = preferences.forwardSkip()
        return HStack(spacing: TransportMetrics.spacing) {
            skipButton(seconds: -back)
            Button { playback.togglePause(); revealControls() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .semibold)).frame(width: TransportMetrics.play, height: TransportMetrics.play)
                    .background(Color.reelText, in: Circle()).foregroundStyle(Color.reelBackground)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            // Group playback has always exposed its on-picture play button as the group transport.
            .accessibilityIdentifier(playback.syncPlayManaged ? "transportPlayPause" : "playerPlayPause")
            skipButton(seconds: forward)
        }
        .disabled(playback.preparing || playback.error != nil || playback.ended)
        // Behind an open sheet the sheet's own copy is the one to use.
        .accessibilityHidden(sheetShown)
    }

    private func skipButton(seconds: Int) -> some View {
        let forward = seconds > 0, magnitude = abs(seconds)
        return Button { playback.skip(Double(seconds)); revealControls() } label: {
            Image(systemName: Self.skipSymbol(forward: forward, seconds: magnitude))
                .font(.system(size: 22, weight: .medium)).frame(width: TransportMetrics.skip, height: TransportMetrics.skip)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle)
        .accessibilityLabel("\(forward ? "Forward" : "Back") \(magnitude) seconds")
        .accessibilityIdentifier(forward ? "playerSkipForward" : "playerSkipBack")
    }

    /// SF Symbols draws the interval into the arrow for these values only.
    static func skipSymbol(forward: Bool, seconds: Int) -> String {
        let base = forward ? "goforward" : "gobackward"
        return [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
    }

    /// Scrubber with elapsed and remaining time. A downloaded copy scrubs without preview frames.
    private var timeline: some View {
        TrickplayScrubber(itemID: item.id, mediaSourceID: playback.currentSourceID,
                          duration: Double(item.RunTimeTicks ?? 0) / ticksPerSecond,
                          api: playback.method == "Offline" ? nil : session.api,
                          currentTime: { playback.player.currentTime().seconds },
                          seek: { playback.seek(to: Int64($0 * ticksPerSecond)); revealControls() },
                          identifier: "playerTimeline",
                          onScrubbingChanged: { scrubbing = $0; revealControls() })
            .disabled(playback.preparing || playback.error != nil)
            .accessibilityHidden(sheetShown)
    }

    /// Skip Intro (or the current segment) while the server marks one; segments set to skip
    /// on their own are skipped here too.
    @ViewBuilder private var segmentSkip: some View {
        if !segments.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let seconds = playback.player.currentTime().seconds
                let ticks = seconds.isFinite ? Int64(max(0, seconds) * ticksPerSecond) : 0
                if let segment = segments.first(where: { $0.StartTicks <= ticks && ticks < $0.EndTicks && $0.EndTicks > $0.StartTicks }) {
                    if preferences.segmentMode(segment.Type) == .ask {
                        Button { playback.seek(to: segment.EndTicks); revealControls() } label: {
                            Label("Skip \(segment.Type.lowercased())", systemImage: "forward.end.fill")
                                .font(.headline).lineLimit(1).padding(.horizontal, 20).frame(minHeight: 48)
                                .background(Color.reelText, in: Capsule()).foregroundStyle(Color.reelBackground)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("skipSegment")
                    } else if preferences.segmentMode(segment.Type) == .auto && !playback.syncPlayManaged
                        && !playback.preparing && playback.error == nil {
                        Color.clear.frame(width: 0, height: 0).allowsHitTesting(false).task(id: segment.id) { playback.seek(to: segment.EndTicks) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var nextEpisodeButton: some View {
        if offersEpisodes, let nextEpisode {
            Button { playEpisode(nextEpisode) } label: {
                Label("Next episode", systemImage: "forward.end.fill").font(.subheadline.weight(.semibold)).fixedSize().frame(minHeight: 44)
            }
            .buttonStyle(.glass).disabled(playback.preparing)
            .accessibilityLabel("Play \(nextEpisode.Name)").accessibilityIdentifier("playerNextEpisode")
        }
    }

    private func close() {
        if playback.syncPlayManaged { Task { await syncPlay.leave() } }
        playback.stop(); playback.activeItem = nil
    }

    private func replay(_ endedID: UUID) {
        guard let api = session.api else { return }
        cancelledAutoplaySession = endedID
        autoplayRemaining = nil
        Task { await playback.replay(endedID: endedID, api: api, quality: StreamQuality(rawValue: quality) ?? .original, bitrate: effectiveBitrate) }
    }

    private func revealControls() {
        chromeTask?.cancel()
        chromeVisible = true
        guard !keepsControlsVisible else { return }
        chromeTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard !Task.isCancelled, !keepsControlsVisible else { return }
            chromeVisible = false
        }
    }

    // MARK: End of playback

    private var endCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(playback.syncPlayManaged ? "Watching together" : nextEpisode == nil ? "Finished watching" : "Up next").font(.largeTitle.bold())
            if playback.syncPlayManaged {
                Text("The next item follows your group’s queue.").foregroundStyle(Color.reelMuted)
                Button("Group controls") { showingGroup = true }.buttonStyle(PrimaryButton()).accessibilityIdentifier("groupControlsAtEnd")
            } else if let nextEpisode {
                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .center, spacing: 16))) {
                    Artwork(item: nextEpisode.thumbnailItem, backdrop: true, width: 600)
                        .frame(width: 200, height: 112).clipShape(RoundedRectangle(cornerRadius: ReelRadius.artwork))
                    VStack(alignment: .leading, spacing: 4) {
                        if !nextEpisode.episodeNumberText.isEmpty {
                            Text(nextEpisode.episodeNumberText).font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelMuted)
                        }
                        Text(nextEpisode.Name).font(.title3.bold()).lineLimit(2)
                        if let autoplayRemaining {
                            Text("Playing in \(autoplayRemaining) seconds").font(.subheadline).foregroundStyle(Color.reelMuted)
                                .monospacedDigit().accessibilityIdentifier("nextEpisodeCountdown")
                        }
                    }
                }
                WrapLayout(spacing: 10, lineSpacing: 10) {
                    Button { playEpisode(nextEpisode) } label: { Label("Play now", systemImage: "play.fill") }
                        .buttonStyle(PrimaryButton()).accessibilityLabel("Play \(nextEpisode.Name)").accessibilityIdentifier("playNext")
                    if autoplayRemaining != nil {
                        Button("Cancel") {
                            cancelledAutoplaySession = playback.endedSessionID; self.autoplayRemaining = nil
                        }.buttonStyle(QuietButton()).accessibilityLabel("Cancel automatic next episode").accessibilityIdentifier("cancelNextEpisode")
                    }
                }
            }
            WrapLayout(spacing: 10, lineSpacing: 10) {
                if !playback.syncPlayManaged, let endedID = playback.endedSessionID {
                    if nextEpisode == nil {
                        Button { replay(endedID) } label: { Label("Play again", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(PrimaryButton()).accessibilityIdentifier("replayPlayer")
                    } else {
                        Button { replay(endedID) } label: { Label("Play again", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(QuietButton()).accessibilityIdentifier("replayPlayer")
                    }
                }
                Button("Back to your library") { playback.stop(); playback.activeItem = nil }.buttonStyle(QuietButton())
            }
        }
        .frame(maxWidth: 600, alignment: .leading).padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.94)], startPoint: .top, endPoint: .bottom))
    }

    // MARK: Options sheet

    private var companion: some View {
        let menuLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
            : AnyLayout(HStackLayout(spacing: 12))
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 9) {
                            Eyebrow(text: "Now playing")
                            Text(item.Name).font(.title2.bold()).lineLimit(2)
                            Text(item.metadata).font(.system(size: 12)).foregroundStyle(Color.reelMuted)
                            if playback.method == "Offline" || session.api?.recordsHistory == false {
                                Label("History off", systemImage: "eye.slash").font(.caption)
                                    .foregroundStyle(Color.reelMuted).accessibilityIdentifier("historyOff")
                            }
                        }
                        Spacer(minLength: 0)
                        if let nextEpisode {
                            VStack(alignment: .trailing, spacing: 9) {
                                Eyebrow(text: "Up next")
                                Text(nextEpisode.Name).font(.system(size: 14)).lineLimit(2)
                                if !nextEpisode.episodeNumberText.isEmpty {
                                    Text(nextEpisode.episodeNumberText).font(.system(size: 11)).foregroundStyle(Color.reelMuted).lineLimit(1)
                                }
                            }.frame(maxWidth: 220)
                        }
                    }
                if item.Type == "Episode", playback.method != "Offline", !playback.syncPlayManaged {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 16) {
                            Button { if let previousEpisode { playEpisode(previousEpisode) } } label: {
                                Label("Previous", systemImage: "backward.end.fill").frame(maxWidth: .infinity, minHeight: 44)
                            }.disabled(previousEpisode == nil || playback.preparing).accessibilityIdentifier("previousEpisode")
                            Button { if let nextEpisode { playEpisode(nextEpisode) } } label: {
                                Label("Next", systemImage: "forward.end.fill").frame(maxWidth: .infinity, minHeight: 44)
                            }.disabled(nextEpisode == nil || playback.preparing).accessibilityIdentifier("nextEpisode")
                        }.buttonStyle(.plain).font(.subheadline.weight(.semibold))
                        Toggle("Play next episode automatically", isOn: $autoplayNextEpisode)
                            .font(.subheadline).tint(Color.reelBlue).accessibilityIdentifier("autoplayNextEpisode")
                        if playback.sleepDeadline != nil {
                            Text("A sleep timer pauses automatic next episodes.").font(.footnote).foregroundStyle(Color.reelMuted)
                        }
                        if let episodeNavigationError {
                            Text(episodeNavigationError).font(.footnote).foregroundStyle(Color.reelMuted)
                            Button("Reload episodes") { Task { await loadNext() } }.accessibilityIdentifier("reloadEpisodeNavigation")
                        }
                    }
                    Divider().overlay(.white.opacity(0.06))
                }
                PlayerStreamControls(item: item, quality: $quality)
                Divider().overlay(.white.opacity(0.06))
                Text("Playback tools").font(.headline)
                optionsTransport
                menuLayout {
                    Menu {
                        Picker("Playback speed", selection: Binding(get: { playback.speed }, set: { playback.speed = $0 })) {
                            ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in Text(String(format: "%g×", value)).tag(value) }
                        }
                    } label: { Label(String(format: "%g×", playback.speed), systemImage: "speedometer") }.disabled(preferences.rateLocked).accessibilityIdentifier("playbackSpeed")
                    Menu {
                        Button("Off") { playback.setSleepTimer(minutes: nil) }
                        ForEach([15, 30, 45, 60], id: \.self) { minutes in Button("\(minutes) minutes") { playback.setSleepTimer(minutes: minutes) } }
                    } label: { Label(playback.sleepDeadline == nil ? "Sleep timer" : "Timer on", systemImage: "moon.zzz") }.accessibilityIdentifier("sleepTimer")
                    if let chapters = item.Chapters, !chapters.isEmpty {
                        Menu {
                            ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                                Button(chapter.Name ?? "Chapter \(index + 1)") { playback.seek(to: chapter.StartPositionTicks) }
                            }
                        } label: { Label("Chapters", systemImage: "list.bullet.rectangle") }.accessibilityIdentifier("playerChapters")
                    }
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                }.font(.subheadline).foregroundStyle(.white).disabled(playback.syncPlayManaged)
                if let api = session.api, playback.method != "Offline" {
                    TrickplayScrubber(itemID: item.id, mediaSourceID: playback.currentSourceID,
                                      duration: Double(item.RunTimeTicks ?? 0) / ticksPerSecond,
                                      api: api, currentTime: { playback.player.currentTime().seconds },
                                      seek: { playback.seek(to: Int64($0 * ticksPerSecond)) })
                    if !playback.syncPlayManaged { ReceiverRoutesView(item: item, api: api, bitrate: preferences.bitrate(local: quality), mediaSourceID: playback.currentSourceID,
                                       position: { playback.ended ? 0 : playback.player.currentTime().seconds },
                                       captureAudio: { try await playback.captureCurrentPlaybackChoices(api: api) },
                                       isCaptureCurrent: { playback.isAudioCaptureCurrent($0) },
                                       castSelection: { try playback.castSelection(from: $0) },
                                       onCastStarted: { playback.commitHandoff(from: $0) },
                                       onReturnToLocal: { playback.resumeOnDevice(at: $0, api: api, quality: StreamQuality(rawValue: quality) ?? .original, bitrate: preferences.bitrate(local: quality)) }) }
                }
                let format = PlaybackFormat.describe(source: playback.currentMediaSource, method: playback.method, audio: playback.currentAudioDisclosure)
                Button { showingStreamInformation.toggle() } label: {
                    HStack {
                        Text("Stream information")
                        Spacer()
                        Image(systemName: showingStreamInformation ? "chevron.up" : "chevron.down").font(.caption)
                    }.frame(minHeight: 44)
                }.font(.subheadline).foregroundStyle(Color.reelMuted)
                    .accessibilityValue(showingStreamInformation ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("streamInformation")
                if showingStreamInformation {
                VStack(alignment: .leading, spacing: 8) {
                    Text(format.source)
                    Text(format.delivery)
                    Text(format.output)
                    if !format.warning.isEmpty { Text(format.warning) }
                }.font(.caption).foregroundStyle(Color.reelMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityElement(children: .combine).accessibilityIdentifier("playbackFormat")
                }
            }.padding(24)
            }
            .accessibilityIdentifier("playerOptionsScroll")
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.reelBackground)
    }

    /// The options sheet's transport, which tests and the managed group player address by name.
    private var optionsTransport: some View {
        let back = preferences.rewindSkip(), forward = preferences.forwardSkip()
        return HStack(spacing: 30) {
            Spacer(minLength: 0)
            Button { playback.skip(-Double(back)) } label: {
                Image(systemName: Self.skipSymbol(forward: false, seconds: back)).font(.system(size: 25)).frame(width: 48, height: 48)
            }.accessibilityLabel("Back \(back) seconds")
            Button { playback.togglePause() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .semibold)).frame(width: 64, height: 64)
                    .background(Color.reelText, in: Circle()).foregroundStyle(Color.reelBackground)
            }.accessibilityLabel(playback.isPlaying ? "Pause" : "Play").accessibilityIdentifier("transportPlayPause")
            Button { playback.skip(Double(forward)) } label: {
                Image(systemName: Self.skipSymbol(forward: true, seconds: forward)).font(.system(size: 25)).frame(width: 48, height: 48)
            }.accessibilityLabel("Forward \(forward) seconds")
            Spacer(minLength: 0)
        }.buttonStyle(.plain).disabled(playback.preparing || playback.error != nil || playback.ended)
    }

    private func retry(original: Bool = false) { if let api = session.api { playback.retry(api: api, quality: StreamQuality(rawValue: quality) ?? .original, bitrate: original ? StreamQuality.original.rawValue : effectiveBitrate) } }
    private func start() { if let api = session.api { playback.speed = preferences.playbackRate(local: playback.speed); playback.start(api: api, quality: StreamQuality(rawValue: quality) ?? .original, bitrate: preferences.bitrate(local: quality)) } }
    private func loadSegments() async {
        guard !Task.isCancelled else { return }
        segments = []
        guard playback.method != "Offline", let api = session.api else { return }
        let revision = session.revision
        do {
            let page: MediaSegmentPage = try await api.get("MediaSegments/\(item.id)")
            try Task.checkCancellation()
            guard session.revision == revision, playback.activeItem?.id == item.id else { return }
            segments = EpisodePlayback.segments(page.Items, duration: item.RunTimeTicks)
        } catch { }
    }
    private func loadNext() async {
        guard !Task.isCancelled else { return }
        previousEpisode = nil; nextEpisode = nil; episodeNavigationError = nil
        guard playback.method != "Offline", let current = playback.activeItem, current.Type == "Episode",
              let seriesID = current.SeriesId, let api = session.api else { return }
        let revision = session.revision
        do {
            let page = try await api.page("Shows/\(seriesID)/Episodes", query: ["adjacentTo": current.id, "isMissing": "false"])
            try Task.checkCancellation()
            guard session.revision == revision, playback.activeItem?.id == current.id else { return }
            let neighbors = EpisodePlayback.neighbors(of: current, in: page.Items)
            previousEpisode = neighbors.previous; nextEpisode = neighbors.next
        } catch is CancellationError { }
        catch {
            if session.revision == revision, playback.activeItem?.id == current.id {
                episodeNavigationError = "Episode navigation couldn’t load. Your current playback can continue."
            }
        }
    }
    private func playEpisode(_ episode: MediaItem) {
        guard !playback.syncPlayManaged, playback.method != "Offline" else { return }
        cancelledAutoplaySession = playback.endedSessionID
        showingOptions = false
        playback.present(episode, fromBeginning: true, startPositionTicks: 0)
    }
    private struct AutoplayIdentity: Hashable {
        let session: UUID?
        let nextID: String?
        let enabled: Bool
        let cancelled: UUID?
        let canRun: Bool
        let accountRevision: UUID
    }
    private var autoplayIdentity: AutoplayIdentity {
        AutoplayIdentity(session: playback.endedSessionID, nextID: nextEpisode?.id,
                         enabled: autoplayNextEpisode, cancelled: cancelledAutoplaySession,
                         canRun: playback.ended && !playback.restartingEnded && !playback.preparing
                             && !playback.resolvingReplacement && playback.error == nil
                             && !playback.syncPlayManaged && playback.method != "Offline" && playback.sleepDeadline == nil
                             && scenePhase == .active && !showingOptions && !showingEpisodes && !showingGroup,
                         accountRevision: session.revision)
    }
    private func countDownToNextEpisode() async {
        autoplayRemaining = nil
        let identity = autoplayIdentity
        guard identity.enabled, identity.canRun, let endedSession = identity.session,
              identity.cancelled != endedSession, let nextEpisode else { return }
        for seconds in (1...10).reversed() {
            guard !Task.isCancelled, autoplayIdentity == identity else { return }
            autoplayRemaining = seconds
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
        guard !Task.isCancelled, autoplayIdentity == identity else { return }
        autoplayRemaining = nil
        playEpisode(nextEpisode)
    }
}
