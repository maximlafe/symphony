# Failover does not migrate running sessions

Failover only affects new Coding Agent starts, including retries or continuations that launch fresh agent work. Running sessions stay on the Coding Agent Account they started with, because migrating an active provider session across authenticated accounts would blur session ownership, complicate recovery semantics, and make operator-visible account state misleading.
