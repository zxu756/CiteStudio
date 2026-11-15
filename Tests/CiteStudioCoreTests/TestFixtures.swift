// 合成测试响应说明（Synthetic handwritten unit-test JSON fixtures / 手写最小单元测试响应 — 不算 C5 的证据）：
// NOTE: The JSON payloads in this file are synthetic handwritten minimal unit-test JSON fixtures
// (合成 · 手写最小单元测试响应) used solely for isolated unit tests in Tests/CiteStudioCoreTests/, and do NOT count as C5 evidence.
// M0/M1 real-response acceptance and README command replay use verbatim upstream responses in Tests/Fixtures/recorded/.

import AppKit
import CoreGraphics
import Darwin
import Foundation
@testable import CiteStudioCore

/// Deterministic in-memory transport living strictly inside `Tests/` (General Rule 2).
struct FixtureScholarTransport: ScholarLookupTransport {
    let recordsByKey: [String: ScholarRecord]

    init(recordsByKey: [String: ScholarRecord]) {
        self.recordsByKey = recordsByKey
    }

    func lookupOutcome(entry: BibEntry) async -> ScholarLookupOutcome {
        if let record = recordsByKey[entry.citeKey] {
            return .found(record)
        }
        return .confirmedNotFound
    }
}

extension LocalPDFIndexer {
    /// Generates a real vector PDF file on disk strictly for unit testing PDFKit extraction.
    static func writeSyntheticAcademicPDF(to url: URL, pages: [[String]]) throws {
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

/// Real loopback HTTP/1.1 server bound to `127.0.0.1:0` serving handwritten minimal unit-test JSON fixtures
/// (手写最小单元测试响应) so unit tests exercise `PublicScholarHTTPTransport` + `URLSession` deterministically offline.
final class LoopbackScholarServer: @unchecked Sendable {
    enum Mode: Sendable {
        case healthy
        case httpStatus(Int)
        case malformedJSON
        case slowResponse(TimeInterval)
    }

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var isStopped = false
    private var _crossrefMode: Mode = .healthy
    private var _openAlexMode: Mode = .healthy
    private var _recordedPaths: [String] = []

    let port: UInt16

    var crossrefBaseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/crossref")!
    }

    var openAlexBaseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/openalex")!
    }

    var mode: Mode {
        get { lock.withLock { _crossrefMode } }
        set {
            lock.withLock {
                _crossrefMode = newValue
                _openAlexMode = newValue
            }
        }
    }

    var crossrefMode: Mode {
        get { lock.withLock { _crossrefMode } }
        set { lock.withLock { _crossrefMode = newValue } }
    }

    var openAlexMode: Mode {
        get { lock.withLock { _openAlexMode } }
        set { lock.withLock { _openAlexMode = newValue } }
    }

    var recordedPaths: [String] {
        lock.withLock { _recordedPaths }
    }

    func resetRecordedPaths() {
        lock.withLock { _recordedPaths.removeAll() }
    }

    init(initialMode: Mode = .healthy) throws {
        self._crossrefMode = initialMode
        self._openAlexMode = initialMode
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "LoopbackScholarServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "LoopbackScholarServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind() failed"])
        }
        guard Darwin.listen(fd, 64) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "LoopbackScholarServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "listen() failed"])
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLen)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
    }

    deinit {
        stop()
    }

    func stop() {
        let fdToClose: Int32 = lock.withLock {
            if isStopped { return -1 }
            isStopped = true
            let current = listenFD
            listenFD = -1
            return current
        }
        if fdToClose >= 0 {
            Darwin.shutdown(fdToClose, SHUT_RDWR)
            Darwin.close(fdToClose)
        }
    }

    private func acceptLoop() {
        while true {
            let currentFD = lock.withLock { isStopped ? -1 : listenFD }
            if currentFD < 0 { break }
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(currentFD, $0, &clientLen)
                }
            }
            if clientFD < 0 {
                if lock.withLock({ isStopped }) { break }
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = Darwin.read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else { return }
        let reqString = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
        let firstLine = reqString.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let rawTarget = String(parts[1])

        let activeMode: Mode = lock.withLock {
            _recordedPaths.append(rawTarget)
            if rawTarget.lowercased().hasPrefix("/openalex") {
                return _openAlexMode
            }
            return _crossrefMode
        }

        switch activeMode {
        case .slowResponse(let delay):
            Thread.sleep(forTimeInterval: delay)
            writeHTTPResponse(fd: fd, status: 200, statusText: "OK", body: #"{"status":"ok"}"#)
        case .httpStatus(let code):
            writeHTTPResponse(fd: fd, status: code, statusText: "Error", body: #"{"error":"upstream failure"}"#)
        case .malformedJSON:
            writeHTTPResponse(fd: fd, status: 200, statusText: "OK", body: #"{"status":"ok","message":truncated"#)
        case .healthy:
            let (status, body) = Self.routeHealthyRequest(rawTarget)
            let statusText = (status == 200) ? "OK" : "Not Found"
            writeHTTPResponse(fd: fd, status: status, statusText: statusText, body: body)
        }
    }

    private func writeHTTPResponse(fd: Int32, status: Int, statusText: String, body: String) {
        let bodyBytes = Array(body.utf8)
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\n\r\n"
        let full = Array(header.utf8) + bodyBytes
        full.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            while sent < full.count {
                let n = Darwin.write(fd, base.advanced(by: sent), full.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    // MARK: - Handwritten Minimal Unit-Test Crossref & OpenAlex JSON Fixtures (手写最小单元测试响应)

    private static func routeHealthyRequest(_ rawTarget: String) -> (Int, String) {
        let comps = URLComponents(string: "http://127.0.0.1" + rawTarget)
        let path = (comps?.percentEncodedPath.removingPercentEncoding ?? comps?.path ?? rawTarget)
        let queryItems = comps?.queryItems ?? []

        if path.hasPrefix("/crossref/works/") {
            let doi = String(path.dropFirst("/crossref/works/".count)).lowercased()
            if let json = crossrefByDOI[doi] {
                return (200, json)
            }
            return (404, #"{"status":"failed","message-type":"route-not-found","message":"Resource not found."}"#)
        }

        if path == "/crossref/works" {
            let q = (queryItems.first(where: { $0.name == "query.bibliographic" })?.value ?? "").lowercased()
            if q.contains("art of computer programming") {
                return (200, crossrefTitleSearchKnuthReview)
            }
            if q.contains("flashattention") {
                return (200, crossrefTitleSearchEmpty)
            }
            return (200, crossrefTitleSearchEmpty)
        }

        if path.hasPrefix("/openalex/works/") {
            var doi = String(path.dropFirst("/openalex/works/".count)).lowercased()
            if doi.hasPrefix("https://doi.org/") {
                doi = String(doi.dropFirst("https://doi.org/".count))
            } else if doi.hasPrefix("https:/doi.org/") {
                doi = String(doi.dropFirst("https:/doi.org/".count))
            }
            if let json = openAlexByDOI[doi] {
                return (200, json)
            }
            return (404, #"{"error":"Work not found"}"#)
        }

        if path == "/openalex/works" {
            let q = (queryItems.first(where: { $0.name == "search" })?.value ?? "").lowercased()
            if q.contains("art of computer programming") {
                return (200, openAlexTitleSearchKnuth1969Review)
            }
            if q.contains("flashattention") {
                return (200, openAlexTitleSearchFlashAttention)
            }
            return (200, #"{"meta":{"count":0},"results":[]}"#)
        }

        return (404, #"{"error":"Not found"}"#)
    }

    private static let crossrefByDOI: [String: String] = [
        "10.1038/nature14539": #"""
        {
          "status": "ok",
          "message-type": "work",
          "message": {
            "DOI": "10.1038/nature14539",
            "title": ["Deep learning"],
            "author": [
              {"given": "Yann", "family": "LeCun"},
              {"given": "Yoshua", "family": "Bengio"},
              {"given": "Geoffrey", "family": "Hinton"}
            ],
            "container-title": ["Nature"],
            "published-print": {"date-parts": [[2015, 5, 28]]}
          }
        }
        """#,
        "10.1162/neco.1997.9.8.1735": #"""
        {
          "status": "ok",
          "message-type": "work",
          "message": {
            "DOI": "10.1162/neco.1997.9.8.1735",
            "title": ["Long Short-Term Memory"],
            "author": [
              {"given": "Sepp", "family": "Hochreiter"},
              {"given": "Jürgen", "family": "Schmidhuber"}
            ],
            "container-title": ["Neural Computation"],
            "published-print": {"date-parts": [[1997, 11, 15]]}
          }
        }
        """#,
        "10.1038/171737a0": #"""
        {
          "status": "ok",
          "message-type": "work",
          "message": {
            "DOI": "10.1038/171737a0",
            "title": ["Molecular Structure of Nucleic Acids: A Structure for Deoxyribose Nucleic Acid"],
            "author": [
              {"given": "J. D.", "family": "Watson"},
              {"given": "F. H. C.", "family": "Crick"}
            ],
            "container-title": ["Nature"],
            "published-print": {"date-parts": [[1953, 4, 25]]}
          }
        }
        """#,
        "10.1016/j.fct.2012.08.005": #"""
        {
          "status": "ok",
          "message-type": "work",
          "message": {
            "DOI": "10.1016/j.fct.2012.08.005",
            "title": ["Long term toxicity of a Roundup herbicide and a Roundup-tolerant genetically modified maize"],
            "author": [
              {"given": "Gilles-Eric", "family": "Séralini"},
              {"given": "Emilie", "family": "Clair"},
              {"given": "Robin", "family": "Mesnage"}
            ],
            "container-title": ["Food and Chemical Toxicology"],
            "published-print": {"date-parts": [[2012, 11]]},
            "update-to": [
              {
                "updated": {"date-parts": [[2014, 1, 1]]},
                "DOI": "10.1016/j.fct.2013.11.047",
                "type": "retraction",
                "label": "Retraction"
              }
            ]
          }
        }
        """#,
        "10.1016/s0140-6736(97)11096-0": #"""
        {
          "status": "ok",
          "message-type": "work",
          "message": {
            "DOI": "10.1016/s0140-6736(97)11096-0",
            "title": ["RETRACTED: Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children"],
            "author": [
              {"given": "A J", "family": "Wakefield"},
              {"given": "S H", "family": "Murch"}
            ],
            "container-title": ["The Lancet"],
            "published-print": {"date-parts": [[1998, 2, 28]]},
            "updated-by": [
              {
                "updated": {"date-parts": [[2010, 2, 2]]},
                "DOI": "10.1016/S0140-6736(10)60175-4",
                "type": "retraction",
                "label": "Retraction"
              }
            ]
          }
        }
        """#,
        "10.9999/test.updatedby.only": #"""
        {
          "status": "ok",
          "message-type": "work",
          "message": {
            "DOI": "10.9999/test.updatedby.only",
            "title": ["Clinical Trial With Updated-By Notice Only"],
            "author": [{"given": "Jane", "family": "Doe"}],
            "container-title": ["Journal of Testing"],
            "published-print": {"date-parts": [[2020, 5, 1]]},
            "updated-by": [
              {"type": "retraction", "DOI": "10.9999/test.retraction.notice"}
            ]
          }
        }
        """#,
        "10.9999/test.openalex.retracted": #"""
        {
          "status": "ok",
          "message-type": "work",
          "message": {
            "DOI": "10.9999/test.openalex.retracted",
            "title": ["Study Retracted Only in OpenAlex"],
            "author": [{"given": "John", "family": "Roe"}],
            "container-title": ["OpenAlex Test Letters"],
            "published-print": {"date-parts": [[2021, 3, 1]]}
          }
        }
        """#
    ]

    private static let openAlexByDOI: [String: String] = [
        "10.1038/nature14539": #"{"id":"https://openalex.org/W2963403868","doi":"https://doi.org/10.1038/nature14539","title":"Deep learning","publication_year":2015,"is_retracted":false}"#,
        "10.1162/neco.1997.9.8.1735": #"{"id":"https://openalex.org/W2100495367","doi":"https://doi.org/10.1162/neco.1997.9.8.1735","title":"Long Short-Term Memory","publication_year":1997,"is_retracted":false}"#,
        "10.1038/171737a0": #"{"id":"https://openalex.org/W2054569362","doi":"https://doi.org/10.1038/171737a0","title":"Molecular Structure of Nucleic Acids: A Structure for Deoxyribose Nucleic Acid","publication_year":1953,"is_retracted":false}"#,
        "10.1016/j.fct.2012.08.005": #"{"id":"https://openalex.org/W2046181874","doi":"https://doi.org/10.1016/j.fct.2012.08.005","title":"Long term toxicity of a Roundup herbicide and a Roundup-tolerant genetically modified maize","publication_year":2012,"is_retracted":true}"#,
        "10.1016/s0140-6736(97)11096-0": #"{"id":"https://openalex.org/W2125826843","doi":"https://doi.org/10.1016/s0140-6736(97)11096-0","title":"RETRACTED: Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children","publication_year":1998,"is_retracted":true}"#,
        "10.9999/test.openalex.retracted": #"{"id":"https://openalex.org/W9999999999","doi":"https://doi.org/10.9999/test.openalex.retracted","title":"Study Retracted Only in OpenAlex","publication_year":2021,"is_retracted":true}"#,
        "10.48550/arxiv.1706.03762": #"""
        {
          "id": "https://openalex.org/W2963403868",
          "doi": "https://doi.org/10.48550/arxiv.1706.03762",
          "title": "Attention Is All You Need",
          "publication_year": 2017,
          "is_retracted": false,
          "authorships": [
            {"author": {"display_name": "Ashish Vaswani"}},
            {"author": {"display_name": "Noam Shazeer"}}
          ],
          "primary_location": {
            "source": {"display_name": "arXiv (Cornell University)", "type": "repository"}
          }
        }
        """#
    ]

    private static let openAlexTitleSearchKnuth1969Review = #"""
    {
      "meta": {"count": 1},
      "results": [
        {
          "id": "https://openalex.org/W2012345678",
          "doi": "https://doi.org/10.2307/1266780",
          "title": "The Art of Computer Programming, Volume 1: Fundamental Algorithms",
          "publication_year": 1969,
          "is_retracted": false,
          "authorships": [
            {"author": {"display_name": "T. A. Jeeves"}}
          ],
          "primary_location": {
            "source": {"display_name": "Technometrics"}
          }
        }
      ]
    }
    """#

    private static let openAlexTitleSearchFlashAttention = #"""
    {
      "meta": {"count": 1},
      "results": [
        {
          "id": "https://openalex.org/W4281482921",
          "doi": "https://doi.org/10.5555/3586589.3587785",
          "title": "FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness",
          "publication_year": 2022,
          "is_retracted": false,
          "authorships": [
            {"author": {"display_name": "Tri Dao"}},
            {"author": {"display_name": "Daniel Y. Fu"}}
          ],
          "primary_location": {
            "source": {"display_name": "Advances in Neural Information Processing Systems"}
          }
        }
      ]
    }
    """#

    private static let crossrefTitleSearchKnuthReview = #"""
    {
      "status": "ok",
      "message": {
        "items": [
          {
            "DOI": "10.2307/1266780",
            "title": ["The Art of Computer Programming, Volume 1: Fundamental Algorithms"],
            "author": [{"given": "T. A.", "family": "Jeeves"}],
            "container-title": ["Technometrics"],
            "published-print": {"date-parts": [[1969, 2]]}
          }
        ]
      }
    }
    """#

    private static let crossrefTitleSearchEmpty = #"""
    {
      "status": "ok",
      "message": {
        "items": []
      }
    }
    """#
}
