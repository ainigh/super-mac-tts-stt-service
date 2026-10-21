#!/bin/bash
# Builds build/SuperVoice.app and build/SuperVoice.zip (what a release carries). Needs a Mac with
# Xcode or its Command Line Tools; GitHub Actions runs it, so nobody has to build anything by hand.
#
#   VERSION=0.1.7 scripts/build-app.sh
#
# The app's "Update" runs it too, on your Mac, when GitHub hasn't built that commit (UNIVERSAL=0:
# just this Mac's chip, which works with only the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
COMMIT="${COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
# The branch the app's updater follows.
BRANCH="${BRANCH:-main}"
NAME=SuperVoice
APP="build/$NAME.app" 

# FluidAudio (the voices) needs Swift 6: an older Swift stops while resolving packages ("using
# Swift tools version 6.0.0 but the installed version is 5.10"). When the Swift on the PATH is
# older (old Command Line Tools) and a newer Xcode is installed, build with that Xcode instead.
swift_major() { "$@" --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+)\..*/\1/p' | head -1; }
major="$(swift_major swift || true)"
if [[ -z "$major" || "$major" -lt 6 ]]; then
  for dev in /Applications/Xcode*.app/Contents/Developer "$HOME"/Applications/Xcode*.app/Contents/Developer; do
    [[ -d "$dev" ]] || continue
    m="$(DEVELOPER_DIR="$dev" swift_major xcrun swift || true)"
    if [[ -n "$m" && "$m" -ge 6 ]]; then
      export DEVELOPER_DIR="$dev"
      major="$m"
      echo "using Swift $m from $dev"
      break
    fi
  done
fi
if [[ -z "$major" || "$major" -lt 6 ]]; then
  have="$(swift --version 2>/dev/null | head -1 || true)"
  echo "error: building needs Swift 6 or newer, and this Mac has: ${have:-no Swift}. Update Apple's command line tools (sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install) or install Xcode 16 or newer, then try again." >&2
  exit 3
fi

if [[ "${UNIVERSAL:-1}" == 1 ]]; then ARCHS=(--arch arm64 --arch x86_64); else ARCHS=(); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BINDIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"
BIN="$BINDIR/$NAME"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
# The packages' resource bundles (FluidAudio's), where their code looks for them.
for bundle in "$BINDIR"/*.bundle; do
  if [[ -e "$bundle" ]]; then cp -R "$bundle" "$APP/Contents/Resources/"; fi
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.ainigh.supervoice</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>Super Voice</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>SuperVoiceCommit</key><string>$COMMIT</string>
  <key>SuperVoiceBranch</key><string>$BRANCH</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>To write down what you say: in Dictate, while always listening, and to AI Listen. It stays on this Mac.</string>
  <key>NSCameraUsageDescription</key><string>To see you wave, which starts AI Listen when Listen is on. Nothing is kept or sent anywhere; the camera is only on while it watches for a wave.</string>
  <key>NSAppleEventsUsageDescription</key><string>So AI Listen can read the page open in your browser and find text on it, when you ask it to. It stays on this Mac.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

# Ad-hoc signature: Apple silicon only runs signed code, and this needs no developer account.
codesign --force --sign - --timestamp=none "$APP"
ditto -c -k --keepParent "$APP" "build/$NAME.zip"
echo "built $APP ($VERSION, $BRANCH, $COMMIT)"
