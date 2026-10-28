import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "ClipModel.js" as ClipModel

// Clipboard history overlay. Capture is done by the built-in omarchy.clipboard
// watcher; this plugin reads its history file and adds a richer picker on top,
// plus pins that outlive history rotation.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
  property string historyPath: stateDir + "/clipboard-history.json"
  property string pinsPath: stateDir + "/bsadik-clipboard-pins.json"

  property bool opened: false
  property string filterText: ""
  property string tab: "all"
  property int selectedIndex: 0
  property bool clearConfirmOpen: false
  property var history: []
  property var pins: []
  property var current: null
  property var counts: ({ all: 0, text: 0, images: 0, pinned: 0 })

  readonly property var tabs: [
    { id: "all", label: "All" },
    { id: "text", label: "Text" },
    { id: "images", label: "Images" },
    { id: "pinned", label: "Pinned" }
  ]

  // Theme tokens: share the menu surface so this matches the launcher,
  // emoji picker and built-in clipboard, with the theme accent for highlights.
  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property color selectedText: Commons.Color.menu.selectedText
  property color accent: Commons.Color.accent
  property color muted: Util.alpha(foreground, 0.55)
  property color subtle: Util.alpha(foreground, 0.05)
  property color hairline: Util.alpha(foreground, 0.1)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property string iconFamily: "JetBrainsMono Nerd Font"

  property int cardWidth: Math.min(Style.space(940), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(600), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(54), Style.font.body + Style.font.caption + Style.space(26))
  property int badgeSize: rowHeight - Style.space(18)
  property int displayLimit: 150

  // ------------------------------------------------------------ lifecycle

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.tab = "all"
    try {
      var payload = JSON.parse(payloadJson || "{}")
      if (payload && root.tabs.some(function(t) { return t.id === payload.tab })) root.tab = payload.tab
    } catch (e) {}
    root.selectedIndex = 0
    root.clearConfirmOpen = false
    pointerGate.reset()
    historyFile.reload()
    root.rebuild()
    openAnim.restart()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.clearConfirmOpen = false
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // ----------------------------------------------------------------- data

  function rebuild() {
    var all = ClipModel.buildRows(root.history, root.pins, root.filterText, "all", 1000)
    var c = { all: all.length, text: 0, images: 0, pinned: 0 }
    var shown = []
    for (var i = 0; i < all.length; i++) {
      var r = all[i]
      if (r.pinned) c.pinned++
      if (r.kind === "image" || r.kind === "file") c.images++
      else c.text++
      if (shown.length < root.displayLimit && ClipModel.matchesTab(r.kind, r.pinned, root.tab)) shown.push(r)
    }
    root.counts = c

    displayModel.clear()
    for (var j = 0; j < shown.length; j++) {
      var row = shown[j]
      displayModel.append({
        kind: row.kind,
        title: row.title,
        meta: row.meta,
        body: row.body,
        imageUrl: row.imagePath ? Util.fileUrl(row.imagePath) : "",
        swatch: row.swatch,
        pinned: row.pinned,
        pinIndex: row.pinIndex,
        historyIndex: row.historyIndex,
        entryKey: row.entryKey
      })
    }

    if (root.selectedIndex >= displayModel.count) root.selectedIndex = Math.max(0, displayModel.count - 1)
    root.syncCurrent()
    Qt.callLater(function() {
      if (displayModel.count > 0) list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function syncCurrent() {
    root.current = displayModel.count > 0 ? displayModel.get(root.selectedIndex) : null
  }

  onSelectedIndexChanged: syncCurrent()

  function entryFor(row) {
    if (!row) return null
    if (row.pinIndex >= 0) return root.pins[row.pinIndex]
    if (row.historyIndex >= 0) return root.history[row.historyIndex]
    return null
  }

  function savePins() {
    pinsFile.setText(JSON.stringify(root.pins, null, 2) + "\n")
  }

  function saveHistory() {
    historyFile.setText(JSON.stringify(root.history, null, 2) + "\n")
  }

  // ------------------------------------------------------------- actions

  function setFilter(text) {
    root.filterText = text
    root.selectedIndex = 0
    pointerGate.reset()
    root.rebuild()
  }

  function setTab(id) {
    if (root.tab === id) return
    root.tab = id
    root.selectedIndex = 0
    root.rebuild()
  }

  function cycleTab(delta) {
    var idx = 0
    for (var i = 0; i < root.tabs.length; i++) if (root.tabs[i].id === root.tab) idx = i
    root.setTab(root.tabs[(idx + delta + root.tabs.length) % root.tabs.length].id)
  }

  function move(delta) {
    if (displayModel.count === 0) return
    pointerGate.reset()
    root.selectedIndex = (root.selectedIndex + delta + displayModel.count) % displayModel.count
    list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function moveTo(index) {
    if (displayModel.count === 0) return
    pointerGate.reset()
    root.selectedIndex = Math.max(0, Math.min(index, displayModel.count - 1))
    list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function paste(index, copyOnly) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    var entry = root.entryFor(row)
    if (!entry) return
    root.close()

    var bin = root.omarchyPath + "/bin/"
    if (entry.type === "image") {
      var args = [bin + "omarchy-clipboard-paste-file"]
      if (copyOnly) args.push("--copy-only")
      Quickshell.execDetached(args.concat([entry.mime, entry.path]))
    } else if (row.historyIndex >= 0) {
      Quickshell.execDetached([bin + "omarchy-clipboard-paste-text", copyOnly ? "--copy-only" : "--shift-insert",
        "--history-index", String(row.historyIndex)])
    } else {
      Quickshell.execDetached([bin + "omarchy-clipboard-paste-text", copyOnly ? "--copy-only" : "--shift-insert", entry.text])
    }
  }

  function togglePin(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    var key = row.entryKey
    var next = root.pins.slice()
    if (row.pinIndex >= 0) {
      next.splice(row.pinIndex, 1)
    } else {
      var entry = root.entryFor(row)
      if (!entry) return
      next.push(entry)
    }
    root.pins = next
    root.savePins()
    root.rebuild()
    // Keep the cursor on the same entry after it moves in or out of the pin group.
    for (var i = 0; i < displayModel.count; i++) {
      if (displayModel.get(i).entryKey === key) { root.selectedIndex = i; break }
    }
    root.syncCurrent()
  }

  function remove(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.pinIndex >= 0) {
      var nextPins = root.pins.slice()
      nextPins.splice(row.pinIndex, 1)
      root.pins = nextPins
      root.savePins()
    }
    if (row.historyIndex >= 0) {
      var nextHistory = root.history.slice()
      nextHistory.splice(row.historyIndex, 1)
      root.history = nextHistory
      root.saveHistory()
    }
    pointerGate.reset()
    root.rebuild()
  }

  function requestClear() {
    if (root.history.length === 0) return
    clearConfirm.selectedIndex = 1
    root.clearConfirmOpen = true
  }

  // Clears history but keeps pins: pinning is how you say "keep this".
  function confirmClear() {
    root.history = []
    root.saveHistory()
    root.clearConfirmOpen = false
    root.selectedIndex = 0
    root.rebuild()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function cancelClear() {
    root.clearConfirmOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // ------------------------------------------------------------- storage

  ListModel { id: displayModel }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: { root.history = ClipModel.parseList(text()); if (root.opened) root.rebuild() }
    onLoadFailed: { root.history = []; if (root.opened) root.rebuild() }
    onFileChanged: reload()
  }

  FileView {
    id: pinsFile
    path: root.pinsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: { root.pins = ClipModel.parseList(text()); if (root.opened) root.rebuild() }
    onLoadFailed: root.pins = []
    onFileChanged: reload()
  }

  // ------------------------------------------------------------------ UI

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "bsadik-clipboard"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      id: scrimLayer
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    ParallelAnimation {
      id: openAnim
      NumberAnimation { target: card; property: "opacity"; from: 0; to: 1; duration: 140; easing.type: Easing.OutCubic }
      NumberAnimation { target: card; property: "scale"; from: 0.97; to: 1; duration: 180; easing.type: Easing.OutCubic }
      NumberAnimation { target: scrimLayer; property: "opacity"; from: 0; to: 1; duration: 140 }
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.clearConfirmOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.clearConfirmOpen) {
            if (clearConfirm.handleKey(event)) event.accepted = true
            return
          }

          var ctrl = event.modifiers & Qt.ControlModifier
          var alt = event.modifiers & Qt.AltModifier
          var shift = event.modifiers & Qt.ShiftModifier
          event.accepted = true

          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.close()
          } else if (alt && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            root.paste(event.key - Qt.Key_1, false)
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
          } else if (event.key === Qt.Key_Tab) {
            root.cycleTab(1)
          } else if (event.key === Qt.Key_Backtab) {
            root.cycleTab(-1)
          } else if (ctrl && event.key === Qt.Key_P) {
            root.togglePin(root.selectedIndex)
          } else if (event.key === Qt.Key_Delete) {
            if (shift) root.requestClear()
            else root.remove(root.selectedIndex)
          } else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K)) {
            root.move(-1)
          } else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J)) {
            root.move(1)
          } else if (event.key === Qt.Key_PageUp) {
            root.move(-6)
          } else if (event.key === Qt.Key_PageDown) {
            root.move(6)
          } else if (event.key === Qt.Key_Home) {
            root.moveTo(0)
          } else if (event.key === Qt.Key_End) {
            root.moveTo(displayModel.count - 1)
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.paste(root.selectedIndex, shift)
          } else if (!ctrl && !alt && event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
          } else {
            event.accepted = false
          }
        }

        ConfirmDialog {
          id: clearConfirm
          anchors.fill: parent
          opened: root.clearConfirmOpen
          z: 10
          message: "Clear clipboard history? Pinned items are kept."
          confirmText: "Clear"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelClear()
          onConfirmed: root.confirmClear()
        }
      }

      Column {
        id: layout
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(12)

        // ---- search
        Item {
          id: searchBar
          width: parent.width
          height: Math.max(Style.space(36), Style.font.heading + Style.space(16))

          Text {
            id: searchIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: ClipModel.icons.search
            color: root.accent
            font.family: root.iconFamily
            font.pixelSize: Style.font.iconLarge
          }

          Text {
            id: queryText
            textFormat: Text.PlainText
            anchors.left: searchIcon.right
            anchors.leftMargin: Style.space(16)
            anchors.right: countLabel.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Search clipboard…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideLeft
          }

          Rectangle {
            id: caret
            visible: root.opened && !root.clearConfirmOpen
            x: root.filterText ? queryText.x + Math.min(queryText.contentWidth, queryText.width) + Style.space(2)
                               : queryText.x - width - Style.space(3)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(2, Style.space(2))
            height: Style.font.heading + Style.space(4)
            color: root.accent

            SequentialAnimation on opacity {
              running: caret.visible
              loops: Animation.Infinite
              NumberAnimation { to: 0; duration: 500; easing.type: Easing.InOutQuad }
              NumberAnimation { to: 1; duration: 500; easing.type: Easing.InOutQuad }
            }
          }

          Text {
            id: countLabel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.history.length + " in history"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- tabs
        Row {
          id: tabRow
          width: parent.width
          height: Style.space(30)
          spacing: Style.space(6)

          Repeater {
            model: root.tabs

            delegate: Rectangle {
              id: tabChip
              required property var modelData
              readonly property bool active: root.tab === modelData.id

              height: tabRow.height
              width: tabLabel.implicitWidth + tabCount.implicitWidth + Style.space(30)
              radius: root.cornerRadius
              color: active ? root.accent : (tabMouse.containsMouse ? root.subtle : "transparent")
              border.width: active ? 0 : Style.normalBorderWidth
              border.color: root.hairline

              Behavior on color { ColorAnimation { duration: 120 } }

              Row {
                anchors.centerIn: parent
                spacing: Style.space(8)

                Text {
                  id: tabLabel
                  text: tabChip.modelData.label
                  color: tabChip.active ? root.background : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: tabChip.active
                }

                Text {
                  id: tabCount
                  text: String(root.counts[tabChip.modelData.id] || 0)
                  color: tabChip.active ? Util.alpha(root.background, 0.7) : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setTab(tabChip.modelData.id)
              }
            }
          }
        }

        Rectangle { width: parent.width; height: Style.normalBorderWidth; color: root.hairline }

        // ---- list + preview
        Item {
          id: body
          width: parent.width
          height: layout.height - searchBar.height - tabRow.height - footer.height
                  - Style.normalBorderWidth * 2 - layout.spacing * 5

          ListView {
            id: list
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Math.round(parent.width * 0.56)
            model: displayModel
            clip: true
            spacing: Style.space(2)
            boundsBehavior: Flickable.StopAtBounds
            highlightMoveDuration: 0

            section.property: "pinned"
            section.criteria: ViewSection.FullString
            section.delegate: Item {
              required property string section
              width: ListView.view.width
              height: root.tab === "pinned" ? 0 : Style.space(24)
              visible: root.tab !== "pinned"

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                text: parent.section === "true" ? "PINNED" : "RECENT"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.5
                font.bold: true
              }
            }

            delegate: Rectangle {
              id: row
              required property int index
              required property string kind
              required property string title
              required property string meta
              required property string imageUrl
              required property string swatch
              required property bool pinned

              readonly property bool selected: index === root.selectedIndex

              width: ListView.view.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: selected ? root.selectedBackground : (rowMouse.containsMouse ? root.subtle : "transparent")

              Rectangle {
                visible: row.selected
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.topMargin: Style.space(8)
                anchors.bottomMargin: Style.space(8)
                width: Math.max(2, Style.space(3))
                color: root.accent
              }

              // Badge: thumbnail, color swatch, or type icon.
              Rectangle {
                id: badge
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                width: root.badgeSize
                height: root.badgeSize
                radius: root.cornerRadius
                clip: true
                color: row.swatch ? row.swatch : (row.selected ? Util.alpha(root.accent, 0.18) : root.subtle)
                border.width: Style.normalBorderWidth
                border.color: row.selected ? Util.alpha(root.accent, 0.5) : root.hairline

                Image {
                  visible: row.imageUrl.length > 0
                  anchors.fill: parent
                  anchors.margins: Style.normalBorderWidth
                  source: row.imageUrl
                  sourceSize.width: root.badgeSize * 2
                  sourceSize.height: root.badgeSize * 2
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: true
                }

                Text {
                  visible: row.imageUrl.length === 0 && !row.swatch
                  anchors.centerIn: parent
                  text: ClipModel.icons[row.kind] || ClipModel.icons.text
                  color: row.selected ? root.accent : root.muted
                  font.family: root.iconFamily
                  font.pixelSize: Style.font.iconLarge
                }
              }

              Column {
                anchors.left: badge.right
                anchors.leftMargin: Style.space(12)
                anchors.right: trailing.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: row.title
                  color: row.selected ? root.selectedText : root.foreground
                  font.family: row.kind === "code" ? Style.font.family : root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  elide: Text.ElideRight
                  maximumLineCount: 1
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: row.meta
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                }
              }

              Row {
                id: trailing
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  visible: row.pinned
                  anchors.verticalCenter: parent.verticalCenter
                  text: ClipModel.icons.pin
                  color: root.accent
                  font.family: root.iconFamily
                  font.pixelSize: Style.font.icon
                }

                Rectangle {
                  visible: row.index < 9
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(18)
                  height: Style.space(18)
                  radius: root.cornerRadius
                  color: "transparent"
                  border.width: Style.normalBorderWidth
                  border.color: root.hairline

                  Text {
                    anchors.centerIn: parent
                    text: String(row.index + 1)
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                onPositionChanged: function(mouse) {
                  if (pointerGate.moved(row, mouse)) root.selectedIndex = row.index
                }
                onClicked: function(mouse) {
                  root.selectedIndex = row.index
                  if (mouse.button === Qt.RightButton) root.togglePin(row.index)
                  else if (mouse.button === Qt.MiddleButton) root.remove(row.index)
                  else root.paste(row.index, false)
                }
              }
            }
          }

          // Empty state
          Column {
            anchors.centerIn: list
            spacing: Style.space(10)
            visible: displayModel.count === 0

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.tab === "pinned" && !root.filterText ? ClipModel.icons.pinOutline : ClipModel.icons.clipboard
              color: root.accent
              opacity: 0.8
              font.family: root.iconFamily
              font.pixelSize: Style.font.displayLarge
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: root.filterText ? "No matches for “" + root.filterText + "”"
                : root.tab === "pinned" ? "Nothing pinned yet — Ctrl+P pins an item"
                : "Nothing here yet"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }
          }

          // ---- preview pane
          Rectangle {
            id: preview
            anchors.left: list.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            radius: root.cornerRadius
            color: root.subtle
            border.width: Style.normalBorderWidth
            border.color: root.hairline
            clip: true

            readonly property var item: root.current

            Item {
              id: previewContent
              anchors.fill: parent
              anchors.margins: Style.space(14)
              anchors.bottomMargin: previewFooter.height + Style.space(14)
              visible: preview.item !== null

              Image {
                id: previewImage
                anchors.fill: parent
                visible: preview.item !== null && preview.item.imageUrl.length > 0
                source: visible ? preview.item.imageUrl : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
                mipmap: true
              }

              Rectangle {
                visible: preview.item !== null && preview.item.swatch.length > 0 && !previewImage.visible
                anchors.fill: parent
                radius: root.cornerRadius
                color: visible ? preview.item.swatch : "transparent"
                border.width: Style.normalBorderWidth
                border.color: root.hairline
              }

              Flickable {
                id: textFlick
                anchors.fill: parent
                visible: preview.item !== null && !previewImage.visible && preview.item.swatch.length === 0
                contentWidth: width
                contentHeight: previewText.paintedHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Text {
                  id: previewText
                  width: textFlick.width
                  textFormat: Text.PlainText
                  text: preview.item ? preview.item.body : ""
                  color: root.foreground
                  font.family: preview.item && (preview.item.kind === "code" || preview.item.kind === "file")
                    ? Style.font.family : root.fontFamily
                  font.pixelSize: Style.font.body
                  lineHeight: 1.25
                  wrapMode: Text.WrapAnywhere
                }
              }
            }

            Item {
              id: previewFooter
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.margins: Style.space(14)
              height: Style.space(28)
              visible: preview.item !== null

              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: -Style.space(8)
                height: Style.normalBorderWidth
                color: root.hairline
              }

              Text {
                anchors.left: parent.left
                anchors.right: actions.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: !preview.item ? ""
                  : previewImage.visible && previewImage.status === Image.Ready
                    ? previewImage.implicitWidth + " × " + previewImage.implicitHeight + " · " + preview.item.meta
                    : preview.item.meta
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Row {
                id: actions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Repeater {
                  model: [
                    { icon: preview.item && preview.item.pinned ? ClipModel.icons.pin : ClipModel.icons.pinOutline,
                      act: "pin", tip: "Pin", hot: preview.item && preview.item.pinned },
                    { icon: ClipModel.icons.trash, act: "remove", tip: "Delete", hot: false }
                  ]

                  delegate: Rectangle {
                    id: actionButton
                    required property var modelData
                    width: Style.space(28)
                    height: Style.space(28)
                    radius: root.cornerRadius
                    color: actionMouse.containsMouse ? Util.alpha(root.foreground, 0.1) : "transparent"

                    Text {
                      anchors.centerIn: parent
                      text: actionButton.modelData.icon
                      color: actionButton.modelData.hot ? root.accent
                        : (actionMouse.containsMouse ? root.foreground : root.muted)
                      font.family: root.iconFamily
                      font.pixelSize: Style.font.icon
                    }

                    MouseArea {
                      id: actionMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        if (actionButton.modelData.act === "pin") root.togglePin(root.selectedIndex)
                        else root.remove(root.selectedIndex)
                      }
                    }
                  }
                }
              }
            }

            Text {
              anchors.centerIn: parent
              visible: preview.item === null
              text: ClipModel.icons.clipboard
              color: root.hairline
              font.family: root.iconFamily
              font.pixelSize: Style.font.displayLarge * 2
            }
          }
        }

        Rectangle { width: parent.width; height: Style.normalBorderWidth; color: root.hairline }

        // ---- key hints
        Row {
          id: footer
          width: parent.width
          height: Style.space(20)
          spacing: Style.space(18)

          Repeater {
            model: [
              { key: "↵", label: "Paste" },
              { key: "⇧↵", label: "Copy" },
              { key: "Alt 1-9", label: "Quick paste" },
              { key: "Ctrl P", label: "Pin" },
              { key: "Del", label: "Delete" },
              { key: "⇧Del", label: "Clear" },
              { key: "Tab", label: "Filter" }
            ]

            delegate: Row {
              required property var modelData
              spacing: Style.space(6)
              anchors.verticalCenter: parent ? parent.verticalCenter : undefined

              Text {
                text: parent.modelData.key
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                text: parent.modelData.label
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }
}
