.pragma library

// Pure helpers for the Instabox panel: parsing, formatting, labels.

function glyph(cp) { return String.fromCodePoint(cp) }

var icons = {
  server: glyph(0xF048B),
  ssh: glyph(0xF018D),
  play: glyph(0xF040A),
  pause: glyph(0xF03E4),
  stop: glyph(0xF04DB),
  restart: glyph(0xF0709),
  snapshot: glyph(0xF0100),
  fork: glyph(0xF062C),
  trash: glyph(0xF01B4),
  refresh: glyph(0xF0450),
  restore: glyph(0xF006F),
  plus: glyph(0xF0415),
  rename: glyph(0xF04F0),
  copy: glyph(0xF018F),
  cash: glyph(0xF0114),
  template: glyph(0xF0256),
  gauge: glyph(0xF029A),
  link: glyph(0xF0339),
  check: glyph(0xF012C),
  close: glyph(0xF0156)
}

var NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/

function validName(name) { return NAME_RE.test(String(name || "")) }

function parseStatus(text) {
  try {
    var d = JSON.parse(String(text || ""))
    if (!d || typeof d !== "object") return null
    if (!Array.isArray(d.machines)) d.machines = []
    if (!Array.isArray(d.snapshots)) d.snapshots = []
    if (!Array.isArray(d.ports)) d.ports = []
    return d
  } catch (e) {
    return null
  }
}

function isRunning(m) { return m && m.state === "running" }

function runningCount(status) {
  if (!status) return 0
  var n = 0
  for (var i = 0; i < status.machines.length; i++) if (isRunning(status.machines[i])) n++
  return n
}

function stateLabel(m) {
  switch (m.state) {
  case "running": return "Running"
  case "suspended": return m.desiredState === "running" ? "Paused (idle)" : "Paused"
  case "stopped": return "Stopped"
  case "starting": return "Starting"
  case "suspending": return "Pausing"
  case "stopping": return "Stopping"
  case "error": return "Error"
  default: return m.state ? m.state.charAt(0).toUpperCase() + m.state.slice(1) : "Unknown"
  }
}

// "on" lit, "off" dim, "busy" transitional, "bad" error
function stateTone(m) {
  if (m.state === "running") return "on"
  if (m.state === "error") return "bad"
  if (m.busy || /ing$/.test(m.state || "")) return "busy"
  return "off"
}

function spec(m) {
  var parts = []
  if (m.vcpus) parts.push(m.vcpus + " vCPU")
  if (m.memMiB) parts.push(Math.round(m.memMiB / 1024) + " GB")
  if (m.diskGiB) parts.push(m.diskGiB + " GB disk")
  return parts.join(" · ")
}

function bytes(n) {
  n = Number(n) || 0
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  while (n >= 1000 && i < units.length - 1) { n /= 1000; i++ }
  return (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)) + " " + units[i]
}

function ago(nowSec, iso) {
  if (!iso) return ""
  var t = Date.parse(iso)
  if (isNaN(t)) return ""
  var d = Math.max(0, nowSec - t / 1000)
  if (d < 60) return "just now"
  if (d < 3600) return Math.floor(d / 60) + "m ago"
  if (d < 86400) return Math.floor(d / 3600) + "h ago"
  return Math.floor(d / 86400) + "d ago"
}

function snapshotName(status, id) {
  if (!status || !id) return ""
  for (var i = 0; i < status.snapshots.length; i++) if (status.snapshots[i].id === id) return status.snapshots[i].name
  return ""
}

function portsFor(status, machineId) {
  if (!status) return []
  return status.ports.filter(function(p) { return p.machineId === machineId })
}

function datestamp() {
  var d = new Date()
  function p(n) { return n < 10 ? "0" + n : "" + n }
  return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + "-" + p(d.getHours()) + p(d.getMinutes())
}

function clip(s, n) { s = String(s || ""); return s.length > n ? s.slice(0, n) : s }

// Suggested names for the inline name prompts.
function defaultName(kind, source) {
  var base = clip(String(source || "box").replace(/[^A-Za-z0-9._-]/g, "-"), 40)
  if (kind === "snapshot-save") return base + "-" + datestamp()
  if (kind === "fork") return base + "-fork"
  if (kind === "rename") return base
  return base + "-box"
}

function headline(status, running) {
  if (!status) return "Loading…"
  if (!status.ok) return status.authError ? "Not signed in" : "Can't reach Instabox"
  var total = status.machines.length
  return running + " running · " + total + (total === 1 ? " box" : " boxes") + " · " + status.snapshots.length + " snapshots"
}

function tooltip(status, running) {
  if (!status) return "Instabox"
  if (!status.ok) return "Instabox: " + (status.authError ? "not signed in" : "unreachable")
  return "Instabox: " + running + " of " + status.machines.length + " boxes running"
}

function usageLine(u) {
  if (!u) return ""
  var parts = [u.machines + (u.maxMachines ? "/" + u.maxMachines : "") + " boxes"]
  parts.push(u.snapshots + (u.maxSnapshots ? "/" + u.maxSnapshots : "") + " snapshots")
  if (u.storedBytes) parts.push(bytes(u.storedBytes))
  return parts.join(" · ")
}

function confirmText(verb, target, extra) {
  switch (verb) {
  case "restore-to": return "Restore " + target + " to snapshot " + extra + "? Everything on it since then is lost."
  case "resize-size": return "Resize " + target + " to " + extra + "? It restarts: files stay, running processes end."
  case "resize-disk": return "Set " + target + "'s disk to " + extra + " GB? A shrink, or a box that can't grow live, restarts it."
  case "new-gpu": return "Create GPU box " + target + "? " + extra + " GPU time is billed while it runs."
  case "rm": return "Delete box " + target + "? Its disks are gone for good."
  case "snapshot-rm": return "Delete snapshot " + target + "? Boxes made from it keep running."
  case "restore": return "Restore " + target + " to the snapshot it was made from? Everything since is lost."
  case "snapshot-save-restart": return "Save snapshot " + extra + " of GPU box " + target + "? A running GPU box can't be saved live, so it stops, saves and starts again: files stay, running processes end."
  case "stop": return "Stop " + target + "? Running processes end; disks stay."
  case "restart": return "Restart " + target + "? Running processes end; disks stay."
  default: return verb + " " + target + "?"
  }
}

// ---------- billing ----------

function money(v) {
  v = Number(v) || 0
  return "$" + (v >= 100 ? Math.round(v) : v.toFixed(2))
}

function billingPct(b) {
  if (!b || !(b.allowanceUSD > 0)) return 0
  return Math.max(0, Math.min(1, b.costUSD / b.allowanceUSD))
}

function shortDate(iso) {
  var t = Date.parse(iso || "")
  if (isNaN(t)) return ""
  var d = new Date(t)
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  return d.getUTCDate() + " " + months[d.getUTCMonth()]
}

function billingHeadline(b) {
  if (!b) return ""
  return b.allowanceUSD > 0 ? money(b.costUSD) + " of " + money(b.allowanceUSD) : money(b.costUSD)
}

function billingDetail(b) {
  if (!b) return ""
  var parts = []
  if (b.overageUSD > 0) parts.push(money(b.overageUSD) + " over allowance")
  else if (b.allowanceUSD > 0) parts.push(money(b.creditRemainingUSD) + " left")
  var end = shortDate(b.periodEnd)
  if (end) parts.push("resets " + end)
  return parts.join(" · ")
}

// "Usage counted up to 18:00", in local time; Instabox rates usage hourly.
function ratedLine(iso) {
  var t = Date.parse(iso || "")
  if (isNaN(t)) return "Usage is counted hourly"
  var d = new Date(t)
  function p(n) { return n < 10 ? "0" + n : "" + n }
  return "Usage counted up to " + p(d.getHours()) + ":" + p(d.getMinutes())
}

function billingParts(b) {
  if (!b || !Array.isArray(b.parts)) return []
  return b.parts.filter(function(p) { return p.usd > 0.004 || p.label === "vCPU" || p.label === "Memory" || p.label === "Storage" })
}

// ---------- sizes, idle pause, templates ----------

function specKey(s) { return s ? s.vcpus + "/" + s.memMiB : "" }

function specLabel(s) { return s ? s.vcpus + " vCPU · " + Math.round(s.memMiB / 1024) + " GB" : "" }

function sizeOptions(specs) {
  return (specs || []).slice().sort(function(a, b) { return a.vcpus - b.vcpus || a.memMiB - b.memMiB })
    .map(function(s) { return { value: specKey(s), label: specLabel(s) } })
}

var idleOptions = [
  { value: "5", label: "5m" }, { value: "10", label: "10m" }, { value: "15", label: "15m" },
  { value: "30", label: "30m" }, { value: "0", label: "Off" }
]

var deleteOptions = [
  { value: "0", label: "Never" }, { value: "1", label: "1h" }, { value: "4", label: "4h" },
  { value: "8", label: "8h" }, { value: "24", label: "24h" }
]

// The box's current idle pause as one of idleOptions' values, or "" when it matches none.
function idleValue(m) {
  var s = m ? m.autoSuspendSec : 0
  if (!s) return "0"
  var min = Math.round(s / 60)
  return ["5", "10", "15", "30"].indexOf(String(min)) >= 0 ? String(min) : ""
}

// Default template first, the rest alphabetically, blocked ones last.
function sortedTemplates(catalog) {
  if (!catalog || !Array.isArray(catalog.templates)) return []
  return catalog.templates.slice().sort(function(a, b) {
    if (a.blocked !== b.blocked) return a.blocked ? 1 : -1
    if (a.id === "agent-browser") return -1
    if (b.id === "agent-browser") return 1
    return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0)
  })
}

function findTemplate(catalog, id) {
  if (!catalog || !Array.isArray(catalog.templates)) return null
  for (var i = 0; i < catalog.templates.length; i++) if (catalog.templates[i].id === id) return catalog.templates[i]
  return null
}

// Options for the "Start from" dropdown: templates first, then ready snapshots.
function sourceOptions(catalog, status) {
  var out = []
  sortedTemplates(catalog).forEach(function(t) {
    if (!t.blocked) out.push({ value: "template:" + t.id, label: t.id + "  (template)" })
  })
  if (status && Array.isArray(status.snapshots)) status.snapshots.forEach(function(sn) {
    if (sn.status === "ready") out.push({ value: "snapshot:" + sn.name, label: sn.name + "  (snapshot)" })
  })
  return out
}

function gpuOptions(template, billing) {
  if (!template || !Array.isArray(template.gpuTypes)) return []
  return template.gpuTypes.map(function(g) {
    var price = billing && billing.gpuPrices ? billing.gpuPrices[g.type] : 0
    return {
      value: g.type,
      label: (g.model || g.type.toUpperCase()) + " · " + specLabel(g.spec) + (price ? " · " + money(price) + "/h" : "")
    }
  })
}

// argv tail for `instabox-panel action new <name> ...` from the form state.
function newBoxArgs(form) {
  var args = [form.name]
  if (form.sourceKind === "template") args.push("--template", form.sourceRef)
  else args.push("--snapshot", form.sourceRef)
  if (form.gpu) args.push("--gpu", form.gpu)
  else if (form.size) args.push("--size", form.size)
  if (form.idle !== "" && form.idle !== undefined) args.push("--idle", form.idle)
  if (form.deleteAfter && form.deleteAfter !== "0") args.push("--delete-after", form.deleteAfter)
  return args
}

function diskLine(info) {
  if (!info || !Array.isArray(info.filesystems) || info.filesystems.length === 0) return ""
  return info.filesystems.map(function(f) {
    return (f.mount === "/data" ? "home" : f.mount) + " " + bytes(f.usedBytes) + " of " + bytes(f.sizeBytes) + " (" + Math.round(f.usedPct) + "%)"
  }).join(" · ")
}

function diskWarn(info) {
  if (!info || !Array.isArray(info.filesystems)) return false
  return info.filesystems.some(function(f) { return f.usedPct >= 80 })
}

var progressText = {
  "resume": "Resuming", "start": "Starting", "suspend": "Pausing", "stop": "Stopping",
  "restart": "Restarting", "restore": "Restoring", "rm": "Deleting",
  "snapshot-save": "Saving snapshot", "snapshot-save-restart": "Saving snapshot", "fork": "Forking", "create": "Creating", "snapshot-rm": "Deleting",
  "new": "Creating", "rename": "Renaming", "restore-to": "Restoring", "idle": "Updating",
  "resize-size": "Resizing", "resize-disk": "Resizing disk"
}
