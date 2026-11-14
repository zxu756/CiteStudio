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
  Scripts/test.sh scope <Module...>   Run scoped unit tests (e.g. Firewall, MCP, CLI, Workspace, CiteStudioCoreTests)
  Scripts/test.sh milestone <N>       Run milestone <N> scoped unit tests + acceptance script
  Scripts/test.sh release             Run full unit tests + acceptance scripts + online gate check
EOF
    exit 2
}

if [[ $# -lt 1 ]]; then
    usage
fi

MODE="$1"
shift

case "${MODE}" in
    scope)
        if [[ $# -lt 1 ]]; then
            usage
        fi
        FILTERS=()
        for mod in "$@"; do
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
        swift test --no-parallel --filter "${PATTERN}"
        ;;

    milestone)
        if [[ $# -lt 1 ]]; then
            usage
        fi
        M_NUM="$1"
        case "${M_NUM}" in
            0|m0|M0)
                echo "==> [M0] Running scoped unit tests (Firewall, MCP, CLI, Workspace, CiteStudioCoreTests)..."
                swift test --no-parallel --filter "FirewallTests|MCPTests|CLITests|WorkspaceTests|CiteStudioCoreTests"
                echo "==> [M0] Running Scripts/acceptance/m0-acceptance.sh..."
                "${ROOT_DIR}/Scripts/acceptance/m0-acceptance.sh"
                echo "==> [M0] Running Scripts/acceptance/readme-commands.sh..."
                "${ROOT_DIR}/Scripts/acceptance/readme-commands.sh"
                ;;
            *)
                echo "Error: Milestone ${M_NUM} acceptance script is not implemented yet." >&2
                exit 2
                ;;
        esac
        ;;

    release)
        echo "==> [release] Running all unit tests..."
        swift test --no-parallel
        echo "==> [release] Running M0 acceptance script..."
        "${ROOT_DIR}/Scripts/acceptance/m0-acceptance.sh"
        echo "==> [release] Running README command replay..."
        "${ROOT_DIR}/Scripts/acceptance/readme-commands.sh"
        if [[ "${SCHOLAR_ONLINE:-0}" == "1" ]]; then
            echo "==> [release] SCHOLAR_ONLINE=1: live benchmark evaluation scheduled for M1 (not yet implemented in M0)."
        else
            echo "SKIPPED: live online registry benchmark evaluation (SCHOLAR_ONLINE!=1;已跳过，不算通过)"
        fi
        ;;

    *)
        usage
        ;;
esac
