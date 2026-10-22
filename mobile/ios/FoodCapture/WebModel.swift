import FoodCore
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

    /// Fetch the raw receipt payload through the web view. The result is byte-compatible with
    /// `food import <file> --retailer kroger|costco`.
    ///
    /// Repeat syncs are incremental. `knownKeys` are the receipts already in the database, so
    /// Kroger skips itemizing them; `since` (the newest stored purchase date, YYYY-MM-DD)
    /// narrows Costco's date-range query. An empty watermark is the first sync and keeps the
    /// old full-window behaviour.
    ///
    /// Kroger still pages the full search list: it is small, and stopping early would assume
    /// the results are strictly newest-first — a late-posted receipt could then be skipped.
    /// Python's `kroger.pull` pages fully and filters by `skip_keys` the same way.
    func fetchReceipts(
        knownKeys: Set<String> = [], since: String? = nil
    ) async -> (summary: String, json: String, ok: Bool) {
        switch retailer {
        case .kroger: return await fetchKroger(knownKeys: knownKeys)
        case .costco: return await fetchCostco(since: since)
        }
    }

    private func fetchKroger(knownKeys: Set<String>) async -> (summary: String, json: String, ok: Bool) {
        // 1. page the search once, on a freshly-armed page
        await navigate(to: fetchPageURL)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard let sraw = await runScript(Self.krogerSearchScript),
              let search = decodeJSON(sraw)["search"] as? [[String: Any]] else {
            return ("search failed", "{}", false)
        }
        let groceryKeys = search.compactMap { row -> String? in
            guard let key = row["receiptKey"] as? String,
                  let type = row["purchaseType"] as? String,
                  Self.receiptTypes.contains(type) else { return nil }
            return key
        }
        let keys = groceryKeys.filter { !knownKeys.contains($0) }

        // Nothing new: skip the details calls (and their page reloads) entirely.
        if keys.isEmpty {
            let payload: [String: Any] = ["search": search, "details": [String: Any]()]
            let summary = "search=\(search.count) keys=\(groceryKeys.count) new=0 (up to date)"
            return (summary, encodeJSON(payload) ?? "{}", true)
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
            "search=\(search.count) keys=\(groceryKeys.count) new=\(keys.count) "
                + "loads=\(loads) detailsOk=\(ok) errors=\(errors) retries=\(retries)",
            pjson,
            true
        )
    }

    private func fetchCostco(since: String?) async -> (summary: String, json: String, ok: Bool) {
        // A Costco idToken lives ~12 minutes; the orders-page SPA mints a new one from its
        // refresh token on load. Reload and retry if the token is stale or the API 401s.
        var lastSummary = "costco fetch failed"
        var lastPayload = "{}"
        for attempt in 1...2 {
            await navigate(to: fetchPageURL)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            // The script polls for a *valid* (non-expired) idToken, not just a present one.
            guard let raw = await runScript(
                Self.costcoScript, arguments: ["since": since ?? ""], timeout: .seconds(60)
            ),
                  let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                print("[fetch] costco attempt \(attempt) failed")
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            let counts = (obj["counts"] as? [String: Any]) ?? [:]
            let summary = counts.keys.sorted()
                .map { "\($0)=\(counts[$0] ?? "?")" }.joined(separator: "  ")
            let pjson = encodeJSON(obj["payload"] ?? [:]) ?? "{}"
            lastSummary = summary
            lastPayload = pjson
            let status = (counts["status"] as? Int) ?? 0
            let error = counts["error"] as? String
            if status == 200 && error == nil {
                return (summary, pjson, true)
            }
            if status == 401 || error != nil {
                print("[fetch] costco session expired (attempt \(attempt)); reloading")
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            // 403/429/other: retrying would make a WAF block worse.
            return (summary, pjson, false)
        }
        return (lastSummary, lastPayload, false)
    }

    /// Page the purchase-history search — mirroring `kroger.pull`. Pages fully; the caller
    /// filters out receipts it already has before itemizing.
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
      const sleep = (ms) => new Promise(r => setTimeout(r, ms));
      const valid = (t) => {
        if (!t) return false;
        try {
          const p = t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
          const c = JSON.parse(atob(p));
          return !c.exp || c.exp * 1000 > Date.now();
        } catch (e) { return false; }
      };
      // The orders-page SPA refreshes the short-lived token after hydration. Poll for a
      // *valid* one; a present but expired token would make the GraphQL call 401.
      let idToken = null;
      for (let i = 0; i < 60; i++) {
        const t = localStorage.getItem('idToken');
        if (valid(t)) { idToken = t; break; }
        await sleep(500);
      }
      if (!idToken) return JSON.stringify({counts:{error:'no valid idToken in localStorage'}, payload:{}});
      const pad = (n) => String(n);
      const end = new Date();
      const floor = new Date(end.getTime() - 90*864e5);
      // Incremental: start from the newest stored receipt, with a 2-day overlap so a receipt
      // that posts late still gets picked up. The first sync uses the full 90-day window.
      let start = floor;
      if (since) {
        const s = new Date(since + 'T00:00:00');
        if (!isNaN(s.getTime())) {
          const overlap = new Date(s.getTime() - 2*864e5);
          if (overlap > floor) start = overlap;
        }
      }
      if (start > end) start = end;
      const fmt = (d) => `${pad(d.getMonth()+1)}/${pad(d.getDate())}/${d.getFullYear()}`;
      const query = `\(SharedContract.costcoQuery)`;
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 25000);
      const r = await fetch('https://ecom-api.costco.com/ebusiness/order/v1/orders/graphql', {
        method:'POST', credentials:'include', signal: ctrl.signal,
        headers:{'Content-Type':'application/json-patch+json','Accept':'*/*',
                 'costco-x-authorization':'Bearer '+idToken,
                 'costco-x-wcs-clientid':'4900eb1f-0c10-4bd9-99c3-c59e6c1ecebf',
                 'client-identifier':'481b1aec-aa3b-454b-b81b-48187e28f205',
                 'costco.env':'ecom','costco.service':'restOrders'},
        body: JSON.stringify({query, variables:{startDate:fmt(start), endDate:fmt(end),
                                                documentType:'warehouse', documentSubType:'all'}})});
      clearTimeout(timer);
      const text = await r.text();
      let json = null; try { json = JSON.parse(text); } catch (e) {}
      const receipts = ((((json||{}).data||{}).receiptsWithCounts||{}).receipts)||[];
      return JSON.stringify({counts:{status: r.status, receipts: receipts.length, since: fmt(start)}, payload: json || {status: r.status, text}});
    } catch (e) {
      return JSON.stringify({counts:{error: String(e)}, payload:{}});
    }
    """

    // MARK: - Script + navigation plumbing

    /// Run page JavaScript, but never wait forever: an in-page `fetch` can stall behind
    /// Akamai, and `callAsyncJavaScript` has no timeout of its own.
    private func runScript(
        _ script: String, arguments: [String: Any] = [:], timeout: Duration = .seconds(35)
    ) async -> String? {
        // A task group would wait for the stubborn call to finish too, defeating the
        // deadline; the first of the two paths to claim the continuation wins.
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let value: String?
                do {
                    value = try await webView.callAsyncJavaScript(
                        script, arguments: arguments, in: nil, contentWorld: .page
                    ) as? String
                } catch {
                    print("[web] script failed: \(error)")
                    value = nil
                }
                if await once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if await once.claim() {
                    print("[web] script timed out after \(timeout)")
                    continuation.resume(returning: nil)
                }
            }
        }
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

    /// WebKit's internal `_WKNavigationActionPolicyAllowWithoutTryingAppLink`
    /// (`WKNavigationActionPolicyAllow + 2`). A plain `.allow` still hands an associated
    /// domain to the installed native app, and `.cancel` doesn't prevent that hand-off
    /// either — WebKit tries the universal link before our decision matters. This policy
    /// is the only way to keep `costco.com` inside the web view. The value has been stable
    /// since iOS 9 and is what embedded browsers use.
    private static let allowWithoutAppLink =
        WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2)!

    /// Keep OAuth/login flows inside the web view. Costco (and sometimes Kroger) try to hand
    /// off to their native app two ways: a custom scheme (`costco://…`), and a *universal link*
    /// — a plain `https://…costco.com/…` URL that iOS routes to the installed native app. Both
    /// lose the authenticated session the in-page fetch depends on, so both must stay here.
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // WebKit delivers navigation decisions on the main thread, so the main-actor
        // state this delegate touches is safe to read here.
        MainActor.assumeIsolated {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            let webSchemes: Set<String> = ["http", "https", "about", "data", "blob"]
            guard webSchemes.contains(scheme) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(Self.allowWithoutAppLink)
        }
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

/// Lets the first of several racing tasks claim a continuation exactly once.
private actor Once {
    private var claimed = false
    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Hosts the model's single persistent WKWebView inside SwiftUI.
struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
