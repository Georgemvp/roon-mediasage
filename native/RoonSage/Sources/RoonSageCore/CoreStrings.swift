import Foundation

/// Localisation for the handful of user-facing strings that Core produces.
///
/// Core cannot call `LS`: the string catalogue is a resource of `RoonSageUI`,
/// and Core sits below it. So Core hard-coded Dutch, which the app then showed
/// in the middle of an English UI — "Stop afspelen op this device". Worse, the
/// localisation gate could not see the problem at all, because it only knows
/// about `LS(...)`/`LT(...)` calls in the UI target.
///
/// The fix is an injected translator rather than moving the messages up: the
/// call sites are error paths threaded through Core's own logic, and hoisting
/// them into the UI would mean returning a typed error from sixteen places for
/// no gain over one function pointer.
///
/// **Every call carries its Dutch as a fallback**, so a missed registration
/// degrades to today's behaviour instead of showing raw keys — the exact
/// failure a user screenshot caught on 2026-08-10.
public enum CoreStrings {

    /// Returns nil when the key is unknown, so the fallback wins.
    public typealias Translator = @Sendable (String) -> String?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var translator: Translator?

    /// Called once at launch by the UI layer. Registering twice is allowed
    /// (tests do it); the last one wins.
    public static func register(_ translator: @escaping Translator) {
        lock.lock(); defer { lock.unlock() }
        Self.translator = translator
    }

    /// Test seam — drop back to fallbacks.
    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        translator = nil
    }

    /// A localised string, or `fallback` when nothing is registered or the key
    /// is unknown to the catalogue.
    public static func s(_ key: String, _ fallback: String) -> String {
        lock.lock()
        let t = translator
        lock.unlock()
        guard let value = t?(key), !value.isEmpty, value != key else { return fallback }
        return value
    }

    /// The same, with `String(format:)` arguments. The format string lives in
    /// the catalogue, so a translation can reorder `%1$@`-style placeholders.
    public static func f(_ key: String, _ fallback: String, _ args: any CVarArg...) -> String {
        String(format: s(key, fallback), arguments: args)
    }
}
