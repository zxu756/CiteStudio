#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CiteStudio"
BUILD_DIR="${ROOT_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"

echo "==> Building ${APP_NAME} (release, arm64, macOS 14.0+)..."
cd "${ROOT_DIR}"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"

cp "${BIN_DIR}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"
cp "Scripts/Info.plist" "${CONTENTS}/Info.plist"

echo "==> Generating AppIcon.icns..."
ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"
rm -rf "${ICONSET_DIR}"
swift Scripts/make-icon.swift "${ICONSET_DIR}"
iconutil -c icns "${ICONSET_DIR}" -o "${RES_DIR}/AppIcon.icns"
rm -rf "${ICONSET_DIR}"

echo "==> Ad-hoc signing & verifying..."
codesign --force --deep --sign - "${APP_BUNDLE}"
codesign --verify --verbose=2 "${APP_BUNDLE}"

echo "==> Rendering 2x Retina screenshots to docs/..."
mkdir -p "${ROOT_DIR}/docs"
"${MACOS_DIR}/${APP_NAME}" --export-screenshots "${ROOT_DIR}/docs"

echo "✓ Built ${APP_BUNDLE}"
