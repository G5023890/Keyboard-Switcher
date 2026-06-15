#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Keyboard Switcher}"
BUNDLE_ID="${BUNDLE_ID:-com.local.KeyboardSwitcher}"
PROJECT_FILE="${PROJECT_FILE:-Keyboard Switcher.xcodeproj}"
SCHEME="${SCHEME:-Keyboard Switcher}"
CONFIGURATION="${CONFIGURATION:-Release}"
XCODE_APP="${XCODE_APP:-/Applications/Xcode-beta.app}"
DEVELOPER_DIR="${DEVELOPER_DIR:-$XCODE_APP/Contents/Developer}"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_DIR/dist/xcodebuild}"
INSTALL_DIR="${INSTALL_DIR:-/Applications/${APP_DISPLAY_NAME}.app}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
RESOLVED_SIGN_IDENTITY=""

log() {
  echo "[build] $*"
}

resolve_sign_identity() {
  if [[ -n "$SIGN_IDENTITY" ]]; then
    RESOLVED_SIGN_IDENTITY="$SIGN_IDENTITY"
    return 0
  fi

  if [[ -d "$INSTALL_DIR" ]]; then
    local existing
    existing="$(codesign -dv --verbose=4 "$INSTALL_DIR" 2>&1 | awk -F= '/^Authority=Apple Development: /{print $2; exit}' || true)"
    if [[ -n "$existing" ]]; then
      RESOLVED_SIGN_IDENTITY="$existing"
      return 0
    fi
  fi

  RESOLVED_SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development: /{print $2; exit}' || true)"
}

if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "xcodebuild not found at: $DEVELOPER_DIR/usr/bin/xcodebuild" >&2
  exit 1
fi

resolve_sign_identity
if [[ -n "$RESOLVED_SIGN_IDENTITY" ]]; then
  log "Using signing identity: $RESOLVED_SIGN_IDENTITY"
else
  log "No Apple Development identity found; using Xcode local signing"
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

log "Building $CONFIGURATION with Xcode-beta"
build_args=(
  -project "$PROJECT_FILE"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "platform=macOS"
  -derivedDataPath "$BUILD_ROOT/DerivedData"
  SYMROOT="$BUILD_ROOT/Products"
  DSTROOT="$BUILD_ROOT/Install"
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
)

if [[ -n "$RESOLVED_SIGN_IDENTITY" ]]; then
  build_args+=(
    CODE_SIGN_IDENTITY="$RESOLVED_SIGN_IDENTITY"
  )
fi

DEVELOPER_DIR="$DEVELOPER_DIR" "$DEVELOPER_DIR/usr/bin/xcodebuild" "${build_args[@]}" build

BUILT_APP="$BUILD_ROOT/Products/$CONFIGURATION/${APP_DISPLAY_NAME}.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Built app not found: $BUILT_APP" >&2
  exit 1
fi

log "Installing to $INSTALL_DIR"
rm -rf "$INSTALL_DIR"
/usr/bin/ditto --norsrc "$BUILT_APP" "$INSTALL_DIR"
xattr -cr "$INSTALL_DIR" 2>/dev/null || true

if [[ -n "$RESOLVED_SIGN_IDENTITY" ]]; then
  log "Re-signing installed app"
  codesign --force --deep --options runtime --entitlements "$PROJECT_DIR/KeyboardSwitcher/KeyboardSwitcher.entitlements" --sign "$RESOLVED_SIGN_IDENTITY" "$INSTALL_DIR"
else
  codesign --force --deep --sign - "$INSTALL_DIR"
fi

codesign --verify --deep --strict "$INSTALL_DIR"
/usr/bin/du -sh "$INSTALL_DIR"

log "Installed: $INSTALL_DIR"
