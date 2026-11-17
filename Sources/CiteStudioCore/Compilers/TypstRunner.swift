import Foundation

/// Drives local `typst` compiler when present, mapping file:line:col diagnostics cleanly.
public enum TypstRunner {

    public static func detectBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let rawPath = environment["PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPath.isEmpty {
            for entry in rawPath.split(separator: ":", omittingEmptySubsequences: true) {
                let candidate = URL(fileURLWithPath: String(entry), isDirectory: true)
                    .appendingPathComponent("typst").path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
            return nil
        }

        let fallbackCandidates = [
            "/opt/homebrew/bin/typst",
            "/usr/local/bin/typst",
            (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin/typst")).path
        ]
        for path in fallbackCandidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public static func compile(
        typFile: URL,
        outputPDF: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CompileResult {
        let start = DispatchTime.now()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: typFile.path, isDirectory: &isDir), !isDir.boolValue else {
            return CompileResult(
                engine: "typst",
                succeeded: false,
                pdfURL: nil,
                synctexURL: nil,
                durationMs: 0,
                diagnostics: [
                    CompilerDiagnostic(
                        file: typFile.lastPathComponent,
                        line: 1,
                        message: "Input file does not exist: \(typFile.path)",
                        isError: true
                    )
                ]
            )
        }
        let targetPDF = outputPDF ?? typFile.deletingPathExtension().appendingPathExtension("pdf")
        guard let bin = detectBinary(environment: environment) else {
            return CompileResult(
                engine: "typst",
                succeeded: false,
                pdfURL: nil,
                synctexURL: nil,
                durationMs: 0,
                diagnostics: [
                    CompilerDiagnostic(
                        file: typFile.lastPathComponent,
                        line: 1,
                        message: "typst CLI not installed (install via `brew install typst`); Tectonic LaTeX engine is active.",
                        isError: true
                    )
                ]
            )
        }

        let proc = Process()
        proc.executableURL = bin
        proc.currentDirectoryURL = typFile.deletingLastPathComponent()
        proc.arguments = ["compile", typFile.path, targetPDF.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return CompileResult(
                engine: "typst",
                succeeded: false,
                pdfURL: nil,
                synctexURL: nil,
                durationMs: 0,
                diagnostics: [
                    CompilerDiagnostic(file: typFile.lastPathComponent, line: 1, message: error.localizedDescription, isError: true)
                ]
            )
        }

        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        let stderrStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let diags = parseTypstDiagnostics(stderrStr, defaultFile: typFile.lastPathComponent)
        let ok = proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: targetPDF.path)

        return CompileResult(
            engine: "typst",
            succeeded: ok,
            pdfURL: ok ? targetPDF : nil,
            synctexURL: nil,
            durationMs: elapsedMs,
            diagnostics: diags
        )
    }

    public static func parseTypstDiagnostics(_ stderrText: String, defaultFile: String) -> [CompilerDiagnostic] {
        var out: [CompilerDiagnostic] = []
        let locRegex = try! NSRegularExpression(pattern: #"┌─\s*([^:\n]+):(\d+):\d+"#)
        let lines = stderrText.components(separatedBy: .newlines)
        var pendingMsg = "Typst compilation diagnostic"
        for line in lines {
            if line.hasPrefix("error:") {
                pendingMsg = String(line.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces)
            }
            let ns = line as NSString
            if let m = locRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let f = ns.substring(with: m.range(at: 1))
                let l = Int(ns.substring(with: m.range(at: 2))) ?? 1
                out.append(CompilerDiagnostic(file: f, line: l, message: pendingMsg, isError: true))
            }
        }
        return out
    }
}
