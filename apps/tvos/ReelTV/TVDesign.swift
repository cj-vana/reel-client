import ImageIO
import SwiftUI

extension Color {
    /// Canvas and raised surfaces. Content artwork supplies the color; chrome stays neutral.
    static let reelBackground = Color(red: 0.047, green: 0.047, blue: 0.055)
    static let reelSurface = Color(red: 0.090, green: 0.090, blue: 0.102)
    static let reelSurfaceRaised = Color(red: 0.133, green: 0.133, blue: 0.149)
    static let reelText = Color(red: 0.957, green: 0.957, blue: 0.965)
    /// The brand mint. Used only for progress, selection marks and toggles.
    static let reelBlue = Color(red: 0.61, green: 0.86, blue: 0.76)
    static let tvMuted = Color.reelText.opacity(0.66)
    static let tvTertiary = Color.reelText.opacity(0.46)
    static let tvHairline = Color.white.opacity(0.08)
    /// Placeholder text that stays readable on a text field's dark resting capsule and its white focused one.
    static let tvFieldPlaceholder = Color(white: 0.56)
    /// The lifted card's shadow: an off-black a little deeper than the canvas.
    static let tvShadow = Color(red: 0.012, green: 0.012, blue: 0.016)
    /// A chip at rest, the same grey tvOS gives a button on the canvas.
    static let tvChip = Color(red: 0.227, green: 0.227, blue: 0.235)
    /// The selected chip: a lighter neutral, never the brand mint.
    static let tvChipSelected = Color(red: 0.345, green: 0.345, blue: 0.357)
}

/// Layout constants for a 1920x1080 canvas. tvOS scales them for 720p output.
enum TVLayout {
    static let margin: CGFloat = 96
    static let artworkRadius: CGFloat = 14
    static let posterWidth: CGFloat = 230
    static let landscapeWidth: CGFloat = 400
    static let rowSpacing: CGFloat = 40
}

extension Animation {
    static let tvState = Animation.easeOut(duration: 0.22)
}

/// Focus for artwork: the card scales up and lifts on a soft shadow. No sheen, rim or tilt, so every
/// card on every screen moves the same way. A press settles it back halfway.
struct TVLiftStyle: ButtonStyle {
    var scale: CGFloat = 1.08
    var radius: CGFloat = TVLayout.artworkRadius

    func makeBody(configuration: Configuration) -> some View {
        Lift(configuration: configuration, scale: scale, radius: radius)
    }

    private struct Lift: View {
        let configuration: Configuration
        let scale: CGFloat
        let radius: CGFloat
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let lifted = focused && !configuration.isPressed
            configuration.label
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .scaleEffect(focused ? (configuration.isPressed ? 1 + (scale - 1) / 2 : scale) : 1)
                .shadow(color: Color.tvShadow.opacity(lifted ? 0.7 : 0), radius: lifted ? 26 : 0, y: lifted ? 18 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// A category chip. It turns white and lifts when focused, like the system buttons around it. The selected
/// chip keeps a lighter neutral fill and full-white text, so mint stays a mark of progress and focus only.
struct TVChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, selected: selected)
    }

    private struct Chip: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Color.reelBackground : selected ? Color.reelText : Color.tvMuted)
                .padding(.horizontal, 30).padding(.vertical, 18)
                .background(Capsule().fill(focused ? Color.reelText : selected ? Color.tvChipSelected : Color.tvChip))
                .scaleEffect(focused ? (configuration.isPressed ? 1.04 : 1.08) : 1)
                .shadow(color: Color.tvShadow.opacity(focused ? 0.5 : 0), radius: focused ? 16 : 0, y: focused ? 10 : 0)
                .opacity(enabled ? 1 : 0.5)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// The title's first genre, small and muted above its name. An episode shows its series and number there instead.
struct TVGenreEyebrow: View {
    let item: MediaItem
    var body: some View {
        if item.Type != "Episode", let genre = item.Genres?.first?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty {
            Text(genre).font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.tvMuted).lineLimit(1)
                .accessibilityIdentifier("genreEyebrow")
        }
    }
}

enum TVMetadata {
    /// "1h 52m", "48m", or seconds for very short media such as trailers and samples.
    static func runtime(_ ticks: Int64?) -> String? {
        guard let ticks, ticks > 0 else { return nil }
        let seconds = Int((Double(ticks) / ticksPerSecond).rounded())
        if seconds < 60 { return "\(max(1, seconds))s" }
        let minutes = seconds / 60
        guard minutes >= 60 else { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    static func remaining(_ item: MediaItem) -> String? {
        guard item.resumeTicks > 0, let total = item.RunTimeTicks, total > item.resumeTicks,
              let left = runtime(total - item.resumeTicks) else { return nil }
        return left + " left"
    }

    static func facts(_ item: MediaItem) -> [String] {
        var values: [String] = []
        if let year = item.ProductionYear { values.append(String(year)) }
        if let rating = item.OfficialRating?.trimmingCharacters(in: .whitespacesAndNewlines), !rating.isEmpty { values.append(rating) }
        if item.isSeries { values.append("Series") }
        else if let runtime = runtime(item.RunTimeTicks) { values.append(runtime) }
        return values
    }

    static func rating(_ item: MediaItem) -> String? {
        guard let rating = item.OfficialRating?.trimmingCharacters(in: .whitespacesAndNewlines), !rating.isEmpty else { return nil }
        return rating
    }

    /// The community score out of ten with one decimal, such as "7.6".
    static func stars(_ item: MediaItem) -> String? {
        guard let score = item.CommunityRating, score > 0, score <= 10 else { return nil }
        return String(format: "%.1f", score)
    }

    /// Media badges only when the server reports the stream properties.
    static func badges(_ item: MediaItem) -> [String] {
        guard let streams = item.MediaSources?.first?.MediaStreams else { return [] }
        var values: [String] = []
        let video = streams.first { $0.Type == "Video" }
        if let width = video?.Width, width >= 3800 { values.append("4K") }
        let range = (video?.VideoRangeType ?? "").uppercased()
        if video?.DvProfile != nil || range.hasPrefix("DOVI") { values.append("Dolby Vision") }
        else if range.contains("HDR") || range.contains("HLG") { values.append("HDR") }
        let audio = streams.filter { $0.Type == "Audio" }
        if let channels = audio.compactMap(\.Channels).max() {
            if channels >= 8 { values.append("7.1") } else if channels >= 6 { values.append("5.1") }
        }
        if audio.contains(where: { ($0.AudioSpatialFormat ?? "").localizedCaseInsensitiveContains("atmos") }) { values.append("Atmos") }
        if streams.contains(where: { $0.Type == "Subtitle" }) { values.append("CC") }
        return values
    }

    static func episodeLabel(_ item: MediaItem) -> String {
        let number = [item.ParentIndexNumber.flatMap { $0 >= 0 ? "S\($0)" : nil },
                      item.IndexNumber.flatMap { $0 >= 0 ? "E\($0)" : nil }].compactMap { $0 }.joined(separator: " ")
        return number
    }

    /// One short line under a card, written as on iPhone and the web: "S1 E2 Manifest", or
    /// "2025 · 1h 58m".
    static func caption(_ item: MediaItem) -> String {
        if item.Type == "Episode" {
            return [episodeLabel(item), item.Name].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return facts(item).filter { $0 != item.OfficialRating }.joined(separator: " · ")
    }
}

/// One line in the order every Reel client uses: year, boxed rating, runtime (or "Series"), star score,
/// then the stream badges.
struct TVMetadataLine: View {
    let item: MediaItem
    var size: CGFloat = 24
    var body: some View {
        let year = item.ProductionYear.map { String($0) }, rating = TVMetadata.rating(item)
        let length = item.isSeries ? "Series" : TVMetadata.runtime(item.RunTimeTicks)
        let stars = TVMetadata.stars(item), badges = TVMetadata.badges(item)
        if year != nil || rating != nil || length != nil || stars != nil || !badges.isEmpty {
            HStack(spacing: 22) {
                if let year { Text(year) }
                if let rating { badge(rating) }
                if let length { Text(length) }
                if let stars {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill").font(.system(size: size * 0.7))
                        Text(stars)
                    }
                    .accessibilityElement(children: .ignore).accessibilityLabel("Rated \(stars) out of 10")
                }
                ForEach(badges, id: \.self) { badge($0) }
            }
            .font(.system(size: size, weight: .medium)).foregroundStyle(Color.tvMuted)
            .accessibilityElement(children: .combine)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: size * 0.72, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.reelText.opacity(0.4), lineWidth: 1.5))
    }
}

/// Full-bleed artwork behind a screen. Keeps the previous image until the next one
/// has decoded, then crossfades, so focus changes never flash an empty canvas.
struct TVBackdrop: View {
    let item: MediaItem?
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Shown?

    private struct Shown: Equatable {
        let id: String
        let image: UIImage
        let poster: Bool
    }

    var body: some View {
        ZStack {
            Color.reelBackground
            if let shown {
                Image(uiImage: shown.image).resizable().scaledToFill()
                    .blur(radius: shown.poster ? 40 : 0).opacity(shown.poster ? 0.55 : 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .id(shown.id).transition(.opacity)
            }
            LinearGradient(stops: [.init(color: Color.reelBackground.opacity(0.94), location: 0), .init(color: Color.reelBackground.opacity(0.7), location: 0.42), .init(color: Color.reelBackground.opacity(0.08), location: 0.8)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: Color.reelBackground.opacity(0.72), location: 0.62), .init(color: Color.reelBackground, location: 0.98)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task(id: "\(session.revision)|\(item?.id ?? "")") { await load() }
    }

    private func load() async {
        guard let item, let api = session.api else { set(nil); return }
        let reference = item.imageReference(backdrop: true)
        if shown?.id == item.id { return }
        do {
            let image = try await TVImages.load(item, backdrop: true, pixels: 1920, api: api)
            set(image.map { Shown(id: item.id, image: $0, poster: reference.type == "Primary") })
        } catch is CancellationError {
        } catch { set(nil) }
    }

    private func set(_ value: Shown?) {
        guard value != shown else { return }
        if reduceMotion { shown = value } else { withAnimation(.easeOut(duration: 0.24)) { shown = value } }
    }
}

enum TVImages {
    /// Fetches through the shared artwork cache and decodes a downscaled image off the main actor.
    static func load(_ item: MediaItem, backdrop: Bool, pixels: Int, api: JellyfinAPI) async throws -> UIImage? {
        let request = api.imageRequest(item, backdrop: backdrop, width: pixels)
        let data = try await ArtworkPipeline.shared.data(request: request, userID: api.userID ?? "", server: api.server)
        try Task.checkCancellation()
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        }.value
        try Task.checkCancellation()
        return image.map { UIImage(cgImage: $0) }
    }
}

/// Card artwork for tvOS. The image replaces the placeholder without an animated transition:
/// with the shared view's animated swap, a card that tvOS refocused after Back drew as focused
/// while the accessibility tree reported no focused element.
struct TVArtwork: View {
    let item: MediaItem
    var backdrop = false
    var width = 500
    @Environment(Session.self) private var session
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.reelSurface
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.isSeries ? "tv" : "film").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(Color.tvTertiary)
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .task(id: "\(session.revision)|\(item.id)|\(backdrop)|\(width)") {
            image = nil
            guard let api = session.api else { return }
            // Artwork is optional; the title and playback stay available without it.
            image = try? await TVImages.load(item, backdrop: backdrop, pixels: width, api: api)
        }
    }
}

struct TVMark: View {
    var body: some View {
        HStack(spacing: 16) {
            Image("BrandMark").resizable().scaledToFit().frame(width: 48, height: 48).foregroundStyle(Color.reelBlue)
            Text("Reel").font(.system(size: 36, weight: .bold)).tracking(-0.8)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Reel")
    }
}

/// An empty or failed state, centered in the space it fills: a quiet symbol, one heading, one sentence
/// and at most one row of actions.
struct TVStateMessage<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 52, weight: .light)).foregroundStyle(Color.tvTertiary)
                .padding(.bottom, 8).accessibilityHidden(true)
            Text(title).font(.system(size: 38, weight: .bold)).tracking(-0.4).foregroundStyle(Color.reelText)
                .multilineTextAlignment(.center)
            Text(message).font(.system(size: 26)).foregroundStyle(Color.tvMuted).multilineTextAlignment(.center)
                .frame(maxWidth: 820).fixedSize(horizontal: false, vertical: true)
            if Actions.self != EmptyView.self {
                HStack(spacing: 24) { actions() }.padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        // The section spans the full width, so Up or Down from a left-aligned row still lands on the
        // centered actions.
        .focusSection()
    }
}

struct TVFailure: View {
    let title: String
    let message: String
    let retry: () -> Void
    var body: some View {
        TVStateMessage(symbol: "exclamationmark.triangle", title: title, message: message) {
            Button("Try again", action: retry).accessibilityIdentifier("retry")
        }
    }
}

struct TVEmpty<Actions: View>: View {
    let title: String
    let message: String
    var symbol = "film.stack"
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        TVStateMessage(symbol: symbol, title: title, message: message, actions: actions)
    }
}

extension TVEmpty where Actions == EmptyView {
    init(title: String, message: String, symbol: String = "film.stack") {
        self.init(title: title, message: message, symbol: symbol) { EmptyView() }
    }
}

/// Placeholder posters or stills in the grid a library page will fill.
struct TVSkeletonGrid: View {
    var wide = false
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? 350 : 230, maximum: wide ? 440 : 310), spacing: 35)], alignment: .leading, spacing: 40) {
            ForEach(0..<12, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 18) {
                    RoundedRectangle(cornerRadius: TVLayout.artworkRadius, style: .continuous).fill(Color.reelSurfaceRaised)
                        .aspectRatio(wide ? 16.0 / 9 : 2.0 / 3, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.reelSurface).frame(width: 150, height: 22)
                }
            }
        }
    }
}

/// Placeholder cards shaped like the row that is loading.
struct TVSkeletonRow: View {
    var wide = true
    var count = 5
    var body: some View {
        HStack(spacing: TVLayout.rowSpacing) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: TVLayout.artworkRadius, style: .continuous).fill(Color.reelSurfaceRaised)
                    .frame(width: wide ? TVLayout.landscapeWidth : TVLayout.posterWidth, height: wide ? TVLayout.landscapeWidth * 9 / 16 : TVLayout.posterWidth * 1.5)
            }
        }.accessibilityHidden(true)
    }
}

struct TVProgressBar: View {
    let progress: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.tvShadow.opacity(0.55))
                Capsule().fill(Color.reelBlue).frame(width: max(8, geometry.size.width * progress))
            }
        }.frame(height: 6)
    }
}

/// Poster (2:3) or landscape (16:9) card. `TVLiftStyle` owns focus feedback.
struct TVCard<Focus: ViewModifier>: View {
    let item: MediaItem
    var wide = false
    /// Replaces the usual second line, as Continue watching does with the time left.
    var caption: String? = nil
    var dateText: String? = nil
    var controlID: String? = nil
    var countStale = false
    var selection: Bool? = nil
    var width: CGFloat? = nil
    let action: () -> Void

    var focus: Focus

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Only the artwork lifts on focus; the text stays below it.
            Button(action: action) {
                TVArtwork(item: wide ? item.thumbnailItem : item, backdrop: wide, width: wide ? 800 : 480)
                    .aspectRatio(wide ? 16.0 / 9 : 2.0 / 3, contentMode: .fit)
                    .overlay(alignment: .bottom) {
                        if item.progress > 0 { TVProgressBar(progress: item.progress).padding(14) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let selection {
                            Image(systemName: selection ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(selection ? Color.reelBlue : Color.reelText, Color.tvShadow.opacity(0.6))
                                .padding(12).accessibilityHidden(true)
                        }
                    }
            }
            .buttonStyle(TVLiftStyle())
            .accessibilityLabel(item.title)
            .accessibilityValue([item.subtitle, caption, dateText, item.isAggregate ? item.aggregateUnplayedCount.map { "\($0) unwatched" } ?? "Unwatched count unavailable" : nil, countStale && item.isAggregate ? "Count may be out of date" : nil, selection.map { $0 ? "Selected" : "Not selected" }].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(selection == true ? .isSelected : [])
            .accessibilityIdentifier(controlID ?? "item-" + item.listingID)
            .modifier(focus)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.system(size: 24, weight: .semibold)).foregroundStyle(Color.reelText).lineLimit(1)
                    let line = caption ?? TVMetadata.caption(item)
                    if !line.isEmpty { Text(line).font(.system(size: 20)).foregroundStyle(Color.tvMuted).lineLimit(1) }
                    if let dateText { Text(dateText).font(.system(size: 19)).foregroundStyle(Color.tvTertiary).lineLimit(1) }
                }
                // The button already speaks the title and these details.
                .accessibilityHidden(true)
                if item.isAggregate { TVUnwatchedCount(item: item, stale: countStale) }
            }
        }
        .frame(width: width)
    }
}

extension TVCard where Focus == EmptyModifier {
    init(item: MediaItem, wide: Bool = false, caption: String? = nil, dateText: String? = nil, controlID: String? = nil, countStale: Bool = false,
         selection: Bool? = nil, width: CGFloat? = nil, action: @escaping () -> Void) {
        self.init(item: item, wide: wide, caption: caption, dateText: dateText, controlID: controlID, countStale: countStale,
                  selection: selection, width: width, action: action, focus: EmptyModifier())
    }
}

/// Binds a card's button, not its caption stack, to a screen's focus state.
struct TVFocusTag<Value: Hashable>: ViewModifier {
    let binding: FocusState<Value?>.Binding
    let value: Value
    func body(content: Content) -> some View { content.focused(binding, equals: value) }
}

/// A titled horizontal row. Clipping is off so lifted cards are never cut at the edges.
struct TVShelf<Content: View, Accessory: View>: View {
    let title: String
    var identifier: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 28) {
                Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.3)
                accessory()
            }
            .padding(.horizontal, TVLayout.margin)
            .focusSection()
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TVLayout.rowSpacing) { content() }
                    .padding(.vertical, 24)
            }
            .contentMargins(.horizontal, TVLayout.margin, for: .scrollContent)
            .scrollClipDisabled()
            .focusSection()
            .accessibilityIdentifier(identifier ?? "shelf-" + title)
        }
    }
}

extension TVShelf where Accessory == EmptyView {
    init(title: String, identifier: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.identifier = identifier; self.accessory = { EmptyView() }; self.content = content
    }
}
