import SwiftUI
import ImageIO

actor ArtworkPipeline {
    static let shared = ArtworkPipeline()
    private let cache = NSCache<NSString, NSData>()
    private var pending: [String: Task<Data, Error>] = [:]
    private var generation = UUID()

    init() { cache.totalCostLimit = 48 * 1024 * 1024; cache.countLimit = 240 }
    func clear() {
        generation = UUID()
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        cache.removeAllObjects()
    }
    func data(request: URLRequest, userID: String, server: URL) async throws -> Data {
        let key = userID + "|" + (request.url?.absoluteString ?? "")
        if let hit = cache.object(forKey: key as NSString) { return hit as Data }
        if let task = pending[key] { return try await task.value }
        let current = generation
        let task = Task {
            let (data, response) = try await JellyfinAPI.transport.data(for: request, delegate: SameOriginRedirects(server: server))
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  data.count < 16 * 1024 * 1024 else { throw ReelError.invalidResponse }
            return data
        }
        pending[key] = task
        do {
            let data = try await task.value
            guard generation == current else { throw CancellationError() }
            pending[key] = nil
            cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
            return data
        } catch { if generation == current { pending[key] = nil }; throw error }
    }
}

struct Artwork: View {
    let item: MediaItem
    var backdrop = false
    var width = 500
    @Environment(Session.self) private var session
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The color takes exactly the offered size; the filled image is drawn
        // over it and clipped, so overflow never covers neighbouring controls.
        Color.reelSurface
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill().transition(.opacity) }
                else {
                    LinearGradient(colors: [Color.reelSurfaceRaised, Color.reelSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: item.isSeries ? "tv" : "film").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(.white.opacity(0.15))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: image != nil)
            .clipped()
            .contentShape(Rectangle())
        .accessibilityHidden(true)
        .task(id: "\(session.revision)|\(item.id)|\(backdrop)|\(width)") {
            image = nil
            guard let api = session.api else { return }
            let request = api.imageRequest(item, backdrop: backdrop, width: width)
            do {
                let data = try await ArtworkPipeline.shared.data(request: request, userID: api.userID ?? "", server: api.server)
                try Task.checkCancellation()
                let pixelSize = min(width, Int(CGFloat(width) * scale))
                let cgImage = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixelSize, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                }.value
                try Task.checkCancellation()
                if let cgImage { image = UIImage(cgImage: cgImage) }
            } catch { /* Artwork is optional; the title and playback remain available. */ }
        }
    }
}
