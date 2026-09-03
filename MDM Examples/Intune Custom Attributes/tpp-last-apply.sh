#!/bin/bash
#
# Intune Custom Attribute (macOS) — Third Party Patcher
#   Attribute name : TPP - Last Apply
#   Data type      : Date
#
# When the daemon last ran an apply (install) pass. Emitted in ISO-8601 (UTC),
# the format Intune expects for a Date attribute. Blank if it has never
# applied an update on this device.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo ""; exit 0; }

value=$("$patcherreport" get lastApply.lastRun 2>/dev/null)

echo "${value}"
