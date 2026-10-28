import QtQuick
import qs.Ui
import "ClipModel.js" as ClipModel

// Bar icon for the clipboard overlay: left click opens it, right click opens
// straight to the Pinned tab.
BarWidget {
  id: root
  moduleName: "bsadik.clipboard"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ClipModel.icons.clipboard
    fontFamily: "JetBrainsMono Nerd Font"
    tooltipText: "Clipboard (Super+V)"
    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.bar.run("omarchy-shell shell toggle bsadik.clipboard '{\"tab\":\"pinned\"}'")
      else root.bar.run("omarchy-shell shell toggle bsadik.clipboard")
    }
  }
}
