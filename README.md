# Omarchy Tunnel

A native Omarchy Quattro bar plugin for importing and managing WireGuard connections through NetworkManager.

Omarchy Tunnel is intentionally small: it does **not** install a privileged daemon, add sudoers rules, or call `wg-quick` as root. It delegates connection storage and activation to NetworkManager, which is already the network stack used by Omarchy.

## Features

- Native Omarchy bar widget and keyboard-friendly popup panel
- Native in-panel browser for local WireGuard `.conf` / `.wg` files — no GTK/native file dialog and no extra picker dependency
- Connect and disconnect profiles without opening a terminal
- Multiple WireGuard profiles with active-state indication
- Remove inactive profiles with a two-step confirmation
- Automatic refresh plus manual refresh with middle-click or `R`
- Secure-by-default import hardening: autoconnect is disabled and the imported profile is restricted to the current user
- No passwordless sudo and no custom privileged helper

## Security model

Omarchy plugins run unsandboxed with the permissions of your user account, so you should review any plugin before enabling it. Omarchy Tunnel keeps its privileged surface deliberately narrow:

1. **No `sudoers` changes.** The plugin never grants passwordless root commands.
2. **No `wg-quick`.** VPN profiles are imported with NetworkManager (`nmcli connection import type wireguard`). NetworkManager's WireGuard importer does not execute wg-quick `PreUp`, `PostUp`, `PreDown`, or `PostDown` hooks.
3. **Hooks are rejected anyway.** Before import, an unprivileged `awk` process checks the selected file and rejects those four command hooks. The validator never prints the file contents, so the WireGuard private key is not copied into QML state or logs.
4. **No shell interpolation.** Paths, UUIDs, and actions are passed as argv arrays to `Process`; user-controlled values are never concatenated into `bash -c` or another shell command.
5. **UUID-only mutations.** Connect, disconnect, harden, and delete operations address NetworkManager profiles by validated UUID instead of connection name.
6. **Import hardening.** After import, the plugin sets `connection.autoconnect=no` and, when `$USER` is available, `connection.permissions=user:$USER`. If this hardening step fails, the plugin attempts to delete the newly imported profile instead of leaving it behind.
7. **Normal NetworkManager authorization.** If NetworkManager requires authorization, the regular Polkit flow is used. Omarchy Tunnel does not bypass it.
8. **No in-process native file dialog.** Import browsing stays inside the Omarchy panel with Qt's read-only `FolderListModel`. This keeps GTK/GVFS file chooser code out of the long-running Omarchy shell process and avoids a picker failure taking down the shell.

Because NetworkManager's WireGuard import semantics differ from `wg-quick`, configs that depend on command hooks are deliberately unsupported.

## Requirements

- Omarchy Quattro / Omarchy Shell plugin system
- NetworkManager with `nmcli` (standard on Omarchy)
- `awk` (part of the normal Arch/Omarchy base environment)
- Qt's `Qt.labs.folderlistmodel` module (provided by the Qt declarative stack used by Omarchy Shell)

No AUR package or extra background service is required.

## Install

```sh
omarchy plugin add https://github.com/ecylmz/omarchy-tunnel.git --enable
```

The plugin ID is:

```text
io.github.ecylmz.omarchy-tunnel
```

If you want to inspect it before enabling:

```sh
omarchy plugin add https://github.com/ecylmz/omarchy-tunnel.git
omarchy plugin validate ~/.config/omarchy/plugins/io.github.ecylmz.omarchy-tunnel
```

## Usage

- **Left-click** the lock icon to open/close the panel.
- **Middle-click** the bar icon to refresh.
- Click a profile or its switch to connect/disconnect.
- Click **Import configuration** to open the in-panel WireGuard file browser, then select a `.conf` or `.wg` file.
- Click the remove button twice to delete an inactive profile.

Keyboard controls on the main panel:

| Key | Action |
| --- | --- |
| `↑` / `↓` | Move through profiles and the import action |
| `Enter` | Toggle the selected profile / open import |
| `I` | Open import browser |
| `R` | Refresh |
| `D` | Arm/confirm removal for the selected inactive profile |
| `Tab` / `Shift+Tab` | Switch to the neighbouring Omarchy panel |
| `Esc` | Close |

Keyboard controls in the import browser:

| Key | Action |
| --- | --- |
| `↑` / `↓` | Select a folder or WireGuard file |
| `Enter` / `→` | Open folder or import selected file |
| `←` / `H` | Parent folder |
| `Esc` / `Q` | Return to the main panel |

The import browser starts in your home directory, lists directories plus readable `.conf` / `.wg` files, hides dotfiles, and never reads configuration contents into the UI.

## Validate during development

The official Omarchy development guide recommends validating both the manifest and the QML files. Use the repository lint harness rather than invoking `qmllint` with the shell directory directly:

```sh
PLUGIN_DIR="$HOME/.config/omarchy/plugins/io.github.ecylmz.omarchy-tunnel"

omarchy plugin validate "$PLUGIN_DIR"
bash "$PLUGIN_DIR/tests/lint.sh"
```

Why the helper? Omarchy exposes its shell tree under the runtime `qs.*` QML namespace. A plain `qmllint -I "$OMARCHY_PATH/shell" ...` does not create that namespace on every Quattro installation and can therefore produce cascading false diagnostics such as `Failed to import qs.Ui`, unresolved `BarWidget`/`Panel`, and inheritance-cycle warnings. The lint helper creates a temporary `qs -> <Omarchy>/shell` import root, adds `/usr/lib/qt6/qml`, and works with the packaged Omarchy 4 path (`/usr/share/omarchy`) as well as development checkouts.

`qmllint` is normally installed with `qt6-declarative` but may not be on `PATH`. The helper also checks `/usr/lib/qt6/bin/qmllint`. If it is missing:

```sh
omarchy pkg add qt6-declarative
```

The helper suppresses only two known tooling-only warning classes: nested `Style.*`/`Color.*` `missing-property` diagnostics and Quickshell `Process.exited`'s unresolved `QProcess::ExitStatus`. Other warnings, especially `[unqualified]`, fail the lint run.

Then exercise the panel lifecycle:

```sh
omarchy-shell shell summon io.github.ecylmz.omarchy-tunnel '{}'
omarchy-shell shell hide io.github.ecylmz.omarchy-tunnel
```

Before a release, test click, keyboard navigation, folder navigation/import, connect/disconnect, removal, disable/re-enable, shell restart, and plugin removal.

## Remove

```sh
omarchy plugin remove io.github.ecylmz.omarchy-tunnel
```

Removing the plugin does **not** delete NetworkManager WireGuard profiles that you imported. This is intentional: removing UI code should not silently delete network credentials or configuration. Remove profiles from the panel before uninstalling, or use `nmcli connection delete uuid <UUID>` afterward.

## Development references

The implementation follows the Omarchy Quattro plugin contract: a namespaced third-party `bar-widget` manifest at the repository root, `BarWidget.qml` as the entry point, and a nested `Panel.qml` using the shell's standard panel lifecycle.

- Omarchy plugin development guide: https://plugins.omarchy.org/develop.html
- Omarchy shell plugin reference: https://github.com/basecamp/omarchy/blob/quattro/shell/README.md
- NetworkManager WireGuard import background: https://blogs.gnome.org/thaller/2019/03/15/wireguard-in-networkmanager/

## License

MIT
