#!/bin/bash
#
# Intune Custom Attribute (macOS) — Third Party Patcher
#   Attribute name : TPP - Delayed Updates
#   Data type      : Integer
#
# Number of updates found but held back by the update delay (UpdateDelayDays).
# These are not staged or offered to the user until the delay ends.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo ""; exit 0; }

value=$("$patcherreport" get labelsDelayed --from delayed 2>/dev/null)

echo "${value:-0}"
