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

t("dismissed: a dismissed thread stays hidden until it gets new activity", () => {
  const n = [{ threadId: "1", updatedAt: "t1" }, { threadId: "2", updatedAt: "t1" }]
  eq(I.undismissed(n, { "1": "t1" }).map(x => x.threadId), ["2"])
  assert.strictEqual(I.undismissed([{ threadId: "1", updatedAt: "t2" }], { "1": "t1" }).length, 1)
})

console.log("\n" + pass + " passed, " + fail + " failed")
process.exit(fail > 0 ? 1 : 0)
