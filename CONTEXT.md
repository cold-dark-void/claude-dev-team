# Domain Glossary

Project ubiquitous language. Prefer these terms in code, specs, tickets, and
agent output. Do not reintroduce avoided aliases.

## Terms

| Term | Definition | Avoid (aliases) |
|------|------------|-----------------|
| Surface | Any user-invocable command or skill; the unit of the v1 stability contract | command (when skills are included), feature |
| Deprecation stub | A one-cycle command file whose only behavior is printing its replacement, shipped because marketplace auto-latest makes silent removal user-visible breakage | alias, shim |
