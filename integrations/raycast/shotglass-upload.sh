#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Shotglass Capture & Copy Link
# @raycast.mode silent
# @raycast.packageName Shotglass
# @raycast.icon 🔗
# @raycast.description Capture an area, upload it to Shotglass Cloud and copy a shareable link.

set -euo pipefail
open -b no.paraply.shotglass 'shotglass://upload'
