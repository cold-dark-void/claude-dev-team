# SPEC-030 --invoke-flags guard fixtures

Both `guard-test.sh` (a `*-test.sh` Script) and `githooks/pre-push` declare
`--help` in their own text and exit `1` if that flag is ever passed to them.
Run under `--invoke-flags`, each MUST still PASS: `check_sh` MUST NOT invoke
`--help`/`--check` on a test script or a githook, no matter what their text
declares (their bodies mutate state). A regression that invoked either would
flip these fixtures from PASS to FAIL.
