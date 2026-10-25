#!/bin/bash
#
# Intune Custom Attribute (macOS) — Third Party Patcher
#   Attribute name : TPP - Delayed Update Labels
#   Data type      : String
#
# Comma-separated list of the Installomator labels whose update is held back by
# the update delay (UpdateDelayDays). Blank when nothing is delayed.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo ""; exit 0; }

value=$("$patcherreport" delayed --csv 2>/dev/null \
        | tail -n +2 \
        | cut -d, -f1 \
        | paste -sd ',' - \
        | sed 's/,/, /g')

echo "${value}"
