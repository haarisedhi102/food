import Foundation

/// Ported from `food/models.py`. Same shapes so the ported normalizers and the SQLite
/// schema line up with the Python pipeline.

/// One retailer line item after the structural adapter has reconciled its shape.
public struct NormalizedItem: Equatable {
    public var rawDescription: String
    public var itemKey: String
    public var rawPkgSize: String?
    public var quantity: Double
    public var unitPriceCents: Int?
    public var lineTotalCents: Int?

    public init(
        rawDescription: String,
        itemKey: String,
        rawPkgSize: String? = nil,
        quantity: Double = 1.0,
        unitPriceCents: Int? = nil,
        lineTotalCents: Int? = nil
    ) {
        self.rawDescription = rawDescription
        self.itemKey = itemKey
        self.rawPkgSize = rawPkgSize
        self.quantity = quantity
        self.unitPriceCents = unitPriceCents
        self.lineTotalCents = lineTotalCents
    }
}

/// A receipt envelope produced by a per-retailer structural adapter.
public struct NormalizedReceipt: Equatable {
    public var externalID: String
    public var purchasedOn: String?
    public var store: String?
    public var totalCents: Int?
    public var items: [NormalizedItem]

    public init(
        externalID: String,
        purchasedOn: String? = nil,
        store: String? = nil,
        totalCents: Int? = nil,
        items: [NormalizedItem] = []
    ) {
        self.externalID = externalID
        self.purchasedOn = purchasedOn
        self.store = store
        self.totalCents = totalCents
        self.items = items
    }
}

/// What the LLM returns per item_key (ported from `CanonicalItem`).
public struct CanonicalItem: Codable, Equatable {
    public var itemKey: String
    public var canonicalName: String
    public var brand: String?
    public var category: String?
    public var pkgSize: String?
    public var unit: String?
    public var isFood: Bool
    public var isPerishable: Bool
    public var storage: String?
    public var shelfLifeDays: Int?
    public var shelfLifeDaysOpened: Int?
    public var confidence: Double

    enum CodingKeys: String, CodingKey {
        case itemKey = "item_key"
        case canonicalName = "canonical_name"
        case brand, category
        case pkgSize = "pkg_size"
        case unit
        case isFood = "is_food"
        case isPerishable = "is_perishable"
        case storage
        case shelfLifeDays = "shelf_life_days"
        case shelfLifeDaysOpened = "shelf_life_days_opened"
        case confidence
    }

    public init(
        itemKey: String,
        canonicalName: String,
        brand: String? = nil,
        category: String? = nil,
        pkgSize: String? = nil,
        unit: String? = nil,
        isFood: Bool = true,
        isPerishable: Bool = false,
        storage: String? = nil,
        shelfLifeDays: Int? = nil,
        shelfLifeDaysOpened: Int? = nil,
        confidence: Double = 0.5
    ) {
        self.itemKey = itemKey
        self.canonicalName = canonicalName
        self.brand = brand
        self.category = category
        self.pkgSize = pkgSize
        self.unit = unit
        self.isFood = isFood
        self.isPerishable = isPerishable
        self.storage = storage
        self.shelfLifeDays = shelfLifeDays
        self.shelfLifeDaysOpened = shelfLifeDaysOpened
        self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemKey = try c.decode(String.self, forKey: .itemKey)
        canonicalName = try c.decode(String.self, forKey: .canonicalName)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        pkgSize = try c.decodeIfPresent(String.self, forKey: .pkgSize)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        isFood = try c.decodeIfPresent(Bool.self, forKey: .isFood) ?? true
        isPerishable = try c.decodeIfPresent(Bool.self, forKey: .isPerishable) ?? false
        storage = try c.decodeIfPresent(String.self, forKey: .storage)
        shelfLifeDays = try c.decodeIfPresent(Int.self, forKey: .shelfLifeDays)
        shelfLifeDaysOpened = try c.decodeIfPresent(Int.self, forKey: .shelfLifeDaysOpened)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.5
    }
}
