#!/bin/bash
#
# Jamf Pro Extension Attribute — Third Party Patcher
#   Display name : TPP - Delayed Update Labels
#   Data type    : String
#   Input type   : Script
#
# Comma-separated list of the Installomator labels whose update is held back by
# the update delay (UpdateDelayDays). Blank when nothing is delayed.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo "<result></result>"; exit 0; }

value=$("$patcherreport" delayed --csv 2>/dev/null \
        | tail -n +2 \
        | cut -d, -f1 \
        | paste -sd ',' - \
        | sed 's/,/, /g')

echo "<result>${value}</result>"
