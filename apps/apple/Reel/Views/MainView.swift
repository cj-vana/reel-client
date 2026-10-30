import SwiftUI

private enum RootTab: Hashable { case home, library, search, downloads, more }

struct MainView: View {
    @Environment(Session.self) private var session
    @Environment(Downloads.self) private var downloads
    @Environment(ServerPreferences.self) private var preferences
    @Environment(MediaHub.self) private var mediaHub
    @Environment(RemoteSessions.self) private var remoteSessions
    @Environment(SyncPlayClient.self) private var syncPlay
    @State private var playback = PlaybackController()
    @State private var selectedTab = RootTab.home
    @State private var sidebarVisible = false
    @State private var foldable = false
    /// Every fold band the screen reports, in global coordinates.
    @State private var divisions: [CGRect] = []
    @State private var screenInsets = EdgeInsets()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @Environment(\.simulatedFoldDivisions) private var simulatedFoldDivisions
    #endif

    /// The fold that Home and Details lay their pages around. Inactive regions count too: a flat,
    /// fully open device still has its crease, and FoldSpread ignores any band that does not leave
    /// two pages on screen.
    private var crease: CGRect? {
        #if DEBUG
        if let simulatedFoldDivisions { return simulatedFoldDivisions.first }
        #endif
        return divisions.first
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(value: RootTab.home) { NavigationStack { HomeView() }.modifier(TabContentStyle(sidebarVisible: $sidebarVisible)) } label: { tabLabel("Home", systemImage: "house", tab: .home) }
            Tab(value: RootTab.library) { NavigationStack { LibraryView(mode: .library) }.modifier(TabContentStyle(sidebarVisible: $sidebarVisible)) } label: { tabLabel("Library", systemImage: "square.grid.2x2", tab: .library) }
            Tab(value: RootTab.search, role: .search) { NavigationStack { LibraryView(mode: .search) }.modifier(TabContentStyle(sidebarVisible: $sidebarVisible)) } label: { tabLabel("Search", systemImage: "magnifyingglass", tab: .search) }
            Tab(value: RootTab.downloads) { NavigationStack { DownloadsView(openLibrary: { selectedTab = .library }) }.modifier(TabContentStyle(sidebarVisible: $sidebarVisible)) } label: { tabLabel("Downloads", systemImage: "arrow.down.circle", tab: .downloads) }
            Tab(value: RootTab.more) { NavigationStack { MoreView() }.modifier(TabContentStyle(sidebarVisible: $sidebarVisible)) } label: { tabLabel("More", systemImage: "ellipsis.circle", tab: .more) }
        }
        // The sidebar's selected row takes the tint as its fill, so it stays neutral there.
        .tint(sidebarVisible ? Color(red: 0.22, green: 0.22, blue: 0.235) : .reelBlue)
        .tabViewStyle(.sidebarAdaptable)
        // On an open foldable the sidebar takes a whole page, so it starts hidden there and the
        // library spans both pages. The sidebar button still opens it.
        .defaultTabBarPlacement(horizontalSizeClass == .regular && !foldable && crease == nil ? .sidebar : .tabBar)
        .onGeometryChange(for: Bool.self) { proxy in
            guard #available(iOS 27.1, *) else { return false }
            return !proxy.reservedRegions(kind: .division, options: .includeInactive).isEmpty
        } action: { foldable = $0 }
        .onGeometryChange(for: [CGRect].self) { proxy in
            guard #available(iOS 27.1, *) else { return [] }
            let origin = proxy.frame(in: .global).origin
            return proxy.reservedRegions(kind: .division, options: .includeInactive).map { $0.frame.offsetBy(dx: origin.x, dy: origin.y) }
        } action: { divisions = $0 }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { screenInsets = $0 }
        .tabViewSidebarHeader { ReelMark().padding(.vertical, 16) }
        .environment(\.foldCrease, crease)
        .environment(\.screenInsets, screenInsets)
        .environment(playback)
        .fullScreenCover(isPresented: Binding(get: { playback.activeItem != nil }, set: { if !$0 { playback.stop(); playback.activeItem = nil } })) {
            if let item = playback.activeItem { PlayerView(item: item).tint(Color.reelBlue).environment(playback).environment(session).environment(downloads).environment(mediaHub).environment(remoteSessions).environment(syncPlay).environment(preferences) }
        }
        .task {
            session.beforeRemove = { account in
                if !(await downloads.flushCleanup(accountID: account.id, api: JellyfinAPI(server: account.server, token: account.token, userID: account.userID, deviceID: session.deviceID, historyEnabled: !session.privateViewing))) { session.notice = "The server couldn’t confirm download cleanup. Its abandoned encoder will need to expire." }
                if syncPlay.ownsAccount(account.id) { await syncPlay.leave() }
                if account.id == session.account?.id {
                    mediaHub.stop()
                    playback.stop(); playback.activeItem = nil
                    await mediaHub.flushReports()
                    await playback.flushReports()
                }
            }
            playback.onWillPresent = { mediaHub.stop(); CastCoordinator.shared.endCasting() }
            mediaHub.onWillPlay = { playback.stop(); playback.activeItem = nil; CastCoordinator.shared.endCasting() }
            remoteSessions.reset(api: session.api)
            syncPlay.configure(api: session.api, playback: playback)
            if let account = session.account, let api = session.api {
                mediaHub.bind(account: account, api: api)
                PlaybackReporter.updatePrivacy(api: api)
                await preferences.activate(accountID: account.id, api: api)
                await playback.retryReports(api: api)
                session.libraryRevision += 1
            }
        }
        .onChange(of: session.privateViewing) { _, _ in
            if let account = session.account, let api = session.api {
                PlaybackReporter.updatePrivacy(api: api)
                mediaHub.bind(account: account, api: api)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, let api = session.api { Task { await playback.retryReports(api: api); session.libraryRevision += 1 } }
        }
    }

    /// In the sidebar only the selected row's icon is mint; the others are muted. The tab bar
    /// keeps template symbols, which follow the tint.
    @ViewBuilder private func tabLabel(_ title: String, systemImage: String, tab: RootTab) -> some View {
        if sidebarVisible, let symbol = UIImage(systemName: systemImage) {
            let color = UIColor(tab == selectedTab ? Color.reelBlue : Color.reelMuted)
            Label { Text(title) } icon: { Image(uiImage: symbol.withTintColor(color, renderingMode: .alwaysOriginal)) }
        } else {
            Label(title, systemImage: systemImage)
        }
    }
}

private struct TabContentStyle: ViewModifier {
    @Environment(\.tabBarPlacement) private var placement
    @Binding var sidebarVisible: Bool

    func body(content: Content) -> some View {
        content
            .tint(Color.reelBlue)
            .onChange(of: placement, initial: true) { _, placement in
                sidebarVisible = placement == .sidebar
            }
    }
}

private struct MoreView: View {
    var body: some View {
        List {
            Section("Explore") {
                NavigationLink { MediaHubView() } label: {
                    destination("Media", subtitle: "Music, photos and books", icon: "music.note.house")
                }.accessibilityLabel("Media").accessibilityIdentifier("Media")
                NavigationLink { LiveTVView() } label: {
                    destination("Live TV", subtitle: "Channels, guide and recordings", icon: "tv")
                }.accessibilityLabel("Live TV").accessibilityIdentifier("Live TV")
                NavigationLink { RequestsView() } label: {
                    destination("Requests", subtitle: "Find something new to watch", icon: "sparkle.magnifyingglass")
                }.accessibilityLabel("Requests").accessibilityIdentifier("Requests")
            }.listRowBackground(Color.clear)
            Section("Your Reel") {
                NavigationLink { RemoteSessionsView() } label: {
                    destination("Devices", subtitle: "Remote playback and watch together", icon: "airplay.video")
                }.accessibilityLabel("Devices").accessibilityIdentifier("Devices")
                NavigationLink { SettingsView() } label: {
                    destination("Settings", subtitle: "Accounts, privacy and playback", icon: "slider.horizontal.3")
                }.accessibilityLabel("Settings").accessibilityIdentifier("Settings")
            }.listRowBackground(Color.clear)
        }
        .listStyle(.plain).modifier(ReadableColumn()).scrollContentBackground(.hidden)
        .reelCanvas().navigationTitle("More").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ServerSwitcher() } }
    }
    private func destination(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 22, weight: .regular)).foregroundStyle(Color.reelMuted)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(Color.reelText)
                Text(subtitle).font(.subheadline).foregroundStyle(Color.reelMuted).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 14).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading).contentShape(Rectangle())
    }
}
