import Foundation

/// Fetches short editorial extracts from Wikipedia's REST summary endpoint
/// (`/api/rest_v1/page/summary/<title>`) — no auth, returns a plain-text lead
/// paragraph. Best-effort: any failure returns nil so the detail page just omits
/// the section. Tries Dutch first, then English (matches the app's NL-first bias
/// while still finding content for artists/albums without an NL page).
public actor WikipediaClient {
    public static let shared = WikipediaClient()

    public struct Summary: Sendable {
        public let text: String
        public let lang: String
    }

    public func summary(title: String, langs: [String] = ["nl", "en"]) async -> Summary? {
        for lang in langs {
            if let text = await fetch(title: title, lang: lang), !text.isEmpty {
                return Summary(text: text, lang: lang)
            }
        }
        return nil
    }

    private func fetch(title: String, lang: String) async -> String? {
        // Wikipedia expects spaces as underscores; percent-encode the rest of the path.
        let path = title.replacingOccurrences(of: " ", with: "_")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(encoded)")
        else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("RoonSage/2.0 ( https://github.com/georgemvp/roonsage )", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Disambiguation / list pages have no real editorial body.
        if let type = json["type"] as? String, type != "standard" { return nil }
        return (json["extract"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
