#!/bin/bash
#
# Intune Custom Attribute (macOS) — Third Party Patcher
#   Attribute name : TPP - Pending Update Labels
#   Data type      : String
#
# Comma-separated list of the Installomator labels that are staged and waiting
# to be applied. Blank when nothing is pending.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo ""; exit 0; }

value=$("$patcherreport" pending --csv 2>/dev/null \
        | tail -n +2 \
        | cut -d, -f1 \
        | paste -sd ',' - \
        | sed 's/,/, /g')

echo "${value}"
