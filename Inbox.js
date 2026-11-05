.pragma library

// Pure inbox logic shared by Panel.qml and tests/inbox.test.js. A "scope" is
// an org ("acme"), a repo ("acme/one"), or a repo exception ("!acme/one")
// that carves one repo out of its org's rule. The hidden and focus settings
// are lists of scopes, so an org rule keeps covering repos it gains later.

// Dictionaries here are keyed by GitHub-controlled names, and "constructor"
// or "__proto__" are valid ones: no prototype, and own-key lookups only.
function dict() { return Object.create(null) }
function has(d, key) { return Object.prototype.hasOwnProperty.call(d, key) }
function copy(d) {
  var out = dict()
  for (var k in d) if (has(d, k)) out[k] = d[k]
  return out
}

// A hidden or focus setting from shell.json, which anyone can hand-edit.
// The shell hands lists over as Qt sequences, not JS arrays, so any list-like
// value is read, but never past 500 entries: a forged {"length": 1e100}
// would otherwise spin the shell's UI thread.
function scopeList(value) {
  if (value === null || typeof value !== "object") return []
  var len = value.length
  var n = typeof len === "number" && len > 0 ? Math.min(len, 500) : 0
  var out = []
  for (var i = 0; i < n; i++)
    if (validScope(value[i])) out.push(value[i])
  return out
}

// GitHub owner and repo names never contain anything else, and the panel
// passes scopes through a shell command, so this is also the safety check.
function validScope(s) {
  return typeof s === "string" && /^([A-Za-z0-9._-]+|!?[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)$/.test(s)
}

// A repo rule beats its exception, which beats the org rule.
function matches(item, scopes) {
  var repo = String(item.repo || "")
  if (scopes.indexOf(repo) >= 0) return true
  if (scopes.indexOf("!" + repo) >= 0) return false
  return scopes.indexOf(String(item.org || "")) >= 0
}

// Hidden always wins. Focus only narrows when something is targeted, so
// turning it on with an empty list never blanks the inbox.
function scoped(list, hidden, focus, focusMode) {
  var narrow = focusMode && focus.length > 0
  var out = []
  for (var i = 0; i < list.length; i++) {
    var item = list[i]
    if (matches(item, hidden)) continue
    if (narrow && !matches(item, focus)) continue
    out.push(item)
  }
  return out
}

// Flip one repo. Under an org rule that means adding or removing its
// exception, otherwise adding or removing the repo itself.
function toggleRepo(list, repo) {
  var org = repo.split("/")[0]
  var on = matches({ org: org, repo: repo }, list)
  var out = list.filter(function(s) { return s !== repo && s !== "!" + repo })
  var orgRule = out.indexOf(org) >= 0
  if (on && orgRule) out.push("!" + repo)
  if (!on && !orgRule) out.push(repo)
  return out.sort()
}

// Set a whole org on or off. Its repo rules and exceptions go either way.
function setOrg(list, org, on) {
  var out = list.filter(function(s) {
    return s !== org && s.indexOf(org + "/") !== 0 && s.indexOf("!" + org + "/") !== 0
  })
  if (on) out.push(org)
  return out.sort()
}

// A scope list in words: "acme (except 1 repo), beta/web".
function describe(list) {
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (list[i].charAt(0) === "!") continue
    var n = 0
    for (var j = 0; j < list.length; j++) if (list[j].indexOf("!" + list[i] + "/") === 0) n++
    out.push(n === 0 ? list[i] : list[i] + " (except " + n + (n === 1 ? " repo)" : " repos)"))
  }
  return out.join(", ")
}

// "all", "some" or "none" of an org's known repos match the list.
function orgState(list, org, repos) {
  if (repos.length === 0) return list.indexOf(org) >= 0 ? "all" : "none"
  var n = 0
  for (var i = 0; i < repos.length; i++) if (matches({ org: org, repo: repos[i] }, list)) n++
  return n === repos.length ? "all" : (n === 0 ? "none" : "some")
}

// A PR can sit in several lists at once (review requested and notified, say).
function distinctCount(lists) {
  var seen = dict()
  var n = 0
  for (var i = 0; i < lists.length; i++)
    for (var j = 0; j < lists[i].length; j++) {
      var url = String(lists[i][j].url || "")
      if (!seen[url]) { seen[url] = true; n++ }
    }
  return n
}

// Orgs with their repos and distinct open-item counts. `extra` scopes are
// listed with a zero count: hidden and focused ones must stay reachable to be
// undone even when nothing is open there.
function scopeTree(lists, extra) {
  var orgs = dict()
  function org(name) {
    if (!has(orgs, name)) orgs[name] = { org: name, count: 0, repoMap: dict() }
    return orgs[name]
  }
  function add(scope, n) {
    if (!validScope(scope)) return
    var parts = scope.replace(/^!/, "").split("/")
    var o = org(parts[0])
    o.count += n
    if (parts.length > 1) {
      var repo = parts.join("/")
      o.repoMap[repo] = (has(o.repoMap, repo) ? o.repoMap[repo] : 0) + n
    }
  }
  var seen = dict()
  for (var i = 0; i < lists.length; i++)
    for (var j = 0; j < lists[i].length; j++) {
      var url = String(lists[i][j].url || "")
      if (seen[url]) continue
      seen[url] = true
      add(String(lists[i][j].repo || ""), 1)
    }
  for (var k = 0; k < extra.length; k++) add(extra[k], 0)

  var names = Object.keys(orgs).sort()
  var out = []
  for (var m = 0; m < names.length; m++) {
    var o = orgs[names[m]]
    var repos = Object.keys(o.repoMap).sort().map(function(r) { return { repo: r, count: o.repoMap[r] } })
    out.push({ org: o.org, count: o.count, repos: repos })
  }
  return out
}

// Alerts fire for keys absent from the previous pass. A null previous pass is
// startup: it seeds the set silently so a restart never replays the inbox.
function freshAlerts(previous, items) {
  var keys = dict()
  var fresh = []
  for (var i = 0; i < items.length; i++) {
    keys[items[i].key] = true
    if (previous && !has(previous, items[i].key)) fresh.push(items[i])
  }
  return { keys: keys, fresh: fresh }
}

// dismissed: threadId -> updatedAt at dismissal. New activity re-shows it.
function undismissed(list, dismissed) {
  var out = []
  for (var i = 0; i < list.length; i++) {
    var n = list[i]
    var id = String(n.threadId)
    if (!has(dismissed, id) || dismissed[id] !== String(n.updatedAt || "")) out.push(n)
  }
  return out
}

// What a key in the comment box does. A held Ctrl+Enter repeats; after a
// failed post that repeat would post again, so it is swallowed.
function commentKey(k) {
  if (k.escape) return "cancel"
  if (k.enter && k.ctrl) return k.repeat ? "swallow" : "submit"
  return ""
}

// What the open preview does when the cursor's item changes or following
// resumes (after a cancel or a released hold): "show" the cursor's item,
// "clear" when it has nothing to preview, "none" while held, busy, in an
// action, or already there. Enter must never open an item the cursor is
// not on.
function followDecision(st) {
  if (!st.open || st.mode !== "" || st.busy || st.hold) return "none"
  if (st.cursorUrl === "") return st.previewUrl === "" ? "none" : "clear"
  return st.cursorUrl === st.previewUrl ? "none" : "show"
}

// A finished action's result stays on screen until the user does
// something deliberate that changes what the cursor means. A refresh
// moving the cursor is not that.
function releasesHold(cause) {
  return ["key", "jump", "pointer", "search", "org"].indexOf(cause) >= 0
}

// Markdown shown as plain text (never rendered, so nothing in it can
// become markup): what GitHub bodies are full of reads as words.
// The emoji codes bots and people type most, as the emoji GitHub shows.
var emojiCodes = {
  white_check_mark: "✅", heavy_check_mark: "✔️", x: "❌", warning: "⚠️", rocket: "🚀",
  tada: "🎉", bug: "🐛", bulb: "💡", memo: "📝", eyes: "👀", fire: "🔥", sparkles: "✨",
  "+1": "👍", "-1": "👎", thumbsup: "👍", thumbsdown: "👎", heart: "❤️", pray: "🙏",
  exclamation: "❗", question: "❓", information_source: "ℹ️", arrow_right: "→", wrench: "🔧",
  hammer: "🔨", lock: "🔒", zap: "⚡", recycle: "♻️", broom: "🧹", construction: "🚧",
  test_tube: "🧪", chart_with_upwards_trend: "📈", chart_with_downwards_trend: "📉",
  small_red_triangle_down: "🔻", small_red_triangle: "🔺", heavy_minus_sign: "➖", rabbit: "🐇"
}

function cleanLine(line) {
  return String(line)
    // What the 400- and 1200-character cuts leave half done goes first: an
    // unclosed tag or image disappears, an unclosed link keeps its text.
    .replace(/!\[[^\]]*\]\([^)]*$/, "[image]")
    .replace(/<[A-Za-z][^>]*$/, "")
    .replace(/\[([^\]]*)\]\([^)]*$/, "$1")
    .replace(/:([a-z0-9_+-]+):/g, function(m, code) { return Object.prototype.hasOwnProperty.call(emojiCodes, code) ? emojiCodes[code] : m })
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "[image]")
    .replace(/<img[^>]*>/gi, "[image]")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/<(https?:\/\/[^>\s]+)>/g, "$1")
    // A known list of tags, not any <...>: code such as Vec<String> stays.
    .replace(/<\/?(details|summary|br|sub|sup|p|div|b|i|em|strong|code|kbd|a|ul|ol|li|table|thead|tbody|tr|td|th|span|h[1-6]|hr|blockquote|pre|picture|source)\b[^>]*>/gi, "")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/(\*\*|__)(.+?)\1/g, "$2")
    .replace(/~~(.+?)~~/g, "$1")
    .replace(/(^|[^*\w])\*([^*\s][^*]*?)\*(?!\*)/g, "$1$2")
    // A fixed set of entities, &amp; last so "&amp;lt;" stays "&lt;".
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"")
    .replace(/&#39;/g, "'").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&")
}

// The description as blocks for the pane: headings, paragraphs, list
// items with their depth (so a wrapped item keeps its indent), table rows
// as "a · b · c", and quotes. Markdown and the HTML bots write instead
// (Dependabot's <blockquote>, <h2> and <li>) are read the same way. Code
// fences keep their content and lose the fence. Input is cut to 4000
// characters first: the regexes are quadratic on unclosed brackets, and
// 200 KB of them once took 23 s.
function bodyBlocks(text, maxBlocks) {
  var max = maxBlocks || 12
  var source = String(text || "")
  var cut = source.length > 4000 || source.slice(-1) === "…"
  var rawLines = source.slice(0, 4000).replace(/\r/g, "").split("\n")
  // Comments are blanked, not removed, so line numbers still match rawLines.
  var lines = rawLines.join("\n").replace(/<!--[\s\S]*?-->/g, function(m) { return m.replace(/[^\n]/g, "") }).split("\n")
  var blocks = []
  var para = []
  var paraQuote = false
  var htmlQuote = false
  var inList = false
  // The HTML quote runs from the first <blockquote> to the last
  // </blockquote>: a nested or stray closing tag inside quoted release
  // notes must not end it early and let quoted text pass as the author's.
  // Two separate quotes then dim the text between them, the safe side.
  // The scan reads the text before comments go, so a close hidden in a
  // comment still counts; and a body cut short (its real close may be past
  // the cut) keeps the quote to the end of what is shown.
  var lastClose = -1
  if (!cut) for (var c = 0; c < rawLines.length; c++) if (/<\/blockquote>/i.test(rawLines[c])) lastClose = c
  // Every block made inside a quote is marked, so quoted release notes in
  // a bot's PR never read as the author's words.
  function block(heading, txt, bullet, indent, quote, urgent) {
    var b = { heading: heading, text: txt, bullet: bullet, indent: indent }
    if (quote) b.quote = true
    if (urgent) b.urgent = true
    blocks.push(b)
  }
  // Hard-wrapped prose (commit-style bodies at about 72 columns) joins up:
  // a long line that does not end a sentence runs on into the next. Short
  // lines keep their break, so deliberate line breaks survive.
  function flush() {
    var t = ""
    for (var k = 0; k < para.length; k++) {
      var prev = k > 0 ? para[k - 1] : ""
      // Full-width punctuation ends a sentence too, and Japanese or
      // Chinese text runs on with no space between the lines.
      var runOn = prev.length > 60 && !/[.!?:。！？：」）)]$|  $/.test(prev)
      var cjk = /[\u3000-\u9fff\uff00-\uffef]$/.test(prev) || /^[\u3000-\u9fff\uff00-\uffef]/.test(para[k])
      t += k === 0 ? para[k] : (runOn ? (cjk ? "" : " ") : "\n") + para[k]
    }
    t = t.trim()
    if (t !== "") block(false, t, "", 0, paraQuote || htmlQuote)
    para = []
  }
  for (var i = 0; i < lines.length && blocks.length < max; i++) {
    var raw = lines[i]
    var li = /^(\s*)([-*+]|\d+\.)\s+(.*)$/.exec(raw)
    // An indented line right under a list item continues it (hard wrap).
    if (!li && inList && /^\s+\S/.test(raw) && blocks.length > 0) {
      var last = blocks[blocks.length - 1]
      last.text = (last.text + " " + cleanLine(raw).trim()).trim()
      continue
    }
    inList = false
    if (/<blockquote\b/i.test(raw)) { flush(); htmlQuote = true }
    var closesQuote = i === lastClose
    if (/^\s*```/.test(raw) || /^\s*([-*_]\s*){3,}$/.test(raw) || /^\s*\|[\s:|-]+\|\s*$/.test(raw)) {
      if (closesQuote) { flush(); htmlQuote = false }
      continue
    }
    var htmlHeading = /^\s*<h[1-6]\b[^>]*>(.*)<\/h[1-6]>\s*$/i.exec(raw)
    var htmlItem = /^\s*<li\b[^>]*>(.*?)(<\/li>)?\s*$/i.exec(raw)
    // A table row the 1200-character cut ended early has no closing pipe.
    // The row above the |---| line is the header: bold, as column names.
    var alert = /^\s*>\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$/i.exec(raw)
    if (alert) {
      flush()
      var kindName = alert[1].toLowerCase()
      block(true, kindName.charAt(0).toUpperCase() + kindName.slice(1), "", 0, true, /warning|caution/.test(kindName))
      paraQuote = true
    } else if (/^\s*\|/.test(raw)) {
      flush()
      block(i + 1 < lines.length && /^\s*\|[\s:|-]+\|\s*$/.test(lines[i + 1]), cleanLine(raw).trim().replace(/^\|\s*|\s*\|$/g, "").split(/\s*\|\s*/).join(" · "), "", 0, htmlQuote)
    } else if (/^#{1,6}\s+/.test(raw) || htmlHeading) {
      flush()
      block(true, cleanLine(htmlHeading ? htmlHeading[1] : raw.replace(/^#{1,6}\s+/, "")).trim(), "", 0, htmlQuote)
    } else if (li || htmlItem) {
      flush()
      inList = !!li
      if (htmlItem) {
        block(false, cleanLine(htmlItem[1]).trim(), "•", 0, htmlQuote)
      } else {
        var indent = Math.min(4, Math.floor(li[1].length / 2))
        var box = /^\[( |x|X)\]\s+(.*)$/.exec(li[3])
        if (box) block(false, cleanLine(box[2]).trim(), box[1] === " " ? "[ ]" : "[x]", indent, htmlQuote)
        else block(false, cleanLine(li[3]).trim(), /\d/.test(li[2]) ? li[2] : "•", indent, htmlQuote)
      }
    } else {
      var quoted = /^\s*>/.test(raw)
      var line = cleanLine(raw.replace(/^\s*>\s?/, ""))
      // A blank line ends a paragraph; a line that only held tags does not.
      if (raw.trim() === "") flush()
      else if (line.trim() !== "") {
        if (quoted !== paraQuote) { flush(); paraQuote = quoted }
        para.push(line)
      }
    }
    if (closesQuote) { flush(); htmlQuote = false }
  }
  flush()
  return blocks.slice(0, max)
}

// A comment as plain text: quoted lines (the reply's context) go.
function plainText(text) {
  return String(text || "").slice(0, 2000).replace(/\r/g, "").replace(/<!--[\s\S]*?-->/g, "")
    .split("\n").filter(function(l) { return !/^\s*>/.test(l) && !/^\s*```/.test(l) })
    .map(function(l) { return cleanLine(l.replace(/^#{1,6}\s+/, "").replace(/^(\s*)[-*+]\s+/, "$1• ")) })
    .join("\n").replace(/\n{3,}/g, "\n\n").trim()
}

// The review line: who approved, who asked for changes, and who is still
// asked, with the viewer named as "your review". Reviews that only
// commented carry no verdict and are left out.
function reviewLine(reviews, requested, viewer, decision) {
  function names(list) {
    return list.slice(0, 2).map(function(n) { return "@" + n }).join(", ") + (list.length > 2 ? " +" + (list.length - 2) : "")
  }
  var me = String(viewer || "").toLowerCase()
  var approved = [], changes = [], waiting = [], youAsked = false
  var r = reviews || [], q = requested || []
  for (var i = 0; i < r.length && i < 50; i++) {
    var who = String(r[i].author || "")
    if (r[i].state === "APPROVED") approved.push(who)
    else if (r[i].state === "CHANGES_REQUESTED") changes.push(who)
  }
  for (var k = 0; k < q.length && k < 50; k++) {
    if (me !== "" && String(q[k]).toLowerCase() === me) youAsked = true
    else waiting.push(String(q[k]))
  }
  var parts = []
  if (changes.length > 0) parts.push("changes requested by " + names(changes))
  if (approved.length > 0) parts.push("approved by " + names(approved))
  if (parts.length === 0) parts.push(decision === "REVIEW_REQUIRED" ? "review required" : "no reviews yet")
  else if (decision === "REVIEW_REQUIRED" && changes.length === 0) parts.push("more reviews required")
  if (youAsked) parts.push("your review is requested")
  else if (waiting.length > 0) parts.push("waiting on " + names(waiting))
  var text = parts.join(" · ")
  var tone = changes.length > 0 ? "bad" : (youAsked ? "ask"
    : (approved.length > 0 && decision !== "REVIEW_REQUIRED" ? "good" : "dim"))
  return { text: text.charAt(0).toUpperCase() + text.slice(1), tone: tone }
}

// What a comment card says when nothing is left after cleanup.
function emptyCommentNote(body, state) {
  if (state === "APPROVED") return "Approved, no comment"
  if (state === "CHANGES_REQUESTED") return "Requested changes, no comment"
  var b = String(body || "").slice(0, 2000).replace(/<!--[\s\S]*?-->/g, "").trim()
  if (b !== "" && b.split("\n").every(function(l) { return l.trim() === "" || /^\s*>/.test(l) })) return "Only quotes an earlier comment"
  return "No text preview. Enter opens it."
}

// The checks line. It leads with how many fail or run, and says when more
// checks exist than the 100 counted, so a pass is never implied by counts.
function checksText(c) {
  if (!c || (c.total || 0) === 0) return "No checks"
  var counted = c.passed + c.failed + c.pending
  var partial = c.total > counted ? " (first " + counted + " of " + c.total + ")" : ""
  var passed = c.passed > 0 ? " · " + c.passed + " passed" : ""
  if (c.failed > 0) return c.failed + " of " + c.total + " checks failing"
    + (c.pending > 0 ? " · " + c.pending + " running" : "") + passed + partial
  if (c.pending > 0) return c.pending + " of " + c.total + " checks running" + passed + partial
  if (c.state === "FAILURE" || c.state === "ERROR") return "Checks failing" + passed + partial
  if (c.state === "PENDING" || c.state === "EXPECTED") return "Checks running" + passed + partial
  return "Checks: " + c.passed + " passed" + partial
}
