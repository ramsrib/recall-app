#!/usr/bin/env bash
# Build the SwiftPM executable and wrap it into a double-clickable
# "Recall App.app" with the right bundle identifier.
# Run from the repo root (the Makefile does this for you): make app
set -euo pipefail

APP_NAME="Recall App"
BUNDLE_ID="io.github.ramsrib.recall"
# scripts/release.sh passes the version being released; it then asserts the
# built Info.plist matches, so this default only applies to local builds.
VERSION="${MARKETING_VERSION:-0.1.0}"
CONFIG="${1:-release}"

if [[ ! -f Package.swift ]]; then
    echo "error: run this from the recall-app repo root (try: make app)" >&2
    exit 1
fi

echo "› swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/RecallApp"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RecallApp"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>RecallApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSMultipleInstancesProhibited</key><true/>

    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAccentColorName</key><string>AccentColor</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>CFBundleURLTypes</key>
    <array>
      <dict>
        <key>CFBundleURLName</key><string>${BUNDLE_ID}</string>
        <key>CFBundleURLSchemes</key>
        <array><string>recall</string></array>
      </dict>
    </array>
</dict>
</plist>
PLIST

# Compile the asset catalog into the bundle so the app icon and accent color
# are available to AppKit at runtime.
if [[ -d Assets.xcassets ]]; then
    xcrun actool Assets.xcassets \
        --compile "$APP/Contents/Resources" \
        --platform macosx --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$(mktemp)" >/dev/null 2>&1 \
        || echo "  (actool skipped - bundled assets won't apply)"
fi

# Sign. A Developer ID signature is what lets someone who *downloads* the app
# open it without Gatekeeper stopping them, so prefer it and fall back to ad-hoc
# (fine locally, not for a release — scripts/release.sh warns when it happens).
if [[ -z "${CODE_SIGN_IDENTITY:-}" ]]; then
    for KIND in "Developer ID Application" "Apple Development"; do
        LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep "\"$KIND" | head -1 || true)"
        if [[ -n "$LINE" ]]; then
            CODE_SIGN_IDENTITY="$(echo "$LINE" | awk '{print $2}')"
            echo "› signing with $KIND ($CODE_SIGN_IDENTITY)"
            break
        fi
    done
fi
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
[[ "$CODE_SIGN_IDENTITY" == "-" ]] && echo "› no signing identity found; signing ad-hoc"

# --options runtime (hardened runtime) is required for notarization; harmless
# when signing ad-hoc locally.
codesign --force --deep --options runtime --timestamp \
    --sign "$CODE_SIGN_IDENTITY" "$APP" >/dev/null 2>&1 || \
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "  (codesign skipped — app will still run locally)"

echo "✓ Built $APP ($VERSION)"
