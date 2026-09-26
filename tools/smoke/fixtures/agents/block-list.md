---
name: smoke-block-list
description: A fixture agent whose tools field is a YAML block sequence (PASS).
tools:
  - Read
  - Bash
model: sonnet
effort: medium
---

This agent's `tools` value is a YAML block sequence, not a flat scalar.
