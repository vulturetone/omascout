import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The glucose pill, and the host for the Nightscout popup.
//
// Panel.qml owns the reading (it stays loaded for the whole session, so one
// poll feeds both surfaces); this file is the bar-side rendering of it.
//
// The pill paints its own label rather than using WidgetButton's, because
// two things have to survive from the waybar stylesheet that a plain label
// cannot express: urgent readings are bold, and the sensor-expiry warning is
// an outline drawn *around* the glucose colour rather than a replacement for
// it, so that a low reading is never visually masked by a sensor warning.
BarWidget {
  id: root
  moduleName: "vulturetone.omascout"

  readonly property var panel: panelLoader.item
  readonly property string pillText: panel ? panel.pillText : ""
  readonly property color pillColor: panel ? panel.glucoseColor : Color.foreground
  readonly property color pillFill: panel ? panel.pillFill : "transparent"
  readonly property color pillBorder: panel ? panel.pillBorder : "transparent"
  readonly property bool urgent: panel ? panel.urgent : false

  // On a vertical bar only the number survives: the slot is one glyph wide,
  // so the trend arrow and the expiry suffix are dropped and the outline is
  // left to carry the sensor warning on its own. The reading is the content,
  // so hiding it the way media hides its track label would leave nothing.
  readonly property string valueText: panel && panel.glucose ? String(panel.glucose.shown) : pillText

  function refresh() {
    if (panel) panel.refresh()
  }

  function togglePanel() {
    if (panel) panel.toggle()
  }

  function openSite() {
    if (panel) panel.openSite()
  }

  // ---- Shape contract for shell.summon/hide/toggle routing: the bar's
  //      findPanelWidget requires open/close/opened on the bar-widget root.
  readonly property bool opened: panel ? panel.opened === true : false

  function open() {
    if (panel) panel.openFromHotkey()
  }

  function close() {
    if (panel) panel.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panel ? panel.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panel) panel.closeForPopoutSwitch()
  }

  // The pill fills more slot than it paints, so the open-panel dot tracks the
  // text rather than the padding around it.
  readonly property real openPanelIndicatorWidth: label.implicitWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

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
    target: "vulturetone.omascout"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.pillText
    // The label below replaces WidgetButton's own; `text` still feeds
    // hasVisualContent so an empty reading collapses the slot as usual.
    labelVisible: false
    horizontalMargin: 8.5
    verticalPadding: 6
    fixedWidth: root.vertical ? -1 : Math.max(Style.space(12), label.implicitWidth + Style.spaceReal(horizontalMargin) * 2)
    // Vertically the pill is one icon-sized line, sized the way the clock
    // sizes its own stack, rather than by a label that isn't painted.
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    // The popup is the detail view, so no tooltip competes with it.
    tooltipText: ""

    onPressed: function(b) {
      if (b === Qt.RightButton) root.openSite()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }

    // Tint and outline sit behind the text: the fill carries how far out of
    // range the reading is, the outline how close the sensor is to done.
    BorderSurface {
      anchors.fill: parent
      anchors.topMargin: root.vertical ? 0 : Style.space(2)
      anchors.bottomMargin: root.vertical ? 0 : Style.space(2)
      color: root.pillFill
      borderSpec: Border.flat(root.pillBorder, Style.space(1))
      radius: Math.min(Style.cornerRadius > 0 ? Style.cornerRadius : height / 2, height / 2)

      Behavior on color { ColorAnimation { duration: 160 } }
    }

    Text {
      id: label
      anchors.centerIn: parent
      text: root.vertical ? "" : root.pillText
      visible: !root.vertical
      color: root.pillColor
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      font.bold: root.urgent
      renderType: Text.NativeRendering
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter

      Behavior on color { ColorAnimation { duration: 160 } }
    }

    OpticalGlyph {
      visible: root.vertical
      anchors.centerIn: parent
      width: button.width
      height: Style.bar.iconSlot
      text: root.valueText
      fontFamily: button.fontFamily
      // Shrunk to fit the slot rather than clipped by it: a reading in mmol/L
      // is four characters wide where mg/dL is three, and neither may spill
      // over its neighbours. 0.62em per character is the monospace advance.
      fontSize: Math.max(Style.font.caption, Math.min(button.fontSize,
        (button.width - Style.space(3)) / Math.max(1, root.valueText.length) / 0.62))
      color: root.pillColor
    }
  }
}
