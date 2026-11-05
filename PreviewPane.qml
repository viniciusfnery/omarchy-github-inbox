import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Inbox.js" as Inbox

// The pane beside the list that previews one PR or issue. Panel.qml owns the
// state and the gh calls (previewData, previewMode, actions); this file only
// draws them. Every GitHub-controlled string is PlainText.
Item {
  id: pane

  required property var inbox
  // Which side of the list the pane sits on: its divider goes between them.
  property bool onLeft: false
  // Alone in the panel on a narrow screen: no divider.
  property bool solo: false
  property var drafts: Inbox.dict()
  property string draftUrl: ""
  // Full data once gh answers. Before that, the row's own title and number,
  // so the pane is never empty while it loads.
  readonly property bool full: inbox.previewData !== null
  readonly property var d: inbox.previewData || inbox.previewStub
  readonly property bool isPr: d !== null && d.kind === "pr"
  // Non-required checks can fail on a mergeable PR (GitHub's UNSTABLE).
  readonly property bool checksFailing: full && isPr && d.checks
    && (d.checks.failed > 0 || d.checks.state === "FAILURE" || d.checks.state === "ERROR" || d.mergeState === "UNSTABLE")

  implicitHeight: (header.visible ? header.height + Style.space(10) : 0) + content.implicitHeight + actions.implicitHeight + Style.space(12)

  // Half a page per press, gliding, the way Ctrl+d and Ctrl+u move in vim.
  readonly property real maxScroll: Math.max(0, flick.contentHeight - flick.height)
  readonly property bool moreBelow: flick.contentY < maxScroll - 1

  function focusComment() { commentBox.forceActiveFocus() }
  readonly property alias commentEditor: commentBox

  function scrollBy(direction) {
    scrollGlide.stop()
    scrollGlide.to = Math.max(0, Math.min(maxScroll, flick.contentY + direction * flick.height * 0.5))
    scrollGlide.start()
  }

  NumberAnimation {
    id: scrollGlide
    target: flick
    property: "contentY"
    duration: 140
    easing.type: Easing.OutCubic
  }

  // A new item starts at its top.
  Connections {
    target: pane.inbox
    function onPreviewUrlChanged() {
      scrollGlide.stop()
      flick.contentY = 0
    }
  }


  function ago(iso) {
    var t = inbox.timeAgo(iso)
    return t === "" ? "" : (t === "now" ? "just now" : t + " ago")
  }

  // GitHub's own reading: a merged PR and a completed issue are done, a
  // closed unmerged PR is the only red, "not planned" is quiet.
  function stateColor(state) {
    if (state === "MERGED") return Color.accent
    if (state === "CLOSED" && !isPr) return d && d.stateReason === "NOT_PLANNED" ? inbox.dim : Color.accent
    if (state === "CLOSED") return inbox.urgent
    if (state === "DRAFT") return inbox.dim
    return inbox.foreground
  }

  function stateLabel() {
    if (!d) return ""
    if (d.state === "CLOSED" && !isPr && d.stateReason === "NOT_PLANNED") return "Not planned"
    return String(d.state).charAt(0) + String(d.state).slice(1).toLowerCase()
  }

  // Bodies are markdown, shown as plain text (never rendered, so nothing in
  // them can become markup): HTML comments, heading marks, emphasis marks
  // and runs of blank lines go.
  // The description as blocks (Inbox.bodyBlocks, tested): headings,
  // paragraphs, list items with their depth, table rows.
  readonly property var bodyBlocks: full ? Inbox.bodyBlocks(d.body, 12) : []
  // True when the 12-block cap left something out.
  TextMetrics {
    id: markerMetrics
    text: "00."
    font.family: pane.inbox.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  readonly property bool bodyCapped: full && Inbox.bodyBlocks(d.body, 13).length > 12

  function plainBody(text) { return Inbox.plainText(text) }

  Rectangle {
    visible: !pane.solo
    x: pane.onLeft ? parent.width + Style.space(6) : -Style.space(7)
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: 1
    color: inbox.alpha(inbox.foreground, 0.12)
  }

    // ---------- Header: kind, repo and number, state ----------
    Item {
      id: header
      // Pinned above the scrolling content, so the item an action is about
      // and the way out (Back, Close) are always in view.
      visible: pane.inbox.previewOpen
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.top: parent.top
      height: Math.max(headerText.implicitHeight, statePill.implicitHeight, backButton.implicitHeight, closeButton.implicitHeight)

      PanelActionButton {
        id: backButton
        visible: pane.solo
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        iconText: ""
        tooltipText: "Back to the list (p)"
        enabled: !pane.inbox.actionBusy
        foreground: pane.inbox.dim
        hoverColor: pane.inbox.foreground
        fontFamily: pane.inbox.fontFamily
        onClicked: pane.inbox.closePreview()
      }

      Text {
        id: headerText
        anchors.left: backButton.visible ? backButton.right : parent.left
        anchors.leftMargin: backButton.visible ? Style.space(6) : 0
        anchors.right: statePill.visible ? statePill.left : (closeButton.visible ? closeButton.left : parent.right)
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: pane.d ? (pane.isPr ? "  " : "  ")
          + String(pane.d.url).replace(/^https:\/\/github\.com\//, "").replace(/\/(pull|issues)\/(\d+)$/, " #$2") : ""
        textFormat: Text.PlainText
        color: pane.inbox.dim
        font.family: pane.inbox.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      PanelActionButton {
        id: closeButton
        visible: !pane.solo
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰅖"
        tooltipText: "Close the preview (p)"
        enabled: !pane.inbox.actionBusy
        foreground: pane.inbox.dim
        hoverColor: pane.inbox.foreground
        fontFamily: pane.inbox.fontFamily
        onClicked: pane.inbox.closePreview()
      }

      BorderSurface {
        id: statePill
        visible: pane.full
        anchors.right: closeButton.visible ? closeButton.left : parent.right
        anchors.rightMargin: closeButton.visible ? Style.space(6) : 0
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: stateText.implicitWidth + Style.space(14)
        implicitHeight: stateText.implicitHeight + Style.space(4)
        radius: Style.cornerRadius
        color: "transparent"
        borderSpec: Border.flat(pane.inbox.alpha(pane.stateColor(pane.d ? pane.d.state : ""), 0.6), 1)

        Text {
          id: stateText
          anchors.centerIn: parent
          text: pane.stateLabel()
          textFormat: Text.PlainText
          color: pane.stateColor(pane.d ? pane.d.state : "")
          font.family: pane.inbox.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }


  Flickable {
    id: flick
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: header.visible ? header.bottom : parent.top
    anchors.topMargin: header.visible ? Style.space(10) : 0
    anchors.bottom: actions.top
    anchors.bottomMargin: Style.space(4)
    contentWidth: width
    contentHeight: content.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    // Always drawn when there is more to read, so the pane says it scrolls.
    ScrollBar.vertical: ScrollBar { policy: pane.maxScroll > 0 ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff }

    Column {
      id: content
      width: flick.width - Style.space(8)
      spacing: Style.space(10)

      // ---------- Loading and errors ----------
      Text {
        visible: pane.d === null
        width: parent.width
        topPadding: Style.space(24)
        // Errors show once, in the action strip beside Retry.
        text: pane.inbox.previewLoading ? "Loading preview…" : (pane.inbox.previewError !== "" ? "" : "Nothing to preview")
        textFormat: Text.PlainText
        color: pane.inbox.dim
        font.family: pane.inbox.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
      }

      // ---------- Title and meta ----------
      Text {
        visible: pane.d !== null
        width: parent.width
        text: pane.d ? String(pane.d.title || "") : ""
        textFormat: Text.PlainText
        color: pane.inbox.foreground
        font.family: pane.inbox.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        wrapMode: Text.Wrap
      }

      // Who and when, then where and how big, each on its own line so a
      // long branch name elides instead of wrapping the line apart.
      Column {
        visible: pane.full
        width: parent.width
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: pane.full ? "@" + pane.d.author + " · opened " + pane.ago(pane.d.createdAt)
            + (!pane.isPr && pane.d.assignees && pane.d.assignees.length > 0
              ? " · assigned to " + pane.d.assignees.map(function(a) { return "@" + a }).join(", ") : "") : ""
          textFormat: Text.PlainText
          color: pane.inbox.dim
          font.family: pane.inbox.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          visible: pane.isPr
          width: parent.width
          text: pane.full && pane.isPr ? pane.d.base + " ← " + pane.d.head + " · +" + pane.d.additions
            + " −" + pane.d.deletions + " in " + pane.d.changedFiles + (pane.d.changedFiles === 1 ? " file" : " files") : ""
          textFormat: Text.PlainText
          color: pane.inbox.dim
          font.family: pane.inbox.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      // ---------- Status: checks, review, merge ----------
      Column {
        visible: pane.full && pane.isPr && pane.d.state !== "MERGED" && pane.d.state !== "CLOSED"
        width: parent.width
        spacing: Style.space(4)

        StatusLine {
          readonly property var c: pane.isPr ? pane.d.checks : null
          // GitHub's overall state covers every check, including any past
          // the 100 that are counted.
          readonly property string st: c ? String(c.state || "") : ""
          readonly property bool bad: st === "FAILURE" || st === "ERROR" || (c && c.failed > 0)
          readonly property bool waiting: !bad && (st === "PENDING" || st === "EXPECTED" || (c && c.pending > 0))
          glyph: !c || (c.total || 0) === 0 ? "" : (bad ? "" : (waiting ? "" : ""))
          tone: bad ? pane.inbox.urgent : (waiting ? pane.inbox.dim : pane.inbox.foreground)
          text: Inbox.checksText(c)
        }

        StatusLine {
          readonly property string r: pane.isPr ? String(pane.d.reviewDecision || "") : ""
          glyph: r === "APPROVED" ? "" : (r === "CHANGES_REQUESTED" ? "" : "")
          tone: r === "CHANGES_REQUESTED" ? pane.inbox.urgent : (r === "APPROVED" ? pane.inbox.foreground : pane.inbox.dim)
          text: r === "APPROVED" ? "Approved" : (r === "CHANGES_REQUESTED" ? "Changes requested"
            : (r === "REVIEW_REQUIRED" ? "Review required" : "No required reviews"))
        }

        StatusLine {
          glyph: pane.inbox.mergeBlock === "" ? "" : ""
          tone: pane.inbox.mergeBlock === "" ? pane.inbox.foreground : pane.inbox.dim
          text: pane.inbox.mergeBlock !== "" ? pane.inbox.mergeBlock
            : (pane.checksFailing ? "Can merge into " + pane.d.base + ", but checks are failing"
              : "Ready to merge into " + pane.d.base)
        }
      }

      // ---------- Labels ----------
      Flow {
        visible: pane.full && pane.d.labels.length > 0
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: pane.full ? pane.d.labels : []

          BorderSurface {
            required property var modelData
            implicitWidth: Math.min(labelText.implicitWidth + Style.space(12), content.width)
            implicitHeight: labelText.implicitHeight + Style.space(4)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.flat(pane.inbox.alpha(pane.inbox.foreground, 0.3), 1)

            Text {
              id: labelText
              anchors.centerIn: parent
              width: Math.min(implicitWidth, content.width - Style.space(12))
              elide: Text.ElideRight
              text: String(modelData)
              textFormat: Text.PlainText
              color: pane.inbox.dim
              font.family: pane.inbox.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // ---------- Still loading ----------
      Text {
        visible: !pane.full && pane.d !== null && pane.inbox.previewLoading
        width: parent.width
        text: "Loading details…"
        textFormat: Text.PlainText
        color: pane.inbox.dim
        font.family: pane.inbox.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      // ---------- Description ----------
      PanelSeparator { visible: pane.full; foreground: pane.inbox.foreground }

      PanelSectionHeader {
        visible: pane.full
        width: parent.width
        text: "DESCRIPTION"
        foreground: pane.inbox.foreground
        fontFamily: pane.inbox.fontFamily
      }

      Text {
        visible: pane.full && pane.bodyBlocks.length === 0
        width: parent.width
        text: "No description."
        textFormat: Text.PlainText
        color: pane.inbox.dim
        font.family: pane.inbox.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      // Markdown headings become bold lines; everything stays PlainText.
      Repeater {
        id: bodyRepeater
        model: pane.full ? pane.bodyBlocks : []

        // A list item is its marker and a wrapping column beside it, so its
        // second line keeps the item's indent.
        Row {
          id: blockRow
          required property var modelData
          readonly property bool quote: modelData.quote === true
          width: content.width
          topPadding: modelData.heading ? Style.space(4) : 0
          // A quote sits behind a bar, dim, so it never reads as the author's.
          leftPadding: quote ? Style.space(10) : modelData.indent * Style.space(14)
          spacing: Style.space(6)

          Rectangle {
            visible: blockRow.quote
            x: 0
            width: 2
            height: quoteText.implicitHeight
            color: pane.inbox.alpha(pane.inbox.foreground, 0.3)
          }

          Text {
            id: bulletText
            visible: modelData.bullet !== ""
            // As wide as "00." so item text lines up after "9." and "10.".
            width: markerMetrics.width
            horizontalAlignment: Text.AlignRight
            text: modelData.bullet
            textFormat: Text.PlainText
            color: pane.inbox.dim
            font.family: pane.inbox.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            id: quoteText
            width: parent.width - parent.leftPadding - (bulletText.visible ? bulletText.width + parent.spacing : 0)
              - (blockRow.quote ? 2 + parent.spacing : 0)
            text: modelData.text
            textFormat: Text.PlainText
            color: blockRow.quote ? pane.inbox.dim : pane.inbox.foreground
            font.family: pane.inbox.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: modelData.heading
            wrapMode: Text.Wrap
          }
        }
      }

      // The description is cut at 1200 characters: say so, and where the rest is.
      Text {
        visible: pane.full && (String(pane.d.body || "").slice(-1) === "…" || pane.bodyCapped)
        width: parent.width
        text: "Only the start is shown. Enter opens the full description."
        textFormat: Text.PlainText
        color: pane.inbox.dim
        font.family: pane.inbox.fontFamily
        font.pixelSize: Style.font.caption
        font.italic: true
        wrapMode: Text.Wrap
      }

      // ---------- Comments ----------
      PanelSectionHeader {
        visible: pane.full && pane.d.comments.length > 0
        width: parent.width
        topPadding: Style.space(6)
        text: "LATEST COMMENTS" + (pane.d && pane.d.commentTotal > pane.d.comments.length
          ? " · " + pane.d.comments.length + " OF " + pane.d.commentTotal : "")
        foreground: pane.inbox.foreground
        fontFamily: pane.inbox.fontFamily
      }

      Repeater {
        model: pane.full ? pane.d.comments : []

        Column {
          required property var modelData
          width: content.width
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: "@" + modelData.author + " · " + pane.ago(modelData.createdAt)
            textFormat: Text.PlainText
            color: pane.inbox.dim
            font.family: pane.inbox.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            readonly property string clean: pane.plainBody(modelData.body)
            text: clean !== "" ? clean : "Quoted an earlier comment"
            textFormat: Text.PlainText
            color: clean !== "" ? pane.inbox.foreground : pane.inbox.dim
            font.family: pane.inbox.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            maximumLineCount: 5
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // While more is below: a fade over the last lines and how to get there.
  Rectangle {
    visible: pane.moreBelow && pane.full
    anchors.left: flick.left
    anchors.right: flick.right
    anchors.bottom: flick.bottom
    height: Style.space(36)
    gradient: Gradient {
      GradientStop { position: 0.0; color: "transparent" }
      GradientStop { position: 1.0; color: Color.popups.background }
    }
  }

  BorderSurface {
    visible: pane.moreBelow && pane.full
    anchors.right: flick.right
    anchors.rightMargin: Style.space(14)
    anchors.bottom: flick.bottom
    implicitWidth: moreText.implicitWidth + Style.space(14)
    implicitHeight: moreText.implicitHeight + Style.space(4)
    radius: Style.cornerRadius
    color: Color.popups.background
    borderSpec: Border.flat(pane.inbox.alpha(pane.inbox.foreground, 0.3), 1)

    Text {
      id: moreText
      anchors.centerIn: parent
      text: "↓ more · J"
      textFormat: Text.PlainText
      color: pane.inbox.dim
      font.family: pane.inbox.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: pane.scrollBy(1)
    }
  }

  // ---------- Actions, the comment box, the merge confirmation ----------
  Column {
    id: actions
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: Style.space(8)
    spacing: Style.space(8)
    visible: pane.d !== null || pane.inbox.previewError !== ""

    // Where the scrolling content is cut, so the cut reads as an edge.
    Rectangle {
      width: parent.width
      height: 1
      color: pane.inbox.alpha(pane.inbox.foreground, 0.12)
    }

    // Old data on screen after a failed refresh, or no data at all.
    Flow {
      visible: pane.inbox.previewStale || (!pane.full && pane.inbox.previewError !== "")
      width: parent.width
      spacing: Style.space(8)

      // Says why (gh's reason, named by preview.sh), and steps aside while
      // a retry runs.
      Text {
        visible: !pane.inbox.previewLoading
        width: Math.min(implicitWidth, parent.width)
        wrapMode: Text.Wrap
        text: pane.inbox.previewStale
          ? "Could not refresh: " + pane.inbox.previewError + ". Showing the last loaded version."
          : "Could not load: " + pane.inbox.previewError
        textFormat: Text.PlainText
        color: pane.inbox.urgent
        font.family: pane.inbox.fontFamily
        font.pixelSize: Style.font.caption
      }

      Button {
        text: pane.inbox.previewLoading ? "Retrying…" : "Retry"
        tooltipText: "r"
        enabled: !pane.inbox.previewLoading
        bordered: true
        foreground: pane.inbox.foreground
        fontFamily: pane.inbox.fontFamily
        fontSize: Style.font.caption
        verticalPadding: Style.spacing.xs
        onClicked: pane.inbox.reloadPreview()
      }
    }

    // Three lines at most, so a long error never pushes the editor or the
    // buttons off the pane; hovering shows all of it.
    Text {
      id: noticeText
      visible: pane.inbox.previewNotice !== ""
      width: parent.width
      text: pane.inbox.previewNotice
      textFormat: Text.PlainText
      color: pane.inbox.previewNoticeError ? pane.inbox.urgent : (pane.inbox.previewNoticeDim ? pane.inbox.dim : pane.inbox.foreground)
      font.family: pane.inbox.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
      maximumLineCount: 3
      elide: Text.ElideRight

      MouseArea {
        id: noticeMouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
      }

      PanelToolTip {
        visible: noticeText.truncated && noticeMouse.containsMouse
        text: pane.inbox.previewNotice
        fontFamily: pane.inbox.fontFamily
      }
    }

    // Comment box: visible only after `c` or the Comment button.
    Column {
      visible: pane.inbox.previewMode === "comment"
      width: parent.width
      spacing: Style.space(6)

      Text {
        width: parent.width
        text: "Comment as @" + String(pane.inbox.feed.user || "you") + " on " + (pane.d ? "#" + pane.d.number : "")
        textFormat: Text.PlainText
        color: pane.inbox.dim
        font.family: pane.inbox.fontFamily
        font.pixelSize: Style.font.caption
      }

      ScrollView {
        width: parent.width
        height: Style.space(96)

        TextArea {
          id: commentBox
          wrapMode: TextArea.Wrap
          placeholderText: "Leave a comment…"
          color: pane.inbox.foreground
          placeholderTextColor: pane.inbox.dim
          font.family: pane.inbox.fontFamily
          font.pixelSize: Style.font.bodySmall
          enabled: !pane.inbox.actionBusy
          background: BorderSurface {
            radius: Style.cornerRadius
            color: pane.inbox.alpha(pane.inbox.foreground, 0.04)
            borderSpec: Border.flat(pane.inbox.alpha(pane.inbox.foreground, commentBox.activeFocus ? 0.5 : 0.25), 1)
          }
          onActiveFocusChanged: pane.inbox.commentFocused = activeFocus
          // The decision lives in Inbox.commentKey, where it is tested.
          Keys.onPressed: function(event) {
            var action = Inbox.commentKey({
              enter: event.key === Qt.Key_Return || event.key === Qt.Key_Enter,
              ctrl: (event.modifiers & Qt.ControlModifier) !== 0,
              escape: event.key === Qt.Key_Escape,
              repeat: event.isAutoRepeat
            })
            if (action === "submit") pane.inbox.sendComment(commentBox.text)
            else if (action === "cancel" && !pane.inbox.actionBusy) pane.inbox.previewMode = ""
            if (action !== "") event.accepted = true
          }
        }
      }

      Row {
        spacing: Style.space(8)

        Button {
          text: pane.inbox.actionBusy ? "Posting…" : "Comment"
          tooltipText: "Ctrl+Enter"
          bordered: true
          enabled: !pane.inbox.actionBusy && commentBox.text.trim() !== ""
          foreground: pane.inbox.foreground
          fontFamily: pane.inbox.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: pane.inbox.sendComment(commentBox.text)
        }

        Button {
          text: "Cancel"
          tooltipText: "Esc"
          bordered: true
          enabled: !pane.inbox.actionBusy
          foreground: pane.inbox.foreground
          fontFamily: pane.inbox.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: pane.inbox.previewMode = ""
        }
      }
    }

    // Merge confirmation: the second, explicit step.
    BorderSurface {
      visible: pane.inbox.previewMode === "merge"
      width: parent.width
      implicitHeight: mergeColumn.implicitHeight + Style.space(20)
      radius: Style.cornerRadius
      color: pane.inbox.alpha(pane.inbox.foreground, 0.05)
      borderSpec: Border.flat(pane.inbox.alpha(pane.inbox.foreground, 0.35), 1)

      Column {
        id: mergeColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(10)
        spacing: Style.space(8)

        Text {
          width: parent.width
          text: pane.inbox.mergeTarget ? ({ squash: "Squash and merge", merge: "Merge", rebase: "Rebase and merge" })[pane.inbox.mergeMethod]
            + " #" + pane.inbox.mergeTarget.number + " into " + pane.inbox.mergeTarget.base
            + " at " + pane.inbox.mergeTarget.sha.slice(0, 7) + "?" : ""
          textFormat: Text.PlainText
          color: pane.inbox.foreground
          font.family: pane.inbox.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          wrapMode: Text.Wrap
        }

        Text {
          visible: pane.checksFailing
          width: parent.width
          text: "Checks are failing on this commit."
          textFormat: Text.PlainText
          color: pane.inbox.urgent
          font.family: pane.inbox.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Flow {
          visible: pane.isPr && pane.d.mergeMethods.length > 1
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: pane.d && pane.isPr ? pane.d.mergeMethods : []

            Button {
              required property var modelData
              text: ({ squash: "Squash", merge: "Merge commit", rebase: "Rebase" })[modelData]
              selected: pane.inbox.mergeMethod === modelData
              enabled: !pane.inbox.actionBusy
              bordered: true
              foreground: pane.inbox.foreground
              fontFamily: pane.inbox.fontFamily
              fontSize: Style.font.caption
              onClicked: pane.inbox.mergeMethod = modelData
            }
          }
        }

        Flow {
          width: parent.width
          spacing: Style.space(8)

          Button {
            text: pane.inbox.actionBusy ? "Merging…" : "Confirm merge"
            focusable: false
            tooltipText: "Enter"
            bordered: true
            enabled: !pane.inbox.actionBusy
            foreground: pane.inbox.foreground
            fontFamily: pane.inbox.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: pane.inbox.confirmMerge()
          }

          Button {
            text: "Cancel"
            tooltipText: "Esc"
            bordered: true
            enabled: !pane.inbox.actionBusy
            foreground: pane.inbox.foreground
            fontFamily: pane.inbox.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: pane.inbox.previewMode = ""
          }
        }
      }
    }

    Flow {
      visible: pane.inbox.previewMode === ""
      width: parent.width
      spacing: Style.space(8)

      Button {
        text: "Open in browser"
        tooltipText: "Enter"
        bordered: true
        foreground: pane.inbox.foreground
        fontFamily: pane.inbox.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: pane.inbox.openPreviewed()
      }

      Button {
        text: "Comment"
        tooltipText: "c"
        enabled: pane.full
        bordered: true
        foreground: pane.inbox.foreground
        fontFamily: pane.inbox.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: pane.inbox.startComment()
      }

      Button {
        // Hidden when it can never merge here (merged, closed, no permission);
        // shown dim for a block that can pass (draft, conflicts, checking),
        // and clickable then too: a click says why, like `m` does.
        visible: pane.isPr && pane.full && pane.d.state !== "MERGED" && pane.d.state !== "CLOSED" && pane.d.canMerge !== false
        enabled: pane.full
        text: "Merge"
        tooltipText: pane.inbox.mergeBlock !== "" ? pane.inbox.mergeBlock : "m"
        bordered: true
        foreground: pane.inbox.mergeBlock === "" ? pane.inbox.foreground : pane.inbox.dim
        fontFamily: pane.inbox.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: pane.inbox.startMerge()
      }
    }
  }

  // The comment box takes the keys as soon as it shows and gives them back
  // when it hides. A cancelled draft stays, a posted one or a draft for
  // another item goes.
  Connections {
    target: pane.inbox
    function onPreviewModeChanged() {
      if (pane.inbox.previewMode === "comment") Qt.callLater(function() { commentBox.forceActiveFocus() })
      else if (commentBox.activeFocus) pane.inbox.focusList()
    }
    // Drafts are kept per item: cancelling or moving on never loses one,
    // and only the item a comment was posted to loses its draft.
    function onCommentPosted(url) {
      var next = Inbox.copy(pane.drafts)
      delete next[url]
      pane.drafts = next
      if (pane.draftUrl === url) commentBox.text = ""
    }
    function onPreviewUrlChanged() {
      var next = Inbox.copy(pane.drafts)
      if (pane.draftUrl !== "" && commentBox.text !== "") next[pane.draftUrl] = commentBox.text
      else delete next[pane.draftUrl]
      pane.drafts = next
      pane.draftUrl = pane.inbox.previewUrl
      commentBox.text = Inbox.has(next, pane.draftUrl) ? next[pane.draftUrl] : ""
    }
  }

  // One status line: glyph and text in a tone.
  component StatusLine: Row {
    id: statusLine
    property string glyph: ""
    property string text: ""
    property color tone: pane.inbox.foreground
    width: content.width
    spacing: Style.space(8)

    Text {
      id: statusGlyph
      text: parent.glyph
      textFormat: Text.PlainText
      color: parent.tone
      font.family: pane.inbox.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      width: statusLine.width - statusGlyph.width - statusLine.spacing
      text: parent.text
      textFormat: Text.PlainText
      color: parent.tone
      font.family: pane.inbox.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.Wrap
    }
  }
}
