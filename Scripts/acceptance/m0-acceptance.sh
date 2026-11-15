#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_DIR="${ROOT_DIR}/reports"
REPORT_FILE="${REPORT_DIR}/m0-acceptance.txt"

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
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/citestudio-m0-acc.XXXXXX")"
SERVER_PID=""
ACTIVE_MUTATION_TARGET=""
ACTIVE_MUTATION_BACKUP=""

cleanup() {
    if [[ -n "${ACTIVE_MUTATION_TARGET}" && -n "${ACTIVE_MUTATION_BACKUP}" && -f "${ACTIVE_MUTATION_BACKUP}" ]]; then
        cp "${ACTIVE_MUTATION_BACKUP}" "${ACTIVE_MUTATION_TARGET}" || true
    fi
    if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
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
    echo "=================================================================="
    echo "CiteStudio M0 Acceptance Verification (m0-acceptance.sh)"
    echo "Timestamp (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "Commit / Branch: $(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD) @ $(git -C "${ROOT_DIR}" rev-parse --short HEAD)"
    echo "Network Policy : Local 127.0.0.1 loopback ONLY (0 external API calls; 0 GUI windows)"
    echo "=================================================================="

    cd "${ROOT_DIR}"
    swift build -q
    BIN="${ROOT_DIR}/.build/debug/CiteStudio"
    if [[ ! -x "${BIN}" ]]; then
        echo "FAIL: Missing executable ${BIN}" >&2
        exit 1
    fi

    TEST_BIB="${ROOT_DIR}/Tests/Fixtures/test.bib"
    if [[ ! -f "${TEST_BIB}" ]]; then
        echo "FAIL: Missing fixture bibliography ${TEST_BIB}" >&2
        exit 1
    fi
    RECORDED_DIR="${ROOT_DIR}/Tests/Fixtures/recorded"

    export HOME="${TMP_ROOT}/fake_home"
    export CITESTUDIO_EPHEMERAL_DEFAULTS=1
    mkdir -p "${HOME}"

    echo "[C23] Validating recorded upstream fixtures in Tests/Fixtures/recorded/..."
    python3 "${ROOT_DIR}/Scripts/acceptance/validate_recorded_fixtures.py" "${RECORDED_DIR}" --min-items 20
    HAS_RECORDED_FIXTURES=1

    # Local 127.0.0.1 loopback server:
    # - Upstream responses in replay mode come STRICTLY from Tests/Fixtures/recorded/*.meta.json + raw files (C15).
    # - Synthetic payloads exist ONLY for fault injection (429, 500, 503, malformed_json, timeout).
    PORT_FILE="${TMP_ROOT}/server_port.txt"
    LOOPBACK_PY="${TMP_ROOT}/loopback_replay_and_fault_server.py"
    cat > "${LOOPBACK_PY}" <<'PYEOF'
import glob
import http.server
import json
import os
import socketserver
import sys
import threading
import time
import urllib.parse

RECORDED_DIR = ""
INDEX = {}
STATE = {"mode": "replay", "requests": 0}
LOCK = threading.Lock()


def canonical_key(service: str, raw_url_or_path: str):
    u = urllib.parse.urlsplit(raw_url_or_path)
    norm_path = urllib.parse.unquote(u.path).rstrip("/") or "/"
    norm_query = tuple(sorted(urllib.parse.parse_qsl(u.query, keep_blank_values=True)))
    return (service, norm_path.lower(), norm_query)


def load_recorded_fixtures(rec_dir: str):
    if not os.path.isdir(rec_dir):
        return
    for meta_path in sorted(glob.glob(os.path.join(rec_dir, "*.meta.json"))):
        with open(meta_path, encoding="utf-8") as fh:
            meta = json.load(fh)
        service = meta["service"]
        url = meta["url"]
        raw_path = os.path.join(rec_dir, meta["raw_file"])
        if not os.path.isfile(raw_path):
            continue
        key = canonical_key(service, url)
        INDEX[key] = (int(meta["status"]), meta.get("content_type", "application/json"), raw_path)


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _send_bytes(self, code: int, content_type: str, body: bytes):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path.startswith("/_mode/"):
            mode = self.path[len("/_mode/"):].strip()
            with LOCK:
                STATE["mode"] = mode
            self._send_bytes(200, "application/json", json.dumps(STATE).encode("utf-8"))
            return
        self._send_bytes(404, "application/json", b'{"error":"unknown_control_endpoint"}')

    def do_GET(self):
        if self.path == "/_stats":
            with LOCK:
                snap = dict(STATE)
                snap["recorded_count"] = len(INDEX)
            self._send_bytes(200, "application/json", json.dumps(snap).encode("utf-8"))
            return

        with LOCK:
            STATE["requests"] += 1
            mode = STATE["mode"]

        # Synthetic fault injection ONLY (permitted by C15)
        if mode == "429":
            self._send_bytes(429, "application/json", b'{"error":"fault_injected_429"}')
            return
        if mode == "500":
            self._send_bytes(500, "application/json", b'{"error":"fault_injected_500"}')
            return
        if mode == "503":
            self._send_bytes(503, "application/json", b'{"error":"fault_injected_503"}')
            return
        if mode == "malformed_json":
            self._send_bytes(200, "application/json", b"{broken")
            return
        if mode == "timeout":
            time.sleep(2.2)
            self._send_bytes(200, "application/json", b"{}")
            return

        # Strict recorded-fixture replay from Tests/Fixtures/recorded/
        if self.path.startswith("/crossref/"):
            sub = self.path[len("/crossref"):]
            key = canonical_key("crossref", sub)
        elif self.path.startswith("/openalex/"):
            sub = self.path[len("/openalex"):]
            key = canonical_key("openalex", sub)
        else:
            self._send_bytes(501, "application/json", b'{"error":"invalid_service_prefix"}')
            return

        hit = INDEX.get(key)
        if hit is None:
            # Never synthesize a fake 404 when a fixture is unrecorded; return 501 so unrecorded URLs surface as Unverified.
            self._send_bytes(501, "application/json", b'{"error":"unrecorded_fixture_url"}')
            return

        status_code, content_type, raw_path = hit
        with open(raw_path, "rb") as bf:
            raw_bytes = bf.read()
        self._send_bytes(status_code, content_type, raw_bytes)


def main():
    global RECORDED_DIR
    port_file, RECORDED_DIR = sys.argv[1], sys.argv[2]
    load_recorded_fixtures(RECORDED_DIR)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(port_file, "w", encoding="utf-8") as fh:
        fh.write(str(srv.server_address[1]))
    srv.serve_forever()


if __name__ == "__main__":
    main()
PYEOF

    python3 "${LOOPBACK_PY}" "${PORT_FILE}" "${RECORDED_DIR}" &
    SERVER_PID=$!
    for _ in $(seq 1 50); do
        if [[ -s "${PORT_FILE}" ]]; then
            break
        fi
        sleep 0.1
    done
    SERVER_PORT="$(cat "${PORT_FILE}")"
    LOOPBACK_BASE="http://127.0.0.1:${SERVER_PORT}"
    echo "[INFO] Local loopback replay/fault server listening at ${LOOPBACK_BASE} (recorded_fixtures=${HAS_RECORDED_FIXTURES})"

    CLOSED_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); p=s.getsockname()[1]; s.close(); print(p)')"
    SKIP_RECORD_MSG="SKIPPED (没跑): Tests/Fixtures/recorded/ has no recorded fixtures yet; run CITESTUDIO_RECORD=1 ./Scripts/acceptance/record-fixtures.sh after user approval"

    ACC_PASSED=0
    ACC_SKIPPED=0
    ACC_SKIPPED_ITEMS=()

    # ------------------------------------------------------------------
    # ROW 1: Offline first -> all Unverified, 0 cache entries;
    #        then online replay (if recorded fixtures present) -> re-queries & verifies!
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 1: Offline -> Unverified (0 cached); Online Recorded Replay -> Re-queries ---"
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
        echo "FAIL Row 1a: Offline verify unexpectedly exited 0" >&2
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
    echo "[PASS] Row 1a (Offline): 12/12 Unverified ([Unverified | 未验证]), 0 GhostPaper, 0 SQLite cache rows (exit=${ROW1_OFFLINE_CODE})."
    ACC_PASSED=$((ACC_PASSED + 1))

    if [[ "${HAS_RECORDED_FIXTURES}" -eq 1 ]]; then
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
        echo "[PASS] Row 1b (Online Recorded Replay): Sent $((AFTER_REQS - BEFORE_REQS)) fresh requests and verified real_lecun, real_lstm, real_watson."
        ACC_PASSED=$((ACC_PASSED + 1))
    else
        echo "[Row 1b - Online Replay] ${SKIP_RECORD_MSG}"
        ACC_SKIPPED=$((ACC_SKIPPED + 1))
        ACC_SKIPPED_ITEMS+=("Row 1b")
    fi

    # ------------------------------------------------------------------
    # ROW 2: Upstream HTTP 429, HTTP 500, Malformed JSON, and Timeout -> Unverified, 0 cached
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 2: Upstream HTTP 429 / HTTP 500 / Malformed JSON / Timeout -> Unverified (0 cached) ---"
    SINGLE_BIB="${TMP_ROOT}/single_real.bib"
    head -n 1 "${TEST_BIB}" > "${SINGLE_BIB}"

    for FAULT in 429 500 malformed_json timeout; do
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
        echo "  [ok] Fault=${FAULT} -> Unverified / [Unverified | 未验证], exit=${FAULT_CODE}, cache_rows=0"
    done
    python3 -c "import urllib.request; req=urllib.request.Request('${LOOPBACK_BASE}/_mode/replay', method='POST'); urllib.request.urlopen(req).read()"
    echo "[PASS] Row 2: HTTP 429, HTTP 500, malformed JSON, and timeout all classified as Unverified with 0 negative-cache entries."
    ACC_PASSED=$((ACC_PASSED + 1))

    # ------------------------------------------------------------------
    # ROW 3: Real DOI + wrong title -> MetadataMismatch; add_verified_bibtex rejects
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 3: Real DOI + Wrong Title (Recorded Replay) -> MetadataMismatch & MCP Gate Rejection ---"
    if [[ "${HAS_RECORDED_FIXTURES}" -eq 1 ]]; then
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
        echo "[PASS] Row 3: Recorded replay flagged wrong title as MetadataMismatch and rejected add_verified_bibtex."
        ACC_PASSED=$((ACC_PASSED + 1))
    else
        echo "[Row 3] ${SKIP_RECORD_MSG}"
        ACC_SKIPPED=$((ACC_SKIPPED + 1))
        ACC_SKIPPED_ITEMS+=("Row 3")
    fi

    # ------------------------------------------------------------------
    # ROW 4: Wakefield 1998 & Séralini 2012 -> Both Retracted (Recorded Replay)
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 4: Wakefield 1998 & Séralini 2012 (Recorded Replay) -> Retracted ---"
    if [[ "${HAS_RECORDED_FIXTURES}" -eq 1 ]]; then
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
        echo "[PASS] Row 4: Recorded replay classified Wakefield 1998 and Séralini 2012 as Retracted ([已撤稿])."
        ACC_PASSED=$((ACC_PASSED + 1))
    else
        echo "[Row 4] ${SKIP_RECORD_MSG}"
        ACC_SKIPPED=$((ACC_SKIPPED + 1))
        ACC_SKIPPED_ITEMS+=("Row 4")
    fi

    # ------------------------------------------------------------------
    # ROW 5: add_verified_bibtex writes canonical upstream title & deduplicates (Recorded Replay)
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 5: add_verified_bibtex Canonical Upstream Metadata & Deduplication (Recorded Replay) ---"
    if [[ "${HAS_RECORDED_FIXTURES}" -eq 1 ]]; then
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
assert "dEEP lEARNING" not in bib_content, f"Scrambled caller title leaked into:\n{bib_content}"
assert "deep learning" in bib_content.lower(), f"Expected canonical upstream title in:\n{bib_content}"
assert bib_content.count("@article{real_lecun,") == 1, f"Expected single deduplicated entry in:\n{bib_content}"
PYEOF
        echo "[PASS] Row 5: Recorded replay wrote canonical upstream metadata and skipped duplicate citeKey."
        ACC_PASSED=$((ACC_PASSED + 1))
    else
        echo "[Row 5] ${SKIP_RECORD_MSG}"
        ACC_SKIPPED=$((ACC_SKIPPED + 1))
        ACC_SKIPPED_ITEMS+=("Row 5")
    fi

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
assert code_en == 2 and code_zh == 2 and code_comp == 2 and code_unk == 2
assert out_en == "" and out_zh == ""
assert "File does not exist" in err_en, err_en
assert "文件不存在" in err_zh, err_zh
PYEOF
    echo "[PASS] Row 6: --cli lint /nonexistent.tex exited ${CODE_EN} (EN) / ${CODE_ZH} (ZH) with clear file-not-found stderr message."
    ACC_PASSED=$((ACC_PASSED + 1))

    # ------------------------------------------------------------------
    # ROW 7 (C19): Headless ViewModel Default Empty State (ZERO GUI Launch!)
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 7 (C19 Headless): Default Workspace Starts Empty Without Launching GUI ---"
    ROW7_OUT="$(swift test --no-parallel --filter "WorkspaceTests/c8DefaultSessionIsEmptyAndLoadDemoMarksDemoMode" 2>&1)"
    python3 - "${ROW7_OUT}" <<'PYEOF'
import sys
out = sys.argv[1]
assert "Test run with 1 test" in out or "1 test in 1 suite passed" in out, out
assert "✔ Test \"C8 (Row 7):" in out, out
PYEOF
    echo "[PASS] Row 7 (C19): Verified default empty workspace (0 manuscript, 0 bib, 0 diagnostics, isDemoMode=false) headlessly via WorkspaceTests (0 GUI processes launched)."
    ACC_PASSED=$((ACC_PASSED + 1))

    # ------------------------------------------------------------------
    # ROW 8 + Supplemental C16: Full 12-entry test.bib + 10.48550/arXiv.1706.03762 (Recorded Replay)
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 8 + C16: 12-Entry test.bib & 10.48550/arXiv.1706.03762 via Recorded Replay ---"
    if [[ "${HAS_RECORDED_FIXTURES}" -eq 1 ]]; then
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

        C16_BIB="${TMP_ROOT}/c16_arxiv.bib"
        cat > "${C16_BIB}" <<'EOF'
@article{vaswani2017arxiv, author = {Vaswani, Ashish and Shazeer, Noam}, title = {Attention Is All You Need}, journal = {arXiv preprint arXiv:1706.03762}, year = {2017}, doi = {10.48550/arXiv.1706.03762}}
EOF
        set +e
        C16_CLI_JSON="$(
            CITESTUDIO_CROSSREF_BASE_URL="${LOOPBACK_BASE}/crossref" \
            CITESTUDIO_OPENALEX_BASE_URL="${LOOPBACK_BASE}/openalex" \
            "${BIN}" --cli verify "${C16_BIB}" --json --cache-dir "${ROW8_CACHE}" --lang en
        )"
        set -e

        python3 - "${ROW8_CLI_CODE}" "${ROW8_CLI_JSON}" "${ROW8_MCP_RESP}" "${C16_CLI_JSON}" <<'PYEOF'
import json, sys
cli_code = int(sys.argv[1])
cli_data = json.loads(sys.argv[2])
mcp_lines = [json.loads(line) for line in sys.argv[3].strip().splitlines() if line.strip()]
mcp_diags = [json.loads(item["result"]["content"][0]["text"]) for item in mcp_lines]
c16_data = json.loads(sys.argv[4])

assert cli_code != 0, "Mixed 12-entry test.bib must exit non-zero"
cli_map = {d["citeKey"]: d["verdict"] for d in cli_data["entries"]}
mcp_map = {d["citeKey"]: d["verdict"] for d in mcp_diags}
assert cli_map == mcp_map, f"CLI and MCP verdicts diverged:\nCLI={cli_map}\nMCP={mcp_map}"
for k, v in cli_map.items():
    print(f"  {k:22s} -> CLI={v:16s} | MCP={mcp_map[k]:16s}")

expected_m0_11 = {
    "real_lecun": "Verified",
    "real_lstm": "Verified",
    "real_watson": "Verified",
    "fake_nonsentinel": "GhostPaper",
    "fake_sentinel": "GhostPaper",
    "wrongtitle": "MetadataMismatch",
    "wrongyear": "MetadataMismatch",
    "wrongyear5": "MetadataMismatch",
    "fake_nodoi": "GhostPaper",
    "retracted_seralini": "Retracted",
    "retracted_wakefield": "Retracted",
}
for k, exp_v in expected_m0_11.items():
    assert cli_map[k] == exp_v, f"Row 8 expected {k}={exp_v}, got {cli_map[k]}"
assert cli_map["real_nodoi"] == "GhostPaper", (
    f"Row 8 (M1 C5 fixed — real_nodoi Knuth 1968): recorded Odeh/MacLaren/Wells book reviews rejected on author/year/type, expected GhostPaper (not found), got {cli_map['real_nodoi']}"
)
real_nodoi_entry = next(d for d in cli_data["entries"] if d["citeKey"] == "real_nodoi")
assert "Not found in Crossref / OpenAlex" in real_nodoi_entry["headline"], real_nodoi_entry

c16_verdict = c16_data["entries"][0]["verdict"]
assert c16_verdict == "Verified", f"C16 DataCite arXiv DOI 10.48550/arXiv.1706.03762 expected Verified, got {c16_verdict}"
print(f"  [C16] 10.48550/arXiv.1706.03762 -> {c16_verdict} (not GhostPaper)")
PYEOF
        echo "[PASS] Row 8 + C16: CLI verify and MCP verify_citation matched across recorded fixtures; 10.48550/arXiv.1706.03762 != GhostPaper."
        ACC_PASSED=$((ACC_PASSED + 2))
    else
        echo "[Row 8 & C16 Recorded Replay] ${SKIP_RECORD_MSG}"
        ACC_SKIPPED=$((ACC_SKIPPED + 2))
        ACC_SKIPPED_ITEMS+=("Row 8" "Supplemental C16")
    fi

    # ------------------------------------------------------------------
    # SUPPLEMENTAL C13 & C14: PreprintUpgrade Exit Code & Doc Consistency
    # ------------------------------------------------------------------
    echo ""
    echo "--- Supplemental C13 & C14: Single PreprintUpgrade Exit Code & README Consistency ---"
    C13_OUT="$(swift test --no-parallel --filter "CLITests/c13AndC14VerifyExitCodeTimeoutAndDocConsistency" 2>&1)"
    python3 - "${C13_OUT}" <<'PYEOF'
import sys
out = sys.argv[1]
assert "✔ Test \"合成 (Synthetic HTTP) C13 + C14:" in out, out
PYEOF
    echo "[PASS] Supplemental C13/C14: 1 PreprintUpgrade entry exits 1 on --cli verify (matching README.md & README.zh-CN.md), timeout=8.0s."
    ACC_PASSED=$((ACC_PASSED + 1))

    # ------------------------------------------------------------------
    # SUPPLEMENTAL C23: Recorded Fixture SHA-256 & HTTP Date Tamper Rejection Gate
    # ------------------------------------------------------------------
    echo ""
    echo "--- Supplemental C23: Recorded Fixture SHA-256 & HTTP Date Tamper Rejection Gate ---"
    python3 - "${ROOT_DIR}/Scripts/acceptance/validate_recorded_fixtures.py" "${RECORDED_DIR}" "${TMP_ROOT}" <<'PYEOF'
import json
import os
import shutil
import subprocess
import sys

validator_py, rec_dir, tmp_root = sys.argv[1], sys.argv[2], sys.argv[3]

# 1. Corrupt 1 byte in a temporary copy of the first .raw file -> validator MUST reject
tamper_raw_dir = os.path.join(tmp_root, "c23_tamper_raw")
shutil.copytree(rec_dir, tamper_raw_dir)
manifest = json.load(open(os.path.join(tamper_raw_dir, "manifest.json"), encoding="utf-8"))
first_raw = os.path.join(tamper_raw_dir, manifest["items"][0]["raw_file"])
orig_bytes = bytearray(open(first_raw, "rb").read())
assert len(orig_bytes) > 0, "Expected non-empty first .raw fixture"
orig_bytes[0] ^= 0x01
with open(first_raw, "wb") as bf:
    bf.write(bytes(orig_bytes))
r1 = subprocess.run([sys.executable, validator_py, tamper_raw_dir, "--min-items", "20"], capture_output=True, text=True)
assert r1.returncode != 0, f"Expected 1-byte .raw tamper to fail validator, got exit 0:\n{r1.stdout}"
assert "sha256 mismatch" in r1.stderr, f"Expected sha256 mismatch error, got:\n{r1.stderr}"

# 2. Blank response_date_header in a temporary copy -> validator MUST reject
tamper_date_dir = os.path.join(tmp_root, "c23_tamper_date")
shutil.copytree(rec_dir, tamper_date_dir)
m2_path = os.path.join(tamper_date_dir, "manifest.json")
m2 = json.load(open(m2_path, encoding="utf-8"))
m2["items"][0]["response_date_header"] = ""
slug0 = m2["items"][0]["slug"]
meta0_path = os.path.join(tamper_date_dir, f"{slug0}.meta.json")
with open(meta0_path, "w", encoding="utf-8") as fh:
    json.dump(m2["items"][0], fh, indent=2, sort_keys=True)
with open(m2_path, "w", encoding="utf-8") as fh:
    json.dump(m2, fh, indent=2, sort_keys=True)
r2 = subprocess.run([sys.executable, validator_py, tamper_date_dir, "--min-items", "20"], capture_output=True, text=True)
assert r2.returncode != 0, f"Expected blank response_date_header to fail validator, got exit 0:\n{r2.stdout}"
assert "response_date_header" in r2.stderr, f"Expected response_date_header error, got:\n{r2.stderr}"
PYEOF
    echo "[PASS] Supplemental C23: Validator rejected 1-byte .raw SHA-256 tamper and blank response_date_header in isolated temp copies."
    ACC_PASSED=$((ACC_PASSED + 1))

    # ------------------------------------------------------------------
    # SUPPLEMENTAL W1: Scripted Mutation Verification
    # Patch implementation -> run named @Test -> verify build succeeded & THAT named test failed -> restore & verify clean
    # ------------------------------------------------------------------
    echo ""
    echo "--- Supplemental W1: Scripted Mutation Verification (6 Named Test Guards) ---"
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
mutated = content.replace(old_s, new_s, 1)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(mutated)
PYEOF

        set +e
        local mut_out
        mut_out="$(swift test --no-parallel --filter "${test_filter}" 2>&1)"
        local mut_code=$?
        set -e

        # Restore immediately before checking assertions
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
        "M1_C1_NegativeCache" \
        "Sources/CiteStudioCore/CitationFirewall/ScholarTriangulator.swift" \
        "FirewallTests/c1OfflineLookupDoesNotPoisonCache" \
        "C1: Offline lookup failure returns Unverified (never GhostPaper) and writes 0 cache entries" \
        "        case .lookupFailed:
            // CRITICAL (C1): Never cache transient network/HTTP/parse failures!
            break" \
        "        case .lookupFailed:
            writeCache(for: key, found: false, record: nil, ttlSeconds: notFoundTTLSeconds)
            return .confirmedNotFound"

    run_single_mutation \
        "M2_C16_Crossref404Only" \
        "Sources/CiteStudioCore/CitationFirewall/ScholarTriangulator.swift" \
        "FirewallTests/c16Crossref404ConsultsOpenAlexBeforeGhostPaper" \
        "C16: Crossref 404 on DataCite DOI consults OpenAlex (200 -> Verified/Mismatch; 503/429 -> Unverified uncached; both 404 -> GhostPaper)" \
        "                switch await queryOpenAlexByDOI(doi) {" \
        "                if !doi.isEmpty { return .confirmedNotFound }; switch await queryOpenAlexByDOI(doi) {"

    run_single_mutation \
        "M3_C2_DisableTitleSimilarity" \
        "Sources/CiteStudioCore/CitationFirewall/CitationDiagnostics.swift" \
        "FirewallTests/c2RealDOIWithWrongTitleIsMetadataMismatch" \
        "C2: Real DOI paired with mismatched title is flagged as MetadataMismatch, never Verified" \
        "            let titleMismatch = trimmedBibTitle.isEmpty || titleSimilarity < minimumDOITitleSimilarity" \
        "            let titleMismatch = false && (trimmedBibTitle.isEmpty || titleSimilarity < minimumDOITitleSimilarity)"

    run_single_mutation \
        "M4_C3_DisableRetractionGate" \
        "Sources/CiteStudioCore/CitationFirewall/CitationDiagnostics.swift" \
        "FirewallTests/c3RetractionDetectionAcrossAllChannels" \
        "C3: Retraction detection catches Crossref update-to, Crossref updated-by, RETRACTED title prefix, and OpenAlex is_retracted" \
        "            if record.isRetracted {" \
        "            if false && record.isRetracted {"

    run_single_mutation \
        "M5_C4_WriteRawCallerBibTeX" \
        "Sources/CiteStudioCore/MCP/CiteStudioMCPServer.swift" \
        "MCPTests/c4AddVerifiedBibTeXWritesCanonicalUpstreamRecordAndSkipsDuplicateKey" \
        "C4 (Row 5): add_verified_bibtex writes canonical upstream title/authors/venue and deduplicates existing cite keys" \
        "            let canonicalStanza = diag.upgradedBibTeX
                ?? BibTeXParser.formatCanonicalBibTeX(
                    entry: entry,
                    record: authoritativeRecord,
                    preferUpgrade: diag.kind == .preprintUpgrade
                )" \
        "            let canonicalStanza = entry.rawBibTeX"

    run_single_mutation \
        "M6_C8_NonEmptyDefaultWorkspace" \
        "Sources/CiteStudioCore/ViewModels/CiteStudioWorkspaceSession.swift" \
        "WorkspaceTests/c8DefaultSessionIsEmptyAndLoadDemoMarksDemoMode" \
        "C8 (Row 7): Default CiteStudioWorkspaceSession() starts completely empty (0 manuscript, 0 bibliography, 0 diagnostics, 0 lints), and Load Demo sets isDemoMode = true" \
        "        self.projectTitle = projectTitle" \
        "        self.projectTitle = projectTitle.isEmpty ? \"Preloaded Demo\" : projectTitle"

    # Rebuild unmutated binary & verify working tree matches pre-mutation state
    swift build -q
    GIT_STATUS_AFTER="$(git -C "${ROOT_DIR}" status --porcelain)"
    if [[ "${GIT_STATUS_AFTER}" != "${GIT_STATUS_BEFORE}" ]]; then
        echo "FAIL W1: Working tree dirty/changed after mutations!" >&2
        echo "${GIT_STATUS_AFTER}" >&2
        exit 1
    fi
    echo "[PASS] Supplemental W1: All 6 scripted mutations failed their exact named @Test after clean build, and working tree was restored cleanly."
    ACC_PASSED=$((ACC_PASSED + 1))

    ACC_TOTAL=$((ACC_PASSED + ACC_SKIPPED))
    echo ""
    echo "=================================================================="
    echo "M0_ACCEPTANCE_SUMMARY: total=${ACC_TOTAL} passed=${ACC_PASSED} skipped=${ACC_SKIPPED} (skipped items NOT counted as passed)"
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
