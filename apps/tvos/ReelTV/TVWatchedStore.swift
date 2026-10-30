import Foundation
import Observation

/// One ephemeral client operation at a time; cancellation cannot undo server work.
@MainActor @Observable final class TVWatchedLane {
    private var owner: UUID?
    var busy: Bool { owner != nil }
    func acquire(_ id: UUID) -> Bool { guard owner == nil else { return false }; owner = id; return true }
    func release(_ id: UUID) { if owner == id { owner = nil } }
}

@MainActor @Observable final class TVWatchedStore {
    enum Outcome: Equatable {
        case saved, confirmed, failed(String), uncertain(String), review(String), unsupported(String), notStarted
    }
    struct Entry: Identifiable {
        var plan: WatchedMutationPlan
        var outcome: Outcome
        var id: String { plan.itemID }
    }
    struct Confirmation: Identifiable {
        let id = UUID()
        let plans: [WatchedMutationPlan]
        let queryKey: String
        var replacing = true
        /// "Mark as watched", "Mark season as watched", or "Mark 3 titles as watched" for a selection.
        var action: String {
            let played = plans.first?.played == true
            guard plans.count == 1 else { return "Mark \(plans.count) titles as \(played ? "watched" : "unwatched")" }
            return TVWatchedStore.action(type: plans[0].type, played: played)
        }
        var title: String { action + "?" }
        var message: String {
            let state = plans.first?.played == true ? "watched" : "unwatched"
            guard plans.count == 1, let plan = plans.first else {
                return "The selected titles will show as \(state). A selected series, season or collection includes everything in it, even titles not loaded on this page. Resume points can be cleared."
            }
            switch plan.type {
            case "Series": return "Every episode of “\(plan.name)” will show as \(state), including episodes outside the current filters. Continue watching and Up next may change, and resume points can be cleared."
            case "Season": return "Every episode in “\(plan.name)” will show as \(state), including episodes outside the current filters. Continue watching and Up next may change, and resume points can be cleared."
            default:
                guard plan.isBulk else { return "Jellyfin will show “\(plan.name)” as \(state), and its resume point can be cleared." }
                return "Everything in “\(plan.name)” will show as \(state), including titles outside the current filters. Jellyfin decides which titles this container includes, and resume points can be cleared."
            }
        }
    }
    private struct Scope: Equatable {
        let type: String?
        let kind: WatchedItemKind
        init(_ item: MediaItem) { type = item.Type; kind = item.watchedKind }
        init(_ plan: WatchedMutationPlan) { type = plan.type; kind = plan.kind }
    }
    private struct Resolution { let outcome: Outcome; let plan: WatchedMutationPlan?; var scope: Scope? = nil }
    private(set) var selecting = false
    private(set) var selected: Set<String> = []
    var confirmation: Confirmation?
    private(set) var entries: [Entry] = []
    private(set) var busy = false
    private(set) var message: String?
    private var accountID: String?
    private var revision: UUID?
    private var queryKey = ""
    private var metadata: [String: Scope] = [:]
    private var generation = UUID()
    private var exitAfterStop = false
    @ObservationIgnored private var lane: TVWatchedLane?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var send: ((WatchedMutationPlan, JellyfinAPI) async throws -> Void)?
    @ObservationIgnored var read: ((String, JellyfinAPI) async throws -> MediaItem)?

    var canStart: Bool { !busy && lane?.busy != true }
    var anotherOperation: Bool { !busy && lane?.busy == true }
    var retryable: [WatchedMutationPlan] { entries.compactMap { entry in
        switch entry.outcome { case .failed, .notStarted: entry.plan; default: nil }
    } }
    var reviewPlans: [WatchedMutationPlan] { entries.compactMap { entry in
        if case .review = entry.outcome { entry.plan } else { nil }
    } }
    var uncertain: Bool { entries.contains {
        switch $0.outcome { case .uncertain, .unsupported: true; default: false }
    } }
    var summary: String {
        let saved = entries.filter { $0.outcome == .saved }.count
        let confirmed = entries.filter { $0.outcome == .confirmed }.count
        let failed = entries.filter { if case .failed = $0.outcome { true } else { false } }.count
        let unknown = entries.filter { if case .uncertain = $0.outcome { true } else { false } }.count
        let review = entries.filter { if case .review = $0.outcome { true } else { false } }.count
        let unsupported = entries.filter { if case .unsupported = $0.outcome { true } else { false } }.count
        let remaining = entries.filter { $0.outcome == .notStarted }.count
        return "\(saved) requests accepted · \(confirmed) states confirmed · \(failed) failed · \(unknown) unconfirmed · \(remaining) not started · \(review) need review · \(unsupported) unsupported"
    }
    static func refusal(_ session: Session) -> String? {
        guard let api = session.api else { return "Connect to Jellyfin to change watched status." }
        if api.isSimulatorPreview { return "This test build can’t change watched status on this server." }
        if !api.recordsHistory { return "Turn off Private viewing to change watched status." }
        return nil
    }
    /// The action for one title. A series or season names its scope: "Mark season as watched".
    nonisolated static func action(type: String?, played: Bool) -> String {
        let scope = type == "Series" ? "series " : type == "Season" ? "season " : ""
        return "Mark \(scope)as \(played ? "watched" : "unwatched")"
    }
    static func eligible(_ item: MediaItem) -> Bool { item.supportsWatchedMutation }
    static let selectionLimit = 500

    func configure(session: Session, key: String, items: [MediaItem], lane: TVWatchedLane? = nil) {
        if let lane { self.lane = lane }
        if accountID != session.account?.id || revision != session.revision || queryKey != key {
            invalidate(); accountID = session.account?.id; revision = session.revision; queryKey = key
        }
        let changed = items.contains { item in metadata[item.id].map { $0 != Scope(item) } ?? false }
        if changed { invalidate(); message = "A title’s watched scope changed. Choose it again and review the current scope before changing history." }
        for item in items { metadata[item.id] = Scope(item) }
        let retained = selected.intersection(Set(items.map(\.id)))
        if retained != selected { selected = retained; confirmation = nil }
    }
    func begin() { guard !busy else { return }; selecting = true; selected = []; entries = []; message = nil }
    func toggle(_ item: MediaItem) {
        guard selecting, !busy else { return }
        guard Self.eligible(item) else { message = "This item type can’t change watched status here. Reload its metadata before trying again."; return }
        if selected.contains(item.id) { selected.remove(item.id) }
        else {
            guard selected.count < Self.selectionLimit else { message = "Select up to \(Self.selectionLimit) titles per batch."; return }
            selected.insert(item.id)
        }
        confirmation = nil
    }
    func selectLoaded(_ items: [MediaItem], session: Session) {
        guard !busy, let account = session.account else { return }
        let eligible = items.filter { Self.eligible($0) && WatchedMutationPlan(item: $0, played: true, account: account, revision: session.revision).path != nil }
        var seen: Set<String> = []
        let unique = eligible.filter { seen.insert($0.id).inserted }
        selected = Set(unique.prefix(Self.selectionLimit).map(\.id))
        if unique.count > Self.selectionLimit { message = "Selected the first \(Self.selectionLimit) loaded titles. Submit another batch for the rest." }
        confirmation = nil
    }
    func clear() { guard !busy else { return }; selected = []; confirmation = nil }
    func finishSelection() { guard !busy else { return }; selecting = false; selected = []; confirmation = nil }
    func request(_ items: [MediaItem], played: Bool, session: Session, key: String) {
        guard canStart, let account = session.account, Self.refusal(session) == nil,
              queryKey == key, accountID == account.id, revision == session.revision else { return }
        var seen: Set<String> = []
        let plans = items.filter { seen.insert($0.id).inserted }.map { WatchedMutationPlan(item: $0, played: played, account: account, revision: session.revision) }
        guard !plans.isEmpty, plans.allSatisfy({ $0.path != nil && metadata[$0.itemID] == Scope($0) }) else {
            message = "Reload these titles before changing watched status; item metadata or an identifier is unsupported."; return
        }
        confirmation = Confirmation(plans: plans, queryKey: key)
    }
    func confirm(session: Session) {
        guard let pending = confirmation else { return }
        confirmation = nil
        guard pending.queryKey == queryKey else { return }
        perform(pending.plans, session: session, replacing: pending.replacing)
    }
    func retry(session: Session) { perform(retryable, session: session, replacing: false) }
    func reviewChanges(session: Session) {
        let plans = reviewPlans
        guard canStart, !plans.isEmpty, Self.refusal(session) == nil,
              plans.allSatisfy({ $0.isCurrent(account: session.account, revision: session.revision) && metadata[$0.itemID] == Scope($0) }) else { return }
        confirmation = Confirmation(plans: plans, queryKey: queryKey, replacing: false)
    }
    func cancelRemaining() { confirmation = nil; task?.cancel() }
    func exitWithBack() {
        if confirmation != nil { confirmation = nil; return }
        if busy { exitAfterStop = true; cancelRemaining(); message = "Stopping remaining changes. An issued request may still complete." }
        else { finishSelection() }
    }
    func invalidate() {
        generation = UUID(); task?.cancel(); task = nil; busy = false; confirmation = nil; exitAfterStop = false
        selecting = false; selected = []; entries = []; message = nil; metadata = [:]
    }
    func policyChanged() { confirmation = nil; cancelRemaining() }
    func dismissResult() { guard !busy else { return }; entries = []; message = nil }
    private func finishOperation(_ operation: UUID) {
        guard generation == operation else { return }
        busy = false; task = nil
        if exitAfterStop { selecting = false; selected = []; exitAfterStop = false }
    }
    private func current(_ plan: WatchedMutationPlan, session: Session, operation: UUID) -> Bool {
        generation == operation && plan.isCurrent(account: session.account, revision: session.revision)
            && accountID == plan.accountID && revision == plan.accountRevision
    }
    private func apply(_ resolution: Resolution, to id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].outcome = resolution.outcome
        if let scope = resolution.scope { metadata[id] = scope }
        if let plan = resolution.plan { entries[index].plan = plan; metadata[id] = Scope(plan) }
    }
    private func perform(_ plans: [WatchedMutationPlan], session: Session, replacing: Bool) {
        guard canStart, !plans.isEmpty, Self.refusal(session) == nil, let api = session.api,
              plans.allSatisfy({ $0.isCurrent(account: session.account, revision: session.revision) && $0.path != nil && metadata[$0.itemID] == Scope($0) }) else { return }
        let operation = UUID(), operationLane = lane
        guard operationLane?.acquire(operation) != false else { return }
        generation = operation; busy = true; message = nil
        if replacing { entries = plans.map { Entry(plan: $0, outcome: .notStarted) } }
        task = Task { @MainActor in
            var possibleEffects = false
            defer {
                if possibleEffects { _ = session.invalidateCatalogue(accountID: plans[0].accountID, revision: plans[0].accountRevision) }
                operationLane?.release(operation); self.finishOperation(operation)
            }
            for plan in plans {
                guard !Task.isCancelled, self.current(plan, session: session, operation: operation),
                      self.metadata[plan.itemID] == Scope(plan), Self.refusal(session) == nil else { break }
                possibleEffects = true
                let resolution: Resolution
                var stop = false
                do {
                    if let send = self.send { try await send(plan, api) }
                    else {
                        let response: UserData = try await api.decode(api.request(plan.path!, query: ["userId": api.userID ?? ""], method: plan.method))
                        guard response.Played != nil else { throw ReelError.invalidResponse }
                    }
                    resolution = Resolution(outcome: .saved, plan: nil)
                } catch {
                    if error is CancellationError {
                        resolution = Resolution(outcome: .uncertain("The request may have reached Jellyfin. Check status before retrying."), plan: nil); stop = true
                    } else if let error = error as? ReelError, error == .unauthorized || error == .previewProtected {
                        resolution = Resolution(outcome: .failed(error == .unauthorized ? "Jellyfin refused this change. Check your sign-in and account permissions, then retry." : error.localizedDescription), plan: nil); stop = true
                    } else { resolution = await self.resolve(plan, api: api) }
                }
                guard self.current(plan, session: session, operation: operation) else { return }
                self.apply(resolution, to: plan.itemID)
                if stop { break }
            }
            if self.generation == operation { self.message = "Jellyfin determines contained-title effects. Review refreshed status before another change." }
        }
    }
    private func resolve(_ plan: WatchedMutationPlan, api: JellyfinAPI) async -> Resolution {
        do {
            let item: MediaItem
            if let read { item = try await read(plan.itemID, api) } else { item = try await api.item(plan.itemID) }
            guard item.id == plan.itemID else { throw WatchedReadbackError.wrongItem }
            guard item.supportsWatchedMutation else { return Resolution(outcome: .unsupported(WatchedReadbackError.unsupportedType.localizedDescription), plan: nil, scope: Scope(item)) }
            let refreshed = try plan.refreshed(from: item), observed = WatchedReadback(item: item)
            if refreshed.type != plan.type || refreshed.kind != plan.kind {
                return Resolution(outcome: .review("The title’s watched scope changed. " + observed.summary + " Review the new scope before another request."), plan: refreshed)
            }
            if observed.matches(plan.played) { return Resolution(outcome: .confirmed, plan: refreshed) }
            if refreshed.isBulk {
                return Resolution(outcome: .review(observed.summary + " This cannot confirm every descendant. Review before repeating the container request."), plan: refreshed)
            }
            guard observed.leafPlayed != nil else { return Resolution(outcome: .uncertain("Jellyfin did not return usable watched status. Check status again."), plan: refreshed) }
            return Resolution(outcome: .failed("Jellyfin still reports a different watched status. Retry is available."), plan: refreshed)
        } catch let error as WatchedReadbackError { return Resolution(outcome: .unsupported(error.localizedDescription), plan: nil) }
        catch { return Resolution(outcome: .uncertain("The request may have completed, but its status couldn’t be read. Check status before retrying."), plan: nil) }
    }
    func checkStatus(session: Session) {
        guard canStart, let api = session.api, let first = entries.first,
              first.plan.isCurrent(account: session.account, revision: session.revision) else { return }
        let operation = UUID(), operationLane = lane
        guard operationLane?.acquire(operation) != false else { return }
        generation = operation; busy = true
        task = Task { @MainActor in
            defer { operationLane?.release(operation); self.finishOperation(operation) }
            for entry in self.entries {
                guard !Task.isCancelled, self.current(entry.plan, session: session, operation: operation) else { return }
                switch entry.outcome { case .uncertain, .unsupported: break; default: continue }
                let resolution = await self.resolve(entry.plan, api: api)
                guard self.current(entry.plan, session: session, operation: operation) else { return }
                self.apply(resolution, to: entry.id)
            }
            _ = session.invalidateCatalogue(accountID: first.plan.accountID, revision: first.plan.accountRevision)
        }
    }
}
