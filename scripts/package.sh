#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_PATH="${ROOT_DIR}/dist/Tintap.app"

if [[ -e "${APP_PATH}" ]]; then
  if [[ "${1:-}" == "--replace" ]]; then
    rm -rf "${APP_PATH}"
  else
    print -u2 "Refusing to overwrite ${APP_PATH}. Re-run with --replace to replace this generated bundle."
    exit 1
  fi
fi

cd "${ROOT_DIR}"
BUILD_FLAGS=(--disable-sandbox -c release)
if [[ -n "${TINTAP_SDK:-}" ]]; then
  BUILD_FLAGS+=(--sdk "${TINTAP_SDK}")
fi
swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"
cp "${BIN_DIR}/Tintap" "${APP_PATH}/Contents/MacOS/Tintap"
cp "${ROOT_DIR}/Resources/Info.plist" "${APP_PATH}/Contents/Info.plist"
cp "${ROOT_DIR}/Resources/MenuBarIcon.png" "${APP_PATH}/Contents/Resources/MenuBarIcon.png"
iconutil -c icns \
  "${ROOT_DIR}/Resources/AppIcon.iconset" \
  -o "${APP_PATH}/Contents/Resources/AppIcon.icns"
codesign --force --sign - "${APP_PATH}"

print "Packaged ${APP_PATH}"
print "Launch it with: open ${APP_PATH}"
