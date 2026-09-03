#!/bin/bash
#
# Jamf Pro Extension Attribute — Third Party Patcher
#   Display name : TPP - Days Until Hard Deadline
#   Data type    : Integer
#   Input type   : Script
#
# Whole days from now until the hard deadline, after which no further
# deferrals are allowed and the update is forced. Negative once the deadline
# has passed. Blank when nothing is pending or DeadlineDaysHard is 0.
#

patcherreport="/usr/local/bin/tpp/patcherreport"
[[ -x "$patcherreport" ]] || { echo "<result></result>"; exit 0; }

value=$("$patcherreport" get deadline.daysUntilHardDeadline 2>/dev/null)

echo "<result>${value}</result>"
