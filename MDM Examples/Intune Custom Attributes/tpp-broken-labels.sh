#!/bin/bash
#
# Intune Custom Attribute (macOS) — Third Party Patcher
#   Attribute name : TPP - Broken Labels
#   Data type      : Integer
#
# Combined count of scan-broken and stage-broken labels — labels that could
# not be evaluated or repeatedly failed to download. See `patcherreport broken`
# for the list.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo ""; exit 0; }

scan=$("$patcherreport" get scanBrokenCount 2>/dev/null)
stage=$("$patcherreport" get stageBrokenCount 2>/dev/null)

echo "$(( ${scan:-0} + ${stage:-0} ))"
