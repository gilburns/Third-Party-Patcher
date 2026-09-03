#!/bin/bash
#
# Intune Custom Attribute (macOS) — Third Party Patcher
#   Attribute name : TPP - Last Scan
#   Data type      : Date
#
# When the daemon last ran a full Installomator scan. Emitted in ISO-8601
# (UTC), the format Intune expects for a Date attribute. Blank if unknown.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo ""; exit 0; }

value=$("$patcherreport" get lastScan.lastRun 2>/dev/null)

echo "${value}"
