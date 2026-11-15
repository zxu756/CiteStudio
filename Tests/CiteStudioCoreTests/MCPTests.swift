// 合成测试响应说明（Synthetic handwritten unit-test HTTP payloads — 不算 C5 的证据）：
// 本文件中使用 LoopbackScholarServer 的测试返回 TestFixtures.swift 中的合成手写最小 JSON 响应正文，不算 C5 的真实证据。

import Foundation
import Testing
@testable import CiteStudioCore

@Suite("MCPTests", .timeLimit(.minutes(1)))
struct MCPTests {

    @Test("C4 (Row 5): add_verified_bibtex writes canonical upstream title/authors/venue and deduplicates existing cite keys")
    func c4AddVerifiedBibTeXWritesCanonicalUpstreamRecordAndSkipsDuplicateKey() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_mcp_c4_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let serverHTTP = try LoopbackScholarServer(initialMode: .healthy)
        defer { serverHTTP.stop() }
        let transport = PublicScholarHTTPTransport(
            crossrefBaseURL: serverHTTP.crossrefBaseURL,
            openAlexBaseURL: serverHTTP.openAlexBaseURL
        )
        let triangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("cache.sqlite"),
            transport: transport
        )
        let indexer = try LocalPDFIndexer(dbURL: tmp.appendingPathComponent("fts.sqlite"))
        let mcp = CiteStudioMCPServer(triangulator: triangulator, pdfIndexer: indexer)

        let bibURL = tmp.appendingPathComponent("refs.bib")
        try "".write(to: bibURL, atomically: true, encoding: .utf8)

        // Caller sends scrambled title casing ("dEEP lEARNING") and incomplete author list
        let scrambledBib = "@article{real_lecun, author = {lecun, yann}, title = {dEEP lEARNING}, journal = {nATURE}, year = {2015}, doi = {10.1038/nature14539}}"
        let addReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": [
                "name": "add_verified_bibtex",
                "arguments": [
                    "bib_file": bibURL.path,
                    "bibtex": scrambledBib
                ]
            ]
        ]
        let reqStr = String(data: try JSONSerialization.data(withJSONObject: addReq), encoding: .utf8)!
        let resp1 = try #require(await mcp.handleJSONLine(reqStr))
        #expect(resp1.contains("APPENDED_VERIFIED"))

        let writtenAfterFirst = try String(contentsOf: bibURL, encoding: .utf8)
        let parsedFirst = BibTeXParser.parseBibTeX(writtenAfterFirst)
        #expect(parsedFirst.count == 1)
        // Canonical upstream title & authors MUST replace caller's scrambled text!
        #expect(parsedFirst[0].title == "Deep learning")
        #expect(!writtenAfterFirst.contains("dEEP lEARNING"))
        #expect(writtenAfterFirst.contains("Yoshua Bengio"))

        // Second call with the same citeKey MUST NOT duplicate the entry
        let resp2 = try #require(await mcp.handleJSONLine(reqStr))
        #expect(!resp2.contains("APPENDED_VERIFIED"))
        let writtenAfterSecond = try String(contentsOf: bibURL, encoding: .utf8)
        #expect(writtenAfterSecond == writtenAfterFirst)
        #expect(BibTeXParser.parseBibTeX(writtenAfterSecond).count == 1)
    }

    @Test("合成 (Synthetic HTTP) C2 + C1 MCP Gate: add_verified_bibtex rejects MetadataMismatch (wrong title) and Unverified (offline) without modifying .bib")
    func mcpRejectsWrongTitleAndOfflineUnverified() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_mcp_gate_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let serverHTTP = try LoopbackScholarServer(initialMode: .healthy)
        defer { serverHTTP.stop() }
        let transport = PublicScholarHTTPTransport(
            crossrefBaseURL: serverHTTP.crossrefBaseURL,
            openAlexBaseURL: serverHTTP.openAlexBaseURL
        )
        let triangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("cache.sqlite"),
            transport: transport
        )
        let indexer = try LocalPDFIndexer(dbURL: tmp.appendingPathComponent("fts.sqlite"))
        let mcp = CiteStudioMCPServer(triangulator: triangulator, pdfIndexer: indexer)

        let bibURL = tmp.appendingPathComponent("seed.bib")
        let initialSeed = "% seed\n@misc{keep_me, title={Seed}}\n"
        try initialSeed.write(to: bibURL, atomically: true, encoding: .utf8)

        // 1. Wrong title paired with real DOI -> rejected with ERR_UNVERIFIED_CITATION
        let wrongTitleReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 21,
            "method": "tools/call",
            "params": [
                "name": "add_verified_bibtex",
                "arguments": [
                    "bib_file": bibURL.path,
                    "bibtex": "@article{wrongtitle, author = {LeCun, Yann}, title = {A Completely Different Invented Title About Ocean Currents}, journal = {Nature}, year = {2015}, doi = {10.1038/nature14539}}"
                ]
            ]
        ]
        let wrongResp = try #require(await mcp.handleJSONLine(String(data: try JSONSerialization.data(withJSONObject: wrongTitleReq), encoding: .utf8)!))
        #expect(wrongResp.contains("ERR_UNVERIFIED_CITATION"))
        #expect(wrongResp.contains("MetadataMismatch"))
        #expect(try String(contentsOf: bibURL, encoding: .utf8) == initialSeed)

        // 2. HTTP 500 -> Unverified -> rejected with ERR_UNVERIFIED_CITATION
        serverHTTP.mode = .httpStatus(500)
        let offlineReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 22,
            "method": "tools/call",
            "params": [
                "name": "add_verified_bibtex",
                "arguments": [
                    "bib_file": bibURL.path,
                    "bibtex": "@article{real_lstm, author = {Hochreiter, Sepp and Schmidhuber, Juergen}, title = {Long Short-Term Memory}, journal = {Neural Computation}, year = {1997}, doi = {10.1162/neco.1997.9.8.1735}}"
                ]
            ]
        ]
        let offlineResp = try #require(await mcp.handleJSONLine(String(data: try JSONSerialization.data(withJSONObject: offlineReq), encoding: .utf8)!))
        #expect(offlineResp.contains("ERR_UNVERIFIED_CITATION"))
        #expect(offlineResp.contains("Unverified"))
        #expect(try String(contentsOf: bibURL, encoding: .utf8) == initialSeed)
    }

    @Test("MCP JSON-RPC returns -32700 on malformed JSON and -32601 on unknown method")
    func mcpInvalidJSONAndUnknownMethod() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_mcp_rpc_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let triangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("cache.sqlite"),
            transport: FixtureScholarTransport(recordsByKey: [:])
        )
        let indexer = try LocalPDFIndexer(dbURL: tmp.appendingPathComponent("fts.sqlite"))
        let mcp = CiteStudioMCPServer(triangulator: triangulator, pdfIndexer: indexer)

        let badJSONResp = try #require(await mcp.handleJSONLine("{invalid_json"))
        #expect(badJSONResp.contains("-32700"))

        let unknownMethodResp = try #require(await mcp.handleJSONLine(#"{"jsonrpc":"2.0","id":7,"method":"unknown/method","params":{}}"#))
        #expect(unknownMethodResp.contains("-32601"))
    }

    @Test("合成 (Synthetic, 不算 C5 证据) C5 MCP Gate: add_verified_bibtex blocks DOI-less non-matching book-review candidates with ERR_UNVERIFIED_CITATION and writes .bib untampered")
    func c5MCPBlocksNonMatchingNoDOIBookReviewCandidate() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_mcp_c5_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let serverHTTP = try LoopbackScholarServer(initialMode: .healthy)
        defer { serverHTTP.stop() }
        let transport = PublicScholarHTTPTransport(
            crossrefBaseURL: serverHTTP.crossrefBaseURL,
            openAlexBaseURL: serverHTTP.openAlexBaseURL
        )
        let triangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("cache.sqlite"),
            transport: transport
        )
        let indexer = try LocalPDFIndexer(dbURL: tmp.appendingPathComponent("fts.sqlite"))
        let mcp = CiteStudioMCPServer(triangulator: triangulator, pdfIndexer: indexer)

        let bibURL = tmp.appendingPathComponent("refs.bib")
        try "".write(to: bibURL, atomically: true, encoding: .utf8)

        let knuthBib = "@book{real_nodoi, author = {Knuth, Donald E.}, title = {The Art of Computer Programming, Volume 1: Fundamental Algorithms}, publisher = {Addison-Wesley}, year = {1968}}"

        // 1. verify_citation returns GhostPaper (not MetadataMismatch on Jeeves 1969 review)
        let verifyReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 31,
            "method": "tools/call",
            "params": [
                "name": "verify_citation",
                "arguments": ["bibtex": knuthBib]
            ]
        ]
        let verifyResp = try #require(await mcp.handleJSONLine(String(data: try JSONSerialization.data(withJSONObject: verifyReq), encoding: .utf8)!))
        #expect(verifyResp.contains("GhostPaper"))
        #expect(!verifyResp.contains("MetadataMismatch"))

        // 2. add_verified_bibtex rejects unverified/not-found citation with ERR_UNVERIFIED_CITATION and leaves .bib empty
        let addReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 32,
            "method": "tools/call",
            "params": [
                "name": "add_verified_bibtex",
                "arguments": ["bib_file": bibURL.path, "bibtex": knuthBib]
            ]
        ]
        let addResp = try #require(await mcp.handleJSONLine(String(data: try JSONSerialization.data(withJSONObject: addReq), encoding: .utf8)!))
        #expect(addResp.contains("ERR_UNVERIFIED_CITATION"))
        #expect(try String(contentsOf: bibURL, encoding: .utf8).isEmpty)
    }
}
