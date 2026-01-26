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
EXTENSION_NAME="Laika Extension.appex"
SIGN_APP="${SIGN_APP:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development}"
APP_ENTITLEMENTS="${REPO_ROOT}/src/laika/LaikaApp/Laika/Laika/Laika.entitlements"
EXT_ENTITLEMENTS="${REPO_ROOT}/src/laika/LaikaApp/Laika/Laika Extension/Laika Extension.entitlements"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.laika.Laika}"
EXT_BUNDLE_ID="${EXT_BUNDLE_ID:-com.laika.Laika.Extension}"
CLEAN_INSTALLATIONS="${CLEAN_INSTALLATIONS:-1}"
CLEAN_REGISTRATION="${CLEAN_REGISTRATION:-1}"
KEEP_BACKUP="${KEEP_BACKUP:-0}"
DEST_APP="${INSTALL_DIR}/${APP_NAME}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install Xcode and try again." >&2
  exit 1
fi

if [ ! -d "${PROJECT_PATH}" ]; then
  echo "Project not found at ${PROJECT_PATH}" >&2
  exit 1
fi

clean_installations() {
  if [ "${CLEAN_INSTALLATIONS}" != "1" ]; then
    return
  fi
  if [ -d "${DEST_APP}" ]; then
    if [ "${KEEP_BACKUP}" = "1" ]; then
      BACKUP_APP="${DEST_APP}.bak.$(date +%Y%m%d-%H%M%S)"
      echo "Backing up existing app to ${BACKUP_APP}"
      mv "${DEST_APP}" "${BACKUP_APP}"
    else
      rm -rf "${DEST_APP}"
    fi
  fi
  for dir in "/Applications" "${HOME}/Applications"; do
    app_path="${dir}/${APP_NAME}"
    if [ -d "${app_path}" ] && [ "${app_path}" != "${DEST_APP}" ]; then
      rm -rf "${app_path}"
    fi
  done
}

extension_path_for_app() {
  local app_path="$1"
  if [ -z "${app_path}" ]; then
    return 1
  fi
  echo "${app_path}/Contents/PlugIns/${EXTENSION_NAME}"
}

unregister_extension_for_app() {
  local app_path="$1"
  local extension_path
  extension_path="$(extension_path_for_app "${app_path}")"
  if [ -d "${extension_path}" ] && command -v pluginkit >/dev/null 2>&1; then
    pluginkit -r "${extension_path}" >/dev/null 2>&1 || true
  fi
}

collect_candidate_apps() {
  local app_path
  local trash_app
  if command -v mdfind >/dev/null 2>&1; then
    mdfind "kMDItemCFBundleIdentifier == '${APP_BUNDLE_ID}'"
  fi
  if [ -d "${APP_PATH}" ]; then
    printf "%s\n" "${APP_PATH}"
  fi
  if [ -d "${DEST_APP}" ]; then
    printf "%s\n" "${DEST_APP}"
  fi
  if [ -d "${REPO_ROOT}" ]; then
    find "${REPO_ROOT}" -type d -name "${APP_NAME}" -print 2>/dev/null
  fi
  trash_app="${HOME}/.Trash/${APP_NAME}"
  if [ -d "${trash_app}" ]; then
    printf "%s\n" "${trash_app}"
  fi
}

clean_registration() {
  if [ "${CLEAN_REGISTRATION}" != "1" ]; then
    return
  fi
  if command -v pluginkit >/dev/null 2>&1; then
    collect_candidate_apps | awk 'NF' | sort -u | while IFS= read -r app_path; do
      unregister_extension_for_app "${app_path}"
    done
  fi
  if [ -x "${LSREGISTER}" ]; then
    collect_candidate_apps | awk 'NF' | sort -u | while IFS= read -r app_path; do
      if [ -n "${app_path}" ]; then
        "${LSREGISTER}" -u "${app_path}" >/dev/null 2>&1 || true
      fi
    done
  fi
}

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
clean_registration
clean_installations

cp -R "${APP_PATH}" "${DEST_APP}"
echo "Installed app to ${DEST_APP}"

if [ "${SIGN_APP}" = "1" ]; then
  EXTENSION_PATH="${DEST_APP}/Contents/PlugIns/${EXTENSION_NAME}"
  if [ -d "${EXTENSION_PATH}" ]; then
    codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${EXT_ENTITLEMENTS}" --options runtime --timestamp=none "${EXTENSION_PATH}"
  fi
  codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${APP_ENTITLEMENTS}" --options runtime --timestamp=none "${DEST_APP}"
fi

if [ "${CLEAN_REGISTRATION}" = "1" ] && [ -x "${LSREGISTER}" ]; then
  if [ -d "${APP_PATH}" ]; then
    "${LSREGISTER}" -u "${APP_PATH}" >/dev/null 2>&1 || true
  fi
  if [ -d "${DEST_APP}" ]; then
    "${LSREGISTER}" -f "${DEST_APP}" >/dev/null 2>&1 || true
  fi
fi

if [ "${CLEAN_REGISTRATION}" = "1" ] && command -v pluginkit >/dev/null 2>&1; then
  EXTENSION_PATH="${DEST_APP}/Contents/PlugIns/${EXTENSION_NAME}"
  if [ -d "${EXTENSION_PATH}" ]; then
    pluginkit -a "${EXTENSION_PATH}" >/dev/null 2>&1 || true
  fi
fi

if [ "${OPEN_APP}" = "1" ]; then
  open "${DEST_APP}"
fi
