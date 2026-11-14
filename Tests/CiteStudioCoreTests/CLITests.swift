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

    @Test("C9 + Item 2: --cli verify <refs.bib> shares firewall engine, exits 0 only when all Verified, exits non-zero otherwise, and --cli clear-cache purges SQLite cache")
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

    @Test("C13 + C14: Single PreprintUpgrade exits 1 on --cli verify, default HTTP timeout is 8s, and README EN/ZH match code")
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
}
