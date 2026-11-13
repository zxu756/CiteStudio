import Foundation

/// Deterministic academic manuscript linter absorbing `writing-anti-ai` and `paper-polish` checks.
public enum WritingQualityLinter {

    private static let aiClicheRules: [(phrase: String, suggestion: String, suggestionZh: String)] = [
        (
            "delve into",
            "Replace 'delve into' with a concrete verb such as 'analyze', 'measure', or 'examine'.",
            "建议将 AI 高频套话 'delve into' 替换为具体学术动词（如 'analyze'、'measure' 或 'examine'）。"
        ),
        (
            "pivotal role",
            "State the specific causal mechanism or quantitative effect instead of 'pivotal role'.",
            "避免空泛套话 'pivotal role'，请直接陈述具体的因果机制或量化性能提升。"
        ),
        (
            "testament to",
            "Remove promotional phrasing ('testament to') and report empirical evidence directly.",
            "删去宣传性修辞 'testament to'，直接报告实验指标与可验证证据。"
        ),
        (
            "rich tapestry",
            "Avoid metaphorical AI filler ('rich tapestry') in technical prose.",
            "学术技术写作中请避免使用比喻式 AI 填充词 'rich tapestry'。"
        ),
        (
            "it is worth noting that",
            "Delete throat-clearing prefix 'It is worth noting that'; state the claim directly.",
            "删去冗余铺垫句式 'It is worth noting that'，直接陈述核心论断。"
        ),
        (
            "underscores the importance",
            "Replace vague significance framing with exact metric delta or scope.",
            "避免模糊拔高句式 'underscores the importance'，改用准确的指标增益或适用边界说明。"
        ),
        (
            "paradigm shift",
            "Avoid overclaiming ('paradigm shift') unless backed by field-wide consensus.",
            "避免过度宣称（'paradigm shift'），请紧扣本文实际方法边界与实验证据。"
        ),
        (
            "groundbreaking",
            "Remove promotional adjective 'groundbreaking'; let benchmark tables speak.",
            "删去夸张修饰词 'groundbreaking'，用基准测试对比表说话。"
        )
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
                        suggestion: rule.suggestion,
                        suggestionZh: rule.suggestionZh
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
                        suggestion: "Convert parenthetical em-dash clauses into semicolons, commas, or a footnote.",
                        matchedTextZh: "第 \(lineNo) 行包含多处破折号",
                        suggestionZh: "单句内密集使用破折号（em-dash）具有明显生成痕迹，建议改用分号、逗号或脚注。"
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
                                suggestion: "Spell out '\(acr)' on first appearance before using the abbreviation.",
                                suggestionZh: "缩略语 '\(acr)' 首次出现时未给出英文全称定义，建议补充全称后再使用缩写。"
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
                    suggestion: "Label '\(lbl)' is never referenced in the text via \\ref{\(lbl)} or \\cref{\(lbl)}.",
                    suggestionZh: "图表标签 '\(lbl)' 在正文中从未通过 \\ref{\(lbl)} 或 \\cref{\(lbl)} 引用。"
                )
            )
        }

        return findings
    }
}
