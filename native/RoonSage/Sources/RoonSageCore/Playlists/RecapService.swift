import Foundation

/// "Wat je deze week draaide" — weekly and monthly recaps, generated from
/// listening history and materialised as playlists.
///
/// `YearInReviewView` already answers the same question once a year, which is
/// long enough that it is a retrospective rather than something you play. A
/// week is short enough to still recognise, and a month is the unit people
/// actually think in.
///
/// Materialised through `syncExternalPlaylists(sourcePrefix: "recap:")` rather
/// than written as ordinary playlists, which buys three things the reconcile
/// already implements: a stable identity per period (so regenerating replaces
/// rather than duplicates), pruning of periods that fall out of the window, and
/// complete isolation from the user's own playlists — those have a NULL
/// `external_id` and are never touched.
public struct RecapService: Sendable {

    /// How many past periods to keep. Four weeks and three months is roughly
    /// "the recent past"; beyond that the yearly review is the right surface,
    /// and an unbounded list of recaps would bury the playlists you made.
    public static let weeksKept = 4
    public static let monthsKept = 3

    /// Minimum plays before a period is worth summarising. A week with three
    /// plays produces a "recap" that is just those three tracks, which reads as
    /// a broken feature rather than a quiet week.
    public static let minPlaysPerPeriod = 10

    public static let sourcePrefix = "recap:"

    /// One recap: what to call it, and the window it covers.
    public struct Period: Sendable, Equatable {
        public let externalID: String
        public let name: String
        public let start: Date
        public let end: Date
    }

    private let database: DatabaseManager
    private let calendar: Calendar
    private let locale: Locale

    /// The calendar and locale are injected so tests are not at the mercy of the
    /// machine's region — week numbering in particular differs between them
    /// (ISO weeks start Monday; the US default starts Sunday), and a recap whose
    /// name changes with the region is a recap that regenerates as a duplicate.
    ///
    /// `Locale.current` rather than the app's `LocalePreference`: that setting
    /// lives in `RoonSageUI`, which sits above this module, and recaps are
    /// generated on the server-of-record where the two are the same thing
    /// anyway.
    public init(database: DatabaseManager,
                calendar: Calendar = RecapService.defaultCalendar,
                locale: Locale = .current) {
        self.database = database
        self.calendar = calendar
        self.locale = locale
    }

    /// ISO-8601 weeks, because "week 34" has to mean the same thing every time
    /// the recap is regenerated — including on a device whose region says weeks
    /// start on Sunday.
    public static var defaultCalendar: Calendar { Calendar(identifier: .iso8601) }

    // MARK: - Periods

    /// The last `weeksKept` complete weeks, newest first. The week in progress
    /// is excluded: a recap of a week that is not over changes every day, so it
    /// is a live list pretending to be a summary.
    public func recentWeeks(now: Date = Date()) -> [Period] {
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        return (1...Self.weeksKept).compactMap { offset -> Period? in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeekStart),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            let week = calendar.component(.weekOfYear, from: start)
            let year = calendar.component(.yearForWeekOfYear, from: start)
            return Period(externalID: "\(Self.sourcePrefix)week:\(year)-W\(String(format: "%02d", week))",
                          name: String(format: CoreStrings.s("core.recap.week", "Terugblik — week %d"), week),
                          start: start, end: end)
        }
    }

    /// The last `monthsKept` complete months, newest first — same reasoning.
    public func recentMonths(now: Date = Date()) -> [Period] {
        guard let thisMonthStart = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        return (1...Self.monthsKept).compactMap { offset -> Period? in
            guard let start = calendar.date(byAdding: .month, value: -offset, to: thisMonthStart),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return Period(externalID: "\(Self.sourcePrefix)month:\(Self.monthKey(start, calendar: calendar))",
                          name: String(format: CoreStrings.s("core.recap.month", "Terugblik — %@"),
                                       formatter.string(from: start)),
                          start: start, end: end)
        }
    }

    static func monthKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return "\(c.year ?? 0)-\(String(format: "%02d", c.month ?? 0))"
    }

    // MARK: - Generation

    /// Build every recent recap and reconcile them into the playlist table.
    ///
    /// Idempotent: regenerating replaces each period in place (same
    /// `external_id`), and periods that have aged out are pruned by the same
    /// reconcile — so this can run on every launch without accumulating.
    ///
    /// Returns the playlists it wrote, for the caller's log.
    @discardableResult
    public func regenerate(now: Date = Date(), tracksPerRecap: Int = 30) async -> [String] {
        var playlists: [DatabaseManager.ExternalPlaylist] = []
        for period in recentWeeks(now: now) + recentMonths(now: now) {
            guard let count = try? await database.listenCount(from: period.start, to: period.end),
                  count >= Self.minPlaysPerPeriod else { continue }
            guard let tracks = try? await database.recapTracks(
                from: period.start, to: period.end, limit: tracksPerRecap), !tracks.isEmpty else { continue }
            playlists.append(DatabaseManager.ExternalPlaylist(
                externalID: period.externalID, name: period.name, tracks: tracks))
        }
        // Reconciled even when empty — that is how a library whose history was
        // cleared loses its stale recaps instead of keeping them forever.
        try? await database.syncExternalPlaylists(sourcePrefix: Self.sourcePrefix, playlists: playlists)
        return playlists.map(\.name)
    }
}
