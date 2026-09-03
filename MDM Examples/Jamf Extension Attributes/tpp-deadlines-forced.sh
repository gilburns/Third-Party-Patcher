#!/bin/bash
#
# Jamf Pro Extension Attribute — Third Party Patcher
#   Display name : TPP - Deadlines Forced (Lifetime)
#   Data type    : Integer
#   Input type   : Script
#
# Number of times a hard deadline was reached and an update proceeded without
# the user getting to choose. Counted across all recorded history.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo "<result></result>"; exit 0; }

value=$("$patcherreport" get totals.deadlinesForced --from deferrals 2>/dev/null)

echo "<result>${value:-0}</result>"
