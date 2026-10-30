import SwiftUI

struct LiveTVView: View {
    private struct Cancellation {
        let timer: LiveTVTimer
        let series: Bool
    }

    @Environment(Session.self) private var session
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var store = LiveTVStore()
    @State private var section: LiveTVSection = .channels
    @State private var date = Date.now
    @State private var channelID = ""
    @State private var selectedProgram: LiveTVProgram?
    @State private var pendingWatch: String?
    @State private var cancelling: Cancellation?
    @State private var actionError: String?
    private var loadKey: String { section.rawValue + "|" + LiveTVDate.string(LiveTVDate.interval(for: date).start) + "|" + channelID }
    private var canManage: Bool { session.api.map { store.canManage(api: $0) } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    // The same pills as the Library rail: white when selected, a quiet fill otherwise.
                    ForEach(LiveTVSection.allCases) { value in
                        let selected = section == value
                        Button { section = value } label: {
                            Text(value.rawValue).font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: true, vertical: false).padding(.horizontal, 16).frame(minWidth: 44, minHeight: 44)
                                .foregroundStyle(selected ? Color.reelBackground : Color.reelText)
                                .background(selected ? Color.reelText : Color.reelFill, in: Capsule())
                                .contentShape(Capsule())
                        }.buttonStyle(.plain).accessibilityIdentifier("tv-\(value.rawValue)")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding(.vertical, 8)
            }.contentMargins(.horizontal, Self.margin, for: .scrollContent).scrollIndicators(.hidden)
            if section == .guide { guideControls }
            if let api = session.api, api.isSimulatorPreview {
                Label("Preview: recording changes are disabled on your real server.", systemImage: "eye")
                    .font(.caption).foregroundStyle(Color.reelMuted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Self.margin).padding(.bottom, 10)
            } else if store.policy?.EnableLiveTvManagement == false {
                Label("Recording changes need permission.", systemImage: "lock")
                    .font(.caption).foregroundStyle(Color.reelMuted).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Self.margin).padding(.bottom, 10)
            }
            content
        }
        .background(Color.reelBackground).navigationTitle("Live TV")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await refresh(permissions: true) } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh Live TV").accessibilityIdentifier("refreshLiveTV") } }
        .task(id: loadKey) { await refresh() }
        .task { if let api = session.api { await store.loadPermissions(api: api) } }
        .sheet(item: $selectedProgram, onDismiss: playPendingChannel) { program in
            NavigationStack {
                LiveTVProgramDetailView(program: program, allowManagement: canManage, onRecorded: { await refresh() }, onWatch: { id in pendingWatch = id; selectedProgram = nil })
            }
        }
        .confirmationDialog(cancelling?.series == true ? "Cancel this series rule?" : "Cancel this recording?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }), titleVisibility: .visible, presenting: cancelling) { target in
            Button(target.series ? "Cancel series rule" : "Cancel recording", role: .destructive) {
                guard let api = session.api else { return }
                cancelling = nil
                Task { do { try await store.cancel(api: api, timer: target.timer, series: target.series) } catch { actionError = LiveTVStore.message(error) } }
            }
            Button("Keep recording", role: .cancel) { cancelling = nil }
        } message: { target in
            Text(target.series ? "Future recordings from this rule will be cancelled. Existing recorded files stay on your server." : "This stops the scheduled or active recording. Other recordings and your watch history stay unchanged.")
        }
        .alert("Live TV", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) { Button("OK") { actionError = nil } } message: { Text(actionError ?? "") }
    }

    private var guideControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { shiftDate(-1) } label: { Image(systemName: "chevron.left").frame(width: 40, height: 40) }.accessibilityLabel("Previous guide day")
                DatePicker("Guide date", selection: $date, displayedComponents: .date).labelsHidden().accessibilityIdentifier("guideDate")
                Button { shiftDate(1) } label: { Image(systemName: "chevron.right").frame(width: 40, height: 40) }.accessibilityLabel("Next guide day")
                Spacer(minLength: 0)
                Button("Today") { date = .now }.font(.subheadline.weight(.semibold))
            }
            Picker("Channel", selection: $channelID) {
                Text("All channels").tag("")
                ForEach(store.channels) { Text($0.Name).tag($0.id) }
            }.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("guideChannel")
        }.padding(.horizontal, Self.margin).padding(.bottom, 10)
    }
    /// One edge for the rail, the guide controls and the notices, matching Library and Home.
    private static let margin: CGFloat = 20

    @ViewBuilder private var content: some View {
        if store.loading && isEmpty { ProgressView(section == .guide ? "Loading the guide…" : "Loading Live TV…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        else if let error = store.error, isEmpty { FailureView(message: error) { Task { await refresh(permissions: true) } } }
        else {
            List {
                if let message = store.policyError {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color.reelMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Check permissions again") { Task { if let api = session.api { await store.loadPermissions(api: api) } } }
                                .buttonStyle(QuietButton())
                        }.padding(.vertical, 8)
                    }.listRowBackground(Color.reelSurface).listRowSeparator(.hidden)
                }
                if isEmpty { emptyState.listRowBackground(Color.clear) }
                switch section {
                case .channels:
                    ForEach(store.channels) { channel in
                        NavigationLink { DetailView(item: channel) } label: { channelRow(channel) }
                            .accessibilityIdentifier("channel-\(channel.id)").listRowBackground(Color.reelSurface)
                    }
                case .guide:
                    ForEach(store.programs) { program in
                        Button { selectedProgram = program } label: { LiveTVProgramRow(program: program, channelName: channelName(program)) }
                            .buttonStyle(.plain).accessibilityIdentifier("program-\(program.id)").listRowBackground(Color.reelSurface)
                    }
                case .recordings:
                    ForEach(store.recordings) { recording in
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                            : AnyLayout(HStackLayout(spacing: 14))
                        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 14) {
                            Button { playback.present(recording) } label: {
                                layout {
                                    Artwork(item: recording, backdrop: true, width: 350).frame(width: 105, height: 66).clipShape(RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(recording.title).font(.headline).foregroundStyle(Color.reelText)
                                        Text(recording.subtitle).font(.caption).foregroundStyle(Color.reelMuted)
                                        if recording.progress > 0 { ProgressView(value: recording.progress).tint(Color.reelBlue) }
                                    }
                                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                                    Image(systemName: "play.fill").foregroundStyle(Color.reelBlue)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("recording-\(recording.id)")
                            NavigationLink { DetailView(item: recording) } label: {
                                Image(systemName: "info.circle").frame(width: 44, height: 44)
                            }.buttonStyle(.plain).frame(width: 44).accessibilityLabel("Recording details")
                        }.padding(.vertical, 8).listRowBackground(Color.reelSurface)
                    }
                case .scheduled:
                    ForEach(store.timers) { timer in timerRow(timer, series: false) }
                case .series:
                    ForEach(store.seriesRules) { timer in timerRow(timer, series: true) }
                }
                if let error = store.error { Section { Text(error).font(.footnote).foregroundStyle(.orange); Button("Try again") { Task { await refresh() } } }.listRowBackground(Color.reelSurface) }
                if store.hasMore {
                    Button { Task { await refresh(append: true) } } label: { HStack { Spacer(); if store.loading { ProgressView() } else { Text("Load more") }; Spacer() } }
                        .disabled(store.loading).accessibilityIdentifier("tvLoadMore").listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .refreshable { await refresh(permissions: true) }.accessibilityIdentifier("liveTVList")
        }
    }

    private var isEmpty: Bool {
        switch section {
        case .channels: store.channels.isEmpty
        case .guide: store.programs.isEmpty
        case .recordings: store.recordings.isEmpty
        case .scheduled: store.timers.isEmpty
        case .series: store.seriesRules.isEmpty
        }
    }
    private var emptyState: some View {
        let title: String
        let description: String
        switch section {
        case .channels: title = "No channels yet"; description = "Channels appear when Live TV is configured on your Jellyfin server and enabled for your account."
        case .guide: title = "No programs in this guide"; description = "Try another date or channel. Your server needs program guide data to schedule recordings."
        case .recordings: title = "No recordings yet"; description = "Completed and ongoing recordings from your server appear here."
        case .scheduled: title = "Nothing scheduled"; description = "Open a program in Guide to schedule a recording."
        case .series: title = "No series rules"; description = "Choose a series in Guide to record future episodes automatically."
        }
        return ContentUnavailableView(title, systemImage: section == .channels ? "tv" : "calendar", description: Text(description))
    }
    private func channelRow(_ channel: MediaItem) -> some View {
        HStack(spacing: 16) {
            Artwork(item: channel, width: 250).frame(width: 96, height: 60).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(channel.Name).font(.headline)
                if let program = channel.CurrentProgram?.Name { Text(program).font(.subheadline).foregroundStyle(Color.reelMuted) }
                // An HStack, not a Label: inside a List a Label puts its icon in a wide column.
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.caption2).accessibilityHidden(true)
                    Text("Watch live")
                }.font(.caption.weight(.semibold)).foregroundStyle(Color.reelBlue)
            }
        }.padding(.vertical, 8)
    }
    private func timerRow(_ timer: LiveTVTimer, series: Bool) -> some View {
        HStack(spacing: 16) {
            Image(systemName: series ? "rectangle.stack.badge.play" : timer.Status == "InProgress" ? "record.circle.fill" : "calendar.badge.clock")
                .font(.title2).foregroundStyle(timer.Status == "InProgress" ? .red : Color.reelBlue).frame(width: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(timer.Name ?? "Scheduled recording").font(.headline)
                if let channel = timer.ChannelName { Text(channel).font(.caption).foregroundStyle(Color.reelMuted) }
                if series { Text(timer.RecordNewOnly == true ? "New episodes" : "All episodes").font(.caption).foregroundStyle(Color.reelBlue) }
                else if let start = timer.start { Text(start.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(Color.reelMuted) }
                if let status = timer.Status { Text(status).font(.caption).foregroundStyle(Color.reelMuted) }
            }
            Spacer(minLength: 0)
            Button { cancelling = Cancellation(timer: timer, series: series) } label: { Image(systemName: "xmark.circle").frame(width: 44, height: 44) }
                .buttonStyle(.borderless).disabled(!canManage || store.mutating).accessibilityLabel((series ? "Cancel series rule " : "Cancel recording ") + (timer.Name ?? "")).accessibilityIdentifier((series ? "cancelSeries-" : "cancelTimer-") + timer.id)
        }.padding(.vertical, 10).listRowBackground(Color.reelSurface)
    }
    private func channelName(_ program: LiveTVProgram) -> String { program.ChannelName ?? store.channels.first(where: { $0.id == program.ChannelId })?.Name ?? "Live TV" }
    private func shiftDate(_ days: Int) { if let result = Calendar.current.date(byAdding: .day, value: days, to: date) { date = result } }
    private func refresh(append: Bool = false, permissions: Bool = false) async {
        guard let api = session.api else { return }
        await store.load(api: api, section: section, date: date, channelID: channelID, append: append)
        if permissions { await store.loadPermissions(api: api) }
    }
    private func playPendingChannel() {
        guard let id = pendingWatch, let api = session.api else { return }
        pendingWatch = nil
        Task {
            do {
                let channel = try await api.item(id)
                try Task.checkCancellation()
                playback.present(channel)
            } catch { actionError = LiveTVStore.message(error) }
        }
    }
}

private struct LiveTVProgramRow: View {
    let program: LiveTVProgram
    let channelName: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                if let start = program.start { Text(start.formatted(date: .omitted, time: .shortened)).font(.subheadline.weight(.semibold)).monospacedDigit() }
                if let end = program.end { Text(end.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(Color.reelMuted).monospacedDigit() }
                if program.isAiring() { Text("LIVE").font(.caption2.bold()).foregroundStyle(Color.reelBlue) }
            }.frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(program.Name).font(.headline).foregroundStyle(Color.reelText)
                if let episode = program.EpisodeTitle { Text(episode).font(.subheadline).foregroundStyle(Color.reelMuted).lineLimit(1) }
                Text(channelName).font(.caption).foregroundStyle(Color.reelMuted)
                if program.TimerId != nil || program.SeriesTimerId != nil { Label("Recording scheduled", systemImage: "record.circle").font(.caption).foregroundStyle(Color.reelBlue) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.reelMuted)
        }.padding(.vertical, 12).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

private struct LiveTVProgramDetailView: View {
    let program: LiveTVProgram
    let allowManagement: Bool
    let onRecorded: @MainActor () async -> Void
    let onWatch: (String) -> Void
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var detail: LiveTVProgram?
    @State private var draft: LiveTVRecordingDraft?
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var message: String?
    @State private var confirmRecording = false
    @State private var recordSeries = false
    private var current: LiveTVProgram { detail ?? program }

    var body: some View {
        Form {
            Section {
                Artwork(item: current.artworkItem, backdrop: true, width: 900).frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 14))
                Text(current.Name).font(.title2.bold()).accessibilityIdentifier("programTitle")
                if let episode = current.EpisodeTitle { Text(episode).font(.headline).foregroundStyle(Color.reelMuted) }
                if let channel = current.ChannelName { Label(channel, systemImage: "tv") }
                if let start = current.start { LabeledContent("Starts", value: start.formatted(date: .abbreviated, time: .shortened)) }
                if let end = current.end { LabeledContent("Ends", value: end.formatted(date: .abbreviated, time: .shortened)) }
                if let overview = current.Overview, !overview.isEmpty { Text(overview).font(.body).foregroundStyle(Color.reelMuted) }
                if current.isAiring(), let id = current.ChannelId { Button { onWatch(id) } label: { Label("Watch live", systemImage: "play.fill") }.accessibilityIdentifier("watchProgramLive") }
            }.listRowBackground(Color.reelSurface)
            if current.TimerId != nil || current.SeriesTimerId != nil {
                Section { Label("Recording scheduled", systemImage: "record.circle").foregroundStyle(Color.reelBlue); Text("Manage or cancel it in Scheduled or Series rules.").font(.footnote).foregroundStyle(Color.reelMuted) }.listRowBackground(Color.reelSurface)
            } else if allowManagement, current.canRecord() {
                Section("Recording options") {
                    if var options = draft {
                        Stepper("Start early: \(options.prePaddingMinutes) min", value: Binding(get: { draft?.prePaddingMinutes ?? 0 }, set: { options.prePaddingMinutes = $0; draft = options }), in: 0...60).accessibilityIdentifier("recordingPrePadding")
                        Stepper("Finish late: \(options.postPaddingMinutes) min", value: Binding(get: { draft?.postPaddingMinutes ?? 0 }, set: { options.postPaddingMinutes = $0; draft = options }), in: 0...120).accessibilityIdentifier("recordingPostPadding")
                        Button("Record this airing") { recordSeries = false; confirmRecording = true }.disabled(loading || saving || message != nil).accessibilityIdentifier("recordProgram")
                        if current.IsSeries == true {
                            Toggle("New episodes only", isOn: Binding(get: { draft?.newEpisodesOnly ?? true }, set: { options.newEpisodesOnly = $0; draft = options }))
                            Toggle("Any channel", isOn: Binding(get: { draft?.anyChannel ?? false }, set: { options.anyChannel = $0; draft = options }))
                            Toggle("Any time", isOn: Binding(get: { draft?.anyTime ?? true }, set: { options.anyTime = $0; draft = options }))
                            Toggle("Skip episodes already in library", isOn: Binding(get: { draft?.skipExisting ?? true }, set: { options.skipExisting = $0; draft = options }))
                            Button("Record series") { recordSeries = true; confirmRecording = true }.disabled(loading || saving || message != nil).accessibilityIdentifier("recordSeries")
                        }
                    } else if loading { ProgressView("Loading recording defaults…") }
                }.listRowBackground(Color.reelSurface)
            } else if !allowManagement {
                Section { Text(session.api?.isSimulatorPreview == true ? "Recording changes are disabled in the simulator preview of your real server." : "Recording management needs permission from your Jellyfin administrator.").font(.footnote).foregroundStyle(Color.reelMuted) }.listRowBackground(Color.reelSurface)
            }
            if let message { Section { Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(Color.reelBlue) } }
            if let error { Section { Text(error).foregroundStyle(.orange); Button("Refresh program") { Task { await load() } }.disabled(saving) } }
            if saving { ProgressView("Saving recording…") }
        }
        .scrollContentBackground(.hidden).background(Color.reelBackground).navigationTitle("Program").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(saving) } }
        .toolbarMinimizationBehavior(.never, for: .navigationBar)
        .interactiveDismissDisabled(saving)
        .task(id: allowManagement) { await load() }
        .confirmationDialog(recordSeries ? "Record this series?" : "Record this airing?", isPresented: $confirmRecording, titleVisibility: .visible) {
            Button(recordSeries ? "Schedule series" : "Schedule recording") { Task { await schedule() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text(recordSeries ? "Jellyfin will create a rule for future episodes using these recording options." : "Jellyfin will record this program on your server using these padding settings.") }
    }
    private func load() async {
        guard let api = session.api else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let service = LiveTVAPI(api: api)
            let result = try await service.program(program.id)
            try Task.checkCancellation()
            detail = result
            if allowManagement && result.canRecord() { draft = try await service.defaults(program: result) }
        } catch is CancellationError { }
        catch { self.error = LiveTVStore.message(error) }
    }
    private func schedule() async {
        guard !saving, allowManagement, let api = session.api, let draft else { return }
        saving = true; error = nil; message = nil
        defer { saving = false }
        do {
            let service = LiveTVAPI(api: api)
            try await service.schedule(program: current, draft: draft, series: recordSeries)
            message = recordSeries ? "Series rule created" : "Recording scheduled"
            detail = try await service.program(program.id)
            await onRecorded()
        } catch {
            self.error = "The server couldn’t confirm the recording change. Refresh this program and Scheduled before trying again. " + LiveTVStore.message(error)
        }
    }
}
