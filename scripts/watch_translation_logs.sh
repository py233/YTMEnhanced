#!/usr/bin/env bash
set -euo pipefail

FILTER="${1:-YTMUTranslation}"

if ! command -v idevicesyslog >/dev/null 2>&1; then
  echo "idevicesyslog not found. Install it with: brew install libimobiledevice" >&2
  exit 1
fi

if ! idevice_id -l | grep -q .; then
  echo "No trusted iPhone found. Connect the device, unlock it, and tap Trust." >&2
  exit 1
fi

echo "Streaming iPhone logs filtered by: $FILTER"
echo "Press Ctrl-C to stop."

idevicesyslog | awk -v pat="$FILTER" 'index($0, pat) { print; fflush() }'
