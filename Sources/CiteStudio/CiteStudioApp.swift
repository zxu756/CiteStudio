import AppKit
import CiteStudioCore
import Darwin
import Foundation
import SwiftUI

@main
enum CiteStudioMain {
    static func main() {
        let args = CommandLine.arguments
        let env = ProcessInfo.processInfo.environment

        if args.contains("--help") || args.contains("-h") || args.contains("--cli") {
            final class ResultBox: @unchecked Sendable {
                var value = CiteStudioCLI.ExecutionResult(exitCode: 1)
            }
            let box = ResultBox()
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                box.value = await CiteStudioCLI.run(arguments: args, environment: env)
                sem.signal()
            }
            sem.wait()
            if !box.value.stdout.isEmpty {
                FileHandle.standardOutput.write(Data(box.value.stdout.utf8))
            }
            if !box.value.stderr.isEmpty {
                FileHandle.standardError.write(Data(box.value.stderr.utf8))
            }
            fflush(stdout)
            fflush(stderr)
            Darwin.exit(box.value.exitCode)
        }

        if args.contains("--mcp") {
            let supportDir = ScholarTriangulator.resolveCacheDirectory(arguments: args, environment: env)
            let mcpLang = AppLanguage.parseCLIArguments(args) ?? .en
            do {
                let transport = PublicScholarHTTPTransport(environment: env)
                let triangulator = try ScholarTriangulator(
                    cacheDBPath: supportDir.appendingPathComponent("scholar_cache.sqlite"),
                    transport: transport
                )
                let indexer = try LocalPDFIndexer(dbURL: supportDir.appendingPathComponent("pdf_fts5.sqlite"))
                CiteStudioMCPServer(triangulator: triangulator, pdfIndexer: indexer, language: mcpLang).runStdioLoop()
                fflush(stdout)
                fflush(stderr)
                Darwin.exit(0)
            } catch {
                fputs("MCP initialization failed: \(error.localizedDescription)\n", stderr)
                fflush(stderr)
                Darwin.exit(1)
            }
        }

        if let idx = args.firstIndex(of: "--export-screenshots"), idx + 1 < args.count {
            let outURL = URL(fileURLWithPath: args[idx + 1])
            let exportLang = AppLanguage.parseCLIArguments(args) ?? .en
            do {
                try MainActor.assumeIsolated {
                    try CiteStudioScreenshotExporter.exportMarketingScreenshots(to: outURL, language: exportLang)
                }
                print("Exported 2x Retina [DEMO] screenshots (\(exportLang.rawValue)) to \(outURL.path)")
                fflush(stdout)
                Darwin.exit(0)
            } catch {
                fputs("Screenshot export failed: \(error.localizedDescription)\n", stderr)
                fflush(stderr)
                Darwin.exit(1)
            }
        }

        CiteStudioApp.main()
    }
}

struct CiteStudioApp: App {
    @StateObject private var session: CiteStudioWorkspaceSession
    @StateObject private var localizer: AppLocalizer

    init() {
        let args = CommandLine.arguments
        let env = ProcessInfo.processInfo.environment

        let useEphemeralDefaults = (env["CITESTUDIO_EPHEMERAL_DEFAULTS"] == "1")
        if useEphemeralDefaults {
            let resolved = CiteStudioCLI.resolveLanguage(arguments: args, environment: env)
            _localizer = StateObject(wrappedValue: AppLocalizer(language: resolved, userDefaults: nil))
        } else {
            _localizer = StateObject(wrappedValue: AppLocalizer.shared)
        }

        if args.contains("--demo") {
            _session = StateObject(wrappedValue: CiteStudioWorkspaceSession.demoSession())
        } else {
            _session = StateObject(wrappedValue: CiteStudioWorkspaceSession())
        }
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
}
