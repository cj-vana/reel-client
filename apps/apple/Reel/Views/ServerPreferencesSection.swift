import SwiftUI

struct ServerPreferencesSection: View {
    @Environment(Session.self) private var session
    @Environment(ServerPreferences.self) private var preferences

    var body: some View {
        Section {
            Toggle("Use supported server preferences", isOn: Binding(get: { preferences.enabled }, set: { value in
                guard let account = session.account, let api = session.api else { return }
                preferences.setEnabled(value, accountID: account.id)
                Task { await preferences.activate(accountID: account.id, api: api) }
            })).accessibilityIdentifier("useServerPreferences")
            if preferences.status == .loading { ProgressView("Loading preferences…") }
            if preferences.enabled {
                if preferences.status == .unavailable {
                    Text("The Streamyfin companion plugin is not installed on this server. Reel is using your local settings.").font(.footnote).foregroundStyle(Color.reelMuted)
                } else if let settings = preferences.settings {
                    if settings.isEmpty { Text("The plugin supplied no playback settings supported by Reel.").font(.footnote).foregroundStyle(Color.reelMuted) }
                    if let speed = settings.defaultPlaybackSpeed {
                        preference("Playback speed", value: String(format: "%g×", speed.value), locked: speed.locked)
                    }
                    if let bitrate = settings.defaultBitrate {
                        preference("Bitrate", value: bitrate.value.map { String(format: "%g Mbps", Double($0) / 1_000_000) } ?? "Automatic", locked: bitrate.locked)
                    }
                    if let skip = settings.forwardSkipTime { preference("Forward", value: "\(skip.value) seconds", locked: skip.locked) }
                    if let skip = settings.rewindSkipTime { preference("Rewind", value: "\(skip.value) seconds", locked: skip.locked) }
                }
                if let error = preferences.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                Button("Refresh server preferences") {
                    guard let account = session.account, let api = session.api else { return }
                    Task { await preferences.activate(accountID: account.id, api: api) }
                }.disabled(preferences.status == .loading).accessibilityIdentifier("refreshServerPreferences")
            }
        } header: { Text("Server playback preferences") } footer: {
            Text("Imports playback defaults from the Streamyfin companion plugin, if your server has it. Locked options stay set by the server while this is on. Reel never changes your server’s configuration or imports other services’ API keys.").foregroundStyle(Color.reelMuted)
        }.listRowBackground(Color.reelSurface)
    }

    private func preference(_ title: String, value: String, locked: Bool) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(Color.reelMuted); if locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(Color.reelBlue).accessibilityLabel("Controlled by server") } }
            .font(.subheadline)
    }
}
