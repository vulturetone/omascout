import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Nightscout popup, and the owner of the reading itself.
//
// Data lives here rather than in BarWidget.qml because the panel is loaded
// for the whole session (BarWidget keeps its Loader active), so one poll
// feeds both surfaces, the same split the first-party weather widget uses.
//
// scripts/nightscout.py does the fetching, the threshold lookup, and the
// sensor-expiry derivation; everything below is presentation.
Panel {
  id: root
  moduleName: "vulturetone.omascout"
  ipcTarget: "vulturetone.omascout"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot (BarWidget.qml), not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Reading state. `payload` is the script's last JSON object, kept on
  //      failure so a dropped poll leaves the previous number on the bar
  //      rather than blanking it.
  property var payload: null
  property bool refreshing: false

  // ---- Demo mode. Cycles the pill and this panel through every state the
  //      script can emit, by standing in for its payload rather than by
  //      duplicating any rendering. What you see is exactly what a real
  //      reading of that shape would paint, so a custom palette in
  //      shell.json is exercised here the way it will actually look.
  //
  //      Polling stops while it runs: the script's data is not used, and
  //      cannot land mid-cycle and fight the preview for the bar.
  property bool demoMode: false
  property int demoIndex: 0

  readonly property var shownPayload: demoMode && demoIndex < demoScenarios.length
                                        ? demoScenarios[demoIndex].payload
                                        : payload

  readonly property string demoLabel: demoMode && demoIndex < demoScenarios.length
                                        ? String(demoScenarios[demoIndex].label)
                                        : ""

  function demoStep(direction) {
    var count = demoScenarios.length
    demoIndex = (demoIndex + direction + count) % count
    if (demoMode) demoTimer.restart()
  }

  function setDemoMode(on) {
    demoIndex = 0
    demoMode = on
    if (on) {
      demoTimer.restart()
    } else {
      demoTimer.stop()
      // Nothing was polled while the preview ran, so the reading on the bar
      // is as old as the demo was long. Catch up the moment it ends.
      refresh()
    }
  }

  // Demo readings are written in mg/dL and shown in whatever unit the live
  // site displays, so the preview uses the numbers you actually read.
  readonly property bool demoMmol: {
    if (!payload || !payload.glucose) return false
    var shown = Number(payload.glucose.shown)
    var mgdl = Number(payload.glucose.mgdl)
    return isFinite(shown) && isFinite(mgdl) && shown > 0 && (mgdl / shown) > 10
  }

  function demoValue(mgdl) {
    return demoMmol ? (mgdl / 18.0).toFixed(1) : String(Math.round(mgdl))
  }

  // Mirrors human_dur() in the script so demo labels read like real ones.
  function demoDur(secs) {
    secs = Math.round(secs / 60) * 60
    var d = Math.floor(secs / 86400)
    var h = Math.floor((secs % 86400) / 3600)
    var m = Math.floor((secs % 3600) / 60)
    if (d > 0) return d + "d " + h + "h"
    if (h > 0) return h + "h"
    return m + "m"
  }

  // `leftSecs` below zero is an overdue sensor, the same as in the script.
  function demoSensor(leftSecs) {
    var days = 15
    var wearMs = days * 86400000
    var now = Date.now()
    var expiry = now + leftSecs * 1000
    var start = expiry - wearMs
    return {
      "tracked": true, "serial": "DEMO123456", "known": true, "days": days,
      "startMs": start, "expiryMs": expiry,
      "ageLabel": demoDur((now - start) / 1000),
      "leftSecs": leftSecs, "leftLabel": demoDur(Math.abs(leftSecs)),
      "fraction": Math.min(1, Math.max(0, (now - start) / wearMs))
    }
  }

  // Assembled the way main() assembles the real thing, including the way the
  // sensor suffix is appended to the pill text rather than replacing it.
  function demoReading(cls, mgdl, arrow, deltaMgdl, ageMins, sensor) {
    var text = (demoValue(mgdl) + " " + arrow).trim()
    var classes = [cls]
    if (sensor && sensor.known) {
      if (sensor.leftSecs <= 0) {
        classes.push("sensor-expired")
        text += "   expired"
      } else if (sensor.leftSecs <= 24 * 3600) {
        classes.push("sensor-expiring")
        text += "   " + demoDur(sensor.leftSecs)
      }
    }
    return {
      "state": "ok", "text": text, "classes": classes, "url": root.browseUrl,
      "glucose": {
        "shown": demoValue(mgdl), "mgdl": mgdl, "arrow": arrow,
        "delta": (deltaMgdl >= 0 ? "+" : "-") + demoValue(Math.abs(deltaMgdl)),
        "ageMins": ageMins,
        "ageLabel": ageMins < 1 ? "just now" : ageMins + " min ago"
      },
      "sensor": sensor || { "tracked": false, "serial": "", "known": false, "days": 0 }
    }
  }

  readonly property var demoScenarios: [
    { "label": "In range",     "payload": demoReading("in-range",    140, "→",  10, 0, null) },
    { "label": "High",         "payload": demoReading("high",        200, "↗",  25, 1, null) },
    { "label": "Urgent high",  "payload": demoReading("urgent-high", 290, "↑",  40, 0, null) },
    { "label": "Low",          "payload": demoReading("low",          65, "↘", -20, 1, null) },
    { "label": "Urgent low",   "payload": demoReading("urgent-low",   48, "↓", -35, 0, null) },
    { "label": "Stale feed",   "payload": demoReading("stale",       120, "→",   0, 27, null) },
    // Sensor life is additive, so the pair below is the one that matters: the
    // reading keeps its own colour while the outline carries the warning.
    { "label": "Sensor fresh",    "payload": demoReading("in-range",  140, "→",   5, 0, demoSensor(9 * 86400)) },
    { "label": "Sensor expiring", "payload": demoReading("in-range",  130, "→",   5, 0, demoSensor(3 * 3600)) },
    { "label": "Sensor expired",  "payload": demoReading("urgent-low", 50, "↓", -25, 0, demoSensor(-2 * 3600)) },
    { "label": "Sensor age unknown", "payload": demoReading("in-range", 140, "→", 5, 0,
        { "tracked": true, "serial": "unknown", "known": false, "days": 15 }) },
    { "label": "No readings", "payload": {
        "state": "error", "text": "⚠️ Readings", "classes": ["error"],
        "title": "No recent readings",
        "detail": "Nightscout returned no glucose entries" } },
    { "label": "No URL set", "payload": {
        "state": "unconfigured", "text": "⚠️ URL Missing", "classes": ["error"],
        "title": "No Nightscout URL",
        "detail": "Set `url` on this widget's entry in ~/.config/omarchy/shell.json." } },
    { "label": "Site unreachable", "payload": {
        "state": "error", "text": "⚠️ Nightscout unreachable", "classes": ["error"],
        "title": "Nightscout unreachable",
        "detail": "TimeoutError: timed out" } },
    { "label": "First load", "payload": null }
  ]

  // Everything below renders `shownPayload`, which is the live reading unless
  // demo mode is standing in for it.
  readonly property bool ok: !!shownPayload && shownPayload.state === "ok"
  readonly property bool unconfigured: !!shownPayload && shownPayload.state === "unconfigured"
  readonly property var glucose: ok && shownPayload.glucose ? shownPayload.glucose : null
  readonly property var sensor: ok && shownPayload.sensor ? shownPayload.sensor : null
  readonly property var classes: shownPayload && shownPayload.classes ? shownPayload.classes : []

  readonly property string pillText: shownPayload ? String(shownPayload.text || "") : ""
  readonly property string glucoseClass: classes.length > 0 ? String(classes[0]) : ""
  readonly property bool sensorExpired: classes.indexOf("sensor-expired") !== -1
  readonly property bool sensorExpiring: classes.indexOf("sensor-expiring") !== -1
  readonly property bool stale: glucoseClass === "stale"
  readonly property bool urgent: glucoseClass === "urgent-low" || glucoseClass === "urgent-high"
  readonly property bool sensorTracked: !!sensor && sensor.tracked === true
  readonly property bool sensorKnown: sensorTracked && sensor.known === true

  // ---- Palette. Glucose classification is a traffic light, so these are
  //      fixed semantic colors rather than theme roles: a reading has to mean
  //      the same thing under every theme. Each is overridable from
  //      shell.json for a theme they genuinely clash with.
  readonly property color colorInRange: setting("colorInRange", '#95d58f')
  readonly property color colorHigh:    setting("colorHigh",    "#f9e2af")
  readonly property color colorLow:     setting("colorLow",     "#fab387")
  readonly property color colorUrgent:  setting("colorUrgent",  "#f38ba8")
  readonly property color colorStale:   setting("colorStale",   '#6480e6')
  readonly property color colorError:   setting("colorError",   '#862782')

  readonly property color glucoseColor: {
    switch (glucoseClass) {
      case "in-range":     return colorInRange
      case "high":         return colorHigh
      case "low":          return colorLow
      case "urgent-high":
      case "urgent-low":   return colorUrgent
      case "stale":        return colorStale
      default:             return colorError
    }
  }

  // In range is the common case: readable, but quiet, with no fill at all. Out of
  // range tints, and both urgent states shout. Alphas carried over from the
  // waybar stylesheet so the visual weight ordering is unchanged.
  readonly property color pillFill: {
    if (urgent) return Util.alpha(colorUrgent, 0.30)
    if (glucoseClass === "high") return Util.alpha(colorHigh, 0.20)
    if (glucoseClass === "low") return Util.alpha(colorLow, 0.22)
    return "transparent"
  }

  // Sensor life runs alongside the glucose classes above, so it must not set
  // the text color: a low reading has to keep its own. An outline instead.
  readonly property color pillBorder: {
    if (sensorExpired) return Util.alpha(colorUrgent, 0.75)
    if (sensorExpiring) return Util.alpha(colorHigh, 0.55)
    return "transparent"
  }

  readonly property color sensorColor: sensorExpired ? colorUrgent : (sensorExpiring ? colorHigh : contentForeground)

  // Guarded so the panel renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Polling. The script is cheap on a cache hit (one properties call);
  //      the expensive full-history scan happens once per sensor.
  //
  // Every knob is passed on the command line rather than read from a config
  // file by the script, so the widget's shell.json entry is the single place
  // a site is described, and so the script stays runnable by hand.
  readonly property int intervalSec: Math.max(15, parseInt(setting("intervalSec", 60), 10) || 60)
  readonly property string configuredUrl: String(setting("url", "")).trim()
  readonly property string scriptPath: String(Qt.resolvedUrl("scripts/nightscout.py")).replace(/^file:\/\//, "")

  function numericArg(flag, key, fallback) {
    var value = Number(setting(key, fallback))
    return isFinite(value) ? [flag, String(value)] : []
  }

  readonly property var scriptCommand: {
    var command = ["python3", scriptPath]
    if (configuredUrl !== "") command = command.concat(["--url", configuredUrl])

    var tokenFile = String(setting("tokenFile", "")).trim()
    if (tokenFile !== "") command = command.concat(["--token-file", tokenFile])

    return command
      .concat(numericArg("--sensor-days", "sensorDays", 0))
      .concat(numericArg("--warmup-mins", "warmupMins", 60))
      .concat(numericArg("--warn-hours", "warnHours", 24))
      .concat(numericArg("--stale-mins", "staleMins", 5))
      .concat(numericArg("--timeout", "timeoutSec", 4))
  }

  // Whatever the script actually talked to, so the open action and the
  // reading can never point at different sites.
  readonly property string browseUrl: payload && payload.url ? String(payload.url) : configuredUrl

  readonly property string expiryLine: {
    if (!sensorKnown) return ""
    var when = Qt.formatDateTime(new Date(sensor.expiryMs), "ddd d MMM HH:mm")
    if (sensor.leftSecs <= 0) return "Expired " + sensor.leftLabel + " ago · " + when
    return "Expires " + when + " · " + sensor.leftLabel + " left"
  }

  // The bar injects settings a beat after constructing the widget, so the
  // command is always built once from empty settings before the real one
  // arrives. Polling on a short settle rather than on construction means one
  // fetch with the configured site, instead of a wasted unconfigured fetch
  // and a "⚠️ NS" flash on every shell restart.
  onScriptCommandChanged: settleTimer.restart()

  function applyOutput(raw) {
    refreshing = false
    var text = String(raw || "").trim()
    if (text === "") return
    try {
      root.payload = JSON.parse(text)
    } catch (e) {
      // Keep the last good reading rather than blanking the bar on a
      // half-written or garbled line.
    }
  }

  function refresh() {
    if (readingProc.running || demoMode) return
    refreshing = true
    readingProc.running = true
  }

  function openSite() {
    if (root.bar && browseUrl !== "") root.bar.run("xdg-open " + Util.shellQuote(browseUrl))
  }

  function open() {
    root.controller.show()
    refresh()
  }

  function openFromHotkey() {
    root.controller.show()
    refresh()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  Process {
    id: readingProc
    command: root.scriptCommand
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOutput(text)
    }
    onExited: root.refreshing = false
  }

  Timer {
    id: settleTimer
    interval: 150
    running: true
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.intervalSec * 1000
    running: !root.demoMode
    repeat: true
    onTriggered: if (!readingProc.running) readingProc.running = true
  }

  // Driven explicitly rather than by a `running:` binding, because demoStep
  // restarts it to keep a manual step from being cut short, and an imperative
  // restart() would break that binding and leave it ticking after demo ends.
  Timer {
    id: demoTimer
    interval: 1000
    repeat: true
    onTriggered: root.demoStep(1)
  }

  // Fake glucose must never outlive the panel that explains it. Closing the
  // popup ends the preview, so a demo reading cannot be left sitting on the
  // bar to be mistaken for the real one.
  onOpenedChanged: if (!opened && demoMode) setDemoMode(false)

  // No IpcHandler here: BarWidget.qml owns the `vulturetone.omascout` target, so
  // that a call reaches every screen's instance through its broadcast rather
  // than whichever panel happened to register first. `manageIpc: false` keeps
  // the base class from claiming the target too.

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // Anchored under the pill rather than centered on the bar: centering is
    // for center-section widgets (the clock, the weather), and this one lives
    // among the status widgets on the right.
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onReturnRequested: root.refresh()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(14)

        // ---- Hero: the reading itself, sized to be read from across the
        //      room, with the delta and the reading age stacked beside it.
        Item {
          width: parent.width
          height: Math.max(heroLeft.height, heroRight.height)
          visible: root.ok

          Row {
            id: heroLeft
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.glucose ? root.glucose.shown : "!?!"
              color: root.glucoseColor
              font.family: root.contentFontFamily
              // Hero read-out, deliberately outside the Style.font.* scale.
              font.pixelSize: 46
              font.bold: root.urgent
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              anchors.verticalCenterOffset: Style.space(3)
              text: root.glucose ? root.glucose.arrow : ""
              color: root.glucoseColor
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.displayLarge
            }
          }

          Column {
            id: heroRight
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Text {
              anchors.right: parent.right
              text: root.glucose ? root.glucose.delta : ""
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              anchors.right: parent.right
              text: root.glucose ? root.glucose.ageLabel : ""
              color: root.stale ? root.colorStale : Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        // ---- Stale feed. The number above is still the last real reading,
        //      so it stays on screen; this says why it has stopped moving.
        Text {
          visible: root.stale
          width: parent.width
          text: "Feed is stale. Is Juggluco uploading?"
          color: root.colorStale
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
          wrapMode: Text.WordWrap
        }

        // ---- Error. Replaces the hero rather than sitting under it: there
        //      is no reading to show.
        Column {
          visible: !!root.shownPayload && !root.ok
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: root.shownPayload ? String(root.shownPayload.title || "Nightscout error") : ""
            // A missing URL is a setup step, not an alarm; a site that went
            // away while you were wearing a sensor is.
            color: root.unconfigured ? root.colorHigh : root.colorUrgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.heading
          }

          Text {
            width: parent.width
            text: root.shownPayload ? String(root.shownPayload.detail || "") : ""
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }

        Text {
          visible: !root.shownPayload
          text: "Reading…"
          color: Qt.darker(root.contentForeground, 1.5)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        PanelSeparator {
          visible: root.ok && root.sensorTracked
          foreground: root.contentForeground
        }

        // ---- Sensor life. Derived, not reported. See the script's header
        //      for why the first reading carrying a serial dates it. The whole
        //      block is absent unless a wear time is configured.
        Column {
          visible: root.ok && root.sensorTracked
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            height: Math.max(sensorHeader.implicitHeight, sensorAge.implicitHeight)

            PanelSectionHeader {
              id: sensorHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.contentForeground
              text: root.sensor ? "SENSOR " + root.sensor.serial : "SENSOR"
            }

            Text {
              id: sensorAge
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.sensorKnown
              text: root.sensorKnown ? root.sensor.ageLabel + " of " + root.sensor.days + "d" : ""
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          // Wear rail: fills as the sensor ages, and takes the warning color
          // once it is close to done.
          Rectangle {
            visible: root.sensorKnown
            width: parent.width
            height: Style.space(6)
            radius: Style.cornerRadius > 0 ? height / 2 : 0
            color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

            Rectangle {
              width: Math.round(parent.width * (root.sensorKnown ? root.sensor.fraction : 0))
              height: parent.height
              radius: parent.radius
              color: root.sensorColor

              Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            }
          }

          Text {
            width: parent.width
            text: root.sensorKnown ? root.expiryLine : "Age unknown, no history for this serial"
            color: root.sensorKnown && (root.sensorExpired || root.sensorExpiring)
              ? root.sensorColor
              : Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: !root.sensorKnown
            wrapMode: Text.WordWrap
          }
        }

        PanelSeparator {
          foreground: root.contentForeground
        }

        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          Button {
            text: "Refresh"
            iconText: "󰑐"
            iconSpinning: root.refreshing
            bordered: true
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.refresh()
          }

          Button {
            text: "Open Nightscout"
            iconText: "󰖟"
            bordered: true
            enabled: root.browseUrl !== ""
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: {
              root.openSite()
              root.close()
            }
          }
        }

        // ---- Demo. Steps through every state on a one-second cycle so the
        //      whole palette, including any overridden colour, can be checked
        //      against a live bar without waiting on real glucose to go there.
        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          Button {
            text: root.demoMode ? "Stop demo" : "Demo"
            bordered: true
            selected: root.demoMode
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.setDemoMode(!root.demoMode)
          }

          Button {
            visible: root.demoMode
            text: "‹"
            bordered: true
            tooltipText: "Previous state"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.demoStep(-1)
          }

          Button {
            visible: root.demoMode
            text: "›"
            bordered: true
            tooltipText: "Next state"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.demoStep(1)
          }
        }

        Text {
          visible: root.demoMode
          width: parent.width
          text: (root.demoIndex + 1) + " / " + root.demoScenarios.length + " · " + root.demoLabel
          color: Qt.darker(root.contentForeground, 1.5)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
