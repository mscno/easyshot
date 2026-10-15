#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Easyshot Paste as Link
# @raycast.mode silent
# @raycast.packageName Easyshot
# @raycast.icon 📎
# @raycast.description Upload the image on your clipboard and replace it with a shareable link. Works over SSH.

set -euo pipefail
open -b no.paraply.easyshot 'easyshot://paste-upload'
