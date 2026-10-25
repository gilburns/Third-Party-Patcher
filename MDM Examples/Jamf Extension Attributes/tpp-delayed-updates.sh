#!/bin/bash
#
# Jamf Pro Extension Attribute — Third Party Patcher
#   Display name : TPP - Delayed Updates
#   Data type    : Integer
#   Input type   : Script
#
# Number of updates found but held back by the update delay (UpdateDelayDays).
# These are not staged or offered to the user until the delay ends.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo "<result></result>"; exit 0; }

value=$("$patcherreport" get labelsDelayed --from delayed 2>/dev/null)

echo "<result>${value:-0}</result>"
