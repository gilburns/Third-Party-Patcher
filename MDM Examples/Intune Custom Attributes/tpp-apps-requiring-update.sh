#!/bin/bash
#
# Intune Custom Attribute (macOS) — Third Party Patcher
#   Attribute name : TPP - Apps Requiring Update
#   Data type      : Integer
#
# Number of managed apps the last check found to be out of date (whether or
# not the update has been staged yet).
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo ""; exit 0; }

value=$("$patcherreport" get updateRequired 2>/dev/null)

echo "${value:-0}"
