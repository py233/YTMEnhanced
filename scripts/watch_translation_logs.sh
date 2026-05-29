#!/usr/bin/env bash
set -euo pipefail

# Stream YTMEnhanced logs from a connected iPhone.
# By default catches BOTH log prefixes — [YTMULyrics] and [YTMUTranslation] —
# plus any other line containing "YTMU".
FILTER="${1:-YTMU}"

if ! command -v idevicesyslog >/dev/null 2>&1; then
  cat >&2 <<'MSG'
idevicesyslog not found.

Install via Homebrew:
  brew install libimobiledevice

Or use Console.app instead:
  1. Connect iPhone via USB and tap Trust.
  2. Open /System/Applications/Utilities/Console.app
  3. Pick your iPhone in the left sidebar (under Devices).
  4. Type the search filter: YTMU
  5. Make sure live streaming is on (the Pause button on top is BLUE, not gray).
  6. Open YouTube Music on the iPhone, play a song.
MSG
  exit 1
fi

if ! idevice_id -l | grep -q .; then
  echo "No trusted iPhone found. Connect the device, unlock it, and tap Trust." >&2
  exit 1
fi

echo "Streaming iPhone logs filtered by: $FILTER"
echo "Tip: change the filter via 'scripts/watch_translation_logs.sh <pattern>'."
echo "Press Ctrl-C to stop."

idevicesyslog | awk -v pat="$FILTER" 'index($0, pat) { print; fflush() }'
