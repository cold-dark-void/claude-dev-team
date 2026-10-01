# fence-check.awk — engine of the fence-exec harness (SPEC-030 R23+, CDT-272).
#
# Pure awk (POSIX features only: no gensub, no match() array, no \s, no {n}
# intervals, no whole-array delete). tools/fence-exec/run.sh runs it on the
# shared fence parser:
#
#   FE_DUMP=<dir> awk -f skills/skill-lint/fence-scan.awk -f fence-check.awk FILE...
#
# It prints one TSV row per record. The first field is the record kind:
#
#   F <file> <start> <end> <heading> <info> <idx> <template 0|1>
#       every bash fence (start and end are its first and last body line,
#       heading is the nearest heading above it, idx names the dump file).
#       When FE_DUMP names a directory, the body of fence <idx> is written to
#       <FE_DUMP>/<idx>.sh so that run.sh can run `bash -n` on it (F1).
#       <template> is 1 when the second word of the info string is exactly
#       "template" (the smoke.py is_template_fence rule). The engine owns that
#       rule: F2-F4 use it here, and run.sh reads this flag for F1.
#   X <check> <file> <line> <start> <heading> <message>
#       one finding of F2, F3 or F4
#   P <file> <line> <start> <heading> <kind> <path>
#       one path literal that run.sh resolves against the repo (F5)
#
# Checks done here (each fence is a fresh shell, so each rule is per fence):
#   F2  a function that another fence of the same file defines is called in a
#       fence that does not define it ("command not found" at run time)
#   F3  `trap ... EXIT` in a fence that is not a script body: it fires when
#       this fence's shell exits, not at the end of the whole procedure
#   F4  `return` outside a function body
#   F5  $PDH/<path>, $PLUGIN_DIR/<path> and `plugin-dir.sh file|dir <path>`
#       literals (emitted as P rows; run.sh checks that the path exists)
#
# Known limit of F4: a function whose body is a subshell, `name() ( ... )`, is
# not read as a function body, so a `return` inside it is reported. Write the
# body with braces.
#
# The lexer (lex_line) is a small shell tokenizer: it tracks single and double
# quotes, $'...', $( ... ), ( ... ), heredoc bodies, comments and the command
# position of each word. It is not a full shell parser. A line it cannot read
# leaves the rest of the fence unchecked. Apart from the limit above, it
# reports only what it reads.
# fence-state.awk (skill-lint C6, C8, C9, C10) holds its own quote scanner because it
# needs character-level events; this lexer needs word-level events.

BEGIN {
  gidx = 0
  have_file = 0
  fe_dump = ENVIRON["FE_DUMP"]
  redir_fd_ok = 0
}

FNR == 1 {
  if (have_file) end_file()
  start_file(FILENAME)
}

{
  fs_feed($0, FNR)
}

END {
  if (have_file) end_file()
}

function start_file(name) {
  have_file = 1
  fname = name
  fs_reset()
  fnum = 0
  split("", fstart)
  split("", fhead)
  split("", fshebang)
  split("", ncall)
  split("", callname)
  split("", callline)
  split("", isdef)
  split("", defany)
  split("", defline)
  split("", fread)
  split("", ntrap)
  split("", trapline)
  split("", trapact)
}

# ---- fence-scan.awk callbacks ------------------------------------------

function fence_open(ln, info, is_bash) {
  if (!is_bash) return
  fnum++
  gidx++
  cur_info = info
  split(info, itok, /[ \t]+/)
  cur_template = (itok[2] == "template")
  cur_start = ln + 1
  cur_last = ln
  fstart[fnum] = cur_start
  fhead[fnum] = fs_head
  fshebang[fnum] = 0
  ncall[fnum] = 0
  ntrap[fnum] = 0
  seen_body = 0
  cur_pdir = ""
  lx_reset()
  dumpfile = ""
  if (fe_dump != "") {
    dumpfile = fe_dump "/" gidx ".sh"
    printf "" > dumpfile
  }
}

function fence_line(line, ln,    was_body) {
  cur_last = ln
  if (!seen_body && line !~ /^[ \t]*$/) {
    seen_body = 1
    if (line ~ /^#!/) fshebang[fnum] = 1
  }
  if (dumpfile != "") print line > dumpfile
  was_body = (hd_tag != "")
  cur_ln = ln
  lex_line(line, ln)
  if (!was_body && line !~ /^[ \t]*#/) scan_paths(line, ln)
}

function fence_close(ln, is_bash) {
  if (!is_bash) return
  if (dumpfile != "") { close(dumpfile); dumpfile = "" }
  printf "F\t%s\t%d\t%d\t%s\t%s\t%d\t%d\n", fname, cur_start, cur_last, fs_clean(fhead[fnum]), fs_clean(cur_info), gidx, cur_template + 0
}

# A TSV field must not hold a tab or a newline, and must not be empty: run.sh
# reads the rows with IFS=tab, which collapses an empty field.
function fs_clean(s) {
  gsub(/[\t\n]/, " ", s)
  if (s == "") s = "-"
  return s
}

function finding(check, ln, n, msg) {
  printf "X\t%s\t%s\t%d\t%d\t%s\t%s\n", check, fname, ln, fstart[n], fs_clean(fhead[n]), fs_clean(msg)
}

# ---- per-file evaluation (F2, F3) --------------------------------------

function end_file(    n, k, nm, ln, act, pure, vars, nv, v, other, m, why) {
  # F2: a call to a function that only another fence defines
  for (n = 1; n <= fnum; n++) {
    for (k = 1; k <= ncall[n]; k++) {
      nm = callname[n, k]
      if ((nm in defany) && !((n, nm) in isdef)) {
        finding("F2", callline[n, k], n, "`" nm "` is called here but only another fence of this file defines it (line " defline[nm] "); every fence is a fresh shell, so the call fails with command not found — define the function in this fence, or move it into a script that the fence runs")
      }
    }
  }
  # F3: trap ... EXIT outside a script-body fence
  for (n = 1; n <= fnum; n++) {
    if (fshebang[n]) continue
    for (k = 1; k <= ntrap[n]; k++) {
      act = trapact[n, k]
      ln = trapline[n, k]
      why = ""
      if (!trap_is_cleanup(act)) {
        why = "its action is more than a plain rm of temporary files, so whatever it guards is released when this fence ends"
      } else {
        nv = trap_vars(act, vars)
        for (v = 1; v <= nv; v++) {
          for (m = 1; m <= fnum; m++) {
            if (m != n && ((m, vars[v]) in fread)) { why = "it deletes $" vars[v] " when this fence ends, and the fence at line " fstart[m] " still reads it"; break }
          }
          if (why != "") break
        }
      }
      if (why != "")
        finding("F3", ln, n, "trap ... EXIT runs when this fence's shell exits, not when the whole procedure ends: " why " — run the cleanup explicitly at the end of the procedure, or keep all work in one fence")
    }
  }
  have_file = 0
}

# The action of a trap is plain cleanup when every command in it is rm, rmdir,
# true or : (redirections and quotes ignored).
function trap_is_cleanup(act,    s, parts, np, i, w, rest) {
  s = act
  if (s ~ /^'.*'$/ || s ~ /^".*"$/) s = substr(s, 2, length(s) - 2)
  gsub(/[0-9]*>&[0-9]+|[0-9]*>>?[ \t]*[^ \t;&|]+/, " ", s)
  gsub(/&&|\|\|/, ";", s)
  np = split(s, parts, ";")
  for (i = 1; i <= np; i++) {
    rest = parts[i]
    sub(/^[ \t]+/, "", rest)
    if (rest == "") continue
    match(rest, /^[^ \t]+/)
    w = substr(rest, RSTART, RLENGTH)
    if (w != "rm" && w != "rmdir" && w != "true" && w != ":") return 0
  }
  return 1
}

# Names of the variables the action expands ($NAME or ${NAME}), into out[].
function trap_vars(act, out,    n, s, r, name) {
  n = 0
  s = act
  while (match(s, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
    r = substr(s, RSTART, RLENGTH)
    sub(/^\$\{?/, "", r)
    name = r
    n++
    out[n] = name
    s = substr(s, RSTART + RLENGTH)
  }
  return n
}

# ---- lexer ---------------------------------------------------------------

function lx_reset() {
  depth = 0
  inS = 0
  inA = 0
  wtext = ""
  wplain = 1
  wstarted = 0
  wcmd = 0
  wline = 0
  cmdstart = 1
  hd_tag = ""
  hd_quoted = 0
  hd_pending = ""
  hd_pending_q = 0
  redir = 0
  redir_keep = 0
  case_hdr = 0
  in_pat = 0
  case_depth = 0
  fn_pending = 0
  fn_name_expect = 0
  bd = 0
  fn_n = 0
  trap_on = 0
  trap_n = 0
  lastcmd_name = ""
  lastcmd_k = 0
  split("", stk)
  split("", sv_wtext)
  split("", sv_wplain)
  split("", sv_wcmd)
  split("", sv_wline)
  split("", sv_cmdstart)
  split("", sv_kind)
  split("", fstack)
  split("", trap_args)
}

function wstart() {
  if (!wstarted) { wstarted = 1; wcmd = cmdstart; wline = cur_ln }
}

function wadd(s) {
  wtext = wtext s
}

function wreset() {
  wtext = ""
  wplain = 1
  wstarted = 0
  wcmd = 0
}

function finish_word() {
  if (!wstarted) return
  if (wplain == 1 && wtext ~ /^[0-9]+$/ && redir_fd_ok) { wreset(); return }
  emit_word(wtext, wplain, wcmd, wline)
  wreset()
}

function sep() {
  if (trap_on) finalize_trap()
  cmdstart = 1
  redir = 0
  lastcmd_name = ""
}

function push_ctx(kind, sv_kind_v) {
  depth++
  stk[depth] = kind
  sv_wtext[depth] = wtext
  sv_wplain[depth] = wplain
  sv_wcmd[depth] = wcmd
  sv_wline[depth] = wline
  sv_cmdstart[depth] = cmdstart
  sv_kind[depth] = sv_kind_v
  if (kind == "P") {
    wtext = ""
    wplain = 1
    wstarted = 0
    wcmd = 0
    cmdstart = 1
  }
}

# Leave a $( ... ) or ( ... ) context: the enclosing word continues.
function pop_paren(    kind) {
  finish_word()
  if (trap_on) finalize_trap()
  kind = sv_kind[depth]
  wtext = sv_wtext[depth] "$(...)"
  wplain = 0
  wstarted = 1
  wcmd = sv_wcmd[depth]
  wline = sv_wline[depth]
  cmdstart = sv_cmdstart[depth]
  depth--
  if (kind == "sub") {
    # a ( ... ) subshell is a command on its own, not a word
    wreset()
    cmdstart = 0
  }
}

function top_ctx() {
  return (depth > 0) ? stk[depth] : "N"
}

function ident_at(s, p,    r) {
  r = substr(s, p)
  if (match(r, /^[A-Za-z_][A-Za-z0-9_]*/)) return substr(r, 1, RLENGTH)
  return ""
}

function note_read(name) {
  fread[fnum, name] = 1
}

# Body line of an UNQUOTED heredoc: it expands $NAME, so count the reads.
function heredoc_reads(line,    p, j, name) {
  p = 1
  while ((j = index(substr(line, p), "$")) > 0) {
    p += j
    if (substr(line, p, 1) == "{") name = ident_at(line, p + 1)
    else name = ident_at(line, p)
    if (name != "") note_read(name)
  }
}

# A "$" at position i in code or double-quote context. Returns the next index.
function dollar(line, i,    nx, p, name, d, c, len) {
  len = length(line)
  nx = substr(line, i + 1, 1)
  if (nx == "(") {
    if (substr(line, i + 2, 1) == "(") {
      # $(( ... )) arithmetic: opaque
      d = 0
      p = i + 2
      while (p <= len) {
        c = substr(line, p, 1)
        if (c == "(") d++
        else if (c == ")") { d--; if (d == 0) break }
        p++
      }
      wstart()
      wadd("$((..))")
      wplain = 0
      return p + 1
    }
    wstart()
    wplain = 0
    push_ctx("P", "cmdsub")
    return i + 2
  }
  if (nx == "{") {
    # ${ ... }: opaque, counting nested braces; a read of the leading name
    wstart()
    wplain = 0
    p = i + 2
    while (substr(line, p, 1) == "!" || substr(line, p, 1) == "#") p++
    name = ident_at(line, p)
    if (name != "") note_read(name)
    d = 1
    p = i + 2
    while (p <= len) {
      c = substr(line, p, 1)
      if (c == "{") d++
      else if (c == "}") { d--; if (d == 0) break }
      p++
    }
    wadd(substr(line, i, p - i + 1))
    return p + 1
  }
  if (nx ~ /[A-Za-z_]/) {
    name = ident_at(line, i + 1)
    note_read(name)
    wstart()
    wplain = 0
    wadd("$" name)
    return i + 1 + length(name)
  }
  wstart()
  wplain = 0
  wadd("$" nx)
  return i + 2
}

# Next non-blank text after position p is ")".
function close_paren_follows(line, p) {
  return (substr(line, p) ~ /^[ \t]*\)/)
}

function lex_line(line, ln,    len, i, c, nx, top, j, q, tag, cont, rest, k) {
  if (hd_tag != "") {
    if (fs_trim(line) == hd_tag) hd_tag = ""
    else if (!hd_quoted) heredoc_reads(line)
    return
  }
  len = length(line)
  i = 1
  cont = 0
  while (i <= len) {
    c = substr(line, i, 1)
    if (inS) {
      if (c == "'") inS = 0
      wadd(c)
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
      if (c == "\\") { wadd(substr(line, i, 2)); i += 2; continue }
      if (c == "\"") { depth--; wadd(c); i++; continue }
      if (c == "$") { i = dollar(line, i); continue }
      wadd(c)
      i++
      continue
    }
    # code context: "N" (top level) or "P" (inside $( ... ) or ( ... ))
    if (c == "\\") {
      rest = substr(line, i + 1)
      if (rest == "") { cont = 1; i++; continue }
      wstart()
      wplain = 0
      wadd(substr(line, i, 2))
      i += 2
      continue
    }
    if (c == " " || c == "\t") { finish_word(); i++; continue }
    if (c == "'") { wstart(); wplain = 0; inS = 1; wadd(c); i++; continue }
    if (c == "\"") { wstart(); wplain = 0; push_ctx("D", "dq"); wadd(c); i++; continue }
    if (c == "`") {
      wstart()
      wplain = 0
      j = index(substr(line, i + 1), "`")
      if (j == 0) { i = len + 1 } else { wadd("`..`"); i += j + 1 }
      continue
    }
    if (c == "#" && !wstarted) break
    if (c == "$") {
      if (substr(line, i + 1, 1) == "'") { wstart(); wplain = 0; inA = 1; i += 2; continue }
      i = dollar(line, i)
      continue
    }
    if (c == ";") {
      finish_word()
      if (substr(line, i + 1, 1) == ";") {
        i += 2
        if (substr(line, i, 1) == "&") i++
        if (case_depth > 0) in_pat = 1
        sep()
        continue
      }
      if (substr(line, i + 1, 1) == "&") i++
      i++
      sep()
      continue
    }
    if (c == "&") {
      if (substr(line, i + 1, 1) == ">") {
        # &> and &>> redirect both streams
        finish_word()
        i += 2
        if (substr(line, i, 1) == ">") i++
        redir = 1
        redir_keep = cmdstart
        continue
      }
      finish_word()
      i++
      if (substr(line, i, 1) == "&") i++
      sep()
      continue
    }
    if (c == "|") {
      finish_word()
      if (in_pat) { i++; continue }
      i++
      if (substr(line, i, 1) == "|" || substr(line, i, 1) == "&") i++
      sep()
      continue
    }
    if (c == "<" || c == ">") {
      # a fd number before the operator (2>file) is not a word
      redir_fd_ok = 1
      finish_word()
      redir_fd_ok = 0
      if (c == "<" && substr(line, i, 3) == "<<<") { i += 3; redir = 1; redir_keep = cmdstart; continue }
      if (c == "<" && substr(line, i, 2) == "<<") {
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
      if (substr(line, i + 1, 1) == "(") {
        # process substitution <( ... ) and >( ... )
        wstart()
        wplain = 0
        push_ctx("P", "cmdsub")
        i += 2
        continue
      }
      nx = substr(line, i + 1, 1)
      i++
      if (nx == c || nx == "|" || (c == "<" && nx == ">")) i++
      if (substr(line, i, 1) == "&") {
        i++
        k = 0
        while (substr(line, i, 1) ~ /[0-9-]/) { i++; k++ }
        if (k > 0) continue
      }
      redir = 1
      redir_keep = cmdstart
      continue
    }
    if (c == "(") {
      finish_word()
      if (fn_pending && close_paren_follows(line, i + 1)) {
        # function foo () { ... }: the () pair
        match(substr(line, i + 1), /^[ \t]*\)/)
        i += RLENGTH + 1
        continue
      }
      if (lastcmd_name != "" && close_paren_follows(line, i + 1)) {
        # name() { ... }: a function definition, not a call
        ncall[fnum]--
        register_def(lastcmd_name, ln)
        match(substr(line, i + 1), /^[ \t]*\)/)
        i += RLENGTH + 1
        lastcmd_name = ""
        cmdstart = 1
        fn_pending = 1
        continue
      }
      if (in_pat) { i++; continue }
      if (cmdstart && substr(line, i + 1, 1) == "(") {
        # (( ... )) arithmetic command: opaque
        j = i + 2
        k = 0
        while (j <= len) {
          q = substr(line, j, 1)
          if (q == "(") k++
          else if (q == ")") { if (k == 0) break; k-- }
          j++
        }
        i = j + 2
        cmdstart = 0
        continue
      }
      push_ctx("P", "sub")
      i++
      continue
    }
    if (c == ")") {
      finish_word()
      if (in_pat) { in_pat = 0; cmdstart = 1; i++; continue }
      if (top == "P") pop_paren()
      i++
      continue
    }
    if (c != "(") lastcmd_name = ""
    wstart()
    wadd(c)
    i++
  }
  # end of line
  if (inS || inA || top_ctx() == "D") {
    wadd(" ")
    return
  }
  finish_word()
  if (hd_pending != "") { hd_tag = hd_pending; hd_quoted = hd_pending_q; hd_pending = "" }
  if (!cont && !in_pat) sep()
}

function register_def(name, ln) {
  if (cur_template) return
  isdef[fnum, name] = ln
  if (!(name in defany)) { defany[name] = 1; defline[name] = ln }
}

function emit_word(text, plain, cmdpos, ln,    eq) {
  lastcmd_name = ""
  if (redir) { redir = 0; cmdstart = redir_keep; return }
  if (in_pat) {
    if (plain && text == "esac") { case_depth--; in_pat = 0; cmdstart = 0 }
    return
  }
  if (trap_on) { trap_n++; trap_args[trap_n] = text; return }
  if (!cmdpos) {
    if (case_hdr && plain && text == "in") { case_hdr = 0; in_pat = 1; case_depth++ }
    else if (fn_name_expect) {
      fn_name_expect = 0
      register_def(text, ln)
      fn_pending = 1
      cmdstart = 1
    }
    return
  }
  if (text ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) { cmdstart = 1; return }
  if (!plain) { cmdstart = 0; return }
  if (text == "if" || text == "then" || text == "elif" || text == "else" || text == "while" || text == "until" || text == "do" || text == "!" || text == "time") { cmdstart = 1; return }
  if (text == "{") {
    bd++
    if (fn_pending) { fn_n++; fstack[fn_n] = bd; fn_pending = 0 }
    cmdstart = 1
    return
  }
  if (text == "}") {
    if (fn_n > 0 && fstack[fn_n] == bd) fn_n--
    if (bd > 0) bd--
    cmdstart = 0
    return
  }
  if (text == "fi" || text == "done" || text == "for" || text == "select") { cmdstart = 0; return }
  if (text == "case") { case_hdr = 1; cmdstart = 0; return }
  if (text == "esac") { if (case_depth > 0) case_depth--; cmdstart = 0; return }
  if (text == "function") { fn_name_expect = 1; cmdstart = 0; return }
  if (text == "return") {
    if (fn_n == 0 && !cur_template)
      finding("F4", ln, fnum, "`return` outside a function: a fence is neither a function nor a sourced script, so bash stops with return: can only return from a function or sourced script — use exit, or restructure the fence")
    cmdstart = 0
    return
  }
  if (text == "trap") { trap_on = 1; trap_n = 0; trap_line = ln; cmdstart = 0; return }
  cmdstart = 0
  if (!cur_template && text ~ /^[A-Za-z_][A-Za-z0-9_-]*$/) {
    ncall[fnum]++
    callname[fnum, ncall[fnum]] = text
    callline[fnum, ncall[fnum]] = ln
    lastcmd_name = text
  }
}

function finalize_trap(    a, k, s, act, sigs, has_exit) {
  trap_on = 0
  a = 1
  if (trap_n >= 1 && trap_args[1] == "--") a = 2
  if (trap_n - a + 1 < 2) return
  act = trap_args[a]
  if (act == "-" || act == "''" || act == "\"\"") return
  has_exit = 0
  for (k = a + 1; k <= trap_n; k++) {
    s = trap_args[k]
    if (s == "EXIT" || s == "0" || s == "'EXIT'" || s == "\"EXIT\"") has_exit = 1
  }
  if (!has_exit || cur_template) return
  ntrap[fnum]++
  trapline[fnum, ntrap[fnum]] = trap_line
  trapact[fnum, ntrap[fnum]] = act
}

# ---- F5: path literals ---------------------------------------------------

# Emit one P row. kind: root (repo-relative), file, dir.
function emit_path(kind, path, ln) {
  sub(/[.,;:]+$/, "", path)
  if (path == "") return
  printf "P\t%s\t%d\t%d\t%s\t%s\t%s\n", fname, ln, fstart[fnum], fs_clean(fhead[fnum]), kind, path
}

# A literal path token starts at p. Returns the token, or "" when the token
# is not a literal (a placeholder, a glob or an expansion follows it).
function literal_at(line, p,    r, tok, nx) {
  r = substr(line, p)
  if (substr(r, 1, 1) == "\"" || substr(r, 1, 1) == "'") r = substr(r, 2)
  if (!match(r, /^[A-Za-z0-9_.\/+-]+/)) return ""
  tok = substr(r, 1, RLENGTH)
  nx = substr(r, RLENGTH + 1, 1)
  if (nx == "$" || nx == "<" || nx == ">" || nx == "*" || nx == "?" || nx == "{" || nx == "[" || nx == "`" || nx == "\\" || nx == "(") return ""
  return tok
}

function scan_paths(line, ln,    s, ms, ml, tok, kind, pre, dirpart) {
  # plugin-dir.sh file|dir <path>
  s = line
  while (match(s, /plugin-dir\.sh"? +(file|dir) +/)) {
    ms = RSTART
    ml = RLENGTH
    pre = substr(s, ms, ml)
    kind = (pre ~ / dir +$/) ? "dir" : "file"
    tok = literal_at(s, ms + ml)
    if (tok != "") {
      emit_path(kind, tok, ln)
      if (kind == "dir" && line ~ /PLUGIN_DIR=/) {
        dirpart = tok
        if (sub(/\/[^\/]*$/, "", dirpart) == 0) dirpart = "."
        cur_pdir = dirpart
      }
    }
    s = substr(s, ms + ml)
  }
  # $PDH/<path>, ${PDH}/<path>, $CLAUDE_PLUGIN_ROOT/<path>, $PLUGIN_ROOT/<path>
  s = line
  while (match(s, /\$(\{(PDH|CLAUDE_PLUGIN_ROOT|PLUGIN_ROOT)\}|PDH|CLAUDE_PLUGIN_ROOT|PLUGIN_ROOT)"?\//)) {
    ms = RSTART
    ml = RLENGTH
    tok = literal_at(s, ms + ml)
    if (tok != "") emit_path("root", tok, ln)
    s = substr(s, ms + ml)
  }
  # $PLUGIN_DIR/<leaf>: resolved against the directory the same fence gave it
  s = line
  while (match(s, /\$(\{PLUGIN_DIR\}|PLUGIN_DIR)"?\//)) {
    ms = RSTART
    ml = RLENGTH
    tok = literal_at(s, ms + ml)
    if (tok != "" && cur_pdir != "") emit_path("root", cur_pdir "/" tok, ln)
    s = substr(s, ms + ml)
  }
}
