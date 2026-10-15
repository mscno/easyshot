#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Easyshot Restore Last Capture
# @raycast.mode silent
# @raycast.packageName Easyshot
# @raycast.icon 🗂️
# @raycast.description Bring back the most recently closed Quick Access card.

set -euo pipefail
open -b no.paraply.easyshot 'easyshot://restore-overlay'
