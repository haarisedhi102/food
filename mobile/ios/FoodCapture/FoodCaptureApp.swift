import FoodCore
import SwiftUI

@main
struct FoodCaptureApp: App {
    init() {
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
