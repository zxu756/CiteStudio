import Foundation

/// Hardware-grade Citation Firewall MCP Server: blocks hallucinated/retracted BibTeX writes with `ERR_UNVERIFIED_CITATION`.
public final class CiteStudioMCPServer: @unchecked Sendable {
    private let triangulator: ScholarTriangulator
    private let pdfIndexer: LocalPDFIndexer

    public init(triangulator: ScholarTriangulator, pdfIndexer: LocalPDFIndexer) {
        self.triangulator = triangulator
        self.pdfIndexer = pdfIndexer
    }

    public func runStdioLoop() {
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                if let resp = await self.handleJSONLine(line) {
                    print(resp)
                    fflush(stdout)
                }
                semaphore.signal()
            }
            semaphore.wait()
        }
    }

    public func handleJSONLine(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let id = req["id"]
        let method = (req["method"] as? String) ?? ""
        let params = (req["params"] as? [String: Any]) ?? [:]

        switch method {
        case "initialize":
            return encodeResponse(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "citestudio-firewall-mcp", "version": "0.2.0"]
            ])

        case "notifications/initialized":
            return nil

        case "tools/list":
            return encodeResponse(id: id, result: ["tools": Self.toolDefinitions])

        case "tools/call":
            let name = (params["name"] as? String) ?? ""
            let args = (params["arguments"] as? [String: Any]) ?? [:]
            return await dispatchTool(id: id, name: name, args: args)

        default:
            return encodeError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func dispatchTool(id: Any?, name: String, args: [String: Any]) async -> String {
        switch name {
        case "verify_citation":
            let bib = (args["bibtex"] as? String) ?? ""
            guard let entry = BibTeXParser.parseBibTeX(bib).first else {
                return encodeToolResult(id: id, isError: true, text: "ERR_INVALID_BIBTEX: Could not parse BibTeX stanza.")
            }
            let diag = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: entry, triangulator: triangulator)
            return encodeToolJSON(id: id, isError: diag.kind.isBlockingForMCP, payload: [
                "citeKey": diag.citeKey,
                "verdict": diag.kind.rawValue,
                "headline": diag.headline,
                "detail": diag.detail,
                "upgradedBibTeX": diag.upgradedBibTeX as Any
            ])

        case "add_verified_bibtex":
            let bibPath = (args["bib_file"] as? String) ?? ""
            let bibStanza = (args["bibtex"] as? String) ?? ""
            guard !bibPath.isEmpty else {
                return encodeToolResult(id: id, isError: true, text: "ERR_MISSING_PATH: 'bib_file' argument is required.")
            }
            let parsed = BibTeXParser.parseBibTeX(bibStanza)
            guard let entry = parsed.first else {
                return encodeToolResult(id: id, isError: true, text: "ERR_INVALID_BIBTEX: Malformed BibTeX entry.")
            }

            let diag = await CitationDiagnosticsEngine.evaluateSingleEntry(entry: entry, triangulator: triangulator)
            if diag.kind.isBlockingForMCP {
                return encodeToolJSON(
                    id: id,
                    isError: true,
                    payload: [
                        "error_code": "ERR_UNVERIFIED_CITATION",
                        "cite_key": entry.citeKey,
                        "verdict": diag.kind.rawValue,
                        "reason": diag.detail,
                        "action": "Write rejected before touching \(URL(fileURLWithPath: bibPath).lastPathComponent)."
                    ]
                )
            }

            let targetURL = URL(fileURLWithPath: bibPath)
            let existing = (try? String(contentsOf: targetURL, encoding: .utf8)) ?? ""
            let stanzaToAppend = diag.upgradedBibTeX ?? bibStanza.trimmingCharacters(in: .whitespacesAndNewlines)
            let updated = existing.isEmpty ? (stanzaToAppend + "\n") : (existing.trimmingCharacters(in: .newlines) + "\n\n" + stanzaToAppend + "\n")
            do {
                try updated.write(to: targetURL, atomically: true, encoding: .utf8)
            } catch {
                return encodeToolResult(id: id, isError: true, text: "ERR_IO: \(error.localizedDescription)")
            }

            return encodeToolJSON(id: id, isError: false, payload: [
                "status": "APPENDED_VERIFIED",
                "cite_key": entry.citeKey,
                "verdict": diag.kind.rawValue,
                "auto_upgraded_from_preprint": diag.upgradedBibTeX != nil
            ])

        case "search_local_pdfs":
            let query = (args["query"] as? String) ?? ""
            let citeKey = args["cite_key"] as? String
            let terms = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
            let hits = pdfIndexer.searchBM25(queryTerms: terms, citeKey: citeKey, limit: 5)
            let items = hits.map { h in
                [
                    "citeKey": h.citeKey,
                    "pdf": h.pdfFilename,
                    "page": h.pageNumber,
                    "confidence": h.confidenceScore,
                    "snippet": h.verbatimSnippet
                ] as [String: Any]
            }
            return encodeToolJSON(id: id, isError: false, payload: ["matches": items])

        case "get_claim_evidence":
            let claim = (args["claim_sentence"] as? String) ?? ""
            let citeKey = (args["cite_key"] as? String) ?? ""
            if let ev = ClaimEvidenceMatcher.matchClaim(sentence: claim, citeKey: citeKey, indexer: pdfIndexer) {
                return encodeToolJSON(id: id, isError: false, payload: [
                    "found": true,
                    "citeKey": ev.citeKey,
                    "pdf": ev.pdfFilename,
                    "page": ev.pageNumber,
                    "rect": [ev.rectX, ev.rectY, ev.rectWidth, ev.rectHeight],
                    "confidence": ev.confidenceScore,
                    "verbatimSnippet": ev.verbatimSnippet
                ])
            }
            return encodeToolJSON(id: id, isError: false, payload: ["found": false, "citeKey": citeKey])

        case "audit_manuscript":
            let manuscript = (args["manuscript_text"] as? String) ?? ""
            let findings = WritingQualityLinter.lint(manuscript: manuscript)
            let rows = findings.map {
                [
                    "ruleId": $0.ruleId,
                    "category": $0.category,
                    "line": $0.lineNumber,
                    "matched": $0.matchedText,
                    "suggestion": $0.suggestion
                ] as [String: Any]
            }
            return encodeToolJSON(id: id, isError: false, payload: ["count": rows.count, "findings": rows])

        case "compile_pdf":
            let path = (args["source_file"] as? String) ?? ""
            let url = URL(fileURLWithPath: path)
            let res: CompileResult = (url.pathExtension.lowercased() == "typ")
                ? TypstRunner.compile(typFile: url)
                : TectonicRunner.compile(texFile: url)
            return encodeToolJSON(id: id, isError: !res.succeeded, payload: [
                "engine": res.engine,
                "succeeded": res.succeeded,
                "pdfPath": res.pdfURL?.path as Any,
                "synctexPath": res.synctexURL?.path as Any,
                "durationMs": res.durationMs,
                "diagnostics": res.diagnostics.map { ["file": $0.file, "line": $0.line, "message": $0.message] }
            ])

        default:
            return encodeError(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
    }

    private func encodeResponse(id: Any?, result: [String: Any]) -> String {
        let obj: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func encodeError(id: Any?, code: Int, message: String) -> String {
        let obj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func encodeToolResult(id: Any?, isError: Bool, text: String) -> String {
        encodeResponse(id: id, result: [
            "isError": isError,
            "content": [["type": "text", "text": text]]
        ])
    }

    private func encodeToolJSON(id: Any?, isError: Bool, payload: [String: Any]) -> String {
        let pretty = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let text = String(data: pretty, encoding: .utf8) ?? "{}"
        return encodeToolResult(id: id, isError: isError, text: text)
    }

    private static var toolDefinitions: [[String: Any]] {
        [
        [
            "name": "verify_citation",
            "description": "Verify a BibTeX entry against Crossref, OpenAlex, and local SQLite cache.",
            "inputSchema": [
                "type": "object",
                "properties": ["bibtex": ["type": "string"]],
                "required": ["bibtex"]
            ]
        ],
        [
            "name": "add_verified_bibtex",
            "description": "Append a BibTeX entry to a .bib file ONLY if it passes the Citation Firewall (returns ERR_UNVERIFIED_CITATION on ghost or retracted papers).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bib_file": ["type": "string"],
                    "bibtex": ["type": "string"]
                ],
                "required": ["bib_file", "bibtex"]
            ]
        ],
        [
            "name": "search_local_pdfs",
            "description": "BM25 search across local reference PDFs indexed with PDFKit page coordinates.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "cite_key": ["type": "string"]
                ],
                "required": ["query"]
            ]
        ],
        [
            "name": "get_claim_evidence",
            "description": "Find the verbatim PDF passage and bounding box supporting a manuscript claim sentence.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "claim_sentence": ["type": "string"],
                    "cite_key": ["type": "string"]
                ],
                "required": ["claim_sentence", "cite_key"]
            ]
        ],
        [
            "name": "audit_manuscript",
            "description": "Run deterministic writing-anti-ai and paper-polish checks on LaTeX/Typst prose.",
            "inputSchema": [
                "type": "object",
                "properties": ["manuscript_text": ["type": "string"]],
                "required": ["manuscript_text"]
            ]
        ],
        [
            "name": "compile_pdf",
            "description": "Compile a .tex or .typ file using local Tectonic (--synctex) or Typst.",
            "inputSchema": [
                "type": "object",
                "properties": ["source_file": ["type": "string"]],
                "required": ["source_file"]
            ]
        ]
        ]
    }
}
