import AudioAnalysis
import Foundation

/// Keeps Christmas out of a summer playlist.
///
/// A generated pool is filtered by genre, mood and activity — none of which
/// exclude seasonal music. "Holly Jolly Christmas" is genuinely easy listening,
/// genuinely relaxed, and genuinely fits "chilling", so it sailed through every
/// gate and into a playlist for sitting in the sun.
///
/// Pure and conservative: it only drops a track when the request did NOT ask for
/// the season. Ask for Christmas and you get Christmas.
public enum SeasonalFilter {

    /// Words that mark a track as seasonal wherever they appear in the title or
    /// album. Deliberately narrow — "winter" and "snow" are left out because
    /// they carry plenty of non-seasonal songs ("Winter" by Tori Amos,
    /// "Snow (Hey Oh)"), and a false drop is worse than an occasional miss.
    static let markers = [
        "christmas", "kerst", "xmas", "noël", "noel", "santa", "st. nick",
        "jingle bell", "silent night", "auld lang syne", "feliz navidad",
        "sinterklaas", "advent", "holiday season", "merry gentlemen",
        "little drummer boy", "winter wonderland", "sleigh ride"
    ]

    /// True when this text names the season outright.
    public static func mentionsSeason(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let low = text.lowercased()
        return markers.contains { low.contains($0) }
    }

    /// Is this track seasonal? Checks title, album and genres — a Christmas album
    /// often has ordinary song titles ("Blue Christmas" vs "White Winter Hymnal").
    public static func isSeasonal(title: String?, album: String?, genres: [String]) -> Bool {
        if mentionsSeason(title) || mentionsSeason(album) { return true }
        return genres.contains { g in
            let low = g.lowercased()
            return low.contains("christmas") || low.contains("holiday")
        }
    }

    /// Drop seasonal tracks unless `prompt` asked for them.
    ///
    /// `keepIfFewerThan` is a safety valve borrowed from the genre and mood
    /// gates: if filtering would starve the pool, return it untouched rather
    /// than hand back nothing.
    public static func filter<T>(
        _ pool: [T], prompt: String?, keepIfFewerThan minPool: Int,
        title: (T) -> String?, album: (T) -> String?, genres: (T) -> [String]
    ) -> (kept: [T], dropped: Int) {
        guard !mentionsSeason(prompt) else { return (pool, 0) }
        let kept = pool.filter { !isSeasonal(title: title($0), album: album($0), genres: genres($0)) }
        guard kept.count >= minPool else { return (pool, 0) }
        return (kept, pool.count - kept.count)
    }
}
