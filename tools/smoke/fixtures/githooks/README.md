# SPEC-030 githook fixture

`pre-commit` fails `bash -n` (unclosed `if`) -> FAIL naming the file.

Do not pass this README as an explicit `run.sh` target: `classify()`
treats any file whose parent directory is `githooks` as a Script
(parent-directory match, not extension-based), so this README would be
checked as a Script and fail `bash -n` too. It exists for documentation
only and is excluded from live no-arg discovery (the `fixtures` path
segment).
