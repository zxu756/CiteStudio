// 合成测试响应说明（Synthetic handwritten unit-test HTTP payloads vs. RecordedFixturesReplayServer）：
// 本文件中使用 LoopbackScholarServer 或 LoopbackOpenAlexResultsWrapperServer 的单元测试返回手写合成 JSON 响应正文（不算 C5 的证据）；
// 使用 RecordedFixturesReplayServer 的测试（如 CR1、CR2、CR4）严格原样回放 Tests/Fixtures/recorded/ 中的真实录制响应。

import Darwin
import Foundation
import Testing
@testable import CiteStudioCore

/// Switchable transport used to verify C1 offline -> online behavior deterministically.
final class SwitchableThrowingTransport: ScholarLookupTransport, @unchecked Sendable {
    private let lock = NSLock()
    var shouldFailOffline: Bool = true
    var callCount: Int = 0
    let recordsByKey: [String: ScholarRecord]

    init(recordsByKey: [String: ScholarRecord]) {
        self.recordsByKey = recordsByKey
    }

    func lookupOutcome(entry: BibEntry) async -> ScholarLookupOutcome {
        let offline = lock.withLock { () -> Bool in
            callCount += 1
            return shouldFailOffline
        }
        if offline {
            return .lookupFailed(.offlineOrNetwork("Simulated offline"))
        }
        if let rec = recordsByKey[entry.citeKey] {
            return .found(rec)
        }
        return .confirmedNotFound
    }
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

@Suite("FirewallTests", .timeLimit(.minutes(1)))
struct FirewallTests {

    @Test("C1: Offline lookup failure returns Unverified (never GhostPaper) and writes 0 cache entries")
    func c1OfflineLookupDoesNotPoisonCache() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_c1_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let transport = SwitchableThrowingTransport(recordsByKey: [
            "real_lecun": ScholarRecord(
                source: "Crossref",
                title: "Deep learning",
                authors: ["Yann LeCun", "Yoshua Bengio", "Geoffrey Hinton"],
                year: 2015,
                venue: "Nature",
                doi: "10.1038/nature14539"
            )
        ])
        let triangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("cache.sqlite"),
            transport: transport
        )
        let entry = try #require(BibTeXParser.parseBibTeX("""
        @article{real_lecun, author = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey}, title = {Deep learning}, journal = {Nature}, year = {2015}, doi = {10.1038/nature14539}}
        """).first)

        transport.shouldFailOffline = true
        let offlineDiag = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: entry, triangulator: triangulator)
        #expect(offlineDiag.kind == .unverified)
        #expect(offlineDiag.kind.badgeLabel(in: .zhHans) == "未验证")
        #expect(triangulator.rawCacheRowCount() == 0)
        #expect(transport.callCount == 1)

        transport.shouldFailOffline = false
        let onlineDiag = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: entry, triangulator: triangulator)
        #expect(transport.callCount == 2)
        #expect(onlineDiag.kind == .verified)
        #expect(triangulator.rawCacheRowCount() == 1)
    }

    @Test("合成 (Synthetic HTTP) C1 + Item 10: Real URLSession HTTP transport handles offline -> online, 429, 500, timeout, and malformed JSON without caching")
    func realURLSessionTransportOffline429And500AndTimeout() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_http_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let lecun = try #require(BibTeXParser.parseBibTeX("""
        @article{real_lecun, author = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey}, title = {Deep learning}, journal = {Nature}, year = {2015}, doi = {10.1038/nature14539}}
        """).first)

        // 1. Offline connection-refused on closed loopback port
        let tempServer = try LoopbackScholarServer()
        let closedPort = tempServer.port
        tempServer.stop()

        let offlineTransport = PublicScholarHTTPTransport(
            crossrefBaseURL: URL(string: "http://127.0.0.1:\(closedPort)/crossref")!,
            openAlexBaseURL: URL(string: "http://127.0.0.1:\(closedPort)/openalex")!,
            timeoutInterval: 1.0
        )
        let cacheURL = tmp.appendingPathComponent("shared_cache.sqlite")
        let offlineTriangulator = try ScholarTriangulator(cacheDBPath: cacheURL, transport: offlineTransport)
        let dOffline = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: lecun, triangulator: offlineTriangulator)
        #expect(dOffline.kind == .unverified)
        #expect(offlineTriangulator.rawCacheRowCount() == 0)

        // 2. HTTP 429, HTTP 500, Malformed JSON, and Timeout against live LoopbackScholarServer
        let server = try LoopbackScholarServer(initialMode: .httpStatus(429))
        defer { server.stop() }

        let liveTransport = PublicScholarHTTPTransport(
            crossrefBaseURL: server.crossrefBaseURL,
            openAlexBaseURL: server.openAlexBaseURL,
            timeoutInterval: 0.15
        )
        let liveTriangulator = try ScholarTriangulator(cacheDBPath: cacheURL, transport: liveTransport)

        let d429 = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: lecun, triangulator: liveTriangulator)
        #expect(d429.kind == .unverified)
        #expect(liveTriangulator.rawCacheRowCount() == 0)

        server.mode = .httpStatus(500)
        let d500 = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: lecun, triangulator: liveTriangulator)
        #expect(d500.kind == .unverified)
        #expect(liveTriangulator.rawCacheRowCount() == 0)

        server.mode = .malformedJSON
        let dBadJSON = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: lecun, triangulator: liveTriangulator)
        #expect(dBadJSON.kind == .unverified)
        #expect(liveTriangulator.rawCacheRowCount() == 0)

        server.mode = .slowResponse(0.45)
        let dTimeout = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: lecun, triangulator: liveTriangulator)
        #expect(dTimeout.kind == .unverified)
        #expect(liveTriangulator.rawCacheRowCount() == 0)

        // 3. Switch server to healthy -> sends fresh HTTP requests on the SAME SQLite cache and resolves to Verified!
        server.resetRecordedPaths()
        server.mode = .healthy
        let dOnline = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: lecun, triangulator: liveTriangulator)
        #expect(dOnline.kind == .verified)
        #expect(!server.recordedPaths.isEmpty)
        #expect(liveTriangulator.rawCacheRowCount() == 1)
    }

    @Test("合成 (Synthetic HTTP) Item 2: Confirmed-not-found TTL is shorter than found TTL, expired rows re-fetch, and clearCache purges rows")
    func cacheExpirationTTLAndClearCache() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_ttl_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(ScholarTriangulator.defaultNotFoundTTL < ScholarTriangulator.defaultFoundTTL)

        let server = try LoopbackScholarServer(initialMode: .healthy)
        defer { server.stop() }
        let clock = MutableClock()

        let transport = PublicScholarHTTPTransport(
            crossrefBaseURL: server.crossrefBaseURL,
            openAlexBaseURL: server.openAlexBaseURL,
            timeoutInterval: 2.0
        )
        let triangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("ttl_cache.sqlite"),
            transport: transport,
            foundTTLSeconds: 3600,
            notFoundTTLSeconds: 300,
            nowProvider: { clock.now() }
        )

        let foundEntry = try #require(BibTeXParser.parseBibTeX("""
        @article{real_lecun, author = {LeCun, Yann}, title = {Deep learning}, journal = {Nature}, year = {2015}, doi = {10.1038/nature14539}}
        """).first)
        let ghostEntry = try #require(BibTeXParser.parseBibTeX("""
        @article{fake_doi, author = {Nobody, A.}, title = {Invented}, year = {2026}, doi = {10.1038/fake.2026.99999}}
        """).first)

        #expect(await CitationDiagnosticsEngine.evaluateSingleEntry(entry: foundEntry, triangulator: triangulator).kind == .verified)
        #expect(await CitationDiagnosticsEngine.evaluateSingleEntry(entry: ghostEntry, triangulator: triangulator).kind == .ghostPaper)
        #expect(triangulator.rawCacheRowCount() == 2)

        // Advance 600s: ghostEntry (TTL 300s) expires and re-fetches, while foundEntry (TTL 3600s) hits cache
        clock.advance(by: 600)
        server.resetRecordedPaths()
        _ = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: foundEntry, triangulator: triangulator)
        #expect(server.recordedPaths.isEmpty)

        _ = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: ghostEntry, triangulator: triangulator)
        #expect(!server.recordedPaths.isEmpty)

        let purged = triangulator.clearCache()
        #expect(purged == 2)
        #expect(triangulator.rawCacheRowCount() == 0)
    }

    @Test("C2: Real DOI paired with mismatched title is flagged as MetadataMismatch, never Verified")
    func c2RealDOIWithWrongTitleIsMetadataMismatch() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_c2_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let server = try LoopbackScholarServer(initialMode: .healthy)
        defer { server.stop() }
        let transport = PublicScholarHTTPTransport(
            crossrefBaseURL: server.crossrefBaseURL,
            openAlexBaseURL: server.openAlexBaseURL
        )
        let triangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("cache.sqlite"),
            transport: transport
        )
        let entry = try #require(BibTeXParser.parseBibTeX("""
        @article{wrongtitle, author = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey}, title = {A Completely Different Invented Title About Ocean Currents}, journal = {Nature}, year = {2015}, doi = {10.1038/nature14539}}
        """).first)

        let diag = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: entry, triangulator: triangulator)
        #expect(diag.kind == .metadataMismatch)
        #expect(diag.detail.contains("title"))
    }

    @Test("C3: Retraction detection catches Crossref update-to, Crossref updated-by, RETRACTED title prefix, and OpenAlex is_retracted")
    func c3RetractionDetectionAcrossAllChannels() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_c3_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let server = try LoopbackScholarServer(initialMode: .healthy)
        defer { server.stop() }
        let transport = PublicScholarHTTPTransport(
            crossrefBaseURL: server.crossrefBaseURL,
            openAlexBaseURL: server.openAlexBaseURL
        )
        let triangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("cache.sqlite"),
            transport: transport
        )

        let bib = """
        @article{retracted_seralini, author = {S{\\'e}ralini, Gilles-{\\'E}ric and Clair, Emilie and Mesnage, Robin}, title = {Long term toxicity of a Roundup herbicide and a Roundup-tolerant genetically modified maize}, journal = {Food and Chemical Toxicology}, year = {2012}, doi = {10.1016/j.fct.2012.08.005}}
        @article{retracted_wakefield, author = {Wakefield, A. J. and Murch, S. H.}, title = {Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children}, journal = {The Lancet}, year = {1998}, doi = {10.1016/S0140-6736(97)11096-0}}
        @article{updated_by_only, author = {Doe, Jane}, title = {Clinical Trial With Updated-By Notice Only}, journal = {Journal of Testing}, year = {2020}, doi = {10.9999/test.updatedby.only}}
        @article{openalex_only, author = {Roe, John}, title = {Study Retracted Only in OpenAlex}, journal = {OpenAlex Test Letters}, year = {2021}, doi = {10.9999/test.openalex.retracted}}
        """
        let entries = BibTeXParser.parseBibTeX(bib)
        #expect(entries.count == 4)
        for entry in entries {
            let diag = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: entry, triangulator: triangulator)
            #expect(diag.kind == .retracted, "Expected \(entry.citeKey) to be Retracted, got \(diag.kind)")
        }
    }

    @Test("合成 (Synthetic HTTP) Row 8: Full 12-entry test.bib matrix over real URLSession HTTP transport matches expected M0 verdicts")
    func twelveEntryTestBibMatrix() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_12_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let server = try LoopbackScholarServer(initialMode: .healthy)
        defer { server.stop() }
        let transport = PublicScholarHTTPTransport(
            crossrefBaseURL: server.crossrefBaseURL,
            openAlexBaseURL: server.openAlexBaseURL
        )
        let triangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("cache.sqlite"),
            transport: transport
        )

        let testBib = #"""
        @article{real_lecun, author = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey}, title = {Deep learning}, journal = {Nature}, year = {2015}, volume = {521}, pages = {436--444}, doi = {10.1038/nature14539}}
        @article{real_lstm, author = {Hochreiter, Sepp and Schmidhuber, J{\"u}rgen}, title = {Long Short-Term Memory}, journal = {Neural Computation}, year = {1997}, volume = {9}, pages = {1735--1780}, doi = {10.1162/neco.1997.9.8.1735}}
        @article{real_watson, author = {Watson, J. D. and Crick, F. H. C.}, title = {Molecular Structure of Nucleic Acids: A Structure for Deoxyribose Nucleic Acid}, journal = {Nature}, year = {1953}, volume = {171}, pages = {737--738}, doi = {10.1038/171737a0}}
        @article{fake_nonsentinel, author = {Whitfield, Eleanor and Patel, Raj}, title = {Quantum Gradient Descent in Biological Neural Networks}, journal = {Nature Machine Intelligence}, year = {2026}, doi = {10.1038/fake.2026.99999}}
        @article{fake_sentinel, author = {Okafor, Ngozi and Lindqvist, Mats}, title = {Self-Supervised Topological Priors for Protein Folding}, journal = {Science}, year = {2026}, doi = {10.1234/fake.2026.99999}}
        @article{wrongtitle, author = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey}, title = {A Completely Different Invented Title About Ocean Currents}, journal = {Nature}, year = {2015}, doi = {10.1038/nature14539}}
        @article{wrongyear, author = {Hochreiter, Sepp and Schmidhuber, J{\"u}rgen}, title = {Long Short-Term Memory}, journal = {Neural Computation}, year = {1999}, doi = {10.1162/neco.1997.9.8.1735}}
        @article{wrongyear5, author = {Hochreiter, Sepp and Schmidhuber, J{\"u}rgen}, title = {Long Short-Term Memory}, journal = {Neural Computation}, year = {1992}, doi = {10.1162/neco.1997.9.8.1735}}
        @book{real_nodoi, author = {Knuth, Donald E.}, title = {The Art of Computer Programming, Volume 1: Fundamental Algorithms}, publisher = {Addison-Wesley}, year = {1968}}
        @article{fake_nodoi, author = {Whitfield, Eleanor and Patel, Raj}, title = {Recursive Causal Lattices for Zero-Shot Climate Forecasting}, journal = {Journal of Applied Machine Cognition}, year = {2023}, volume = {12}, pages = {101--119}}
        @article{retracted_seralini, author = {S{\'e}ralini, Gilles-{\'E}ric and Clair, Emilie and Mesnage, Robin}, title = {Long term toxicity of a Roundup herbicide and a Roundup-tolerant genetically modified maize}, journal = {Food and Chemical Toxicology}, year = {2012}, doi = {10.1016/j.fct.2012.08.005}}
        @article{retracted_wakefield, author = {Wakefield, A. J. and Murch, S. H.}, title = {Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children}, journal = {The Lancet}, year = {1998}, doi = {10.1016/S0140-6736(97)11096-0}}
        """#

        let expected: [String: FirewallVerdictKind] = [
            "real_lecun": .verified,
            "real_lstm": .verified,
            "real_watson": .verified,
            "fake_nonsentinel": .ghostPaper,
            "fake_sentinel": .ghostPaper,
            "wrongtitle": .metadataMismatch,
            "wrongyear": .metadataMismatch,
            "wrongyear5": .metadataMismatch,
            "real_nodoi": .ghostPaper, // C5 fixed in M1: Odeh/Jeeves 1969 book review rejected on surname mismatch -> not found
            "fake_nodoi": .ghostPaper,
            "retracted_seralini": .retracted,
            "retracted_wakefield": .retracted
        ]

        let entries = BibTeXParser.parseBibTeX(testBib)
        #expect(entries.count == 12)
        for entry in entries {
            let diag = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: entry, triangulator: triangulator)
            #expect(diag.kind == expected[entry.citeKey], "Mismatch on \(entry.citeKey): got \(diag.kind)")
            if entry.citeKey == "real_nodoi" {
                #expect(diag.headline.contains("Not found in Crossref / OpenAlex"))
                #expect(!diag.headline.lowercased().contains("fabricated"))
                #expect(diag.localizedHeadline(in: .zhHans).contains("未在 Crossref / OpenAlex"))
                #expect(!diag.localizedDetail(in: .zhHans).contains("编造"))
            }
        }
    }

    @Test("C16: Crossref 404 on DataCite DOI consults OpenAlex (200 -> Verified/Mismatch; 503/429 -> Unverified uncached; both 404 -> GhostPaper)")
    func c16Crossref404ConsultsOpenAlexBeforeGhostPaper() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_c16_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let server = try LoopbackScholarServer(initialMode: .healthy)
        defer { server.stop() }
        let transport = PublicScholarHTTPTransport(
            crossrefBaseURL: server.crossrefBaseURL,
            openAlexBaseURL: server.openAlexBaseURL,
            timeoutInterval: 1.0
        )

        let arxivEntry = try #require(BibTeXParser.parseBibTeX("""
        @article{vaswani2017arxiv, author = {Vaswani, Ashish and Shazeer, Noam}, title = {Attention Is All You Need}, journal = {arXiv preprint arXiv:1706.03762}, year = {2017}, doi = {10.48550/arXiv.1706.03762}}
        """).first)

        // 1. Crossref 404 + OpenAlex 503 -> MUST be Unverified (未验证) and MUST NOT cache as GhostPaper!
        server.crossrefMode = .healthy
        server.openAlexMode = .httpStatus(503)
        let failTriangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("c16_503.sqlite"),
            transport: transport
        )
        let d503 = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: arxivEntry, triangulator: failTriangulator)
        #expect(d503.kind == .unverified)
        #expect(d503.kind.badgeLabel(in: .zhHans) == "未验证")
        #expect(failTriangulator.rawCacheRowCount() == 0)

        server.openAlexMode = .httpStatus(429)
        let d429 = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: arxivEntry, triangulator: failTriangulator)
        #expect(d429.kind == .unverified)
        #expect(failTriangulator.rawCacheRowCount() == 0)

        // 2. Crossref 404 + OpenAlex 200 matching Attention Is All You Need -> MUST NOT be GhostPaper!
        server.openAlexMode = .healthy
        let dHit = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: arxivEntry, triangulator: failTriangulator)
        #expect(dHit.kind != .ghostPaper)
        #expect(dHit.kind == .verified)
        #expect(failTriangulator.rawCacheRowCount() == 1)

        // Crossref 404 + OpenAlex 200 with mismatched title -> MetadataMismatch
        let wrongTitleArxiv = try #require(BibTeXParser.parseBibTeX("""
        @article{vaswani_wrong, author = {Vaswani, Ashish}, title = {Unrelated Study on Marine Biology}, journal = {arXiv}, year = {2017}, doi = {10.48550/arXiv.1706.03762}}
        """).first)
        let mismatchTriangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("c16_mismatch.sqlite"),
            transport: transport
        )
        let dMismatch = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: wrongTitleArxiv, triangulator: mismatchTriangulator)
        #expect(dMismatch.kind == .metadataMismatch)

        // 3. Crossref 404 + OpenAlex 404 -> GhostPaper
        let bothMissing = try #require(BibTeXParser.parseBibTeX("""
        @article{both_404, author = {Nobody, X.}, title = {Completely Nonexistent DOI}, journal = {arXiv}, year = {2026}, doi = {10.48550/arXiv.9999.99999}}
        """).first)
        let ghostTriangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("c16_ghost.sqlite"),
            transport: transport
        )
        let dGhost = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: bothMissing, triangulator: ghostTriangulator)
        #expect(dGhost.kind == .ghostPaper)
        #expect(ghostTriangulator.rawCacheRowCount() == 1)
    }

    @Test("合成 (Synthetic HTTP) C22: parseOpenAlexWork & queryOpenAlexByDOI cover every kept branch (display_name, raw_author_name, repository source.type, missing-source OpenAlex Indexed Venue fallback, results wrapper) and TestFixtures.swift has honest comment")
    func c22OpenAlexParserBranchesAndHonestTestFixturesComment() async throws {
        // 1. Missing primary_location.source -> reverts to "OpenAlex Indexed Venue" with publishedUpgradeVenue == nil
        let minimalWork: [String: Any] = [
            "display_name": "Fallback Display Name Only",
            "publication_year": 2021,
            "doi": "https://doi.org/10.5281/zenodo.12345",
            "is_retracted": false,
            "authorships": [
                ["author": ["display_name": ""], "raw_author_name": "Ada Lovelace"],
                ["raw_author_name": "Charles Babbage"]
            ]
        ]
        let parsedMinimal = try #require(PublicScholarHTTPTransport.parseOpenAlexWork(minimalWork))
        #expect(parsedMinimal.title == "Fallback Display Name Only")
        #expect(parsedMinimal.year == 2021)
        #expect(parsedMinimal.doi == "10.5281/zenodo.12345")
        #expect(parsedMinimal.authors == ["Ada Lovelace", "Charles Babbage"])
        #expect(parsedMinimal.venue == "OpenAlex Indexed Venue")
        #expect(parsedMinimal.publishedUpgradeVenue == nil)
        #expect(parsedMinimal.publishedUpgradeDOI == nil)
        #expect(parsedMinimal.publishedUpgradeYear == nil)

        // 2. Repository source whose display_name does NOT contain "arxiv" (e.g., "Cornell University", type="repository")
        //    MUST set publishedUpgradeVenue = nil so citing an arXiv entry does not falsely trigger PreprintUpgrade
        let repoWork: [String: Any] = [
            "title": "Attention Is All You Need",
            "publication_year": 2017,
            "doi": "https://doi.org/10.48550/arxiv.1706.03762",
            "authorships": [["author": ["display_name": "Ashish Vaswani"]]],
            "primary_location": [
                "source": [
                    "display_name": "Cornell University",
                    "type": "repository"
                ]
            ]
        ]
        let parsedRepo = try #require(PublicScholarHTTPTransport.parseOpenAlexWork(repoWork))
        #expect(parsedRepo.venue == "Cornell University")
        #expect(parsedRepo.publishedUpgradeVenue == nil)

        // 3. Journal/conference source (type="journal") sets publishedUpgradeVenue to the peer-reviewed venue
        let journalWork: [String: Any] = [
            "title": "Deep Residual Learning for Image Recognition",
            "publication_year": 2016,
            "doi": "https://doi.org/10.1109/cvpr.2016.90",
            "authorships": [["author": ["display_name": "Kaiming He"]]],
            "primary_location": [
                "source": [
                    "display_name": "IEEE Conference on Computer Vision and Pattern Recognition",
                    "type": "conference"
                ]
            ]
        ]
        let parsedJournal = try #require(PublicScholarHTTPTransport.parseOpenAlexWork(journalWork))
        #expect(parsedJournal.venue == "IEEE Conference on Computer Vision and Pattern Recognition")
        #expect(parsedJournal.publishedUpgradeVenue == "IEEE Conference on Computer Vision and Pattern Recognition")
        #expect(parsedJournal.publishedUpgradeYear == 2016)

        // 4. queryOpenAlexByDOI handles {"results": [...]} list wrapper and empty {"results": []} over real HTTP
        let listServer = try LoopbackOpenAlexResultsWrapperServer()
        defer { listServer.stop() }
        let wrapperTransport = PublicScholarHTTPTransport(
            crossrefBaseURL: listServer.crossrefBaseURL,
            openAlexBaseURL: listServer.openAlexBaseURL,
            timeoutInterval: 1.5
        )
        let hitEntry = try #require(BibTeXParser.parseBibTeX("""
        @article{wrap_hit, author = {Lovelace, Ada}, title = {Analytical Engine Notes}, journal = {arXiv}, year = {2020}, doi = {10.48550/arXiv.2001.00001}}
        """).first)
        let hitOutcome = await wrapperTransport.lookupOutcome(entry: hitEntry)
        if case .found(let rec) = hitOutcome {
            #expect(rec.title == "Analytical Engine Notes")
            #expect(rec.authors == ["Ada Lovelace"])
            #expect(rec.year == 2020)
            #expect(rec.publishedUpgradeVenue == nil)
        } else {
            Issue.record("Expected .found from OpenAlex results wrapper, got \(hitOutcome)")
        }

        let emptyEntry = try #require(BibTeXParser.parseBibTeX("""
        @article{wrap_empty, author = {Nobody, X.}, title = {Missing Work}, journal = {arXiv}, year = {2020}, doi = {10.48550/arXiv.2001.99999}}
        """).first)
        let emptyOutcome = await wrapperTransport.lookupOutcome(entry: emptyEntry)
        #expect(emptyOutcome == .confirmedNotFound)

        // 5. TestFixtures.swift must not claim "recorded-structure" for handwritten unit-test JSON
        let fixturesPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("TestFixtures.swift")
        let fixturesSource = try String(contentsOf: fixturesPath, encoding: .utf8)
        #expect(!fixturesSource.lowercased().contains("recorded-structure"))
        #expect(fixturesSource.contains("手写最小单元测试响应"))
    }

    @Test("CR1: Recorded replay of Odeh book review surfaces matched venue and upstream workType across human/JSON/MCP outputs, and README EN/ZH document untagged book-review limitation")
    func cr1RecordedOdehBookReviewSurfacesVenueAndWorkTypeAndReadmeDocumentsLimitation() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_cr1_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let replay = try RecordedFixturesReplayServer()
        defer { replay.stop() }
        let transport = PublicScholarHTTPTransport(
            crossrefBaseURL: replay.crossrefBaseURL,
            openAlexBaseURL: replay.openAlexBaseURL,
            timeoutInterval: 2.0
        )
        let triangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("cr1_cache.sqlite"),
            transport: transport
        )

        let odehBib = """
        @book{odeh_taocp, author = {Odeh, Robert E.}, title = {The Art of Computer Programming, Volume 1: Fundamental Algorithms}, publisher = {Addison-Wesley}, year = {1968}}
        """
        let odehEntry = try #require(BibTeXParser.parseBibTeX(odehBib).first)
        let diag = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: odehEntry, triangulator: triangulator)
        #expect(diag.kind == .verified)
        #expect(diag.matchedRecord?.venue == "Journal of the American Statistical Association")
        #expect(diag.matchedRecord?.workType == "article")
        #expect(diag.headline.contains("Journal of the American Statistical Association"))
        #expect(diag.headline.contains("type: article"))
        #expect(diag.localizedHeadline(in: .zhHans).contains("Journal of the American Statistical Association"))
        #expect(diag.localizedHeadline(in: .zhHans).contains("类型：article"))

        // Missing upstream workType renders honestly as "unknown" / "未知" (never an invented default)
        let untypedRecord = ScholarRecord(source: "Crossref", title: "Sample", authors: ["Jane Doe"], year: 2020, venue: "Venue", workType: nil)
        #expect(untypedRecord.displayWorkType(in: .en) == "unknown")
        #expect(untypedRecord.displayWorkType(in: .zhHans) == "未知")

        // Recorded Crossref DOI (real_lecun) also populates workType ("journal-article")
        let lecunEntry = try #require(BibTeXParser.parseBibTeX("""
        @article{real_lecun, author = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey}, title = {Deep learning}, journal = {Nature}, year = {2015}, doi = {10.1038/nature14539}}
        """).first)
        let lecunDiag = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: lecunEntry, triangulator: triangulator)
        #expect(lecunDiag.kind == .verified)
        #expect(lecunDiag.matchedRecord?.venue == "Nature")
        #expect(lecunDiag.matchedRecord?.workType == "journal-article")

        // CLI --json and MCP verify_citation must also surface matchedVenue and matchedWorkType
        let bibURL = tmp.appendingPathComponent("odeh.bib")
        try odehBib.write(to: bibURL, atomically: true, encoding: .utf8)
        let cliEnv = [
            "CITESTUDIO_CROSSREF_BASE_URL": replay.crossrefBaseURL.absoluteString,
            "CITESTUDIO_OPENALEX_BASE_URL": replay.openAlexBaseURL.absoluteString,
            "CITESTUDIO_CACHE_DIR": tmp.appendingPathComponent("cli_cache").path
        ]
        let cliRes = await CiteStudioCLI.run(
            arguments: ["CiteStudio", "--cli", "verify", bibURL.path, "--json", "--lang", "en"],
            environment: cliEnv
        )
        #expect(cliRes.exitCode == 0)
        let cliJSON = try #require(try JSONSerialization.jsonObject(with: Data(cliRes.stdout.utf8)) as? [String: Any])
        let cliEntries = try #require(cliJSON["entries"] as? [[String: Any]])
        #expect(cliEntries.first?["matchedVenue"] as? String == "Journal of the American Statistical Association")
        #expect(cliEntries.first?["matchedWorkType"] as? String == "article")

        let indexer = try LocalPDFIndexer(dbURL: tmp.appendingPathComponent("fts.sqlite"))
        let mcp = CiteStudioMCPServer(triangulator: triangulator, pdfIndexer: indexer, language: .en)
        let mcpReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 91,
            "method": "tools/call",
            "params": ["name": "verify_citation", "arguments": ["bibtex": odehBib]]
        ]
        let mcpRaw = try #require(await mcp.handleJSONLine(String(data: try JSONSerialization.data(withJSONObject: mcpReq), encoding: .utf8)!))
        let mcpRPC = try #require(try JSONSerialization.jsonObject(with: Data(mcpRaw.utf8)) as? [String: Any])
        let mcpContent = try #require((mcpRPC["result"] as? [String: Any])?["content"] as? [[String: Any]])
        let mcpText = try #require(mcpContent.first?["text"] as? String)
        let mcpPayload = try #require(try JSONSerialization.jsonObject(with: Data(mcpText.utf8)) as? [String: Any])
        #expect(mcpPayload["matchedVenue"] as? String == "Journal of the American Statistical Association")
        #expect(mcpPayload["matchedWorkType"] as? String == "article")

        // README.md and README.zh-CN.md must explicitly document that untagged book reviews (type: article / journal-article without Book Review: prefix) are treated as the original book when cited with the reviewer's author/year
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readmeEN = try String(contentsOf: repoRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let readmeZH = try String(contentsOf: repoRoot.appendingPathComponent("README.zh-CN.md"), encoding: .utf8)
        #expect(readmeEN.contains("Journal of the American Statistical Association"))
        #expect(readmeEN.contains("treated as the original"))
        #expect(readmeZH.contains("Journal of the American Statistical Association"))
        #expect(readmeZH.contains("当成原书"))
    }

    @Test("CR2: Title-search similarity threshold (0.78) boundary checks using strictly verbatim responses in Tests/Fixtures/recorded/")
    func cr2RecordedTitleSimilarityThresholdBoundaryTests() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_cr2_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let replay = try RecordedFixturesReplayServer()
        defer { replay.stop() }
        let transport = PublicScholarHTTPTransport(
            crossrefBaseURL: replay.crossrefBaseURL,
            openAlexBaseURL: replay.openAlexBaseURL,
            timeoutInterval: 2.0
        )
        let triangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("cr2_cache.sqlite"),
            transport: transport
        )

        // 1. End-to-end HTTP replay ABOVE 0.78 (similarity = 8/10 = 0.8000 >= 0.78):
        //    Recorded OpenAlex/Crossref response for query "The Art of Computer Programming, Volume 1: Fundamental Algorithms"
        //    contains MacLaren 1969 ("The Art of Computer Programming—Volume 1: Fundamental Algorithms (Donald E. Knuth)", type="article").
        let maclarenAbove = try #require(BibTeXParser.parseBibTeX("""
        @article{cr2_above_080, author = {MacLaren, M. Donald}, title = {The Art of Computer Programming, Volume 1: Fundamental Algorithms}, journal = {SIAM Review}, year = {1969}}
        """).first)
        let simAbove = ScholarTriangulator.normalizedTitleSimilarity(
            maclarenAbove.title,
            "The Art of Computer Programming—Volume 1: Fundamental Algorithms (Donald E. Knuth)"
        )
        #expect(abs(simAbove - 0.80) < 1e-9)
        let diagAbove = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: maclarenAbove, triangulator: triangulator)
        #expect(diagAbove.kind == .verified)
        #expect(diagAbove.matchedRecord?.venue == "SIAM Review")

        // 2. End-to-end HTTP replay BELOW 0.78 (similarity = 5/16 = 0.3125 < 0.78, but > 0.30):
        //    Recorded Crossref response for query "Recursive Causal Lattices for Zero-Shot Climate Forecasting"
        //    contains Jun Wang 2025 ("A zero-shot load forecasting method for extreme weather integrating causal learning and meta-learning",
        //    venue="Energy", type="journal-article"). Author ("Wang") and year (2025) match; ONLY similarity 0.3125 < 0.78 rejects it.
        //    NOTE on end-to-end HTTP replay coverage gap (现有录制测不到):
        //    PublicScholarHTTPTransport sends entry.title verbatim in the HTTP query URL, and Tests/Fixtures/recorded/ only has 2 recorded
        //    title queries; the sole candidate in (0.3125, 0.78) is Wells 1973 (0.6667), which is already blocked by type="book-review".
        //    Therefore, in end-to-end HTTP replay, non-book-review candidates in (0.3125, 0.78) are 现有录制测不到 (no synthetic body added).
        let wangBelow = try #require(BibTeXParser.parseBibTeX("""
        @article{cr2_below_03125, author = {Wang, Jun}, title = {Recursive Causal Lattices for Zero-Shot Climate Forecasting}, journal = {Energy}, year = {2025}}
        """).first)
        let simWang = ScholarTriangulator.normalizedTitleSimilarity(
            wangBelow.title,
            "A zero-shot load forecasting method for extreme weather integrating causal learning and meta-learning"
        )
        #expect(abs(simWang - 0.3125) < 1e-9)
        let diagWang = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: wangBelow, triangulator: triangulator)
        #expect(diagWang.kind == .ghostPaper)
        #expect(diagWang.kind != .metadataMismatch)

        let montetBelow = try #require(BibTeXParser.parseBibTeX("""
        @inproceedings{cr2_below_02353, author = {Montet, Fr{\\'e}d{\\'e}ric}, title = {Recursive Causal Lattices for Zero-Shot Climate Forecasting}, booktitle = {Conf}, year = {2025}}
        """).first)
        let diagMontet = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: montetBelow, triangulator: triangulator)
        #expect(diagMontet.kind == .ghostPaper)

        // 3. Direct candidate-matcher boundary check on verbatim recorded .raw JSON (10/13 = 0.7692 < 0.78 vs 11/13 = 0.8462 >= 0.78):
        let recDir = RecordedFixturesReplayServer.defaultRecordedDirectory
        let wakefieldRawData = try Data(contentsOf: recDir.appendingPathComponent("openalex_doi_10.1016_s0140-6736_97_11096-0_e1144ad9cb.raw"))
        let wakefieldJSON = try #require(try JSONSerialization.jsonObject(with: wakefieldRawData) as? [String: Any])
        let wakefieldRecord = try #require(PublicScholarHTTPTransport.parseOpenAlexWork(wakefieldJSON))

        let tenOfThirteenBib = try #require(BibTeXParser.parseBibTeX("""
        @article{cr2_0769, author = {Wakefield, Andrew J.}, title = {Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental}, year = {1998}}
        """).first)
        let sim0769 = ScholarTriangulator.normalizedTitleSimilarity(tenOfThirteenBib.title, wakefieldRecord.title)
        #expect(abs(sim0769 - (10.0 / 13.0)) < 1e-9) // 0.7692307... < 0.78
        #expect(!ScholarTriangulator.isMatchingTitleSearchCandidate(
            entry: tenOfThirteenBib,
            record: wakefieldRecord,
            upstreamWorkType: wakefieldRecord.workType
        ))

        let elevenOfThirteenBib = try #require(BibTeXParser.parseBibTeX("""
        @article{cr2_0846, author = {Wakefield, Andrew J.}, title = {Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder}, year = {1998}}
        """).first)
        let sim0846 = ScholarTriangulator.normalizedTitleSimilarity(elevenOfThirteenBib.title, wakefieldRecord.title)
        #expect(abs(sim0846 - (11.0 / 13.0)) < 1e-9) // 0.8461538... >= 0.78
        #expect(ScholarTriangulator.isMatchingTitleSearchCandidate(
            entry: elevenOfThirteenBib,
            record: wakefieldRecord,
            upstreamWorkType: wakefieldRecord.workType
        ))
    }
}

/// 合成（Synthetic）手写最小响应辅助服务器：仅用于测试 OpenAlex `{"results": [...]}` 包装格式分支。
private final class LoopbackOpenAlexResultsWrapperServer: @unchecked Sendable {
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
        _ = Darwin.listen(fd, 16)
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
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(cfd, &buf, buf.count)
            if n > 0 {
                let req = String(decoding: buf[0..<n], as: UTF8.self)
                let target = String((req.components(separatedBy: "\r\n").first ?? "").split(separator: " ").dropFirst().first ?? "")
                let (code, body): (Int, String)
                if target.hasPrefix("/crossref/") {
                    code = 404
                    body = #"{"status":"failed"}"#
                } else if target.contains("2001.00001") {
                    code = 200
                    body = #"{"results":[{"display_name":"Analytical Engine Notes","publication_year":2020,"doi":"https://doi.org/10.48550/arxiv.2001.00001","authorships":[{"raw_author_name":"Ada Lovelace"}],"primary_location":{"source":{"display_name":"Repository Host","type":"repository"}}}]}"#
                } else {
                    code = 200
                    body = #"{"results":[]}"#
                }
                let bytes = Array(body.utf8)
                let resp = Array("HTTP/1.1 \(code) OK\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8) + bytes
                resp.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        _ = Darwin.write(cfd, base, resp.count)
                    }
                }
            }
            Darwin.close(cfd)
        }
    }
}
