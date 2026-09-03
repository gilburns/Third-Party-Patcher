#!/bin/bash
#
# Jamf Pro Extension Attribute — Third Party Patcher
#   Display name : TPP - Pending Update Labels
#   Data type    : String
#   Input type   : Script
#
# Comma-separated list of the Installomator labels that are staged and waiting
# to be applied. Blank when nothing is pending.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo "<result></result>"; exit 0; }

value=$("$patcherreport" pending --csv 2>/dev/null \
        | tail -n +2 \
        | cut -d, -f1 \
        | paste -sd ',' - \
        | sed 's/,/, /g')

echo "<result>${value}</result>"
