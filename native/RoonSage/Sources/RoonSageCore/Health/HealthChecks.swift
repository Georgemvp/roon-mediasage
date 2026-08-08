import Foundation

/// The concrete checks, split so the *decision* is a pure function over values
/// and the *gathering* is a thin wrapper around it. Only the pure half is unit-
/// tested; the gathering half needs a live server and is verified on the mini.
public enum HealthChecks {

    // MARK: - Pure decisions (thresholds live here, and only here)

    /// `library.db` plus the on-disk art cache need room, and the mini shares its
    /// disk with Docker, Plex and rclone caches. Below a gigabyte SQLite starts
    /// failing writes, which surfaces as lost feedback rather than an error.
    public static func diskSpace(freeBytes: Int64) -> HealthResult {
        let gb = Double(freeBytes) / 1_073_741_824
        let text = String(format: "%.1f GB vrij", gb)
        if freeBytes < 1_073_741_824 {
            return .init(checkID: "disk", title: "Schijfruimte", level: .error, message: text,
                         hint: "Maak ruimte vrij — onder 1 GB kan de database schrijffouten geven.")
        }
        if freeBytes < 5 * 1_073_741_824 {
            return .init(checkID: "disk", title: "Schijfruimte", level: .warning, message: text,
                         hint: "Ruim op voordat het krap wordt; de kunstcache groeit tot 200 MB.")
        }
        return .init(checkID: "disk", title: "Schijfruimte", level: .ok, message: text)
    }

    /// A library that stopped syncing looks identical to one that is simply
    /// quiet, until you notice new albums never appear.
    public static func syncAge(lastSync: Date?, now: Date = Date()) -> HealthResult {
        guard let lastSync else {
            return .init(checkID: "sync", title: "Bibliotheeksync", level: .warning,
                         message: "nog nooit gesynchroniseerd",
                         hint: "Start een sync vanuit Instellingen.")
        }
        let days = now.timeIntervalSince(lastSync) / 86_400
        let text = String(format: "laatste sync %.0f dagen geleden", days)
        if days > 30 {
            return .init(checkID: "sync", title: "Bibliotheeksync", level: .error, message: text,
                         hint: "De sync loopt niet meer — controleer de Roon-verbinding.")
        }
        if days > 7 {
            return .init(checkID: "sync", title: "Bibliotheeksync", level: .warning, message: text)
        }
        return .init(checkID: "sync", title: "Bibliotheeksync", level: .ok, message: text)
    }

    /// Audio features only reach the DJ/sonic features through a match on
    /// `match_key`. A collapsed match-rate is the failure mode that produced the
    /// "~41%" episode, and it is invisible without measuring it.
    public static func featureCoverage(features: Int, tracks: Int) -> HealthResult {
        guard tracks > 0 else {
            return .init(checkID: "features", title: "Audiokenmerken", level: .ok,
                         message: "geen bibliotheek geladen")
        }
        let pct = Double(features) / Double(tracks) * 100
        let text = String(format: "%d van %d tracks geanalyseerd (%.0f%%)", features, tracks, pct)
        if pct < 25 {
            return .init(checkID: "features", title: "Audiokenmerken", level: .error, message: text,
                         hint: "Draai ‘Diagnose match-rate’ in Instellingen → Audio analyzer.")
        }
        if pct < 60 {
            return .init(checkID: "features", title: "Audiokenmerken", level: .warning, message: text,
                         hint: "De analyse loopt nog, of de match-rate is gezakt.")
        }
        return .init(checkID: "features", title: "Audiokenmerken", level: .ok, message: text)
    }

    /// A scheduled job that keeps failing is the single most useful thing to
    /// surface: it means a feature silently stopped working.
    public static func scheduledTasks(
        _ tasks: [DatabaseManager.ScheduledTaskRecord]) -> HealthResult {
        let failing = tasks.filter { $0.lastStatus == "failed" }
        guard !failing.isEmpty else {
            return .init(checkID: "tasks", title: "Geplande taken", level: .ok,
                         message: "\(tasks.count) taken, geen fouten")
        }
        let names = failing.map(\.name).sorted().joined(separator: ", ")
        return .init(checkID: "tasks", title: "Geplande taken", level: .error,
                     message: "mislukt: \(names)",
                     hint: failing.compactMap(\.lastError).first)
    }

    /// A client knocking that was never approved simply doesn't work, and the
    /// user has no reason to look in the Apparaten-list unless told.
    public static func pendingDevices(count: Int) -> HealthResult {
        guard count > 0 else {
            return .init(checkID: "devices", title: "Apparaten", level: .ok,
                         message: "geen wachtende apparaten")
        }
        return .init(checkID: "devices", title: "Apparaten", level: .warning,
                     message: "\(count) apparaat(en) wacht op goedkeuring",
                     hint: "Keur ze goed onder Apparaten, anders krijgen ze 401.")
    }

    /// The discovery pipeline already records whether a batch ran degraded
    /// (schema v45); without surfacing it, a producer outage just looks like
    /// "the recommendations got worse".
    public static func discoveryHealth(lastBatchDegraded: Bool?) -> HealthResult {
        switch lastBatchDegraded {
        case .none:
            return .init(checkID: "discovery", title: "Ontdekkingen", level: .ok,
                         message: "nog geen batch gedraaid")
        case .some(true):
            return .init(checkID: "discovery", title: "Ontdekkingen", level: .warning,
                         message: "laatste ronde draaide gedegradeerd",
                         hint: "Een bron gaf niets terug; de volgende ronde probeert het opnieuw.")
        case .some(false):
            return .init(checkID: "discovery", title: "Ontdekkingen", level: .ok,
                         message: "laatste ronde was gezond")
        }
    }

    /// The always-on server must stay attached to Roon; everything else follows
    /// from that.
    public static func roonConnection(isConnected: Bool, coreName: String?) -> HealthResult {
        isConnected
            ? .init(checkID: "roon", title: "Roon", level: .ok,
                    message: "verbonden met \(coreName ?? "Core")")
            : .init(checkID: "roon", title: "Roon", level: .error,
                    message: "niet verbonden",
                    hint: "De server probeert automatisch opnieuw; controleer of de Core draait.")
    }

    // MARK: - Gathering

    /// Free bytes on the volume holding `url`. nil when the volume can't be read.
    public static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
