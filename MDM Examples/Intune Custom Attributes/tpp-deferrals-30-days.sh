#!/bin/bash
#
# Intune Custom Attribute (macOS) — Third Party Patcher
#   Attribute name : TPP - Deferrals (Last 30 Days)
#   Data type      : Integer
#
# Total dialog deferrals recorded in the last 30 days (user-chosen +
# timer-timeout + blocking-process skips). A persistently high value flags a
# device whose user keeps putting patching off.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo ""; exit 0; }

value=$("$patcherreport" get totals.deferrals --from deferrals --days 30 2>/dev/null)

echo "${value:-0}"
