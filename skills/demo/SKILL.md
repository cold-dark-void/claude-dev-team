---
name: demo
description: |
    DEPRECATED — removed at v1.0.0 (CDT-46-C2). Use /setup + /kickoff on a scratch
    project instead, or run a plain /orchestrate walkthrough on any existing project.
---

# /demo removed at v1.0.0 (CDT-46-C2)

The interactive demo skill has been removed as part of the v1.0 feature freeze and
surface-cleanup pass. It required maintaining a separate scaffold and duplicated the
orchestration workflow in a way that drifted from the real agents.

The replacement workflow gives you a real end-to-end run on an actual project rather
than a synthetic stub:

1. Run `/setup` in a scratch repository to initialize the dev-team plugin.
2. Run `/kickoff` with a short ticket description to see PM, Tech Lead, and IC agents
   plan and implement a feature from start to finish.

Alternatively, run `/orchestrate <TICKET-ID> "<description>"` directly in any project
where the plugin is already initialized — this is the same flow `/demo orchestrate`
used to simulate, but with real agents on real code.

This stub disappears at v1.1 once the migration window closes. Until then the skill
file is present so the smoke harness can verify the frontmatter remains valid.
