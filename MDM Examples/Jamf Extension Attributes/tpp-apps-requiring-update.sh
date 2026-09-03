#!/bin/bash
#
# Jamf Pro Extension Attribute — Third Party Patcher
#   Display name : TPP - Apps Requiring Update
#   Data type    : Integer
#   Input type   : Script
#
# Number of managed apps the last check found to be out of date (whether or
# not the update has been staged yet).
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo "<result></result>"; exit 0; }

value=$("$patcherreport" get updateRequired 2>/dev/null)

echo "<result>${value:-0}</result>"
