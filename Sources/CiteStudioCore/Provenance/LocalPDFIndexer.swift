import AppKit
import CoreGraphics
import Foundation
import PDFKit
import SQLite3

/// Extracts paragraph text + PDF page `CGRect` coordinates via Apple `PDFKit` and indexes them into SQLite FTS5.
public final class LocalPDFIndexer: @unchecked Sendable {
    private let dbURL: URL
    private let lock = NSLock()
    private var db: OpaquePointer?

    public init(dbURL: URL) throws {
        self.dbURL = dbURL
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            dbURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "CiteStudio.PDFIndex", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to open SQLite FTS5 PDF provenance index"
            ])
        }
        self.db = handle
        sqlite3_exec(
            handle,
            """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS pdf_passages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                cite_key TEXT NOT NULL,
                pdf_filename TEXT NOT NULL,
                page_no INTEGER NOT NULL,
                rect_x REAL NOT NULL,
                rect_y REAL NOT NULL,
                rect_w REAL NOT NULL,
                rect_h REAL NOT NULL,
                passage TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS pdf_passages_fts USING fts5(
                cite_key,
                passage,
                content='pdf_passages',
                content_rowid='id'
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

    @discardableResult
    public func indexPDF(url: URL, citeKey: String) -> Int {
        guard let doc = PDFDocument(url: url) else { return 0 }
        let filename = url.lastPathComponent
        var inserted = 0

        clearPassages(for: citeKey)

        for pageIdx in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIdx),
                  let pageStr = page.string,
                  !pageStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let nsStr = pageStr as NSString
            let rawParagraphs = pageStr.components(separatedBy: "\n\n")
            var searchStart = 0

            for rawPara in rawParagraphs {
                let cleaned = rawPara
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard cleaned.count >= 24 else { continue }

                let probe = String(rawPara.prefix(min(48, rawPara.count)))
                let remaining = NSRange(location: searchStart, length: max(0, nsStr.length - searchStart))
                let foundRange = nsStr.range(of: probe, options: [], range: remaining)

                let rect: CGRect
                if foundRange.location != NSNotFound {
                    let fullLen = min(rawPara.count, nsStr.length - foundRange.location)
                    let paraRange = NSRange(location: foundRange.location, length: max(1, fullLen))
                    if let sel = page.selection(for: paraRange) {
                        rect = sel.bounds(for: page)
                    } else {
                        rect = CGRect(x: 72, y: 420, width: 468, height: 48)
                    }
                    searchStart = min(nsStr.length, foundRange.location + fullLen)
                } else {
                    rect = CGRect(x: 72, y: 420, width: 468, height: 48)
                }

                insertPassage(
                    citeKey: citeKey,
                    pdfFilename: filename,
                    pageNumber: pageIdx + 1,
                    rect: rect,
                    passage: cleaned
                )
                inserted += 1
            }
        }
        return inserted
    }

    public func insertPassage(
        citeKey: String,
        pdfFilename: String,
        pageNumber: Int,
        rect: CGRect,
        passage: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO pdf_passages (cite_key, pdf_filename, page_no, rect_x, rect_y, rect_w, rect_h, passage)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, citeKey, -1, transient)
        sqlite3_bind_text(stmt, 2, pdfFilename, -1, transient)
        sqlite3_bind_int(stmt, 3, Int32(pageNumber))
        sqlite3_bind_double(stmt, 4, Double(rect.origin.x))
        sqlite3_bind_double(stmt, 5, Double(rect.origin.y))
        sqlite3_bind_double(stmt, 6, Double(rect.size.width))
        sqlite3_bind_double(stmt, 7, Double(rect.size.height))
        sqlite3_bind_text(stmt, 8, passage, -1, transient)
        _ = sqlite3_step(stmt)
        let rowId = sqlite3_last_insert_rowid(db)
        sqlite3_finalize(stmt)

        var ftsStmt: OpaquePointer?
        if sqlite3_prepare_v2(
            db,
            "INSERT INTO pdf_passages_fts(rowid, cite_key, passage) VALUES (?, ?, ?)",
            -1,
            &ftsStmt,
            nil
        ) == SQLITE_OK {
            sqlite3_bind_int64(ftsStmt, 1, rowId)
            sqlite3_bind_text(ftsStmt, 2, citeKey, -1, transient)
            sqlite3_bind_text(ftsStmt, 3, passage, -1, transient)
            _ = sqlite3_step(ftsStmt)
            sqlite3_finalize(ftsStmt)
        }
    }

    public func searchBM25(queryTerms: [String], citeKey: String? = nil, limit: Int = 5) -> [PDFPassageEvidence] {
        let sanitized = queryTerms
            .map { $0.components(separatedBy: CharacterSet.alphanumerics.inverted).joined() }
            .filter { $0.count >= 3 }
        guard !sanitized.isEmpty else { return [] }
        let matchExpr = sanitized.joined(separator: " OR ")

        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        let sql: String
        if citeKey != nil {
            sql = """
            SELECT p.cite_key, p.pdf_filename, p.page_no, p.rect_x, p.rect_y, p.rect_w, p.rect_h, p.passage,
                   bm25(pdf_passages_fts) AS rank_score
            FROM pdf_passages_fts
            JOIN pdf_passages p ON p.id = pdf_passages_fts.rowid
            WHERE pdf_passages_fts MATCH ? AND p.cite_key = ?
            ORDER BY rank_score ASC
            LIMIT ?
            """
        } else {
            sql = """
            SELECT p.cite_key, p.pdf_filename, p.page_no, p.rect_x, p.rect_y, p.rect_w, p.rect_h, p.passage,
                   bm25(pdf_passages_fts) AS rank_score
            FROM pdf_passages_fts
            JOIN pdf_passages p ON p.id = pdf_passages_fts.rowid
            WHERE pdf_passages_fts MATCH ?
            ORDER BY rank_score ASC
            LIMIT ?
            """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, matchExpr, -1, transient)
        if let citeKey {
            sqlite3_bind_text(stmt, 2, citeKey, -1, transient)
            sqlite3_bind_int(stmt, 3, Int32(limit))
        } else {
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }

        var out: [PDFPassageEvidence] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ck = String(cString: sqlite3_column_text(stmt, 0))
            let fn = String(cString: sqlite3_column_text(stmt, 1))
            let pg = Int(sqlite3_column_int(stmt, 2))
            let rx = sqlite3_column_double(stmt, 3)
            let ry = sqlite3_column_double(stmt, 4)
            let rw = sqlite3_column_double(stmt, 5)
            let rh = sqlite3_column_double(stmt, 6)
            let text = String(cString: sqlite3_column_text(stmt, 7))
            let rawBM25 = abs(sqlite3_column_double(stmt, 8))
            let confidence = min(0.99, max(0.35, 1.0 - exp(-0.35 * (rawBM25 + 1.0))))

            out.append(
                PDFPassageEvidence(
                    citeKey: ck,
                    pdfFilename: fn,
                    pageNumber: pg,
                    boundingBox: CGRect(x: rx, y: ry, width: rw, height: rh),
                    verbatimSnippet: text,
                    confidenceScore: confidence
                )
            )
        }
        return out
    }

    public func indexedCiteKeys() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT cite_key FROM pdf_passages", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var keys = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                keys.insert(String(cString: c))
            }
        }
        return keys
    }

    private func clearPassages(for citeKey: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var s1: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM pdf_passages WHERE cite_key = ?", -1, &s1, nil) == SQLITE_OK {
            sqlite3_bind_text(s1, 1, citeKey, -1, transient)
            _ = sqlite3_step(s1)
            sqlite3_finalize(s1)
        }
        sqlite3_exec(db, "INSERT INTO pdf_passages_fts(pdf_passages_fts) VALUES('rebuild');", nil, nil, nil)
    }

    /// Generates a real vector PDF file on disk for testing PDFKit paragraph + coordinate extraction.
    public static func writeSyntheticAcademicPDF(to url: URL, pages: [[String]]) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "CiteStudio.PDFSynth", code: 2, userInfo: nil)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.black
        ]
        for paragraphs in pages {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            var cursorY: CGFloat = 700
            for para in paragraphs {
                let rect = CGRect(x: 72, y: cursorY - 64, width: 468, height: 64)
                (para as NSString).draw(in: rect, withAttributes: attrs)
                cursorY -= 96
            }
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
