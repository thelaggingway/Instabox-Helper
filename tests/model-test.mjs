// Tests Model.js (a QML ".pragma library" file) under Node: node tests/model-test.mjs
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import assert from "node:assert/strict"
import vm from "node:vm"

const src = readFileSync(fileURLToPath(new URL("../Model.js", import.meta.url)), "utf8").replace(/^\.pragma library\s*$/m, "")
const M = {}
vm.runInNewContext(src + "\n;Object.assign(M, { glyph, icons, validName, parseStatus, runningCount, stateLabel, stateTone, spec, bytes, ago, snapshotName, portsFor, defaultName, headline, tooltip, usageLine, confirmText, progressText })", { M, Date, JSON, Math, String, Number, Object, Array, isNaN })

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

console.log(`model-test: ${n} groups passed`)
