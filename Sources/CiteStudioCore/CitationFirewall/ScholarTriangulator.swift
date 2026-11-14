import Foundation
import SQLite3

/// Explicit failure reason when an upstream scholarly lookup could not complete.
public enum ScholarLookupFailureReason: Error, Sendable, Equatable, Codable {
    case offlineOrNetwork(String)
    case timedOut
    case rateLimited
    case upstreamServerError(Int)
    case invalidResponse(String)

    public var summaryEn: String {
        switch self {
        case .offlineOrNetwork(let msg):
            return "network unavailable (\(msg))"
        case .timedOut:
            return "request timed out"
        case .rateLimited:
            return "HTTP 429 rate limited"
        case .upstreamServerError(let status):
            return "upstream HTTP \(status)"
        case .invalidResponse(let detail):
            return "response parse error (\(detail))"
        }
    }

    public var summaryZh: String {
        switch self {
        case .offlineOrNetwork:
            return "网络不可用或连接被拒绝"
        case .timedOut:
            return "请求超时"
        case .rateLimited:
            return "触发 HTTP 429 速率限制"
        case .upstreamServerError(let status):
            return "上游服务返回 HTTP \(status)"
        case .invalidResponse:
            return "上游响应解析失败"
        }
    }
}

/// Three strictly separated verification lookup outcomes (M0 Item 1 / C1 / C16):
/// 1. `.found`: authoritative record retrieved from Crossref or OpenAlex;
/// 2. `.confirmedNotFound`: both Crossref and OpenAlex returned 404 for the DOI, or both Crossref and OpenAlex title searches returned 200 with zero matches;
/// 3. `.lookupFailed`: offline, timeout, 429, 5xx, or parse error — NEVER cached and NEVER classified as GhostPaper.
public enum ScholarLookupOutcome: Sendable, Equatable {
    case found(ScholarRecord)
    case confirmedNotFound
    case lookupFailed(ScholarLookupFailureReason)
}

/// Pluggable lookup transport for scholarly metadata retrieval.
public protocol ScholarLookupTransport: Sendable {
    func lookupOutcome(entry: BibEntry) async -> ScholarLookupOutcome
}

/// Live zero-API-key multi-source public scholarly lookup (Crossref + OpenAlex).
public struct PublicScholarHTTPTransport: ScholarLookupTransport {
    public static let defaultCrossrefBaseURL = URL(string: "https://api.crossref.org")!
    public static let defaultOpenAlexBaseURL = URL(string: "https://api.openalex.org")!
    public static let userAgent = "CiteStudio/0.2.0 (Academic Citation Firewall)"

    public let crossrefBaseURL: URL
    public let openAlexBaseURL: URL
    public let timeoutInterval: TimeInterval
    public let session: URLSession

    public init(
        crossrefBaseURL: URL? = nil,
        openAlexBaseURL: URL? = nil,
        timeoutInterval: TimeInterval? = nil,
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let crossrefBaseURL {
            self.crossrefBaseURL = crossrefBaseURL
        } else if let raw = environment["CITESTUDIO_CROSSREF_BASE_URL"],
                  let parsed = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  parsed.scheme != nil {
            self.crossrefBaseURL = parsed
        } else {
            self.crossrefBaseURL = Self.defaultCrossrefBaseURL
        }

        if let openAlexBaseURL {
            self.openAlexBaseURL = openAlexBaseURL
        } else if let raw = environment["CITESTUDIO_OPENALEX_BASE_URL"],
                  let parsed = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  parsed.scheme != nil {
            self.openAlexBaseURL = parsed
        } else {
            self.openAlexBaseURL = Self.defaultOpenAlexBaseURL
        }

        if let timeoutInterval {
            self.timeoutInterval = timeoutInterval
        } else if let raw = environment["CITESTUDIO_HTTP_TIMEOUT"],
                  let seconds = TimeInterval(raw), seconds > 0 {
            self.timeoutInterval = seconds
        } else {
            self.timeoutInterval = 8.0
        }

        self.session = session
    }

    public func lookupOutcome(entry: BibEntry) async -> ScholarLookupOutcome {
        if let doi = entry.doi, !doi.isEmpty {
            switch await queryCrossrefByDOI(doi) {
            case .failure(let reason):
                return .lookupFailed(reason)
            case .success(.none):
                // Crossref returned HTTP 404 (common for DataCite / arXiv DOIs like 10.48550/...).
                // Consult OpenAlex before concluding confirmedNotFound (C16).
                switch await queryOpenAlexByDOI(doi) {
                case .failure(let reason):
                    return .lookupFailed(reason)
                case .success(.some(let oaRecord)):
                    return .found(oaRecord)
                case .success(.none):
                    // Both Crossref and OpenAlex explicitly returned not-found
                    return .confirmedNotFound
                }
            case .success(.some(let crossrefRecord)):
                if crossrefRecord.isRetracted {
                    return .found(crossrefRecord)
                }
                // Also consult OpenAlex is_retracted for DOI records (C3 / M0 Item 4)
                switch await queryOpenAlexRetractionByDOI(doi) {
                case .success(let oaRetracted):
                    return .found(oaRetracted ? crossrefRecord.withRetracted(true) : crossrefRecord)
                case .failure(let reason):
                    return .lookupFailed(reason)
                }
            }
        }

        let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return .confirmedNotFound
        }

        let oaResult = await queryOpenAlexByTitle(trimmedTitle)
        if case .success(.some(let oaRecord)) = oaResult {
            return .found(oaRecord)
        }

        let crResult = await queryCrossrefByTitle(trimmedTitle)
        if case .success(.some(let crRecord)) = crResult {
            return .found(crRecord)
        }

        switch (oaResult, crResult) {
        case (.success(.none), .success(.none)):
            // Both registries returned HTTP 200 and neither found a title match >= 0.78
            return .confirmedNotFound
        case (.failure(let reason), _):
            return .lookupFailed(reason)
        case (_, .failure(let reason)):
            return .lookupFailed(reason)
        default:
            return .confirmedNotFound
        }
    }

    // MARK: - HTTP Request Helpers

    private func performJSONRequest(_ request: URLRequest) async -> Result<(statusCode: Int, json: [String: Any]?), ScholarLookupFailureReason> {
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .timedOut {
                return .failure(.timedOut)
            }
            return .failure(.offlineOrNetwork(urlError.localizedDescription))
        } catch {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorTimedOut {
                return .failure(.timedOut)
            }
            return .failure(.offlineOrNetwork(error.localizedDescription))
        }

        guard let http = resp as? HTTPURLResponse else {
            return .failure(.invalidResponse("Non-HTTP response"))
        }

        switch http.statusCode {
        case 200:
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any] else {
                return .failure(.invalidResponse("Invalid JSON object"))
            }
            return .success((200, dict))
        case 404:
            return .success((404, nil))
        case 429:
            return .failure(.rateLimited)
        default:
            return .failure(.upstreamServerError(http.statusCode))
        }
    }

    private func makeRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeoutInterval)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    private static func appendPath(_ base: URL, suffix: String) -> URL? {
        var baseStr = base.absoluteString
        while baseStr.hasSuffix("/") { baseStr.removeLast() }
        let cleanSuffix = suffix.hasPrefix("/") ? suffix : "/" + suffix
        return URL(string: baseStr + cleanSuffix)
    }

    private static func encodeDOIForPath(_ doi: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#[]%")
        return doi.addingPercentEncoding(withAllowedCharacters: allowed) ?? doi
    }

    private func queryCrossrefByDOI(_ doi: String) async -> Result<ScholarRecord?, ScholarLookupFailureReason> {
        let encoded = Self.encodeDOIForPath(doi)
        guard let url = Self.appendPath(crossrefBaseURL, suffix: "/works/\(encoded)") else {
            return .failure(.invalidResponse("Invalid Crossref DOI URL"))
        }
        switch await performJSONRequest(makeRequest(url: url)) {
        case .failure(let reason):
            return .failure(reason)
        case .success((404, _)):
            return .success(nil)
        case .success((_, let root)):
            guard let msg = root?["message"] as? [String: Any],
                  let record = Self.parseCrossrefMessage(msg) else {
                return .failure(.invalidResponse("Missing Crossref message payload"))
            }
            return .success(record)
        }
    }

    private func queryOpenAlexByDOI(_ doi: String) async -> Result<ScholarRecord?, ScholarLookupFailureReason> {
        let encoded = Self.encodeDOIForPath(doi)
        guard let url = Self.appendPath(openAlexBaseURL, suffix: "/works/https://doi.org/\(encoded)") else {
            return .failure(.invalidResponse("Invalid OpenAlex DOI URL"))
        }
        switch await performJSONRequest(makeRequest(url: url)) {
        case .failure(let reason):
            return .failure(reason)
        case .success((404, _)):
            return .success(nil)
        case .success((_, let root)):
            guard let root else {
                return .failure(.invalidResponse("Empty OpenAlex payload"))
            }
            if let results = root["results"] as? [[String: Any]] {
                if results.isEmpty {
                    return .success(nil)
                }
                if let first = results.first, let rec = Self.parseOpenAlexWork(first) {
                    return .success(rec)
                }
                return .failure(.invalidResponse("Missing OpenAlex work fields"))
            }
            if let rec = Self.parseOpenAlexWork(root) {
                return .success(rec)
            }
            return .failure(.invalidResponse("Missing OpenAlex work fields"))
        }
    }

    private func queryOpenAlexRetractionByDOI(_ doi: String) async -> Result<Bool, ScholarLookupFailureReason> {
        let encoded = Self.encodeDOIForPath(doi)
        guard let url = Self.appendPath(openAlexBaseURL, suffix: "/works/https://doi.org/\(encoded)") else {
            return .failure(.invalidResponse("Invalid OpenAlex DOI URL"))
        }
        switch await performJSONRequest(makeRequest(url: url)) {
        case .failure(let reason):
            return .failure(reason)
        case .success((404, _)):
            // OpenAlex may not index every Crossref DOI; 404 means no OpenAlex retraction override
            return .success(false)
        case .success((_, let root)):
            guard let root else {
                return .failure(.invalidResponse("Empty OpenAlex payload"))
            }
            if let isRet = root["is_retracted"] as? Bool {
                return .success(isRet)
            }
            if let results = root["results"] as? [[String: Any]],
               let first = results.first,
               let isRet = first["is_retracted"] as? Bool {
                return .success(isRet)
            }
            if root["id"] != nil {
                return .success(false)
            }
            return .failure(.invalidResponse("Missing OpenAlex work fields"))
        }
    }

    private func queryCrossrefByTitle(_ title: String) async -> Result<ScholarRecord?, ScholarLookupFailureReason> {
        guard let worksURL = Self.appendPath(crossrefBaseURL, suffix: "/works"),
              var comps = URLComponents(url: worksURL, resolvingAgainstBaseURL: false) else {
            return .failure(.invalidResponse("Invalid Crossref search URL"))
        }
        comps.queryItems = [
            URLQueryItem(name: "query.bibliographic", value: title),
            URLQueryItem(name: "rows", value: "3")
        ]
        guard let url = comps.url else {
            return .failure(.invalidResponse("Invalid Crossref query components"))
        }

        switch await performJSONRequest(makeRequest(url: url)) {
        case .failure(let reason):
            return .failure(reason)
        case .success((404, _)):
            return .success(nil)
        case .success((_, let root)):
            guard let msg = root?["message"] as? [String: Any],
                  let items = msg["items"] as? [[String: Any]] else {
                return .failure(.invalidResponse("Missing Crossref items array"))
            }
            for item in items {
                if let rec = Self.parseCrossrefMessage(item),
                   ScholarTriangulator.normalizedTitleSimilarity(title, rec.title) >= 0.78 {
                    return .success(rec)
                }
            }
            return .success(nil)
        }
    }

    private func queryOpenAlexByTitle(_ title: String) async -> Result<ScholarRecord?, ScholarLookupFailureReason> {
        guard let worksURL = Self.appendPath(openAlexBaseURL, suffix: "/works"),
              var comps = URLComponents(url: worksURL, resolvingAgainstBaseURL: false) else {
            return .failure(.invalidResponse("Invalid OpenAlex search URL"))
        }
        comps.queryItems = [
            URLQueryItem(name: "search", value: title),
            URLQueryItem(name: "per-page", value: "3")
        ]
        guard let url = comps.url else {
            return .failure(.invalidResponse("Invalid OpenAlex query components"))
        }

        switch await performJSONRequest(makeRequest(url: url)) {
        case .failure(let reason):
            return .failure(reason)
        case .success((404, _)):
            return .success(nil)
        case .success((_, let root)):
            guard let results = root?["results"] as? [[String: Any]] else {
                return .failure(.invalidResponse("Missing OpenAlex results array"))
            }
            for work in results {
                guard let record = Self.parseOpenAlexWork(work),
                      ScholarTriangulator.normalizedTitleSimilarity(title, record.title) >= 0.78 else {
                    continue
                }
                return .success(record)
            }
            return .success(nil)
        }
    }

    public static func parseOpenAlexWork(_ work: [String: Any]) -> ScholarRecord? {
        let rawTitle = (work["title"] as? String) ?? (work["display_name"] as? String)
        guard let rawTitle else { return nil }
        let foundTitle = sanitizeUpstreamText(rawTitle)
        guard !foundTitle.isEmpty else { return nil }

        let year = (work["publication_year"] as? Int) ?? 0
        let isRetracted = ((work["is_retracted"] as? Bool) ?? false) || hasRetractedTitlePrefix(foundTitle)
        let doi = BibTeXParser.normalizeDOI(work["doi"] as? String)

        var authors: [String] = []
        if let auths = work["authorships"] as? [[String: Any]] {
            for a in auths {
                if let authorObj = a["author"] as? [String: Any],
                   let name = authorObj["display_name"] as? String, !name.isEmpty {
                    authors.append(name)
                } else if let rawName = a["raw_author_name"] as? String, !rawName.isEmpty {
                    authors.append(rawName)
                }
            }
        }

        let primarySource = (work["primary_location"] as? [String: Any])?["source"] as? [String: Any]
        let hostVenue = work["host_venue"] as? [String: Any]
        let rawVenueName = (primarySource?["display_name"] as? String) ?? (hostVenue?["display_name"] as? String)
        let sourceType = ((primarySource?["type"] as? String) ?? (hostVenue?["type"] as? String))?.lowercased()

        let venue: String
        let isVenuePeerReviewed: Bool
        if let rawVenueName, !sanitizeUpstreamText(rawVenueName).isEmpty {
            venue = sanitizeUpstreamText(rawVenueName)
            let vLower = venue.lowercased()
            let isPreprintRepo = vLower.contains("arxiv")
                || vLower.contains("biorxiv")
                || vLower.contains("medrxiv")
                || vLower.contains("zenodo")
                || sourceType == "repository"
            isVenuePeerReviewed = !isPreprintRepo
        } else {
            venue = (doi?.hasPrefix("10.48550/arxiv.") == true) ? "arXiv" : "OpenAlex"
            isVenuePeerReviewed = false
        }

        return ScholarRecord(
            source: "OpenAlex",
            title: foundTitle,
            authors: authors,
            year: year,
            venue: venue,
            doi: doi,
            isRetracted: isRetracted,
            publishedUpgradeVenue: isVenuePeerReviewed ? venue : nil,
            publishedUpgradeDOI: isVenuePeerReviewed ? doi : nil,
            publishedUpgradeYear: isVenuePeerReviewed ? year : nil
        )
    }

    public static func parseCrossrefMessage(_ msg: [String: Any]) -> ScholarRecord? {
        let titles = msg["title"] as? [String]
        guard let rawTitle = titles?.first else { return nil }
        let title = sanitizeUpstreamText(rawTitle)
        guard !title.isEmpty else { return nil }

        var authors: [String] = []
        if let rawAuthors = msg["author"] as? [[String: Any]] {
            for a in rawAuthors {
                let given = (a["given"] as? String) ?? ""
                let family = (a["family"] as? String) ?? ""
                let full = "\(given) \(family)".trimmingCharacters(in: .whitespaces)
                if !full.isEmpty { authors.append(full) }
            }
        }

        var year = 0
        for dateKey in ["published-print", "published-online", "issued", "created"] {
            if let obj = msg[dateKey] as? [String: Any],
               let parts = obj["date-parts"] as? [[Int]],
               let firstYear = parts.first?.first {
                year = firstYear
                break
            }
        }

        let containers = msg["container-title"] as? [String]
        let rawVenue = containers?.first ?? ((msg["publisher"] as? String) ?? "Crossref")
        let venue = sanitizeUpstreamText(rawVenue)
        let doi = BibTeXParser.normalizeDOI(msg["DOI"] as? String)

        let updateTo = msg["update-to"] as? [[String: Any]] ?? []
        let updatedBy = msg["updated-by"] as? [[String: Any]] ?? []
        let relation = msg["relation"] as? [String: Any] ?? [:]
        let isRetractedByRelation = ((relation["is-retracted-by"] as? [Any])?.isEmpty == false)

        let hasRetractionNotice = (updateTo + updatedBy).contains { notice in
            let typeStr = ((notice["type"] as? String) ?? "").lowercased()
            let labelStr = ((notice["label"] as? String) ?? "").lowercased()
            return typeStr.contains("retract") || typeStr.contains("withdraw")
                || labelStr.contains("retract") || labelStr.contains("withdraw")
        }
        let isRetracted = hasRetractionNotice || isRetractedByRelation || hasRetractedTitlePrefix(title)

        let peerReviewed = !venue.lowercased().contains("arxiv")
        return ScholarRecord(
            source: "Crossref",
            title: title,
            authors: authors,
            year: year,
            venue: venue,
            doi: doi,
            isRetracted: isRetracted,
            publishedUpgradeVenue: peerReviewed ? venue : nil,
            publishedUpgradeDOI: peerReviewed ? doi : nil,
            publishedUpgradeYear: peerReviewed ? year : nil
        )
    }

    public static func hasRetractedTitlePrefix(_ title: String) -> Bool {
        let lower = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixes = [
            "retracted:",
            "retracted :",
            "[retracted]",
            "retracted article:",
            "retraction notice:",
            "withdrawn:"
        ]
        return prefixes.contains { lower.hasPrefix($0) }
    }

    private static func sanitizeUpstreamText(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Persistent SQLite-cached scholarly verifier with explicit TTL and strict exclusion of transient lookup failures.
public final class ScholarTriangulator: @unchecked Sendable {
    public static let defaultFoundTTL: TimeInterval = 7 * 24 * 3600    // 7 days
    public static let defaultNotFoundTTL: TimeInterval = 24 * 3600    // 24 hours (shorter than found TTL)

    private let cacheDBPath: URL
    private let transport: ScholarLookupTransport
    public let foundTTLSeconds: TimeInterval
    public let notFoundTTLSeconds: TimeInterval
    private let nowProvider: @Sendable () -> Date
    private let lock = NSLock()
    private var db: OpaquePointer?

    public static func resolveCacheDirectory(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        for (idx, arg) in arguments.enumerated() {
            if arg == "--cache-dir", idx + 1 < arguments.count {
                return URL(fileURLWithPath: arguments[idx + 1], isDirectory: true)
            } else if arg.hasPrefix("--cache-dir=") {
                let path = String(arg.dropFirst("--cache-dir=".count))
                if !path.isEmpty {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
        }
        if let envDir = environment["CITESTUDIO_CACHE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envDir.isEmpty {
            return URL(fileURLWithPath: envDir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CiteStudio", isDirectory: true)
    }

    public init(
        cacheDBPath: URL,
        transport: ScholarLookupTransport = PublicScholarHTTPTransport(),
        foundTTLSeconds: TimeInterval = ScholarTriangulator.defaultFoundTTL,
        notFoundTTLSeconds: TimeInterval = ScholarTriangulator.defaultNotFoundTTL,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.cacheDBPath = cacheDBPath
        self.transport = transport
        self.foundTTLSeconds = foundTTLSeconds
        self.notFoundTTLSeconds = notFoundTTLSeconds
        self.nowProvider = nowProvider

        try FileManager.default.createDirectory(
            at: cacheDBPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            cacheDBPath.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "CiteStudio.ScholarCache", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to open citation SQLite cache at \(cacheDBPath.path)"
            ])
        }
        self.db = handle
        sqlite3_exec(
            handle,
            """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS scholar_cache (
                lookup_key TEXT PRIMARY KEY,
                found INTEGER NOT NULL,
                record_json TEXT,
                cached_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL DEFAULT 0
            );
            """,
            nil,
            nil,
            nil
        )
        // Migrate pre-M0 schema lacking expires_at column if needed
        sqlite3_exec(
            handle,
            "ALTER TABLE scholar_cache ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0;",
            nil,
            nil,
            nil
        )
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    public func verifyOutcome(_ entry: BibEntry) async -> ScholarLookupOutcome {
        let key = Self.cacheKey(for: entry)
        if let cachedOutcome = readCache(for: key) {
            return cachedOutcome
        }
        let outcome = await transport.lookupOutcome(entry: entry)
        switch outcome {
        case .found(let record):
            writeCache(for: key, found: true, record: record, ttlSeconds: foundTTLSeconds)
        case .confirmedNotFound:
            writeCache(for: key, found: false, record: nil, ttlSeconds: notFoundTTLSeconds)
        case .lookupFailed:
            // CRITICAL (C1): Never cache transient network/HTTP/parse failures!
            break
        }
        return outcome
    }

    public func verify(_ entry: BibEntry) async -> ScholarRecord? {
        if case .found(let record) = await verifyOutcome(entry) {
            return record
        }
        return nil
    }

    @discardableResult
    public func clearCache() -> Int {
        lock.withLock {
            guard let db else { return 0 }
            guard sqlite3_exec(db, "DELETE FROM scholar_cache;", nil, nil, nil) == SQLITE_OK else {
                return 0
            }
            return Int(sqlite3_changes(db))
        }
    }

    public func rawCacheRowCount() -> Int {
        lock.withLock {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM scholar_cache;", -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    public static func cacheKey(for entry: BibEntry) -> String {
        if let doi = entry.doi, !doi.isEmpty {
            return "doi:\(doi.lowercased())"
        }
        let normTitle = foldForComparison(entry.title)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        return "title:\(normTitle)"
    }

    public static func foldForComparison(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func stripRetractedPrefixForSimilarity(_ title: String) -> String {
        var cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "retracted article:",
            "retraction notice:",
            "retracted :",
            "retracted:",
            "[retracted]",
            "withdrawn:"
        ]
        for prefix in prefixes {
            if cleaned.lowercased().hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return cleaned
    }

    public static func normalizedTitleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let normLHS = foldForComparison(stripRetractedPrefixForSimilarity(lhs))
        let normRHS = foldForComparison(stripRetractedPrefixForSimilarity(rhs))

        let setA = Set(
            normLHS
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 }
        )
        let setB = Set(
            normRHS
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 }
        )
        guard !setA.isEmpty && !setB.isEmpty else { return 0.0 }
        let inter = Double(setA.intersection(setB).count)
        let union = Double(setA.union(setB).count)
        return inter / union
    }

    private func readCache(for key: String) -> ScholarLookupOutcome? {
        lock.withLock {
            guard let db else { return nil }
            let nowEpoch = Int64(nowProvider().timeIntervalSince1970)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT found, record_json, expires_at FROM scholar_cache WHERE lookup_key = ?",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, key, -1, transient)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

            let found = sqlite3_column_int(stmt, 0) == 1
            let expiresAt = sqlite3_column_int64(stmt, 2)

            if expiresAt <= nowEpoch {
                var delStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "DELETE FROM scholar_cache WHERE lookup_key = ?", -1, &delStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(delStmt, 1, key, -1, transient)
                    _ = sqlite3_step(delStmt)
                    sqlite3_finalize(delStmt)
                }
                return nil
            }

            if !found {
                return .confirmedNotFound
            }
            guard let cStr = sqlite3_column_text(stmt, 1) else {
                return nil
            }
            let jsonData = Data(String(cString: cStr).utf8)
            guard let decoded = try? JSONDecoder().decode(ScholarRecord.self, from: jsonData) else {
                return nil
            }
            return .found(decoded)
        }
    }

    private func writeCache(for key: String, found: Bool, record: ScholarRecord?, ttlSeconds: TimeInterval) {
        lock.withLock {
            guard let db else { return }
            let nowEpoch = Int64(nowProvider().timeIntervalSince1970)
            let expiresEpoch = nowEpoch + max(1, Int64(ttlSeconds.rounded()))
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                INSERT OR REPLACE INTO scholar_cache (lookup_key, found, record_json, cached_at, expires_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                -1,
                &stmt,
                nil
            ) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, key, -1, transient)
            sqlite3_bind_int(stmt, 2, found ? 1 : 0)
            if found, let record, let data = try? JSONEncoder().encode(record), let str = String(data: data, encoding: .utf8) {
                sqlite3_bind_text(stmt, 3, str, -1, transient)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_int64(stmt, 4, nowEpoch)
            sqlite3_bind_int64(stmt, 5, expiresEpoch)
            _ = sqlite3_step(stmt)
        }
    }
}
