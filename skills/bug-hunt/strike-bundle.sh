#!/usr/bin/env bash
# strike-bundle.sh — orchestrator evidence strike (BH-S01).
# A bundle is kept only when file_line is set, raw_blob is non-empty, and
# stdout of reproducible_command matches that blob byte for byte.
# tool_use_id is ignored. Exit 0 keep. Exit 1 strike. Exit 2 usage.
# Usage: strike-bundle.sh [--exempt-rerun] --command CMD --raw-file PATH --file-line LOCATOR
# --exempt-rerun keeps a non-empty bundle without the byte compare (M14 Verify wrapper).
set -u

CMD=""
RAW_FILE=""
FILE_LINE=""
EXEMPT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --exempt-rerun)
      EXEMPT=1
      shift
      ;;
    --command)
      CMD="${2:-}"
      shift 2
      ;;
    --raw-file)
      RAW_FILE="${2:-}"
      shift 2
      ;;
    --file-line)
      FILE_LINE="${2:-}"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$CMD" ]; then
  echo "strike: missing reproducible_command" >&2
  exit 1
fi
if [ -z "$FILE_LINE" ]; then
  echo "strike: missing file_line" >&2
  exit 1
fi
if [ -z "$RAW_FILE" ] || [ ! -f "$RAW_FILE" ] || [ ! -s "$RAW_FILE" ]; then
  echo "strike: empty raw_blob" >&2
  exit 1
fi

# M14 Verify bundle: raw_blob is the wrapper output, not a bare re-run.
if [ "$EXEMPT" -eq 1 ]; then
  exit 0
fi

got=$(mktemp "${TMPDIR:-/tmp}/bh-strike.XXXXXX") || exit 2
if ! bash -c "$CMD" >"$got"; then
  echo "strike: reproducible_command failed" >&2
  rm -f "$got"
  exit 1
fi
if ! cmp -s "$RAW_FILE" "$got"; then
  echo "strike: raw_blob does not match re-run" >&2
  rm -f "$got"
  exit 1
fi
rm -f "$got"
exit 0
