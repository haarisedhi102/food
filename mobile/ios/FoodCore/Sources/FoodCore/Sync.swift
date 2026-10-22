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
        /// Receipt lines still unmapped; the next sync retries them.
        public var pending = 0
    }

    @discardableResult
    public static func run(
        _ db: Database,
        retailer: String,
        payload: Any,
        provider: LLMProvider,
        embedModel: String? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Summary {
        progress?("Reading receipts…")
        let receipts = retailer == "costco"
            ? Normalizer.normalizeCostco(payload)
            : Normalizer.normalizeKroger(payload)
        progress?("Saving \(receipts.count) receipts…")
        let (newR, newI) = try Store.store(db, retailer: retailer, receipts: receipts)
        // classify = canonicalize (which also resolves shelf life for the new food items)
        let stats = try await Canonicalize.canonicalize(
            db, provider: provider, embedModel: embedModel, progress: progress
        )
        // A shelf-life chunk can fail while classification succeeds. Backfill any perishable
        // product still missing an expiry, so those items don't sit at "no expiry" forever.
        let backfill = try await ShelfLifeAgent.resolveMissing(
            db, provider: provider, embedModel: embedModel, progress: progress
        )
        progress?("Building your kitchen…")
        let inv = try Inventory.build(db)
        _ = try Inventory.refreshStatus(db)

        var summary = Summary()
        summary.newReceipts = newR
        summary.newItems = newI
        summary.inventory = inv
        summary.canonicalized = stats
        summary.shelfLife.resolved = stats.resolved + backfill.resolved
        summary.pending = stats.pending
        return summary
    }
}
