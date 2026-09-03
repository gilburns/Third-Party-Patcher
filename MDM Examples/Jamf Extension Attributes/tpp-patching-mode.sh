#!/bin/bash
#
# Jamf Pro Extension Attribute — Third Party Patcher
#   Display name : TPP - Patching Mode
#   Data type    : String
#   Input type   : Script
#
# "monthly" when a monthly patch-day cadence is configured, otherwise
# "deadline". Blank if the tool is not installed.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo "<result></result>"; exit 0; }

value=$("$patcherreport" get deadline.patchingMode 2>/dev/null)

echo "<result>${value}</result>"
