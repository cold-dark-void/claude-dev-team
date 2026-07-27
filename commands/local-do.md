---
name: local-do
description: Deprecated — local-agent offload path removed at v1.0.0 (CDT-46-C2).
---

# Local Do — Deprecated

/local-do was removed at v1.0.0 as part of the v1 feature freeze (CDT-46-C2). The local-agent offload path it depended on has been excised entirely.

There is no replacement command. Work that previously went through /local-do should use the normal agent flow: assign the task to an IC agent directly via the orchestrator or /debug ticket.

This stub disappears at v1.1.
