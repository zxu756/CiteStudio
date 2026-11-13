import CoreGraphics
import Foundation
import Testing
@testable import CiteStudioCore

@Suite("CiteStudio Citation Firewall, PDFKit BM25 Provenance, SyncTeX & MCP Tests")
struct CiteStudioCoreTests {

    @Test("BibTeXParser parses .bib stanzas and extracts LaTeX + Typst inline citations")
    func parseBibAndInlineRefs() {
        let bib = """
        @inproceedings{vaswani2017attention,
          title = {Attention Is All You Need},
          author = {Vaswani, Ashish and Shazeer, Noam},
          booktitle = {NeurIPS},
          year = {2017},
          doi = {https://doi.org/10.5555/3295222.3295349}
        }
        """
        let entries = BibTeXParser.parseBibTeX(bib)
        #expect(entries.count == 1)
        #expect(entries[0].citeKey == "vaswani2017attention")
        #expect(entries[0].firstAuthorSurname == "Vaswani")
        #expect(entries[0].doi == "10.5555/3295222.3295349")

        let doc = """
        % ignored comment \\cite{commented_out}
        Transformers scale well \\citep{vaswani2017attention, dao2022flashattention}.
        In Typst syntax we also cite @kwon2023vllm directly.
        """
        let refs = BibTeXParser.extractInlineCitations(from: doc)
        let keys = refs.map(\.citeKey)
        #expect(keys == ["vaswani2017attention", "dao2022flashattention", "kwon2023vllm"])
        #expect(refs[0].lineNumber == 2)
        #expect(refs[2].lineNumber == 3)
    }

    @Test("CitationDiagnosticsEngine classifies Verified, PreprintUpgrade, MetadataMismatch, Retracted, and GhostPaper")
    func fiveClassFirewallDiagnostics() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_fw_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let transport = FixtureScholarTransport(recordsByKey: [
            "real2023": ScholarRecord(
                source: "Crossref",
                title: "PagedAttention",
                authors: ["Woosuk Kwon"],
                year: 2023,
                venue: "SOSP",
                doi: "10.1145/3600006.3613165"
            ),
            "preprint2022": ScholarRecord(
                source: "OpenAlex",
                title: "FlashAttention",
                authors: ["Tri Dao"],
                year: 2022,
                venue: "NeurIPS 2022",
                publishedUpgradeVenue: "NeurIPS 2022",
                publishedUpgradeDOI: "10.5555/neurips.2022",
                publishedUpgradeYear: 2022
            ),
            "wrongyear": ScholarRecord(
                source: "Crossref",
                title: "ResNet",
                authors: ["Kaiming He"],
                year: 2016,
                venue: "CVPR"
            ),
            "retracted2021": ScholarRecord(
                source: "Crossref",
                title: "Flawed Benchmark",
                authors: ["R. Roe"],
                year: 2021,
                venue: "J. Irreproducible",
                isRetracted: true
            )
        ])

        let triangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("cache.sqlite"),
            transport: transport
        )

        let bib = """
        @inproceedings{real2023, title={PagedAttention}, author={Kwon, Woosuk}, booktitle={SOSP}, year={2023}}
        @article{preprint2022, title={FlashAttention}, author={Dao, Tri}, journal={arXiv preprint arXiv:2205.14135}, year={2022}}
        @inproceedings{wrongyear, title={ResNet}, author={He, Kaiming}, booktitle={CVPR}, year={2024}}
        @article{retracted2021, title={Flawed Benchmark}, author={Roe, R.}, journal={J. Irreproducible}, year={2021}}
        @article{ghost2026, title={Fabricated Quantum Attention}, author={Nobody, X.}, journal={FakeConf}, year={2026}}
        """
        let tex = "Claims \\cite{real2023,preprint2022,wrongyear,retracted2021,ghost2026,missing_in_bib}."

        let diags = await CitationDiagnosticsEngine.auditManuscript(
            manuscript: tex,
            bibText: bib,
            triangulator: triangulator
        )
        let byKey = Dictionary(uniqueKeysWithValues: diags.map { ($0.citeKey, $0) })
        #expect(byKey["real2023"]?.kind == .verified)
        #expect(byKey["preprint2022"]?.kind == .preprintUpgrade)
        #expect(byKey["preprint2022"]?.upgradedBibTeX?.contains("NeurIPS 2022") == true)
        #expect(byKey["wrongyear"]?.kind == .metadataMismatch)
        #expect(byKey["retracted2021"]?.kind == .retracted)
        #expect(byKey["ghost2026"]?.kind == .ghostPaper)
        #expect(byKey["missing_in_bib"]?.kind == .orphanCite)
    }

    @Test("CiteStudioMCPServer enforces ERR_UNVERIFIED_CITATION hardware gate before touching .bib")
    func mcpHardwareFirewallGate() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_mcp_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bibFile = tmp.appendingPathComponent("refs.bib")
        try "".write(to: bibFile, atomically: true, encoding: .utf8)

        let transport = FixtureScholarTransport(recordsByKey: [
            "verified2024": ScholarRecord(
                source: "Crossref",
                title: "Verified Systems Paper",
                authors: ["Alice Chen"],
                year: 2024,
                venue: "OSDI 2024",
                doi: "10.5555/osdi.2024.1"
            )
        ])
        let triangulator = try ScholarTriangulator(
            cacheDBPath: tmp.appendingPathComponent("cache.sqlite"),
            transport: transport
        )
        let indexer = try LocalPDFIndexer(dbURL: tmp.appendingPathComponent("fts.sqlite"))
        let server = CiteStudioMCPServer(triangulator: triangulator, pdfIndexer: indexer)

        // 1. Attempt to inject hallucinated reference -> MUST be rejected with ERR_UNVERIFIED_CITATION
        let ghostReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "add_verified_bibtex",
                "arguments": [
                    "bib_file": bibFile.path,
                    "bibtex": "@article{hallucinated99, title={Nonexistent LLM Dream}, author={Bot, A.}, year={2026}}"
                ]
            ]
        ]
        let ghostLine = String(data: try JSONSerialization.data(withJSONObject: ghostReq), encoding: .utf8)!
        let ghostResp = await server.handleJSONLine(ghostLine) ?? ""
        #expect(ghostResp.contains("ERR_UNVERIFIED_CITATION"))
        let bibAfterGhost = try String(contentsOf: bibFile, encoding: .utf8)
        #expect(bibAfterGhost.isEmpty)

        // 2. Inject verified reference -> MUST succeed and write to refs.bib
        let okReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "add_verified_bibtex",
                "arguments": [
                    "bib_file": bibFile.path,
                    "bibtex": "@inproceedings{verified2024, title={Verified Systems Paper}, author={Chen, Alice}, booktitle={OSDI}, year={2024}}"
                ]
            ]
        ]
        let okLine = String(data: try JSONSerialization.data(withJSONObject: okReq), encoding: .utf8)!
        let okResp = await server.handleJSONLine(okLine) ?? ""
        #expect(okResp.contains("APPENDED_VERIFIED"))
        let bibAfterOK = try String(contentsOf: bibFile, encoding: .utf8)
        #expect(bibAfterOK.contains("verified2024"))
    }

    @Test("LocalPDFIndexer + ClaimEvidenceMatcher extract PDFKit bounding boxes and match via SQLite FTS5 BM25")
    func pdfKitBM25Provenance() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_pdf_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pdfURL = tmp.appendingPathComponent("flashattention.pdf")
        try LocalPDFIndexer.writeSyntheticAcademicPDF(
            to: pdfURL,
            pages: [
                [
                    "Background on standard quadratic self-attention memory footprint across long context windows.",
                    "Tiling attention blocks in fast on-chip SRAM avoids materializing the quadratic matrix in HBM memory."
                ]
            ]
        )

        let indexer = try LocalPDFIndexer(dbURL: tmp.appendingPathComponent("pdf_fts.sqlite"))
        let count = indexer.indexPDF(url: pdfURL, citeKey: "dao2022flashattention")
        #expect(count >= 1)

        let match = ClaimEvidenceMatcher.matchClaim(
            sentence: "Tiling blocks inside SRAM avoids HBM materialization \\cite{dao2022flashattention}.",
            citeKey: "dao2022flashattention",
            indexer: indexer
        )
        #expect(match != nil)
        #expect(match?.pageNumber == 1)
        #expect(match?.verbatimSnippet.contains("SRAM") == true)
        #expect((match?.boundingBox.width ?? 0) > 50)
    }

    @Test("SyncTeXMapper bidirectionally maps source lines and PDF coordinates, and Tectonic compiles real PDF")
    func syncTeXAndTectonicCompilation() throws {
        let sampleSyncTeX = """
        SyncTeX Version:1
        Input:1:/tmp/paper/main.tex
        Content:
        {1
        [1,1:4718592,4718592:30146560,42205184,0
        h1,12:4718592,15728640:19660800,786432,0
        h1,28:4718592,26214400:19660800,786432,0
        ]
        }
        """
        let mapper = SyncTeXMapper.parse(synctexText: sampleSyncTeX)
        let fwd = mapper.forwardLookup(sourceFile: "main.tex", line: 13)
        #expect(fwd?.line == 12)
        #expect(fwd?.page == 1)

        let inv = mapper.inverseLookup(page: 1, point: CGPoint(x: 72, y: 400))
        #expect(inv?.line == 28)

        if TectonicRunner.detectBinary() != nil {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_tec_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let texURL = tmp.appendingPathComponent("hello.tex")
            try """
            \\documentclass{article}
            \\begin{document}
            Hello CiteStudio Tectonic SyncTeX Verification.
            \\end{document}
            """.write(to: texURL, atomically: true, encoding: .utf8)

            let res = TectonicRunner.compile(texFile: texURL, outputDirectory: tmp)
            #expect(res.succeeded)
            #expect(res.pdfURL != nil)
            #expect(res.synctexURL != nil)
        }
    }

    @Test("WritingQualityLinter catches AI cliches, em-dash density, uncited floats, and undefined acronyms")
    func writingQualityLinterRules() {
        let sample = """
        It is worth noting that KVCP plays a pivotal role --- first --- and second in decoding.
        \\begin{figure}
        \\label{fig:orphan_plot}
        \\end{figure}
        """
        let findings = WritingQualityLinter.lint(manuscript: sample)
        let ruleIds = Set(findings.map(\.ruleId))
        #expect(ruleIds.contains("anti-ai-vocab"))
        #expect(ruleIds.contains("polish-emdash-density"))
        #expect(ruleIds.contains("polish-undefined-acronym"))
        #expect(ruleIds.contains("polish-uncited-float"))
    }

    @Test("CiteStudioScreenshotExporter renders 2x Retina screenshots (EN + ZH) cleanly")
    @MainActor
    func exportsScreenshots() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_shots_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try CiteStudioScreenshotExporter.exportMarketingScreenshots(to: tmp, language: .en)
        try CiteStudioScreenshotExporter.exportMarketingScreenshots(to: tmp, language: .zhHans)

        let mainEN = try Data(contentsOf: tmp.appendingPathComponent("screenshot-main.png"))
        let fwEN = try Data(contentsOf: tmp.appendingPathComponent("screenshot-firewall.png"))
        let mainZH = try Data(contentsOf: tmp.appendingPathComponent("screenshot-main-zh.png"))
        let fwZH = try Data(contentsOf: tmp.appendingPathComponent("screenshot-firewall-zh.png"))
        #expect(mainEN.count > 40_000)
        #expect(fwEN.count > 40_000)
        #expect(mainZH.count > 40_000)
        #expect(fwZH.count > 40_000)
    }

    @Test("AppLocalizer resolves --lang CLI flag, UserDefaults persistence, Chinese locale auto-detection, and live toggle")
    @MainActor
    func appLocalizerResolutionAndToggle() throws {
        let suiteName = "CiteStudioLocalizerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "io.github.zxu756.CiteStudio.test.language"

        // 1. Auto-detect Chinese system locale when no CLI flag or UserDefaults override exists
        let zhAuto = AppLocalizer(
            arguments: ["CiteStudio"],
            userDefaults: defaults,
            preferredLanguages: ["zh-Hans-CN", "en-US"],
            defaultsKey: key
        )
        #expect(zhAuto.language == .zhHans)
        #expect(zhAuto.isChinese)
        #expect(zhAuto.L("Verify Citations", "核验引文") == "核验引文")

        // 2. Live toggle persists to UserDefaults
        zhAuto.toggle()
        #expect(zhAuto.language == .en)
        #expect(defaults.string(forKey: key) == "en")
        zhAuto.toggle()
        #expect(zhAuto.language == .zhHans)
        #expect(defaults.string(forKey: key) == "zh-Hans")

        // 3. Stored UserDefaults wins over non-Chinese locale
        defaults.set("zh-Hans", forKey: key)
        let fromDefaults = AppLocalizer(
            arguments: ["CiteStudio"],
            userDefaults: defaults,
            preferredLanguages: ["en-US"],
            defaultsKey: key
        )
        #expect(fromDefaults.language == .zhHans)

        // 4. CLI --lang flag overrides UserDefaults and system locale
        let cliOverride = AppLocalizer(
            arguments: ["CiteStudio", "--lang", "en"],
            userDefaults: defaults,
            preferredLanguages: ["zh-Hant-TW"],
            defaultsKey: key
        )
        #expect(cliOverride.language == .en)

        let cliZhOverride = AppLocalizer(
            arguments: ["CiteStudio", "--lang=zh"],
            userDefaults: defaults,
            preferredLanguages: ["en-US"],
            defaultsKey: key
        )
        #expect(cliZhOverride.language == .zhHans)
    }
}
