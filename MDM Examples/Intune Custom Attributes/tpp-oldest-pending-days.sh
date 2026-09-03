#!/bin/bash
#
# Intune Custom Attribute (macOS) — Third Party Patcher
#   Attribute name : TPP - Oldest Pending Update (Days)
#   Data type      : Integer
#
# Age in days of the oldest staged-but-not-applied update. 0 when nothing is
# pending. Useful for device groups that escalate as machines approach the
# deadline.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo ""; exit 0; }

value=$("$patcherreport" get deadline.oldestPendingDays 2>/dev/null)

echo "${value:-0}"
