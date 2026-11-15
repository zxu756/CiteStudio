#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

REPORT_DIR="${ROOT_DIR}/reports"
REPORT_FILE="${REPORT_DIR}/m1-acceptance.txt"
PINNED_M0_MANIFEST_SHA256="29b557c0d69c2bdf0913eaa395e5286b63c066afd9af77255493395851097bb9"

RECORD_MODE=0
RUN_INNER=0
for arg in "$@"; do
    case "${arg}" in
        --record)
            RECORD_MODE=1
            ;;
        --run-inner)
            RUN_INNER=1
            ;;
        *)
            echo "Unknown argument: ${arg} (supported: --record)" >&2
            exit 2
            ;;
    esac
done

REAL_HOME="${HOME}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/citestudio-m1.XXXXXX")"
LOOPBACK_PID=""
SYNTH_PID=""
ACTIVE_MUTATION_TARGET=""
ACTIVE_MUTATION_BACKUP=""

cleanup() {
    if [[ -n "${ACTIVE_MUTATION_TARGET}" && -n "${ACTIVE_MUTATION_BACKUP}" && -f "${ACTIVE_MUTATION_BACKUP}" ]]; then
        cp "${ACTIVE_MUTATION_BACKUP}" "${ACTIVE_MUTATION_TARGET}" || true
    fi
    if [[ -n "${LOOPBACK_PID}" ]]; then
        kill "${LOOPBACK_PID}" >/dev/null 2>&1 || true
        wait "${LOOPBACK_PID}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${SYNTH_PID}" ]]; then
        kill "${SYNTH_PID}" >/dev/null 2>&1 || true
        wait "${SYNTH_PID}" >/dev/null 2>&1 || true
    fi
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT INT TERM

scrub_paths() {
    python3 -c '
import re, sys
root_dir, real_home, tmp_root = sys.argv[1], sys.argv[2], sys.argv[3]
text = sys.stdin.read()
if tmp_root:
    text = text.replace(tmp_root, "<TMP_DIR>")
if root_dir:
    text = text.replace(root_dir, "<REPO_ROOT>")
if real_home:
    text = text.replace(real_home, "<HOME>")
users_prefix = "/" + "Users" + "/"
text = re.sub(re.escape(users_prefix) + r"[^/\s\"'"'"']+", "<HOME>", text)
text = re.sub(r"/private/var/folders/[^\s\"'"'"')）。]+", "<TMP_DIR>", text)
text = re.sub(r"/var/folders/[^\s\"'"'"')）。]+", "<TMP_DIR>", text)
text = re.sub(r"(?:/private)?/tmp/citestudio-[^\s\"'"'"')）。]+", "<TMP_DIR>", text)
sys.stdout.write(text)
' "${ROOT_DIR}" "${REAL_HOME}" "${TMP_ROOT}"
}

run_suite() {
    local start_epoch
    start_epoch="$(date +%s)"
    export HOME="${TMP_ROOT}/isolated_home"
    export CITESTUDIO_CACHE_DIR="${TMP_ROOT}/default_cache"
    export CITESTUDIO_EPHEMERAL_DEFAULTS=1
    export HTTP_PROXY="http://127.0.0.1:9"
    export HTTPS_PROXY="http://127.0.0.1:9"
    export NO_PROXY="127.0.0.1,localhost"
    mkdir -p "${HOME}" "${CITESTUDIO_CACHE_DIR}"

    ACC_PASSED=0
    ACC_SKIPPED=0
    ACC_SKIPPED_ITEMS=()

    local git_branch git_sha
    git_branch="$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    git_sha="$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

    echo "=================================================================="
    echo "CiteStudio M1 Acceptance Suite (m1-acceptance.sh)"
    echo "Timestamp (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "Commit / Branch: ${git_branch} @ ${git_sha}"
    echo "Offline Proxy Guard: HTTP_PROXY=${HTTP_PROXY} NO_PROXY=${NO_PROXY}"
    echo "=================================================================="

    echo "==> Building debug binary (CiteStudio)..."
    swift build -q
    BIN="${ROOT_DIR}/.build/debug/CiteStudio"
    if [[ ! -x "${BIN}" ]]; then
        echo "FAIL: Expected executable at ${BIN}" >&2
        exit 1
    fi

    # ------------------------------------------------------------------
    # M1 ITEM 1 & ITEM 2: ScholarOS 460-Entry Benchmark Format & Replay
    # Explicitly skipped ("等评测集") and NEVER counted as passed!
    # ------------------------------------------------------------------
    echo ""
    echo "--- M1 Item 1: ScholarOS 460-Entry Benchmark Input Format ---"
    echo "[SKIP] M1 Item 1 (ScholarOS 460-entry benchmark format & input): 等评测集 — ScholarOS 460-entry dataset has not been built yet."
    ACC_SKIPPED=$((ACC_SKIPPED + 1))
    ACC_SKIPPED_ITEMS+=("M1_Item_1(等评测集)")

    echo ""
    echo "--- M1 Item 2: ScholarOS 460-Entry Replay Benchmark (m1-citation-bench.py) ---"
    echo "[SKIP] M1 Item 2 (ScholarOS 460-entry benchmark replay & threshold evaluation): 等评测集 — ScholarOS 460-entry dataset has not been built yet."
    ACC_SKIPPED=$((ACC_SKIPPED + 1))
    ACC_SKIPPED_ITEMS+=("M1_Item_2(等评测集)")

    # ------------------------------------------------------------------
    # M1 ITEM 3 (C5 Part A): Recorded 12-Entry Replay on Tests/Fixtures/test.bib
    # Verifies Knuth 1968 (real_nodoi) against recorded Crossref & OpenAlex
    # book reviews (Odeh 1969, MacLaren 1969, Wells 1973) -> NOT MetadataMismatch!
    # ------------------------------------------------------------------
    echo ""
    echo "--- M1 Item 3 (C5 Part A): Recorded 12-Entry Replay (test.bib + CLI/MCP Parity + Bilingual Wording) ---"
    RECORDED_DIR="${ROOT_DIR}/Tests/Fixtures/recorded"
    TEST_BIB="${ROOT_DIR}/Tests/Fixtures/test.bib"

    python3 "${ROOT_DIR}/Scripts/acceptance/validate_recorded_fixtures.py" \
        "${RECORDED_DIR}" \
        --min-items 20 \
        --expected-manifest-sha256 "${PINNED_M0_MANIFEST_SHA256}"

    PORT_FILE="${TMP_ROOT}/recorded_replay.port"
    python3 - "${RECORDED_DIR}" "${PORT_FILE}" <<'PYEOF' &
import glob, http.server, json, os, socketserver, sys, urllib.parse

rec_dir, port_file = sys.argv[1], sys.argv[2]

def canonical_key(service: str, raw_url_or_path: str):
    u = urllib.parse.urlsplit(raw_url_or_path)
    norm_path = urllib.parse.unquote(u.path).rstrip("/") or "/"
    norm_query = tuple(sorted(urllib.parse.parse_qsl(u.query, keep_blank_values=True)))
    return (service, norm_path.lower(), norm_query)

index = {}
for meta_path in sorted(glob.glob(os.path.join(rec_dir, "*.meta.json"))):
    meta = json.load(open(meta_path, encoding="utf-8"))
    raw_path = os.path.join(rec_dir, meta["raw_file"])
    if os.path.isfile(raw_path):
        index[canonical_key(meta["service"], meta["url"])] = (
            int(meta["status"]),
            meta.get("content_type", "application/json"),
            raw_path,
        )

class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

class ReplayHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return
    def do_GET(self):
        if self.path.startswith("/crossref/"):
            key = canonical_key("crossref", self.path[len("/crossref"):])
        elif self.path.startswith("/openalex/"):
            key = canonical_key("openalex", self.path[len("/openalex"):])
        else:
            self.send_response(501)
            self.end_headers()
            return
        hit = index.get(key)
        if hit is None:
            self.send_response(501)
            self.end_headers()
            return
        code, ctype, rpath = hit
        body = open(rpath, "rb").read()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

httpd = ThreadingHTTPServer(("127.0.0.1", 0), ReplayHandler)
with open(port_file, "w", encoding="utf-8") as pf:
    pf.write(str(httpd.server_address[1]))
httpd.serve_forever()
PYEOF
    LOOPBACK_PID=$!

    for _ in $(seq 1 50); do
        [[ -s "${PORT_FILE}" ]] && break
        sleep 0.05
    done
    REC_PORT="$(cat "${PORT_FILE}")"
    REC_BASE="http://127.0.0.1:${REC_PORT}"

    C5_REC_CACHE="${TMP_ROOT}/c5_rec_cache"
    set +e
    REC_CLI_EN="$(
        CITESTUDIO_CROSSREF_BASE_URL="${REC_BASE}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="${REC_BASE}/openalex" \
        "${BIN}" --cli verify "${TEST_BIB}" --json --cache-dir "${C5_REC_CACHE}_en" --lang en
    )"
    REC_CLI_CODE=$?
    REC_CLI_ZH="$(
        CITESTUDIO_CROSSREF_BASE_URL="${REC_BASE}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="${REC_BASE}/openalex" \
        "${BIN}" --cli verify "${TEST_BIB}" --json --cache-dir "${C5_REC_CACHE}_zh" --lang zh
    )"
    set -e

    MCP_TARGET_BIB="${TMP_ROOT}/c5_rec_target.bib"
    : > "${MCP_TARGET_BIB}"
    REC_MCP_REQ="$(python3 - "${TEST_BIB}" "${MCP_TARGET_BIB}" <<'PYEOF'
import json, sys
bib_path, target_bib = sys.argv[1], sys.argv[2]
lines = [ln.strip() for ln in open(bib_path, encoding="utf-8") if ln.strip().startswith("@")]
for idx, line in enumerate(lines, start=1):
    print(json.dumps({
        "jsonrpc": "2.0",
        "id": idx,
        "method": "tools/call",
        "params": {"name": "verify_citation", "arguments": {"bibtex": line}},
    }))
knuth_line = next(ln for ln in lines if "real_nodoi" in ln)
fake_nodoi_line = next(ln for ln in lines if "fake_nodoi" in ln)
print(json.dumps({
    "jsonrpc": "2.0",
    "id": 101,
    "method": "tools/call",
    "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": knuth_line}},
}))
print(json.dumps({
    "jsonrpc": "2.0",
    "id": 102,
    "method": "tools/call",
    "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": target_bib, "bibtex": fake_nodoi_line}},
}))
PYEOF
)"
    REC_MCP_RESP="$(
        printf '%s\n' "${REC_MCP_REQ}" | \
        CITESTUDIO_CROSSREF_BASE_URL="${REC_BASE}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="${REC_BASE}/openalex" \
        "${BIN}" --mcp --cache-dir "${C5_REC_CACHE}_mcp" --lang en
    )"

    kill "${LOOPBACK_PID}" >/dev/null 2>&1 || true
    wait "${LOOPBACK_PID}" >/dev/null 2>&1 || true
    LOOPBACK_PID=""

    python3 - "${REC_CLI_CODE}" "${REC_CLI_EN}" "${REC_CLI_ZH}" "${REC_MCP_RESP}" "${MCP_TARGET_BIB}" <<'PYEOF'
import json, os, sys

cli_code = int(sys.argv[1])
en_data = json.loads(sys.argv[2])
zh_data = json.loads(sys.argv[3])
mcp_msgs = [json.loads(ln) for ln in sys.argv[4].strip().splitlines() if ln.strip()]
target_bib = sys.argv[5]

assert cli_code != 0, "Mixed 12-entry test.bib must exit non-zero"

en_map = {d["citeKey"]: d for d in en_data["entries"]}
zh_map = {d["citeKey"]: d for d in zh_data["entries"]}
verify_msgs = [m for m in mcp_msgs if m["id"] <= 12]
add_msgs = {m["id"]: m for m in mcp_msgs if m["id"] > 100}
mcp_map = {}
for m in verify_msgs:
    d = json.loads(m["result"]["content"][0]["text"])
    mcp_map[d["citeKey"]] = d["verdict"]

expected_12 = {
    "real_lecun": "Verified",
    "real_lstm": "Verified",
    "real_watson": "Verified",
    "fake_nonsentinel": "GhostPaper",
    "fake_sentinel": "GhostPaper",
    "wrongtitle": "MetadataMismatch",
    "wrongyear": "MetadataMismatch",
    "wrongyear5": "MetadataMismatch",
    "real_nodoi": "GhostPaper",
    "fake_nodoi": "GhostPaper",
    "retracted_seralini": "Retracted",
    "retracted_wakefield": "Retracted",
}

for k, exp in expected_12.items():
    assert en_map[k]["verdict"] == exp, f"CLI EN {k}: expected {exp}, got {en_map[k]['verdict']}"
    assert zh_map[k]["verdict"] == exp, f"CLI ZH {k}: expected {exp}, got {zh_map[k]['verdict']}"
    assert mcp_map[k] == exp, f"MCP {k}: expected {exp}, got {mcp_map[k]}"
    print(f"  {k:22s} -> CLI={en_map[k]['verdict']:16s} | MCP={mcp_map[k]:16s}")

# C5 specific checks on Knuth 1968 (real_nodoi)
assert en_map["real_nodoi"]["verdict"] != "MetadataMismatch"
assert en_map["real_nodoi"]["badge"] == "NOT FOUND"
assert "Not found in Crossref / OpenAlex (real_nodoi)" == en_map["real_nodoi"]["headline"], en_map["real_nodoi"]
assert "fabricated" not in en_map["real_nodoi"]["detail"].lower(), en_map["real_nodoi"]
assert "未在 Crossref / OpenAlex 中查到匹配记录 (real_nodoi)" == zh_map["real_nodoi"]["headline"], zh_map["real_nodoi"]
assert "编造" not in zh_map["real_nodoi"]["detail"], zh_map["real_nodoi"]

# MCP add_verified_bibtex must block both real_nodoi (not found in Crossref/OpenAlex) and fake_nodoi
for req_id in (101, 102):
    txt = add_msgs[req_id]["result"]["content"][0]["text"]
    assert add_msgs[req_id]["result"].get("isError") is True, add_msgs[req_id]
    assert "ERR_UNVERIFIED_CITATION" in txt, txt
assert os.path.getsize(target_bib) == 0, "Target .bib must remain untouched when add_verified_bibtex rejects unverified citations"
PYEOF
    echo "[PASS] C5 Part A (Recorded Replay — sole C5 real-response evidence, covering the 2 recorded DOI-less titles real_nodoi & fake_nodoi): 12/12 CLI == MCP verdicts matched; real_nodoi (Knuth 1968) rejected Odeh/MacLaren/Wells book reviews -> NOT FOUND (not MetadataMismatch), blocked from .bib insertion."
    ACC_PASSED=$((ACC_PASSED + 1))

    # ------------------------------------------------------------------
    # M1 ITEM 3 (C5 Part B · 合成 / Synthetic — 不算 C5 的证据):
    # Handwritten Loopback Sanity Check in TMP_ROOT (NOT counted in ACC_PASSED and NOT C5 evidence; zero touch to Tests/Fixtures/recorded/)
    # ------------------------------------------------------------------
    echo ""
    echo "--- M1 Item 3 (C5 Part B · 合成 / Synthetic — 不算 C5 的证据): Handwritten Loopback Sanity Check (Year Δ=0/1/2, Author Surname Match/Mismatch, Book-Review, DOI Regression) ---"
    SYNTH_PORT_FILE="${TMP_ROOT}/synth_c5.port"
    python3 - "${SYNTH_PORT_FILE}" <<'PYEOF' &
import http.server, json, socketserver, sys, urllib.parse

port_file = sys.argv[1]

class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

class SynthC5Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return
    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        path = urllib.parse.unquote(u.path)
        qs = dict(urllib.parse.parse_qsl(u.query))
        code = 200
        payload = {"results": []}

        if path.startswith("/crossref/works/"):
            doi = path[len("/crossref/works/"):].lower()
            if doi == "10.1162/neco.1997.9.8.1735":
                payload = {
                    "status": "ok",
                    "message": {
                        "DOI": "10.1162/neco.1997.9.8.1735",
                        "title": ["Long Short-Term Memory"],
                        "author": [{"given": "Sepp", "family": "Hochreiter"}, {"given": "Jürgen", "family": "Schmidhuber"}],
                        "container-title": ["Neural Computation"],
                        "published-print": {"date-parts": [[1997, 11, 15]]},
                    },
                }
            else:
                code = 404
                payload = {"status": "failed"}
        elif path.startswith("/openalex/works/"):
            code = 404
            payload = {"error": "not found"}
        elif path == "/openalex/works":
            q = qs.get("search", "").lower()
            if "fundamental algorithms" in q:
                # Candidate 1: Odeh 1969 review (wrong author); Candidate 2: Donald E. Knuth 1968 monograph (matching author & year)
                payload = {
                    "results": [
                        {
                            "title": "The Art of Computer Programming, Volume 1: Fundamental Algorithms",
                            "publication_year": 1969,
                            "type": "article",
                            "authorships": [{"author": {"display_name": "Robert E. Odeh"}}],
                            "primary_location": {"source": {"display_name": "JASA", "type": "journal"}},
                        },
                        {
                            "title": "The Art of Computer Programming, Volume 1: Fundamental Algorithms",
                            "publication_year": 1968,
                            "type": "book",
                            "authorships": [{"author": {"display_name": "Donald E. Knuth"}}],
                            "primary_location": {"source": {"display_name": "Addison-Wesley", "type": "book series"}},
                        },
                    ]
                }
            elif "concrete mathematics" in q:
                # Only Odeh 1989 review exists upstream -> must reject on author mismatch (Knuth != Odeh)
                payload = {
                    "results": [
                        {
                            "title": "Concrete Mathematics: A Foundation for Computer Science",
                            "publication_year": 1989,
                            "type": "article",
                            "authorships": [{"author": {"display_name": "Robert E. Odeh"}}],
                            "primary_location": {"source": {"display_name": "SIAM Review", "type": "journal"}},
                        }
                    ]
                }
            elif "compiler construction principles" in q:
                # Only book-review candidate exists upstream -> must reject even with matching surname & year
                payload = {
                    "results": [
                        {
                            "title": "Book Review: Compiler Construction Principles and Practice",
                            "publication_year": 1977,
                            "type": "book-review",
                            "authorships": [{"author": {"display_name": "Alfred V. Aho"}}],
                            "primary_location": {"source": {"display_name": "Computing Reviews", "type": "journal"}},
                        }
                    ]
                }
        elif path == "/crossref/works":
            payload = {"status": "ok", "message": {"items": []}}

        raw = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

httpd = ThreadingHTTPServer(("127.0.0.1", 0), SynthC5Handler)
with open(port_file, "w", encoding="utf-8") as pf:
    pf.write(str(httpd.server_address[1]))
httpd.serve_forever()
PYEOF
    SYNTH_PID=$!

    for _ in $(seq 1 50); do
        [[ -s "${SYNTH_PORT_FILE}" ]] && break
        sleep 0.05
    done
    SYNTH_PORT="$(cat "${SYNTH_PORT_FILE}")"
    SYNTH_BASE="http://127.0.0.1:${SYNTH_PORT}"

    SYNTH_BIB="${TMP_ROOT}/synth_c5_edge.bib"
    cat > "${SYNTH_BIB}" <<'EOF'
@book{nodoi_knuth_diff0, author = {Knuth, Donald E.}, title = {The Art of Computer Programming, Volume 1: Fundamental Algorithms}, publisher = {Addison-Wesley}, year = {1968}}
@book{nodoi_knuth_diff1, author = {Donald E. Knuth}, title = {The Art of Computer Programming, Volume 1: Fundamental Algorithms}, publisher = {Addison-Wesley}, year = {1969}}
@book{nodoi_knuth_diff2, author = {Knuth, Donald E.}, title = {The Art of Computer Programming, Volume 1: Fundamental Algorithms}, publisher = {Addison-Wesley}, year = {1970}}
@book{nodoi_author_mismatch, author = {Knuth, Donald E.}, title = {Concrete Mathematics: A Foundation for Computer Science}, publisher = {Addison-Wesley}, year = {1989}}
@book{nodoi_book_review_only, author = {Aho, Alfred V.}, title = {Compiler Construction Principles and Practice}, publisher = {Addison-Wesley}, year = {1977}}
@article{doi_year_diff5, author = {Hochreiter, Sepp and Schmidhuber, J{\"u}rgen}, title = {Long Short-Term Memory}, journal = {Neural Computation}, year = {1992}, doi = {10.1162/neco.1997.9.8.1735}}
@article{doi_wrong_title, author = {Hochreiter, Sepp and Schmidhuber, J{\"u}rgen}, title = {Completely Unrelated Title on Ocean Tides}, journal = {Neural Computation}, year = {1997}, doi = {10.1162/neco.1997.9.8.1735}}
EOF

    set +e
    SYNTH_CLI_JSON="$(
        CITESTUDIO_CROSSREF_BASE_URL="${SYNTH_BASE}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="${SYNTH_BASE}/openalex" \
        "${BIN}" --cli verify "${SYNTH_BIB}" --json --cache-dir "${TMP_ROOT}/synth_cache_cli" --lang en
    )"
    SYNTH_CLI_CODE=$?
    set -e

    SYNTH_WRITE_BIB="${TMP_ROOT}/synth_mcp_write.bib"
    : > "${SYNTH_WRITE_BIB}"
    SYNTH_MCP_REQ="$(python3 - "${SYNTH_BIB}" "${SYNTH_WRITE_BIB}" <<'PYEOF'
import json, sys
src_bib, out_bib = sys.argv[1], sys.argv[2]
for idx, ln in enumerate([l.strip() for l in open(src_bib, encoding="utf-8") if l.strip().startswith("@")], start=1):
    print(json.dumps({
        "jsonrpc": "2.0",
        "id": idx,
        "method": "tools/call",
        "params": {"name": "add_verified_bibtex", "arguments": {"bib_file": out_bib, "bibtex": ln}},
    }))
PYEOF
)"
    SYNTH_MCP_RESP="$(
        printf '%s\n' "${SYNTH_MCP_REQ}" | \
        CITESTUDIO_CROSSREF_BASE_URL="${SYNTH_BASE}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="${SYNTH_BASE}/openalex" \
        "${BIN}" --mcp --cache-dir "${TMP_ROOT}/synth_cache_mcp" --lang en
    )"

    kill "${SYNTH_PID}" >/dev/null 2>&1 || true
    wait "${SYNTH_PID}" >/dev/null 2>&1 || true
    SYNTH_PID=""

    python3 - "${SYNTH_CLI_CODE}" "${SYNTH_CLI_JSON}" "${SYNTH_MCP_RESP}" "${SYNTH_WRITE_BIB}" <<'PYEOF'
import json, sys

code = int(sys.argv[1])
data = json.loads(sys.argv[2])
mcp_lines = [json.loads(l) for l in sys.argv[3].strip().splitlines() if l.strip()]
written_bib = open(sys.argv[4], encoding="utf-8").read()

assert code != 0
vmap = {d["citeKey"]: d["verdict"] for d in data["entries"]}
expected = {
    "nodoi_knuth_diff0": "Verified",
    "nodoi_knuth_diff1": "Verified",
    "nodoi_knuth_diff2": "GhostPaper",
    "nodoi_author_mismatch": "GhostPaper",
    "nodoi_book_review_only": "GhostPaper",
    "doi_year_diff5": "MetadataMismatch",
    "doi_wrong_title": "MetadataMismatch",
}
for k, exp in expected.items():
    assert vmap[k] == exp, f"Synthetic edge {k}: expected {exp}, got {vmap[k]}"
    print(f"  [合成 / synthetic, non-evidence] {k:24s} -> {vmap[k]}")

# Only the 2 Verified entries may be written by add_verified_bibtex; the 5 non-verified entries must return ERR_UNVERIFIED_CITATION
assert "nodoi_knuth_diff0" in written_bib and "nodoi_knuth_diff1" in written_bib, written_bib
for blocked_key in ("nodoi_knuth_diff2", "nodoi_author_mismatch", "nodoi_book_review_only", "doi_year_diff5", "doi_wrong_title"):
    assert blocked_key not in written_bib, f"{blocked_key} must never be written to .bib!"

for idx in (1, 2):
    assert "APPENDED_VERIFIED" in mcp_lines[idx - 1]["result"]["content"][0]["text"], mcp_lines[idx - 1]
for idx in (3, 4, 5, 6, 7):
    assert "ERR_UNVERIFIED_CITATION" in mcp_lines[idx - 1]["result"]["content"][0]["text"], mcp_lines[idx - 1]
PYEOF
    echo "[INFO · 合成 / Synthetic — 不算 C5 的证据] C5 Part B (Handwritten Loopback Sanity Check — 手写合成响应正文，不算 C5 的证据，C5 的结论仅按 Part A 已录制的两个标题计；本段不计入 passed): Δyear=0/1 Verified, Δyear=2 & author mismatch & book-review -> GhostPaper, DOI Δyear=5 & wrong title -> MetadataMismatch."

    # ------------------------------------------------------------------
    # C24: Behavioral Test-Framework Skip Output & Recorded Fixture Immutability
    # ------------------------------------------------------------------
    echo ""
    echo "--- C24: Actual Swift Testing Skip Output (PATH without tectonic) & Recorded Fixture Immutability ---"
    STRIPPED_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    C24_RUNNER_OUT="$(
        PATH="${STRIPPED_PATH}" \
        CITESTUDIO_REAL_TECTONIC=1 \
        "${ROOT_DIR}/Scripts/test.sh" scope "CiteStudioCoreTests.CiteStudioCoreTests/realTectonicCompilation" 2>&1
    )"
    python3 - "${C24_RUNNER_OUT}" <<'PYEOF'
import sys
out = sys.argv[1]
lines = out.splitlines()
label = 'Test "Real Tectonic compilation produces PDF and SyncTeX output"'
has_skipped = any((ln.startswith("➜ " + label) or ln.startswith("◇ " + label)) and "skipped" in ln for ln in lines)
has_passed = any(ln.startswith("✔ " + label) and "passed" in ln for ln in lines)
assert has_skipped, f"Expected actual Swift Testing skipped line, got:\n{out}"
assert not has_passed, f"Test without tectonic on PATH must NEVER be counted as passed:\n{out}"
assert "UNIT_TESTS_SUMMARY: total=1 passed=0 skipped=1 failed=0" in out, f"Expected passed=0 skipped=1 summary, got:\n{out}"
PYEOF

    BASELINE_REF=""
    if git -C "${ROOT_DIR}" rev-parse --verify m0/honest >/dev/null 2>&1; then
        BASELINE_REF="m0/honest"
    elif git -C "${ROOT_DIR}" rev-parse --verify origin/m0/honest >/dev/null 2>&1; then
        BASELINE_REF="origin/m0/honest"
    fi
    if [[ -n "${BASELINE_REF}" ]]; then
        REC_DIFF="$(git -C "${ROOT_DIR}" diff "${BASELINE_REF}" -- Tests/Fixtures/recorded/)"
        if [[ -n "${REC_DIFF}" ]]; then
            echo "FAIL C24: Tests/Fixtures/recorded/ differs from ${BASELINE_REF}!" >&2
            echo "${REC_DIFF}" >&2
            exit 1
        fi
    fi

    ACTUAL_MANIFEST_SHA="$(shasum -a 256 "${RECORDED_DIR}/manifest.json" | awk '{print $1}')"
    if [[ "${ACTUAL_MANIFEST_SHA}" != "${PINNED_M0_MANIFEST_SHA256}" ]]; then
        echo "FAIL C24: manifest.json SHA-256 (${ACTUAL_MANIFEST_SHA}) != pinned c8298c3 digest (${PINNED_M0_MANIFEST_SHA256})" >&2
        exit 1
    fi

    # Verify co-tampering of .raw + .meta.json + manifest.json in a temp copy passes unpinned self-check (documented C24 limit)
    # and is rejected when --expected-manifest-sha256 is pinned to c8298c3's digest
    python3 - "${ROOT_DIR}/Scripts/acceptance/validate_recorded_fixtures.py" "${RECORDED_DIR}" "${TMP_ROOT}" "${PINNED_M0_MANIFEST_SHA256}" <<'PYEOF'
import hashlib, json, os, shutil, subprocess, sys

val_py, rec_dir, tmp_root, pinned_sha = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
cotamper_dir = os.path.join(tmp_root, "c24_cotamper")
shutil.copytree(rec_dir, cotamper_dir)
m_path = os.path.join(cotamper_dir, "manifest.json")
m = json.load(open(m_path, encoding="utf-8"))
it0 = m["items"][0]
r0_path = os.path.join(cotamper_dir, it0["raw_file"])
meta0_path = os.path.join(cotamper_dir, f"{it0['slug']}.meta.json")
mut_bytes = open(r0_path, "rb").read() + b"\n"
open(r0_path, "wb").write(mut_bytes)
it0["byte_length"] = len(mut_bytes)
it0["sha256"] = hashlib.sha256(mut_bytes).hexdigest()
json.dump(it0, open(meta0_path, "w", encoding="utf-8"), indent=2, sort_keys=True)
json.dump(m, open(m_path, "w", encoding="utf-8"), indent=2, sort_keys=True)

unpinned = subprocess.run([sys.executable, val_py, cotamper_dir, "--min-items", "20"], capture_output=True, text=True)
assert unpinned.returncode == 0, "Expected unpinned self-check to demonstrate C24 co-modification limit"

pinned = subprocess.run(
    [sys.executable, val_py, cotamper_dir, "--min-items", "20", "--expected-manifest-sha256", pinned_sha],
    capture_output=True,
    text=True,
)
assert pinned.returncode != 0 and "manifest.json sha256 mismatch" in pinned.stderr, pinned.stderr
PYEOF
    echo "[PASS] C24: Test runner emitted native skipped record (passed=0, skipped=1) with tectonic stripped from PATH; Tests/Fixtures/recorded/ has 0 diff vs ${BASELINE_REF:-c8298c3} (manifest SHA-256=${ACTUAL_MANIFEST_SHA})."
    ACC_PASSED=$((ACC_PASSED + 1))

    # ------------------------------------------------------------------
    # SCRIPTED MUTATION VERIFICATION FOR M1 (C5 Year, C5 Author, C24 Skip Trait)
    # ------------------------------------------------------------------
    echo ""
    echo "--- Scripted Mutation Verification (4 M1 Guards: C5 Year, C5 Author, C24 Skip Trait, CR2 Similarity 0.78->0.30) ---"
    GIT_STATUS_BEFORE="$(git -C "${ROOT_DIR}" status --porcelain)"

    run_single_mutation() {
        local mut_id="$1"
        local rel_file="$2"
        local test_filter="$3"
        local expected_test_label="$4"
        local old_snippet="$5"
        local new_snippet="$6"

        local abs_file="${ROOT_DIR}/${rel_file}"
        local backup_file="${TMP_ROOT}/mut_backup_${mut_id}"
        cp "${abs_file}" "${backup_file}"
        ACTIVE_MUTATION_TARGET="${abs_file}"
        ACTIVE_MUTATION_BACKUP="${backup_file}"

        python3 - "${abs_file}" "${old_snippet}" "${new_snippet}" <<'PYEOF'
import sys
path, old_s, new_s = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(path, encoding="utf-8").read()
count = content.count(old_s)
assert count == 1, f"Expected exact 1 occurrence of target snippet in {path}, found {count}"
with open(path, "w", encoding="utf-8") as fh:
    fh.write(content.replace(old_s, new_s, 1))
PYEOF

        set +e
        local mut_out
        mut_out="$(swift test --no-parallel --filter "${test_filter}" 2>&1)"
        local mut_code=$?
        set -e

        cp "${backup_file}" "${abs_file}"
        cmp -s "${backup_file}" "${abs_file}"
        ACTIVE_MUTATION_TARGET=""
        ACTIVE_MUTATION_BACKUP=""

        python3 - "${mut_id}" "${mut_code}" "${expected_test_label}" "${mut_out}" <<'PYEOF'
import sys
mut_id, code, label, out = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
assert code != 0, f"[{mut_id}] Expected mutated test run to fail non-zero, but exited 0!\n{out}"
assert "Build complete!" in out, f"[{mut_id}] Mutation caused a compiler failure rather than a test failure!\n{out}"
assert "Test run started." in out, f"[{mut_id}] Test runner did not start!\n{out}"
expected_fail_line = f'✘ Test "{label}" failed after'
assert expected_fail_line in out, f"[{mut_id}] Expected named test failure '{expected_fail_line}', got:\n{out}"
PYEOF
        echo "  [ok] ${mut_id}: compiled cleanly -> failed named test '${test_filter}' (exit=${mut_code}) -> restored ${rel_file}"
    }

    run_single_mutation \
        "M1_C5_DisableYearDriftGuard" \
        "Sources/CiteStudioCore/CitationFirewall/ScholarTriangulator.swift" \
        "SyntheticC5FirewallTests/syntheticC5HandwrittenCandidateFiltering" \
        "合成 (Synthetic, 不算 C5 证据) C5: DOI-less title search handwritten candidate filtering for year drift, first-author surname, and book-review rules" \
        "        if let citedYear = entry.year, citedYear > 0, record.year > 0 {
            if abs(citedYear - record.year) > maximumTitleSearchYearDrift {
                return false
            }
        }" \
        "        if false, let citedYear = entry.year, citedYear > 0, record.year > 0 {
            if abs(citedYear - record.year) > maximumTitleSearchYearDrift {
                return false
            }
        }"

    run_single_mutation \
        "M2_C5_DisableFirstAuthorSurnameGuard" \
        "Sources/CiteStudioCore/CitationFirewall/ScholarTriangulator.swift" \
        "SyntheticC5FirewallTests/syntheticC5HandwrittenCandidateFiltering" \
        "合成 (Synthetic, 不算 C5 证据) C5: DOI-less title search handwritten candidate filtering for year drift, first-author surname, and book-review rules" \
        "        if !citedSurname.isEmpty || !candidateSurname.isEmpty {
            guard !citedSurname.isEmpty,
                  !candidateSurname.isEmpty,
                  citedSurname == candidateSurname else {
                return false
            }
        }" \
        "        if false && (!citedSurname.isEmpty || !candidateSurname.isEmpty) {
            return false
        }"

    run_single_mutation \
        "M3_C24_EarlyReturnInsteadOfSkipTrait" \
        "Tests/CiteStudioCoreTests/CiteStudioCoreTests.swift" \
        "CLITests/c21AndC24TectonicTestEmitsActualSkippedFrameworkRecordWhenAbsentOnPath" \
        "C21 + C24: When CITESTUDIO_REAL_TECTONIC is unset or tectonic is absent on PATH, Swift Testing emits a native skipped record (never passed) and --cli status respects PATH" \
        '    @Test(
        "Real Tectonic compilation produces PDF and SyncTeX output",
        .enabled(
            if: ProcessInfo.processInfo.environment["CITESTUDIO_REAL_TECTONIC"] == "1"
                && TectonicRunner.detectBinary() != nil,
            "Requires CITESTUDIO_REAL_TECTONIC=1 and tectonic on PATH (external TeX bundle cache / network)"
        )
    )
    func realTectonicCompilation() throws {' \
        '    @Test("Real Tectonic compilation produces PDF and SyncTeX output")
    func realTectonicCompilation() throws {
        if ProcessInfo.processInfo.environment["CITESTUDIO_REAL_TECTONIC"] != "1" || TectonicRunner.detectBinary() == nil { return }'

    run_single_mutation \
        "M4_CR2_LowerTitleSimilarity078To030" \
        "Sources/CiteStudioCore/CitationFirewall/ScholarTriangulator.swift" \
        "FirewallTests/cr2RecordedTitleSimilarityThresholdBoundaryTests" \
        "CR2: Title-search similarity threshold (0.78) boundary checks using strictly verbatim responses in Tests/Fixtures/recorded/" \
        "    public static let minimumTitleSearchSimilarity: Double = 0.78" \
        "    public static let minimumTitleSearchSimilarity: Double = 0.30"

    swift build -q
    GIT_STATUS_AFTER="$(git -C "${ROOT_DIR}" status --porcelain)"
    if [[ "${GIT_STATUS_AFTER}" != "${GIT_STATUS_BEFORE}" ]]; then
        echo "FAIL M1 Mutations: Working tree dirty/changed after mutations!" >&2
        echo "${GIT_STATUS_AFTER}" >&2
        exit 1
    fi
    echo "[PASS] Scripted M1 Mutations: All 4 mutations (C5 year, C5 surname, C24 skip trait, CR2 title similarity 0.78->0.30) failed their exact named @Test and restored cleanly."
    ACC_PASSED=$((ACC_PASSED + 1))

    ACC_TOTAL=$((ACC_PASSED + ACC_SKIPPED))
    local elapsed_sec=$(( $(date +%s) - start_epoch ))
    echo ""
    echo "=================================================================="
    echo "M1_ACCEPTANCE_SUMMARY: total=${ACC_TOTAL} passed=${ACC_PASSED} skipped=${ACC_SKIPPED} exit_code=0 elapsed_sec=${elapsed_sec} (skipped items NOT counted as passed)"
    if [[ "${ACC_SKIPPED}" -gt 0 ]]; then
        echo "SKIPPED_ITEMS: ${ACC_SKIPPED_ITEMS[*]}"
    fi
    echo "=================================================================="
}

if [[ "${RUN_INNER}" -eq 1 ]]; then
    run_suite
elif [[ "${RECORD_MODE}" -eq 1 ]]; then
    mkdir -p "${REPORT_DIR}"
    "${BASH_SOURCE[0]}" --run-inner 2>&1 | scrub_paths | tee "${REPORT_FILE}"
else
    run_suite
fi
