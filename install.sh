#!/usr/bin/env bash
# Install (or update) the bsadik.clipboard Omarchy shell plugin from this repo.
#
#   ./install.sh             copy plugin, add bar icon, bind SUPER+V
#   ./install.sh --uninstall remove plugin, bar icon and SUPER+V binding
#
# Safe to re-run: every step checks before changing anything.

set -euo pipefail

ID="bsadik.clipboard"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_DIR/$ID"
DEST="$HOME/.config/omarchy/plugins/$ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
BINDINGS="$HOME/.config/hypr/bindings.lua"
OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"

BIND_START="-- >>> $ID >>>"
BIND_END="-- <<< $ID <<<"

say() { printf '\033[1;34m::\033[0m %s\n' "$*"; }

edit_shell_json() {
  local filter="$1"
  jq --arg id "$ID" "$filter" "$SHELL_JSON" >"$SHELL_JSON.tmp"
  mv "$SHELL_JSON.tmp" "$SHELL_JSON"
}

remove_binding() {
  [[ -f $BINDINGS ]] || return 0
  sed -i "/^$BIND_START\$/,/^$BIND_END\$/d" "$BINDINGS"
}

reload_hyprland() {
  if command -v hyprctl >/dev/null && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    hyprctl reload >/dev/null
    local errors
    errors=$(hyprctl configerrors)
    [[ -z $errors || $errors == *"no errors"* ]] || echo "$errors" >&2
  fi
}

uninstall() {
  say "Removing $DEST"
  rm -rf "$DEST"
  if [[ -f $SHELL_JSON ]]; then
    say "Removing bar icon"
    edit_shell_json '
      (.bar.layout // {}) |= with_entries(.value |= map(select(.id != $id)))
      | (.plugins // []) |= map(select(.id != $id))'
  fi
  say "Restoring SUPER+V (universal paste)"
  remove_binding
  reload_hyprland
  say "Uninstalled. Log out and back in to restore the default SUPER+V binding."
}

install() {
  [[ -f $SRC/manifest.json ]] || { echo "missing $SRC/manifest.json" >&2; exit 1; }

  say "Copying plugin to $DEST"
  mkdir -p "$DEST"
  rsync -a --delete "$SRC/" "$DEST/"
  omarchy plugin validate "$DEST" >/dev/null

  [[ -f $SHELL_JSON ]] || cp "$OMARCHY_PATH/config/omarchy/shell.json" "$SHELL_JSON"

  # A plugin that is also a bar widget is enabled by its bar entry, so it must
  # not also sit in plugins[]. Place it right after the system tray.
  say "Adding bar icon next to the tray"
  edit_shell_json '
    (.plugins // []) |= map(select(.id != $id))
    | if ([.bar.layout[]?[]?.id] | index($id)) then .
      else .bar.layout.right = (
        (.bar.layout.right // []) as $right
        | ($right | map(.id) | index("omarchy.tray")) as $tray
        | if $tray == null then $right + [{id: $id}]
          else $right[:$tray + 1] + [{id: $id}] + $right[$tray + 1:] end)
      end'

  say "Binding SUPER+V"
  remove_binding
  cat >>"$BINDINGS" <<EOF
$BIND_START
-- Clipboard manager plugin (replaces the default "Universal paste" on SUPER+V).
hl.unbind("SUPER + V")
o.bind("SUPER + V", "Clipboard manager", "omarchy-shell shell toggle $ID")
$BIND_END
EOF
  reload_hyprland

  say "Done. Press SUPER+V or click the clipboard icon in the bar."
  say "If the bar icon doesn't appear, run: omarchy restart shell"
}

case "${1:-}" in
  --uninstall) uninstall ;;
  "") install ;;
  *) echo "usage: $0 [--uninstall]" >&2; exit 2 ;;
esac
