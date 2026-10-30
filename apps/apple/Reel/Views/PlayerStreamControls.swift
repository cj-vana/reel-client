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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Picture & sound").font(.headline)
                Spacer()
                if busy { ProgressView().controlSize(.small).accessibilityLabel("Updating playback") }
            }
            if offline {
                Label("Downloaded copy", systemImage: "arrow.down.circle.fill").foregroundStyle(Color.reelBlue)
                Text("Use the video controls for audio and captions included in this download.")
                    .font(.footnote).foregroundStyle(Color.reelMuted)
            } else if playback.syncPlayManaged {
                Label("Managed by your watch group", systemImage: "person.2.wave.2")
                    .font(.subheadline).foregroundStyle(Color.reelMuted)
            } else {
                VStack(spacing: 0) {
                    Menu {
                        ForEach(StreamQuality.allCases) { value in
                            Button { changeQuality(value) } label: {
                                if effectiveBitrate == value.rawValue { Label(value.label, systemImage: "checkmark") }
                                else { Text(value.label) }
                            }
                        }
                    } label: { row("Quality", value: qualityLabel, icon: "slider.horizontal.3") }
                    .accessibilityIdentifier("playerQuality").disabled(!canChange || preferences.bitrateLocked)
                    if preferences.bitrateLocked {
                        Text("Quality is set by your server.").font(.footnote).foregroundStyle(Color.reelMuted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 12)
                    }
                    if !audioTracks.isEmpty {
                        Divider().overlay(.white.opacity(0.06))
                        Menu {
                            Button("Server default") { change(.audio(nil)) }
                            ForEach(audioTracks, id: \.Index) { track in
                                Button { change(.audio(track.Index)) } label: {
                                    if audio == track.Index { Label(trackName(track), systemImage: "checkmark") }
                                    else { Text(trackName(track)) }
                                }
                            }
                        } label: { row("Audio", value: trackLabel(audio, in: audioTracks), icon: "waveform") }
                        .accessibilityIdentifier("playerAudio").disabled(!canChange || catalogSource == nil)
                    }
                    if !subtitleTracks.isEmpty {
                        Divider().overlay(.white.opacity(0.06))
                        Menu {
                            Button("Server default") { change(.subtitle(nil)) }
                            Button { change(.subtitle(-1)) } label: {
                                if subtitle == -1 { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                            }
                            ForEach(subtitleTracks, id: \.Index) { track in
                                Button { change(.subtitle(track.Index)) } label: {
                                    if subtitle == track.Index { Label(trackName(track), systemImage: "checkmark") }
                                    else { Text(trackName(track)) }
                                }
                            }
                        } label: { row("Subtitles", value: subtitle == -1 ? "Off" : trackLabel(subtitle, in: subtitleTracks), icon: "captions.bubble") }
                        .accessibilityIdentifier("playerSubtitles").disabled(!canChange || catalogSource == nil)
                    }
                    if versions.count > 1 {
                        Divider().overlay(.white.opacity(0.06))
                        Menu {
                            ForEach(versions, id: \.Id) { version in
                                Button { change(.version(version.Id)) } label: {
                                    if version.Id == playback.currentSourceID { Label(versionName(version), systemImage: "checkmark") }
                                    else { Text(versionName(version)) }
                                }
                            }
                        } label: { row("Version", value: source.map(versionName) ?? "Current version", icon: "film.stack") }
                        .accessibilityIdentifier("playerVersion").disabled(!canChange)
                    }
                }
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
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

    private func row(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.reelBlue).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(value).font(.footnote).foregroundStyle(Color.reelMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Color.reelMuted)
        }
        .foregroundStyle(Color.reelText).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
    }
    private func uniqueTracks(_ type: String) -> [MediaStream] {
        let tracks = source?.MediaStreams?.filter { $0.Type == type && $0.Index >= 0 } ?? []
        return tracks.filter { track in tracks.filter { $0.Index == track.Index }.count == 1 }
    }
    private func trackName(_ stream: MediaStream) -> String { stream.DisplayTitle ?? stream.Language ?? "Track \(stream.Index)" }
    private func trackLabel(_ index: Int?, in tracks: [MediaStream]) -> String {
        tracks.first { $0.Index == index }.map(trackName) ?? "Server default"
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
