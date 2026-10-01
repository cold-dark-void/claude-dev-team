/**
 * Untracked paths from `git status --porcelain`. Pure: pass the status text.
 */

function unquote(path) {
  if (path.startsWith('"') && path.endsWith('"') && path.length >= 2) {
    return path.slice(1, -1).replace(/\\"/g, '"').replace(/\\\\/g, '\\')
  }
  return path
}

export function untrackedFromPorcelain(text) {
  const out = []
  const raw = String(text || '')
  const records = raw.includes('\0') ? raw.split('\0') : raw.split('\n')
  for (const line of records) {
    if (!line.startsWith('??')) continue
    const path = unquote(line.slice(3).trim())
    // A directory summary ("?? dir/") is not a file. -uall lists the files.
    if (!path || path.endsWith('/')) continue
    out.push(path)
  }
  return out
}

export function refuteEvidence(porcelain) {
  const files = untrackedFromPorcelain(porcelain)
  const list = files.length ? files.map((f) => `- ${f}`).join('\n') : '(none)'
  return (
    'Also run git status --porcelain and read every ?? path.\n' +
    'Untracked files:\n' +
    list +
    '\n'
  )
}
