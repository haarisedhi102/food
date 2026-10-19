import FoodCore
import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppModel()
    @StateObject private var web = WebModel()
    // Data-driven hooks so visual checks can open a tab/item without tapping:
    //   FOOD_TAB=0|1 (Fridge|Settings)
    @State private var selection = Int(ProcessInfo.processInfo.environment["FOOD_TAB"] ?? "0") ?? 0

    var body: some View {
        TabView(selection: $selection) {
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
