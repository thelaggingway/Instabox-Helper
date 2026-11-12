# Instabox Helper

An [Omarchy](https://omarchy.org/) bar plugin for [Instabox](https://instabox.sh) cloud boxes. It shows your boxes and snapshots in a panel on the bar, so day-to-day work doesn't need the dashboard: one-click SSH, pause and resume, snapshots, forks and new boxes.

It is a front end to the official `instabox` CLI and uses the CLI's own sign-in. The plugin stores no API key, token or password.

## What it does

**Bar icon.** A server icon that lights up while any box is running, with the count beside it. Left-click opens the panel and right-click refreshes. The tooltip says how many boxes are running.

**Boxes.** Every box shows its state, size and two buttons:

| Button | What happens |
|---|---|
| Terminal (SSH) | Opens your default terminal and SSHs in. A paused box is resumed first and a stopped one started, so one click is enough. |
| Play / pause | Pause (`instabox suspend`) a running box, or resume/start one that isn't running. |

Click a box to see more: the snapshot or template it came from, its idle-pause time, when it was made, and links to its published ports. The extra actions there are:

| Action | CLI | Asks first? |
|---|---|---|
| Snapshot | `snapshot save <box> --name <name>` | Asks for a name (suggests `<box>-YYYYMMDD-HHMM`) |
| Fork | `fork <box> --name <name>` | Asks for a name (suggests `<box>-fork`) |
| Stop | `stop <box>` | Yes |
| Restart | `restart <box>` | Yes |
| Restore | `restore <box> --yes` (back to the snapshot it was made from) | Yes |
| Delete | `rm <box> --yes` | Yes |

**Snapshots.** The newest snapshots are listed (8 by default, then "Show all"). The **+** on a row starts a new box from it (`create --name <name> --snapshot <snapshot>`). Click a row to read its description and size, or to delete it (`snapshot rm`, asks first).

**Footer.** Your usage against your plan's limits, when the list was last refreshed, and a **Dashboard** button for everything the panel doesn't cover.

Every action sends a desktop notification when it finishes, saying whether it worked and, if not, what the CLI reported. While an action runs, the box's dot pulses and its buttons are disabled.

## Requirements

- Omarchy with the Quickshell-based shell (the one with `omarchy plugin` and `~/.config/omarchy/shell.json`).
- The [`instabox` CLI](https://instabox.sh/docs), signed in. Check with `instabox whoami`.
- `python3`, which Omarchy ships.

## Install

```bash
omarchy plugin add https://github.com/WyrdWerk/Instabox-Helper.git --enable
```

`omarchy plugin add` shows the code warning, clones the repo into `~/.config/omarchy/plugins/wyrdwerk.instabox`, validates it and asks which bar section to use (the default is `right`). Then restart the shell once so the bar loads the new widget:

```bash
omarchy restart shell
```

To place it next to a particular widget:

```bash
omarchy bar put wyrdwerk.instabox --after robzolkos.github
```

### Sign in to Instabox

If the CLI isn't installed or signed in yet:

```bash
npx -y instabox@latest      # installs the CLI to ~/.local/bin and signs you in
instabox whoami             # check
```

If the sign-in expires, the panel shows **Not signed in** and a **Sign in to Instabox** button that runs `instabox login` in a terminal.

**Optional: an API key instead of your account sign-in.** The CLI uses `INSTABOX_API_KEY` from the environment when it is set, and so does this plugin. To limit what the panel can do, create a key with only the scopes you want (`instabox keys create --name omarchy-panel --scope machines:read --scope machines:write --scope images:read`) and put it in the shell's environment, for example in `~/.config/environment.d/instabox.conf`. That file is plain text, so keep it out of dotfile repos. Without the `machines:delete` and `images:delete` scopes, the Delete buttons fail with a permission error instead of deleting.

## Settings

Open the plugin's settings from the Omarchy settings panel, or set them in `~/.config/omarchy/shell.json` on the widget's entry:

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | `120` | How often to check while the panel is closed. While it is open, or an action is running, it checks every 10 seconds. |
| `maxSnapshots` | `8` | Snapshots listed before "Show all". |
| `showCount` | `true` | Show the number of running boxes next to the icon. |

```bash
omarchy bar set wyrdwerk.instabox refreshIntervalSec 300
```

## Keyboard and scripting

The panel listens on the IPC target `wyrdwerk.instabox`:

```bash
omarchy-shell wyrdwerk.instabox toggle     # also open, close
omarchy-shell wyrdwerk.instabox refresh
```

To open it with a key, add a line to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + I", "Instabox", "omarchy-shell wyrdwerk.instabox toggle")
```

Inside the panel, Esc closes it, Esc cancels a name prompt, Enter accepts one, and the arrow keys and Enter drive the confirm dialog.

The helper also works on its own:

```bash
~/.config/omarchy/plugins/wyrdwerk.instabox/bin/instabox-panel status | jq .
~/.config/omarchy/plugins/wyrdwerk.instabox/bin/instabox-panel ssh <box>
~/.config/omarchy/plugins/wyrdwerk.instabox/bin/instabox-panel action snapshot-save <box> <name>
```

## How it works

```
Panel.qml ──argv──▶ bin/instabox-panel ──argv──▶ instabox CLI ──HTTPS──▶ api.instabox.sh
   ▲                     │
   └──── one JSON ◀──────┘   (status: ls + snapshot ls + usage + port ls, in parallel)
```

- **`Panel.qml`** draws the bar icon and the panel, polls `instabox-panel status`, runs actions as child processes, and opens SSH with `omarchy-launch-tui`.
- **`bin/instabox-panel`** (Python, standard library only) is the only thing that talks to the CLI. `status` runs four CLI calls in parallel and prints one trimmed JSON document. `action` runs one whitelisted command and sends the notification. `ssh` wakes the box and hands over to `instabox ssh`.
- **`Model.js`** holds the pure formatting and labelling logic, tested under Node.

### Security and privacy

- **No secrets.** The plugin reads and stores no credentials; the CLI handles sign-in (`~/.config/instabox/credentials.json`, or `INSTABOX_API_KEY`).
- **No shell strings.** Every process is started with a fixed argument list. Box, snapshot and new names must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$` before anything runs, so a name can't become a flag or a command.
- **Only listed actions run.** The helper accepts a fixed set of verbs; anything else exits without calling the CLI.
- **Untrusted text is shown as plain text.** Names, descriptions and errors from the API are never rendered as rich text, and only `https://` port links are shown or opened.
- **Network use:** only what the `instabox` CLI does, which is `api.instabox.sh`. That's 4 requests every 2 minutes in the background (configurable), every 10 seconds while the panel is open, plus the actions you click. Nothing else is contacted.
- **Data kept:** none. No cache or state file is written.

## Troubleshooting

| Symptom | Fix |
|---|---|
| No icon on the bar after installing | `omarchy restart shell`. Check that it is in the layout with `grep wyrdwerk.instabox ~/.config/omarchy/shell.json`, or add it with `omarchy bar put wyrdwerk.instabox`. |
| Edits to the plugin's files don't show | Hot reload doesn't always pick up changes to this plugin; run `omarchy restart shell`. |
| "Not signed in" | Click **Sign in to Instabox**, or run `instabox login` (or `npx -y instabox@latest`). |
| "Can't reach Instabox" | The error text comes from the CLI. Try `instabox ls` in a terminal. |
| The SSH window closes at once | It stays open with a message when `ssh` fails. If it vanishes, run `~/.config/omarchy/plugins/wyrdwerk.instabox/bin/instabox-panel ssh <box>` in a terminal to see why. |
| An action failed | The notification shows the CLI's last lines. Run the same `instabox` command in a terminal for the full output. |
| Shell log | `journalctl --user -t omarchy-shell -f`, or `journalctl --user -f \| grep -i instabox`. |

## Update and uninstall

```bash
omarchy plugin update wyrdwerk.instabox && omarchy restart shell
omarchy plugin remove wyrdwerk.instabox
```

## Not included (yet)

These remain on the [dashboard](https://dashboard.instabox.sh/dashboard/machines) or the CLI: new boxes from a template, restoring to a snapshot other than the box's own, resizing, metrics and logs, secrets, webhooks, workspaces, and `snapshot import` from a Docker image.

## Development

```bash
tests/run.sh        # static checks, the helper against a fake CLI, and Model.js under Node
```

The tests never touch a real account: `helper-test.sh` puts a fake `instabox` and a fake notifier on `PATH`. See [AGENTS.md](AGENTS.md) for the layout, conventions and how to add an action.

## License

MIT, see [LICENSE](LICENSE). Instabox is a separate service; this plugin is not affiliated with it.
