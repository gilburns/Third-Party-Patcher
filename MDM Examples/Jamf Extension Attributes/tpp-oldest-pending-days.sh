#!/bin/bash
#
# Jamf Pro Extension Attribute — Third Party Patcher
#   Display name : TPP - Oldest Pending Update (Days)
#   Data type    : Integer
#   Input type   : Script
#
# Age in days of the oldest staged-but-not-applied update. 0 when nothing is
# pending. Useful for smart groups that escalate as devices approach the
# deadline.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo "<result></result>"; exit 0; }

value=$("$patcherreport" get deadline.oldestPendingDays 2>/dev/null)

echo "<result>${value:-0}</result>"
