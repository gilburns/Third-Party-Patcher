#!/bin/bash
#
# Jamf Pro Extension Attribute — Third Party Patcher
#   Display name : TPP - Deferrals (Last 30 Days)
#   Data type    : Integer
#   Input type   : Script
#
# Total dialog deferrals recorded in the last 30 days (user-chosen +
# timer-timeout + blocking-process skips). A persistently high value flags a
# device whose user keeps putting patching off.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo "<result></result>"; exit 0; }

value=$("$patcherreport" get totals.deferrals --from deferrals --days 30 2>/dev/null)

echo "<result>${value:-0}</result>"
