import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Inbox.js" as Inbox

Panel {
  id: root
  moduleName: "viniciusfnery.github-inbox"
  ipcTarget: "viniciusfnery.github-inbox"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string scriptPath: Qt.resolvedUrl("fetch.sh").toString().replace(/^file:\/\//, "")
  readonly property string notifyPath: Qt.resolvedUrl("notify.sh").toString().replace(/^file:\/\//, "")
  readonly property string previewPath: Qt.resolvedUrl("preview.sh").toString().replace(/^file:\/\//, "")

  // Never name this `data`: that shadows Item's default property and steals
  // every declared child from the scene.
  property var feed: ({ user: "", error: "", prs: [], issues: [], notifications: [] })
  property bool loaded: false
  property double lastFetchMs: 0
  property string selectedOrg: ""
  property bool cursorActive: false

  // Bound clock: relative times keep updating while the panel sits open.
  property double nowMs: Date.now()

  // ------------------------------------------------ settings (shell.json entry)
  //
  // Written through the shell's setBarWidget, the same path `omarchy bar set`
  // takes. `pending` holds a just-written value until the shell hands the
  // entry back, so a toggle answers instantly.
  property var pending: ({})
  // Deferred: settings first arrive while bindings that read `pending` are
  // still evaluating, and clearing it there is a binding loop.
  onSettingsChanged: Qt.callLater(clearPending)
  function clearPending() { pending = ({}) }

  function pref(name, fallback) {
    return pending[name] !== undefined ? pending[name] : setting(name, fallback)
  }

  function scopePref(name) { return Inbox.scopeList(pref(name, [])) }

  // Only the four keys this panel owns, holding a boolean or a list of
  // validScope() strings, reach the shell, and as argv with no shell in
  // between. The leading space in the value is load-bearing: `qs ipc` splits
  // an argument that starts with "[" into several.
  readonly property var prefKeys: ["hidden", "focus", "focusMode", "desktopNotifications"]

  function savePref(name, value) {
    if (prefKeys.indexOf(name) < 0) return
    if (typeof value !== "boolean") {
      if (!Array.isArray(value) || !value.every(Inbox.validScope)) return
    }
    var next = Object.assign({}, pending)
    next[name] = value
    pending = next
    Quickshell.execDetached(["omarchy-shell", "shell", "setBarWidget", moduleName, name,
                             " " + JSON.stringify(value), "{}"])
  }

  readonly property var hiddenScopes: scopePref("hidden")
  readonly property var focusScopes: scopePref("focus")
  readonly property bool focusMode: pref("focusMode", false) === true
  readonly property bool desktopNotifications: pref("desktopNotifications", false) === true
  readonly property bool focusNarrowing: focusMode && focusScopes.length > 0

  function inScope(list) { return Inbox.scoped(list, hiddenScopes, focusScopes, focusMode) }

  // threadId -> updatedAt for rows dismissed here. Hides them until GitHub
  // agrees, even if a refresh already in flight still carries them.
  property var dismissed: Inbox.dict()

  // `feed` can be uninitialized during construction; an exception here would
  // leave dependent bindings permanently failed.
  function rawList(name) { return (feed && feed[name]) || [] }
  readonly property var rawNotifications: Inbox.undismissed(rawList("notifications"), dismissed)

  readonly property var allPrs: inScope(rawList("prs"))
  readonly property var allReviews: inScope(rawList("reviews"))
  readonly property var allIssues: inScope(rawList("issues"))
  readonly property var allNotifications: inScope(rawNotifications)
  readonly property var allMentions: inScope(rawList("mentions"))
  readonly property var allClosed: inScope(rawList("closed"))
  readonly property int workCount: allPrs.length + allReviews.length + allIssues.length

  readonly property int rawOpenCount: Inbox.distinctCount([rawList("prs"), rawList("reviews"),
    rawList("issues"), rawNotifications, rawList("mentions")])

  // Open rows focus mode is keeping out of view, for the focus banner.
  readonly property int focusHiddenCount: Inbox.distinctCount([Inbox.scoped(rawList("prs").concat(rawList("reviews"))
    .concat(rawList("issues")).concat(rawNotifications).concat(rawList("mentions")), hiddenScopes, [], false)])
    - Inbox.distinctCount([allPrs, allReviews, allIssues, allNotifications, allMentions])

  // GitHub has no "mention read" state, so it lives here: url -> updatedAt at
  // the moment the mention was opened. New activity on the thread re-dots it.
  property var seen: Inbox.dict()

  function mentionUnread(m) {
    // Your own comments/reactions never create GitHub notifications, so
    // requiring an unread one filters your own activity out of the dot.
    if (m.notifUnread !== true) return false
    var url = String(m.url || "")
    var seenAt = Inbox.has(seen, url) ? seen[url] : undefined
    return !seenAt || String(m.updatedAt || "") > String(seenAt)
  }

  function countUnread(list) {
    var n = 0
    for (var i = 0; i < list.length; i++) if (mentionUnread(list[i])) n++
    return n
  }

  // The chip counts every org, the empty state the selected org, the
  // section header what is on screen.
  readonly property int unreadMentions: {
    var n = 0
    for (var i = 0; i < allMentions.length; i++)
      if (mentionUnread(allMentions[i])) n++
    return n
  }

  // Opening a mention: seen now, and GitHub's inbox agrees right away (the
  // dot rule reads it). `d` goes through dismissMention and its undo window.
  function markSeen(item) {
    setSeen(String(item.url || ""), String(item.updatedAt || ""))
    markThreadRead([item.threadId])
  }

  // value null forgets the url. Pruned to the listed mentions so the file
  // never grows. The file watcher hands the change to the other monitors.
  function setSeen(url, value) {
    var next = Inbox.dict()
    var listed = rawList("mentions")
    for (var i = 0; i < listed.length; i++) {
      var u = String(listed[i].url || "")
      if (Inbox.has(seen, u) && seen[u]) next[u] = seen[u]
    }
    if (value === null || value === undefined) delete next[url]
    else next[url] = value
    seen = next
    writeSeen(JSON.stringify(next))
  }

  // Rows leave at once and GitHub hears about each batch 5 seconds later. It
  // has no "mark unread", so that window is the only undo there is. A batch
  // holds dismissed notifications and mentions whose dot was cleared, keeps
  // its own deadline (closing the panel or dismissing again never cuts it
  // short), and is shared by every monitor's copy so `u` works from any of
  // them. Only the copy that made a batch sends it.
  property var undoBatches: []
  property double undoNow: Date.now()

  function instances() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    if (items.indexOf(root) < 0) items = items.concat([root])
    return items
  }

  function shareAll(name, value) {
    var all = instances()
    for (var i = 0; i < all.length; i++) if (all[i][name] !== undefined) all[i][name] = value
  }

  function setDismissed(next) { shareAll("dismissed", next) }
  function setBatches(next) { shareAll("undoBatches", next) }

  onUndoBatchesChanged: if (undoBatches.length > 0) { undoNow = Date.now(); undoTick.start() }

  function addBatch(notes, mentions) {
    undoNow = Date.now()
    setBatches(undoBatches.concat([{ notes: notes, mentions: mentions, due: undoNow + 5000, owner: root }]))
  }

  function dismissNotifications(items) {
    if (items.length === 0) return
    var next = Inbox.copy(dismissed)
    for (var i = 0; i < items.length; i++) next[String(items[i].threadId)] = String(items[i].updatedAt || "")
    setDismissed(next)
    addBatch(items.slice(), [])
  }

  // `d` on a mention: the dot clears now, GitHub hears with the batch.
  function dismissMention(item) {
    var url = String(item.url || "")
    var before = Inbox.has(seen, url) ? seen[url] : undefined
    setSeen(url, String(item.updatedAt || ""))
    addBatch([], [{ item: item, before: before === undefined ? null : before }])
  }

  function flushDismissals() {
    undoNow = Date.now()
    var keep = []
    var send = []
    var live = instances()
    for (var i = 0; i < undoBatches.length; i++) {
      var b = undoBatches[i]
      if (b.due > undoNow) { keep.push(b); continue }
      // Another live copy sends its own batches. One whose copy is gone
      // (monitor unplugged) is adopted, or it would never be sent.
      if (b.owner !== root && live.indexOf(b.owner) >= 0) { keep.push(b); continue }
      for (var j = 0; j < b.notes.length; j++) send.push(b.notes[j].threadId)
      for (var k = 0; k < b.mentions.length; k++) send.push(b.mentions[k].item.threadId)
    }
    if (keep.length !== undoBatches.length) setBatches(keep)
    if (send.length > 0) markThreadRead(send)
    if (undoBatches.length === 0) undoTick.stop()
  }

  // Undoes the most recent batch still inside its window.
  function undoDismiss() {
    if (undoBatches.length === 0) return
    var last = undoBatches[undoBatches.length - 1]
    setBatches(undoBatches.slice(0, -1))
    restoreDismissed(last.notes.map(function(n) { return n.threadId }))
    for (var i = 0; i < last.mentions.length; i++)
      setSeen(String(last.mentions[i].item.url || ""), last.mentions[i].before)
  }

  function restoreDismissed(threadIds) {
    var next = Inbox.copy(dismissed)
    for (var i = 0; i < threadIds.length; i++) delete next[String(threadIds[i])]
    setDismissed(next)
  }

  readonly property var lastUndo: undoBatches.length > 0 ? undoBatches[undoBatches.length - 1] : null
  readonly property int lastUndoSize: lastUndo ? lastUndo.notes.length + lastUndo.mentions.length : 0

  Timer {
    id: undoTick
    interval: 250
    repeat: true
    onTriggered: root.flushDismissals()
  }

  // Dismiss without opening: a notification is marked read, a mention loses
  // its dot. Other rows have nothing to dismiss.
  function dismissCursor() {
    var row = rowAt(cursor)
    if (!row || !row.item) return
    if (row.notification) dismissNotifications([row.item])
    else if (row.mention && mentionUnread(row.item)) dismissMention(row.item)
  }

  // Thread ids come from the GitHub API, and the numeric check keeps
  // anything else off the command line. One call at a time: ids that arrive
  // meanwhile queue for the next one. Ids GitHub refused come back on stdout
  // and their rows return with a note in the hint line.
  property var markQueue: []
  property int markFailures: 0

  function markThreadRead(threadIds) {
    var ids = []
    for (var i = 0; i < threadIds.length; i++)
      if (/^[0-9]+$/.test(String(threadIds[i] || ""))) ids.push(String(threadIds[i]))
    if (ids.length === 0) return
    markQueue = markQueue.concat(ids)
    startMark()
  }

  function startMark() {
    if (markProcess.running || markQueue.length === 0) return
    markProcess.command = ["bash", scriptPath, "--mark-read"].concat(markQueue)
    markQueue = []
    markProcess.running = true
  }

  function markFinished(text) {
    var failed = String(text || "").split("\n").filter(function(id) { return /^[0-9]+$/.test(id) })
    if (failed.length === 0) return
    restoreDismissed(failed)
    var listed = rawList("mentions")
    for (var i = 0; i < listed.length; i++)
      if (failed.indexOf(String(listed[i].threadId)) >= 0) setSeen(String(listed[i].url || ""), null)
    shareAll("markFailures", markFailures + failed.length)
  }

  Process {
    id: markProcess
    running: false
    onRunningChanged: if (!running) Qt.callLater(root.startMark)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.markFinished(text)
    }
  }

  // The refusal notice counts down only while someone can see it.
  Timer {
    interval: 6000
    running: root.opened && root.markFailures > 0
    onTriggered: root.shareAll("markFailures", 0)
  }

  // ------------------------------------------------ desktop notifications
  //
  // Every monitor's copy fetches, but only the first copy alerts. Keys cover
  // all rows, not just the focused ones, so leaving focus mode does not replay
  // what it kept quiet.
  property var alertKeys: null

  function isLeader() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    return items.length === 0 || items[0] === root
  }

  // Keys come from what GitHub reports, never from local dismissal or seen
  // state, so an undo or a refresh inside the undo window cannot replay an
  // alert. A thread in both Notifications and Mentions alerts once.
  function checkAlerts() {
    var items = []
    var notes = rawList("notifications")
    for (var i = 0; i < notes.length; i++)
      items.push({ key: "n" + notes[i].threadId + "@" + notes[i].updatedAt, item: notes[i], mention: false })
    var mentions = rawList("mentions")
    for (var j = 0; j < mentions.length; j++)
      if (mentions[j].notifUnread === true)
        items.push({ key: "m" + mentions[j].url + "@" + mentions[j].updatedAt, item: mentions[j], mention: true })
    var result = Inbox.freshAlerts(alertKeys, items)
    alertKeys = result.keys
    if (!desktopNotifications || !isLeader()) return

    var fresh = []
    var urls = Inbox.dict()
    for (var k = 0; k < result.fresh.length; k++) {
      var f = result.fresh[k]
      var url = String(f.item.url || "")
      var shown = f.mention ? mentionUnread(f.item) : dismissed[String(f.item.threadId)] === undefined
      if (!shown || urls[url] || inScope([f.item]).length === 0) continue
      urls[url] = true
      fresh.push(f)
    }
    if (fresh.length === 0) return

    var args = []
    if (fresh.length > 3) {
      var titles = []
      for (var m = 0; m < 3; m++) titles.push(String(fresh[m].item.title || ""))
      args = ["https://github.com/notifications", fresh.length + " new on GitHub",
              titles.join("\n") + "\n…and " + (fresh.length - 3) + " more"]
    } else {
      for (var n = 0; n < fresh.length; n++) {
        var it = fresh[n].item
        args.push(String(it.url || ""), String(it.title || ""),
                  it.repo + " · " + (fresh[n].mention ? "mentioned you" : reasonLabel(it.reason)))
      }
    }
    alertProcess.command = ["bash", notifyPath].concat(args)
    alertProcess.running = true
  }

  Process {
    id: alertProcess
    running: false
  }

  // ------------------------------------------------ settings view
  property bool settingsOpen: false
  property bool keysOpen: false
  // Bumped when the pointer rests on a row, so the row that was open folds.
  property int pointerRestSerial: 0
  property bool pointerFollowPending: false
  onPointerRestSerialChanged: if (pointerFollowPending) {
    pointerFollowPending = false
    syncPreviewToCursor()
  }
  signal lingerOpenRow()
  // The legend borrows the list's scroll, so give it back on every way out.
  property real keysScrollY: 0
  onKeysOpenChanged: {
    if (!panelFlick) return
    if (keysOpen && previewOpen) closePreview()
    if (keysOpen) { keysScrollY = panelFlick.contentY; panelFlick.contentY = 0; keyCatcher.forceActiveFocus() }
    else Qt.callLater(function() { panelFlick.contentY = keysScrollY })
  }
  property int settingsCursor: -1
  property var expandedOrgs: Inbox.dict()

  readonly property var scopeTree: {
    var extra = hiddenScopes.concat(focusScopes)
    var closed = rawList("closed")
    for (var i = 0; i < closed.length; i++) extra.push(String(closed[i].repo || ""))
    return Inbox.scopeTree([rawList("prs"), rawList("reviews"), rawList("issues"),
                            rawNotifications, rawList("mentions")], extra)
  }

  // Two switches, then one row per org with its repos under it when unfolded.
  readonly property int settingsToggleCount: 2
  readonly property var scopeRows: {
    var rows = []
    for (var i = 0; i < scopeTree.length; i++) {
      var o = scopeTree[i]
      var names = o.repos.map(function(r) { return r.repo })
      rows.push({ kind: "org", scope: o.org, org: o.org, count: o.count, siblings: names })
      if (expandedOrgs[o.org])
        for (var j = 0; j < o.repos.length; j++)
          rows.push({ kind: "repo", scope: o.repos[j].repo, org: o.org, count: o.repos[j].count, siblings: names })
    }
    return rows
  }
  readonly property int settingsRowCount: settingsToggleCount + scopeRows.length

  // Effective state of a settings row. An org reads "all", "some" or "none"
  // of its known repos, which drives the partial checkbox and target.
  function scopeState(row) {
    if (row.kind === "repo") {
      var item = { org: row.org, repo: row.scope }
      var shown = !Inbox.matches(item, hiddenScopes)
      var focused = Inbox.matches(item, focusScopes)
      return { hidden: shown ? "none" : "all", focus: focused ? "all" : "none", hiddenRepos: 0, focusRepos: 0 }
    }
    var hiddenRepos = 0
    var focusRepos = 0
    for (var i = 0; i < row.siblings.length; i++) {
      var repo = { org: row.org, repo: row.siblings[i] }
      if (Inbox.matches(repo, hiddenScopes)) hiddenRepos++
      if (Inbox.matches(repo, focusScopes)) focusRepos++
    }
    return {
      hidden: Inbox.orgState(hiddenScopes, row.org, row.siblings),
      focus: Inbox.orgState(focusScopes, row.org, row.siblings),
      hiddenRepos: hiddenRepos, focusRepos: focusRepos
    }
  }

  // An org acts on what its row shows: a partly hidden org becomes fully
  // shown, a partly focused org becomes fully focused.
  function toggleShown(row) {
    savePref("hidden", row.kind === "org"
      ? Inbox.setOrg(hiddenScopes, row.org, scopeState(row).hidden === "none")
      : Inbox.toggleRepo(hiddenScopes, row.scope))
  }

  function toggleFocus(row) {
    savePref("focus", row.kind === "org"
      ? Inbox.setOrg(focusScopes, row.org, scopeState(row).focus !== "all")
      : Inbox.toggleRepo(focusScopes, row.scope))
  }

  function setExpanded(org, open) {
    var next = Inbox.copy(expandedOrgs)
    if (open) next[org] = true
    else delete next[org]
    expandedOrgs = next
  }

  // From the keyboard the cursor lands on the first switch; from a click it
  // waits for the pointer.
  property real inboxScrollY: 0

  function openSettings(fromKeyboard) {
    if (previewOpen) closePreview()
    // Over the legend the list's own position is the one the legend saved.
    if (!settingsOpen && panelFlick) inboxScrollY = keysOpen ? keysScrollY : panelFlick.contentY
    keysOpen = false
    // A click on the gear can come from inside the find field: take the keys
    // back from it, or j/k would keep typing into a hidden query.
    keyCatcher.forceActiveFocus()
    settingsOpen = true
    cursorFromKeyboard = fromKeyboard === true
    cursorActive = fromKeyboard === true
    settingsCursor = fromKeyboard === true ? 0 : -1
    Qt.callLater(function() { if (panelFlick) panelFlick.contentY = 0 })
  }

  // Back to the inbox where it was left, cursor and scroll both.
  function closeSettings() {
    keysOpen = false
    settingsOpen = false
    Qt.callLater(function() { if (panelFlick) panelFlick.contentY = inboxScrollY })
  }

  onSettingsRowCountChanged: if (settingsCursor >= settingsRowCount) settingsCursor = settingsRowCount - 1

  function moveSettingsCursor(delta) {
    hoverGate.reset()
    cursorFromKeyboard = true
    cursorActive = true
    settingsCursor = clamp(settingsCursor + delta, 0, settingsRowCount - 1)
  }

  function settingsRow(i) { return i >= settingsToggleCount ? scopeRows[i - settingsToggleCount] : null }

  // Space/Enter flip the row's own switch or checkbox; f is focus everywhere.
  function activateSettings() {
    if (settingsCursor === 0) savePref("desktopNotifications", !desktopNotifications)
    else if (settingsCursor === 1) savePref("focusMode", !focusMode)
    else if (settingsRow(settingsCursor)) toggleShown(settingsRow(settingsCursor))
  }

  function focusKeyInSettings() {
    var row = settingsRow(settingsCursor)
    if (row) toggleFocus(row)
    else savePref("focusMode", !focusMode)
  }

  function foldSettings(dx) {
    var row = settingsRow(settingsCursor)
    if (!row) return
    if (row.kind === "org") { setExpanded(row.org, dx > 0); return }
    if (dx < 0) {
      // Fold from a repo: land on its org, then close it.
      for (var i = 0; i < scopeRows.length; i++)
        if (scopeRows[i].kind === "org" && scopeRows[i].org === row.org) settingsCursor = settingsToggleCount + i
      setExpanded(row.org, false)
    }
  }

  // ------------------------------------------------ preview
  //
  // `p` opens a pane beside the list for the PR or issue under the cursor,
  // and it follows the cursor. From there: open, comment, merge. Comment and
  // merge post to GitHub as the user, so each is an explicit second step,
  // and a merge is pinned to the head commit the pane showed.
  property bool previewOpen: false
  property string previewUrl: ""
  property var previewData: null
  // What the row already knows, shown the instant the pane opens.
  property var previewStub: null
  property string previewError: ""
  property bool previewLoading: false
  property var previewCache: Inbox.dict()
  property string previewMode: ""          // "", "comment" or "merge"
  property string previewNotice: ""
  property bool previewNoticeError: false
  property bool actionBusy: false
  property string mergeMethod: ""
  property bool commentFocused: false

  // The panel is kept on screen, so with the chip on the right half of the
  // bar it grows to the left. The pane goes on that side so the list stays
  // still while the panel widens. Read when the pane opens, not live.
  property bool paneOnLeft: true
  // The list's closed width (the panel's closed content width less the
  // panel's own padding), kept in both states, so it never re-wraps while
  // the panel widens or shrinks.
  readonly property real listWidth: closedContentWidth - (panel.contentWidth - keyCatcher.width)

  // Both columns need about 852 units. On a screen too narrow for that the
  // pane takes the panel on its own, and p or Esc goes back to the list.
  // Decided when the pane opens, from the room beside the closed card: the
  // pane goes on the chip's side if it fits there, the other side if it
  // fits there, and alone in the panel otherwise. That way widening never
  // pushes the list, even when the screen edge clamps the card.
  property bool paneFits: true
  readonly property bool paneSolo: previewOpen && !paneFits

  function pickPaneSide() {
    var w = panel.screenW
    if (w <= 0) { paneOnLeft = true; paneFits = true; return }
    var need = Style.space(452)
    var leftRoom = panel.cardOrigin.x - panel.margin
    var rightRoom = w - panel.margin - (panel.cardOrigin.x + panel.contentWidth)
    var preferLeft = panel.anchorScreenPos.x + panel.anchorW / 2 > w / 2
    if (preferLeft ? leftRoom >= need : rightRoom >= need) { paneOnLeft = preferLeft; paneFits = true }
    else if (preferLeft ? rightRoom >= need : leftRoom >= need) { paneOnLeft = !preferLeft; paneFits = true }
    else { paneOnLeft = preferLeft; paneFits = false }
  }
  signal commentPosted(string url)
  // A reload that must start fresh: an answer already in flight began
  // before the action and is discarded, so wait for it and ask again.
  property bool reloadPending: false

  function focusList() { keyCatcher.forceActiveFocus() }

  function previewableUrl(url) {
    return /^https:\/\/github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\/(pull|issues)\/[0-9]+$/.test(String(url || ""))
  }

  readonly property string cursorUrl: {
    var row = rowAt(cursor)
    return row && row.item && previewableUrl(row.item.url) ? String(row.item.url) : ""
  }

  // Back from comment or merge: catch up with the cursor if it moved.
  // After a finished comment or merge the pane stays on its item, notice
  // and all, until the user moves; only a cancel catches up at once.
  property bool holdAfterAction: false
  // Keys and real pointer motion call this before moving the cursor. A
  // cursor change without it (a refresh removed the merged PR, say) keeps
  // the finished action's item and notice on screen.
  function releaseHold(cause) {
    if (!holdAfterAction || !Inbox.releasesHold(cause)) return
    holdAfterAction = false
    // The cursor may not change (pointer motion within the row, Up on the
    // first row), so bring the pane to it explicitly; with the pointer, once
    // it rests, like any other pointer follow.
    if (cause === "pointer") pointerFollowPending = true
    else Qt.callLater(syncPreviewToCursor)
  }

  // Every place following resumes goes through Inbox.followDecision.
  function syncPreviewToCursor() {
    var act = Inbox.followDecision({ open: previewOpen, mode: previewMode, busy: actionBusy,
      hold: holdAfterAction, cursorUrl: cursorUrl, previewUrl: previewUrl })
    if (act === "clear") {
      previewDebounce.stop()
      previewUrl = ""
      previewData = null
      previewStub = null
      previewError = ""
      previewLoading = false
    } else if (act === "show") {
      showPreview(cursorUrl, true)
    }
  }
  onPreviewModeChanged: {
    if (previewMode !== "" || !previewOpen || actionBusy) return
    if (holdAfterAction) return
    syncPreviewToCursor()
  }

  function togglePreview() {
    if (actionBusy) return
    if (previewOpen) closePreview()
    else openPreview()
  }

  // While a comment or merge runs nothing replaces or closes the pane, by
  // key or by mouse, so its result always lands on its own item.
  function openPreview() {
    if (cursorUrl === "" || actionBusy) return
    if (!previewOpen) pickPaneSide()
    previewOpen = true
    showPreview(cursorUrl)
  }

  function closePreview() {
    if (actionBusy) return
    holdAfterAction = false
    previewOpen = false
    previewMode = ""
    keyCatcher.forceActiveFocus()
  }

  // A cached preview shows at once. Otherwise following the cursor waits a
  // moment, so j/k through a list does not fire one gh call per row. With
  // the pane closed, a row the cursor rests on is fetched in the background,
  // so `p` usually opens on a cache hit.
  onCursorUrlChanged: {
    if (!opened) return
    // Only a deliberate move releases a held result (see releaseHold). The
    // pane switches at once, so c and m only ever act on what is shown, and
    // only the fetch waits for the cursor to settle; a row with nothing to
    // preview empties it, so Enter cannot open the previous PR.
    if (holdAfterAction) return
    // The pointer crossing rows on its way to the pane's buttons must not
    // swap the preview: it follows once the pointer rests on a row (the
    // row's 350 ms rest), keys follow at once.
    if (previewOpen && !cursorFromKeyboard) { pointerFollowPending = true; return }
    if (previewOpen) syncPreviewToCursor()
    else prefetchTimer.restart()
  }
  Timer {
    id: previewDebounce
    interval: 120
    onTriggered: if (root.previewMode === "" && !root.actionBusy && root.previewLoading) {
      root.loadPreview()
      root.prefetchNeighbors()
    }
  }
  Timer {
    id: prefetchTimer
    interval: 400
    onTriggered: if (!root.previewOpen) root.prefetch(root.cursorUrl)
  }

  function cachedPreview(url, maxAge) {
    var hit = Inbox.has(previewCache, url) ? previewCache[url] : null
    return hit && Date.now() - hit.at < maxAge ? hit : null
  }

  function stubFor(url) {
    var row = rowAt(cursor)
    var it = row && row.item && String(row.item.url) === url ? row.item : null
    if (!it) return null
    return { kind: /\/pull\//.test(url) ? "pr" : "issue", url: url, title: String(it.title || ""), stub: true }
  }

  // Up to five minutes old shows at once. Older than a minute it is
  // refreshed in the background and replaced when the answer lands.
  property bool previewStale: false
  property int unknownRetries: 0
  Timer {
    id: unknownRetryTimer
    interval: 3000
    onTriggered: if (root.previewOpen && root.previewMode === "") root.reloadPreview()
  }

  // Ask GitHub again for the item on screen, ignoring the cache.
  function reloadPreview() {
    if (previewUrl === "" || actionBusy) return
    var next = Inbox.copy(previewCache)
    delete next[previewUrl]
    previewCache = next
    previewLoading = true
    loadPreview()
  }

  function showPreview(url, deferFetch) {
    if (actionBusy) return
    if (url !== previewUrl) unknownRetries = 0
    previewStale = false
    previewUrl = url
    previewNotice = ""
    previewMode = ""
    previewStub = stubFor(url)
    previewError = ""
    var hit = cachedPreview(url, 300000)
    previewData = hit ? hit.data : null
    previewLoading = !hit || Date.now() - hit.at > 60000
    if (previewLoading && deferFetch === true) { previewDebounce.restart(); return }
    if (previewLoading) loadPreview()
    prefetchNeighbors()
  }

  function prefetchNeighbors() {
    for (var delta = -1; delta <= 1; delta += 2) {
      var row = rowAt(cursor + delta)
      if (row && row.item) prefetch(String(row.item.url))
    }
  }

  // Background fetches, at most three waiting, one running, and never ahead
  // of the visible pane's own fetch.
  property var prefetchQueue: []

  // A URL that just failed waits a minute, and background fetches start at
  // most every 800 ms, so a failing row cannot be hammered by j/k.
  property var failedAt: Inbox.dict()
  property double lastPrefetchAt: 0

  function prefetch(url) {
    if (!previewableUrl(url) || cachedPreview(url, 60000)) return
    if (Inbox.has(failedAt, url) && Date.now() - failedAt[url] < 60000) return
    if ((prefetchProcess.running && prefetchProcess.requested === url) || prefetchQueue.indexOf(url) >= 0) return
    if (previewProcess.running && previewProcess.requested === url) return
    prefetchQueue = prefetchQueue.concat([url]).slice(-3)
    runPrefetch()
  }

  function runPrefetch() {
    if (prefetchProcess.running || previewProcess.running || prefetchQueue.length === 0) return
    var wait = 800 - (Date.now() - lastPrefetchAt)
    if (wait > 0) { prefetchCadence.interval = wait; prefetchCadence.restart(); return }
    lastPrefetchAt = Date.now()
    var url = prefetchQueue[0]
    prefetchQueue = prefetchQueue.slice(1)
    var failedRecently = Inbox.has(failedAt, url) && Date.now() - failedAt[url] < 60000
    if (cachedPreview(url, 60000) || failedRecently) { Qt.callLater(runPrefetch); return }
    prefetchProcess.requested = url
    prefetchProcess.startedAt = Date.now()
    prefetchProcess.command = ["bash", previewPath, "view", url]
    prefetchProcess.running = true
  }

  Timer {
    id: prefetchCadence
    onTriggered: root.runPrefetch()
  }

  Process {
    id: prefetchProcess
    property string requested: ""
    property double startedAt: 0
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPreview(text, prefetchProcess.requested, prefetchProcess.startedAt)
    }
    onRunningChanged: if (!running) {
      if (root.reloadPending) Qt.callLater(root.loadPreview)
      Qt.callLater(root.runPrefetch)
    }
  }

  // One visible fetch at a time, beside at most one background fetch. A
  // cursor that moved on while it ran gets its own call as soon as this one
  // ends, and the stale answer only fills the cache. A background fetch
  // already running for this URL is simply awaited.
  function loadPreview() {
    if (previewUrl === "") return
    if (!reloadPending && prefetchProcess.running && prefetchProcess.requested === previewUrl) return
    if (previewProcess.running) return
    if (reloadPending && prefetchProcess.running && prefetchProcess.requested === previewUrl) return
    reloadPending = false
    previewProcess.requested = previewUrl
    previewProcess.startedAt = Date.now()
    previewProcess.command = ["bash", previewPath, "view", previewUrl]
    previewProcess.running = true
  }

  function applyPreview(text, url, startedAt) {
    if (Inbox.has(invalidatedAt, url) && startedAt < invalidatedAt[url]) return
    var parsed = null
    if (String(text || "").length <= 1048576) {
      try { parsed = JSON.parse(text) } catch (e) { parsed = null }
    }
    if (!parsed || typeof parsed !== "object") parsed = { error: "Unreadable preview data" }
    var ok = String(parsed.error || "") === "" && parsed.url === url
    if (!ok) {
      var failed = Inbox.copy(failedAt)
      failed[url] = Date.now()
      failedAt = failed
    }
    if (ok) {
      var next = Object.keys(previewCache).length > 50 ? Inbox.dict() : Inbox.copy(previewCache)
      next[url] = { data: parsed, at: Date.now() }
      previewCache = next
    }
    if (url !== previewUrl) return
    previewLoading = false
    // A failed refresh keeps the older preview on screen, marked as such.
    if (!ok && previewData && previewData.url === url) { previewStale = true; return }
    previewStale = false
    // GitHub computes mergeability lazily: ask again a few times.
    if (ok && parsed.kind === "pr" && parsed.mergeable === "UNKNOWN" && unknownRetries < 3) {
      unknownRetries++
      unknownRetryTimer.restart()
    }
    previewError = ok ? "" : String(parsed.error || "Unreadable preview data")
    previewData = ok ? parsed : null
  }

  Process {
    id: previewProcess
    property string requested: ""
    property double startedAt: 0
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPreview(text, previewProcess.requested, previewProcess.startedAt)
    }
    onRunningChanged: if (!running) {
      if (root.reloadPending || (root.previewLoading && root.previewUrl !== requested)) Qt.callLater(root.loadPreview)
      Qt.callLater(root.runPrefetch)
    }
  }

  // Why the merge button cannot merge, or "" when it can.
  readonly property string mergeBlock: {
    var d = previewData
    if (!d || d.kind !== "pr") return "Only pull requests merge"
    if (d.state === "MERGED") return "Already merged"
    if (d.state === "CLOSED") return "Closed"
    if (d.state === "DRAFT") return "Draft: mark it ready for review first"
    if (d.canMerge === false) return "You do not have permission to merge here"
    if (d.mergeable === "CONFLICTING") return "Has conflicts with " + d.base
    if (d.mergeable !== "MERGEABLE") return "GitHub is still checking mergeability"
    if (d.mergeState === "BLOCKED") return "Blocked by required reviews or checks"
    if (d.mergeState === "BEHIND") return "Behind " + d.base + ": update the branch first"
    if (!d.mergeMethods || d.mergeMethods.length === 0) return "Merging is turned off for this repo"
    if (!d.headSha) return "Head commit unknown"
    return ""
  }

  function startComment() {
    if (!previewOpen) return
    if (previewMode === "comment") { previewPane.focusComment(); return }
    if (!previewData || actionBusy) return
    previewDebounce.stop()
    previewNotice = ""
    previewMode = "comment"
  }

  // The merge strip freezes what it asks about: URL, number, base and the
  // head commit shown. A refresh landing meanwhile cannot change the target.
  property var mergeTarget: null

  function startMerge() {
    if (!previewOpen || !previewData || actionBusy || previewMode !== "") return
    if (mergeBlock !== "") { notice(mergeBlock, false, true); return }
    previewDebounce.stop()
    mergeTarget = { url: previewUrl, sha: String(previewData.headSha), base: String(previewData.base), number: previewData.number }
    mergeMethod = previewData.mergeMethods[0]
    previewNotice = ""
    previewMode = "merge"
  }

  function cycleMergeMethod(delta) {
    if (actionBusy) return
    var methods = previewData && previewData.mergeMethods ? previewData.mergeMethods : []
    if (methods.length < 2) return
    var i = methods.indexOf(mergeMethod)
    mergeMethod = methods[((i + delta) % methods.length + methods.length) % methods.length]
  }

  // Three tones: errors red, results ("Merged") plain, reasons dim.
  property bool previewNoticeDim: false
  function notice(text, isError, isDim) {
    previewNotice = text
    previewNoticeError = isError === true
    previewNoticeDim = isDim === true
  }

  function sendComment(text) {
    if (!previewOpen || previewMode !== "comment") return
    if (actionBusy || String(text || "").trim() === "" || previewUrl === "") return
    actionBusy = true
    actionProcess.kind = "comment"
    actionProcess.target = previewUrl
    actionProcess.payload = String(text)
    actionProcess.stdinEnabled = true
    actionProcess.command = ["bash", previewPath, "comment", previewUrl]
    actionProcess.running = true
  }

  // A fresh Enter (the Shortcut rejects repeats) or the button: `m` and
  // Space never confirm, so a held key cannot open and confirm in one go.
  function confirmMerge() {
    if (actionBusy || previewMode !== "merge" || !mergeTarget) return
    if (previewData && String(previewData.headSha) !== mergeTarget.sha) {
      previewMode = ""
      notice("New commits arrived since you opened this. Review them, then press m again.", true)
      return
    }
    if (previewData && String(previewData.base) !== mergeTarget.base) {
      previewMode = ""
      notice("This PR now targets " + previewData.base + ". Review it, then press m again.", true)
      return
    }
    actionBusy = true
    actionProcess.kind = "merge"
    actionProcess.target = mergeTarget.url
    actionProcess.payload = ""
    actionProcess.stdinEnabled = false
    actionProcess.command = ["bash", previewPath, "merge", mergeTarget.url, mergeMethod, mergeTarget.sha, mergeTarget.base]
    actionProcess.running = true
  }

  // The pane cannot move on while an action runs (see onCursorUrlChanged
  // and the Esc handling), so its result always lands on its own item.
  property bool actionUnseen: false

  function actionFinished(text) {
    actionBusy = false
    if (!opened) actionUnseen = true
    var parsed = null
    try { parsed = JSON.parse(text) } catch (e) { parsed = null }
    var kind = actionProcess.kind
    if (!parsed || parsed.ok !== true) {
      notice(parsed && parsed.error ? String(parsed.error) : "GitHub did not answer", true)
      // A failed post keeps its draft: give the box the keys back.
      if (previewMode === "comment") Qt.callLater(function() { previewPane.focusComment() })
      return
    }
    if (kind === "comment") commentPosted(actionProcess.target)
    holdAfterAction = true
    previewMode = ""
    if (previewUrl === actionProcess.target) notice(kind === "merge" ? "Merged" : "Comment posted", false)
    // Show what GitHub now says, and let the list catch up with a merge.
    // Any answer to a request started before now is out of date.
    var stale = Inbox.copy(invalidatedAt)
    stale[actionProcess.target] = Date.now()
    invalidatedAt = stale
    var next = Inbox.copy(previewCache)
    delete next[actionProcess.target]
    previewCache = next
    if (previewUrl === actionProcess.target) {
      previewLoading = true
      reloadPending = true
      loadPreview()
    }
    if (kind === "merge") refreshNow()
  }

  property var invalidatedAt: Inbox.dict()

  // Comment text goes in on stdin, never argv, which any local user can read.
  Process {
    id: actionProcess
    property string kind: ""
    property string target: ""
    property string payload: ""
    running: false
    onStarted: {
      if (kind === "comment") write(payload)
      payload = ""
      stdinEnabled = false
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.actionFinished(text)
    }
  }

  // The line under the list: what the keys do for the row under the cursor.
  function hintText() {
    if (lastUndo) {
      var left = Math.max(1, Math.ceil((lastUndo.due - undoNow) / 1000))
      var earlier = undoBatches.length - 1
      return (lastUndoSize === 1 ? "Dismissed" : "Dismissed " + lastUndoSize)
        + (earlier > 0 ? " · u undoes the last (" + left + "s) · " + earlier + " earlier sending"
                       : " · u or click to undo (" + left + "s)")
    }
    if (keysOpen) return "? or Esc back"
    if (actionBusy) return actionProcess.kind === "merge" ? "Merging…" : "Posting the comment…"
    if (previewOpen && previewMode === "merge")
      return "↵ confirm merge" + (previewData && previewData.mergeMethods && previewData.mergeMethods.length > 1 ? " · h/l method" : "") + " · Esc cancel"
    if (previewOpen && previewMode === "comment") return "Ctrl+↵ send · Esc cancel"
    if (previewOpen) return "j/k next item · J/K scroll · ↵ open · c comment" + (previewData && previewData.kind === "pr" && mergeBlock === "" ? " · m merge" : "")
      + (paneSolo ? " · p back to the list" : " · p close")
    if (settingsOpen) {
      var srow = settingsRow(settingsCursor)
      if (!srow) return "space toggle · j/k move · s or Esc back"
      return "space show/hide · f focus · "
        + (srow.kind === "org" ? (expandedOrgs[srow.org] ? "h fold" : "l repos") : "h fold")
        + " · s back"
    }
    var row = cursorActive ? rowAt(cursor) : null
    if (row && row.notification) return "↵ open · d dismiss · " + (previewableUrl(row.item.url) ? "p preview" : "D dismiss all") + " · ? keys"
    if (row && row.mention && mentionUnread(row.item)) return "↵ open · d mark seen · ? keys"
    if (row && previewableUrl(row.item.url)) return "↵ open · p preview · / find · ? keys"
    return "j/k move · ↵ open · / find · s settings · ? keys"
  }

  function toggleFocusMode() {
    savePref("focusMode", !focusMode)
  }

  function applySeen(text) {
    if (String(text || "").length > 262144) return
    try {
      var parsed = JSON.parse(text)
      if (parsed && typeof parsed === "object") seen = Inbox.copy(parsed)
    } catch (e) { /* first run: no file yet */ }
  }

  // Orgs seen while the panel is open keep their tab, even after GitHub
  // stops returning their last row, unless settings take them out of scope.
  property var sessionOrgs: Inbox.dict()
  onLiveOrgsChanged: {
    var next = Inbox.copy(sessionOrgs)
    for (var i = 0; i < liveOrgs.length; i++) next[liveOrgs[i]] = true
    sessionOrgs = next
  }

  // Whether any repo of the org can still show: a hidden org with a
  // "!org/repo" exception can, and focus needs the org or one of its repos.
  function orgInScope(org) {
    var excepted = hiddenScopes.some(function(h) { return h.indexOf("!" + org + "/") === 0 })
    if (hiddenScopes.indexOf(org) >= 0 && !excepted) return false
    if (!focusNarrowing) return true
    return focusScopes.some(function(f) { return f === org || f.indexOf(org + "/") === 0 })
  }

  readonly property var orgs: {
    var result = liveOrgs.slice()
    for (var org in sessionOrgs)
      if (result.indexOf(org) < 0 && orgInScope(org)) result.push(org)
    result.sort()
    return result
  }

  readonly property var liveOrgs: {
    var seen = Inbox.dict()
    var result = []
    // Raw notifications, so dismissing an org's last row keeps its tab.
    var all = allPrs.concat(allReviews).concat(allIssues).concat(inScope(rawList("notifications")))
      .concat(allMentions).concat(allClosed)
    for (var i = 0; i < all.length; i++) {
      var org = String(all[i].org || "")
      if (org !== "" && !seen[org]) { seen[org] = true; result.push(org) }
    }
    result.sort()
    return result
  }

  function filtered(list) {
    if (selectedOrg === "") return list
    var result = []
    for (var i = 0; i < list.length; i++)
      if (list[i].org === selectedOrg) result.push(list[i])
    return result
  }

  readonly property var prs: filtered(allPrs)
  readonly property var reviews: filtered(allReviews)
  readonly property var issues: filtered(allIssues)
  readonly property var notifications: filtered(allNotifications)
  readonly property var mentions: filtered(allMentions)
  // Org-filter first, then cap: each org tab gets its own most-recent slice.
  readonly property var closed: filtered(allClosed).slice(0, Math.max(1, Number(setting("closedLimit", 5))))

  // ------------------------------------------------ fuzzy find & keyboard cursor
  //
  // The query filters on top of the org filter; matching a section name keeps
  // that whole section.
  property bool searchOpen: false
  property string query: ""

  function fuzzy(q, s) {
    s = String(s || "").toLowerCase()
    var i = 0
    for (var j = 0; j < s.length && i < q.length; j++)
      if (s.charAt(j) === q.charAt(i)) i++
    return i === q.length
  }

  function sectionRows(list, sectionName) {
    var q = query.trim().toLowerCase()
    if (q === "" || fuzzy(q, sectionName)) return list
    var result = []
    for (var i = 0; i < list.length; i++)
      if (fuzzy(q, String(list[i].title || "") + " " + String(list[i].repo || ""))) result.push(list[i])
    return result
  }

  readonly property var shownPrs: sectionRows(prs, "pull requests")
  readonly property var shownReviews: sectionRows(reviews, "review requests")
  readonly property var shownIssues: sectionRows(issues, "issues")
  readonly property var shownNotifications: sectionRows(notifications, "notifications")
  readonly property var shownMentions: sectionRows(mentions, "mentions")
  readonly property var shownClosed: sectionRows(closed, "recently closed")

  // One flat cursor over every visible row, in display order.
  readonly property int notificationBase: 0
  readonly property int prBase: shownNotifications.length
  readonly property int reviewBase: prBase + shownPrs.length
  readonly property int issueBase: reviewBase + shownReviews.length
  readonly property int mentionBase: issueBase + shownIssues.length
  readonly property int closedBase: mentionBase + shownMentions.length
  readonly property int rowCount: closedBase + shownClosed.length

  property int cursor: -1
  property bool cursorFromKeyboard: false

  onQueryChanged: {
    cursor = query !== "" && rowCount > 0 ? 0 : -1
    cursorActive = cursor >= 0
    if (panelFlick) panelFlick.contentY = 0
  }

  // Hiding or focusing can take the selected org tab away.
  onOrgsChanged: if (selectedOrg !== "" && orgs.indexOf(selectedOrg) < 0) selectedOrg = ""

  // Dismissing the last rows must not leave the cursor past the end.
  onRowCountChanged: if (cursor >= rowCount) cursor = rowCount - 1

  onSelectedOrgChanged: {
    cursor = -1
    if (panelFlick) panelFlick.contentY = 0
  }

  function rowAt(i) {
    if (i < 0) return null
    if (i < prBase) return { item: shownNotifications[i], mention: false, notification: true }
    if (i < reviewBase) return { item: shownPrs[i - prBase], mention: false }
    if (i < issueBase) return { item: shownReviews[i - reviewBase], mention: false }
    if (i < mentionBase) return { item: shownIssues[i - issueBase], mention: false }
    if (i < closedBase) return { item: shownMentions[i - mentionBase], mention: true }
    if (i < rowCount) return { item: shownClosed[i - closedBase], mention: false }
    return null
  }

  function moveCursor(delta) {
    releaseHold("key")
    if (rowCount === 0) return
    // The pointer moved the cursor without the pane following yet: j/k step
    // from the item the pane shows, not from the row the pointer crossed.
    if (pointerFollowPending && previewOpen && previewUrl !== "") {
      pointerFollowPending = false
      for (var r = 0; r < rowCount; r++) {
        var at = rowAt(r)
        if (at && at.item && String(at.item.url) === previewUrl) { cursor = r; break }
      }
    }
    hoverGate.reset()
    cursorFromKeyboard = true
    cursorActive = true
    cursor = clamp(cursor + delta, 0, rowCount - 1)
  }

  function sectionStarts() {
    var starts = []
    if (shownNotifications.length > 0) starts.push(notificationBase)
    if (shownPrs.length > 0) starts.push(prBase)
    if (shownReviews.length > 0) starts.push(reviewBase)
    if (shownIssues.length > 0) starts.push(issueBase)
    if (shownMentions.length > 0) starts.push(mentionBase)
    if (shownClosed.length > 0) starts.push(closedBase)
    return starts
  }

  function jumpSection(direction) {
    releaseHold("jump")
    var starts = sectionStarts()
    if (starts.length === 0) return
    hoverGate.reset()
    cursorFromKeyboard = true
    cursorActive = true
    if (direction > 0) {
      for (var i = 0; i < starts.length; i++)
        if (starts[i] > cursor) { cursor = starts[i]; return }
      cursor = starts[0]
    } else {
      for (var j = starts.length - 1; j >= 0; j--)
        if (starts[j] < cursor) { cursor = starts[j]; return }
      cursor = starts[starts.length - 1]
    }
  }

  function activateCursor() {
    var row = rowAt(cursor)
    if (!row || !row.item) return
    if (row.mention) markSeen(row.item)
    if (row.notification) dismissNotifications([row.item])
    openUrl(row.item.url)
  }

  function ensureVisible(rowItem) {
    if (!panelFlick || !rowItem) return
    var y = rowItem.mapToItem(panelFlick.contentItem, 0, 0).y
    // Top padding keeps the section header in view.
    var padTop = Style.space(36)
    var padBottom = Style.space(8)
    if (y - padTop < panelFlick.contentY)
      panelFlick.contentY = Math.max(0, y - padTop)
    else if (y + rowItem.height + padBottom > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = Math.min(Math.max(0, panelFlick.contentHeight - panelFlick.height),
                                     y + rowItem.height + padBottom - panelFlick.height)
  }

  // Find lives in the inbox, so it leaves settings and scrolls to the field.
  function scrollPreview(direction) { previewPane.scrollBy(direction) }

  // Open from the pane does what opening the row does (a notification is
  // dismissed, a mention marked seen) when the pane shows the cursor's row.
  function openPreviewed() {
    var row = rowAt(cursor)
    if (row && row.item && String(row.item.url) === previewUrl) activateCursor()
    else openUrl(previewUrl)
  }

  function openSearch() {
    releaseHold("search")
    if (previewMode === "merge" && !actionBusy) previewMode = ""
    // Single-column: the search field lives in the list, so show the list.
    if (paneSolo && !actionBusy) closePreview()
    keysOpen = false
    if (settingsOpen) closeSettings()
    Qt.callLater(function() { if (panelFlick) panelFlick.contentY = 0 })
    searchOpen = true
    Qt.callLater(function() { searchField.forceActiveFocus(); searchField.selectAll() })
  }

  function closeSearch() {
    searchField.text = ""
    searchOpen = false
    keyCatcher.forceActiveFocus()
  }

  // Enter keeps the filter and hands focus back to list navigation.
  function acceptSearch() {
    if (cursor === -1 && rowCount > 0) {
      cursorFromKeyboard = true
      cursorActive = true
      cursor = 0
    }
    keyCatcher.forceActiveFocus()
  }

  function selectOrg(index) {
    releaseHold("org")
    var count = orgs.length + 1
    var wrapped = ((index % count) + count) % count
    selectedOrg = wrapped === 0 ? "" : orgs[wrapped - 1]
  }

  readonly property int selectedOrgIndex: selectedOrg === "" ? 0 : orgs.indexOf(selectedOrg) + 1

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function timeAgo(iso) {
    var ms = root.nowMs - new Date(String(iso || "")).getTime()
    if (!isFinite(ms) || ms < 0) return ""
    var minutes = Math.floor(ms / 60000)
    if (minutes < 1) return "now"
    if (minutes < 60) return minutes + "m"
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + "h"
    var days = Math.floor(hours / 24)
    if (days < 30) return days + "d"
    return Math.floor(days / 30) + "mo"
  }

  function openUrl(url) {
    // Only github.com, and never a quote that could escape the shell single
    // quoting: a poisoned cache must not be able to open anything else.
    var target = String(url || "")
    if (target.indexOf("https://github.com/") !== 0 || target.indexOf("'") >= 0 || root.bar === null) return
    root.bar.run("omarchy-launch-browser '" + target + "'")
    root.close()
  }

  // A refresh asked for while one runs (a merge just landed) runs after it,
  // so the list never keeps showing what the pane says is merged.
  property bool refreshQueued: false

  function refreshNow() {
    if (fetchProcess.running) refreshQueued = true
    else fetchProcess.running = true
    if (previewOpen && previewMode === "") reloadPreview()
  }

  function applyFetch(text) {
    // fetch.sh enforces its own output ceiling; this is the shell-side line.
    if (String(text || "").length > 4194304) {
      retryTimer.restart()
      return
    }
    var parsed = null
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      console.warn("github", "bad fetch output", e)
    }
    if (!parsed || typeof parsed !== "object") parsed = { error: "Unreadable data from GitHub, retrying soon" }
    if (String(parsed.error || "") !== "") {
      // Transient failure: keep the stale lists visible, surface the error.
      // lastFetchMs stays put so "Updated Xh ago" keeps telling the truth.
      var stale = Inbox.copy(feed)
      stale.user = String(feed.user || parsed.user || "")
      stale.error = String(parsed.error)
      feed = stale
      retryTimer.restart()
      return
    }
    // A refresh can add rows above the cursor: keep it on the same item, not
    // the same row number, so the next `d` hits what the user is looking at.
    var anchor = rowAt(cursor)
    var anchorUrl = anchor && anchor.item ? String(anchor.item.url || "") : ""
    var anchorKind = anchor ? (anchor.notification ? "n" : (anchor.mention ? "m" : "")) : ""
    var anchorScope = settingsRow(settingsCursor) ? settingsRow(settingsCursor).scope : ""
    feed = parsed
    if (anchorUrl !== "")
      for (var r = 0; r < rowCount; r++) {
        var row = rowAt(r)
        var kind = row.notification ? "n" : (row.mention ? "m" : "")
        if (row.item && String(row.item.url || "") === anchorUrl && kind === anchorKind) { cursor = r; break }
      }
    if (anchorScope !== "")
      for (var q = 0; q < scopeRows.length; q++)
        if (scopeRows[q].scope === anchorScope) { settingsCursor = settingsToggleCount + q; break }
    // A dismissal only needs remembering while GitHub still reports the
    // thread unread and unchanged.
    var kept = Inbox.dict()
    var notes = rawList("notifications")
    for (var i = 0; i < notes.length; i++) {
      var id = String(notes[i].threadId)
      if (dismissed[id] !== undefined && dismissed[id] === String(notes[i].updatedAt || "")) kept[id] = dismissed[id]
    }
    dismissed = kept
    checkAlerts()
    loaded = true
    // When GitHub was asked, not when the 60s cache answered.
    lastFetchMs = typeof parsed.fetchedAt === "number" ? parsed.fetchedAt * 1000 : Date.now()
    nowMs = Date.now()
    retryTimer.stop()
    if (selectedOrg !== "" && orgs.indexOf(selectedOrg) < 0) selectedOrg = ""
  }

  function reasonLabel(reason) {
    return String(reason || "").replace(/_/g, " ")
  }

  function footerText() {
    if (!loaded) return String(feed.error || "") !== "" ? "Not loaded yet" : "Loading…"
    if (lastFetchMs <= 0) return ""
    var ago = timeAgo(new Date(lastFetchMs).toISOString())
    return ago === "" ? "" : "Updated " + (ago === "now" ? "just now" : ago + " ago")
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    // A comment or merge still running, or finished while the panel was
    // closed, keeps its pane so its outcome is seen.
    var keepPane = previewOpen && (actionBusy || actionUnseen)
    // The cursor reset below must not empty the pane being kept.
    if (keepPane && !actionBusy) holdAfterAction = true
    actionUnseen = false
    if (!keepPane) {
      previewOpen = false
      previewMode = ""
    }
    sessionOrgs = Inbox.dict()
    cursorActive = false
    cursor = -1
    // After the cursor reset, so no row still holds the cursor and skips it.
    pointerRestSerial++
    cursorFromKeyboard = false
    searchOpen = false
    searchField.text = ""
    settingsOpen = false
    keysOpen = false
    settingsCursor = -1
    hoverGate.reset()
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    refreshNow()
    // One focus choice: a restored comment box, otherwise the list.
    Qt.callLater(function() {
      if (root.previewOpen && root.previewMode === "comment" && !root.actionBusy) previewPane.focusComment()
      else keyCatcher.forceActiveFocus()
    })
  }

  // Filters synthetic hover churn while keyboard scrolling moves rows under
  // a stationary pointer; rows only take the cursor on real pointer motion.
  PointerMoveGate {
    id: hoverGate
    referenceItem: panelFlick
  }

  readonly property string seenPath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
    + "/omarchy/github-mentions-seen.json"

  // Watcher only, never a reader or writer: FileView has no size bound and
  // would hang opening a planted FIFO. preload:false and never calling
  // text() keep it from reading.
  FileView {
    id: seenFile
    path: root.seenPath
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.readSeen()
  }

  // Writes go through umask 077 + temp + atomic rename: the file lists
  // private repo URLs and must not be world-readable (FileView cannot set
  // modes), and the predictable path must never be opened for writing.
  Process {
    id: seenWriteProcess
    running: false
  }

  function writeSeen(json) {
    seenWriteProcess.command = ["bash", "-c",
      'umask 077; mkdir -p "$(dirname "$1")" && tmp=$(mktemp "$1.XXXXXX") && printf "%s\n" "$2" >"$tmp" && mv -f "$tmp" "$1"',
      "--", seenPath, json]
    seenWriteProcess.running = true
  }

  // Bounded read of the user-writable seen file: 256KB cap, refuses
  // symlinks, and a FIFO yields EAGAIN instead of blocking a shell thread.
  Process {
    id: seenReadProcess
    running: false
    command: ["dd", "if=" + root.seenPath, "iflag=nofollow,nonblock", "bs=64k", "count=4", "status=none"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySeen(text)
    }
  }

  function readSeen() {
    if (!seenReadProcess.running) seenReadProcess.running = true
  }

  Component.onCompleted: readSeen()

  Process {
    id: fetchProcess
    running: false
    onRunningChanged: if (!running && root.refreshQueued) {
      root.refreshQueued = false
      Qt.callLater(root.refreshNow)
    }
    command: ["bash", root.scriptPath,
      "--mentions", String(Math.max(1, Number(root.setting("mentionLimit", 30)))),
      "--closed-days", String(Math.max(1, Number(root.setting("closedDays", 30))))]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyFetch(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("github", text.trim())
    }
  }

  Timer {
    interval: Math.max(60, Number(root.setting("refreshIntervalSec", 300))) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshNow()
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // Short-leash retry after a failed fetch; the first success stops it.
  Timer {
    id: retryTimer
    interval: 30000
    repeat: false
    onTriggered: root.refreshNow()
  }

  // Suspend/resume detector: a wall-clock jump past the heartbeat interval
  // means the machine slept — refresh instead of serving hours-old numbers.
  property double lastHeartbeatMs: Date.now()

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: {
      var now = Date.now()
      if (now - root.lastHeartbeatMs > 180000) root.refreshNow()
      root.lastHeartbeatMs = now
    }
  }

  // One instance per monitor, but only one owns the IPC target, and the bar
  // facade handed to third-party widgets has no findPanelWidget. Open copy
  // wins, then the focused monitor's copy. Zero-size copies are the hidden
  // placeholders a center-anchored layout keeps around.
  function routedInstance() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    var monitor = Hyprland.focusedMonitor
    var focused = monitor ? String(monitor.name || "") : ""
    var onFocused = null
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      if (!item || item.visible !== true || item.width <= 0 || item.height <= 0) continue
      if (item.opened === true) return item
      var window = item.QsWindow ? item.QsWindow.window : null
      if (!onFocused && focused && window && window.screen && String(window.screen.name || "") === focused) onFocused = item
    }
    return onFocused || root
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.routedInstance().open() }
    function close(): void { root.routedInstance().close() }
    function show(): void { root.routedInstance().open() }
    function hide(): void { root.routedInstance().close() }
    function toggle(): void {
      var target = root.routedInstance()
      if (target.opened) target.close()
      else target.open()
    }
    function refresh(): string { root.routedInstance().refreshNow(); root.refreshNow(); return "ok" }
    function settings(): string {
      var target = root.routedInstance()
      target.open()
      target.openSettings(true)
      return "ok"
    }
    function focus(): string {
      root.routedInstance().toggleFocusMode()
      return root.routedInstance().focusMode ? "on" : "off"
    }
    function find(): string {
      var target = root.routedInstance()
      target.open()
      target.openSearch()
      return "ok"
    }
  }

  // The shell centers the panel under its anchor, clamped to the screen.
  // Shifting the anchor by half the extra width, away from the side the
  // pane opens on, keeps the list's edge fixed wherever the chip sits; at
  // a screen edge the clamp already does.
  Item {
    id: panelAnchor
    parent: button
    width: button.width
    height: button.height
    x: (root.paneOnLeft ? -1 : 1) * Math.max(0, panel.contentWidth - root.closedContentWidth) / 2
  }

  readonly property real closedContentWidth: panel.fittedContentWidth(Style.space(400))

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Focus mode swaps the octocat for a target so a quiet chip never looks
    // like an empty inbox.
    text: (root.focusNarrowing ? "󰓾" : "") + (root.workCount > 0 ? " " + root.workCount : "")
    active: root.allNotifications.length > 0 || root.unreadMentions > 0
    tooltipText: root.feed && String(root.feed.error || "") !== ""
      ? String(root.feed.error)
      : (root.focusNarrowing ? "Focus mode · " : "") + root.allPrs.length + " PRs · " + root.allReviews.length + " reviews · "
        + root.allIssues.length + " issues · "
        + root.allNotifications.length + " notifications"
        + (root.unreadMentions > 0 ? " · " + root.unreadMentions + " new mentions" : "")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (root.bar) root.bar.run("omarchy-launch-browser 'https://github.com/notifications'")
      } else if (buttonCode === Qt.MiddleButton) {
        root.refreshNow()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: panelAnchor
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.previewOpen && root.previewMode === "comment" && !root.actionBusy ? previewPane.commentEditor : keyCatcher
    // The preview pane widens the panel; the bar keeps it on screen, so it
    // grows away from the screen edge.
    contentWidth: panel.fittedContentWidth(Style.space(400) + (root.previewOpen && root.paneFits ? Style.space(452) : 0))
    // While the preview is open the panel keeps one height, so j/k through
    // short lists does not move its bottom edge; the pane scrolls inside.
    contentHeight: root.previewOpen ? panel.fittedContentHeight(Style.space(720), Style.space(720))
      : panel.fittedContentHeight(column.implicitHeight + hintBar.implicitHeight
        + (failureLine.visible ? failureLine.implicitHeight : 0), Style.space(640))
    Behavior on contentWidth { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    Behavior on contentHeight { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus || root.commentFocused
      // The list's width with the pane closed, kept while it is open so
      // the list does not change size or move as the panel widens.

      // With the comment box open, every key the list catches goes back to
      // the box and does nothing else (see textKey).
      onMoveRequested: function(dx, dy) {
        if (root.previewOpen && root.previewMode === "comment") { previewPane.focusComment(); return }
        // Choosing how to merge: left and right pick the method, nothing moves.
        if (root.previewOpen && root.previewMode === "merge") {
          if (dx !== 0) root.cycleMergeMethod(dx)
          return
        }
        // Over the legend, up and down scroll it and nothing underneath moves.
        if (root.keysOpen) {
          var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(40), 0, maxY)
          return
        }
        if (root.settingsOpen) {
          if (dx !== 0) root.foldSettings(dx)
          if (dy !== 0) root.moveSettingsCursor(dy)
          return
        }
        if (dx !== 0) {
          root.cursorActive = true
          root.selectOrg(root.selectedOrgIndex + dx)
        }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: {
        if (root.previewOpen && root.previewMode === "comment") { previewPane.focusComment(); return }
        if (root.keysOpen) return
        // Space or a repeated Enter must not merge: the strip ignores this
        // generic signal, and a fresh Enter reaches it through the Shortcut.
        if (root.previewOpen && root.previewMode === "merge") return
        if (root.settingsOpen) root.activateSettings()
        else if (root.previewOpen && root.previewUrl !== "") root.openPreviewed()
        else root.activateCursor()
      }
      onDeleteRequested: {
        if (root.previewOpen && root.previewMode === "comment") { previewPane.focusComment(); return }
        if (!root.settingsOpen && !root.keysOpen) root.dismissCursor()
      }
      onCloseRequested: {
        // A running comment or merge keeps its strip and pane on screen.
        if (root.actionBusy) return
        if (root.previewOpen && root.previewMode !== "") root.previewMode = ""
        else if (root.previewOpen) root.closePreview()
        else if (root.keysOpen) root.keysOpen = false
        else if (root.settingsOpen) root.closeSettings()
        else if (root.query !== "" || root.searchOpen) root.closeSearch()
        else root.close()
      }
      onTabRequested: function(direction) {
        if (root.previewOpen && root.previewMode === "comment") { previewPane.focusComment(); return }
        root.switchPanel(direction)
      }
      onTextKey: function(t) {
        // u, s and / still work over the legend: undo must never be blocked,
        // and the other two leave the legend for their view.
        // While the merge strip is open only Enter confirms: a held `m`
        // must never open and confirm in one go.
        if (root.previewOpen && root.previewMode === "merge") return
        // With the comment box open, a key that reached the list (focus lost
        // after a failed post, say) goes back to the box and does nothing
        // else: a word typed there must never open or confirm a merge.
        if (root.previewOpen && root.previewMode === "comment") { previewPane.focusComment(); return }
        if (t === "?") root.keysOpen = !root.keysOpen
        else if (t === "u") root.undoDismiss()
        else if (t === "p" && !root.settingsOpen && !root.keysOpen && !root.actionBusy) root.togglePreview()
        else if (root.previewOpen && (t === "r" || t === "R")) root.refreshNow()
        else if (root.previewOpen && t === "c") root.startComment()
        else if (root.previewOpen && t === "m") root.startMerge()
        // Ctrl+d and Ctrl+u arrive as control characters. Shift+J and Shift+K
        // are Shortcuts next to the pane; a capital J or K that arrives as
        // text (some input methods send no Shift) scrolls here.
        else if (root.previewOpen && (t === "J" || t === "\u0004")) root.scrollPreview(1)
        else if (root.previewOpen && (t === "K" || t === "\u0015")) root.scrollPreview(-1)
        else if (root.keysOpen && t !== "s" && !(t === "/" && !root.settingsOpen)) return
        else if (t === "s") {
          if (root.settingsOpen) root.closeSettings()
          else root.openSettings(true)
        } else if (t === "f") {
          if (root.settingsOpen) root.focusKeyInSettings()
          else root.toggleFocusMode()
        } else if (root.settingsOpen) {
          if (t === "r" || t === "R") root.refreshNow()
        } else if (t === "d") root.dismissCursor()
        else if (t === "D") root.dismissNotifications(root.shownNotifications)
        else if (t === "r" || t === "R") root.refreshNow()
        else if (t === "/") root.openSearch()
        else if (t === "]") root.jumpSection(1)
        else if (t === "[") root.jumpSection(-1)
      }

      // Scrolling the preview. The key catcher sees Shift+j as a plain "j"
      // (it would move the cursor), so these are shortcuts, which Qt handles
      // before the key reaches it. Off while a comment or a search is typed.
      // The only key that confirms a merge: a fresh Enter, never a repeat.
      Shortcut {
        sequences: ["Return", "Enter"]
        autoRepeat: false
        enabled: root.previewOpen && root.previewMode === "merge" && !searchField.activeFocus
        onActivated: root.confirmMerge()
      }
      Shortcut {
        sequences: ["Shift+J", StandardKey.MoveToNextPage]
        enabled: root.previewOpen && !root.commentFocused && !searchField.activeFocus
        onActivated: root.scrollPreview(1)
      }
      Shortcut {
        sequences: ["Shift+K", StandardKey.MoveToPreviousPage]
        enabled: root.previewOpen && !root.commentFocused && !searchField.activeFocus
        onActivated: root.scrollPreview(-1)
      }

      PreviewPane {
        id: previewPane
        inbox: root
        onLeft: root.paneOnLeft
        // A fixed width on the outer edge, so it stays drawn while it fades
        // and the panel grows or shrinks around it.
        x: root.paneSolo ? 0 : (root.paneOnLeft ? 0 : root.listWidth + Style.space(12))
        width: root.paneSolo ? parent.width : Style.space(440)
        solo: root.paneSolo
        anchors.top: parent.top
        anchors.bottom: panelFlick.bottom
        visible: opacity > 0.01
        // Fading out after p: drawn, but nothing in it can be clicked.
        enabled: root.previewOpen
        opacity: root.previewOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
      }

      Text {
        id: failureLine
        visible: root.markFailures > 0
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: hintBar.top
        topPadding: Style.space(6)
        text: "GitHub refused " + (root.markFailures === 1 ? "a dismissal" : root.markFailures + " dismissals")
          + ", back in the list"
        textFormat: Text.PlainText
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }

      Text {
        id: hintBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        topPadding: Style.space(8)
        text: root.hintText()
        textFormat: Text.PlainText
        color: root.lastUndo ? root.foreground : root.dim

        MouseArea {
          anchors.fill: parent
          enabled: root.lastUndo !== null
          cursorShape: Qt.PointingHandCursor
          onClicked: root.undoDismiss()
        }

        MouseArea {
          anchors.fill: parent
          enabled: root.lastUndo === null
          cursorShape: Qt.PointingHandCursor
          onClicked: root.keysOpen = !root.keysOpen
        }
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }

      Flickable {
        id: panelFlick
        // The list keeps its place on screen: it sits on the side the panel
        // does not grow toward, and the pane opens on the other.
        anchors.left: root.paneOnLeft && !root.paneSolo ? undefined : parent.left
        anchors.right: root.paneOnLeft && !root.paneSolo ? parent.right : undefined
        width: root.paneSolo ? parent.width : root.listWidth
        visible: !root.paneSolo
        anchors.top: parent.top
        anchors.bottom: failureLine.visible ? failureLine.top : hintBar.top
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero: mark · GitHub · account ----------
          PanelHero {
            width: parent.width
            title: "GitHub"
            meta: root.settingsOpen ? "Settings"
              : (String(root.feed.user || "") !== "" ? "@" + root.feed.user : "Tasks")
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.spacing.sm

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: fetchProcess.running ? "Refreshing…" : root.footerText()
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                PanelActionButton {
                  visible: !root.settingsOpen
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""
                  tooltipText: "Find (/)"
                  foreground: root.foreground
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.searchOpen ? root.closeSearch() : root.openSearch()
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""
                  tooltipText: "Refresh"
                  foreground: root.foreground
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !fetchProcess.running
                  onClicked: root.refreshNow()
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.settingsOpen ? "󰅖" : "󰒓"
                  tooltipText: root.settingsOpen ? "Back to inbox (s)" : "Settings (s)"
                  foreground: root.foreground
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.settingsOpen ? root.closeSettings() : root.openSettings()
                }
              }
            }
          }

          // ---------- Error ----------
          BorderSurface {
            visible: String(root.feed.error || "") !== ""
            width: parent.width
            implicitHeight: errorText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: errorText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: String(root.feed.error || "")
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Inbox ----------
          Column {
            id: inboxView
            visible: !root.settingsOpen && !root.keysOpen
            width: parent.width
            spacing: Style.space(12)

            // ---------- Focus banner ----------
            CursorSurface {
              id: focusBanner
              visible: root.focusMode
              width: parent.width
              implicitHeight: focusBannerRow.implicitHeight + Style.spacing.rowPaddingX
              foreground: root.foreground
              bordered: true
              hasCursor: focusBannerMouse.containsMouse

              MouseArea {
                id: focusBannerMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openSettings()
              }

              Row {
                id: focusBannerRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                Text {
                  id: focusBannerGlyph
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰓾"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - focusBannerGlyph.width - leaveFocus.width - parent.spacing * 2
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    text: root.focusNarrowing ? "Focus on " + Inbox.describe(root.focusScopes) : "Focus mode is on"
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: root.focusNarrowing
                      ? (root.focusHiddenCount > 0 ? root.focusHiddenCount + " other items waiting" : "Nothing else waiting")
                        + " · click to edit"
                      : "Nothing is targeted yet, so everything shows · click to choose"
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Button {
                  id: leaveFocus
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Leave"
                  tooltipText: "Leave focus mode (f)"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  verticalPadding: Style.spacing.xs
                  onClicked: root.toggleFocusMode()
                }
              }
            }

            // ---------- Organization filter ----------
            // One scrolling row however many orgs there are. The selected tab
            // is kept in view, and long names are cut with the full name in
            // the tooltip.
            ListView {
              id: orgTabs
              visible: root.orgs.length > 1
              width: parent.width
              height: contentItem.childrenRect.height
              orientation: ListView.Horizontal
              spacing: Style.spacing.md
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentWidth > width
              model: ["All"].concat(root.orgs)
              currentIndex: root.selectedOrgIndex
              highlightFollowsCurrentItem: false
              onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

              delegate: Button {
                required property var modelData
                required property int index

                text: modelData.length > 20 ? modelData.slice(0, 19) + "…" : modelData
                tooltipText: modelData.length > 20 ? modelData : ""
                selected: index === root.selectedOrgIndex
                hasCursor: root.cursorActive && root.cursor === -1 && index === root.selectedOrgIndex
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: {
                  root.cursorActive = true
                  root.selectOrg(index)
                }
                onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
              }
            }

            // ---------- Fuzzy find ----------
            TextField {
              id: searchField
              visible: root.searchOpen
              width: parent.width
              placeholderText: "Fuzzy find… Enter to navigate · Esc clears"
              font.family: root.fontFamily
              foreground: root.foreground
              onTextChanged: root.query = text
              Keys.onEscapePressed: root.closeSearch()
              Keys.onReturnPressed: root.acceptSearch()
              Keys.onEnterPressed: root.acceptSearch()
              Keys.onDownPressed: root.moveCursor(1)
              Keys.onUpPressed: root.moveCursor(-1)
            }

            Text {
              visible: root.query !== "" && root.rowCount === 0
              width: parent.width
              topPadding: Style.space(12)
              text: "No matches for \"" + root.query + "\""
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
            }

            Text {
              visible: root.loaded && root.query === "" && String(root.feed.error || "") === ""
                && root.prs.length === 0 && root.reviews.length === 0
                && root.issues.length === 0 && root.notifications.length === 0
                && root.countUnread(root.mentions) === 0
              width: parent.width
              topPadding: Style.space(24)
              // Org names come from GitHub data: never parsed as markup.
              textFormat: Text.PlainText
              text: root.selectedOrg !== ""
                ? "Nothing in " + root.selectedOrg + " right now."
                : root.focusNarrowing
                ? "Nothing in focus needs you right now."
                  + (root.focusHiddenCount > 0 ? "\nLeave focus to see the other " + root.focusHiddenCount + " items." : "")
                : (root.hiddenScopes.length > 0 && root.selectedOrg === "" && root.rawOpenCount > 0
                  ? "Everything open is in hidden orgs or repos.\nPress s to show them again."
                  : "Nothing on your plate.\nNo PRs, review requests, issues, or notifications.")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            // ---------- Notifications ----------
            PanelSeparator {
              visible: notificationSection.visible
              foreground: root.foreground
            }

            Column {
              id: notificationSection
              visible: root.shownNotifications.length > 0
              width: parent.width
              spacing: Style.space(4)

              Item {
                width: parent.width
                implicitHeight: Math.max(notificationHeader.implicitHeight, dismissAll.implicitHeight)

                PanelSectionHeader {
                  id: notificationHeader
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "NOTIFICATIONS · " + root.shownNotifications.length
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Text {
                  id: dismissAll
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.shownNotifications.length > 1 ? "Dismiss all " + root.shownNotifications.length : "Dismiss"
                  color: dismissAllMouse.containsMouse ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true

                  MouseArea {
                    id: dismissAllMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.dismissNotifications(root.shownNotifications)
                  }

                  PanelToolTip {
                    visible: dismissAllMouse.containsMouse
                    text: "Mark every notification shown here read on GitHub (D)"
                    fontFamily: root.fontFamily
                  }
                }
              }

              Repeater {
                model: root.shownNotifications

                ItemRow {
                  required property var modelData
                  required property int index
                  width: notificationSection.width
                  flatIndex: root.notificationBase + index
                  notification: true
                  item: modelData
                  glyph: ""
                  glyphColor: root.urgent
                  detail: modelData.repo + " · " + root.reasonLabel(modelData.reason)
                    + " · " + root.timeAgo(modelData.updatedAt)
                }
              }
            }

            // ---------- Pull requests ----------
            PanelSeparator {
              visible: prSection.visible
              foreground: root.foreground
            }

            Column {
              id: prSection
              visible: root.shownPrs.length > 0
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                width: parent.width
                text: "PULL REQUESTS · " + root.shownPrs.length
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.shownPrs

                ItemRow {
                  required property var modelData
                  required property int index
                  width: prSection.width
                  flatIndex: root.prBase + index
                  item: modelData
                  glyph: ""
                  glyphColor: modelData.draft ? root.dim : root.foreground
                  detail: modelData.repo + "#" + modelData.number
                    + (modelData.draft ? " · draft" : "")
                    + " · " + root.timeAgo(modelData.updatedAt)
                }
              }
            }

            // ---------- Review requests ----------
            PanelSeparator {
              visible: reviewSection.visible
              foreground: root.foreground
            }

            Column {
              id: reviewSection
              visible: root.shownReviews.length > 0
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                width: parent.width
                text: "REVIEW REQUESTS · " + root.shownReviews.length
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.shownReviews

                ItemRow {
                  required property var modelData
                  required property int index
                  width: reviewSection.width
                  flatIndex: root.reviewBase + index
                  item: modelData
                  glyph: ""
                  glyphColor: modelData.draft ? root.dim : root.foreground
                  detail: modelData.repo + "#" + modelData.number
                    + (modelData.draft ? " · draft" : "")
                    + " · " + root.timeAgo(modelData.updatedAt)
                }
              }
            }

            // ---------- Issues ----------
            PanelSeparator {
              visible: issueSection.visible
              foreground: root.foreground
            }

            Column {
              id: issueSection
              visible: root.shownIssues.length > 0
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                width: parent.width
                text: "ISSUES · " + root.shownIssues.length
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.shownIssues

                ItemRow {
                  required property var modelData
                  required property int index
                  width: issueSection.width
                  flatIndex: root.issueBase + index
                  item: modelData
                  glyph: ""
                  detail: modelData.repo + "#" + modelData.number + " · " + root.timeAgo(modelData.updatedAt)
                }
              }
            }

            // ---------- Mentions ----------
            PanelSeparator {
              visible: mentionSection.visible
              foreground: root.foreground
            }

            Column {
              id: mentionSection
              visible: root.shownMentions.length > 0
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                width: parent.width
                text: "MENTIONS" + (root.countUnread(root.shownMentions) > 0 ? " · " + root.countUnread(root.shownMentions) + " NEW" : "")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.shownMentions

                ItemRow {
                  required property var modelData
                  required property int index
                  width: mentionSection.width
                  flatIndex: root.mentionBase + index
                  item: modelData
                  glyph: "@"
                  mention: true
                  detail: modelData.repo + "#" + modelData.number + " · " + root.timeAgo(modelData.updatedAt)
                }
              }
            }

            // ---------- Recently closed ----------
            PanelSeparator {
              visible: closedSection.visible
              foreground: root.foreground
            }

            Column {
              id: closedSection
              visible: root.shownClosed.length > 0
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                width: parent.width
                text: "RECENTLY CLOSED"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.shownClosed

                ItemRow {
                  required property var modelData
                  required property int index
                  width: closedSection.width
                  flatIndex: root.closedBase + index
                  item: modelData
                  glyph: modelData.kind === "pr" ? "" : ""
                  glyphColor: root.dim
                  detail: modelData.repo + "#" + modelData.number
                    + " · closed " + root.timeAgo(modelData.closedAt) + " ago"
                }
              }
            }
          }

          // ---------- Settings ----------
          SettingsView {
            visible: root.settingsOpen && !root.keysOpen
            width: parent.width
          }

          // ---------- Keys ----------
          KeysView {
            visible: root.keysOpen
            width: parent.width
          }
        }
      }
    }
  }

  // Every key in one place, for `?` or a click on the hint line.
  component KeysView: Column {
    spacing: Style.space(4)

    PanelSectionHeader {
      width: parent.width
      text: "KEYS"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Repeater {
      model: root.settingsOpen ? [
        ["j k  ↓ ↑", "Move between rows"],
        ["space  ↵", "Flip a switch, show or hide a row"],
        ["f", "Add to focus or remove from it"],
        ["l  →", "Show an org's repos"],
        ["h  ←", "Fold them again"],
        ["u", "Undo a dismissal (5 seconds)"],
        ["r", "Refresh"],
        ["s  Esc", "Back to the inbox"]
      ] : [
        ["j k  ↓ ↑", "Move between rows"],
        ["h l  ← →", "Switch org tab"],
        ["[ ]", "Jump between sections"],
        ["↵", "Open in the browser"],
        ["d  x", "Dismiss, or clear a mention dot"],
        ["D", "Dismiss every notification shown"],
        ["u", "Undo a dismissal (5 seconds)"],
        ["p", "Preview a PR or issue beside the list"],
        ["c  m", "In a preview: comment, merge"],
        ["J K", "Scroll the preview (or PgDn PgUp, Ctrl+d Ctrl+u)"],
        ["/", "Fuzzy find"],
        ["f", "Focus mode on or off"],
        ["s", "Settings"],
        ["r", "Refresh"],
        ["Tab", "Next panel in the bar"],
        ["Esc", "Back, then close"]
      ]

      Item {
        required property var modelData
        width: parent.width
        implicitHeight: Math.max(keyText.implicitHeight, keyHelp.implicitHeight) + Style.space(6)

        Text {
          id: keyText
          width: Style.space(90)
          anchors.verticalCenter: parent.verticalCenter
          text: modelData[0]
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          id: keyHelp
          anchors.left: keyText.right
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: modelData[1]
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // Settings: two switches, then every org and repo the inbox has seen, each
  // with a show/hide checkbox and a focus target.
  component SettingsView: Column {
    id: settingsView
    spacing: Style.space(12)

    Column {
      width: parent.width
      spacing: Style.space(6)

      Toggle {
        width: parent.width
        label: "Desktop notifications"
        description: "New notifications and mentions pop up on your desktop."
        checked: root.desktopNotifications
        id: alertsToggle
        hasCursor: root.cursorActive && root.settingsCursor === 0
        onHasCursorChanged: if (hasCursor && root.cursorFromKeyboard) root.ensureVisible(alertsToggle)
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.savePref("desktopNotifications", !root.desktopNotifications)
        // Same rule as the rows: only real pointer motion takes the cursor.
        MouseArea {
          id: alertsToggleHover
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          onPositionChanged: function(mouse) {
            if (!hoverGate.moved(alertsToggleHover, mouse)) return
            root.cursorFromKeyboard = false
            root.cursorActive = true
            root.settingsCursor = 0
          }
        }
      }

      Toggle {
        width: parent.width
        label: "Focus mode"
        description: root.focusScopes.length === 0
          ? "Target an org or repo below to choose what stays."
          : "Only targeted orgs and repos show, count, and notify."
        checked: root.focusMode
        id: focusToggle
        hasCursor: root.cursorActive && root.settingsCursor === 1
        onHasCursorChanged: if (hasCursor && root.cursorFromKeyboard) root.ensureVisible(focusToggle)
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.savePref("focusMode", !root.focusMode)
        // Same rule as the rows: only real pointer motion takes the cursor.
        MouseArea {
          id: focusToggleHover
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          onPositionChanged: function(mouse) {
            if (!hoverGate.moved(focusToggleHover, mouse)) return
            root.cursorFromKeyboard = false
            root.cursorActive = true
            root.settingsCursor = 1
          }
        }
      }
    }

    PanelSeparator { foreground: root.foreground }

    Column {
      width: parent.width
      spacing: Style.space(4)

      PanelSectionHeader {
        width: parent.width
        text: "ORGANIZATIONS AND REPOSITORIES"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Text {
        width: parent.width
        bottomPadding: Style.space(4)
        text: "Uncheck to hide. Target to keep in focus mode. Numbers count open items."
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        visible: root.scopeRows.length === 0
        width: parent.width
        topPadding: Style.space(8)
        text: root.loaded ? "No orgs yet. They appear here as GitHub activity arrives."
          : (String(root.feed.error || "") !== "" ? "Orgs appear here once GitHub answers." : "Loading…")
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }

      Repeater {
        model: root.scopeRows

        ScopeRow {
          required property var modelData
          required property int index
          width: settingsView.width
          entry: modelData
          flatIndex: root.settingsToggleCount + index
        }
      }
    }
  }

  // One org or repo: fold chevron, show/hide checkbox, name, open count, and
  // the focus target. Repo changes under an org rule are stored as
  // exceptions (Inbox.toggleRepo), so the org rule keeps covering new repos.
  component ScopeRow: CursorSurface {
    id: scopeRow
    property var entry: ({})
    property int flatIndex: -1

    readonly property bool isOrg: entry.kind === "org"
    readonly property var st: root.scopeState(entry)
    readonly property bool expanded: isOrg && root.expandedOrgs[entry.org] === true

    hasCursor: root.cursorActive && root.settingsCursor === flatIndex
    foreground: root.foreground
    implicitHeight: scopeContent.implicitHeight + Style.spacing.rowPaddingX
    onHasCursorChanged: if (hasCursor && root.cursorFromKeyboard) root.ensureVisible(scopeRow)

    function hover(mouse, area) {
      if (!hoverGate.moved(area, mouse)) return
      root.cursorFromKeyboard = false
      root.cursorActive = true
      root.settingsCursor = scopeRow.flatIndex
    }

    MouseArea {
      id: scopeMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onPositionChanged: function(mouse) { scopeRow.hover(mouse, scopeMouse) }
      // Like any tree: a click on an org folds it, the checkbox hides it.
      onClicked: {
        if (scopeRow.isOrg && scopeRow.entry.siblings.length > 0) root.setExpanded(scopeRow.entry.org, !scopeRow.expanded)
        else root.toggleShown(scopeRow.entry)
      }
    }

    Item {
      id: scopeContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(scopeRow.isOrg ? 4 : 30)
      anchors.rightMargin: Style.space(4)
      implicitHeight: Math.max(chevron.implicitHeight, focusButton.implicitHeight, scopeName.implicitHeight)

      PanelActionButton {
        id: chevron
        visible: scopeRow.isOrg
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        iconText: scopeRow.expanded ? "󰅀" : "󰅂"
        tooltipText: scopeRow.expanded ? "Fold (h)" : "Show repos (l)"
        enabled: scopeRow.entry.siblings && scopeRow.entry.siblings.length > 0
        foreground: root.dim
        hoverColor: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.setExpanded(scopeRow.entry.org, !scopeRow.expanded)
      }

      Text {
        id: checkbox
        anchors.left: scopeRow.isOrg ? chevron.right : parent.left
        anchors.leftMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        // Partial when only some of the org's repos are hidden.
        text: scopeRow.st.hidden === "none" ? "󰄲" : (scopeRow.st.hidden === "some" ? "󰡖" : "󰄱")
        color: scopeRow.st.hidden === "all" ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          cursorShape: Qt.PointingHandCursor
          onClicked: root.toggleShown(scopeRow.entry)
        }
      }

      Text {
        id: scopeName
        anchors.left: checkbox.right
        anchors.leftMargin: Style.space(10)
        anchors.right: scopeMeta.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        // Repos drop the org prefix: the org row right above already says it.
        text: scopeRow.isOrg ? scopeRow.entry.scope : scopeRow.entry.scope.split("/")[1]
        textFormat: Text.PlainText
        color: scopeRow.st.hidden === "all" ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.strikeout: scopeRow.st.hidden === "all"
        elide: Text.ElideRight

        PanelToolTip {
          visible: scopeName.truncated && scopeMouse.containsMouse
          text: scopeRow.entry.scope
          fontFamily: root.fontFamily
        }
      }

      Text {
        id: scopeMeta
        anchors.right: focusButton.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: {
          var parts = []
          if (scopeRow.st.hidden === "some") parts.push(scopeRow.st.hiddenRepos + " hidden")
          if (scopeRow.st.focus === "some") parts.push(scopeRow.st.focusRepos + " in focus")
          if (scopeRow.st.focus === "all") parts.push("in focus")
          if (scopeRow.entry.count > 0) parts.push(String(scopeRow.entry.count))
          return parts.join(" · ")
        }
        textFormat: Text.PlainText
        color: scopeRow.st.focus === "none" ? root.dim : Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelActionButton {
        id: focusButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰓾"
        tooltipText: scopeRow.st.focus === "all" ? "Remove from focus (f)"
          : (scopeRow.isOrg ? "Focus on the whole org (f)" : "Add to focus (f)")
        foreground: scopeRow.st.focus === "all" ? Color.accent
          : (scopeRow.st.focus === "some" ? root.alpha(Color.accent, 0.6) : root.alpha(root.dim, 0.55))
        hoverColor: scopeRow.st.focus === "none" ? root.foreground : Color.accent
        fontFamily: root.fontFamily
        onClicked: root.toggleFocus(scopeRow.entry)
      }
    }
  }

  // Two-line clickable row: glyph, title, dim detail; opens item.url.
  component ItemRow: CursorSurface {
    id: row
    property var item: null
    property string glyph: ""
    property color glyphColor: root.foreground
    property string detail: ""
    property bool mention: false
    property bool notification: false
    property int flatIndex: -1

    readonly property bool dotted: mention && item && root.mentionUnread(item)
    readonly property bool dismissable: notification || dotted

    // Right-click dismisses without opening, like an Omarchy toast.
    function dismiss() {
      var it = row.item
      if (!it) return
      if (row.notification) root.dismissNotifications([it])
      else if (row.dotted) root.dismissMention(it)
    }

    hasCursor: root.cursorActive && root.cursor === flatIndex
    foreground: root.foreground

    // The selected row unfolds to its full title. From the keyboard that is
    // immediate. Under the pointer nothing changes size mid-sweep: the row
    // unfolds once the pointer has rested on it for 350 ms, and the row that
    // was open stays open ("lingering") until then, so both change in the
    // same moment and nothing moves while the pointer travels.
    property bool rested: false
    property bool lingering: false
    readonly property bool expanded: (hasCursor && (root.cursorFromKeyboard || rested)) || lingering

    Timer {
      id: restTimer
      interval: 350
      onTriggered: {
        row.rested = true
        root.pointerRestSerial++
      }
    }

    // Every real pointer move inside the row restarts the wait, so it
    // measures rest, not time since the row was selected.
    function pointerMoved() {
      if (!rested) restTimer.restart()
    }

    Connections {
      target: root
      function onPointerRestSerialChanged() { if (!row.hasCursor) row.lingering = false }
      function onLingerOpenRow() { if (row.expanded) row.lingering = true }
      function onCursorFromKeyboardChanged() { if (root.cursorFromKeyboard) { row.lingering = false; restTimer.stop() } }
    }

    // Only keyboard cursor moves scroll: hover must never yank the list.
    onHasCursorChanged: {
      if (!hasCursor && expanded && !root.cursorFromKeyboard) lingering = true
      rested = false
      restTimer.stop()
      if (hasCursor && root.cursorFromKeyboard) root.ensureVisible(row)
    }

    // A row above the pointer that folds would pull the hovered row up:
    // scroll by the same amount so it stays put when the list allows it.
    property real lastHeight: 0
    onHeightChanged: {
      var delta = height - lastHeight
      lastHeight = height
      if (hasCursor && root.cursorFromKeyboard) root.ensureVisible(row)
      else if (!hasCursor && !root.cursorFromKeyboard && delta < 0 && flatIndex < root.cursor && panelFlick)
        panelFlick.contentY = Math.max(0, panelFlick.contentY + delta)
    }

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX
    clip: true
    Behavior on implicitHeight {
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onPositionChanged: function(mouse) {
        if (!hoverGate.moved(rowMouse, mouse)) return
        root.releaseHold("pointer")
        // Handing over from the keyboard: the row it opened stays open as
        // lingering, so the switch itself moves nothing.
        if (root.cursorFromKeyboard) root.lingerOpenRow()
        root.cursorFromKeyboard = false
        root.cursorActive = true
        root.cursor = row.flatIndex
        row.pointerMoved()
      }
      // Leaving before the rest is up cancels the unfold.
      onExited: if (!row.rested) restTimer.stop()
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) { row.dismiss(); return }
        // Dismissal rebuilds the Repeater and can destroy this row mid-handler.
        var it = row.item
        if (!it) return
        if (row.mention) root.markSeen(it)
        if (row.notification) root.dismissNotifications([it])
        root.openUrl(it.url)
      }
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(rowGlyph.implicitHeight, rowInfo.implicitHeight)

      Text {
        id: rowGlyph
        text: row.glyph
        color: row.glyphColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      PanelActionButton {
        id: previewButton
        // Also lit on the row the pane shows, which the cursor may have left
        // while the pointer travels toward the pane.
        visible: !!row.item && root.previewableUrl(row.item.url)
          && (row.hasCursor || (root.previewOpen && String(row.item.url) === root.previewUrl))
        anchors.right: dismissButton.visible ? dismissButton.left : parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰈈"
        tooltipText: root.previewOpen && root.previewUrl === String(row.item ? row.item.url : "") ? "Close preview (p)" : "Preview (p)"
        foreground: root.previewOpen && root.previewUrl === String(row.item ? row.item.url : "") ? root.foreground : root.dim
        hoverColor: root.foreground
        fontFamily: root.fontFamily
        onClicked: {
          root.cursor = row.flatIndex
          if (root.previewOpen && root.previewUrl === String(row.item.url)) root.closePreview()
          else root.openPreview()
        }
      }

      PanelActionButton {
        id: dismissButton
        visible: row.dismissable && row.hasCursor
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰅖"
        tooltipText: row.notification ? "Dismiss (d or right-click)" : "Mark seen (d or right-click)"
        foreground: root.dim
        hoverColor: root.foreground
        fontFamily: root.fontFamily
        onClicked: row.dismiss()
      }

      Rectangle {
        id: unreadDot
        visible: row.dotted && !dismissButton.visible && !previewButton.visible
        width: Style.space(7)
        height: width
        radius: width / 2
        color: Color.accent
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: rowInfo
        spacing: Style.space(1)
        anchors.left: rowGlyph.right
        anchors.leftMargin: Style.space(10)
        anchors.right: previewButton.visible ? previewButton.left
          : (dismissButton.visible ? dismissButton.left : (unreadDot.visible ? unreadDot.left : parent.right))
        anchors.rightMargin: previewButton.visible || dismissButton.visible || unreadDot.visible ? Style.space(8) : 0
        anchors.verticalCenter: parent.verticalCenter

        Text {
          text: row.item ? String(row.item.title || "") : ""
          // GitHub-controlled string: PlainText keeps AutoText from parsing
          // markup-shaped titles (rich text would even fetch <img> URLs).
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          // The selected row shows its whole title.
          wrapMode: row.expanded ? Text.Wrap : Text.NoWrap
          maximumLineCount: row.expanded ? 4 : 1
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          text: row.detail
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }
    }
  }
}
