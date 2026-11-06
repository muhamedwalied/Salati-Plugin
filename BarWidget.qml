import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Salati bar pill: a single crescent-moon icon that opens the prayer-times
// panel. The icon is identical whatever the panel's data source is; the
// tooltip and the disclosure line live in the panel.
BarWidget {
  id: root
  moduleName: "muhamed.salati"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---- Panel wiring (mirrors omarchy.weather) --------------------------
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Refresh the panel's data from the bar's IPC surface.
  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "muhamed.salati"

    function refresh() { root.refresh() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.togglePanel() }
  }

  // An icon-only slot, sized like the shell's other single-glyph widgets. The
  // moon is pinned to the Nerd Font family so it renders even if the bar's
  // configured font is swapped for one without the glyph. U+F186 is the Nerd
  // Font / Font Awesome "moon".
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    // The glyph is drawn as a plain child, so the button's own text-based
    // visibility check has nothing to see; keep the slot drawable.
    hasVisualContent: true
    slotSize: Style.bar.iconSlot
    tooltipText: strings.t("tooltip.default")

    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
    }

    Text {
      id: moon
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: "\uF186"
      color: root.bar ? root.bar.foreground : Commons.Color.foreground
      font.family: "JetBrainsMono Nerd Font"
      font.pixelSize: Style.font.icon
      renderType: Text.NativeRendering
      scale: button.pressScale
    }
  }
}
