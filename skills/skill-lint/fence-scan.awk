# fence-scan.awk — the one fenced-block scanner for the awk engines.
#
# Pure awk (POSIX features only: no gensub, no match() array, no \s, no {n}
# intervals). awk has no include, so pass this file first:
#
#   awk -f fence-scan.awk -f <engine>.awk FILE...
#
# Users today: skills/skill-lint/fence-state.awk (C6, C10) and
# tools/fence-exec/fence-check.awk (F2-F5 and the fence list). Do not write a
# second fence-opener match in an engine; call fs_feed() instead.
#
# Fence rules mirror lint.py scan_fences(): an opening fence is a line that
# starts (after blanks) with 3 or more backticks; it closes on a line with at
# least as many backticks and no info string; a fence is bash when the first
# word of its info string is exactly "bash". While a fence is open, a line
# that starts with backticks and holds an info string is content, so a
# ```bash example inside a ````markdown template is text, not a fence.
#
# Caller contract:
#   fs_reset()            call on the first line of every file
#   fs_feed(line, ln)     call for every line of the file, in order
# The engine defines three callbacks (an engine that needs no hook defines an
# empty function; awk rejects a call to an undefined function):
#   fence_open(ln, info, is_bash)   the opening fence line, any language
#   fence_line(line, ln)            one body line of a BASH fence (delimiters
#                                   excluded; other languages never call it)
#   fence_close(ln, is_bash)        the closing fence line
# State the engine may read:
#   fs_head / fs_head_ln  text and line number of the latest ATX heading seen
#                         outside every fence ("" and 0 before the first)
#   fs_info               info string of the fence that is open now

function fs_trim(s) {
  gsub(/^[ \t]+|[ \t]+$/, "", s)
  return s
}

function fs_reset() {
  fs_ticks = 0
  fs_bash = 0
  fs_info = ""
  fs_head = ""
  fs_head_ln = 0
}

function fs_feed(line, ln,    run, info, rest, tok) {
  if (fs_ticks == 0) {
    if (match(line, /^[ \t]*```+/)) {
      run = substr(line, RSTART, RLENGTH)
      sub(/^[ \t]*/, "", run)
      fs_ticks = length(run)
      info = fs_trim(substr(line, RSTART + RLENGTH))
      split(info, tok, /[ \t]+/)
      fs_bash = (info != "" && tok[1] == "bash")
      fs_info = info
      fence_open(ln, info, fs_bash)
      return
    }
    if (line ~ /^#+[ \t]/) {
      fs_head = fs_trim(line)
      sub(/^#+[ \t]+/, "", fs_head)
      fs_head_ln = ln
    }
    return
  }
  if (match(line, /^[ \t]*```+/)) {
    run = substr(line, RSTART, RLENGTH)
    sub(/^[ \t]*/, "", run)
    rest = fs_trim(substr(line, RSTART + RLENGTH))
    if (length(run) >= fs_ticks && rest == "") {
      fence_close(ln, fs_bash)
      fs_ticks = 0
      fs_bash = 0
      fs_info = ""
      return
    }
  }
  if (fs_bash) fence_line(line, ln)
}
