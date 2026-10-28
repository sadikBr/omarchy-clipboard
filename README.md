# Omarchy Clipboard

A themed clipboard history for [Omarchy](https://omarchy.org), built as an Omarchy shell (Quickshell) plugin. It handles text and images, lets you pin entries, and adds a clipboard icon to the bar next to the system tray.

- **SUPER+V** opens it (replacing Omarchy's default "Universal paste" on that key)
- **Bar icon**: left-click opens it, right-click opens the Pinned tab
- Uses your current Omarchy theme (menu surface colors, accent, border, corner rounding), so it changes along with the theme

## Features

- Search across all entries as you type
- Tabs for **All / Text / Images / Pinned**, with counts
- Detects the type of each entry: image thumbnails, file lists, links (shown with their domain), hex/rgb colors (shown as swatches), and code snippets
- Preview pane showing the full text, or the image at full size with its dimensions
- Pinned entries are stored separately and stay after they drop out of history
- Quick paste of the first nine entries with Alt+1…9

## Keys

| Key | Action |
|---|---|
| Type | Search |
| ↑ / ↓, Ctrl+K / Ctrl+J | Move selection |
| PgUp / PgDn, Home / End | Jump |
| Enter | Paste into the focused window |
| Shift+Enter | Copy only |
| Alt+1…9 | Paste entry 1–9 |
| Ctrl+P | Pin / unpin |
| Del | Delete entry |
| Shift+Del | Clear history (pins are kept) |
| Tab / Shift+Tab | Next / previous tab |
| Esc | Clear search, then close |

Mouse: click pastes, right-click pins, middle-click deletes.

## Install

```bash
git clone <this repo> ~/Work/omarchy-clipboard-plugin
cd ~/Work/omarchy-clipboard-plugin
./install.sh
```

`install.sh` is safe to re-run. It:

1. copies `bsadik.clipboard/` to `~/.config/omarchy/plugins/bsadik.clipboard/` (the shell hot-reloads it)
2. adds the bar icon after `omarchy.tray` in `~/.config/omarchy/shell.json`
3. adds a marked SUPER+V block to `~/.config/hypr/bindings.lua` and reloads Hyprland

After editing anything in this repo, run `./install.sh` again to apply it. Omarchy rejects symlinked plugin folders, so the plugin is copied rather than linked.

To remove it: `./install.sh --uninstall`.

## How it works

Capture is handled by Omarchy's built-in `omarchy.clipboard` plugin, whose `wl-paste --watch` processes write `~/.local/state/omarchy/clipboard-history.json`. This plugin reads that file, so nothing is captured twice. Keep the built-in plugin enabled; it also stays available on SUPER+CTRL+V.

Pins are stored in `~/.local/state/omarchy/bsadik-clipboard-pins.json`. Pasting uses Omarchy's own `omarchy-clipboard-paste-text` and `omarchy-clipboard-paste-file` helpers.

| File | Purpose |
|---|---|
| `bsadik.clipboard/manifest.json` | Plugin manifest (overlay and bar widget) |
| `bsadik.clipboard/Clipboard.qml` | The overlay UI |
| `bsadik.clipboard/ClipboardBarWidget.qml` | Bar icon |
| `bsadik.clipboard/ClipModel.js` | Entry parsing, classification, filtering |

## Requirements

- Omarchy with the Quickshell-based `omarchy-shell` and Lua Hyprland config
- `JetBrainsMono Nerd Font` (Omarchy default) for the icons
- `jq` and `rsync` (for `install.sh`)

## Troubleshooting

- **Bar icon missing after an update that renames files:** run `omarchy restart shell`. The QML engine caches folder listings.
- **Logs:** `qs log --id "$(qs list --all | awk '/Instance/{print $2; exit}' | tr -d :)" | grep -i clipboard`
