import CLAPEngine
import Foundation
import RoonSageCore

/// The CLAP-backed `SonicFitScoring` provider — the server build's half of the
/// sonic-fit re-rank.
///
/// This code used to live in `RoonSageCore/Discovery/DiscoverySonicFit.swift`.
/// It moved here because RoonSageCore is linked by every client app, and a bare
/// mention of `CLAPModel` there pulled the 746 MB CLAPEngine resource bundle
/// into RoonSage.app on macOS *and* iOS — for a re-rank the clients never run.
/// Only the analyser owns a model, so only the analyser registers a provider;
/// on a client `SonicFit.shared.provider` stays nil and the discovery batch
/// keeps its pre-sonic ranking, exactly as it already did when the model was
/// absent.
///
/// An actor because `CLAPModel` wraps CoreML state that this type hands out
/// serially — the re-rank loop calls `cosineToTaste` one candidate at a time.
actor ClapSonicFit: SonicFitScoring {

    private let clap: CLAPModel

    init(clap: CLAPModel) { self.clap = clap }

    func textEmbedding(_ text: String) async -> [Float]? {
        guard clap.canEmbedText else { return nil }
        return try? clap.textEmbedding(text)
    }

    /// Download `previewURL` to a temp `.mp3`, CLAP-embed it, and cosine against
    /// the taste centroid. nil on any download/decode/embed failure (caller then
    /// leaves the score untouched). Mirrors AnalyzerCore's PreviewEmbeddingBackfill:
    /// AVFoundation sniffs by extension, so the temp file MUST end in `.mp3`
    /// (Deezer previews are MP3). The temp file is always cleaned up.
    func cosineToTaste(previewURL: URL, centroid: [Float]) async -> Double? {
        guard let (tmp, _) = try? await URLSession.shared.download(from: previewURL) else { return nil }
        let mp3 = tmp.deletingPathExtension().appendingPathExtension("mp3")
        try? FileManager.default.moveItem(at: tmp, to: mp3)
        defer { try? FileManager.default.removeItem(at: mp3) }
        guard let embedding = try? clap.embed(url: mp3),
              embedding.count == centroid.count, !centroid.isEmpty else { return nil }
        // Both vectors are L2-normalized (CLAP embeddings and the taste centroid),
        // so their dot product IS the cosine similarity.
        var acc: Float = 0
        for i in 0..<embedding.count { acc += embedding[i] * centroid[i] }
        return Double(acc)
    }
}
