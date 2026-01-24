#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_safari_ui_test.sh --scenario <path>

Options:
  --scenario <path>  Scenario JSON file (required)
  --port <n>         Port for harness server (default 8766)
  --output <path>    Output JSON path (default /tmp/laika-automation-output.json)
  --timeout <sec>    UI test timeout in seconds (default 240)
  --quit-safari      Quit Safari before running the UI test
  --no-build         Skip building/installing the app
  --install-dir <p>  Install directory for Laika.app (default ~/Applications)
  --no-open-app      Do not open the app after install
  --help             Show this help
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAIKA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LAIKA_BUILD_SCRIPT="${LAIKA_ROOT}/../laika_build.sh"
XCODEPROJ="${LAIKA_ROOT}/LaikaApp/Laika/Laika.xcodeproj"
HARNESS_SCRIPT="${SCRIPT_DIR}/laika_bridge_harness.js"

SCENARIO_PATH=""
PORT="8766"
OUTPUT_PATH="/tmp/laika-automation-output.json"
TIMEOUT_SECONDS="240"
CONFIG_PATH="/tmp/laika-automation-config.json"
BUILD_APP="1"
INSTALL_DIR="${HOME}/Applications"
OPEN_APP="1"
QUIT_SAFARI="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)
      SCENARIO_PATH="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="$2"
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

if [[ -z "${SCENARIO_PATH}" ]]; then
  usage
  exit 1
fi

if [[ "${BUILD_APP}" == "1" ]]; then
  if [[ ! -x "${LAIKA_BUILD_SCRIPT}" ]]; then
    echo "Build script not found at ${LAIKA_BUILD_SCRIPT}" >&2
    exit 1
  fi
  OPEN_APP="${OPEN_APP}" INSTALL_DIR="${INSTALL_DIR}" "${LAIKA_BUILD_SCRIPT}"
fi

if [[ ! -f "${SCENARIO_PATH}" ]]; then
  if [[ -f "${LAIKA_ROOT}/automation_harness/${SCENARIO_PATH}" ]]; then
    SCENARIO_PATH="${LAIKA_ROOT}/automation_harness/${SCENARIO_PATH}"
  elif [[ -f "${SCRIPT_DIR}/${SCENARIO_PATH}" ]]; then
    SCENARIO_PATH="${SCRIPT_DIR}/${SCENARIO_PATH}"
  else
    echo "Scenario not found: ${SCENARIO_PATH}"
    exit 1
  fi
fi

mkdir -p "$(dirname "${OUTPUT_PATH}")"
rm -f "${OUTPUT_PATH}"
QUIT_SAFARI_JSON="false"
if [[ "${QUIT_SAFARI}" == "1" ]]; then
  QUIT_SAFARI_JSON="true"
fi
cat <<EOF > "${CONFIG_PATH}"
{"harnessURL":"http://127.0.0.1:${PORT}/harness.html","outputPath":"${OUTPUT_PATH}","timeoutSeconds":${TIMEOUT_SECONDS},"quitSafari":${QUIT_SAFARI_JSON}}
EOF

node "${HARNESS_SCRIPT}" --scenario "${SCENARIO_PATH}" --port "${PORT}" --output "${OUTPUT_PATH}" --timeout "${TIMEOUT_SECONDS}" &
HARNESS_PID=$!

cleanup() {
  if kill -0 "${HARNESS_PID}" >/dev/null 2>&1; then
    kill "${HARNESS_PID}" >/dev/null 2>&1 || true
  fi
  rm -f "${CONFIG_PATH}"
}
trap cleanup EXIT

ready=0
for _ in {1..40}; do
  if curl -sf "http://127.0.0.1:${PORT}/api/config" >/dev/null; then
    ready=1
    break
  fi
  sleep 0.25
done

if [[ "${ready}" -ne 1 ]]; then
  echo "Harness server failed to start on port ${PORT}"
  exit 1
fi

if [[ "${QUIT_SAFARI}" == "1" ]]; then
  osascript -e 'tell application "Safari" to quit' >/dev/null 2>&1 || true
  sleep 1
fi

set +e
LAIKA_AUTOMATION_URL="http://127.0.0.1:${PORT}/harness.html" \
LAIKA_AUTOMATION_OUTPUT="${OUTPUT_PATH}" \
LAIKA_AUTOMATION_TIMEOUT="${TIMEOUT_SECONDS}" \
LAIKA_AUTOMATION_QUIT_SAFARI="${QUIT_SAFARI}" \
xcodebuild test -project "${XCODEPROJ}" -scheme LaikaUITests -destination "platform=macOS"
XCODE_STATUS=$?
set -e

wait "${HARNESS_PID}" || true
exit "${XCODE_STATUS}"
