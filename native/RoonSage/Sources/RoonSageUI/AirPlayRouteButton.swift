import AVKit
import RoonSageCore
import SwiftUI

/// The system AirPlay route picker, wrapped for SwiftUI.
///
/// Placed next to the output picker rather than among the transport controls:
/// AirPlay *is* an output choice, so it belongs where you already go to decide
/// where the sound comes out — and the Now Playing screen was explicitly asked
/// to get quieter, not gain another glyph.
///
/// `AVRoutePickerView` presents the system sheet itself; there is no public API
/// to trigger it programmatically, so the real view has to be on screen. It only
/// affects THIS device's audio session — a Roon zone is routed by Roon, which is
/// why the button hides when a zone is the active output.
struct AirPlayRouteButton: View {
    @Environment(RoonClient.self) private var client

    var body: some View {
        if client.localOutputSelected {
            RoutePicker()
                .frame(width: 34, height: 34)
                .accessibilityLabel(LS("output.airplay"))
                .help(LS("output.airplay"))
        }
    }
}

#if canImport(UIKit)
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .secondaryLabel
        // Gold while a route is actually engaged, matching the rest of the
        // "this control is doing something" language in the app.
        view.activeTintColor = UIColor(Color.roonGold)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#else
private struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        // `activeTintColor` / `prioritizesVideoDevices` are iOS-only; on macOS
        // the picker renders as a plain routing button.
        AVRoutePickerView()
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
