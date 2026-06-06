# Triage Labels

The skills speak in terms of five canonical triage roles. This repo maps those roles to Linear workflow statuses rather than standalone labels.

| Role in mattpocock/skills | Linear status | Meaning |
| --- | --- | --- |
| `needs-triage` | `Backlog` | Maintainer needs to evaluate or shape the issue |
| `needs-info` | `Blocked` | Waiting on missing information, access, or human action |
| `ready-for-agent` | `Todo` | Fully specified and ready for Symphony/AFK agent execution |
| `ready-for-human` | `Spec Review` | Requires human review of the prepared spec before execution |
| `wontfix` | `Canceled` | Will not be actioned |

For this repo, labels such as `repo:symphony`, `mode:plan`, `mode:research`, `delivery:tdd`, and `verification:*` are routing or verification labels. Do not treat them as replacements for the triage roles above.
