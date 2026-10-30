import SwiftUI

struct TVRootView: View {
    @Environment(TVCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var phase

    var body: some View {
        @Bindable var coordinator = coordinator
        let presentationID = coordinator.presentationID
        NavigationStack(path: $coordinator.path) {
            TabView(selection: $coordinator.tab) {
                Tab("Home", systemImage: "house", value: TVTab.home) { TVHomeView().id(coordinator.session.revision) }
                Tab("Movies", systemImage: "film", value: TVTab.movies) {
                    TVLibraryView(destination: coordinator.moviesTab, section: "Movies").id(coordinator.session.revision)
                }
                Tab("Series", systemImage: "tv", value: TVTab.shows) {
                    TVLibraryView(destination: coordinator.showsTab, section: "Series").id(coordinator.session.revision)
                }
                Tab("Search", systemImage: "magnifyingglass", value: TVTab.search) { TVLibraryView(searching: true).id(coordinator.session.revision) }
                Tab("Library", systemImage: "square.grid.2x2", value: TVTab.library) { TVLibraryView().id(coordinator.session.revision) }
                Tab("Settings", systemImage: "gearshape", value: TVTab.settings) { TVSettingsView() }
            }
            .navigationDestination(for: TVRoute.self) { route in
                switch route {
                case .detail(let id): TVDetailView(id: id)
                case .library(let destination): TVLibraryView(destination: destination).id(coordinator.session.revision)
                }
            }
        }
        .background(Color.reelBackground)
        .fullScreenCover(isPresented: Binding(get: { coordinator.showingPlayer }, set: { if !$0 { Task { await coordinator.closePlayback(id: presentationID) } } }), onDismiss: { coordinator.presentationDismissed(id: presentationID) }) {
            TVPlayerScreen(id: coordinator.presentationID).id(coordinator.presentationID)
        }
        .task(id: coordinator.session.revision) { await coordinator.activated() }
        .onChange(of: phase) { _, value in
            if value == .background { coordinator.playback.player.pause(); coordinator.playback.reportPauseState() }
            if value == .active, let api = coordinator.session.api { Task { await coordinator.playback.retryReports(api: api) } }
        }
    }
}
