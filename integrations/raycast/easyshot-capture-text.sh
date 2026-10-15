#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Easyshot Capture Text
# @raycast.mode silent
# @raycast.packageName Easyshot
# @raycast.icon 🔤
# @raycast.description Select an area and copy its text and QR codes, recognized on device.

set -euo pipefail
open -b no.paraply.easyshot 'easyshot://capture-text'
