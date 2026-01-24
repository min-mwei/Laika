#!/bin/sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_PATH="${REPO_ROOT}/src/laika/LaikaApp/Laika/Laika.xcodeproj"
SCHEME="${SCHEME:-LaikaUITests}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=macOS}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-4Z82EAJL2W}"
INSTALL_APP="${INSTALL_APP:-1}"
INSTALL_DIR="${INSTALL_DIR:-${HOME}/Applications}"
OPEN_APP="${OPEN_APP:-0}"
APP_NAME="Laika.app"
SIGN_APP="${SIGN_APP:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development}"
APP_ENTITLEMENTS="${REPO_ROOT}/src/laika/LaikaApp/Laika/Laika/Laika.entitlements"
EXT_ENTITLEMENTS="${REPO_ROOT}/src/laika/LaikaApp/Laika/Laika Extension/Laika Extension.entitlements"

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
echo "Install app: ${INSTALL_APP} -> ${INSTALL_DIR}"
echo "Sign app: ${SIGN_APP} (${SIGN_IDENTITY})"

xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  build

if [ "${INSTALL_APP}" != "1" ]; then
  exit 0
fi

BUILD_PRODUCTS_DIR="$(
  xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "${DESTINATION}" \
    -showBuildSettings | awk -F ' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}'
)"
APP_PATH="${BUILD_PRODUCTS_DIR}/${APP_NAME}"

if [ ! -d "${APP_PATH}" ]; then
  echo "Built app not found at ${APP_PATH}" >&2
  exit 1
fi

mkdir -p "${INSTALL_DIR}"
DEST_APP="${INSTALL_DIR}/${APP_NAME}"
if [ -d "${DEST_APP}" ]; then
  BACKUP_APP="${DEST_APP}.bak.$(date +%Y%m%d-%H%M%S)"
  echo "Backing up existing app to ${BACKUP_APP}"
  mv "${DEST_APP}" "${BACKUP_APP}"
fi

cp -R "${APP_PATH}" "${DEST_APP}"
echo "Installed app to ${DEST_APP}"

if [ "${SIGN_APP}" = "1" ]; then
  EXTENSION_PATH="${DEST_APP}/Contents/PlugIns/Laika Extension.appex"
  if [ -d "${EXTENSION_PATH}" ]; then
    codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${EXT_ENTITLEMENTS}" --options runtime --timestamp=none "${EXTENSION_PATH}"
  fi
  codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${APP_ENTITLEMENTS}" --options runtime --timestamp=none "${DEST_APP}"
fi

if [ "${OPEN_APP}" = "1" ]; then
  open "${DEST_APP}"
fi
