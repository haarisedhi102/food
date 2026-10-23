import Foundation
import RigPocKit

/// Starts the Rust-side OpenTelemetry exporter that ships Rig's `gen_ai.*` spans to Phoenix.
///
/// The Rust layer reads its endpoint from the process environment, so this sets it before
/// initializing the subscriber. A Debug build defaults to a local Phoenix when nothing is
/// configured (the simulator and the Mac share `127.0.0.1`); release builds stay quiet unless
/// the environment explicitly asks for tracing.
public enum Tracing {
    public static let localEndpoint = "http://127.0.0.1:6006/v1/traces"

    public static func start() {
        let env = ProcessInfo.processInfo.environment
        var endpoint = env["RIG_POC_OTLP_ENDPOINT"] ?? env["OTEL_EXPORTER_OTLP_ENDPOINT"]
        if endpoint?.isEmpty ?? true {
            #if DEBUG
            if env["FOOD_TRACING_DISABLED"] != "1" { endpoint = localEndpoint }
            #endif
        }
        guard let endpoint, !endpoint.isEmpty else { return }

        setenv("RIG_POC_OTLP_ENDPOINT", endpoint, 1)
        if let service = env["OTEL_SERVICE_NAME"], !service.isEmpty {
            setenv("OTEL_SERVICE_NAME", service, 1)
        }
        if let project = env["PHOENIX_PROJECT"], !project.isEmpty {
            setenv("PHOENIX_PROJECT", project, 1)
        }
        initTracing()
        print("[tracing] OTLP -> \(endpoint)")
    }

    public static func shutdown() {
        shutdownTracing()
    }
}
