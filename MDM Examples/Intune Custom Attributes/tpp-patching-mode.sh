#!/bin/bash
#
# Intune Custom Attribute (macOS) — Third Party Patcher
#   Attribute name : TPP - Patching Mode
#   Data type      : String
#
# "monthly" when a monthly patch-day cadence is configured, otherwise
# "deadline". Blank if the tool is not installed.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo ""; exit 0; }

value=$("$patcherreport" get deadline.patchingMode 2>/dev/null)

echo "${value}"
