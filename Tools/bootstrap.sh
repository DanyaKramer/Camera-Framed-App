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

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing XcodeGen..."
    brew install xcodegen
  else
    echo "XcodeGen is not installed and Homebrew is missing."
    echo "Install Homebrew from https://brew.sh and run this script again."
    exit 1
  fi
fi

# Remove any stale project first so nothing survives from a previous run.
rm -rf CameraApp.xcodeproj

echo "Generating project from project.yml..."
xcodegen generate

echo ""
echo "Done. Opening Xcode..."
open CameraApp.xcodeproj