import Foundation

struct TVSubtitleCatalog: Equatable {
    struct Track: Equatable {
        let index: Int
        let title: String
    }

    let tracks: [Track]
    let error: String?
    private let sources: [MediaSource]

    init(item: MediaItem?, sourceID: String?) {
        sources = item?.MediaSources?.filter { $0.Id == sourceID } ?? []
        guard sources.count == 1, let streams = sources.first?.MediaStreams else {
            tracks = []
            error = "The subtitle track list is unavailable. Choose Off, or return to Details to choose a version."
            return
        }
        let subtitles = streams.filter { $0.Type == "Subtitle" }
        func title(_ stream: MediaStream) -> String {
            stream.DisplayTitle?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping ?? ""
        }
        let titles = subtitles.map(title).filter { !$0.isEmpty }
        guard subtitles.allSatisfy({ $0.Index >= 0 }), Set(subtitles.map(\.Index)).count == subtitles.count,
              Set(titles).count == titles.count else {
            tracks = []
            error = "These subtitle tracks can’t be distinguished safely. Choose Off, or return to Details to choose another version."
            return
        }
        tracks = subtitles.map { stream in
            let name = title(stream)
            return Track(index: stream.Index, title: name.isEmpty ? (stream.Language ?? "Subtitle") + " · Track \(stream.Index)" : name)
        }
        error = nil
    }
}
