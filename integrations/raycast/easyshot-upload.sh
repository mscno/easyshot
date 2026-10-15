#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Easyshot Capture & Copy Link
# @raycast.mode silent
# @raycast.packageName Easyshot
# @raycast.icon 🔗
# @raycast.description Capture an area, upload it to Easyshot Cloud and copy a shareable link.

set -euo pipefail
open -b no.paraply.easyshot 'easyshot://upload'
