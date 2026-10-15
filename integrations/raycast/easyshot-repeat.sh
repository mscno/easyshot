#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Easyshot Repeat Area
# @raycast.mode silent
# @raycast.packageName Easyshot
# @raycast.icon 📸
# @raycast.description Capture the previous area immediately.

set -euo pipefail
open -b no.paraply.easyshot 'easyshot://repeat'
