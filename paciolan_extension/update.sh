#!/usr/bin/env bash
# Update the unpacked eVenue/Paciolan collector from git (no Web Store).
#
#   ./paciolan_extension/update.sh
#
# then Reload the extension at chrome://extensions (or click the reload ↻ icon).
# Chrome does NOT auto-update unpacked extensions, so this pull + reload is the
# update path. The popup's "Check for updates" tells you when a newer version
# has been published to Supabase (by CI on push to main).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"
echo "Pulling latest from git in $here …"
git pull --ff-only
ver="$(grep -o '"version"[^,]*' paciolan_extension/manifest.json | head -1 | grep -o '[0-9.]*')"
echo
echo "✓ Updated. Extension manifest version is now v${ver}."
echo "→ Open chrome://extensions and click Reload ↻ on 'eVenue / Paciolan Seat Collector'."
