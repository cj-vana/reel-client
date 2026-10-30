import SwiftUI
import AVKit
import ImageIO

struct MediaHubView: View {
    @Environment(Session.self) private var session
    @Environment(MediaHub.self) private var hub
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var nowPlaying = false
    var body: some View {
        ScrollView {
            // The bar already says Media; the page starts with its first group, like Settings.
            VStack(alignment: .leading, spacing: 32) {
                group("Listen", sections: [.albums, .artists, .tracks, .playlists, .audiobooks])
                group("Look & read", sections: [.photoAlbums, .photos, .books])
                NavigationLink { HubSavedView() } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "arrow.down.circle").font(.title2).foregroundStyle(Color.reelMuted).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) { Text("Saved music & books").font(.headline); Text("Original files, available on this device.").font(.subheadline).foregroundStyle(Color.reelMuted) }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.reelTertiary).accessibilityHidden(true)
                    }.padding(20).background(Color.reelSurface, in: RoundedRectangle(cornerRadius: Self.panelRadius))
                }.buttonStyle(.plain).accessibilityIdentifier("hub-saved")
            }
            .padding(.horizontal, AdaptiveLayout.margin(regular: horizontalSizeClass == .regular, width: 0)).padding(.vertical, 16)
        }
        .background(Color.reelBackground).navigationTitle("Media").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ServerSwitcher() } }
        .safeAreaInset(edge: .bottom) { if hub.current != nil { HubMiniPlayer { nowPlaying = true } } }
        .sheet(isPresented: $nowPlaying) { NavigationStack { HubNowPlayingView() } }
        .task(id: "\(session.revision)|\(session.privateViewing)") { if let account = session.account, let api = session.api { hub.bind(account: account, api: api) } }
        .onChange(of: scenePhase) { _, _ in hub.checkpoint() }
    }
    private func group(_ title: String, sections: [HubSection]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 16)], spacing: 16) {
                ForEach(sections) { section in
                    NavigationLink { HubCatalogView(section: section) } label: {
                        // Icons sit in a fixed box so every label lands on the same line; the
                        // accent stays for playback and state, not for every tile.
                        VStack(alignment: .leading, spacing: 20) {
                            Image(systemName: section.icon).font(.system(size: 26, weight: .regular)).foregroundStyle(Color.reelText)
                                .frame(height: 32, alignment: .bottomLeading).accessibilityHidden(true)
                            Text(section.rawValue).font(.headline).foregroundStyle(Color.reelText)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                            .background(Color.reelSurface, in: RoundedRectangle(cornerRadius: Self.panelRadius))
                    }.buttonStyle(.plain).accessibilityIdentifier("hub-\(section.itemTypes)")
                }
            }
        }
    }
    /// Reel's panel radius.
    private static let panelRadius: CGFloat = 16
}

struct HubCatalogView: View {
    let section: HubSection
    var parent: HubItem?
    @Environment(Session.self) private var session
    @Environment(MediaHub.self) private var hub
    @State private var items: [HubItem] = []
    @State private var total = 0
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""
    @State private var generation = UUID()
    @State private var playingAll = false
    @State private var queueTask: Task<Void, Never>?
    @State private var photo: HubItem?
    @State private var showingPlayer = false
    private var audioCollection: Bool { [.tracks, .audiobooks].contains(section) || parent?.Type == "MusicAlbum" || parent?.Type == "Playlist" || parent?.Type == "AudioBook" }
    private var photos: [HubItem] { items.filter { $0.Type == "Photo" } }
    var body: some View {
        Group {
            if loading && items.isEmpty { ProgressView("Opening \(parent?.Name ?? section.rawValue.lowercased())…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error, items.isEmpty { FailureView(message: error) { Task { await load(reset: true) } } }
            else if items.isEmpty { ContentUnavailableView("Nothing here yet", systemImage: section.icon, description: Text("Try another search or check that this library is available to your Jellyfin account.")) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if audioCollection, items.contains(where: { $0.isAudio || $0.isFolder }) {
                            HStack(spacing: 12) {
                                Button { playAll(shuffle: false) } label: { Label(playingAll ? "Opening queue…" : "Play all", systemImage: "play.fill") }.buttonStyle(PrimaryButton()).accessibilityIdentifier("hubPlayAll")
                                Button { playAll(shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }.buttonStyle(QuietButton()).accessibilityIdentifier("hubShuffle")
                            }.disabled(playingAll)
                        }
                        if audioCollection {
                            LazyVStack(spacing: 0) { ForEach(Array(items.enumerated()), id: \.offset) { offset, item in row(item, offset: offset) } }
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 18)], alignment: .leading, spacing: 24) {
                                ForEach(items) { item in tile(item) }
                            }
                        }
                        if let error { Text(error).font(.footnote).foregroundStyle(.orange); Button("Retry") { Task { await load(reset: false) } } }
                        if items.count < total {
                            Button { Task { await load(reset: false) } } label: { if loading { ProgressView() } else { Text("Load more") } }.buttonStyle(QuietButton()).disabled(loading).accessibilityIdentifier("hubLoadMore")
                        }
                    }.padding(24)
                }.accessibilityIdentifier("hubCatalogScroll").refreshable { await load(reset: true) }
            }
        }
        .background(Color.reelBackground).navigationTitle(parent?.Name ?? section.rawValue)
        .modifier(HubSearch(query: $query, prompt: "Search \(section.rawValue.lowercased())", enabled: parent?.Type != "Playlist"))
        .task(id: "\(session.revision)|\(query)") { do { try await Task.sleep(for: .milliseconds(250)) } catch { return }; await load(reset: true) }
        .onDisappear { queueTask?.cancel() }
        .sheet(item: $photo) { selected in HubPhotoViewer(items: photos, initialID: selected.id) }
        .sheet(isPresented: $showingPlayer) { NavigationStack { HubNowPlayingView() } }
        .safeAreaInset(edge: .bottom) { if hub.current != nil { HubMiniPlayer { showingPlayer = true } } }
    }
    private func row(_ item: HubItem, offset: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 14) {
            if item.isFolder { NavigationLink { HubCatalogView(section: section, parent: item) } label: { rowLabel(item) }.buttonStyle(.plain).accessibilityIdentifier("hub-item-\(item.id)") }
            else if item.isAudio {
                Button {
                    guard let account = session.account, let api = session.api else { return }
                    hub.play(items, at: offset, account: account, api: api)
                    showingPlayer = true
                } label: { rowLabel(item) }.buttonStyle(.plain).accessibilityIdentifier("hub-audio-\(item.id)")
                Menu {
                    if let account = session.account, let file = hub.saved(item, accountID: account.id) {
                        ShareLink(item: hub.fileURL(file)) { Label("Export saved original", systemImage: "square.and.arrow.up") }
                    } else if let account = session.account, hub.saving.contains(MediaHub.fileKey(accountID: account.id, itemID: item.id)) {
                        Button("Cancel saving", systemImage: "xmark.circle") { hub.cancelSave(MediaHub.fileKey(accountID: account.id, itemID: item.id)) }
                    } else {
                        Button("Save original for offline", systemImage: "arrow.down.circle") { if let account = session.account, let api = session.api { hub.save(item, account: account, api: api) } }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityIdentifier("hub-audio-options-\(item.id)")
            } else { NavigationLink { HubBookView(item: item) } label: { rowLabel(item) }.buttonStyle(.plain) }
        }
        if item.isAudio && !item.isFolder { HubSaveStatus(item: item).padding(.leading, 72) }
        }.padding(.vertical, 11)
        .overlay(alignment: .bottom) { Divider().opacity(0.25) }
    }
    private func rowLabel(_ item: HubItem) -> some View {
        HStack(spacing: 14) {
            Artwork(item: item.artworkItem, width: 250).frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.Name).font(.headline).foregroundStyle(Color.reelText)
                Text(item.subtitle.isEmpty ? (item.Album ?? item.Type ?? "") : item.subtitle).font(.subheadline).foregroundStyle(Color.reelMuted).lineLimit(1)
            }
            Spacer()
            if item.duration > 0 { Text(Self.time(item.duration)).font(.caption.monospacedDigit()).foregroundStyle(Color.reelMuted) }
            if hub.current?.id == item.id { Image(systemName: hub.playing ? "waveform" : "pause.fill").foregroundStyle(Color.reelBlue) }
        }.contentShape(Rectangle())
    }
    @ViewBuilder private func tile(_ item: HubItem) -> some View {
        if item.isFolder {
            NavigationLink { HubCatalogView(section: section, parent: item) } label: { tileLabel(item) }.buttonStyle(.plain).accessibilityIdentifier("hub-item-\(item.id)")
        } else if item.Type == "Photo" {
            Button { photo = item } label: { tileLabel(item) }.buttonStyle(.plain).accessibilityIdentifier("hub-photo-\(item.id)")
        } else {
            NavigationLink { HubBookView(item: item) } label: { tileLabel(item) }.buttonStyle(.plain).accessibilityIdentifier("hub-book-\(item.id)")
        }
    }
    private func tileLabel(_ item: HubItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Color.reelSurface).aspectRatio(section == .books ? 0.7 : 1, contentMode: .fit)
                .overlay { Artwork(item: item.artworkItem, width: 500) }
                .clipShape(RoundedRectangle(cornerRadius: item.Type == "MusicArtist" ? 80 : 14))
            Text(item.Name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelText).lineLimit(2)
            if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(Color.reelMuted).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    private func playAll(shuffle: Bool) {
        guard let api = session.api, let account = session.account, !playingAll else { return }
        playingAll = true; error = nil
        queueTask = Task {
            defer { playingAll = false }
            do {
                let all = try await HubAPI.allAudio(api: api, section: section, parent: parent, search: query)
                try Task.checkCancellation()
                guard !all.isEmpty else { return }
                hub.play(all, account: account, api: api, shuffled: shuffle); showingPlayer = true
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    private func load(reset: Bool) async {
        guard let api = session.api else { return }
        let run = UUID(); generation = run
        if reset { items = []; total = 0 }
        loading = true; error = nil
        defer { if generation == run { loading = false } }
        do {
            let page = try await HubAPI.browse(api: api, section: section, parent: parent, search: query, start: items.count)
            try Task.checkCancellation(); guard generation == run else { return }
            items += page.Items; total = page.TotalRecordCount ?? items.count
        } catch is CancellationError { }
        catch { if generation == run { self.error = error.localizedDescription } }
    }
    static func time(_ seconds: Double) -> String { let value = max(0, Int(seconds.isFinite ? seconds : 0)); return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60) }
}

private struct HubSearch: ViewModifier {
    @Binding var query: String
    let prompt: String
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.searchable(text: $query, prompt: prompt) } else { content }
    }
}

struct HubSaveStatus: View {
    let item: HubItem
    @Environment(Session.self) private var session
    @Environment(MediaHub.self) private var hub
    private var key: String { MediaHub.fileKey(accountID: session.account?.id ?? "", itemID: item.id) }
    var body: some View {
        if let account = session.account, let saved = hub.saved(item, accountID: account.id) {
            Label(saved.item.isAudio && !saved.canPlay ? "Saved for export" : "Saved offline", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.reelBlue).accessibilityIdentifier("hub-save-status-\(item.id)")
        } else if hub.saving.contains(key) {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Saving original…"); Spacer(); Button("Cancel") { hub.cancelSave(key) }.accessibilityIdentifier("hub-cancel-save-\(item.id)") }.font(.caption).accessibilityIdentifier("hub-saving-\(item.id)")
        } else if let error = hub.fileErrors[key] {
            VStack(alignment: .leading, spacing: 9) {
                Text(error).foregroundStyle(.orange).accessibilityIdentifier("hub-save-error-\(item.id)")
                HStack(spacing: 20) {
                    Button("Retry saving") { if let account = session.account, let api = session.api { hub.save(item, account: account, api: api) } }.accessibilityIdentifier("hub-retry-save-\(item.id)")
                    Button("Dismiss") { hub.dismissSave(key) }.accessibilityIdentifier("hub-dismiss-save-\(item.id)")
                }
                if hub.fileErrors["storage"] != nil { Button("Retry storage recovery") { hub.recoverStorage() }.accessibilityIdentifier("hub-recover-storage-\(item.id)") }
            }.font(.caption)
        }
    }
}

struct HubMiniPlayer: View {
    @Environment(MediaHub.self) private var hub
    var open: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Button(action: open) {
                HStack(spacing: 12) {
                    if let item = hub.current { Artwork(item: item.artworkItem, width: 150).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8)) }
                    VStack(alignment: .leading, spacing: 3) { Text(hub.current?.Name ?? "").font(.subheadline.weight(.semibold)).lineLimit(1); Text(hub.preparing ? "Opening audio…" : hub.current?.subtitle ?? "").font(.caption).foregroundStyle(Color.reelMuted).lineLimit(1) }
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("hubNowPlaying")
            Button { hub.toggle() } label: { Image(systemName: hub.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }.disabled(hub.preparing).accessibilityLabel(hub.playing ? "Pause music" : "Play music").accessibilityIdentifier("hubMiniToggle")
            Button { hub.next() } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }.accessibilityLabel("Next track")
        }.padding(.horizontal, 16).padding(.vertical, 10).background(.ultraThinMaterial)
    }
}

struct HubNowPlayingView: View {
    @Environment(MediaHub.self) private var hub
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var scrub: Double?
    @State private var showingLyrics = false
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let item = hub.current {
                    Artwork(item: item.artworkItem, width: 1000).aspectRatio(1, contentMode: .fit).frame(maxWidth: 340).clipShape(RoundedRectangle(cornerRadius: 22))
                    VStack(spacing: 8) { Text(item.Name).font(.title2.bold()).multilineTextAlignment(.center).accessibilityIdentifier("hubCurrentTitle"); Text(item.subtitle).foregroundStyle(Color.reelMuted); if let album = item.Album { Text(album).font(.caption).foregroundStyle(Color.reelMuted) } }
                    if hub.preparing { ProgressView("Opening audio…") }
                    Slider(value: Binding(get: { scrub ?? min(hub.position, max(1, hub.duration)) }, set: { scrub = $0 }), in: 0...max(1, hub.duration), onEditingChanged: { editing in if !editing, let scrub { hub.seek(scrub); self.scrub = nil } }).disabled(hub.preparing || hub.duration <= 0).accessibilityIdentifier("hubSeek")
                    HStack { Text(HubCatalogView.time(scrub ?? hub.position)); Spacer(); Text(HubCatalogView.time(hub.duration)) }.font(.caption.monospacedDigit()).foregroundStyle(Color.reelMuted)
                    HStack(spacing: 40) {
                        Button { hub.previous() } label: { Image(systemName: "backward.end.fill").font(.title2).frame(width: 48, height: 48) }.accessibilityIdentifier("hubPrevious")
                        Button { hub.toggle() } label: { Image(systemName: hub.playing ? "pause.fill" : "play.fill").font(.title).frame(width: 76, height: 76).background(Color.reelBlue, in: Circle()).foregroundStyle(Color.reelBackground) }.disabled(hub.preparing).accessibilityLabel(hub.playing ? "Pause music" : "Play music").accessibilityIdentifier("hubToggle")
                        Button { hub.next() } label: { Image(systemName: "forward.end.fill").font(.title2).frame(width: 48, height: 48) }.accessibilityIdentifier("hubNext")
                    }
                    ScrollView(.horizontal) { HStack(spacing: 24) {
                        Button { hub.repeatQueue.toggle() } label: { Label(hub.repeatQueue ? "Repeat on" : "Repeat off", systemImage: "repeat") }.accessibilityIdentifier("hubRepeat")
                        Menu { ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { speed in Button(String(format: "%g×", speed)) { hub.speed = speed } } } label: { Text(String(format: "%g×", hub.speed)) }.accessibilityIdentifier("hubSpeed")
                        if let chapters = item.Chapters, !chapters.isEmpty {
                            Menu { ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in Button(chapter.Name ?? "Chapter \(index + 1)") { hub.seek(Double(chapter.StartPositionTicks) / ticksPerSecond) } } } label: { Label("Chapters", systemImage: "list.bullet") }.accessibilityIdentifier("hubChapters")
                        }
                        if item.Type == "Audio", item.HasLyrics != false { Button { showingLyrics = true } label: { Label("Lyrics", systemImage: "quote.bubble") }.accessibilityIdentifier("hubLyrics") }
                        HubRoutePicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay audio")
                    }.font(.subheadline) }.scrollIndicators(.hidden)
                    if let error = hub.error { Text(error).foregroundStyle(.orange).font(.footnote); Button("Try audio again") { hub.resume() }.accessibilityIdentifier("hubAudioRetry") }
                    if let error = hub.syncError { Text(error).foregroundStyle(.orange).font(.footnote) }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Queue · \(hub.queue.count)").font(.title3.bold())
                        ForEach(Array(hub.queue.enumerated()), id: \.offset) { index, queued in
                            Button {
                                guard let account = session.account, let api = session.api else { return }
                                hub.play(hub.queue, at: index, account: account, api: api)
                            } label: { HStack { Text(queued.Name).lineLimit(1); Spacer(); if index == hub.index { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.reelBlue) } }.padding(.vertical, 8).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityIdentifier("hub-queue-\(index)")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else { ContentUnavailableView("Choose something to hear", systemImage: "music.note") }
            }.padding(24).frame(maxWidth: 650).frame(maxWidth: .infinity)
        }.background(Color.reelBackground).navigationTitle("Now playing").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("hubClosePlayer") } }
        .toolbarMinimizationBehavior(.never, for: .navigationBar)
        .sheet(isPresented: $showingLyrics) { HubLyricsView() }
    }
}

struct HubLyricsView: View {
    @Environment(MediaHub.self) private var hub
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [HubLyrics.Line] = []
    @State private var loading = true
    @State private var error: String?
    @State private var retry = 0
    private var currentLine: Int? { lines.lastIndex { ($0.Start ?? Int64.max) <= Int64(hub.position * ticksPerSecond) } }
    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView("Opening lyrics…") }
                else if let error { FailureView(message: error) { retry += 1 } }
                else if lines.isEmpty { ContentUnavailableView("No lyrics supplied", systemImage: "quote.bubble", description: Text("Add lyrics to this track on Jellyfin to read them here.")) }
                else {
                    ScrollView { VStack(alignment: .leading, spacing: 22) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Button { if let start = line.Start { hub.seek(Double(start) / ticksPerSecond) } } label: { Text(line.Text).font(.title2.weight(.semibold)).foregroundStyle(currentLine == index ? Color.reelBlue : Color.reelText).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).disabled(line.Start == nil).accessibilityIdentifier("hub-lyric-\(index)")
                        }
                    }.padding(24) }.accessibilityIdentifier("hubLyricsScroll")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.reelBackground).navigationTitle("Lyrics").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("hubCloseLyrics") } }
                .toolbarMinimizationBehavior(.never, for: .navigationBar)
                .task(id: "\(hub.current?.id ?? "")|\(retry)") {
                    lines = []; error = nil; loading = true
                    defer { loading = false }
                    guard let item = hub.current, let api = session.api else { return }
                    do { let lyrics: HubLyrics = try await api.get("Audio/\(item.id)/Lyrics"); try Task.checkCancellation(); lines = lyrics.Lyrics }
                    catch is CancellationError { }
                    catch ReelError.server(404) { }
                    catch { self.error = error.localizedDescription }
                }
        }
    }
}

struct HubRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.tintColor = .white; return view }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}

struct HubBookView: View {
    let item: HubItem
    @Environment(Session.self) private var session
    @Environment(MediaHub.self) private var hub
    @State private var reading: HubFile?
    @State private var exporter = HubFileExporter()
    @State private var showingPlayer = false
    private var saved: HubFile? { session.account.flatMap { hub.saved(item, accountID: $0.id) } }
    private var key: String { MediaHub.fileKey(accountID: session.account?.id ?? "", itemID: item.id) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Artwork(item: item.artworkItem, width: 700).aspectRatio(0.7, contentMode: .fit).frame(maxWidth: 260).clipShape(RoundedRectangle(cornerRadius: 16)).frame(maxWidth: .infinity)
                Text(item.Name).font(.largeTitle.bold()).accessibilityIdentifier("hubBookTitle")
                if !item.subtitle.isEmpty { Text(item.subtitle).foregroundStyle(Color.reelMuted) }
                if let overview = item.Overview { Text(overview).font(.body).lineSpacing(5).foregroundStyle(Color.reelMuted) }
                if let saved {
                    Button {
                        if saved.canPlay, let account = session.account, let api = session.api { hub.playSaved(saved, account: account, api: api); showingPlayer = true }
                        else { reading = saved }
                    } label: { Label(saved.canPlay ? "Play saved audiobook" : "Open saved book", systemImage: saved.canPlay ? "play.fill" : "book") }.buttonStyle(PrimaryButton()).accessibilityIdentifier("hubOpenBook")
                    if saved.item.isAudio {
                        ShareLink(item: hub.fileURL(saved)) { Label("Export original file", systemImage: "square.and.arrow.up") }.buttonStyle(QuietButton()).accessibilityIdentifier("hubExportBook")
                    } else {
                        Button { exporter.export(saved, hub: hub, session: session) } label: { Label(exporter.preparing ? "Preparing export…" : "Export original file", systemImage: "square.and.arrow.up") }.buttonStyle(QuietButton()).disabled(exporter.preparing).accessibilityIdentifier("hubExportBook")
                    }
                    Text(ByteCountFormatter.string(fromByteCount: saved.bytes, countStyle: .file) + " · Saved on this device").font(.caption).foregroundStyle(Color.reelBlue)
                    Text("PDF and text files open here. Other formats can be exported to a compatible reader.").font(.footnote).foregroundStyle(Color.reelMuted)
                } else if hub.saving.contains(key) {
                    HStack { ProgressView(); Text("Saving original…"); Button("Cancel") { hub.cancelSave(key) }.accessibilityIdentifier("hubCancelBook") }
                } else {
                    Button { if let account = session.account, let api = session.api { hub.save(item, account: account, api: api) } } label: { Label("Save original & read", systemImage: "arrow.down.circle") }.buttonStyle(PrimaryButton()).accessibilityIdentifier("hubSaveBook")
                }
                if let error = hub.fileErrors[key] { Text(error).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("hubBookError") }
            }.padding(24).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(Color.reelBackground).navigationTitle("Book").navigationBarTitleDisplayMode(.inline)
        .modifier(HubExportPresentation(exporter: exporter))
        .fullScreenCover(item: $reading) { file in HubReaderView(file: file) }
        .sheet(isPresented: $showingPlayer) { NavigationStack { HubNowPlayingView() } }
    }
}

struct HubSavedView: View {
    @Environment(Session.self) private var session
    @Environment(MediaHub.self) private var hub
    @State private var deleting: HubFile?
    @State private var reading: HubFile?
    @State private var exporter = HubFileExporter()
    @State private var player = false
    @State private var error: String?
    private var files: [HubFile] { hub.files.filter { $0.accountID == session.account?.id } }
    private var requests: [String: HubItem] { hub.requestedFiles.filter { $0.key.hasPrefix((session.account?.id ?? "") + "|") } }
    var body: some View {
        List {
            if files.isEmpty && requests.isEmpty { ContentUnavailableView("Take it with you", systemImage: "arrow.down.circle", description: Text("Saved music, audiobooks and books appear here. Save an original from its library first.")) }
            if !requests.isEmpty {
                Section("Transfers") {
                    ForEach(requests.keys.sorted(), id: \.self) { key in
                        if let item = requests[key] { VStack(alignment: .leading, spacing: 10) { Text(item.Name).font(.headline); HubSaveStatus(item: item).buttonStyle(.borderless) }.padding(.vertical, 8).listRowBackground(Color.reelSurface).accessibilityIdentifier("hub-transfer-\(item.id)") }
                    }
                }
            }
            ForEach(files) { file in
                HStack {
                    Button {
                        if file.canPlay, let account = session.account, let api = session.api { hub.playSaved(file, account: account, api: api); player = true }
                        else { reading = file }
                    } label: { VStack(alignment: .leading, spacing: 5) { Text(file.item.Name).font(.headline); Text(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file) + " · " + URL(fileURLWithPath: file.filename).pathExtension.uppercased()).font(.caption).foregroundStyle(Color.reelMuted) }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityIdentifier("hub-saved-\(file.item.id)")
                    Menu {
                        if file.item.isAudio {
                            ShareLink(item: hub.fileURL(file)) { Label("Export original file", systemImage: "square.and.arrow.up") }
                        } else {
                            Button { exporter.export(file, hub: hub, session: session) } label: { Label("Export original file", systemImage: "square.and.arrow.up") }.disabled(exporter.preparing)
                        }
                        Button("Remove saved file", role: .destructive) { deleting = file }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityIdentifier("hub-saved-options-\(file.item.id)")
                }.padding(.vertical, 10).listRowBackground(Color.reelSurface)
            }
            if let error { Text(error).foregroundStyle(.orange) }
            if let error = hub.fileErrors["storage"] { Text(error).foregroundStyle(.orange); Button("Retry storage recovery") { hub.recoverStorage() }.accessibilityIdentifier("hubRetryStorage") }
        }.scrollContentBackground(.hidden).background(Color.reelBackground).navigationTitle("Saved music & books")
        .modifier(HubExportPresentation(exporter: exporter))
        .fullScreenCover(item: $reading) { file in HubReaderView(file: file) }
        .sheet(isPresented: $player) { NavigationStack { HubNowPlayingView() } }
        .confirmationDialog("Remove this saved file?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { file in
            Button("Remove saved file", role: .destructive) { do { try hub.remove(file) } catch { self.error = error.localizedDescription }; deleting = nil }.accessibilityIdentifier("hubConfirmRemoveSaved")
        } message: { _ in Text("The original stays on Jellyfin.") }
    }
}

struct HubPhotoViewer: View {
    let items: [HubItem]
    @State private var selected: String
    @Environment(\.dismiss) private var dismiss
    init(items: [HubItem], initialID: String) { self.items = items; _selected = State(initialValue: initialID) }
    var body: some View {
        NavigationStack {
            TabView(selection: $selected) { ForEach(items) { item in HubPhotoCanvas(item: item).tag(item.id) } }.tabViewStyle(.page(indexDisplayMode: .automatic)).background(.black)
                .navigationTitle(items.first(where: { $0.id == selected })?.Name ?? "Photo").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("hubClosePhoto") } }
                .toolbarMinimizationBehavior(.never, for: .navigationBar)
                .accessibilityIdentifier("hubPhotoViewer")
        }
    }
}

struct HubPhotoCanvas: View {
    let item: HubItem
    @Environment(Session.self) private var session
    @State private var image: UIImage?
    @State private var error: String?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var baseOffset = CGSize.zero
    @State private var retry = 0
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height).scaleEffect(scale).offset(offset)
                        .gesture(MagnifyGesture().onChanged { scale = min(5, max(1, baseScale * $0.magnification)) }.onEnded { _ in baseScale = scale; if scale <= 1 { offset = .zero; baseOffset = .zero } })
                        .gesture(DragGesture().onChanged { value in
                            let horizontal = geometry.size.width * (scale - 1) / 2
                            let vertical = geometry.size.height * (scale - 1) / 2
                            offset = CGSize(width: min(horizontal, max(-horizontal, baseOffset.width + value.translation.width)), height: min(vertical, max(-vertical, baseOffset.height + value.translation.height)))
                        }.onEnded { _ in baseOffset = offset }, including: scale > 1 ? .all : .none)
                        .onTapGesture(count: 2) { scale = scale > 1 ? 1 : 2; baseScale = scale; offset = .zero; baseOffset = .zero }
                        .accessibilityLabel(item.Name).accessibilityIdentifier("hubFullPhoto-\(item.id)")
                } else if let error { FailureView(message: error) { retry += 1 } }
                else { ProgressView("Opening photo…") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }.task(id: "\(session.revision)|\(item.id)|\(retry)") {
            image = nil; error = nil
            guard let api = session.api else { return }
            do {
                let request = api.imageRequest(item.artworkItem, backdrop: false, width: 2560)
                let data = try await ArtworkPipeline.shared.data(request: request, userID: api.userID ?? "", server: api.server)
                let cg = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2560, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                }.value
                try Task.checkCancellation()
                guard let cg else { throw ReelError.invalidResponse }
                image = UIImage(cgImage: cg)
            } catch is CancellationError { }
            catch { self.error = "This photo couldn’t be opened. Check the connection and try again." }
        }
    }
}
