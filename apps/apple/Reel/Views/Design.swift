import SwiftUI

extension Color {
    static let reelBackground = Color(red: 0.047, green: 0.047, blue: 0.055)
    static let reelSurface = Color(red: 0.090, green: 0.090, blue: 0.102)
    static let reelSurfaceRaised = Color(red: 0.133, green: 0.133, blue: 0.149)
    static let reelBlue = Color(red: 0.61, green: 0.86, blue: 0.76)
    static let reelText = Color(red: 0.957, green: 0.957, blue: 0.965)
    static let reelMuted = Color(red: 0.957, green: 0.957, blue: 0.965).opacity(0.64)
    static let reelTertiary = Color(red: 0.957, green: 0.957, blue: 0.965).opacity(0.46)
    static let reelHairline = Color.white.opacity(0.08)
    static let reelFill = Color.white.opacity(0.09)
}

extension View {
    /// The canvas behind a page, and behind the navigation container that holds it. After an iPad
    /// turns to landscape the container can show below a page's own background, and in dark mode
    /// the container's system background is pure black.
    func reelCanvas() -> some View {
        background(Color.reelBackground).containerBackground(Color.reelBackground, for: .navigation)
    }
}

/// One radius scale for the whole app: artwork, controls, and fully round chips.
enum ReelRadius {
    static let artwork: CGFloat = 10
    static let control: CGFloat = 12
}

/// Picks two-column layouts from the size class and the width a screen is given, never from the
/// device idiom or the screen size. A book-style foldable iPhone reports the phone idiom while its
/// open inner screen is regular width and only about 626 to 669 points across, so each test below
/// is the sum of the narrowest columns that layout can show.
enum AdaptiveLayout {
    /// Below this width a regular-width layout uses the tighter margins and type.
    static let roomyWidth: CGFloat = 760

    static func margin(regular: Bool, width: CGFloat) -> CGFloat {
        !regular ? 20 : width < roomyWidth ? 28 : 40
    }

    /// Details: poster beside an information column that holds Play over five action tiles.
    enum Details {
        static let posterMinimum: CGFloat = 140
        static let spacing: CGFloat = 24
        /// Five action tiles at their 64 point minimum, 8 points apart.
        static let informationMinimum: CGFloat = 5 * 64 + 4 * 8
    }

    static func detailsSideBySide(_ sizeClass: UserInterfaceSizeClass?, accessibility: Bool, width: CGFloat) -> Bool {
        sizeClass == .regular && !accessibility
            && width >= 2 * margin(regular: true, width: 0) + Details.posterMinimum + Details.spacing + Details.informationMinimum
    }

    /// Home: the wide featured band, whose text column needs room for a two-line title and two buttons.
    enum Home {
        static let bandTextMinimum: CGFloat = 360
        static let bandPadding: CGFloat = 28
    }

    static func homeBand(_ sizeClass: UserInterfaceSizeClass?, accessibility: Bool, width: CGFloat) -> Bool {
        sizeClass == .regular && !accessibility
            && width >= 2 * margin(regular: true, width: 0) + 2 * Home.bandPadding + Home.bandTextMinimum
    }

    /// Sign-in: the introduction beside the form.
    enum Connect {
        static let introductionMinimum: CGFloat = 240
        static let spacing: CGFloat = 48
        static let formMinimum: CGFloat = 340
        static let margin: CGFloat = 40
        /// A stacked layout in a regular-width window stays a readable column.
        static let stackedColumn: CGFloat = 520
    }

    static func connectSideBySide(_ sizeClass: UserInterfaceSizeClass?, accessibility: Bool, width: CGFloat) -> Bool {
        sizeClass == .regular && !accessibility
            && width >= 2 * Connect.margin + Connect.introductionMinimum + Connect.spacing + Connect.formMinimum
    }
}

extension EnvironmentValues {
    /// The fold of a book-style foldable in global coordinates, published by MainView. Nil on
    /// devices without one.
    @Entry var foldCrease: CGRect?
    /// The screen's safe-area insets at the root, published by MainView. A foldable's side strip,
    /// which holds the status bar and the tab bar, shows up here even where a pushed screen reports
    /// a narrower inset. Art runs under the strip; words and controls keep clear of it.
    @Entry var screenInsets = EdgeInsets()
}

/// The two pages either side of an open foldable's crease, in a view's own coordinates. Text and
/// controls stay on one page; only artwork may run across the crease.
struct FoldSpread: Equatable {
    /// Each page has to hold a readable column, so a crease near an edge makes no spread. This
    /// also leaves the folded outer screen, 466 points wide, with a single page.
    static let pageMinimum: CGFloat = 300

    /// The crease band, in the view's coordinates.
    let crease: CGRect

    /// `frame` is the view's own frame in global coordinates.
    init?(crease global: CGRect?, in frame: CGRect) {
        guard let global, global.height > global.width else { return nil }
        let local = global.offsetBy(dx: -frame.minX, dy: -frame.minY)
        guard local.minX >= Self.pageMinimum, frame.width - local.maxX >= Self.pageMinimum else { return nil }
        crease = local
    }

    /// Width of the left page, from the view's leading edge to the crease.
    var leadingWidth: CGFloat { crease.minX }
    /// Where the right page begins.
    var trailingStart: CGFloat { crease.maxX }
}

/// Keeps a list or form to a readable column on a wide screen, and to the left page of an open
/// foldable, so its rows neither stretch across an iPad nor run over the crease.
struct ReadableColumn: ViewModifier {
    static let maxWidth: CGFloat = 680
    static let margin: CGFloat = 20
    @Environment(\.foldCrease) private var foldCrease
    @State private var frame = CGRect.zero

    enum Layout: Equatable {
        /// A centered list this wide, its own margins included.
        case column(CGFloat)
        /// Rows end this far from the trailing edge, short of the crease.
        case leftPage(trailing: CGFloat)
    }

    func body(content: Content) -> some View {
        Group {
            // A list honors a trailing content margin but not a leading one, so a centered column
            // narrows the list itself; the background around it stays the caller's.
            switch Self.layout(width: frame.width, spread: FoldSpread(crease: foldCrease, in: frame)) {
            case .column(let width): content.frame(maxWidth: width)
            case .leftPage(let trailing): content.contentMargins(.trailing, trailing, for: .scrollContent)
            case nil: content
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }

    /// Nil where the system's own margins already give a readable column.
    static func layout(width: CGFloat, spread: FoldSpread?) -> Layout? {
        if let spread { return .leftPage(trailing: width - spread.leadingWidth + margin) }
        guard width > maxWidth + 4 * margin else { return nil }
        return .column(maxWidth + 2 * margin)
    }
}

struct ReelMark: View {
    /// The mark alone, for a narrow bar such as the vertical bar beside a foldable's outer screen.
    var markOnly = false
    var body: some View {
        HStack(spacing: 9) {
            Image("BrandMark").renderingMode(.template).resizable().scaledToFit().frame(width: 27, height: 27).foregroundStyle(Color.reelBlue)
            if !markOnly { Text("Reel").font(.system(size: 25, weight: .bold)).tracking(-0.8) }
        }
        .foregroundStyle(Color.reelText)
        .accessibilityElement(children: .ignore).accessibilityLabel("Reel")
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View { Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelMuted) }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .padding(.horizontal, 22).padding(.vertical, 13)
            .frame(minHeight: 50).background(Color.reelText, in: RoundedRectangle(cornerRadius: ReelRadius.control))
            .foregroundStyle(Color.reelBackground)
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct QuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).padding(14).frame(minHeight: 48)
            .background(.white.opacity(configuration.isPressed ? 0.18 : 0.1), in: RoundedRectangle(cornerRadius: ReelRadius.control))
            .foregroundStyle(Color.reelText).opacity(isEnabled ? 1 : 0.4)
    }
}

/// Icon over a short label, used for the secondary actions on Details. At
/// accessibility sizes the icon moves beside the label so the text can wrap.
struct ActionTile: View {
    let title: String
    let systemImage: String
    var highlighted = false
    var progress: Double?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 14) {
                    icon
                    Text(title).font(.body.weight(.medium)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
            } else {
                VStack(spacing: 6) {
                    icon
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                }.frame(maxWidth: .infinity, minHeight: 64).padding(.horizontal, 4)
            }
        }
        .foregroundStyle(Color.reelText)
        .background(Color.reelFill, in: RoundedRectangle(cornerRadius: ReelRadius.control))
        .contentShape(RoundedRectangle(cornerRadius: ReelRadius.control))
        .opacity(isEnabled ? 1 : 0.45)
    }

    @ViewBuilder private var icon: some View {
        if let progress {
            ZStack {
                Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
                Circle().trim(from: 0, to: max(0.04, progress)).stroke(Color.reelBlue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: "stop.fill").font(.system(size: 8, weight: .bold))
            }.frame(width: 22, height: 22).frame(height: 26)
        } else {
            Image(systemName: systemImage).font(.title3).frame(height: 26)
                .foregroundStyle(highlighted ? Color.reelBlue : Color.reelText)
        }
    }
}

/// Compact menu trigger: a category and its current value in a round chip.
struct OptionChip: View {
    let title: String
    let systemImage: String
    var value: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // Full width, value under the title, so neither has to be cut.
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.body.weight(.semibold)).foregroundStyle(Color.reelMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(Color.reelText)
                    if let value, !value.isEmpty { Text(value).font(.subheadline).foregroundStyle(Color.reelMuted) }
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.reelFill, in: RoundedRectangle(cornerRadius: ReelRadius.control))
            .contentShape(RoundedRectangle(cornerRadius: ReelRadius.control))
        } else {
            HStack(spacing: 7) {
                Image(systemName: systemImage).font(.footnote.weight(.semibold)).foregroundStyle(Color.reelMuted)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelText)
                if let value, !value.isEmpty {
                    Text(value).font(.subheadline).foregroundStyle(Color.reelMuted).lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Color.reelTertiary)
            }
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(Color.reelFill, in: Capsule())
            .contentShape(Capsule())
        }
    }
}

/// Lays children out left to right and wraps them onto new rows.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let itemWidth = min(size.width, width)
            let needed = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], itemWidth, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Year, rating, runtime and media badges, spaced rather than dot separated.
struct MetadataLine: View {
    let item: MediaItem
    var source: MediaSource?
    var foreground = Color.reelMuted

    var body: some View {
        WrapLayout(spacing: 10, lineSpacing: 6) {
            if let year = item.ProductionYear { Text(String(year)) }
            if let rating = item.OfficialRating, !rating.isEmpty { MediaBadge(text: rating) }
            if item.isSeries { Text("Series") } else if let duration = item.duration { Text(duration) }
            if let score = item.CommunityRating { Label(String(format: "%.1f", score), systemImage: "star.fill").labelStyle(.titleAndIcon) }
            ForEach(source?.badges ?? [], id: \.self) { MediaBadge(text: $0) }
        }
        .font(.subheadline.weight(.medium)).foregroundStyle(foreground)
        .accessibilityElement(children: .combine)
    }
}

struct MediaBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
    }
}

/// Thin progress line with a track, drawn along the bottom of a thumbnail.
struct WatchProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Color.white.opacity(0.22))
                .overlay(alignment: .leading) { Capsule().fill(Color.reelBlue).frame(width: max(4, geometry.size.width * value)) }
        }.frame(height: 4).accessibilityLabel("Watch progress").accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

struct FailureView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Let’s try that again", systemImage: "wifi.exclamationmark")
        } description: { Text(message) } actions: {
            Button("Try again", action: retry).buttonStyle(PrimaryButton()).accessibilityIdentifier("retry")
        }
    }
}

struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat = 148
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Artwork(item: item, width: 400).frame(width: width, height: width * 1.5)
                .overlay(alignment: .topTrailing) {
                    if item.isFavorite { Image(systemName: "heart.fill").font(.system(size: 11)).padding(7).background(.black.opacity(0.6), in: Circle()).padding(7).foregroundStyle(Color.reelBlue) }
                }
                .overlay(alignment: .bottom) {
                    if item.progress > 0, item.UserData?.Played != true { WatchProgressBar(value: item.progress).padding(8) }
                }
                .clipShape(RoundedRectangle(cornerRadius: ReelRadius.artwork))
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(Color.reelText)
            Text(item.subtitle).font(.caption).lineLimit(1).foregroundStyle(Color.reelMuted)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ResumeCard: View {
    let item: MediaItem
    var width: CGFloat = 274
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Artwork(item: item.thumbnailItem, backdrop: true, width: 600).frame(width: width, height: width * 9 / 16)
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).frame(width: 30, height: 30)
                            .background(.white.opacity(0.22), in: Circle()).foregroundStyle(.white)
                        WatchProgressBar(value: item.progress)
                    }.padding(10)
                }.clipShape(RoundedRectangle(cornerRadius: ReelRadius.artwork))
            Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelText).lineLimit(1)
            Text(caption).font(.caption).foregroundStyle(Color.reelMuted).lineLimit(1)
        }.frame(width: width, alignment: .leading).accessibilityElement(children: .combine)
    }

    /// "S1 E2 Manifest" for an episode, the time left for anything else.
    private var caption: String {
        item.Type == "Episode" ? item.subtitle : item.remainingText ?? item.duration ?? ""
    }
}

struct EpisodeCard: View {
    let item: MediaItem
    var width: CGFloat = 274
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Artwork(item: item.thumbnailItem, backdrop: true, width: 600)
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .topTrailing) {
                    if item.isFavorite { Image(systemName: "heart.fill").font(.system(size: 11)).padding(7).background(.black.opacity(0.6), in: Circle()).padding(7).foregroundStyle(Color.reelBlue) }
                }
                .overlay(alignment: .bottom) {
                    if item.progress > 0, item.UserData?.Played != true { WatchProgressBar(value: item.progress).padding(10) }
                }
                .clipShape(RoundedRectangle(cornerRadius: ReelRadius.artwork))
            Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.reelText).lineLimit(1)
            Text(item.subtitle).font(.caption).foregroundStyle(Color.reelMuted).lineLimit(1)
        }.frame(width: width, alignment: .leading).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}

/// Placeholder shaped like a row of cards, shown while a row loads.
struct SkeletonRow: View {
    var count = 4
    var width: CGFloat = 148
    var aspect: CGFloat = 1.5
    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: ReelRadius.artwork).fill(Color.reelSurface).frame(width: width, height: width * aspect)
                    RoundedRectangle(cornerRadius: 4).fill(Color.reelSurface).frame(width: width * 0.7, height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(Color.reelSurface).frame(width: width * 0.4, height: 10)
                }
            }
        }.accessibilityHidden(true)
    }
}
