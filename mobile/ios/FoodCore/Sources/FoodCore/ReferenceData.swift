import Foundation

/// Port of `food sync-ref` / `embed-ref`: fetch USDA FoodKeeper and load it into `shelf_life_ref`,
/// then (optionally) embed the corpus for hybrid retrieval. Without this the reference table is
/// empty and every shelf life falls back to the LLM with no grounding.
///
/// Mirror list mirrors `config.py` (official host first, then byte-identical GitHub mirrors).
public enum ReferenceData {
    static let urls = [
        "https://www.fsis.usda.gov/shared/data/EN/foodkeeper.json",
        "https://raw.githubusercontent.com/jfarrar1/FoodKeeper-API/master/foodkeeper.json",
        "https://raw.githubusercontent.com/iamademar/fusentra/main/data/raw/foodkeeper/foodkeeper.json",
        "https://raw.githubusercontent.com/jaimedmar/fusentra/main/data/raw/foodkeeper/foodkeeper.json",
    ]

    public static func isLoaded(_ db: Database) -> Bool {
        !((try? db.query("SELECT 1 FROM shelf_life_ref LIMIT 1")) ?? []).isEmpty
    }

    public static func fetch(session: URLSession = .shared) async -> Any? {
        for string in urls {
            guard let url = URL(string: string) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                    + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            return object
        }
        return nil
    }

    @discardableResult
    public static func loadIfNeeded(_ db: Database, session: URLSession = .shared) async throws -> Int {
        if isLoaded(db) { return 0 }
        guard let payload = await fetch(session: session) else {
            throw LLMError.notConfigured("could not download the FoodKeeper reference")
        }
        return try FoodKeeper.load(db, payload: payload)
    }

    @discardableResult
    public static func embedIfNeeded(
        _ db: Database, provider: LLMProvider, model: String
    ) async throws -> Int {
        let existing = (try? db.query(
            "SELECT 1 FROM shelf_life_embedding WHERE model = ? LIMIT 1", [.text(model)]
        )) ?? []
        if !existing.isEmpty { return 0 }
        return try await Reference.embedCorpus(db, provider: provider, model: model)
    }
}
