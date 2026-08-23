#!/usr/bin/env bash
# Builds Source/{Lyrics,Translation,Scrobbling,Utils} plus Tests/Host/*.m
# into one Mac Catalyst binary and runs it. Needs a full Xcode.app (the
# Catalyst UIKit lives in its macOS SDK); the system xcode-select can stay
# on CommandLineTools — we point DEVELOPER_DIR at Xcode for this script only.
#
#   Tests/Host/run.sh            # build + run
#   Tests/Host/run.sh --build    # build only
set -euo pipefail
cd "$(dirname "$0")/../.."

XCODE="${XCODE:-/Applications/Xcode.app}"
if [[ ! -d "$XCODE/Contents/Developer" ]]; then
  echo "Tests/Host/run.sh: needs Xcode.app at $XCODE (set XCODE=/path/to/Xcode.app)" >&2
  exit 2
fi
export DEVELOPER_DIR="$XCODE/Contents/Developer"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS_FW="$SDK/System/iOSSupport/System/Library/Frameworks"
THEOS="${THEOS:-$HOME/theos}"
OUT=".theos/host-tests"
mkdir -p "$OUT"

SOURCES=(
  Source/Lyrics/*.m
  Source/Lyrics/Providers/*.m
  Source/Translation/*.m
  Source/Translation/Providers/*.m
  Source/Scrobbling/*.m
  Source/Scrobbling/Providers/*.m
  Source/Utils/*.m
  Tests/Host/*.m
)

# Mirror the flags Theos uses that affect semantics: ARC, -Wall, the
# rootless prefix define. -Wno-* below only silences Catalyst-specific
# availability noise that Theos' iOS SDK does not emit.
xcrun clang \
  -fobjc-arc -Wall -Werror \
  -Wno-deprecated-declarations -Wno-unguarded-availability-new \
  -target arm64-apple-ios16.0-macabi -isysroot "$SDK" \
  -iframework "$IOS_FW" -F "$IOS_FW" \
  -I "$THEOS/include" -I "$THEOS/vendor/include" -I Source -I Tests/Host \
  -D THEOS_PACKAGE_INSTALL_PREFIX='""' -DTWEAK_VERSION=1.0.0 -DDEBUG -DYTMU_HOST_TESTS=1 \
  -framework UIKit -framework Foundation -framework QuartzCore \
  -framework MediaPlayer -framework NaturalLanguage -framework CoreGraphics \
  "${SOURCES[@]}" -o "$OUT/ytmu-host-tests"

# UIApplicationMain (which the runner uses so UIKit windows / display links
# are real) insists on a bundle identifier, so wrap the binary in a minimal
# Catalyst .app. Nothing is installed or registered anywhere.
APP="$OUT/YTMUHostTests.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$OUT/ytmu-host-tests" "$APP/Contents/MacOS/YTMUHostTests"
# The real localisation bundle, found the same way the sideloaded app finds
# it ([NSBundle mainBundle] pathForResource:@"YTMusicUltimate" ofType:@"bundle").
mkdir -p "$APP/Contents/Resources"
cp -R "layout/Library/Application Support/YTMusicUltimate.bundle" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>net.py233.ytmu.host-tests</string>
  <key>CFBundleName</key><string>YTMUHostTests</string>
  <key>CFBundleExecutable</key><string>YTMUHostTests</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

if [[ "${1:-}" == "--build" ]]; then echo "built $APP"; exit 0; fi

# Every on-disk cache the tweak writes is rooted at YTMU_CACHES_ROOT when set
# (see Source/Utils/YTMUPaths.m), so the suite can exercise cache code paths
# without touching ~/Library/Caches. Fresh dir per run; removed afterwards.
CACHES="$(mktemp -d -t ytmu-host-tests)"
trap 'rm -rf "$CACHES"' EXIT
YTMU_CACHES_ROOT="$CACHES" "$APP/Contents/MacOS/YTMUHostTests"
