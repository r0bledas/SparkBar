#!/bin/zsh
set -euo pipefail

APP_NAME="SparkBar"
VERSION="${1:-1.8.3}"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
BUNDLE_DIR="dist/${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "⚡ Building ${APP_NAME} (Release)..."
swift build -c release

rm -rf "${BUNDLE_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp ".build/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"
cp "AGENTS.md" "${RESOURCES_DIR}/AGENTS.md"

if [ -f "Assets/AppIcon.icns" ]; then
    cp "Assets/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi
if [ -f "Assets/SparkBarSymbol.pdf" ]; then
    cp "Assets/SparkBarSymbol.pdf" "${RESOURCES_DIR}/SparkBarSymbol.pdf"
fi
if [ -f "Assets/SparkBarSymbol.svg" ]; then
    cp "Assets/SparkBarSymbol.svg" "${RESOURCES_DIR}/SparkBarSymbol.svg"
fi

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.sparkbar.app</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>GitCommitSHA</key>
    <string>${GIT_SHA}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "✅ Created macOS bundle at ${BUNDLE_DIR}"
