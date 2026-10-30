import SwiftUI
import AVKit
#if canImport(GoogleCast)
@preconcurrency import GoogleCast
#endif

struct TrickplayScrubber: View {
    let itemID: String
    var mediaSourceID: String?
    let duration: Double
    /// Nil for a downloaded copy, which scrubs without preview frames.
    let api: JellyfinAPI?
    let currentTime: () -> Double
    let seek: (Double) -> Void
    /// The options sheet's timeline keeps "scrubTimeline"; the one over the picture has its own.
    var identifier = "scrubTimeline"
    /// Lets the player keep its controls up while a finger is on the timeline.
    var onScrubbingChanged: (Bool) -> Void = { _ in }
    @State private var store = TrickplayStore()
    @State private var scrubbing = false
    @State private var scrubPosition: Double?
    @State private var thumbnail: UIImage?
    @State private var thumbnailFailed = false

    var body: some View {
        if duration.isFinite && duration > 0 {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let current = currentTime()
                let actual = min(duration, max(0, current.isFinite ? current : 0))
                let displayed = scrubbing ? scrubPosition ?? actual : actual
                VStack(spacing: 8) {
                    PlaybackPositionSlider(value: displayed, duration: duration, identifier: identifier, onChange: { position in
                        if scrubbing { scrubPosition = position }
                        else { seek(position) }
                    }, onEditingChanged: { editing in
                        scrubbing = editing
                        onScrubbingChanged(editing)
                        if !editing {
                            if let scrubPosition { seek(scrubPosition) }
                            scrubPosition = nil
                        }
                    })
                        .frame(height: 31)
                        .overlay(alignment: .bottom) {
                            if scrubbing {
                                VStack(spacing: 8) {
                                    if let thumbnail {
                                        Image(uiImage: thumbnail).resizable().scaledToFit().frame(width: 192, height: 108)
                                            .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Preview at \(Self.timestamp(displayed))").accessibilityIdentifier("trickplayThumbnail")
                                    } else if store.info != nil && !thumbnailFailed { ProgressView().frame(width: 192, height: 108) }
                                    Text(Self.timestamp(displayed)).font(.caption.monospacedDigit()).foregroundStyle(Color.reelBlue)
                                }
                                .padding(12).background(Color.reelSurface, in: RoundedRectangle(cornerRadius: 12))
                                .offset(y: -44).allowsHitTesting(false)
                            }
                        }
                    HStack {
                        Text(Self.timestamp(displayed)); Spacer(); Text("−" + Self.timestamp(max(0, duration - displayed)))
                    }.font(.caption.monospacedDigit()).foregroundStyle(Color.reelMuted)
                }
                .zIndex(1)
                .task(id: scrubbing ? store.info?.frame(at: displayed)?.thumbnail : nil) {
                    guard scrubbing, let api else { thumbnail = nil; return }
                    thumbnailFailed = false
                    do {
                        try await Task.sleep(for: .milliseconds(80))
                        let next = try await store.thumbnail(itemID: itemID, seconds: displayed, api: api)
                        try Task.checkCancellation()
                        thumbnail = next
                        thumbnailFailed = next == nil
                    } catch is CancellationError { }
                    catch { thumbnail = nil; thumbnailFailed = true }
                }
            }
            .task(id: "\(api?.server.absoluteString ?? "offline")|\(api?.userID ?? "")|\(itemID)|\(mediaSourceID ?? "")") {
                thumbnail = nil
                guard let api else { return }
                await store.load(itemID: itemID, mediaSourceID: mediaSourceID, api: api)
            }
        }
    }

    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = Int(min(Double(Int.max / 2), max(0, seconds)))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct PlaybackPositionSlider: UIViewRepresentable {
    let value: Double
    let duration: Double
    let identifier: String
    let onChange: (Double) -> Void
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.minimumValue = 0
        // A thin white line with a small knob that grows while dragged, like the web player's,
        // instead of the system's large capsule knob sitting on the picture.
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.setThumbImage(Self.knob(diameter: 14), for: .normal)
        slider.setThumbImage(Self.knob(diameter: 24), for: .highlighted)
        slider.accessibilityLabel = "Playback position"
        slider.accessibilityIdentifier = identifier
        slider.addTarget(context.coordinator, action: #selector(Coordinator.begin), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.change), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.end), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }
    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        slider.maximumValue = Float(duration)
        if !context.coordinator.editing { slider.value = Float(value) }
        slider.accessibilityValue = TrickplayScrubber.timestamp(Double(slider.value))
    }

    /// A white disc with a soft shadow, drawn with room for the shadow around it.
    static func knob(diameter: CGFloat) -> UIImage {
        let inset: CGFloat = 4
        let size = CGSize(width: diameter + inset * 2, height: diameter + inset * 2)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillEllipse(in: CGRect(x: inset, y: inset, width: diameter, height: diameter))
        }
    }

    @MainActor final class Coordinator: NSObject {
        var parent: PlaybackPositionSlider
        var editing = false
        init(_ parent: PlaybackPositionSlider) { self.parent = parent }
        @objc func begin(_ slider: UISlider) {
            editing = true
            parent.onEditingChanged(true)
        }
        @objc func change(_ slider: UISlider) {
            slider.accessibilityValue = TrickplayScrubber.timestamp(Double(slider.value))
            parent.onChange(Double(slider.value))
        }
        @objc func end(_ slider: UISlider) {
            guard editing else { return }
            // Keep touch release attached to the same native control while the
            // timeline clock and preview update the surrounding SwiftUI view.
            parent.onChange(Double(slider.value))
            editing = false
            parent.onEditingChanged(false)
        }
    }
}

struct AirPlayRouteButton: UIViewRepresentable {
    var tint = UIColor(Color.reelBlue)
    var activeTint = UIColor.white
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = tint
        picker.activeTintColor = activeTint
        picker.accessibilityLabel = "AirPlay devices"
        return picker
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) { }
}

#if canImport(GoogleCast)
private struct GoogleCastRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton {
        CastCoordinator.shared.configure()
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        button.tintColor = UIColor(Color.reelBlue)
        button.accessibilityLabel = "Google Cast devices"
        return button
    }
    func updateUIView(_ view: GCKUICastButton, context: Context) { }
}
#endif

struct ReceiverRoutesView: View {
    let item: MediaItem
    let api: JellyfinAPI
    let bitrate: Int
    var mediaSourceID: String?
    let position: () -> Double
    let captureAudio: () async throws -> PlaybackController.CapturedAudioChoice
    let isCaptureCurrent: (PlaybackController.CapturedAudioChoice) -> Bool
    let castSelection: (PlaybackController.CapturedAudioChoice) throws -> PlaybackTrackSelection
    let onCastStarted: (PlaybackController.CapturedAudioChoice) -> Bool
    var onReturnToLocal: ((Double) -> Void)? = nil
    @State private var cast = CastCoordinator.shared
    @State private var returnPosition: Double?
    @State private var returningToLocal = false
    @State private var captureTask: Task<Void, Never>?
    @State private var captureOperation = UUID()
    @State private var capturing = false
    @State private var ownedCastID: UUID?
    @State private var captureError: String?
    private var ownsCurrentItem: Bool { cast.hasEstablishedPlayback && cast.remoteItemID == item.id && cast.ownsAccount(api.server.absoluteString + "|" + (api.userID ?? "")) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if !api.isSimulatorPreview && api.gatewayHeaders.isEmpty {
                    AirPlayRouteButton().frame(width: 44, height: 44).accessibilityIdentifier("airPlayRoute")
                    #if canImport(GoogleCast)
                    GoogleCastRouteButton().frame(width: 44, height: 44).accessibilityIdentifier("googleCastRoute")
                    if cast.connected && !ownsCurrentItem {
                        Button { beginCast() } label: { Label(cast.loading || capturing ? "Connecting…" : "Play on \(cast.receiverName)", systemImage: "tv") }
                            .disabled(cast.loading || capturing).accessibilityIdentifier("castCurrentTitle")
                    }
                    #endif
                } else if !api.gatewayHeaders.isEmpty { Label("Gateway-protected media plays on iPhone; receivers need a direct server connection", systemImage: "lock.shield").font(.caption).foregroundStyle(Color.reelMuted) }
                else { Label("Receiver playback is off in this protected preview", systemImage: "eye").font(.caption).foregroundStyle(Color.reelMuted) }
                Spacer(minLength: 0)
            }
            if ownsCurrentItem {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Playing on \(cast.receiverName)", systemImage: "tv.fill").font(.headline)
                    Text(cast.remoteTitle).font(.subheadline).foregroundStyle(Color.reelMuted)
                    HStack(spacing: 24) {
                        Button { cast.seek(to: cast.position - 15) } label: { Image(systemName: "gobackward.15") }.accessibilityLabel("Cast back 15 seconds")
                        Button { cast.togglePause() } label: { Image(systemName: cast.isPlaying ? "pause.fill" : "play.fill") }.accessibilityLabel(cast.isPlaying ? "Pause Cast" : "Play Cast")
                        Button { cast.seek(to: cast.position + 15) } label: { Image(systemName: "goforward.15") }.accessibilityLabel("Cast forward 15 seconds")
                        Spacer()
                        Button("Stop casting") { cast.endCasting() }.accessibilityIdentifier("stopCasting")
                    }.font(.title3).buttonStyle(.borderless)
                }.padding(16).background(Color.reelSurface, in: RoundedRectangle(cornerRadius: 14))
            }
            if let onReturnToLocal, ownsCurrentItem || returnPosition != nil || cast.canReturnToLocal(itemID: item.id, api: api) {
                Button("Play on this device") {
                    let lastPosition = returnPosition ?? (ownsCurrentItem ? cast.position : cast.lastPosition)
                    returningToLocal = true
                    cast.endCasting(); cast.forgetLocalReturn(); returnPosition = nil
                    onReturnToLocal(lastPosition)
                }.accessibilityIdentifier("returnCastToLocal")
            }
            if let captureError { Text(captureError).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("castSelectionError") }
            if let notice = cast.pendingLoadNotice { Text(notice).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("castPendingLoadNotice") }
            if let error = cast.error { Text(error).font(.footnote).foregroundStyle(.orange) }
        }
        .onDisappear { cancelPendingCast() }
        .onChange(of: item.id) { _, _ in cancelPendingCast() }
        .onChange(of: api.server) { _, _ in cancelPendingCast() }
        .onChange(of: api.userID) { _, _ in cancelPendingCast() }
        .onChange(of: api.token) { _, _ in cancelPendingCast() }
        .onChange(of: api.gatewayHeaders) { _, _ in cancelPendingCast() }
        .onChange(of: cast.remoteItemID) { previous, current in
            if previous == item.id, current == nil { returnPosition = returningToLocal ? nil : cast.lastPosition; returningToLocal = false }
            else if current == item.id { returnPosition = nil; returningToLocal = false }
        }
    }
    private func beginCast() {
        guard !capturing, !cast.loading else { return }
        let capturedBitrate: Int
        do { capturedBitrate = try CastBitratePolicy.receiverBitrate(bitrate) }
        catch { captureError = error.localizedDescription; return }
        let operation = UUID(); captureOperation = operation
        capturing = true; captureError = nil
        captureTask = Task { @MainActor in
            defer { if captureOperation == operation { capturing = false; captureTask = nil } }
            do {
                let choice = try await captureAudio()
                try Task.checkCancellation()
                guard captureOperation == operation, isCaptureCurrent(choice) else { throw PlaybackAudioSelection.SelectionError.stale }
                let resumedPosition = CastSessionOwnership.startPosition(local: position(), remote: ownsCurrentItem ? cast.position : nil,
                    remembered: cast.canReturnToLocal(itemID: item.id, api: api) ? cast.lastPosition : nil)
                let selection = try castSelection(choice)
                ownedCastID = cast.cast(item, api: api, position: resumedPosition, bitrate: capturedBitrate, selection: selection, admitted: {
                    captureOperation == operation && isCaptureCurrent(choice)
                }) {
                    guard captureOperation == operation, isCaptureCurrent(choice) else { return false }
                    let accepted = onCastStarted(choice)
                    if accepted { ownedCastID = nil }
                    return accepted
                }
            } catch {
                guard captureOperation == operation, !Task.isCancelled else { return }
                if let subtitleError = error as? PlaybackSubtitleSelection.SelectionError { captureError = subtitleError.localizedDescription }
                else { captureError = (error as? PlaybackAudioSelection.SelectionError)?.localizedDescription
                    ?? PlaybackAudioSelection.SelectionError.unavailable.localizedDescription }
            }
        }
    }
    private func cancelPendingCast() {
        captureOperation = UUID(); captureTask?.cancel(); captureTask = nil; capturing = false
        if let ownedCastID { cast.cancelOwnedCast(ownedCastID) }
        ownedCastID = nil
    }

}
