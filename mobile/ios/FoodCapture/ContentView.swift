import FoodCore
import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppModel()
    @StateObject private var web = WebModel()

    var body: some View {
        TabView(selection: $app.selectedTab) {
            KitchenView()
                .tabItem { Label("Kitchen", systemImage: "refrigerator") }
                .tag(0)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
        .environmentObject(app)
        .environmentObject(web)
    }
}
