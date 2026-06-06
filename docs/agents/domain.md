# Domain Docs

How engineering skills should consume this repo's domain documentation.

## Layout

This repo uses a single-context layout.

Read these when they exist:

- `CONTEXT.md` at the repo root for domain vocabulary and project concepts.
- `docs/adr/` at the repo root for architectural decisions relevant to the work.

If these files do not exist, proceed silently. Do not block on creating them.

## Vocabulary

When output names a domain concept, use the term as defined in `CONTEXT.md`. If the concept is missing, note the gap rather than inventing conflicting terminology.

## ADR conflicts

If a proposed change contradicts an existing ADR, surface the conflict explicitly instead of silently overriding the decision.
