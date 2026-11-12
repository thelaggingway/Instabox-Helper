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

function confirmText(verb, target) {
  switch (verb) {
  case "rm": return "Delete box " + target + "? Its disks are gone for good."
  case "snapshot-rm": return "Delete snapshot " + target + "? Boxes made from it keep running."
  case "restore": return "Restore " + target + " to the snapshot it was made from? Everything since is lost."
  case "stop": return "Stop " + target + "? Running processes end; disks stay."
  case "restart": return "Restart " + target + "? Running processes end; disks stay."
  default: return verb + " " + target + "?"
  }
}

var progressText = {
  "resume": "Resuming", "start": "Starting", "suspend": "Pausing", "stop": "Stopping",
  "restart": "Restarting", "restore": "Restoring", "rm": "Deleting",
  "snapshot-save": "Saving snapshot", "fork": "Forking", "create": "Creating", "snapshot-rm": "Deleting"
}
