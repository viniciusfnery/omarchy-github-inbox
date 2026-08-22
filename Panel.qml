import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

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

  // Never name this `data`: that shadows Item's default property and steals
  // every declared child from the scene.
  property var feed: ({ user: "", error: "", prs: [], issues: [], notifications: [] })
  property bool loaded: false
  property double lastFetchMs: 0
  property string selectedOrg: ""
  property bool cursorActive: false

  // Bound clock: relative times keep updating while the panel sits open.
  property double nowMs: Date.now()

  // `feed` can be uninitialized during construction; an exception here would
  // leave dependent bindings permanently failed.
  readonly property var allPrs: (feed && feed.prs) || []
  readonly property var allReviews: (feed && feed.reviews) || []
  readonly property var allIssues: (feed && feed.issues) || []
  readonly property var allNotifications: (feed && feed.notifications) || []
  readonly property var allMentions: (feed && feed.mentions) || []
  readonly property var allClosed: (feed && feed.closed) || []
  readonly property int workCount: allPrs.length + allReviews.length + allIssues.length

  // GitHub has no "mention read" state, so it lives here: url -> updatedAt at
  // the moment the mention was opened. New activity on the thread re-dots it.
  property var seen: ({})

  function mentionUnread(m) {
    // Your own comments/reactions never create GitHub notifications, so
    // requiring an unread one filters your own activity out of the dot.
    if (m.notifUnread !== true) return false
    var seenAt = seen[String(m.url || "")]
    return !seenAt || String(m.updatedAt || "") > String(seenAt)
  }

  readonly property int unreadMentions: {
    var n = 0
    for (var i = 0; i < allMentions.length; i++)
      if (mentionUnread(allMentions[i])) n++
    return n
  }

  function markSeen(item) {
    // Prune to the currently listed mentions so the file never grows.
    var next = {}
    for (var i = 0; i < allMentions.length; i++) {
      var url = String(allMentions[i].url || "")
      if (seen[url]) next[url] = seen[url]
    }
    next[String(item.url || "")] = String(item.updatedAt || "")
    seen = next
    seenFile.setText(JSON.stringify(next))
    // Keep GitHub's inbox in agreement — the dot rule reads it.
    markThreadRead(item.threadId)
  }

  // Drop the row now and mark the thread read on GitHub in the background —
  // waiting for the next refresh would leave a read notification sitting here.
  function dismissNotification(item) {
    var remaining = []
    for (var i = 0; i < allNotifications.length; i++)
      if (allNotifications[i] !== item) remaining.push(allNotifications[i])
    feed = {
      user: feed.user, error: feed.error,
      prs: allPrs, reviews: allReviews, issues: allIssues,
      mentions: allMentions, notifications: remaining, closed: allClosed
    }
    markThreadRead(item.threadId)
  }

  // Thread ids come from the GitHub API; the numeric check keeps anything
  // else out of the shell command line.
  function markThreadRead(threadId) {
    var id = String(threadId || "")
    if (/^[0-9]+$/.test(id) && bar)
      bar.run("bash '" + scriptPath + "' --mark-read '" + id + "'")
  }

  function applySeen(text) {
    try {
      var parsed = JSON.parse(text)
      if (parsed && typeof parsed === "object") seen = parsed
    } catch (e) { /* first run: no file yet */ }
  }

  readonly property var orgs: {
    var seen = {}
    var result = []
    var all = allPrs.concat(allReviews).concat(allIssues).concat(allNotifications).concat(allMentions).concat(allClosed)
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
    if (rowCount === 0) return
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
    if (row.notification) dismissNotification(row.item)
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

  function openSearch() {
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
    // URLs come from the GitHub API; the quote check keeps anything else out
    // of the shell command line.
    var target = String(url || "")
    if (target.indexOf("https://") !== 0 || target.indexOf("'") >= 0 || root.bar === null) return
    root.bar.run("omarchy-launch-browser '" + target + "'")
    root.close()
  }

  function refreshNow() {
    if (!fetchProcess.running) fetchProcess.running = true
  }

  function applyFetch(text) {
    var parsed = null
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      console.warn("github", "bad fetch output", e)
      retryTimer.restart()
      return
    }
    if (!parsed || typeof parsed !== "object") {
      retryTimer.restart()
      return
    }
    if (String(parsed.error || "") !== "") {
      // Transient failure: keep the stale lists visible, surface the error.
      // lastFetchMs stays put so "Updated Xh ago" keeps telling the truth.
      feed = {
        user: String(feed.user || parsed.user || ""),
        error: String(parsed.error),
        prs: allPrs, reviews: allReviews, issues: allIssues,
        mentions: allMentions, notifications: allNotifications, closed: allClosed
      }
      retryTimer.restart()
      return
    }
    feed = parsed
    loaded = true
    lastFetchMs = Date.now()
    nowMs = lastFetchMs
    retryTimer.stop()
    if (selectedOrg !== "" && orgs.indexOf(selectedOrg) < 0) selectedOrg = ""
  }

  function reasonLabel(reason) {
    return String(reason || "").replace(/_/g, " ")
  }

  function footerText() {
    if (!loaded) return "Loading…"
    if (lastFetchMs <= 0) return ""
    var ago = timeAgo(new Date(lastFetchMs).toISOString())
    return ago === "" ? "" : "Updated " + (ago === "now" ? "just now" : ago + " ago")
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursor = -1
    cursorFromKeyboard = false
    searchOpen = false
    searchField.text = ""
    hoverGate.reset()
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    refreshNow()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Filters synthetic hover churn while keyboard scrolling moves rows under
  // a stationary pointer; rows only take the cursor on real pointer motion.
  PointerMoveGate {
    id: hoverGate
    referenceItem: panelFlick
  }

  FileView {
    id: seenFile
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
      + "/omarchy/github-mentions-seen.json"
    // Watched so the panel instance on the other monitor drops its dot too
    // when a mention is opened on this one.
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applySeen(text())
    onFileChanged: reload()
  }

  Process {
    id: fetchProcess
    running: false
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

  // Only one monitor's instance owns the IPC target; the bar's router picks
  // the instance a hotkey should act on (open one first, else focused monitor).
  function routedInstance() {
    var item = bar && typeof bar.findPanelWidget === "function"
      ? bar.findPanelWidget(moduleName) : null
    return item || root
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
    function find(): string {
      var target = root.routedInstance()
      target.open()
      target.openSearch()
      return "ok"
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.workCount > 0 ? " " + root.workCount : ""
    active: root.allNotifications.length > 0 || root.unreadMentions > 0
    tooltipText: root.feed && String(root.feed.error || "") !== ""
      ? String(root.feed.error)
      : root.allPrs.length + " PRs · " + root.allReviews.length + " reviews · "
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
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectOrg(root.selectedOrgIndex + dx)
        }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: {
        if (root.query !== "" || root.searchOpen) root.closeSearch()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        else if (t === "/") root.openSearch()
        else if (t === "]") root.jumpSection(1)
        else if (t === "[") root.jumpSection(-1)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
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
            meta: String(root.feed.user || "") !== "" ? "@" + root.feed.user : "Tasks"
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
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""
                  tooltipText: "Refresh"
                  foreground: root.foreground
                  hoverColor: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !fetchProcess.running
                  onClicked: root.refreshNow()
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
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Organization filter ----------
          Flow {
            visible: root.orgs.length > 1
            width: parent.width
            spacing: Style.spacing.md

            Repeater {
              model: ["All"].concat(root.orgs)

              Button {
                required property var modelData
                required property int index

                text: modelData
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
            width: parent.width
            topPadding: Style.space(24)
            text: "Nothing on your plate.\nNo PRs, review requests, issues, or notifications."
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

            PanelSectionHeader {
              width: parent.width
              text: "NOTIFICATIONS · " + root.shownNotifications.length
              foreground: root.foreground
              fontFamily: root.fontFamily
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
              text: "MENTIONS" + (root.unreadMentions > 0 ? " · " + root.unreadMentions + " NEW" : "")
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

    hasCursor: root.cursorActive && root.cursor === flatIndex
    foreground: root.foreground

    // Only keyboard cursor moves scroll — hover must never yank the list.
    onHasCursorChanged: if (hasCursor && root.cursorFromKeyboard) root.ensureVisible(row)

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onPositionChanged: function(mouse) {
        if (!hoverGate.moved(rowMouse, mouse)) return
        root.cursorFromKeyboard = false
        root.cursorActive = true
        root.cursor = row.flatIndex
      }
      onClicked: {
        // Dismissal rebuilds the Repeater and can destroy this row mid-handler.
        var it = row.item
        if (!it) return
        if (row.mention) root.markSeen(it)
        if (row.notification) root.dismissNotification(it)
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

      Rectangle {
        id: unreadDot
        visible: row.dotted
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
        anchors.right: unreadDot.visible ? unreadDot.left : parent.right
        anchors.rightMargin: unreadDot.visible ? Style.space(8) : 0
        anchors.verticalCenter: parent.verticalCenter

        Text {
          text: row.item ? String(row.item.title || "") : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          text: row.detail
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
