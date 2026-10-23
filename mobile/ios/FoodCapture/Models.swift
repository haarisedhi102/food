import Foundation

/// The retailer whose session we are capturing. The login URLs mirror the Python side's
/// `RETAILER_LOGIN_URL`, so the POC lands on the same page the browser backend would.
enum Retailer: String, CaseIterable, Identifiable {
    case kroger
    case costco

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kroger: return "Kroger"
        case .costco: return "Costco"
        }
    }

    /// Land on a page that redirects to login when signed out and shows history when signed in.
    var startURL: URL {
        switch self {
        case .kroger: return URL(string: "https://www.kroger.com/mypurchases")!
        case .costco: return URL(string: "https://www.costco.com/")!
        }
    }

    /// Cookie domains that belong to this retailer.
    var cookieDomains: [String] {
        switch self {
        case .kroger: return ["kroger.com"]
        case .costco: return ["costco.com"]
        }
    }

    /// The token key the Python pipeline expects, and where the site is expected to keep it.
    var tokenKey: String? {
        switch self {
        case .kroger: return nil
        case .costco: return "costco:idToken"
        }
    }

    var tokenStorageKey: String? {
        switch self {
        case .kroger: return nil
        case .costco: return "idToken"
        }
    }
}

/// The captured login session: cookies keyed by domain, plus named tokens (Costco's
/// `idToken`). A diagnostic for the POC — the receipt fetch doesn't depend on it.
struct Session: Codable {
    var cookies: [String: [String: String]] = [:]
    var tokens: [String: String] = [:]
    var userAgent: String?
    var capturedAt: String?
    var pageURL: String?
    var storage: [String: [String: String]] = [:]

    enum CodingKeys: String, CodingKey {
        case cookies, tokens, storage
        case userAgent = "user_agent"
        case capturedAt = "captured_at"
        case pageURL = "page_url"
    }

    var cookieCount: Int { cookies.values.reduce(0) { $0 + $1.count } }

    /// Fold another capture in, so capturing Kroger then Costco yields one combined file.
    mutating func merge(_ other: Session) {
        for (domain, jar) in other.cookies {
            cookies[domain, default: [:]].merge(jar) { _, new in new }
        }
        tokens.merge(other.tokens) { _, new in new }
        storage.merge(other.storage) { _, new in new }
        if let ua = other.userAgent { userAgent = ua }
        if let url = other.pageURL { pageURL = url }
        if let at = other.capturedAt { capturedAt = at }
    }

    static func load(from url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

func normalizeDomain(_ domain: String) -> String {
    domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
}

/// A JWT is three base64url segments joined by dots; used to sniff out a token whose
/// storage key we didn't predict.
func looksLikeJWT(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 3 && value.count > 40 && parts.allSatisfy { $0.allSatisfy { c in
        c.isLetter || c.isNumber || c == "-" || c == "_"
    } }
}
