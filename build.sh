#!/bin/bash
set -e

echo "Building DisplayBuddy..."

cd "$(dirname "$0")"

# Build with Swift Package Manager
swift build -c release 2>&1

# Create .app bundle
APP_DIR="DisplayBuddy.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp .build/release/DisplayBuddy "$APP_DIR/Contents/MacOS/"

# Copy Info.plist
cp Resources/Info.plist "$APP_DIR/Contents/"

# Ad-hoc code sign (required for IOKit access)
codesign --force --sign - "$APP_DIR"

echo ""
echo "Build complete: $APP_DIR"
echo "Run with: open $APP_DIR"
