import SwiftUI
import AVFoundation

struct PlayerStreamControls: View {
    let item: MediaItem
    @Binding var quality: Int
    @Environment(Session.self) private var session
    @Environment(PlaybackController.self) private var playback
    @Environment(ServerPreferences.self) private var preferences
    @State private var metadata: MediaItem?
    @State private var loading = false
    @State private var changing = false
    @State private var message: String?
    @State private var audio: Int?
    @State private var subtitle: Int?
    @State private var operation: Task<Void, Never>?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var effectiveBitrate: Int { playback.currentBitrate ?? preferences.bitrate(local: quality) }
    private var qualityLabel: String {
        StreamQuality(rawValue: effectiveBitrate)?.label ?? String(format: "%.1f Mbps", Double(effectiveBitrate) / 1_000_000)
    }
    private var offline: Bool { playback.method == "Offline" }
    private var busy: Bool { loading || changing || playback.preparing || playback.resolvingReplacement }
    private var canChange: Bool {
        !busy && !offline && !playback.syncPlayManaged && !playback.ended && playback.error == nil
            && playback.player.currentItem?.status == .readyToPlay
    }
    private var catalogSource: MediaSource? {
        let matches = metadata?.MediaSources?.filter { $0.Id == playback.currentSourceID } ?? []
        return matches.count == 1 ? matches.first : nil
    }
    private var source: MediaSource? { catalogSource ?? playback.currentMediaSource }
    private var audioTracks: [MediaStream] { uniqueTracks("Audio") }
    private var subtitleTracks: [MediaStream] { uniqueTracks("Subtitle") }
    private var versions: [MediaSource] {
        let sources = metadata?.MediaSources ?? []
        return sources.filter { source in !source.Id.isEmpty && sources.filter { $0.Id == source.Id }.count == 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if offline {
                Label("Downloaded copy", systemImage: "arrow.down.circle.fill").foregroundStyle(Color.reelBlue)
                Text("Use the video controls for audio and captions included in this download.")
                    .font(.footnote).foregroundStyle(Color.reelMuted)
            } else if playback.syncPlayManaged {
                Label("Managed by your watch group", systemImage: "person.2.wave.2")
                    .font(.subheadline).foregroundStyle(Color.reelMuted)
            } else {
                // Subtitles and audio first: they are why most people open this sheet. Each row opens its own
                // list, which holds a long track list better than a menu and can be searched.
                VStack(spacing: 0) {
                    if !subtitleTracks.isEmpty {
                        choiceRow("Subtitles", value: subtitle == -1 ? "Off" : trackLabel(subtitle, in: subtitleTracks), icon: "captions.bubble",
                                  identifier: "playerSubtitles", disabled: !canChange || catalogSource == nil) {
                            StreamChoiceList(title: "Subtitles", choices: subtitleChoices)
                        }
                    }
                    if !audioTracks.isEmpty {
                        if !subtitleTracks.isEmpty { rowDivider }
                        choiceRow("Audio", value: trackLabel(audio, in: audioTracks), icon: "waveform",
                                  identifier: "playerAudio", disabled: !canChange || catalogSource == nil) {
                            StreamChoiceList(title: "Audio", choices: audioChoices)
                        }
                    }
                    if !audioTracks.isEmpty || !subtitleTracks.isEmpty { rowDivider }
                    choiceRow("Quality", value: qualityLabel, icon: "tv", identifier: "playerQuality",
                              disabled: !canChange || preferences.bitrateLocked) {
                        StreamChoiceList(title: "Quality", choices: StreamQuality.allCases.map { value in
                            StreamChoice(id: "quality-\(value.rawValue)", title: value.label, selected: effectiveBitrate == value.rawValue) { changeQuality(value) }
                        })
                    }
                    if versions.count > 1 {
                        rowDivider
                        choiceRow("Version", value: source.map(versionName) ?? "Current version", icon: "film.stack",
                                  identifier: "playerVersion", disabled: !canChange) {
                            StreamChoiceList(title: "Version", choices: versions.map { version in
                                StreamChoice(id: "version-\(version.Id)", title: versionName(version), selected: version.Id == playback.currentSourceID) { change(.version(version.Id)) }
                            })
                        }
                    }
                }
                .background(Color.reelSurfaceRaised, in: RoundedRectangle(cornerRadius: 14))
                if preferences.bitrateLocked {
                    Text("Quality is set by your server.").font(.footnote).foregroundStyle(Color.reelMuted)
                }
                if metadata != nil && catalogSource == nil {
                    Text("Track changes are unavailable for this stream. Use the video’s audio and subtitle controls when available.")
                        .font(.footnote).foregroundStyle(Color.reelMuted)
                }
                if versions.count > 1 {
                    Text("Changing versions keeps your place and uses the new version’s default audio and subtitles.")
                        .font(.footnote).foregroundStyle(Color.reelMuted)
                }
                if let error = playback.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("playerStreamError")
                        Button("Retry playback") { retryPlayback() }.accessibilityIdentifier("retryPlayerStream")
                        if effectiveBitrate != StreamQuality.original.rawValue && !preferences.bitrateLocked {
                            Button("Use original quality") { retryPlayback(original: true) }
                                .accessibilityIdentifier("recoverPlayerOriginal")
                        }
                    }.font(.subheadline.weight(.semibold)).disabled(busy)
                } else if let message = message ?? playback.audioSelectionError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("playerStreamError")
                        Button("Reload stream choices") { operation?.cancel(); operation = Task { await load() } }
                            .font(.subheadline.weight(.semibold)).disabled(busy).accessibilityIdentifier("reloadPlayerStreams")
                    }
                } else if !loading && audioTracks.isEmpty && subtitleTracks.isEmpty {
                    Text("This version has no additional audio or subtitle choices.")
                        .font(.footnote).foregroundStyle(Color.reelMuted)
                }
            }
        }
        .task(id: item.id) { await load() }
        .onChange(of: playback.preparing) { _, preparing in
            if !preparing { operation?.cancel(); operation = Task { await refreshSelections() } }
        }
        .onDisappear { operation?.cancel() }
    }

    /// The row a spinner replaces the chevron of while playback changes.
    private var firstRow: String { !subtitleTracks.isEmpty ? "playerSubtitles" : !audioTracks.isEmpty ? "playerAudio" : "playerQuality" }
    private var rowDivider: some View { Divider().overlay(Color.reelHairline).padding(.leading, 52) }

    private func choiceRow<Destination: View>(_ title: String, value: String, icon: String, identifier: String, disabled: Bool,
                                              @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.body.weight(.medium)).foregroundStyle(Color.reelBlue).frame(width: 24)
                if dynamicTypeSize.isAccessibilitySize {
                    // The value moves under the name, so neither has to be cut.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.body.weight(.medium)).foregroundStyle(Color.reelText)
                        Text(value).font(.subheadline).foregroundStyle(Color.reelMuted).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 8)
                    Spacer(minLength: 8)
                } else {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Color.reelText)
                    Spacer(minLength: 12)
                    Text(value).font(.subheadline).foregroundStyle(Color.reelMuted).lineLimit(1).truncationMode(.tail)
                }
                if busy && identifier == firstRow {
                    ProgressView().controlSize(.small).accessibilityLabel("Updating playback")
                } else {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.reelTertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 14).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.65 : 1)
        .accessibilityIdentifier(identifier)
    }
    private var subtitleChoices: [StreamChoice] {
        [StreamChoice(id: "subtitle-off", title: "Off", selected: subtitle == -1) { change(.subtitle(-1)) }]
            + subtitleTracks.map { track in
                StreamChoice(id: "subtitle-\(track.Index)", title: PlaybackTrackLabel.name(track), detail: PlaybackTrackLabel.detail(track),
                             selected: subtitle == track.Index) { change(.subtitle(track.Index)) }
            }
            + [StreamChoice(id: "subtitle-default", title: "Server default", detail: "Let your server choose", selected: false) { change(.subtitle(nil)) }]
    }
    private var audioChoices: [StreamChoice] {
        audioTracks.map { track in
            StreamChoice(id: "audio-\(track.Index)", title: PlaybackTrackLabel.name(track), detail: PlaybackTrackLabel.detail(track),
                         selected: audio == track.Index) { change(.audio(track.Index)) }
        } + [StreamChoice(id: "audio-default", title: "Server default", detail: "Let your server choose", selected: false) { change(.audio(nil)) }]
    }
    private func uniqueTracks(_ type: String) -> [MediaStream] {
        let tracks = source?.MediaStreams?.filter { $0.Type == type && $0.Index >= 0 } ?? []
        return tracks.filter { track in tracks.filter { $0.Index == track.Index }.count == 1 }
    }
    private func trackLabel(_ index: Int?, in tracks: [MediaStream]) -> String {
        tracks.first { $0.Index == index }.map(PlaybackTrackLabel.name) ?? "Server default"
    }
    private func versionName(_ source: MediaSource) -> String {
        source.Name ?? source.Container?.uppercased() ?? "Version \((versions.firstIndex { $0.Id == source.Id } ?? 0) + 1)"
    }
    private func load() async {
        guard !offline, !playback.syncPlayManaged, let api = session.api else { return }
        let revision = session.revision
        loading = true; message = nil
        defer { loading = false }
        do {
            let result = try await api.item(item.id)
            guard !Task.isCancelled, session.revision == revision, playback.activeItem?.id == item.id else { return }
            guard result.id == item.id else { throw ReelError.invalidResponse }
            metadata = result
            await refreshSelections()
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled && session.revision == revision {
                message = "Stream choices couldn’t load. Reload them to try again; your current playback is unchanged."
            }
        }
    }
    private func refreshSelections() async {
        guard let api = session.api, !playback.preparing, !offline else { return }
        do {
            let captured = try await playback.captureCurrentPlaybackChoices(api: api)
            guard !Task.isCancelled, playback.isAudioCaptureCurrent(captured) else { return }
            audio = captured.audioIndex; subtitle = captured.subtitleIndex
        } catch { audio = playback.currentAudioIndex; subtitle = playback.currentSubtitleIndex }
    }
    private func retryPlayback(original: Bool = false) {
        guard !busy, !offline, !playback.syncPlayManaged, let api = session.api else { return }
        message = nil
        if original { quality = StreamQuality.original.rawValue }
        playback.retry(api: api, quality: StreamQuality(rawValue: quality) ?? .original,
                       bitrate: original ? StreamQuality.original.rawValue : effectiveBitrate)
    }
    private func changeQuality(_ value: StreamQuality) {
        guard canChange, !preferences.bitrateLocked, let api = session.api else { return }
        message = nil; quality = value.rawValue
        playback.retry(api: api, quality: value, bitrate: value.rawValue, initiallyPaused: playback.player.rate == 0)
    }
    private func change(_ selection: PlaybackStreamChange) {
        guard canChange, let metadata, let api = session.api else { return }
        let revision = session.revision
        changing = true; message = nil
        operation?.cancel()
        operation = Task {
            defer { changing = false }
            do {
                try await playback.changeStreamSelection(selection, metadata: metadata, api: api,
                    quality: StreamQuality(rawValue: quality) ?? .original, bitrate: effectiveBitrate)
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, session.revision == revision, playback.activeItem?.id == item.id else { return }
                message = "That change couldn’t be applied. \(error.localizedDescription)"
            }
        }
    }
}

/// One row of a stream choice list.
struct StreamChoice: Identifiable {
    let id: String
    let title: String
    var detail: String?
    let selected: Bool
    let choose: () -> Void
}

/// The choices behind a row of the options sheet: the current one checked, a search field when the list is long
/// (a file can carry dozens of subtitle tracks), and back to the sheet once something is chosen.
struct StreamChoiceList: View {
    let title: String
    let choices: [StreamChoice]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var searchable: Bool { choices.count > 8 }
    private var shown: [StreamChoice] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return choices }
        return choices.filter { $0.title.localizedCaseInsensitiveContains(text) || ($0.detail?.localizedCaseInsensitiveContains(text) ?? false) }
    }

    var body: some View {
        if searchable {
            list.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(title.lowercased())")
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, choice in
                        if index > 0 { Divider().overlay(Color.reelHairline).padding(.leading, 16) }
                        Button { choice.choose(); dismiss() } label: { row(choice) }
                            .buttonStyle(.plain).id(choice.id)
                            .accessibilityLabel(choice.title)
                            .accessibilityValue(choice.detail ?? "")
                            .accessibilityAddTraits(choice.selected ? .isSelected : [])
                    }
                    if shown.isEmpty {
                        Text("No matches").font(.subheadline).foregroundStyle(Color.reelMuted)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                }
                .background(Color.reelSurfaceRaised, in: RoundedRectangle(cornerRadius: 14))
                .padding(16)
            }
            // A long list opens on the current choice rather than the top.
            .onAppear { if searchable, let current = choices.first(where: \.selected) { proxy.scrollTo(current.id, anchor: .center) } }
        }
        .background(Color.reelBackground)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ choice: StreamChoice) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title).font(.body).foregroundStyle(Color.reelText).fixedSize(horizontal: false, vertical: true)
                if let detail = choice.detail, !detail.isEmpty {
                    Text(detail).font(.footnote).foregroundStyle(Color.reelMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.reelBlue).opacity(choice.selected ? 1 : 0)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 6).contentShape(Rectangle())
    }
}
