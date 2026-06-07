# Retry preserves workspace continuity

Retry continues the same Issue Run in the same Workspace so branch state, Workpad state, validation context, and Review Evidence lineage remain trustworthy. If the Workspace is missing, stale, or no longer matches the expected execution head, Symphony Runtime must stop with a classified Handoff instead of silently creating a fresh Workspace and presenting that as a retry.
