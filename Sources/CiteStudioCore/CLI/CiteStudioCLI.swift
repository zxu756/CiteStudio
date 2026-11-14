import Foundation

/// Headless command-line runner shared by `CiteStudio --cli ...` and unit tests.
public enum CiteStudioCLI {

    public struct ExecutionResult: Sendable, Equatable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public static func resolveLanguage(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppLanguage {
        if let explicit = AppLanguage.parseCLIArguments(arguments) {
            return explicit
        }
        for key in ["CITESTUDIO_LANG", "LC_ALL", "LANG"] {
            if let val = environment[key], let parsed = AppLanguage.parse(val) {
                return parsed
            }
        }
        return .en
    }

    public static func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        customTransport: ScholarLookupTransport? = nil
    ) async -> ExecutionResult {
        let lang = resolveLanguage(arguments: arguments, environment: environment)

        if arguments.contains("--help") || arguments.contains("-h") {
            return ExecutionResult(exitCode: 0, stdout: usageText(in: lang) + "\n")
        }

        guard let cliIdx = arguments.firstIndex(of: "--cli") else {
            return ExecutionResult(exitCode: 2, stderr: usageText(in: lang) + "\n")
        }

        let remaining = extractPositionalArgs(from: Array(arguments.dropFirst(cliIdx + 1)))
        guard let subcommand = remaining.first else {
            let errHeader = lang == .zhHans
                ? "错误：缺少 --cli 子命令。\n"
                : "Error: Missing subcommand after --cli.\n"
            return ExecutionResult(exitCode: 2, stderr: errHeader + usageText(in: lang) + "\n")
        }

        let subArgs = Array(remaining.dropFirst())
        let jsonOutput = arguments.contains("--json")

        switch subcommand {
        case "help":
            return ExecutionResult(exitCode: 0, stdout: usageText(in: lang) + "\n")

        case "status":
            let notInstalled = lang == .zhHans ? "未安装" : "not installed"
            let tec = TectonicRunner.detectBinary()?.path ?? notInstalled
            let typ = TypstRunner.detectBinary()?.path ?? notInstalled
            let out = lang == .zhHans
                ? "CiteStudio 0.2.0 | Tectonic: \(tec) | Typst: \(typ)\n"
                : "CiteStudio 0.2.0 | Tectonic: \(tec) | Typst: \(typ)\n"
            return ExecutionResult(exitCode: 0, stdout: out)

        case "lint":
            guard let targetPath = subArgs.first, !targetPath.isEmpty else {
                let msg = lang == .zhHans
                    ? "用法错误：CiteStudio --cli lint <manuscript.tex> [--lang en|zh]\n"
                    : "Usage: CiteStudio --cli lint <manuscript.tex> [--lang en|zh]\n"
                return ExecutionResult(exitCode: 2, stderr: msg)
            }
            if let fileErr = validateExistingFile(path: targetPath, in: lang) {
                return ExecutionResult(exitCode: 2, stderr: fileErr + "\n")
            }
            let url = URL(fileURLWithPath: targetPath)
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                let msg = lang == .zhHans
                    ? "错误：无法读取文件 \(targetPath)：\(error.localizedDescription)\n"
                    : "Error: Unable to read file \(targetPath): \(error.localizedDescription)\n"
                return ExecutionResult(exitCode: 2, stderr: msg)
            }

            let findings = WritingQualityLinter.lint(manuscript: text)
            var lines: [String] = []
            for f in findings {
                if lang == .zhHans {
                    lines.append("[第 \(f.lineNumber) 行] [\(f.ruleId)] \(f.localizedMatchedText(in: .zhHans)) -> \(f.localizedSuggestion(in: .zhHans))")
                } else {
                    lines.append("[L\(f.lineNumber)] [\(f.ruleId)] \(f.matchedText) -> \(f.suggestion)")
                }
            }
            if lang == .zhHans {
                lines.append("确定性行文与图表检查共发现问题：\(findings.count) 项")
            } else {
                lines.append("Total deterministic findings: \(findings.count)")
            }
            return ExecutionResult(
                exitCode: findings.isEmpty ? 0 : 1,
                stdout: lines.joined(separator: "\n") + "\n"
            )

        case "compile":
            guard let targetPath = subArgs.first, !targetPath.isEmpty else {
                let msg = lang == .zhHans
                    ? "用法错误：CiteStudio --cli compile <manuscript.tex|manuscript.typ> [--lang en|zh]\n"
                    : "Usage: CiteStudio --cli compile <manuscript.tex|manuscript.typ> [--lang en|zh]\n"
                return ExecutionResult(exitCode: 2, stderr: msg)
            }
            if let fileErr = validateExistingFile(path: targetPath, in: lang) {
                return ExecutionResult(exitCode: 2, stderr: fileErr + "\n")
            }
            let url = URL(fileURLWithPath: targetPath)
            let res = (url.pathExtension.lowercased() == "typ")
                ? TypstRunner.compile(typFile: url)
                : TectonicRunner.compile(texFile: url)

            var outLines: [String] = []
            if lang == .zhHans {
                outLines.append("编译引擎：\(res.engine) | 成功：\(res.succeeded) | 耗时：\(res.durationMs) ms")
                if let pdf = res.pdfURL {
                    outLines.append("输出 PDF：\(pdf.path)")
                }
            } else {
                outLines.append("Engine: \(res.engine) | Succeeded: \(res.succeeded) | Duration: \(res.durationMs) ms")
                if let pdf = res.pdfURL {
                    outLines.append("Output PDF: \(pdf.path)")
                }
            }
            for d in res.diagnostics {
                outLines.append("  [\(d.file):\(d.line)] \(d.message)")
            }

            if res.succeeded {
                return ExecutionResult(exitCode: 0, stdout: outLines.joined(separator: "\n") + "\n")
            } else {
                let reason = res.diagnostics.first?.message ?? (lang == .zhHans ? "编译失败" : "Compilation failed")
                let errLine = lang == .zhHans
                    ? "错误：编译失败（\(res.engine)）：\(reason)\n"
                    : "Error: Compilation failed (\(res.engine)): \(reason)\n"
                return ExecutionResult(
                    exitCode: 1,
                    stdout: outLines.joined(separator: "\n") + "\n",
                    stderr: errLine
                )
            }

        case "verify":
            guard let bibPath = subArgs.first, !bibPath.isEmpty else {
                let msg = lang == .zhHans
                    ? "用法错误：CiteStudio --cli verify <refs.bib> [--json] [--cache-dir <dir>] [--lang en|zh]\n"
                    : "Usage: CiteStudio --cli verify <refs.bib> [--json] [--cache-dir <dir>] [--lang en|zh]\n"
                return ExecutionResult(exitCode: 2, stderr: msg)
            }
            if let fileErr = validateExistingFile(path: bibPath, in: lang) {
                return ExecutionResult(exitCode: 2, stderr: fileErr + "\n")
            }
            let bibURL = URL(fileURLWithPath: bibPath)
            let bibText: String
            do {
                bibText = try String(contentsOf: bibURL, encoding: .utf8)
            } catch {
                let msg = lang == .zhHans
                    ? "错误：无法读取文件 \(bibPath)：\(error.localizedDescription)\n"
                    : "Error: Unable to read file \(bibPath): \(error.localizedDescription)\n"
                return ExecutionResult(exitCode: 2, stderr: msg)
            }

            let entries = BibTeXParser.parseBibTeX(bibText)
            guard !entries.isEmpty else {
                let msg = lang == .zhHans
                    ? "错误：未在 \(bibPath) 中解析到有效的 BibTeX 条目。\n"
                    : "Error: No valid BibTeX entries found in \(bibPath).\n"
                return ExecutionResult(exitCode: 1, stderr: msg)
            }

            let cacheDir = ScholarTriangulator.resolveCacheDirectory(arguments: arguments, environment: environment)
            let cacheDB = cacheDir.appendingPathComponent("scholar_cache.sqlite")
            let transport = customTransport ?? PublicScholarHTTPTransport(environment: environment)
            let triangulator: ScholarTriangulator
            do {
                triangulator = try ScholarTriangulator(cacheDBPath: cacheDB, transport: transport)
            } catch {
                let msg = lang == .zhHans
                    ? "错误：无法打开核查缓存数据库：\(error.localizedDescription)\n"
                    : "Error: Failed to open verification cache: \(error.localizedDescription)\n"
                return ExecutionResult(exitCode: 1, stderr: msg)
            }

            var diagnostics: [CitationDiagnostic] = []
            for entry in entries {
                // Shares the exact same evaluation function as MCP `verify_citation`
                let diag = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: entry, triangulator: triangulator)
                diagnostics.append(diag)
            }

            let counts = Dictionary(grouping: diagnostics, by: \.kind).mapValues(\.count)
            let verifiedCount = counts[.verified] ?? 0
            let upgradeCount = counts[.preprintUpgrade] ?? 0
            let mismatchCount = counts[.metadataMismatch] ?? 0
            let retractedCount = counts[.retracted] ?? 0
            let ghostCount = counts[.ghostPaper] ?? 0
            let unverifiedCount = counts[.unverified] ?? 0

            // Exit 0 ONLY when every entry is strictly Verified
            let allStrictlyVerified = diagnostics.allSatisfy { $0.kind == .verified }
            let code: Int32 = allStrictlyVerified ? 0 : 1

            if jsonOutput {
                let entryPayloads: [[String: Any]] = diagnostics.map { d in
                    var item: [String: Any] = [
                        "citeKey": d.citeKey,
                        "verdict": d.kind.rawValue,
                        "badge": d.kind.badgeLabel(in: lang),
                        "headline": d.localizedHeadline(in: lang),
                        "detail": d.localizedDetail(in: lang)
                    ]
                    if let up = d.upgradedBibTeX {
                        item["upgradedBibTeX"] = up
                    }
                    return item
                }
                let rootObj: [String: Any] = [
                    "entries": entryPayloads,
                    "summary": [
                        "evaluated": diagnostics.count,
                        "verified": verifiedCount,
                        "preprintUpgrade": upgradeCount,
                        "metadataMismatch": mismatchCount,
                        "retracted": retractedCount,
                        "ghostPaper": ghostCount,
                        "unverified": unverifiedCount
                    ]
                ]
                let data = (try? JSONSerialization.data(withJSONObject: rootObj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                let jsonStr = String(data: data, encoding: .utf8) ?? "{}"
                return ExecutionResult(exitCode: code, stdout: jsonStr + "\n")
            } else {
                var lines: [String] = []
                for d in diagnostics {
                    if lang == .zhHans {
                        lines.append("[\(d.kind.rawValue) | \(d.kind.badgeLabel(in: .zhHans))] \(d.citeKey) — \(d.localizedHeadline(in: .zhHans)) | \(d.localizedDetail(in: .zhHans))")
                    } else {
                        lines.append("[\(d.kind.rawValue)] \(d.citeKey) — \(d.headline) | \(d.detail)")
                    }
                }
                if lang == .zhHans {
                    lines.append("核查汇总：共 \(diagnostics.count) 条 · 已验证(Verified)=\(verifiedCount) · 可升级(PreprintUpgrade)=\(upgradeCount) · 元数据不符(MetadataMismatch)=\(mismatchCount) · 已撤稿(Retracted)=\(retractedCount) · 确认不存在(GhostPaper)=\(ghostCount) · 未验证(Unverified)=\(unverifiedCount)")
                } else {
                    lines.append("Summary: Evaluated=\(diagnostics.count) Verified=\(verifiedCount) PreprintUpgrade=\(upgradeCount) MetadataMismatch=\(mismatchCount) Retracted=\(retractedCount) GhostPaper=\(ghostCount) Unverified=\(unverifiedCount)")
                }
                return ExecutionResult(exitCode: code, stdout: lines.joined(separator: "\n") + "\n")
            }

        case "clear-cache", "cache-clear":
            let cacheDir = ScholarTriangulator.resolveCacheDirectory(arguments: arguments, environment: environment)
            let cacheDB = cacheDir.appendingPathComponent("scholar_cache.sqlite")
            do {
                let triangulator = try ScholarTriangulator(cacheDBPath: cacheDB)
                let purged = triangulator.clearCache()
                let out = lang == .zhHans
                    ? "已清空 \(purged) 条引文核查缓存记录（\(cacheDB.path)）。\n"
                    : "Cleared \(purged) cached citation verification entries (\(cacheDB.path)).\n"
                return ExecutionResult(exitCode: 0, stdout: out)
            } catch {
                let err = lang == .zhHans
                    ? "错误：清空缓存失败：\(error.localizedDescription)\n"
                    : "Error: Failed to clear cache: \(error.localizedDescription)\n"
                return ExecutionResult(exitCode: 1, stderr: err)
            }

        default:
            let errHeader = lang == .zhHans
                ? "错误：未知的命令行子命令 '\(subcommand)'。\n"
                : "Error: Unknown CLI subcommand '\(subcommand)'.\n"
            return ExecutionResult(exitCode: 2, stderr: errHeader + usageText(in: lang) + "\n")
        }
    }

    private static func validateExistingFile(path: String, in language: AppLanguage) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return language == .zhHans
                ? "错误：文件不存在：\(path)"
                : "Error: File does not exist: \(path)"
        }
        if isDir.boolValue {
            return language == .zhHans
                ? "错误：路径是目录而非文件：\(path)"
                : "Error: Path is a directory, not a file: \(path)"
        }
        return nil
    }

    private static func extractPositionalArgs(from rawArgs: [String]) -> [String] {
        var positional: [String] = []
        var idx = 0
        while idx < rawArgs.count {
            let token = rawArgs[idx]
            if token == "--lang" || token == "--cache-dir" {
                idx += 2
                continue
            }
            if token.hasPrefix("--lang=") || token.hasPrefix("--cache-dir=") || token == "--json" {
                idx += 1
                continue
            }
            positional.append(token)
            idx += 1
        }
        return positional
    }

    public static func usageText(in language: AppLanguage) -> String {
        if language == .zhHans {
            return """
            CiteStudio 命令行与服务入口：
              CiteStudio --cli status [--lang en|zh]
              CiteStudio --cli verify <refs.bib> [--json] [--cache-dir <dir>] [--lang en|zh]
              CiteStudio --cli clear-cache [--cache-dir <dir>] [--lang en|zh]
              CiteStudio --cli lint <manuscript.tex> [--lang en|zh]
              CiteStudio --cli compile <manuscript.tex|manuscript.typ> [--lang en|zh]
              CiteStudio --mcp [--cache-dir <dir>] [--lang en|zh]
              CiteStudio [--demo] [--lang en|zh]
            """
        } else {
            return """
            CiteStudio CLI & Server Entry Points:
              CiteStudio --cli status [--lang en|zh]
              CiteStudio --cli verify <refs.bib> [--json] [--cache-dir <dir>] [--lang en|zh]
              CiteStudio --cli clear-cache [--cache-dir <dir>] [--lang en|zh]
              CiteStudio --cli lint <manuscript.tex> [--lang en|zh]
              CiteStudio --cli compile <manuscript.tex|manuscript.typ> [--lang en|zh]
              CiteStudio --mcp [--cache-dir <dir>] [--lang en|zh]
              CiteStudio [--demo] [--lang en|zh]
            """
        }
    }
}
