import Foundation
import Observation

struct TVLibraryDestination: Hashable {
    let category: String?
    let sort: LibrarySort?
    let parent: MediaItem?
    let intentID = UUID()
}

@MainActor @Observable final class TVHomeStore {
    private struct Identity: Equatable {
        let server: URL; let user: String?; let token: String?
        init(_ api: JellyfinAPI) { server = api.server; user = api.userID; token = api.token }
    }
    private enum Shelf: CaseIterable, Sendable { case resume, next, movies, series, episodes }
    private(set) var loading = false
    private(set) var resume: [MediaItem] = []
    private(set) var next: [MediaItem] = []
    private(set) var movies: [MediaItem] = []
    private(set) var series: [MediaItem] = []
    private(set) var episodes: [MediaItem] = []
    private(set) var episodesLoading = false
    private(set) var episodeError: String?
    private var errors: [Shelf: String] = [:]
    private var generation = UUID()
    private var identity: Identity?
    private var episodeTask: Task<Result<[MediaItem], Error>, Never>?
    private var episodeGeneration = UUID()

    var featured: MediaItem? { movies.first ?? series.first ?? resume.first ?? next.first ?? episodes.first }
    var partial: Bool { featured != nil && !errors.isEmpty }
    var error: String? { featured == nil ? Shelf.allCases.compactMap { errors[$0] }.first : nil }

    func load(api: JellyfinAPI) async {
        let current = UUID(); generation = current
        episodeGeneration = UUID(); episodeTask?.cancel(); episodeTask = nil
        loading = true; episodesLoading = true
        let nextIdentity = Identity(api)
        if identity != nextIdentity {
            resume = []; next = []; movies = []; series = []; episodes = []
            identity = nextIdentity
        }
        errors = [:]; episodeError = nil
        defer { if generation == current { loading = false; episodesLoading = false } }
        await withTaskGroup(of: (Shelf, Result<[MediaItem], Error>).self) { group in
            for shelf in Shelf.allCases {
                group.addTask { (shelf, await Self.fetch(shelf, api: api)) }
            }
            for await (shelf, result) in group {
                guard !Task.isCancelled, generation == current else { group.cancelAll(); continue }
                switch result {
                case .success(let items):
                    errors[shelf] = nil
                    switch shelf {
                    case .resume: resume = items
                    case .next: next = items
                    case .movies: movies = items
                    case .series: series = items
                    case .episodes: episodes = items
                    }
                case .failure(let failure):
                    errors[shelf] = failure.localizedDescription
                }
                if shelf == .episodes {
                    episodesLoading = false
                    episodeError = errors[shelf]
                }
            }
        }
    }

    func cancel() {
        generation = UUID(); episodeGeneration = UUID()
        episodeTask?.cancel(); episodeTask = nil
        loading = false; episodesLoading = false
    }

    func retryEpisodes(api: JellyfinAPI) async {
        guard !episodesLoading, identity == Identity(api) else { return }
        let current = generation, request = UUID(); episodeGeneration = request
        episodesLoading = true; episodeError = nil
        defer { if generation == current, episodeGeneration == request { episodesLoading = false; episodeTask = nil } }
        let task = Task { await Self.fetch(.episodes, api: api) }; episodeTask = task
        let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        guard !Task.isCancelled, generation == current, episodeGeneration == request else { return }
        switch result {
        case .success(let items): episodes = items; episodeError = nil; errors[.episodes] = nil
        case .failure(let failure): episodeError = failure.localizedDescription; errors[.episodes] = failure.localizedDescription
        }
    }

    private nonisolated static func fetch(_ shelf: Shelf, api: JellyfinAPI) async -> Result<[MediaItem], Error> {
        do {
            let items: [MediaItem]
            switch shelf {
            case .resume: items = try await api.page("UserItems/Resume", query: ["mediaTypes": "Video", "limit": "12"]).Items
            case .next: items = try await api.page("Shows/NextUp", query: ["limit": "12"]).Items
            case .movies: items = try await api.latest(type: "Movie")
            case .series: items = try await api.latest(type: "Series")
            case .episodes:
                let query = LibraryQuery(category: "Episodes", sort: .recentlyAdded).parameters(start: 0, limit: 18)
                items = try await api.page("Items", query: query).Items
            }
            try Task.checkCancellation()
            // Preserve individual episodes from the same series; only repeat item IDs collapse.
            var known = Set<String>()
            return .success(items.filter { known.insert($0.id).inserted })
        } catch { return .failure(error) }
    }
}
