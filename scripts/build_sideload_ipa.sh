#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/build_sideload_ipa.sh <decrypted-ipa> [output-ipa] [display-name] [bundle-id]

Examples:
  scripts/build_sideload_ipa.sh "_YouTube Music_v9.17-AppAssassin.ipa"
  scripts/build_sideload_ipa.sh "_YouTube Music_v9.17-AppAssassin.ipa" \
    "build/ipa/YTMusicUltimate-Bilingual.ipa" \
    "YTMusic Bilingual" \
    "com.py233.ytmusicultimate.bilingual"

Environment:
  THEOS defaults to /Users/py_23/theos
  CYAN defaults to cyan
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 ]]; then
  usage
  exit 0
fi

IPA_INPUT="$1"
IPA_OUTPUT="${2:-build/ipa/YTMusicUltimate-Bilingual.ipa}"
DISPLAY_NAME="${3:-YTMusic Bilingual}"
BUNDLE_ID="${4:-com.py233.ytmusicultimate.bilingual}"
THEOS="${THEOS:-/Users/py_23/theos}"
CYAN="${CYAN:-cyan}"

if [[ ! -f "$IPA_INPUT" ]]; then
  echo "Input IPA not found: $IPA_INPUT" >&2
  exit 1
fi

if [[ ! -d "$THEOS" ]]; then
  echo "THEOS directory not found: $THEOS" >&2
  echo "Install Theos first or pass THEOS=/path/to/theos." >&2
  exit 1
fi

if ! command -v "$CYAN" >/dev/null 2>&1; then
  echo "cyan not found. Install with:" >&2
  echo "  brew install pipx" >&2
  echo "  pipx install --force https://github.com/asdfzxcvbn/pyzule-rw/archive/main.zip" >&2
  exit 1
fi

mkdir -p "$(dirname "$IPA_OUTPUT")"

echo "==> Building sideloading deb"
THEOS="$THEOS" SIDELOADING=1 FINALPACKAGE=1 make clean package

DEB="$(ls -t packages/*.deb | head -1)"
if [[ ! -f "$DEB" ]]; then
  echo "No deb produced in packages/." >&2
  exit 1
fi

echo "==> Injecting $DEB into $IPA_INPUT"
"$CYAN" \
  -i "$IPA_INPUT" \
  -o "$IPA_OUTPUT" \
  -u -w -s \
  -f "$DEB" \
  -n "$DISPLAY_NAME" \
  -b "$BUNDLE_ID" \
  --overwrite

echo "==> Built IPA: $IPA_OUTPUT"
