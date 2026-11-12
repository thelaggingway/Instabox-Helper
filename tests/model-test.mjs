// Tests Model.js (a QML ".pragma library" file) under Node: node tests/model-test.mjs
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import assert from "node:assert/strict"
import vm from "node:vm"

const src = readFileSync(fileURLToPath(new URL("../Model.js", import.meta.url)), "utf8").replace(/^\.pragma library\s*$/m, "")
const M = {}
vm.runInNewContext(src + "\n;Object.assign(M, { glyph, icons, validName, parseStatus, runningCount, stateLabel, stateTone, spec, bytes, ago, snapshotName, portsFor, defaultName, headline, tooltip, usageLine, confirmText, progressText, money, billingPct, shortDate, billingHeadline, billingDetail, billingParts, ratedLine, specKey, specLabel, sizeOptions, idleOptions, deleteOptions, idleValue, sortedTemplates, findTemplate, sourceOptions, gpuOptions, newBoxArgs, diskLine, diskWarn })", { M, Date, JSON, Math, String, Number, Object, Array, isNaN })

let n = 0
const t = (name, fn) => { fn(); n++ }

t("validName", () => {
  for (const ok of ["dev", "a", "box-1.2_x", "A".repeat(63)]) assert.ok(M.validName(ok), ok)
  for (const bad of ["", "-x", ".x", "a b", "a;b", "$(id)", "A".repeat(64), null, undefined]) assert.ok(!M.validName(bad), String(bad))
})

t("parseStatus", () => {
  assert.equal(M.parseStatus("not json"), null)
  assert.equal(M.parseStatus(""), null)
  const s = M.parseStatus('{"ok":true}')
  assert.deepEqual([s.machines.length, s.snapshots.length, s.ports.length], [0, 0, 0])
})

t("running count and labels", () => {
  const s = { machines: [{ state: "running" }, { state: "suspended" }, { state: "running" }] }
  assert.equal(M.runningCount(s), 2)
  assert.equal(M.runningCount(null), 0)
  assert.equal(M.stateLabel({ state: "suspended", desiredState: "running" }), "Paused (idle)")
  assert.equal(M.stateLabel({ state: "suspended", desiredState: "suspended" }), "Paused")
  assert.equal(M.stateLabel({ state: "weird" }), "Weird")
  assert.equal(M.stateTone({ state: "running" }), "on")
  assert.equal(M.stateTone({ state: "starting" }), "busy")
  assert.equal(M.stateTone({ state: "suspended", busy: true }), "busy")
  assert.equal(M.stateTone({ state: "error" }), "bad")
  assert.equal(M.stateTone({ state: "stopped" }), "off")
})

t("formatting", () => {
  assert.equal(M.spec({ vcpus: 4, memMiB: 8192, diskGiB: 20 }), "4 vCPU · 8 GB · 20 GB disk")
  assert.equal(M.spec({}), "")
  assert.equal(M.bytes(0), "0 B")
  assert.equal(M.bytes(106127962874), "106 GB")
  assert.equal(M.bytes(1500), "1.5 KB")
  const now = Date.parse("2026-11-12T12:00:00Z") / 1000
  assert.equal(M.ago(now, "2026-11-12T11:59:30Z"), "just now")
  assert.equal(M.ago(now, "2026-11-12T11:00:00Z"), "1h ago")
  assert.equal(M.ago(now, "2026-11-10T12:00:00Z"), "2d ago")
  assert.equal(M.ago(now, "garbage"), "")
})

t("lookups", () => {
  const s = { snapshots: [{ id: "sn_1", name: "base" }], ports: [{ machineId: "m_1", port: 1 }, { machineId: "m_2", port: 2 }] }
  assert.equal(M.snapshotName(s, "sn_1"), "base")
  assert.equal(M.snapshotName(s, "nope"), "")
  assert.deepEqual([...M.portsFor(s, "m_2").map(p => p.port)], [2])
})

t("default names are always valid", () => {
  for (const kind of ["snapshot-save", "fork", "create"]) {
    for (const src of ["dev", "weird name!", "x".repeat(80), ""]) {
      const name = M.defaultName(kind, src)
      assert.ok(M.validName(name), `${kind}(${src}) -> ${name}`)
    }
  }
  assert.match(M.defaultName("snapshot-save", "dev"), /^dev-\d{8}-\d{4}$/)
  assert.equal(M.defaultName("fork", "dev"), "dev-fork")
})

t("headline, tooltip, usage, confirm", () => {
  const s = { ok: true, machines: [{}, {}], snapshots: [{}] }
  assert.equal(M.headline(s, 1), "1 running · 2 boxes · 1 snapshots")
  assert.equal(M.headline({ ok: false, authError: true }, 0), "Not signed in")
  assert.equal(M.headline(null, 0), "Loading…")
  assert.equal(M.tooltip(s, 1), "Instabox: 1 of 2 boxes running")
  assert.equal(M.usageLine({ machines: 4, maxMachines: 500, snapshots: 21, maxSnapshots: 0, storedBytes: 1e9 }), "4/500 boxes · 21 snapshots · 1.0 GB")
  for (const v of ["rm", "snapshot-rm", "restore", "stop", "restart"]) assert.match(M.confirmText(v, "dev"), /dev/)
  for (const v of ["resume", "start", "suspend", "stop", "restart", "restore", "rm", "snapshot-save", "fork", "create", "snapshot-rm"]) assert.ok(M.progressText[v], v)
})

t("icons are single code points", () => {
  for (const [k, v] of Object.entries(M.icons)) assert.equal([...v].length, 1, k)
})

t("billing", () => {
  const b = { costUSD: 1.5, allowanceUSD: 20, creditRemainingUSD: 18.5, overageUSD: 0, periodEnd: "2026-12-01T00:00:00Z",
    parts: [{ label: "vCPU", usd: 0.5 }, { label: "GPU", usd: 0 }, { label: "Egress", usd: 0.01 }] }
  assert.equal(M.money(1.5), "$1.50")
  assert.equal(M.money(150.4), "$150")
  assert.equal(M.billingHeadline(b), "$1.50 of $20.00")
  assert.equal(M.billingDetail(b), "$18.50 left · resets 1 Dec")
  assert.equal(M.billingDetail({ ...b, overageUSD: 3 }), "$3.00 over allowance · resets 1 Dec")
  assert.equal(M.billingPct(b), 0.075)
  assert.equal(M.billingPct({ costUSD: 50, allowanceUSD: 20 }), 1)
  assert.equal(M.billingPct({ costUSD: 5, allowanceUSD: 0 }), 0)
  assert.deepEqual([...M.billingParts(b).map(p => p.label)], ["vCPU", "Egress"])
  assert.equal(M.shortDate("bad"), "")
  assert.match(M.ratedLine("2026-11-12T18:00:00Z"), /^Usage counted up to \d\d:\d\d$/)
  assert.equal(M.ratedLine(""), "Usage is counted hourly")
})

t("sizes and idle", () => {
  const specs = [{ vcpus: 4, memMiB: 8192 }, { vcpus: 2, memMiB: 4096 }, { vcpus: 8, memMiB: 16384 }]
  assert.deepEqual([...M.sizeOptions(specs).map(o => o.value)], ["2/4096", "4/8192", "8/16384"])
  assert.equal(M.specLabel(specs[0]), "4 vCPU · 8 GB")
  assert.equal(M.idleValue({ autoSuspendSec: 1800 }), "30")
  assert.equal(M.idleValue({ autoSuspendSec: 0 }), "0")
  assert.equal(M.idleValue({ autoSuspendSec: 420 }), "")
  for (const o of M.idleOptions) assert.ok(o.value === "0" || (+o.value >= 5 && +o.value <= 30))
  for (const o of M.deleteOptions) assert.ok(+o.value >= 0 && +o.value <= 24)
})

t("templates and sources", () => {
  const cat = { templates: [{ id: "zeta" }, { id: "macos", blocked: true }, { id: "agent-browser" }, { id: "alpha", gpuTypes: [{ type: "l4", model: "NVIDIA L4", spec: { vcpus: 11, memMiB: 36864 } }] }] }
  assert.deepEqual([...M.sortedTemplates(cat).map(t => t.id)], ["agent-browser", "alpha", "zeta", "macos"])
  assert.equal(M.findTemplate(cat, "zeta").id, "zeta")
  assert.equal(M.findTemplate(cat, "nope"), null)
  const status = { snapshots: [{ name: "s1", status: "ready" }, { name: "s2", status: "pending" }] }
  const src = M.sourceOptions(cat, status).map(o => o.value)
  assert.deepEqual([...src], ["template:agent-browser", "template:alpha", "template:zeta", "snapshot:s1"])
  assert.equal(M.gpuOptions(M.findTemplate(cat, "alpha"), { gpuPrices: { l4: 0.8 } })[0].label, "NVIDIA L4 · 11 vCPU · 36 GB · $0.80/h")
  assert.equal(M.gpuOptions(M.findTemplate(cat, "alpha"), null)[0].label, "NVIDIA L4 · 11 vCPU · 36 GB")
})

t("newBoxArgs", () => {
  assert.deepEqual([...M.newBoxArgs({ name: "b", sourceKind: "template", sourceRef: "agent-browser", size: "2/4096", idle: "15", deleteAfter: "4" })],
    ["b", "--template", "agent-browser", "--size", "2/4096", "--idle", "15", "--delete-after", "4"])
  assert.deepEqual([...M.newBoxArgs({ name: "b", sourceKind: "snapshot", sourceRef: "s1", size: "", idle: "30", deleteAfter: "0" })],
    ["b", "--snapshot", "s1", "--idle", "30"])
  assert.deepEqual([...M.newBoxArgs({ name: "g", sourceKind: "template", sourceRef: "gpu", gpu: "l4", size: "4/8192", idle: "0" })],
    ["g", "--template", "gpu", "--gpu", "l4", "--idle", "0"])
})

t("disk", () => {
  const d = { filesystems: [{ mount: "/data", usedBytes: 4e9, sizeBytes: 20e9, usedPct: 20 }, { mount: "/", usedBytes: 9e9, sizeBytes: 10e9, usedPct: 90 }] }
  assert.equal(M.diskLine(d), "home 4.0 GB of 20.0 GB (20%) · / 9.0 GB of 10.0 GB (90%)")
  assert.ok(M.diskWarn(d))
  assert.ok(!M.diskWarn({ filesystems: [d.filesystems[0]] }))
  assert.equal(M.diskLine(null), "")
})

t("v0.2 confirm texts", () => {
  assert.match(M.confirmText("restore-to", "dev", "base"), /dev.*base/)
  assert.match(M.confirmText("resize-size", "dev", "8 vCPU / 16 GB"), /restarts/)
  assert.match(M.confirmText("resize-disk", "dev", "40"), /40 GB/)
  assert.match(M.confirmText("new-gpu", "g", "NVIDIA L4."), /billed/)
  for (const v of ["new", "rename", "restore-to", "idle", "resize-size", "resize-disk"]) assert.ok(M.progressText[v], v)
})

console.log(`model-test: ${n} groups passed`)
