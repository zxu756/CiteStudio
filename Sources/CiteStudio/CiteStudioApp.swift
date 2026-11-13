import AppKit
import CiteStudioCore
import Foundation
import SwiftUI

@main
struct CiteStudioApp: App {
    @StateObject private var session: CiteStudioWorkspaceSession
    @StateObject private var localizer = AppLocalizer.shared

    init() {
        let args = CommandLine.arguments

        if let idx = args.firstIndex(of: "--export-screenshots"), idx + 1 < args.count {
            let outURL = URL(fileURLWithPath: args[idx + 1])
            let exportLang = AppLanguage.parseCLIArguments(args) ?? .en
            do {
                try MainActor.assumeIsolated {
                    try CiteStudioScreenshotExporter.exportMarketingScreenshots(to: outURL, language: exportLang)
                }
                print("Exported 2x Retina screenshots (\(exportLang.rawValue)) to \(outURL.path)")
                exit(0)
            } catch {
                fputs("Screenshot export failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if args.contains("--mcp") {
            let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("CiteStudio", isDirectory: true)
            do {
                let triangulator = try ScholarTriangulator(cacheDBPath: supportDir.appendingPathComponent("scholar_cache.sqlite"))
                let indexer = try LocalPDFIndexer(dbURL: supportDir.appendingPathComponent("pdf_fts5.sqlite"))
                CiteStudioMCPServer(triangulator: triangulator, pdfIndexer: indexer).runStdioLoop()
                exit(0)
            } catch {
                fputs("MCP initialization failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if let idx = args.firstIndex(of: "--cli") {
            let sub = (idx + 1 < args.count) ? args[idx + 1] : "help"
            Self.runHeadlessCLI(sub: sub, args: args, startIdx: idx + 2)
        }

        _session = StateObject(wrappedValue: CiteStudioWorkspaceSession())
    }

    var body: some Scene {
        Window("CiteStudio", id: "main") {
            StudioThreePaneView(session: session, localizer: localizer)
        }
        .defaultSize(width: 1260, height: 760)
        .commands {
            CommandMenu(localizer.L("Language", "语言")) {
                Button("切换语言 / Toggle Language") {
                    localizer.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                Button("简体中文 (中文)") {
                    localizer.setLanguage(.zhHans)
                }
                Button("English (EN)") {
                    localizer.setLanguage(.en)
                }
            }
        }
    }

    private static func runHeadlessCLI(sub: String, args: [String], startIdx: Int) -> Never {
        switch sub {
        case "lint":
            guard startIdx < args.count else {
                fputs("Usage: CiteStudio --cli lint <manuscript.tex>\n", stderr)
                exit(2)
            }
            let path = URL(fileURLWithPath: args[startIdx])
            let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
            let findings = WritingQualityLinter.lint(manuscript: text)
            for f in findings {
                print("[L\(f.lineNumber)] [\(f.ruleId)] \(f.matchedText) -> \(f.suggestion)")
            }
            print("Total deterministic findings: \(findings.count)")
            exit(findings.isEmpty ? 0 : 1)

        case "compile":
            guard startIdx < args.count else {
                fputs("Usage: CiteStudio --cli compile <manuscript.tex|manuscript.typ>\n", stderr)
                exit(2)
            }
            let url = URL(fileURLWithPath: args[startIdx])
            let res = (url.pathExtension.lowercased() == "typ")
                ? TypstRunner.compile(typFile: url)
                : TectonicRunner.compile(texFile: url)
            print("Engine: \(res.engine) | Succeeded: \(res.succeeded) | Duration: \(res.durationMs) ms")
            if let pdf = res.pdfURL { print("Output PDF: \(pdf.path)") }
            for d in res.diagnostics {
                print("  [\(d.file):\(d.line)] \(d.message)")
            }
            exit(res.succeeded ? 0 : 1)

        case "status":
            let tec = TectonicRunner.detectBinary()?.path ?? "not installed"
            let typ = TypstRunner.detectBinary()?.path ?? "not installed"
            print("CiteStudio 0.2.0 | Tectonic: \(tec) | Typst: \(typ)")
            exit(0)

        default:
            print("CiteStudio CLI commands: status | lint <file> | compile <file> | --mcp | --export-screenshots <dir>")
            exit(0)
        }
    }
}
