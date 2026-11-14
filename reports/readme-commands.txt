==================================================================
CiteStudio README Command Replay (readme-commands.sh)
Timestamp (UTC): 2026-11-14T04:38:47Z
==================================================================

$ .build/debug/CiteStudio --cli status
CiteStudio 0.2.0 | Tectonic: /opt/homebrew/bin/tectonic | Typst: not installed

$ .build/debug/CiteStudio --cli verify path/to/references.bib
[Verified] lecun2015deep — Verified via Crossref (Nature, 2015) | DOI: 10.1038/nature14539
Summary: Evaluated=1 Verified=1 PreprintUpgrade=0 MetadataMismatch=0 Retracted=0 GhostPaper=0 Unverified=0

$ .build/debug/CiteStudio --cli verify path/to/references.bib --json
{
  "entries" : [
    {
      "badge" : "VERIFIED",
      "citeKey" : "lecun2015deep",
      "detail" : "DOI: 10.1038\/nature14539",
      "headline" : "Verified via Crossref (Nature, 2015)",
      "verdict" : "Verified"
    }
  ],
  "summary" : {
    "evaluated" : 1,
    "ghostPaper" : 0,
    "metadataMismatch" : 0,
    "preprintUpgrade" : 0,
    "retracted" : 0,
    "unverified" : 0,
    "verified" : 1
  }
}

$ .build/debug/CiteStudio --cli verify path/to/references.bib --lang zh
[Verified | 已验证] lecun2015deep — 已通过 Crossref 核验（Nature, 2015） | DOI 10.1038/nature14539
核查汇总：共 1 条 · 已验证(Verified)=1 · 可升级(PreprintUpgrade)=0 · 元数据不符(MetadataMismatch)=0 · 已撤稿(Retracted)=0 · 确认不存在(GhostPaper)=0 · 未验证(Unverified)=0

$ .build/debug/CiteStudio --cli clear-cache
Cleared 1 cached citation verification entries (/var/folders/d5/4h6nzhm94l91870kmn7p8q040000gn/T//citestudio-readme.m7yYsN/cache/scholar_cache.sqlite).

$ .build/debug/CiteStudio --cli clear-cache --lang zh
已清空 0 条引文核查缓存记录（/var/folders/d5/4h6nzhm94l91870kmn7p8q040000gn/T//citestudio-readme.m7yYsN/cache/scholar_cache.sqlite）。

$ .build/debug/CiteStudio --cli lint path/to/main.tex
Total deterministic findings: 0

$ .build/debug/CiteStudio --cli lint path/to/main.tex --lang zh
确定性行文与图表检查共发现问题：0 项

$ .build/debug/CiteStudio --cli compile path/to/main.tex
Engine: tectonic | Succeeded: true | Duration: 154 ms
Output PDF: /var/folders/d5/4h6nzhm94l91870kmn7p8q040000gn/T//citestudio-readme.m7yYsN/path/to/main.pdf

$ printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | .build/debug/CiteStudio --mcp
{"id":1,"result":{"tools":[{"inputSchema":{"properties":{"bibtex":{"type":"string"}},"type":"object","required":["bibtex"]},"name":"verify_citation","description":"Verify a BibTeX entry against Crossref, OpenAlex, and local SQLite cache."},{"name":"add_verified_bibtex","description":"Append canonical BibTeX metadata to a .bib file ONLY if verified against Crossref \/ OpenAlex (returns ERR_UNVERIFIED_CITATION on ghost, mismatched, retracted, or unverified entries).","inputSchema":{"required":["bib_file","bibtex"],"type":"object","properties":{"bib_file":{"type":"string"},"bibtex":{"type":"string"}}}},{"name":"search_local_pdfs","description":"BM25 full-text search across local reference PDFs indexed with PDFKit.","inputSchema":{"properties":{"query":{"type":"string"},"cite_key":{"type":"string"}},"required":["query"],"type":"object"}},{"inputSchema":{"type":"object","properties":{"claim_sentence":{"type":"string"},"cite_key":{"type":"string"}},"required":["claim_sentence","cite_key"]},"description":"Find the highest-BM25 PDF passage candidate for a manuscript sentence.","name":"get_claim_evidence"},{"name":"audit_manuscript","description":"Run deterministic writing-anti-ai and paper-polish checks on LaTeX\/Typst prose.","inputSchema":{"properties":{"manuscript_text":{"type":"string"}},"required":["manuscript_text"],"type":"object"}},{"name":"compile_pdf","description":"Compile a .tex or .typ file using local Tectonic or Typst.","inputSchema":{"required":["source_file"],"type":"object","properties":{"source_file":{"type":"string"}}}}]},"jsonrpc":"2.0"}

[PASS] Every documented README / README.zh-CN command executed cleanly.
