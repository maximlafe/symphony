# Require issue-scoped cleanup boundaries

Symphony Runtime only treats the exact retained Workspace and explicitly namespaced Issue-Scoped Artifacts as eligible for per-Issue cleanup. Broad shared paths, caches, and un-namespaced temporary files stay outside terminal cleanup because cleanup must be safe to run automatically without deleting state that belongs to other Issues, operators, or shared runtime homes.
