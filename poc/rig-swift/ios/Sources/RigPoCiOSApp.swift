import SwiftUI
import Foundation

@main
struct RigPoCiOSApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var status = "Not called"
    @State private var busy = false
    @State private var ran = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Rig iOS PoC").font(.title2)
            Text(status).multilineTextAlignment(.center)
            Button(busy ? "Calling…" : "Call Rig") {
                Task { await callRig() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
        }
        .padding()
        .task {
            guard !ran else { return }
            ran = true
            initTracing()
            await callRig()
            if ProcessInfo.processInfo.environment["RIG_EXIT_AFTER_CALL"] == "1" {
                exit(0)
            }
        }
    }

    private func callRig() async {
        busy = true
        defer { busy = false }
        do {
            let otlp = ProcessInfo.processInfo.environment["RIG_POC_OTLP_ENDPOINT"] ?? "nil"
            print("RIG_IOS_OTLP=\(otlp)")
            let reply = try await chat(prompt: "Reply with exactly: rig ios ok")
            status = reply
            print("RIG_IOS_REPLY=\(reply)")
            let decision = try await jevNoul(
                question: "Is this product perishable and typically refrigerated?",
                state: #"{"name":"Whole Milk","category":"Dairy"}"#
            )
            print("RIG_IOS_JEV=\(decision.probability) model=\(decision.model)")
            shutdownTracing()
        } catch {
            shutdownTracing()
            status = "error: \(error.localizedDescription)"
            print("RIG_IOS_ERROR=\(error.localizedDescription)")
        }
    }
}
