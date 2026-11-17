#!/bin/zsh
set -euo pipefail

APP_NAME="SparkBar"
VERSION="${1:-1.0.1}"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
STAGE_DIR="dist/dmg_stage"
DMG_PATH="dist/${DMG_NAME}"

./Scripts/package_app.sh "${VERSION}"

rm -rf "${STAGE_DIR}" "${DMG_PATH}"
mkdir -p "${STAGE_DIR}"

cp -R "dist/${APP_NAME}.app" "${STAGE_DIR}/"
ln -s /Applications "${STAGE_DIR}/Applications"

echo "💿 Creating ${DMG_PATH}..."
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE_DIR}" -ov -format UDZO "${DMG_PATH}"
rm -rf "${STAGE_DIR}"

echo "✅ Created DMG at ${DMG_PATH}"
ls -lh "${DMG_PATH}"
