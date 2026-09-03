#!/bin/bash
#
# Intune Custom Attribute (macOS) — Third Party Patcher
#   Attribute name : TPP - Deadlines Forced (Lifetime)
#   Data type      : Integer
#
# Number of times a hard deadline was reached and an update proceeded without
# the user getting to choose. Counted across all recorded history.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo ""; exit 0; }

value=$("$patcherreport" get totals.deadlinesForced --from deferrals 2>/dev/null)

echo "${value:-0}"
