import Foundation

/// DuckDuckGo HTML search — the tool the shelf-life agent calls. No API key; a rough
/// title/snippet extractor over the results page (the Python side uses `ddgs`).
public enum WebSearch {
    public static func duckDuckGo(_ query: String, session: URLSession = .shared) async -> String {
        guard var comps = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            return "search failed: bad url"
        }
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        request.httpBody = Data((comps.percentEncodedQuery ?? "").utf8)

        do {
            let (data, _) = try await session.data(for: request)
            let results = parse(String(decoding: data, as: UTF8.self))
            return results.isEmpty ? "no results" : results.joined(separator: "\n\n")
        } catch {
            return "search failed: \(error)"
        }
    }

    static func parse(_ html: String, limit: Int = 5) -> [String] {
        let titles = matches(html, #"result__a[^>]*>(.*?)</a>"#)
        let snippets = matches(html, #"result__snippet[^>]*>(.*?)</a>"#)
        var out: [String] = []
        for i in 0..<min(titles.count, limit) {
            let snippet = i < snippets.count ? "\n\(snippets[i])" : ""
            out.append(stripTags(titles[i]) + snippet)
        }
        return out
    }

    static func matches(_ text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
