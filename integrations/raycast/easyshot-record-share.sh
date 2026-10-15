#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Easyshot Record & Share
# @raycast.mode silent
# @raycast.packageName Easyshot
# @raycast.icon 🎬
# @raycast.description Record an area and copy its Easyshot Cloud link right away; run again to stop.

set -euo pipefail
open -b no.paraply.easyshot 'easyshot://record-share'
