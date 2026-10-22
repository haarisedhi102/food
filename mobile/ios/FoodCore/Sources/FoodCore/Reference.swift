import Foundation

/// Port of `food/reference.py`: FoodKeeper matching, separated from canonicalization.
///
/// The Python version fuses a **lexical** retriever with a **vector** one by reciprocal rank
/// fusion (LangChain `EnsembleRetriever`, c=60), then one LLM call picks the final row from
/// each shortlist. All three pieces are ported here: the lexical retriever, the vector
/// retriever over `shelf_life_embedding`, and RRF. Without an embeddings key it degrades to
/// lexical-only, exactly like Python.
public enum Reference {
    static let rrfConstant = 60.0

    // MARK: - Lexical

    static func tokens(_ text: String?) -> Set<String> {
        guard let text = text, !text.isEmpty else { return [] }
        var out = Set<String>()
        let normalised = text.lowercased()
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "/", with: " ")
        for chunk in normalised.split(separator: ",") {
            for word in chunk.split(separator: " ") {
                let w = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,()'\""))
                if w.count > 2 { out.insert(w) }
            }
        }
        return out
    }

    static func docText(_ row: [String: SQLValue]) -> String {
        [row["name"]?.stringValue, row["subtitle"]?.stringValue, row["keywords"]?.stringValue]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Positive-overlap lexical shortlist (mirrors `_LexicalRetriever`): no zero-score padding.
    public static func lexicalShortlist(
        _ db: Database, query: String, k: Int = 16
    ) throws -> [[String: SQLValue]] {
        let q = tokens(query)
        if q.isEmpty { return [] }
        var scored: [(score: Int, id: Int, row: [String: SQLValue])] = []
        for row in try db.query("SELECT * FROM shelf_life_ref") {
            let hay = tokens(row["name"]?.stringValue)
                .union(tokens(row["subtitle"]?.stringValue))
                .union(tokens(row["keywords"]?.stringValue))
            let score = q.intersection(hay).count
            if score > 0, let fid = row["foodkeeper_id"]?.intValue {
                scored.append((score, fid, row))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        return scored.prefix(k).map { $0.row }
    }

    // MARK: - Vector

    static func pack(_ vec: [Float]) -> Data {
        vec.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func unpack(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        // Matches Python's `reference._cosine`: a bare dot product over the provider's
        // embeddings, which are expected to be normalized.
        var dot = 0.0
        for i in 0..<a.count { dot += Double(a[i] * b[i]) }
        return dot
    }

    /// `embed_corpus`: embed and store FoodKeeper rows missing an embedding for `model`.
    @discardableResult
    public static func embedCorpus(
        _ db: Database, provider: LLMProvider, model: String, force: Bool = false
    ) async throws -> Int {
        let rows = try db.query("SELECT foodkeeper_id, name, subtitle, keywords FROM shelf_life_ref")
        if rows.isEmpty { return 0 }
        let done = Set(
            try db.query("SELECT foodkeeper_id FROM shelf_life_embedding WHERE model = ?", [.text(model)])
                .compactMap { $0["foodkeeper_id"]?.intValue }
        )
        let todo = rows.filter { force || !done.contains($0["foodkeeper_id"]?.intValue ?? -1) }
        if todo.isEmpty { return 0 }

        let vectors = try await provider.embed(todo.map(docText))
        for (row, vec) in zip(todo, vectors) {
            guard let fid = row["foodkeeper_id"]?.intValue else { continue }
            try db.run(
                """
                INSERT OR REPLACE INTO shelf_life_embedding (foodkeeper_id, model, dim, vector)
                VALUES (?, ?, ?, ?)
                """,
                [.int(Int64(fid)), .text(model), .int(Int64(vec.count)), .blob(pack(vec))]
            )
        }
        return todo.count
    }

    /// Brute-force cosine over the persisted embeddings (the corpus is small).
    public static func vectorShortlist(
        _ db: Database, query: String, k: Int, provider: LLMProvider, model: String
    ) async throws -> [[String: SQLValue]] {
        let q = try await provider.embed([query]).first ?? []
        guard !q.isEmpty else { return [] }
        let embeddings = try db.query(
            "SELECT foodkeeper_id, vector FROM shelf_life_embedding WHERE model = ?", [.text(model)]
        )
        if embeddings.isEmpty { return [] }
        var scored: [(score: Double, id: Int)] = []
        for row in embeddings {
            guard let fid = row["foodkeeper_id"]?.intValue, case let .blob(blob) = row["vector"] ?? .null else { continue }
            scored.append((cosine(q, unpack(blob)), fid))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        let ids = scored.prefix(k).map { $0.id }
        let byID = try rowsByID(db)
        return ids.compactMap { byID[$0] }
    }

    static func rowsByID(_ db: Database) throws -> [Int: [String: SQLValue]] {
        var out: [Int: [String: SQLValue]] = [:]
        for row in try db.query("SELECT * FROM shelf_life_ref") {
            if let fid = row["foodkeeper_id"]?.intValue { out[fid] = row }
        }
        return out
    }

    // MARK: - Reciprocal rank fusion (LangChain EnsembleRetriever, c=60)

    static func reciprocalRankFusion(
        _ lists: [[Int]], weights: [Double], c: Double = rrfConstant
    ) -> [Int] {
        var scores: [Int: Double] = [:]
        var order: [Int] = []
        for (i, list) in lists.enumerated() {
            let weight = i < weights.count ? weights[i] : 1.0
            for (rank, id) in list.enumerated() {
                if scores[id] == nil { order.append(id) }
                // LangChain's EnsembleRetriever enumerates ranks from 1.
                scores[id, default: 0] += weight * (1.0 / (Double(rank + 1) + c))
            }
        }
        return order.sorted { a, b in
            let sa = scores[a] ?? 0, sb = scores[b] ?? 0
            return sa != sb ? sa > sb : a < b
        }
    }

    /// The hybrid shortlist: lexical + (optional) vector, fused with RRF. `limit` is the
    /// per-retriever depth before fusion (Python passes `limit * 2`).
    public static func hybridShortlist(
        _ db: Database,
        query: String,
        limit: Int,
        provider: LLMProvider? = nil,
        model: String? = nil
    ) async throws -> [[String: SQLValue]] {
        let lexical = try lexicalShortlist(db, query: query, k: limit * 2)
        let lexicalIDs = lexical.compactMap { $0["foodkeeper_id"]?.intValue }

        var vectorIDs: [Int] = []
        if let provider = provider, let model = model {
            let hasEmbeddings = try db.query(
                "SELECT 1 FROM shelf_life_embedding WHERE model = ? LIMIT 1", [.text(model)]
            )
            if !hasEmbeddings.isEmpty {
                let vector = try await vectorShortlist(db, query: query, k: limit * 2, provider: provider, model: model)
                vectorIDs = vector.compactMap { $0["foodkeeper_id"]?.intValue }
            }
        }

        let byID = try rowsByID(db)
        if vectorIDs.isEmpty {
            return lexicalIDs.compactMap { byID[$0] }
        }
        let fused = reciprocalRankFusion([lexicalIDs, vectorIDs], weights: [0.5, 0.5])
        return fused.compactMap { byID[$0] }
    }

    // MARK: - FoodKeeper shortlists

    /// FoodKeeper shortlists for a batch of names, keyed by name. Query embeddings are fetched
    /// in one call, mirroring Python's `_shortlists` / `_query_vectors`.
    public static func shortlists(
        _ db: Database,
        names: [String],
        limit: Int,
        provider: LLMProvider? = nil,
        model: String? = nil
    ) async throws -> [String: [[String: SQLValue]]] {
        var uniq: [String] = []
        for n in names where !n.isEmpty && !uniq.contains(n) { uniq.append(n) }
        if uniq.isEmpty { return [:] }

        let byID = try rowsByID(db)
        let indexed: [(id: Int, tokens: Set<String>)] = try db.query(
            "SELECT foodkeeper_id, name, subtitle, keywords FROM shelf_life_ref"
        ).compactMap { row in
            guard let id = row["foodkeeper_id"]?.intValue else { return nil }
            let hay = tokens(row["name"]?.stringValue)
                .union(tokens(row["subtitle"]?.stringValue))
                .union(tokens(row["keywords"]?.stringValue))
            return (id, hay)
        }

        var queryVectors: [String: [Float]] = [:]
        var storedEmbeddings: [(id: Int, vector: [Float])] = []
        if let provider = provider, let model = model {
            let has = (try? db.query(
                "SELECT 1 FROM shelf_life_embedding WHERE model = ? LIMIT 1", [.text(model)]
            )) ?? []
            if !has.isEmpty {
                if let vectors = try? await provider.embed(uniq) {
                    for (name, vector) in zip(uniq, vectors) { queryVectors[name] = vector }
                }
                storedEmbeddings = ((try? db.query(
                    "SELECT foodkeeper_id, vector FROM shelf_life_embedding WHERE model = ?", [.text(model)]
                )) ?? []).compactMap { row in
                    guard let id = row["foodkeeper_id"]?.intValue,
                          case let .blob(blob) = row["vector"] ?? .null else { return nil }
                    return (id, unpack(blob))
                }
            }
        }

        var candidates: [String: [[String: SQLValue]]] = [:]
        for name in uniq {
            let queryTokens = tokens(name)
            var scored: [(score: Int, id: Int)] = []
            if !queryTokens.isEmpty {
                for row in indexed {
                    let score = queryTokens.intersection(row.tokens).count
                    if score > 0 { scored.append((score, row.id)) }
                }
            }
            scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
            let lexicalIDs = scored.prefix(limit * 2).map { $0.id }

            var vectorIDs: [Int] = []
            if let queryVector = queryVectors[name], !storedEmbeddings.isEmpty {
                vectorIDs = storedEmbeddings
                    .map { ($0.id, cosine(queryVector, $0.vector)) }
                    .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                    .prefix(limit * 2)
                    .map { $0.0 }
            }

            let fused = vectorIDs.isEmpty
                ? lexicalIDs
                : reciprocalRankFusion([lexicalIDs, vectorIDs], weights: [0.5, 0.5])
            candidates[name] = fused.prefix(limit).compactMap { byID[$0] }
        }
        return candidates
    }

    // MARK: - Helpers

    static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
