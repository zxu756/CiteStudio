// 合成测试样本说明（Synthetic handwritten HTTP response bodies — 不算 C5 的证据）：
// 本文件中的 LoopbackC5TitleCandidateServer 返回为单元测试手写的合成 JSON 响应正文，
// 仅用于隔离回归 C5 候选过滤规则的各个代码分支（年份差 0/1/2、第一作者姓氏归一化、book-review 排除、缓存键隔离），
// 不算 C5 的真实上游证据。C5 的真实回放证据仅限 Tests/Fixtures/recorded/ 中已录制的两个无 DOI 标题查询（Knuth 1968 与 fake_nodoi）。

import Darwin
import Foundation
import Testing
@testable import CiteStudioCore

@Suite("SyntheticC5FirewallTests", .timeLimit(.minutes(1)))
struct SyntheticC5FirewallTests {

    @Test("合成 (Synthetic, 不算 C5 证据) C5: DOI-less title search handwritten candidate filtering for year drift, first-author surname, and book-review rules")
    func syntheticC5HandwrittenCandidateFiltering() async throws {
        // Synthetic handwritten loopback verification of C5 candidate filtering, surname normalization, & SQLite cache isolation
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_c5_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let c5Server = try LoopbackC5TitleCandidateServer()
        defer { c5Server.stop() }
        let transport = PublicScholarHTTPTransport(
            crossrefBaseURL: c5Server.crossrefBaseURL,
            openAlexBaseURL: c5Server.openAlexBaseURL,
            timeoutInterval: 2.0
        )
        let triangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("c5_cache.sqlite"),
            transport: transport
        )

        // (a) Year diff == 0 + matching first author ("Knuth, Donald E." vs "Donald E. Knuth") -> Verified
        //     Note: candidate #1 in OpenAlex is Odeh 1984 (mismatched surname), candidate #2 is Donald E. Knuth 1984 -> must skip #1 and match #2!
        let exactMatch = try #require(BibTeXParser.parseBibTeX("""
        @book{knuth_exact, author = {Knuth, Donald E.}, title = {Structured Literate Programming Systems}, publisher = {Addison-Wesley}, year = {1984}}
        """).first)
        let dExact = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: exactMatch, triangulator: triangulator)
        #expect(dExact.kind == .verified)

        // (b) Year diff == 1 (1983 vs 1984) + matching first author ("Donald E. Knuth" in First M. Last BibTeX format) -> Verified
        let diffOneMatch = try #require(BibTeXParser.parseBibTeX("""
        @book{knuth_diff1, author = {Donald E. Knuth}, title = {Structured Literate Programming Systems}, publisher = {Addison-Wesley}, year = {1983}}
        """).first)
        let dDiff1 = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: diffOneMatch, triangulator: triangulator)
        #expect(dDiff1.kind == .verified)

        // (c) Year diff == 2 (> 1: 1982 vs 1984) + matching first author -> confirmedNotFound (.ghostPaper), NOT MetadataMismatch!
        let diffTwoMiss = try #require(BibTeXParser.parseBibTeX("""
        @book{knuth_diff2, author = {Knuth, Donald E.}, title = {Structured Literate Programming Systems}, publisher = {Addison-Wesley}, year = {1982}}
        """).first)
        let dDiff2 = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: diffTwoMiss, triangulator: triangulator)
        #expect(dDiff2.kind == .ghostPaper)
        #expect(dDiff2.kind != .metadataMismatch)

        // (d) Year diff == 1 + mismatched first-author surname ("Knuth" vs "Odeh" / "MacLaren") -> confirmedNotFound (.ghostPaper), NOT MetadataMismatch!
        let authorMiss = try #require(BibTeXParser.parseBibTeX("""
        @book{taocp_1968, author = {Knuth, Donald E.}, title = {The Art of Computer Programming, Volume 1: Fundamental Algorithms}, publisher = {Addison-Wesley}, year = {1968}}
        """).first)
        let dAuthorMiss = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: authorMiss, triangulator: triangulator)
        #expect(dAuthorMiss.kind == .ghostPaper)
        #expect(dAuthorMiss.kind != .metadataMismatch)

        // (e) SQLite cache isolation on same title: citing Odeh's 1969 article directly on the SAME cache resolves Verified without colliding with Knuth 1968
        let odehDirect = try #require(BibTeXParser.parseBibTeX("""
        @article{odeh_1969, author = {Odeh, Robert E.}, title = {The Art of Computer Programming, Volume 1: Fundamental Algorithms}, journal = {JASA}, year = {1969}}
        """).first)
        let dOdeh = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: odehDirect, triangulator: triangulator)
        #expect(dOdeh.kind == .verified)

        // Re-evaluating Knuth 1968 on the same SQLite cache still returns .ghostPaper (not poisoned by Odeh's cached record)
        let dAuthorMissCached = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: authorMiss, triangulator: triangulator)
        #expect(dAuthorMissCached.kind == .ghostPaper)

        // (f) Surname normalization edge cases: LaTeX diacritics, hyphenated surnames, nobiliary particles, Jr. suffix, substring non-match ("Lee" vs "Greenlee"), and empty-author candidate rejection
        let diacriticEntry = try #require(BibTeXParser.parseBibTeX("""
        @article{garcia2019, author = {Garc{\\'i}a-Molina, H{\\'e}ctor}, title = {Distributed Transaction Coordination Protocols}, journal = {ACM TODS}, year = {2019}}
        """).first)
        #expect(await CitationDiagnosticsEngine.evaluateSingleEntry(entry: diacriticEntry, triangulator: triangulator).kind == .verified)

        let particleEntry = try #require(BibTeXParser.parseBibTeX("""
        @inproceedings{rossum2007, author = {van Rossum, Guido}, title = {Python Runtime Type Specialization Notes}, booktitle = {PyCon}, year = {2007}}
        """).first)
        #expect(await CitationDiagnosticsEngine.evaluateSingleEntry(entry: particleEntry, triangulator: triangulator).kind == .verified)

        let suffixEntry = try #require(BibTeXParser.parseBibTeX("""
        @book{steele1990, author = {Steele, Jr., Guy L.}, title = {Common Lisp Language Specification Second Edition}, publisher = {Digital Press}, year = {1990}}
        """).first)
        #expect(await CitationDiagnosticsEngine.evaluateSingleEntry(entry: suffixEntry, triangulator: triangulator).kind == .verified)

        let substringTrap = try #require(BibTeXParser.parseBibTeX("""
        @article{lee_trap, author = {Lee, Kai-Fu}, title = {Acoustic Modeling With Continuous Mixture Densities}, journal = {IEEE TASSP}, year = {1990}}
        """).first)
        let dSubstringTrap = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: substringTrap, triangulator: triangulator)
        #expect(dSubstringTrap.kind == .ghostPaper)
        #expect(dSubstringTrap.kind != .verified)
        #expect(dSubstringTrap.kind != .metadataMismatch)

        let unsignedCandidateTrap = try #require(BibTeXParser.parseBibTeX("""
        @book{unsigned_trap, author = {Knuth, Donald E.}, title = {Unsigned Archival Catalogue Note}, publisher = {Press}, year = {1970}}
        """).first)
        #expect(await CitationDiagnosticsEngine.evaluateSingleEntry(entry: unsignedCandidateTrap, triangulator: triangulator).kind == .ghostPaper)

        // (g) Book-review candidate ("type": "book-review" / "Book Review:" title) rejected even if reviewer shares surname & year
        let reviewTrap = try #require(BibTeXParser.parseBibTeX("""
        @book{smith_monograph, author = {Smith, Alice}, title = {Algebraic Topology Foundations}, publisher = {Springer}, year = {1975}}
        """).first)
        let dReviewTrap = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: reviewTrap, triangulator: triangulator)
        #expect(dReviewTrap.kind == .ghostPaper)

        // (h) Regression guard: Entry WITH a DOI and year diff == 5 or substring-mismatched surname ("Lee" vs "Greenlee") STILL returns MetadataMismatch (C5 only filters DOI-less title searches)
        let doiYearDrift = try #require(BibTeXParser.parseBibTeX("""
        @article{doi_drift, author = {Knuth, Donald E.}, title = {Structured Literate Programming Systems}, journal = {Comp. J.}, year = {1989}, doi = {10.1093/comjnl/27.2.97}}
        """).first)
        let dDOIDrift = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: doiYearDrift, triangulator: triangulator)
        #expect(dDOIDrift.kind == .metadataMismatch)

        let doiAuthorSubstring = try #require(BibTeXParser.parseBibTeX("""
        @article{doi_lee_vs_greenlee, author = {Lee, Kai-Fu}, title = {Acoustic Modeling With Continuous Mixture Densities}, journal = {IEEE TASSP}, year = {1990}, doi = {10.1109/29.56000}}
        """).first)
        let dDOIAuthor = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: doiAuthorSubstring, triangulator: triangulator)
        #expect(dDOIAuthor.kind == .metadataMismatch)

        // (i) Direct unit matrix on ScholarTriangulator.firstAuthorSurnamesMatch
        #expect(ScholarTriangulator.firstAuthorSurnamesMatch("Knuth, Donald E.", "Donald E. Knuth"))
        #expect(ScholarTriangulator.firstAuthorSurnamesMatch("KNUTH, DONALD", "donald e. knuth"))
        #expect(!ScholarTriangulator.firstAuthorSurnamesMatch("Knuth, Donald E.", "Robert E. Odeh"))
        #expect(!ScholarTriangulator.firstAuthorSurnamesMatch("Lee, Kai-Fu", "Jason Greenlee"))
        #expect(!ScholarTriangulator.firstAuthorSurnamesMatch("Knuth, Donald E.", ""))
        #expect(!ScholarTriangulator.firstAuthorSurnamesMatch("", "Robert E. Odeh"))
        #expect(ScholarTriangulator.firstAuthorSurnamesMatch("Strauss, Franz", "Franz Strauß"))
    }
}

/// 合成（Synthetic）手写 HTTP 响应服务器：仅用于隔离单元测试 C5 候选过滤规则，不算 C5 的证据。
private final class LoopbackC5TitleCandidateServer: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var stopped = false
    let port: UInt16

    var crossrefBaseURL: URL { URL(string: "http://127.0.0.1:\(port)/crossref")! }
    var openAlexBaseURL: URL { URL(string: "http://127.0.0.1:\(port)/openalex")! }

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = Darwin.listen(fd, 32)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)
        DispatchQueue.global().async { [weak self] in self?.loop() }
    }

    deinit { stop() }

    func stop() {
        let fd: Int32 = lock.withLock {
            if stopped { return -1 }
            stopped = true
            let cur = listenFD
            listenFD = -1
            return cur
        }
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private func loop() {
        while true {
            let lfd = lock.withLock { stopped ? -1 : listenFD }
            if lfd < 0 { break }
            var caddr = sockaddr_in()
            var clen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &caddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(lfd, $0, &clen)
                }
            }
            if cfd < 0 { break }
            DispatchQueue.global().async { Self.handle(cfd) }
        }
    }

    private static func handle(_ cfd: Int32) {
        defer { Darwin.close(cfd) }
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = Darwin.read(cfd, &buf, buf.count)
        guard n > 0 else { return }
        let req = String(decoding: buf[0..<n], as: UTF8.self)
        let target = String((req.components(separatedBy: "\r\n").first ?? "").split(separator: " ").dropFirst().first ?? "")
        let comps = URLComponents(string: "http://127.0.0.1" + target)
        let path = comps?.percentEncodedPath.removingPercentEncoding ?? comps?.path ?? target
        let qItems = comps?.queryItems ?? []

        var code = 200
        var body = #"{"results":[]}"#

        if path.hasPrefix("/crossref/works/") {
            if path.lowercased().contains("10.1093/comjnl/27.2.97") {
                body = #"{"status":"ok","message":{"DOI":"10.1093/comjnl/27.2.97","title":["Structured Literate Programming Systems"],"author":[{"given":"Donald E.","family":"Knuth"}],"container-title":["The Computer Journal"],"published-print":{"date-parts":[[1984,5]]}}}"#
            } else if path.lowercased().contains("10.1109/29.56000") {
                body = #"{"status":"ok","message":{"DOI":"10.1109/29.56000","title":["Acoustic Modeling With Continuous Mixture Densities"],"author":[{"given":"Jason","family":"Greenlee"}],"container-title":["IEEE TASSP"],"published-print":{"date-parts":[[1990,6]]}}}"#
            } else {
                code = 404
                body = #"{"status":"failed"}"#
            }
        } else if path.hasPrefix("/openalex/works/") {
            code = 404
            body = #"{"error":"not found"}"#
        } else if path == "/openalex/works" {
            let q = (qItems.first(where: { $0.name == "search" })?.value ?? "").lowercased()
            if q.contains("structured literate programming") {
                // Candidate 1 has wrong author (Odeh 1984); Candidate 2 has right author (Donald E. Knuth 1984)
                body = #"""
                {"results":[
                  {"title":"Structured Literate Programming Systems","publication_year":1984,"type":"article","authorships":[{"author":{"display_name":"Robert E. Odeh"}}],"primary_location":{"source":{"display_name":"Review Journal","type":"journal"}}},
                  {"title":"Structured Literate Programming Systems","publication_year":1984,"type":"book","doi":"https://doi.org/10.1093/comjnl/27.2.97","authorships":[{"author":{"display_name":"Donald E. Knuth"}}],"primary_location":{"source":{"display_name":"Addison-Wesley","type":"book series"}}}
                ]}
                """#
            } else if q.contains("art of computer programming") {
                // Synthetic handwritten subset mirroring Odeh 1969, MacLaren 1969, Wells 1973 book-review
                body = #"""
                {"results":[
                  {"title":"The Art of Computer Programming, Volume 1: Fundamental Algorithms.","publication_year":1969,"type":"article","doi":"https://doi.org/10.2307/2283757","authorships":[{"author":{"display_name":"Robert E. Odeh"}},{"author":{"display_name":"Donald E. Knuth"}}],"primary_location":{"source":{"display_name":"Journal of the American Statistical Association","type":"journal"}}},
                  {"title":"The Art of Computer Programming, Volume 1: Fundamental Algorithms (Donald E. Knuth)","publication_year":1969,"type":"article","doi":"https://doi.org/10.1137/1011017","authorships":[{"author":{"display_name":"M. Donald MacLaren"}}],"primary_location":{"source":{"display_name":"SIAM Review","type":"journal"}}},
                  {"title":"Book Review: The Art of Computer Programming, Volume 1: Fundamental Algorithms","publication_year":1973,"type":"book-review","doi":"https://doi.org/10.1090/s0002-9904-1973-13173-8","authorships":[{"author":{"display_name":"Mark B. Wells"}}],"primary_location":{"source":{"display_name":"Bulletin of the AMS","type":"journal"}}}
                ]}
                """#
            } else if q.contains("algebraic topology foundations") {
                body = #"""
                {"results":[
                  {"title":"Algebraic Topology Foundations","publication_year":1975,"type":"book-review","authorships":[{"author":{"display_name":"Alice Smith"}}],"primary_location":{"source":{"display_name":"Math Reviews","type":"journal"}}}
                ]}
                """#
            } else if q.contains("distributed transaction coordination protocols") {
                body = #"""
                {"results":[
                  {"title":"Distributed Transaction Coordination Protocols","publication_year":2019,"type":"article","authorships":[{"author":{"display_name":"Hector Garcia-Molina"}}],"primary_location":{"source":{"display_name":"ACM TODS","type":"journal"}}}
                ]}
                """#
            } else if q.contains("python runtime type specialization notes") {
                body = #"""
                {"results":[
                  {"title":"Python Runtime Type Specialization Notes","publication_year":2007,"type":"article","authorships":[{"author":{"display_name":"Guido van Rossum"}}],"primary_location":{"source":{"display_name":"PyCon","type":"conference"}}}
                ]}
                """#
            } else if q.contains("common lisp language specification second edition") {
                body = #"""
                {"results":[
                  {"title":"Common Lisp Language Specification Second Edition","publication_year":1990,"type":"book","authorships":[{"author":{"display_name":"Guy L. Steele Jr."}}],"primary_location":{"source":{"display_name":"Digital Press","type":"book series"}}}
                ]}
                """#
            } else if q.contains("acoustic modeling with continuous mixture densities") {
                body = #"""
                {"results":[
                  {"title":"Acoustic Modeling With Continuous Mixture Densities","publication_year":1990,"type":"article","authorships":[{"author":{"display_name":"Jason Greenlee"}}],"primary_location":{"source":{"display_name":"IEEE TASSP","type":"journal"}}}
                ]}
                """#
            } else if q.contains("unsigned archival catalogue note") {
                body = #"""
                {"results":[
                  {"title":"Unsigned Archival Catalogue Note","publication_year":1970,"type":"article","authorships":[],"primary_location":{"source":{"display_name":"Press","type":"journal"}}}
                ]}
                """#
            }
        } else if path == "/crossref/works" {
            let q = (qItems.first(where: { $0.name == "query.bibliographic" })?.value ?? "").lowercased()
            if q.contains("art of computer programming") {
                body = #"""
                {"status":"ok","message":{"items":[
                  {"DOI":"10.1090/s0002-9904-1973-13173-8","type":"journal-article","title":["Book Review: The Art of Computer Programming, Volume 1: Fundamental Algorithms"],"author":[{"given":"Mark B.","family":"Wells"}],"container-title":["Bulletin of the AMS"],"published-print":{"date-parts":[[1973,5]]}},
                  {"DOI":"10.2307/2283757","type":"journal-article","title":["The Art of Computer Programming, Volume 1: Fundamental Algorithms"],"author":[{"given":"Robert E.","family":"Odeh"}],"container-title":["JASA"],"published-print":{"date-parts":[[1969,3]]}}
                ]}}
                """#
            } else if q.contains("algebraic topology foundations") {
                body = #"""
                {"status":"ok","message":{"items":[
                  {"DOI":"10.9999/review.1975","type":"book-review","title":["Book Review: Algebraic Topology Foundations"],"author":[{"given":"Alice","family":"Smith"}],"container-title":["Math Reviews"],"published-print":{"date-parts":[[1975,1]]}}
                ]}}
                """#
            } else {
                body = #"{"status":"ok","message":{"items":[]}}"#
            }
        }

        let bytes = Array(body.utf8)
        let resp = Array("HTTP/1.1 \(code) OK\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8) + bytes
        resp.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                _ = Darwin.write(cfd, base, resp.count)
            }
        }
    }
}
