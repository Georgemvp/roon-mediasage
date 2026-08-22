import SwiftUI

/// A single line that scrolls itself when it doesn't fit.
///
/// The last open item from `KOEL_AUDIT` (K7). Track titles are routinely longer
/// than a phone is wide — classical especially, where "Symphony No. 9 in D minor,
/// Op. 125: IV. Presto — Allegro assai" truncates to "Symphony No. 9 in D min…"
/// and every movement of the piece looks identical in the queue.
///
/// Three rules it obeys, all of them the reason this isn't just an animation:
///   - It only moves when the text actually overflows. A short title that
///     twitches is worse than a long one that truncates.
///   - It stops entirely under Reduce Motion, falling back to truncation. A
///     permanently animating element is exactly what that setting is for.
///   - It pauses at both ends. Text that slides continuously is unreadable; the
///     pause is where you actually read it.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    /// Seconds the text rests before it starts moving, and again at the far end.
    var dwell: Double = 1.6
    /// Points travelled per second while scrolling.
    var speed: Double = 26

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }
    private var shouldScroll: Bool { !reduceMotion && overflow > 1 }

    var body: some View {
        // A hidden copy carries the LAYOUT: it takes the width it's given and the
        // right height, so the row is exactly as tall as a normal line of this
        // font and nothing around it shifts. The visible copy is drawn over it at
        // its natural width and clipped. Measuring the visible one instead would
        // feed its own truncation back into the measurement.
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: offset)
                    .background(widthReader { textWidth = $0 })
            }
            .background(widthReader { containerWidth = $0 })
            .clipped()
            // Truncation is what a static line needs; a scrolling one is never
            // truncated because it's laid out at its natural width.
            .accessibilityLabel(text)
            .task(id: animationKey) { await run() }
    }

    /// Restart the cycle when the text OR the space available changes — a
    /// rotation can turn an overflowing title into a fitting one.
    private var animationKey: String { "\(text)|\(Int(containerWidth))|\(Int(textWidth))" }

    private func run() async {
        offset = 0
        guard shouldScroll else { return }
        let travel = Double(overflow)
        let duration = max(0.8, travel / speed)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: duration)) { offset = -overflow }
            try? await Task.sleep(nanoseconds: UInt64((duration + dwell) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: duration)) { offset = 0 }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        }
    }

    private func widthReader(_ report: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { geo in
            Color.clear
                .task(id: geo.size.width) { report(geo.size.width) }
        }
    }
}
