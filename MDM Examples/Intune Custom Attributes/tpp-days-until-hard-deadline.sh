#!/bin/bash
#
# Intune Custom Attribute (macOS) — Third Party Patcher
#   Attribute name : TPP - Days Until Hard Deadline
#   Data type      : Integer
#
# Whole days from now until the hard deadline, after which no further
# deferrals are allowed and the update is forced. Negative once the deadline
# has passed. Blank when nothing is pending or DeadlineDaysHard is 0.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo ""; exit 0; }

value=$("$patcherreport" get deadline.daysUntilHardDeadline 2>/dev/null)

echo "${value}"
