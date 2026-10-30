import Foundation

/// Only use neighbors returned around the current episode, within the same series.
enum EpisodePlayback {
    static func neighbors(of current: MediaItem, in items: [MediaItem]) -> (previous: MediaItem?, next: MediaItem?) {
        guard current.Type == "Episode", let seriesID = current.SeriesId else { return (nil, nil) }
        let episodes = items.filter { candidate in
            candidate.Type == "Episode" && candidate.SeriesId == seriesID
                && items.filter { $0.id == candidate.id }.count == 1
        }
        guard let index = episodes.firstIndex(where: { $0.id == current.id }) else { return (nil, nil) }
        return (index > 0 ? episodes[index - 1] : nil, index + 1 < episodes.count ? episodes[index + 1] : nil)
    }

    static func segments(_ items: [MediaSegment], duration: Int64?) -> [MediaSegment] {
        items.filter {
            ["Intro", "Outro", "Recap", "Preview"].contains($0.Type)
                && $0.StartTicks >= 0 && $0.EndTicks > $0.StartTicks
                && (duration == nil || duration! <= 0 || $0.EndTicks <= duration!)
        }
    }
}
