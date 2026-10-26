# Domain Glossary (fixture)

Synthetic CDT-589-C1 fixture. It is not a real project glossary. The
`ticket-class.sh` tests point `TICKET_CLASS_GLOSSARY` at this file.

## Terms

| Term | Definition | Avoid (aliases) |
|------|------------|-----------------|
| Same-session | The pin stays shared Same-session via preferences across a token refresh | shared login, reuse-auth |
| `Private-key-material` | Rotated signing bundle for the cross-token signer | keyblob, secret file |
| Widget | Plain non-compound decoy term | gadget |
| api-key | Row whose every hyphen segment is a classifier keyword (D4 drop) | key file |

## Decisions

- 2026-10-26: Column 1 of `## Terms` is the only carve vocabulary — the
  Same-session text in the definition cell above proves it.
