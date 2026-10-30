import SwiftUI

/// Every destination in the app, shown as tab bar items on iPhone and as sidebar rows on iPad.
enum RootTab: Hashable { case home, library, search, downloads, more, media, liveTV, requests, devices, settings }

/// The iPad sidebar. It sits on the app's own canvas, like the web app's sidebar, lists every
/// destination instead of hiding some behind More, and keeps Settings and the signed-in account at
/// its foot.
struct ReelSidebar: View {
    @Binding var selection: RootTab
    @Environment(Session.self) private var session
    @State private var showingServers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReelMark().padding(.leading, 26).padding(.top, 18).padding(.bottom, 24)
            searchField.padding(.horizontal, 14).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(.home, "Home", icon: "house")
                    row(.library, "Library", icon: "square.grid.2x2")
                    row(.downloads, "Downloads", icon: "arrow.down.circle")
                    sectionTitle("Explore")
                    row(.media, "Media", icon: "rectangle.stack")
                    row(.liveTV, "Live TV", icon: "tv")
                    row(.requests, "Requests", icon: "sparkle.magnifyingglass")
                    row(.devices, "Devices", icon: "airplay.video")
                }
                .padding(.horizontal, 14)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            VStack(alignment: .leading, spacing: 10) {
                row(.settings, "Settings", icon: "slider.horizontal.3")
                accountCard
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background { Color.reelBackground.ignoresSafeArea() }
        .overlay(alignment: .trailing) { Rectangle().fill(Color.reelHairline).frame(width: 1).ignoresSafeArea() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reelSidebar")
        .sheet(isPresented: $showingServers) { NavigationStack { ServersView() } }
    }

    /// Looks like a search field and opens Search, where the real field takes the keyboard.
    private var searchField: some View {
        let selected = selection == .search
        return Button { selection = .search } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(selected ? Color.reelBlue : Color.reelMuted)
                Text("Search").foregroundStyle(selected ? Color.reelText : Color.reelMuted)
                Spacer(minLength: 0)
            }
            .font(.body)
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(selected ? Color.reelSurfaceRaised : Color.reelSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.reelHairline) }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SidebarPressStyle())
        .hoverEffect(.highlight)
        .accessibilityLabel("Search")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("Search")
    }

    private func row(_ tab: RootTab, _ title: String, icon: String) -> some View {
        let selected = selection == tab
        return Button { selection = tab } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .symbolVariant(selected ? .fill : .none)
                    .font(.system(size: 18, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.reelBlue : Color.reelMuted)
                    .frame(width: 26)
                Text(title)
                    .font(.body.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.reelText : Color.reelText.opacity(0.84))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(minHeight: 46)
            .background { if selected { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.reelSurfaceRaised) } }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SidebarPressStyle())
        .hoverEffect(.highlight)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(title)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.reelTertiary)
            .padding(.leading, 12).padding(.top, 22).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    /// The signed-in account and its server. It opens Servers, where accounts are added or switched.
    private var accountCard: some View {
        let account = session.account
        return Button { showingServers = true } label: {
            HStack(spacing: 12) {
                Text(Self.initial(account?.name))
                    .font(.headline)
                    .foregroundStyle(Color.reelBackground)
                    .frame(width: 36, height: 36)
                    .background(Color.reelBlue, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(account?.name ?? "Not signed in").font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelText)
                    Text(account?.serverName ?? "Choose a server").font(.footnote).foregroundStyle(Color.reelMuted)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Color.reelTertiary)
            }
            .padding(10)
            .background(Color.reelSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.reelHairline) }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(SidebarPressStyle())
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Account and servers")
        .accessibilityValue([account?.name, account?.serverName].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("sidebarAccount")
    }

    static func initial(_ name: String?) -> String {
        name?.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }

    /// How wide the sidebar is in a window this wide, or nil when the window is too narrow for one.
    static func width(for windowWidth: CGFloat) -> CGFloat? {
        guard windowWidth >= 780 else { return nil }
        return min(292, max(248, (windowWidth * 0.22).rounded()))
    }
}

private struct SidebarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
