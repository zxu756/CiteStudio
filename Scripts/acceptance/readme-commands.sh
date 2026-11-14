#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_DIR="${ROOT_DIR}/reports"
mkdir -p "${REPORT_DIR}"
REPORT_FILE="${REPORT_DIR}/readme-commands.txt"

REAL_HOME="${HOME}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/citestudio-readme.XXXXXX")"
SERVER_PID=""

cleanup() {
    if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

run_replay() {
    echo "=================================================================="
    echo "CiteStudio README Command Replay (readme-commands.sh)"
    echo "Timestamp (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "=================================================================="

    cd "${ROOT_DIR}"
    swift build -q
    BIN="${ROOT_DIR}/.build/debug/CiteStudio"

    export HOME="${TMP_ROOT}/fake_home"
    export CITESTUDIO_CACHE_DIR="${TMP_ROOT}/cache"
    export CITESTUDIO_EPHEMERAL_DEFAULTS=1
    mkdir -p "${HOME}/Library/Caches" "${CITESTUDIO_CACHE_DIR}" "${TMP_ROOT}/path/to"
    if [[ -d "${REAL_HOME}/Library/Caches/TectonicProject.Tectonic" ]]; then
        ln -s "${REAL_HOME}/Library/Caches/TectonicProject.Tectonic" "${HOME}/Library/Caches/TectonicProject.Tectonic"
    fi

    # Minimal loopback Crossref/OpenAlex server for README verify commands
    PORT_FILE="${TMP_ROOT}/port.txt"
    cat > "${TMP_ROOT}/server.py" <<'PYEOF'
import http.server, json, sys

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return
    def do_GET(self):
        if self.path.startswith("/crossref/works/10.1038/nature14539"):
            body = json.dumps({
                "status": "ok",
                "message": {
                    "DOI": "10.1038/nature14539",
                    "title": ["Deep learning"],
                    "author": [{"given": "Yann", "family": "LeCun"}],
                    "published-print": {"date-parts": [[2015, 5, 28]]},
                    "container-title": ["Nature"],
                },
            }).encode("utf-8")
            self.send_response(200)
        elif self.path.startswith("/openalex/works/"):
            body = json.dumps({"id": "https://openalex.org/W2163605009", "is_retracted": False}).encode("utf-8")
            self.send_response(200)
        else:
            body = json.dumps({"status": "not-found"}).encode("utf-8")
            self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF

    python3 "${TMP_ROOT}/server.py" "${PORT_FILE}" &
    SERVER_PID=$!
    for _ in $(seq 1 50); do
        [[ -s "${PORT_FILE}" ]] && break
        sleep 0.1
    done
    PORT="$(cat "${PORT_FILE}")"
    export CITESTUDIO_CROSSREF_BASE_URL="http://127.0.0.1:${PORT}/crossref"
    export CITESTUDIO_OPENALEX_BASE_URL="http://127.0.0.1:${PORT}/openalex"

    cat > "${TMP_ROOT}/path/to/references.bib" <<'EOF'
@article{lecun2015deep,
  title = {Deep learning},
  author = {LeCun, Yann and Bengio, Yoshua and Hinton, Geoffrey},
  journal = {Nature},
  year = {2015},
  doi = {10.1038/nature14539}
}
EOF

    cat > "${TMP_ROOT}/path/to/main.tex" <<'EOF'
\documentclass{article}
\begin{document}
Representation learning scales across layers.
\end{document}
EOF

    echo ""
    echo "$ .build/debug/CiteStudio --cli status"
    "${BIN}" --cli status

    echo ""
    echo "$ .build/debug/CiteStudio --cli verify path/to/references.bib"
    "${BIN}" --cli verify "${TMP_ROOT}/path/to/references.bib"

    echo ""
    echo "$ .build/debug/CiteStudio --cli verify path/to/references.bib --json"
    "${BIN}" --cli verify "${TMP_ROOT}/path/to/references.bib" --json

    echo ""
    echo "$ .build/debug/CiteStudio --cli verify path/to/references.bib --lang zh"
    "${BIN}" --cli verify "${TMP_ROOT}/path/to/references.bib" --lang zh

    echo ""
    echo "$ .build/debug/CiteStudio --cli clear-cache"
    "${BIN}" --cli clear-cache

    echo ""
    echo "$ .build/debug/CiteStudio --cli clear-cache --lang zh"
    "${BIN}" --cli clear-cache --lang zh

    echo ""
    echo "$ .build/debug/CiteStudio --cli lint path/to/main.tex"
    "${BIN}" --cli lint "${TMP_ROOT}/path/to/main.tex"

    echo ""
    echo "$ .build/debug/CiteStudio --cli lint path/to/main.tex --lang zh"
    "${BIN}" --cli lint "${TMP_ROOT}/path/to/main.tex" --lang zh

    if command -v tectonic >/dev/null 2>&1 || [[ -x /opt/homebrew/bin/tectonic ]]; then
        echo ""
        echo "$ .build/debug/CiteStudio --cli compile path/to/main.tex"
        "${BIN}" --cli compile "${TMP_ROOT}/path/to/main.tex"
    else
        echo ""
        echo "[SKIPPED] tectonic not installed for optional --cli compile smoke check"
    fi

    echo ""
    echo "$ printf '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\\n' | .build/debug/CiteStudio --mcp"
    printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | "${BIN}" --mcp

    echo ""
    echo "[PASS] Every documented README / README.zh-CN command executed cleanly."
}

if [[ "${1:-}" == "--run-inner" ]]; then
    run_replay
else
    "${BASH_SOURCE[0]}" --run-inner 2>&1 | tee "${REPORT_FILE}"
fi
