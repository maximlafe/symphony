# PARITY-01 Evidence (2026-04-26)

## Scope

- Ticket: `PARITY-01`
- Goal: freeze canonical Linear routing contract with fixture-backed and live-sanitized executable proof.

## Artifacts

- Contract:
  - `docs/symphony-next/contracts/PARITY-01_LINEAR_ROUTING_CONTRACT.md`
- Deterministic matrix fixture:
  - `elixir/test/fixtures/parity/parity_01_linear_routing_matrix.json`
  - SHA256: `4467a66eafdf7213e73baab78d6cee369987f8b1f5c297cb3f35e0a81783522f`
- Live-sanitized fixture:
  - `elixir/test/fixtures/parity/parity_01_linear_routing_live_sanitized.json`
  - Generated at: `2026-04-26T11:47:28Z`
  - SHA256: `84312fe5a6dbbf7db9dda720a764f48003ad147b7bbc5f8b61b152c5d1c00e95`
- Fixture generator:
  - `scripts/generate_parity_01_live_sanitized_fixture.sh`

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
cd /tmp/symphony-parity-main/elixir && mise exec -- mix test test/symphony_elixir/linear_routing_parity_test.exs
```

Result: `2 tests, 0 failures`

```bash
/tmp/symphony-parity-main/scripts/generate_parity_01_live_sanitized_fixture.sh
```

Result: generated live fixture with 11 sanitized cases.

## Acceptance Matrix Mapping

- `PARITY-01-AM-01..06`: covered by `linear_routing_parity_test.exs` over deterministic matrix fixture.
- `PARITY-01-AM-07`: covered by `linear_routing_parity_test.exs` over live-sanitized fixture generated from LET team scope.
- `PARITY-01-AM-08`: covered by contract + matrix consistency in shared matrix runner (same deterministic rules applied to both fixture sets).
