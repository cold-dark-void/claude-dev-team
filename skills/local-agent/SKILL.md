---
name: local-agent
description: Deprecated — local-agent offload engine removed at v1.0.0 (CDT-46-C2).
---

# Local Agent — Deprecated

/local-agent (the internal engine primitive backing /local-do) was removed at v1.0.0 as part of the v1 feature freeze (CDT-46-C2). The run.sh wrapper and emit-orch-metric.sh companion script have been deleted; the skills/local-agent/ directory is retained only for this stub.

There is no replacement skill. Work that previously offloaded to a local model via this engine should be routed through the normal Claude agent flow.

This stub disappears at v1.1.
