import Foundation

/// Drives local `tectonic` LaTeX compiler with `--synctex` enabled and structured log line parsing.
public enum TectonicRunner {

    public static func detectBinary() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/tectonic",
            "/usr/local/bin/tectonic",
            (FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin/tectonic")).path
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public static func compile(texFile: URL, outputDirectory: URL? = nil) -> CompileResult {
        let start = DispatchTime.now()
        let outDir = outputDirectory ?? texFile.deletingLastPathComponent()
        guard let bin = detectBinary() else {
            return CompileResult(
                engine: "tectonic",
                succeeded: false,
                pdfURL: nil,
                synctexURL: nil,
                durationMs: 0,
                diagnostics: [
                    CompilerDiagnostic(
                        file: texFile.lastPathComponent,
                        line: 1,
                        message: "tectonic binary not found in /opt/homebrew/bin or /usr/local/bin",
                        isError: true
                    )
                ]
            )
        }

        let proc = Process()
        proc.executableURL = bin
        proc.currentDirectoryURL = texFile.deletingLastPathComponent()
        proc.arguments = [
            "-X", "compile",
            texFile.path,
            "--synctex",
            "--outdir", outDir.path
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return CompileResult(
                engine: "tectonic",
                succeeded: false,
                pdfURL: nil,
                synctexURL: nil,
                durationMs: 0,
                diagnostics: [
                    CompilerDiagnostic(file: texFile.lastPathComponent, line: 1, message: error.localizedDescription, isError: true)
                ]
            )
        }

        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        let stdoutStr = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = stdoutStr + "\n" + stderrStr

        let stem = texFile.deletingPathExtension().lastPathComponent
        let pdfURL = outDir.appendingPathComponent("\(stem).pdf")
        let synctexURL = outDir.appendingPathComponent("\(stem).synctex.gz")
        let diags = parseDiagnostics(log: combined, defaultFile: texFile.lastPathComponent)
        let ok = proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: pdfURL.path)

        return CompileResult(
            engine: "tectonic",
            succeeded: ok,
            pdfURL: ok ? pdfURL : nil,
            synctexURL: FileManager.default.fileExists(atPath: synctexURL.path) ? synctexURL : nil,
            durationMs: elapsedMs,
            diagnostics: diags
        )
    }

    public static func parseDiagnostics(log: String, defaultFile: String) -> [CompilerDiagnostic] {
        var list: [CompilerDiagnostic] = []
        let regex = try! NSRegularExpression(pattern: #"error:\s*([^:\n]+):(\d+):\s*(.+)"#)
        for line in log.components(separatedBy: .newlines) {
            let ns = line as NSString
            if let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let file = ns.substring(with: m.range(at: 1))
                let lineNo = Int(ns.substring(with: m.range(at: 2))) ?? 1
                let msg = ns.substring(with: m.range(at: 3))
                list.append(CompilerDiagnostic(file: file, line: lineNo, message: msg, isError: true))
            } else if line.lowercased().contains("warning:") {
                list.append(CompilerDiagnostic(file: defaultFile, line: 1, message: line.trimmingCharacters(in: .whitespaces), isError: false))
            }
        }
        return list
    }
}
