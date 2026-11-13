import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Oxford Archival Vellum & Fountain-Pen Ink Palette

public enum CiteStudioTheme {
    /// Archival vellum page (#FAF8F3)
    public static let vellumPage = Color(red: 250 / 255, green: 248 / 255, blue: 243 / 255)
    /// Pure manuscript sheet (#FFFFFF)
    public static let manuscriptSheet = Color.white
    /// Folio rail & audit drawer (#F1EEE6)
    public static let folioRail = Color(red: 241 / 255, green: 238 / 255, blue: 230 / 255)
    /// Bookbinding spine hairline (#DFDBD0)
    public static let spineRule = Color(red: 223 / 255, green: 219 / 255, blue: 208 / 255)
    /// Fountain-pen carbon ink (#191816)
    public static let carbonInk = Color(red: 25 / 255, green: 24 / 255, blue: 22 / 255)
    /// Marginalia grey (#68635A)
    public static let marginaliaGrey = Color(red: 104 / 255, green: 99 / 255, blue: 90 / 255)

    // Academic Semantic Signals
    /// Verified peer-reviewed source & section anchor (#1B4980)
    public static let oxfordNavy = Color(red: 27 / 255, green: 73 / 255, blue: 128 / 255)
    /// Ghost / hallucinated citation or Retracted block (#A62C2B)
    public static let exLibrisBurgundy = Color(red: 166 / 255, green: 44 / 255, blue: 43 / 255)
    /// arXiv -> published venue upgrade or metadata drift (#B86B14)
    public static let amberGold = Color(red: 184 / 255, green: 107 / 255, blue: 20 / 255)
    /// Local PDF provenance bound via BM25 (#1D6B48)
    public static let forestGreen = Color(red: 29 / 255, green: 107 / 255, blue: 72 / 255)
}

// MARK: - Bibliography & Inline Citation AST

public struct BibEntry: Identifiable, Sendable, Equatable, Codable {
    public var id: String { citeKey }
    public let citeKey: String
    public let entryType: String
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let venue: String?
    public let doi: String?
    public let arxivId: String?
    public let fields: [String: String]
    public let rawBibTeX: String

    public init(
        citeKey: String,
        entryType: String,
        title: String,
        authors: [String],
        year: Int?,
        venue: String?,
        doi: String? = nil,
        arxivId: String? = nil,
        fields: [String: String] = [:],
        rawBibTeX: String = ""
    ) {
        self.citeKey = citeKey
        self.entryType = entryType
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.doi = doi
        self.arxivId = arxivId
        self.fields = fields
        self.rawBibTeX = rawBibTeX
    }

    public var firstAuthorSurname: String {
        guard let first = authors.first else { return "Unknown" }
        if let commaIdx = first.firstIndex(of: ",") {
            return String(first[..<commaIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let tokens = first.split(separator: " ")
        return tokens.last.map(String.init) ?? first
    }
}

public struct InlineCitationRef: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let citeKey: String
    public let lineNumber: Int
    public let claimSentence: String

    public init(citeKey: String, lineNumber: Int, claimSentence: String) {
        self.id = "\(citeKey):L\(lineNumber)"
        self.citeKey = citeKey
        self.lineNumber = lineNumber
        self.claimSentence = claimSentence
    }
}

// MARK: - Citation Firewall Models

public enum FirewallVerdictKind: String, Sendable, Codable, CaseIterable {
    case verified = "Verified"
    case preprintUpgrade = "PreprintUpgrade"
    case metadataMismatch = "MetadataMismatch"
    case retracted = "Retracted"
    case ghostPaper = "GhostPaper"
    case orphanCite = "OrphanCite"

    public var isBlockingForMCP: Bool {
        switch self {
        case .ghostPaper, .retracted, .metadataMismatch:
            return true
        case .verified, .preprintUpgrade, .orphanCite:
            return false
        }
    }
}

public struct ScholarRecord: Sendable, Equatable, Codable {
    public let source: String  // Crossref | OpenAlex | SemanticScholar | arXiv | LocalCache
    public let title: String
    public let authors: [String]
    public let year: Int
    public let venue: String
    public let doi: String?
    public let isRetracted: Bool
    public let publishedUpgradeVenue: String?
    public let publishedUpgradeDOI: String?
    public let publishedUpgradeYear: Int?

    public init(
        source: String,
        title: String,
        authors: [String],
        year: Int,
        venue: String,
        doi: String? = nil,
        isRetracted: Bool = false,
        publishedUpgradeVenue: String? = nil,
        publishedUpgradeDOI: String? = nil,
        publishedUpgradeYear: Int? = nil
    ) {
        self.source = source
        self.title = title
        self.authors = authors
        self.year = year
        self.venue = venue
        self.doi = doi
        self.isRetracted = isRetracted
        self.publishedUpgradeVenue = publishedUpgradeVenue
        self.publishedUpgradeDOI = publishedUpgradeDOI
        self.publishedUpgradeYear = publishedUpgradeYear
    }

    public var firstAuthorSurname: String {
        guard let first = authors.first else { return "" }
        if let commaIdx = first.firstIndex(of: ",") {
            return String(first[..<commaIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return first.split(separator: " ").last.map(String.init) ?? first
    }
}

public struct CitationDiagnostic: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let citeKey: String
    public let kind: FirewallVerdictKind
    public let headline: String
    public let detail: String
    public let matchedRecord: ScholarRecord?
    public let upgradedBibTeX: String?
    public let lineNumbers: [Int]
    public let hasLocalPDFEvidence: Bool

    public init(
        citeKey: String,
        kind: FirewallVerdictKind,
        headline: String,
        detail: String,
        matchedRecord: ScholarRecord? = nil,
        upgradedBibTeX: String? = nil,
        lineNumbers: [Int] = [],
        hasLocalPDFEvidence: Bool = false
    ) {
        self.id = "\(citeKey)-\(kind.rawValue)"
        self.citeKey = citeKey
        self.kind = kind
        self.headline = headline
        self.detail = detail
        self.matchedRecord = matchedRecord
        self.upgradedBibTeX = upgradedBibTeX
        self.lineNumbers = lineNumbers
        self.hasLocalPDFEvidence = hasLocalPDFEvidence
    }
}

// MARK: - Local PDF Provenance & SyncTeX Models

public struct PDFPassageEvidence: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let citeKey: String
    public let pdfFilename: String
    public let pageNumber: Int
    public let rectX: Double
    public let rectY: Double
    public let rectWidth: Double
    public let rectHeight: Double
    public let verbatimSnippet: String
    public let confidenceScore: Double

    public init(
        citeKey: String,
        pdfFilename: String,
        pageNumber: Int,
        boundingBox: CGRect,
        verbatimSnippet: String,
        confidenceScore: Double
    ) {
        self.id = "\(citeKey)-p\(pageNumber)-\(Int(boundingBox.origin.y))"
        self.citeKey = citeKey
        self.pdfFilename = pdfFilename
        self.pageNumber = pageNumber
        self.rectX = Double(boundingBox.origin.x)
        self.rectY = Double(boundingBox.origin.y)
        self.rectWidth = Double(boundingBox.size.width)
        self.rectHeight = Double(boundingBox.size.height)
        self.verbatimSnippet = verbatimSnippet
        self.confidenceScore = confidenceScore
    }

    public var boundingBox: CGRect {
        CGRect(x: rectX, y: rectY, width: rectWidth, height: rectHeight)
    }
}

public struct SyncTeXAnchor: Sendable, Equatable, Codable {
    public let sourceFile: String
    public let line: Int
    public let page: Int
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(sourceFile: String, line: Int, page: Int, x: Double, y: Double, width: Double, height: Double) {
        self.sourceFile = sourceFile
        self.line = line
        self.page = page
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - Writing Quality Linter & Compiler Models

public struct WritingLintFinding: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let ruleId: String
    public let category: String  // anti-ai | punctuation | cross-ref | acronym
    public let lineNumber: Int
    public let matchedText: String
    public let suggestion: String

    public init(ruleId: String, category: String, lineNumber: Int, matchedText: String, suggestion: String) {
        self.id = "\(ruleId)-L\(lineNumber)-\(matchedText.prefix(12))"
        self.ruleId = ruleId
        self.category = category
        self.lineNumber = lineNumber
        self.matchedText = matchedText
        self.suggestion = suggestion
    }
}

public struct CompilerDiagnostic: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let file: String
    public let line: Int
    public let message: String
    public let isError: Bool

    public init(file: String, line: Int, message: String, isError: Bool) {
        self.id = "\(file):\(line):\(message.prefix(24))"
        self.file = file
        self.line = line
        self.message = message
        self.isError = isError
    }
}

public struct CompileResult: Sendable, Equatable {
    public let engine: String  // tectonic | typst
    public let succeeded: Bool
    public let pdfURL: URL?
    public let synctexURL: URL?
    public let durationMs: Int
    public let diagnostics: [CompilerDiagnostic]

    public init(
        engine: String,
        succeeded: Bool,
        pdfURL: URL?,
        synctexURL: URL?,
        durationMs: Int,
        diagnostics: [CompilerDiagnostic]
    ) {
        self.engine = engine
        self.succeeded = succeeded
        self.pdfURL = pdfURL
        self.synctexURL = synctexURL
        self.durationMs = durationMs
        self.diagnostics = diagnostics
    }
}
