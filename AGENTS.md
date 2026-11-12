# AGENTS.md: Instabox Helper

Guide for coding agents (and people) changing this plugin. Read [README.md](README.md) first for what it does from a user's point of view.

## What this is

An Omarchy shell **bar-widget plugin** (id `wyrdwerk.instabox`) that puts Instabox boxes and snapshots in a bar panel. It runs inside the user's long-lived, unsandboxed `omarchy-shell` (Quickshell) process. It does no networking itself; it calls the signed-in `instabox` CLI through one helper script.

## Layout

| Path | Role |
|---|---|
| `manifest.json` | Omarchy plugin manifest: id, `kinds: ["bar-widget"]`, entry point, settings schema and defaults. The repo root **is** the plugin folder; `omarchy plugin add` clones it to `~/.config/omarchy/plugins/wyrdwerk.instabox`. |
| `Panel.qml` | Bar icon + `KeyboardPanel`. State, polling, action dispatch, confirm dialog, inline name prompts. Inline components at the bottom: `PlainText`, `StateDot`, `ActionButton`, `NamePrompt`, `MachineRow`, `SnapshotRow`. |
| `Model.js` | `.pragma library` with pure helpers: parsing, labels, formatting, default names, confirm texts, icon glyphs. No QML types, so it runs under Node for tests. |
| `bin/instabox-panel` | Python 3 (stdlib only, run with `python3 -I`). Subcommands: `status`, `action <verb> …`, `ssh <box>`. The only code that runs `instabox`. |
| `tests/` | `run.sh` runs all of them: `source-test.sh` (static safety checks), `helper-test.sh` (helper against a fake CLI), `model-test.mjs` (Model.js under Node). |
| `.github/workflows/ci.yml` | Runs `tests/run.sh` on push and PR. |

## Run, reload, test

```bash
tests/run.sh                                   # always run before committing
omarchy restart shell                          # reload after changes (hot reload is unreliable for this plugin)
omarchy-shell wyrdwerk.instabox toggle         # open the panel (opens on the focused monitor)
journalctl --user -f -o cat | grep -i instabox # QML warnings and errors
bin/instabox-panel status | jq .               # what the panel sees, against the real account
omarchy plugin validate .                      # manifest schema check
```

To see the panel without clicking, open it over IPC and screenshot right away (`grim`); it closes when focus moves elsewhere.

**Don't test actions against a real account** unless the user asks. `status` is read-only and safe; `action` and `ssh` change real boxes. Use `tests/helper-test.sh`, which puts a fake `instabox` on `PATH`.

## Conventions and invariants (tests enforce most of these)

1. **All text is plain.** Use the `PlainText` component, never a bare `Text {}`. API data (names, descriptions, errors) must not reach a rich-text sink. `source-test.sh` fails on a bare `Text {`.
2. **Argv only, never a shell.** QML starts processes with arrays (`Quickshell.execDetached([...])`, `Process { command: [...] }`); the helper uses `subprocess.run([...])` without `shell=True`. Never build a `sh -c` string that contains data.
3. **Validate names before the CLI runs.** The helper's `NAME_RE` (`^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`) and `Model.validName` must stay identical. A name starting with `-` would become a CLI flag.
4. **Whitelist verbs.** New actions go into `ACTIONS` (one target) or `TWO_ARG` (target + new name) in the helper. Unknown verbs exit without calling the CLI.
5. **Confirm destructive or disruptive actions.** Verbs routed through `root.request()` that destroy data or kill processes (`rm`, `snapshot-rm`, `restore`, `stop`, `restart`) open the `ConfirmDialog` first. Add new ones to that list and to `Model.confirmText`.
6. **Bound what comes back.** The helper caps list lengths and string lengths, and passes on only the fields the panel uses (never `metadata`). Port URLs must be `https://`.
7. **Icons go in the button text.** `BarIconButton` draws `text`, so the glyph has to be in it (`Model.icons.server + count`). Glyphs are Nerd Font code points built with `String.fromCodePoint` in `Model.icons`; keep literal private-use characters out of the source.
8. **The helper notifies; the panel refreshes.** `action` sends the success or failure notification (`omarchy-notification-send`, falling back to `notify-send`) and exits with the CLI's code. The panel only clears its pending state and refreshes on exit.
9. **Motion:** only the pulsing state dot and the shell's own panel animations. Follow Omarchy's motion rules (`Style.duration`, ease-out, under 300 ms) if you add any.
10. **No secrets, no state files.** Don't add caching of account data to disk, and don't read or write `~/.config/instabox/`.

## How to add an action (example: `resize --disk N`)

1. Helper: add a builder to `ACTIONS` or `TWO_ARG`, or a new table if the argument isn't a name (validate it with its own strict regex or an int range).
2. `Model.js`: add `progressText[verb]`, and `confirmText` if it needs confirming.
3. `Panel.qml`: add an `ActionButton` to the box's `Flow`, calling `root.request(verb, name)` or `root.openPrompt(kind, name)` (a prompt needs a `NamePrompt` with that `kind` in the row).
4. Tests: extend the expected argv in `helper-test.sh` and the `progressText` list in `model-test.mjs`.
5. README: add a row to the action table.

## CLI facts this depends on

Checked against `instabox` 0.8.x; confirm with `instabox <cmd> --help` before relying on new flags.

- `ls`, `snapshot ls`, `usage`, `port ls` accept `--json`; errors with `--json` print `{"error":{"code","message"}}` on stdout. Exit codes: 0 ok, 3 auth, 4 not found, 5 quota, 75 retryable.
- `ls` items: `id`, `name`, `state` (`running|suspended|stopped|…`), `desiredState`, `operationId` (non-null while busy), `vcpus`, `memMiB`, `spec.persistentDiskGiB`, `template.id`, `snapshot.id`, `autoSuspendAfterSeconds`, `createdAt`.
- `snapshot ls` items: `id`, `name`, `description`, `status` (`ready|pending|…`), `rootSizeBytes`, `dataSizeBytes`, `createdAt`.
- `usage.limits`: a limit of `0` means unlimited.
- `rm`, `snapshot rm` and `restore` need `--yes` off a terminal. `ssh` needs a running box; the helper resumes, starts or wakes it first.
- `INSTABOX_API_KEY` replaces the stored sign-in when set. The helper sets `INSTABOX_NO_UPDATE_CHECK=1` for its own calls.

## Releasing

Bump `version` in `manifest.json`, run `tests/run.sh`, commit and push to `main`. Users update with `omarchy plugin update wyrdwerk.instabox`, then `omarchy restart shell`.
