import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Instabox: cloud boxes and snapshots in the bar.
//
// All CLI work happens in bin/instabox-panel, which calls the signed-in
// `instabox` CLI with a fixed argv. This file polls `status`, draws the
// panel, opens SSH in a terminal, and runs actions as child processes
// (the helper sends the success/failure notification itself).
Panel {
  id: root
  moduleName: "wyrdwerk.instabox"
  ipcTarget: "wyrdwerk.instabox"
  manageIpc: false

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  readonly property string helper: pluginDir + "bin/instabox-panel"

  readonly property int refreshIntervalSec: Math.max(30, setting("refreshIntervalSec", 120))
  readonly property int maxSnapshots: Math.max(3, setting("maxSnapshots", 8))
  readonly property bool showCount: setting("showCount", true) !== false

  property var status: null
  property bool loading: false
  property real lastRefreshAt: 0
  property real now: Date.now() / 1000

  // UI state
  property string expandedBox: ""
  property string expandedSnapshot: ""
  property bool showAllSnapshots: false
  // Inline name prompt: { kind: "snapshot-save"|"fork"|"create", target: <box or snapshot> }
  property var prompt: null
  property string promptText: ""
  // Pending confirmation: { verb, target }
  property var confirm: null
  // target -> verb for actions in flight
  property var pending: ({})
  readonly property int pendingCount: Object.keys(pending).length

  readonly property int running: Model.runningCount(status)
  readonly property bool healthy: status !== null && status.ok === true
  readonly property var machines: healthy ? status.machines : []
  readonly property var snapshots: healthy
    ? (showAllSnapshots ? status.snapshots : status.snapshots.slice(0, maxSnapshots))
    : []

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color muted: Qt.darker(foreground, 1.4)

  // ---------- data ----------

  function refresh() {
    if (statusProc.running) return
    root.loading = true
    statusProc.running = true
  }

  function applyStatus(text) {
    root.loading = false
    var next = Model.parseStatus(text)
    if (!next) return
    root.status = next
    root.lastRefreshAt = Date.now() / 1000
    root.now = root.lastRefreshAt
  }

  // ---------- actions ----------

  function setPending(target, verb) {
    var next = Object.assign({}, root.pending)
    if (verb) next[target] = verb
    else delete next[target]
    root.pending = next
  }

  function runAction(verb, args) {
    var target = args[0]
    if (root.pending[target]) return
    var proc = opComponent.createObject(root, { target: target, command: [root.helper, "action", verb].concat(args) })
    if (!proc) return
    setPending(target, verb)
    proc.running = true
  }

  function finishAction(target) {
    setPending(target, "")
    refresh()
  }

  // Destructive or disruptive verbs go through the confirm dialog first.
  function request(verb, target) {
    if (verb === "rm" || verb === "snapshot-rm" || verb === "restore" || verb === "stop" || verb === "restart") {
      root.confirm = { verb: verb, target: target }
      Qt.callLater(function() { confirmKeys.forceActiveFocus() })
    } else {
      runAction(verb, [target])
    }
  }

  function confirmAccepted() {
    var c = root.confirm
    root.confirm = null
    keyCatcher.forceActiveFocus()
    if (c) runAction(c.verb, [c.target])
  }

  function confirmCanceled() {
    root.confirm = null
    keyCatcher.forceActiveFocus()
  }

  function openPrompt(kind, target) {
    root.prompt = { kind: kind, target: target }
    root.promptText = Model.defaultName(kind, target)
  }

  function cancelPrompt() {
    root.prompt = null
    keyCatcher.forceActiveFocus()
  }

  function submitPrompt() {
    var p = root.prompt
    var name = String(root.promptText || "").trim()
    if (!p || !Model.validName(name)) return
    root.prompt = null
    keyCatcher.forceActiveFocus()
    runAction(p.kind, [p.target, name])
  }

  function ssh(name) {
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.instabox-ssh", root.helper, "ssh", name])
    // The helper wakes the box first; show that here too.
    root.close()
    wakeRefresh.restart()
  }

  function signIn() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "instabox login"])
    root.close()
  }

  function openUrl(url) {
    if (/^https:\/\//.test(url)) Quickshell.execDetached(["xdg-open", url])
  }

  function toggleBox(name) {
    root.expandedBox = root.expandedBox === name ? "" : name
    if (root.prompt && root.prompt.target !== name) root.prompt = null
  }

  function toggleSnapshot(id) {
    root.expandedSnapshot = root.expandedSnapshot === id ? "" : id
  }

  onOpenedChanged: {
    if (!opened) {
      root.prompt = null
      root.confirm = null
      return
    }
    root.now = Date.now() / 1000
    if (root.now - root.lastRefreshAt > 8) refresh()
  }

  IpcHandler {
    target: "wyrdwerk.instabox"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
    onExited: function(exitCode) { if (exitCode !== 0) root.loading = false }
  }

  Component {
    id: opComponent
    Process {
      property string target: ""
      onExited: function() {
        root.finishAction(target)
        destroy()
      }
    }
  }

  Timer { interval: 5000; running: true; onTriggered: root.refresh() }

  Timer {
    interval: root.opened || root.pendingCount > 0 ? 10000 : root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: { root.now = Date.now() / 1000; root.refresh() }
  }

  // After an SSH launch, pick up the box's new state once it has woken.
  Timer { id: wakeRefresh; interval: 15000; onTriggered: root.refresh() }

  // ---------- bar icon ----------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.icons.server + (root.showCount && root.running > 0 && !vertical ? " " + root.running : "")
    slotSize: Style.bar.iconSlot * (root.showCount && root.running > 0 && !vertical ? (root.running > 9 ? 2 : 1.6) : 1)
    opacity: root.running > 0 || root.pendingCount > 0 ? 1 : 0.55
    active: root.status !== null && !root.healthy
    tooltipText: root.opened ? "" : Model.tooltip(root.status, root.running)
    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  // ---------- panel ----------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.prompt !== null || root.confirm !== null
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Column {
          id: column
          width: flick.width
          spacing: Style.space(10)

          // ---------- hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            PlainText {
              id: heroIcon
              text: Model.icons.server
              color: root.healthy ? root.foreground : root.urgent
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: refreshButton.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              PlainText {
                text: "Instabox"
                font.pixelSize: Style.font.title
                font.bold: true
                width: parent.width
              }

              PlainText {
                text: Model.headline(root.status, root.running).toUpperCase()
                color: root.healthy || root.status === null ? root.muted : root.urgent
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                width: parent.width
              }
            }

            PanelActionButton {
              id: refreshButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: Model.icons.refresh
              tooltipText: root.loading ? "Refreshing…" : "Refresh"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.loading
              opacity: enabled ? 1 : 0.4
              onClicked: root.refresh()
            }
          }

          // ---------- error ----------
          Column {
            visible: root.status !== null && !root.healthy
            width: parent.width
            spacing: Style.space(8)

            PlainText {
              width: parent.width
              wrapMode: Text.Wrap
              maximumLineCount: 4
              text: root.status ? root.status.error : ""
              color: root.urgent
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              visible: root.status !== null && root.status.authError === true
              iconText: Model.icons.ssh
              text: "Sign in to Instabox"
              fontSize: Style.font.bodySmall
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.signIn()
            }
          }

          // ---------- boxes ----------
          PanelSectionHeader {
            visible: root.healthy
            text: "BOXES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          PlainText {
            visible: root.healthy && root.machines.length === 0
            text: "No boxes. Start one from a snapshot below."
            color: root.muted
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.machines
            delegate: MachineRow {}
          }

          PanelSeparator { visible: root.healthy; foreground: root.foreground }

          // ---------- snapshots ----------
          PanelSectionHeader {
            visible: root.healthy
            text: "SNAPSHOTS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          PlainText {
            visible: root.healthy && root.status.snapshots.length === 0
            text: "No snapshots yet."
            color: root.muted
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.snapshots
            delegate: SnapshotRow {}
          }

          PlainText {
            visible: root.healthy && root.status.snapshots.length > root.maxSnapshots
            text: root.showAllSnapshots ? "Show fewer" : "Show all " + (root.healthy ? root.status.snapshots.length : 0)
            color: root.accent
            font.pixelSize: Style.font.bodySmall
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.showAllSnapshots = !root.showAllSnapshots
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------- footer ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(footerText.implicitHeight, dashButton.implicitHeight)

            PlainText {
              id: footerText
              anchors.left: parent.left
              anchors.right: dashButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: {
                var parts = []
                if (root.healthy && root.status.usage) parts.push(Model.usageLine(root.status.usage))
                parts.push(root.loading ? "refreshing…" : (root.lastRefreshAt ? "updated " + Model.ago(root.now, new Date(root.lastRefreshAt * 1000).toISOString()) : "loading…"))
                return parts.join(" · ")
              }
              color: root.muted
              font.pixelSize: Style.font.caption
            }

            ActionButton {
              id: dashButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: Model.icons.link
              text: "Dashboard"
              tooltipText: "Open the Instabox dashboard"
              onClicked: { root.openUrl("https://dashboard.instabox.sh/dashboard/machines"); root.close() }
            }
          }
        }
      }

      // Confirm dialog over the panel; Keys go to it while it is open.
      FocusScope {
        id: confirmKeys
        anchors.fill: parent
        visible: root.confirm !== null
        z: 10
        Keys.onPressed: function(event) { event.accepted = confirmDialog.handleKey(event) }

        ConfirmDialog {
          id: confirmDialog
          anchors.fill: parent
          opened: root.confirm !== null
          message: root.confirm ? Model.confirmText(root.confirm.verb, root.confirm.target) : ""
          confirmText: root.confirm && (root.confirm.verb === "rm" || root.confirm.verb === "snapshot-rm") ? "Delete"
            : (root.confirm && root.confirm.verb === "restore" ? "Restore" : "Confirm")
          foreground: root.foreground
          fontFamily: root.fontFamily
          onConfirmed: root.confirmAccepted()
          onCanceled: root.confirmCanceled()
        }
      }
    }
  }

  // ---------- components ----------

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component StateDot: Rectangle {
    property string tone: "off"
    width: Style.space(8)
    height: width
    radius: width / 2
    color: tone === "on" ? root.accent : (tone === "bad" ? root.urgent : (tone === "busy" ? root.foreground : root.muted))
    opacity: tone === "off" ? 0.6 : 1
    SequentialAnimation on opacity {
      running: tone === "busy"
      loops: Animation.Infinite
      NumberAnimation { to: 0.3; duration: 600 }
      NumberAnimation { to: 1; duration: 600 }
    }
  }

  component ActionButton: Button {
    fontSize: Style.font.caption
    foreground: root.foreground
    fontFamily: root.fontFamily
    bordered: true
  }

  // Inline "name the new thing" prompt shared by snapshot-save, fork and create.
  component NamePrompt: Row {
    id: promptRow
    property string kind: ""
    property string target: ""
    readonly property bool shown: root.prompt !== null && root.prompt.kind === kind && root.prompt.target === target
    readonly property bool valid: Model.validName(String(root.promptText).trim())
    visible: shown
    width: parent.width
    spacing: Style.space(6)

    onShownChanged: if (shown) Qt.callLater(function() { field.forceActiveFocus(); field.selectAll() })

    TextField {
      id: field
      width: promptRow.width - okButton.width - cancelButton.width - promptRow.spacing * 2
      text: promptRow.shown ? root.promptText : ""
      placeholderText: kind === "snapshot-save" ? "Snapshot name" : "New box name"
      foreground: root.foreground
      font.pixelSize: Style.font.bodySmall
      verticalPadding: Style.spacing.controlPaddingY
      onTextChanged: if (promptRow.shown) root.promptText = text
      onAccepted: root.submitPrompt()
      Keys.onEscapePressed: root.cancelPrompt()
    }

    PanelActionButton {
      id: okButton
      anchors.verticalCenter: field.verticalCenter
      iconText: Model.icons.check
      tooltipText: promptRow.valid ? "Go" : "Letters, digits, . _ - only"
      foreground: root.foreground
      fontFamily: root.fontFamily
      enabled: promptRow.valid
      opacity: enabled ? 1 : 0.4
      onClicked: root.submitPrompt()
    }

    PanelActionButton {
      id: cancelButton
      anchors.verticalCenter: field.verticalCenter
      iconText: Model.icons.close
      tooltipText: "Cancel"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.cancelPrompt()
    }
  }

  component MachineRow: Column {
    id: mrow
    required property var modelData
    readonly property var m: modelData
    readonly property bool isOpen: root.expandedBox === m.name
    readonly property string busyVerb: root.pending[m.name] || ""
    readonly property bool isBusy: busyVerb !== "" || m.busy
    readonly property bool isRunning: Model.isRunning(m)
    readonly property var ports: Model.portsFor(root.status, m.id)
    width: column.width
    spacing: Style.space(6)

    Rectangle {
      width: parent.width
      implicitHeight: head.implicitHeight + Style.space(10)
      radius: Style.space(4)
      color: headMouse.containsMouse || mrow.isOpen ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07) : "transparent"

      MouseArea {
        id: headMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleBox(mrow.m.name)
      }

      Item {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        implicitHeight: Math.max(labels.implicitHeight, sshButton.implicitHeight)

        StateDot {
          id: dot
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          tone: mrow.busyVerb !== "" ? "busy" : Model.stateTone(mrow.m)
        }

        Column {
          id: labels
          anchors.left: dot.right
          anchors.leftMargin: Style.space(10)
          anchors.right: powerButton.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          PlainText {
            width: parent.width
            text: mrow.m.name
            font.bold: true
          }

          PlainText {
            width: parent.width
            text: (mrow.busyVerb ? Model.progressText[mrow.busyVerb] + "…" : Model.stateLabel(mrow.m)) + " · " + Model.spec(mrow.m)
            color: root.muted
            font.pixelSize: Style.font.caption
          }
        }

        PanelActionButton {
          id: powerButton
          anchors.right: sshButton.left
          anchors.rightMargin: Style.space(2)
          anchors.verticalCenter: parent.verticalCenter
          iconText: mrow.isRunning ? Model.icons.pause : Model.icons.play
          tooltipText: mrow.isRunning ? "Pause" : (mrow.m.state === "stopped" ? "Start" : "Resume")
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !mrow.isBusy
          opacity: enabled ? 1 : 0.35
          onClicked: root.request(mrow.isRunning ? "suspend" : (mrow.m.state === "stopped" ? "start" : "resume"), mrow.m.name)
        }

        PanelActionButton {
          id: sshButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.icons.ssh
          tooltipText: mrow.isRunning ? "SSH into " + mrow.m.name : "Wake and SSH into " + mrow.m.name
          foreground: root.foreground
          hoverColor: root.accent
          fontFamily: root.fontFamily
          enabled: mrow.busyVerb === "" || mrow.busyVerb === "resume" || mrow.busyVerb === "start"
          opacity: enabled ? 1 : 0.35
          onClicked: root.ssh(mrow.m.name)
        }
      }
    }

    // Expanded details and actions
    Column {
      visible: mrow.isOpen
      width: parent.width
      leftPadding: Style.space(24)
      spacing: Style.space(6)

      PlainText {
        width: parent.width - parent.leftPadding
        text: {
          var from = Model.snapshotName(root.status, mrow.m.snapshotId)
          var parts = [from ? "from " + from : (mrow.m.template ? "template " + mrow.m.template : "")]
          if (mrow.m.autoSuspendSec > 0) parts.push("idle pause " + Math.round(mrow.m.autoSuspendSec / 60) + "m")
          else parts.push("idle pause off")
          parts.push("created " + Model.ago(root.now, mrow.m.createdAt))
          return parts.filter(function(p) { return p }).join(" · ")
        }
        color: root.muted
        font.pixelSize: Style.font.caption
      }

      Repeater {
        model: mrow.ports
        PlainText {
          required property var modelData
          width: mrow.width - Style.space(24)
          text: Model.icons.link + "  :" + modelData.port + "  " + modelData.url + (modelData.access === "private" ? "  (private)" : "")
          color: root.accent
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openUrl(modelData.url)
          }
        }
      }

      Flow {
        width: parent.width - parent.leftPadding
        spacing: Style.space(6)
        enabled: !mrow.isBusy
        opacity: enabled ? 1 : 0.4

        ActionButton {
          iconText: Model.icons.snapshot; text: "Snapshot"
          tooltipText: "Save this box's disks as a snapshot"
          onClicked: root.openPrompt("snapshot-save", mrow.m.name)
        }
        ActionButton {
          iconText: Model.icons.fork; text: "Fork"
          tooltipText: "Copy this box's disks into a new box"
          onClicked: root.openPrompt("fork", mrow.m.name)
        }
        ActionButton {
          visible: mrow.m.state !== "stopped"
          iconText: Model.icons.stop; text: "Stop"
          onClicked: root.request("stop", mrow.m.name)
        }
        ActionButton {
          visible: mrow.isRunning
          iconText: Model.icons.restart; text: "Restart"
          onClicked: root.request("restart", mrow.m.name)
        }
        ActionButton {
          visible: mrow.m.snapshotId !== ""
          iconText: Model.icons.restore; text: "Restore"
          tooltipText: "Put the disks back to the snapshot it was made from"
          onClicked: root.request("restore", mrow.m.name)
        }
        ActionButton {
          iconText: Model.icons.trash; text: "Delete"
          foreground: root.urgent
          onClicked: root.request("rm", mrow.m.name)
        }
      }

      Item {
        width: parent.width - parent.leftPadding
        implicitHeight: forkPrompt.visible ? forkPrompt.implicitHeight : (savePrompt.visible ? savePrompt.implicitHeight : 0)
        NamePrompt { id: savePrompt; kind: "snapshot-save"; target: mrow.m.name }
        NamePrompt { id: forkPrompt; kind: "fork"; target: mrow.m.name }
      }
    }
  }

  component SnapshotRow: Column {
    id: srow
    required property var modelData
    readonly property var sn: modelData
    readonly property bool isOpen: root.expandedSnapshot === sn.id
    readonly property string busyVerb: root.pending[sn.name] || ""
    width: column.width
    spacing: Style.space(6)

    Rectangle {
      width: parent.width
      implicitHeight: shead.implicitHeight + Style.space(8)
      radius: Style.space(4)
      color: sMouse.containsMouse || srow.isOpen ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07) : "transparent"

      MouseArea {
        id: sMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleSnapshot(srow.sn.id)
      }

      Item {
        id: shead
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        implicitHeight: Math.max(sname.implicitHeight, newButton.implicitHeight)

        PlainText {
          id: sicon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: Model.icons.snapshot
          color: srow.sn.status === "ready" ? root.muted : root.foreground
          font.pixelSize: Style.font.bodySmall
        }

        PlainText {
          id: sname
          anchors.left: sicon.right
          anchors.leftMargin: Style.space(10)
          anchors.right: smeta.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: srow.sn.name
          font.pixelSize: Style.font.bodySmall
        }

        PlainText {
          id: smeta
          anchors.right: newButton.left
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          text: srow.busyVerb ? Model.progressText[srow.busyVerb] + "…"
            : (srow.sn.status !== "ready" ? srow.sn.status : Model.ago(root.now, srow.sn.createdAt))
          color: root.muted
          font.pixelSize: Style.font.caption
        }

        PanelActionButton {
          id: newButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.icons.plus
          tooltipText: "New box from " + srow.sn.name
          foreground: root.foreground
          hoverColor: root.accent
          fontFamily: root.fontFamily
          enabled: srow.sn.status === "ready" && srow.busyVerb === ""
          opacity: enabled ? 1 : 0.35
          onClicked: {
            root.expandedSnapshot = srow.sn.id
            root.openPrompt("create", srow.sn.name)
          }
        }
      }
    }

    Column {
      visible: srow.isOpen
      width: parent.width
      leftPadding: Style.space(24)
      spacing: Style.space(6)

      PlainText {
        visible: srow.sn.description !== ""
        width: parent.width - parent.leftPadding
        text: srow.sn.description
        wrapMode: Text.Wrap
        maximumLineCount: 4
        color: root.muted
        font.pixelSize: Style.font.caption
      }

      PlainText {
        width: parent.width - parent.leftPadding
        text: Model.bytes(srow.sn.sizeBytes) + " disks · saved " + Model.ago(root.now, srow.sn.createdAt)
        color: root.muted
        font.pixelSize: Style.font.caption
      }

      Flow {
        width: parent.width - parent.leftPadding
        spacing: Style.space(6)
        enabled: srow.busyVerb === ""
        opacity: enabled ? 1 : 0.4

        ActionButton {
          iconText: Model.icons.plus; text: "New box"
          enabled: srow.sn.status === "ready"
          onClicked: root.openPrompt("create", srow.sn.name)
        }
        ActionButton {
          iconText: Model.icons.trash; text: "Delete"
          foreground: root.urgent
          onClicked: root.request("snapshot-rm", srow.sn.name)
        }
      }

      Item {
        width: parent.width - parent.leftPadding
        implicitHeight: createPrompt.visible ? createPrompt.implicitHeight : 0
        NamePrompt { id: createPrompt; kind: "create"; target: srow.sn.name }
      }
    }
  }
}
