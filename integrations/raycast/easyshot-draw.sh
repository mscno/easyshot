#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Easyshot Draw New Area
# @raycast.mode silent
# @raycast.packageName Easyshot
# @raycast.icon 📸
# @raycast.description Draw anywhere and capture on release.

set -euo pipefail
open -b no.paraply.easyshot 'easyshot://draw'
