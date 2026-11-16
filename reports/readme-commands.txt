==================================================================
CiteStudio README Command Replay (readme-commands.sh)
Timestamp (UTC): 2026-11-16T20:02:37Z
==================================================================
[PASS] Extracted 16 commands from README.md and README.zh-CN.md (100% parity).
[PASS] C23 validator: VALID_RECORDED_FIXTURES: items=28 total_http_requests_sent=28 started_at=2026-11-14T20:29:06Z completed_at=2026-11-16T19:38:41Z m0_baseline_20_byte_identical=true
[INFO] Active default CLI language resolved from environment: zh

[1/16] $ git clone https://github.com/zxu756/CiteStudio.git
  [SKIPPED] External network git clone; running against current checked-out repository.

[2/16] $ cd CiteStudio
  [SKIPPED] Directory navigation step; commands execute inside isolated replay workspace.

[3/16] $ swift build
  [PASS] exit=0, verified executable .build/debug/CiteStudio exists.

[4/16] $ ./Scripts/test.sh milestone 0
  [SKIPPED] Parent M0 orchestrator command (already invoking readme-commands.sh; avoids recursion).

[5/16] $ .build/debug/CiteStudio --cli status
  stdout: CiteStudio 0.2.0 | Tectonic: <COMPILER_PATH> | Typst: 未安装
  [PASS] exit=0, matched 'CiteStudio 0.2.0 | Tectonic: ... | Typst: ...' (locale=zh).

[6/16] $ .build/debug/CiteStudio --cli verify path/to/references.bib
  [PASS] exit=0, matched '[Verified | 已验证]' and '已验证(Verified)=1'.

[7/16] $ .build/debug/CiteStudio --cli verify path/to/references.bib --json
  [PASS] exit=0, JSON summary.verified == 1, verdict == 'Verified', badge == '已验证'.

[8/16] $ .build/debug/CiteStudio --cli verify path/to/references.bib --lang zh
  [PASS] exit=0, matched '[Verified | 已验证]' and '已验证(Verified)=1'.

[9/16] $ .build/debug/CiteStudio --cli clear-cache
  stdout: 已清空 1 条引文核查缓存记录（<TMP_DIR>）。
  [PASS] exit=0, matched '已清空 ... 条引文核查缓存记录' (locale=zh, product SQLite DB verified).

[10/16] $ .build/debug/CiteStudio --cli clear-cache --lang zh
  stdout: 已清空 0 条引文核查缓存记录（<TMP_DIR>）。
  [PASS] exit=0, matched '已清空 ... 条引文核查缓存记录'.

[11/16] $ .build/debug/CiteStudio --cli lint path/to/main.tex
  stdout: 确定性行文与图表检查共发现问题：0 项
  [PASS] exit=0, matched '确定性行文与图表检查共发现问题：0 项' (locale=zh).

[12/16] $ .build/debug/CiteStudio --cli lint path/to/main.tex --lang zh
  stdout: 确定性行文与图表检查共发现问题：0 项
  [PASS] exit=0, matched '确定性行文与图表检查共发现问题：0 项'.

[13/16] $ .build/debug/CiteStudio --cli compile path/to/main.tex
  [SKIPPED] CITESTUDIO_REAL_TECTONIC!=1; real tectonic compilation requires external TeX bundle cache / network (C18 / General Rule §4).

[14/16] $ printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | .build/debug/CiteStudio --mcp
  stdout: {"id":1,"result":{"tools":[{"name":"verify_citation","description":"Verify a BibTeX entry against Crossref, OpenAlex, and local SQLite cache.","inputSchema":{"type":"object","required":["bibtex"],"properties":{"bibtex":{"type":"string"}}}},{"name":"add_verified_bibtex","description":"Append canonical BibTeX metadata to a .bib file ONLY if verified against Crossref \/ OpenAlex (returns ERR_UNVERIFIED_CITATION on ghost, mismatched, retracted, or unverified entries).","inputSchema":{"required":["bib_file","bibtex"],"properties":{"bib_file":{"type":"string"},"bibtex":{"type":"string"}},"type":"object"}},{"name":"search_local_pdfs","description":"BM25 search across pre-indexed PDF passages in pdf_fts5.sqlite (note: no CLI\/MCP indexing tool is exposed yet; returns empty unless populated via LocalPDFIndexer).","inputSchema":{"required":["query"],"type":"object","properties":{"cite_key":{"type":"string"},"query":{"type":"string"}}}},{"name":"get_claim_evidence","inputSchema":{"properties":{"claim_sentence":{"type":"string"},"cite_key":{"type":"string"}},"required":["claim_sentence","cite_key"],"type":"object"},"description":"Keyword BM25 lookup against pre-indexed PDF text blocks in pdf_fts5.sqlite (returns coarse block\/page bounds without numeric or negation verification; requires pre-populated index)."},{"inputSchema":{"properties":{"manuscript_text":{"type":"string"}},"type":"object","required":["manuscript_text"]},"description":"Run deterministic writing-anti-ai and paper-polish checks on LaTeX\/Typst prose.","name":"audit_manuscript"},{"name":"compile_pdf","description":"Compile a .tex or .typ file using local Tectonic or Typst.","inputSchema":{"type":"object","properties":{"source_file":{"type":"string"}},"required":["source_file"]}}]},"jsonrpc":"2.0"}
  [PASS] exit=0, verified all 6 MCP tools: ['add_verified_bibtex', 'audit_manuscript', 'compile_pdf', 'get_claim_evidence', 'search_local_pdfs', 'verify_citation'].

[15/16] $ .build/debug/CiteStudio
  [SKIPPED] Desktop GUI launch forbidden in automated acceptance/test scripts (C19 / W6).

[16/16] $ .build/debug/CiteStudio --demo --lang zh
  [SKIPPED] Desktop GUI launch forbidden in automated acceptance/test scripts (C19 / W6).

[Extra Check] $ ./Scripts/acceptance/record-fixtures.sh (with CITESTUDIO_RECORD unset)
  stdout: SKIPPED: Set CITESTUDIO_RECORD=1 after explicit user approval to record live Crossref/OpenAlex fixtures.
  [PASS] exit=0, default non-network gate verified.

==================================================================
README_REPLAY_SUMMARY: total=16 passed=10 skipped=6 (skipped items NOT counted as passed; locale=zh)
==================================================================
