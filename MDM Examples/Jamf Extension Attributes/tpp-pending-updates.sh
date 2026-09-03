#!/bin/bash
#
# Jamf Pro Extension Attribute — Third Party Patcher
#   Display name : TPP - Pending Updates
#   Data type    : Integer
#   Input type   : Script
#
# Number of updates that are staged (downloaded) and waiting to be applied.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo "<result></result>"; exit 0; }

value=$("$patcherreport" get labelsPending 2>/dev/null)

echo "<result>${value:-0}</result>"
