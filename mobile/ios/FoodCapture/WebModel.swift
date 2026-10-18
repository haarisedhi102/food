import SwiftUI
import WebKit

/// Owns the in-app browser and the extraction logic.
///
/// This is a real WebKit engine, so the TLS/JA3 fingerprint and the login are genuine —
/// the same reason Google and Meta ship their own in-app browser instead of a bare request.
/// Because it *is* the app's own web view, we can read the two things a plain HTTP client
/// cannot get after the fact: the full cookie jar (including httpOnly) and origin
/// localStorage (Costco's `idToken`).
///
/// And, as the probe proved, Akamai resets the HTTP/2 stream for every headless client on
/// the receipt endpoints while this engine gets 200 — so the fetch happens *here* too.
///
/// Empirically the details endpoint allows only ~2 batches per *page load* before it starts
/// dropping connections (`TypeError: Load failed`), which retries do not recover. So the
/// full history is fetched in chunks, reloading the page between them to re-arm Akamai's
/// sensor, and the chunks are accumulated on the Swift side.
@MainActor
final class WebModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView

    @Published var retailer: Retailer = .kroger
    @Published var progress = "Log in, then tap Fetch."
    @Published var isBusy = false

    /// Where the accumulated session lives between captures (merges Kroger + Costco).
    let sessionURL = FileManager.default.temporaryDirectory.appendingPathComponent("session.json")
    private var navContinuation: CheckedContinuation<Void, Never>?

    private static let receiptTypes: Set<String> = [
        "IN_STORE", "SELF_SERVICE_PICKUP", "DELIVERY", "INSTACART_DELIVERY", "SHIP",
    ]
    /// Receipts per page load. Two batches is the observed per-load limit; one is the safe bet.
    private static let receiptsPerLoad = 10
    private static let attempts = 3

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // persistent store: cookies survive relaunch
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        // Present a full Safari UA so the site doesn't flag the embedded view as insecure.
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }

    func load() { webView.load(URLRequest(url: retailer.startURL)) }
    func reload() { webView.reload() }

    /// The page whose origin we must be on before an in-page fetch will be same-origin.
    var fetchPageURL: URL {
        switch retailer {
        case .kroger: return URL(string: "https://www.kroger.com/mypurchases")!
        case .costco: return URL(string: "https://www.costco.com/myaccount/orders")!
        }
    }

    // MARK: - Session capture

    /// Read cookies + storage out of the live web view into a fresh Session.
    func capture() async -> Session {
        var fresh = Session()
        fresh.capturedAt = ISO8601DateFormatter().string(from: Date())
        fresh.userAgent = await js("navigator.userAgent") as? String
        fresh.pageURL = webView.url?.absoluteString

        for cookie in await allCookies() where matches(cookie.domain) {
            fresh.cookies[normalizeDomain(cookie.domain), default: [:]][cookie.name] = cookie.value
        }

        let storage = await readStorage()
        fresh.storage = storage

        if let key = retailer.tokenStorageKey {
            let candidate = storage["local"]?[key]
                ?? storage["local"]?.first(where: { looksLikeJWT($0.value) })?.value
                ?? storage["session"]?.first(where: { looksLikeJWT($0.value) })?.value
            if let token = candidate, !token.isEmpty, let tokenKey = retailer.tokenKey {
                fresh.tokens[tokenKey] = token
            }
        }
        return fresh
    }

    // MARK: - Ground-truth probe

    /// Run the exact details POST from inside the loaded page, same-origin with the real
    /// session — i.e. what the SPA does. Distinguishes "request is wrong" from "client is
    /// fingerprinted".
    func probeDetails() async -> String {
        let script = """
        const H = {'X-Kroger-Channel':'WEB','Accept':'application/json'};
        const sr = await fetch('https://www.kroger.com/atlas/v1/post-order/v1/purchase-history-search?pageNo=1&pageSize=5',
                               {credentials:'include', headers:H});
        const sj = await sr.json();
        const recs = (((sj.data||{}).postOrderSearch||{}).data)||[];
        const key = (recs.find(r => r.receiptKey)||{}).receiptKey;
        if (!key) return JSON.stringify({search: sr.status, keys: recs.length});
        const p = String(key).split('~');
        const body = JSON.stringify([{divisionNumber:p[0], storeNumber:p[1], transactionDate:p[2],
                                      terminalNumber:p[3], transactionId:p[4]}]);
        const dr = await fetch('https://www.kroger.com/atlas/v1/purchase-history/v2/details',
                               {method:'POST', credentials:'include',
                                headers:{'Content-Type':'application/json','X-Kroger-Channel':'WEB','Accept':'application/json'},
                                body});
        const dt = await dr.text();
        return JSON.stringify({search: sr.status, keys: recs.length, details: dr.status, bodyHead: dt.slice(0,120)});
        """
        return await runScript(script) ?? "probe failed"
    }

    // MARK: - Receipt fetch (inside the browser engine)

    /// Fetch the full raw receipt payload through the web view. The result is byte-compatible
    /// with `food import <file> --retailer kroger|costco`.
    func fetchReceipts() async -> (summary: String, json: String) {
        switch retailer {
        case .kroger: return await fetchKroger()
        case .costco: return await fetchCostco()
        }
    }

    private func fetchKroger() async -> (summary: String, json: String) {
        // 1. page the search once, on a freshly-armed page
        await navigate(to: fetchPageURL)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard let sraw = await runScript(Self.krogerSearchScript),
              let search = decodeJSON(sraw)["search"] as? [[String: Any]] else {
            return ("search failed", "{}")
        }
        let keys = search.compactMap { row -> String? in
            guard let key = row["receiptKey"] as? String,
                  let type = row["purchaseType"] as? String,
                  Self.receiptTypes.contains(type) else { return nil }
            return key
        }

        // 2. itemize in chunks, reloading the page between them to re-arm the sensor
        var details: [String: Any] = [:]
        var ok = 0, errors = 0, retries = 0, loads = 0
        var index = 0
        while index < keys.count {
            let chunk = Array(keys[index ..< min(index + Self.receiptsPerLoad, keys.count)])
            await navigate(to: fetchPageURL)  // fresh page load -> sensor re-validates
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            loads += 1
            if let draw = await runScript(Self.krogerDetailsScript, arguments: ["keys": chunk]),
               let obj = try? JSONSerialization.jsonObject(with: Data(draw.utf8)) as? [String: Any] {
                let counts = (obj["counts"] as? [String: Any]) ?? [:]
                ok += (counts["ok"] as? Int) ?? 0
                errors += (counts["errors"] as? Int) ?? 0
                retries += (counts["retries"] as? Int) ?? 0
                if let d = obj["details"] as? [String: Any] {
                    details.merge(d) { _, new in new }
                }
            } else {
                errors += chunk.count
            }
            index += Self.receiptsPerLoad
        }

        let payload: [String: Any] = ["search": search, "details": details]
        let pjson = encodeJSON(payload) ?? "{}"
        return (
            "search=\(search.count) keys=\(keys.count) loads=\(loads) detailsOk=\(ok) errors=\(errors) retries=\(retries)",
            pjson
        )
    }

    private func fetchCostco() async -> (summary: String, json: String) {
        await navigate(to: fetchPageURL)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard let raw = await runScript(Self.costcoScript),
              let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            return ("costco fetch failed", "{}")
        }
        let counts = (obj["counts"] as? [String: Any]) ?? [:]
        let summary = counts.keys.sorted().map { "\($0)=\(counts[$0] ?? "?")" }.joined(separator: "  ")
        let pjson = encodeJSON(obj["payload"] ?? [:]) ?? "{}"
        return (summary, pjson)
    }

    /// Page the purchase-history search — mirroring `kroger.pull`.
    private static let krogerSearchScript = """
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    const H = {'X-Kroger-Channel':'WEB','Accept':'application/json'};
    const search = [];
    for (let page = 1; page <= 30; page++) {
      let j = null;
      for (let a = 0; a < 3 && j === null; a++) {
        try {
          const r = await fetch(`https://www.kroger.com/atlas/v1/post-order/v1/purchase-history-search?pageNo=${page}&pageSize=50`,
                                {credentials:'include', headers:H});
          j = await r.json();
        } catch (e) { if (a < 2) await sleep(600 * (a + 1)); }
      }
      if (j === null) break;
      const node = ((j.data||{}).postOrderSearch)||{};
      const recs = node.data||[];
      search.push(...recs);
      if (node.isLastPage || recs.length === 0) break;
      await sleep(250);
    }
    return JSON.stringify({search});
    """

    /// Itemize one chunk of receipts; `keys` is injected as an argument by the caller.
    private static let krogerDetailsScript = """
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    const details = {};
    let ok = 0, errors = 0, retries = 0;
    for (let i = 0; i < keys.length; i += 10) {
      const batch = keys.slice(i, i + 10);
      const vars = batch.map(k => { const p = String(k).split('~');
        return {divisionNumber:p[0],storeNumber:p[1],transactionDate:p[2],terminalNumber:p[3],transactionId:p[4]}; });
      let res;
      for (let a = 0; a < 3; a++) {
        try {
          const dr = await fetch('https://www.kroger.com/atlas/v1/purchase-history/v2/details',
            {method:'POST', credentials:'include',
             headers:{'Content-Type':'application/json','X-Kroger-Channel':'WEB','Accept':'application/json'},
             body: JSON.stringify(vars)});
          const text = await dr.text();
          let json = null; try { json = JSON.parse(text); } catch (e) {}
          res = {status: dr.status, ok: dr.ok, json, text};
          if (res.ok || (res.status >= 400 && res.status < 500 && res.status !== 429)) break;
        } catch (e) {
          res = {status: -1, ok: false, json: null, text: String(e)};
        }
        if (a < 2) { retries++; await sleep(1500 * (a + 1)); }
      }
      if (res.ok) ok++; else errors++;
      batch.forEach(k => { details[k] = res; });
      await sleep(300);
    }
    return JSON.stringify({counts:{ok, errors, retries}, details});
    """

    /// Reproduce `costco.pull`'s GraphQL call inside the page.
    private static let costcoScript = """
    try {
      const idToken = localStorage.getItem('idToken');
      if (!idToken) return JSON.stringify({counts:{error:'no idToken in localStorage'}, payload:{}});
      const pad = (n) => String(n);
      const end = new Date();
      const start = new Date(end.getTime() - 90*864e5);
      const fmt = (d) => `${pad(d.getMonth()+1)}/${pad(d.getDate())}/${d.getFullYear()}`;
      const query = `query receiptsWithCounts($startDate: String!, $endDate: String!, $documentType: String!, $documentSubType: String!) {
        receiptsWithCounts(startDate: $startDate, endDate: $endDate, documentType: $documentType, documentSubType: $documentSubType) {
          receipts { transactionBarcode transactionDateTime warehouseName total itemArray { itemNumber itemDescription01 unit amount itemUnitPriceAmount } }
        }
      }`;
      const r = await fetch('https://ecom-api.costco.com/ebusiness/order/v1/orders/graphql', {
        method:'POST', credentials:'include',
        headers:{'Content-Type':'application/json-patch+json','Accept':'*/*',
                 'costco-x-authorization':'Bearer '+idToken,
                 'costco-x-wcs-clientid':'4900eb1f-0c10-4bd9-99c3-c59e6c1ecebf',
                 'client-identifier':'481b1aec-aa3b-454b-b81b-48187e28f205',
                 'costco.env':'ecom','costco.service':'restOrders'},
        body: JSON.stringify({query, variables:{startDate:fmt(start), endDate:fmt(end),
                                                documentType:'warehouse', documentSubType:'all'}})});
      const text = await r.text();
      let json = null; try { json = JSON.parse(text); } catch (e) {}
      const receipts = ((((json||{}).data||{}).receiptsWithCounts||{}).receipts)||[];
      return JSON.stringify({counts:{status: r.status, receipts: receipts.length}, payload: json || {status: r.status, text}});
    } catch (e) {
      return JSON.stringify({counts:{error: String(e)}, payload:{}});
    }
    """

    // MARK: - Script + navigation plumbing

    private func runScript(_ script: String, arguments: [String: Any] = [:]) async -> String? {
        (try? await webView.callAsyncJavaScript(
            script, arguments: arguments, in: nil, contentWorld: .page
        )) as? String
    }

    private func decodeJSON(_ raw: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]
    }

    private func encodeJSON(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func navigate(to url: URL) async {
        await withCheckedContinuation { cont in
            navContinuation = cont
            webView.load(URLRequest(url: url))
        }
    }

    private func finishNavigation() {
        navContinuation?.resume()
        navContinuation = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in finishNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in finishNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in finishNavigation() }
    }

    // MARK: - Helpers

    private func readStorage() async -> [String: [String: String]] {
        let script = """
        (() => {
          const dump = (s) => { const o = {}; try {
            for (let i = 0; i < s.length; i++) { const k = s.key(i); o[k] = s.getItem(k); }
          } catch (e) {} return o; };
          return JSON.stringify({ local: dump(localStorage), session: dump(sessionStorage) });
        })()
        """
        guard let raw = await js(script) as? String,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else { return [:] }
        return obj
    }

    private func matches(_ domain: String) -> Bool {
        let d = domain.lowercased()
        return retailer.cookieDomains.contains { d.hasSuffix($0) }
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
    }

    private func js(_ script: String) async -> Any? {
        try? await webView.evaluateJavaScript(script)
    }
}

/// Hosts the model's single persistent WKWebView inside SwiftUI.
struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
