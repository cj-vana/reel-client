import SwiftUI

struct DownloadsView: View {
    let openLibrary: () -> Void
    @Environment(Session.self) private var session
    @Environment(Downloads.self) private var downloads
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var removing: DownloadedItem?
    @State private var error: String?

    private var items: [DownloadedItem] {
        guard let account = session.account else { return [] }
        return downloads.items.filter { $0.accountID == account.id }
    }
    private var requestedKeys: [String] {
        guard let account = session.account else { return [] }
        return downloads.requested.keys.filter { $0.hasPrefix(account.id + "|") }.sorted()
    }

    /// Nothing saved, nothing transferring and nothing to report: the screen is one centered invitation.
    private var showsInvitation: Bool {
        downloads.storageReady && items.isEmpty && requestedKeys.isEmpty && downloads.errors["storage"] == nil && error == nil
    }

    var body: some View {
        Group {
            if showsInvitation { emptyLibrary } else { list }
        }
        .reelCanvas().navigationTitle("Downloads").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove this download?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { item in
            Button("Remove download", role: .destructive) {
                guard session.account?.id == item.accountID else { removing = nil; return }
                do { try downloads.remove(item); error = nil }
                catch { self.error = error.localizedDescription }
                removing = nil
            }.accessibilityIdentifier("confirmRemoveDownload")
            Button("Cancel", role: .cancel) { removing = nil }.accessibilityIdentifier("cancelRemoveDownload")
        } message: { _ in Text("Only the downloaded file is removed. The original stays on Jellyfin.") }
        .onChange(of: session.account?.id) { _, _ in removing = nil; error = nil }
    }

    private var list: some View {
        List {
            if let message = downloads.errors["storage"] {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Storage needs attention", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.headline).foregroundStyle(Color.reelText)
                        Text(message).font(.subheadline).foregroundStyle(Color.reelMuted)
                            .accessibilityIdentifier("downloadsStorageError")
                        Button("Retry storage cleanup") { downloads.recoverStorage() }
                            .buttonStyle(QuietButton()).accessibilityIdentifier("retryDownloadStorage")
                    }.padding(.vertical, 8)
                }.listRowBackground(Color.reelSurface)
            }

            if !requestedKeys.isEmpty {
                Section("Transfers") {
                    ForEach(requestedKeys, id: \.self) { key in transfer(key) }
                }.listRowBackground(Color.reelSurface)
            }

            if !items.isEmpty {
                Section {
                    ForEach(items) { item in saved(item) }
                } header: {
                    HStack {
                        Text("On this device")
                        Spacer()
                        Text("\(items.count) saved").monospacedDigit()
                    }
                }.listRowBackground(Color.reelSurface)
            }

            if let error {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Couldn’t remove the download", systemImage: "exclamationmark.circle")
                            .font(.headline).foregroundStyle(Color.reelText)
                        Text(error).font(.subheadline).foregroundStyle(Color.reelMuted)
                            .accessibilityIdentifier("downloadRemovalError")
                        Button("Dismiss") { self.error = nil }.accessibilityIdentifier("dismissDownloadError")
                    }.padding(.vertical, 6)
                }.listRowBackground(Color.reelSurface)
            }

            Section {
                Label {
                    Text("Saved on this device. Offline progress stays local and never changes your server’s history.")
                        .font(.footnote).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "internaldrive").accessibilityHidden(true)
                }.foregroundStyle(Color.reelMuted).padding(.vertical, 4)
            }.listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden)
        .frame(maxWidth: 860).frame(maxWidth: .infinity)
    }

    private var emptyLibrary: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 30, weight: .regular)).foregroundStyle(Color.reelText)
                        .frame(width: 72, height: 72).background(Color.reelSurface, in: Circle())
                        .overlay(Circle().strokeBorder(Color.reelHairline))
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("Watch anywhere").font(.title2.weight(.bold))
                            .foregroundStyle(Color.reelText).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("downloadsEmpty")
                        Text("Download a movie or an episode and it will wait here, ready to play offline.")
                            .font(.body).foregroundStyle(Color.reelMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }.multilineTextAlignment(.center)
                    Button(action: openLibrary) {
                        Text("Browse library").frame(maxWidth: .infinity)
                    }.buttonStyle(PrimaryButton()).frame(maxWidth: 280).accessibilityIdentifier("downloadsBrowseLibrary")
                }
                .frame(maxWidth: 400).padding(.horizontal, 24).padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }

    private func saved(_ item: DownloadedItem) -> some View {
        HStack(spacing: 14) {
            if !dynamicTypeSize.isAccessibilitySize {
                Artwork(item: item.item, width: 240)
                    .frame(width: 60, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: ReelRadius.artwork))
                    .accessibilityHidden(true)
            }
            Button {
                guard session.account?.id == item.accountID else { return }
                playback.presentDownload(item.item, url: downloads.url(item))
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.item.title).font(.headline).foregroundStyle(Color.reelText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    if !item.item.subtitle.isEmpty {
                        Text(item.item.subtitle).font(.caption).foregroundStyle(Color.reelMuted)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    }
                    Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file) + " · " + (item.isOptimized ? "Optimized copy" : "Original"))
                        .font(.caption).foregroundStyle(Color.reelTertiary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("offline-\(item.item.id)")
            Button { removing = item } label: {
                Image(systemName: "trash").frame(width: 44, height: 44)
            }.buttonStyle(.borderless).accessibilityLabel("Remove download")
                .accessibilityIdentifier("removeDownload-\(item.item.id)")
        }.padding(.vertical, 8)
    }

    private func transfer(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(downloads.requested[key]?.title ?? "Download").font(.headline).foregroundStyle(Color.reelText)
            if let message = downloads.errors[key] {
                Label("Download interrupted", systemImage: "exclamationmark.circle").font(.caption.weight(.medium)).foregroundStyle(.orange)
                Text(message).font(.footnote).foregroundStyle(Color.reelMuted)
                Button("Retry download") {
                    guard let account = session.account, let api = session.api,
                          key.hasPrefix(account.id + "|"), let item = downloads.requested[key] else { return }
                    downloads.download(item, account: account, api: api, optimized: downloads.optimized.contains(key))
                }.buttonStyle(QuietButton()).accessibilityIdentifier("retryDownload")
                    .disabled(session.api == nil)
            } else {
                HStack(spacing: 12) {
                    if let progress = downloads.progress[key] {
                        ProgressView(value: progress).tint(Color.reelBlue)
                            .accessibilityLabel("Download progress")
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit()).foregroundStyle(Color.reelMuted)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("Downloading…").font(.caption).foregroundStyle(Color.reelMuted)
                }
                Button("Cancel") {
                    guard let account = session.account, key.hasPrefix(account.id + "|") else { return }
                    downloads.cancel(key)
                }.buttonStyle(QuietButton()).accessibilityIdentifier("cancelDownload")
            }
        }.padding(.vertical, 10)
    }
}
