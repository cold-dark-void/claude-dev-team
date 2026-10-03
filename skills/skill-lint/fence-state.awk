# fence-state.awk — SPEC-021 rules C6, C8, C9 and C10 for fenced bash blocks.
#
# Pure awk (POSIX features only: no gensub, no match() array, no \s, no {n}
# intervals). check-skill-bash.sh runs this after lint.py and merges both
# reports. It reads the .md files named on the command line and prints one
# TSV line per finding:
#
#   <waived 0|1> TAB <path> TAB <line> TAB <check-id> TAB <message>
#
# Also lint ```sh and ```shell fences (CDT-286 [09 E2]). fence-exec does not.
# A bare assignment here would be an always-true pattern whose default action
# prints every line, so the flag is set once in BEGIN.
BEGIN { fs_shell_aliases = 1 }

# Fence scanning lives in fence-scan.awk (WP 2-01): pass that file first
# (awk -f fence-scan.awk -f fence-state.awk FILE...). It mirrors lint.py
# scan_fences() and calls the three fence_* callbacks defined near the end of
# this file. This file holds no fence-opener match of its own.
#
# C6  assign-before-use. Inside ONE bash fence, a read of $MROOT, $WTROOT,
#     $MEMDB, $PLUGIN_DIR, $PDH or $EXT_DIR that comes before the first
#     assignment of that same name in that fence. Every fence is a separate
#     shell, so the read sees an empty value (MEMDB=/.claude/memory/memory.db)
#     and the skill silently takes its fallback branch. Reads in comments,
#     single quotes and quoted heredoc bodies are not reads. One finding per
#     name per fence. A fence that never assigns the name is C1's job, not
#     C6's; set
#     -v BROAD=1 to report that case too (used only to size the rule).
#     Waivable: "# lint-ok: C6" on the line or the line above (same matching
#     as lint.py).
#
# C8  idiom hazards in a bash fence. Six sub-rules, one per defect class. Each
#     reads the code part of a line: text in comments, single quotes and
#     heredoc bodies is not code (a masked copy of the line, see idiom_scan).
#       (a) grep -c / rg -c followed by "|| echo 0": with no match grep prints
#           0 and exits 1, so the substitution yields "0" newline "0".
#       (b) "$$" in a word that holds TMPDIR or /tmp: a predictable temp path
#           (and a new PID in every Bash-tool call).
#       (c) a bare /tmp/ path (AGENTS.md: use "${TMPDIR:-/tmp}/..." or mktemp).
#       (d) a brace inside a ${VAR:-...} default: the expansion ends at the
#           first }, so ${X:-{}} is "{" followed by a stray "}".
#       (e) a "# Stop here" comment with no exit or return as the next command.
#       (f) git branch -D, reset --hard, clean -f and push --force/--delete.
#     Waivable: "# lint-ok: C8" on the line or the line above.
#
# C9  argument pass-through in a command fence (path commands/*.md only). A
#     Bash-tool fence is a fresh shell with no positional arguments, and Claude
#     Code puts the user text in only where $ARGUMENTS appears.
#       (a) $@ $* $# $1-$9 (also ${1}, ${@:2}) read at the top level of a fence
#           that has not run "set --" (function bodies are exempt: they have
#           their own arguments),
#       (b) an unquoted $ARGUMENTS, or $ARGUMENTS inside an unquoted heredoc:
#           the text is word-split, glob-expanded or executed. Quoted
#           heredoc bodies and double-quoted words are not flagged.
#     Waivable: "# lint-ok: C9" on the line or the line above.
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
# C7 bash-4 / GNU-only constructs (CDT-286), in ```bash, ```sh and ```shell
# fences and — via SH_SCAN (check-skill-bash.sh) — in consumer-shipped .sh
# files under commands/, skills/ and agents/. Flags: declare -A, mapfile,
# readarray, local -n / declare -n, ${x,,} and ${x^^}, [-1] subscripts,
# grep -P, bare `sed -i` (no suffix), `find ... -printf`, `touch -d` and
# `readlink -f`. Scanned text is the code part of the line: comments,
# single- and double-quoted text and heredoc bodies are not constructs.
# Exemptions: the SPEC-002 PDH bootstrap stanza (byte-pinned; its macOS
# behavior is owned by SPEC-002) and skills/skill-lint/fixtures/** (planted
# defects; the fixture dir never reaches this engine). sort -V and xargs -r
# are deliberately not flagged.
#     Waivable: "# lint-ok: C7" on the line or the line above.
#
# C8 (g) `shift N` (N >= 2) at the top level of a fence or .sh file without
#     an arity guard on the same or the previous line (need_arg, a $# -ge/-lt
#     test, require_value, or `shift N ||`): a value-flag loop spins forever
#     when one argument remains (06 F23 / 08 F16). Function bodies are exempt
#     (a function's `shift 2` bounds its own contract).
#
# The scanner tracks quote state across lines within a fence: single quote,
# double quote, $'...' and $( ... ) nesting (a stack, so "$(a "b")" nests).
# It does not model backticks, ${...} operators or case-arm parentheses.

BEGIN {
  FS = "\n"
  n = split("MROOT WTROOT MEMDB PLUGIN_DIR PDH EXT_DIR", nm, " ")
  for (k = 1; k <= n; k++) isname[nm[k]] = 1
  nfind = 0
  have_file = 0
}

FNR == 1 {
  if (have_file) end_file()
  start_file(FILENAME)
}

{
  src[FNR] = $0
  fs_feed($0, FNR)
}

END {
  if (have_file) end_file()
}

function start_file(name) {
  have_file = 1
  fname = name
  split("", src)
  nfind = 0
  # C9 reads only command fences: commands/<name>.md (any root prefix).
  is_cmd = (name ~ /(^|\/)commands\/[^\/]+\.md$/)
  fs_reset()
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
  # C7_ONLY mode (check-skill-bash.sh, .sh scan): every rule funnels through
  # add/add_once/add_sub, so one gate turns the engine into a C7-only pass.
  if (C7_ONLY && id != "C7") return
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

# One finding per line, rule id and sub-rule (C8 holds six sub-rules).
function add_sub(ln, id, sub_id, msg,    key) {
  key = ln SUBSEP id SUBSEP sub_id
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

# Callbacks for fence-scan.awk (the shared fence parser).
# c7_block_first anchors the C8 (g) guard window to the fence that is open —
# src[] spans the whole file, and a guard in one fence must not excuse a
# `shift N` in the next one.
function fence_open(ln, info, is_bash) {
  if (is_bash) {
    c7_block_first = ln
    block_start()
  }
}

function fence_line(line, ln) {
  scan_line(line, ln)
}

function fence_close(ln, is_bash) {
  if (is_bash) block_end()
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
  # C8/C9 state: brace depth and function bodies, top-level "set --", and a
  # "# Stop here" comment that still waits for its exit.
  bd = 0
  nf = 0
  fn_pending = 0
  has_set = 0
  stop_ln = 0
  split("", fnb)
  # C7 PDH-stanza state resets per fence / per .sh file.
  c7_in_pdh = 0
  c7_pdep = 0
}

# Emit C6 findings for the fence that just closed. Uses are kept in order;
# the first use of each name that precedes its first assignment is reported.
function block_end(    u, nmn, reported, before) {
  if (stop_ln > 0) stop_unresolved()
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
    if (is_cmd && name == "ARGUMENTS") args_unquoted(ln, "an unquoted heredoc body")
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
  # C8 (e): the first command after a "# Stop here" comment must be exit/return
  t = trim(line)
  if (stop_ln > 0 && t != "" && t !~ /^#/) {
    if (t ~ /^(exit|return)([ \t;]|$)/) stop_ln = 0
    else stop_unresolved()
  }
  split("", cx)
  cmt = 0
  while (i <= len) {
    c = substr(line, i, 1)
    # context of this character for idiom_scan: S single-quoted, D double-quoted, C code
    cx[i] = (inS || inA) ? "S" : ((top_ctx() == "D") ? "D" : "C")
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
    if (c == "#" && is_wordstart(line, i)) { cmt = i; break }
    if (c == "{" && substr(line, i + 1, 1) ~ /^([ \t]|$)/ && (is_wordstart(line, i) || substr(line, i - 1, 1) == ")")) {
      # a brace group or a function body opens; "{" right after name() starts the body
      if (fn_pending) { nf++; fnb[nf] = bd; fn_pending = 0 }
      bd++
      i++
      continue
    }
    if (c == "}" && is_wordstart(line, i) && substr(line, i + 1, 1) ~ /^([ \t;&|)]|$)/) {
      if (bd > 0) bd--
      if (nf > 0 && bd == fnb[nf]) nf--
      i++
      continue
    }
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
      if (is_wordstart(line, i)) {
        rest = substr(line, i + length(name))
        if (rest ~ /^[ \t]*\([ \t]*\)/ || name == "function") fn_pending = 1
        else if (name == "set" && nf == 0 && rest ~ /^[ \t]+(-[A-Za-z]+[ \t]+)*--([ \t]|$)/) has_set = 1
      }
      i += length(name)
      continue
    }
    i++
  }
  idiom_scan(line, ln, len)
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
    if (name == "ARGUMENTS") args_ref(ln)
    else if (name == "" && substr(line, p, 1) ~ /[1-9@*]/) pos_read(ln, "$" substr(line, p, 1))
    return p + (length(name) > 0 ? length(name) : 1)
  }
  if (nx ~ /[1-9@*#]/) {
    pos_read(ln, "$" nx)
    return i + 2
  }
  if (nx ~ /[A-Za-z_]/) {
    name = ident_at(line, i + 1)
    if (name in isname) use_event(name, ln, i)
    if (name == "ARGUMENTS") args_ref(ln)
    return i + 1 + length(name)
  }
  return i + 2
}

# C9 (a): a positional-parameter read at the top level of a command fence.
function pos_read(ln, tok) {
  if (!is_cmd || nf > 0 || has_set) return
  add_sub(ln, "C9", "a", tok " is read at the top level of a command fence, where it is empty: a Bash-tool fence is a fresh shell with no arguments, and Claude Code puts the user text in only at $ARGUMENTS — read the text through a quoted heredoc (ARGS=$(cat <<'__A__'  $ARGUMENTS  __A__), then set -f; set -- $ARGS; set +f)")
}

# C9 (b): $ARGUMENTS outside a quoted heredoc and outside double quotes.
function args_ref(ln) {
  if (!is_cmd || top_ctx() == "D") return
  args_unquoted(ln, "an unquoted word")
}

function args_unquoted(ln, where) {
  add_sub(ln, "C9", "b", "$ARGUMENTS in " where " is word-split, glob-expanded or executed by the shell — read it through a quoted heredoc (ARGS=$(cat <<'__A__'  $ARGUMENTS  __A__), then set -f; set -- $ARGS; set +f)")
}

# C8 (e): a "# Stop here" comment whose next command is not exit or return.
function stop_unresolved() {
  add_sub(stop_ln, "C8", "e", "a \"# Stop here\" comment is not a stop: the block keeps running after it — put an exit (or return) on the next command")
  stop_ln = 0
}

# C7: one pass over the code part of the line. `masked` blanks comments and
# quoted text (a quoted python lines[-1] is not a bash subscript); `code`
# keeps every character for the guard checks. The PDH stanza (SPEC-002,
# byte-pinned) is skipped whole.
function c7_scan(line, ln, code, masked, cs,    j, ch, m, prev) {
  if (c7_in_pdh) {
    for (j = 1; j <= cs; j++) {
      if (cx[j] != "C") continue
      ch = substr(code, j, 1)
      if (ch == "(") c7_pdep++
      else if (ch == ")") {
        c7_pdep--
        if (c7_pdep <= 0) { c7_in_pdh = 0; break }
      }
    }
    return
  }
  if (code ~ /^[[:space:]]*PDH=\$\(/) {
    # Opener line: enter the stanza, count parens after the opening `$(`.
    c7_in_pdh = 1
    c7_pdep = 1
    for (j = index(code, "$(") + 2; j <= cs; j++) {
      if (cx[j] != "C") continue
      ch = substr(code, j, 1)
      if (ch == "(") c7_pdep++
      else if (ch == ")") c7_pdep--
    }
    return
  }
  if (masked ~ /(^|[;&|(])[[:space:]]*declare[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*A([[:space:]]|$)/)
    add_sub(ln, "C7", "a", "declare -A needs bash 4 (associative arrays) — rewrite with parallel arrays and a linear lookup, or jq/python3 (CDT-285)")
  if (masked ~ /(^|[;&|(])[[:space:]]*(mapfile|readarray)([[:space:]]|$)/)
    add_sub(ln, "C7", "b", "mapfile/readarray needs bash 4 — read with `while IFS= read -r x` into an array (CDT-285)")
  if (masked ~ /(^|[;&|(])[[:space:]]*local[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*n([[:space:]]|$)/ || \
      masked ~ /(^|[;&|(])[[:space:]]*declare[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*n([[:space:]]|$)/)
    add_sub(ln, "C7", "c", "local -n / declare -n (namerefs) need bash 4.3 — pass the value in and print the result, or assign at the call site (CDT-285)")
  if (masked ~ /\$\{[^{}]*(,,|\^\^)/)
    add_sub(ln, "C7", "d", "${var,,}/${var^^} case-modification needs bash 4 — use tr 'A-Z' 'a-z' (CDT-285)")
  if (masked ~ /[A-Za-z0-9})][[:space:]]*\[[[:space:]]*-1[[:space:]]*\]/)
    add_sub(ln, "C7", "e", "a [-1] array subscript needs bash 4.3 — index from ${#arr[@]} - 1 (CDT-285)")
  if (masked ~ /(^|[;&|(])[[:space:]]*grep[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*P([[:space:]]|$)/)
    add_sub(ln, "C7", "f", "grep -P (Perl regex) is GNU-only — use grep -E, awk or python3 (CDT-285)")
  if (masked ~ /(^|[;&|(])[[:space:]]*sed[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-i([[:space:]]|$)/)
    add_sub(ln, "C7", "g", "bare `sed -i` is GNU-only — BSD sed needs a suffix (`sed -i.bak ... && rm -f file.bak`) (CDT-285)")
  if (masked ~ /(^|[;&|(])[[:space:]]*find[[:space:]][^|;&]*-printf([[:space:]]|$)/)
    add_sub(ln, "C7", "h", "`find -printf` is GNU-only — stat the files instead (tests/lib/mtimes.sh find_mtimes) (CDT-285)")
  if (masked ~ /(^|[;&|(])[[:space:]]*touch[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-d([[:space:]]|$)/)
    add_sub(ln, "C7", "i", "`touch -d` is GNU-only — touch -t with a computed timestamp (tests/lib/mtimes.sh) (CDT-285)")
  if (masked ~ /(^|[;&|(])[[:space:]]*readlink[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*f([[:space:]]|$)/)
    add_sub(ln, "C7", "j", "readlink -f is GNU-only — use `cd -P`/pwd, or guard with a realpath fallback (CDT-285)")
}

# C8 (a)-(d), (f) and the start of (e): one scan over the code part of a line.
# cx[] (set in scan_line) says which characters are code (C), double-quoted (D)
# or single-quoted (S); cmt is the column of a trailing comment, or 0.
function idiom_scan(line, ln, len,    j, code, cs, masked, ch, off, rest, pos, p, cut, after, seg, kk, s, e, word, pc, rs, rl, gk, gln, gtxt, guarded, _g_pos, _g_tok, _g_n, _g_after) {
  for (j = 1; j <= len; j++) if (!(j in cx)) cx[j] = (j > 1) ? cx[j - 1] : "C"
  code = (cmt > 1) ? substr(line, 1, cmt - 1) : ((cmt == 1) ? "" : line)
  cs = length(code)
  if (cmt > 0 && stop_ln == 0 && tolower(substr(line, cmt)) ~ /stop here/ && code !~ /(^|[^A-Za-z0-9_])(exit|return)([^A-Za-z0-9_]|$)/)
    stop_ln = ln
  if (cs == 0) {
    c7_scan(line, ln, code, masked, cs)
    return
  }
  masked = ""
  for (j = 1; j <= cs; j++) {
    ch = substr(code, j, 1)
    masked = masked ((cx[j] == "C") ? ch : "_")
  }
  c7_scan(line, ln, code, masked, cs)
  # (a) grep -c / rg -c ... || echo 0
  off = 0
  rest = masked
  while ((pos = index(rest, "||")) > 0) {
    cut = off + pos
    after = substr(code, cut + 2)
    if (after ~ /^[ \t]*echo[ \t]+["']?0["']?([^0-9A-Za-z_.]|$)/) {
      seg = substr(masked, 1, cut - 1)
      for (kk = length(seg); kk >= 1; kk--) {
        ch = substr(seg, kk, 1)
        if (ch == "|" || ch == ";" || ch == "(") break
        if (ch == "&" && ((kk > 1 && substr(seg, kk - 1, 1) == "&") || substr(seg, kk + 1, 1) == "&")) break
      }
      seg = substr(seg, kk + 1)
      if (seg ~ /^[ \t]*(grep|egrep|fgrep|rg)[ \t]/ && (seg ~ /[ \t]-[A-Za-z]*c[A-Za-z]*([ \t]|$)/ || seg ~ /[ \t]--count([ \t]|$)/))
        add_sub(ln, "C8", "a", "grep -c prints 0 and exits 1 when nothing matches, so \"|| echo 0\" yields \"0\" newline \"0\" and breaks -eq tests — use n=$(grep -c ... || true); n=${n:-0}")
    }
    off = cut + 1
    rest = substr(masked, off + 1)
  }
  # (b) "$$" in a word that holds TMPDIR or /tmp
  off = 0
  rest = code
  while ((pos = index(rest, "$$")) > 0) {
    p = off + pos
    if (cx[p] != "S" && (p == 1 || substr(code, p - 1, 1) != "\\")) {
      s = p
      while (s > 1 && substr(code, s - 1, 1) !~ /[ \t]/) s--
      e = p + 1
      while (e < cs && substr(code, e + 1, 1) !~ /[ \t]/) e++
      word = substr(code, s, e - s + 1)
      if (word ~ /TMPDIR/ || word ~ /\/tmp/)
        add_sub(ln, "C8", "b", "$$ in a temp path is predictable (CWE-377) and is a new PID in every Bash-tool call — use mktemp or mktemp -d, and carry the path to later fences as a placeholder")
    }
    off = p + 1
    rest = substr(code, off + 1)
  }
  # (c) a bare /tmp/ path
  off = 0
  rest = code
  while ((pos = index(rest, "/tmp/")) > 0) {
    p = off + pos
    pc = (p == 1) ? "" : substr(code, p - 1, 1)
    if (cx[p] != "S" && (pc == "" || index(" \t\"'=(:<>;&|,`", pc) > 0))
      add_sub(ln, "C8", "c", "bare /tmp/ path — AGENTS.md: write temp files to \"${TMPDIR:-/tmp}/...\" or use mktemp / mktemp -d")
    off = p + 4
    rest = substr(code, off + 1)
  }
  # (d) a brace inside a ${VAR:-...} default
  off = 0
  rest = code
  while (match(rest, /\$\{[A-Za-z_][A-Za-z0-9_]*:?[-=+?]([^}${]|\$[^{}])*\{/)) {
    rs = RSTART
    rl = RLENGTH
    p = off + rs
    if (cx[p] != "S")
      add_sub(ln, "C8", "d", "a brace inside a ${VAR:-...} default ends the expansion at the first } — ${X:-{}} is \"{\" plus a stray \"}\"; assign DEF='{}' first and use ${X:-$DEF}")
    off = p + rl - 1
    rest = substr(code, off + 1)
  }
  # (f) destructive git
  if (match(masked, /(^|[ \t;&|(])git[ \t]+((-[Cc][ \t]+[^ \t]+|--[A-Za-z-]+(=[^ \t]*)?)[ \t]+)*(branch[ \t]+([^|;&]*[ \t])?-D([ \t]|$)|reset[ \t]+([^|;&]*[ \t])?--hard([ \t]|$)|clean[ \t]+([^|;&]*[ \t])?(-[A-Za-z]*f[A-Za-z]*|--force)([ \t]|$)|push[ \t]+([^|;&]*[ \t])?(--force(-with-lease)?(=[^ \t]*)?|-f|--delete|-d)([ \t]|$))/))
    add_sub(ln, "C8", "f", "destructive git (branch -D, reset --hard, clean -f, push --force or --delete) in a fence — route it through skills/lib/git-safety.sh, or waive it on the line above with # lint-ok: C8 and say why it is safe")
  # (g) `shift N` with N >= 2 and no arity guard within the same or the eight
  # previous lines of the same fence, at the top level: a value-flag loop
  # spins forever when one argument remains (06 F23 / 08 F16). A guard is
  # need_arg, require_value, a `$#` comparison against 2, a
  # `[ -z "${2:-}" ]`/`case "${2:-}"` value test, or `shift N ||`. The
  # window spans a whole case arm (its guard sits at the arm's top, several
  # lines above the shift) but never crosses a fence boundary. The number
  # must be >= 2 (`shift 1` cannot hang) and the trailing separator is
  # allowed (`shift 9;` inside `while …; do shift 9; done`). Function
  # bodies bind their own contract and are exempt.
  if (nf == 0 && match(masked, /(^|[^A-Za-z0-9_])[[:space:]]*shift[[:space:]]+[0-9]+/)) {
    _g_pos = RSTART
    _g_tok = substr(masked, _g_pos, RLENGTH)
    match(_g_tok, /[0-9]+/)
    _g_n = substr(_g_tok, RSTART, RLENGTH) + 0
    _g_after = substr(masked, _g_pos + RSTART + RLENGTH, 1)
    if (_g_n >= 2 && (_g_after == "" || index(" \t;&|)", _g_after) > 0)) {
      guarded = 0
      if (code ~ /shift[[:space:]]+[0-9]+[[:space:]]*\|\|/) guarded = 1
      for (gk = 0; gk <= 8 && !guarded; gk++) {
        gln = ln - gk
        if (gln < c7_block_first || !((gln) in src)) break
        gtxt = src[gln]
        if (gtxt ~ /need_arg/ || gtxt ~ /require_value/) guarded = 1
        # `$#` only guards when compared against 2 — a `while [ $# -gt 0 ]`
        # loop head is the hang itself, not an arity guard.
        if (gtxt ~ /\$#[^|;&]*(-ge|-gt|-lt|-eq|-ne)[[:space:]]*2([^0-9]|$)/) guarded = 1
        if (gtxt ~ /\[ -z "\$\{2:-\}" \]/ || gtxt ~ /case "\$\{2:-\}"/) guarded = 1
      }
      if (!guarded)
        add_sub(ln, "C8", "g", "`shift N` (N >= 2) without an arity guard hangs on a trailing value-less flag — call need_arg (or [ $# -ge 2 ] || usage) before shifting")
    }
  }
}

# "#" that starts a word inside an open quote. Report a waiver inside any
# quote, or any "#" while a sqlite3 command is running (the text is SQL).
function hash_in_quote(line, i, ln) {
  if (substr(line, i) ~ /^#[ \t]*lint-ok:/)
    add_once(ln, "C10", "a # lint-ok waiver inside an open quote is string text, not a waiver — it changes the quoted value; put the waiver on its own line above the command, or remove the need for it (for example, assign the variable in this block)")
  else if (sqlite)
    add_once(ln, "C10", "a # inside a quoted sqlite3 SQL argument is SQL text, not a shell comment (parse error) — move the comment onto its own line above the command")
}
