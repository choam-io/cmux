#!/usr/bin/env bash
set -euo pipefail

# Build nsmux - a personal fork of cmux with prefix key mode
# Builds a release version and rebrands it as "nsmux"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build-nsmux"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
APP_NAME="nsmux"
BUNDLE_ID="io.choam.nsmux"
VERSION="${NSMUX_VERSION:-0.1.0}"
BUILD_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"

cd "$PROJECT_DIR"

echo "==> Building nsmux v${VERSION}..."

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Running xcodebuild (Release)..."
xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  build 2>&1 | tee "${BUILD_DIR}/build.log" | grep -E '(warning:|error:|fatal:|BUILD FAILED|BUILD SUCCEEDED|\*\* BUILD)'

# Find the built app
SRC_APP="${DERIVED_DATA}/Build/Products/Release/cmux.app"

if [[ ! -d "$SRC_APP" ]]; then
  echo "error: Build failed - cmux.app not found at ${SRC_APP}"
  echo "Check ${BUILD_DIR}/build.log for details"
  exit 1
fi

echo "==> Rebranding as ${APP_NAME}..."

# Copy to new name
DEST_APP="${BUILD_DIR}/${APP_NAME}.app"
rm -rf "$DEST_APP"
cp -R "$SRC_APP" "$DEST_APP"

# Rename the main executable
mv "${DEST_APP}/Contents/MacOS/cmux" "${DEST_APP}/Contents/MacOS/${APP_NAME}"

# Update Info.plist
PLIST="${DEST_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${APP_NAME}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST"

# Stamp the git commit so doctor can check if the build is current
/usr/libexec/PlistBuddy -c "Set :NsmuxBuildCommit ${BUILD_SHA}" "$PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :NsmuxBuildCommit string ${BUILD_SHA}" "$PLIST"

# Add display name if not present
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APP_NAME}" "$PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${APP_NAME}" "$PLIST"

# Update the CLI binary name
CLI_DIR="${DEST_APP}/Contents/Resources/bin"
if [[ -f "${CLI_DIR}/cmux" ]]; then
  mv "${CLI_DIR}/cmux" "${CLI_DIR}/${APP_NAME}"
  # Keep a cmux symlink so CMUX_BUNDLED_CLI_PATH resolution works
  ln -sf "${APP_NAME}" "${CLI_DIR}/cmux"
fi

# Re-sign (ad-hoc)
echo "==> Signing (ad-hoc)..."
codesign --force --deep --sign - "$DEST_APP" 2>/dev/null || true

echo ""
echo "==> Build complete!"
echo "    App: ${DEST_APP}"
echo ""
echo "To install:"
echo "  cp -R \"${DEST_APP}\" /Applications/"
echo ""
echo "To enable prefix key mode:"
echo "  defaults write ${BUNDLE_ID} prefixKeyMode.enabled -bool true"
echo ""
echo "Prefix bindings (Ctrl+A then key):"
echo "  h/j/k/l  - focus pane left/down/up/right"
echo "  v        - split vertical (right)"
echo "  s/-      - split horizontal (down)"
echo "  z        - toggle zoom"
echo "  x        - close workspace"
echo "  c        - new workspace"
echo "  n/p      - next/prev workspace"
echo "  1-9      - select workspace by number"
echo "  ,        - rename workspace"
