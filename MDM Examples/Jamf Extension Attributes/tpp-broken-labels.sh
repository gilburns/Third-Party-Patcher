#!/bin/bash
#
# Jamf Pro Extension Attribute — Third Party Patcher
#   Display name : TPP - Broken Labels
#   Data type    : Integer
#   Input type   : Script
#
# Combined count of scan-broken and stage-broken labels — labels that could
# not be evaluated or repeatedly failed to download. See `patcherreport broken`
# for the list.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo "<result></result>"; exit 0; }

scan=$("$patcherreport" get scanBrokenCount 2>/dev/null)
stage=$("$patcherreport" get stageBrokenCount 2>/dev/null)

echo "<result>$(( ${scan:-0} + ${stage:-0} ))</result>"
