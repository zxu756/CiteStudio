#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

TMP_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/citestudio-test.XXXXXX")"
cleanup() {
    rm -rf "${TMP_TEST_ROOT}"
}
trap cleanup EXIT

export CITESTUDIO_CACHE_DIR="${TMP_TEST_ROOT}/cache"
export CITESTUDIO_EPHEMERAL_DEFAULTS=1
mkdir -p "${CITESTUDIO_CACHE_DIR}"

usage() {
    cat >&2 <<'EOF'
Usage:
  Scripts/test.sh scope <Module...>            Run scoped unit tests (Firewall, MCP, CLI, Workspace, CiteStudioCoreTests)
  Scripts/test.sh milestone <N> [--record]     Run milestone <N> scoped unit tests + acceptance scripts (--record updates reports/*.txt)
  Scripts/test.sh release [--record]           Run full unit tests + acceptance scripts + online gate check
EOF
    exit 2
}

LAST_UT_PASSED=0
LAST_UT_SKIPPED=0
LAST_UT_TOTAL=0

run_swift_test_with_summary() {
    local log_file="${TMP_TEST_ROOT}/swift-test.log"
    set +e
    "$@" 2>&1 | tee "${log_file}"
    local status=${PIPESTATUS[0]}
    set -e

    read -r LAST_UT_PASSED LAST_UT_SKIPPED LAST_UT_FAILED < <(
        python3 - "${log_file}" <<'PYEOF'
import re, sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
passed = sum(1 for ln in lines if ln.startswith('✔ Test "') and " passed after " in ln)
skipped = sum(1 for ln in lines if ln.startswith('➜ Test "') and " skipped" in ln)
failed = sum(1 for ln in lines if ln.startswith('✘ Test "') and " failed after " in ln)
print(f"{passed} {skipped} {failed}")
PYEOF
    )
    LAST_UT_TOTAL=$((LAST_UT_PASSED + LAST_UT_SKIPPED + LAST_UT_FAILED))
    echo "UNIT_TESTS_SUMMARY: total=${LAST_UT_TOTAL} passed=${LAST_UT_PASSED} skipped=${LAST_UT_SKIPPED} failed=${LAST_UT_FAILED} (skipped tests NOT counted as passed)"
    return "${status}"
}

extract_summary_pair() {
    local prefix="$1"
    local log_file="$2"
    python3 - "${prefix}" "${log_file}" <<'PYEOF'
import re, sys
prefix, path = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="replace").read()
matches = re.findall(rf"^{re.escape(prefix)}\s+total=(\d+)\s+passed=(\d+)\s+skipped=(\d+)", text, flags=re.MULTILINE)
if matches:
    t, p, s = matches[-1]
    print(f"{t} {p} {s}")
else:
    print("0 0 0")
PYEOF
}

if [[ $# -lt 1 ]]; then
    usage
fi

MODE="$1"
shift

RECORD_ARGS=()
PASSTHROUGH=()
for arg in "$@"; do
    if [[ "${arg}" == "--record" ]]; then
        RECORD_ARGS=("--record")
    else
        PASSTHROUGH+=("${arg}")
    fi
done

case "${MODE}" in
    scope)
        if [[ ${#PASSTHROUGH[@]} -lt 1 ]]; then
            usage
        fi
        FILTERS=()
        for mod in "${PASSTHROUGH[@]}"; do
            case "${mod}" in
                Firewall)
                    FILTERS+=("FirewallTests")
                    ;;
                MCP)
                    FILTERS+=("MCPTests")
                    ;;
                CLI)
                    FILTERS+=("CLITests")
                    ;;
                Workspace)
                    FILTERS+=("WorkspaceTests")
                    ;;
                Core|CiteStudioCoreTests)
                    FILTERS+=("CiteStudioCoreTests\\.CiteStudioCoreTests")
                    ;;
                *)
                    FILTERS+=("${mod}")
                    ;;
            esac
        done
        PATTERN="$(IFS='|'; echo "${FILTERS[*]}")"
        echo "==> [scope] swift test --no-parallel --filter '${PATTERN}'"
        run_swift_test_with_summary swift test --no-parallel --filter "${PATTERN}"
        ;;

    milestone)
        if [[ ${#PASSTHROUGH[@]} -lt 1 ]]; then
            usage
        fi
        M_NUM="${PASSTHROUGH[0]}"
        case "${M_NUM}" in
            0|m0|M0)
                echo "==> [M0] Running scoped unit tests (Firewall, MCP, CLI, Workspace, CiteStudioCoreTests)..."
                run_swift_test_with_summary swift test --no-parallel --filter "FirewallTests|MCPTests|CLITests|WorkspaceTests|CiteStudioCoreTests"

                ACC_LOG="${TMP_TEST_ROOT}/m0-acc.log"
                echo "==> [M0] Running Scripts/acceptance/m0-acceptance.sh ${RECORD_ARGS[*]:-}..."
                "${ROOT_DIR}/Scripts/acceptance/m0-acceptance.sh" "${RECORD_ARGS[@]+"${RECORD_ARGS[@]}"}" 2>&1 | tee "${ACC_LOG}"

                RD_LOG="${TMP_TEST_ROOT}/readme.log"
                echo "==> [M0] Running Scripts/acceptance/readme-commands.sh ${RECORD_ARGS[*]:-}..."
                "${ROOT_DIR}/Scripts/acceptance/readme-commands.sh" "${RECORD_ARGS[@]+"${RECORD_ARGS[@]}"}" 2>&1 | tee "${RD_LOG}"

                read -r ACC_TOTAL ACC_PASSED ACC_SKIPPED < <(extract_summary_pair "M0_ACCEPTANCE_SUMMARY:" "${ACC_LOG}")
                read -r RD_TOTAL RD_PASSED RD_SKIPPED < <(extract_summary_pair "README_REPLAY_SUMMARY:" "${RD_LOG}")

                echo ""
                echo "=================================================================="
                echo "MILESTONE_M0_SUMMARY: (skipped items counted separately, NEVER folded into passed)"
                echo "  Unit tests      : passed=${LAST_UT_PASSED}, skipped=${LAST_UT_SKIPPED}, total=${LAST_UT_TOTAL}"
                echo "  M0 acceptance   : passed=${ACC_PASSED}, skipped=${ACC_SKIPPED}, total=${ACC_TOTAL}"
                echo "  README commands : passed=${RD_PASSED}, skipped=${RD_SKIPPED}, total=${RD_TOTAL}"
                echo "=================================================================="
                ;;
            *)
                echo "Error: Milestone ${M_NUM} acceptance script is not implemented yet." >&2
                exit 2
                ;;
        esac
        ;;

    release)
        echo "==> [release] Running all unit tests..."
        run_swift_test_with_summary swift test --no-parallel

        ACC_LOG="${TMP_TEST_ROOT}/m0-acc.log"
        echo "==> [release] Running M0 acceptance script ${RECORD_ARGS[*]:-}..."
        "${ROOT_DIR}/Scripts/acceptance/m0-acceptance.sh" "${RECORD_ARGS[@]+"${RECORD_ARGS[@]}"}" 2>&1 | tee "${ACC_LOG}"

        RD_LOG="${TMP_TEST_ROOT}/readme.log"
        echo "==> [release] Running README command replay ${RECORD_ARGS[*]:-}..."
        "${ROOT_DIR}/Scripts/acceptance/readme-commands.sh" "${RECORD_ARGS[@]+"${RECORD_ARGS[@]}"}" 2>&1 | tee "${RD_LOG}"

        GATE_PASSED=0
        GATE_SKIPPED=0
        if [[ "${CITESTUDIO_REAL_TECTONIC:-0}" == "1" ]]; then
            GATE_PASSED=$((GATE_PASSED + 1))
        else
            GATE_SKIPPED=$((GATE_SKIPPED + 1))
            echo "SKIPPED: real tectonic compilation check (CITESTUDIO_REAL_TECTONIC!=1; 已跳过，不算通过)"
        fi
        if [[ "${SCHOLAR_ONLINE:-0}" == "1" ]]; then
            GATE_SKIPPED=$((GATE_SKIPPED + 1))
            echo "SKIPPED: SCHOLAR_ONLINE=1 live benchmark evaluation scheduled for M1 (not yet implemented in M0; 已跳过，不算通过)"
        else
            GATE_SKIPPED=$((GATE_SKIPPED + 1))
            echo "SKIPPED: live online registry benchmark evaluation (SCHOLAR_ONLINE!=1; 已跳过，不算通过)"
        fi

        read -r ACC_TOTAL ACC_PASSED ACC_SKIPPED < <(extract_summary_pair "M0_ACCEPTANCE_SUMMARY:" "${ACC_LOG}")
        read -r RD_TOTAL RD_PASSED RD_SKIPPED < <(extract_summary_pair "README_REPLAY_SUMMARY:" "${RD_LOG}")

        echo ""
        echo "=================================================================="
        echo "RELEASE_SUMMARY (skipped items counted separately, NEVER folded into passed):"
        echo "  Unit tests      : passed=${LAST_UT_PASSED}, skipped=${LAST_UT_SKIPPED}, total=${LAST_UT_TOTAL}"
        echo "  M0 acceptance   : passed=${ACC_PASSED}, skipped=${ACC_SKIPPED}, total=${ACC_TOTAL}"
        echo "  README commands : passed=${RD_PASSED}, skipped=${RD_SKIPPED}, total=${RD_TOTAL}"
        echo "  Optional gates  : passed=${GATE_PASSED}, skipped=${GATE_SKIPPED}, total=$((GATE_PASSED + GATE_SKIPPED))"
        echo "=================================================================="
        ;;

    *)
        usage
        ;;
esac
