---
name: zoom-out
description: Map an unfamiliar code area before deep work. Use when a task
  touches an unknown subsystem and the agent needs a quick module/caller map
  during Spec Prep, or as bounded helper context under execute-mode.
---

# Zoom Out

Build a compact map of the touched subsystem before detailed changes.

## Inputs

- Current issue contract (description + labels)
- Relevant paths from the ticket/workpad

## Output

Return a short map with:

1. primary modules/files for the behavior
2. main callers and call chain direction
3. persistence/runtime boundaries involved
4. known invariants/contracts to preserve
5. unresolved unknowns that still block implementation

## Rules

- Prefer `rg`-based discovery and focused file reads.
- Keep the map minimal and actionable; avoid full-architecture essays.
- Use existing repo vocabulary from specs/workpad where possible.
- Do not edit product code in this mode.
- If the map reveals ambiguous requirements, hand control back to
  `research-mode`/`plan-mode` for clarification.
