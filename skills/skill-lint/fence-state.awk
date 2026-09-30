# fence-state.awk — SPEC-021 rules C6 and C10 for fenced bash blocks.
#
# Pure awk (POSIX features only: no gensub, no match() array, no \s, no {n}
# intervals). check-skill-bash.sh runs this after lint.py and merges both
# reports. It reads the .md files named on the command line and prints one
# TSV line per finding:
#
#   <waived 0|1> TAB <path> TAB <line> TAB <check-id> TAB <message>
#
# Fence scanning mirrors lint.py scan_fences(): an opening fence is a line
# that starts (after blanks) with 3 or more backticks; it closes on a line
# with at least as many backticks and no info string; a fence is bash when
# the first word of its info string is exactly "bash".
#
# C6  assign-before-use. Inside ONE bash fence, a read of $MROOT, $WTROOT,
#     $MEMDB or $PLUGIN_DIR that comes before the first assignment of that
#     same name in that fence. Every fence is a separate shell, so the read
#     sees an empty value (MEMDB=/.claude/memory/memory.db) and the skill
#     silently takes its fallback branch. Reads in comments, single quotes
#     and quoted heredoc bodies are not reads. One finding per name per
#     fence. A fence that never assigns the name is C1's job, not C6's; set
#     -v BROAD=1 to report that case too (used only to size the rule).
#     Waivable: "# lint-ok: C6" on the line or the line above (same matching
#     as lint.py).
#
# C10 comment and waiver placement. Text after a backslash-newline joins the
#     next line into the command, and text inside an open quote is part of
#     the string, so a "# lint-ok: ..." waiver or any "#" comment written
#     there changes the command instead of annotating it. Flags:
#       (a) a backslash followed by blanks and then end of line or "#"
#           (an escaped space, not a continuation),
#       (b) a "#" comment line directly after a line that ends in "\" (the
#           command ends at the comment; the next line runs on its own),
#       (c) "# lint-ok:" inside any open quote, and a "#" that starts a
#           word inside an open quote while a sqlite3 command is running
#           (the "#" is SQL text).
#     NOT waivable: a waiver there would re-hide the defect.
#     Text inside heredoc bodies is not scanned by C10.
#
# The scanner tracks quote state across lines within a fence: single quote,
# double quote, $'...' and $( ... ) nesting (a stack, so "$(a "b")" nests).
# It does not model backticks, ${...} operators or case-arm parentheses.

BEGIN {
  FS = "\n"
  n = split("MROOT WTROOT MEMDB PLUGIN_DIR", nm, " ")
  for (k = 1; k <= n; k++) isname[nm[k]] = 1
  ticks = 0
  nfind = 0
  have_file = 0
}

FNR == 1 {
  if (have_file) end_file()
  start_file(FILENAME)
}

{
  src[FNR] = $0
  process_line($0, FNR)
}

END {
  if (have_file) end_file()
}

function start_file(name) {
  have_file = 1
  fname = name
  split("", src)
  nfind = 0
  ticks = 0
  is_bash = 0
}

# Waiver match mirrors lint.py WAIVER_RE: "#", blanks, "lint-ok:", then the
# longest run of [A-Za-z0-9, blanks]; the run is split on commas and each
# token trimmed, then compared to the check id exactly.
function waived_on(ln, id,    s, rest, m, toks, t, k, cnt) {
  if (ln < 1 || !(ln in src)) return 0
  s = src[ln]
  if (!match(s, /#[ \t]*lint-ok:/)) return 0
  rest = substr(s, RSTART + RLENGTH)
  match(rest, /^[A-Za-z0-9, \t]*/)
  m = substr(rest, 1, RLENGTH)
  cnt = split(m, toks, ",")
  for (k = 1; k <= cnt; k++) {
    t = toks[k]
    gsub(/^[ \t]+|[ \t]+$/, "", t)
    if (t == id) return 1
  }
  return 0
}

function add(ln, id, msg) {
  nfind++
  fl[nfind] = ln
  fid[nfind] = id
  fmsg[nfind] = msg
}

function add_once(ln, id, msg,    key) {
  key = ln SUBSEP id
  if (key in seen_find) return
  seen_find[key] = 1
  add(ln, id, msg)
}

function end_file(    i, j, t, order, w) {
  # stable insertion sort by line number
  for (i = 1; i <= nfind; i++) order[i] = i
  for (i = 2; i <= nfind; i++) {
    t = order[i]
    j = i - 1
    while (j >= 1 && fl[order[j]] > fl[t]) { order[j + 1] = order[j]; j-- }
    order[j + 1] = t
  }
  for (i = 1; i <= nfind; i++) {
    j = order[i]
    w = 0
    if (fid[j] != "C10") {
      if (waived_on(fl[j], fid[j]) || waived_on(fl[j] - 1, fid[j])) w = 1
    }
    printf "%d\t%s\t%d\t%s\t%s\n", w, fname, fl[j], fid[j], fmsg[j]
  }
  split("", seen_find)
  have_file = 0
}

function trim(s) {
  gsub(/^[ \t]+|[ \t]+$/, "", s)
  return s
}

function process_line(line, ln,    run, info, rest, tok) {
  if (ticks == 0) {
    if (match(line, /^[ \t]*```+/)) {
      run = substr(line, RSTART, RLENGTH)
      sub(/^[ \t]*/, "", run)
      ticks = length(run)
      info = trim(substr(line, RSTART + RLENGTH))
      split(info, tok, /[ \t]+/)
      is_bash = (info != "" && tok[1] == "bash")
      if (is_bash) block_start()
    }
    return
  }
  if (match(line, /^[ \t]*```+/)) {
    run = substr(line, RSTART, RLENGTH)
    sub(/^[ \t]*/, "", run)
    rest = trim(substr(line, RSTART + RLENGTH))
    if (length(run) >= ticks && rest == "") {
      if (is_bash) block_end()
      ticks = 0
      is_bash = 0
      return
    }
  }
  if (is_bash) scan_line(line, ln)
}

function block_start() {
  depth = 0
  inS = 0
  inA = 0
  sqlite = 0
  hd_tag = ""
  hd_quoted = 0
  hd_pending = ""
  hd_pending_q = 0
  prevcont = 0
  nuse = 0
  split("", fdl)
  split("", fdc)
  split("", stk)
  split("", pdep)
}

# Emit C6 findings for the fence that just closed. Uses are kept in order;
# the first use of each name that precedes its first assignment is reported.
function block_end(    u, nmn, reported, before) {
  split("", reported)
  for (u = 1; u <= nuse; u++) {
    nmn = uname[u]
    if (nmn in reported) continue
    if (nmn in fdl) {
      before = (ulin[u] < fdl[nmn]) || (ulin[u] == fdl[nmn] && ucol[u] < fdc[nmn])
      if (before) {
        reported[nmn] = 1
        add(ulin[u], "C6", "$" nmn " is used before it is assigned in this bash block (first assignment at line " fdl[nmn] ") — every block is a separate shell; assign " nmn " earlier in the same block (MROOT, then WTROOT, then MEMDB)")
      }
    } else if (BROAD + 0) {
      reported[nmn] = 1
      add(ulin[u], "C6", "$" nmn " is used in a block that never assigns it")
    }
  }
}

function use_event(name, ln, col) {
  nuse++
  uname[nuse] = name
  ulin[nuse] = ln
  ucol[nuse] = col
}

function def_event(name, ln, col) {
  if (!(name in fdl)) { fdl[name] = ln; fdc[name] = col }
}

# Name token at position p of s ("" when none).
function ident_at(s, p,    r) {
  r = substr(s, p)
  if (match(r, /^[A-Za-z_][A-Za-z0-9_]*/)) return substr(r, 1, RLENGTH)
  return ""
}

# Body line of an UNQUOTED heredoc: it expands $NAME, so count the reads.
# (Assignments in a body are text, never definitions.)
function scan_heredoc_uses(line, ln,    p, rest, name, j) {
  p = 1
  while ((j = index(substr(line, p), "$")) > 0) {
    p += j
    rest = substr(line, p, 1)
    if (rest == "{") {
      name = ident_at(line, p + 1)
      if (name in isname) use_event(name, ln, p - 1)
    } else {
      name = ident_at(line, p)
      if (name in isname) use_event(name, ln, p - 1)
    }
  }
}

function top_ctx() {
  return (depth > 0) ? stk[depth] : "N"
}

function push_ctx(c) {
  depth++
  stk[depth] = c
  pdep[depth] = 0
}

function is_wordstart(line, i,    pc) {
  if (i == 1) return 1
  pc = substr(line, i - 1, 1)
  return (pc == " " || pc == "\t" || pc == ";" || pc == "&" || pc == "|" || pc == "(")
}

function scan_line(line, ln,    len, i, c, top, nx, name, rest, j, q, tag, cont, pc, t) {
  if (hd_tag != "") {
    t = trim(line)
    if (t == hd_tag) { hd_tag = ""; return }
    if (!hd_quoted) scan_heredoc_uses(line, ln)
    return
  }
  len = length(line)
  i = 1
  cont = 0
  # C10 (b): a comment line right after a continuation backslash
  if (prevcont && line ~ /^[ \t]*#/)
    add_once(ln, "C10", "a # comment line after a \\ continuation joins the command line and ends it; the next line then runs as its own command — move the comment above the command")
  prevcont = 0
  while (i <= len) {
    c = substr(line, i, 1)
    if (inS) {
      if (c == "'") inS = 0
      else if (c == "#" && (i == 1 || substr(line, i - 1, 1) == " " || substr(line, i - 1, 1) == "\t"))
        hash_in_quote(line, i, ln)
      i++
      continue
    }
    if (inA) {
      if (c == "\\") { i += 2; continue }
      if (c == "'") inA = 0
      i++
      continue
    }
    top = top_ctx()
    if (top == "D") {
      if (c == "\\") {
        rest = substr(line, i + 1)
        if (rest ~ /^[ \t]+($|#)/)
          add_once(ln, "C10", "a backslash followed by blanks is an escaped space, not a line continuation; the command ends at this line — end the line with \\ and nothing else, and put any waiver or comment on its own line above the command")
        i += 2
        continue
      }
      if (c == "\"") { depth--; i++; continue }
      if (c == "$") {
        nx = substr(line, i + 1, 1)
        if (nx == "(") { push_ctx("P"); i += 2; continue }
        i = note_dollar(line, i, ln)
        continue
      }
      if (c == "#" && (i == 1 || substr(line, i - 1, 1) == " " || substr(line, i - 1, 1) == "\t"))
        hash_in_quote(line, i, ln)
      i++
      continue
    }
    # code context (top-level "N" or inside $( ... ) "P")
    if (c == "\\") {
      rest = substr(line, i + 1)
      if (rest == "") { cont = 1; i++; continue }
      if (rest ~ /^[ \t]+($|#)/)
        add_once(ln, "C10", "a backslash followed by blanks is an escaped space, not a line continuation; the command ends at this line — end the line with \\ and nothing else, and put any waiver or comment on its own line above the command")
      i += 2
      continue
    }
    if (c == "'") { inS = 1; i++; continue }
    if (c == "\"") { push_ctx("D"); i++; continue }
    if (c == "#" && is_wordstart(line, i)) break
    if (c == "$") {
      nx = substr(line, i + 1, 1)
      if (nx == "'") { inA = 1; i += 2; continue }
      if (nx == "(") { push_ctx("P"); i += 2; continue }
      i = note_dollar(line, i, ln)
      continue
    }
    if (c == "(") { if (top == "P") pdep[depth]++; i++; continue }
    if (c == ")") {
      if (top == "P") {
        if (pdep[depth] > 0) pdep[depth]--
        else { depth--; sqlite = 0 }
      } else sqlite = 0
      i++
      continue
    }
    if (c == ";" || c == "&" || c == "|") { sqlite = 0; i++; continue }
    if (c == "<" && substr(line, i, 2) == "<<" && substr(line, i + 2, 1) != "<" && (i == 1 || substr(line, i - 1, 1) != "<")) {
      j = i + 2
      if (substr(line, j, 1) == "-") j++
      while (substr(line, j, 1) == " " || substr(line, j, 1) == "\t") j++
      q = substr(line, j, 1)
      hd_q = 0
      if (q == "'" || q == "\"" || q == "\\") { hd_q = 1; j++ }
      tag = ident_at(line, j)
      if (tag != "") {
        if (hd_pending == "") { hd_pending = tag; hd_pending_q = hd_q }
        i = j + length(tag)
        if (hd_q && (substr(line, i, 1) == "'" || substr(line, i, 1) == "\"")) i++
        continue
      }
      i += 2
      continue
    }
    if (c ~ /[A-Za-z_]/ && (i == 1 || substr(line, i - 1, 1) !~ /[A-Za-z0-9_]/)) {
      name = ident_at(line, i)
      nx = substr(line, i + length(name), 1)
      if (name == "sqlite3" && nx !~ /[-.A-Za-z0-9_]/) sqlite = 1
      else if ((name in isname) && is_wordstart(line, i)) {
        if (nx == "=" || (nx == "+" && substr(line, i + length(name) + 1, 1) == "="))
          def_event(name, ln, i)
      }
      i += length(name)
      continue
    }
    i++
  }
  # end of line
  if (hd_pending != "") { hd_tag = hd_pending; hd_quoted = hd_pending_q; hd_pending = "" }
  if (!inS && !inA && top_ctx() != "D") {
    if (cont) prevcont = 1
    else sqlite = 0
  }
}

# A "$" at position i in code or double-quote context: record a read of a
# tracked name, or a ${NAME:=...} default-assignment; return the next index.
function note_dollar(line, i, ln,    nx, p, name, after) {
  nx = substr(line, i + 1, 1)
  if (nx == "{") {
    p = i + 2
    while (substr(line, p, 1) == "!" || substr(line, p, 1) == "#") p++
    name = ident_at(line, p)
    if (name in isname) {
      after = substr(line, p + length(name), 2)
      if (after ~ /^:?=/) def_event(name, ln, i)
      else use_event(name, ln, i)
    }
    return p + (length(name) > 0 ? length(name) : 1)
  }
  if (nx ~ /[A-Za-z_]/) {
    name = ident_at(line, i + 1)
    if (name in isname) use_event(name, ln, i)
    return i + 1 + length(name)
  }
  return i + 2
}

# "#" that starts a word inside an open quote. Report a waiver inside any
# quote, or any "#" while a sqlite3 command is running (the text is SQL).
function hash_in_quote(line, i, ln) {
  if (substr(line, i) ~ /^#[ \t]*lint-ok:/)
    add_once(ln, "C10", "a # lint-ok waiver inside an open quote is string text, not a waiver — it changes the quoted value; put the waiver on its own line above the command, or remove the need for it (for example, assign the variable in this block)")
  else if (sqlite)
    add_once(ln, "C10", "a # inside a quoted sqlite3 SQL argument is SQL text, not a shell comment (parse error) — move the comment onto its own line above the command")
}
