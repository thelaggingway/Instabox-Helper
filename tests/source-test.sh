#!/usr/bin/env bash
# Static checks on the QML and helper sources.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }

# Every Text in the panel must be plain text, because box and snapshot names,
# descriptions and errors come from the API (see Omarchy's "Plugin UI Safety").
# Panel.qml routes all text through its PlainText component.
bare=$(grep -nE '^\s*Text\s*\{' "$ROOT/Panel.qml" || true)
[[ -z $bare ]] || fail "bare Text element (use PlainText):\n$bare"
grep -q 'component PlainText: Text {' "$ROOT/Panel.qml" || fail "PlainText component missing"
grep -A1 'component PlainText: Text {' "$ROOT/Panel.qml" | grep -q 'textFormat: Text.PlainText' || fail "PlainText is not plain"

# Processes are started with argv arrays, never a shell string with data in it.
if grep -nE '"(ba)?sh",\s*"-c"' "$ROOT/Panel.qml"; then fail "shell -c in Panel.qml"; fi
grep -q 'shell=True' "$ROOT/bin/instabox-panel" && fail "shell=True in helper"

# URLs opened from the panel must be https.
grep -q 'if (/\^https:' "$ROOT/Panel.qml" || fail "openUrl https guard missing"

# The manifest is valid JSON with the fields Omarchy needs.
python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))
assert m["id"] == "wyrdwerk.instabox"
assert m["kinds"] == ["bar-widget"] and m["entryPoints"]["barWidget"] == "Panel.qml"
for f in m["barWidget"]["schema"]:
    assert f["key"] in m["barWidget"]["defaults"], f["key"]
' "$ROOT/manifest.json" || fail "manifest"

[[ -x $ROOT/bin/instabox-panel ]] || fail "bin/instabox-panel is not executable"
python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$ROOT/bin/instabox-panel" || fail "helper syntax"

echo "source-test: ok"
