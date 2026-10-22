import Foundation
import FoodCore

/// A tiny harness for the Swift↔Python comparison. Commands:
///
///   foodcore-cli import <payload.json> --retailer kroger --db <path>
///   foodcore-cli snapshot --db <path>
///   foodcore-cli canonicalize --db <path> [--embed-model m] [--limit n] [--env .env]
///   foodcore-cli sync <payload.json> --retailer kroger --db <path> [--env .env]
///
/// `snapshot` prints the same table dump the Python mirror produces, so the two can be diffed.

struct CLIError: Error, CustomStringConvertible {
    var description: String
}

@main
struct CLI {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ args: [String]) async throws {
        guard let command = args.first else {
            print("usage: foodcore-cli <import|snapshot|canonicalize|sync> …")
            return
        }
        let rest = Array(args.dropFirst())
        let opts = Options(rest)

        switch command {
        case "import":
            let (db, payload) = try openForImport(opts)
            let retailer = try opts.require("retailer")
            let receipts = retailer == "costco"
                ? Normalizer.normalizeCostco(payload)
                : Normalizer.normalizeKroger(payload)
            let (newR, newI) = try Store.store(db, retailer: retailer, receipts: receipts)
            print("imported receipts=\(receipts.count) new=\(newR) items=\(newI)")

        case "snapshot":
            let db = try openDB(opts)
            print(try Snapshot.string(db))

        case "canonicalize":
            let db = try openDB(opts)
            let provider = MacPawProvider(config: providerConfig(opts))
            let stats = try await Canonicalize.canonicalize(
                db, provider: provider, embedModel: embedModel(opts, provider), limit: opts.int("limit")
            )
            print("canonicalized batches=\(stats.batches) ok=\(stats.ok) fallback=\(stats.fallback) "
                + "resolved=\(stats.resolved)")

        case "ping":
            let provider = MacPawProvider(config: providerConfig(opts))
            print("base=\(provider.config.baseURL) models=\(provider.config.models)")
            let reply = try await provider.chatText(system: "You are terse.", user: "Reply with exactly: OK", temperature: 0)
            print("chat -> \(reply.trimmingCharacters(in: .whitespacesAndNewlines))")
            if provider.config.embeddingsConfigured {
                let vector = try await provider.embed(["hello"])
                print("embed -> dim \(vector.first?.count ?? 0)")
            } else {
                print("embed -> (OPENROUTER_API_KEY not set)")
            }

        case "sync":
            let (db, payload) = try openForImport(opts)
            let retailer = try opts.require("retailer")
            let provider = MacPawProvider(config: providerConfig(opts))
            let summary = try await Sync.run(
                db, retailer: retailer, payload: payload, provider: provider,
                embedModel: embedModel(opts, provider)
            )
            print("synced receipts=\(summary.newReceipts) items=\(summary.newItems) "
                + "products=\(summary.canonicalized.ok) shelf=\(summary.shelfLife.resolved) "
                + "inventory=\(summary.inventory)")

        case "resolve":
            let db = try openDB(opts)
            let provider = MacPawProvider(config: providerConfig(opts))
            let stats = try await ShelfLifeAgent.resolveMissing(
                db, provider: provider, limit: opts.int("limit"),
                embedModel: embedModel(opts, provider)
            )
            print("resolved=\(stats.resolved) unresolved=\(stats.unresolved) errors=\(stats.errors)")

        case "chat":
            let db = try openDB(opts)
            let provider = MacPawProvider(config: providerConfig(opts))
            print(try await Chat.ask(db, question: try opts.require("q"), provider: provider))

        case "digest":
            let db = try openDB(opts)
            let provider = MacPawProvider(config: providerConfig(opts))
            if let text = try await Chat.digest(db, days: opts.int("days") ?? 3, provider: provider) {
                print(text)
            } else {
                print("nothing expiring soon")
            }

        case "expiring":
            let db = try openDB(opts)
            for row in try Inventory.expiringSoon(db, days: opts.int("days") ?? 3) {
                let when = row["expires_on"]?.stringValue ?? ""
                let name = row["canonical_name"]?.stringValue ?? ""
                let location = row["location"]?.stringValue ?? ""
                print("\(when)  \(name)  [\(location)]")
            }

        case "item":
            let db = try openDB(opts)
            let id = opts.int("id") ?? 0
            for point in try ItemDetail.pricePoints(db, productID: id) {
                print("\(point["date"] ?? "")  $\(point["price"] ?? 0)")
            }

        default:
            throw CLIError(description: "unknown command: \(command)")
        }
    }

    // MARK: - helpers

    static func openDB(_ opts: Options) throws -> Database {
        let path = try opts.require("db")
        let db = try Database(path: path)
        try Schema.initDB(db)
        return db
    }

    static func openForImport(_ opts: Options) throws -> (Database, Any) {
        let db = try openDB(opts)
        let file = try opts.positional.first ?? opts.require("payload")
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        return (db, try JSONSerialization.jsonObject(with: data))
    }

    static func providerConfig(_ opts: Options) -> ProviderConfig {
        let envFile = opts.value("env").map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: ".env")
        return ProviderConfig.fromEnvironment(envFile: FileManager.default.fileExists(atPath: envFile.path) ? envFile : nil)
    }

    static func embedModel(_ opts: Options, _ provider: MacPawProvider) -> String? {
        if let m = opts.value("embed-model") { return m }
        return provider.config.embeddingsConfigured ? provider.config.embedModel : nil
    }
}

struct Options {
    let flags: [String: String] = [:]
    var positional: [String] = []
    private var map: [String: String] = [:]

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    map[key] = args[i + 1]
                    i += 2
                } else {
                    map[key] = "true"
                    i += 1
                }
            } else {
                positional.append(arg)
                i += 1
            }
        }
    }

    func value(_ key: String) -> String? { map[key] }
    func int(_ key: String) -> Int? { map[key].flatMap { Int($0) } }
    func require(_ key: String) throws -> String {
        guard let v = map[key] else { throw CLIError(description: "missing --\(key)") }
        return v
    }
}
