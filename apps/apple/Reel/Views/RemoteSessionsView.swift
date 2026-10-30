import SwiftUI

struct RemoteSessionsView: View {
    var selectedItem: MediaItem? = nil
    @Environment(Session.self) private var session
    @Environment(PlaybackController.self) private var playback
    @Environment(RemoteSessions.self) private var remote
    @Environment(SyncPlayClient.self) private var sync
    @State private var groupName = ""

    var body: some View {
        List {
            if session.api?.isSimulatorPreview == true {
                Section {
                    Label("Preview protects every player", systemImage: "eye")
                    Text("Players and groups can be viewed. Remote commands and group changes are disabled for real servers in the simulator.")
                        .font(.footnote).foregroundStyle(Color.reelMuted)
                }
            }
            if let selectedItem {
                Section("Selected title") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selectedItem.title).font(.headline)
                        Text(selectedItem.subtitle).font(.subheadline).foregroundStyle(Color.reelMuted)
                    }
                }
            }
            Section {
                if remote.loading && remote.sessions.isEmpty { ProgressView("Finding players…") }
                else if remote.sessions.isEmpty {
                    Text("No controllable players are online. Open Jellyfin on a TV or another device with remote control enabled for your account.")
                        .font(.subheadline).foregroundStyle(Color.reelMuted)
                }
                ForEach(remote.sessions) { player in sessionRow(player) }
                if let error = remote.error { Text(error).foregroundStyle(.orange).font(.footnote).accessibilityIdentifier("remoteError") }
                if let notice = remote.notice { Text(notice).font(.footnote).foregroundStyle(Color.reelBlue).accessibilityIdentifier("remoteNotice") }
                Button("Refresh players") { Task { if let api = session.api { await remote.refresh(api: api) } } }.accessibilityIdentifier("refreshRemote")
            } header: { Text("Other players") } footer: {
                Text("Commands control the selected device and can change its watch history. A sent command confirms server acceptance; the receiver controls playback.")
                    .foregroundStyle(Color.reelMuted)
            }
            Section {
                if let group = sync.group {
                    HStack {
                        Label(group.GroupName, systemImage: "person.2.wave.2")
                        Spacer()
                        Text(sync.state).foregroundStyle(Color.reelBlue)
                    }.accessibilityIdentifier("activeSyncGroup")
                    Text("Connected · \(Int(sync.latency * 1_000)) ms round trip").font(.caption).foregroundStyle(Color.reelMuted)
                    if let selectedItem {
                        Button("Play selected title together") { Task { await sync.setQueue(selectedItem) } }.accessibilityIdentifier("syncPlaySelected")
                        Button("Add selected title to group queue") { Task { await sync.enqueue(selectedItem) } }.accessibilityIdentifier("syncQueueSelected")
                    }
                    HStack {
                        Button("Pause") { Task { await sync.request("Pause") } }.accessibilityIdentifier("syncPause")
                        Spacer()
                        Button("Resume") { Task { await sync.request("Unpause") } }.accessibilityIdentifier("syncUnpause")
                        Spacer()
                        Button("Stop") { Task { await sync.request("Stop") } }.accessibilityIdentifier("syncStop")
                    }.buttonStyle(.borderless)
                    HStack {
                        Button("Previous item") { Task { await sync.request("PreviousItem") } }.accessibilityIdentifier("syncPrevious")
                        Spacer()
                        Button("Next item") { Task { await sync.request("NextItem") } }.accessibilityIdentifier("syncNext")
                    }.buttonStyle(.borderless).disabled(sync.currentEntry == nil)
                    Button("Leave group", role: .destructive) { Task { await sync.leave() } }.accessibilityIdentifier("syncLeave")
                } else {
                    if sync.loading && sync.groups.isEmpty { ProgressView("Loading groups…") }
                    ForEach(sync.groups) { group in
                        Button {
                            Task { await sync.join(group) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.GroupName).font(.headline)
                                    Text("\(group.Participants.count) participants · \(group.State)").font(.caption).foregroundStyle(Color.reelMuted)
                                }
                                Spacer()
                                Text("Join").font(.subheadline.weight(.semibold))
                            }.contentShape(Rectangle())
                        }.disabled(sync.busy || !sync.canJoin || protected).accessibilityIdentifier("syncJoin-\(group.id)")
                    }
                    if sync.groups.isEmpty && !sync.loading { Text("No groups are available.").foregroundStyle(Color.reelMuted) }
                    TextField("Group name", text: $groupName).accessibilityIdentifier("syncGroupName")
                    Button {
                        Task { await sync.create(name: groupName) }
                    } label: {
                        Label(sync.busy ? "Connecting…" : "Create a group", systemImage: "plus.circle")
                    }.disabled(sync.busy || !sync.canCreate || protected).accessibilityIdentifier("syncCreate")
                    if !sync.canJoin && !sync.loading {
                        Text("SyncPlay needs playback and group access in your Jellyfin user permissions.").font(.footnote).foregroundStyle(Color.reelMuted)
                    }
                }
                if let error = sync.error { Text(error).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("syncError") }
                Button("Refresh groups") { Task { await sync.refresh() } }.accessibilityIdentifier("refreshSyncGroups")
            } header: { Text("Watch together") } footer: {
                Text("SyncPlay uses Jellyfin’s live group events and server clock to schedule native playback. Leaving stops your local group playback; it does not stop other participants.")
                    .foregroundStyle(Color.reelMuted)
            }
        }
        .scrollContentBackground(.hidden).background(Color.reelBackground)
        .navigationTitle("Players & watch together")
        .task(id: session.revision) {
            sync.configure(api: session.api, playback: playback)
            if let api = session.api {
                async let players: Void = remote.refresh(api: api)
                async let groups: Void = sync.refresh()
                _ = await (players, groups)
            }
        }
        .refreshable {
            if let api = session.api { await remote.refresh(api: api) }
            await sync.refresh()
        }
    }

    private var protected: Bool { session.api?.isSimulatorPreview != false }

    private func sessionRow(_ player: RemoteSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "tv").font(.title2).foregroundStyle(Color.reelBlue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.name).font(.headline)
                    Text([player.Client, player.UserName].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Color.reelMuted)
                }
            }.accessibilityIdentifier("remote-session-\(player.id)")
            if let item = player.NowPlayingItem {
                Text(item.title).font(.subheadline.weight(.semibold))
                Text(player.PlayState?.IsPaused == true ? "Paused" : "Playing").font(.caption).foregroundStyle(Color.reelMuted)
                HStack(spacing: 18) {
                    Button { command("Seek", player: player, offset: -15) } label: { Image(systemName: "gobackward.15") }
                        .disabled(player.PlayState?.CanSeek != true).accessibilityLabel("Back 15 seconds on \(player.name)").accessibilityIdentifier("remote-seek-back-\(player.id)")
                    Button(player.PlayState?.IsPaused == true ? "Resume" : "Pause") { command(player.PlayState?.IsPaused == true ? "Unpause" : "Pause", player: player) }
                        .accessibilityIdentifier(player.PlayState?.IsPaused == true ? "remote-unpause-\(player.id)" : "remote-pause-\(player.id)")
                    Button { command("Seek", player: player, offset: 15) } label: { Image(systemName: "goforward.15") }
                        .disabled(player.PlayState?.CanSeek != true).accessibilityLabel("Forward 15 seconds on \(player.name)").accessibilityIdentifier("remote-seek-forward-\(player.id)")
                    Spacer()
                    Button("Stop") { command("Stop", player: player) }.accessibilityIdentifier("remote-stop-\(player.id)")
                }.disabled(player.SupportsMediaControl != true || remote.busy || protected).buttonStyle(.borderless)
            }
            if let selectedItem {
                HStack(spacing: 18) {
                    Button("Play here") { play(selectedItem, player: player, mode: "PlayNow") }.accessibilityIdentifier("remote-play-\(player.id)")
                    Button("Play next") { play(selectedItem, player: player, mode: "PlayNext") }.accessibilityIdentifier("remote-next-\(player.id)")
                    Button("Queue") { play(selectedItem, player: player, mode: "PlayLast") }.accessibilityIdentifier("remote-queue-\(player.id)")
                }.disabled(!player.acceptsVideo || remote.busy || protected).buttonStyle(.borderless).font(.subheadline)
            }
        }.padding(.vertical, 8).listRowBackground(Color.reelSurface)
    }

    private func command(_ command: String, player: RemoteSession, offset: Double = 0) {
        guard let api = session.api else { return }
        let delta = Int64(offset * ticksPerSecond)
        let (position, overflow) = (player.PlayState?.PositionTicks ?? 0).addingReportingOverflow(delta)
        let target = overflow ? (delta > 0 ? Int64.max : 0) : max(0, position)
        Task { await remote.command(command, session: player, api: api, ticks: target) }
    }
    private func play(_ item: MediaItem, player: RemoteSession, mode: String) {
        guard let api = session.api else { return }
        Task { await remote.play(item, on: player, mode: mode, api: api) }
    }
}
