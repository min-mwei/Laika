#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_all_safari_ui_tests.sh

Options:
  --output-dir <path>  Directory for JSON outputs (default /tmp/laika-automation)
  --timeout <sec>      UI test timeout in seconds (default 240)
  --retries <n>        Retry UI test on flaky failures (default 2)
  --retry-delay <s>    Delay between retries in seconds (default 3)
  --quit-safari        Quit Safari before and after each UI test
  --no-build           Skip building/installing the app
  --install-dir <p>    Install directory for Laika.app (default ~/Applications)
  --no-open-app        Do not open the app after install
  --help               Show this help
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="${SCRIPT_DIR}/run_safari_ui_test.sh"
OUTPUT_DIR="/tmp/laika-automation"
TIMEOUT_SECONDS="240"
XCODE_RETRIES="2"
XCODE_RETRY_DELAY="3"
BUILD_APP="1"
INSTALL_DIR="${HOME}/Applications"
OPEN_APP="1"
QUIT_SAFARI="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --retries)
      XCODE_RETRIES="$2"
      shift 2
      ;;
    --retry-delay)
      XCODE_RETRY_DELAY="$2"
      shift 2
      ;;
    --quit-safari)
      QUIT_SAFARI="1"
      shift 1
      ;;
    --no-build)
      BUILD_APP="0"
      shift 1
      ;;
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --no-open-app)
      OPEN_APP="0"
      shift 1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

mkdir -p "${OUTPUT_DIR}"

scenarios=(
  "scripts/scenarios/hn.json"
  "scripts/scenarios/bbc.json"
  "scripts/scenarios/wsj.json"
)

first_run=1
for scenario in "${scenarios[@]}"; do
  base_name="$(basename "${scenario}" .json)"
  output_path="${OUTPUT_DIR}/laika-${base_name}.json"
  args=("--scenario" "${scenario}" "--output" "${output_path}" "--timeout" "${TIMEOUT_SECONDS}" "--retries" "${XCODE_RETRIES}" "--retry-delay" "${XCODE_RETRY_DELAY}")

  if [[ "${BUILD_APP}" != "1" || "${first_run}" != "1" ]]; then
    args+=("--no-build")
  else
    args+=("--install-dir" "${INSTALL_DIR}")
    if [[ "${OPEN_APP}" != "1" ]]; then
      args+=("--no-open-app")
    fi
  fi
  if [[ "${QUIT_SAFARI}" == "1" ]]; then
    args+=("--quit-safari")
  fi

  "${RUN_SCRIPT}" "${args[@]}"
  first_run=0
  BUILD_APP=0
  OPEN_APP=0
  echo "Completed ${scenario} -> ${output_path}"
  sleep 1
done
