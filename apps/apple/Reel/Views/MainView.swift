import SwiftUI

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
    @State private var windowWidth: CGFloat = 0
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

    /// Reel's own sidebar, on a regular-width window wide enough for it. An open foldable keeps the
    /// bar beside the screen instead, so the library spans both pages.
    private func sidebarWidth(in windowWidth: CGFloat) -> CGFloat? {
        guard horizontalSizeClass == .regular, !foldable, crease == nil else { return nil }
        return ReelSidebar.width(for: windowWidth)
    }

    var body: some View {
        let sidebarWidth = sidebarWidth(in: windowWidth)
        HStack(spacing: 0) {
            if let sidebarWidth {
                ReelSidebar(selection: $selectedTab)
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            tabs(hidesTabBar: sidebarWidth != nil)
        }
        .animation(.smooth(duration: 0.3), value: sidebarWidth == nil)
        // The sidebar lists More's destinations itself, and the tab bar reaches them through More.
        .onChange(of: sidebarWidth == nil) { _, tabBar in
            if tabBar, [.media, .liveTV, .requests, .devices, .settings].contains(selectedTab) { selectedTab = .more }
            if !tabBar, selectedTab == .more { selectedTab = .home }
        }
        // Only the width decides the layout. The keyboard changes the height, and drawing the tabs again
        // while a field takes focus puts the field back, which raises the keyboard again: on a Duo's outer
        // screen that never settled and froze the app.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            // The first measurement places the sidebar without sliding it in.
            var transaction = Transaction()
            transaction.disablesAnimations = windowWidth == 0
            withTransaction(transaction) { windowWidth = width }
        }
        .background { Color.reelBackground.ignoresSafeArea() }
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

    private func tabs(hidesTabBar: Bool) -> some View {
        let style = TabContentStyle(sidebarVisible: $sidebarVisible, hidesTabBar: hidesTabBar)
        return TabView(selection: $selectedTab) {
            Tab(value: RootTab.home) { NavigationStack { HomeView() }.modifier(style) } label: { tabLabel("Home", systemImage: "house", tab: .home) }
            Tab(value: RootTab.library) { NavigationStack { LibraryView(mode: .library) }.modifier(style) } label: { tabLabel("Library", systemImage: "square.grid.2x2", tab: .library) }
            Tab(value: RootTab.search, role: .search) { NavigationStack { LibraryView(mode: .search) }.modifier(style) } label: { tabLabel("Search", systemImage: "magnifyingglass", tab: .search) }
            Tab(value: RootTab.downloads) { NavigationStack { DownloadsView(openLibrary: { selectedTab = .library }) }.modifier(style) } label: { tabLabel("Downloads", systemImage: "arrow.down.circle", tab: .downloads) }
            // Reel's iPad sidebar lists More's screens as rows of their own. The tab bar keeps More,
            // and only five tabs, so iOS adds no overflow tab of its own.
            if hidesTabBar {
                Tab(value: RootTab.media) { NavigationStack { MediaHubView() }.modifier(style) } label: { tabLabel("Media", systemImage: "rectangle.stack", tab: .media) }
                Tab(value: RootTab.liveTV) { NavigationStack { LiveTVView() }.modifier(style) } label: { tabLabel("Live TV", systemImage: "tv", tab: .liveTV) }
                Tab(value: RootTab.requests) { NavigationStack { RequestsView() }.modifier(style) } label: { tabLabel("Requests", systemImage: "sparkle.magnifyingglass", tab: .requests) }
                Tab(value: RootTab.devices) { NavigationStack { RemoteSessionsView() }.modifier(style) } label: { tabLabel("Devices", systemImage: "airplay.video", tab: .devices) }
                Tab(value: RootTab.settings) { NavigationStack { SettingsView() }.modifier(style) } label: { tabLabel("Settings", systemImage: "slider.horizontal.3", tab: .settings) }
            } else {
                Tab(value: RootTab.more) { NavigationStack { MoreView() }.modifier(style) } label: { tabLabel("More", systemImage: "ellipsis.circle", tab: .more) }
            }
        }
        // The system sidebar's selected row takes the tint as its fill, so it stays neutral there.
        .tint(sidebarVisible ? Color(red: 0.22, green: 0.22, blue: 0.235) : .reelBlue)
        // Phones and foldables use the tab bar. On iPad, Reel's own sidebar stands in for the tab bar,
        // and the tab-bar-only style keeps the system from adding a second sidebar beside it.
        .modifier(AdaptiveTabStyle(tabBarOnly: hidesTabBar))
        .defaultTabBarPlacement(.tabBar)
        .onGeometryChange(for: Bool.self) { proxy in
            guard #available(iOS 27.1, *) else { return false }
            return !proxy.reservedRegions(kind: .division, options: .includeInactive).isEmpty
        } action: { foldable = $0 }
        .onGeometryChange(for: [CGRect].self) { proxy in
            guard #available(iOS 27.1, *) else { return [] }
            let origin = proxy.frame(in: .global).origin
            return proxy.reservedRegions(kind: .division, options: .includeInactive).map { $0.frame.offsetBy(dx: origin.x, dy: origin.y) }
        } action: { divisions = $0 }
        // Only the sides, where a foldable's strip sits. Nothing reads the top or bottom, and the bottom
        // moves with the keyboard, which would redraw every tab each time it rises.
        .onGeometryChange(for: EdgeInsets.self) { proxy in
            EdgeInsets(top: 0, leading: proxy.safeAreaInsets.leading, bottom: 0, trailing: proxy.safeAreaInsets.trailing)
        } action: { screenInsets = $0 }
        .tabViewSidebarHeader { ReelMark().padding(.vertical, 16) }
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

private struct AdaptiveTabStyle: ViewModifier {
    var tabBarOnly: Bool
    func body(content: Content) -> some View {
        if tabBarOnly { content.tabViewStyle(.tabBarOnly) } else { content.tabViewStyle(.sidebarAdaptable) }
    }
}

private struct TabContentStyle: ViewModifier {
    @Environment(\.tabBarPlacement) private var placement
    @Binding var sidebarVisible: Bool
    /// True while Reel's own sidebar is on screen, which stands in for the tab bar.
    var hidesTabBar = false

    func body(content: Content) -> some View {
        content
            .toolbarVisibility(hidesTabBar ? .hidden : .automatic, for: .tabBar)
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
                    destination("Media", subtitle: "Music, photos and books", icon: "rectangle.stack")
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
