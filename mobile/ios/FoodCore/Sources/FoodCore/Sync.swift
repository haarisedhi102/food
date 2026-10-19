import Foundation

/// The core loop in one call: normalize → store → canonicalize → inventory. This is what the
/// app runs after a fetch, and what the CLI harness uses to compare against Python.
public enum Sync {
    public struct Summary: Equatable {
        public var newReceipts = 0
        public var newItems = 0
        public var inventory = 0
        public var canonicalized = Canonicalize.Stats()
        public var shelfLife = ShelfLifeAgent.Stats()
    }

    @discardableResult
    public static func run(
        _ db: Database,
        retailer: String,
        payload: Any,
        provider: LLMProvider,
        embedModel: String? = nil
    ) async throws -> Summary {
        let receipts = retailer == "costco"
            ? Normalizer.normalizeCostco(payload)
            : Normalizer.normalizeKroger(payload)
        let (newR, newI) = try Store.store(db, retailer: retailer, receipts: receipts)
        // classify = canonicalize, then ground any remaining perishable shelf life (as in cli.py)
        let stats = try await Canonicalize.canonicalize(db, provider: provider, embedModel: embedModel)
        let shelf = try await ShelfLifeAgent.resolveMissing(db, provider: provider)
        let inv = try Inventory.build(db)
        _ = try Inventory.refreshStatus(db)

        var summary = Summary()
        summary.newReceipts = newR
        summary.newItems = newI
        summary.inventory = inv
        summary.canonicalized = stats
        summary.shelfLife = shelf
        return summary
    }
}
