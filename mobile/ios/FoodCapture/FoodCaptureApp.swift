import FoodCore
import SwiftUI

@main
struct FoodCaptureApp: App {
    init() {
        // Capture stdout/stderr first, so Rig tracing output and every later log land in the
        // exportable file.
        AppLog.start()
        // Rig only exports spans once its subscriber is installed; no call here means the
        // Phoenix UI stays empty no matter how many model calls run.
        Tracing.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
