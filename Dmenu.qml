import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons

// Classic dmenu: a single flat horizontal bar spanning the screen edge
// (top by default, like vanilla dmenu; set dockAtBottom for dmenu -b),
// prompt/input on the left, matches laid out left-to-right after it.
//
// Lifecycle contract (see /usr/share/omarchy/shell/shell.qml): the host
// injects `shell` and `manifest` after loading this file, then drives the
// plugin purely through open(payloadJson) / close() — there is no
// per-plugin IpcHandler to write. `omarchy-shell shell summon/toggle
// local.dmenu` reaches this file through that shared "shell" IPC target.
Item {
  id: root

  // Injected by omarchy-shell once this plugin is loaded.
  property var shell: null
  property var manifest: null

  // Read by the host's isPluginOpen() to track summon/hide state.
  property bool opened: false

  property string filterText: ""
  property int selectedIndex: 0

  // ------------------------------------------------------------- styling
  // Uses the same tokens the real status bar renders itself with — height,
  // background, text, and accent — so this reads as "the bar became
  // dmenu" rather than a second bar popping up on top of it. It sits on
  // WlrLayer.Overlay (above the bar's own WlrLayer.Top) at the bar's exact
  // geometry, so the real bar is fully covered while this is open.
  property color background: Color.bar.background
  property color foreground: Color.bar.text
  property color selectedBackground: Util.alpha(Color.bar.active, 0.25)
  property color selectedText: Color.bar.active
  property string fontFamily: Style.font.menuFamily

  // ------------------------------------------------------------- layout
  // Tweak these to reposition/resize the bar (see README.md). Defaults
  // match the real bar's own height and edge padding conventions.
  property bool dockAtBottom: false
  property int barHeight: Style.bar.sizeHorizontal
  property int sideMargin: Style.space(8)
  property int itemPaddingX: Style.space(10)
  property int itemSpacing: Style.space(2)

  // Where the dmenu segment starts and how far right it may grow. A
  // separate Wayland surface can't query the real bar's live widget
  // geometry (different layer-shell client, no shared property), so
  // leftOffset can't be read off the real bar directly — but the bar's
  // workspace-number widget (i3-workspaces/omarchy.workspaces) renders
  // each pill at a fixed Style.space(20) with no gap between them, so the
  // *variable* part (how many pills there are right now) can be tracked
  // live via the same Quickshell.Hyprland data those widgets use. leftBase
  // covers everything before the workspace pills (bar margin, menu icon,
  // module spacing) and stays a measured constant — re-measure it if you
  // change what's in the bar's left section (see README.md). Right edge
  // stops short of the screen's horizontal center by centerGap, leaving
  // breathing room before the bar's own center modules (clock, etc.).
  property int maxWorkspaceId: 10
  property int perWorkspaceWidth: Style.space(20)
  property int leftBase: 40
  property int leftOffset: root.leftBase + root.workspaceCount * root.perWorkspaceWidth
  property int centerGap: 100
  readonly property int maxRightX: Math.round(panel.width / 2) - root.centerGap
  readonly property int contentWidth: Math.max(0, root.maxRightX - root.leftOffset)

  // Same id set the i3-workspaces/omarchy.workspaces widgets compute for
  // this monitor: every live Hyprland workspace id in [1, maxWorkspaceId],
  // owned by this screen (or unowned), deduplicated.
  readonly property var hyprWorkspaceIds: {
    var mine = panel.screen ? String(panel.screen.name || "") : ""
    var ids = []
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      var id = ws.id
      if (id <= 0 || id > root.maxWorkspaceId) continue
      if (mine !== "") {
        var owner = ws.monitor && ws.monitor.name ? String(ws.monitor.name)
          : (ws.lastIpcObject && ws.lastIpcObject.monitor ? String(ws.lastIpcObject.monitor) : "")
        if (owner !== "" && owner !== mine) continue
      }
      if (ids.indexOf(id) === -1) ids.push(id)
    }
    return ids
  }
  readonly property int workspaceCount: root.hyprWorkspaceIds.length

  ListModel { id: displayModel }

  // --------------------------------------------------------- lifecycle
  // Called by the host after `shell summon`/`shell toggle`.
  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    // keepLoaded means this component can sit around for a long time —
    // pull a fresh workspace count so leftOffset reflects "right now"
    // rather than whatever it was when the plugin last mounted.
    Hyprland.refreshWorkspaces()
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Called by the host when something else hides this plugin.
  function close() {
    root.opened = false
  }

  // Called from inside the UI (Escape, Enter) — also tells the host so
  // its openPanelIds bookkeeping matches reality.
  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "local.dmenu")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ------------------------------------------------------------ filtering
  // Real dmenu's match(): case-insensitive, every space-separated term of
  // the query must appear somewhere in the text (AND — not a fuzzy score),
  // then results are bucketed exact match, then prefix match, then any
  // other substring match, each bucket keeping the underlying list's
  // order. No relevance scoring, no acronym matching.
  function allTermsMatch(haystack, terms) {
    for (var i = 0; i < terms.length; i++) {
      if (haystack.indexOf(terms[i]) < 0) return false
    }
    return true
  }

  function dmenuFilter(baseRows, query) {
    if (!query) return baseRows

    var terms = query.split(/\s+/)
    var exact = [], prefix = [], substr = []
    for (var i = 0; i < baseRows.length; i++) {
      var row = baseRows[i]
      var haystack = row.label.toLowerCase()
      if (!allTermsMatch(haystack, terms)) continue
      if (haystack === query) exact.push(row)
      else if (haystack.indexOf(query) === 0) prefix.push(row)
      else substr.push(row)
    }
    return exact.concat(prefix, substr)
  }

  // Base list source: the shell's shared AppLibrary (DesktopEntries +
  // hidden-entry filtering, same source the Omarchy menu uses) in
  // dictionary order, matching what real dmenu shows with an empty query.
  // Falls back to DesktopEntries directly when running outside
  // omarchy-shell. The AND/bucket ranking above is applied on top either
  // way — this plugin never uses AppLibrary's own fuzzy/acronym scoring.
  function baseRows() {
    var rows = []
    if (root.shell && root.shell.appLibrary) {
      var lib = root.shell.appLibrary
      var all = lib.sortedEntries("")
      for (var i = 0; i < all.length; i++) {
        var entry = all[i].entry
        var appId = String(entry.id || "")
        if (!appId) continue
        rows.push({ appId: appId, label: lib.entryName(entry) })
      }
    } else {
      var apps = DesktopEntries.applications.values || []
      for (var j = 0; j < apps.length; j++) {
        var app = apps[j]
        if (!app || app.noDisplay) continue
        var name = String(app.name || app.id || "")
        if (!name) continue
        rows.push({ appId: String(app.id || ""), label: name })
      }
      rows.sort(function(a, b) { return a.label.localeCompare(b.label) })
    }
    return rows
  }

  function rebuildDisplay() {
    var query = root.filterText.trim().toLowerCase()
    var rows = root.dmenuFilter(root.baseRows(), query)

    displayModel.clear()
    for (var k = 0; k < rows.length; k++) displayModel.append(rows[k])

    if (displayModel.count === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= displayModel.count) root.selectedIndex = displayModel.count - 1
    else if (root.selectedIndex < 0) root.selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function setFilter(text) {
    root.filterText = text
    root.selectedIndex = 0
    root.rebuildDisplay()
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.selectedIndex = (root.selectedIndex + delta + displayModel.count) % displayModel.count
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.launchApp(row.appId, row.label)
  }

  function launchApp(appId, label) {
    root.dismiss()
    if (!appId) return
    if (root.shell && root.shell.appLibrary) {
      // Same launch path (gtk-launch under uwsm) the Omarchy menu uses.
      root.shell.appLibrary.launch(appId, label)
    } else {
      Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(appId + ".desktop"))
    }
  }

  // dmenu_run parity: pressing Enter with no app match runs the raw typed
  // text as a shell command, same as classic `dmenu_run` piping the
  // selection into `$SHELL -c`. This is what makes dmenu a command
  // launcher rather than just an app picker.
  function launchRaw(text) {
    var command = String(text || "").trim()
    root.dismiss()
    if (!command) return
    Util.execDetached(command)
  }

  // Enter: launch the highlighted match if there is one (default cursor
  // sits on the best match), otherwise fall through to launchRaw() —
  // mirrors dmenu's own keypress handling (puts(sel->text) vs puts(text)).
  function activate() {
    if (displayModel.count > 0) root.activateIndex(root.selectedIndex)
    else root.launchRaw(root.filterText)
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors {
      top: !root.dockAtBottom
      bottom: root.dockAtBottom
      left: true
      right: true
    }
    implicitHeight: root.barHeight
    // Transparent: only the contentBar segment below paints anything, so
    // the real bar's own widgets (menu icon, workspace numbers, tray,
    // clock, ...) stay visible everywhere outside that segment.
    color: "transparent"
    WlrLayershell.namespace: "local-dmenu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // Keyboard grab spans the full transparent surface — Escape/typing
    // must work regardless of where the visible segment sits.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.dismiss()
          event.accepted = true
        } else if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)) {
          root.dismiss()
          event.accepted = true
        } else if (Util.editsFilter(event, root.filterText)) {
          root.setFilter(Util.editedFilter(event, root.filterText))
          event.accepted = true
        } else if (event.key === Qt.Key_Left
            || (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier))) {
          root.select(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Right
            || (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier))) {
          root.select(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Backtab
            || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
          root.select(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Tab) {
          root.select(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.activate()
          event.accepted = true
        } else if (event.text && event.text.length === 1
            && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
            && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
          root.setFilter(root.filterText + event.text)
          event.accepted = true
        }
      }
    }

    // The one opaque, visible segment: starts right after the real bar's
    // workspace-number widget (root.leftOffset) and never reaches past
    // the screen's horizontal center (root.maxRightX) — see the layout
    // properties above.
    Rectangle {
      id: contentBar
      x: root.leftOffset
      width: root.contentWidth
      height: parent.height
      color: root.background
      clip: true

      // Prompt/input. A live Text bound to filterText rather than a real
      // TextField — keeps a single exclusive-focus key grab for the whole
      // bar (input + navigation) instead of juggling two.
      Text {
        id: promptText
        anchors.left: parent.left
        anchors.leftMargin: root.sideMargin
        anchors.verticalCenter: parent.verticalCenter
        text: root.filterText.length > 0 ? (root.filterText + "▏") : "▏"
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      // Matches, laid out left-to-right like real dmenu — not a dropdown.
      // Renders nothing when the model is empty, so it can share the same
      // region as the "no match" hint below without stealing its space.
      ListView {
        id: resultList
        anchors.left: promptText.right
        anchors.leftMargin: root.sideMargin
        anchors.right: parent.right
        anchors.rightMargin: root.sideMargin
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        model: displayModel
        orientation: ListView.Horizontal
        clip: true
        spacing: root.itemSpacing
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          id: row
          required property int index
          required property string appId
          required property string label

          readonly property bool hasCursor: index === root.selectedIndex

          height: ListView.view.height
          width: labelText.implicitWidth + root.itemPaddingX * 2
          color: hasCursor ? root.selectedBackground : "transparent"

          Text {
            id: labelText
            anchors.centerIn: parent
            // row.label comes straight from a .desktop file's Name= field —
            // untrusted local content. Without this, Qt's default AutoText
            // format sniffs for HTML and would render (and fetch resources
            // for, e.g. <img src=...>) a crafted rich-text name.
            text: row.label
            textFormat: Text.PlainText
            color: row.hasCursor ? root.selectedText : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: root.selectedIndex = index
            onClicked: root.activateIndex(index)
          }
        }
      }

      Text {
        anchors.left: promptText.right
        anchors.leftMargin: root.sideMargin
        anchors.right: parent.right
        anchors.rightMargin: root.sideMargin
        anchors.verticalCenter: parent.verticalCenter
        visible: displayModel.count === 0 && root.filterText.length > 0
        text: "no match — Enter runs this as a command"
        textFormat: Text.PlainText
        color: root.foreground
        opacity: 0.55
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
    }
  }
}
