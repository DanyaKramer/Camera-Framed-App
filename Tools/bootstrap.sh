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
# Homebrew, works on Ventura and anything newer.

set -euo pipefail

cd "$(dirname "$0")/.."

# 2.42.0 is the last release built against the Xcode 15 toolchain, which is the
# newest line that runs on macOS 13. Override with XCODEGEN_VERSION if needed.
XCODEGEN_VERSION="${XCODEGEN_VERSION:-2.42.0}"
LOCAL_BIN="$PWD/.tools/bin/xcodegen"

resolve_xcodegen() {
  # Already usable?
  if command -v xcodegen >/dev/null 2>&1 && xcodegen --version >/dev/null 2>&1; then
    echo "Using system XcodeGen: $(xcodegen --version 2>&1 | head -1)"
    return 0
  fi

  # Previously downloaded by this script?
  if [ -x "$LOCAL_BIN" ] && "$LOCAL_BIN" --version >/dev/null 2>&1; then
    echo "Using local XcodeGen: $("$LOCAL_BIN" --version 2>&1 | head -1)"
    export PATH="$PWD/.tools/bin:$PATH"
    return 0
  fi

  echo "Downloading XcodeGen $XCODEGEN_VERSION (prebuilt, no compiler needed)..."
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  if ! curl -fsSL -o "$tmp/xcodegen.zip" \
      "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"; then
    echo "Failed to download XcodeGen $XCODEGEN_VERSION." >&2
    return 1
  fi

  unzip -oq "$tmp/xcodegen.zip" -d "$tmp" || {
    echo "Failed to unpack xcodegen.zip" >&2
    return 1
  }

  if [ ! -f "$tmp/bin/xcodegen" ]; then
    echo "xcodegen binary not found inside the archive" >&2
    return 1
  fi

  mkdir -p "$PWD/.tools/bin"
  cp "$tmp/bin/xcodegen" "$LOCAL_BIN"
  chmod +x "$LOCAL_BIN"

  if ! "$LOCAL_BIN" --version >/dev/null 2>&1; then
    echo "The downloaded XcodeGen will not run on this macOS version." >&2
    echo "Try an older build:  XCODEGEN_VERSION=2.38.0 ./Tools/bootstrap.sh" >&2
    return 1
  fi

  export PATH="$PWD/.tools/bin:$PATH"
  echo "Installed XcodeGen: $("$LOCAL_BIN" --version 2>&1 | head -1)"
}

resolve_xcodegen

echo ""
echo "macOS:    $(sw_vers -productVersion)  ($(uname -m))"
echo "Xcode:    $(xcodebuild -version 2>/dev/null | head -1 || echo 'NOT INSTALLED')"

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