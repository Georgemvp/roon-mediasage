import AudioAnalysis
import Foundation

// MARK: - Plex as a library source
//
// Plex already indexes the very folder the analyser walks
// (`/Volumes/4tbdrive/Muziek`) and, unlike Roon's Browse API, hands out a
// **stable** per-track id (`ratingKey`) plus the absolute file path. That file
// path is what makes Plex worth pulling: `track_features` is keyed on
// `file_path`, so Plex ↔ analyser is an exact join instead of the fuzzy
// `match_key` bridge that currently loses rows.
//
// Measured against the real installs on 2026-08-23 (65.738 Plex paths vs 66.467
// analyser paths):
//   58.308  exact matches — after NFC normalisation (only 55.700 before, see below)
//    7.430  Plex-only  — files the analyser has not analysed; all 300 sampled exist
//    8.038  analyser-only — stale rows; 0 of 300 sampled still exist on disk
// So Plex is the more accurate picture of what is actually on the disk.

/// Read-only client for a Plex Media Server's music section.
///
/// Deliberately minimal: enumerate tracks. Playback, transcoding and artwork are
/// Plex URL constructions the caller makes; nothing here streams.
public struct PlexClient: Sendable {

    /// Where the desktop Plex Media Server keeps its preferences on macOS. Note
    /// the doubled "Plex" — the *data* directory (`Plex Media Server/`) sits
    /// elsewhere, and looking for the token there finds nothing.
    public static let macPreferencesPath =
        "Library/Application Support/Plex/Plex Media Server/Preferences.xml"

    public enum PlexError: Error, Sendable, Equatable {
        case noToken
        case badURL(String)
        case http(Int)
        case malformedResponse(String)
        case transport(String)
    }

    public let baseURL: URL
    public let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    // MARK: - Token discovery

    /// `PlexOnlineToken` from the local server's Preferences.xml, or nil.
    ///
    /// Only works on the machine running Plex — which is the mini, i.e. the
    /// analyser host, i.e. exactly where the library sync runs. Clients never
    /// need this: they talk to the analyser, not to Plex directly.
    public static func localToken(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> String? {
        let url = home.appendingPathComponent(macPreferencesPath)
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return attribute("PlexOnlineToken", in: xml)
    }

    /// Pull one `name="value"` attribute out of Plex's single-element XML. A
    /// full XML parse would be overkill for a one-line document, but the value
    /// may contain anything except a quote, so match to the closing quote.
    static func attribute(_ name: String, in xml: String) -> String? {
        guard let range = xml.range(of: "\(name)=\"") else { return nil }
        let rest = xml[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
    }

    // MARK: - Sections

    public struct Section: Sendable, Equatable {
        public let key: String
        public let type: String
        public let title: String
    }

    /// All library sections. Music sections have `type == "artist"`.
    public func sections() async throws -> [Section] {
        let json = try await getJSON(path: "/library/sections", query: [])
        guard let container = json["MediaContainer"] as? [String: Any],
              let dirs = container["Directory"] as? [[String: Any]] else {
            throw PlexError.malformedResponse("/library/sections: no MediaContainer.Directory")
        }
        return dirs.compactMap { d in
            guard let key = d["key"] as? String,
                  let type = d["type"] as? String,
                  let title = d["title"] as? String else { return nil }
            return Section(key: key, type: type, title: title)
        }
    }

    /// The first music section, or nil when the server has none.
    public func musicSection() async throws -> Section? {
        try await sections().first { $0.type == "artist" }
    }

    // MARK: - Tracks

    public struct Track: Sendable, Equatable {
        /// Plex's stable per-item id. Survives rescans; unlike Roon's `item_key`
        /// it is safe to store as a primary key.
        public let ratingKey: String
        /// `plex://track/…` when Plex matched the recording, `local://…` when it
        /// could not. 28.799 of 65.738 were `local://` on 2026-08-23, so treat a
        /// matched guid as a bonus, never as a requirement.
        public let guid: String?
        public let title: String
        public let artist: String?
        public let album: String?
        /// Plex's stable album id (`parentRatingKey`). A real key for album
        /// grouping, where the Roon and analyser sources both have to fall back
        /// to an `album|artist` string fingerprint.
        public let albumRatingKey: String?
        public let year: Int?
        /// Absolute path on the server's disk — the exact join key to the
        /// analyser's `track_features.file_path`. Always NFC-normalised here.
        public let filePath: String?
        /// Milliseconds.
        public let duration: Int?
        /// Plex-relative artwork path (`/library/metadata/…/thumb/…`).
        public let thumb: String?

        public init(ratingKey: String, guid: String?, title: String, artist: String?,
                    album: String?, albumRatingKey: String? = nil, year: Int?,
                    filePath: String?, duration: Int?, thumb: String?) {
            self.ratingKey = ratingKey
            self.guid = guid
            self.title = title
            self.artist = artist
            self.album = album
            self.albumRatingKey = albumRatingKey
            self.year = year
            self.filePath = filePath
            self.duration = duration
            self.thumb = thumb
        }
    }

    /// Default page size. Plex streams happily at this size; the full 65.738-track
    /// section is ~66 requests.
    public static let pageSize = 1000

    /// Every track in `section`, fetched page by page.
    ///
    /// `onPage` is called after each page so a caller can stream 65k tracks into
    /// the database instead of holding them all in memory.
    public func allTracks(inSection section: String,
                          pageSize: Int = PlexClient.pageSize,
                          onPage: ([Track]) async throws -> Void) async throws {
        var start = 0
        while true {
            let json = try await getJSON(path: "/library/sections/\(section)/all", query: [
                URLQueryItem(name: "type", value: "10"),      // 10 = track
                URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(pageSize)),
            ])
            guard let container = json["MediaContainer"] as? [String: Any] else {
                throw PlexError.malformedResponse("section \(section): no MediaContainer")
            }
            let items = (container["Metadata"] as? [[String: Any]]) ?? []
            if items.isEmpty { return }
            try await onPage(items.compactMap(Self.parseTrack))
            start += items.count
            // `totalSize` is only present on the first page of some versions, so
            // trust the short page instead: fewer items than asked for = last page.
            if items.count < pageSize { return }
        }
    }

    /// Convenience: collect every track into an array. Fine for tests and small
    /// sections; prefer the `onPage` form for a real library.
    public func allTracks(inSection section: String) async throws -> [Track] {
        var out: [Track] = []
        try await allTracks(inSection: section) { out.append(contentsOf: $0) }
        return out
    }

    /// Map one Plex `Metadata` entry. nil only when there is no ratingKey, or no
    /// title AND no filename to derive one from — then there is genuinely nothing
    /// to key or show.
    static func parseTrack(_ d: [String: Any]) -> Track? {
        guard let ratingKey = stringValue(d["ratingKey"]) else { return nil }
        // Plex nests the file two levels down and both levels are arrays; a track
        // with several media versions still has one path per part, so take the first.
        var file: String?
        if let media = d["Media"] as? [[String: Any]], let parts = media.first?["Part"] as? [[String: Any]] {
            file = parts.first?["file"] as? String
        }
        // Plex leaves `title` empty on 184 of this library's 65.719 tracks
        // (measured 2026-08-23): vinyl side-rips ("… - Side A.flac"), 5.1 AC3
        // stems, some box-set discs. Dropping them would make real, playable,
        // analysed files invisible — the exact failure this source exists to fix.
        // The filename always carries a usable name, so fall back to its stem.
        let rawTitle = (d["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let title = rawTitle.isEmpty ? (file.map(Self.titleFromFilename) ?? "") : rawTitle
        guard !title.isEmpty else { return nil }
        return Track(
            ratingKey: ratingKey,
            guid: d["guid"] as? String,
            title: title,
            artist: d["grandparentTitle"] as? String,
            album: d["parentTitle"] as? String,
            albumRatingKey: stringValue(d["parentRatingKey"]),
            // Tracks usually carry no `year` of their own — the album's
            // `parentYear` is what Plex fills in (verified against the live
            // server, 2026-08-23), so fall through to it rather than storing nil.
            year: intValue(d["year"]) ?? intValue(d["parentYear"]),
            filePath: file.map(Self.normalizedPath),
            duration: intValue(d["duration"]),
            thumb: d["thumb"] as? String
        )
    }

    /// Last-resort display title for a track Plex left untitled: the filename
    /// without its directory or extension, with a leading track number stripped
    /// ("06 - Back In Black.flac" → "Back In Black"). Empty when the path yields
    /// nothing usable, which makes the caller reject the row.
    static func titleFromFilename(_ path: String) -> String {
        let stem = (path as NSString).lastPathComponent
        let noExt = (stem as NSString).deletingPathExtension
        // Leading "06 - ", "06-", "06 " — the common rip conventions. Only when
        // something survives it, so a file literally named "07.flac" keeps "07"
        // rather than becoming untitled.
        let stripped = noExt.replacingOccurrences(
            of: #"^\s*\d{1,3}\s*[-._ ]\s*"#, with: "", options: .regularExpression)
        let candidate = stripped.trimmingCharacters(in: .whitespaces)
        return candidate.isEmpty ? noExt.trimmingCharacters(in: .whitespaces) : candidate
    }

    /// Unicode-normalise a path to NFC before it is ever compared or stored.
    ///
    /// This is not cosmetic. APFS hands filenames back decomposed (NFD) while
    /// Plex stores them composed, so a byte-comparison of the two silently misses
    /// every path containing an accent. Measured on the real corpus: 55.700 exact
    /// matches raw, **58.308 after NFC** — 2.608 tracks recovered by this one line.
    public static func normalizedPath(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    // MARK: - Sonic Analysis (Plex Pass)

    /// One sonically-near item as Plex reports it.
    public struct NearestHit: Sendable, Equatable {
        public let ratingKey: String
        /// 0 = the seed itself; larger = further away in Plex's "musical universe".
        public let distance: Double
    }

    /// Sonically nearest items to `ratingKey`, from Plex Pass's Sonic Analysis.
    ///
    /// **Undocumented endpoint.** Plex publishes Sonic Analysis as a Plexamp
    /// feature and does not document `/nearest` as a public API — but it answers
    /// an ordinary token-authenticated request (verified 2026-08-23 against the
    /// live server: HTTP 200, a real distance gradient, and it works on track,
    /// album and artist rating keys). It can break on a Plex update, which is
    /// exactly why every caller goes through this one method and why the caller
    /// keeps a local fallback.
    ///
    /// **Excludes the seed itself** — measured 10/10 on the live server
    /// (2026-08-23). Do not read a `distance` of 0 as "this is the seed": it is a
    /// *different* row that is sonically identical, i.e. another copy of the same
    /// recording. Plex does no duplicate hygiene at all — one seed returned five
    /// further copies of its own recording plus three of another — so run the
    /// hits through `SonicSelection` before showing them.
    ///
    /// Hits come back in ascending distance order.
    public func nearest(ratingKey: String, limit: Int = 30) async throws -> [NearestHit] {
        let json = try await getJSON(path: "/library/metadata/\(ratingKey)/nearest",
                                     query: [URLQueryItem(name: "limit", value: String(limit))])
        guard let hits = Self.parseNearest(json) else {
            throw PlexError.malformedResponse("/nearest: no MediaContainer")
        }
        return hits
    }

    /// Split out from `nearest` so the wire shape is testable without a server.
    /// nil = the response was not a MediaContainer at all (endpoint changed);
    /// an empty array = it answered with no hits.
    static func parseNearest(_ json: [String: Any]) -> [NearestHit]? {
        guard let container = json["MediaContainer"] as? [String: Any] else { return nil }
        let items = (container["Metadata"] as? [[String: Any]]) ?? []
        return items.compactMap { d in
            guard let rk = stringValue(d["ratingKey"]) else { return nil }
            // `distance` is absent on some builds; treat that as "no opinion"
            // (maximally far) rather than dropping an otherwise usable hit.
            return NearestHit(ratingKey: rk, distance: doubleValue(d["distance"]) ?? 1)
        }
    }

    // MARK: - URLs the caller builds

    /// Direct-stream URL for a track part. Plex serves the original file here;
    /// add `?X-Plex-Token=` because media requests are not header-authenticated
    /// by every client stack.
    public func streamURL(partKey: String) -> URL? {
        var comps = URLComponents(url: baseURL.appendingPathComponent(partKey), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
        return comps?.url
    }

    /// Artwork URL for a `thumb` path as returned on a track.
    public func artworkURL(thumb: String) -> URL? {
        var comps = URLComponents(url: baseURL.appendingPathComponent(thumb), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
        return comps?.url
    }

    // MARK: - Transport

    private func getJSON(path: String, query: [URLQueryItem]) async throws -> [String: Any] {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw PlexError.badURL(path)
        }
        comps.queryItems = query
        guard let url = comps.url else { throw PlexError.badURL(path) }

        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw PlexError.transport(error.localizedDescription)
        }
        guard let code = (response as? HTTPURLResponse)?.statusCode else {
            throw PlexError.malformedResponse("no HTTP response for \(path)")
        }
        guard (200..<300).contains(code) else { throw PlexError.http(code) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlexError.malformedResponse("\(path): not a JSON object")
        }
        return json
    }

    // MARK: - Lenient scalars
    //
    // Plex is inconsistent about numeric JSON: `ratingKey` comes back as a string
    // in some versions and a number in others, `year` likewise. Reading them
    // strictly drops real rows, so coerce both shapes.

    static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s.isEmpty ? nil : s }
        if let i = any as? Int { return String(i) }
        return nil
    }

    static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s) }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
