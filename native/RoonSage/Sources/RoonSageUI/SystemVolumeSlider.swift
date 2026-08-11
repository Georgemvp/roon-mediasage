import SwiftUI
#if canImport(UIKit)
import MediaPlayer
#endif

/// The **system** volume slider on iOS.
///
/// The screen used to show a slider bound to `LocalPlaybackController.volume`,
/// which is `AVPlayer.volume` — a software attenuation applied on top of the
/// device volume. It made sound quieter, but the hardware buttons and Control
/// Center kept showing something else, so the app and the phone disagreed about
/// how loud things were.
///
/// `MPVolumeView` IS the system volume: hardware buttons, Control Center and this
/// slider are the same value. That's what Music and Plexamp show, and it means
/// the engine no longer needs its own attenuation — `player.volume` is left to
/// carry only the loudness gain.
///
/// The route button is disabled: it's deprecated in favour of
/// `AVRoutePickerView`, which already sits next to the output picker.
///
/// NOTE: renders as an empty view in the Simulator — MPVolumeView only draws
/// against real audio hardware. Verify on a device.
struct SystemVolumeSlider: View {
    var body: some View {
        #if canImport(UIKit)
        VolumeViewRepresentable()
            .frame(height: 28)
            .accessibilityLabel(LS("localNowPlaying.systemVolume"))
        #else
        EmptyView()
        #endif
    }
}

#if canImport(UIKit)
private struct VolumeViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        view.showsRouteButton = false
        view.tintColor = UIColor(Color.roonGold)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
#endif
