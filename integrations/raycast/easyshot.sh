#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Easyshot
# @raycast.mode silent
# @raycast.packageName Easyshot
# @raycast.icon 📸
# @raycast.description Open the compact capture bar with the last mode selected.

set -euo pipefail
open -b no.paraply.easyshot 'easyshot://capture'
