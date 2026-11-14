#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_DIR="${ROOT_DIR}/reports"
REPORT_FILE="${REPORT_DIR}/readme-commands.txt"

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
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/citestudio-readme.XXXXXX")"

cleanup() {
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

run_replay() {
    echo "=================================================================="
    echo "CiteStudio README Command Replay (readme-commands.sh)"
    echo "Timestamp (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "=================================================================="

    python3 - "${ROOT_DIR}" "${TMP_ROOT}" <<'PYEOF'
import glob
import http.server
import json
import os
import re
import socketserver
import subprocess
import sys
import threading
import urllib.parse

root_dir, tmp_root = sys.argv[1], sys.argv[2]


def extract_bash_commands(md_path: str):
    content = open(md_path, encoding="utf-8").read()
    blocks = re.findall(r"```(?:bash|sh)\n(.*?)```", content, flags=re.DOTALL)
    cmds = []
    for block in blocks:
        for raw_line in block.splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            cmds.append(line)
    return cmds


en_path = os.path.join(root_dir, "README.md")
zh_path = os.path.join(root_dir, "README.zh-CN.md")
en_cmds = extract_bash_commands(en_path)
zh_cmds = extract_bash_commands(zh_path)

assert len(en_cmds) > 0, "No bash commands found in README.md"
if en_cmds != zh_cmds:
    print("FAIL: Command list mismatch between README.md and README.zh-CN.md!", file=sys.stderr)
    print(f"README.md ({len(en_cmds)}): {en_cmds}", file=sys.stderr)
    print(f"README.zh-CN.md ({len(zh_cmds)}): {zh_cmds}", file=sys.stderr)
    sys.exit(1)

print(f"[PASS] Extracted {len(en_cmds)} commands from README.md and README.zh-CN.md (100% parity).")

ws_dir = os.path.join(tmp_root, "ws")
fake_home = os.path.join(tmp_root, "fake_home")
cache_dir = os.path.join(tmp_root, "cache")
os.makedirs(os.path.join(ws_dir, "path", "to"), exist_ok=True)
os.makedirs(fake_home, exist_ok=True)
os.makedirs(cache_dir, exist_ok=True)

with open(os.path.join(root_dir, "Tests", "Fixtures", "test.bib"), encoding="utf-8") as bf:
    first_bib_line = bf.readline().strip()
with open(os.path.join(ws_dir, "path", "to", "references.bib"), "w", encoding="utf-8") as rf:
    rf.write(first_bib_line + "\n")

with open(os.path.join(ws_dir, "path", "to", "main.tex"), "w", encoding="utf-8") as tf:
    tf.write("\\documentclass{article}\n\\begin{document}\nClean deterministic manuscript paragraph.\n\\end{document}\n")

recorded_dir = os.path.join(root_dir, "Tests", "Fixtures", "recorded")
has_recorded = (
    os.path.isfile(os.path.join(recorded_dir, "manifest.json"))
    and len(glob.glob(os.path.join(recorded_dir, "*.meta.json"))) > 0
)

replay_index = {}
replay_server = None
replay_base = None

if has_recorded:
    def canonical_key(service: str, raw_url_or_path: str):
        u = urllib.parse.urlsplit(raw_url_or_path)
        norm_path = urllib.parse.unquote(u.path).rstrip("/") or "/"
        norm_query = tuple(sorted(urllib.parse.parse_qsl(u.query, keep_blank_values=True)))
        return (service, norm_path.lower(), norm_query)

    for meta_path in sorted(glob.glob(os.path.join(recorded_dir, "*.meta.json"))):
        meta = json.load(open(meta_path, encoding="utf-8"))
        raw_path = os.path.join(recorded_dir, meta["raw_file"])
        if os.path.isfile(raw_path):
            replay_index[canonical_key(meta["service"], meta["url"])] = (
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
            hit = replay_index.get(key)
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

    replay_server = ThreadingHTTPServer(("127.0.0.1", 0), ReplayHandler)
    t = threading.Thread(target=replay_server.serve_forever, daemon=True)
    t.start()
    replay_base = f"http://127.0.0.1:{replay_server.server_address[1]}"

base_env = dict(os.environ)
base_env["HOME"] = fake_home
base_env["CITESTUDIO_CACHE_DIR"] = cache_dir
base_env["CITESTUDIO_EPHEMERAL_DEFAULTS"] = "1"
if replay_base:
    base_env["CITESTUDIO_CROSSREF_BASE_URL"] = f"{replay_base}/crossref"
    base_env["CITESTUDIO_OPENALEX_BASE_URL"] = f"{replay_base}/openalex"

executed_count = 0
skipped_count = 0

try:
    for idx, cmd in enumerate(en_cmds, start=1):
        print(f"\n[{idx}/{len(en_cmds)}] $ {cmd}")

        if cmd.startswith("git clone "):
            skipped_count += 1
            print("  [SKIPPED] External network git clone; running against current checked-out repository.")
            continue

        if cmd == "cd CiteStudio":
            skipped_count += 1
            print("  [SKIPPED] Directory navigation step; commands execute inside isolated replay workspace.")
            continue

        if cmd == "./Scripts/test.sh milestone 0":
            skipped_count += 1
            print("  [SKIPPED] Parent M0 orchestrator command (already invoking readme-commands.sh; avoids recursion).")
            continue

        if cmd in (".build/debug/CiteStudio", ".build/debug/CiteStudio --demo --lang zh"):
            skipped_count += 1
            print("  [SKIPPED] Desktop GUI launch forbidden in automated acceptance/test scripts (C19 / W6).")
            continue

        if cmd == "swift build":
            res = subprocess.run(cmd, shell=True, cwd=root_dir, env=base_env, capture_output=True, text=True)
            assert res.returncode == 0, f"swift build failed ({res.returncode}):\n{res.stderr}"
            bin_path = os.path.join(root_dir, ".build", "debug", "CiteStudio")
            assert os.path.isfile(bin_path) and os.access(bin_path, os.X_OK), f"Missing binary {bin_path}"
            link_build = os.path.join(ws_dir, ".build")
            if not os.path.lexists(link_build):
                os.symlink(os.path.join(root_dir, ".build"), link_build)
            executed_count += 1
            print("  [PASS] exit=0, verified executable .build/debug/CiteStudio exists.")
            continue

        if "--cli verify " in cmd:
            if not has_recorded:
                skipped_count += 1
                print(
                    "  [SKIPPED (没跑)] Tests/Fixtures/recorded/ has no recorded fixtures yet; "
                    "run CITESTUDIO_RECORD=1 ./Scripts/acceptance/record-fixtures.sh after user approval (C15)."
                )
                continue
            res = subprocess.run(cmd, shell=True, cwd=ws_dir, env=base_env, capture_output=True, text=True)
            assert res.returncode == 0, f"verify failed ({res.returncode}):\n{res.stdout}\n{res.stderr}"
            if "--json" in cmd:
                payload = json.loads(res.stdout)
                assert payload["summary"]["verified"] == 1, payload
                print("  [PASS] exit=0, JSON summary.verified == 1.")
            elif "--lang zh" in cmd:
                assert "已验证(Verified)=1" in res.stdout, res.stdout
                print("  [PASS] exit=0, matched '已验证(Verified)=1'.")
            else:
                assert "Verified=1" in res.stdout, res.stdout
                print("  [PASS] exit=0, matched 'Verified=1'.")
            executed_count += 1
            continue

        if cmd == ".build/debug/CiteStudio --cli compile path/to/main.tex":
            if os.environ.get("CITESTUDIO_REAL_TECTONIC") != "1":
                skipped_count += 1
                print(
                    "  [SKIPPED] CITESTUDIO_REAL_TECTONIC!=1; real tectonic compilation requires external "
                    "TeX bundle cache / network (C18 / General Rule §4)."
                )
                continue
            res = subprocess.run(cmd, shell=True, cwd=ws_dir, env=base_env, capture_output=True, text=True)
            assert res.returncode == 0, f"compile failed ({res.returncode}):\n{res.stdout}\n{res.stderr}"
            assert "Succeeded: true" in res.stdout, res.stdout
            executed_count += 1
            print("  [PASS] exit=0, matched 'Succeeded: true'.")
            continue

        # Execute remaining deterministic CLI / MCP commands and assert both exit code & stdout
        res = subprocess.run(cmd, shell=True, cwd=ws_dir, env=base_env, capture_output=True, text=True)
        out = res.stdout.strip()
        if out:
            print(f"  stdout: {out}")

        if cmd == ".build/debug/CiteStudio --cli status":
            assert res.returncode == 0, f"status exited {res.returncode}: {res.stderr}"
            assert "CiteStudio 0.2.0 | Tectonic:" in res.stdout and "| Typst:" in res.stdout, res.stdout
            print("  [PASS] exit=0, matched 'CiteStudio 0.2.0 | Tectonic: ... | Typst: ...'.")
        elif cmd == ".build/debug/CiteStudio --cli clear-cache":
            assert res.returncode == 0, f"clear-cache exited {res.returncode}: {res.stderr}"
            assert "Cleared " in res.stdout and "cached citation verification entries" in res.stdout, res.stdout
            assert os.path.isfile(os.path.join(cache_dir, "scholar_cache.sqlite")), "Product cache DB not created"
            print("  [PASS] exit=0, matched 'Cleared ... cached citation verification entries' (product SQLite DB verified).")
        elif cmd == ".build/debug/CiteStudio --cli clear-cache --lang zh":
            assert res.returncode == 0, f"clear-cache zh exited {res.returncode}: {res.stderr}"
            assert "已清空 " in res.stdout and "条引文核查缓存记录" in res.stdout, res.stdout
            print("  [PASS] exit=0, matched '已清空 ... 条引文核查缓存记录'.")
        elif cmd == ".build/debug/CiteStudio --cli lint path/to/main.tex":
            assert res.returncode == 0, f"lint exited {res.returncode}: {res.stderr}"
            assert "Total deterministic findings: 0" in res.stdout, res.stdout
            print("  [PASS] exit=0, matched 'Total deterministic findings: 0'.")
        elif cmd == ".build/debug/CiteStudio --cli lint path/to/main.tex --lang zh":
            assert res.returncode == 0, f"lint zh exited {res.returncode}: {res.stderr}"
            assert "确定性行文与图表检查共发现问题：0 项" in res.stdout, res.stdout
            print("  [PASS] exit=0, matched '确定性行文与图表检查共发现问题：0 项'.")
        elif "--mcp" in cmd and "tools/list" in cmd:
            assert res.returncode == 0, f"mcp tools/list exited {res.returncode}: {res.stderr}"
            rpc = json.loads(res.stdout.strip().splitlines()[-1])
            names = {t["name"] for t in rpc["result"]["tools"]}
            expected_tools = {
                "verify_citation",
                "add_verified_bibtex",
                "search_local_pdfs",
                "get_claim_evidence",
                "audit_manuscript",
                "compile_pdf",
            }
            assert names == expected_tools, f"Unexpected MCP tools: {names}"
            print(f"  [PASS] exit=0, verified all 6 MCP tools: {sorted(names)}.")
        else:
            raise AssertionError(f"Unhandled README command lacks explicit output assertion: {cmd}")

        executed_count += 1

    # Also verify C15 recorder default gate (CITESTUDIO_RECORD unset -> exit 0 + SKIPPED message, zero network)
    rec_env = dict(base_env)
    rec_env.pop("CITESTUDIO_RECORD", None)
    rec_script = os.path.join(root_dir, "Scripts", "acceptance", "record-fixtures.sh")
    rec_res = subprocess.run([rec_script], cwd=root_dir, env=rec_env, capture_output=True, text=True)
    assert rec_res.returncode == 0, f"record-fixtures.sh default gate failed: {rec_res.returncode}"
    assert "SKIPPED: Set CITESTUDIO_RECORD=1" in rec_res.stdout, rec_res.stdout
    print("\n[Extra Check] $ ./Scripts/acceptance/record-fixtures.sh (with CITESTUDIO_RECORD unset)")
    print(f"  stdout: {rec_res.stdout.strip()}")
    print("  [PASS] exit=0, default non-network gate verified.")

    print("\n==================================================================")
    print(
        f"[PASS] README / README.zh-CN command replay complete: "
        f"total={len(en_cmds)}, executed_with_assertions={executed_count}, skipped_with_reasons={skipped_count}."
    )
    print("==================================================================")
finally:
    if replay_server is not None:
        replay_server.shutdown()
PYEOF
}

if [[ "${RUN_INNER}" -eq 1 ]]; then
    run_replay
elif [[ "${RECORD_MODE}" -eq 1 ]]; then
    mkdir -p "${REPORT_DIR}"
    "${BASH_SOURCE[0]}" --run-inner 2>&1 | scrub_paths | tee "${REPORT_FILE}"
else
    run_replay
fi
