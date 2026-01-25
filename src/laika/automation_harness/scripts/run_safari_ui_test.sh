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
  --retries <n>      Retry UI test on flaky failures (default 2)
  --retry-delay <s>  Delay between retries in seconds (default 3)
  --quit-safari      Quit Safari before and after running the UI test
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
XCODE_RETRIES="2"
XCODE_RETRY_DELAY="3"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-4Z82EAJL2W}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-}"
HARNESS_TIMEOUT_BUFFER="${HARNESS_TIMEOUT_BUFFER:--5}"
HARNESS_TIMEOUT_SECONDS="${HARNESS_TIMEOUT_SECONDS:-}"
TELEMETRY_PATH="${TELEMETRY_PATH:-}"
BUILD_APP="1"
INSTALL_DIR="${HOME}/Applications"
OPEN_APP="1"
QUIT_SAFARI="0"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.laika.Laika}"
EXT_BUNDLE_ID="${EXT_BUNDLE_ID:-com.laika.Laika.Extension}"

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

HARNESS_PID=""

if [[ -z "${HARNESS_TIMEOUT_SECONDS}" ]]; then
  HARNESS_TIMEOUT_SECONDS=$((TIMEOUT_SECONDS + HARNESS_TIMEOUT_BUFFER))
  if [[ "${HARNESS_TIMEOUT_SECONDS}" -le 0 ]]; then
    HARNESS_TIMEOUT_SECONDS="${TIMEOUT_SECONDS}"
  fi
fi

stop_harness() {
  if [[ -n "${HARNESS_PID}" ]] && kill -0 "${HARNESS_PID}" >/dev/null 2>&1; then
    kill "${HARNESS_PID}" >/dev/null 2>&1 || true
    wait "${HARNESS_PID}" >/dev/null 2>&1 || true
  fi
  HARNESS_PID=""
}

start_harness() {
  stop_harness
  pkill -f "laika_bridge_harness.js" >/dev/null 2>&1 || true
  sleep 0.2
  node "${HARNESS_SCRIPT}" --scenario "${SCENARIO_PATH}" --port "${PORT}" --output "${OUTPUT_PATH}" --timeout "${HARNESS_TIMEOUT_SECONDS}" &
  HARNESS_PID=$!
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
    stop_harness
    return 1
  fi
  return 0
}

cleanup() {
  stop_harness
  rm -f "${CONFIG_PATH}"
}
trap cleanup EXIT

ensure_harness() {
  if [[ -z "${HARNESS_PID}" ]] || ! kill -0 "${HARNESS_PID}" >/dev/null 2>&1; then
    start_harness
    return $?
  fi
  if ! curl -sf "http://127.0.0.1:${PORT}/api/config" >/dev/null; then
    start_harness
    return $?
  fi
  return 0
}

if [[ -z "${DERIVED_DATA_PATH}" ]]; then
  derived_base="${OUTPUT_PATH}"
  if [[ "${derived_base}" == *.json ]]; then
    derived_base="${derived_base%.json}"
  fi
  DERIVED_DATA_PATH="${derived_base}-derived-data"
fi
mkdir -p "$(dirname "${DERIVED_DATA_PATH}")"

if [[ -z "${TELEMETRY_PATH}" ]]; then
  telemetry_base="${OUTPUT_PATH}"
  if [[ "${telemetry_base}" == *.json ]]; then
    telemetry_base="${telemetry_base%.json}"
  fi
  TELEMETRY_PATH="${telemetry_base}.telemetry.json"
fi

if [[ "${QUIT_SAFARI}" == "1" ]]; then
  osascript -e 'tell application "Safari" to quit' >/dev/null 2>&1 || true
  sleep 1
fi

should_retry_ui() {
  local log_path="$1"
  if grep -q "System authentication is running" "${log_path}"; then
    return 0
  fi
  if grep -q "Failed to launch Safari in foreground" "${log_path}"; then
    return 0
  fi
  if grep -q "Failed to activate Safari in foreground" "${log_path}"; then
    return 0
  fi
  if grep -q "Failed to activate application 'com.apple.Safari" "${log_path}"; then
    return 0
  fi
  if grep -q "Failed to initialize for UI testing" "${log_path}"; then
    CLEAN_DERIVED_DATA="1"
    return 0
  fi
  if grep -q "Authentication canceled" "${log_path}"; then
    return 0
  fi
  if grep -q "test runner hung before establishing connection" "${log_path}"; then
    CLEAN_DERIVED_DATA="1"
    return 0
  fi
  if grep -q "Automation error: timeout" "${log_path}"; then
    return 0
  fi
  if grep -q "Timed out waiting for automation output" "${log_path}"; then
    return 0
  fi
  return 1
}

cleanup_test_runner() {
  pkill -f "LaikaUITests-Runner" >/dev/null 2>&1 || true
  pkill -f "xctest.*LaikaUITests" >/dev/null 2>&1 || true
  pkill -f "xcodebuild .*LaikaUITests" >/dev/null 2>&1 || true
}

clean_extension_registration() {
  if command -v pluginkit >/dev/null 2>&1; then
    pluginkit -r "${EXT_BUNDLE_ID}" >/dev/null 2>&1 || true
  fi
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "${LSREGISTER}" ]] && command -v mdfind >/dev/null 2>&1; then
    mdfind "kMDItemCFBundleIdentifier == '${APP_BUNDLE_ID}'" | while IFS= read -r app_path; do
      if [[ -n "${app_path}" ]]; then
        "${LSREGISTER}" -u "${app_path}" >/dev/null 2>&1 || true
      fi
    done
  fi
}

set +e
attempt=0
max_attempts=$((XCODE_RETRIES + 1))
XCODE_STATUS=1
CLEAN_DERIVED_DATA="0"
while [[ "${attempt}" -lt "${max_attempts}" ]]; do
  attempt=$((attempt + 1))
  if [[ "${attempt}" -gt 1 && "${CLEAN_DERIVED_DATA}" == "1" ]]; then
    rm -rf "${DERIVED_DATA_PATH}"
    CLEAN_DERIVED_DATA="0"
  fi
  cleanup_test_runner
  sleep 0.5
  rm -f "${OUTPUT_PATH}"
  rm -f "${TELEMETRY_PATH}"
  if ! ensure_harness; then
    XCODE_STATUS=1
    break
  fi
  clean_extension_registration
  result_base="${OUTPUT_PATH%.json}"
  if [[ "${result_base}" == "${OUTPUT_PATH}" ]]; then
    result_base="${OUTPUT_PATH}"
  fi
  result_bundle="${result_base}-attempt${attempt}.xcresult"
  log_path="${result_base}-attempt${attempt}.log"
  if [[ -e "${result_bundle}" ]]; then
    rm -rf "${result_bundle}"
  fi
  if [[ -e "${log_path}" ]]; then
    rm -f "${log_path}"
  fi
  LAIKA_AUTOMATION_URL="http://127.0.0.1:${PORT}/harness.html" \
  LAIKA_AUTOMATION_OUTPUT="${OUTPUT_PATH}" \
  LAIKA_AUTOMATION_TIMEOUT="${TIMEOUT_SECONDS}" \
  LAIKA_AUTOMATION_QUIT_SAFARI="${QUIT_SAFARI}" \
  xcodebuild test -project "${XCODEPROJ}" -scheme LaikaUITests -destination "platform=macOS" -resultBundlePath "${result_bundle}" -derivedDataPath "${DERIVED_DATA_PATH}" DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" 2>&1 | tee "${log_path}"
  XCODE_STATUS=${PIPESTATUS[0]}
  if [[ "${XCODE_STATUS}" -eq 0 ]]; then
    break
  fi
  if [[ "${attempt}" -ge "${max_attempts}" ]]; then
    break
  fi
  if ! should_retry_ui "${log_path}"; then
    break
  fi
  sleep "${XCODE_RETRY_DELAY}"
done
set -e

stop_harness
exit "${XCODE_STATUS}"
