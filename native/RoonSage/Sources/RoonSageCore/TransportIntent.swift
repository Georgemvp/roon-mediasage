import Foundation

/// A transport change the user just asked for, expressed so it can be applied to
/// the zone list *before* the server confirms it.
///
/// Every transport command sent and then waited. The UI only changed when the
/// next authoritative snapshot arrived, and that is not fast: over ZeroTier while
/// playing it is the round-trip plus a poll, and while **paused** it can be up to
/// fifteen seconds — `PlaybackEventHub` only pushes when the snapshot digest
/// changes, and a paused zone's digest doesn't, so the client falls back to its
/// 15 s safety-net poll. The biggest button on the screen therefore did nothing
/// visible for a second or more, which reads as a dropped tap and invites a
/// second one — on play/pause, a second tap undoes the first.
///
/// This is deliberately a **pure function over the zone list**, not a parallel
/// "pending intent" layer the views have to read through. The snapshot stays the
/// single authority: it overwrites whatever this wrote, on its own schedule, with
/// no reconciliation step to get wrong. All this does is fill the gap until the
/// authority speaks — and `RoonClient` rolls it back if the command fails.
public enum TransportIntent: Equatable, Sendable {
    case togglePlayPause
    case setShuffle(Bool)
    case setLoop(String)
    case setMuted(Bool, outputID: String)
    case setVolume(Int, outputID: String)

    /// `zones` with this intent applied to `zoneID`. Unknown zone → unchanged.
    public func applied(to zones: [Zone], zoneID: String) -> [Zone] {
        guard let idx = zones.firstIndex(where: { $0.id == zoneID }) else { return zones }
        var out = zones
        out[idx] = applied(to: out[idx])
        return out
    }

    func applied(to zone: Zone) -> Zone {
        var z = zone
        switch self {
        case .togglePlayPause:
            // Only from a settled state. `.loading` is Roon mid-transition and
            // `.stopped` has nothing to resume, so guessing there would be a
            // worse lie than the delay this replaces.
            switch zone.state {
            case .playing: z.state = .paused
            case .paused:  z.state = .playing
            case .loading, .stopped: break
            }
        case .setShuffle(let on):
            z.shuffle = on
        case .setLoop(let mode):
            z.loopMode = mode
        case .setMuted(let muted, let outputID):
            z.outputs = zone.outputs.map { out in
                guard out.id == outputID, out.volume != nil else { return out }
                var o = out; o.volume?.isMuted = muted; return o
            }
        case .setVolume(let value, let outputID):
            z.outputs = zone.outputs.map { out in
                guard out.id == outputID, let vol = out.volume else { return out }
                var o = out
                // Clamp to the output's own range: a relative nudge past the end
                // must show the end, not an impossible number the server will
                // immediately contradict.
                o.volume?.value = Swift.min(Swift.max(value, vol.min), vol.max)
                return o
            }
        }
        return z
    }
}
