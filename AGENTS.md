# AGENTS.md: Instabox Helper

Guide for coding agents (and people) changing this plugin. Read [README.md](README.md) first for what it does from a user's point of view.

## What this is

An Omarchy shell **bar-widget plugin** (id `thelaggingway.instabox-helper`) that puts Instabox boxes, snapshots, base templates and the current billing period's spend in a bar panel, with a New box form. It runs inside the user's long-lived, unsandboxed `omarchy-shell` (Quickshell) process. It does no networking itself; it calls the signed-in `instabox` CLI through one helper script.

## Layout

| Path | Role |
|---|---|
| `manifest.json` | Omarchy plugin manifest: id, `kinds: ["bar-widget"]`, entry point, settings schema and defaults. The repo root **is** the plugin folder; `omarchy plugin add` clones it to `~/.config/omarchy/plugins/thelaggingway.instabox-helper`. |
| `Panel.qml` | Bar icon + `KeyboardPanel`. State, polling (`status`, `catalog`, `disk`), action dispatch, confirm dialog, inline name prompts, restore picker, New box form. Inline components at the bottom: `PlainText`, `StateDot`, `ActionButton`, `Chips` (ButtonGroup), `Picker` (Dropdown), `FieldLabel`, `RowCard`, `NamePrompt`, `BillingCard`, `NewBoxForm`, `MachineRow`, `SnapshotRow`, `TemplateRow`. |
| `Model.js` | `.pragma library` with pure helpers: parsing, labels, formatting, billing text, size/idle/delete options, template sorting, form → argv (`newBoxArgs`), default names, confirm texts, icon glyphs. No QML types, so it runs under Node for tests. |
| `bin/instabox-panel` | Python 3 (stdlib only, run with `python3 -I`). Subcommands: `status` (boxes, snapshots, ports, usage, `billing`, `specs`), `catalog` (templates), `disk <box>`, `action <verb> …`, `ssh <box>`. The only code that runs `instabox`. |
| `tests/` | `marketplace-scan.mjs` runs the marketplace's own security baseline over the repo (needs a clone of `omacom/omarchy-plugin-marketplace`; CI does this). `run.sh` runs the rest: `source-test.sh` (static safety checks), `helper-test.sh` (helper against a fake CLI), `model-test.mjs` (Model.js under Node). |
| `preview.png` | Marketplace and README image, taken with Demo data on (never real account data). |
| `.github/workflows/ci.yml` | Runs `tests/run.sh` on push and PR. |

## Run, reload, test

```bash
tests/run.sh                                   # always run before committing
omarchy restart shell                          # reload after changes (hot reload is unreliable for this plugin)
omarchy-shell thelaggingway.instabox-helper toggle         # open the panel (opens on the focused monitor)
journalctl --user -f -o cat | grep -i instabox # QML warnings and errors
bin/instabox-panel status | jq .               # what the panel sees, against the real account
omarchy plugin validate .                      # manifest schema check
```

To see the panel without clicking, open it over IPC and screenshot right away (`grim`); it closes when focus moves elsewhere. `omarchy-shell thelaggingway.instabox-helper newBox` opens it with the New box form. To check an expanded box, the Templates list or the billing breakdown, temporarily change the defaults of `expandedBox`, `templatesOpen` or `billingOpen` in `Panel.qml`, restart the shell, capture, and put the file back.

**Don't test actions against a real account** unless the user asks. `status` is read-only and safe; `action` and `ssh` change real boxes. Use `tests/helper-test.sh`, which puts a fake `instabox` on `PATH`.

## Conventions and invariants (tests enforce most of these)

1. **All text is plain.** Use the `PlainText` component, never a bare `Text {}`. API data (names, descriptions, errors) must not reach a rich-text sink. `source-test.sh` fails on a bare `Text {`.
2. **Argv only, never a shell.** QML starts processes with arrays (`Quickshell.execDetached([...])`, `Process { command: [...] }`); the helper uses `subprocess.run([...])` without `shell=True`. Never build a `sh -c` string that contains data.
3. **Validate names before the CLI runs.** The helper's `NAME_RE` (`^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`) and `Model.validName` must stay identical. A name starting with `-` would become a CLI flag.
4. **Whitelist verbs and options.** New actions go into `ONE_ARG` (one target) or `TWO_NAMES` (target + name) in the helper, or get their own branch in `action()` with strict checks (`check_int`, `check_idle`, `GPU_RE`). `new` parses only its known options (`build_new`); unknown or repeated options are refused. Unknown verbs exit without calling the CLI.
5. **Confirm destructive, disruptive or billable actions.** `root.request()` opens the `ConfirmDialog` for every verb in `root.confirmVerbs` (`rm`, `snapshot-rm`, `restore`, `restore-to`, `stop`, `restart`, `resize-size`, `resize-disk`, `snapshot-save-restart`, and `new-gpu` for GPU creates). Add new ones to that list and to `Model.confirmText`.
6. **Never create macOS boxes.** A macOS box leases a Mac for 24 hours minimum. The helper refuses `--template macos` (`BLOCKED_TEMPLATES`) and `catalog` marks any template with a `minimumLease` as `blocked`; the panel shows it without a create button. Keep both guards.
7. **Bound what comes back.** The helper caps list lengths and string lengths, and passes on only the fields the panel uses (never `metadata`). Port URLs must be `https://`.
8. **Icons go in the button text.** `BarIconButton` draws `text`, so the glyph has to be in it (`Model.icons.server + count`). Glyphs are Nerd Font code points built with `String.fromCodePoint` in `Model.icons`; keep literal private-use characters out of the source.
9. **The helper notifies; the panel refreshes.** `action` sends the success or failure notification (`omarchy-notification-send`, falling back to `notify-send`) and exits with the CLI's code. The panel only clears its pending state and refreshes on exit.
10. **Motion:** only the pulsing state dot and the shell's own panel animations. Follow Omarchy's motion rules (`Style.duration`, ease-out, under 300 ms) if you add any.
11. **No secrets, no state files.** Don't add caching of account data to disk, and don't read or write `~/.config/instabox/`.

## How to add an action (example: `max-run <box> <minutes>`)

1. Helper: add a builder to `ONE_ARG` or `TWO_NAMES`, or a branch in `action()` if an argument isn't a name (validate it with `check_int` or its own strict regex).
2. `Model.js`: add `progressText[verb]`, and `confirmText` if it needs confirming.
3. `Panel.qml`: add an `ActionButton` to the box's `Flow`, calling `root.request(verb, name)` or `root.openPrompt(kind, name)` (a prompt needs a `NamePrompt` with that `kind` in the row).
4. Tests: extend the expected argv in `helper-test.sh` and the `progressText` list in `model-test.mjs`.
5. README: add a row to the action table.

## CLI facts this depends on

Checked against `instabox` 0.8.277; confirm with `instabox <cmd> --help` before relying on new flags.

- `ls`, `snapshot ls`, `usage`, `port ls` accept `--json`; errors with `--json` print `{"error":{"code","message"}}` on stdout. Exit codes: 0 ok, 3 auth, 4 not found, 5 quota, 75 retryable.
- `ls` items: `id`, `name`, `state` (`running|suspended|stopped|…`), `desiredState`, `operationId` (non-null while busy), `vcpus`, `memMiB`, `spec.persistentDiskGiB`, `template.id`, `snapshot.id`, `autoSuspendAfterSeconds`, `createdAt`.
- `snapshot ls` items: `id`, `name`, `description`, `status` (`ready|pending|…`), `rootSizeBytes`, `dataSizeBytes`, `createdAt`.
- `usage.limits`: a limit of `0` means unlimited.
- `usage --json` also returns `cost` (this period: `costUSD`, `allowanceUSD`, `creditRemainingUSD`, `overageUSD`, `vcpuUSD`, `memUSD`, `storageUSD`, `gpuUSD`, `egressUSD`, `gpu[]` with `hourUSD`, `periodEnd`, `ratedUntil`), `org.tier`, and `limits.machineSpecs` (the plan's sizes). `workspace get <org>` has the same numbers plus spend cap; the panel doesn't need it.
- `templates --json` → `{templates: [{id, description, defaultSpec, creatable, gpuTypes?[{type, model, sizes[]}], minimumLease?}]}`. `gpu` has no description; the helper writes one.
- `create` flags used: `--template|--snapshot`, `--vcpus --mem-mib`, `--gpu TYPE`, `--auto-suspend 5m-30m|0`, `--delete-after 1h-24h`. `auto-suspend <box> <dur>|0`, `rename <box> <new>`, `snapshot save <box> --name N [--restart]` (a running GPU box is refused without `--restart`, which stops, saves and starts it again; the panel uses it only for running GPU boxes, after a confirm), `resize <box> --vcpus N --mem-mib M | --disk N [--restart]`, `restore <box> --snapshot S --yes`, `disk <box> --json` (running boxes only).
- `templates --json` also has `gpuMode` (`null` or `"metal"`, as on `gpu-metal`) and `gpuTypes[].default`/`maxPerMachine`; the panel doesn't use them yet. `create --snapshot S --gpu TYPE:COUNT` re-sizes a GPU snapshot's count; the form doesn't offer counts.
- `ls --json` doesn't document where a box's GPUs appear; `is_gpu()` checks `gpus`/`gpu` at the top level and in `spec`, then a `gpu*` template id.
- With `--json`, failures now also print one `instabox: error CODE: MESSAGE` line on stderr; `cli_json` reads the JSON error first, so this changes nothing.
- `rm`, `snapshot rm` and `restore` need `--yes` off a terminal. `ssh` needs a running box; the helper resumes, starts or wakes it first.
- `INSTABOX_API_KEY` replaces the stored sign-in when set. The helper sets `INSTABOX_NO_UPDATE_CHECK=1` for its own calls.

## The preview image

`preview.png` must never show a real account. Retake it like this:

1. `omarchy bar set thelaggingway.instabox-helper demoMode true --json` (back up `~/.config/omarchy/shell.json` first).
2. Optionally set the `expandedBox` default to `"web-app"` in `Panel.qml`, then `omarchy restart shell`.
3. Open the panel (`omarchy-shell thelaggingway.instabox-helper open`), screenshot the monitor with `grim -o <output>`, and crop exactly to the panel border (no bar, tray or desktop) with `magick … -crop … -bordercolor "#16161a" -border 40 -strip preview.png`.
4. Restore `Panel.qml` and `shell.json`, and `omarchy restart shell`.

Demo data lives in `demo_status`, `demo_catalog` and `demo_disk` in the helper; keep it plausible and obviously made up.

## Releasing

Bump `version` in `manifest.json`, run `tests/run.sh`, commit and push to `main`. Users update with `omarchy plugin update thelaggingway.instabox-helper`, then `omarchy restart shell`.

Once listed on the Omarchy marketplace, each release also needs a **Plugin verification** issue in `omacom/omarchy-plugin-marketplace` ("Verify and publish a newer upstream commit", with the plugin id, repo URL and full commit SHA); until a maintainer approves it the listing shows *Update unverified*. Keep the repo free of privilege escalation, service-manager calls, package-manager installs, download-and-run commands and files named `install*`/`setup*` (even in docs; see the marketplace's `SECURITY.md`), so its security baseline stays `passed`.
