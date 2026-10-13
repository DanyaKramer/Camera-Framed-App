#!/bin/bash
#
# Generates CameraApp.xcodeproj from project.yml.
#
# The project file is NOT committed — it is rebuilt from project.yml every time.
# That removes the entire class of "hand-written pbxproj is subtly broken"
# failures, and means XcodeGen reads the real filesystem rather than trusting
# a list someone wrote by hand.
#
# Usage:  ./Tools/bootstrap.sh
# Then:   open CameraApp.xcodeproj
#
# Note on installation: we deliberately do NOT use `brew install xcodegen`.
# Homebrew ships no prebuilt bottle for macOS 13 (Ventura), so it falls back to
# compiling from source, which needs Xcode 15.3, which needs macOS 14. Instead we
# download the official prebuilt release binary into ./.tools — no compiler, no
# Homebrew, no sudo.

set -euo pipefail

cd "$(dirname "$0")/.."

# 2.42.0 is the last release built against the Xcode 15 toolchain, which is the
# newest line that runs on macOS 13. Override with XCODEGEN_VERSION if needed.
XCODEGEN_VERSION="${XCODEGEN_VERSION:-2.42.0}"
TOOLS_DIR="$PWD/.tools"
BIN_DIR="$TOOLS_DIR/bin"
SHARE_DIR="$TOOLS_DIR/share"

xcodegen_works() {
  "$@" --version >/dev/null 2>&1
}

install_from_release() {
  local version="$1"
  local tmp root binary

  tmp="$(mktemp -d)"
  root="$tmp/xcodegen"

  echo "Downloading XcodeGen $version (prebuilt, no compiler needed)..."
  if ! curl -fsSL -o "$tmp/xcodegen.zip" \
      "https://github.com/yonaskolb/XcodeGen/releases/download/${version}/xcodegen.zip"; then
    rm -rf "$tmp"
    echo "Failed to download XcodeGen $version." >&2
    return 1
  fi

  # unzip is standard on macOS; ditto is the native fallback.
  if command -v unzip >/dev/null 2>&1; then
    unzip -oq "$tmp/xcodegen.zip" -d "$tmp" || { rm -rf "$tmp"; echo "Failed to unpack the archive." >&2; return 1; }
  else
    ditto -x -k "$tmp/xcodegen.zip" "$tmp" || { rm -rf "$tmp"; echo "Failed to unpack the archive." >&2; return 1; }
  fi

  # The archive has a top-level `xcodegen/` directory holding bin/ and share/.
  # Locate the binary by path rather than by name alone: the archive also
  # contains install.sh, and `find -perm` syntax differs between BSD and GNU.
  binary="$(find "$tmp" -type f -path '*/bin/xcodegen' 2>/dev/null | head -1)"
  if [ -z "$binary" ]; then
    binary="$(find "$tmp" -type f -name xcodegen 2>/dev/null | head -1)"
  fi
  if [ -z "$binary" ]; then
    echo "Could not find the xcodegen binary inside the archive." >&2
    rm -rf "$tmp"
    return 1
  fi

  mkdir -p "$BIN_DIR"
  cp "$binary" "$BIN_DIR/xcodegen"
  chmod +x "$BIN_DIR/xcodegen"

  # XcodeGen reads default build settings from share/xcodegen/SettingPresets and
  # resolves them relative to its own location. Copying only the binary gives a
  # "missing setting preset" failure, so the share/ tree must sit next to bin/.
  if [ -d "$root/share" ]; then
    rm -rf "$SHARE_DIR"
    cp -R "$root/share" "$SHARE_DIR"
  fi

  rm -rf "$tmp"

  if ! xcodegen_works "$BIN_DIR/xcodegen"; then
    echo "The downloaded XcodeGen will not run on this macOS." >&2
    echo "Try an older build:  XCODEGEN_VERSION=2.38.0 ./Tools/bootstrap.sh" >&2
    return 1
  fi
}

# --- resolve a working xcodegen ---------------------------------------------
if command -v xcodegen >/dev/null 2>&1 && xcodegen --version >/dev/null 2>&1; then
  echo "Using system XcodeGen: $(xcodegen --version 2>&1 | head -1)"
elif [ -x "$BIN_DIR/xcodegen" ] && xcodegen_works "$BIN_DIR/xcodegen"; then
  echo "Using local XcodeGen: $("$BIN_DIR/xcodegen" --version 2>&1 | head -1)"
  export PATH="$BIN_DIR:$PATH"
else
  install_from_release "$XCODEGEN_VERSION"
  export PATH="$BIN_DIR:$PATH"
  echo "Installed XcodeGen: $(xcodegen --version 2>&1 | head -1)"
fi

command -v xcodegen >/dev/null 2>&1 || {
  echo "xcodegen is not on PATH after installation." >&2
  exit 1
}

echo ""
echo "macOS:  $(sw_vers -productVersion)  ($(uname -m))"
echo "Xcode:  $(xcodebuild -version 2>/dev/null | head -1 || echo 'NOT INSTALLED — iOS build will not work')"

# Remove any stale project first so nothing survives from a previous run.
rm -rf CameraApp.xcodeproj

echo ""
echo "Generating project from project.yml..."
xcodegen generate

if [ "${XCODEGEN_SKIP_OPEN:-}" = "1" ]; then
  echo ""
  echo "Done (XCODEGEN_SKIP_OPEN set — not opening Xcode)."
  exit 0
fi

echo ""
echo "Done. Opening Xcode..."
open CameraApp.xcodeproj