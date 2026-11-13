import Foundation

/// Deterministic academic manuscript linter absorbing `writing-anti-ai` and `paper-polish` checks.
public enum WritingQualityLinter {

    private static let aiClicheRules: [(phrase: String, suggestion: String)] = [
        ("delve into", "Replace 'delve into' with a concrete verb such as 'analyze', 'measure', or 'examine'."),
        ("pivotal role", "State the specific causal mechanism or quantitative effect instead of 'pivotal role'."),
        ("testament to", "Remove promotional phrasing ('testament to') and report empirical evidence directly."),
        ("rich tapestry", "Avoid metaphorical AI filler ('rich tapestry') in technical prose."),
        ("it is worth noting that", "Delete throat-clearing prefix 'It is worth noting that'; state the claim directly."),
        ("underscores the importance", "Replace vague significance framing with exact metric delta or scope."),
        ("paradigm shift", "Avoid overclaiming ('paradigm shift') unless backed by field-wide consensus."),
        ("groundbreaking", "Remove promotional adjective 'groundbreaking'; let benchmark tables speak.")
    ]

    public static func lint(manuscript: String) -> [WritingLintFinding] {
        var findings: [WritingLintFinding] = []
        let lines = manuscript.components(separatedBy: .newlines)

        var declaredLabels: [(label: String, line: Int)] = []
        var referencedLabels = Set<String>()
        var definedAcronyms = Set<String>(["PDF", "CPU", "GPU", "RAM", "API", "SQL", "URL", "DOI", "LLM", "NLP", "JSON", "HTML"])

        let labelDefRegex = try! NSRegularExpression(pattern: #"\\label\{((?:fig|tab|eq):[^}]+)\}"#)
        let refUseRegex = try! NSRegularExpression(pattern: #"\\(?:ref|autoref|cref|Cref|eqref)\{([^}]+)\}"#)
        let acronymDefRegex = try! NSRegularExpression(pattern: #"\(([A-Z]{3,6})\)"#)
        let acronymUseRegex = try! NSRegularExpression(pattern: #"\b([A-Z]{3,6})\b"#)

        for (idx, rawLine) in lines.enumerated() {
            let lineNo = idx + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("%") { continue }

            let lower = rawLine.lowercased()
            // 1. AI cliché vocabulary scan
            for rule in aiClicheRules where lower.contains(rule.phrase) {
                findings.append(
                    WritingLintFinding(
                        ruleId: "anti-ai-vocab",
                        category: "anti-ai",
                        lineNumber: lineNo,
                        matchedText: rule.phrase,
                        suggestion: rule.suggestion
                    )
                )
            }

            // 2. Em-dash overuse (more than 1 `---` or `—` on a single line/sentence)
            let latexDashes = rawLine.components(separatedBy: "---").count - 1
            let unicodeDashes = rawLine.filter { $0 == "\u{2014}" }.count
            if latexDashes + unicodeDashes >= 2 {
                findings.append(
                    WritingLintFinding(
                        ruleId: "polish-emdash-density",
                        category: "punctuation",
                        lineNumber: lineNo,
                        matchedText: "Multiple em-dashes on line \(lineNo)",
                        suggestion: "Convert parenthetical em-dash clauses into semicolons, commas, or a footnote."
                    )
                )
            }

            let nsLine = rawLine as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            // 3. Collect \label{fig:...} and \ref{...}
            for m in labelDefRegex.matches(in: rawLine, range: fullRange) {
                declaredLabels.append((nsLine.substring(with: m.range(at: 1)), lineNo))
            }
            for m in refUseRegex.matches(in: rawLine, range: fullRange) {
                let inner = nsLine.substring(with: m.range(at: 1))
                for part in inner.split(separator: ",") {
                    referencedLabels.insert(part.trimmingCharacters(in: .whitespaces))
                }
            }

            // 4. First-use undefined acronym detection
            for m in acronymDefRegex.matches(in: rawLine, range: fullRange) {
                definedAcronyms.insert(nsLine.substring(with: m.range(at: 1)))
            }
            if !trimmed.hasPrefix("\\") {
                for m in acronymUseRegex.matches(in: rawLine, range: fullRange) {
                    let acr = nsLine.substring(with: m.range(at: 1))
                    if !definedAcronyms.contains(acr) {
                        definedAcronyms.insert(acr)
                        findings.append(
                            WritingLintFinding(
                                ruleId: "polish-undefined-acronym",
                                category: "acronym",
                                lineNumber: lineNo,
                                matchedText: acr,
                                suggestion: "Spell out '\(acr)' on first appearance before using the abbreviation."
                            )
                        )
                    }
                }
            }
        }

        for (lbl, ln) in declaredLabels where !referencedLabels.contains(lbl) {
            findings.append(
                WritingLintFinding(
                    ruleId: "polish-uncited-float",
                    category: "cross-ref",
                    lineNumber: ln,
                    matchedText: "\\label{\(lbl)}",
                    suggestion: "Label '\(lbl)' is never referenced in the text via \\ref{\(lbl)} or \\cref{\(lbl)}."
                )
            )
        }

        return findings
    }
}
