#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
DEVELOPER_DIR_PATH="$(xcode-select -p)"
TEST_FLAGS=()

if [[ "${DEVELOPER_DIR_PATH}" == "/Library/Developer/CommandLineTools" ]]; then
  FRAMEWORKS_DIR="${DEVELOPER_DIR_PATH}/Library/Developer/Frameworks"
  LIBRARIES_DIR="${DEVELOPER_DIR_PATH}/Library/Developer/usr/lib"

  if [[ ! -d "${FRAMEWORKS_DIR}/Testing.framework" ]]; then
    print -u2 "Swift Testing is unavailable in the selected Command Line Tools. Install Xcode 16 or newer, then select it with xcode-select."
    exit 1
  fi

  TEST_FLAGS+=(
    -Xswiftc -F
    -Xswiftc "${FRAMEWORKS_DIR}"
    -Xlinker -rpath
    -Xlinker "${FRAMEWORKS_DIR}"
    -Xlinker -rpath
    -Xlinker "${LIBRARIES_DIR}"
  )
fi

cd "${ROOT_DIR}"
swift test "${TEST_FLAGS[@]}" "$@"
