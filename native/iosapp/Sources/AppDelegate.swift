import RoonSageCore
import UIKit

/// The one thing a SwiftUI `App` cannot express: the background-URLSession
/// handshake.
///
/// When offline downloads finish while the app is suspended, iOS relaunches the
/// process into the background purely to hand over the results. It calls this
/// method, and if the completion handler is not invoked once the session has
/// replayed everything, the system treats the app as hung and kills it — and
/// the downloads' bookkeeping rows are never written, so the files exist on
/// disk while the app insists nothing was downloaded.
///
/// Nothing else belongs here. The rest of the app's lifecycle runs through
/// `scenePhase` in `RoonSageiOSApp`.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == OfflineDownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        let manager = OfflineDownloadManager.shared
        manager.backgroundCompletionHandler = {
            // UIKit requires the handler on the main thread; the session calls
            // `urlSessionDidFinishEvents` on its own delegate queue.
            DispatchQueue.main.async(execute: completionHandler)
        }
        // Touch the session so it reattaches and starts replaying — without
        // this the delegate callbacks never arrive and the handler never fires.
        manager.reattach()
    }
}
