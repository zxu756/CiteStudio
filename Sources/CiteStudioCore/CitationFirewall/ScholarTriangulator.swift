import Foundation
import SQLite3

/// Pluggable lookup transport so unit tests and offline firewall checks never depend on flaky live APIs.
public protocol ScholarLookupTransport: Sendable {
    func lookup(entry: BibEntry) async throws -> ScholarRecord?
}

/// Live zero-API-key multi-source public scholarly lookup (Crossref + OpenAlex + arXiv).
public struct PublicScholarHTTPTransport: ScholarLookupTransport {
    public init() {}

    public func lookup(entry: BibEntry) async throws -> ScholarRecord? {
        if let doi = entry.doi, !doi.isEmpty {
            if let crossref = try? await queryCrossrefByDOI(doi) {
                return crossref
            }
        }
        if !entry.title.isEmpty {
            if let openAlex = try? await queryOpenAlexByTitle(entry.title) {
                return openAlex
            }
            if let crossrefSearch = try? await queryCrossrefByTitle(entry.title) {
                return crossrefSearch
            }
        }
        return nil
    }

    private func queryCrossrefByDOI(_ doi: String) async throws -> ScholarRecord? {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        guard let url = URL(string: "https://api.crossref.org/works/\(encoded)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("CiteStudio/0.1.0 (Academic Citation Firewall)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = root["message"] as? [String: Any] else { return nil }
        return parseCrossrefMessage(msg)
    }

    private func queryCrossrefByTitle(_ title: String) async throws -> ScholarRecord? {
        var comps = URLComponents(string: "https://api.crossref.org/works")!
        comps.queryItems = [
            URLQueryItem(name: "query.bibliographic", value: title),
            URLQueryItem(name: "rows", value: "3")
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("CiteStudio/0.1.0 (Academic Citation Firewall)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = root["message"] as? [String: Any],
              let items = msg["items"] as? [[String: Any]] else { return nil }

        for item in items {
            if let rec = parseCrossrefMessage(item),
               ScholarTriangulator.normalizedTitleSimilarity(title, rec.title) >= 0.78 {
                return rec
            }
        }
        return nil
    }

    private func queryOpenAlexByTitle(_ title: String) async throws -> ScholarRecord? {
        var comps = URLComponents(string: "https://api.openalex.org/works")!
        comps.queryItems = [
            URLQueryItem(name: "search", value: title),
            URLQueryItem(name: "per-page", value: "3")
        ]
        guard let url = comps.url else { return nil }
        let req = URLRequest(url: url, timeoutInterval: 8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return nil }

        for work in results {
            guard let foundTitle = work["title"] as? String,
                  ScholarTriangulator.normalizedTitleSimilarity(title, foundTitle) >= 0.78 else { continue }
            let year = (work["publication_year"] as? Int) ?? 0
            let isRetracted = (work["is_retracted"] as? Bool) ?? false
            let doiRaw = work["doi"] as? String
            let doi = BibTeXParser.normalizeDOI(doiRaw)

            var authors: [String] = []
            if let auths = work["authorships"] as? [[String: Any]] {
                for a in auths {
                    if let authorObj = a["author"] as? [String: Any],
                       let name = authorObj["display_name"] as? String {
                        authors.append(name)
                    }
                }
            }

            var venue = "OpenAlex Indexed Venue"
            if let loc = work["primary_location"] as? [String: Any],
               let src = loc["source"] as? [String: Any],
               let dname = src["display_name"] as? String {
                venue = dname
            }

            let isVenuePeerReviewed = !venue.lowercased().contains("arxiv")
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
        return nil
    }

    private func parseCrossrefMessage(_ msg: [String: Any]) -> ScholarRecord? {
        let titles = msg["title"] as? [String]
        guard let title = titles?.first, !title.isEmpty else { return nil }

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
        let venue = containers?.first ?? ((msg["publisher"] as? String) ?? "Crossref")
        let doi = BibTeXParser.normalizeDOI(msg["DOI"] as? String)
        let updateTo = msg["update-to"] as? [[String: Any]] ?? []
        let isRetracted = updateTo.contains { (($0["type"] as? String) ?? "").lowercased().contains("retract") }

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
}

/// Persistent SQLite-cached scholarly verifier supporting hermetic or live HTTP transports.
public final class ScholarTriangulator: @unchecked Sendable {
    private let cacheDBPath: URL
    private let transport: ScholarLookupTransport
    private let lock = NSLock()
    private var db: OpaquePointer?

    public init(cacheDBPath: URL, transport: ScholarLookupTransport = PublicScholarHTTPTransport()) throws {
        self.cacheDBPath = cacheDBPath
        self.transport = transport
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
                NSLocalizedDescriptionKey: "Unable to open citation SQLite cache"
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
                cached_at INTEGER NOT NULL
            );
            """,
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

    public func verify(_ entry: BibEntry) async -> ScholarRecord? {
        let key = Self.cacheKey(for: entry)
        if let cached = readCache(for: key) {
            return cached.record
        }
        let fetched = try? await transport.lookup(entry: entry)
        writeCache(for: key, record: fetched)
        return fetched
    }

    public static func cacheKey(for entry: BibEntry) -> String {
        if let doi = entry.doi, !doi.isEmpty {
            return "doi:\(doi.lowercased())"
        }
        let normTitle = entry.title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        return "title:\(normTitle)"
    }

    public static func normalizedTitleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let setA = Set(
            lhs.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 }
        )
        let setB = Set(
            rhs.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 }
        )
        guard !setA.isEmpty && !setB.isEmpty else { return 0.0 }
        let inter = Double(setA.intersection(setB).count)
        let union = Double(setA.union(setB).count)
        return inter / union
    }

    private func readCache(for key: String) -> (hit: Bool, record: ScholarRecord?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT found, record_json FROM scholar_cache WHERE lookup_key = ?",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let found = sqlite3_column_int(stmt, 0) == 1
        if !found { return (true, nil) }
        guard let cStr = sqlite3_column_text(stmt, 1) else { return (true, nil) }
        let jsonData = Data(String(cString: cStr).utf8)
        let decoded = try? JSONDecoder().decode(ScholarRecord.self, from: jsonData)
        return (true, decoded)
    }

    private func writeCache(for key: String, record: ScholarRecord?) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO scholar_cache (lookup_key, found, record_json, cached_at) VALUES (?, ?, ?, ?)",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        sqlite3_bind_int(stmt, 2, record != nil ? 1 : 0)
        if let record, let data = try? JSONEncoder().encode(record), let str = String(data: data, encoding: .utf8) {
            sqlite3_bind_text(stmt, 3, str, -1, transient)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_int64(stmt, 4, Int64(Date().timeIntervalSince1970))
        _ = sqlite3_step(stmt)
    }
}
