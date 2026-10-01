#!/usr/bin/env bash
# ext-hash.sh — sidecar check before loading a native extension (CDT-492).
# Source only. A missing sidecar allows the load (hand-placed fixtures and
# installs that predate the sidecar). A sidecar that does not match the file
# bytes refuses the load. The sidecar is written only after download-time
# pin verification; it is not a substitute for that pin.
#
#   ext_verify <file>            rc 0 load ok, rc 1 sidecar mismatch
#   ext_write_sidecar <file> <hex>

ext_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$file" | awk '{print $1}'
  else
    return 1
  fi
}

ext_verify() {
  local file="${1-}" side want actual
  [ -n "$file" ] && [ -f "$file" ] || return 0
  side="${file}.sha256"
  [ -f "$side" ] || return 0
  want=$(tr -d '[:space:]' < "$side" | tr 'A-F' 'a-f') || return 1
  [ -n "$want" ] || return 1
  actual=$(ext_sha256 "$file" | tr 'A-F' 'a-f') || return 1
  [ "$actual" = "$want" ]
}

ext_write_sidecar() {
  local file="${1-}" hex="${2-}" dir tmp
  [ -n "$file" ] && [ -n "$hex" ] || return 1
  dir=$(dirname -- "$file")
  tmp=$(mktemp "$dir/.sha.XXXXXX") || return 1
  printf '%s\n' "$hex" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f "$tmp" "${file}.sha256"
}
