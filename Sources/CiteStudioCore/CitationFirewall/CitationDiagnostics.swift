import Foundation

/// Runs 5-class scholarly citation firewall checks across `.bib` entries and manuscript inline citations.
public enum CitationDiagnosticsEngine {

    public static func evaluateSingleEntry(
        entry: BibEntry,
        triangulator: ScholarTriangulator,
        lineNumbers: [Int] = [],
        hasLocalPDF: Bool = false
    ) async -> CitationDiagnostic {
        guard let record = await triangulator.verify(entry) else {
            return CitationDiagnostic(
                citeKey: entry.citeKey,
                kind: .ghostPaper,
                headline: "Unverified / hallucinated reference (\(entry.citeKey))",
                detail: "No matching DOI or title found in Crossref, OpenAlex, or arXiv. Blocked by Citation Firewall.",
                matchedRecord: nil,
                upgradedBibTeX: nil,
                lineNumbers: lineNumbers,
                hasLocalPDFEvidence: hasLocalPDF
            )
        }

        if record.isRetracted {
            return CitationDiagnostic(
                citeKey: entry.citeKey,
                kind: .retracted,
                headline: "Retracted publication (\(entry.citeKey))",
                detail: "Indexed by \(record.source) with an official retraction notice (\(record.venue), \(record.year)).",
                matchedRecord: record,
                upgradedBibTeX: nil,
                lineNumbers: lineNumbers,
                hasLocalPDFEvidence: hasLocalPDF
            )
        }

        // Check first-author surname & publication year consistency
        let bibSurname = entry.firstAuthorSurname.lowercased()
        let recSurname = record.firstAuthorSurname.lowercased()
        let authorMismatch = !bibSurname.isEmpty && !recSurname.isEmpty && bibSurname != "unknown" && !recSurname.contains(bibSurname) && !bibSurname.contains(recSurname)
        let yearDrift: Int = {
            guard let by = entry.year, record.year > 0 else { return 0 }
            return abs(by - record.year)
        }()

        // Detect arXiv -> peer-reviewed venue upgrade opportunity first if authors match
        let venueLower = (entry.venue ?? "").lowercased()
        let isCitedAsPreprint = entry.arxivId != nil || venueLower.contains("arxiv") || venueLower.contains("corr")
        if !authorMismatch,
           isCitedAsPreprint,
           let upVenue = record.publishedUpgradeVenue,
           !upVenue.lowercased().contains("arxiv") {
            let upgraded = BibTeXParser.formatUpgradedBibTeX(entry: entry, record: record)
            return CitationDiagnostic(
                citeKey: entry.citeKey,
                kind: .preprintUpgrade,
                headline: "Peer-reviewed version available (\(upVenue) \(record.publishedUpgradeYear ?? record.year))",
                detail: "Currently cited as arXiv preprint; official version published in \(upVenue).",
                matchedRecord: record,
                upgradedBibTeX: upgraded,
                lineNumbers: lineNumbers,
                hasLocalPDFEvidence: hasLocalPDF
            )
        }

        if authorMismatch || yearDrift > 1 {
            var issues: [String] = []
            if authorMismatch {
                issues.append("first author '\(entry.firstAuthorSurname)' != '\(record.firstAuthorSurname)'")
            }
            if yearDrift > 1, let by = entry.year {
                issues.append("year \(by) != \(record.year)")
            }
            return CitationDiagnostic(
                citeKey: entry.citeKey,
                kind: .metadataMismatch,
                headline: "Metadata mismatch against \(record.source) (\(entry.citeKey))",
                detail: "Discrepancy detected: \(issues.joined(separator: "; ")).",
                matchedRecord: record,
                upgradedBibTeX: BibTeXParser.formatUpgradedBibTeX(entry: entry, record: record),
                lineNumbers: lineNumbers,
                hasLocalPDFEvidence: hasLocalPDF
            )
        }

        return CitationDiagnostic(
            citeKey: entry.citeKey,
            kind: .verified,
            headline: "Verified via \(record.source) (\(record.venue), \(record.year))",
            detail: record.doi.map { "DOI: \($0)" } ?? "Title & author metadata verified.",
            matchedRecord: record,
            upgradedBibTeX: nil,
            lineNumbers: lineNumbers,
            hasLocalPDFEvidence: hasLocalPDF
        )
    }

    public static func auditManuscript(
        manuscript: String,
        bibText: String,
        triangulator: ScholarTriangulator,
        indexedPDFKeys: Set<String> = []
    ) async -> [CitationDiagnostic] {
        let entries = BibTeXParser.parseBibTeX(bibText)
        let inlineRefs = BibTeXParser.extractInlineCitations(from: manuscript)

        var linesByKey: [String: [Int]] = [:]
        for ref in inlineRefs {
            linesByKey[ref.citeKey, default: []].append(ref.lineNumber)
        }
        let entriesByKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.citeKey, $0) })

        var results: [CitationDiagnostic] = []

        // 1. Check inline cite keys missing from .bib (OrphanCite - missing definition)
        for (citeKey, lines) in linesByKey.sorted(by: { $0.key < $1.key }) where entriesByKey[citeKey] == nil {
            results.append(
                CitationDiagnostic(
                    citeKey: citeKey,
                    kind: .orphanCite,
                    headline: "Missing BibTeX entry for cited key '\(citeKey)'",
                    detail: "Referenced on manuscript line(s) \(lines.map(String.init).joined(separator: ", ")), but absent from .bib.",
                    lineNumbers: lines
                )
            )
        }

        // 2. Verify all .bib entries
        for entry in entries {
            let lines = linesByKey[entry.citeKey] ?? []
            if lines.isEmpty {
                results.append(
                    CitationDiagnostic(
                        citeKey: entry.citeKey,
                        kind: .orphanCite,
                        headline: "Uncited bibliography entry '\(entry.citeKey)'",
                        detail: "Present in .bib file but never referenced via \\cite{} or @key in manuscript.",
                        lineNumbers: []
                    )
                )
                continue
            }
            let diag = await evaluateSingleEntry(
                entry: entry,
                triangulator: triangulator,
                lineNumbers: lines,
                hasLocalPDF: indexedPDFKeys.contains(entry.citeKey)
            )
            results.append(diag)
        }

        return results
    }
}
