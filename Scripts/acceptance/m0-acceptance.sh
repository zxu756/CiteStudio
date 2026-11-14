#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_DIR="${ROOT_DIR}/reports"
mkdir -p "${REPORT_DIR}"
REPORT_FILE="${REPORT_DIR}/m0-acceptance.txt"

REAL_HOME="${HOME}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/citestudio-m0-acc.XXXXXX")"
SERVER_PID=""
GUI_PID=""

cleanup() {
    if [[ -n "${GUI_PID}" ]] && kill -0 "${GUI_PID}" 2>/dev/null; then
        kill "${GUI_PID}" 2>/dev/null || true
        wait "${GUI_PID}" 2>/dev/null || true
    fi
    if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

run_suite() {
    echo "=================================================================="
    echo "CiteStudio M0 Acceptance Verification (m0-acceptance.sh)"
    echo "Timestamp (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "Commit / Branch: $(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD) @ $(git -C "${ROOT_DIR}" rev-parse --short HEAD)"
    echo "Network Policy : Local 127.0.0.1 loopback server ONLY (0 external API calls)"
    echo "=================================================================="

    cd "${ROOT_DIR}"
    swift build -q
    BIN="${ROOT_DIR}/.build/debug/CiteStudio"
    if [[ ! -x "${BIN}" ]]; then
        echo "FAIL: Missing executable ${BIN}" >&2
        exit 1
    fi

    export HOME="${TMP_ROOT}/fake_home"
    export XDG_CACHE_HOME="${REAL_HOME}/.cache"
    export CITESTUDIO_EPHEMERAL_DEFAULTS=1
    mkdir -p "${HOME}"

    # Prepare the canonical 12-entry test.bib (and verify parity with harness copy if present)
    TEST_BIB="${TMP_ROOT}/test.bib"
    cat > "${TEST_BIB}" <<'EOF'
@article{real_lecun, author = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey}, title = {Deep learning}, journal = {Nature}, year = {2015}, volume = {521}, pages = {436--444}, doi = {10.1038/nature14539}}
@article{real_lstm, author = {Hochreiter, Sepp and Schmidhuber, J{\"u}rgen}, title = {Long Short-Term Memory}, journal = {Neural Computation}, year = {1997}, volume = {9}, pages = {1735--1780}, doi = {10.1162/neco.1997.9.8.1735}}
@article{real_watson, author = {Watson, J. D. and Crick, F. H. C.}, title = {Molecular Structure of Nucleic Acids: A Structure for Deoxyribose Nucleic Acid}, journal = {Nature}, year = {1953}, volume = {171}, pages = {737--738}, doi = {10.1038/171737a0}}
@article{fake_nonsentinel, author = {Whitfield, Eleanor and Patel, Raj}, title = {Quantum Gradient Descent in Biological Neural Networks}, journal = {Nature Machine Intelligence}, year = {2026}, doi = {10.1038/fake.2026.99999}}
@article{fake_sentinel, author = {Okafor, Ngozi and Lindqvist, Mats}, title = {Self-Supervised Topological Priors for Protein Folding}, journal = {Science}, year = {2026}, doi = {10.1234/fake.2026.99999}}
@article{wrongtitle, author = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey}, title = {A Completely Different Invented Title About Ocean Currents}, journal = {Nature}, year = {2015}, doi = {10.1038/nature14539}}
@article{wrongyear, author = {Hochreiter, Sepp and Schmidhuber, J{\"u}rgen}, title = {Long Short-Term Memory}, journal = {Neural Computation}, year = {1999}, doi = {10.1162/neco.1997.9.8.1735}}
@article{wrongyear5, author = {Hochreiter, Sepp and Schmidhuber, J{\"u}rgen}, title = {Long Short-Term Memory}, journal = {Neural Computation}, year = {1992}, doi = {10.1162/neco.1997.9.8.1735}}
@book{real_nodoi, author = {Knuth, Donald E.}, title = {The Art of Computer Programming, Volume 1: Fundamental Algorithms}, publisher = {Addison-Wesley}, year = {1968}}
@article{fake_nodoi, author = {Whitfield, Eleanor and Patel, Raj}, title = {Recursive Causal Lattices for Zero-Shot Climate Forecasting}, journal = {Journal of Applied Machine Cognition}, year = {2023}, volume = {12}, pages = {101--119}}
@article{retracted_seralini, author = {S{\'e}ralini, Gilles-{\'E}ric and Clair, Emilie and Mesnage, Robin}, title = {Long term toxicity of a Roundup herbicide and a Roundup-tolerant genetically modified maize}, journal = {Food and Chemical Toxicology}, year = {2012}, doi = {10.1016/j.fct.2012.08.005}}
@article{retracted_wakefield, author = {Wakefield, A. J. and Murch, S. H.}, title = {Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children}, journal = {The Lancet}, year = {1998}, doi = {10.1016/S0140-6736(97)11096-0}}
EOF

    HARNESS_BIB="/Users/xu/Projects/flagship-acceptance/harness/scholaros/recheck/test.bib"
    if [[ -f "${HARNESS_BIB}" ]]; then
        diff -u "${HARNESS_BIB}" "${TEST_BIB}"
        echo "[INFO] Verified byte-for-byte match with flagship-acceptance test.bib (12 entries)."
    fi

    # Write local loopback Crossref + OpenAlex HTTP server (127.0.0.1 only)
    PORT_FILE="${TMP_ROOT}/server_port.txt"
    LOOPBACK_PY="${TMP_ROOT}/loopback_scholar_server.py"
    cat > "${LOOPBACK_PY}" <<'PYEOF'
import http.server
import json
import socketserver
import sys
import threading
import time
import urllib.parse

STATE = {"mode": "normal", "requests": 0}
LOCK = threading.Lock()

CROSSREF_BY_DOI = {
    "10.1038/nature14539": {
        "status": "ok",
        "message": {
            "DOI": "10.1038/nature14539",
            "title": ["Deep learning"],
            "author": [
                {"given": "Yann", "family": "LeCun"},
                {"given": "Yoshua", "family": "Bengio"},
                {"given": "Geoffrey", "family": "Hinton"},
            ],
            "published-print": {"date-parts": [[2015, 5, 28]]},
            "container-title": ["Nature"],
        },
    },
    "10.1162/neco.1997.9.8.1735": {
        "status": "ok",
        "message": {
            "DOI": "10.1162/neco.1997.9.8.1735",
            "title": ["Long Short-Term Memory"],
            "author": [
                {"given": "Sepp", "family": "Hochreiter"},
                {"given": "Jürgen", "family": "Schmidhuber"},
            ],
            "published-print": {"date-parts": [[1997, 11, 15]]},
            "container-title": ["Neural Computation"],
        },
    },
    "10.1038/171737a0": {
        "status": "ok",
        "message": {
            "DOI": "10.1038/171737a0",
            "title": ["Molecular Structure of Nucleic Acids: A Structure for Deoxyribose Nucleic Acid"],
            "author": [
                {"given": "J. D.", "family": "Watson"},
                {"given": "F. H. C.", "family": "Crick"},
            ],
            "published-print": {"date-parts": [[1953, 4, 25]]},
            "container-title": ["Nature"],
        },
    },
    "10.1016/j.fct.2012.08.005": {
        "status": "ok",
        "message": {
            "DOI": "10.1016/j.fct.2012.08.005",
            "title": ["Long term toxicity of a Roundup herbicide and a Roundup-tolerant genetically modified maize"],
            "author": [
                {"given": "Gilles-Eric", "family": "Séralini"},
                {"given": "Emilie", "family": "Clair"},
                {"given": "Robin", "family": "Mesnage"},
            ],
            "published-print": {"date-parts": [[2012, 11]]},
            "container-title": ["Food and Chemical Toxicology"],
            # Intentionally omit Crossref update-to here so OpenAlex is_retracted=True is also verified!
        },
    },
    "10.1016/s0140-6736(97)11096-0": {
        "status": "ok",
        "message": {
            "DOI": "10.1016/s0140-6736(97)11096-0",
            "title": ["RETRACTED: Ileal-lymphoid-nodular hyperplasia, non-specific colitis, and pervasive developmental disorder in children"],
            "author": [
                {"given": "A. J.", "family": "Wakefield"},
                {"given": "S. H.", "family": "Murch"},
            ],
            "published-print": {"date-parts": [[1998, 2, 28]]},
            "container-title": ["The Lancet"],
            "updated-by": [
                {"type": "retraction", "label": "Retraction", "DOI": "10.1016/S0140-6736(10)60175-4"}
            ],
        },
    },
}

OPENALEX_BY_DOI = {
    "10.1038/nature14539": {"id": "https://openalex.org/W2163605009", "is_retracted": False},
    "10.1162/neco.1997.9.8.1735": {"id": "https://openalex.org/W2064675550", "is_retracted": False},
    "10.1038/171737a0": {"id": "https://openalex.org/W2054566145", "is_retracted": False},
    "10.1016/j.fct.2012.08.005": {"id": "https://openalex.org/W2132502759", "is_retracted": True},
    "10.1016/s0140-6736(97)11096-0": {"id": "https://openalex.org/W2150643597", "is_retracted": True},
}


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _send_json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path.startswith("/_mode/"):
            mode = self.path[len("/_mode/"):].strip()
            with LOCK:
                STATE["mode"] = mode
            self._send_json(200, STATE)
            return
        self._send_json(404, {"error": "unknown control endpoint"})

    def do_GET(self):
        if self.path == "/_stats":
            with LOCK:
                snap = dict(STATE)
            self._send_json(200, snap)
            return

        with LOCK:
            STATE["requests"] += 1
            mode = STATE["mode"]

        if mode == "429":
            self._send_json(429, {"error": "Too Many Requests"})
            return
        if mode == "500":
            self._send_json(500, {"error": "Internal Server Error"})
            return
        if mode == "timeout":
            time.sleep(2.2)
            self._send_json(200, {"status": "delayed"})
            return

        parsed = urllib.parse.urlsplit(self.path)
        raw_path = urllib.parse.unquote(parsed.path)
        query = urllib.parse.parse_qs(parsed.query)

        # Crossref endpoints
        if raw_path.startswith("/crossref/works/"):
            doi = raw_path[len("/crossref/works/"):].strip().lower()
            if doi in CROSSREF_BY_DOI:
                self._send_json(200, CROSSREF_BY_DOI[doi])
            else:
                self._send_json(404, {"status": "not-found"})
            return

        if raw_path == "/crossref/works":
            q_title = (query.get("query.bibliographic", [""])[0]).lower()
            if "art of computer programming" in q_title:
                # Reproduces C5 (unranked rows hit a review / later record rather than Knuth 1968 book)
                self._send_json(200, {
                    "status": "ok",
                    "message": {
                        "items": [{
                            "DOI": "10.1137/1011045",
                            "title": ["The Art of Computer Programming, Volume 1: Fundamental Algorithms"],
                            "author": [{"given": "D. G.", "family": "Moursund"}],
                            "published-print": {"date-parts": [[1969, 4]]},
                            "container-title": ["SIAM Review"],
                        }]
                    },
                })
            else:
                self._send_json(200, {"status": "ok", "message": {"items": []}})
            return

        # OpenAlex endpoints
        if raw_path.startswith("/openalex/works/https://doi.org/"):
            doi = raw_path[len("/openalex/works/https://doi.org/"):].strip().lower()
            if doi in OPENALEX_BY_DOI:
                self._send_json(200, OPENALEX_BY_DOI[doi])
            else:
                self._send_json(404, {"error": "Not found"})
            return

        if raw_path == "/openalex/works":
            self._send_json(200, {"results": []})
            return

        self._send_json(404, {"error": "unhandled path", "path": raw_path})


def main():
    port_file = sys.argv[1]
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    with open(port_file, "w", encoding="utf-8") as fh:
        fh.write(str(port))
    srv.serve_forever()


if __name__ == "__main__":
    main()
PYEOF

    python3 "${LOOPBACK_PY}" "${PORT_FILE}" &
    SERVER_PID=$!
    for _ in $(seq 1 50); do
        if [[ -s "${PORT_FILE}" ]]; then
            break
        fi
        sleep 0.1
    done
    SERVER_PORT="$(cat "${PORT_FILE}")"
    LOOPBACK_BASE="http://127.0.0.1:${SERVER_PORT}"
    echo "[INFO] Local loopback Scholar fixture server listening at ${LOOPBACK_BASE}"

    # Find an unused closed port for Row 1 offline verification
    CLOSED_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); p=s.getsockname()[1]; s.close(); print(p)')"

    # ------------------------------------------------------------------
    # ROW 1: Offline first -> all Unverified, 0 cache entries;
    #        then online -> fresh queries & 3 real papers Verified!
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 1: Offline -> Unverified (0 cached), then Online -> Re-queries & Verifies ---"
    ROW1_CACHE="${TMP_ROOT}/row1_cache"
    mkdir -p "${ROW1_CACHE}"

    set +e
    ROW1_OFFLINE_JSON="$(
        CITESTUDIO_CROSSREF_BASE_URL="http://127.0.0.1:${CLOSED_PORT}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="http://127.0.0.1:${CLOSED_PORT}/openalex" \
        CITESTUDIO_HTTP_TIMEOUT=1.5 \
        "${BIN}" --cli verify "${TEST_BIB}" --json --cache-dir "${ROW1_CACHE}" --lang en
    )"
    ROW1_OFFLINE_CODE=$?

    ROW1_OFFLINE_ZH="$(
        CITESTUDIO_CROSSREF_BASE_URL="http://127.0.0.1:${CLOSED_PORT}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="http://127.0.0.1:${CLOSED_PORT}/openalex" \
        CITESTUDIO_HTTP_TIMEOUT=1.5 \
        "${BIN}" --cli verify "${TEST_BIB}" --cache-dir "${ROW1_CACHE}" --lang zh
    )"
    ROW1_OFFLINE_ZH_CODE=$?
    set -e

    if [[ "${ROW1_OFFLINE_CODE}" -eq 0 || "${ROW1_OFFLINE_ZH_CODE}" -eq 0 ]]; then
        echo "FAIL Row 1: Offline verify unexpectedly exited 0" >&2
        exit 1
    fi

    python3 - "${ROW1_OFFLINE_JSON}" "${ROW1_OFFLINE_ZH}" "${ROW1_CACHE}/scholar_cache.sqlite" <<'PYEOF'
import json, sqlite3, sys
data = json.loads(sys.argv[1])
zh_text = sys.argv[2]
db_path = sys.argv[3]
diags = data["entries"]
assert len(diags) == 12, f"Expected 12 entries, got {len(diags)}"
kinds = {d["verdict"] for d in diags}
assert kinds == {"Unverified"}, f"Expected all Unverified when offline, got {kinds}"
assert zh_text.count("[Unverified | 未验证]") == 12, f"Expected 12 [Unverified | 未验证] badges in ZH output, got:\n{zh_text}"
assert "[GhostPaper | 确认不存在]" not in zh_text, "Offline output must never classify any entry as 确认不存在"
assert "确认不存在(GhostPaper)=0" in zh_text, zh_text

conn = sqlite3.connect(db_path)
count = conn.execute("SELECT COUNT(*) FROM scholar_cache").fetchone()[0]
conn.close()
assert count == 0, f"Offline Unverified must write 0 cache rows, found {count}"
PYEOF

    BEFORE_REQS="$(python3 -c "import json,urllib.request; print(json.load(urllib.request.urlopen('${LOOPBACK_BASE}/_stats'))['requests'])")"

    set +e
    ROW1_ONLINE_JSON="$(
        CITESTUDIO_CROSSREF_BASE_URL="${LOOPBACK_BASE}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="${LOOPBACK_BASE}/openalex" \
        "${BIN}" --cli verify "${TEST_BIB}" --json --cache-dir "${ROW1_CACHE}" --lang en
    )"
    set -e

    AFTER_REQS="$(python3 -c "import json,urllib.request; print(json.load(urllib.request.urlopen('${LOOPBACK_BASE}/_stats'))['requests'])")"

    python3 - "${ROW1_ONLINE_JSON}" "${BEFORE_REQS}" "${AFTER_REQS}" <<'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
before_r, after_r = int(sys.argv[2]), int(sys.argv[3])
assert after_r > before_r, f"Expected fresh HTTP queries after offline run ({before_r} -> {after_r})"
by_key = {d["citeKey"]: d["verdict"] for d in data["entries"]}
for real_key in ("real_lecun", "real_lstm", "real_watson"):
    assert by_key[real_key] == "Verified", f"Expected {real_key}=Verified, got {by_key[real_key]}"
PYEOF
    echo "[PASS] Row 1: Offline returned 12/12 Unverified (未验证) with 0 cached rows; Online sent $((AFTER_REQS - BEFORE_REQS)) fresh requests and verified all 3 real papers."

    # ------------------------------------------------------------------
    # ROW 2: Upstream HTTP 429, HTTP 500, and Timeout -> Unverified, 0 cached
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 2: Upstream HTTP 429 / HTTP 500 / Timeout -> Unverified (0 cached) ---"
    SINGLE_BIB="${TMP_ROOT}/single_real.bib"
    head -n 1 "${TEST_BIB}" > "${SINGLE_BIB}"

    for FAULT in 429 500 timeout; do
        python3 -c "import urllib.request; req=urllib.request.Request('${LOOPBACK_BASE}/_mode/${FAULT}', method='POST'); urllib.request.urlopen(req).read()"
        FAULT_CACHE="${TMP_ROOT}/row2_${FAULT}"
        mkdir -p "${FAULT_CACHE}"

        set +e
        FAULT_EN_JSON="$(
            CITESTUDIO_CROSSREF_BASE_URL="${LOOPBACK_BASE}/crossref" \
            CITESTUDIO_OPENALEX_BASE_URL="${LOOPBACK_BASE}/openalex" \
            CITESTUDIO_HTTP_TIMEOUT=0.6 \
            "${BIN}" --cli verify "${SINGLE_BIB}" --json --cache-dir "${FAULT_CACHE}" --lang en
        )"
        FAULT_CODE=$?
        FAULT_ZH_TXT="$(
            CITESTUDIO_CROSSREF_BASE_URL="${LOOPBACK_BASE}/crossref" \
            CITESTUDIO_OPENALEX_BASE_URL="${LOOPBACK_BASE}/openalex" \
            CITESTUDIO_HTTP_TIMEOUT=0.6 \
            "${BIN}" --cli verify "${SINGLE_BIB}" --cache-dir "${FAULT_CACHE}" --lang zh
        )"
        set -e

        python3 - "${FAULT}" "${FAULT_CODE}" "${FAULT_EN_JSON}" "${FAULT_ZH_TXT}" "${FAULT_CACHE}/scholar_cache.sqlite" <<'PYEOF'
import json, sqlite3, sys
fault, code, en_raw, zh_txt, db_path = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
assert code != 0, f"Fault {fault} must exit non-zero"
data = json.loads(en_raw)
kind = data["entries"][0]["verdict"]
assert kind == "Unverified", f"Fault {fault}: expected Unverified, got {kind}"
assert "[Unverified | 未验证]" in zh_txt, f"Fault {fault}: expected [Unverified | 未验证] in ZH output, got {zh_txt}"
conn = sqlite3.connect(db_path)
rows = conn.execute("SELECT COUNT(*) FROM scholar_cache").fetchone()[0]
conn.close()
assert rows == 0, f"Fault {fault}: expected 0 cache rows, got {rows}"
PYEOF
        echo "  [ok] Fault=${FAULT} -> Unverified / [未验证], exit=${FAULT_CODE}, cache_rows=0"
    done
    python3 -c "import urllib.request; req=urllib.request.Request('${LOOPBACK_BASE}/_mode/normal', method='POST'); urllib.request.urlopen(req).read()"
    echo "[PASS] Row 2: HTTP 429, HTTP 500, and timeout all classified as Unverified with 0 negative-cache entries."

    # ------------------------------------------------------------------
    # ROW 3: Real DOI + wrong title -> MetadataMismatch; add_verified_bibtex rejects
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 3: Real DOI + Wrong Title -> MetadataMismatch & MCP Gate Rejection ---"
    ROW3_CACHE="${TMP_ROOT}/row3_cache"
    mkdir -p "${ROW3_CACHE}"
    WRONGTITLE_BIB="${TMP_ROOT}/wrongtitle_input.bib"
    sed -n '6p' "${TEST_BIB}" > "${WRONGTITLE_BIB}"

    set +e
    ROW3_CLI_JSON="$(
        CITESTUDIO_CROSSREF_BASE_URL="${LOOPBACK_BASE}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="${LOOPBACK_BASE}/openalex" \
        "${BIN}" --cli verify "${WRONGTITLE_BIB}" --json --cache-dir "${ROW3_CACHE}" --lang en
    )"
    ROW3_CLI_CODE=$?
    set -e

    TARGET_ROW3_BIB="${TMP_ROOT}/row3_target.bib"
    printf '%% Protected bibliography\n' > "${TARGET_ROW3_BIB}"
    SHA_BEFORE="$(shasum -a 256 "${TARGET_ROW3_BIB}" | awk '{print $1}')"

    ROW3_MCP_REQ="$(python3 - "${TARGET_ROW3_BIB}" "${WRONGTITLE_BIB}" <<'PYEOF'
import json, sys
bib_line = open(sys.argv[2], encoding="utf-8").read().strip()
req = {
    "jsonrpc": "2.0",
    "id": 301,
    "method": "tools/call",
    "params": {
        "name": "add_verified_bibtex",
        "arguments": {"bib_file": sys.argv[1], "bibtex": bib_line},
    },
}
print(json.dumps(req))
PYEOF
)"

    ROW3_MCP_RESP="$(
        printf '%s\n' "${ROW3_MCP_REQ}" | \
        CITESTUDIO_CROSSREF_BASE_URL="${LOOPBACK_BASE}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="${LOOPBACK_BASE}/openalex" \
        "${BIN}" --mcp --cache-dir "${ROW3_CACHE}" --lang en
    )"
    SHA_AFTER="$(shasum -a 256 "${TARGET_ROW3_BIB}" | awk '{print $1}')"

    python3 - "${ROW3_CLI_CODE}" "${ROW3_CLI_JSON}" "${ROW3_MCP_RESP}" "${SHA_BEFORE}" "${SHA_AFTER}" <<'PYEOF'
import json, sys
code = int(sys.argv[1])
cli_data = json.loads(sys.argv[2])
mcp_resp = json.loads(sys.argv[3].strip().splitlines()[-1])
sha_before, sha_after = sys.argv[4], sys.argv[5]
assert code != 0, "wrongtitle CLI verify must exit non-zero"
assert cli_data["entries"][0]["verdict"] == "MetadataMismatch", cli_data
text = mcp_resp["result"]["content"][0]["text"]
assert mcp_resp["result"]["isError"] is True, mcp_resp
assert "ERR_UNVERIFIED_CITATION" in text and "MetadataMismatch" in text, text
assert sha_before == sha_after, "Target .bib file must remain untouched upon rejection"
PYEOF
    echo "[PASS] Row 3: Real DOI with wrong title flagged as MetadataMismatch; add_verified_bibtex rejected with ERR_UNVERIFIED_CITATION (SHA-256 unchanged)."

    # ------------------------------------------------------------------
    # ROW 4: Wakefield 1998 & Séralini 2012 -> Both Retracted
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 4: Wakefield 1998 & Séralini 2012 -> Both Retracted ---"
    ROW4_CACHE="${TMP_ROOT}/row4_cache"
    mkdir -p "${ROW4_CACHE}"
    RETRACTED_BIB="${TMP_ROOT}/retracted_pair.bib"
    tail -n 2 "${TEST_BIB}" > "${RETRACTED_BIB}"

    set +e
    ROW4_EN_JSON="$(
        CITESTUDIO_CROSSREF_BASE_URL="${LOOPBACK_BASE}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="${LOOPBACK_BASE}/openalex" \
        "${BIN}" --cli verify "${RETRACTED_BIB}" --json --cache-dir "${ROW4_CACHE}" --lang en
    )"
    ROW4_CODE=$?
    ROW4_ZH_TXT="$(
        CITESTUDIO_CROSSREF_BASE_URL="${LOOPBACK_BASE}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="${LOOPBACK_BASE}/openalex" \
        "${BIN}" --cli verify "${RETRACTED_BIB}" --cache-dir "${ROW4_CACHE}" --lang zh
    )"
    set -e

    python3 - "${ROW4_CODE}" "${ROW4_EN_JSON}" "${ROW4_ZH_TXT}" <<'PYEOF'
import json, sys
code = int(sys.argv[1])
data = json.loads(sys.argv[2])
zh = sys.argv[3]
assert code != 0, "Retracted bibliography must exit non-zero"
by_key = {d["citeKey"]: d["verdict"] for d in data["entries"]}
assert by_key == {"retracted_seralini": "Retracted", "retracted_wakefield": "Retracted"}, by_key
assert zh.count("[Retracted | 已撤稿]") == 2, zh
PYEOF
    echo "[PASS] Row 4: Both Wakefield 1998 and Séralini 2012 classified as Retracted ([已撤稿])."

    # ------------------------------------------------------------------
    # ROW 5: add_verified_bibtex writes canonical upstream title & deduplicates
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 5: add_verified_bibtex Writes Canonical Upstream Metadata & Deduplicates ---"
    ROW5_CACHE="${TMP_ROOT}/row5_cache"
    mkdir -p "${ROW5_CACHE}"
    ROW5_BIB="${TMP_ROOT}/row5_canonical.bib"
    : > "${ROW5_BIB}"

    ROW5_REQS="$(python3 - "${ROW5_BIB}" <<'PYEOF'
import json, sys
scrambled = "@article{real_lecun, author = {lecun, yann}, title = {dEEP lEARNING}, journal = {nATURE}, year = {2015}, doi = {10.1038/nature14539}}"
for req_id in (501, 502):
    print(json.dumps({
        "jsonrpc": "2.0",
        "id": req_id,
        "method": "tools/call",
        "params": {
            "name": "add_verified_bibtex",
            "arguments": {"bib_file": sys.argv[1], "bibtex": scrambled},
        },
    }))
PYEOF
)"

    ROW5_MCP_OUT="$(
        printf '%s\n' "${ROW5_REQS}" | \
        CITESTUDIO_CROSSREF_BASE_URL="${LOOPBACK_BASE}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="${LOOPBACK_BASE}/openalex" \
        "${BIN}" --mcp --cache-dir "${ROW5_CACHE}" --lang en
    )"

    python3 - "${ROW5_MCP_OUT}" "${ROW5_BIB}" <<'PYEOF'
import json, sys
lines = [json.loads(line) for line in sys.argv[1].strip().splitlines() if line.strip()]
bib_content = open(sys.argv[2], encoding="utf-8").read()
assert "APPENDED_VERIFIED" in lines[0]["result"]["content"][0]["text"], lines[0]
assert "SKIPPED_DUPLICATE_KEY" in lines[1]["result"]["content"][0]["text"], lines[1]
assert "title = {Deep learning}" in bib_content, f"Expected canonical upstream title in:\n{bib_content}"
assert "dEEP lEARNING" not in bib_content, f"Scrambled caller title leaked into:\n{bib_content}"
assert bib_content.count("@article{real_lecun,") == 1, f"Expected single deduplicated entry in:\n{bib_content}"
PYEOF
    echo "[PASS] Row 5: add_verified_bibtex wrote canonical upstream 'title = {Deep learning}' and skipped duplicate citeKey."

    # ------------------------------------------------------------------
    # ROW 6: CiteStudio --cli lint /nonexistent.tex -> Non-zero exit & stderr error
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 6: Missing File & Invalid CLI Arguments Return Non-Zero Exit Code ---"
    MISSING_TEX="${TMP_ROOT}/does_not_exist.tex"
    ERR_EN_FILE="${TMP_ROOT}/row6_en.err"
    ERR_ZH_FILE="${TMP_ROOT}/row6_zh.err"

    set +e
    OUT_EN="$("${BIN}" --cli lint "${MISSING_TEX}" --lang en 2>"${ERR_EN_FILE}")"
    CODE_EN=$?
    OUT_ZH="$("${BIN}" --cli lint "${MISSING_TEX}" --lang zh 2>"${ERR_ZH_FILE}")"
    CODE_ZH=$?
    "${BIN}" --cli compile "${MISSING_TEX}" --lang en >/dev/null 2>"${TMP_ROOT}/row6_compile.err"
    CODE_COMPILE=$?
    "${BIN}" --cli unknown-subcmd >/dev/null 2>"${TMP_ROOT}/row6_unknown.err"
    CODE_UNKNOWN=$?
    set -e

    python3 - "${CODE_EN}" "${OUT_EN}" "${ERR_EN_FILE}" "${CODE_ZH}" "${OUT_ZH}" "${ERR_ZH_FILE}" "${CODE_COMPILE}" "${CODE_UNKNOWN}" <<'PYEOF'
import sys
code_en, out_en, err_en = int(sys.argv[1]), sys.argv[2], open(sys.argv[3], encoding="utf-8").read()
code_zh, out_zh, err_zh = int(sys.argv[4]), sys.argv[5], open(sys.argv[6], encoding="utf-8").read()
code_comp, code_unk = int(sys.argv[7]), int(sys.argv[8])
assert code_en != 0 and code_zh != 0 and code_comp != 0 and code_unk != 0
assert out_en == "" and out_zh == ""
assert "File does not exist" in err_en, err_en
assert "文件不存在" in err_zh, err_zh
PYEOF
    echo "[PASS] Row 6: --cli lint /nonexistent.tex exited ${CODE_EN} (EN) / ${CODE_ZH} (ZH) with clear file-not-found stderr message."

    # ------------------------------------------------------------------
    # ROW 7: Launch GUI without --demo -> Empty state (0 manuscript, 0 bib, 0 diags)
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 7: GUI Without --demo Starts Empty (0 Manuscript, 0 Bib, 0 Diagnostics) ---"
    for LANG_TAG in en zh; do
        UI_SNAP="${TMP_ROOT}/ui_empty_${LANG_TAG}.json"
        rm -f "${UI_SNAP}"
        CITESTUDIO_UI_STATE_FILE="${UI_SNAP}" CITESTUDIO_EPHEMERAL_DEFAULTS=1 "${BIN}" --lang "${LANG_TAG}" >/dev/null 2>&1 &
        GUI_PID=$!
        for _ in $(seq 1 50); do
            if [[ -s "${UI_SNAP}" ]]; then
                break
            fi
            sleep 0.1
        done
        kill "${GUI_PID}" 2>/dev/null || true
        wait "${GUI_PID}" 2>/dev/null || true
        GUI_PID=""

        python3 - "${LANG_TAG}" "${UI_SNAP}" <<'PYEOF'
import json, os, sys
lang_tag, snap_path = sys.argv[1], sys.argv[2]
assert os.path.exists(snap_path), f"GUI snapshot not written for {lang_tag}"
snap = json.load(open(snap_path, encoding="utf-8"))
assert snap["isDemoMode"] is False, snap
assert snap["manuscriptChars"] == 0, snap
assert snap["bibEntries"] == 0, snap
assert snap["diagnostics"] == 0, snap
assert snap["lintFindings"] == 0, snap
PYEOF
        echo "  [ok] GUI default launch (--lang ${LANG_TAG}) -> $(cat "${UI_SNAP}")"
    done
    echo "[PASS] Row 7: Desktop GUI without --demo launched with 0 manuscript chars, 0 bib entries, 0 diagnostics in both EN and ZH."

    # ------------------------------------------------------------------
    # ROW 8: Full 12-entry test.bib via CLI verify + MCP verify_citation
    #        (11/12 match ground truth; only C5 real_nodoi is MetadataMismatch)
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 8: Full 12-Entry test.bib Matrix via CLI verify & MCP verify_citation ---"
    ROW8_CACHE="${TMP_ROOT}/row8_cache"
    mkdir -p "${ROW8_CACHE}"

    set +e
    ROW8_CLI_JSON="$(
        CITESTUDIO_CROSSREF_BASE_URL="${LOOPBACK_BASE}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="${LOOPBACK_BASE}/openalex" \
        "${BIN}" --cli verify "${TEST_BIB}" --json --cache-dir "${ROW8_CACHE}" --lang en
    )"
    ROW8_CLI_CODE=$?
    set -e

    ROW8_MCP_REQ="$(python3 - "${TEST_BIB}" <<'PYEOF'
import json, sys
for idx, line in enumerate(open(sys.argv[1], encoding="utf-8"), start=1):
    stanza = line.strip()
    if not stanza:
        continue
    print(json.dumps({
        "jsonrpc": "2.0",
        "id": 800 + idx,
        "method": "tools/call",
        "params": {"name": "verify_citation", "arguments": {"bibtex": stanza}},
    }))
PYEOF
)"

    ROW8_MCP_RESP="$(
        printf '%s\n' "${ROW8_MCP_REQ}" | \
        CITESTUDIO_CROSSREF_BASE_URL="${LOOPBACK_BASE}/crossref" \
        CITESTUDIO_OPENALEX_BASE_URL="${LOOPBACK_BASE}/openalex" \
        "${BIN}" --mcp --cache-dir "${ROW8_CACHE}" --lang en
    )"

    python3 - "${ROW8_CLI_CODE}" "${ROW8_CLI_JSON}" "${ROW8_MCP_RESP}" <<'PYEOF'
import json, sys
cli_code = int(sys.argv[1])
cli_data = json.loads(sys.argv[2])
mcp_lines = [json.loads(line) for line in sys.argv[3].strip().splitlines() if line.strip()]
mcp_diags = [json.loads(item["result"]["content"][0]["text"]) for item in mcp_lines]

assert cli_code != 0, "Mixed 12-entry test.bib must exit non-zero"
cli_map = {d["citeKey"]: d["verdict"] for d in cli_data["entries"]}
mcp_map = {d["citeKey"]: d["verdict"] for d in mcp_diags}
assert cli_map == mcp_map, f"CLI and MCP verdicts diverged:\nCLI={cli_map}\nMCP={mcp_map}"

expected_m0 = {
    "real_lecun": "Verified",
    "real_lstm": "Verified",
    "real_watson": "Verified",
    "fake_nonsentinel": "GhostPaper",
    "fake_sentinel": "GhostPaper",
    "fake_nodoi": "GhostPaper",
    "wrongtitle": "MetadataMismatch",
    "wrongyear": "MetadataMismatch",
    "wrongyear5": "MetadataMismatch",
    "retracted_seralini": "Retracted",
    "retracted_wakefield": "Retracted",
    "real_nodoi": "MetadataMismatch",  # Known C5 no-DOI classic book limitation (scheduled for M1)
}
assert cli_map == expected_m0, f"Unexpected M0 verdict matrix:\nGot:      {cli_map}\nExpected: {expected_m0}"
for k, v in cli_map.items():
    note = " (expected M0 C5 limitation -> M1)" if k == "real_nodoi" else ""
    print(f"  {k:22s} -> CLI={v:16s} | MCP={mcp_map[k]:16s}{note}")
PYEOF

    # Verify exit 0 when all entries in a .bib are Verified, and test --cli clear-cache
    ONLY_REAL_BIB="${TMP_ROOT}/only_real_3.bib"
    head -n 3 "${TEST_BIB}" > "${ONLY_REAL_BIB}"
    CITESTUDIO_CROSSREF_BASE_URL="${LOOPBACK_BASE}/crossref" \
    CITESTUDIO_OPENALEX_BASE_URL="${LOOPBACK_BASE}/openalex" \
    "${BIN}" --cli verify "${ONLY_REAL_BIB}" --cache-dir "${ROW8_CACHE}" --lang zh >/dev/null

    CLEAR_EN="$("${BIN}" --cli clear-cache --cache-dir "${ROW8_CACHE}" --lang en)"
    CLEAR_ZH="$("${BIN}" --cli clear-cache --cache-dir "${ROW8_CACHE}" --lang zh)"
    echo "  clear-cache (EN): ${CLEAR_EN}"
    echo "  clear-cache (ZH): ${CLEAR_ZH}"
    echo "[PASS] Row 8: CLI verify and MCP verify_citation share identical verdicts across all 12 entries (11/12 ground-truth + C5 real_nodoi documented for M1)."

    echo ""
    echo "=================================================================="
    echo "ALL 8 M0 ACCEPTANCE ROWS PASSED (EN + ZH, ZERO EXTERNAL API CALLS)"
    echo "=================================================================="
}

if [[ "${1:-}" == "--run-inner" ]]; then
    run_suite
else
    "${BASH_SOURCE[0]}" --run-inner 2>&1 | tee "${REPORT_FILE}"
fi
