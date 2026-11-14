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

    @Test("C1 + Item 10: Real URLSession HTTP transport handles offline -> online, 429, 500, timeout, and malformed JSON without caching")
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

    @Test("Item 2: Confirmed-not-found TTL is shorter than found TTL, expired rows re-fetch, and clearCache purges rows")
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

    @Test("Row 8: Full 12-entry test.bib matrix over real URLSession HTTP transport matches expected M0 verdicts")
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
            "real_nodoi": .metadataMismatch, // C5 (scheduled for M1 per citestudio.md Row 8)
            "fake_nodoi": .ghostPaper,
            "retracted_seralini": .retracted,
            "retracted_wakefield": .retracted
        ]

        let entries = BibTeXParser.parseBibTeX(testBib)
        #expect(entries.count == 12)
        for entry in entries {
            let diag = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: entry, triangulator: triangulator)
            #expect(diag.kind == expected[entry.citeKey], "Mismatch on \(entry.citeKey): got \(diag.kind)")
        }
    }
}
