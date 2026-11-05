import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// The pane beside the list that previews one PR or issue. Panel.qml owns the
// state and the gh calls (previewData, previewMode, actions); this file only
// draws them. Every GitHub-controlled string is PlainText.
Item {
  id: pane

  required property var inbox
  // Full data once gh answers. Before that, the row's own title and number,
  // so the pane is never empty while it loads.
  readonly property bool full: inbox.previewData !== null
  readonly property var d: inbox.previewData || inbox.previewStub
  readonly property bool isPr: d !== null && d.kind === "pr"

  implicitHeight: content.implicitHeight + actions.implicitHeight + Style.space(12)

  function scrollBy(direction) {
    var maxY = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(maxY, flick.contentY + direction * Style.space(80)))
  }

  // A new item starts at its top.
  Connections {
    target: pane.inbox
    function onPreviewUrlChanged() { flick.contentY = 0 }
  }


  function ago(iso) {
    var t = inbox.timeAgo(iso)
    return t === "" ? "" : (t === "now" ? "just now" : t + " ago")
  }

  function stateColor(state) {
    if (state === "MERGED") return Color.accent
    if (state === "CLOSED") return inbox.urgent
    if (state === "DRAFT") return inbox.dim
    return inbox.foreground
  }

  // Bodies are markdown, shown as plain text (never rendered, so nothing in
  // them can become markup): HTML comments, heading marks, emphasis marks
  // and runs of blank lines go.
  function plainBody(text) {
    return String(text || "").replace(/\r/g, "")
      .replace(/<!--[\s\S]*?-->/g, "")
      .replace(/^#{1,6}\s+/gm, "")
      .replace(/(\*\*|__)(.+?)\1/g, "$2")
      .replace(/\n{3,}/g, "\n\n")
      .trim()
  }

  Rectangle {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.leftMargin: -Style.space(7)
    width: 1
    color: inbox.alpha(inbox.foreground, 0.12)
  }

  Flickable {
    id: flick
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: actions.top
    anchors.bottomMargin: Style.space(8)
    contentWidth: width
    contentHeight: content.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: content
      width: flick.width - Style.space(8)
      spacing: Style.space(10)

      // ---------- Loading and errors ----------
      Text {
        visible: pane.d === null
        width: parent.width
        topPadding: Style.space(24)
        text: pane.inbox.previewLoading ? "Loading preview…" : (pane.inbox.previewError || "Nothing to preview")
        textFormat: Text.PlainText
        color: pane.inbox.previewError !== "" && !pane.inbox.previewLoading ? pane.inbox.urgent : pane.inbox.dim
        font.family: pane.inbox.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }

      // ---------- Header: kind, repo and number, state ----------
      Item {
        visible: pane.d !== null
        width: parent.width
        implicitHeight: Math.max(headerText.implicitHeight, statePill.implicitHeight)

        Text {
          id: headerText
          anchors.left: parent.left
          anchors.right: statePill.visible ? statePill.left : parent.right
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

        BorderSurface {
          id: statePill
          visible: pane.full
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          implicitWidth: stateText.implicitWidth + Style.space(14)
          implicitHeight: stateText.implicitHeight + Style.space(4)
          radius: Style.cornerRadius
          color: "transparent"
          borderSpec: Border.flat(pane.inbox.alpha(pane.stateColor(pane.d ? pane.d.state : ""), 0.6), 1)

          Text {
            id: stateText
            anchors.centerIn: parent
            text: pane.d ? String(pane.d.state).charAt(0) + String(pane.d.state).slice(1).toLowerCase() : ""
            textFormat: Text.PlainText
            color: pane.stateColor(pane.d ? pane.d.state : "")
            font.family: pane.inbox.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
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

      Text {
        visible: pane.full
        width: parent.width
        text: {
          if (!pane.full) return ""
          var parts = ["@" + pane.d.author, "opened " + pane.ago(pane.d.createdAt)]
          if (pane.isPr) {
            parts.push(pane.d.base + " ← " + pane.d.head)
            parts.push("+" + pane.d.additions + " −" + pane.d.deletions + " in " + pane.d.changedFiles
              + (pane.d.changedFiles === 1 ? " file" : " files"))
          } else if (pane.d.assignees && pane.d.assignees.length > 0) {
            parts.push("assigned to " + pane.d.assignees.map(function(a) { return "@" + a }).join(", "))
          }
          return parts.join(" · ")
        }
        textFormat: Text.PlainText
        color: pane.inbox.dim
        font.family: pane.inbox.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      // ---------- Status: checks, review, merge ----------
      Column {
        visible: pane.full && pane.isPr && pane.d.state !== "MERGED" && pane.d.state !== "CLOSED"
        width: parent.width
        spacing: Style.space(4)

        StatusLine {
          readonly property var c: pane.isPr ? pane.d.checks : null
          glyph: !c || c.passed + c.failed + c.pending === 0 ? "" : (c.failed > 0 ? "" : (c.pending > 0 ? "" : ""))
          tone: c && c.failed > 0 ? pane.inbox.urgent : (c && c.pending > 0 ? pane.inbox.dim : pane.inbox.foreground)
          text: {
            if (!c || c.passed + c.failed + c.pending === 0) return "No checks"
            var parts = []
            if (c.failed > 0) parts.push(c.failed + " failing")
            if (c.pending > 0) parts.push(c.pending + " running")
            if (c.passed > 0) parts.push(c.passed + " passed")
            return "Checks: " + parts.join(", ")
          }
        }

        StatusLine {
          readonly property string r: pane.isPr ? String(pane.d.reviewDecision || "") : ""
          glyph: r === "APPROVED" ? "" : (r === "CHANGES_REQUESTED" ? "" : "")
          tone: r === "CHANGES_REQUESTED" ? pane.inbox.urgent : (r === "APPROVED" ? pane.inbox.foreground : pane.inbox.dim)
          text: r === "APPROVED" ? "Approved" : (r === "CHANGES_REQUESTED" ? "Changes requested"
            : (r === "REVIEW_REQUIRED" ? "Review required" : "No review needed"))
        }

        StatusLine {
          glyph: pane.inbox.mergeBlock === "" ? "" : ""
          tone: pane.inbox.mergeBlock === "" ? pane.inbox.foreground : pane.inbox.dim
          text: pane.inbox.mergeBlock === "" ? "Ready to merge into " + pane.d.base : pane.inbox.mergeBlock
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
            implicitWidth: labelText.implicitWidth + Style.space(12)
            implicitHeight: labelText.implicitHeight + Style.space(4)
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.flat(pane.inbox.alpha(pane.inbox.foreground, 0.3), 1)

            Text {
              id: labelText
              anchors.centerIn: parent
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
        visible: !pane.full && pane.d !== null
        width: parent.width
        text: pane.inbox.previewError !== "" ? pane.inbox.previewError : "Loading details…"
        textFormat: Text.PlainText
        color: pane.inbox.previewError !== "" ? pane.inbox.urgent : pane.inbox.dim
        font.family: pane.inbox.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
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
        visible: pane.full
        width: parent.width
        text: pane.full ? (pane.plainBody(pane.d.body) || "No description.") : ""
        textFormat: Text.PlainText
        color: pane.full && pane.plainBody(pane.d.body) !== "" ? pane.inbox.foreground : pane.inbox.dim
        font.family: pane.inbox.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
        maximumLineCount: 14
        elide: Text.ElideRight
      }

      // ---------- Comments ----------
      PanelSectionHeader {
        visible: pane.full && pane.d.comments.length > 0
        width: parent.width
        topPadding: Style.space(6)
        text: "LATEST COMMENTS"
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
            text: pane.plainBody(modelData.body)
            textFormat: Text.PlainText
            color: pane.inbox.foreground
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

  // ---------- Actions, the comment box, the merge confirmation ----------
  Column {
    id: actions
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: Style.space(8)
    spacing: Style.space(8)
    visible: pane.d !== null

    Text {
      visible: pane.inbox.previewNotice !== ""
      width: parent.width
      text: pane.inbox.previewNotice
      textFormat: Text.PlainText
      color: pane.inbox.previewNoticeError ? pane.inbox.urgent : pane.inbox.foreground
      font.family: pane.inbox.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
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
          Keys.onPressed: function(event) {
            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
              pane.inbox.sendComment(commentBox.text)
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              pane.inbox.previewMode = ""
              event.accepted = true
            }
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
          text: pane.d && pane.isPr ? ({ squash: "Squash and merge", merge: "Merge", rebase: "Rebase and merge" })[pane.inbox.mergeMethod]
            + " #" + pane.d.number + " into " + pane.d.base + "?" : ""
          textFormat: Text.PlainText
          color: pane.inbox.foreground
          font.family: pane.inbox.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          wrapMode: Text.WordWrap
        }

        Row {
          visible: pane.isPr && pane.d.mergeMethods.length > 1
          spacing: Style.space(6)

          Repeater {
            model: pane.d && pane.isPr ? pane.d.mergeMethods : []

            Button {
              required property var modelData
              text: ({ squash: "Squash", merge: "Merge commit", rebase: "Rebase" })[modelData]
              selected: pane.inbox.mergeMethod === modelData
              bordered: true
              foreground: pane.inbox.foreground
              fontFamily: pane.inbox.fontFamily
              fontSize: Style.font.caption
              onClicked: pane.inbox.mergeMethod = modelData
            }
          }
        }

        Row {
          spacing: Style.space(8)

          Button {
            text: pane.inbox.actionBusy ? "Merging…" : "Confirm merge"
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

    Row {
      visible: pane.inbox.previewMode === ""
      spacing: Style.space(8)

      Button {
        text: "Open"
        tooltipText: "Enter"
        bordered: true
        foreground: pane.inbox.foreground
        fontFamily: pane.inbox.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: pane.inbox.openUrl(pane.inbox.previewUrl)
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
        visible: pane.isPr
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
    function onCommentSerialChanged() { commentBox.text = "" }
    function onPreviewUrlChanged() { commentBox.text = "" }
  }

  // One status line: glyph and text in a tone.
  component StatusLine: Row {
    property string glyph: ""
    property string text: ""
    property color tone: pane.inbox.foreground
    spacing: Style.space(8)

    Text {
      text: parent.glyph
      textFormat: Text.PlainText
      color: parent.tone
      font.family: pane.inbox.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      text: parent.text
      textFormat: Text.PlainText
      color: parent.tone
      font.family: pane.inbox.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
