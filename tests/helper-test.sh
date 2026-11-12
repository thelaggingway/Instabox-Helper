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
  "usage --json") echo '{"machines":2,"snapshots":2,"storedBytes":1000,"limits":{"maxMachines":500,"maxSnapshots":0}}' ;;
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

# --- ssh wakes a paused box, then connects ---
: > "$LOG"
"$HELPER" ssh dev < /dev/null > /dev/null
[[ $(cat "$LOG") == $'get dev --json\nresume dev\nssh dev' ]] || { cat "$LOG"; fail "ssh wake order"; }
ok

echo "helper-test: $pass groups passed"
