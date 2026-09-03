#!/bin/bash
#
# Jamf Pro Extension Attribute — Third Party Patcher
#   Display name : TPP - Last Scan
#   Data type    : Date
#   Input type   : Script
#
# When the daemon last ran a full Installomator scan (UTC).
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo "<result></result>"; exit 0; }

iso=$("$patcherreport" get lastScan.lastRun 2>/dev/null)

value=""
if [[ -n "$iso" ]]; then
    value=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
fi

echo "<result>${value}</result>"
