#!/bin/bash
#
# Intune Custom Attribute (macOS) — Third Party Patcher
#   Attribute name : TPP - Patch Compliance Status
#   Data type      : String
#
# A single rollup verdict for the device, for reporting and device groups:
#
#   Not Installed        Third Party Patcher is not on this device
#   Overdue              a hard deadline has been reached
#   Deadline Approaching pending updates, hard deadline within 3 days
#   Pending              updates staged, deadline not yet close
#   Updates Detected     updates found but nothing staged yet
#   Compliant            nothing outstanding
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo "Not Installed"; exit 0; }

pending=$("$patcherreport" get labelsPending 2>/dev/null)
updateRequired=$("$patcherreport" get updateRequired 2>/dev/null)
hardReached=$("$patcherreport" get deadline.hardDeadlineReached 2>/dev/null)
daysToHard=$("$patcherreport" get deadline.daysUntilHardDeadline 2>/dev/null)

pending=${pending:-0}
updateRequired=${updateRequired:-0}

status="Compliant"
if [[ "$hardReached" == "true" ]]; then
    status="Overdue"
elif (( pending > 0 )) && [[ -n "$daysToHard" ]] && (( daysToHard <= 3 )); then
    status="Deadline Approaching"
elif (( pending > 0 )); then
    status="Pending"
elif (( updateRequired > 0 )); then
    status="Updates Detected"
fi

echo "${status}"
