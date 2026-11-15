import Foundation

/// Runs scholarly citation firewall checks across `.bib` entries and manuscript inline citations.
public enum CitationDiagnosticsEngine {
    /// Minimum normalized Jaccard title token similarity required when verifying a record fetched by DOI (C2).
    public static let minimumDOITitleSimilarity: Double = 0.60

    public static func evaluateSingleEntry(
        entry: BibEntry,
        triangulator: ScholarTriangulator,
        lineNumbers: [Int] = [],
        hasLocalPDF: Bool = false
    ) async -> CitationDiagnostic {
        let outcome = await triangulator.verifyOutcome(entry)

        switch outcome {
        case .lookupFailed(let reason):
            return CitationDiagnostic(
                citeKey: entry.citeKey,
                kind: .unverified,
                headline: "Unverified reference (\(entry.citeKey)) — lookup failed",
                detail: "Could not verify against Crossref / OpenAlex (\(reason.summaryEn)). Not cached; retry when online.",
                headlineZh: "未验证文献 (\(entry.citeKey))：联网核查未完成",
                detailZh: "未能完成 Crossref / OpenAlex 核查（\(reason.summaryZh)）。本次未写入缓存，恢复连接后将重新查询。",
                matchedRecord: nil,
                upgradedBibTeX: nil,
                lineNumbers: lineNumbers,
                hasLocalPDFEvidence: hasLocalPDF
            )

        case .confirmedNotFound:
            let hasExplicitDOI = !(entry.doi?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if hasExplicitDOI {
                return CitationDiagnostic(
                    citeKey: entry.citeKey,
                    kind: .ghostPaper,
                    headline: "Confirmed not found (\(entry.citeKey))",
                    detail: "Neither Crossref nor OpenAlex found this DOI. Blocked by Citation Firewall.",
                    headlineZh: "确认不存在 (\(entry.citeKey))",
                    detailZh: "Crossref 与 OpenAlex 对该 DOI 均返回 404（未找到）；已被引文防火墙拦截。",
                    matchedRecord: nil,
                    upgradedBibTeX: nil,
                    lineNumbers: lineNumbers,
                    hasLocalPDFEvidence: hasLocalPDF
                )
            } else {
                return CitationDiagnostic(
                    citeKey: entry.citeKey,
                    kind: .ghostPaper,
                    headline: "Not found in Crossref / OpenAlex (\(entry.citeKey))",
                    detail: "No Crossref or OpenAlex title-search candidate matched title (>= 0.78), first-author surname, and year (±1). Older books, theses, or reports without a DOI may not be indexed; blocked by Citation Firewall.",
                    headlineZh: "未在 Crossref / OpenAlex 中查到匹配记录 (\(entry.citeKey))",
                    detailZh: "Crossref 与 OpenAlex 按标题检索均未找到同时满足标题相似度（>= 0.78）、第一作者姓氏一致且年份相差不超过 1 年的记录（无 DOI 的早期专著、学位论文或技术报告可能未被收录）；引文防火墙已拦截自动写入。",
                    matchedRecord: nil,
                    upgradedBibTeX: nil,
                    lineNumbers: lineNumbers,
                    hasLocalPDFEvidence: hasLocalPDF
                )
            }

        case .found(let record):
            if record.isRetracted {
                return CitationDiagnostic(
                    citeKey: entry.citeKey,
                    kind: .retracted,
                    headline: "Retracted publication (\(entry.citeKey))",
                    detail: "Indexed by \(record.source) with an official retraction notice (\(record.venue), \(record.year)).",
                    headlineZh: "已撤稿文献告警 (\(entry.citeKey))",
                    detailZh: "\(record.source) 记录显示该文献已正式撤稿（\(record.venue), \(record.year)），严禁引用。",
                    matchedRecord: record,
                    upgradedBibTeX: nil,
                    lineNumbers: lineNumbers,
                    hasLocalPDFEvidence: hasLocalPDF
                )
            }

            // Check title similarity (C2), first-author surname, and publication year consistency
            let trimmedBibTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleSimilarity = ScholarTriangulator.normalizedTitleSimilarity(trimmedBibTitle, record.title)
            let titleMismatch = trimmedBibTitle.isEmpty || titleSimilarity < minimumDOITitleSimilarity

            let bibSurname = ScholarTriangulator.normalizedAuthorSurname(from: entry.authors.first)
            let recSurname = ScholarTriangulator.normalizedAuthorSurname(from: record.authors.first)
            let authorMismatch = !bibSurname.isEmpty && !recSurname.isEmpty && bibSurname != recSurname

            let yearDrift: Int = {
                guard let by = entry.year, record.year > 0 else { return 0 }
                return abs(by - record.year)
            }()

            // Detect arXiv -> peer-reviewed venue upgrade opportunity only when title & author match
            let venueLower = (entry.venue ?? "").lowercased()
            let isCitedAsPreprint = entry.arxivId != nil || venueLower.contains("arxiv") || venueLower.contains("corr")
            if !titleMismatch,
               !authorMismatch,
               yearDrift <= 2,
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

            if titleMismatch || authorMismatch || yearDrift > 1 {
                var issues: [String] = []
                if titleMismatch {
                    issues.append("title '\(entry.title)' != '\(record.title)' (similarity \(String(format: "%.2f", titleSimilarity)))")
                }
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
                    upgradedBibTeX: BibTeXParser.formatCanonicalBibTeX(entry: entry, record: record),
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
