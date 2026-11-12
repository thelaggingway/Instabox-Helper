#!/usr/bin/env bash
# Tests bin/instabox-panel against a fake `instabox` CLI and a fake notifier.
# Needs only bash and python3; touches no real account.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/bin/instabox-panel"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
LOG="$T/calls.log"
NOTES="$T/notes.log"
export FAKE_LOG="$LOG" FAKE_NOTES="$NOTES" FAKE_MODE=ok

cat > "$T/bin/instabox" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
if [[ $FAKE_MODE == auth ]]; then
  echo '{"error":{"code":"unauthenticated","message":"not signed in"}}'; exit 3
fi
case "$*" in
  "ls --json") cat <<'J'
[{"id":"m_1","name":"dev","state":"running","desiredState":"running","operationId":null,
  "spec":{"vcpus":4,"memMiB":8192,"persistentDiskGiB":20},"vcpus":4,"memMiB":8192,
  "template":{"id":"agent-browser"},"snapshot":{"id":"sn_1"},"autoSuspendAfterSeconds":1800,
  "createdAt":"2026-11-01T00:00:00Z","metadata":{"secret":"must-not-leak"}},
 {"id":"m_2","name":"<b>evil</b>","state":"suspended","desiredState":"suspended","operationId":"op_1",
  "spec":{},"template":null,"snapshot":null}]
J
  ;;
  "snapshot ls --json") cat <<'J'
[{"id":"sn_1","name":"old","status":"ready","rootSizeBytes":1,"dataSizeBytes":2,"createdAt":"2026-10-01T00:00:00Z"},
 {"id":"sn_2","name":"new","status":"pending","rootSizeBytes":0,"dataSizeBytes":0,"createdAt":"2026-11-01T00:00:00Z"}]
J
  ;;
  "usage --json") cat <<'J'
{"machines":2,"snapshots":2,"storedBytes":1000,
 "limits":{"maxMachines":500,"maxSnapshots":0,"machineSpecs":[{"vcpus":4,"memMiB":8192,"persistentDiskGiB":20},{"vcpus":2,"memMiB":4096}]},
 "org":{"tier":"pro"},
 "cost":{"periodEnd":"2026-12-01T00:00:00Z","costUSD":1.775,"allowanceUSD":20,"creditRemainingUSD":18.225,"overageUSD":0,
         "vcpuUSD":0.5,"vcpuHours":141.5,"memUSD":0.6,"storageUSD":0.1,"gpuUSD":0.4,
         "gpu":[{"type":"l4","model":"NVIDIA L4","gpuHours":0.5,"hourUSD":0.8}]}}
J
  ;;
  "templates --json") cat <<'J'
{"templates":[{"id":"agent-browser","description":"default","defaultSpec":{"vcpus":4,"memMiB":8192},"creatable":true},
 {"id":"gpu","defaultSpec":{"vcpus":4},"gpuTypes":[{"type":"l4","model":"NVIDIA L4","memGiB":24,"sizes":[{"vcpus":11,"memMiB":36864}]},{"type":"$(id)"}],"creatable":true},
 {"id":"macos","defaultSpec":{"vcpus":12},"minimumLease":{"hours":24},"creatable":true},
 {"id":"old","creatable":false},
 {"id":"-x","creatable":true}]}
J
  ;;
  "disk dev --json") echo '{"filesystems":[{"mount":"/data","sizeBytes":100,"usedBytes":85,"usedPct":85,"level":"high"}]}' ;;
  "port ls --json") echo '{"ports":[{"machineId":"m_1","port":3000,"url":"https://3000-x.instabox.tech","access":"public"},{"machineId":"m_1","port":1,"url":"javascript:alert(1)"}]}' ;;
  "get dev --json") echo '{"name":"dev","state":"suspended"}' ;;
  rm\ broken*) echo "boom: no such box" >&2; exit 4 ;;
  *) exit 0 ;;
esac
EOF
cat > "$T/bin/omarchy-notification-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_NOTES"
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); }

# --- status ---
out=$("$HELPER" status)
python3 -I - "$out" <<'EOF' || fail "status shape"
import json, sys
d = json.loads(sys.argv[1])
assert d["ok"] is True and d["error"] == ""
m = {x["name"]: x for x in d["machines"]}
assert m["dev"]["vcpus"] == 4 and m["dev"]["memMiB"] == 8192 and m["dev"]["snapshotId"] == "sn_1"
assert m["<b>evil</b>"]["busy"] is True and m["<b>evil</b>"]["template"] == ""
assert "metadata" not in m["dev"], "metadata must not be passed through"
assert [s["name"] for s in d["snapshots"]] == ["new", "old"], "snapshots newest first"
assert d["snapshots"][1]["sizeBytes"] == 3
assert [p["port"] for p in d["ports"]] == [3000], "non-https port URLs are dropped"
assert d["usage"]["maxMachines"] == 500
b = d["billing"]
assert b["tier"] == "pro" and b["costUSD"] == 1.775 and b["allowanceUSD"] == 20 and b["creditRemainingUSD"] == 18.225
assert b["gpuPrices"] == {"l4": 0.8}
assert [p["label"] for p in b["parts"]] == ["vCPU", "Memory", "Storage", "GPU", "Egress"]
assert d["specs"] == [{"vcpus": 4, "memMiB": 8192, "diskGiB": 20}, {"vcpus": 2, "memMiB": 4096, "diskGiB": 0}]
EOF
ok

out=$(FAKE_MODE=auth "$HELPER" status)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] is False and d["authError"] is True and "not signed in" in d["error"]' "$out" \
  || fail "auth error reported"
ok

# --- actions build the right argv ---
: > "$LOG"
"$HELPER" action resume dev
"$HELPER" action rm dev
"$HELPER" action snapshot-rm old
"$HELPER" action restore dev
"$HELPER" action snapshot-save dev dev-20261112
"$HELPER" action fork dev dev-fork
"$HELPER" action create old fresh-box
expected=$'resume dev\nrm dev --yes\nsnapshot rm old --yes\nrestore dev --yes\nsnapshot save dev --name dev-20261112\nfork dev --name dev-fork\ncreate --name fresh-box --snapshot old'
[[ $(cat "$LOG") == "$expected" ]] || { diff <(echo "$expected") "$LOG"; fail "action argv"; }
ok
[[ $(wc -l < "$NOTES") -eq 7 ]] || fail "one notification per action"
grep -q "fresh-box created from old" "$NOTES" || fail "success notification text"
ok

# --- failures notify urgently and keep the exit code ---
: > "$NOTES"
set +e; "$HELPER" action rm broken >/dev/null 2>&1; code=$?; set -e
[[ $code -eq 4 ]] || fail "exit code passed through (got $code)"
grep -q -- "-u critical" "$NOTES" && grep -q "boom" "$NOTES" || fail "failure notification"
ok

# --- unsafe input is refused before the CLI runs ---
: > "$LOG"
for bad in 'a;b' '-rf' '$(id)' '' 'x y' "$(printf 'a%.0s' {1..70})"; do
  if "$HELPER" action rm "$bad" >/dev/null 2>&1; then fail "accepted bad name: $bad"; fi
done
if "$HELPER" action snapshot-save dev 'bad name' >/dev/null 2>&1; then fail "accepted bad new name"; fi
if "$HELPER" action ssh-everything dev >/dev/null 2>&1; then fail "accepted unknown verb"; fi
if "$HELPER" action rm >/dev/null 2>&1; then fail "accepted missing target"; fi
[[ ! -s $LOG ]] || fail "CLI ran for refused input: $(cat "$LOG")"
ok

# --- catalog: creatable, safe ids only; macOS marked blocked; bad GPU types dropped ---
out=$("$HELPER" catalog)
python3 -I - "$out" <<'EOF' || fail "catalog"
import json, sys
d = json.loads(sys.argv[1])
t = {x["id"]: x for x in d["templates"]}
assert sorted(t) == ["agent-browser", "gpu", "macos"], sorted(t)
assert t["macos"]["blocked"] is True and t["agent-browser"]["blocked"] is False
assert [g["type"] for g in t["gpu"]["gpuTypes"]] == ["l4"]
assert t["gpu"]["gpuTypes"][0]["spec"] == {"vcpus": 11, "memMiB": 36864, "diskGiB": 0}
EOF
ok

# --- disk ---
out=$("$HELPER" disk dev)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); f=d["filesystems"][0]; assert d["ok"] and f["mount"]=="/data" and f["usedPct"]==85' "$out" || fail "disk"
if "$HELPER" disk '-x' >/dev/null 2>&1; then fail "disk accepted bad name"; fi
ok

# --- v0.2 actions ---
: > "$LOG"
"$HELPER" action rename dev dev2
"$HELPER" action restore-to dev old
"$HELPER" action idle dev 10
"$HELPER" action idle dev 0
"$HELPER" action resize-size dev 8 16384
"$HELPER" action resize-disk dev 40
"$HELPER" action new fresh --template agent-browser --size 2/4096 --idle 15 --delete-after 4
"$HELPER" action new fromsnap --snapshot old
"$HELPER" action new gbox --template gpu --gpu l4 --idle 0
expected=$'rename dev dev2\nrestore dev --snapshot old --yes\nauto-suspend dev 10m\nauto-suspend dev 0\nresize dev --vcpus 8 --mem-mib 16384 --restart\nresize dev --disk 40 --restart\ncreate --name fresh --template agent-browser --vcpus 2 --mem-mib 4096 --auto-suspend 15m --delete-after 4h\ncreate --name fromsnap --snapshot old\ncreate --name gbox --template gpu --gpu l4 --auto-suspend 0'
[[ $(cat "$LOG") == "$expected" ]] || { diff <(echo "$expected") "$LOG"; fail "v0.2 action argv"; }
ok

# --- v0.2 refusals: nothing reaches the CLI ---
: > "$LOG"
refuse() { if "$HELPER" action "$@" >/dev/null 2>&1; then fail "accepted: $*"; fi; }
refuse idle dev 3
refuse idle dev 31
refuse idle dev 10m
refuse resize-size dev 8
refuse resize-size dev x 16384
refuse resize-disk dev 0
refuse resize-disk dev 2000
refuse rename dev 'bad name'
refuse new
refuse new box
refuse new box --template agent-browser --snapshot old
refuse new box --template macos
refuse new box --template agent-browser --size 4x8192
refuse new box --template agent-browser --idle 2
refuse new box --template agent-browser --delete-after 48
refuse new box --template agent-browser --gpu 'l4;id'
refuse new box --template agent-browser --idle
refuse new box --template agent-browser --idle 5 --idle 10
refuse new box --template agent-browser --setup-file /etc/passwd
refuse new -box --template agent-browser
[[ ! -s $LOG ]] || fail "CLI ran for refused input: $(cat "$LOG")"
ok

# --- demo data: valid shapes, and the CLI is never called ---
: > "$LOG"
out=$("$HELPER" status --demo)
python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ok"] and d["demo"] and len(d["machines"])==3 and d["billing"]["costUSD"]>0 and d["specs"]' "$out" || fail "demo status"
"$HELPER" catalog --demo | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert any(t["blocked"] for t in d["templates"]) and any(t["gpuTypes"] for t in d["templates"])' || fail "demo catalog"
"$HELPER" disk web-app --demo | python3 -I -c 'import json,sys; assert json.load(sys.stdin)["filesystems"]' || fail "demo disk"
[[ ! -s $LOG ]] || fail "demo mode called the CLI: $(cat "$LOG")"
ok

# --- ssh wakes a paused box, then connects ---
: > "$LOG"
"$HELPER" ssh dev < /dev/null > /dev/null
[[ $(cat "$LOG") == $'get dev --json\nresume dev\nssh dev' ]] || { cat "$LOG"; fail "ssh wake order"; }
ok

echo "helper-test: $pass groups passed"
