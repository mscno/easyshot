#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Shotglass Paste as Link
# @raycast.mode silent
# @raycast.packageName Shotglass
# @raycast.icon 📎
# @raycast.description Upload the image on your clipboard and replace it with a shareable link. Works over SSH.

set -euo pipefail
open -b no.paraply.shotglass 'shotglass://paste-upload'
