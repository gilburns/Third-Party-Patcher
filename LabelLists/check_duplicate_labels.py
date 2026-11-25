#!/usr/bin/env python3
"""Validate duplicate-labels.json and compare it with Installomator-Tracker data.

    check_duplicate_labels.py validate
    check_duplicate_labels.py compare label_status.json [--report report.md]

validate exits 1 when the list is malformed. compare prints a Markdown report of what
needs review (new duplicate groups, new members of known groups, listed labels that no
longer exist) and exits 0; with --report it also writes the report to that file, and
writes nothing when there is nothing to review. Picking a preferred label stays a human
decision, so compare never edits the list.

Duplicates are found the same way the list was first built: labels that share an app
`name` and `expectedTeamID`.
"""

import argparse
import collections
import json
import sys
from pathlib import Path

LIST_PATH = Path(__file__).with_name("duplicate-labels.json")
KINDS = {"variant", "edition", "major"}


def load_list():
    with LIST_PATH.open(encoding="utf-8") as f:
        return json.load(f)


def validate(doc):
    """Returns a list of problems; empty when the list is well formed."""
    problems = []
    if doc.get("schemaVersion") != 1:
        problems.append("schemaVersion must be 1.")
    seen_ids, seen_labels = set(), {}
    for section in ("groups", "reviewedNotListed"):
        for entry in doc.get(section, []):
            gid = entry.get("id", "?")
            if gid in seen_ids:
                problems.append(f"{section}: id '{gid}' is used more than once.")
            seen_ids.add(gid)
            members = entry.get("members", [])
            if len(members) < 2:
                problems.append(f"{section}/{gid}: needs at least two members.")
            for label in members:
                if label in seen_labels:
                    problems.append(f"{section}/{gid}: '{label}' is also in '{seen_labels[label]}'.")
                seen_labels[label] = gid
            if section == "groups":
                if entry.get("kind") not in KINDS:
                    problems.append(f"groups/{gid}: kind must be one of {sorted(KINDS)}.")
                if entry.get("preferred") not in members:
                    problems.append(f"groups/{gid}: preferred '{entry.get('preferred')}' is not a member.")
            elif not entry.get("reason"):
                problems.append(f"reviewedNotListed/{gid}: needs a reason.")
    return problems


def tracker_groups(items):
    """Labels sharing an app name and Team ID, keyed by (name, teamID)."""
    groups = collections.defaultdict(set)
    for item in items:
        name = item.get("name") or ""
        if name:
            groups[(name, item.get("expectedTeamID") or "")].add(item["label"])
    return {key: labels for key, labels in groups.items() if len(labels) > 1}


def compare(doc, items):
    """Returns Markdown sections describing what needs review; empty when nothing does."""
    known = {item["label"] for item in items}
    entries = [(s, e) for s in ("groups", "reviewedNotListed") for e in doc.get(s, [])]
    owner = {label: (s, e) for s, e in entries for label in e["members"]}

    new_groups, new_members = [], []
    for (name, team), labels in sorted(tracker_groups(items).items(), key=lambda kv: kv[0][0].lower()):
        listed = {owner[label][1]["id"] for label in labels if label in owner}
        unlisted = sorted(labels - owner.keys())
        if not listed:
            new_groups.append(f"- **{name}** (`{team}`): {', '.join(f'`{l}`' for l in sorted(labels))}")
        elif unlisted:
            ids = ", ".join(f"`{i}`" for i in sorted(listed))
            new_members.append(f"- **{name}** ({ids}): {', '.join(f'`{l}`' for l in unlisted)} not listed yet")

    missing = []
    for section, entry in entries:
        for label in entry["members"]:
            if label not in known:
                note = " — **this is the preferred label**" if entry.get("preferred") == label else ""
                missing.append(f"- `{label}` in {section}/`{entry['id']}`{note}")

    sections = []
    if new_groups:
        sections.append("### New duplicate groups\nChoose a preferred label, or add the group to "
                        "`reviewedNotListed` with a reason.\n\n" + "\n".join(new_groups))
    if new_members:
        sections.append("### New labels in known groups\n" + "\n".join(new_members))
    if missing:
        sections.append("### Listed labels no longer in Installomator\n" + "\n".join(missing))
    return sections


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    cmp = sub.add_parser("compare")
    cmp.add_argument("tracker", type=Path, help="Installomator-Tracker label_status.json")
    cmp.add_argument("--report", type=Path, help="Write the report here when there is something to review.")
    args = parser.parse_args()

    doc = load_list()
    problems = validate(doc)
    if problems:
        print("duplicate-labels.json has problems:\n" + "\n".join(f"- {p}" for p in problems))
        return 1
    if args.command == "validate":
        print(f"duplicate-labels.json is valid: {len(doc['groups'])} groups, "
              f"{len(doc['reviewedNotListed'])} reviewed and not listed.")
        return 0

    with args.tracker.open(encoding="utf-8") as f:
        items = json.load(f)
    sections = compare(doc, items)
    if not sections:
        print("Nothing to review: the list covers every duplicate group in the tracker data.")
        return 0
    report = ("The weekly check found Installomator label changes that "
              "`LabelLists/duplicate-labels.json` doesn't cover yet.\n\n" + "\n\n".join(sections) + "\n")
    print(report)
    if args.report:
        args.report.write_text(report, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
