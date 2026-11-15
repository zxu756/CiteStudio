// 合成测试响应说明（Synthetic handwritten unit-test HTTP payloads）：
// 本文件中使用 LoopbackScholarServer 的单元测试（如 C9、C13+C14）返回手写合成最小 JSON 响应，不算真实上游录制证据。

import Darwin
import Foundation
import Testing
@testable import CiteStudioCore

@Suite("CLITests", .timeLimit(.minutes(1)))
struct CLITests {

    private static func locateCiteStudioBinary() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            root.appendingPathComponent(".build/debug/CiteStudio"),
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/CiteStudio"),
            root.appendingPathComponent(".build/out/Products/Debug/CiteStudio")
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        throw NSError(domain: "CLITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "CiteStudio debug binary not found; build target CiteStudio before running subprocess smoke check."
        ])
    }

    private static func runSubprocessCLI(
        args: [String],
        extraEnv: [String: String] = [:],
        timeoutSeconds: TimeInterval = 8.0
    ) throws -> (code: Int32, stdout: String, stderr: String) {
        let bin = try locateCiteStudioBinary()
        let tmpHome = FileManager.default.temporaryDirectory.appendingPathComponent("cs_cli_home_\(UUID().uuidString)")
        let tmpCache = tmpHome.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: tmpCache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tmpHome.path
        env["CITESTUDIO_CACHE_DIR"] = tmpCache.path
        env["CITESTUDIO_EPHEMERAL_DEFAULTS"] = "1"
        for (k, v) in extraEnv { env[k] = v }

        let proc = Process()
        proc.executableURL = bin
        proc.arguments = args
        proc.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        final class DataBox: @unchecked Sendable {
            var out = Data()
            var err = Data()
        }
        let box = DataBox()
        let group = DispatchGroup()

        try proc.run()
        group.enter()
        DispatchQueue.global().async {
            box.out = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            box.err = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            proc.waitUntilExit()
            throw NSError(domain: "CLITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "CLI subprocess timed out after \(timeoutSeconds)s for args: \(args)"
            ])
        }
        proc.waitUntilExit()
        _ = group.wait(timeout: .now() + 2.0)

        return (
            proc.terminationStatus,
            String(data: box.out, encoding: .utf8) ?? "",
            String(data: box.err, encoding: .utf8) ?? ""
        )
    }

    @Test("C10 (Row 6): --cli lint and --cli compile fail with non-zero exit code and clear bilingual stderr message on missing files, and unknown subcommands exit 2")
    func c10MissingFileAndUnknownSubcommandReturnNonZero() async throws {
        let missingTex = "/tmp/citestudio_definitely_nonexistent_\(UUID().uuidString).tex"

        let lintEN = await CiteStudioCLI.run(arguments: ["CiteStudio", "--cli", "lint", missingTex, "--lang", "en"])
        #expect(lintEN.exitCode != 0)
        #expect(lintEN.stderr.lowercased().contains("does not exist"))

        let lintZH = await CiteStudioCLI.run(arguments: ["CiteStudio", "--cli", "lint", missingTex, "--lang", "zh"])
        #expect(lintZH.exitCode != 0)
        #expect(lintZH.stderr.contains("不存在"))

        let compileEN = await CiteStudioCLI.run(arguments: ["CiteStudio", "--cli", "compile", missingTex, "--lang", "en"])
        #expect(compileEN.exitCode != 0)
        #expect(compileEN.stderr.lowercased().contains("does not exist"))

        let compileZH = await CiteStudioCLI.run(arguments: ["CiteStudio", "--cli", "compile", missingTex, "--lang", "zh"])
        #expect(compileZH.exitCode != 0)
        #expect(compileZH.stderr.contains("不存在"))

        let unknown = await CiteStudioCLI.run(arguments: ["CiteStudio", "--cli", "nonexistent-subcommand", "--lang", "en"])
        #expect(unknown.exitCode == 2)

        let emptyCLI = await CiteStudioCLI.run(arguments: ["CiteStudio", "--cli", "--lang", "zh"])
        #expect(emptyCLI.exitCode == 2)

        // Real executable subprocess smoke check (verifies CiteStudioMain exits cleanly before NSApplication)
        let subLint = try Self.runSubprocessCLI(args: ["--cli", "lint", missingTex, "--lang", "en"])
        #expect(subLint.code == 2)
        #expect(subLint.stderr.lowercased().contains("does not exist"))

        let subUnknown = try Self.runSubprocessCLI(args: ["--cli", "bogus", "--lang", "zh"])
        #expect(subUnknown.code == 2)
        #expect(subUnknown.stderr.contains("未知"))
    }

    @Test("合成 (Synthetic HTTP) C9 + Item 2: --cli verify <refs.bib> shares firewall engine, exits 0 only when all Verified, exits non-zero otherwise, and --cli clear-cache purges SQLite cache")
    func c9VerifyCommandAndClearCache() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_cli_v_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let server = try LoopbackScholarServer(initialMode: .healthy)
        defer { server.stop() }
        let cacheDir = tmp.appendingPathComponent("cache")
        let env = [
            "CITESTUDIO_CROSSREF_BASE_URL": server.crossrefBaseURL.absoluteString,
            "CITESTUDIO_OPENALEX_BASE_URL": server.openAlexBaseURL.absoluteString,
            "CITESTUDIO_CACHE_DIR": cacheDir.path
        ]

        let cleanBib = tmp.appendingPathComponent("clean.bib")
        try """
        @article{real_lecun, author = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey}, title = {Deep learning}, journal = {Nature}, year = {2015}, doi = {10.1038/nature14539}}
        """.write(to: cleanBib, atomically: true, encoding: .utf8)

        let okEN = await CiteStudioCLI.run(arguments: ["CiteStudio", "--cli", "verify", cleanBib.path, "--lang", "en"], environment: env)
        #expect(okEN.exitCode == 0)
        #expect(okEN.stdout.contains("[Verified] real_lecun"))

        let clearZH = await CiteStudioCLI.run(arguments: ["CiteStudio", "--cli", "clear-cache", "--lang", "zh"], environment: env)
        #expect(clearZH.exitCode == 0)
        #expect(clearZH.stdout.contains("已清空 1 条"))

        // Mixed bib with fabricated DOI -> MUST exit non-zero!
        let mixedBib = tmp.appendingPathComponent("mixed.bib")
        try """
        @article{real_lecun, author = {LeCun, Yann}, title = {Deep learning}, journal = {Nature}, year = {2015}, doi = {10.1038/nature14539}}
        @article{fake_one, author = {Nobody, X.}, title = {Fake}, journal = {Nature}, year = {2026}, doi = {10.1038/fake.2026.99999}}
        """.write(to: mixedBib, atomically: true, encoding: .utf8)

        let failEN = await CiteStudioCLI.run(arguments: ["CiteStudio", "--cli", "verify", mixedBib.path, "--json", "--lang", "en"], environment: env)
        #expect(failEN.exitCode == 1)
        #expect(failEN.stdout.contains("GhostPaper"))

        // Offline / HTTP 500 -> MUST output Unverified / 未验证 and exit non-zero!
        server.mode = .httpStatus(500)
        _ = await CiteStudioCLI.run(arguments: ["CiteStudio", "--cli", "clear-cache"], environment: env)
        let unverifiedZH = await CiteStudioCLI.run(arguments: ["CiteStudio", "--cli", "verify", cleanBib.path, "--lang", "zh"], environment: env)
        #expect(unverifiedZH.exitCode == 1)
        #expect(unverifiedZH.stdout.contains("未验证"))

        // Real executable subprocess smoke check on --cli verify
        server.mode = .healthy
        let subVerify = try Self.runSubprocessCLI(args: ["--cli", "verify", cleanBib.path, "--lang", "en"], extraEnv: env)
        #expect(subVerify.code == 0)
        #expect(subVerify.stdout.contains("Verified=1"))
    }

    @Test("合成 (Synthetic HTTP) C13 + C14: Single PreprintUpgrade exits 1 on --cli verify, default HTTP timeout is 8s, and README EN/ZH match code")
    func c13AndC14VerifyExitCodeTimeoutAndDocConsistency() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_cli_c13_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let server = try LoopbackScholarServer(initialMode: .healthy)
        defer { server.stop() }
        let cacheDir = tmp.appendingPathComponent("cache")
        let env = [
            "CITESTUDIO_CROSSREF_BASE_URL": server.crossrefBaseURL.absoluteString,
            "CITESTUDIO_OPENALEX_BASE_URL": server.openAlexBaseURL.absoluteString,
            "CITESTUDIO_CACHE_DIR": cacheDir.path
        ]

        // 1. Single PreprintUpgrade entry (FlashAttention arXiv -> NeurIPS 2022) MUST exit 1 in both EN and ZH
        let preprintBib = tmp.appendingPathComponent("preprint_only.bib")
        try """
        @article{dao2022flash, title = {FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness}, author = {Dao, Tri and Fu, Daniel Y.}, journal = {arXiv preprint arXiv:2205.14135}, year = {2022}}
        """.write(to: preprintBib, atomically: true, encoding: .utf8)

        let resEN = await CiteStudioCLI.run(arguments: ["CiteStudio", "--cli", "verify", preprintBib.path, "--lang", "en"], environment: env)
        #expect(resEN.exitCode == 1)
        #expect(resEN.stdout.contains("[PreprintUpgrade] dao2022flash"))
        #expect(resEN.stdout.contains("PreprintUpgrade=1"))

        let subZH = try Self.runSubprocessCLI(args: ["--cli", "verify", preprintBib.path, "--lang", "zh"], extraEnv: env)
        #expect(subZH.code == 1)
        #expect(subZH.stdout.contains("[PreprintUpgrade | 可升级正式版] dao2022flash"))
        #expect(subZH.stdout.contains("可升级(PreprintUpgrade)=1"))

        // 2. Default HTTP timeout in code is 8.0 seconds
        let defaultTransport = PublicScholarHTTPTransport(environment: [:])
        #expect(defaultTransport.timeoutInterval == 8.0)

        // 3. Crossref updated-by recognizes retract/withdraw, NOT removal
        let removalRecord = PublicScholarHTTPTransport.parseCrossrefMessage([
            "DOI": "10.9999/removal.only",
            "title": ["Notice With Removal Type Only"],
            "author": [["given": "Jane", "family": "Doe"]],
            "published-print": ["date-parts": [[2021, 1, 1]]],
            "container-title": ["Test Venue"],
            "updated-by": [["type": "removal", "label": "Removal"]]
        ])
        #expect(removalRecord?.isRetracted == false)

        // 4. Verify README.md and README.zh-CN.md match actual code behavior (C13, C14, PDF coarse granularity & missing index entry)
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readmeEN = try String(contentsOf: repoRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let readmeZH = try String(contentsOf: repoRoot.appendingPathComponent("README.zh-CN.md"), encoding: .utf8)

        #expect(!readmeEN.contains("Exits 0 ONLY when all entries are Verified (or PreprintUpgrade)"))
        #expect(!readmeZH.contains("仅当全部条目均为 Verified（或 PreprintUpgrade）时退出码为 0"))
        #expect(!readmeEN.contains("defaults to `12`"))
        #expect(!readmeZH.contains("默认 `12` 秒"))
        #expect(!readmeEN.contains("`removal`"))
        #expect(!readmeZH.contains("`removal`"))
        #expect(readmeEN.contains("defaults to `8`"))
        #expect(readmeZH.contains("默认 `8` 秒"))
    }

    @Test("C20: CLI commands without --lang follow LANG locale (zh_CN.UTF-8 vs en_US.UTF-8), and readme-commands.sh asserts active locale")
    func c20CLIDefaultLocaleAndReadmeReplayLocaleHandling() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_cli_c20_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let texFile = tmp.appendingPathComponent("clean.tex")
        try "\\documentclass{article}\n\\begin{document}\nClean manuscript paragraph.\n\\end{document}\n"
            .write(to: texFile, atomically: true, encoding: .utf8)

        let zhEnv = [
            "LANG": "zh_CN.UTF-8",
            "LC_ALL": "",
            "CITESTUDIO_LANG": "",
            "CITESTUDIO_CACHE_DIR": tmp.appendingPathComponent("cache_zh").path
        ]
        let enEnv = [
            "LANG": "en_US.UTF-8",
            "LC_ALL": "",
            "CITESTUDIO_LANG": "",
            "CITESTUDIO_CACHE_DIR": tmp.appendingPathComponent("cache_en").path
        ]

        // Without --lang, LANG=zh_CN.UTF-8 produces Chinese CLI output
        let clearZh = try Self.runSubprocessCLI(args: ["--cli", "clear-cache"], extraEnv: zhEnv)
        #expect(clearZh.code == 0)
        #expect(clearZh.stdout.contains("已清空 "))

        let lintZh = try Self.runSubprocessCLI(args: ["--cli", "lint", texFile.path], extraEnv: zhEnv)
        #expect(lintZh.code == 0)
        #expect(lintZh.stdout.contains("确定性行文与图表检查共发现问题：0 项"))

        // Without --lang, LANG=en_US.UTF-8 produces English CLI output
        let clearEn = try Self.runSubprocessCLI(args: ["--cli", "clear-cache"], extraEnv: enEnv)
        #expect(clearEn.code == 0)
        #expect(clearEn.stdout.contains("Cleared "))

        let lintEn = try Self.runSubprocessCLI(args: ["--cli", "lint", texFile.path], extraEnv: enEnv)
        #expect(lintEn.code == 0)
        #expect(lintEn.stdout.contains("Total deterministic findings: 0"))

        // Verify Scripts/acceptance/readme-commands.sh resolves active locale for commands without --lang
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readmeScript = try String(
            contentsOf: repoRoot.appendingPathComponent("Scripts/acceptance/readme-commands.sh"),
            encoding: .utf8
        )
        #expect(readmeScript.contains("resolve_active_cli_lang"))
    }

    @Test("C21 + C24: When CITESTUDIO_REAL_TECTONIC is unset or tectonic is absent on PATH, Swift Testing emits a native skipped record (never passed) and --cli status respects PATH")
    func c21AndC24TectonicTestEmitsActualSkippedFrameworkRecordWhenAbsentOnPath() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let strippedPath = "/usr/bin:/bin:/usr/sbin:/sbin"

        // 1. Direct unit & CLI status checks on PATH resolution (custom mock binary on PATH vs stripped PATH)
        let tmpBinDir = FileManager.default.temporaryDirectory.appendingPathComponent("cs_c24_bin_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpBinDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpBinDir) }
        let fakeTectonic = tmpBinDir.appendingPathComponent("tectonic")
        try "#!/bin/sh\nexit 0\n".write(to: fakeTectonic, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeTectonic.path)

        #expect(TectonicRunner.detectBinary(environment: ["PATH": strippedPath]) == nil)
        #expect(TectonicRunner.detectBinary(environment: ["PATH": "\(tmpBinDir.path):\(strippedPath)"])?.path == fakeTectonic.path)
        #expect(TypstRunner.detectBinary(environment: ["PATH": strippedPath]) == nil)

        let statusStrippedEN = try Self.runSubprocessCLI(
            args: ["--cli", "status", "--lang", "en"],
            extraEnv: ["PATH": strippedPath]
        )
        #expect(statusStrippedEN.code == 0)
        #expect(statusStrippedEN.stdout.contains("Tectonic: not installed"))

        // 2. Execute the actual Swift Testing test runner binary directly on realTectonicCompilation (avoids recursive SwiftPM .build lock)
        func runFilteredSwiftTest(realTectonicFlag: String?) throws -> (code: Int32, output: String) {
            let tmpHome = FileManager.default.temporaryDirectory.appendingPathComponent("cs_c24_home_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpHome) }

            var env = ProcessInfo.processInfo.environment
            env["HOME"] = tmpHome.path
            env["PATH"] = strippedPath
            env["CITESTUDIO_EPHEMERAL_DEFAULTS"] = "1"
            env["HTTP_PROXY"] = "http://127.0.0.1:9"
            env["HTTPS_PROXY"] = "http://127.0.0.1:9"
            env["NO_PROXY"] = "127.0.0.1,localhost"
            if let realTectonicFlag {
                env["CITESTUDIO_REAL_TECTONIC"] = realTectonicFlag
            } else {
                env.removeValue(forKey: "CITESTUDIO_REAL_TECTONIC")
            }

            let proc = Process()
            proc.currentDirectoryURL = repoRoot
            if let bundleFlagIdx = CommandLine.arguments.firstIndex(of: "--test-bundle-path"),
               bundleFlagIdx + 1 < CommandLine.arguments.count {
                proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                proc.arguments = [
                    "--test-bundle-path",
                    CommandLine.arguments[bundleFlagIdx + 1],
                    "--testing-library",
                    "swift-testing",
                    "--filter",
                    "CiteStudioCoreTests.CiteStudioCoreTests/realTectonicCompilation",
                    "--no-parallel"
                ]
            } else {
                let xctestCandidates = [
                    repoRoot.appendingPathComponent(".build/out/Products/Debug/CiteStudioCoreTests.xctest").path,
                    repoRoot.appendingPathComponent(".build/debug/CiteStudioPackageTests.xctest").path,
                    repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/CiteStudioPackageTests.xctest").path
                ]
                let bundlePath = try #require(xctestCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }))
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                proc.arguments = ["xctest", bundlePath]
            }
            proc.environment = env

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }

        let targetLabel = "Real Tectonic compilation produces PDF and SyncTeX output"

        // Case A: CITESTUDIO_REAL_TECTONIC unset -> framework emits skipped record, never passed
        let unsetRun = try runFilteredSwiftTest(realTectonicFlag: nil)
        #expect(unsetRun.code == 0, "Expected exit 0 when skipped, output:\n\(unsetRun.output)")
        let unsetLines = unsetRun.output.components(separatedBy: .newlines)
        let unsetSkipped = unsetLines.contains { line in
            (line.hasPrefix("➜ Test \"\(targetLabel)\"") || line.hasPrefix("◇ Test \"\(targetLabel)\""))
                && line.contains("skipped")
        }
        let unsetPassed = unsetLines.contains { line in
            line.hasPrefix("✔ Test \"\(targetLabel)\"") && line.contains("passed")
        }
        #expect(unsetSkipped, "Expected Swift Testing skipped line in actual output, got:\n\(unsetRun.output)")
        #expect(!unsetPassed, "Skipped test must never be emitted as passed:\n\(unsetRun.output)")

        // Case B: CITESTUDIO_REAL_TECTONIC=1 with tectonic absent on PATH -> framework STILL emits skipped record, never passed
        let noPathRun = try runFilteredSwiftTest(realTectonicFlag: "1")
        #expect(noPathRun.code == 0, "Expected exit 0 (skipped) when tectonic is absent on PATH, got exit \(noPathRun.code):\n\(noPathRun.output)")
        let noPathLines = noPathRun.output.components(separatedBy: .newlines)
        let noPathSkipped = noPathLines.contains { line in
            (line.hasPrefix("➜ Test \"\(targetLabel)\"") || line.hasPrefix("◇ Test \"\(targetLabel)\""))
                && line.contains("skipped")
        }
        let noPathPassed = noPathLines.contains { line in
            line.hasPrefix("✔ Test \"\(targetLabel)\"") && line.contains("passed")
        }
        #expect(noPathSkipped, "Expected Swift Testing skipped line when tectonic is absent on PATH, got:\n\(noPathRun.output)")
        #expect(!noPathPassed, "Test without tectonic on PATH must never be emitted as passed:\n\(noPathRun.output)")
    }

    @Test("C23: validate_recorded_fixtures.py verifies manifest URL/privacy, requested_at, HTTP Date header, and raw SHA-256, and rejects 1-byte tampering or blank Date")
    func c23RecordedFixtureValidatorAndRecorderHardening() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let validatorURL = repoRoot.appendingPathComponent("Scripts/acceptance/validate_recorded_fixtures.py")
        let recorderURL = repoRoot.appendingPathComponent("Scripts/acceptance/record-fixtures.sh")
        #expect(FileManager.default.fileExists(atPath: validatorURL.path))

        let recorderSource = try String(contentsOf: recorderURL, encoding: .utf8)
        #expect(recorderSource.contains("USER_AGENT = \"CiteStudio/0.2.0\""))
        #expect(recorderSource.contains("MAX_REQUESTS = 24"))
        #expect(recorderSource.contains("response_date_header"))
        #expect(recorderSource.contains("total_http_requests_sent"))

        let m0AcceptanceSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Scripts/acceptance/m0-acceptance.sh"),
            encoding: .utf8
        )
        let readmeReplaySource = try String(
            contentsOf: repoRoot.appendingPathComponent("Scripts/acceptance/readme-commands.sh"),
            encoding: .utf8
        )
        #expect(m0AcceptanceSource.contains("validate_recorded_fixtures.py"))
        #expect(readmeReplaySource.contains("validate_recorded_fixtures.py"))

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs_c23_val_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        func runValidator(on dir: URL, allowCount: Int = 1, expectedManifestSha: String? = nil) throws -> (Int32, String, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            var args = [validatorURL.path, dir.path, "--min-items", "\(allowCount)"]
            if let expectedManifestSha {
                args.append(contentsOf: ["--expected-manifest-sha256", expectedManifestSha])
            }
            p.arguments = args
            let out = Pipe()
            let err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            p.waitUntilExit()
            return (
                p.terminationStatus,
                String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            )
        }

        // Build a valid minimal 1-item fixture directory in tmp
        let rawBytes = Data(#"{"status":"ok","message":{"DOI":"10.1038/nature14539"}}"#.utf8)
        let rawPath = tmp.appendingPathComponent("crossref_doi_sample.raw")
        try rawBytes.write(to: rawPath)

        // Compute sha256 via /usr/bin/shasum -a 256
        let shaProc = Process()
        shaProc.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        shaProc.arguments = ["-a", "256", rawPath.path]
        let shaPipe = Pipe()
        shaProc.standardOutput = shaPipe
        try shaProc.run()
        shaProc.waitUntilExit()
        let shaOut = String(data: shaPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let digest = String(shaOut.split(separator: " ").first ?? "")

        let item: [String: Any] = [
            "slug": "crossref_doi_sample",
            "service": "crossref",
            "url": "https://api.crossref.org/works/10.1038/nature14539",
            "status": 200,
            "requested_at": "2026-11-15T00:00:00Z",
            "response_date_header": "Sun, 15 Nov 2026 00:00:00 GMT",
            "content_type": "application/json;charset=UTF-8",
            "raw_file": "crossref_doi_sample.raw",
            "byte_length": rawBytes.count,
            "sha256": digest,
            "attempts": 1
        ]
        let metaData = try JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys])
        try metaData.write(to: tmp.appendingPathComponent("crossref_doi_sample.meta.json"))

        let manifest: [String: Any] = [
            "started_at": "2026-11-15T00:00:00Z",
            "completed_at": "2026-11-15T00:00:02Z",
            "user_agent": "CiteStudio/0.2.0",
            "count": 1,
            "total_http_requests_sent": 1,
            "items": [item]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: tmp.appendingPathComponent("manifest.json"))

        // 1. Valid directory passes (and passes with matching --expected-manifest-sha256, fails with mismatched digest)
        let manifestPath = tmp.appendingPathComponent("manifest.json")
        let manifestShaProc = Process()
        manifestShaProc.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        manifestShaProc.arguments = ["-a", "256", manifestPath.path]
        let manifestShaPipe = Pipe()
        manifestShaProc.standardOutput = manifestShaPipe
        try manifestShaProc.run()
        manifestShaProc.waitUntilExit()
        let manifestShaOut = String(data: manifestShaPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let pinnedManifestDigest = String(manifestShaOut.split(separator: " ").first ?? "")

        let validRes = try runValidator(on: tmp, allowCount: 1, expectedManifestSha: pinnedManifestDigest)
        #expect(validRes.0 == 0, "Expected valid manifest to pass, stderr=\(validRes.2)")

        let wrongPinRes = try runValidator(
            on: tmp,
            allowCount: 1,
            expectedManifestSha: String(repeating: "0", count: 64)
        )
        #expect(wrongPinRes.0 != 0)
        #expect(wrongPinRes.2.contains("manifest.json sha256 mismatch"))

        // 2. Corrupt 1 byte in .raw -> MUST fail!
        var corrupted = rawBytes
        corrupted[0] ^= 0x01
        try corrupted.write(to: rawPath)
        let corruptRes = try runValidator(on: tmp, allowCount: 1)
        #expect(corruptRes.0 != 0)
        try rawBytes.write(to: rawPath) // restore

        // 3. Blank response_date_header -> MUST fail!
        var badItem = item
        badItem["response_date_header"] = ""
        var badManifest = manifest
        badManifest["items"] = [badItem]
        try JSONSerialization.data(withJSONObject: badItem, options: [.prettyPrinted, .sortedKeys])
            .write(to: tmp.appendingPathComponent("crossref_doi_sample.meta.json"))
        try JSONSerialization.data(withJSONObject: badManifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: tmp.appendingPathComponent("manifest.json"))
        let blankDateRes = try runValidator(on: tmp, allowCount: 1)
        #expect(blankDateRes.0 != 0)
    }

    @Test("CR3: Handwritten-body C5 tests carry '合成' in file header and test name, and m1-acceptance.sh Part B states it is synthetic and not C5 evidence")
    func cr3SyntheticC5TestsAndAcceptancePartBAreExplicitlyMarkedSyntheticNonEvidence() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let synthC5URL = repoRoot.appendingPathComponent("Tests/CiteStudioCoreTests/SyntheticC5TitleCandidateTests.swift")
        #expect(FileManager.default.fileExists(atPath: synthC5URL.path))
        let synthC5Source = (try? String(contentsOf: synthC5URL, encoding: .utf8)) ?? ""
        let synthHeader = synthC5Source.components(separatedBy: .newlines).prefix(10).joined(separator: "\n")
        #expect(synthHeader.contains("合成"))
        #expect(synthHeader.contains("不算 C5"))
        #expect(synthC5Source.contains("@Test(\"合成"))

        let firewallSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Tests/CiteStudioCoreTests/FirewallTests.swift"),
            encoding: .utf8
        )
        #expect(!firewallSource.contains("LoopbackC5TitleCandidateServer"))
        #expect(firewallSource.components(separatedBy: .newlines).prefix(10).joined(separator: "\n").contains("合成"))

        let fixturesHeader = try String(
            contentsOf: repoRoot.appendingPathComponent("Tests/CiteStudioCoreTests/TestFixtures.swift"),
            encoding: .utf8
        ).components(separatedBy: .newlines).prefix(10).joined(separator: "\n")
        #expect(fixturesHeader.contains("合成"))

        let mcpSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Tests/CiteStudioCoreTests/MCPTests.swift"),
            encoding: .utf8
        )
        #expect(mcpSource.components(separatedBy: .newlines).prefix(10).joined(separator: "\n").contains("合成"))
        #expect(mcpSource.contains("@Test(\"合成"))

        let m1Script = try String(
            contentsOf: repoRoot.appendingPathComponent("Scripts/acceptance/m1-acceptance.sh"),
            encoding: .utf8
        )
        #expect(m1Script.contains("不算 C5 的证据"))
        #expect(m1Script.contains("[INFO · 合成"))
    }
}
