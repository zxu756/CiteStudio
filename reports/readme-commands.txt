==================================================================
CiteStudio README Command Replay (readme-commands.sh)
Timestamp (UTC): 2026-11-14T08:40:57Z
==================================================================
[PASS] Extracted 16 commands from README.md and README.zh-CN.md (100% parity).

[1/16] $ git clone https://github.com/zxu756/CiteStudio.git
  [SKIPPED] External network git clone; running against current checked-out repository.

[2/16] $ cd CiteStudio
  [SKIPPED] Directory navigation step; commands execute inside isolated replay workspace.

[3/16] $ swift build
  [PASS] exit=0, verified executable .build/debug/CiteStudio exists.

[4/16] $ ./Scripts/test.sh milestone 0
  [SKIPPED] Parent M0 orchestrator command (already invoking readme-commands.sh; avoids recursion).

[5/16] $ .build/debug/CiteStudio --cli status
  stdout: CiteStudio 0.2.0 | Tectonic: /opt/homebrew/bin/tectonic | Typst: not installed
  [PASS] exit=0, matched 'CiteStudio 0.2.0 | Tectonic: ... | Typst: ...'.

[6/16] $ .build/debug/CiteStudio --cli verify path/to/references.bib
  [SKIPPED (没跑)] Tests/Fixtures/recorded/ has no recorded fixtures yet; run CITESTUDIO_RECORD=1 ./Scripts/acceptance/record-fixtures.sh after user approval (C15).

[7/16] $ .build/debug/CiteStudio --cli verify path/to/references.bib --json
  [SKIPPED (没跑)] Tests/Fixtures/recorded/ has no recorded fixtures yet; run CITESTUDIO_RECORD=1 ./Scripts/acceptance/record-fixtures.sh after user approval (C15).

[8/16] $ .build/debug/CiteStudio --cli verify path/to/references.bib --lang zh
  [SKIPPED (没跑)] Tests/Fixtures/recorded/ has no recorded fixtures yet; run CITESTUDIO_RECORD=1 ./Scripts/acceptance/record-fixtures.sh after user approval (C15).

[9/16] $ .build/debug/CiteStudio --cli clear-cache
  stdout: Cleared 0 cached citation verification entries (<TMP_DIR>).
  [PASS] exit=0, matched 'Cleared ... cached citation verification entries' (product SQLite DB verified).

[10/16] $ .build/debug/CiteStudio --cli clear-cache --lang zh
  stdout: 已清空 0 条引文核查缓存记录（<TMP_DIR>）。
  [PASS] exit=0, matched '已清空 ... 条引文核查缓存记录'.

[11/16] $ .build/debug/CiteStudio --cli lint path/to/main.tex
  stdout: Total deterministic findings: 0
  [PASS] exit=0, matched 'Total deterministic findings: 0'.

[12/16] $ .build/debug/CiteStudio --cli lint path/to/main.tex --lang zh
  stdout: 确定性行文与图表检查共发现问题：0 项
  [PASS] exit=0, matched '确定性行文与图表检查共发现问题：0 项'.

[13/16] $ .build/debug/CiteStudio --cli compile path/to/main.tex
  [SKIPPED] CITESTUDIO_REAL_TECTONIC!=1; real tectonic compilation requires external TeX bundle cache / network (C18 / General Rule §4).

[14/16] $ printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | .build/debug/CiteStudio --mcp
  stdout: {"id":1,"result":{"tools":[{"description":"Verify a BibTeX entry against Crossref, OpenAlex, and local SQLite cache.","name":"verify_citation","inputSchema":{"required":["bibtex"],"properties":{"bibtex":{"type":"string"}},"type":"object"}},{"name":"add_verified_bibtex","description":"Append canonical BibTeX metadata to a .bib file ONLY if verified against Crossref \/ OpenAlex (returns ERR_UNVERIFIED_CITATION on ghost, mismatched, retracted, or unverified entries).","inputSchema":{"type":"object","required":["bib_file","bibtex"],"properties":{"bibtex":{"type":"string"},"bib_file":{"type":"string"}}}},{"name":"search_local_pdfs","description":"BM25 search across pre-indexed PDF passages in pdf_fts5.sqlite (note: no CLI\/MCP indexing tool is exposed yet; returns empty unless populated via LocalPDFIndexer).","inputSchema":{"properties":{"query":{"type":"string"},"cite_key":{"type":"string"}},"required":["query"],"type":"object"}},{"inputSchema":{"type":"object","required":["claim_sentence","cite_key"],"properties":{"cite_key":{"type":"string"},"claim_sentence":{"type":"string"}}},"name":"get_claim_evidence","description":"Keyword BM25 lookup against pre-indexed PDF text blocks in pdf_fts5.sqlite (returns coarse block\/page bounds without numeric or negation verification; requires pre-populated index)."},{"inputSchema":{"type":"object","properties":{"manuscript_text":{"type":"string"}},"required":["manuscript_text"]},"description":"Run deterministic writing-anti-ai and paper-polish checks on LaTeX\/Typst prose.","name":"audit_manuscript"},{"name":"compile_pdf","description":"Compile a .tex or .typ file using local Tectonic or Typst.","inputSchema":{"type":"object","properties":{"source_file":{"type":"string"}},"required":["source_file"]}}]},"jsonrpc":"2.0"}
  [PASS] exit=0, verified all 6 MCP tools: ['add_verified_bibtex', 'audit_manuscript', 'compile_pdf', 'get_claim_evidence', 'search_local_pdfs', 'verify_citation'].

[15/16] $ .build/debug/CiteStudio
  [SKIPPED] Desktop GUI launch forbidden in automated acceptance/test scripts (C19 / W6).

[16/16] $ .build/debug/CiteStudio --demo --lang zh
  [SKIPPED] Desktop GUI launch forbidden in automated acceptance/test scripts (C19 / W6).

[Extra Check] $ ./Scripts/acceptance/record-fixtures.sh (with CITESTUDIO_RECORD unset)
  stdout: SKIPPED: Set CITESTUDIO_RECORD=1 after explicit user approval to record live Crossref/OpenAlex fixtures.
  [PASS] exit=0, default non-network gate verified.

==================================================================
[PASS] README / README.zh-CN command replay complete: total=16, executed_with_assertions=7, skipped_with_reasons=9.
==================================================================
