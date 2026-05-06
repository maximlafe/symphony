---
name: tdd
description: LET-native red/green protocol for `delivery:tdd` tasks. Use when
  execution requires deterministic failing proof before code changes and
  matching green proof on the same behavior path.
---

# TDD

Apply red -> green for the changed core behavior only.

## Goal

For `delivery:tdd` tasks, produce explicit failing proof before the fix and
explicit passing proof after the fix, then carry it through cheap/final gates.

## Loop

1. Define the smallest observable behavior that must change.
2. Create `red proof`:
   - targeted deterministic test/reproducer that fails for the current behavior.
3. Implement the smallest change to satisfy the behavior.
4. Create `green proof`:
   - rerun the same behavior proof and show it passes.
5. Run required surrounding checks for the touched change class.

## LET Contract Rules

- Treat `delivery:tdd` as opt-in delivery semantics, not intake routing.
- Scope TDD to cheap deterministic core behavior; validate broader runtime shell
  through the normal matrix.
- Reflect proofs in workpad validation/proof mapping consistently with
  `Acceptance Matrix`.
- Do not mark required red proof as `n/a` when `delivery:tdd` applies.
- Preserve behavior contracts while refactoring; refactor is optional.

## Forbidden

- Do not write broad speculative tests before defining current behavior.
- Do not claim TDD completion without explicit red and green evidence.
- Do not substitute CI-only status for local red/green proof.
