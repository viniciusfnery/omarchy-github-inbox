// Tests for Inbox.js, the panel's pure logic. Loads the QML-side library
// file as-is (minus its .pragma line) into a node VM: no QML runtime needed.
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

const src = fs.readFileSync(path.join(__dirname, "..", "Inbox.js"), "utf8").replace(/^\.pragma.*$/m, "")
const I = {}
vm.runInNewContext(src, I)

// Values built inside the VM carry its Array prototype, so compare as JSON.
const eq = (a, b) => assert.strictEqual(JSON.stringify(a), JSON.stringify(b))

let pass = 0
let fail = 0
function t(name, fn) {
  try { fn(); pass++; console.log("ok    " + name) }
  catch (e) { fail++; console.log("FAIL  " + name + "\n      " + e.message) }
}

const a1 = { org: "acme", repo: "acme/one", url: "u1" }
const a2 = { org: "acme", repo: "acme/two", url: "u2" }
const b1 = { org: "beta", repo: "beta/one", url: "u3" }

t("scope: nothing hidden, focus off keeps everything", () => {
  eq(I.scoped([a1, a2, b1], [], [], false).length, 3)
})
t("scope: hiding an org drops all its repos", () => {
  eq(I.scoped([a1, a2, b1], ["acme"], [], false), [b1])
})
t("scope: hiding a repo drops only that repo", () => {
  eq(I.scoped([a1, a2, b1], ["acme/two"], [], false), [a1, b1])
})
t("scope: focus keeps targeted orgs and repos only", () => {
  eq(I.scoped([a1, a2, b1], [], ["acme/one", "beta"], true), [a1, b1])
})
t("scope: focus with nothing targeted keeps everything", () => {
  assert.strictEqual(I.scoped([a1, a2, b1], [], [], true).length, 3)
})
t("scope: hidden wins over focus", () => {
  eq(I.scoped([a1, a2], ["acme/one"], ["acme"], true), [a2])
})

t("repo exception: a shown repo under a hidden org is an exception, not a sibling list", () => {
  const hidden = I.toggleRepo(["acme"], "acme/one")
  eq(hidden, ["!acme/one", "acme"])
  // A repo the org gains later stays hidden with the org.
  const later = { org: "acme", repo: "acme/new", url: "u9" }
  eq(I.scoped([a1, a2, later], hidden, [], false).map(x => x.repo), ["acme/one"])
})
t("repo exception: toggling it again restores the plain org rule", () => {
  eq(I.toggleRepo(["!acme/one", "acme"], "acme/one"), ["acme"])
})
t("repo rule: with no org rule a repo is listed by itself", () => {
  eq(I.toggleRepo([], "acme/one"), ["acme/one"])
  eq(I.toggleRepo(["acme/one"], "acme/one"), [])
})
t("setOrg: on sets the whole org, off clears it, either way its repo rules go", () => {
  eq(I.setOrg(["acme/one", "!acme/two", "beta"], "acme", true), ["acme", "beta"])
  eq(I.setOrg(["acme", "!acme/two", "beta"], "acme", false), ["beta"])
})
t("describe: exceptions read as words, not storage syntax", () => {
  assert.strictEqual(I.describe(["acme", "!acme/one", "beta/web"]), "acme (except 1 repo), beta/web")
  assert.strictEqual(I.describe(["acme", "!acme/one", "!acme/two"]), "acme (except 2 repos)")
})
t("org state: all, some, or none of its repos match", () => {
  eq(I.orgState(["acme"], "acme", ["acme/one", "acme/two"]), "all")
  eq(I.orgState(["acme", "!acme/one"], "acme", ["acme/one", "acme/two"]), "some")
  eq(I.orgState(["acme/one"], "acme", ["acme/one", "acme/two"]), "some")
  eq(I.orgState([], "acme", ["acme/one"]), "none")
  eq(I.orgState(["acme"], "acme", []), "all")
})
t("focus exceptions narrow the same way", () => {
  eq(I.scoped([a1, a2, b1], [], ["acme", "!acme/two"], true), [a1])
})

t("tree: groups repos under orgs, counting each distinct item once", () => {
  const other = { org: "acme", repo: "acme/one", url: "u1b" }
  // a1 sits in two lists (a review request and its notification): one item.
  const tree = I.scopeTree([[a2, a1, other], [a1, b1]], [])
  eq(tree.map(o => o.org), ["acme", "beta"])
  assert.strictEqual(tree[0].count, 3)
  eq(tree[0].repos.map(r => [r.repo, r.count]), [["acme/one", 2], ["acme/two", 1]])
})
t("tree: extra scopes with no open items still appear, with a zero count", () => {
  const tree = I.scopeTree([[a1]], ["gone", "!acme/old"])
  eq(tree.map(o => o.org), ["acme", "gone"])
  eq(tree[0].repos.map(r => r.repo), ["acme/old", "acme/one"])
  assert.strictEqual(tree[1].count, 0)
})
t("tree: ignores malformed scope strings", () => {
  const tree = I.scopeTree([[a1]], ["", "has space", "a/b/c", "!acme", null])
  eq(tree.map(o => o.org), ["acme"])
})

t("tree: names that shadow Object builtins are plain names", () => {
  const odd = ["constructor", "toString", "__proto__", "hasOwnProperty"].map(o => ({ org: o, repo: o + "/repo", url: "u-" + o }))
  const tree = I.scopeTree([odd], ["__proto__"])
  eq(tree.map(o => o.org), ["__proto__", "constructor", "hasOwnProperty", "toString"])
  eq(tree.map(o => o.count), [1, 1, 1, 1])
  assert.strictEqual(Object.prototype.count, undefined)
})
t("alerts and distinct counts accept builtin-shaped keys", () => {
  assert.strictEqual(I.distinctCount([[{ url: "constructor" }, { url: "__proto__" }]]), 2)
  const r = I.freshAlerts({}, [{ key: "constructor" }, { key: "__proto__" }])
  eq(r.fresh.map(x => x.key), ["constructor", "__proto__"])
})
t("scopeList: list-likes read, valid scopes only, never past 500 entries", () => {
  const t0 = Date.now()
  eq(I.scopeList({ length: 1e100 }), [])
  assert.ok(Date.now() - t0 < 100, "a forged length must not spin")
  eq(I.scopeList({ length: { valueOf: 0, toString: 0 } }), [])
  eq(I.scopeList({ length: "3", 0: "acme" }), [])
  // Qt sequences arrive as array-likes, not JS arrays.
  eq(I.scopeList({ length: 2, 0: "acme", 1: "beta/web" }), ["acme", "beta/web"])
  eq(I.scopeList("acme"), [])
  eq(I.scopeList(["acme", "bad name", 3, "!acme/one"]), ["acme", "!acme/one"])
  assert.strictEqual(I.scopeList(Array.from({ length: 5000 }, (_, i) => "o" + i)).length, 500)
})

t("distinct: counts each url once across lists", () => {
  assert.strictEqual(I.distinctCount([[a1, a2], [a1, b1]]), 3)
})

t("alerts: the first pass only seeds, never alerts", () => {
  const r = I.freshAlerts(null, [{ key: "k1" }])
  eq(r.fresh, [])
  eq(Object.keys(r.keys), ["k1"])
})
t("alerts: only keys not seen on the previous pass are fresh", () => {
  const r = I.freshAlerts({ k1: true }, [{ key: "k1" }, { key: "k2" }])
  eq(r.fresh.map(x => x.key), ["k2"])
  eq(Object.keys(r.keys).sort(), ["k1", "k2"])
})
t("alerts: a key that left and came back alerts again", () => {
  const r = I.freshAlerts({ k2: true }, [{ key: "k1" }])
  eq(r.fresh.map(x => x.key), ["k1"])
})

t("comment keys: Ctrl+Enter posts once; its auto-repeat is swallowed, never posted", () => {
  assert.strictEqual(I.commentKey({ enter: true, ctrl: true, repeat: false }), "submit")
  // After a failed post, a still-held Ctrl+Enter must not post again.
  assert.strictEqual(I.commentKey({ enter: true, ctrl: true, repeat: true }), "swallow")
  assert.strictEqual(I.commentKey({ enter: true, ctrl: false, repeat: false }), "")
  assert.strictEqual(I.commentKey({ escape: true }), "cancel")
  assert.strictEqual(I.commentKey({}), "")
})

t("follow: the pane follows the cursor, empties without a target, and waits while held or busy", () => {
  const base = { open: true, mode: "", busy: false, hold: false, cursorUrl: "b", previewUrl: "a" }
  assert.strictEqual(I.followDecision(base), "show")
  // Cancelled comment, org switch or empty filter: nothing left to preview.
  assert.strictEqual(I.followDecision({ ...base, cursorUrl: "" }), "clear")
  assert.strictEqual(I.followDecision({ ...base, cursorUrl: "a" }), "none")
  assert.strictEqual(I.followDecision({ ...base, hold: true }), "none")
  assert.strictEqual(I.followDecision({ ...base, busy: true }), "none")
  assert.strictEqual(I.followDecision({ ...base, mode: "comment" }), "none")
  assert.strictEqual(I.followDecision({ ...base, open: false }), "none")
  // Already empty stays empty without work.
  assert.strictEqual(I.followDecision({ ...base, cursorUrl: "", previewUrl: "" }), "none")
})

t("hold: deliberate moves, searches and org switches release it, a refresh never does", () => {
  for (const cause of ["key", "jump", "pointer", "search", "org"]) assert.strictEqual(I.releasesHold(cause), true, cause)
  for (const cause of ["refresh", "settings", "", "anything else"]) assert.strictEqual(I.releasesHold(cause), false, cause)
})

t("body blocks: headings, paragraphs, bullets with their depth, numbered items, table rows", () => {
  const b = I.bodyBlocks("## Summary\nSome **bold** text\nmore\n\n- top\n  - nested `code`\n1. first\n| a | b |\n|---|---|\n| 1 | 2 |")
  eq(b, [
    { heading: true, text: "Summary", bullet: "", indent: 0 },
    { heading: false, text: "Some bold text\nmore", bullet: "", indent: 0 },
    { heading: false, text: "top", bullet: "•", indent: 0 },
    { heading: false, text: "nested code", bullet: "•", indent: 1 },
    { heading: false, text: "first", bullet: "1.", indent: 0 },
    { heading: false, text: "a · b", bullet: "", indent: 0 },
    { heading: false, text: "1 · 2", bullet: "", indent: 0 }])
})
t("markdown noise: images, links, checkboxes, fences, details and quotes read as text", () => {
  const b = I.bodyBlocks("![shot](https://github.com/user-attachments/x.png)\n<img src=\"https://e.x/a.png\" width=\"300\">\nSee [the docs](https://x.y/z)\n```yaml\nkey: 1\n```\n- [ ] todo\n- [x] done\n<details><summary>More</summary>\nhidden\n</details>")
  eq(b.map(x => x.bullet + "|" + x.text), ["|[image]\n[image]\nSee the docs\nkey: 1", "☐|todo", "☑|done", "|More\nhidden"])
  assert.strictEqual(I.plainText("> quoted reply\nmy answer with [a link](https://x)\n\n\n\nend"), "my answer with a link\n\nend")
})

t("bot bodies: HTML lists, links, tables, rules, autolinks, strike and italics read as text", () => {
  const b = I.bodyBlocks("<ul>\n<li><a href=\"https://x/c\">f299b52</a> Bump deps</li>\n</ul>\n---\nSee <https://auto.link> and ~~old~~ *new*\n<table><tr><td>a</td></tr></table>\nVec<String> stays")
  eq(b.map(x => x.text), ["f299b52 Bump deps", "See https://auto.link and old new\na\nVec<String> stays"])
})
t("checks: the line leads with how many are failing or running, and says when not all were counted", () => {
  assert.strictEqual(I.checksText({ passed: 30, failed: 0, pending: 0, total: 30, state: "SUCCESS" }), "Checks: 30 passed")
  assert.strictEqual(I.checksText({ passed: 24, failed: 2, pending: 0, total: 26, state: "FAILURE" }), "2 of 26 checks failing · 24 passed")
  assert.strictEqual(I.checksText({ passed: 23, failed: 0, pending: 3, total: 26, state: "PENDING" }), "3 of 26 checks running · 23 passed")
  assert.strictEqual(I.checksText({ passed: 100, failed: 0, pending: 0, total: 140, state: "FAILURE" }), "Checks failing · 100 passed (first 100 of 140)")
  assert.strictEqual(I.checksText({ passed: 0, failed: 0, pending: 0, total: 0, state: "" }), "No checks")
})
t("markdown cleanup is bounded: a huge hostile body stays fast", () => {
  const t0 = Date.now()
  I.bodyBlocks("[".repeat(200000) + "](".repeat(1000))
  I.plainText("<details".repeat(50000))
  assert.ok(Date.now() - t0 < 500, "took " + (Date.now() - t0) + " ms")
})

t("lists: a hard-wrapped item stays one item", () => {
  const b = I.bodyBlocks("- first item\n  and continues here\n- second")
  eq(b.map(x => x.bullet + "|" + x.text), ["•|first item and continues here", "•|second"])
})
t("checks: running checks are counted beside failing ones", () => {
  assert.strictEqual(I.checksText({ passed: 20, failed: 2, pending: 4, total: 26, state: "FAILURE" }), "2 of 26 checks failing · 4 running · 20 passed")
})
t("entities: the common ones read as their characters, &amp; last", () => {
  assert.strictEqual(I.cleanLine("&lt;T&gt; &quot;a&quot; it&#39;s&nbsp;x &amp;lt;"), "<T> \"a\" it's x &lt;")
})
t("quotes: quoted lines in a description are their own quote blocks", () => {
  const b = I.bodyBlocks("Bumps lib.\n\n> Release notes\n> fixed a bug\n\nMine again")
  eq(b.map(x => (x.quote ? "> " : "") + x.text), ["Bumps lib.", "> Release notes\nfixed a bug", "Mine again"])
})

t("dependabot: HTML blockquote, headings and list items read as quoted headings and bullets", () => {
  const body = "Bumps [actions/checkout](https://github.com/actions/checkout) from 3 to 4.\n<details>\n<summary>Release notes</summary>\n<p><em>Sourced from <a href=\"https://x\">releases</a>.</em></p>\n<blockquote>\n<h2>v4.0.0</h2>\n<h2>What's Changed</h2>\n<ul>\n<li>Update default runtime to node20</li>\n<li>Support fetching without the <code>--progress</code> option</li>\n</ul>\n</blockquote>\n</details>"
  const b = I.bodyBlocks(body, 20)
  eq(b.map(x => (x.quote ? "> " : "") + (x.heading ? "# " : "") + x.bullet + "|" + x.text), [
    "|Bumps actions/checkout from 3 to 4.\nRelease notes\nSourced from releases.",
    "> # |v4.0.0", "> # |What's Changed",
    "> •|Update default runtime to node20", "> •|Support fetching without the --progress option"])
})
t("hard wraps: a run-on line joins the next with a space; short lines keep their break", () => {
  const long = "This change moves the cache into its own module so that the panel and"
  const b = I.bodyBlocks(long + "\nthe script share one place for it.\nShort line\nNext line")
  eq(b.map(x => x.text), [long + " the script share one place for it.\nShort line\nNext line"])
})
t("lists: an indented line after a heading or table row is not glued to the list item", () => {
  const b = I.bodyBlocks("- a\n## H\n  x")
  eq(b.map(x => x.text), ["a", "H", "x"])
})

t("Japanese: a long line ending in 。 keeps its break, and wrapped Japanese joins with no space", () => {
  const long = "Action Managers の AOBC への要求が AOBC に届くようにし、SILS でも PCDU・NAC の実データで判断することを確認した。"
  eq(I.bodyBlocks(long + "\n2 行目の別の文です。").map(x => x.text), [long + "\n2 行目の別の文です。"])
  const wrapped = "分離から THREE_AXIS の三軸制御収束まで Action Managers が自律で進むことを確認するために必要な手順を"
  eq(I.bodyBlocks(wrapped + "\n追加した").map(x => x.text), [wrapped + "追加した"])
})
t("quotes: a nested or stray closing blockquote does not end the outer quote", () => {
  const b = I.bodyBlocks("Bumps x.\n<blockquote>\n<h2>v2</h2>\n<p>notes</blockquote></p>\n<p>Reviewed by the security team, safe to merge.</p>\n</blockquote>\nAfter")
  eq(b.map(x => (x.quote ? "> " : "") + x.text), ["Bumps x.", "> v2", "> notes\nReviewed by the security team, safe to merge.", "After"])
})

t("dismissed: a dismissed thread stays hidden until it gets new activity", () => {
  const n = [{ threadId: "1", updatedAt: "t1" }, { threadId: "2", updatedAt: "t1" }]
  eq(I.undismissed(n, { "1": "t1" }).map(x => x.threadId), ["2"])
  assert.strictEqual(I.undismissed([{ threadId: "1", updatedAt: "t2" }], { "1": "t1" }).length, 1)
})

console.log("\n" + pass + " passed, " + fail + " failed")
process.exit(fail > 0 ? 1 : 0)
