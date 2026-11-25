# Label lists

Hosted lists that Third Party Patcher downloads, so they can be updated without a new release.

## duplicate-labels.json

Groups of Installomator labels that manage the same app. With `IgnoreDuplicateLabels` on (the default), Third Party Patcher keeps each group's `preferred` label and ignores the other members.

- **Choose a different member:** add that label to `RequiredLabels`. It replaces the group's preferred label, and the rest of the group stays ignored.
- **Don't use the list:** set `IgnoreDuplicateLabels` to false.

Each group has a `kind`:

| Kind | Meaning |
|---|---|
| `variant` | Same product, different delivery or release channel. Safe to collapse to one label. |
| `edition` | Different editions of one product (gov, SMB, thin client). The right one depends on the organization. |
| `major` | Major versions that install to the same path, often licensed separately. The preferred label is the newest. |

`reviewedNotListed` records groups that look like duplicates but were left out on purpose: either an existing preference already handles them, or their versions install side by side. The weekly check uses this section so it doesn't flag them again.

### Keeping it current

`.github/workflows/duplicate-labels.yml` runs `check_duplicate_labels.py` every Monday, and on demand from the Actions tab. It compares the list with the tracker's latest `label_status.json` and keeps one **Duplicate label list needs review** issue open for anything new: new duplicate groups, new labels in known groups, and listed labels that no longer exist. It closes that issue once the list covers everything again. The workflow never edits the list, because choosing a preferred label is a human decision.

The same workflow validates the list on every pull request that changes it. To run the checks locally:

```sh
python3 LabelLists/check_duplicate_labels.py validate
curl -sL -o /tmp/label_status.json https://raw.githubusercontent.com/gilburns/Installomator-Tracker/main/label_status.json
python3 LabelLists/check_duplicate_labels.py compare /tmp/label_status.json
```

Groups were first found by matching the app `name` and `expectedTeamID` in [Installomator-Tracker](https://github.com/gilburns/Installomator-Tracker)'s `label_status.json`.
