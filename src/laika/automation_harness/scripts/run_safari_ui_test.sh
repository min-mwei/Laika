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
  --no-quit-safari   Keep Safari open between runs
  --no-build         Skip building/installing the app
  --install-dir <p>  Install directory for Laika.app (default ~/Applications)
  --open-app         Open the app after install
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
HARNESS_TIMEOUT_BUFFER="${HARNESS_TIMEOUT_BUFFER:-5}"
HARNESS_TIMEOUT_SECONDS="${HARNESS_TIMEOUT_SECONDS:-}"
TELEMETRY_PATH="${TELEMETRY_PATH:-}"
BUILD_APP="1"
INSTALL_DIR="${HOME}/Applications"
OPEN_APP="0"
QUIT_SAFARI="1"
APP_NAME="Laika.app"
EXTENSION_NAME="Laika Extension.appex"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.laika.Laika}"
EXT_BUNDLE_ID="${EXT_BUNDLE_ID:-com.laika.Laika.Extension}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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
    --no-quit-safari)
      QUIT_SAFARI="0"
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
    --open-app)
      OPEN_APP="1"
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
  HARNESS_TIMEOUT_SECONDS=$((TIMEOUT_SECONDS - HARNESS_TIMEOUT_BUFFER))
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

resolve_primary_app_path() {
  echo "${INSTALL_DIR}/${APP_NAME}"
}

resolve_derived_app_path() {
  if [[ -z "${DERIVED_DATA_PATH}" ]]; then
    return 1
  fi
  for config in Debug Release; do
    candidate="${DERIVED_DATA_PATH}/Build/Products/${config}/${APP_NAME}"
    if [[ -d "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

resolve_keep_app_path() {
  local primary_path
  local derived_path
  primary_path="$(resolve_primary_app_path)"
  if [[ -d "${primary_path}" ]]; then
    echo "${primary_path}"
    return 0
  fi
  derived_path="$(resolve_derived_app_path || true)"
  if [[ -n "${derived_path}" ]]; then
    echo "${derived_path}"
    return 0
  fi
  return 1
}

prune_extension_duplicates() {
  local keep_path="${1:-}"
  local candidates=()
  local derived_path
  local primary_path
  local trash_app
  local unique_paths

  if [[ -z "${keep_path}" ]]; then
    keep_path="$(resolve_keep_app_path || true)"
  fi

  if command -v mdfind >/dev/null 2>&1; then
    while IFS= read -r app_path; do
      if [[ -n "${app_path}" ]]; then
        candidates+=("${app_path}")
      fi
    done < <(mdfind "kMDItemCFBundleIdentifier == '${APP_BUNDLE_ID}'")
  fi

  derived_path="$(resolve_derived_app_path || true)"
  if [[ -n "${derived_path}" ]]; then
    candidates+=("${derived_path}")
  fi

  primary_path="$(resolve_primary_app_path)"
  if [[ -d "${primary_path}" ]]; then
    candidates+=("${primary_path}")
  fi
  if [[ -d "${LAIKA_ROOT}" ]]; then
    while IFS= read -r app_path; do
      if [[ -n "${app_path}" ]]; then
        candidates+=("${app_path}")
      fi
    done < <(find "${LAIKA_ROOT}" -type d -name "${APP_NAME}" -print 2>/dev/null)
  fi
  trash_app="${HOME}/.Trash/${APP_NAME}"
  if [[ -d "${trash_app}" ]]; then
    candidates+=("${trash_app}")
  fi

  if [[ -x "${LSREGISTER}" ]]; then
    unique_paths="$(printf "%s\n" "${candidates[@]}" | awk 'NF' | sort -u)"
    while IFS= read -r app_path; do
      if [[ -z "${app_path}" || "${app_path}" == "${keep_path}" ]]; then
        continue
      fi
      if [[ -d "${app_path}" ]]; then
        unregister_extension_for_app "${app_path}"
        "${LSREGISTER}" -u "${app_path}" >/dev/null 2>&1 || true
      fi
    done <<< "${unique_paths}"
    if [[ -n "${keep_path}" && -d "${keep_path}" ]]; then
      "${LSREGISTER}" -f "${keep_path}" >/dev/null 2>&1 || true
    fi
  fi
}

register_extension_for_app() {
  local app_path="$1"
  local extension_path
  extension_path="$(extension_path_for_app "${app_path}")"
  if [[ -d "${extension_path}" ]] && command -v pluginkit >/dev/null 2>&1; then
    pluginkit -a "${extension_path}" >/dev/null 2>&1 || true
  fi
}

extension_path_for_app() {
  local app_path="$1"
  if [[ -z "${app_path}" ]]; then
    return 1
  fi
  echo "${app_path}/Contents/PlugIns/${EXTENSION_NAME}"
}

unregister_extension_for_app() {
  local app_path="$1"
  local extension_path
  extension_path="$(extension_path_for_app "${app_path}")"
  if [[ -d "${extension_path}" ]] && command -v pluginkit >/dev/null 2>&1; then
    pluginkit -r "${extension_path}" >/dev/null 2>&1 || true
  fi
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
  local keep_path
  keep_path="$(resolve_keep_app_path || true)"
  prune_extension_duplicates "${keep_path}"
  if [[ -n "${keep_path}" ]]; then
    register_extension_for_app "${keep_path}"
  fi
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

quit_safari() {
  if ! pgrep -x "Safari" >/dev/null 2>&1; then
    return 0
  fi
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'tell application "Safari" to quit' >/dev/null 2>&1 || true
    for _ in {1..10}; do
      if ! pgrep -x "Safari" >/dev/null 2>&1; then
        return 0
      fi
      sleep 0.3
    done
  fi
  pkill -x "Safari" >/dev/null 2>&1 || true
  sleep 1
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
  quit_safari
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
  local keep_path
  keep_path="$(resolve_keep_app_path || true)"
  if [[ -n "${keep_path}" ]]; then
    unregister_extension_for_app "${keep_path}"
  fi
  prune_extension_duplicates "${keep_path}"
  if [[ -n "${keep_path}" ]]; then
    register_extension_for_app "${keep_path}"
  fi
}

set +e
attempt=0
max_attempts=$((XCODE_RETRIES + 1))
XCODE_STATUS=1
CLEAN_DERIVED_DATA="0"
LAST_RESULT_BUNDLE=""
LAST_LOG_PATH=""
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
  LAST_RESULT_BUNDLE="${result_bundle}"
  LAST_LOG_PATH="${log_path}"
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
if [[ "${QUIT_SAFARI}" == "1" ]]; then
  quit_safari
fi
if [[ "${XCODE_STATUS}" -ne 0 ]]; then
  artifact_base="${OUTPUT_PATH}"
  if [[ "${artifact_base}" == *.json ]]; then
    artifact_base="${artifact_base%.json}"
  fi
  artifact_dir="${artifact_base}-artifacts"
  echo "Automation run failed."
  if [[ -n "${LAST_RESULT_BUNDLE}" ]]; then
    echo "Last xcresult: ${LAST_RESULT_BUNDLE}"
  fi
  if [[ -n "${LAST_LOG_PATH}" ]]; then
    echo "Last xcodebuild log: ${LAST_LOG_PATH}"
  fi
  echo "Output JSON: ${OUTPUT_PATH}"
  echo "Harness telemetry: ${TELEMETRY_PATH}"
  echo "UI artifacts: ${artifact_dir}"
  echo "Extension logs: ${HOME}/Library/Containers/com.laika.Laika.Extension/Data/Laika/logs/llm.jsonl"
  echo "App logs: ${HOME}/Library/Containers/com.laika.Laika/Data/Laika/logs/llm.jsonl"
fi
exit "${XCODE_STATUS}"
