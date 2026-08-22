import Foundation

/// The arithmetic behind the Now Playing screen, with no view attached.
///
/// It exists because there used to be **two** Now Playing screens — one bound to
/// a Roon zone, one to the on-device engine — that each carried their own copy
/// of this maths. They were aligned by hand twice (v1.10.229 and v1.10.260) and
/// drifted again in between. Pulling the calculations down here means the single
/// `PlayerScreen` above can stay a layout, and the parts that can silently go
/// wrong (clamping, a paused clock that keeps running, a negative remaining
/// time) are covered by `NowPlayingModelTests` instead of by eyeballing.
///
/// Everything here is pure and `nonisolated`: same input, same output, no clock
/// of its own — `now` is always passed in, so the interpolation is testable.
public enum NowPlayingModel {

    // MARK: - Loop mode

    /// Cycle Roon's loop vocabulary: off → all → one → off.
    ///
    /// The on-device engine deliberately speaks the same three strings
    /// (`LocalPlayback.loopMode`), so one function serves both outputs.
    public static func nextLoop(_ current: String) -> String {
        switch current {
        case "disabled": "loop"
        case "loop":     "loop_one"
        default:         "disabled"
        }
    }

    // MARK: - Position

    /// Progress through the track as 0…1, or 0 when the length is unknown.
    ///
    /// A stream with no reported length must return 0 rather than dividing by
    /// zero: the bar can't fill, but the elapsed counter still runs.
    public static func fraction(position: Double, duration: Double) -> Double {
        guard duration > 0, position.isFinite, duration.isFinite else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    /// The position to display between two authoritative updates.
    ///
    /// Roon reports a seek position only on each poll, so the screen advances the
    /// clock itself from a wall-clock anchor: `anchor + (now − anchoredAt)`. That
    /// is deliberately not "+1 per timer tick" — timer ticks aren't exactly one
    /// second apart and a poll can land mid-second, which drifted a few seconds
    /// per track in the version this replaces.
    ///
    /// While paused the anchor is returned unchanged, so a pause doesn't silently
    /// accumulate time that jumps into view on resume.
    public static func interpolatedPosition(
        anchor: Double,
        anchoredAt: Date,
        now: Date,
        isPlaying: Bool,
        duration: Double
    ) -> Double {
        let base = max(0, anchor)
        guard isPlaying else { return clampToDuration(base, duration: duration) }
        let elapsed = max(0, now.timeIntervalSince(anchoredAt))
        return clampToDuration(base + elapsed, duration: duration)
    }

    /// Where a drag at `x` inside a bar of `width` lands, in seconds.
    /// Returns nil when there is nothing to seek within — the caller must then
    /// leave the position alone rather than jump to 0.
    public static func seekSeconds(atX x: Double, width: Double, duration: Double) -> Double? {
        guard duration > 0, width > 0 else { return nil }
        return min(max(x / width, 0), 1) * duration
    }

    /// Seconds still to play; never negative, even if the reported position
    /// overshoots the length (which Roon does briefly at a track boundary).
    public static func remaining(position: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return max(0, duration - min(max(position, 0), duration))
    }

    private static func clampToDuration(_ value: Double, duration: Double) -> Double {
        guard duration > 0 else { return max(0, value) }
        return min(max(0, value), duration)
    }

    // MARK: - Formatting

    /// `m:ss`, or `h:mm:ss` past the hour. Negative and non-finite input reads as
    /// `0:00` rather than as `-1:-1` — a NaN duration reached this from an AVAsset
    /// that hadn't loaded yet.
    public static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// The right-hand counter: `-1:23`, or `--:--` when the length is unknown.
    public static func remainingLabel(position: Double, duration: Double) -> String {
        guard duration > 0 else { return "--:--" }
        return "-" + formatTime(remaining(position: position, duration: duration))
    }
}
