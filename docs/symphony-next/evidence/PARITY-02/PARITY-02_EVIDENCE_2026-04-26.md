# PARITY-02 Evidence (2026-04-26)

## Scope

- Ticket: `PARITY-02`
- Goal: freeze canonical issue trace contract for comment/workpad/artifact/handoff
  traces with deterministic + live-sanitized executable proof.

## Artifacts

- Contract:
  - `docs/symphony-next/contracts/PARITY-02_ISSUE_TRACE_CONTRACT.md`
- Deterministic matrix fixture:
  - `elixir/test/fixtures/parity/parity_02_issue_trace_matrix.json`
  - SHA256: `93da09bdf616ac11bb0fd02a70e78d1d9b2075cb2e1d939c8dabbdc994ff550e`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_02_issue_trace_live_sanitized.json`
  - Generated at: `2026-04-26T12:21:57Z`
  - SHA256: `20de2ff39618f5a7d171a72a52801fe67ac917adc0d028f98a058b5ca71d3c90`
  - Sample scope:
    - workpad slice (`Codex Workpad`): 3 historical issues
    - handoff slice (`selected_action`): 12 issues
- Fixture generator:
  - `scripts/generate_parity_02_live_sanitized_fixture.sh`
- Executable proof:
  - `elixir/test/symphony_elixir/issue_trace_parity_test.exs`

## Commands Run

```bash
make -C /tmp/symphony-parity-main symphony-preflight
```

Result: `Symphony preflight passed.`

```bash
make -C /tmp/symphony-parity-main symphony-acceptance-preflight
```

Result: `Acceptance capability preflight passed: no explicit required capabilities`

```bash
cd /tmp/symphony-parity-main/elixir && mise exec -- mix format --check-formatted
```

Result: passed (no formatting violations)

```bash
/tmp/symphony-parity-main/scripts/generate_parity_02_live_sanitized_fixture.sh
```

Result: live fixture regenerated successfully with retry/sanitize handling for
intermittent Linear transport failures.

```bash
cd /tmp/symphony-parity-main/elixir && mise exec -- mix test test/symphony_elixir/issue_trace_parity_test.exs test/symphony_elixir/linear_routing_parity_test.exs
```

Result: `4 tests, 0 failures`

## Acceptance Matrix Mapping

- `PARITY-02-AM-01..05`:
  - covered by deterministic matrix runner in
    `issue_trace_parity_test.exs` over
    `parity_02_issue_trace_matrix.json`.
- `PARITY-02-AM-06`:
  - covered by the same runner over live workpad slice cases in
    `parity_02_issue_trace_live_sanitized.json`.
- `PARITY-02-AM-07`:
  - covered by the same runner over live handoff slice cases in
    `parity_02_issue_trace_live_sanitized.json`.
- `PARITY-02-AM-08`:
  - covered by explicit contract fields and trace-channel assertions in
    `PARITY-02_ISSUE_TRACE_CONTRACT.md` and
    `issue_trace_parity_test.exs`.
