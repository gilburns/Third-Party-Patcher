#!/bin/bash
#
# Intune Custom Attribute (macOS) — Third Party Patcher
#   Attribute name : TPP - Pending Updates
#   Data type      : Integer
#
# Number of updates that are staged (downloaded) and waiting to be applied.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo ""; exit 0; }

value=$("$patcherreport" get labelsPending 2>/dev/null)

echo "${value:-0}"
