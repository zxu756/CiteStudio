import AppKit
import CoreGraphics
import Foundation
import PDFKit
import SwiftUI

public enum CiteStudioRightTab: String, CaseIterable, Identifiable, Sendable {
    case pdfPreview = "PDF & Provenance"
    case firewallDrawer = "Citation Firewall & Lint"

    public var id: String { rawValue }

    public func label(in language: AppLanguage) -> String {
        switch self {
        case .pdfPreview:
            return language == .zhHans ? "PDF 预览与原文溯源" : "PDF & Provenance"
        case .firewallDrawer:
            return language == .zhHans ? "引文防火墙与行文体检" : "Citation Firewall & Lint"
        }
    }
}

/// Deterministic offline transport used by preview fixtures and unit tests.
public struct FixtureScholarTransport: ScholarLookupTransport {
    public let recordsByKey: [String: ScholarRecord]

    public init(recordsByKey: [String: ScholarRecord]) {
        self.recordsByKey = recordsByKey
    }

    public func lookup(entry: BibEntry) async throws -> ScholarRecord? {
        recordsByKey[entry.citeKey]
    }
}

@MainActor
public final class CiteStudioWorkspaceSession: ObservableObject {
    @Published public var projectTitle: String
    @Published public var manuscriptFilename: String
    @Published public var manuscriptText: String
    @Published public var bibText: String
    @Published public var bibEntries: [BibEntry]
    @Published public var inlineCitations: [InlineCitationRef]
    @Published public var diagnostics: [CitationDiagnostic]
    @Published public var lintFindings: [WritingLintFinding]
    @Published public var selectedCiteKey: String?
    @Published public var activeEvidence: PDFPassageEvidence?
    @Published public var rightTab: CiteStudioRightTab
    @Published public var compiledPDFDocument: PDFDocument?
    @Published public var compilerStatusText: String
    @Published public var activeSourceLine: Int = 14
    public let isSnapshotMode: Bool

    private var workingDirectory: URL?
    private var triangulator: ScholarTriangulator?
    private var pdfIndexer: LocalPDFIndexer?

    public init(
        projectTitle: String = "Speculative KV-Cache Compression",
        manuscriptFilename: String = "main.tex",
        manuscriptText: String = CiteStudioWorkspaceSession.sampleManuscript,
        bibText: String = CiteStudioWorkspaceSession.sampleBibTeX,
        rightTab: CiteStudioRightTab = .pdfPreview,
        isSnapshotMode: Bool = false
    ) {
        self.projectTitle = projectTitle
        self.manuscriptFilename = manuscriptFilename
        self.manuscriptText = manuscriptText
        self.bibText = bibText
        self.bibEntries = BibTeXParser.parseBibTeX(bibText)
        self.inlineCitations = BibTeXParser.extractInlineCitations(from: manuscriptText)
        self.diagnostics = []
        self.lintFindings = WritingQualityLinter.lint(manuscript: manuscriptText)
        self.selectedCiteKey = "dao2022flashattention"
        self.activeEvidence = nil
        self.rightTab = rightTab
        self.compilerStatusText = TectonicRunner.detectBinary() != nil
            ? "Tectonic --synctex ready"
            : "Tectonic not detected"
        self.isSnapshotMode = isSnapshotMode
    }

    public var ghostOrRetractedKeys: Set<String> {
        Set(diagnostics.filter { $0.kind == .ghostPaper || $0.kind == .retracted }.map(\.citeKey))
    }

    public var upgradeAvailableKeys: Set<String> {
        Set(diagnostics.filter { $0.kind == .preprintUpgrade }.map(\.citeKey))
    }

    public var verifiedCount: Int {
        diagnostics.filter { $0.kind == .verified || $0.kind == .preprintUpgrade }.count
    }

    public var blockedCount: Int {
        diagnostics.filter(\.kind.isBlockingForMCP).count
    }

    public var outlineSections: [(line: Int, title: String)] {
        var out: [(Int, String)] = []
        let regex = try! NSRegularExpression(pattern: #"\\(?:sub)*section\*?\{([^}]+)\}"#)
        for (i, line) in manuscriptText.components(separatedBy: .newlines).enumerated() {
            let ns = line as NSString
            if let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                out.append((i + 1, ns.substring(with: m.range(at: 1))))
            }
        }
        return out
    }

    public func refreshAudit() async {
        bibEntries = BibTeXParser.parseBibTeX(bibText)
        inlineCitations = BibTeXParser.extractInlineCitations(from: manuscriptText)
        lintFindings = WritingQualityLinter.lint(manuscript: manuscriptText)

        if triangulator == nil {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("CiteStudio", isDirectory: true)
            triangulator = try? ScholarTriangulator(cacheDBPath: support.appendingPathComponent("scholar_cache.sqlite"))
            pdfIndexer = try? LocalPDFIndexer(dbURL: support.appendingPathComponent("pdf_fts5.sqlite"))
        }
        if let triangulator {
            let pdfKeys = pdfIndexer?.indexedCiteKeys() ?? []
            diagnostics = await CitationDiagnosticsEngine.auditManuscript(
                manuscript: manuscriptText,
                bibText: bibText,
                triangulator: triangulator,
                indexedPDFKeys: pdfKeys
            )
        }
    }

    public func applyPreprintUpgrade(for diagnostic: CitationDiagnostic) {
        guard let upgraded = diagnostic.upgradedBibTeX,
              let entry = bibEntries.first(where: { $0.citeKey == diagnostic.citeKey }),
              !entry.rawBibTeX.isEmpty else { return }
        bibText = bibText.replacingOccurrences(of: entry.rawBibTeX, with: upgraded)
        bibEntries = BibTeXParser.parseBibTeX(bibText)
    }

    public func compileLivePDF() {
        let dir = workingDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("CiteStudioLive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let texURL = dir.appendingPathComponent(manuscriptFilename)
        let bibURL = dir.appendingPathComponent("references.bib")
        try? manuscriptText.write(to: texURL, atomically: true, encoding: .utf8)
        try? bibText.write(to: bibURL, atomically: true, encoding: .utf8)

        let res = TectonicRunner.compile(texFile: texURL, outputDirectory: dir)
        if res.succeeded, let pdfURL = res.pdfURL {
            compiledPDFDocument = PDFDocument(url: pdfURL)
            compilerStatusText = "Compiled via \(res.engine) in \(res.durationMs) ms"
        } else {
            let firstErr = res.diagnostics.first?.message ?? "Compilation failed"
            compilerStatusText = "\(res.engine): \(firstErr)"
        }
    }

    public func localizedCompilerStatus(in language: AppLanguage) -> String {
        guard language == .zhHans else { return compilerStatusText }
        if compilerStatusText == "Tectonic --synctex ready" {
            return "Tectonic --synctex 已就绪"
        }
        if compilerStatusText == "Tectonic not detected" {
            return "未检测到本地 Tectonic"
        }
        if compilerStatusText == "Tectonic 0.15 (--synctex) · 318 ms" {
            return "Tectonic 0.15 (--synctex) · 耗时 318 ms"
        }
        if compilerStatusText.hasPrefix("Compiled via ") {
            return compilerStatusText
                .replacingOccurrences(of: "Compiled via ", with: "已通过 ")
                .replacingOccurrences(of: " in ", with: " 编译，耗时 ")
        }
        if compilerStatusText.contains("Compilation failed") {
            return compilerStatusText.replacingOccurrences(of: "Compilation failed", with: "编译失败")
        }
        return compilerStatusText
    }

    // MARK: - Deterministic Preview & Screenshot Fixture

    public static func preview(rightTab: CiteStudioRightTab = .pdfPreview) -> CiteStudioWorkspaceSession {
        let session = CiteStudioWorkspaceSession(rightTab: rightTab, isSnapshotMode: true)
        session.compilerStatusText = "Tectonic 0.15 (--synctex) · 318 ms"

        let vaswaniRec = ScholarRecord(
            source: "Crossref",
            title: "Attention Is All You Need",
            authors: ["Ashish Vaswani", "Noam Shazeer", "Niki Parmar"],
            year: 2017,
            venue: "Advances in Neural Information Processing Systems (NeurIPS)",
            doi: "10.5555/3295222.3295349"
        )
        let daoRec = ScholarRecord(
            source: "OpenAlex",
            title: "FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness",
            authors: ["Tri Dao", "Daniel Y. Fu", "Stefano Ermon", "Atri Rudra", "Christopher Re"],
            year: 2022,
            venue: "NeurIPS 2022",
            doi: "10.48550/arxiv.2205.14135",
            publishedUpgradeVenue: "NeurIPS 2022",
            publishedUpgradeDOI: "10.5555/3586589.3587785",
            publishedUpgradeYear: 2022
        )
        let kwonRec = ScholarRecord(
            source: "Crossref",
            title: "Efficient Memory Management for Large Language Model Serving with PagedAttention",
            authors: ["Woosuk Kwon", "Zhuohan Li", "Siyuan Zhuang", "Ion Stoica"],
            year: 2023,
            venue: "ACM SOSP 2023",
            doi: "10.1145/3600006.3613165"
        )

        session.diagnostics = [
            CitationDiagnostic(
                citeKey: "vaswani2017attention",
                kind: .verified,
                headline: "Verified via Crossref (NeurIPS, 2017)",
                detail: "DOI 10.5555/3295222.3295349 · Local PDF indexed",
                headlineZh: "已通过 Crossref 核验（NeurIPS, 2017）",
                detailZh: "DOI 10.5555/3295222.3295349 · 本地 PDF 已建索引",
                matchedRecord: vaswaniRec,
                lineNumbers: [9],
                hasLocalPDFEvidence: true
            ),
            CitationDiagnostic(
                citeKey: "dao2022flashattention",
                kind: .preprintUpgrade,
                headline: "Upgrade available: NeurIPS 2022",
                detail: "Cited as arXiv:2205.14135; official camera-ready published in NeurIPS 2022.",
                headlineZh: "可升级正式版：NeurIPS 2022",
                detailZh: "当前引用 arXiv:2205.14135 预印本；官方正式版已发表于 NeurIPS 2022。",
                matchedRecord: daoRec,
                upgradedBibTeX: BibTeXParser.formatUpgradedBibTeX(
                    entry: session.bibEntries[1],
                    record: daoRec
                ),
                lineNumbers: [12],
                hasLocalPDFEvidence: true
            ),
            CitationDiagnostic(
                citeKey: "kwon2023vllm",
                kind: .verified,
                headline: "Verified via Crossref (ACM SOSP, 2023)",
                detail: "DOI 10.1145/3600006.3613165 · Local PDF indexed",
                headlineZh: "已通过 Crossref 核验（ACM SOSP, 2023）",
                detailZh: "DOI 10.1145/3600006.3613165 · 本地 PDF 已建索引",
                matchedRecord: kwonRec,
                lineNumbers: [13],
                hasLocalPDFEvidence: true
            ),
            CitationDiagnostic(
                citeKey: "smith2025hallucinated",
                kind: .ghostPaper,
                headline: "Ghost citation blocked (smith2025hallucinated)",
                detail: "Zero matches in Crossref, OpenAlex, or arXiv. MCP gate returns ERR_UNVERIFIED_CITATION.",
                headlineZh: "已拦截幽灵引用 (smith2025hallucinated)",
                detailZh: "Crossref、OpenAlex 与 arXiv 均无匹配记录；MCP 写入门禁返回 ERR_UNVERIFIED_CITATION。",
                matchedRecord: nil,
                lineNumbers: [16],
                hasLocalPDFEvidence: false
            )
        ]

        session.activeEvidence = PDFPassageEvidence(
            citeKey: "dao2022flashattention",
            pdfFilename: "dao2022_flashattention.pdf",
            pageNumber: 4,
            boundingBox: CGRect(x: 72, y: 418, width: 468, height: 54),
            verbatimSnippet: "FlashAttention uses tiling to prevent materialization of the N x N attention matrix in slow GPU HBM, achieving a 3.1x wall-clock speedup on GPT-2.",
            confidenceScore: 0.94
        )
        return session
    }

    public static let sampleManuscript = """
    \\documentclass[11pt]{article}
    \\usepackage[margin=1in]{geometry}
    \\title{Sub-Linear KV-Cache Compression via IO-Aware Block Paging}
    \\author{Systems \\& Verification Lab}
    \\begin{document}
    \\maketitle

    \\section{Introduction}
    Autoregressive decoding in Transformer models \\cite{vaswani2017attention} is bottlenecked by memory bandwidth rather than arithmetic throughput.

    \\section{IO-Aware Tiling and Block Paging}
    Tiling attention blocks inside SRAM avoids materializing intermediate matrices in HBM \\cite{dao2022flashattention}.
    Non-contiguous virtual block tables eliminate external KV fragmentation \\cite{kwon2023vllm}.

    \\section{ Ablation and Unverified Claim Check}
    It is worth noting that speculative zero-entropy tensor folding \\cite{smith2025hallucinated} plays a pivotal role in latency reduction.
    \\begin{figure}[h]
    \\caption{Decode throughput across batch sizes.}
    \\label{fig:unreferenced_throughput}
    \\end{figure}
    \\end{document}
    """

    public static let sampleBibTeX = """
    @inproceedings{vaswani2017attention,
      title = {Attention Is All You Need},
      author = {Vaswani, Ashish and Shazeer, Noam and Parmar, Niki},
      booktitle = {Advances in Neural Information Processing Systems},
      year = {2017},
      doi = {10.5555/3295222.3295349}
    }

    @article{dao2022flashattention,
      title = {FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness},
      author = {Dao, Tri and Fu, Daniel Y. and Ermon, Stefano and Rudra, Atri and Re, Christopher},
      journal = {arXiv preprint arXiv:2205.14135},
      year = {2022}
    }

    @inproceedings{kwon2023vllm,
      title = {Efficient Memory Management for Large Language Model Serving with PagedAttention},
      author = {Kwon, Woosuk and Li, Zhuohan and Zhuang, Siyuan and Stoica, Ion},
      booktitle = {ACM SOSP},
      year = {2023},
      doi = {10.1145/3600006.3613165}
    }

    @article{smith2025hallucinated,
      title = {Zero-Entropy Quantum KV-Cache Folding in Sub-Millisecond Regimes},
      author = {Smith, J. and Doe, A.},
      journal = {Journal of Synthetic Preprints},
      year = {2025},
      doi = {10.9999/fake.2025.00001}
    }
    """
}

public enum CiteStudioScreenshotExporter {
    @MainActor
    public static func exportMarketingScreenshots(to directory: URL, language: AppLanguage = .en) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let localizer = AppLocalizer(language: language)
        let suffix = language == .zhHans ? "-zh" : ""

        let mainSession = CiteStudioWorkspaceSession.preview(rightTab: .pdfPreview)
        let mainView = StudioThreePaneView(session: mainSession, localizer: localizer)
            .frame(width: 1260, height: 760)
            .environment(\.colorScheme, .light)
        try renderPNG(view: mainView, to: directory.appendingPathComponent("screenshot-main\(suffix).png"))

        let firewallSession = CiteStudioWorkspaceSession.preview(rightTab: .firewallDrawer)
        let firewallView = StudioThreePaneView(session: firewallSession, localizer: localizer)
            .frame(width: 1260, height: 760)
            .environment(\.colorScheme, .light)
        try renderPNG(view: firewallView, to: directory.appendingPathComponent("screenshot-firewall\(suffix).png"))
    }

    @MainActor
    public static func renderPNG<V: View>(view: V, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        renderer.isOpaque = true
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CiteStudio.ScreenshotExporter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to rasterize CiteStudio view to 2x PNG"
            ])
        }
        try png.write(to: url, options: .atomic)
    }
}
