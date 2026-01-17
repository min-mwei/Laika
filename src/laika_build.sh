#!/bin/sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_PATH="${REPO_ROOT}/src/laika/LaikaApp/Laika/Laika.xcodeproj"
SCHEME="Laika"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=macOS}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-4Z82EAJL2W}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install Xcode and try again." >&2
  exit 1
fi

if [ ! -d "${PROJECT_PATH}" ]; then
  echo "Project not found at ${PROJECT_PATH}" >&2
  exit 1
fi

echo "Building ${SCHEME} (${CONFIGURATION}) for ${DESTINATION}"
echo "Project: ${PROJECT_PATH}"
echo "Team: ${DEVELOPMENT_TEAM}"

xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  build
