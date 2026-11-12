import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Instabox: cloud boxes, snapshots, templates and billing in the bar.
//
// All CLI work happens in bin/instabox-panel, which calls the signed-in
// `instabox` CLI with a fixed argv. This file polls `status` (and `catalog`
// for templates), draws the panel, opens SSH in a terminal, and runs actions
// as child processes (the helper sends the success/failure notification).
Panel {
  id: root
  moduleName: "thelaggingway.instabox-helper"
  ipcTarget: "thelaggingway.instabox-helper"
  manageIpc: false

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  readonly property string helper: pluginDir + "bin/instabox-panel"

  readonly property int refreshIntervalSec: Math.max(30, setting("refreshIntervalSec", 120))
  readonly property int maxSnapshots: Math.max(3, setting("maxSnapshots", 8))
  // On/off settings may arrive as booleans or as "true"/"false" strings (omarchy bar set without --json).
  function flag(name, fallback) {
    var v = setting(name, fallback)
    return v === true || v === "true" ? true : (v === false || v === "false" ? false : fallback)
  }
  readonly property bool showCount: flag("showCount", true)
  readonly property bool showBilling: flag("showBilling", true)
  // Made-up data for screenshots: the helper never calls the CLI, and actions do nothing.
  readonly property bool demo: flag("demoMode", false)
  readonly property var demoArg: demo ? ["--demo"] : []

  property var status: null
  property bool loading: false
  property real lastRefreshAt: 0
  property real now: Date.now() / 1000

  // Templates and sizes change rarely: fetched on first open, then every 6 hours.
  property var catalog: null
  property real catalogAt: 0

  // ---------- UI state ----------
  property string expandedBox: ""
  property string expandedSnapshot: ""
  property bool showAllSnapshots: false
  property bool templatesOpen: false
  property bool billingOpen: false
  // Inline name prompt on a box: { kind: "snapshot-save"|"fork"|"rename", target }
  property var prompt: null
  property string promptText: ""
  // Restore-to picker: the box whose picker is open, and the chosen snapshot.
  property string restoreBox: ""
  property string restoreChoice: ""
  // New box form: { sourceKind: "template"|"snapshot", sourceRef }
  property var form: null
  property string formName: ""
  property string formSize: ""
  property string formIdle: "30"
  property string formDelete: "0"
  property string formGpu: ""
  // Pending confirmation: { verb, target, args, extra }
  property var confirm: null
  // target -> verb for actions in flight
  property var pending: ({})
  readonly property int pendingCount: Object.keys(pending).length
  // box name -> disk info from `instabox-panel disk`
  property var diskInfo: ({})

  readonly property int running: Model.runningCount(status)
  readonly property bool healthy: status !== null && status.ok === true
  readonly property var machines: healthy ? status.machines : []
  readonly property var snapshots: healthy
    ? (showAllSnapshots ? status.snapshots : status.snapshots.slice(0, maxSnapshots))
    : []
  readonly property var templates: Model.sortedTemplates(catalog)
  readonly property var specs: healthy ? status.specs : []
  readonly property var billing: healthy ? status.billing : null
  readonly property var creating: {
    var names = machines.map(function(m) { return m.name })
    return Object.keys(pending).filter(function(k) { return pending[k] === "new" && names.indexOf(k) < 0 })
  }
  readonly property var formTemplate: form && form.sourceKind === "template" ? Model.findTemplate(catalog, form.sourceRef) : null
  readonly property bool formIsGpu: formTemplate !== null && formTemplate.gpuTypes.length > 0

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color muted: Qt.darker(foreground, 1.4)
  readonly property real labelWidth: Style.space(84)

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
    if (!Array.isArray(next.specs)) next.specs = []
    root.status = next
    root.lastRefreshAt = Date.now() / 1000
    root.now = root.lastRefreshAt
  }

  function refreshCatalog() {
    if (catalogProc.running) return
    catalogProc.running = true
  }

  function applyCatalog(text) {
    try {
      var c = JSON.parse(String(text || ""))
      if (c && c.ok && Array.isArray(c.templates)) {
        root.catalog = c
        root.catalogAt = Date.now() / 1000
      }
    } catch (e) {}
  }

  function fetchDisk(name) {
    var proc = diskComponent.createObject(root, { box: name, command: [root.helper, "disk", name].concat(root.demoArg) })
    if (proc) proc.running = true
  }

  function applyDisk(name, text) {
    try {
      var d = JSON.parse(String(text || ""))
      var next = Object.assign({}, root.diskInfo)
      next[name] = d && d.ok ? d : null
      root.diskInfo = next
    } catch (e) {}
  }

  // ---------- actions ----------

  function setPending(target, verb) {
    var next = Object.assign({}, root.pending)
    if (verb) next[target] = verb
    else delete next[target]
    root.pending = next
  }

  function demoNotice() {
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Instabox", "-u", "low", "Demo data is on", "Nothing was changed. Turn off Demo data in the plugin settings."])
  }

  function runAction(verb, args) {
    if (root.demo) { demoNotice(); return }
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

  readonly property var confirmVerbs: ["rm", "snapshot-rm", "restore", "restore-to", "stop", "restart", "resize-size", "resize-disk", "new-gpu"]

  // Destructive, disruptive or billable verbs go through the confirm dialog first.
  function request(verb, target, args, extra) {
    var a = args || [target]
    if (confirmVerbs.indexOf(verb) >= 0) {
      root.confirm = { verb: verb, target: target, args: a, extra: extra || "" }
      Qt.callLater(function() { confirmKeys.forceActiveFocus() })
    } else {
      runAction(verb, a)
    }
  }

  function confirmAccepted() {
    var c = root.confirm
    root.confirm = null
    keyCatcher.forceActiveFocus()
    if (!c) return
    if (c.verb === "new-gpu") {
      root.form = null
      runAction("new", c.args)
    } else {
      runAction(c.verb, c.args)
    }
  }

  function confirmCanceled() {
    root.confirm = null
    keyCatcher.forceActiveFocus()
  }

  function uniqueName(base) {
    var names = root.machines.map(function(m) { return m.name })
    if (names.indexOf(base) < 0) return base
    for (var i = 2; i < 100; i++) {
      var n = Model.clip(base, 58) + "-" + i
      if (names.indexOf(n) < 0) return n
    }
    return base
  }

  function openPrompt(kind, target) {
    root.restoreBox = ""
    root.prompt = { kind: kind, target: target }
    root.promptText = kind === "rename" ? target : uniqueName(Model.defaultName(kind, target))
  }

  function cancelPrompt() {
    root.prompt = null
    keyCatcher.forceActiveFocus()
  }

  function submitPrompt() {
    var p = root.prompt
    var name = String(root.promptText || "").trim()
    if (!p || !Model.validName(name)) return
    if (p.kind === "rename" && name === p.target) { cancelPrompt(); return }
    root.prompt = null
    keyCatcher.forceActiveFocus()
    runAction(p.kind, [p.target, name])
  }

  function openRestore(box) {
    root.prompt = null
    root.restoreBox = box
    root.restoreChoice = ""
  }

  function submitRestore() {
    var box = root.restoreBox
    var sn = root.restoreChoice
    if (!box || !Model.validName(sn)) return
    root.restoreBox = ""
    request("restore-to", box, [box, sn], sn)
  }

  // ----- new box form -----

  function openForm(kind, ref) {
    if (!root.catalog) refreshCatalog()
    root.prompt = null
    root.restoreBox = ""
    setFormSource(kind, ref)
    root.formIdle = "30"
    root.formDelete = "0"
    flick.contentY = 0
  }

  function setFormSource(kind, ref) {
    root.form = { sourceKind: kind, sourceRef: ref }
    root.formName = uniqueName(Model.defaultName("create", ref))
    var t = kind === "template" ? Model.findTemplate(root.catalog, ref) : null
    var keys = Model.sizeOptions(root.specs).map(function(o) { return o.value })
    var want = t ? Model.specKey(t.spec) : (root.specs.length ? Model.specKey(root.specs[0]) : "")
    root.formSize = keys.indexOf(want) >= 0 ? want : (keys.length ? keys[0] : "")
    root.formGpu = t && t.gpuTypes.length ? t.gpuTypes[0].type : ""
  }

  function onSourcePicked(value) {
    var i = value.indexOf(":")
    if (i > 0) setFormSource(value.slice(0, i), value.slice(i + 1))
  }

  function cancelForm() {
    root.form = null
    keyCatcher.forceActiveFocus()
  }

  readonly property bool formValid: form !== null && Model.validName(String(formName).trim())
    && machines.every(function(m) { return m.name !== String(formName).trim() })

  function submitForm() {
    if (!root.formValid) return
    var f = {
      name: String(root.formName).trim(),
      sourceKind: root.form.sourceKind,
      sourceRef: root.form.sourceRef,
      size: root.formIsGpu ? "" : root.formSize,
      gpu: root.formIsGpu ? root.formGpu : "",
      idle: root.formIdle,
      deleteAfter: root.formDelete
    }
    var args = Model.newBoxArgs(f)
    if (f.gpu) {
      var label = (Model.gpuOptions(root.formTemplate, root.billing).filter(function(o) { return o.value === f.gpu })[0] || { label: f.gpu }).label
      request("new-gpu", f.name, args, label + ".")
      return
    }
    root.form = null
    keyCatcher.forceActiveFocus()
    runAction("new", args)
  }

  // ----- misc -----

  function ssh(name) {
    if (root.demo) { demoNotice(); return }
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=org.omarchy.instabox-ssh", root.helper, "ssh", name])
    root.close()
    wakeRefresh.restart()
  }

  function copySsh(name) {
    if (!Model.validName(name)) return
    Quickshell.execDetached(["wl-copy", "instabox ssh " + name])
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Instabox", "-u", "low", "Copied", "instabox ssh " + name])
  }

  function signIn() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "instabox login"])
    root.close()
  }

  function openUrl(url) {
    if (/^https:\/\//.test(url)) Quickshell.execDetached(["xdg-open", url])
  }

  function toggleBox(m) {
    var open = root.expandedBox !== m.name
    root.expandedBox = open ? m.name : ""
    if (root.prompt && root.prompt.target !== m.name) root.prompt = null
    if (root.restoreBox !== m.name) root.restoreBox = ""
    if (open && Model.isRunning(m)) fetchDisk(m.name)
  }

  function toggleSnapshot(id) {
    root.expandedSnapshot = root.expandedSnapshot === id ? "" : id
  }

  onDemoChanged: { root.status = null; root.catalog = null; root.diskInfo = ({}); refresh(); refreshCatalog() }

  onOpenedChanged: {
    if (!opened) {
      root.prompt = null
      root.confirm = null
      root.form = null
      root.restoreBox = ""
      return
    }
    root.now = Date.now() / 1000
    if (root.now - root.lastRefreshAt > 8) refresh()
    if (root.now - root.catalogAt > 6 * 3600) refreshCatalog()
  }

  IpcHandler {
    target: "thelaggingway.instabox-helper"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function newBox(): void { root.open(); root.openForm("template", "agent-browser") }
  }

  Process {
    id: statusProc
    command: [root.helper, "status"].concat(root.demoArg)
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
    onExited: function(exitCode) { if (exitCode !== 0) root.loading = false }
  }

  Process {
    id: catalogProc
    command: [root.helper, "catalog"].concat(root.demoArg)
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyCatalog(text) }
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

  Component {
    id: diskComponent
    Process {
      id: dp
      property string box: ""
      stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyDisk(dp.box, text) }
      onExited: function() { destroy() }
    }
  }

  Timer { interval: 5000; running: true; onTriggered: { root.refresh(); root.refreshCatalog() } }

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
      + (root.billing ? "\n" + Model.billingHeadline(root.billing) + " this month" : "")
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
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.prompt !== null || root.confirm !== null || root.form !== null || root.restoreBox !== ""
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
              anchors.right: newButton.left
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
              id: newButton
              anchors.right: refreshButton.left
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              visible: root.healthy
              iconText: Model.icons.plus
              tooltipText: "New box"
              foreground: root.foreground
              hoverColor: root.accent
              fontFamily: root.fontFamily
              onClicked: root.form ? root.cancelForm() : root.openForm("template", "agent-browser")
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

          // ---------- billing ----------
          BillingCard { visible: root.showBilling && root.billing !== null }

          // ---------- new box form ----------
          NewBoxForm { visible: root.form !== null }

          // ---------- boxes ----------
          PanelSectionHeader {
            visible: root.healthy
            text: "BOXES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          PlainText {
            visible: root.healthy && root.machines.length === 0 && root.creating.length === 0
            text: "No boxes. Use + to create one."
            color: root.muted
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.creating
            Row {
              required property var modelData
              spacing: Style.space(10)
              leftPadding: Style.space(6)
              StateDot { tone: "busy"; anchors.verticalCenter: parent.verticalCenter }
              PlainText {
                text: modelData + " · creating…"
                color: root.muted
                font.pixelSize: Style.font.bodySmall
              }
            }
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

          PanelSeparator { visible: root.healthy; foreground: root.foreground }

          // ---------- templates ----------
          Item {
            visible: root.healthy
            width: parent.width
            implicitHeight: tplHeader.implicitHeight

            PanelSectionHeader {
              id: tplHeader
              text: "TEMPLATES " + (root.templatesOpen ? "▾" : "▸") + (root.catalog ? "  " + root.templates.length : "")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.templatesOpen = !root.templatesOpen
                if (root.templatesOpen && !root.catalog) root.refreshCatalog()
              }
            }
          }

          PlainText {
            visible: root.healthy && root.templatesOpen && !root.catalog
            text: catalogProc.running ? "Loading templates…" : "Couldn't load templates."
            color: root.muted
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.templatesOpen ? root.templates : []
            delegate: TemplateRow {}
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
                if (root.demo) { parts.push("demo data"); return parts.join(" · ") }
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
          message: root.confirm ? Model.confirmText(root.confirm.verb, root.confirm.target, root.confirm.extra) : ""
          confirmText: {
            var v = root.confirm ? root.confirm.verb : ""
            if (v === "rm" || v === "snapshot-rm") return "Delete"
            if (v === "restore" || v === "restore-to") return "Restore"
            if (v === "resize-size" || v === "resize-disk") return "Resize"
            if (v === "new-gpu") return "Create"
            return "Confirm"
          }
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

  component Chips: ButtonGroup {
    fontSize: Style.font.caption
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  component Picker: Dropdown {
    showLabel: false
    fontFamily: root.fontFamily
  }

  // A labelled form row: label on the left, one control on the right.
  component FieldLabel: PlainText {
    width: root.labelWidth
    color: root.muted
    font.pixelSize: Style.font.caption
  }

  component RowCard: Rectangle {
    radius: Style.space(4)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
  }

  // Inline "name" prompt shared by snapshot-save, fork and rename.
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
      placeholderText: kind === "snapshot-save" ? "Snapshot name" : (kind === "rename" ? "New name" : "New box name")
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

  component BillingCard: Column {
    id: bc
    width: column.width
    spacing: Style.space(6)
    readonly property var b: root.billing
    readonly property bool over: b !== null && b.overageUSD > 0

    Item {
      width: parent.width
      implicitHeight: billTop.implicitHeight

      Row {
        id: billTop
        width: parent.width
        spacing: Style.space(8)

        PlainText {
          id: billLabel
          text: Model.icons.cash + "  THIS MONTH"
          color: root.muted
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
        }

        PlainText {
          width: parent.width - billLabel.implicitWidth - parent.spacing
          horizontalAlignment: Text.AlignRight
          text: Model.billingHeadline(bc.b) + "  " + (root.billingOpen ? "▾" : "▸")
          color: bc.over ? root.urgent : root.foreground
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.billingOpen = !root.billingOpen
      }
    }

    Rectangle {
      visible: bc.b !== null && bc.b.allowanceUSD > 0
      width: parent.width
      height: Style.space(4)
      radius: height / 2
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

      Rectangle {
        width: Math.max(height, parent.width * Model.billingPct(bc.b))
        height: parent.height
        radius: height / 2
        color: bc.over ? root.urgent : (Model.billingPct(bc.b) >= 0.8 ? root.urgent : root.accent)
      }
    }

    PlainText {
      width: parent.width
      text: Model.billingDetail(bc.b) + (bc.b && bc.b.tier ? " · " + bc.b.tier + " plan" : "")
      color: bc.over ? root.urgent : root.muted
      font.pixelSize: Style.font.caption
    }

    Column {
      visible: root.billingOpen
      width: parent.width
      spacing: Style.space(2)

      Repeater {
        model: root.billingOpen ? Model.billingParts(bc.b) : []
        Row {
          required property var modelData
          width: bc.width
          spacing: Style.space(8)
          PlainText {
            id: partLabel
            width: root.labelWidth
            text: modelData.label
            font.pixelSize: Style.font.caption
          }
          PlainText {
            width: bc.width - root.labelWidth - partUsd.implicitWidth - parent.spacing * 2
            text: modelData.detail
            color: root.muted
            font.pixelSize: Style.font.caption
          }
          PlainText {
            id: partUsd
            text: Model.money(modelData.usd)
            font.pixelSize: Style.font.caption
          }
        }
      }

      PlainText {
        width: parent.width
        text: Model.ratedLine(bc.b ? bc.b.ratedUntil : "") + (bc.b && bc.b.creditsUSD > 0 ? " · " + Model.money(bc.b.creditsUSD) + " promo credit" : "")
        color: root.muted
        font.pixelSize: Style.font.caption
      }
    }

    PanelSeparator { width: parent.width; foreground: root.foreground }
  }

  component NewBoxForm: RowCard {
    id: nf
    width: column.width
    implicitHeight: formCol.implicitHeight + Style.space(20)

    Column {
      id: formCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      spacing: Style.space(8)

      PlainText {
        text: "New box"
        font.bold: true
      }

      Row {
        width: parent.width
        FieldLabel { text: "Start from"; anchors.verticalCenter: parent.verticalCenter }
        Picker {
          width: parent.width - root.labelWidth
          options: Model.sourceOptions(root.catalog, root.status)
          value: root.form ? root.form.sourceKind + ":" + root.form.sourceRef : ""
          onChanged: function(v) { root.onSourcePicked(v) }
        }
      }

      PlainText {
        visible: text !== ""
        width: parent.width
        leftPadding: root.labelWidth
        wrapMode: Text.Wrap
        maximumLineCount: 3
        text: root.formTemplate ? root.formTemplate.description : ""
        color: root.muted
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        FieldLabel { text: "Name"; anchors.verticalCenter: parent.verticalCenter }
        TextField {
          id: nameField
          width: parent.width - root.labelWidth
          text: root.formName
          placeholderText: "box name"
          foreground: root.foreground
          font.pixelSize: Style.font.bodySmall
          verticalPadding: Style.spacing.controlPaddingY
          onTextChanged: if (text !== root.formName) root.formName = text
          onAccepted: root.submitForm()
          Keys.onEscapePressed: root.cancelForm()
        }
      }

      Row {
        visible: !root.formIsGpu
        width: parent.width
        FieldLabel { text: "Size"; anchors.verticalCenter: parent.verticalCenter }
        Chips {
          options: Model.sizeOptions(root.specs)
          value: root.formSize
          onChanged: function(v) { root.formSize = v }
        }
      }

      Row {
        visible: root.formIsGpu
        width: parent.width
        FieldLabel { text: "GPU"; anchors.verticalCenter: parent.verticalCenter }
        Picker {
          width: parent.width - root.labelWidth
          options: Model.gpuOptions(root.formTemplate, root.billing)
          value: root.formGpu
          onChanged: function(v) { root.formGpu = v }
        }
      }

      Row {
        width: parent.width
        FieldLabel { text: "Idle pause"; anchors.verticalCenter: parent.verticalCenter }
        Chips {
          options: Model.idleOptions
          value: root.formIdle
          onChanged: function(v) { root.formIdle = v }
        }
      }

      Row {
        width: parent.width
        FieldLabel { text: "Delete after"; anchors.verticalCenter: parent.verticalCenter }
        Chips {
          options: Model.deleteOptions
          value: root.formDelete
          onChanged: function(v) { root.formDelete = v }
        }
      }

      Item {
        width: parent.width
        implicitHeight: createButton.implicitHeight

        PlainText {
          anchors.left: parent.left
          anchors.right: cancelFormButton.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          visible: !root.formValid && root.form !== null
          text: Model.validName(String(root.formName).trim()) ? "A box with that name exists" : "Name: letters, digits, . _ -"
          color: root.urgent
          font.pixelSize: Style.font.caption
        }

        ActionButton {
          id: cancelFormButton
          anchors.right: createButton.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: "Cancel"
          onClicked: root.cancelForm()
        }

        ActionButton {
          id: createButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.icons.plus
          text: "Create"
          active: root.formValid
          enabled: root.formValid
          opacity: enabled ? 1 : 0.4
          onClicked: root.submitForm()
        }
      }
    }

    onVisibleChanged: if (visible) Qt.callLater(function() { nameField.forceActiveFocus(); nameField.selectAll() })
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
    readonly property var disk: root.diskInfo[m.name] || null
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
        onClicked: root.toggleBox(mrow.m)
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

    // Expanded details, actions and settings
    Column {
      visible: mrow.isOpen
      width: parent.width
      leftPadding: Style.space(24)
      spacing: Style.space(8)
      readonly property real innerWidth: width - leftPadding

      PlainText {
        width: parent.innerWidth
        text: {
          var from = Model.snapshotName(root.status, mrow.m.snapshotId)
          var parts = [from ? "from " + from : (mrow.m.template ? "template " + mrow.m.template : "")]
          parts.push("created " + Model.ago(root.now, mrow.m.createdAt))
          return parts.filter(function(p) { return p }).join(" · ")
        }
        color: root.muted
        font.pixelSize: Style.font.caption
      }

      PlainText {
        visible: mrow.isRunning && mrow.disk !== null
        width: parent.innerWidth
        text: Model.icons.gauge + "  " + Model.diskLine(mrow.disk)
        color: Model.diskWarn(mrow.disk) ? root.urgent : root.muted
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
        width: parent.innerWidth
        spacing: Style.space(6)
        enabled: !mrow.isBusy
        opacity: enabled ? 1 : 0.4

        ActionButton {
          iconText: Model.icons.copy; text: "Copy SSH"
          tooltipText: "Copy \"instabox ssh " + mrow.m.name + "\""
          onClicked: root.copySsh(mrow.m.name)
        }
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
          iconText: Model.icons.rename; text: "Rename"
          onClicked: root.openPrompt("rename", mrow.m.name)
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
          iconText: Model.icons.restore; text: "Restore to…"
          tooltipText: "Put the disks back to any snapshot"
          onClicked: root.openRestore(mrow.m.name)
        }
        ActionButton {
          iconText: Model.icons.trash; text: "Delete"
          foreground: root.urgent
          onClicked: root.request("rm", mrow.m.name)
        }
      }

      Item {
        width: parent.innerWidth
        implicitHeight: savePrompt.visible ? savePrompt.implicitHeight : (forkPrompt.visible ? forkPrompt.implicitHeight : (renamePrompt.visible ? renamePrompt.implicitHeight : 0))
        visible: implicitHeight > 0
        NamePrompt { id: savePrompt; kind: "snapshot-save"; target: mrow.m.name }
        NamePrompt { id: forkPrompt; kind: "fork"; target: mrow.m.name }
        NamePrompt { id: renamePrompt; kind: "rename"; target: mrow.m.name }
      }

      // Restore to another snapshot
      Row {
        visible: root.restoreBox === mrow.m.name
        width: parent.innerWidth
        spacing: Style.space(6)

        Picker {
          id: restorePicker
          width: parent.width - restoreGo.width - restoreCancel.width - parent.spacing * 2
          options: root.healthy ? root.status.snapshots.filter(function(s) { return s.status === "ready" }).map(function(s) { return s.name }) : []
          value: root.restoreChoice
          onChanged: function(v) { root.restoreChoice = v }
        }
        PanelActionButton {
          id: restoreGo
          anchors.verticalCenter: restorePicker.verticalCenter
          iconText: Model.icons.check
          tooltipText: "Restore to this snapshot"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: Model.validName(root.restoreChoice)
          opacity: enabled ? 1 : 0.4
          onClicked: root.submitRestore()
        }
        PanelActionButton {
          id: restoreCancel
          anchors.verticalCenter: restorePicker.verticalCenter
          iconText: Model.icons.close
          tooltipText: "Cancel"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.restoreBox = ""
        }
      }

      // Settings
      Column {
        width: parent.innerWidth
        spacing: Style.space(6)
        enabled: !mrow.isBusy
        opacity: enabled ? 1 : 0.4

        Row {
          width: parent.width
          FieldLabel { text: "Idle pause"; anchors.verticalCenter: parent.verticalCenter }
          Chips {
            options: Model.idleOptions
            value: Model.idleValue(mrow.m)
            onChanged: function(v) { if (v !== Model.idleValue(mrow.m)) root.runAction("idle", [mrow.m.name, v]) }
          }
        }

        Row {
          visible: !mrow.m.gpu && root.specs.length > 1
          width: parent.width
          FieldLabel { text: "Size"; anchors.verticalCenter: parent.verticalCenter }
          Chips {
            options: Model.sizeOptions(root.specs)
            value: mrow.m.vcpus + "/" + mrow.m.memMiB
            onChanged: function(v) {
              var p = v.split("/")
              if (v !== mrow.m.vcpus + "/" + mrow.m.memMiB)
                root.request("resize-size", mrow.m.name, [mrow.m.name, p[0], p[1]], p[0] + " vCPU / " + Math.round(p[1] / 1024) + " GB")
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)
          FieldLabel { text: "Disk (GB)"; anchors.verticalCenter: parent.verticalCenter }
          NumberField {
            id: diskField
            anchors.verticalCenter: parent.verticalCenter
            from: 10
            to: 1024
            stepSize: 10
            value: mrow.m.diskGiB || 20
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
          }
          ActionButton {
            anchors.verticalCenter: parent.verticalCenter
            text: "Apply"
            visible: diskField.value !== mrow.m.diskGiB
            onClicked: root.request("resize-disk", mrow.m.name, [mrow.m.name, String(diskField.value)], String(diskField.value))
          }
        }
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
        implicitHeight: Math.max(sname.implicitHeight, snNewButton.implicitHeight)

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
          anchors.right: snNewButton.left
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          text: srow.busyVerb ? Model.progressText[srow.busyVerb] + "…"
            : (srow.sn.status !== "ready" ? srow.sn.status : Model.ago(root.now, srow.sn.createdAt))
          color: root.muted
          font.pixelSize: Style.font.caption
        }

        PanelActionButton {
          id: snNewButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: Model.icons.plus
          tooltipText: "New box from " + srow.sn.name
          foreground: root.foreground
          hoverColor: root.accent
          fontFamily: root.fontFamily
          enabled: srow.sn.status === "ready" && srow.busyVerb === ""
          opacity: enabled ? 1 : 0.35
          onClicked: root.openForm("snapshot", srow.sn.name)
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
          + (srow.sn.template ? " · template " + srow.sn.template : "")
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
          onClicked: root.openForm("snapshot", srow.sn.name)
        }
        ActionButton {
          iconText: Model.icons.trash; text: "Delete"
          foreground: root.urgent
          onClicked: root.request("snapshot-rm", srow.sn.name)
        }
      }
    }
  }

  component TemplateRow: Rectangle {
    id: trow
    required property var modelData
    readonly property var t: modelData
    width: column.width
    implicitHeight: tcol.implicitHeight + Style.space(8)
    radius: Style.space(4)
    color: tMouse.containsMouse && !t.blocked ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07) : "transparent"

    MouseArea {
      id: tMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: trow.t.blocked ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: if (!trow.t.blocked) root.openForm("template", trow.t.id)
    }

    PlainText {
      id: ticon
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.top: tcol.top
      text: Model.icons.template
      color: root.muted
      font.pixelSize: Style.font.bodySmall
    }

    Column {
      id: tcol
      anchors.left: ticon.right
      anchors.leftMargin: Style.space(10)
      anchors.right: tNew.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      PlainText {
        width: parent.width
        text: trow.t.id + (trow.t.id === "agent-browser" ? "  (default)" : "")
        font.pixelSize: Style.font.bodySmall
        opacity: trow.t.blocked ? 0.6 : 1
      }
      PlainText {
        width: parent.width
        text: trow.t.blocked ? "Leases a whole Mac for 24 h minimum; create it with the CLI or dashboard" : trow.t.description
        color: root.muted
        font.pixelSize: Style.font.caption
      }
    }

    PanelActionButton {
      id: tNew
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      visible: !trow.t.blocked
      iconText: Model.icons.plus
      tooltipText: "New box from " + trow.t.id
      foreground: root.foreground
      hoverColor: root.accent
      fontFamily: root.fontFamily
      onClicked: root.openForm("template", trow.t.id)
    }
  }
}
