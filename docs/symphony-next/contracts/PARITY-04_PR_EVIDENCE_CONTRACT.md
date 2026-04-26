# PARITY-04: PR Evidence Contract

## Purpose

Freeze replacement-scope PR evidence recovery so handoff/review/merge decisions
cannot silently drift when legacy traces are noisy.

`Symphony-next` must recover canonical PR context from legacy-visible signals in
a deterministic order and fail closed when evidence is missing.

## Canonical Output Surface

Resolver output is a normalized map:

- `source` (`workspace_checkpoint` | `workpad` | `issue_comment` | `issue_attachment` | `branch_lookup` | `none`)
- `repo` (`OWNER/REPO` or `null` for fail-closed)
- `pr_number` (positive integer or `null` for fail-closed)
- `url` (`https://github.com/OWNER/REPO/pull/<n>` or `null` for fail-closed)

## Source Order (Deterministic Precedence)

When multiple sources are present, the resolver must choose the first valid
evidence in this fixed order:

1. `workspace_checkpoint`
2. `workpad`
3. `issue_comment`
4. `issue_attachment`
5. `branch_lookup`

## Parsing Rules

1. GitHub PR URL pattern:
   - `https://github.com/<owner>/<repo>/pull/<number>`
2. Marker fallback pattern:
   - `PR #<number>`
3. Marker fallback requires a valid repository hint (`OWNER/REPO`).
4. Attachment source checks URL first, then title/subtitle marker text.

## Fail-Closed Rule

If no valid evidence is found, output must be explicit fail-closed:

- `source=none`
- `repo=null`
- `pr_number=null`
- `url=null`

No guessed PR context is allowed.

## Acceptance Mapping

- `PARITY-04-AM-01`:
  - `workspace_checkpoint` evidence path is executable and green.
- `PARITY-04-AM-02`:
  - `workpad` evidence path is executable and green.
- `PARITY-04-AM-03`:
  - `issue_comment` evidence path is executable and green.
- `PARITY-04-AM-04`:
  - `issue_attachment` evidence path is executable and green.
- `PARITY-04-AM-05`:
  - `branch_lookup` evidence path is executable and green.
- `PARITY-04-AM-06`:
  - precedence scenario is explicit and green.
- `PARITY-04-AM-07`:
  - fail-closed `source=none` scenario is explicit and green.
- `PARITY-04-AM-08`:
  - live-sanitized LET traces run through the same contract runner.
- `PARITY-04-AM-09`:
  - contract document and executable assertions remain aligned.

## Replacement Scope

- Team: `LET`
- Live evidence includes real PR traces from:
  - issue comments,
  - issue attachments,
  - issue branch names resolved to PR via GitHub lookup.

## Sanitization Rules

1. Strip control bytes from raw Linear payload before JSON parsing.
2. Keep only minimal evidence needed for contract checks:
   - sampled issue identifier,
   - sampled branch name,
   - canonical PR URL/number,
   - evidence channel metadata.
3. Do not store full raw comment/workpad history from live issues.

## Evidence Sources

- Deterministic fixture:
  - `elixir/test/fixtures/parity/parity_04_pr_evidence_matrix.json`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_04_pr_evidence_live_sanitized.json`
- Fixture generator:
  - `scripts/generate_parity_04_live_sanitized_fixture.sh`
- Contract resolver:
  - `elixir/lib/symphony_elixir/pr_evidence.ex`
- Executable proof:
  - `elixir/test/symphony_elixir/pr_evidence_parity_test.exs`
